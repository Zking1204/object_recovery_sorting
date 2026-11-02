---
name: pl-accelerator-host-driver
description: >-
  在 PYNQ 上用 Python 驱动一个 HLS 导出的 `m_axi` + `s_axilite` 加速器：CMA 缓冲与 cache 一致性、
  **`ap_ready` / `ap_done` / `ap_idle` 三个状态位的真实语义**、裸 `MMIO` 读不到寄存器怎么办、
  以及"把一次调用逐段计时与总时间对账"的方法。本技能只做主机侧驱动与计时，不做加速器微架构。
scope: 通用（PYNQ / Zynq PS 侧驱动任意 HLS IP）
when_to_use: 要在 PYNQ 上调用自己做的 HLS IP；等不到 AP_DONE/AP_IDLE；加速器读到的数据是旧的；想知道一次调用里时间都花在哪
triggers: ["等 AP_READY 超时", "等 AP_IDLE 超时", "CTRL 读出 0x00000000", "加速器读到旧数据", "allocate flush invalidate", "AP_DONE", "ap_ready 一直是 0", "逐段计时", "一次调用多久"]
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "驱动具备"写基地址、分配输入输出缓冲、触发与轮询、黄金自检"四段，任一段失败都能定位到具体环节。"
origin: "加速器曾出现"寄存器值都写对了但不启动"，靠把基地址回读、输入缓冲内容、自检结果三样一起打印，才把范围从整条链路收窄到单一寄存器。"
---

# 在 PYNQ 上驱动 HLS 加速器：状态位语义与逐段计时

## 一、这个技能解决什么

HLS 导出的 IP 在 PYNQ 上的接口只有两类：**AXI-Lite（寄存器/指针）** 和 **m_axi（数据）**。看起来简单，但有三类坑会让程序直接卡死或读到垃圾：

1. **状态位语义搞错** → 死等 `AP_READY` / `AP_IDLE`，永远等不到。
2. **cache 没同步** → PL 读到旧数据，或 CPU 读到旧结果，且**不报错**。
3. **句柄没连到真 IP** → 寄存器读出全 0，看着像"IP 没起来"。

本技能给出正确时序、判据，以及**"时间到底花在哪"的拆账方法**。

---

## 二、什么时候用 / 什么时候别用

**用**：自己做的 HLS IP、`s_axilite` + `m_axi` 接口、要上板调用并计时。

**别用**：
- 用的是 PYNQ 官方库的 DMA/VDMA —— 那些有现成驱动（`pynq.lib.dma`），别自己写。
- IP 带 `s_axis`/`m_axis` 流接口 —— 那是 AXIS 流控问题，另一套判据（先看 tvalid/tready 握手）。

---

## 三、★ 三个状态位的真实语义（最容易搞错的地方）

| 位 | 语义 | 坑 |
|---|---|---|
| `AP_START` (bit0) | 写 1 启动一次 | 写完不会自动清零，别靠读它判断"是否在跑" |
| **`AP_DONE` (bit1)** | **电平**：跑完拉高，**一直保持到下一次 `AP_START`** | 直接"等它变 1"会**立刻通过**（上一轮的 1 还在）⇒ 读到上一轮结果 |
| **`AP_IDLE` (bit2)** | 空闲且未启动时为 1 | **跑完之前读不到 1**。如果在启动后忙等它，会陷入和 `AP_READY` 一样的死等 |
| **`AP_READY` (bit3)** | 只对带 `s_axis` 等"输入就绪"接口的核有意义 | ★ **纯 `m_axi` + `s_axilite` 的核，这一位永久为 0**。等它必然超时 |

### ✅ 正确的启动/等待时序（两段等待）

```python
ip.write(R_CTRL, 1)                       # 启动
while ip.read(R_CTRL) & 2:                # ① 等上一轮的 AP_DONE 落下去，证明这次启动被接受
    pass                                  #    ★ 少了这一段，就会立刻读到上一轮结果
while not (ip.read(R_CTRL) & 2):          # ② 再等这次跑完
    pass
buf_out.invalidate()                      # ③ 读结果前必须作废 cache
```

**每一段等待都必须带超时**（`deadline = time.perf_counter() + TIMEOUT`），否则 IP 出问题就是整个 Jupyter 内核卡死。

---

## 四、CMA 缓冲与 cache 一致性

PL 通过 **HP 口直接访问 DDR，绕过 CPU cache**。所以：

| 方向 | 必须做 | 漏了的现象 |
|---|---|---|
| CPU 写 → PL 读 | 写完后 `buf.flush()` | PL 读到**旧数据**，结果像是"IP 没工作" |
| PL 写 → CPU 读 | 读之前 `buf.invalidate()` | CPU 读到**旧数据**，结果像是"IP 没跑完" |

**两条配套纪律**：

1. 缓冲必须 `pynq.allocate()` 申请（**物理连续**）。普通 `np.zeros()` 不连续，PL 按物理地址读会读到别的内存。
2. **不报错**是这两类 bug 最恶的地方 —— 现象永远是"结果差一点点"或"结果不变"，不会抛异常。详见 `../pynq-dma-cache/SKILL.md`。

---

## 五、★ 句柄：裸 `MMIO` 可能根本没连上 IP

实测现象：`MMIO(0x43C30000, 0x1000).read(0x00)` 读出 **0x00000000**，而同一时刻 `overlay.<ip名>.read(0x00)` 读出 **0x00000004**（正常的 AP_IDLE）。

**做法**：优先复用已经加载过的 overlay 里的 IP 对象，别自己裸映射。

```python
ip = None
for ol in getattr(Overlay, "_instances", {}).values():   # PYNQ 记录所有已加载的 overlay
    if "cnn_top_0" in getattr(ol, "ip_dict", {}):        # 按 IP 实例名找
        ip = ol.cnn_top_0                                # 复用它的句柄
        break
if ip is None:
    ip = MMIO(BASE, RANGE)                               # 实在找不到才裸映射
```

★ **绝不要为了"拿到句柄"再调用一次 `Overlay()`** —— 那会**重新编程 PL**，fabric 里的寄存器全部复位，同一条位流上别的子系统（相机链路、VDMA、时钟）当场失效。挂上去，不要重新配置。

**推论**：既然寄存器随时可能被复位清掉，**每次调用前把基地址重写一遍**（成本 0.36 ms，见第七节），比"只在初始化时写一次"稳。

---

## 六、Workflow

| 步 | 做什么 | 判据 |
|---|---|---|
| 1 | 先用 IP 自带的**黄金向量**跑一次自检（不经预处理） | 输出与 PC 参考**逐字节相同** |
| 2 | 打印 `CTRL` 与所有基地址寄存器 | `AP_IDLE=1`、基地址非 0 |
| 3 | 单次调用 + 超时保护 | 不卡死、结果正确 |
| 4 | 连续 N 次调用 | 结果稳定；第 1~3 次可能偏慢（冷启） |
| 5 | **逐段计时并与总时间对账**（第七节） | 各段之和 ≈ 总时间，差 < 5% |
| 6 | 只有在账对上之后，才谈优化 | 账没对上就去优化 = 猜 |

---

## 七、★ 逐段计时：先量，再优化

把"一次调用"拆成**互不重叠的段**，每段单独计时，最后求和与总时间对账。本项目一次 CNN 调用的拆法：

| 段 | 本项目实测 | 说明 |
|---|---|---|
| 预处理（缩放/归一化） | 随 ROI 面积变（实测 84 ns/px） | ★ **唯一跟输入大小有关的一段** |
| 量化 float→int8 | **3.14 ms** | 与输入尺寸无关，纯固定开销 |
| 写输入 + `flush()` | 0.47 ms | |
| 写 6 个基地址（12 次 MMIO 写） | 0.36 ms | 约 30 µs/次 |
| **启动 → 等到 AP_DONE** | **23.65 ms** | 这是加速器本体 |
| `invalidate` + 解包 | 0.52 ms | |
| softmax | 0.33 ms | |
| **合计** | **≈35.6 ms** | 与实测总时间**逐步对上** |

**对账的价值**：
- 一眼看出"本体 23.65 ms"和"框架开销 12 ms"的比例 ⇒ 知道该优化哪边。
- 本体 23.65 ms 与"单独测的 22.96 ms"只差 3% ⇒ **证明加速器在真实 DDR 争用下没有被拖慢**，这是一条可以写进报告的正向结论。

**反例（必须记住）**：本项目连续三次用"纸面反推"估速度（估 31 ms、估 42 ms、估 29.5 ms），三次全错；实测一次就把账算清了。**没有逐段实测数字，不许谈优化。**

---

## 八、已验证效果

- 自检：黄金向量逐字节 PASS，一次调用 22.96 ms（中位；前 3 次冷启 29~36 ms）。
- 逐段账：7 段求和 35.6 ms，与生产代码里的实测均值 35.6 ms **完全一致**。
- 稳定性：2910 次连续调用无失败、无累积漂移。

---

## 八点五、★ 主机侧预处理查表化：把"浮点归一化 + 量化"压成每通道 256 项

**问题**：推理本体已经搬到 PL 了，反而主机侧的预处理成了大头（本工程实测 35.6 ms 里，**预处理 7 ms + 量化 3.14 ms = 10.2 ms**）。

**观察**：`像素 → /255 → (x−mean)/std → /scale → round → +zero_point` 这一整串**都是逐像素的一维映射**，而 8 位图像的取值**只有 256 种** ⇒ 整个链条可以预先算成一张 **256 项的表**，运行时只剩一次 gather。

```python
def build_quant_lut():                      # (3,256) uint8 表
    tab = np.empty((3, 256), dtype=np.uint8)
    v = np.arange(256, dtype=np.float32)     # 像素值 0~255
    for c in range(3):
        x = v / np.float32(255.0)                                        # ① /255
        x = (x - np.float32(MEAN[c])) / np.float32(STD[c])               # ② ImageNet 归一化
        x = x / np.float32(IN_SCALE)                                     # ③ 除以量化 scale
        x = np.trunc(x + np.sign(x) * np.float32(0.5))                   # ④ 远离零取整
        x = np.clip(x + IN_ZP, -128, 127).astype(np.int8)                # ⑤ 加零点夹到 int8
        tab[c] = x.view(np.uint8)                                        # 存位模式，转 int8 零开销
    return tab

# 运行时（flat = letterbox 后的 H×W×3 uint8 图）
lut   = build_quant_lut().reshape(-1)                 # (768,)，索引 = c*256+v
choff = (np.arange(flat.size, dtype=np.int32) % 3) * 256   # 每字节该查哪张表（预计算一次）
q     = lut[flat + choff].view(np.int8)               # 一次 gather
```

**必须守住的四条**：

1. **逐字节等价靠"运算顺序 + dtype 完全一致"**，不是靠公式等价。原来那条链是 float32 算术（`/255` → 减 mean → 除 std → 除 scale → 取整），建表时必须**照抄同样的顺序、同样的 float32**，否则边界值会差 1 LSB。
2. **取整是"远离零"而不是银行家舍入**：`np.trunc(x + np.sign(x)*0.5)`，**不能用 `np.round`**。
3. **`letterbox` / 缩放不要自己重写**，复用训练端一致的那一份（本工程直接调 `ti.letterbox`），只把后面的浮点段换掉。
4. **验证方法**：随机生成 200 张 uint8 图 + 全 0 / 全 255 两个边界，把老路径与新路径各算一遍，`np.count_nonzero(a!=b)` **必须恒为 0**。本工程实测 0 处不一致。

**收益**：10.2 ms → **~1.5 ms**（剩下的是 `cv2.cvtColor` + `cv2.resize`，那两步是真的几何运算，没法查表）。**不动位流、不改 HLS，纯主机侧**。

**顺带一条句柄坑**：`getattr(Overlay, "_instances", {})` 在 **PYNQ 3.0.1 上恒为空**（该属性不存在），而 `getattr` 的默认值会**静默**掩盖这件事，让代码悄悄退回裸 `MMIO` ⇒ `CTRL` 读出 0。正解是从当前命名空间取已加载的 overlay 对象（`globals().get("ol")` → `ol.cnn_top_0`），并在取不到时**打印警告**而不是静默兜底。

---

## 九、来源

从"给 CNN 加速器写 PYNQ 驱动"这段里总结，每一步都踩过：

- `RuntimeError: 等 AP_READY 超时, CTRL=0x00000004` → 发现纯 `m_axi` 核的 `ap_ready` 永久为 0。
- `RuntimeError: 等 AP_IDLE 超时, CTRL=0x00000000` → 裸 `MMIO` 句柄没连到真 IP（同一个地址用 overlay 的 IP 对象读出 0x04）。
- 启动后立刻读到上一轮结果 → `AP_DONE` 是电平，必须先等它落下去。
- 35.6 ms vs 估算的 29.5 ms 差 6.8 ms → 逐段计时才发现"量化"一项就占 3.14 ms。

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-10-26 | 首次成文：三个状态位语义、两段等待、cache 双向同步、overlay 句柄复用、逐段计时对账法 |
| 1.1.0 | 2026-10-28 | 新增第八点五节：**主机侧预处理查表化**（每通道 256 项 LUT，10.2 ms → ~1.5 ms，逐字节等价验证方法）、`Overlay._instances` 在 PYNQ 3.0.1 不存在导致静默退回裸 MMIO 的坑 |

## 相关文件（Integration）

- **上游**：`../hls-accelerator-on-pl/SKILL.md`（加速器本体怎么设计）
- **平行**：`../pynq-dma-cache/SKILL.md`（cache 一致性的通用原理）
- **平行**：`../pynq-pitfalls/SKILL.md`（忙等带超时、Jupyter 不重读改过的 .py）
- **平行**：`../verification-methods/SKILL.md`（"改了没反应 = 改错地方"的排查法）
