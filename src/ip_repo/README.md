# 第三方 IP 源码说明

BD 里有 4 个 IP **不在 Vivado 安装目录里**，它们只存在于本包的 `src/ip_repo/`。
**缺任何一个，`design_1.bd` 都重建不出来**（对应 cell 会变红）。

`create_project.tcl` 会把本目录整体注册成 IP 仓库（`ip_repo_paths`），Vivado 靠每个子目录里的
`component.xml` 把它们认成 IP。目录名本身不参与识别，VLNV 由 `component.xml` 决定。

---

## 目录与 BD 单元的对应关系

| 目录 | BD 中的 cell | VLNV（必须与 BD 里的完全一致） | 作用 |
|---|---|---|---|
| `ov5640_cap_data/` | `ov5640_capture_data_0` | `alientek.com:user:ov5640_capture_data:1.0` | OV5640 并口（DVP 8 bit×2）→ RGB888，每 2 个 PCLK 出 1 像素；输出 `frame_clk` / `frame_ce` 直接驱动下游 |
| `DVI_TX/` | `DVI_Transmitter_0` | `openedv.com:user:DVI_Transmitter:1.0` | DVI/TMDS 发送；`pclk` 与 `pclk_x5` 由 `axi_dynclk` 提供，`reset_n` 接 MMCM 的 `LOCKED_O` |
| `axi_dynclk_v1_0/` | `axi_dynclk_0` | `digilentinc.com:ip:axi_dynclk:1.0` | 运行时通过 DRP 重配 MMCM，产生 74.2857 MHz 像素时钟（74.25 MHz 无法由 MMCM 精确合成） |
| `cnn_top_1/` | `cnn_top_0` | `xilinx.com:hls:cnn_top:1.4` | 本工程用 Vitis HLS 生成的 int8 CNN 加速器 **v1.4**；源在 `../hls/` |

> `cnn_top_1` 目录名里的 `_1` 是历史遗留（早先还有一个同样叫 `cnn_top` 的 v1.3 目录）。**里面装的就是 v1.4**，不要按目录名判断版本，以 `component.xml` 里的 `ip.version` 为准。

---

## 三个容易踩碎的细节

### 1. `DVI_TX` 的 `component.xml` 嵌在子目录里

结构是：

```
DVI_TX/
├── if/
│   ├── TMDS.xml          ← 自定义总线定义，必需
│   └── TMDS_rtl.xml      ← 自定义总线定义，必需
└── ip/
    ├── component.xml     ← IP 定义（注意：不在 DVI_TX/ 根目录）
    └── src/
        ├── dvi_transmitter_top.v
        ├── dvi_encoder.v
        ├── serializer_10_to_1.v
        └── asyn_rst_syn.v
```

**必须整目录原样拷贝**。只取 `ip/src/*.v` 而不带 `if/*.xml`，BD 打开时该 cell 的端口会全部对不上。

### 2. `ov5640_cap_data` 与板子的实际接线不一致

这个 IP 内部按它自己的引脚顺序处理数据，但**本设计的转接板是跨排对接的**（主排 pad 1–6 ↔ 转接板 7–12），数据位是相邻互换的。真正的引脚映射写在 `build/constraints/top.xdc` 里，**不要照抄该 IP 文档里的示例 XDC**。

同样，**XCLK 必须由 FPGA 提供 24 MHz**（模组侧无晶振），由 `clk_wiz_xclk` 产生。IP 自身不产生时钟。

### 3. `axi_dynclk` 的 MMCM 配置是运行时给的

它上电后的默认配置不能用，必须由 PS 侧按查找表写入：

- 像素时钟 74.2857 MHz：`src/ps/pz2_video.py` + `src/ps/dynclk_tables.py`
- 5 倍频 `PXL_CLK_5X_O` ≈ 371.43 MHz 供 DVI 发送器

只烧位流不做这一步，显示器会没有信号。

---

## `cnn_top_1` 的两种获得方式

| 方式 | 做法 | 适用 |
|---|---|---|
| **直接用（推荐）** | 用本目录下已打包好的 v1.4 IP | 不改算法，只想重建位流 |
| 从源码重新生成 | 见根 `README.md` §3.2，跑 `vitis-run` / `v++` 三个命令 | 改了 `../hls/cnn_accel.cpp` |

重新生成后必须 `update_ip_catalog -add_ip <zip> -repo_path <本目录>` 注册，并且**同时把 `hls.cfg` 里的 `package.ip.version` 抬号**。同一个 VLNV 重新加 zip，Vivado 会锁住已缓存的网表并静默综合旧结果——现象是改了代码、位流却一点没变。
