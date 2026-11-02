---
name: pl-accelerator-on-board
description: >-
  把训练好的 int8 神经网络部署成 PL 加速器并跑起来的一条完整链路：
  **微架构怎么切**（按输出通道驻留，不要按输入通道切换）、**大权重数组怎么真落进一块单端口 BRAM**、
  **量化怎么与 TFLite 逐位对齐**、**PYNQ 侧怎么驱动**（`ap_ready`/`ap_done`/`ap_idle` 的真实语义、两段等待、
  cache 双向同步、句柄没连上真 IP）、**怎么逐段计时对账**，以及本项目这一版的具体寄存器、文件指纹与专属坑。
  当你要把 CNN/算子挪到 PL、HLS 综合后资源爆掉、加速器等不到 AP_DONE、读到旧数据、或者要在这个工程上换模型时使用。
  本技能不管 BD 侧的 IP 版本管理与重建流程（见 `../vivado-bd-ops/SKILL.md`），也不管通用 DMA cache 原理（见 `../pynq-dma-cache/SKILL.md`）。
scope: 通用（HLS/FPGA 加速器设计 + PYNQ 主机驱动）；末节"本项目档案"换题目即作废
compatibility: Vitis HLS 2026.1 + PYNQ（`pynq.Overlay` / `pynq.allocate`）；xc7z020 已实测，换器件只改并行度常数
inputs: 一个已量化的 int8 模型（或任一 HLS 算子）；PC 端逐层黄金参考
outputs: 一个能 C 仿真逐字节通过的核；一个能在 PYNQ 上自检、计时、稳定调用的驱动
version: 2.0.0
updated: 2026-11-03
license: MIT
verified_effect: "内核单次 9.15 ms（有效算力 6.58 GMAC/s，达理论峰值 52%）；classify 全程 14.62 ms（空载）/16.8 ms（生产）；自检与 PC 端逐位参考最大绝对差 < 0.01。"
origin: "合并自三段实践：① 同一个网络切错并行维度导致 MAC 效率只有 17%（55.42 ms），改为按输出通道驻留后 22.96 ms；② 权重数组被 HLS 静默复制成 9 份（BRAM 119%）与 `BIND_STORAGE` 被忽略（FF 105%）；③ 驱动侧等 `AP_READY` 超时、裸 MMIO 读到 CTRL=0、启动后立刻读到上一轮结果。"
---

# 把加速器部署到 PL 并跑起来：从微架构到 PYNQ 驱动

本技能覆盖一条完整链路：**设计核 → 量化对齐 → 资源落地 → 主机驱动 → 逐段计时 → 本项目实值**。三段原本是独立的技能文件（`hls-accelerator-on-pl`、`pl-accelerator-host-driver`、`cnn-on-pl`），现合并为一份，因为它们在实践中总是同时出现。

---

## 一、这个技能解决什么

把 `QUANTIZE → CONV ×4 → POOL ×3 → GAP → FC → DEQUANTIZE` 这种小网络搬到 PL 上，**难点从来不是"写出来"**，而是六件事：

| # | 难点 | 典型症状 |
|---|---|---|
| 1 | 数据流怎么切 | 切错维度，MAC 效率只有 17% |
| 2 | 大权重怎么落进一块 BRAM | 你以为 1 块，HLS 静默复制成 9 块（BRAM 119%） |
| 3 | 量化怎么逐位对齐 | 差 1 个 LSB，端到端精度不可解释 |
| 4 | 主机侧状态位怎么等 | 死等 `AP_READY`、启动后读到上一轮结果 |
| 5 | cache 怎么同步 | PL 读到旧数据、CPU 读到旧结果，**都不报错** |
| 6 | 时间花在哪 | 没有逐段数字就优化 = 猜（本项目三次纸面反推全错） |

---

## 二、什么时候用 / 什么时候别用

**用**：
- 要把已量化的 int8 CNN（或任一算子）放到 PL 上做实时推理；
- HLS 综合报 `FF/LUT/BRAM > 100%`，需要知道是哪种写法导致；
- 已有 HLS 版本但吞吐远低于算术地板；
- 要在 PYNQ 上调用自己做的 HLS IP，等不到 AP_DONE/AP_IDLE、或读到旧数据。

**别用**：
- 网络太大、权重超出片上 BRAM —— 那是权重流式/分块从 DDR 读的另一套结构；
- 只是想让 PS 跑得快点 —— 先试推理引擎多线程；
- 没有 PC 端逐层黄金参考 —— 没判据，先补 `../golden-compare/SKILL.md`；
- 用的是 PYNQ 官方 DMA/VDMA 库 —— 有现成驱动，别自己写；
- IP 带 `s_axis`/`m_axis` 流接口 —— 那是 AXIS 流控，先看 tvalid/tready 握手。

---

## 三、第一步永远是算算术地板

```
加速下限 = 网络 MMAC ÷ (每周期 MAC 数) ÷ 时钟频率
```

本项目（64×64 int8、60.2 MMAC、64 MAC/周期 @100 MHz）：

```
60.2e6 ÷ 64 ÷ 100e6 = 9.41 ms
```

**这条线决定目标定得对不对**。想跑到 10 ms 以下必须 128 MAC/周期，而在 xc7z020 上那要约 256 个 DSP（>220，装不下）⇒ **定目标前先算这条线**，别为物理上做不到的目标改结构。

实测效率算法：`实测 MMAC ÷ 实测时间 ÷ 时钟`，再除以设计并行度。本项目 v4 实测 55.42 ms ⇒ 10.9/64 = **17%**；v5 实测 22.96 ms ⇒ 26.2/64 = **41%**。

---

## 四、★ 核心结论：按**输出通道**驻留，不要按输入通道切换

同一网络、同一器件，两种切法差 2.4 倍，**而且后者资源更低**。

| | 按输入通道切换（v4） | 按输出通道驻留（v5） |
|---|---|---|
| 片上保存 | 一个输入通道块的权重 tile（576 B） | **一个输出通道组的全部权重**（9 KB） |
| 累加器放哪 | **BRAM 平面**（131 KB） | **寄存器** `acc0/acc1[POC]` |
| 每次内层 MAC | 576 | 576（同样） |
| 每次内层额外代价 | **累加器 BRAM 往返 + 循环控制 ≈25~32 周期** | **0** |
| 权重载入次数 | 676 | **60** |
| 实测 | 55.42 ms | **22.96 ms** |

切输入通道 ⇒ 每算完一小片就要把累加器写回 BRAM、下一片再读回来；这个固定代价（25~32 周期）摊在只有 576 个 MAC 的内层上，**比计算本身还大**。切输出通道 ⇒ 累加器全程留寄存器，权重整块驻留，代价摊成 0。

★ **代价是"重复读输入"而不是"重复读权重"** —— 输入张量比权重小一个数量级，这是 SqueezeJet-2 的做法，也是本方案依据。

```
for og in 输出通道组:                    # 外层：每组一次
    一次性载入该组的全部权重到 wblk
    for 每个输出像素（含池化存回位置）:
        for (tap × 输入通道块):          # 内层：流水 II=1
            64 MAC（POC × PIC）
        写回 / requant / 2×2 max 池化
```

---

## 五、★ 让大权重数组真的落进**一块**单端口 BRAM

两种写法都"看起来对"，实际都爆：

| ❌ 写法 | 结果 | 为什么 |
|---|---|---|
| `ARRAY_PARTITION ... complete` + `BIND_STORAGE ... BRAM` | **FF 112,154（105%）、LUT 86,523（162%）** | `complete` 把子数组拆成标量，`BIND_STORAGE` 被**静默忽略** |
| `ARRAY_RESHAPE block factor=64` + `BIND_STORAGE` | **BRAM 334/280（119%）** | `ARRAY_RESHAPE` **只加宽到 128 bit**，为凑 64 个读口把同一块存储器**复制 9 份** |

```cpp
// ✅ 元素类型直接声明成 512 位宽 ⇒ 一拍读出 64 个 int8 权重
ap_uint<POC * PIC * 8> wblk[9][MAXCINP / PIC];      // 单数组，无 partition/reshape
#pragma HLS BIND_STORAGE variable=wblk type=RAM_2P impl=BRAM
```

实测变成**一个实例 `512, 144`**，BRAM 降到 **46.5 块（33.2%）**；取值 `wv.range(((j*PIC+t)*8)+7, ((j*PIC+t)*8))` 逐字节切。

**三条纪律**：① `BIND_STORAGE` 只对**真数组**生效，任何改变数组形状的 pragma 都会让它白写；② HLS 加宽上限 128 bit，要更宽就改元素类型；③ 判据永远看**真实 OOC 综合**报告。

---

## 六、量化对齐：逐位复刻 TFLite

| 步骤 | 要点 |
|---|---|
| `QuantizeMultiplier` | `frexp` 拆(尾数,指数) ⇒ **`frexp` 不可综合**，必须在 PC 上预算成 (int32, shift) 表，核里只查表 |
| `SaturatingRoundingDoublingHighMul` | 定点乘 + 双重舍入，注意 nudge `1<<30` / `1-(1<<30)` |
| `RoundingDivideByPOT` | 算术右移 + 舍入偏移，**截断不是四舍五入** |
| 输入量化 | `round_half_away_from_zero`，**不能用银行家舍入** |

**两个可严格证明的等价变换**：

1. **池化融进 requant**：max 直接在 **int32 累加值**上取 —— requant 单调 ⇒ 先 requant 再 max 与先 max 再 requant **逐位等价**，省 3/4 requant。
2. **零点折进 bias**：`Σ(iv−izp)·w = Σiv·w − izp·Σw`，右边只需 PC 上算一次 `b_cor = b − izp·Σw` ⇒ 把 MAC 路径上的减法器删掉。

---

## 七、并发度翻倍：先量 II，再决定加什么硬件

| 指标 | POC=8 | POC=16 |
|---|---|---|
| 内层 MAC 迭代 | 1,032,192 | **516,096（减半）** |
| 最高频域总延迟（HLS 估计） | 83.4 M 拍 | **41.6 M 拍** |
| DSP | 52 | 84 |
| BRAM | 46.5 | 67.5 |
| LUT（布线后） | 14,821 | 18,728 |

**① int8 乘加能打包进 DSP48E1** ⇒ 并发度基本线性加速（实测 **64 MAC 只花 34 个 DSP ≈ 2 MAC/DSP**），别假定"一个 MAC 一个 DSP"。

**② 先确认瓶颈在算术上**：本核整链 22.96 ms，MAC 只占 ≈1.03 M 拍（10.3 ms）⇒ **一半时间不在 MAC 上**，读循环表才发现真凶是**权重载入 II=64**。

**③ `max_widen_bitwidth` 单独加没用，必须显式宽读**：只加 pragma 会把 II 从 64 推到 **128**（`Lower bound of II is 128 due to multiple operations accessing 'gmem' m_axi read`）。正解是 `reinterpret_cast` 成宽类型、用对齐宽字读 ⇒ II **128→16**，载入 3.9 ms → **0.49 ms**，LUT 估计 44,863 → 35,666（逐字节 mux 比宽字贵）。

**④ 两个"以为改了其实没改"的坑**：`max_widen_bitwidth` **不改** IP 的 `C_M_AXI_GMEM_DATA_WIDTH`（要在 BD 设）；宽读**必须对齐**，不对齐读出的值错且**不报错**。

**⑤⑥** HLS 的 LUT 估计约为布线后 **2 倍**（35,666 → 18,728）；资源可行性按 **LUT/FF/BRAM/DSP** 判断，**Slice 满只说明布局拥挤、不是门槛**。

---

## 八、★ 主机侧：三个状态位的真实语义

| 位 | 语义 | 坑 |
|---|---|---|
| `AP_START` (bit0) | 写 1 启动一次 | 写完不自清零，别靠读它判"是否在跑" |
| **`AP_DONE` (bit1)** | **电平**：跑完拉高，**保持到下一次 AP_START** | 直接"等它变 1"会**立刻通过**（上一轮的 1 还在）⇒ 读到上一轮结果 |
| **`AP_IDLE` (bit2)** | 空闲且未启动时为 1 | 跑完前读不到 1，忙等它会死等 |
| **`AP_READY` (bit3)** | 只对带 `s_axis` 等输入就绪接口的核有意义 | ★ **纯 `m_axi`+`s_axilite` 的核这一位永久为 0**，等它必然超时 |

```python
ip.write(R_CTRL, 1)                       # 启动
while ip.read(R_CTRL) & 2:                # ① 等上一轮的 AP_DONE 落下去，证明这次启动被接受
    pass                                  #    ★ 少了这段就会立刻读到上一轮结果
while not (ip.read(R_CTRL) & 2):          # ② 再等这次跑完
    pass
buf_out.invalidate()                      # ③ 读结果前必须作废 cache
```

**每一段等待都必须带超时**，否则 IP 出问题就是整个 Jupyter 内核卡死。

---

## 九、CMA 缓冲与 cache 一致性

| 方向 | 必须做 | 漏了的现象 |
|---|---|---|
| CPU 写 → PL 读 | 写完 `buf.flush()` | PL 读到**旧数据**，像"IP 没工作" |
| PL 写 → CPU 读 | 读前 `buf.invalidate()` | CPU 读到**旧数据**，像"IP 没跑完" |

① 缓冲必须 `pynq.allocate()`（物理连续），`np.zeros()` 不连续、PL 按物理地址会读到别的内存；② **不报错**是这两类 bug 最恶的地方。

---

## 十、★ 句柄：裸 `MMIO` 可能根本没连上 IP

实测：`MMIO(0x43C30000).read(0x00)` 读出 **0x00000000**，而同一时刻 `overlay.<ip>.read(0x00)` 是 **0x00000004**（正常 AP_IDLE）。

**做法**：优先复用已加载 overlay 里的 IP 对象。

```python
ip = None
for ol in getattr(Overlay, "_instances", {}).values():   # ⚠️ PYNQ 3.0.1 上恒为空，见下
    if "<ip_inst>" in getattr(ol, "ip_dict", {}):
        ip = getattr(ol, "<ip_inst>")
        break
if ip is None:
    ip = MMIO(BASE, RANGE)                               # 实在找不到才裸映射，并打印警告
```

★ **绝不要为了"拿句柄"再调用一次 `Overlay()`** —— 那会重新编程 PL，寄存器全复位，同一位流上别的子系统（相机链路/VDMA/时钟）当场失效。
★ **`getattr(Overlay, "_instances", {})` 在 PYNQ 3.0.1 上不存在**，`getattr` 的默认值会**静默**让代码退回裸 MMIO ⇒ CTRL 读出 0。正解是从当前命名空间取已加载对象（`globals().get("ol")` → `ol.<ip>`），取不到要**打印警告**而不是静默兜底。
**推论**：寄存器随时可能被复位清掉 ⇒ **每次调用前把基地址重写一遍**（成本 0.36 ms），比"只在初始化写一次"稳。

---

## 十一、★ 逐段计时：先量，再优化

把"一次调用"拆成**互不重叠的段**，各自计时，最后求和与总时间对账：

| 段 | 本项目实测 | 说明 |
|---|---|---|
| 预处理（缩放/归一化） | 随 ROI 面积变（≈84 ns/px） | ★ 唯一跟输入大小有关 |
| 量化 float→int8 | **3.14 ms** | 固定开销 |
| 写输入 + `flush()` | 0.47 ms | |
| 写 6 个基地址（12 次 MMIO） | 0.36 ms | ≈30 µs/次 |
| **启动 → 等到 AP_DONE** | **23.65 ms** | 加速器本体 |
| `invalidate` + 解包 | 0.52 ms | |
| softmax | 0.33 ms | |
| **合计** | **≈35.6 ms** | 与实测总时间**逐步对上** |

**对账的价值**：一眼看出"本体 23.65 ms / 框架开销 12 ms"的比例；本体与单独测的 22.96 ms 只差 3% ⇒ **证明加速器在真实 DDR 争用下没被拖慢**（可写进报告的正向结论）。

**反例**：本项目连续三次纸面反推（估 31 / 42 / 29.5 ms）**全错**。**没有逐段实测，不许谈优化。**

---

## 十二、★ 主机侧预处理查表化：把浮点链压成 256 项表

**问题**：推理本体搬到 PL 后，主机侧预处理反而成了大头（35.6 ms 里 **预处理 7 ms + 量化 3.14 ms = 10.2 ms**）。

**观察**：`像素 → /255 → (x−mean)/std → /scale → round → +zp` 整串都是**逐像素一维映射**，而 8 位图像只有 256 种取值 ⇒ 预先把整链算成 **256 项表**，运行时只剩一次 gather。

```python
def build_quant_lut():                      # (3,256) uint8 表
    tab = np.empty((3, 256), dtype=np.uint8)
    v = np.arange(256, dtype=np.float32)
    for c in range(3):
        x = v / np.float32(255.0)                                   # ① /255
        x = (x - np.float32(MEAN[c])) / np.float32(STD[c])           # ② 归一化
        x = x / np.float32(IN_SCALE)                                 # ③ 除量化 scale
        x = np.trunc(x + np.sign(x) * np.float32(0.5))               # ④ 远离零取整
        x = np.clip(x + IN_ZP, -128, 127).astype(np.int8)            # ⑤ 加零点夹 int8
        tab[c] = x.view(np.uint8)
    return tab

lut   = build_quant_lut().reshape(-1)                        # (768,)，索引 = c*256+v
choff = (np.arange(flat.size, dtype=np.int32) % 3) * 256     # 预计算一次
q     = lut[flat + choff].view(np.int8)                      # 一次 gather
```

**四条必须守住**：① 逐字节等价靠"**运算顺序 + dtype 完全一致**"，建表要照抄原顺序与 float32；② 取整是**远离零**（`np.trunc(x+sign(x)*0.5)`），**不能用 `np.round`**；③ `letterbox`/缩放不要自己重写，复用训练端一致的那份；④ 验证：随机 200 张 + 全 0/全 255 边界，新旧路径 `count_nonzero(a!=b)` **必须恒为 0**。

**收益**：10.2 ms → **~1.5 ms**，不动位流、不改 HLS。

---

## 十三、Workflow

**设计侧**
| 步 | 做什么 | 判据 |
|---|---|---|
| 1 | 算算术地板 | 目标时间 ≥ 下限 |
| 2 | PC 端 numpy 逐位参考（`ref_cnn.py`） | 与板上引擎最大绝对差 < 0.01 |
| 3 | 导出权重/偏置/requant 表为扁平 bin | 字节数与布局表一致 |
| 4 | 定 POC×PIC，算权重块大小 | 权重总量 ÷ BRAM 容量 < 可用块数 |
| 5 | 选数据流、写核 | **C 仿真逐层逐字节一致** |
| 6 | 每次改布局/索引后**必跑 C 仿真** | PASS（数值校验抓不到索引错） |
| 7 | 真 OOC 综合看资源 | LUT/FF/BRAM/DSP 都 < 100% 且与上版对比可解释 |
| 8 | 上板实测 | 效率与算术地板换算解释得通 |

**驱动侧**
| 步 | 做什么 | 判据 |
|---|---|---|
| 1 | 用 IP 自带黄金向量跑自检（不经预处理） | 输出与 PC 参考逐字节相同 |
| 2 | 打印 `CTRL` 与全部基地址寄存器 | `AP_IDLE=1`、基地址非 0 |
| 3 | 单次调用 + 超时保护 | 不卡死、结果正确 |
| 4 | 连续 N 次 | 稳定；前 1~3 次可能偏慢（冷启） |
| 5 | 逐段计时并与总时间对账 | 各段之和 ≈ 总时间，差 < 5% |
| 6 | 账对上之后才谈优化 | 账没对上就优化 = 猜 |

---

## 十四、已验证效果

| 版本 | 纯推理 | MAC 效率 | LUT | FF | BRAM | DSP | OOC WNS |
|---|---|---|---|---|---|---|---|
| v4（切输入通道） | 55.42 ms | 17% | 19,910 (37.4%) | 21,475 | 79 (56.4%) | 20 | +1.960 ns |
| v5（切输出通道 POC=8） | **22.96 ms** | **41%** | **14,821 (27.9%)** | **15,842** | **46.5 (33.2%)** | 52 | **+1.742 ns** |

★ **v5 不仅快 2.41 倍，LUT/FF/BRAM 三项还同时更低** ⇒ "按输出通道划分"不是拿资源换速度，而是**结构上更省**。

驱动侧：黄金向量逐字节 PASS；7 段求和 35.6 ms 与生产实测**完全一致**；2910 次连续调用无失败、无累积漂移。

本项目最终两档（POC=16，2026-10-28）：**内核 9.15 ms**（min 9.14 / max 9.18，抖动 0.4%）｜`infer()` 10.18｜**`classify()` 14.62 ms**（空载）/ **16.8 ms**（生产负载，比空载慢 15%：DDR 争用 + 真实 ROI 更大）；有效算力 2.62 → **6.58 GMAC/s（峰值 52%）**。

---

## 十五、本项目档案（换题目即作废）

| 项 | 值 |
|---|---|
| IP | `xilinx.com:hls:cnn_top:1.4`（★ 每次重做必须 bump 版本号，否则 Vivado 用缓存网表） |
| 地址 | **`0x43C30000`**，64 KB（`ps7_0_axi_periph` 第 7 个从口） |
| 数据口 | `S_AXI_HP1`，经 `smartconnect` 接入（`axi_protocol_converter` 不能转位宽） |
| 接口 | 6 个 `m_axi` + 1 个 `s_axilite`（**纯 m_axi ⇒ `ap_ready` 恒 0**） |

**寄存器偏移**（每个指针占低/高两个 32 位）：`0x00` CTRL（[0]AP_START / [1]AP_DONE 电平 / [2]AP_IDLE / [3]AP_READY 恒 0）｜`0x10` 权重 blob｜`0x1C` 偏置｜`0x28` requant 乘数｜`0x34` requant 移位｜`0x40` 输入图（int8，12288 B）｜`0x4C` 输出（4 个 int32：`[0][1]` 打包 6 个 int8 logits、`[2]` 信标、`[3]` 备用）。

**数据文件**（布局一变必须整套重传）：`model_blob.bin` 390,912（布局 `[og][tap][ib][oc][ic]`，**换 POC 就整套换布局**）｜`model_bias.bin` 1,944｜`model_mmult.bin` 2,968｜`model_mshift.bin` 2,968｜`golden_in.bin` 12,288。
★ **`N_BLOB=390912` / `N_BIAS=486` / `N_MUL=742` 三个数不随模型变**（只由通道数/核尺寸决定），换模型后常量不用改、**内容必须整套重传**。
**黄金值**（2026-10-28 换模型后）：int8 logits `[-39, 95, 7, -116, -49, -128]`，argmax=1（can）；`selftest()` 必须 PASS。

**换模型完整流程（顺序不可乱，前提是新旧网络结构完全一致）**：
1. `dump_tflite.py` 解析新模型，逐字段与旧 `weights.npz` 对比（`keys same: True`、shape 相同、激活 `zero_point` 相同）；
2. `dump_tflite.py <新模型> weights.npz` 覆盖（先备份）；
3. `gen_data.py` 重导 bin 与 `golden_*.bin`、`model_meta.h` —— ★ 其中 `POC_TILE` **必须等于** `cnn_accel.cpp` 的 `POC`；
4. C 仿真：**七层全部 `mismatch=0`**，且打印的 logits 等于新黄金值；
5. 综合 → `--package`（版本号 bump）→ BD `upgrade_ip` → 构建。

**★★ 最容易静默出错的一步：换模型后 `FC_ZP` 可能变。** 这次 **0 → −3**（`FC_SCALE` 0.087355129 → 0.113328353）。若驱动里还写旧 `FC_ZP = 0`，**分类结果整体偏 3 个 LSB 且完全不报错**。判据：每次都去 `model_meta.h` 抄，不要凭记忆。

**本项目专属的坑**：

| 坑 | 现象 | 正解 |
|---|---|---|
| 读掩膜忘先切档 | `detect()` 返回覆盖整幅的框 `(0,0,972,720)`，ROI `(720,962,3)`，预处理从 7 ms 涨到 **58 ms** | 读 `v1[0]` 前**必须 `set_disp(5)`** |
| `tflite_infer.py` 的 SIZE | 盘上旧版 `SIZE=42` + 默认 `'model.tflite'`，PL 往 12288 B 缓冲写 5292 B ⇒ `ValueError` | 板端是 `SIZE=64` + `'model_int8_64.tflite'`；**判据 `print(ti.SIZE)` 必须是 64** |
| 两个 tflite 同大小 | `model_int8.tflite` 与 `model_int8_64.tflite` **都是 408,464 B** | 只能看 `IMG_W` 宏 / golden 字节数（12288）判断 |
| 模型文件名多空格 | 传上来是 `model_int8_64 .tflite`（`.` 前多一个空格） | 上传前 `dir` 核名字；Windows 里这个空格很容易看不见 |
| 重启内核后寄存器复位 | 掩膜全黑/全白、相机不出图 | `%run cam_full.py` 之后**必须重跑 `config.py`**；`capture_bg()` 必须在空场景、放物体之前跑 |
| 运动画面撕裂 | 静止正常，一运动横向撕裂 | VDMA GenLock 下 `FRMDLY=0` 时 MM2S 读正在写的帧 ⇒ 显示通路帧延迟 **≥1** |

---

## 十六、DON'Ts（全部实测踩出）

| 坑 | 现象 | 正解 |
|---|---|---|
| 用 HLS 的 estimate 判断能不能装下 | 同版 estimate LUT 48,724，真实 OOC 20,104 | **只信真实 OOC 综合** |
| 用 HLS 报的 cycle/latency 估运行时间 | 报 8.3×10⁷ 周期，与实测无关 | 只能上板测 |
| 用 cosim 做 profile | 194 s CPU 只推进 12,500 周期（全跑 ~25 小时） | 改用**上板分段计时** |
| 改完权重布局只做数值检查就综合 | 权重载入基址漏乘 `POC`，布局校验和折叠偏置校验**全过**，C 仿真才炸 | **布局一改必跑 C 仿真**，逐层比对 |
| 内层循环写边界判断/运行时除法 | `control-flow is too complicated to be pipelined` | 用**补边 arena**（四周补 1 像素量化零点）消掉分支 |
| 多个 `m_axi` 端口参数不一致 | `HLS 214-215 bundled ports should have same adapter parameters` | 所有 m_axi 写**完全相同**的 latency/outstanding/burst |
| 等 `AP_READY` | 永远是 0 | 判"能不能启动"看 `AP_IDLE` |
| 裸 `MMIO` 读寄存器 | CTRL 读到 0x00，像"IP 没起来" | 复用 overlay 里的 IP 对象 |
| 为拿句柄再 `Overlay()` 一次 | 寄存器全复位、别的子系统当场失效 | 复用，不要重新配置 |

---

## 十七、来源

从"把 64×64 int8 CNN 从 PS 挪到 PL、并从 55.42 ms 压到 9.15 ms、再写成稳定驱动"这一整段实践总结，共 5 个微架构版本 + 一整轮驱动调试：

- **v1~v2**：单层卷积跑通，验证量化对齐可行。
- **v3~v4**：四层共用一套计算单元 + 运行时描述表，实测 55.42 ms ⇒ 由"效率只有 17%"反推出"切输入通道导致累加器 BRAM 往返"。
- **v5**：照 SqueezeJet-2（同为 xc7z020）改成输出通道驻留，一次到位 22.96 ms。
- **资源爆掉那两轮**（FF 105% / BRAM 119%）纯属 HLS pragma 语义问题，与算法无关。
- **v1.4**：POC 8→16 + 权重 64 位宽读 ⇒ 内层迭代减半、II 128→16，纯推理 9.15 ms。
- **驱动侧**：`等 AP_READY 超时 CTRL=0x00000004`（纯 m_axi 核该位恒 0）；`AP_IDLE 超时 CTRL=0x00000000`（裸 MMIO 没连上真 IP）；"启动后立刻读到上一轮结果"（`AP_DONE` 是电平）；35.6 ms vs 估的 29.5 ms 差 6.8 ms ⇒ 逐段计时才发现量化一项就占 3.14 ms。

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 2.0.0 | 2026-11-03 | 由 `hls-accelerator-on-pl` + `pl-accelerator-host-driver` + `cnn-on-pl` 三份合并：微架构（算术地板/输出通道驻留/宽字权重/量化对齐/并发度）+ 主机驱动（三状态位/两段等待/cache/句柄/逐段计时/预处理查表）+ 本项目档案（寄存器/文件指纹/换模型流程/专属坑）。合并时消除三份之间的重复条目，保留全部判据与实测数字 |

---

## 相关文件（Integration）

- 上游：`../golden-compare/SKILL.md`（PC 端逐层黄金参考是验收前提）
- 平行：`../vivado-bd-ops/SKILL.md`（IP 版本号 bump、`v++ --compile` 后再 `--package`、OOC 综合陷阱）
- 平行：`../pynq-dma-cache/SKILL.md`（cache 一致性的通用原理）
- 平行：`../pynq-overlay-regmap/SKILL.md`（加载 overlay 与寄存器访问范式）
- 平行：`../memory-structure-timing/SKILL.md`（HDL 侧存储器端口数与 BRAM 推导）
