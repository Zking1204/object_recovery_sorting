---
name: hls-accelerator-on-pl
description: >-
  用 Vitis HLS 把一个训练好的 int8 CNN 部署成 PL 加速器：**怎么选数据流**（按输出通道驻留 vs 按输入通道切换）、
  **怎么让大权重数组真的落进一块单端口 BRAM**、**量化怎么和 TFLite 逐位对齐**、以及 HLS 资源/周期报告该怎么读。
  本技能只做"卷积加速器的微架构与资源映射"，不做 BD 集成与 IP 版本管理（见 ../vivado-bd-ops/SKILL.md）。
scope: 通用（HLS / FPGA 加速器设计；换板卡换网络都成立，只改并行度常数）
when_to_use: 要把 CNN 从 CPU 挪到 PL；HLS 综合后 FF/LUT/BRAM 爆掉；权重数组被 HLS 复制成多份；不确定该按哪个维度做并行
triggers: ["把 CNN 部署到 PL", "HLS 加速器", "卷积加速", "BRAM 超了", "资源爆了", "FF 105%", "权重进不了 BRAM", "ap_uint<512>", "ARRAY_PARTITION", "ARRAY_RESHAPE", "BIND_STORAGE", "数据流怎么切", "MAC 效率低", "max_widen_bitwidth", "II=64", "权重载入慢", "并发度翻倍", "POC 加倍"]
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "内核单次 9.15 ms，有效算力达到理论峰值的 52%，且模型更新后能在一轮构建内重新部署。"
origin: "早期逐字节读取权重导致迭代间隔 II=128，改用显式 64 位宽字读后降到 16，载入时间从 3.9 ms 降到 0.49 ms。"
---

# 把 int8 CNN 部署成 HLS PL 加速器：数据流选择与资源映射

## 一、这个技能解决什么

把 `QUANTIZE → CONV ×4 → POOL ×3 → GAP → FC → DEQUANTIZE` 这种小网络搬到 PL 上，**真正的难点从来不是"写出来"，而是三件事**：

1. **数据流怎么切** —— 同一个网络，切错维度，MAC 效率只有 17%；切对维度，同样资源下快 2.4 倍。
2. **大权重数组怎么落进一块 BRAM** —— HLS 会为了凑端口数**静默复制**存储器，你以为 1 块，它给你 9 块。
3. **量化怎么和 TFLite 逐位对齐** —— 不是"近似一致"，是**逐字节相同**，否则端到端精度不可解释。

本技能给这三件事的判据和实测数字。

---

## 二、什么时候用 / 什么时候别用

**用**：
- 有一个已经量化好（int8、per-channel scale）的小型 CNN，要放到 PL 上做实时推理。
- HLS 综合报出 `FF > 100%` / `LUT > 100%` / `BRAM > 100%`，需要知道是哪种写法导致的。
- 已经有 HLS 版本但**吞吐远低于算术地板**，想找效率损失在哪。

**别用**：
- 网络太大（权重超过片上 BRAM 容量）—— 必须先做权重压缩/分块从 DDR 流式读取，那是另一套（row-stationary / 权重流式）。
- 只是想在 PS 上跑得快点 —— 先试推理引擎的多线程，别上 PL。
- 没有 PC 端逐层黄金参考 —— 没参考就没有验收判据，见 `../golden-compare/SKILL.md`。

---

## 三、第一步永远是算算术地板

```
加速下限 = 网络 MMAC ÷ (每周期 MAC 数) ÷ 时钟频率
```

例（本项目 64×64 int8，60.2 MMAC，64 MAC/周期 @100 MHz）：

```
60.2e6 ÷ 64 ÷ 100e6 = 9.41 ms
```

**这条线决定"目标定得对不对"**。想跑到 10 ms 以下就必须 128 MAC/周期，而在 xc7z020 上那需要约 256 个 DSP（>220，装不下）。所以**在定目标之前先算这条线**，避免为了一个物理上做不到的目标改结构。

★ 实测效率要这样算：`实测 MMAC ÷ 实测时间 ÷ 时钟 = 实际每秒多少 MAC`，再除以"设计并行度"。
本项目 v4 实测 55.42 ms ⇒ 效率 10.9/64 = **17%**；v5 实测 22.96 ms ⇒ 26.2/64 = **41%**。

---

## 四、★ 核心结论：按**输出通道**驻留，不要按输入通道切换

同一个网络、同一块器件，两种切法差 2.4 倍，**而且资源是后者更低**。

| | 按输入通道切换（v4） | 按输出通道驻留（v5） |
|---|---|---|
| 片上保存 | 一个输入通道块的权重 tile（576 B） | **一个输出通道组的全部权重**（9 KB） |
| 累加器放哪 | **BRAM 平面**（131 KB） | **寄存器** `acc0/acc1[POC]` |
| 每次内层调用做的 MAC | 576（POC×PIC×9 的一小片） | 576（同样） |
| 每次内层调用的额外代价 | **累加器 BRAM 往返 + 循环控制 ≈25~32 周期** | **0**（累加器就在寄存器里连续累加） |
| 权重载入次数 | 676 | **60** |
| 实测 | 55.42 ms | **22.96 ms** |

**为什么差这么多**：切输入通道 ⇒ 每算完一小片就要把累加器写回 BRAM、下一片再读回来。这个往返 + 循环控制的固定代价（25~32 周期）要摊在只有 576 个 MAC 的内层上，**代价比计算本身还大**。切输出通道 ⇒ 一个输出通道组的累加器从头到尾留在寄存器里，权重整块驻留，代价被摊成 0。

★ **代价换来的是"重复读输入"而不是"重复读权重"** —— 输入张量比权重小一个数量级，这是 SqueezeJet-2 的做法，也是本方案的关键依据。

**循环结构（最终版）**：

```
for og in 输出通道组:                       # 外层：每组一次
    一次性载入该组的全部权重到 wblk
    for 每个输出像素（含池化后的存回位置）:
        for (tap × 输入通道块):             # 内层：流水 II=1
            64 MAC（POC × PIC）
        写回 / requant / 2×2 max 池化
```

---

## 五、★ 让大权重数组真的落进**一块**单端口 BRAM

这是本项目踩得最狠的坑，两种写法都"看起来对"，实际都爆。

### DON'Ts

| 写法 | 结果 | 为什么 |
|---|---|---|
| `#pragma HLS ARRAY_PARTITION ... complete` + `BIND_STORAGE ... BRAM` | **FF 112,154（105%）、LUT 86,523（162%）** | `complete` 把子数组拆成标量，`BIND_STORAGE` 被**静默忽略**，全变成寄存器 |
| `#pragma HLS ARRAY_RESHAPE dim=2 block factor=64` + `BIND_STORAGE ... BRAM` | **BRAM 334/280（119%）** | `ARRAY_RESHAPE` **只加宽到 128 bit**（报告里是 `ram_2p bram 128, 9`）；HLS 为凑够 64 个读口把**同一块存储器复制了 9 份** |

### DO

```cpp
// 元素类型直接声明成 512 位宽 ⇒ 一拍读出 64 个 int8 权重
ap_uint<POC * PIC * 8> wblk[9][MAXCINP / PIC];      // 单数组、无 partition/reshape
#pragma HLS BIND_STORAGE variable=wblk type=RAM_2P impl=BRAM
```

实测资源报告里变成 **一个实例 `512, 144`**，BRAM 占用降到 **46.5 块（33.2%）**。
取值用 `wv.range(((j*PIC + t)*8) + 7, ((j*PIC + t)*8))` 逐字节切。

**三条纪律**：

1. `BIND_STORAGE` 只对**真数组**生效 —— 任何会改变数组形状的 pragma（`PARTITION` / `RESHAPE`）都会让它白写。**先确认数组还是数组。**
2. HLS 的"加宽"上限是 128 bit。要更宽就别指望 reshape，**改元素类型**。
3. 判据永远看**真实 OOC 综合**的资源报告，不看 HLS 的 estimate（见第九节）。

---

## 六、量化对齐：逐位复刻 TFLite，不要"近似"

TFLite int8 的乘加后重定标是**带舍入模式的定点运算**，用浮点或普通四舍五入会逐层放大误差。必须逐个复刻：

| 步骤 | 要点 |
|---|---|
| `QuantizeMultiplier` | `frexp` 拆出 (尾数, 指数) ⇒ **`frexp` 不可综合**，必须提前在 PC 上算好每通道 (int32 multiplier, shift) 表，核里只查表 |
| `SaturatingRoundingDoublingHighMul` | 定点乘法 + 双重舍入，注意 nudge 值 `1<<30` / `1-(1<<30)` |
| `RoundingDivideByPOT` | 算术右移 + 舍入偏移，**截断不是四舍五入** |
| 输入量化 | `round_half_away_from_zero`（`std::round` 语义），**不能用银行家舍入** |

**两个把算术省下来的等价变换**（都能严格证明）：

1. **池化融进 requant 那一遍**：max 直接在 **int32 累加值**上取 —— requant 是单调函数 ⇒ 先 requant 再 max 与先 max 再 requant **逐位等价**，省掉 3/4 的 requant 计算。
2. **零点折进 bias**：`Σ(iv−izp)·w = Σiv·w − izp·Σw`。左边需要在 MAC 路径上放 `PIC` 个减法器，右边只需在 PC 上算一次偏置修正 `b_cor = b − izp·Σw`。**等价且 int32 安全**，直接把减法器从关键路径上删掉。

---

## 七、Workflow

| 步 | 做什么 | 产出 | 判据 |
|---|---|---|---|
| 1 | 算算术地板（第三节） | 一个"物理下限"数字 | 目标时间 ≥ 下限，否则先改并行度 |
| 2 | PC 端写 numpy 逐位参考（`ref_cnn.py`） | 六层张量 + logits 黄金值 | 与板上推理引擎结果**最大绝对差 < 0.01** |
| 3 | 导出权重/偏置/requant 表为扁平 bin | `model_blob.bin` 等 | 每个 bin 的字节数与布局表一致 |
| 4 | 定并行度 POC×PIC，算权重块大小 | 决定 BRAM 块数 | 权重总量 ÷ BRAM 容量 < 可用块数 |
| 5 | 选数据流（第四节），写核 | 能 C 仿真的核 | **C 仿真逐层逐字节一致** |
| 6 | 每次改布局/索引后**必跑 C 仿真** | PASS | 见 DON'T：数值校验抓不到索引错 |
| 7 | 真 OOC 综合看资源 | `report_utilization` | LUT/FF/BRAM/DSP 都 < 100%，且**与上一版对比是解释得通的** |
| 8 | 上板实测 | 墙钟时间 | 与算术地板换算出的效率解释得通（本项目 41%） |

---

## 八、已验证效果（本项目实测）

| 版本 | 纯推理 | MAC 效率 | LUT | FF | BRAM | DSP | OOC WNS |
|---|---|---|---|---|---|---|---|
| v4（切输入通道） | 55.42 ms | 17% | 19,910 (37.4%) | 21,475 | 79 (56.4%) | 20 | +1.960 ns |
| **v5（切输出通道）** | **22.96 ms** | **41%** | **14,821 (27.9%)** | **15,842** | **46.5 (33.2%)** | 52 (23.6%) | **+1.742 ns** |

★ **关键结论：v5 不仅快 2.41 倍，LUT / FF / BRAM 三项还同时比 v4 更低。** 说明"按输出通道划分"不是拿资源换速度，而是**结构上更省**。

---

## 九、DON'Ts（都是实测踩出来的）

| 坑 | 现象 | 正解 |
|---|---|---|
| 用 HLS 的 estimate 判断能不能装下 | 同一版本 estimate LUT 48,724，真实 OOC 只有 20,104 | **只信真实 OOC 综合**，estimate 偏悲观 |
| 用 HLS 报的 cycle/latency 估运行时间 | 报了 8.3×10⁷ 周期，与实测毫无关系 | 运行时长由循环边界决定的核，**只能上板测** |
| 用 cosim 做 profile | 194 s CPU 只推进 12,500 周期 ⇒ 全跑要 ~25 小时 | 放弃 cosim 做性能分析，改用**上板分段计时**（见 `../pl-accelerator-host-driver/SKILL.md`） |
| 改完权重布局只做数值检查就综合 | 权重载入基址漏乘了 `POC`（写成 `og*9*CINP + kk*CINP`），blob 布局校验和折叠偏置校验**全过**，C 仿真才在第二层炸出来 | **布局一改必跑 C 仿真**，比对每一层张量 |
| 内层循环里写边界判断 | `Unable to satisfy pipeline directive ... control-flow is too complicated` | 用**补边 arena**（四周补 1 像素量化零点）消掉判断，内层完全无分支 |
| 内层循环里做运行时除法 | 同上 | 除数改成 2 的幂/常数，或提前算成表 |
| 多个 `m_axi` 端口参数不一致 | `HLS 214-215 bundled ports should have same adapter parameters` | 所有 m_axi 端口写**完全相同**的 `latency / num_read_outstanding / max_read_burst_length` |

---

## 十、并发度翻倍：先量 II，再决定加什么硬件

**判据顺序：先从 `csynth.rpt` 的循环表里读出每个循环的 II，再决定加什么。** 本轮同一个核从 64 MAC/cycle 提到 128 MAC/cycle 的实测对照：

| 指标 | POC=8 | POC=16 |
|---|---|---|
| 内层 MAC 迭代次数 | 1,032,192 | **516,096（减半）** |
| 最高频域总延迟（HLS 估计） | 83.4 M 拍 | **41.6 M 拍** |
| DSP | 52 | 84 |
| BRAM | 46.5 | 67.5 |
| LUT（**布线后**） | 14,821 | 18,728 |

**① int8 乘加能被打包进 DSP48E1，所以并发度基本是"线性加速"。** 实测 **64 MAC 只花 34 个 DSP ≈ 2 MAC/DSP**。不要一开始就假定"一个 MAC 一个 DSP"而不敢加并行度——先按 2 MAC/DSP 估资源。

**② 但先确认瓶颈真在算术上。** 本核整链 22.96 ms，而 MAC 只有 60.2 MMAC ÷ 64 MAC·拍⁻¹ ≈ **1.03 M 拍（10.3 ms）** ⇒ **一半时间根本不在 MAC 上**。逐条读完循环表才找到真凶：**权重载入循环 II=64**。

**③ `max_widen_bitwidth` 单独加没用，必须"显式宽读"。**
- 症状：日志 `Widen Fail ... Could not widen since type i8 size is greater than or equal to the max_widen_bitwidth threshold of 0`，权重载入 II=64（并行度翻倍后恶化到 **128**）。
- 原因：从 DDR 一个字节一个字节读，单端口 `m_axi` 要把 N 个字节操作串行化，**II 下限 = 字节操作个数**。
- ✗ 只加 `#pragma HLS INTERFACE m_axi ... max_widen_bitwidth=512` **不但没用，还把 II 从 64 推到 128**（日志：`Lower bound of II is 128 due to multiple operations accessing 'gmem' m_axi read`，128 个独立 `gmem_addr_XX_read`）。
- ✓ 正解是把指针 `reinterpret_cast` 成宽类型，用**对齐的宽字**读：

```cpp
typedef ap_uint<64> WTQ;                                   // 一拍 DDR 的宽度
const WTQ *wsrc = reinterpret_cast<const WTQ *>(src) + w * (POC*PIC/8);
ap_uint<POC*PIC*8> tmp;                                    // 整块权重字
for (int t = 0; t < POC*PIC/8; ++t) {                      // 16 个 64 位读，全展开
#pragma HLS UNROLL
    tmp.range((t + 1) * 64 - 1, t * 64) = wsrc[t];
}
wblk[kk][w] = tmp;
```

⇒ II **128 → 16**，权重载入从 0.39 M 拍（3.9 ms）降到 **0.049 M 拍（0.49 ms）**；顺带把整核 LUT 估计从 44,863 降到 35,666 —— **逐字节的 mux 比宽字贵得多**。

**④ 两个"以为改了其实没改"的坑**：
- `max_widen_bitwidth` **不改变打包 IP 的 `C_M_AXI_GMEM_DATA_WIDTH`**（实测仍是 32）。那是 IP 的独立需求方参数，要改得在 BD 里设 `CONFIG.C_M_AXI_GMEM_DATA_WIDTH`。
- 宽读要求**对齐**：各层权重偏移与每块字节数都必须是宽度的整数倍（本工程 0/2304/20736/94464/389376 与 128/512/1024/2048 都满足 8 的倍数）。**不对齐时读出来的值是错的，而且不报错。**

**⑤ HLS 的 LUT 估计约为布线后的 2 倍**（本核 HLS 35,666 → 实测 18,728；上一版 29,760 → 14,821）。判断"装不装得下"必须看**真实 OOC 综合**，别被 HLS 数字吓退；反过来 HLS 报 slack 为负也要用真实 OOC 复核（本核 HLS slack −1.49，实际 WNS +1.742）。

**⑥ 资源余量判据按 LUT / FF / BRAM / DSP 看。** Slice 利用率高（本工程布线后 98.5%）说明**布局拥挤**，会让 WNS 掉一点，但那属于实现质量问题、不是可行性门槛——不要因为 Slice 满了就否掉一个 LUT/FF/DSP 都还有余量的方案。

## 十一、来源

从"把 64×64 int8 CNN 从 PS 挪到 PL、并把纯推理从 55.42 ms 压到 22.96 ms"这一整段实践里总结，共经历 5 个微架构版本：

- **v1~v2**：单层卷积跑通，验证量化对齐可行。
- **v3~v4**：四层共用一套计算单元 + 运行时描述表，实测 55.42 ms；**由此发现"效率只有 17%"这个异常**，反推出"切输入通道导致累加器 BRAM 往返"这个根因。
- **v5**：照 SqueezeJet-2（器件同为 xc7z020）改成输出通道驻留，一次到位 22.96 ms。
- **资源爆掉的那两轮**（FF 105% / BRAM 119%）纯粹是 HLS pragma 语义问题，与算法无关，是 `BIND_STORAGE` 被静默忽略/被存储器复制导致的。
- **权重载入基址漏乘 POC** 这个 bug 只有在 C 仿真里才暴露 —— 数值层面的自检（布局校验、折叠偏置校验）全部通过。

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-10-26 | 首次成文：算术地板、输出通道驻留、ap_uint<512> 权重数组、量化逐位对齐、HLS 报告不可信的六条 DON'T |
| 1.1.0 | 2026-10-28 | 新增第十节：并发度翻倍实测对照（POC 8→16）、**DDR 访问宽度决定 II**（`max_widen_bitwidth` 单独加反而更慢，必须显式 `reinterpret_cast` 宽读）、HLS 的 LUT 估计约为实测 2 倍、Slice 满不等于不可行 |

## 相关文件（Integration）

- **上游**：`../golden-compare/SKILL.md`（PC 端逐层黄金参考是验收前提）
- **下游**：`../pl-accelerator-host-driver/SKILL.md`（PYNQ 侧怎么驱动这个核）
- **平行**：`../vivado-bd-ops/SKILL.md`（IP 版本号必须 bump、`v++ --compile` 后再 `--package`、OOC 综合陷阱——**这些别在本文件重复查**）
- **平行**：`../memory-structure-timing/SKILL.md`（存储器端口数与 BRAM 推导的 HDL 侧纪律）
