# Skill card: hls-accelerator-on-pl

- **Name**: `hls-accelerator-on-pl`
- **Description**: 要把神经网络或计算密集算子用 Vitis HLS 做成 PL 加速器、接进 block design 并上板时使用。
- **Scope**: 通用。换模型主要改并发度宏与权重，流程不变。
- **已验证效果**: 内核单次 9.15 ms，有效算力达到理论峰值的 52%，且模型更新后能在一轮构建内重新部署。
- **来源**: 早期逐字节读取权重导致迭代间隔 II=128，改用显式 64 位宽字读后降到 16，载入时间从 3.9 ms 降到 0.49 ms。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
