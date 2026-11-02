# 第三方组件声明

本仓库的 `LICENSE` 采用 **MIT**，覆盖本项目自行编写的部分：RTL 定位链、HLS 加速器、PS 侧脚本、构建与复现脚本，以及全部文档。

`src/ip_repo/` 下的下列 IP 以**源码形式**随仓库分发。分发目的是让本作品的 Vivado 块设计能够被完整重建——缺少这些目录，`build/bd/create_project.tcl` 无法恢复块设计。它们各自保留其 `component.xml` 与源文件头部所声明的原始条款：

| 目录 | 内容 |
|---|---|
| `src/ip_repo/ov5640_cap_data` | 摄像头并行总线采集 IP |
| `src/ip_repo/DVI_TX` | TMDS / DVI 发送 IP |
| `src/ip_repo/axi_dynclk_v1_0` | 动态可重配像素时钟 IP |
| `src/ip_repo/cnn_top_1` | 由本项目 HLS 源码（`src/hls/`）生成的加速器 IP，属本项目产出 |

块设计中使用的 Xilinx / AMD LogiCORE IP（`axi_vdma`、`v_tc`、`v_axi4s_vid_out`、`v_vid_in_axi4s`、`axis_broadcaster`、`clk_wiz`、`processing_system7`、`proc_sys_reset`、`smartconnect`、`axi_interconnect`、`xlconstant`）**不在本仓库内再分发**：它们属于 Vivado 安装的一部分，构建时由块设计按其配置重新生成。

若上述第三方源码的权利人对再分发有异议，请通过本仓库的 issue 说明，我们会移除对应目录。
