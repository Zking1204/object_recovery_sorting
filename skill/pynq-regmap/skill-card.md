# Skill card: pynq-regmap

- **Name**: `pynq-regmap`
- **Description**: 需要用 PYNQ 的 register_map 或 MMIO 访问自研 AXI-Lite 从设备，或需要一份与 RTL 一致的寄存器偏移表时使用。
- **Scope**: 通用。
- **已验证效果**: 寄存器偏移一次对齐，PS 侧脚本与 RTL 不会各自漂移。
- **来源**: 自研检测核的寄存器索引只有 7 位、空间写满后，新外设被迫改为独立 AXI-Lite 从设备，由此固化出"每设备 64 KB 地址窗、不复用现有核"的地址规划规则。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
