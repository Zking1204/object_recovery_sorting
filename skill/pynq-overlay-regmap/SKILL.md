---
name: pynq-overlay-regmap
description: >-
  把 overlay 安全加载起来，并把 PL 侧寄存器访问做对：加载之前绝不碰 PL 地址、位流身份用"警告不中断"核对、
  `.bit` 与 `.hwh` 必须同目录同基础名；访问寄存器优先用 `register_map` 声明地址与位域，
  无法描述时用 `MMIO` 兜底，**写任何偏移之前先 grep 本机头文件核对**。
  当你要加载或更换位流、怀疑"位流没加载"、寄存器读回全 0 或读到上一次的值、
  或想把散落的裸 MMIO 整理成有名字的寄存器类时使用。
  只管"怎么安全加载"与"怎么找对地址"，不管寄存器里该写什么值，也不管 PL 里的电路对不对。
scope: 通用 PYNQ —— 换题目、换板卡仍可用
compatibility: PYNQ（`pynq.Overlay` / `DefaultIP` / `register_map` / `MMIO`）；PYNQ-Z2 已实测，任意 Zynq / Zynq MPSoC 板同理
inputs: 一个 `.bit` + 配套的 `.hwh`（同目录、同基础名）；或某个 IP 的 VLNV / 基地址 + 空间大小
outputs: 一个已正确加载的 overlay；一个带名字的寄存器访问类；一份"地址从哪来"的核对记录
version: 2.0.0
updated: 2026-11-03
license: MIT
verified_effect: "上板后 fpga state=operating、摄像头 chip id 读回 0x5640、自研算法核 AXI-Lite 读回 0xDEADBEEF，全部一次通过；反向验证：把 PL 探测挪到加载之前，连续挂死两次、只能整板断电。"
origin: "合并自两条实战教训：① 现象『屏幕全黑，而 PS 侧 SCCB、VDMA 状态、寄存器回读全部正常』，最终查到 .hwh 里 FCLK0 分频仍是 4/4 ⇒ PL 实际只跑 62.5 MHz；② 凭记忆把 EMIO(bank2) 的 MASK_DATA_LSW 记成 0x000（那是 bank0 的值），导致 SCCB 一个 ACK 都没有，事后 grep 头文件才定案。"
---

# Overlay 加载与寄存器访问

> **归属**：通用 PYNQ 技能（换题目、换板卡仍可用）
> **对应官方点名的加分方向**：「通用 Overlay 加载与校验流程、寄存器映射与 `register_map` 使用范式」

---

## Purpose

**目的**：把两件事在不把板子搞死的前提下确认掉 ——

1. **PL 到底配没配上**、配的是不是我想的那一版；
2. **这个寄存器偏移到底是多少**，从"凭记忆"变成"查得到来源"。

**预期产出**：

| 产出 | 说明 |
|---|---|
| 一个加载好的 overlay | `Overlay(...)` 返回的对象 |
| 一份身份核对记录 | 每个候选位流的路径 + MD5，以及最终选了哪个 |
| 一个寄存器类 | 地址与位域**只声明一次**，之后按名字读写 |
| 一条不可越界的纪律 | **加载之前，绝不出现任何 `MMIO(...)`** |

**前置条件**：`.bit` 与它的 `.hwh` **同目录、同基础名**；要访问自研 IP 时，`.hwh` 里要有该 cell 的 VLNV。

---

## When to Use

- 任何用 PYNQ 加载 overlay（配置 PL）的场合，无论板卡是 PYNQ-Z2、ZCU104 还是别的 Zynq 板
- 换了新位流、重新上传之后
- 脚本报"寄存器读出来全 0 / 读出来是上一次的值"
- 要把散落的 `MMIO(...).write(0x??, ...)` 整理成有名字的寄存器类
- 怀疑某个偏移记错了

## When NOT to Use

- 无——"加载前不碰 PL 地址"是硬约束，没有例外。唯一可用的替代判断是**读 Linux 侧的纯文件**（`/sys/class/fpga_manager/fpga0/state`），但**仍然不能碰 PL 地址**。
- 不用 PYNQ 的加载方式（例如启动时由 PetaLinux 自动加载）不在本技能范围。
- 工程里**没有可查的头文件**时，第 6 步退化为"必须实测确认"（写一个已知值再读回）。
- 寄存器读回来了但电路不工作 —— 那是 IP 内部行为问题，要靠仿真/波形，不在这里解决。

---

## DO's

- **板端脚本的第一步只能是两件事之一**：直接 `Overlay()`，或读 Linux 侧的纯文件
- 加载前**打印所有候选位流的路径 + MD5**
- 位流身份**不匹配时给警告 + 交给需求方判断**，而不是中断
- 自己 IP 的地址**从 `.hwh` 的 `C_BASEADDR` / `MEMRANGE` 取**
- **写任何偏移之前，先 grep 本机头文件核对**
- 拿不准就**实测确认**（写已知值再读回）
- 把 VLNV 写进 `bindto`，让 PYNQ 自动把 overlay 里的这个 IP 绑到你的类

## DON'Ts

- ⚠️ **加载之前绝不访问任何 PL 地址** —— 会把 CPU 挂死，`try/except` 拦不住、不会超时、**重启内核也解不掉，只能整板断电**
- ⚠️ **不要把会变的标识（MD5 / 版本号 / 时间戳）做成"匹配不上就失败"**
- ⚠️ **不要凭记忆写寄存器偏移** —— 差一个 `0x010` 就是一个通宵
- **不要只换 `.bit` 不换 `.hwh`** —— PS 会按旧地址表访问新电路
- **不要以为 `write_bitstream` 会生成 `.hwh`** —— 它只由 `generate_target` 产出
- **不要相信 IP 实例名** —— 名字里的频率、编号都不是证据

---

## Workflow

### Step 1：加载之前，绝不访问任何 PL 地址

PL 未配置时，对 PL 地址的 MMIO / AXI 读**会把 CPU 挂死**：它不是异常、不会超时返回、重启内核也解不掉。

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

> 反面记录：曾为了"避免重复加载导致熄屏"，把 PL 探测挪到 `Overlay()` 之前 ⇒ **连续挂死两次，只能整板断电**。**知道规则 ≠ 遵守规则。**

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

- PYNQ 靠**同名 `.hwh`** 才知道 overlay 的内存布局与地址映射
- **只换 `.bit` 不换 `.hwh`** ⇒ PS 按旧地址表访问新电路 ⇒ 寄存器全读错
- `.hwh` 是 **`generate_target` 的产物**，`write_bitstream` **不会**生成它 ⇒ `.hwh` 比 `.bit` 旧是**正常**的
- `.hwh` 头部自带 `TIMESTAMP` / `SPEEDGRADE` / `BOARD`，可直接核对

### Step 4：优先用官方的 `register_map`（比裸 `MMIO` 好）

它把寄存器地址与位域**声明一次**，之后按名字读写：

```python
from pynq import DefaultIP
from pynq.registers import RegisterMap, Register

class MyIpRegisters(RegisterMap):
    CONTROL   = Register(0x00)      # 名字 = 偏移地址（十六进制）
    STATUS    = Register(0x04)
    THRESHOLD = Register(0x10)

class MyIp(DefaultIP):
    bindto = ['xilinx.com:module_ref:<你的模块名>:1.0']   # 用 .hwh 里该 cell 的真实 VLNV

    def __init__(self, description):
        super().__init__(description=description)
        self.regs = MyIpRegisters(self.mmio)

    @property
    def hit_count(self):            # 需要时可写语义化读写
        return self.regs.STATUS
```

**好处**：地址、位域、权限集中在一处；换 IP / 换板卡只改 VLNV 与偏移表。

### Step 5：无法描述时用 `MMIO` 兜底

```python
from pynq import MMIO
VDMA0 = MMIO(0x43000000, 0x10000)     # 基地址, 空间大小
VDMA0.write(0x00, 0x0B)               # 写
val = VDMA0.read(0x04)                # 读
```

### Step 6：★ 写任何偏移之前，先 grep 本机头文件核对

工作区里通常就有权威来源：

| 要找什么 | 去哪查 |
|---|---|
| Xilinx IP 的寄存器偏移 | Vivado 安装目录下的驱动头文件（如 `xaxivdma_v6_3/src/xaxivdma_hw.h`） |
| PS 侧外设（GPIO / UART / I2C） | BSP 的 `include/*_hw.h`（如 `xgpiops_hw.h`） |
| 自己 IP 的地址 | overlay 的 `.hwh`（`C_BASEADDR` / `MEMRANGE`） |

**可直接套用的偏移公式（Zynq GPIO，可推广到同类外设）**：

| 寄存器 | 公式 |
|---|---|
| `DATA` | `0x040 + 4 × bank` |
| `DATA_RO` | `0x060 + 4 × bank` |
| `DIRM` | `0x204 + 0x40 × bank` |
| `OEN` | `0x208 + 0x40 × bank` |
| `MASK_DATA_LSW` | `0x000 + 8 × bank` |

⇒ **EMIO 是 bank2**：`DATA=0x048`、`DATA_RO=0x068`、`DIRM=0x284`、`OEN=0x288`、`MASK_DATA_LSW=0x010`。

---

## ★★ 为什么"MD5 不匹配"不要做成硬中断

`BIT_MD5` 是**每次重新综合都会变**的东西。写成硬中断，等于**每产出一版新位流，这个脚本就作废一次**。实际发生过：重新综合后上传新位流，一跑就 `SystemExit`，而上一行刚打印出实际 MD5 —— 位流明明已经传上去了。

**通用原则**：

> 凡是"每次构建 / 产出都会变"的标识（**MD5、版本号、时间戳**），**不要做成"匹配不上就失败"**，要做成**警告 + 交给需求方判断**，并在警告文案里写清两种可能：**"刚重编过 = 正常" / "没重编过 = 传错文件"**。

而且 `.bit` + `.hwh` 配套**不是靠 MD5 保证的**（靠"同目录同基础名"），所以放宽它不会丢掉真正的保护 —— 原来的写法是"防错了地方还把自己锁死"。

---

## 已验证效果

- 本工程上板：`fpga state = operating`、摄像头 chip id `0x5640`、自研算法核 AXI-Lite 读回 `0xDEADBEEF`，全部一次通过。
- 按偏移公式推出的 EMIO 地址后，SCCB 立刻读到 OV5640 正品 ID（`0x300A/0x300B`）。
- 反面验证：PL 探测挪到加载之前 ⇒ 连续挂死两次，只能整板断电。

---

## 来源（从哪些失败或观察中总结得出）

1. **"屏幕全黑、PS 侧一切正常"**：最终定位到 `.hwh` 里 FCLK0 分频仍是 4/4，PL 实际只跑 62.5 MHz。⇒ 由此固化"加载后必须自查时钟频率"这条习惯。
2. **位流身份靠"同目录同基础名"而非 MD5**：只换 `.bit` 没换 `.hwh` 时，PS 按旧地址表访问新电路，寄存器全读错。
3. **EMIO 偏移记错一个 `0x010`**：把 bank2 的 `MASK_DATA_LSW` 记成 bank0 的 `0x000`，SCCB 一个 ACK 都没有；grep `xgpiops_hw.h` 才定案。
4. **MD5 硬中断把上板卡住**：改成"警告 + 继续"后，产线式重新综合不再需要改脚本。

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-09-24 | 拆成 overlay 加载与寄存器访问两条独立技能 |
| 2.0.0 | 2026-11-03 | 合并为一条：加载三铁律 + `register_map` 范式 + 偏移核对与公式；补"MD5 不做硬中断"的通用原则 |

---

## 相关文件（Integration）

- 本项目落地：`src/ps/cam_full.py`（找位流 → 加载 → 时钟自检 → 外设初始化）、`src/ps/pz2_video.py`（寄存器级函数库）
- 下游：加载完成后怎么验电路行为 → `../onboard-verification/SKILL.md`
