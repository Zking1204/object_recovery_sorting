# Skill card: memory-structure-timing

- **Name**: `memory-structure-timing`
- **Description**: 需要把权重或行缓冲放进片上 BRAM，并要判断该用什么存储结构、会不会掉时序时使用。
- **Scope**: 通用。
- **已验证效果**: 存储结构选型有判据：RAM_2P 还是 BRAM 绑定、分区因子取多少、会不会引入跨周期依赖。
- **来源**: 权重放不进 BRAM 时先怀疑容量不足，实际是访问模式与分区因子不匹配。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
