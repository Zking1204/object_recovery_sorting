# 历史脚本（不要用于复现）

这三个脚本来自原始工程，里面**写死了原机器的绝对路径**（`D:/AMD/PROJECT/...`），
换一台机器必然失败。放在这里只为沿革参照，**复现时请用**：

| 历史脚本 | 现在用哪个替代 |
|---|---|
| `bd_step10_v14.tcl`（把 cnn_top v1.4 注册进工程） | 不需要 —— `src/ip_repo/cnn_top_1/` 里已经是 v1.4，`create_project.tcl` 注册 IP 仓库后即可被 BD 直接引用 |
| `bd_step11_build_v14.tcl`（综合 + 实现 + 出位流） | `build/bd/build_bitstream.tcl` |
| `ooc_syn.tcl`（HLS IP 的单独 OOC 综合） | 不需要 —— `launch_runs synth_1` 会自动先跑完 BD 里所有 IP 的 OOC 综合 |

复现入口只有两个：

```
build/bd/create_project.tcl     建工程 + 恢复 BD（+ 可选生成输出产物）
build/bd/build_bitstream.tcl    综合 + 实现 + 出位流
```

出完位流再跑 `build/deliver.py` 给 `.hwh` 打 FCLK0 补丁。