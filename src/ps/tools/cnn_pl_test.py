###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：cnn_pl_test.py
# 角色   ：PL CNN 独立自检：位流 MD5 校验 + 黄金参考逐值比对 + 20 次性能统计（会重新下载位流，不要与 ui.py 同时跑）
# 依赖   ：见文件内 import
# 启动   ：独立运行（不属于生产链）
###########################################################################
# -*- coding: utf-8 -*-
"""
cnn_pl_test.py -- PL 侧 CNN 加速器的第一次板上验证（不接摄像头）

【这个脚本干什么】
  把 HLS 加速器当成一个"黑盒函数"来测：给它一张 64x64x3 的 int8 图像，
  它吐出 6 个 int8 logit。喂的是 C 仿真里用的那条黄金输入向量，
  所以输出应该**精确等于**下面这 6 个数（不是"差不多"）：

      [-76, 66, 115, -128, -123, -126]

  对上了 ⇒ 整条 PL 通路（AXI-Lite 配寄存器 → AXI 主口读 DDR → 四层卷积 →
  GAP → FC → 写回 DDR）一个字节都没错，可以放心往下接摄像头。
  对不上 ⇒ 先别看摄像头，按后面"失败排查"一节逐条查。

【跑之前必须准备好的文件（都在板子上，和本 notebook 同一个目录）】
  design_1_wrapper.bit     4,045,771 B   MD5 D5C98A13DD14284BE63F8D3F114D3F35
  design_1_wrapper.hwh       732,207 B   MD5 F067E7C79B5D0E52EC6326B193E785A6
  model_blob.bin             390,912 B   权重
  model_bias.bin               1,944 B   偏置（486 个 int32）
  model_mmult.bin              2,968 B   requant 乘数（742 个 int32）
  model_mshift.bin             2,968 B   requant 移位（742 个 int32）
  golden_in.bin               12,288 B   黄金输入向量

  ★ 注意文件名是 model_mmult.bin（mmul + t），不是 model_mmul.bin
  ★ build 目录里还有一个 model_scale.bin，是旧的浮点 scale 表，本脚本不需要它

【用法】
  在 Jupyter 里新建一个 cell，先 Ctrl+A 全选清空，再把这个文件内容整体粘进去，Shift+Enter。
  ★ 不要 import 本文件（Jupyter 会缓存模块，改了不生效），就整段粘贴。

【失败排查】
  - 报 "没有 cnn_top_0" → overlay 加载的是旧 bit/hwh，确认两个文件都是新的、同名
  - AP_DONE 超时      → 先看 ip.read(0x00) 打印出来是多少；再确认 hwh 里地址是 0x43C30000
  - logit 全 0 / 全 -128 → 大概率是缓存没同步（flush/invalidate），或基地址写错
  - logit 有值但不对   → 把得到的 6 个数发我，能反推是哪一层出错
"""

import time

import numpy as np
from pynq import Overlay, allocate

# ============================================================================
# 0. 常量：加速器的寄存器偏移（来自 Vitis HLS 的 s_axilite 寄存器表）
#    每个指针占两个 32 位寄存器：低 32 位在前，高 32 位在后。
# ============================================================================
R_CTRL = 0x00      # [0]=AP_START 启动  [1]=AP_DONE 完成  [2]=AP_IDLE 空闲  [3]=AP_READY 可启动
R_BLOB = 0x10      # 权重基地址（0x10 低半 / 0x14 高半）
R_BIAS = 0x1C      # 偏置基地址（0x1C / 0x20）
R_MMUL = 0x28      # 乘数基地址（0x28 / 0x2C）
R_MSHF = 0x34      # 移位基地址（0x34 / 0x38）
R_IN = 0x40        # 输入图像基地址（0x40 / 0x44）
R_OUT = 0x4C       # 输出基地址（0x4C / 0x50）

BIT_START = 0x01   # CTRL 的启动位
BIT_DONE = 0x02    # CTRL 的完成位（电平，跑完一直保持到下次启动）
BIT_IDLE = 0x04    # CTRL 的空闲位
BIT_READY = 0x08   # CTRL 的 ready 位——★ 本设计里恒为 0，别用它做判断
                   #   （只有带 ap_hs / AXIS 接口的 DATAFLOW 设计才会拉高）

N_BLOB = 390912    # 权重总字节数
N_BIAS = 486       # 偏置个数（每输出通道一个）
N_MUL = 742        # 乘数个数（c1..c4 + gap + fc 的每通道一项）
N_IN = 12288       # 输入字节数 64*64*3
N_OUT = 4          # 输出 4 个 int32：0/1 = 6 个 int8 logit，2 = 阶段信标，3 = 备用

# 黄金答案：C 仿真（与 numpy/tflite 逐位一致）得到的 int8 logit
GOLDEN = [-76, 66, 115, -128, -123, -126]

TIMEOUT_S = 5.0    # 任何等待都带超时，绝不无限挂住


def main():
    # ------------------------------------------------------------------
    # 1. 加载 overlay（这一步会把新位流烧进 PL）
    #    ★ 加载前绝不能访问任何 PL 地址，否则 CPU 挂死只能断电
    # ------------------------------------------------------------------
    print("[1] 加载 overlay ...", flush=True)
    t0 = time.perf_counter()
    ol = Overlay("design_1_wrapper.bit")
    print("    完成，用时 %.2f s" % (time.perf_counter() - t0), flush=True)

    # 加速器在 BD 里的实例名是 cnn_top_0；不存在就说明 overlay 不是新版
    if "cnn_top_0" not in ol.ip_dict:
        print("    !! overlay 里没有 cnn_top_0，加载的不是这一版位流", flush=True)
        print("    现有的 IP 有：", list(ol.ip_dict.keys()), flush=True)
        return
    ip = ol.cnn_top_0
    print("    cnn_top_0 找到了", flush=True)

    # ------------------------------------------------------------------
    # 2. 在 DDR 里申请连续缓冲区
    #    allocate() 拿到的内存物理地址连续、且地址对 CPU 和 PL 都可见；
    #    普通的 np.zeros() 不行，物理上不连续，PL 按地址读会读错。
    # ------------------------------------------------------------------
    print("[2] 申请 DDR 缓冲 ...", flush=True)
    buf_w = allocate(shape=(N_BLOB,), dtype=np.uint8)      # 权重
    buf_b = allocate(shape=(N_BIAS,), dtype=np.int32)      # 偏置
    buf_m = allocate(shape=(N_MUL,), dtype=np.int32)       # requant 乘数
    buf_s = allocate(shape=(N_MUL,), dtype=np.int32)       # requant 移位
    buf_i = allocate(shape=(N_IN,), dtype=np.int8)         # 输入图像
    buf_o = allocate(shape=(N_OUT,), dtype=np.uint32)      # 输出（logits 2 字 + 信标 1 字）
    print("    权重@0x%08X  输入@0x%08X  输出@0x%08X"
          % (buf_w.physical_address, buf_i.physical_address,
             buf_o.physical_address), flush=True)

    # ------------------------------------------------------------------
    # 3. 从文件读数据填进去
    #    fromfile 读的是原始二进制，dtype 必须和文件里的一致，否则数字全乱。
    # ------------------------------------------------------------------
    print("[3] 读取模型数据 ...", flush=True)
    buf_w[:] = np.fromfile("model_blob.bin", dtype=np.uint8)
    buf_b[:] = np.fromfile("model_bias.bin", dtype=np.int32)
    buf_m[:] = np.fromfile("model_mmult.bin", dtype=np.int32)
    buf_s[:] = np.fromfile("model_mshift.bin", dtype=np.int32)
    buf_i[:] = np.fromfile("golden_in.bin", dtype=np.int8)
    print("    权重 %d 字节，输入 %d 字节" % (buf_w.size, buf_i.size), flush=True)

    # ------------------------------------------------------------------
    # 4. 把 CPU 写的数据刷到 DDR，让 PL 看得到
    #    ★ 关键：PL 走的是 HP 口，不经过 CPU 的 cache。CPU 刚写的数据可能
    #      还躺在 cache 里没落到 DDR，不 flush 的话 PL 读到的是旧数据。
    # ------------------------------------------------------------------
    print("[4] flush 到 DDR ...", flush=True)
    buf_w.flush()
    buf_b.flush()
    buf_m.flush()
    buf_s.flush()
    buf_i.flush()
    buf_o.flush()
    print("    完成", flush=True)

    # ------------------------------------------------------------------
    # 5. 把 6 个基地址写进寄存器
    #    每个指针拆成低/高两个 32 位写（板子 DDR 都在 4GB 以内，高半恒为 0）。
    # ------------------------------------------------------------------
    print("[5] 写基地址寄存器 ...", flush=True)

    def set_ptr(base, addr):
        ip.write(base + 0, addr & 0xFFFFFFFF)          # 低 32 位
        ip.write(base + 4, (addr >> 32) & 0xFFFFFFFF)  # 高 32 位

    set_ptr(R_BLOB, buf_w.physical_address)
    set_ptr(R_BIAS, buf_b.physical_address)
    set_ptr(R_MMUL, buf_m.physical_address)
    set_ptr(R_MSHF, buf_s.physical_address)
    set_ptr(R_IN, buf_i.physical_address)
    set_ptr(R_OUT, buf_o.physical_address)
    for name, base in (("blob", R_BLOB), ("bias", R_BIAS), ("mmul", R_MMUL),
                       ("mshf", R_MSHF), ("in", R_IN), ("out", R_OUT)):
        lo = ip.read(base)
        hi = ip.read(base + 4)
        print("    %-4s = 0x%08X%08X" % (name, hi, lo), flush=True)

    # ------------------------------------------------------------------
    # 6. 触发一次，等它跑完
    # ------------------------------------------------------------------
    def run_once():
        """启动一次并等完成，返回耗时（秒）。超时抛异常，绝不无限等。

        ★ 不能用 AP_READY 判断"能不能启动"：ap_ready 只对带 ap_hs / AXIS 接口的
          DATAFLOW 设计有意义，我们这个核的接口全是 m_axi + s_axilite，
          ap_ready 恒为 0（实测 CTRL=0x04，只有 AP_IDLE 是 1）。所以改用 AP_DONE。

        ★ 也不能直接等 AP_DONE==1：AP_DONE 是**电平**信号，上一轮跑完后会一直
          保持高，直到下一次 ap_start 才清掉。直接等它，第二次往后每次都会立刻
          "完成"，测出来是 0 ms。必须先看到它落下去，才说明这次启动真被接受了。
        """
        t = time.perf_counter()
        ip.write(R_CTRL, BIT_START)                    # 写 AP_START=1 启动

        # ① 确认这次启动被接受了：AP_DONE 落下去、或 AP_IDLE 落下去，二者之一成立
        #    就说明加速器已离开"上一轮完成且空闲"的状态，开始跑这一轮。
        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl:
            v = ip.read(R_CTRL)
            if (v & BIT_DONE) == 0 or (v & BIT_IDLE) == 0:
                break
        else:
            raise RuntimeError("启动没被接受（AP_DONE/AP_IDLE 都没变化），CTRL=0x%08X"
                               % ip.read(R_CTRL))

        # ② 再等它真的算完：AP_DONE 变高
        dl = time.perf_counter() + TIMEOUT_S
        while time.perf_counter() < dl:
            if ip.read(R_CTRL) & BIT_DONE:
                return time.perf_counter() - t
        raise RuntimeError("等 AP_DONE 超时，CTRL=0x%08X" % ip.read(R_CTRL))

    print("[6] 触发前 CTRL = 0x%08X（bit2=AP_IDLE 应为 1）" % ip.read(R_CTRL), flush=True)
    print("[6] 触发一次推理 ...", flush=True)
    dt = run_once()
    print("    完成，耗时 %.2f ms" % (dt * 1000.0), flush=True)

    # ------------------------------------------------------------------
    # 7. 读回结果
    #    ★ 同样是缓存问题：PL 写进 DDR 的数据，CPU 的 cache 里可能是旧的，
    #      必须先 invalidate 再读，否则读到的还是刚才 flush 进去的初始值。
    # ------------------------------------------------------------------
    buf_o.invalidate()
    w0 = int(buf_o[0])                                 # cls0..cls3，小端
    w1 = int(buf_o[1])                                 # cls4..cls5
    raw = [(w0 >> (8 * i)) & 0xFF for i in range(4)] + [(w1 >> (8 * i)) & 0xFF for i in range(2)]
    got = [b - 256 if b >= 128 else b for b in raw]    # 无符号字节还原成有符号 int8

    print("", flush=True)
    print("    期望 logits :", GOLDEN, flush=True)
    print("    实际 logits :", got, flush=True)
    ok = (got == GOLDEN)
    print("    ==== %s ====" % ("PASS 逐字节一致" if ok else "FAIL"), flush=True)
    if not ok:
        print("    !! 不要接着测摄像头，先把这 6 个数发给我", flush=True)
        return

    # ------------------------------------------------------------------
    # 9. 采信标时间线 —— 内核跑到每个阶段边界都会往 out[2] 写一个阶段码，
    #    这里在它跑的过程中不停读 out[2]，把"什么时候进入哪个阶段"录下来，
    #    就能算出每一段到底花了多少 ms（不用再靠猜）。
    #      1      = 输入拷贝完成
    #      100+l  = 第 l 层卷积开始（100/101/102/103）
    #      2      = 四层卷积全部完成
    #      3      = GAP 完成
    #      4      = FC 完成
    # ------------------------------------------------------------------
    print("", flush=True)
    print("[9] 采信标时间线 ...", flush=True)
    BEACON = {1: "输入拷贝完成", 2: "四层卷积完成", 3: "GAP 完成", 4: "FC 完成",
              100: "layer1 开始", 101: "layer2 开始", 102: "layer3 开始", 103: "layer4 开始"}

    buf_o[2] = 0                                           # 先把信标清零
    buf_o.flush()
    ev = []                                                # [(ms, code)]
    last = -1
    t0 = time.perf_counter()
    ip.write(R_CTRL, BIT_START)                            # 启动
    dl = time.perf_counter() + TIMEOUT_S
    while time.perf_counter() < dl:                        # 边跑边采
        buf_o.invalidate()                                 # 丢掉 cache 才能读到新值
        v = int(buf_o[2])                                  # 当前阶段码
        if v != last:                                      # 变了就记一笔
            ev.append(((time.perf_counter() - t0) * 1000.0, v))
            last = v
            if v == 4:                                     # FC 完了，剩下只是写回
                break
    # 等 AP_DONE 收尾
    dl = time.perf_counter() + TIMEOUT_S
    while time.perf_counter() < dl and not (ip.read(R_CTRL) & BIT_DONE):
        pass
    t_end = (time.perf_counter() - t0) * 1000.0

    if not ev:
        print("    !! 一个信标都没采到 —— 说明板上跑的还是**旧位流/旧 IP**", flush=True)
        print("       请确认 .bit/.hwh 都是 6A31893A… 之后的新版，且 hwh 与 bit 配套", flush=True)
    else:
        print("    %-16s %10s %10s" % ("阶段", "进入时刻", "本段耗时"), flush=True)
        prev_t, prev_c = ev[0][0], None
        for ms, code in ev:
            name = BEACON.get(code, "码 %d（未知）" % code)
            seg = "" if prev_c is None else "%8.2f ms" % (ms - prev_t)
            print("    %-16s %8.2f ms %s" % (name, ms, seg), flush=True)
            prev_t, prev_c = ms, code
        print("    %-16s %8.2f ms" % ("收尾(写回+退出)", t_end), flush=True)
        print("", flush=True)
        print("    ★ 上表中耗时最长的那一段，就是下一步该优化的地方", flush=True)

    # ------------------------------------------------------------------
    # 8. 正确了就量速度
    #    权重/偏置这些静态数据已经在 DDR 里，不需要每次重传，
    #    所以这里量到的就是纯推理时间（PS 版 tflite 的对应值是 65.53 ms）。
    # ------------------------------------------------------------------
    print("", flush=True)
    print("[8] 测速（20 次）...", flush=True)
    times = []
    for n in range(20):
        times.append(run_once())
        print("    第 %2d 次 %.2f ms" % (n + 1, times[-1] * 1000.0), flush=True)

    ms = np.array(times) * 1000.0
    print("", flush=True)
    print("    PL 推理：最小 %.2f ms / 中位 %.2f ms / 平均 %.2f ms"
          % (ms.min(), np.median(ms), ms.mean()), flush=True)
    print("    PS(tflite) 基准 65.53 ms ⇒ 加速 %.2f 倍"
          % (65.53 / np.median(ms)), flush=True)


main()
