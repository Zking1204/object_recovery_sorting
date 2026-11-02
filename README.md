# 物品回收智能分拣系统 · 代码提交包

> **器件**：AMD Zynq-7000 XC7Z020（PYNQ-Z2，`xc7z020clg400-1`）
> **工具链**：Vivado / Vitis **2026.1**；板端 PYNQ **3.0.1** / Python **3.10.4**（armv7l）
> **说明**：按大赛要求匿名提交，本包不含任何身份标识信息。

---

## 0 这个包是什么

一块 PYNQ-Z2 完成端到端闭环：

```
OV5640 ─► PL：背景差分定位（14 拍流水线）─► 掩膜
             └─► PL：int8 CNN 识别（HLS 加速器）
                     └─► PS：连通域 / 裁 ROI / 跨帧跟踪计数 / OSD 下发 / 舵机分派
                                          └─► PL：OSD 叠加（显示通路内，零闪）
                                          └─► PL：三路 SG90 PWM（按过线时刻拍飞）
```

- **PL 做逐像素、代价恒定的运算**（定位流水线 + 神经网络推理）。
- **PS 做整帧视野、跨帧记忆、随机访问的事**（连通域、跟踪、计数、绘制、分派）。
- 视频流全程在 PL 内以 AXI4-Stream 流水，识别结果叠加在**显示通路**（VDMA 读出之后、时序生成之前），因此叠加不打断也不拖慢采集与识别。

实测：定位 24.1 ms/帧，CNN 内核 9.15 ms，单次识别全程 16.8 ms，整链循环 32.4 Hz，WNS +0.271 ns。

---

## 1 目录结构

| 目录 | 内容 |
|---|---|
| `README.md` | 本文件：总入口、两条使用路径、陷阱清单、验收判据 |
| `MANIFEST.md` | **包完整性校验记录**：逐文件比对结果、关键产物 MD5、归档时做过的改动、尚未做的验证 |
| `src/rtl/` | 自研 Verilog 定位链与两个 BD 顶层（16 个 `.v`）+ `README.md` 模块索引与行为约束 |
| `src/hls/` | **Vitis HLS 侧全部源码**：`cnn_accel.cpp`（核实现）、`tb_cnn.cpp`（C 仿真测试台）、`model_meta.h`（量化参数）、`hls.cfg`（综合配置，唯一入口） |
| `src/ps/` | 板端 Python（11 个生产必需 + `tools/` 下 4 个验证脚本） |
| `src/ip_repo/` | **第三方 IP 源码**（BD 重建必需，共 4 个） |
| `sim/` | 各级 testbench（Verilog / SystemVerilog）与批量跑法 |
| `build/bd/` | **复现入口**：`create_project.tcl`（建工程 + 恢复 BD）、`build_bitstream.tcl`（综合 + 实现 + 出位流）、`design_1.bd` / `.bda` |
| `build/constraints/` | 实际使用的引脚与时序约束 `top.xdc`（`history/` 下是旧的快照，勿用） |
| `build/report/` | 利用率 / 时序 / 方法学 / DRC 报告（原件，头部 `Command :` 行带着原机器路径，属证据） |
| `build/deliver.py` | 交付脚本：自动找位流与 hwh → **给 `.hwh` 打 FCLK0 分频补丁** → 整理上板文件（漏跑会黑屏，见 §3.5） |
| `build/history/` | 原工程的历史脚本，**写死了原机器绝对路径、复现不要用**（见该目录 README） |
| `board/` | 位流、`.hwh`、上传清单、板端运行记录、tflite 运行时 wheel |
| `data/` | 模型权重 bin、量化 tflite、黄金参考、PC 端生成脚本 |
| `skill/` | 技能包（可复用的工程经验，见 `skill/README.md`） |
| `report/` | 设计报告源文件（`design_report.md`）、**大模型协作详细记录**（`ai_collaboration.md`）与全部矢量插图 |

---

## 2 路径 A：把板子跑起来（不重建位流）

用 `board/` 里已验证的位流，10 分钟内出画面。

### 2.1 硬件与一次性准备

1. **硬件**：PYNQ-Z2（已烧 PYNQ 3.0.1 镜像）+ OV5640 经转接板接 Pmod + HDMI 显示器（只接受 720p60）+ 三路舵机（外部 5 V 供电）+ 传送带。
2. **装运行时**（只做一次，板端无外网，先上传 wheel 再本地装）：
   ```
   sudo pip3 install --no-deps tflite_runtime-2.13.0-cp310-cp310-manylinux2014_armv7l.whl
   ```

### 2.2 要上传哪些文件、每个文件干什么

全部**平铺**传到 `/home/xilinx/jupyter_notebooks/`（同一层，不要建子目录）；`.bit` 与 `.hwh` **必须同名且同目录**，PYNQ 靠同名自动配对。

| 类别 | 文件 | 作用 |
|---|---|---|
| 入口 | `ui.py` | **唯一入口**：ipywidgets 控制台。加载时只搭界面，不碰任何硬件 |
| 硬件 | `design_1_wrapper.bit` | 位流（4 045 771 B） |
| | `design_1_wrapper.hwh` | 硬件描述（749 391 B）。必须是打过 FCLK0 分频补丁的那份，用未打补丁的会**屏幕全黑** |
| 初始化 | `cam_full.py` | 烧位流 + FCLK0 频率自检 + 位敲 SCCB 配摄像头 + 显示时序 + 四条 VDMA 与帧同步 + 算法槽位自检 |
| | `pz2_video.py` | `axi_dynclk` / `v_tc` 的寄存器级函数库 |
| | `dynclk_tables.py` | 像素时钟 MMCM 配置查找表（纯常量） |
| 参数 | `config.py` | 曝光 / 增益 / AWB 锁定 + 掩膜阈值 + 抗阴影参数 + 显示档位 |
| 定位 | `detect.py` | 读掩膜 → 连通域 → 合并 → 裁彩色 ROI（含掩膜↔原图坐标换算） |
| 识别 | `cnn_pl_infer.py` | PL CNN 驱动：6 个基地址、加载 4 个权重 bin、`infer` / `selftest` |
| | `tflite_infer.py` | PS 侧 TFLite 回退推理与预处理；PL 可用时只提供标签表与预处理参数 |
| | `model_blob.bin`、`model_bias.bin`、`model_mmult.bin`、`model_mshift.bin` | 量化权重 / 偏置 / 乘数 / 右移量（PL 推理用） |
| | `golden_in.bin` | 内核自检的黄金输入（缺失只会让自检报 SKIP，不影响识别） |
| | `model_int8_64.tflite` | 仅在 PS 回退路径下使用 |
| 跟踪与分拣 | `track.py` | 跨帧质心匹配、3 帧确认、12 帧丢失、最近 5 次投票、越线触发 |
| | `servo.py` | 三路舵机参数下发与 KICK |
| 显示 | `osd.py` | 硬件 OSD 画框与 ASCII 字符 + `osd_live` 实时主循环 |

以上 **19 个为必需**；另有 4 个自检工具脚本（`tools/`）与 `tflite_runtime` wheel 属可选。完整清单、三种传文件方式（Jupyter 上传 / SMB / WinSCP）、上传后核对数量的命令，见 **`board/upload_list.md`**。

### 2.3 运行

在该目录打开 Jupyter → 新建 notebook → 执行：

```
%run ui.py
```

出现控制台界面后按顺序点：**① 加载位流 → ② 加载识别 → ③ 采集背景（传送带空转、带面无物）→ ④ 开始识别**。

> **第一次跑没反应怎么办**：再执行一次 `%run ui.py`。内核刚启动时图形控件与显示后端偶尔尚未就绪，第二次即正常出现界面；若仍无界面，Restart Kernel 后重跑一次。

`ui.py` 加载时只搭界面，**不做任何硬件动作**；烧位流、跑采集、加载识别、采背景、开始识别全部由按钮触发。

---

## 3 路径 B：从源码重建同一份 bit 流

### 3.0 开始之前

**需要的软件**

| 项 | 要求 | 说明 |
|---|---|---|
| Vivado / Vitis | **2026.1** | 必须是这个版本。块设计里锁定了 `axi_vdma:6.3`、`v_tc:6.2`、`axis_broadcaster:1.1`，换版本会触发 IP 自动升级，重建结果不再等价 |
| Python | 3.7 及以上 | 只有第 3 步的 `deliver.py` 用到，而且只用标准库；装了 Vivado 的机器上一定有可用的 Python |
| 磁盘 | ≥ 15 GB 空余 | 综合实现的中间文件较大 |
| 内存 | ≥ 16 GB | 构建脚本按单线程运行；内存更小的机器可能被系统杀掉进程 |

**需要的硬件**（只有第 4 步上板才用得到，前三步在普通 PC 上就能全部跑完）

- PYNQ-Z2 开发板（已烧录 PYNQ 3.0.1 镜像）、microSD 卡、网线
- OV5640 摄像头 + PMOD 转接板
- HDMI 显示器（本项目用的这块屏只接受 720p60 刷新率）
- 三路 SG90 舵机 + 独立 5 V 电源 + 传送带

**三个词的意思**

| 词 | 含义 |
|---|---|
| 块设计（block design，`.bd`） | 用图形方式把 IP 和连线组织成一个硬件系统；本作品的核心硬件都在这里 |
| 位流（`.bit`） | 烧进 FPGA 的配置文件，决定 PL 内部接成什么电路 |
| 硬件描述（`.hwh`） | 给 PYNQ 看的说明书：有哪些 IP、各自的寄存器在什么地址。PYNQ 靠它把 `.bit` 里的电路对应成 Python 能访问的对象 |

**全程时间预算**：约 1 小时 —— 步骤 1 约 2 分钟，步骤 2 约 40~50 分钟，步骤 3 几秒，步骤 4 约 10 分钟。

### 3.1 复现步骤（按顺序做，共 4 步）

> 这 4 步是**自包含**的：只用本包里的文件，不需要原工程、不需要联网、不需要任何包外脚本。
> 下文用 `<包>` 表示本包解压后的目录。例如解压到 `D:\objrs\` 下，`<包>` 就是 `D:\objrs\object_recovery_sorting`。
> 每一步都给出：敲什么 · 等多久 · 看到什么算成功 · 失败了怎么办。

#### 准备：打开命令行，确认位置

按 `Win + R`，输入 `cmd` 后回车，得到命令行窗口。然后依次执行：

```bat
cd /d "<包>"
dir build\bd\create_project.tcl
```

`dir` 能列出这个文件的字节数，说明当前目录正确，后面的命令可以直接复制执行。

再确认 Vivado 的位置（下文写作 `%VIVADO_BIN%`），常见路径是 `C:\Xilinx\Vivado\2026.1\bin`：

```bat
dir "C:\Xilinx\Vivado\2026.1\bin\vivado.bat"
```

若不在该路径，换成实际安装路径。也可以在窗口里先把路径存成变量，后面直接引用：

```bat
set VIVADO_BIN=C:\Xilinx\Vivado\2026.1\bin
```

#### 步骤 1｜建工程并恢复块设计（约 2 分钟）

```bat
set OBJRS_PROJ_DIR=D:\objrs_build
set OBJRS_GENERATE=1
"%VIVADO_BIN%\vivado.bat" -mode batch -notrace -nojournal -log create.log ^
    -source "<包>\build\bd\create_project.tcl"
```

- `OBJRS_PROJ_DIR` —— 新工程放在哪里，任意路径都行（中英文目录都可以）。
- `OBJRS_GENERATE=1` —— 顺带生成各 IP 的输出产物，多花约 1 分钟，建议打开。
- 这两行 `set` 只对**当前这个命令行窗口**有效，换窗口要重新设置。
- `^` 是 cmd 的换行续行符，整段要一次粘进去执行。

**成功的样子**：窗口滚过若干 Vivado 信息后结束，命令行提示符回来。然后执行

```bat
findstr /C:"CHECK " create.log
echo %errorlevel%
```

应输出下列 11 行（顺序可能略有出入），且 `%errorlevel%` 为 `0`：

```
CHECK ip_found     = alientek.com:user:ov5640_capture_data:1.0
CHECK ip_found     = openedv.com:user:DVI_Transmitter:1.0
CHECK ip_found     = digilentinc.com:ip:axi_dynclk:1.0
CHECK ip_found     = xilinx.com:hls:cnn_top:1.4
CHECK bd_cells     = 20  (expect 20)
CHECK addr_segs    = 23
CHECK validate     = PASS
CHECK top          = design_1_wrapper
CHECK part         = xc7z020clg400-1
CHECK proj_dir     = D:/objrs_build
CHECK REBUILD_DONE
```

其中 `bd_cells = 20`（块设计里有 20 个单元）、`validate = PASS`（块设计校验通过）、
`REBUILD_DONE`（脚本跑完了）这三行是最关键的判据。

**如果你习惯用 PowerShell**：`set X=Y` 要写成 `$env:X = "Y"`，其余命令相同。

**为什么判据是英文的 `CHECK` 行**：Vivado 的 `.log` 里，脚本打印的文本是 UTF-8、Vivado 自己的消息是系统 ANSI(GBK)，**同一个文件混了两种编码**，用任何一种编码整篇读都会有一半乱码，中文判据 grep 不到。因此脚本额外打印了上面这组纯 ASCII 的行。

#### 步骤 2｜综合 + 实现 + 出位流（约 40~50 分钟）

**必须在同一个命令行窗口里执行**（要用到上一步设置的 `OBJRS_PROJ_DIR`；若是新窗口，先把那两行 `set` 重新执行一遍）：

```bat
"%VIVADO_BIN%\vivado.bat" -mode batch -notrace -nojournal -log build.log ^
    -source "<包>\build\bd\build_bitstream.tcl"
```

这一步耗时最长，期间不要关闭窗口。它依次做：先给块设计里 20 个 IP 各做一次独立综合（这是 Vivado 的固定流程），再综合整个设计，再布局布线，最后生成位流。

**成功的样子**：

```
== synth_1 PROGRESS = 100%
== impl_1 PROGRESS = 100%
  WNS = 0.271 ns
  WHS = 0.050 ns
  大小 = 4045771 字节
== 完成
```

`WNS`（时序余量）为正说明时序收敛；位流字节数接近 4 045 771 即与交付版同量级。

**失败怎么办**：先看 `build.log` 里所有 `ERROR:` 行，对照 §3.6。最常见的两种是
`[Synth 8-439] module ... not found`（用错了流程）和内存不足被杀（改用内存更大的机器）。

#### 步骤 3｜打 FCLK0 分频补丁，整理上板文件（几秒）

```bat
python "<包>\build\deliver.py"
```

若 `python` 不可用，可试 `py "<包>\build\deliver.py"`，或用完整路径调用任意 Python 3.7+。

**成功的样子**：

```
PATCH PCW_FCLK0_PERIPHERAL_DIVISOR0            4 -> 10  hits=1
PATCH PCW_FCLK0_PERIPHERAL_DIVISOR1            4 -> 1   hits=1
CHECK 两个分频参数复核通过（10 / 1）
DELIVER_OK
```

产物在 `<工程目录>\_deliver\` 下：`design_1_wrapper.bit` 与 `design_1_wrapper.hwh`。

**为什么一定要做这一步**：PS 侧给 PL 的时钟分频参数在块设计里是派生量，改块设计不生效，导出的 `.hwh` 里永远是 4/4，于是 PL 实际只跑 62.5 MHz。现象是**屏幕全黑，而 PS 侧的寄存器读写、VDMA 状态全部正常**，很难定位。补丁把它改成 10/1，即 100 MHz。

#### 步骤 4｜上板运行（约 10 分钟）

前三步产出的 `_deliver/` 里那两个文件，加上 `src/ps/` 的 11 个 `.py` 和 `data/` 的模型文件，
按 **`board/upload_list.md`** 的清单全部上传到板子的 `/home/xilinx/jupyter_notebooks/`，
然后在该目录打开 Jupyter，新建 notebook 执行 `%run ui.py`，依次点 **① 加载位流 → ② 加载识别 → ③ 采集背景 → ④ 开始识别**。

上传清单、一次性准备（装 tflite 运行时）、硬件接线检查、每一步"成功的样子"，都在 `board/upload_list.md` 里。

> 如果只是想看看程序跑起来什么效果，**不需要做前面的 1~3 步**，直接用 `board/` 里已经验证过的位流即可，见本文 §2。

### 3.2 补充说明：HLS —— 从 C++ 源码重新生成 IP（可跳过）

**可以跳过**：`src/ip_repo/cnn_top_1/` 已经是打包好的 `cnn_top` **v1.4** IP（VLNV `xilinx.com:hls:cnn_top:1.4`），直接用即可。只有在改了 `src/hls/cnn_accel.cpp` 时才需要重跑本步。

本包已包含 **Vitis HLS 侧的全部源码**（`cnn_accel.cpp` / `tb_cnn.cpp` / `model_meta.h` / `hls.cfg`），以及 PC 侧的数据准备链：`data/dump_tflite.py`（手写 flatbuffer 解析，不依赖 TensorFlow，从 `.tflite` 抽取权重与量化参数 → `weights.npz`）→ `data/gen_data.py`（生成 `model_blob/bias/mmult/mshift.bin` 与 C 仿真黄金张量）→ `data/ref_cnn.py`（逐位复刻 TFLite int8 语义的参考实现，用于与硬件输出逐字节比对）。

```
call "<Vitis安装目录>\.settings64-Vitis_for_HLS.bat"
cd src/hls
vitis-run --mode hls --csim    --config hls.cfg --work_dir work_v6
v++       --compile --mode hls --config hls.cfg --work_dir work_v6
vitis-run --mode hls --package --config hls.cfg --work_dir work_v6
```

- 唯一输入是 `hls.cfg`（`part` / `syn.top=cnn_top` / `syn.file=cnn_accel.cpp` / `tb.file=tb_cnn.cpp` / `package.ip.name=cnn_top` / `package.ip.version=1.4`）。
- 产物：`work_v6/cnn_top.zip` → 用 `update_ip_catalog -add_ip` 注册后可替代 `src/ip_repo/cnn_top_1`。
- **C 仿真**：`vitis-run --mode hls --csim` 会编译并运行 `tb_cnn.cpp`，逐字节比对 5 层张量 + gap + fc，判据是每层 `mismatch = 0`（bit-exact）。它读 `data/csim/` 下的 `golden_*.bin`，跑前把 `tb_cnn.cpp` 里的 `DATADIR` 指向该目录。
- ★ **改源必须同时抬 `package.ip.version`**。同一个 VLNV 重新加 zip，Vivado 会锁住已缓存的网表并**静默综合旧结果**，现象是改了半天代码、位流一点没变。

### 3.3 详解：建工程脚本做了什么（对应步骤 1）

> 本仓库**不附带 `.xpr` 工程文件**，也不附带 `.runs/` `.cache/` 等中间产物（体积以 GB 计、且可完全再生）。工程由脚本按包内文件重建。

命令见 §3.1 步骤 1，这里只说明它内部做了什么、以及哪些地方容易出问题。

脚本依次执行：

1. 按器件 `xc7z020clg400-1` 新建工程（如装了 PYNQ-Z2 的板卡定义，一并设置）；
2. 把 `src/ip_repo` 注册成 IP 仓库，并逐个检查 4 个 IP 的标识（VLNV）能否找到；
3. 加入 `src/rtl/*.v` 与 `build/constraints/top.xdc`；
4. 把 `build/bd/design_1.bd` 与 `design_1.bda` 放回 `sources_1/bd/design_1/` 并打开；
5. 校验块设计，打印单元数与地址段数；
6. 生成 HDL 顶层包装文件并设为顶层，整理编译顺序；
7. 最后打印一组纯 ASCII 的 `CHECK` 行作为判据。

两个环境变量都可省略：

| 变量 | 作用 | 默认 |
|---|---|---|
| `OBJRS_PROJ_DIR` | 新工程建到哪里。设了就不会在包内生成 `_build/` | `<包>/_build/project` |
| `OBJRS_GENERATE` | 设 `1` 时额外生成块设计的输出产物（见下） | 不执行 |

**要点（照着排查时最容易踩到的四条）**

- `.bd` 只保存「与 IP 默认值不同」的参数，这是 Vivado 的正常机制，缺失项会按 IP 定义重新推导；PS7 的 358 项参数是整份内嵌的。
- **IP 仓库路径必须是相对路径**（形如 `IPRepoPath=$PPRDIR/ip_repo`），写成绝对路径换机器就会失败。
- 块设计里有 **3 个 `module_ref`**（直接引用 `.v` 源码、不在 `ip_repo` 里的单元）：`glass_defect_core_v2`、`dd_osd_axis`、`servo_pwm`，各自对应 `src/rtl/` 下的同名文件，缺一个块设计就报红。这三个文件名与模块名沿用早期命名、没有改动——改 `module_ref` 的名字会导致必须删除并重建该单元，进而全量重综合。
- 第一次打开块设计时会刷出二十多条 `[BD 41-2576] ... .xci could not be found` 的警告，这是**输出产物还没生成**，属正常现象；跑完步骤 1 的 `OBJRS_GENERATE=1`（或直接跑到步骤 2）后自然消失。

**本步骤的验证情况**：已在一个全新的空工程里从零执行通过，结果见 `MANIFEST.md` 第五节。

### 3.4 详解：综合与实现（对应步骤 2）

`build/bd/build_bitstream.tcl` 内部等价于：

```tcl
create_run synth_1 -part xc7z020clg400-1
launch_runs synth_1 -jobs 1              ;# 会先自动跑完 BD 里 20 个 IP 的 OOC 综合
wait_on_run synth_1
create_run impl_1 -parent_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
open_run impl_1                          ;# 再出 util / timing / drc / methodology 报告
```

**必须走 run 流程**：BD 里每个 IP 都要先各自做一次 out-of-context 综合产出 `.dcp`，BD 生成的 `design_1.v` 才找得到 `design_1_<ip>_0_0` 这些模块。打开工程后直接 `synth_design` 会报
`ERROR: [Synth 8-439] module 'design_1_DVI_Transmitter_0_0' not found`。

参考结果（本设计实测，可直接当复现成功的判据）：

> 下表已由**两次互相独立的完整重建**各跑一遍，数字逐项相同（详见 `MANIFEST.md` 第五节）。

| 项 | 值 |
|---|---|
| 耗时 | 40.8 分钟（20 个 IP 的 OOC 综合 + 综合 + 实现 + 位流） |
| `synth_1` / `impl_1` | 均 100% |
| WNS / WHS / TNS | +0.271 ns / +0.050 ns / 0 |
| 时序总端点（max / min / pulse） | 114 491 / 114 364 / 44 873 |
| Slice LUTs | 38 726（72.79%） |
| FF | 41 248（38.77%） |
| Block RAM Tile | 67.5（48.21%） |
| DSP | 93（42.27%） |
| 位流大小 | **4 045 771 B** |

★ **不要**加 `set_param general.maxThreads 8`：本机会卡死在 Tech Mapping（CPU 45 秒零增长、日志时间戳不前进，常伴随 `Failed to create directory 'C'`）。
★ **不要**把 `-jobs` 调到 1 以上：并行多个 run 会 OOM。

> `build/history/` 下放着**原始工程**用的三个历史脚本（`bd_step10_v14.tcl`、`bd_step11_build_v14.tcl`、`ooc_syn.tcl`）。它们写死了原机器的绝对路径（`D:/AMD/PROJECT/...`），**复现时不要用**，功能已被 `create_project.tcl` + `build_bitstream.tcl` 取代，详见 `build/history/README.md`。

### 3.5 详解：交付补丁（对应步骤 3）

```bash
python build/deliver.py
# 也可显式指定：python build/deliver.py --proj-dir D:\objrs_build --out D:\objrs_upload
```

它做四件事：

1. **在工程目录里自动找文件**（不依赖任何绝对路径）：`design_1.hwh` 递归找 `**/hw_handoff/design_1.hwh`，位流优先 `_bit/`、其次 `runs/impl_1/`；
2. 给 hwh 打两处补丁：`PCW_FCLK0_PERIPHERAL_DIVISOR0` `4 → 10`、`PCW_FCLK0_PERIPHERAL_DIVISOR1` `4 → 1`；任一处 0 命中即 **ABORT 且不写盘**（并提示"可能已经打过补丁"）；
3. **补丁后复核**这两个参数确实是 `10` 与 `1`，不通过同样 ABORT；
4. 把打过补丁的 hwh 与位流落到 `<工程目录>/_deliver/`，打印字节数与 MD5，并列出上板要上传的其余文件。

**为什么必须打**：`FCLK_CLK0` 的百分频在 BD 里是**派生参数，改 BD 不生效**，导出的 `.hwh` 里永远是 4/4，于是 PL 实际只跑 **62.5 MHz**——现象是 **屏幕全黑，但 PS 侧 SCCB 读写、VDMA 状态、寄存器回读全部正常**，极难定位。

**核对方式**：打完补丁的 hwh 与 `board/design_1_wrapper.hwh` 相比，**2254 个 `PARAMETER` 应全部一致**
（`TIMESTAMP` 与两个 `Component_Name` 会不同，属正常）。两者 **MD5 不会相同**（头部有编译时间戳），别拿 MD5 判等。

### 3.6 复现常见问题（按报错查）

| 现象 / 报错 | 原因 | 处理 |
|---|---|---|
| `ERROR: [Synth 8-439] module 'design_1_XXX_0_0' not found` | 走了内存流程（打开工程直接 `synth_design`）。BD 里每个 IP 要先各自做一次 OOC 综合产出 `.dcp` | 用 `build_bitstream.tcl`（走 `launch_runs`）。**报错点名的永远是第一个第三方 IP，不代表它的源码缺失** |
| `ERROR: [Common 17-161] Invalid option value 'design_1' specified for 'files'` | 2026.1 的 `make_wrapper` 签名变了：`-top` 是**开关不带值**，`.bd` 是**位置参数** | 用 `make_wrapper -top -files [get_files design_1.bd] -import -force`（`create_project.tcl` 已改好） |
| `can't read "(...)" : no such variable` | Tcl 里写了 `$(...)` —— 那不是 Tcl 的命令替换 | Tcl 只用 `[...]`；复杂取值先赋给变量 |
| 打开 BD 时刷出 20 多条 `WARNING: [BD 41-2576] File '...xci' could not be found` | IP 输出产物尚未生成，属正常现象 | 跑完 `OBJRS_GENERATE=1` 或直接跑到综合后自然消失 |
| 工程里出现 `ov5640_hdmi_fd.gen/` 而不是 `objrs.gen/` | `.bd` 文件内嵌了原工程名 | 正常现象，不影响构建与上板 |
| 某个 IP 的 `get_ipdefs` 找不到、BD 对应 cell 变红 | `src/ip_repo` 没注册成 IP 仓库，或用了绝对路径 | `create_project.tcl` 按相对路径注册；手工核对 `get_property ip_repo_paths [current_project]` |
| 综合卡在 Tech Mapping，CPU 长时间零增长 | 设了 `set_param general.maxThreads 8` | 删掉该设置，用默认线程 |
| 综合/实现被 OOM 杀掉 | `-jobs` > 1 同时跑多个 run | 保持 `OBJRS_JOBS=1`（默认就是 1） |
| `deliver.py` 报 `ABORT 有补丁没命中` | 这份 hwh 已打过补丁（值已是 10 / 1），或版本不符 | 已打过就直接用；否则 `grep PCW_FCLK0_PERIPHERAL_DIVISOR` 看实际值 |
| **位流出了但屏幕全黑**，而 PS 侧一切正常 | hwh 没打 FCLK0 补丁 ⇒ PL 只跑 62.5 MHz | 跑 `build/deliver.py`，并确认上传的是 `_deliver/` 里那份 hwh |
| `cam_full.py` 找不到位流 | 它在 `/home/xilinx` 与 `/home/xilinx/jupyter_notebooks` 下找 `design_1_wrapper*.bit` | `.bit` 必须放在这两个目录之一 |
| `RuntimeError: ... tflite_infer.py 是旧的` | `cnn_pl_infer.py` 有门禁，要求 `tflite_infer.SIZE == 64` | 用本包 `src/ps/tflite_infer.py`（已修正为 64） |
| 想 grep 日志里的中文判据，却发现全是乱码 | Vivado 的 `.log` **混合了 UTF-8（Tcl puts）与 ANSI/GBK（Vivado 消息）** | 别 grep 中文。用 `findstr /C:"CHECK "` 抓本包脚本打的 ASCII 判据行；或 `findstr /C:"ERROR:"` |
| Vivado 报 `Could not open file` | 个别步骤对超长路径敏感 | **中文路径可以使用**（本作品全程在含中文的路径下构建通过）；若确实报错，换一个较短路径（如 `D:\objrs`）再试。包可以放在任意盘符、任意目录，只要里面文件结构不变 |
| 想确认"包里还有没有写死别的机器路径" | — | 在本包根目录执行 `findstr /S /I /C:"D:\AMD" /C:"C:\Users" *.tcl *.py *.ps1 *.md`。**正常只应命中 `build/history/`、`build/report/` 里的原件，以及脚本文档里作为"反例"出现的字符串** |

---

## 4 仿真验证

`sim/` 下是各级 testbench，覆盖定位链的每一个流水级与两个 BD 顶层的寄存器行为，另有 HLS 的 C 仿真（`src/hls/tb_cnn.cpp`，见 §3.2）。

跑法与"每条判据怎么读"见 `sim/README.md`。

★ 例外一处：`sim/tb_dd_gray.v` 是按早期"灰度化"版本写的，而现行 `dd_gray` 自 2026-10-21 起已改为 **24 位彩色逐位透传**（灰度/色度后移到 `dd_shadow` 现算），两者语义不同 ⇒ **复现时请跳过该 TB**，该级的正确性由下游各级 TB 与上板实测覆盖（详见 `sim/README.md` 第五节）。

验证策略：**改动 RTL → `xvlog` + `xelab` 编译 → 跑对应 testbench 全绿 → 才允许综合**。只编译通过不算过。

---

## 5 官方 IP 与第三方 IP 的处理

BD 共 **20 个 cell**，分三类：

### ① Vivado 官方 IP —— 只给调用方式，不带源码

| cell | VLNV | 本设计的关键配置 |
|---|---|---|
| `processing_system7_0` | `xilinx.com:ip:processing_system7:5.5` | 358 项参数全量内嵌在 `.bd` |
| `axi_vdma_0` / `_1` | `xilinx.com:ip:axi_vdma:6.3` | AXIS 24 bit、`C_INCLUDE_SG=0`、3 帧环、GenLock（S2MM 动态主 / MM2S 动态从） |
| `v_tc_0` | `xilinx.com:ip:v_tc:6.2` | 720p，`C_GENERATE_EN=1` |
| `v_vid_in_axi4s_0` | `xilinx.com:ip:v_vid_in_axi4s:5.0` | `C_PIXELS_PER_CLOCK=1`，RGB |
| `v_axi4s_vid_out_0` | `xilinx.com:ip:v_axi4s_vid_out:4.0` | `C_VTG_MASTER_SLAVE=1`（VTG Slave） |
| `axis_broadcaster_0` | `xilinx.com:ip:axis_broadcaster:1.1` | 1→2，无缓冲 |
| `clk_wiz_xclk` | `xilinx.com:ip:clk_wiz:6.0` | 100 MHz → 24 MHz 供摄像头 XVCLK |
| `ps7_0_axi_periph` / `axi_smc` / `axi_smc_cnn` | `axi_interconnect:2.1` / `smartconnect:1.0` | 总线互联 |
| `rst_ps7_0_50M` | `xilinx.com:ip:proc_sys_reset:5.0` | 复位 |
| `const_gen_clken` | `xilinx.com:ip:xlconstant:1.1` | 显示使能接常量 |

**为什么不带源码**：这些是 Vivado 安装自带的 LogiCORE，装了同版本就有；`.bd` 里已经存了全部非默认配置，打开 BD 时 Vivado 会按配置重新生成。带源码既无必要也不符合再分发条件。**受影响的只有一件事**——必须用 2026.1（见 §3.1）。

### ② 第三方 IP —— 必须带源码（已随包）

| 目录 | BD 中 cell / VLNV | 作用 |
|---|---|---|
| `src/ip_repo/ov5640_cap_data` | `ov5640_capture_data_0` | OV5640 并口 → RGB888，每 2 个 PCLK 出 1 像素 |
| `src/ip_repo/DVI_TX` | `DVI_Transmitter_0` | DVI/TMDS 发送（含 TMDS 总线定义 `if/TMDS.xml`、`if/TMDS_rtl.xml`） |
| `src/ip_repo/axi_dynclk_v1_0` | `axi_dynclk_0` | 运行时重配 MMCM，产生 74.29 MHz 像素时钟 |
| `src/ip_repo/cnn_top_1` | `cnn_top_0` | 本工程 HLS 生成的 int8 CNN 加速器 **v1.4** |

**注意**：`DVI_TX` 的 `component.xml` 嵌在 `ip/` 子目录里，**整个目录要原样拷贝**，不要只取 `src/`。`cnn_top_1` 目录名里的 `_1` 是历史遗留，里面装的就是 v1.4。

### ③ 自研 —— 带源码

- 3 个 `module_ref`（直接引用 `.v`）：`glass_defect_core_v2`、`dd_osd_axis`、`servo_pwm`
- 1 个 HLS IP：`cnn_top` v1.4（源在 `src/hls/`）


---

## 6 已知陷阱（按"踩到会浪费多久"排序）

| # | 现象 | 根因与对策 |
|---|---|---|
| 1 | **屏幕全黑，但 PS 侧一切正常** | `.hwh` 里 FCLK0 分频是 4/4 ⇒ PL 只有 62.5 MHz。必须跑 `build/deliver.py` 打补丁（§3.5） |
| 2 | 运动物体一顿一顿、有重影，静止画面正常 | VDMA GenLock 未启用。S2MM `CR=0x0B`、MM2S `CR=0x800B` |
| 3 | 显示侧 IP 一帧都不接收 | 显示侧 AXIS→时序 IP 的主从方向选错，与 `gen_clken` 形成互等死锁。改 Slave、断开互锁线、使能接常量 |
| 4 | 重建后综合卡死在 Tech Mapping | `set_param general.maxThreads 8`。删掉该设置回默认线程 |
| 5 | 重建后 IP 全变红 | `ip_repo` 没注册成 IP 仓库，或用了绝对路径。必须 `ip_repo_paths` 指向 `src/ip_repo` 且为相对路径 |
| 6 | 加载识别时抛 `RuntimeError: … tflite_infer.py 是旧的` | `cnn_pl_infer.py` 有硬门禁，要求 `tflite_infer.SIZE == 64`。本包内的副本已修正为 64 |
| 7 | 位流下载后 PS 挂死、只能断电 | 加载 overlay 前访问了任何 PL 地址。只看 `/sys/class/fpga_manager/fpga0/state` |
| 8 | `cam_full.py` 找不到位流 | 它在 `/home/xilinx` 与 `/home/xilinx/jupyter_notebooks` 下 glob `design_1_wrapper*.bit`，`.bit` 必须落在这两处之一 |
| 9 | 读缓冲"完全没更新"（假阴性） | CPU 缓存未失效。读前 `invalidate`、写完 `flush` |
| 10 | 画面被"拦腰切开"或差分全黑 | 差分级输出节拍跟了背景流而非相机流。`m_axis` 的几何必须跟相机流节拍 |
| 11 | 改完 HLS 代码，位流一点没变 | 同 VLNV 重新加 zip，Vivado 锁旧网表。必须抬 `package.ip.version` |
| 12 | 重复跑 `cnn_pl_infer.py` 后内存耗尽 | 每次 `Overlay()` 会重置 `cnn_top` 的 6 个基地址寄存器；重跑 `cam_full.py` 后**必须重跑 `config.py` 与 `cnn_pl_infer.py`**，且 `cnn_pl_infer.py` 只在该内核里跑一次 |
| 13 | 显示器黑屏/进省电 | 该屏只接受 720p60，30 Hz 会熄屏 |

---

## 7 验收判据（照这个自查是否复现成功）

| 阶段 | 成功的样子 |
|---|---|
| 构建 | `wait_on_run synth_1` 与 `impl_1` 均 100%；WNS 为正；生成的 `.bit` 与 `.hwh` 尺寸接近 4,045,771 B / 749,391 B |
| 补丁 | `design_1_wrapper.hwh` 内 `PCW_FCLK0_PERIPHERAL_DIVISOR0 = 10`、`DIVISOR1 = 1`；加载后读 `Clocks.fclk0_mhz` 应是 100 |
| 出图 | 屏幕上出现实时彩色画面，无撕裂、无重影 |
| 定位 | 放进物体后 ≤3 帧出框；稳态每帧 `lead_max=0 / stall_cnt=0 / lap_cnt=1` |
| 识别 | 框上叠加英文类别名；未教过的物体报"未知"且不画框 |
| 计数 | 物体静止 10 s 不重复计数；画面一侧实时显示「可回收 X / 不可回收 Y」 |
| 分拣 | 可回收物越过分拣线后按类别被对应舵机拍离带面；同类连续到达时排队顺延而不丢动作 |
| HLS C 仿真 | `tb_cnn.cpp` 每层 `mismatch = 0` |

---

## 8 许可

MIT，见 `LICENSE`。`src/ip_repo/` 下第三方 IP 各自保留其原有条款。
