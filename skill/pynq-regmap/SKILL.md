---
name: pynq-regmap
description: >-
  寄存器映射与访问范式：优先用 PYNQ 官方 `register_map` 声明地址与位域、
  无法描述时用 `MMIO` 兜底、**写任何偏移之前先 grep 本机头文件核对**，附 Zynq GPIO/EMIO 的通用偏移公式。
  当你要**从 PS 读写 PL 侧 IP 的 AXI-Lite 寄存器、要把裸 `MMIO` 换成有名字的寄存器类、
  或者怀疑某个寄存器偏移记错了**时使用。只管"怎么找到并访问正确的地址"，不管寄存器里该写什么值。
scope: 通用 PYNQ —— 换题目、换板卡仍可用
compatibility: PYNQ（`pynq.DefaultIP` / `register_map` / `MMIO`）；Zynq-7000 已实测
inputs: 一个 IP 的 VLNV（从 `.hwh` 查）或基地址 + 空间大小
outputs: 一个带名字的寄存器访问类；一份可核对的地址来源
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "寄存器偏移一次对齐，PS 侧脚本与 RTL 不会各自漂移。"
origin: "自研检测核的寄存器索引只有 7 位、空间写满后，新外设被迫改为独立 AXI-Lite 从设备，由此固化出"每设备 64 KB 地址窗、不复用现有核"的地址规划规则。"
---

# 寄存器映射与访问范式

> **归属**：`pynq/` 通用 PYNQ 技能 ｜ 来源编号 **P3**
> **比赛点名方向**：「**寄存器映射与 `register_map` 使用范式**」

---

## Purpose

**目的**：把"**这个偏移到底是多少**"从"凭记忆"变成"**查得到来源**"。

**预期产出**：

| 产出 | 说明 |
|---|---|
| 一个寄存器类 | 地址与位域**只声明一次**，之后按名字读写 |
| 一条核对习惯 | 写偏移之前先 grep 头文件 |
| 一张来源表 | "要找什么 ⇒ 去哪查" |

**前置条件**：有 `.hwh`（自己的 IP）或对应 IP 的驱动头文件（厂商 IP）。

---

## When to Use

- 任何要从 PS 读写 PL 侧 IP 寄存器的场合（AXI-Lite）
- 要把散落的 `MMIO(...).write(0x??, ...)` 整理成有名字的寄存器类
- 怀疑某个偏移记错了

## When NOT to Use

- 工程里**没有可查的头文件**时，第 3 条退化为"必须实测确认"（读回写进的值验证）
- `register_map` 需要该 IP 在 `.hwh` 里有正确的 VLNV；自定义 `module_ref` 的 VLNV 形如
  `xilinx.com:module_ref:<模块名>:1.0`
- 纯 IP 内部的行为问题（寄存器读回来了但电路不工作）—— 那要靠波形/仿真

---

## DO's

- **优先用 `register_map`**，把地址与位域集中在一处
- **写任何偏移之前，先 grep 本机头文件核对**
- 自己 IP 的地址**从 `.hwh` 的 `C_BASEADDR` / `MEMRANGE` 取**
- 拿不准就**实测确认**（写一个已知值再读回）
- 把 VLNV 写进 `bindto`，让 PYNQ 自动把 overlay 里的这个 IP 绑到你的类

## DON'Ts

- ⚠️ **不要凭记忆写寄存器偏移** —— 差一个 `0x010` 就是一个通宵
- **不要相信 IP 实例名**（名字里的频率/编号都不是证据）
- **不要在没加载 overlay 时碰任何 PL 地址**（见 `../pynq-overlay-load/SKILL.md`）

---

## Workflow

### Step 1：优先用官方的 `register_map`（比裸 `MMIO` 好）

它把寄存器地址与位域**声明一次**，之后按名字读写，避免手算偏移出错：

```python
from pynq import DefaultIP
from pynq.registers import RegisterMap, Register

class MyIpRegisters(RegisterMap):
    # 名字 = 偏移地址（十六进制）
    CONTROL   = Register(0x00)
    STATUS    = Register(0x04)
    THRESHOLD = Register(0x10)

class MyIp(DefaultIP):
    bindto = ['xilinx.com:module_ref:<你的模块名>:1.0']   # 用 .hwh 里该 cell 的真实 VLNV

    def __init__(self, description):
        super().__init__(description=description)
        self.regs = MyIpRegisters(self.mmio)

    # 若需要，可写语义化的读写方法
    @property
    def defect_count(self):
        return self.regs.STATUS
```

**⇒ 好处**：地址、位域、权限都集中在一处；换 IP / 换板卡只改 VLNV 与偏移表。

### Step 2：无法描述时用 `MMIO` 兜底

```python
from pynq import MMIO
VDMA0 = MMIO(0x43000000, 0x10000)     # 基地址, 空间大小
VDMA0.write(0x00, 0x0B)               # 写
val = VDMA0.read(0x04)                # 读
```

### Step 3：★ 写任何偏移之前，先 grep 本机头文件核对

**不要凭记忆写地址。** 工作区里通常就有权威来源：

| 要找什么 | 去哪查 |
|---|---|
| Xilinx IP 的寄存器偏移 | Vivado 安装目录下的驱动头文件（如 `xaxivdma_v6_16/src/xaxivdma_hw.h`） |
| PS 侧外设（GPIO/UART/I2C） | BSP 的 `include/*_hw.h`（如 `xgpiops_hw.h`） |
| 自己 IP 的地址 | overlay 的 `.hwh`（`C_BASEADDR` / `MEMRANGE`） |

### Step 4：可直接套用的偏移公式（Zynq GPIO，可推广）

| 寄存器 | 公式 |
|---|---|
| `DATA` | `0x040 + 4 × bank` |
| `DATA_RO` | `0x060 + 4 × bank` |
| `DIRM` | `0x204 + 0x40 × bank` |
| `OEN` | `0x208 + 0x40 × bank` |
| `MASK_DATA_LSW` | `0x000 + 8 × bank` |

**⇒ EMIO 是 bank2**：`DATA=0x048`、`DATA_RO=0x068`、`DIRM=0x284`、`OEN=0x288`、`MASK_DATA_LSW=0x010`。

---

## 已验证效果

- 按公式推偏移后，SCCB 立刻读到 OV5640 正品 ID `0x5640`（`0x300A/0x300B`）
- 本项目算法槽位通过 `MMIO(0x43C20000)` 读回 `0xDEADBEEF`，验证 AXI-Lite 通路

---

## 来源（从哪些失败或观察中总结得出）

**P3**：大模型凭记忆把 EMIO(bank2) 的 `MASK_DATA_LSW` 记成 `0x000`（**那是 bank0 的**），实际是 `0x010`
⇒ 位敲 SCCB 一个 ACK 都没有。事后 grep 工作区里的 `xgpiops_hw.h` 才定案。
**教训：差一个 0x010 就是一个通宵。**

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-09-24 | 首版：register_map 范式 + 偏移核对习惯 + GPIO/EMIO 公式 |

---

## 相关文件（Integration）

- **上游**：先正确加载 overlay → `../pynq-overlay-load/SKILL.md`
- **本项目地址映射全表**：`设计报告第 3 章与附录 A`
- **板端实际用法**：`../../bitstream/cam_full.py`
