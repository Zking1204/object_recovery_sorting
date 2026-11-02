# 技能包

本目录按 agent skill 的通用组织方式打包：**一个技能一个目录，目录内是 `SKILL.md`**。

`SKILL.md` 头部 frontmatter 的 `description` 写的是"**什么情况下该激活本技能**"，而不是"这个技能是什么"。这样它常驻上下文时开销很小，只有任务真正命中才加载正文；`scope` / `verified_effect` / `origin` 三个字段承担治理信息（换题是否仍可用、验证过什么、从哪个失败总结出来）。

每一项都写明五件事：**适用场景 · 使用方法 · 失效条件 · 已验证效果 · 来源（从哪些失败或观察中总结）**。
判断标准只有一条：**换一个题目、换一块板卡，它是否仍然成立**。不成立的属于项目文档，应当写进设计报告，不放进技能包。

---

## 怎么用

**作为 AI agent**：先读各技能 `SKILL.md` 的 `description`，命中当前任务时再读正文，按 `Workflow` 的编号步骤执行，每一步都给了判据；动手前先看 `When NOT to Use`（失效条件）确认自己不适用。

**作为工程人员**：先从下面的索引找到对口的一条，再读它的 `verified_effect` / `origin` 确认验证过什么、从什么故障里总结出来的，最后进正文看具体步骤。

---

## 一、PYNQ / PL 通用技能（8 个）

面向 PYNQ 框架与 PL 加速器，**不绑定具体题目**，换题目、换板卡仍可用。

| 技能 | 内容 | 对应官方加分方向 |
|---|---|---|
| [`pynq-overlay-regmap`](pynq-overlay-regmap/SKILL.md) | 加载 overlay 的三条硬约束 + 寄存器访问范式（`register_map` 优先、偏移必查头文件） | Overlay 加载与校验流程、寄存器映射与 `register_map` 范式 |
| [`pynq-dma-cache`](pynq-dma-cache/SKILL.md) | DMA 搬运与 CPU 缓存一致性（flush / invalidate 时机、读到旧值的判定） | DMA 搬运与缓存一致性封装 |
| [`hwh-codegen`](hwh-codegen/SKILL.md) | 从 `.hwh` 提取地址与连接关系，生成主机侧访问代码，替代手抄 | 从接口契约生成主机侧代码 |
| [`golden-compare`](golden-compare/SKILL.md) | 用黄金参考做逐值比对，把"看起来对"变成"逐字节相等" | 黄金参考比对 |
| [`util-timing-collect`](util-timing-collect/SKILL.md) | 从实现报告自动抽取资源与时序数据并生成可比对表格 | 性能与资源数据自动采集 |
| [`hls-accelerator-on-pl`](hls-accelerator-on-pl/SKILL.md) | 把 C++ 算子做成 Vitis HLS 加速器、接进 BD 并上板 | — |
| [`pl-accelerator-host-driver`](pl-accelerator-host-driver/SKILL.md) | PL 加速器的 PS 侧驱动结构、状态位语义与自检 | — |
| [`pynq-pitfalls`](pynq-pitfalls/SKILL.md) | PYNQ 常见故障的"现象 → 根因 → 处理"分流表 | — |

## 二、工程工作流技能（12 个）

与具体算法无关的方法论：提示词工作流、校验思路、踩坑清单。

| 技能 | 内容 |
|---|---|
| [`prompt-workflows`](prompt-workflows/SKILL.md) | 稳定产出结果的提问模板（软硬件划分推导、瓶颈定位、时序反推） |
| [`change-proposal`](change-proposal/SKILL.md) | 改动已验证工程前的方案书：改什么、影响谁、怎么回退 |
| [`constraint-engineering`](constraint-engineering/SKILL.md) | 与 AI 协作时如何把约束条件写清楚（有效约束与反模式） |
| [`selfcheck-gate`](selfcheck-gate/SKILL.md) | 综合前的放行门禁：编译通过 + 相关 testbench 全绿才算过 |
| [`verification-methods`](verification-methods/SKILL.md) | 每类模块该用什么判据去验，以及哪些做法属于自证其说 |
| [`testbench-guide`](testbench-guide/SKILL.md) | 写 / 改 testbench，以及"失败到底是 DUT 错还是测试错"的判别 |
| [`onboard-verification`](onboard-verification/SKILL.md) | 上板验证的步骤顺序、每步判据与失败分流 |
| [`vivado-bd-ops`](vivado-bd-ops/SKILL.md) | 用 Tcl 改 block design：幂等操作、IP 升级与端口表缓存的陷阱 |
| [`hdl-module-split`](hdl-module-split/SKILL.md) | 把算法拆成可单独仿真、级间只靠寄存器隔断的模块 |
| [`memory-structure-timing`](memory-structure-timing/SKILL.md) | 大数组进 BRAM 的存储结构选型（RAM_2P / 分区因子 / 时序） |
| [`timing-report-reading`](timing-report-reading/SKILL.md) | 分辨真违例与虚约束，定位到逻辑级数还是布线延迟 |
| [`pl-osd-overlay`](pl-osd-overlay/SKILL.md) | 在 PL 里往实时视频流叠加图形，做到不闪、不抢带宽 |

## 三、本作品提炼技能（1 个）

| 技能 | 内容 |
|---|---|
| [`cnn-on-pl`](cnn-on-pl/SKILL.md) | 量化 int8 神经网络从 TFLite 部署到 PL，并与训练端预处理逐位对齐 |

---

## 收录标准

一条经验要进这里，必须同时满足三条：

1. **换题目或换板卡仍然成立**——否则它是项目文档，应写进设计报告；
2. **能落到一个具体的失败或观察**——写不出来源的直觉经验不收；
3. **有可判定的效果**——要么带量化数字，要么带明确判据。

题目专属的常量（阈值、时序参数、地址表、模型参数）不进技能包，它们放在 `src/ps/`、`src/hls/`
与设计报告的附录里。技能包一旦掺进项目参数，可复用性就不成立了。
