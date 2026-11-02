# Skill card: hwh-codegen

- **Name**: `hwh-codegen`
- **Description**: 拿到 .hwh 后需要自动生成主机侧的寄存器访问代码或测试骨架，避免手抄地址时使用。
- **Scope**: 通用。换任何 Zynq 工程都可用。
- **已验证效果**: 从 .hwh 直接产出偏移表与 Python 访问 stub，手抄导致的地址错位归零。
- **来源**: 手工维护的地址表多次与 block design 漂移，改完 BD 后忘了同步 PS 侧脚本，直到读回值对不上才发现。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
