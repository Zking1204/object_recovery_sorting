# Skill card: vivado-bd-ops

- **Name**: `vivado-bd-ops`
- **Description**: 需要用 Tcl 改 block design（加 IP、连线、改地址映射、重建）而不是手点时使用。
- **Scope**: 通用。
- **已验证效果**: BD 改动脚本化且幂等，重复执行不会产生重复连线，改完 validate 干净。
- **来源**: 手点改 BD 无法复现；且升级 IP 时会被已缓存的网表骗过，静默综合旧结果，导致"改了代码位流没变"。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
