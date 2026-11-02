---
name: cnn-on-pl
description: >-
  本项目（《实时垃圾分类识别与计数系统》）把 64×64 int8 CNN 下放到 PL 的**专属档案**：
  加速器地址与寄存器偏移、数据文件清单与指纹、板端驱动类接口、以及只有这个工程才会遇到的坑
  （`tflite_infer.py` 的 SIZE 与模型文件名、`osd.py` 硬编码路径、**读掩膜前必须先 `set_disp(5)`**）。
  ★ 本文件换题目、换板卡全部作废，只用于复现与维护本作品。
scope: 本项目专属（实时垃圾分类识别与计数系统）
when_to_use: 要在这个工程上继续改 CNN 加速器；板端 PL 识别跑不通；要给这个工程写报告/交接
triggers: ["cnn_top", "0x43C30000", "cnn_pl_infer.py", "PL 识别", "model_blob.bin", "model_int8_64.tflite", "set_disp", "DISP=5", "掩膜全白", "PLClassifier", "换模型", "模型重训", "FC_ZP", "golden_in.bin", "POC=16"]
version: 1.0.0
updated: 2026-11-01
license: MIT
verified_effect: "内核 9.15 ms、单次识别全程 16.8 ms，板端输出与 PC 端逐位复刻的黄金参考最大绝对差小于 0.01。"
origin: "预处理漏掉后两步归一化时不报任何错，但数值差 4~5 倍，靠逐位比对才发现；此后固化为"板端预处理必须与训练端逐行对齐"。"
---

# 本项目的 CNN-on-PL 档案

> ★ **通用部分不在这里**：微架构看 `../hls-accelerator-on-pl/SKILL.md`，主机侧驱动看 `../pl-accelerator-host-driver/SKILL.md`。
> 本文件只记"这个工程的具体值"。

## 一、加速器身份

| 项 | 值 |
|---|---|
| IP | `xilinx.com:hls:cnn_top:1.4`（★ 版本号每次重做必须 bump，否则 Vivado 会用缓存网表） |
| 地址 | **`0x43C30000`**，范围 64 KB（`ps7_0_axi_periph` NUM_MI = 7 的第 7 个从口） |
| 数据口 | `S_AXI_HP1`，经 `smartconnect`（NUM_SI=1 NUM_MI=1）接入（★ `axi_protocol_converter` 不能转位宽） |
| 接口类型 | 6 个 `m_axi` + 1 个 `s_axilite`（**纯 m_axi ⇒ `ap_ready` 永久为 0**） |

**寄存器偏移**（每个指针占低/高两个 32 位）：

| 偏移 | 内容 |
|---|---|
| `0x00` | CTRL：[0] AP_START / [1] AP_DONE（电平）/ [2] AP_IDLE / [3] AP_READY（恒 0） |
| `0x10` | 权重 blob 基地址 |
| `0x1C` | 偏置基地址 |
| `0x28` | requant 乘数基地址 |
| `0x34` | requant 移位基地址 |
| `0x40` | 输入图基地址（int8，12288 B） |
| `0x4C` | 输出基地址（4 个 int32：`[0][1]`=6 个 int8 logits 打包，`[2]`=信标、`[3]`=备用） |

## 二、数据文件清单（★ 布局一变就必须整套重传）

| 文件 | 字节 | 说明 |
|---|---|---|
| `model_blob.bin` | 390,912 | 权重，布局 `[og][tap][ib][oc][ic]` ⇒ **换 POC 就整套换布局**（v5 的 POC=8 与 v1.4 的 POC=16 互不兼容） |
| `model_bias.bin` | 1,944 | int32，486 项（零点已折进 bias） |
| `model_mmult.bin` | 2,968 | int32，742 项（每输出通道的 requant 乘数） |
| `model_mshift.bin` | 2,968 | int32，742 项（右移位数） |
| `golden_in.bin` | 12,288 | 自检输入（int8，64×64×3） |

**★ 三个数量不随模型变**：`N_BLOB=390912`、`N_BIAS=486`、`N_MUL=742` —— 因为权重总量只由通道数/核尺寸决定，与训练权重数值、与 POC 都无关。所以 `cnn_pl_infer.py` 里这三个常量**换模型后不用改**（但内容必须整套重传）。

**黄金值（2026-10-28 换模型后）**：`[-39, 95, 7, -116, -49, -128]`（int8 logits 域），对应浮点
`[-4.0798, 11.1062, 1.1333, -12.8061, -5.2131, -14.1660]`，argmax=1（can）。
`PLClassifier.selftest()` 必须 PASS。（旧模型的 `[-76, 66, 115, -128, -123, -126]` 已作废。）

## 二点五、★★★★ 换模型的完整流程（2026-10-28 实测走通，顺序不可乱）

前提：**新 model 的网络结构与旧的一模一样**（层数/通道数/输入尺寸/核尺寸）。本工程两次换模型都满足。若结构变了，HLS 描述表与 arena 布局都要改，不能照这个流程。

1. **先用 `dump_tflite.py` 解析新模型，逐字段和旧 npz 对比** —— 判据：`keys same: True`、所有 shape 相同、激活 zero_point 相同。
2. **`dump_tflite.py <新模型> weights.npz`** → 覆盖 `weights.npz`（先备份！）。
3. **`gen_data.py`** → 重新导出 `build/model_*.bin` 与 `golden_*.bin`、`model_meta.h`。
   ★ `gen_data.py` 里的 `POC_TILE` **必须等于 `cnn_accel.cpp` 里的 `POC`**，否则 tile 布局与核不匹配（这次从 8 改成 16）。
4. **C 仿真**（`vitis-run --mode hls --csim --config hls.cfg --work_dir <新目录>`）—— 判据：**七层全部 `mismatch=0`**，且打印的 `logits(int8)` 等于新黄金值。
5. 综合 → `--package`（版本号 bump）→ BD `upgrade_ip` → 构建。

**★★ 最容易静默出错的一步：模型换了以后 `FC_ZP`（输出零点）可能变。**
这次就是 **0 → −3**（同时 `FC_SCALE` 0.087355129 → 0.113328353）。若 `cnn_pl_infer.py` 里还写着旧的 `FC_ZP = 0`，**分类结果会整体偏 3 个 LSB 而完全不报错**。
判据：每次换模型都去 `model_meta.h` 抄 `FC_SCALE` / `FC_ZP`，**不要凭记忆**。输入侧 `IN_SCALE`/`IN_ZP` 这次没变（0.018179998 / −12），但同样要核。

## 三、板端文件与调用方式

| 文件 | 作用 |
|---|---|
| `cnn_pl_infer.py` | `PLClassifier`，**接口与 `tflite_infer.Classifier` 完全一致**（`classify(roi_bgr) → (cid, name, garb, conf)`），所以 `track.py` / `osd.py` 一行都不用改 |
| `cnn_pl_test.py` | 独立上板自检与时序测量脚本 |
| `tflite_infer.py` | PS 参考实现；`cnn_pl_infer` **复用它的 `preprocess()`**，绝不复写 |

▶ **切 PL 识别**：`osd_live(None, clf=clf_pl)`（`osd.py` 里 `AUTO_RUN` 必须先改 `False`）
▶ **切 PS 识别**：`%run osd.py` 直接就是（AUTO_RUN 块里建的是 `Classifier('model_int8_64.tflite', num_threads=2)`）

## 四、★ 本工程专属的坑

| 坑 | 现象 | 正解 |
|---|---|---|
| **读掩膜忘了先切档** | `detect()` 返回**一个覆盖整幅画面**的框（`(0,0,972,720)`），裁出来的 ROI 是 `(720, 962, 3)`；预处理从 7 ms 涨到 **58 ms** | 读 `v1[0]` 之前**必须 `set_disp(5)`**。`detect.py` 和 `osd_live()` 里都有这一句，自己写调试 cell 时最容易漏 |
| `tflite_infer.py` 的输入尺寸 | 盘上旧版是 `SIZE = 42` + 默认 `'model.tflite'`；**这两个都对不上 64×64 模型**，PL 会往 12288 字节缓冲写 5292 字节 ⇒ `ValueError` | 板端版本是 `SIZE = 64` + `'model_int8_64.tflite'` + `num_threads=2`。**判据：`print(ti.SIZE)` 必须是 64** |
| 两个 tflite 文件同大小 | `model_int8.tflite` 与 `model_int8_64.tflite` **都是 408,464 字节**，无法靠字节数区分 | GAP 之后张量形状与分辨率无关、参数量相同 ⇒ 只能看 `IMG_W` 宏 / golden 字节数（12288）判断 |
| `osd.py` 硬编码模型名 | 第 291 行写死 `Classifier('model_int8.tflite')`，该文件已不存在 | 传 `osd_live(None, clf=...)` 就不会走那条路径；或直接改文件名 |
| 运动画面撕裂 | 静止画面正常，**一运动就出现横向撕裂** | VDMA GenLock 下 `FRMDLY=0` 时 MM2S 读的正是 S2MM 正在写的那一帧 ⇒ 显示通路的帧延迟设 **≥1** |
| **模型文件名多一个空格** | 传上来的是 `model_int8_64 .tflite`（`.` 前多一个空格），而 `osd.py` 找的是 `model_int8_64.tflite` | 上传前 `dir` 一眼核名字。**Windows 资源管理器里这个空格很容易看不见**，代码侧只会报"文件不存在" |
| 重启内核后寄存器复位 | 掩膜全黑 / 掩膜全白 / 相机不出图 | `%run cam_full.py` 之后必须**重跑 `config.py`**；`capture_bg()` 必须在**空场景、放物体之前**跑 |

## 五、已实测数字

### v1.3（POC=8，2026-10-26）

| 项 | 值 |
|---|---|
| 纯推理（AP_START → AP_DONE） | **22.96 ms**（中位；min 22.64；前 3 次冷启 29~36） |
| `classify()` 全程 | **35.6 ms**（预处理 ≈7 + 量化 3.14 + 其余 ≈1.4 + 本体 23.65） |
| 整链循环 | 找框 25.2 + CNN 31.8（0.894 次/帧）+ 记账 3.1 = **60.1 ms ⇒ 16.6 Hz** |
| 资源 | CNN OOC：LUT 14,821 / FF 15,842 / BRAM 46.5 / DSP 52；整链 WNS **+0.336** |

### v1.4（POC=16 + 权重 64 位宽读，2026-10-28 构建完成）

| 项 | 值 |
|---|---|
| 内层 MAC 迭代 | 1,032,192 → **516,096** |
| 权重载入 | II 128 → **16**；0.39 M 拍（3.9 ms）→ **0.049 M 拍（0.49 ms）** |
| 最高频域总延迟（HLS 估计） | 83.4 M → **41.6 M 拍** |
| 资源（CNN 折算） | LUT ≈**18,728** / FF ≈17,548 / BRAM ≈53.5 / DSP **84** |
| 资源（整链布线后） | LUT 38,630 (72.61%) / FF 41,019 (38.55%) / BRAM 67.5 (48.21%) / **DSP 91 (41.36%)** / Slice 13,110 (98.57%) |
| 时序 | **WNS +0.182 ns**，TNS 0，0 违例端点，`All user specified timing constraints are met` |
| 最差路径 | **在 `u_osd` 文字渲染**（`tx_reg[5][3] → t_rr_d1_reg[1]`，12 级逻辑 / 5 个 CARRY4），**不在 CNN** —— 整体变大后布局拥挤所致 |
| 板端实测推理/整链 | **待测**（构建后第一件事；预测内核 ~7 ms） |

## 六、下一步（本项目）

1. **上板验 v1.4**：`clf_pl.selftest()` 必须先 PASS（黄金值见第二节），再测单次耗时。
2. **并行化**：CNN 移出主循环（worker 线程 + 队列），主循环只剩 28.3 ms ⇒ 29 Hz 满帧。判据：日志打 28~29 Hz 且目标数不丢。
3. ~~预处理+量化合并成 256 项 LUT~~ **已完成（2026-10-28）**：见 `../pl-accelerator-host-driver/SKILL.md` 的"主机侧预处理查表化"，逐字节等价已验证（200 张随机图 + 全 0/全 255 边界，0 处不一致）。
4. 基地址不必每帧重写（省 0.36 ms）。
5. 若还想再快：`POC=32`（DSP 约 148 = 67%，超出当时定的 60% 线）或把 `C_M_AXI_GMEM_DATA_WIDTH` 提到 64（权重载入还能再省 ~0.25 ms，收益已很小）。

## 七、来源

从 2026-10-26 一整天的下放、调试、拆账过程中形成。最贵的两个教训：

- **自己写的调试 cell 漏了 `set_disp(5)`**，把整幅原图当成掩膜喂进 `detect()` ⇒ 得到全画面框 ⇒ 由此产生的"预处理 58 ms""PS 97.7 ms""PL 只快 1.13×"三个结论全部作废。数字能反证：全幅框 `(0,0,972,720)` 裁出来正好是 `(720, 962)`。
- **同一工程的板端文件与本地盘上文件版本不一致**（`tflite_infer.py` 的 `SIZE` 与 `num_threads`）。任何"读某文件的某个值"的断言，都要先确认读到的是**板端那一份**。

## Version History

| 版本 | 日期 | 变更 |
|---|---|---|
| 1.0.0 | 2026-10-26 | 首次成文 |
| 1.1.0 | 2026-10-28 | 换新模型 + IP 升级到 1.4（POC 16、权重 64 位宽读）：新增"换模型完整流程"与 **FC 输出零点会变**的陷阱、文件名带空格的坑、v1.4 实测资源/时序（WNS +0.182，最差路径在 OSD 不在 CNN）、预处理查表化标记完成 |

## 相关文件（Integration）

- `../hls-accelerator-on-pl/SKILL.md` —— 加速器怎么设计的（通用）
- `../pl-accelerator-host-driver/SKILL.md` —— 主机侧怎么驱动的（通用）
- `../vivado-bd-ops/SKILL.md` —— IP 换版与重建流程
- `设计报告第 6 章` —— 视频链路的坑（本项目仍在用同一套链路）
