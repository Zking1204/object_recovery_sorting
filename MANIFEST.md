# 包完整性校验记录

本文件是"**先逐个读源码确认无误再归档**"这一要求的证据，也是重建者在出问题时的第一份对照基准。

- **校验时间**：2026-11-02
- **包根**：`object_recovery_sorting/`
- **规模**：281 个文件 / 约 15.3 MB（RAR 上传口上限 200 MB）
- **校验方法**：逐文件取原文与归档副本做**逐字节/逐行比对**（`Get-FileHash` 与按行数组比对），不是抽查。

---

## 一、归档一致性

| # | 检查项 | 方法 | 结果 |
|---|---|---|---|
| A | `src/rtl/` 16 个 `.v` | 归档内容**以工程内原件结尾**（只前置了一段文件头注释，正文零改动） | **16 / 16 通过** |
| B | `src/ps/` 11 个 `.py` | 尾部与原件逐行比对 | **11 / 11 通过**（其中 `tflite_infer.py` 恰好 1 行差异，见 §三） |
| C | `src/ps/tools/` 4 个 `.py` | 同上 | **4 / 4 通过** |
| D | `sim/` 15 个 testbench + `report/design_report.md` | 与原件逐字节比对（`tb_dd_gray.v` **只在文件头增补了状态说明注释**、`report/design_report.md` 随后续修订更新） | **通过**（正文零改动） |
| E | `src/ip_repo/` 4 个第三方 IP，共 148 个文件 | 递归比对**相对路径 + 每文件哈希** | **缺 0 / 多 0 / 哈希不一致 0** |
| F | 二进制与脚本 36 项（位流、`.hwh`、模型 bin、tflite、`.bd`、`.bda`、`top.xdc`、`deliver.py`、HLS 源、构建脚本、C 仿真黄金张量等） | `Get-FileHash` 逐项比对 | **36 / 36 逐字节一致** |

第三方 IP 明细：

| IP 目录 | 源文件数 | 归档数 | 缺失 | 多余 | 哈希不一致 |
|---|---|---|---|---|---|
| `axi_dynclk_v1_0` | 18 | 18 | 0 | 0 | 0 |
| `cnn_top_1` | 118 | 118 | 0 | 0 | 0 |
| `DVI_TX` | 9 | 9 | 0 | 0 | 0 |
| `ov5640_cap_data` | 3 | 3 | 0 | 0 | 0 |

---

## 二、关键产物 MD5（重建后应与本表一致）

| 文件 | MD5 | 大小 |
|---|---|---|
| `board/design_1_wrapper.bit` | `18A17B7ACB637FCDA315110B970B84B9` | 4 045 771 B |
| `board/design_1_wrapper.hwh` | `0BF805BFBACEAA773EAA4D3E7E603916` | 749 391 B |
| `build/bd/design_1.bd` | `C25C6297BBA0BD4E3D1AED292AA5333D` | 151 222 B |
| `build/bd/design_1.bda` | `30ACDA7DF911F4AB06DB6940ED507724` | 15 980 B |
| `build/constraints/top.xdc` | `E0C9E7AC8854BFEF736F0F969073436B` | 7 016 B |
| `data/model_blob.bin` | `07AE3FEF9E6E9CC3D1E36E7A8BA1655F` | 390 912 B |

> 重建出的 `.bit` 与上表**只有 8 个字节不同**——就是头部记录的编译日期与时间（详见 §5.3）。其余逐字节相同，这是本包可复现性的最强证据。`.hwh` 在打了 FCLK0 补丁后与上表**参数项 100% 一致**（2254 项零差异，见 §5.2）。

---

## 三、归档时做过的实质改动（共五处 + 一次目录整理）

| 文件 | 改动 | 原因 |
|---|---|---|
| `src/ps/tflite_infer.py` | `SIZE = 42` → `SIZE = 64` | 工程内这份是旧值；`cnn_pl_infer.py` 有硬门禁 `if int(ti.SIZE) != 64: raise RuntimeError(...)`。若把 42 的版本传上板，按"② 加载识别"按钮会当场抛错。64 与 `model_int8_64.tflite` 及板上那份一致 |
| `src/ps/cam_full.py` | **一行注释**：`跑 D:\AMD\PROJECT\k_deliver.py` → `跑提交包里的 build/deliver.py` | 那条注释是"黑屏排查"的指路牌，指向别人机器上不存在的路径等于没指。逻辑零改动 |
| `src/hls/tb_cnn.cpp` | `DATADIR` 默认值从原机器绝对路径改为相对 `../../../data/csim`，并注明可用 `-DDATADIR=` 覆盖 | C 仿真要读 `data/csim/` 里的黄金张量；写死绝对路径别人跑不了 |
| `src/rtl/` 下 8 个 `.v` 的**注释文字** | 把「玻璃 / 缺陷 / 划痕 / 裂痕 / 污渍 / 气泡」等历史词汇替换为中性表述（目标 / 定位流水线 / 细线 / 斑块 / 大面积区域…），约 120 处 | 本作品最终定位是物品回收分拣。**只动注释、不动任何一行有效代码** |

**目录整理**：原工程的三个历史脚本（`bd_step10_v14.tcl`、`bd_step11_build_v14.tcl`、`ooc_syn.tcl`）
含写死的原机器绝对路径，**已从提交包中移除、不随包分发**；同样的整理还包括旧版约束快照
`new_top_pz2.xdc`。本包只保留构建实际使用的 `build/bd/*.tcl` 与 `build/constraints/top.xdc`。
另修复了 `data/dump_tflite.py`、`sim/tools/test_track.py`、`sim/run_all.ps1` 与
`skill/util-timing-collect/SKILL.md` 里的写死路径（改成按文件位置推算 / 占位符 / 自动探测）。

**注释改动的验证方式（双重）**：

1. 用 Vivado 的 `xvlog` 编译 `src/rtl/` 全部 16 个文件 → **0 error / 0 warning**，注释替换没破坏任何语法；
2. **剥离所有注释后逐行比对**归档副本与工程原件 → **0 个文件存在有效代码差异**。

即：改动只落在注释文字上，可综合的代码与原件完全一致。

`src/rtl/`（除注释外）与 `src/ps/` 其余文件**只在文件头追加了注释块**，有效代码一行未动——
检查项 A/B 证明的就是这一点（在注释中和**之前**做的比对）。

---

## 四、内部引用完整性

| # | 检查项 | 结果 |
|---|---|---|
| G1 | `board/upload_list.md` 列出的 **19 个必需文件**是否都在包里 | **19 / 19 存在** |
| G2 | `sim/run_all.ps1` 引用的 **13 个 RTL 源**是否都在 `src/rtl/` | **13 / 13 存在** |
| G3 | 根 `README.md` 引用的 **28 个路径**是否存在 | **28 / 28 存在** |
| G4 | 全包文件名/目录名是否为纯 ASCII（字母数字 `.` `_` `-`），无空格、无中文 | **全部合规** |
| G5 | `skill/` 下 **22 个技能**是否都含 `SKILL.md` 与 `skill-card.md` | **22 / 22 齐全** |

---

## 五、端到端重建实测记录（2026-11-01 完成）

用本包的复现脚本、在**一个全新的空工程**里从零重建，不参考任何原有的 `.xpr` / `.runs` / `.cache`。

执行方式（命令见根 `README.md` §3.3）：

```bat
set OBJRS_PROJ_DIR=D:\_rebuild_test
vivado.bat -mode batch -notrace -nojournal -log build.log -source <本包>\build\bd\create_project.tcl
```

**结果：退出码 0，`ERROR` 计数 0，`CRITICAL WARNING` 计数 0。**

| 阶段 | 输出 |
|---|---|
| IP 仓库注册 | 需求方 IP 仓库加载成功；`alientek.com:user:ov5640_capture_data:1.0`、`openedv.com:user:DVI_Transmitter:1.0`、`digilentinc.com:ip:axi_dynclk:1.0`、`xilinx.com:hls:cnn_top:1.4` —— **四个全部找到** |
| RTL | 加入 16 个源文件 |
| 约束 | 加入 `top.xdc` |
| BD 恢复 | `Successfully read diagram <design_1>`；`Design successfully migrated to use XCI files` |
| BD 校验 | **单元数 20**、**地址段数 23**、**`validate_bd_design` 通过** |
| wrapper | 生成并导入到 `sources_1/imports/hdl/design_1_wrapper.v`，设为顶层 |
| 结束 | 打印 `工程重建完成` |

产物核对：`objrs.xpr` 生成；`design_1.bd`(151 249 B) 与 `design_1.bda`(15 980 B) 就位；16 个 RTL 与 `top.xdc` 以 **`$PPRDIR/../../…` 相对路径**登记在工程里（换机器只要保持相对位置即可）；重建工程共 24.9 MB。

> 首次尝试失败过一次：`make_wrapper -fileset sources_1 -top design_1` 在 2026.1 报
> `ERROR: [Common 17-161] Invalid option value 'design_1' specified for 'files'` —— 新版签名里
> `-top` 是**开关**（不带值），文件是位置参数。已改为
> `make_wrapper -top -files [get_files design_1.bd] -import -force`，坑也写进了 `create_project.tcl` 的注释。

### 5.1 进一步：连 IP 输出产物一起生成（`OBJRS_GENERATE=1`）

第二次跑加上 `OBJRS_GENERATE=1`，让它执行 `generate_target all`：

| 项 | 结果 |
|---|---|
| 退出码 / 耗时 | **0** / 约 1.4 分钟 |
| ERROR / CRITICAL WARNING | **0 / 0** |
| IP 输出产物 | **22 个 IP 全部生成**，每个都有 HDL 产物（`*.v`/`*.vhd`）：包括 3 个第三方 IP（`DVI_Transmitter`、`ov5640_capture_data`、`axi_dynclk`）与自研 `cnn_top` —— **这就是"第三方 IP 源码确实完整"的证据** |
| BD 产物 | `synth/design_1.v`（143 722 B）、`synth/design_1.hwdef`、`sim/design_1.v`、**`hw_handoff/design_1.hwh`**（新生成的） |

> **产物落点说明**：新工程里这些输出跑到 `ov5640_hdmi_fd.gen/`（而不是 `objrs.gen/`）——因为 `.bd` 文件里内嵌了原工程名。这是**正常现象**，不影响构建，也不影响 PYNQ；重建者看到不必惊疑。

### 5.2 `.hwh` 补丁的实证比对（本包最关键的一条结论）

拿上面**新生成的** `design_1.hwh` 做三件事：

1. 读它的 `FCLK0` 分频：`PCW_FCLK0_PERIPHERAL_DIVISOR0 = 4`、`DIVISOR1 = 4` ⇒ **重建出来的 hwh 果然是 4/4**，直接坐实了"不打补丁 PL 只跑 62.5 MHz、屏幕全黑"这条坑；
2. 按 `build/deliver.py` 的规则打补丁（`4→10`、`4→1`），两处各命中 **1 处**；
3. 与 `board/design_1_wrapper.hwh`（实测可用的那一份）逐项比对：

| 比对项 | 结果 |
|---|---|
| `PARAMETER` 条目数 | 2254 / 2254 |
| **参数值不同的个数** | **0** |
| 缺失 / 多余参数 | 0 / 0 |
| 总行数 | 12 883 / 12 883 |
| 内容不同的行 | **仅 3 行** |

那 3 行是：

| 行 | 重建 | 交付 | 性质 |
|---|---|---|---|
| L2 | `TIMESTAMP="Sun Nov 1 17:01:40 2026"` | `TIMESTAMP="Wed Oct 28 12:13:39 2026"` | 时间戳 |
| L7356 | `Component_Name = design_1_cnn_top_0_0` | `…_0_3` | IP 实例容器名（原工程重复加过 3 次，重建时重新从 0 编号） |
| L8077 | `Component_Name = design_1_glass_defect_core_0_0` | `…_0_2` | 同上 |

**含义**：重建出的硬件与交付的硬件在**全部 2254 个参数、全部地址映射、全部模块名上完全一致**，差异只在时间戳与两个内部实例容器名（PYNQ 的 `Overlay` 按模块名与地址段建 `ip_dict`，不读 `Component_Name`，因此不影响上板）。

> 顺带修正了一处保真度问题：原工程的工程属性里设了板卡定义 `tul.com.tw:pynq-z2:part0:1.0`，它会被写进 `.hwh` 的 `<SYSTEMINFO BOARD=…>`。第一次重建没设，导致该属性缺失；现已补进 `create_project.tcl`（**装了该板卡就设、没装就跳过并提示**，不影响建工程）。

### 5.3 顶层综合、实现与出位流（已完成）

用本包的 `build/bd/build_bitstream.tcl` 在同一工程上继续跑（**必须走 `launch_runs` 的 run 流程**，原因见该脚本头部注释）：

| 项 | 结果 |
|---|---|
| 退出码 / 耗时 | **0** / **40.8 分钟** |
| ERROR / CRITICAL WARNING | **0 / 0** |
| `synth_1` / `impl_1` | PROGRESS 均 **100%** |
| 位流 | **4 045 771 B** —— 与交付版字节数完全相同 |

与 `board/` + `build/report/` 里的交付产物逐项比对：

| 项 | 重建版 | 交付版 | 一致 |
|---|---|---|---|
| Slice LUTs | 38 726（72.79%） | 38 726（72.79%） | ✅ |
| LUT as Logic / Memory | 36 589 / 2 137 | 36 589 / 2 137 | ✅ |
| LUT as Distributed RAM / Shift Reg | 850 / 1 287 | 850 / 1 287 | ✅ |
| Block RAM Tile | 67.5（48.21%） | 67.5（48.21%） | ✅ |
| DSPs | 93（42.27%） | 93（42.27%） | ✅ |
| WNS / WHS | +0.271 / +0.050 ns | +0.271 / +0.050 ns | ✅ |
| TNS / THS | 0.000 / 0.000 | 0.000 / 0.000 | ✅ |
| 违例端点 | 0 | 0 | ✅ |
| 时序总端点 | 114 491 / 114 364 | 114 491 / 114 364 | ✅ |
| 位流大小 | 4 045 771 B | 4 045 771 B | ✅ |
| 位流 MD5 | `AC48B2E504B0BFF96110D130DB97E6AF` | `18A17B7ACB637FCDA315110B970B84B9` | 不同（见下） |

**位流差异只有 8 个字节**，位置 `0xB9`–`0xC8`，是 Xilinx 位流头部记录的**编译日期与时间**：

| | 日期字段 | 时间字段 |
|---|---|---|
| 重建版 | `2026/11/01` | `17:50:17` |
| 交付版 | `2026/10/30` | `16:15:38` |

其余 **4 045 763 字节逐字节相同**。

> **结论**：本包的源码与脚本能完整重建出与交付版**等价**的位流 —— 不是"能编译通过"，而是"综合实现结果逐项复现、位流除时间戳外逐字节相同"。

> **踩过的一个坑（写进脚本注释了）**：一开始图省事用内存流程（打开工程后直接 `synth_design`），报
> `ERROR: [Synth 8-439] module 'design_1_DVI_Transmitter_0_0' not found`。原因是 **BD 里每个 IP 都要先各自做一次 OOC 综合产出 `.dcp`**，内存流程不会做这一步。必须用 `launch_runs`，它会先把这些 IP 的 OOC 综合跑完。

### 5.4 独立环境复现验证（仅依据 README §3.1、仅使用包内文件）

在不借助任何包外材料的前提下，**只按 README §3.1 的步骤顺序、只用包里的文件**，在一个全新目录中完整执行一遍。

| 步 | 结果 |
|---|---|
| 1 建工程 | 退出码 0、0 ERROR / 0 CRITICAL、**1.56 分钟**；`CHECK bd_cells = 20`、`addr_segs = 23`、`validate = PASS`、`top = design_1_wrapper`、`REBUILD_DONE` |
| 2 综合实现 | 退出码 0、0 ERROR / 0 CRITICAL、**40.3 分钟**；`synth_1` 与 `impl_1` 均 100%；**WNS +0.271 / WHS +0.050** |
| 3 交付补丁 | 退出码 0；自动定位到 hwh 与位流；两处补丁各 `hits=1`；复核 10/1 通过；产物 **bit 4 045 771 B + hwh 749 391 B** |
| 4 上板 | 未做（需要硬件） |

本次产物与交付产物的逐字节比对：

| 文件 | 大小 | 不同字节 | 首个差异位置 |
|---|---|---|---|
| `design_1_wrapper.bit` | 4 045 771 / 4 045 771 | **7** | `0xB9`（编译时间戳） |
| `design_1_wrapper.hwh` | 749 391 / 749 391 | **14** | `0x62`（`TIMESTAMP` + 两个 `Component_Name`） |

**本轮验证中发现并修正的 4 个兼容性问题**（只在完全不借助包外材料时才会暴露）：

| # | 问题 | 修法 |
|---|---|---|
| 1 | README 原来让人 `source bd_step11_build_v14.tcl`，而该脚本写死了 `D:/AMD/PROJECT/video_fd_pz2/ov5640_hdmi_fd.xpr`，**别人跑必失败** | 改成 `build_bitstream.tcl`；`bd_step10/11` 降级标注为"历史脚本，复现不要用" |
| 2 | `build/deliver.py` 其实是原工程的 `k_deliver.py`，写死 `D:\AMD\PROJECT\...` 与 `D:\AMD\bitstream\...`，**别人第一步就 ABORT** | 重写为包内相对路径：递归找 `**/hw_handoff/design_1.hwh`、位流优先 `_bit/` 其次 `runs/impl_1/`；新增 `--proj-dir / --out / --hwh / --bit` 参数；补丁后加一道复核 |
| 3 | 判据全是中文，而 Vivado 日志**混合 UTF-8（Tcl puts）与 ANSI/GBK（Vivado 消息）**，任何单一编码读都有一半乱码，**判据根本 grep 不到** | 脚本追加一组纯 ASCII 的 `CHECK ...` 行；README 判据同步换成 ASCII，并注明别拿中文 grep |
| 4 | README 没有"按报错查"的入口，几个坑（`Synth 8-439`、`Common 17-161`、`$(...)`）只能翻正文 | 新增 §3.6 复现常见问题表（12 条） |

### 5.5 第二轮独立复现验证（修正路径依赖之后）

在第一轮验证之后又增加了一次静态检查：在包根执行
`findstr /S /I /C:"D:\AMD" /C:"C:/AMD" /C:"C:\Users"`，扫出 **31 处**本机路径。

| 类别 | 处理 |
|---|---|
| **必须修（8 处）** | `data/dump_tflite.py` 默认输入参数、`src/hls/tb_cnn.cpp` 的 `DATADIR`、`sim/tools/test_track.py` 的 `sys.path`、`sim/run_all.ps1` 的 Vivado 默认路径、`src/ps/cam_full.py` 里一条指错的注释、`skill/util-timing-collect/SKILL.md` 的两处示例路径、`sim/tb_dd_gray.v` 与 `sim/tb_dd_thresh.v` 文件头里指向原工程的运行方式 —— 全部改为**按文件位置推算 / 占位符 / 自动探测 / 指向 `sim/README.md`** |
| **移除（3 个）** | `bd_step10_v14.tcl`、`bd_step11_build_v14.tcl`、`ooc_syn.tcl` 三个原工程历史脚本**已从包中移除、不随包分发**（功能由 `create_project.tcl` + `build_bitstream.tcl` 取代） |
| **保留（6 处）** | `build/report/*.rpt` 头部 `Command :` 行 —— 这是**实现报告原件**，路径本身就是证据，不改 |

修正后再按 README §3.1 完整执行一遍：

| 步 | 结果 |
|---|---|
| 1 建工程 | 退出码 0、**1.46 分钟**；`CHECK` 判据全部通过（bd_cells=20 / addr_segs=23 / validate=PASS / top=design_1_wrapper / REBUILD_DONE） |
| 2 综合实现 | 退出码 0、**0 ERROR / 0 CRITICAL**、**45.1 分钟**；synth/impl 均 100%；**WNS +0.271 / WHS +0.050** |
| 3 交付补丁 | 退出码 0；自动定位文件；两处补丁各 `hits=1`；复核 10/1 通过；`DELIVER_OK` |

比对结果：

| 项 | 结果 |
|---|---|
| 重建出的 hwh（**未打补丁**）的 FCLK0 分频 | `DIVISOR0 = 4`、`DIVISOR1 = 4` —— 再次证实补丁不可省 |
| 本次重建位流 vs 交付位流 | 同样 4 045 771 B，**不同字节 8**（首个 `0xB9`，编译时间戳） |
| 本次重建 hwh vs 交付 hwh | 同样 749 391 B，**不同字节 15**（`0x62` 起，时间戳 + 两个 `Component_Name`） |
| hwh 参数级比对 | **2254 / 2254 条，值不同 0 处** |

> 这一轮的结论：**在只读文档、只用包内文件的前提下，从零能重建出与交付版等价的位流与硬件描述。**
> 清完写死路径后再扫一遍，`*.tcl / *.py / *.ps1 / *.v / *.cpp` 中已无原机器路径残留（历史脚本与旧约束快照已移出本包）。

---

## 六、其余尚未做的验证（如实列出）

| 项 | 现状 | 影响 |
|---|---|---|
| `sim/run_all.ps1` 实跑 | 脚本引用的源文件与 TB 全部存在（G2 已证），但未在干净环境里跑过一遍 | 若个别 TB 因缺少超时保护而挂住，见 `sim/README.md` §六 |
| 跨机解压验证 | 未做 | 建议用一台**从未打开过本工程**的机器解压后走一遍"上电 → 出画面" |

---

## 七、打包可行性测试

用 ZIP 无损压缩整包做一次预演（RAR 的压缩率与它同数量级）：

| 项 | 结果 |
|---|---|
| 原始体积 | 约 15.3 MB（281 个文件） |
| 压缩后 | **6.07 MB**（压缩率 39.6%），耗时 6.7 秒 |
| RAR 上传口上限 | 200 MB ⇒ **余量约 33 倍** |
| 最长内部路径 | 156 字符（`src/ip_repo/cnn_top_1/hdl/verilog/…`），在 Windows `MAX_PATH`(260) 内 |
| 路径字符 | 全 ASCII、无空格、无中文（检查项 G4 已证） |

本机未安装 WinRAR / 7-Zip，因此**没有生成 `.rar`**。提交时在资源管理器里右键 `object_recovery_sorting`
→「添加到压缩文件」→ 选 RAR 即可，参数用默认值。测试用的 ZIP 已删除，提交目录内不留压缩件。

---

## 八、校验环境

| 项 | 值 |
|---|---|
| 目标器件 | `xc7z020clg400-1`（PYNQ-Z2，Zynq-7000） |
| 综合实现工具 | Vivado / Vitis **2026.1** |
| 板端环境 | PYNQ **3.0.1** / Python **3.10.4** / armv7l |
| 实现结果 | WNS **+0.271 ns**、WHS +0.050 ns、TNS 0；LUT 38 726（72.79%）、FF 41 248（38.77%）、BRAM 67.5（48.21%）、DSP 93（42.27%） |
| 报告原件 | `build/report/impl_util_v14.rpt`、`impl_timing_v14.rpt` |
