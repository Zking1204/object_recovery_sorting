# 板端上传清单

**目标目录**：`/home/xilinx/jupyter_notebooks/`（必须**平铺在同一层**，不要建子目录）

- `cam_full.py` 会在 `/home/xilinx` 与 `/home/xilinx/jupyter_notebooks` 两处 glob `design_1_wrapper*.bit`，放别处会找不到位流。
- `.bit` 与 `.hwh` **必须同名且同目录**，PYNQ 靠同名自动配对读取硬件描述。
- 各 `.py` 之间是**同目录 import / `%run`** 关系，不能分开放。
- 板端不允许中文目录名或文件名。

---

## 零、怎么把文件传到板子上

三种方式任选一种，效果相同。

**前提**：板子已烧 PYNQ 3.0.1 镜像、插好网线、上电，并和电脑在同一网段。
板子的 IP 可以这样获得：登录路由器后台看 DHCP 列表；或接 USB 串口（波特率 115200）后在板子里执行 `hostname -I`。

| 方式 | 怎么做 | 适合 |
|---|---|---|
| **Jupyter 网页上传** | 浏览器打开 `http://<板子IP>:9090`，输入密码（PYNQ 默认 `xilinx`），进入 `/home/xilinx/jupyter_notebooks` 目录，点右上角 **Upload** 逐个选文件 | 文件少、想顺手操作 |
| **SMB 共享** | Windows 资源管理器地址栏输入 `\\<板子IP>\xilinx\jupyter_notebooks`，直接把文件拖进去 | 文件多，最省事 |
| **WinSCP / scp** | 协议选 SFTP，主机填板子 IP，用户 `xilinx`，密码 `xilinx`，目标目录 `/home/xilinx/jupyter_notebooks` | 习惯命令行的人 |

传完之后，在 Jupyter 里打开一个 terminal 执行 `ls -1 | wc -l`，应能看到文件数量（必需文件共 19 个）。

---

## 一、必需文件（19 个）

### 1. 板端 Python（11 个）

| 文件 | 按钮 | 作用 |
|---|---|---|
| `ui.py` | — | **唯一入口**。ipywidgets 控制台，加载时只搭界面、不碰硬件 |
| `cam_full.py` | ① | 烧位流 + FCLK0 自检 + 位敲 SCCB 配摄像头 + 显示时序 + 四条 VDMA + GenLock |
| `pz2_video.py` | ① | `axi_dynclk` / `v_tc` 寄存器级函数库（被 `cam_full` import） |
| `dynclk_tables.py` | ① | 像素时钟 MMCM 配置查找表（纯常量） |
| `config.py` | ② | 曝光 / 增益 / AWB + 掩膜阈值 + 抗阴影参数 + 显示档位 |
| `detect.py` | ② | 掩膜 → 二次阈值 → 连通域 → 合并 → 裁彩色 ROI |
| `cnn_pl_infer.py` | ② | PL CNN 加速器驱动：6 个基地址、载入 4 个权重 bin、`infer` / `selftest` |
| `tflite_infer.py` | ② | PS 侧 TFLite 回退推理与预处理；PL 可用时只提供标签表与预处理参数 |
| `track.py` | ④ | 跨帧跟踪计数：质心匹配、3 帧确认、12 帧丢失、最近 5 次投票、过线触发 |
| `servo.py` | ②④ | 舵机 AXI-Lite 驱动（三路参数下发与 KICK） |
| `osd.py` | ④ | 硬件 OSD 画框与 ASCII 字符 + `osd_live` 实时主循环 |

### 2. 硬件描述（2 个）

| 文件 | 说明 |
|---|---|
| `design_1_wrapper.bit` | 位流，4 045 771 B |
| `design_1_wrapper.hwh` | 硬件描述，749 391 B。**必须是打过 FCLK0 分频补丁的那一份**（`build/deliver.py` 生成）。用未打补丁的版本 ⇒ 屏幕全黑 |

### 3. 模型与黄金参考（6 个）

| 文件 | 说明 |
|---|---|
| `model_blob.bin` | 390 912 B，量化权重 |
| `model_bias.bin` | 1 944 B，偏置 |
| `model_mmult.bin` | 2 968 B，量化乘数 |
| `model_mshift.bin` | 2 968 B，量化右移量 |
| `golden_in.bin` | 12 288 B，`selftest()` 用的黄金输入 |
| `model_int8_64.tflite` | 408 464 B，仅作 PS 回退路径时使用 |

> `golden_in.bin` 缺失不会影响识别，只会让按钮②末尾的 `selftest` 报 SKIP。

---

## 二、可选文件

| 文件 | 用途 |
|---|---|
| `tflite_runtime-2.13.0-cp310-cp310-manylinux2014_armv7l.whl` | 只需装一次：`sudo pip3 install --no-deps <wheel>`；装完可从板子删除 |
| `tools/cnn_pl_test.py` | PL CNN 独立自检：位流 MD5 + 黄金逐值比对 + 20 次性能统计。**会重新下载位流，不要与 `ui.py` 同时跑** |
| `tools/live.py` | 实时帧率与漏帧监测 |
| `tools/bench.py` | 刷新率基准测试 |
| `tools/cnn.py` | 裁图到模型输入的可视化核对（早期脚本） |

---

## 三、上传后的一次性准备

```bash
# 1) 安装 tflite 运行时（本板无外网，必须先上传 wheel 再本地装）
sudo pip3 install --no-deps tflite_runtime-2.13.0-cp310-cp310-manylinux2014_armv7l.whl

# 2) 确认文件齐了（应输出 19）
ls -1 /home/xilinx/jupyter_notebooks/ | wc -l
```

---

## 四、运行顺序（严格照此）

| 步 | 操作 | 成功的样子 |
|---|---|---|
| 0 | 在 `/home/xilinx/jupyter_notebooks/` 新建 notebook，执行 `%run ui.py` | 出现控制台界面；**此步不应有任何硬件动作、不烧位流**。若第一次没出现界面，**再执行一次 `%run ui.py`**（内核刚启动时控件与显示后端偶未就绪），仍无界面则 Restart Kernel 后重试 |
| 1 | 点 **① 加载位流** | 打印 FCLK0 频率自检、SCCB 读写正常、四条 VDMA 状态；显示器出现实时画面 |
| 2 | 点 **② 加载识别** | 末尾打印"加载识别结果汇总"：句柄类型、`selftest` PASS、CTRL / blob / in / out 回读值 |
| 3 | 点 **③ 采集背景** | **此时传送带必须运转且带面无物**，采完背景冻结 |
| 4 | 点 **④ 开始识别** | 屏幕出现框、英文类别名、汇总数字；放上物体 ≤3 帧出框 |
| 5 | 点 **⑤ 中止** | 循环停止，叠加清除 |

### 三条容易踩的运行时规则

1. **重跑 `cam_full.py` 后必须重跑 `config.py` 与 `cnn_pl_infer.py`**。`Overlay()` 会重编程 PL，把 `cnn_top` 的 6 个基地址寄存器清零，同时 AWB / 曝光被打回自动模式。
2. **`cnn_pl_infer.py` 在同一个内核里只跑一次**，重复跑会泄漏 CMA 内存。
3. **改板端 `.py` 后**：重新上传覆盖 → 用 `%run xxx.py` 重跑（**不要用 `import`**，会命中旧缓存）；必要时 Restart Kernel 再跑一遍。

---

## 五、硬件连接检查（上电前）

| 项 | 要求 |
|---|---|
| 摄像头 | OV5640 经转接板接 Pmod，**跨排对接**（主排 pad 1–6 ↔ 转接板 7–12）；XCLK 由 FPGA 供 24 MHz（模组侧无晶振） |
| 显示器 | HDMI 连接，输出分辨率为 720p60 |
| 舵机供电 | **外部 5 V 独立供电**；棕线（地）不接板上 GND，另引一根细线做 0 V 参考，避免动作瞬间拉塌逻辑地 |
| 传送带 | **1 m 黑色布带**，带面无褶皱花纹；物体由右向左运动 |
| 采背景 | 传送带**运转**且**带面空无一物**时采一次并冻结 |
