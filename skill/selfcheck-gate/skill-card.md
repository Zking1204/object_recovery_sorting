# Skill card: selfcheck-gate

- **Name**: `selfcheck-gate`
- **Description**: 写完或改完 RTL，需要在综合之前判断"到底能不能放行"时使用。
- **Scope**: 通用。
- **已验证效果**: 编译通过 + 相关 testbench 全绿才放行综合，避免把逻辑 bug 带进二十分钟的构建。
- **来源**: 只编译通过就去综合，出问题后无法判断是逻辑错还是时序错，浪费整轮构建时间。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
