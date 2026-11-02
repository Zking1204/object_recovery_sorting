# Skill card: pynq-dma-cache

- **Name**: `pynq-dma-cache`
- **Description**: 用 VDMA 或 DMA 在 PL 与 PS 之间搬运图像数据，需要在读前写后处理 CPU 缓存，或已经读到"旧数据/假阴性"时使用。
- **Scope**: 通用。任何 PS 侧访问 DDR 帧缓冲的场景都适用。
- **已验证效果**: 正确使用 flush 与 invalidate 后，帧缓冲读写不再出现假阴性，配合寄存器回读可把"硬件没出数据"与"读到旧值"区分开。
- **来源**: 曾整帧读到上一帧内容，误判为硬件不出数据，实际是 CPU 缓存未失效。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
