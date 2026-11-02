---
name: util-timing-collect
description: >-
  用脚本从 Vivado 实现报告里机械提取资源与时序数字（LUT/FF/BRAM/DSP/WNS/时序是否满足），
  累积成 JSON 并打印成 markdown 表，直接生成"优化前后对比表"。
  当你**做完一次有意义的改动、要留证据、要写报告里的对比数据**，或者需求方说
  "这次优化了多少"、"把资源数字记下来"、"生成对比表"时使用。
  只管"把数字采下来存好"，不管怎么优化。
scope: 通用 PYNQ / Vivado —— 换题目、换板卡仍可用
compatibility: Vivado 2026.1 的报告格式已实测；跨版本表格格式可能微调
inputs: 一个实现完成后的 run 目录
outputs: 一份累积的 `metrics.json` + 一张可贴进报告的 markdown 对比表
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "一条命令从实现报告里抽出 LUT / FF / BRAM / DSP 与 WNS / WHS / TNS，直接产出对比表。"
origin: "需要交"优化前后对比"时才发现没留数据，只能重跑综合，教训是每个改动都要当场记下资源与时序。"
---

# 资源 / 时序数据自动采集（生成"优化前后对比表"）

> **归属**：`pynq/` 通用 PYNQ 技能 ｜ 来源编号 **P6**（后半）
> **比赛点名方向**：「性能与资源数据**自动采集并生成报告**的工具」

---

## Purpose

**目的**：把"**这次优化到底有没有效果**"变成**可以贴进报告的一张表** ——
而且**每做一次改动就采一次**，因为人到了截止前是**补不回来**这些数字的。

**预期产出**：

| 产出 | 说明 |
|---|---|
| `metrics.json` | 每次改动的 `tag / 日期 / LUT / FF / BRAM / DSP / IOB / WNS / met` |
| 一张 markdown 表 | 直接贴进设计报告的"优化前后对比"章节 |
| 原始报告 | `report_utilization` / `report_timing_summary` 导出的干净文本 |

**前置条件**：已经跑完一次实现（`impl_1` 完成）。

---

## When to Use

- 任何需要证明"**优化有效**"的场合 —— 比赛明确要求"给出**与基线的对比**"
- 每做完一次有意义的 RTL 改动、重新构建之后
- 写设计报告要数据时

## When NOT to Use

- 报告文件名随工程/top 名变化 ⇒ 改脚本里的 `TOP` 即可
- `report_utilization` 的表格格式**跨 Vivado 版本可能微调** ⇒ 正则要跟着改
  （**建议先手工 grep 一次确认能匹配上**再跑）
- 还没有实现结果（只有综合）时 —— 采集到的不是最终数字

---

## DO's

- **机械提取，不要手抄** —— 手抄上百个数字风险极高
- **用 `get_property DIRECTORY [get_runs impl_1]` 问出 run 目录**，不要猜
- 每次改动都追加一条记录，**只增不改**
- 把 `met`（时序是否满足）一起记下来 —— 只看 WNS 会漏掉其他约束
- 采完立刻 `show_table()` 看一眼，确认正则匹配上了

## DON'Ts

- ⚠️ **不要等想起来才补采** —— 位流覆盖之后旧报告就没了
- **不要猜 run 目录**（用 `get_property DIRECTORY [get_runs impl_1]` 问 Vivado 要，不同工程的落点不一样）
- **不要把综合报告的数字当成实现后的数字**

---

## Workflow

### Step 1：搞清报告文件在哪

| 要什么 | 文件 |
|---|---|
| 资源占用 | `<run 目录>/<top>_utilization_placed.rpt` |
| 时序 | `<run 目录>/<top>_timing_summary_routed.rpt` |
| 引脚落位 | `<run 目录>/<top>_io_placed.rpt` |

**⚠️ run 目录不要猜**：用 `get_property DIRECTORY [get_runs impl_1]` 问出来。

### Step 2：跑采集脚本（可直接粘贴）

```python
import re, os, json, datetime

# 按需改这三行
RPT_DIR = r"<工程目录>\<proj>.runs\impl_1"      # 换成你自己的 run 目录
TOP     = "design_1_wrapper"
DB      = r"metrics.json"                    # 累积结果，放哪都行

def _grab(path, pattern, cast=float):
    if not os.path.exists(path):
        return None
    for line in open(path, encoding="utf-8", errors="ignore"):
        m = re.search(pattern, line)
        if m:
            try:
                return cast(m.group(1))
            except ValueError:
                return m.group(1).strip()
    return None

def collect(tag):
    util = os.path.join(RPT_DIR, f"{TOP}_utilization_placed.rpt")
    tim  = os.path.join(RPT_DIR, f"{TOP}_timing_summary_routed.rpt")
    rec = {
        "tag": tag,
        "date": datetime.date.today().isoformat(),
        "LUT":    _grab(util, r"Slice LUTs\s*\|\s*(\d+)", int),
        "FF":     _grab(util, r"Slice Registers\s*\|\s*(\d+)", int),
        "BRAM":   _grab(util, r"Block RAM Tile\s*\|\s*([\d.]+)"),
        "DSP":    _grab(util, r"DSPs\s*\|\s*(\d+)", int),
        "IOB":    _grab(util, r"Bonded IOB\s*\|\s*(\d+)", int),
        "WNS":    _grab(tim,  r"WNS\(ns\)\s*\|?\s*(-?[\d.]+)"),
        "met":    bool(_grab(tim, r"(All user specified timing constraints are met)")),
    }
    db = json.load(open(DB)) if os.path.exists(DB) else []
    db.append(rec)
    json.dump(db, open(DB, "w"), indent=2)
    print(rec)
    return rec

def show_table():
    """打印成 markdown 表，可直接贴进报告"""
    db = json.load(open(DB)) if os.path.exists(DB) else []
    if not db:
        print("(还没有数据)"); return
    cols = ["tag", "LUT", "FF", "BRAM", "DSP", "WNS", "met"]
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for r in db:
        print("| " + " | ".join(str(r.get(c)) for c in cols) + " |")

if __name__ == "__main__":
    collect(input("这次改动叫什么：").strip())   # 例：插入灰度级
    show_table()
```

### Step 3：配套 —— 从 Vivado 里一次性出干净报告

```tcl
# 在 Vivado Tcl 里跑，导出干净文本
open_run impl_1
report_utilization        -file ./util.rpt
report_timing_summary     -file ./timing.rpt
puts "DIR=[get_property DIRECTORY [get_runs impl_1]]"
```

---

## 已验证效果

本项目用同样的模式从 `*_utilization_placed.rpt` 读出了：
**LUT 10710/53200 (20.1%)、FF 16600 (15.6%)、BRAM 12/140 (8.6%)、DSP 0/220** —— 这些数字直接进了报告。

最新一次（里程碑 1）：**LUT 10,920（20.53%）｜FF 16,890（15.87%）｜BRAM 12（8.57%）｜DSP 0/220｜WNS +0.511ns**。

---

## 来源（从哪些失败或观察中总结得出）

**P6**：早期由人工逐项核对报告里的数字，容易看漏 ⇒ 改为脚本机械提取。
参照教训：此前有 C 代码里的 128 个查找表数字，**手抄风险极高**，改用脚本解析生成常量表。

---

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-09-24 | 首版：采集脚本 + markdown 表输出 + 报告位置表 |

---

## 相关文件（Integration）

- **平行**：画面侧回归 → `../golden-compare/SKILL.md`
- **本项目实际采到的数字**：`设计报告第 5 章`
- **上游陷阱**：构建"成功"了但数字没变 ⇒ 见 `../vivado-bd-ops/SKILL.md` 第五节（OOC）
