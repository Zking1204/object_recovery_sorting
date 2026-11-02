# Skill card: hdl-module-split

- **Name**: `hdl-module-split`
- **Description**: 要把一个算法拆成可维护的多个 Verilog 模块，并划清各级接口与延迟预算时使用。
- **Scope**: 通用。
- **已验证效果**: 每个模块自洽、可单独仿真，级间只靠寄存器隔断，时序不随级数累积恶化。
- **来源**: 单文件巨型 always 块让时序与调试都无法收敛，拆分后同样的逻辑面积更小且可逐级验证。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
