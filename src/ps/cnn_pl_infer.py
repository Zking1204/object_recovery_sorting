###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：cnn_pl_infer.py
# 角色   ：按钮②第 3 步：PL int8 CNN 加速器驱动。写 6 个基地址、载入 4 个权重 bin、表驱动预处理、infer / selftest
# 依赖   ：tflite_infer（取标签表与预处理参数）
# 启动   ：按钮②，或 %run cnn_pl_infer.py
###########################################################################
# -*- coding: utf-8 -*-
"""
cnn_pl_infer.py —— 用 PL 上的 CNN 加速器替代 tflite，接口与 tflite_infer.Classifier 完全一致

【为什么这样接】
  track.py 只认一个东西：clf.classify(roi_bgr) -> (cid, name, garb, conf)，判为未知时 cid=-1。
  所以这里做一个 **drop-in 替换**：track.py / osd.py 一行都不用改，只要把 clf 换成 PLClassifier。

【和 tflite 版的唯一区别】
  tflite 版把 float32 张量喂给模型，模型内部第一步是 QUANTIZE（float→int8）；
  我们直接把那一步在 numpy 里做掉，把 int8 送进 PL：
      q = clip(round_half_away(x / IN_SCALE) + IN_ZP, -128, 127)
  这里的 IN_SCALE / IN_ZP 必须和模型里的 QUANTIZE 参数**一字不差**（取自 model_meta.h），
  预处理也必须和训练端一致 —— 所以下面直接复用 tflite_infer.preprocess()，绝不复写。

【用法】
    %run cam_full.py        # 加载 overlay（含新位流）、建好相机链路
    capture_bg()            # 空场景采背景（传送带要转起来、带上空无一物）
    %run config.py          # 曝光/AWB 锁定 + 掩膜参数
    %run detect.py
    %run tflite_infer.py    # 只为拿 preprocess / LABELS / GARBAGE
    %run cnn_pl_infer.py    # 本文件：建好 clf_pl
    %run track.py
    osd_live(None, clf=clf_pl)     # ★ 把 clf 换成 PL 版（osd.py 里 AUTO_RUN 建议改 False）

【自检】
    clf_pl.selftest()   # 喂模型自带的黄金向量，logits 必须等于 [-39,95,7,-116,-49,-128]
                        # （★ 2026-10-28 换了新模型后更新：旧模型是 [-76,66,115,-128,-123,-126]）

【2026-10-28 v1.4 两处改动】
  ① 量化参数随新模型更新：FC_SCALE 0.087355129->0.113328353、FC_ZP 0->-3。
     ★ 输入侧 IN_SCALE / IN_ZP 没变（0.018179998 / -12），所以预处理后的量化结果一致。
  ② 预处理 + 量化合并成 **每通道 256 项查表**：原来 float 换算 + mean/std + 量化共 ~10.2 ms，
     现在只剩 cv2 缩放 + 一次 gather，实测降到 ~1.5 ms。数值逐字节等价（见 quantize_roi）。
"""

import time
import numpy as np
import cv2
from pynq import MMIO, Overlay, allocate

import tflite_infer as ti          # ★ 复用它的 preprocess / LABELS / GARBAGE / SIZE

# ---------------------------------------------------------------- 量化参数
# ★ 必须与 model_meta.h 里的 IN_SCALE / IN_ZP / FC_SCALE / FC_ZP 完全一致
IN_SCALE = 0.018179998             # 输入 float→int8 的 scale（模型 QUANTIZE 那一步；新模型未变）
IN_ZP = -12                        # 输入零点
FC_SCALE = 0.113328353             # ★ 新模型：输出 int8→float 的 scale（DEQUANTIZE）
FC_ZP = -3                         # ★ 新模型：输出零点（旧模型是 0，别再用 0）
N_CLASS = 6                        # 类别数

# ---------------------------------------------------------------- 寄存器偏移
# 来自 Vitis HLS 的 s_axilite 寄存器表；每个指针占低/高两个 32 位
R_CTRL = 0x00                      # [0]=AP_START [1]=AP_DONE [2]=AP_IDLE [3]=AP_READY
R_BLOB = 0x10                      # 权重基地址
R_BIAS = 0x1C                      # 偏置基地址
R_MMUL = 0x28                      # requant 乘数基地址
R_MSHF = 0x34                      # requant 移位基地址
R_IN = 0x40                        # 输入图像基地址
R_OUT = 0x4C                       # 输出基地址
BIT_START = 0x01                   # 启动位
BIT_DONE = 0x02                    # 完成位（电平，跑完保持到下次启动）

CNN_BASE = 0x43C30000           # 加速器 AXI-Lite 基址（BD 里分配的地址）
CNN_RANGE = 0x1000             # 4KB 窗口
N_BLOB = 390912                    # 权重字节数
N_BIAS = 486                       # 偏置个数
N_MUL = 742                        # 乘数个数
N_IN = 64 * 64 * 3                 # 输入字节数
N_OUT = 4                          # 输出 4 个 int32（[0][1]=logits，[2]=信标，[3]备用）
TIMEOUT_S = 5.0                    # 任何等待都带超时，绝不无限挂住


def quantize_input(x):
    """float32 (1,64,64,3) → int8 (12288,)，语义与 tflite 的 QUANTIZE 一致。
       ★ 四舍五入必须用"远离零"的规则（std::round），不能用 np.round 的银行家舍入，
         否则边界值会差 1 LSB，逐层放大后 logits 就不是逐字节一致了。"""
    v = x.astype(np.float32).reshape(-1) / np.float32(IN_SCALE)   # 缩放
    v = np.trunc(v + np.sign(v) * np.float32(0.5)).astype(np.int32)  # 远离零取整
    v = v + IN_ZP                                                  # 加零点
    return np.clip(v, -128, 127).astype(np.int8)                   # 夹到 int8 范围


def dequantize_logits(q):
    """int8 logits → float32（模型 DEQUANTIZE 那一步）"""
    return (q.astype(np.float32) - np.float32(FC_ZP)) * np.float32(FC_SCALE)


# ============================================================ 预处理查表化
# 为什么要这么做：原来一帧的预处理是
#     letterbox(64x64) → astype(float32) → /255 → (x-mean)/std → /IN_SCALE → 取整+零点
# 其中后面四步都是**逐像素的一维映射**，输入只有 0~255 这 256 个可能值 ⇒
# 整个链条可以预先算成"每通道 256 项的表"，运行时只剩一次 gather。
# ★ 数值必须逐字节等价：这里所有算术都用 float32、且运算顺序与 tflite_infer.preprocess
#   + quantize_input 完全一致（先 /255、再减 mean、再除 std、再除 IN_SCALE、最后远离零取整）。
def build_quant_lut():
    """返回 (3,256) 的 uint8 表；tab[c][v] = 通道 c 上像素值 v 量化后的 int8（位模式）"""
    tab = np.empty((3, 256), dtype=np.uint8)                    # 每通道一张 256 项表
    v = np.arange(256, dtype=np.float32)                        # 像素值 0~255
    for c in range(3):                                          # R / G / B 三个通道各一张
        x = v / np.float32(255.0)                               # ① /255（与 preprocess 一致）
        x = (x - np.float32(ti.IMGNET_MEAN[c])) / np.float32(ti.IMGNET_STD[c])  # ② ImageNet 归一化
        x = x / np.float32(IN_SCALE)                            # ③ 除以量化 scale
        x = np.trunc(x + np.sign(x) * np.float32(0.5))           # ④ 远离零取整（不是银行家舍入）
        x = np.clip(x + IN_ZP, -128, 127).astype(np.int8)        # ⑤ 加零点并夹到 int8
        tab[c] = x.view(np.uint8)                               # 存位模式，转 int8 时零开销
    return tab


def _ipy_ns():
    """交互命名空间（notebook 那一层）。
       ★ 为什么需要：IPython 的 `%run` **默认在一个独立命名空间里执行文件**（只有 `%run -i`
         才共享交互命名空间）⇒ 文件里的 globals() 看不到 notebook 里 cam_full.py 建的 `ol`。
         本工程实测踩过：cam_full 明明跑完了，这里却报"命名空间里没有 ol"。"""
    try:
        ip = get_ipython()                                   # notebook 里有，纯 python 里没有
        return ip.user_ns if ip is not None else {}
    except Exception:
        return {}


def _find_overlay():
    """在【交互命名空间 / __main__ / 本文件 globals】三处找 cam_full.py 建的那个 Overlay。
       不认死变量名（ol / overlay / ov …都行），直接看"哪个名字是 Overlay 实例"。
       返回 (变量名, 对象)；找不到返回 (None, None)。"""
    import sys as _sys
    from pynq import Overlay as _OV
    seen = []                                                # 所有 Overlay 实例
    for src in (_ipy_ns(),                                   # ① notebook 命名空间（最可能）
                getattr(_sys.modules.get('__main__'), '__dict__', {}),  # ② __main__
                globals()):                                  # ③ 本文件
        for k, v in list(src.items()):
            if isinstance(v, _OV) and all(v is not s[1] for s in seen):
                seen.append((k, v))
    for k, v in seen:                                        # 优先挑含 cnn_top 的那个
        if any('cnn_top' in kk.lower() for kk in getattr(v, 'ip_dict', {})):
            return k, v
    return (seen[0][0], seen[0][1]) if seen else (None, None)


class PLClassifier:
    """PL 版分类器：接口与 tflite_infer.Classifier 完全一致"""

    def __init__(self, model_dir="."):
        # ---- 1. 挂到**已经加载好**的加速器上（★ 绝不自己再 Overlay 一次）----
        # 为什么要这样：cam_full.py 已经把位流烧进去并把相机链路（VDMA/VTC/dynclk）
        # 配置好了。再调一次 Overlay() 会**重新编程 PL**，fabric 里的寄存器全部复位，
        # 相机链路当场失效。这里只做一次 MMIO 映射，什么都不碰。
        # ★ 优先复用已经加载过的 overlay 里的 IP 对象（cam_full.py 加载的那个）：
        #   PYNQ 会把所有已加载的 overlay 记在 Overlay._instances 里。用 IP 对象
        #   比裸 MMIO 可靠 —— 独立测试时 ol.cnn_top_0 读出 CTRL=0x04，而裸 MMIO
        #   读到 0x00（说明句柄没真正连到加速器上）。
        self.ip = None
        # ★ 2026-10-28 修 bug：原来用 Overlay._instances，而本版 PYNQ(3.0.1) 的 Overlay
        #   类**根本没有这个属性** ⇒ getattr 兜底成 {} ⇒ 静默退回裸 MMIO ⇒ CTRL 读到 0。
        # ★ 2026-10-28 第二版：不再认死名字 "cnn_top_0"，改成在 ip_dict 里按子串找
        #   （PNYQ 的 key 可能带层级前缀）；找不到就把真实 key 全打出来。
        # ★ 2026-10-28 第三版：不再依赖 globals() —— %run 的命名空间是独立的，
        #   cam_full.py 建的 ol 不在本文件的 globals() 里。改成去交互命名空间里找实例。
        _oname, _ol = _find_overlay()                                 # 找任何已加载的 Overlay
        if _ol is None:                                               # 真的一个都没有
            print("!! 找不到任何已加载的 Overlay 实例 —— cam_full.py 没跑过，或跑在别的内核里", flush=True)
        else:
            _ids = sorted(getattr(_ol, "ip_dict", {}).keys())          # 这个 overlay 认识哪些 IP
            _hit = [k for k in _ids if "cnn_top" in k.lower()]         # 按子串找加速器
            if _hit:                                                   # 找到了
                self.ip = getattr(_ol, _hit[0])                        #    复用真实 IP 对象
                print("PL 加速器句柄：%s.%s" % (_oname, _hit[0]), flush=True)
            else:                                                      # 没找到 ⇒ 把清单打出来
                print("!! %s.ip_dict 里没有含 'cnn_top' 的项。实际有 %d 个："
                      % (_oname, len(_ids)), flush=True)
                for _k in _ids:
                    print("     %s" % _k, flush=True)
        if self.ip is None:                                            # 还没拿到才自己映射
            print("!! 退回裸 MMIO 0x%08X（能读写，但拿不到 IP 的元信息）" % CNN_BASE, flush=True)
            self.ip = MMIO(CNN_BASE, CNN_RANGE)
        self._ptr_ready = False

        # ---- 预处理查表（每通道 256 项），把 float 换算那 ~10 ms 全部省掉 ----
        # ★ 防线：加速器固定吃 64×64×3 = 12288 字节，而 letterbox 的尺寸由
        #   ti.SIZE 决定。板上那份 tflite_infer.py 必须是 SIZE=64；盘上那份是 42，
        #   万一把盘上的覆盖上去，letterbox 只会产出 5292 字节，这里先炸掉，
        #   免得变成后面一句看不懂的 numpy 形状错误。
        if int(ti.SIZE) != 64:
            raise RuntimeError(
                "tflite_infer.SIZE=%d，但 PL 加速器要 64 —— 板上那份 tflite_infer.py 是旧的！"
                % int(ti.SIZE))
        self._lut = build_quant_lut().reshape(-1)                    # (768,) uint8，索引 = c*256+v
        self._n_lut = int(ti.SIZE) * int(ti.SIZE) * 3                # 一张图共多少个字节
        self._choff = (np.arange(self._n_lut, dtype=np.int32) % 3) * 256  # 每个字节该查哪张表

        # ---- 2. 申请连续 DDR 缓冲（普通 numpy 不连续，PL 按地址读会读错）----
        self.b_w = allocate(shape=(N_BLOB,), dtype=np.uint8)        # 权重
        self.b_b = allocate(shape=(N_BIAS,), dtype=np.int32)        # 偏置
        self.b_m = allocate(shape=(N_MUL,), dtype=np.int32)         # 乘数
        self.b_s = allocate(shape=(N_MUL,), dtype=np.int32)         # 移位
        self.b_i = allocate(shape=(N_IN,), dtype=np.int8)           # 输入图
        self.b_o = allocate(shape=(N_OUT,), dtype=np.uint32)        # 输出

        # ---- 3. 一次性把静态数据读进 DDR（权重/偏置/乘数/移位都不随帧变化）----
        self.b_w[:] = np.fromfile(model_dir + "/model_blob.bin", dtype=np.uint8)
        self.b_b[:] = np.fromfile(model_dir + "/model_bias.bin", dtype=np.int32)
        self.b_m[:] = np.fromfile(model_dir + "/model_mmult.bin", dtype=np.int32)
        self.b_s[:] = np.fromfile(model_dir + "/model_mshift.bin", dtype=np.int32)
        self.b_w.flush()                                            # 刷到 DDR，PL 才看得到
        self.b_b.flush()
        self.b_m.flush()
        self.b_s.flush()
        self.b_o.flush()

        # ---- 4. 写 6 个基地址 ----
        self.write_ptrs()

        self.th = 0.5                                               # 拒识阈值（与 tflite 版同占位值）
        self.n_calls = 0                                            # 统计用
        self.t_total = 0.0                                          # 累计耗时

    # ------------------------------------------------------------ 基地址
    def write_ptrs(self):
        """把 6 个缓冲的物理地址写进寄存器。
           ★ 每次推理前都重写：如果中途重跑过 cam_full.py（重新编程 PL），fabric 里
             的寄存器会被复位，基地址就没了 —— 那时 CTRL 会读出 0x00。"""
        def set_ptr(base, addr):
            self.ip.write(base + 0, addr & 0xFFFFFFFF)               # 低 32 位
            self.ip.write(base + 4, (addr >> 32) & 0xFFFFFFFF)       # 高 32 位
        set_ptr(R_BLOB, self.b_w.physical_address)                   # 权重
        set_ptr(R_BIAS, self.b_b.physical_address)                   # 偏置
        set_ptr(R_MMUL, self.b_m.physical_address)                   # 乘数
        set_ptr(R_MSHF, self.b_s.physical_address)                   # 移位
        set_ptr(R_IN, self.b_i.physical_address)                     # 输入
        set_ptr(R_OUT, self.b_o.physical_address)                    # 输出
        self._ptr_ready = True

    # ------------------------------------------------------------ 自诊断
    def status(self):
        """打印当前状态，排查"读不到加速器"用"""
        c = self.ip.read(R_CTRL)
        print("CTRL=0x%08X  AP_START=%d AP_DONE=%d AP_IDLE=%d AP_READY=%d"
              % (c, c & 1, (c >> 1) & 1, (c >> 2) & 1, (c >> 3) & 1), flush=True)
        print("  blob=%#x in=%#x out=%#x" % (self.ip.read(R_BLOB), self.ip.read(R_IN),
                                              self.ip.read(R_OUT)), flush=True)
        return c

    # ------------------------------------------------------------ 跑一次
    def infer(self, img_i8):
        """把已量化好的 int8(12288) 喂进 PL，返回 6 个 float logit"""
        self.b_i[:] = img_i8                                        # 写入输入缓冲
        self.b_i.flush()                                            # ★ 不 flush 的话 PL 读到旧数据
        self.write_ptrs()                                           # ★ 每帧重写基地址（防被清）

        # 直接启动。不再死等 AP_IDLE —— 它只在"运行完成后"才被硬件拉高，
        # 一旦读到 0 就永远等不到（实测踩过 CTRL=0x00000000 卡死）。
        self.ip.write(R_CTRL, BIT_START)                            # 启动

        # ★ AP_DONE 是电平，上一轮跑完会一直保持高，直到本次启动才清；
        #   所以必须先看到它落下去，才能确认这次启动被接受
        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl:
            v = self.ip.read(R_CTRL)
            if (v & BIT_DONE) == 0 or (v & 0x04) == 0:
                break
        else:
            raise RuntimeError("启动没被接受, CTRL=0x%08X" % self.ip.read(R_CTRL))

        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl:
            if self.ip.read(R_CTRL) & BIT_DONE:                     # 真的算完了
                break
        else:
            raise RuntimeError("等 AP_DONE 超时, CTRL=0x%08X" % self.ip.read(R_CTRL))

        self.b_o.invalidate()                                       # ★ 读前作废 cache
        w0 = int(self.b_o[0])                                       # cls0..3
        w1 = int(self.b_o[1])                                       # cls4..5
        raw = [(w0 >> (8 * i)) & 0xFF for i in range(4)] + [(w1 >> (8 * i)) & 0xFF for i in range(2)]
        q = np.array([b - 256 if b >= 128 else b for b in raw], np.int8)   # 还原成有符号
        return dequantize_logits(q)                                 # int8 → float

    # ------------------------------------------------------------ 预处理（查表版）
    def quantize_roi(self, roi_bgr):
        """ROI(BGR, 任意尺寸) → int8(12288)，与 ti.preprocess()+quantize_input() 逐字节等价"""
        rgb = cv2.cvtColor(roi_bgr, cv2.COLOR_BGR2RGB)               # ① 通道序与训练端对齐
        lb = ti.letterbox(rgb)                                       # ② ★ 复用板端那份 letterbox
        flat = lb.reshape(-1)                                        # ③ 展平（连续数组，零拷贝视图）
        if flat.size != self._n_lut:                                 # ④ 尺寸变了就重建通道偏移
            self._n_lut = flat.size                                  #     （正常情况下不会触发）
            self._choff = (np.arange(self._n_lut, dtype=np.int32) % 3) * 256
        return self._lut[flat + self._choff].view(np.int8)            # ⑤ 一次 gather 得到 int8

    # ------------------------------------------------------------ 对外接口
    def classify(self, roi_bgr):
        """与 tflite_infer.Classifier.classify 完全一致的 4 元组返回"""
        ts = time.perf_counter()
        q = self.quantize_roi(roi_bgr)                              # ★ 预处理+量化合并成全表查询
        z = self.infer(q)                                           # PL 推理 + 反量化
        e = np.exp(z - z.max())                                     # softmax 第一步：减最大值防溢出
        p = e / e.sum()                                             # softmax 第二步：归一化
        cid = int(np.argmax(p))                                     # 概率最大的类
        conf = float(p[cid])                                        # 它的概率
        self.n_calls += 1                                           # 计数
        self.t_total += time.perf_counter() - ts                    # 累计耗时
        if conf < self.th:                                          # 低于阈值 ⇒ 当作没教过的东西
            return -1, '未知', '未知', conf                          # 不硬塞进某一类
        name = ti.LABELS[cid]                                       # 类名
        return cid, name, ti.GARBAGE[name], conf                    # 正常返回

    # ------------------------------------------------------------ 自检
    def selftest(self, golden="golden_in.bin"):
        """喂黄金向量，logits 必须等于 [-39,95,7,-116,-49,-128]（新模型的 int8 域）
           ★ 2026-10-28：开头必须 self.write_ptrs()。因为 %run cam_full.py 会重新编程 PL，
             cnn_top 里那 6 个基地址寄存器会被清零；而 selftest 原来不写它们（只有 infer 写）
             ⇒ 只要在 clf_pl 建好之后又跑过 cam_full，selftest 就一定读到垃圾。
             实测踩过一次：表现为"退回裸 MMIO + selftest 不过"，很容易误判成位流/bin 是旧的。"""
        self.write_ptrs()                                           # ★ 先把 6 个基地址重写一遍
        g = np.fromfile(golden, dtype=np.int8)                      # 12288 字节
        self.b_i[:] = g                                             # 直接写 int8，不过预处理
        self.b_i.flush()                                            # 刷到 DDR
        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl and not (self.ip.read(R_CTRL) & 0x04):
            pass
        self.ip.write(R_CTRL, BIT_START)
        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl:
            v = self.ip.read(R_CTRL)
            if (v & BIT_DONE) == 0 or (v & 0x04) == 0:
                break
        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl and not (self.ip.read(R_CTRL) & BIT_DONE):
            pass
        self.b_o.invalidate()
        w0, w1 = int(self.b_o[0]), int(self.b_o[1])
        raw = [(w0 >> (8 * i)) & 0xFF for i in range(4)] + [(w1 >> (8 * i)) & 0xFF for i in range(2)]
        got = [b - 256 if b >= 128 else b for b in raw]
        exp = [-39, 95, 7, -116, -49, -128]                          # 新模型(seed=1234)的 int8 logits
        print("期望 logits:", exp, flush=True)
        print("实际 logits:", got, flush=True)
        print("=== %s ===" % ("PASS" if got == exp else "FAIL"), flush=True)
        return got == exp

    def ms_per_call(self):
        """最近的平均单次耗时（含预处理）"""
        return (self.t_total / self.n_calls) * 1000.0 if self.n_calls else 0.0


# ---- 自动建一个实例（%run 后直接用 clf_pl）----
try:
    clf_pl = PLClassifier()
    print("PL 分类器就绪（v1.4：预处理已合并成 256 项查表）；先跑 selftest() 自检", flush=True)
except Exception as _e:
    clf_pl = None
    print("!! PL 分类器初始化失败：%s" % _e, flush=True)
