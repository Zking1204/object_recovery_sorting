---
name: memory-structure-timing
description: >-
  写含片内存储器（行缓冲 / 延迟线 / 阵列）的 RTL 时的**两条结构纪律**：
  ① **端口数**决定综合器能不能把数组推成 BRAM（多一个读口就退化成 LUTRAM，白吃几百个 LUT）；
  ② **存储器件的输出必须先过一级寄存器**再进组合算法（BRAM 的 CLK→Q 本身就要 2ns 上下）。
  当你要写行缓冲、要给一个阵列接多个读口、或者**时序报告里最差路径的起点是 RAMB 的 CLKARDCLK→DOADO** 时用它。
  本技能只管「存储器的结构与时序」，不管模块怎么分（那是 hdl-module-split）、也不管报告怎么读（那是 reading-timing-reports）。
scope: 通用（HDL / FPGA）
compatibility: 7 系列 / UltraScale 的 BRAM 与 LUTRAM 推断；Vivado 2026.1 实测
inputs: 一段含片内阵列的 RTL + 一次综合/布线的资源与时序报告
outputs: 能推出 BRAM 的写法 + 报告里可核对的 LUT/BRAM 数字
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "存储结构选型有判据：RAM_2P 还是 BRAM 绑定、分区因子取多少、会不会引入跨周期依赖。"
origin: "权重放不进 BRAM 时先怀疑容量不足，实际是访问模式与分区因子不匹配。"
---

# 存储器件的结构纪律：端口数决定 BRAM，输出必须先打拍

> **归属**：`workflow/` 跨项目通用。与 `../hdl-module-split/SKILL.md`（模块怎么分、拍子怎么对）、
> `../timing-report-reading/SKILL.md`（报告怎么读）配套使用。

---

## Purpose

**目的**：在写"要存一整行/一整帧"的 RTL 时，**一次就写对**——
让综合器**推得出 BRAM**，并且**不让存储器件的慢输出拖垮时序**。

这两件事都不是"写完再说"的优化，而是**写下去那一刻就定了**的结构问题：

- 端口数不对 ⇒ 综合器直接放弃 BRAM，你白吃掉几百个 LUT，而且**它只给一条 WARNING**
- 输出没打拍 ⇒ 时序报告里多一条 9.7ns 的路径，而**你以为是算法太深**

**前置条件**：知道这一级存储器要几个读口、几个写口。

---

## When to Use

- 要写**行缓冲 / 列缓冲 / 延迟线 / 小型阵列**
- 要给同一个数组**接两个以上的读口**（3×3 窗口要同时读三行就是这种情况）
- 综合后资源里 **`LUT as Distributed RAM` 突然多出几百**，或者日志里出现 `Synth 8-6849`
- 布线后**最差路径的 Source 是 `xxx_reg/CLKARDCLK`**（即从 BRAM 的时钟脚出发）

## When NOT to Use

- 存储器很小（几十位以内）—— 那用寄存器比 BRAM 更划算，别硬推
- 器件没有 BRAM 余量、但 LUT 富余 —— 那 LUTRAM 反而是正解，**故意**用 `ram_style="distributed"`
- 纯组合逻辑设计，没有片内阵列

---

## DO's

- **先数端口**：`写口数 + 读口数 ≤ 2` 才可能推成一块 BRAM。超了就要改结构，而不是加 `ram_style`
- 需要"同时读多行"时，**让每个数组各接一个属于自己的读口**，几个数组同时读同一地址，
  读完**再在寄存器输出上做多选一**
- **选择信号跟着数据一起打一拍**：数据是第 E 拍读出来的，选它的索引也必须是第 E 拍的值
  （行尾计数器会 +1，直接用"当前"索引会选错数组）
- **存储器的输出先过一级寄存器**，再进任何组合算法
- 数组本体**不加复位**（BRAM 没有复位端，写了会退化成几万个 FF）；要清的只是控制计数器
- 综合后**核对两个数字**：`Block RAM Tile` 有没有涨、`LUT as Distributed RAM` 有没有异常

## DON'Ts

- ⚠️ **不要用 `case` 在读口之间挑数组** —— 这会让**每个数组都可能被任一读口选中**
  ⇒ 综合器认为每个数组需要 **2 读 + 1 写 = 3 端口** ⇒ 直接放弃 BRAM
- ⚠️ **不要指望 `ram_style="block"` 能救** —— 端口数不合法时它只会给一条 WARNING 然后照样用 LUTRAM
- ⚠️ **不要把"存储器输出 → 一串比较器/加法器"写成一段组合逻辑**
- ⚠️ **不要拿"逻辑级数不多"安慰自己** —— 存储器的 CLK→Q 是固定的 2ns 上下，它不属于"逻辑级数"

---

## Workflow

### Step 1 — 数端口，决定结构

把这一级要的访问列出来：

| 访问 | 例（3×3 行缓冲） |
|---|---|
| 写 | 1 个（写当前行） |
| 读 | **2 个**（同时读上一行、上上行） |
| 合计 | 3 个 ⇒ **一块 BRAM（2 端口）装不下** |

⇒ 结论：**不能用"一个数组 + 两个读口"**，必须拆成多个数组，让每个数组只承担 1 读 + 1 写。

### Step 2 — 按"每数组 1 读 1 写"重写访问

```verilog
// ❌ 错：两个 case 各自去挑数组 ⇒ 每个数组都可能被任一读口选中 ⇒ 3 端口 ⇒ LUTRAM
case (rd_sel_a) 2'd0: row_a_d <= lb0[addr]; ... endcase
case (rd_sel_b) 2'd0: row_b_d <= lb0[addr]; ... endcase

// ✅ 对：每个数组各接一个属于自己的读口，读完再选
always @(posedge clk) if (en) begin
    rd0 <= lb0[addr];      // 各用各的读口
    rd1 <= lb1[addr];
    rd2 <= lb2[addr];
    rd3 <= lb3[addr];
    sel_a_d <= sel_a;      // ★ 选择信号跟数据一起打一拍
    sel_b_d <= sel_b;
end
wire [7:0] row_a_d = (sel_a_d == 2'd0) ? rd0 : (sel_a_d == 2'd1) ? rd1 : (sel_a_d == 2'd2) ? rd2 : rd3;
wire [7:0] row_b_d = (sel_b_d == 2'd0) ? rd0 : (sel_b_d == 2'd1) ? rd1 : (sel_b_d == 2'd2) ? rd2 : rd3;
```

**产出**：每个数组都是标准的 1 写口 + 1 读口。
**判据**：综合日志里**没有** `Synth 8-6849`；报告的 `LUT as Distributed RAM` 回到 0。

### Step 3 — 在存储器输出后加一级寄存器

```verilog
// 存储器的输出（rdN / 多选结果）先过一级寄存器，再进组合算法
always @(posedge clk) begin
    if (valid) begin
        o_pix <= 组合算法(...);   // 这一级的输入必须全部来自寄存器
    end
end
```

**判据**：布线后最差路径的 Source **不再是** `.../CLKARDCLK`。

### Step 4 — 核对数字

| 查什么 | 在哪查 | 期望 |
|---|---|---|
| BRAM 有没有涨 | `report_utilization` 的 `Block RAM Tile` | 涨了 = 推成功了 |
| LUTRAM 有没有回落 | 同上的 `LUT as Distributed RAM` | 回到 0（或只剩别的模块的） |
| 有没有被拒 | 综合 `runme.log` 搜 `8-6849` | 搜不到 |
| 路径起点变了没 | `report_timing_summary` 的路径明细 | Source 不再是 RAMB 的时钟脚 |

---

## 已验证效果（本项目实测数字）

| 项 | 改之前 | 改之后 |
|---|---|---|
| 4 个 1024×8 数组的落地方式 | **LUTRAM**（`LUT as Distributed RAM = 512`） | **4 × RAMB18**（`LUT as Distributed RAM = 0`） |
| 该模块（OOC）LUT | **1063** | **485** |
| 最差路径 | `RAMB18 CLK→DOADO 2.454ns + 4选1 1.203ns + 三个串联比较器 ≈5.0ns` = **9.712ns / Slack 0.103ns**，走线占 **66%** | 拆成 `存储器→4选1→寄存器`(≈3.8ns) 与 `寄存器→3 个比较器` 两段，Slack **0.461ns** |
| 代价 | — | 多 32 个 FF（4 个读数据寄存器）+ 76 个 FF（输出寄存器），延迟 +1 拍 |

**整片资源（同一工程两次构建对比）**：LUT 11,751 → **11,196**；BRAM 12 → **14 tile**；DSP 0 不变。

---

## 来源（从哪些失败或观察中总结得出）

1. **LUTRAM 那次**：行缓冲写完、仿真全过、资源报告一出来发现 `LUT as Memory` 多了 **512**，
   综合日志里躺着一条没人注意的
   `WARNING: [Synth 8-6849] Infeasible attribute ram_style = "block" set for RAM ".../lb0_reg", trying to implement using LUTRAM`。
   ⇒ 反查才想明白：**是端口数不够，不是属性没写**。
2. **时序那次**：加了输出寄存器之前，`clk_fpga_0` 域的 WNS 从 1.479ns 掉到 **0.103ns**。
   一开始怀疑"中值网络太深"，**读路径明细才发现**：
   `Requirement 10ns / Data Path 9.712ns / **route 占 66.7%**`，
   起点是 `u_win/lb3_reg/CLKARDCLK` —— 是**存储器件的固定延迟**加上布局散乱，不是逻辑级数问题。
   加一级寄存器后路径被切成两段，两段都宽裕。

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-10-04 | 首版：端口数决定 BRAM + 存储器输出必须打拍 + 索引跟数据同拍 |

---

## 相关文件（Integration）

- **模块怎么分、拍子怎么对**：`../hdl-module-split/SKILL.md`
- **报告怎么读、怎么判断是布局问题还是逻辑问题**：`../timing-report-reading/SKILL.md`
- **综合资源数字怎么自动采集**：`../util-timing-collect/SKILL.md`
- **本项目的真实案例**：`设计报告 §2.4`
