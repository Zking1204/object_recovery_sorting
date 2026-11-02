---
name: pynq-dma-cache
description: >-
  CPU 与 PL 共享内存时的缓存一致性处理，含可直接粘贴的封装 `grab_snapshot` / `feed_frames`，
  以及"全 0 / 永远慢一拍 / 像 DMA 没工作"这类现象的定位表。
  当你要**用 VDMA/DMA 把 PL 的数据搬到 DDR 再由 CPU 读、或反过来喂帧给 DMA**，
  或者需求方说"读出来全是 0""读出来是上一次的值""采集侧好像一个字节都没写进来"时使用。
  只管内存这一侧，不管 DMA 通道配得对不对。
scope: 通用 PYNQ —— 换题目、换板卡仍可用
compatibility: PYNQ（`pynq.Buffer`）；PYNQ-Z2 + VDMA 三缓冲已实测
inputs: 一个 DMA 用的 `pynq.Buffer` + 它的 numpy 视图
outputs: 一份"取到的确实是当前 DDR 内容"的保证；一套出错现象定位表
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "正确使用 flush 与 invalidate 后，帧缓冲读写不再出现假阴性，配合寄存器回读可把"硬件没出数据"与"读到旧值"区分开。"
origin: "曾整帧读到上一帧内容，误判为硬件不出数据，实际是 CPU 缓存未失效。"
---

# DMA 缓存一致性（含可复用封装）

> **归属**：`pynq/` 通用 PYNQ 技能 ｜ 来源编号 **P2**
> **比赛点名方向**：「可复用的 **DMA 搬运与缓存一致性处理封装**，含常见出错情形的定位方法」

---

## Purpose

**目的**：让"**PL 到底写没写进 DDR**"这个问题，**在怀疑硬件之前先自己排除掉**。

**预期产出**：

| 产出 | 说明 |
|---|---|
| 一个取帧封装 | `grab_snapshot()`：自动做 cache 维护 + 自动避开正在读的帧 |
| 一个喂帧封装 | `feed_frames()`：写完数据后把 cache 推到 DDR |
| 一张定位表 | 四种"看起来像硬件坏了"的现象，其实都是漏了 cache 维护 |

**前置条件**：你已经有一个 DMA 在跑（本技能不负责把 DMA 配起来）。

---

## When to Use

- 任何 **CPU 与 PL 共享内存**的场合 —— VDMA / DMA / AXI Master 往一块内存里写、CPU 又要读它的时候
- **典型症状**：PL 明明在写，CPU 读出来却是旧数据或全 0

## When NOT to Use

- 内存本来就映射为**非缓存（non-cacheable）** —— 这两个操作是多余的（但做了也无害）
- 不同 PYNQ 版本的 `Buffer` API 略有差异：老版本可能只有 `flush()`，需要 `try/except` 兜住
- DMA 通道本身没配好（没启动、地址写错、GenLock 没开）—— 那是另一类问题

---

## DO's

- **把 cache 维护封装进"取帧/喂帧"函数里**，而不是散落在调用点
- **读之前 `invalidate()`**，写之后 `flush()`
- 用 `try/except AttributeError` 兜住老版本没有 `invalidate()` 的情况
- 出问题时**先查 cache，再怀疑硬件**
- 多缓冲环形搬运时，**挑一个不在被读写的帧**再取

## DON'Ts

- ⚠️ **不要读到一个空缓冲就下结论"采集侧没数据"** —— 那是最典型的假阴性
- **不要把 `flush()` 和 `invalidate()` 用反**（写→PL 用 flush；PL 写→读 用 invalidate）
- **不要连续读同一个缓冲两次来"确认"** —— 第二次才变恰恰说明是 cache 问题，别把它当成正常

---

## Workflow

### Step 1：先理解根因

PL 通过 **S_AXI_HP 口**访问 DDR 时，**不经过 CPU 的 L2 cache**，也**不通知 cache**。所以：

```
PL 写 DDR  ──→ DDR 里是新数据
                  ↑
CPU 读同一地址 ──→ 可能命中自己的 cache ⇒ 读到旧值 ✗
```

**⇒ 两个方向都要管：**

| 方向 | 必须做 | 不做会怎样 |
|---|---|---|
| **CPU 写 → PL 读**（喂帧给 DMA） | `buf.flush()` | DMA 从物理内存读到旧/空数据 |
| **PL 写 → CPU 读**（取 DMA 抓的帧） | `buf.invalidate()` | CPU 读到旧值 ⇒ **假阴性** |

### Step 2：用现成的封装（可直接粘贴）

```python
import numpy as np

def grab_snapshot(buf, views, idx=None, park_reg=None):
    """
    从 DMA 的环形帧缓冲里安全取一帧（自动做 cache 维护）。

    buf      : pynq.Buffer（帧缓冲整体）
    views    : 每一帧的 numpy 视图列表
    idx      : 要取第几帧；None = 自动挑一个"不在被读写"的帧
    park_reg : 若给了 (mmio, offset)，用它读当前读帧号来自动挑帧
    """
    if idx is None:
        if park_reg is not None:
            mm, off = park_reg
            rd = (mm.read(off) >> 16) & 0x1F      # 当前正在读的帧号
            idx = (rd + 2) % len(views)           # 挑一个不在读、也早写完的
        else:
            idx = 0

    # ★ 关键：丢弃 CPU cache，强制从 DDR 重读
    try:
        buf.invalidate()
    except AttributeError:
        buf.flush()          # 老版本 PYNQ 没有 invalidate，退化为 flush

    f = views[idx]
    if f.ndim == 1:
        f = f.reshape(-1, f.shape[0] // 1)
    return np.array(f)


def feed_frames(buf, views, data):
    """CPU 写帧给 DMA 之前：把数据写进缓冲并发起 cache 刷写。"""
    for v, d in zip(views, data):
        v[:] = d
    buf.flush()              # ★ 把 CPU 的改动推到 DDR，DMA 才读得到
```

### Step 3：出问题时按表定位

| 现象 | 最可能的原因 | 怎么确认 |
|---|---|---|
| 读出来**全 0 / 全同一值** | 漏了 `invalidate()` | 加一句 `buf.invalidate()` 再读，值变了 ⇒ 确诊 |
| 读出来**是上一帧**（永远慢一拍） | 同上（读到的是 cache 里上次的快照） | 连续读两次同一个缓冲，第二次才变 ⇒ 确诊 |
| DMA 收到的数据**明显是旧的** | 漏了 `flush()` | 写完数据后**插延时**再启动 DMA，若现象消失 ⇒ 确诊 |
| **完全读不到数据，像 DMA 没工作** | 也可能是漏 `invalidate()` | ★ 先查这个，别急着怀疑硬件 |

---

## 已验证效果

本项目（PYNQ-Z2 + VDMA 三缓冲）上：
- 加上 `buf.invalidate()` 后，立刻读到真实帧数据（此前读出"一个字节都没被改写"）
- `buf.flush()` 用于缓冲铺黑（两侧黑边就是靠它生效的）

---

## 来源（从哪些失败或观察中总结得出）

**P2**：大模型漏了 `invalidate()`，就直接下结论「采集侧一个字节都没写进来」⇒ **假阴性**，白白怀疑了一轮硬件。
真因是 CPU 从自己的 cache 里读到了旧值。**这条错误的代价是整轮排查方向被带偏。**

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-09-24 | 首版：根因说明 + `grab_snapshot` / `feed_frames` 封装 + 定位表 |

---

## 相关文件（Integration）

- **封装的实际使用者**：`../../bitstream/cam_full.py`（`buf0.flush()` / 抓帧代码）
- **上游**：先把 overlay 正确加载 → `../pynq-overlay-regmap/SKILL.md`
- **下游**：拿到帧之后怎么比对 → `../golden-compare/SKILL.md`
- **相关的帧率测量陷阱**：`设计报告第 6 章`
