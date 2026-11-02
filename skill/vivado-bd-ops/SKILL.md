---
name: vivado-bd-ops
description: >-
  Vivado 工程操作与回滚的踩坑清单：module_ref 端口表被缓存、扩/缩 AXI 互联必须"三件事一起做"、
  回滚必须覆盖 IP 的 .xci、"构建成功但位流里还是旧逻辑"的 OOC 陷阱、
  以及"删了源文件、工程里还留着悬空引用 ⇒ 工程打不开"。
  当你要**改 Block Design、挂自研 Verilog 进 BD、扩/缩 AXI 互联、从备份还原工程、
  改完 RTL 要重新构建位流**，或者需求方说"你的意思是我上次叫你回滚没回滚干净吗"、
  "构建成功了但资源数字一个没变"时使用。只管工程操作层面，不管算法本身。
scope: 通用 —— 只要是用 Vivado 的工程就成立，与题目、板卡无关
compatibility: Vivado 2026.1 实测（部分行为在更早版本同样存在，未逐一验证）
inputs: 一次 BD 改动 / 一次工程还原 / 一次位流构建
outputs: 一份改动前后都自洽的工程；一份"新逻辑确实进去了"的核对结果
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "BD 改动脚本化且幂等，重复执行不会产生重复连线，改完 validate 干净。"
origin: "手点改 BD 无法复现；且升级 IP 时会被已缓存的网表骗过，静默综合旧结果，导致"改了代码位流没变"。"
---

# Vivado 工程操作与回滚（跨项目通用）

> **归属**：`workflow/` 工作流 —— 只要是用 Vivado 的工程就成立，**与题目、板卡无关**。
> 对应素材编号 G2 / G3 / G4 / G11。

---

## Purpose

**目的**：把 Vivado **"报错不报错"**和**"东西到底进没进去"**这两件事分开看 ——
这个工具最贵的坑不是编译失败，而是**它说成功了，其实没进去**。

**预期产出**：

| 产出 | 说明 |
|---|---|
| 一份能编译的 BD | 扩/缩口时"三件套"齐全 |
| **一个构建后核对动作** | 每次改 RTL 构建后，核对 OOC 资源数字有没有变 |
| 一条可靠的回滚路径 | 逐文件 MD5 比对，而不是"应该好了" |

**前置条件**：有改动前的**整目录备份**。

---

## When to Use

- 要**改 Block Design**、要**把自研 Verilog 挂进 BD**（`module_ref`）
- 要**扩 / 缩 AXI 互联的 M/S 口**
- 要**从备份还原工程**
- **改完 RTL 要重新构建位流**（必须做 OOC 核对）
- 现象像工具 bug（`validate_bd_design` 报内部错误）时

## When NOT to Use

- 纯顶层 RTL 工程（不在 BD 里）—— 第五节 OOC 陷阱不适用
- 只跑仿真、不碰工程文件 —— 那看 `../testbench-guide/SKILL.md`

---

## DO's

- 改 BD 结构前**先备份整个工程目录**
- `module_ref` 的**接口信号一律写全 `X_INTERFACE_INFO` 注解**
- `module_ref` **改了端口就换一个新模块名**
- 扩/缩 AXI 互联时，**结构参数 + 时钟复位 + 地址分配**三件一起做
- 还原工程后**逐文件 MD5 比对**，输出三类清单
- **每次改完 RTL 构建，核对 OOC 利用率数字有没有变**
- 喂 Vivado 的 `.tcl` **纯 ASCII**

## DON'Ts

- ⚠️ **不要把"`write_bitstream Complete!` + 0 critical warning"当成"新代码进去了"**
- **不要只还原 `.bd`** —— `.xci` 里的结构参数（如 `NUM_MI`）不会跟着回来
- **不要只断线不减 `NUM_SI`** —— 症状和"没分地址"一模一样
- **不要在脚本里写 `save_project`** —— 它不存在，而且会**中止整个脚本**
- **不要靠 IP 实例名推断频率**（`rst_ps7_0_50M` 实际跑 100MHz）

---

## Workflow：按时间顺序该查哪一节

| 时点 | 查哪节 | 一句话判据 |
|---|---|---|
| 挂自研模块进 BD 之前 | **一** | 注解写全了？端口变了就换名 |
| 扩 / 缩 AXI 互联时 | **二** | 结构参数、时钟复位、地址分配，三件齐了吗 |
| 从备份还原之后 | **三** | 逐文件 MD5 比对，三类清单里"哈希不同"那类是重点 |
| 写改动脚本时 | **四** | 纯 ASCII？没有 `save_project`？每步 catch？ |
| **构建成功之后** | **五** | **OOC 的 `Slice LUTs` 变了吗？没变就是没进去** |

---

## 一、★ 单个 IP 的坑：`module_ref` 端口表会被缓存

**适用**：任何要在 BD 里挂自己 Verilog 的工程｜**失效**：无

### 做法（`create_bd_cell -type module -reference <模块名>`）

① **必须写全 `X_INTERFACE_INFO` 注解** —— BD 才认得出 `s_axis`/`m_axis`/`s_axi` 是**总线接口**，否则只会当成一堆散引脚。
② ★**`module_ref` 的端口表会被工程缓存 ⇒ 改了模块端口就必须换一个新模块名**（如 `my_mod_v2`），否则新建的 cell 拿到的是**空端口表**。
③ **被 BD 引用的源文件绝不能从工程里移除**，否则报 `[BD 41-1726] Unable to resolve module-source`。

### 来源

AI 早期改完 HDL 端口后**没换模块名**，新建的 cell 拿到**空端口表**，白折腾一轮。
**⇒ 这是 Vivado 的缓存行为，不是"偶发故障"，别重试，直接换名。**

---

## 二、★ 扩 / 缩 AXI 互联的 M / S 口：三件事必须一起做

**适用**：`ps7_0_axi_periph` / `SmartConnect` 等互联 IP｜**失效**：无

### 做法

**加一个主口** ⇒ 缺一不可：
1. `NUM_MI` +1
2. 新口的 `Mxx_ACLK` / `Mxx_ARESETN` **接到时钟复位网**
3. **地址分配**（`assign_bd_address`）

**删一个从口** ⇒ 同理，**只断线是不够的**：
必须同时把 `NUM_SI` −1 并**重连其余所有口**。

### 来源

AI 之前扩了 M04 却**没连时钟、没分地址** ⇒ 报：

```
[BD 41-758]  m04_couplers/S_ACLK not connected to a valid clock source
[BD 41-2670] incomplete address path
```

⇒ **整个工程无法生成 HDL**。三件一起做完后 `generate_target` 一次通过。

**⇒ 反向教训**：**"只断线不减 `NUM_SI`" 同样会报 `[BD 41-2670] incomplete address path`** ——
症状和"没分地址"一模一样，只看报错容易查错方向。

---

## 三、★ 回滚：必须覆盖 IP 自己的 `.xci` / `ip/` 目录

**适用**：任何"从备份还原工程"的操作｜**失效**：无。**这是本工作包最贵的一条教训。**

### 做法

还原 `.bd` **之外**，还必须还原：
- IP 自己的 **`.xci`**（参数就存在这里！）
- **`ip/`** 目录

**验收方式（别靠"应该好了"）**：拿改动前的**整目录备份**与当前工程**逐文件比 MD5**，输出三类清单：

| 清单 | 含义 |
|---|---|
| 只在现在的 | 新增文件 |
| 只在备份的 | 漏还原的文件 |
| 两边都有但哈希不同 | **被改过没还原的文件** ← 真凶通常在这类 |

### 来源

AI 只还原了 `.bd`，**漏了 AXI 互联的 `.xci`**（里面还留着 `NUM_MI=5`）⇒
工程**根本没法重新编译**，而且症状先**伪装成 `validate_bd_design` 报内部错误**（看起来像工具 bug，不像漏文件）。

需求方直接质问：

> "**你的意思是我前面那次叫你回滚你没有给我回滚干净吗**"

按逐文件 MD5 比对才定位到**只有 `.xci` 这一层没还原**，补齐即恢复。

**⇒ 结论：`NUM_MI` 这类"结构参数"是存在 `.xci` 里的；`.bd` 还原了不等于工程还原了。**

---

## 四、Vivado 工具坑合集（2026.1 实测）

**适用**：Vivado 2026.1｜**失效**：版本升级后需重测。

| 坑 | 现象 | 正解 |
|---|---|---|
| **没有 `save_project` 命令**（只有 `save_project_as`） | 报 `[Common 17-163]` 并**中止整个脚本**（后面所有语句都不执行！） | 别写；`add_files` / `remove_files` **立即写盘**，不需显式保存 |
| `close_bd_design` 要带参数 | 报 missing value | `close_bd_design [current_bd_design]` |
| `connect_bd_net` / `connect_bd_intf_net` 参数必须是对象 | 传字符串失败 | 传 `[get_bd_pins ...]`；`disconnect_bd_intf_net` 需要 `-objects`；删网更稳用 `delete_bd_objs <net>` |
| **`get_bd_addr_segs -of_objects <cell>` 拿到的从口侧 OFFSET 是空的** | 自检误报"地址没分到" | offset 要查**地址空间一侧** |
| **`.hwh` 的 `CLKFREQUENCY` 含工具推断** | 把推断值当实测频率 | 频率必须落到"**谁驱动它**"的网表连接上 |
| **IP 实例名不含频率信息** | 见名生意、臆造时钟域 | 同上：任何频率都要查网表 |
| 喂 Vivado 的 `.tcl` 必须**纯 ASCII** | 中文按 cp936 解析成乱码 | 脚本和注释都用英文；`expr` 里不能带转义引号 |
| 构建产物目录不要猜 | 打印 MISSING 但构建其实成功了 | `get_property DIRECTORY [get_runs impl_1]` 问工具 |

### 来源（两条最典型的）

1. AI 在清理脚本里写了 `save_project` ⇒ 报错中止，**后面"磁盘搬移 + close_project"整段没执行**。
   **⇒ 教训：Vivado 脚本里一条命令报错会中止整个脚本，所以关键动作要么前置、要么每步 `catch`。**
2. AI 据 IP 名字里的 "50M" **臆造出一个根本不存在的"50MHz 时钟域"**，后来核对网表才自己揪出来。
   **⇒ 教训：IP 实例名不是证据，任何频率/位宽/连接都必须回到网表或源码。**（实例化此条：本项目 `rst_ps7_0_50M` 实际跑 **100MHz**）

---

## 五、★★ 改了 `module_ref` 里的 `.v`，却忘了重跑 OOC 综合 ⇒ **位流里还是旧逻辑**

**适用**：BD 里有 `module_ref`（自研 HDL 挂进 BD），且你改了它的源文件。｜**失效**：纯顶层 RTL（不在 BD 里）不受影响。

### 症状（★ 最阴的地方：它"成功"了）

构建报告 **`write_bitstream Complete!` + `PROGRESS 100%` + 0 error 0 critical warning**，位流也生成了 ——
**但代码根本没进去**。位流里跑的还是上一版逻辑。

**唯一的线索**：资源占用**和改动前一模一样**（这次是 10710 LUT / 16600 FF / 12 BRAM，一个数字都没变）。

### 根因

BD 里的 `module_ref` 是**离体综合（Out-Of-Context, OOC）**的 —— Vivado 把它当成独立 IP，**单独跑一个综合 run**：

```
synth_1                                  ← 顶层（大家都会 reset 这个）
design_1_<模块名>_0_0_synth_1            ← ★ 你的模块在这里，没人 reset 它
```

**`reset_run synth_1` 只重置顶层，不动这些 OOC run** ⇒ 顶层综合拿的是**缓存的旧网表**。

### 修法

```tcl
# 构建前：把所有 OOC 综合 run 也重置掉
# *_synth_1 只匹配 per-IP 的 OOC run，不会匹配顶层的 "synth_1"
foreach r [get_runs -quiet *_synth_1] {
    puts "RESET_OOC $r"
    reset_run $r
}
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```

### ★★ 每次构建后必查的判据

| 查什么 | 怎么查 | 判据 |
|---|---|---|
| **OOC 利用率** | `bitstream\<OOC run 名>\*_utilization_synth.rpt` | **RTL 改了，`Slice LUTs` 就必须变** —— 不变 = 没进去 |
| **OOC 是不是本次跑的** | `bitstream\<OOC run 名>\runme.log` 的时间戳 | 必须是**本次构建**的时间 |
| 顶层总资源 | `*_utilization_placed.rpt` | 和上一版**一个数字都不差** ⇒ 高度可疑 |

### 来源

曾遇到：改完一个 `module_ref` 模块的 `.v`（给它加了一整套算法）后构建，
报告一切正常，**但资源数字和改动前逐位相同**。追下去发现该模块的 OOC 综合 run
的 `runme.log` 还是上一次构建的时间戳，利用率报告里写着 **`Slice LUTs = 2`** ——
那还是改动前的纯透传骨架。

**⇒ 教训**：**"构建成功"不等于"新代码进去了"**。
每次改完 RTL 构建，**必须核对 OOC 资源数字有没有变**；
这跟"编译过 ≠ 算得对"是同一类错误，只是发生在更上游。

---

## 六、用 MCP 驱动 Vivado 会话（比 `-mode batch` 好在哪）

**适用**：任何想"边跑边看"的场合｜**失效**：没装 Vivado MCP Server 的机器。

### 两种跑法的差别

| | `vivado -mode batch -source xxx.tcl` | MCP 会话 |
|---|---|---|
| 生命周期 | **跑完就退**，下次要重新 `open_project` | **常驻**，`open_project` 只做一次 |
| 中途可见性 | 看不到进度，只能事后读日志文件 | **`vivado_status` 能查在跑什么、跑了多久、日志尾部** |
| 报错 | 自己 grep 日志 | **`vivado_log_messages` 结构化分类**（errors / critical / warnings / info） |
| 长命令 | 阻塞整个进程 | **甩到后台 + 持续监控**，可以边等边查 |
| 连着做几件事 | 得写进同一个脚本，一条命令报错会**中止整个脚本** | **一条一条发**，错了就改 |

### 典型用法

```
vivado_start(working_dir=<工程目录>, session_type=<ipi 或 general>)
vivado_execute("open_project <xpr>")                     ← 只做一次
vivado_execute("source <构建脚本>.tcl")                   ← 长命令，会被甩到后台
    ... 每隔几分钟 vivado_status(session_id) 查一次（★ 不要循环轮询）
vivado_execute("open_run impl_1")
vivado_execute("report_methodology -json <路径>")         ← 时序方法学检查（UG906）
vivado_execute("synth_design -top <模块> -part <器件> -lint -file <路径>")  ← RTL lint
vivado_stop(session_id)
```

**⚠️ 三条注意**：
① **`session_type`**：要动 Block Design 就选 `ipi`，其余选 `general`（官方要求必填）；
② **别循环轮询 `vivado_status`** —— 服务端会限流，"睡一段时间 → 查一次"就够；
③ **`synth_design -lint` 是独立命令**，得单独发；**2026.1 的 lint 报告本身就是 CSV**（官方文档里说的 Python 解析器只对 <2026.1 需要）。

### ★ 但工具不替代方法论

MCP 让你**能连着跑命令、能看到进度**，但它**不会告诉你"这个数字该怎么读"**。
本项目出过一次真实事故：时序报告跑出来了、工具一点没报错，
AI 却因为**把全局 WNS 当成自己域的余量**，得出了"关键路径不在自研模块里"的错误结论。
**⇒ 读报告的方法见 [`../timing-report-reading/SKILL.md`](../timing-report-reading/SKILL.md)。**

---

## 七、★ 删了源文件、工程里还留着悬空引用 ⇒ 打开工程报缺文件、构建直接失败

### 症状
- 回滚 / 清退某一版时把 `.v` 删了，**但工程文件集里还挂着它** ⇒ 下次 `open_project` 报文件不存在，`launch_runs` 根本起不来。
- 最阴的地方：**删的那一刻没有任何提示**，坑要等到下一个会话才炸（和第五节的 OOC 陷阱是同一个"工程元数据 ≠ 磁盘现实"家族）。

### 根因
- `.xpr` 里 `<FileSet Name="sources_1">` 下每个源文件是一条 `<File Path=…>` 记录；**删磁盘文件不会删这条记录**（`add_files` 加过的，必须 `remove_files` 减）。

### 做法（★ 改 `.xpr` 前先备份）
1. **列出来比对**：`Select-String -Path *.xpr -Pattern 'File Path="\$PSRCDIR/sources_1/new/'`，逐条 `Test-Path` 磁盘文件。
2. **备份**：`Copy-Item x.xpr x.xpr.bak_before_<改动名>`。
3. **删记录**：Vivado 里 `remove_files <路径>`；或工程关闭时直接摘掉对应的 `<File …>…</File>` 节点（纯 XML、改动自洽可审计）。
4. **两步验证**（缺一不可）：`open_project` **0 error**；`synth_design -rtl -top <顶层>` **0 error / 0 critical** —— 后者顺带证明"没有别处再引用被删的模块"。

### 来源
2026-10-10 清退第④级后要对齐到 10/4 版本，发现 `.xpr` 里仍留着 `dd_align.v`（第 80 行）/ `dd_localbg.v`（第 94 行）两条记录，而文件已删。摘掉后：文件集正好 9 个自研 `.v`、`open_project` 0 error、RTL 展开 0 error / 0 critical（119 条 warning 全是 `axi_vdma` 等官方 IP 内部的 XPM 提示）。

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-09-24 | 首版：module_ref 缓存、AXI 互联三件套、回滚覆盖 `.xci`、工具坑合集 |
| 1.1.0 | 2026-09-24 | 补第五节：OOC 陷阱（"构建成功但位流里还是旧逻辑"） |
| 1.2.0 | 2026-10-04 | 补第六节：用 MCP 驱动 Vivado 会话（与 `-mode batch` 的差别、注意事项） |
| 1.3.0 | 2026-10-10 | 补第七节：删源文件后的 `.xpr` 悬空引用（工程打不开 / 构建失败）与两步验证 |

---

## 相关文件（Integration）

- **上游**：改动前先出方案 → `../change-proposal/SKILL.md`；脚本怎么写 → `../selfcheck-gate/SKILL.md`
- **平行**：验证方法论 → `../verification-methods/SKILL.md`
- **下游**：写完 RTL 怎么确认算得对 → `../testbench-guide/SKILL.md`
- **本项目的实际应用**：`设计报告第 5 章`
