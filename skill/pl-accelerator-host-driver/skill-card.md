# Skill card: pl-accelerator-host-driver

- **Name**: `pl-accelerator-host-driver`
- **Description**: PL 加速器已综合进 block design，需要写 PS 侧驱动把它真正跑起来并做自检时使用。
- **Scope**: 通用。
- **已验证效果**: 驱动具备"写基地址、分配输入输出缓冲、触发与轮询、黄金自检"四段，任一段失败都能定位到具体环节。
- **来源**: 加速器曾出现"寄存器值都写对了但不启动"，靠把基地址回读、输入缓冲内容、自检结果三样一起打印，才把范围从整条链路收窄到单一寄存器。
- **Owner**: 本作品参赛队（按大赛要求匿名）
- **License**: MIT
- **Version**: 1.0.0（2026-11-01）
- **完整内容**: 见同目录 `SKILL.md`
