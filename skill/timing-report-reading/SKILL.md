---
name: timing-report-reading
description: >-
  正确读 Vivado 时序报告的方法：**WNS 是全局最小值，不等于你那个域的余量**；
  必须先按 Path Group 拆表；看一条路径要看「逻辑级数 / 走线占比 / Requirement 是否可信」三样。
  当你要**判断时序余量够不够、定位关键路径到底在谁身上、决定要不要插流水、
  或者看到"逻辑级数很少但延迟很大"的路径**时使用。
  本技能只管"怎么读、怎么判"，不管具体怎么改 RTL。
scope: 通用 —— 换任何 FPGA/HDL 工程都能用
compatibility: Vivado 2026.1 实测；更早版本报告结构可能略有差异
inputs: 一份 `*_timing_summary_routed.rpt`（或一个打开的 impl run）
outputs: 一份判断 —— 关键路径在谁身上、是什么性质、该不该动
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "能分辨真违例与虚约束，并定位到是逻辑级数还是布线延迟。"
origin: "时钟跨到 MMCM 输出后，静态约束频率与运行时频率不一致，一度把虚约束当成真违例反复优化。"
---

# 怎么正确读 Vivado 时序报告

> **归属**：`workflow/` 工作流 —— **换任何 FPGA/HDL 工程都能用**。
> 本文件的核心结论是拿一次**真实误判**换来的，不是教科书抄的。

---

## Purpose

**目的**：把"时序还够不够"从**看一个数字**变成**看清一条路径**。

**预期产出**：

| 产出 | 说明 |
|---|---|
| 一张按域拆开的余量表 | 而不是一个全局 WNS |
| 一条被定位到"源 → 终点"的最差路径 | 知道它是**谁的**路径 |
| 一个性质判断 | 逻辑问题 / 布局问题 / 假约束 —— 三者治法完全不同 |

**前置条件**：跑完 `place` + `route`（`*_timing_summary_routed.rpt` 才有意义）。

---

## When to Use

- 要判断"现在还剩多少余量"，尤其**准备再往里加逻辑之前**
- 看到全局 WNS 很紧，想知道**到底紧在谁身上**
- 要决定"要不要给某一级插流水"
- 看到 `Logic Levels` 很少但 `Data Path Delay` 很大
- 看到 `Requirement` 和你以为的时钟频率对不上

## When NOT to Use

- 只有综合报告（`*_utilization_synth.rpt`）—— **没有布线就没有真实时序**
- 想看"逻辑功能对不对" —— 那是仿真的事（见 `../testbench-guide/SKILL.md`）

---

## DO's

- **第一步永远是按 Path Group 拆表**，再看自己那个域那一行
- 看一条路径**至少看四样**：`Slack`、`Source`/`Destination`、`Logic Levels`、`Data Path Delay` 里 **logic 与 route 的占比**
- 顺手核对 **`Requirement`** 跟你以为的时钟周期是否一致
- 报告里 **`Path Group:` 出现在 `Source:` / `Destination:` 之后** —— 写解析脚本要按这个顺序
- 判断"这条路径属不属于我的模块"时，**看 `Source`/`Destination` 里的层次名**，不要靠猜

## DON'Ts

- ⚠️ **不要把"全局 WNS"当成"我的模块的余量"** —— WNS 是**所有域里的最小值**，可能落在任何一个时钟域、甚至落在别人的 IP 里
- ⚠️ **不要只看 `Slack` 数字就下结论** —— 同样的 slack，成因可能完全不同
- **不要用错误的字段顺序解析报告** —— 解析错了照样能得出"看起来很有道理"的结论，但那是错的
- **不要一看到 slack 紧就插流水** —— 先确认那条路径**经不经过你要切的地方**

---

## Workflow

### Step 1：先看「时钟摘要表」，按域拆开

报告前面的 Clock Summary 会列出**每个时钟的标称周期与频率**。
先把这张表看一遍，确认**每个域的约束周期是不是你预期的那个**。

> 本项目就在这里发现过一个歧义：`axi_dynclk_0_PXL_CLK_O` 被标成 **100 MHz（10 ns）**，
> 而板端脚本用 DRP 把它重配成 **74.2857 MHz（13.46 ns）**。

### Step 2：看 Intra Clock Table，找**自己域**的那一行

表里每个时钟一行，给出该域**内部**的 WNS / TNS / 端点总数。

```
Clock                        WNS(ns)  ...  TNS Total Endpoints
cam_pclk                       3.821   ...        428
clk_fpga_0                     1.479   ...     42,542      ← 自研算法在这个域
axi_dynclk_0_PXL_CLK_O         0.500   ...      5,253      ← 全局最差，但在别人 IP 里
```

**⇒ 全局 WNS 取的是这一列的最小值。它落在哪个域，决定了"这是谁的问题"。**

### Step 3：定位自己域的最差路径

在 Max Delay Paths 段落里，找 `Path Group: <你的域>` 的那些条目，读出：

```
Slack (MET) :  1.479ns
  Source:      design_1_i/<你的模块>/.../某寄存器/C
  Destination: design_1_i/<另一个 IP>/.../D
  Path Group:  clk_fpga_0
  Requirement: 10.000ns
  Data Path Delay: 8.000ns (logic 1.592ns (19.9%)  route 6.408ns (80.1%))
  Logic Levels: 5 (CARRY4=1 LUT3=1 LUT4=1 LUT6=2)
```

### Step 4：看三样，判性质

| 看什么 | 怎么读 | 说明什么 |
|---|---|---|
| **`Source` / `Destination`** | 里面的层次名 | 这条路径**是谁的**。两边都在你的模块里 = 你的问题 |
| **`Logic Levels` + logic/route 占比** | 见下表 | **逻辑问题** 还是 **布局问题** |
| **`Requirement`** | 和时钟摘要表里的周期对一遍 | 对不上 ⇒ **假约束**，真实余量不是这个数 |

### Step 5：按判据定性（本技能的核心判据表）

| 特征 | 性质 | 治法 |
|---|---|---|
| `Logic Levels` **多**（≥6），logic 占比高 | **逻辑深度问题**（组合链太长） | 在链的**正中间**插流水寄存器 |
| `Logic Levels` **少**（1~2），**route 占比 ≥80%** | **布局问题**（元件摆得太远） | 缩短物理距离：Pblock / 把跨模块的长线在本地锁存一份 / 减少跨界 |
| `Requirement` 与实际时钟周期不符 | **假约束** | 修约束（`create_clock` 覆盖 / `set_clock_groups`），**别改 RTL** |
| 两边分属**不同模块 / 不同 IP**，且 route 占比高 | **跨边界 + 布局**问题 | 把信号在**离终点近的那一侧**先寄存 |

### Step 6：再决定治不治

**先问三个问题**：
1. 时序现在**满足**吗？（`All user specified timing constraints are met`）
2. **你要加的新逻辑会不会让这条路径变长？**（比如新逻辑是否插在它的路径上）
3. 治它的**代价** vs 收益？

> **本项目实例**：那条 1.479 ns 的路径是"配置寄存器 → 比较器 → 显示 MUX → 另一个 IP"，
> **加像素处理级根本不会碰它** ⇒ 结论是"不急，先不动"。

---

## ★ 一个必须记住的解析坑

用脚本解析 `*_timing_summary_routed.rpt` 时，**字段顺序是**：

```
Slack (MET) :  1.479ns  (required time - arrival time)
  Source:       ...
  Destination:  ...
  Path Group:   ...          ← ★ 在 Source/Destination 之后，不是之前！
  Path Type:    ...
  Requirement:  ...
  Data Path Delay: ...
  Logic Levels: ...
```

**按"Path Group 在前"去扫，会取不到 Source/Destination、把分组算错 —— 然后得出一个看起来很有道理的错结论。**

---

## 已验证效果

**本项目 2026-10-04 实测**（Zynq-7020 / 100 MHz 主域）：

| 域 | WNS |
|---|---|
| `cam_pclk`（72M，采集） | 3.821 |
| **`clk_fpga_0`（100M，自研算法）** | **1.479** |
| `axi_dynclk_0_PXL_CLK_O`（标称 100M，实际跑 74.25M） | **0.500** ← 全局最小，**但它是假约束，真实 ≈ 4.2 ns** |

**同一个数据，读法不同，结论完全相反**：

| 读法 | 结论 |
|---|---|
| 只看全局 WNS | "关键路径不在自研算法里" ❌ |
| 按 Path Group 拆开看 | "**本域的最差路径就是自研链**，而且它是**布局问题**不是逻辑问题" ✅ |

---

## 来源（从哪些失败或观察中总结得出）

**触发**：AI 看到全局 WNS 0.500 出自 Xilinx 的 `v_tc_0`，就断言"**关键路径根本不在自研算法里**"。
复核时被追问 —— "**难道本项目的灰度算法没有在关键路径上吗**" —— 逼着回去重看。

**两个错叠在一起**：
1. **概念错**：把"全局 WNS（所有域的最小值）"当成了"本域的余量"；
2. **解析错**：写脚本时以为 `Path Group:` 在 `Source:` **之前**，结果 Source/Destination 全取空、分组全错 ——
   **而错误的解析照样产出了一个看起来很合理的结论**，这才是最危险的。

**⇒ 最有用的一条结论**：**先按域拆，再看路径，最后才看数字。**

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-10-04 | 首版：按域拆表 → 定位路径 → 三样判性质 → 三条判据表 |

---

## 相关文件（Integration）

- **怎么修时序**：`../hdl-module-split/SKILL.md`（打拍纪律、辅助逻辑别串主链）
- **怎么跑出报告**：`../vivado-bd-ops/SKILL.md`（构建与 OOC 陷阱）
- **官方对应技能**：AMD Ross 的 `vivado-timing-methodology-checks`（55+ 条 UG906 检查的逐条处置）
- **验证方法论**：`../verification-methods/SKILL.md`（"假约束识别"那一节）
