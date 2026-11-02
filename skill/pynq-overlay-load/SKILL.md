---
name: pynq-overlay-load
description: >-
  用 PYNQ 加载 overlay 之前必须做的三件事：绝不访问 PL 地址、核对位流身份（但**不匹配时不要中断**）、
  确认 .bit 与 .hwh 同目录同基础名。当你要**加载位流、换位流、怀疑"位流没加载"、
  需求方上传新位流后脚本跑不起来**，或者需求方说"寄存器读出来全是 0""读出来是上一次的值"时使用。
  只管加载这一步的安全性，不管 PL 里的电路对不对。
scope: 通用 PYNQ —— 换题目、换板卡仍可用
compatibility: PYNQ（`pynq.Overlay`）；PYNQ-Z2 已实测，任意 Zynq / Zynq MPSoC 板同理
inputs: 一个 `.bit` + 配套的 `.hwh`（同目录同基础名）
outputs: 一个已正确加载的 overlay；一份"位流身份"的核对记录
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "加载后能可靠区分"位流未生效""频率不对""句柄没建起来"三类故障，而不是笼统地"跑不通"。"
origin: "多次上板联调中出现"屏幕全黑但 PS 侧 SCCB、VDMA 状态、寄存器回读全部正常"，最终靠加载自检定位到硬件描述文件里的 FCLK0 分频仍是 4/4，PL 实际只跑 62.5 MHz。"
---

# Overlay 加载与校验流程

> **归属**：`pynq/` 通用 PYNQ 技能（换题目、换板卡仍可用）｜ 来源编号 **P1 + P7**

---

## Purpose

**目的**：把"**PL 到底配没配上**"和"**我配的是不是我想的那一版**"这两件事，
在**不把板子搞死**的前提下确认掉。

**预期产出**：

| 产出 | 说明 |
|---|---|
| 一个加载好的 overlay | `Overlay(...)` 返回的对象 |
| 一份身份核对记录 | 每个候选位流的路径 + MD5，以及最终选了哪个 |
| 一条不可越界的纪律 | **加载之前，绝不出现任何 `MMIO(...)`** |

**前置条件**：`.bit` 与它的 `.hwh` **同目录、同基础名**。

---

## When to Use

- 任何用 PYNQ 加载 overlay（配置 PL）的场合 —— 无论板卡是 PYNQ-Z2、ZCU104 还是别的 Zynq 板
- 换了新位流、重新上传之后
- 脚本报"寄存器读出来全 0 / 读出来是上一次的值"

## When NOT to Use

- **无**。"加载前不碰 PL 地址"是硬约束。
- 唯一例外：如果你的平台提供了**非 MMIO** 的状态查询接口（如 `/sys/class/fpga_manager/fpga0/state`），
  可以用它判断 PL 状态，但**仍然不能碰 PL 地址**。
- 不用 PYNQ 的加载方式（如 PetaLinux 启动时自动加载）不在本技能范围。

---

## DO's

- **板端脚本的第一步只能是两件事之一**：直接 `Overlay()`，或读 Linux 侧的纯文件
- 加载前**打印所有候选位流的路径 + MD5**
- 位流身份**不匹配时给警告 + 交给需求方判断**，而不是中断
- 用 `/sys/class/fpga_manager/fpga0/state` 判断 PL 状态（输出 `operating` = 已配置）
- 确认 `.bit` 与 `.hwh` **同目录同基础名**

## DON'Ts

- ⚠️ **加载之前绝不访问任何 PL 地址** —— 会把 CPU 挂死，**重启内核也解不掉，只能整板断电**
- ⚠️ **不要把会变的标识（MD5 / 版本号 / 时间戳）做成"匹配不上就失败"** —— 见下文
- **不要只换 `.bit` 不换 `.hwh`** —— PS 会按旧地址表访问新电路
- **不要以为 `write_bitstream` 会生成 `.hwh`** —— 它只由 `generate_target` 产出

---

## Workflow

### Step 1：加载之前，绝不访问任何 PL 地址

PL 未配置时，对 PL 地址的 MMIO/AXI 读**会把 CPU 挂死**：

- 它不是异常 —— `try/except` 拦不住
- 它不会超时返回
- **重启内核也解不掉，只能整板断电**

**安全的两条路（二选一）**：

```python
from pynq import Overlay
import os

# 路径 A：直接加载（这一步本身是安全的）
ol = Overlay('/home/xilinx/jupyter_notebooks/design_1_wrapper.bit')

# 路径 B：要判断状态，就读 Linux 侧的纯文件（不碰 PL 地址）
s = '/sys/class/fpga_manager/fpga0/state'
print(open(s).read().strip() if os.path.exists(s) else '(无此文件)')
# 输出 operating = PL 已配置
```

### Step 2：加载前核对 MD5 —— 但**不匹配时不要中断**

```python
import glob, hashlib, os

BIT_MD5 = "1C3325010780EB62A5DC0B14DDCEFDDD"   # 当前期望的位流（每次重编都会变）

cands = []
for r in ("/home/xilinx/jupyter_notebooks", "/home/xilinx"):
    if os.path.isdir(r):
        cands += glob.glob(os.path.join(r, "**", "design_1_wrapper*.bit"), recursive=True)
cands = sorted(set(cands))
for q in cands:
    print("找到:", q, "md5=", hashlib.md5(open(q, "rb").read()).hexdigest().upper())

hit = [q for q in cands
       if hashlib.md5(open(q, "rb").read()).hexdigest().upper() == BIT_MD5]
if not hit:
    if not cands:
        raise SystemExit("!! 一个位流都没找到 —— 先上传再跑")   # 这才是真的没得跑
    # ★ 版本不匹配**不中断**：取最新的继续，但把两种可能说清楚
    hit = [max(cands, key=os.path.getmtime)]
    print("!! ⚠️ 没有位流匹配 BIT_MD5 =", BIT_MD5)
    print("!! ⚠️ 改用最新的:", hit[0])
    print("!! ⚠️ 刚重新综合过 -> 正常，继续跑。")
    print("!! ⚠️ 没重新综合过 -> 传错文件了！停下来核对！")
ol = Overlay(hit[0])
```

### Step 3：确认 `.bit` 与 `.hwh` 同目录同基础名

- PYNQ 靠 **同名 `.hwh`** 才知道 overlay 的内存布局与地址映射
- **只换 `.bit` 不换 `.hwh`** ⇒ PS 按旧地址表访问新电路 ⇒ 寄存器全读错
- `.hwh` 是 **`generate_target` 的产物**，**`write_bitstream` 不会生成它** ⇒ `.hwh` 比 `.bit` 旧是正常的
- `.hwh` 头部自带 `TIMESTAMP` / `SPEEDGRADE` / `BOARD`，可直接核对

---

## ★★ 为什么**不要**做成"不匹配就退出"

`BIT_MD5` 是**每次重新综合都会变**的东西。写成硬中断，等于**每产出一版新位流，这个脚本就作废一次** ——
必须回头改脚本、重新上传、重启内核才能跑。实际遇到过这个坑：

> 重新综合出里程碑 1 的位流 → 需求方上传后一跑 → `!! 没找到 MD5 = 2AE38AAD… 的位流` + `SystemExit`
> —— 而**上一行刚打印出实际 MD5 是 `1C332501…`**，位流明明已经传上去了。

**⇒ 通用原则**：

> 凡是"每次构建 / 产出都会变"的标识（**MD5、版本号、时间戳**），
> **不要做成"匹配不上就失败"**，要做成**警告 + 交给需求方判断**，
> 并在警告文案里写清两种可能：**"刚重编过 = 正常" / "没重编过 = 传错文件"**。

**`.bit` + `.hwh` 配套这件事不是靠这个 MD5 保证的**（见 Step 3，靠"同目录同基础名"），
所以放宽它**并不会丢掉真正的保护** —— 原来的写法其实是"防错了地方还把自己锁死"。

---

## 已验证效果

- 在本项目（PYNQ-Z2）上，按以上三步加载后：`fpga state = operating`、chip id 读回 `0x5640`、算法槽位 AXI-Lite 读回 `0xDEADBEEF`，全部正常。
- **反面验证**：曾把"PL 探测"挪到加载之前 ⇒ **连续挂死两次，只能整板断电**。

---

## 来源（从哪些失败或观察中总结得出）

1. **P1**：大模型明知这条风险，为"避免重复加载导致熄屏"仍把 PL 探测挪到了 `Overlay()` 之前 ⇒ **当晚连续挂死两次**。教训：**知道规则 ≠ 遵守规则**。
2. **P7**：交付时只换了 `.bit` 没换 `.hwh` ⇒ PS 按旧地址表访问新电路，读到的寄存器全错。
3. **2026-09-24**：**这个 MD5 校验把自己把上板卡住了** —— 脚本里写死的是上一版位流的 MD5，
   重新综合后需求方一跑就 `SystemExit`，而位流明明已经传上去了。
   ⇒ 从"硬中断"改成"**警告后继续**"，并补上这条通用原则：**会变的标识不要做成"匹配不上就失败"**。

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-09-24 | 首版：三条铁律（不碰 PL 地址 / MD5 核对 / bit+hwh 配套） |
| 1.1.0 | 2026-09-24 | MD5 校验从"硬中断"改为"警告后继续"，并升格为通用原则 |

---

## 相关文件（Integration）

- **本项目里的实际实现**：`../../bitstream/cam_full.py` 的第 1 节（找位流 + MD5 + Overlay + 状态打印）
- **本项目专用的完整启动流程**：`设计报告 §8.4 与 `src/ps/cam_full.py``
- **下游**：加载之后怎么读写寄存器 → `../pynq-regmap/SKILL.md`
