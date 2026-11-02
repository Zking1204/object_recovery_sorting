###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：live.py
# 角色   ：实时帧率与漏帧监测（一次性验证脚本）
# 依赖   ：见文件内 import
# 启动   ：独立运行（不属于生产链）
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
live.py —— 实时检测循环：等新帧 → 找框 → 裁图（可一直跑，也可定时跑）（2026-10-13，第 3 版）

作用：让"从 PL 读掩膜 → 找框 → 裁出目标"按真实帧节拍【持续】跑。
      · DUR = 0  ⇒ 一直跑，Ctrl+C 停
      · DUR > 0  ⇒ 跑 DUR 秒后自己退出

Jupyter 用法（★ 必须先跑 cam_full.py / config.py / detect.py，本文件用到它们建的东西）：
    %run cam_full.py → 空场景 capture_bg() → %run config.py → %run detect.py → %run live.py

★ 怎么知道"来了新帧"——只用【软件指纹】：
  看画面【底部 ROWS 行】的 md5 变没变（这几行是每帧最后写完的，变了就说明这帧齐了）。
  · ★★ 必须【三个帧缓冲都比】：VDMA 是 3 帧环形，只盯 v0[0] 会量到 1/3 帧率
    （2026-09-20 就是这么量出"9.3 fps"这个假读数的）。
  · ★ 一次 buf0.invalidate() 就覆盖三个槽 —— v0[0..2] 本来就是同一块连续内存切出来的。
  · ★ 这个 PYNQ 版本（3.0.1）的 PynqBuffer.invalidate() 【不收参数】，
    写成 invalidate(offset, length) 会报 "takes 1 positional argument but 3 were given"
    （那是旧版 xlnk 的 API）。

★ 为什么不用 VDMA 的硬件帧计数（SR bit[23:16]）：实测 1→1、一秒 0 帧 ——
  我们的 CR=0x0B 没置 bit4(FRMCNT_EN)。**而且别去开它**：2026-09-19 给四通道加
  CR_FRMCNT_EN(0x10) 之后四个 VDMA 全变成 HALTED、PL 直接不出视频 ✗。

★ 实测性能（2026-10-13）：检测 + 裁图 = **25 ms/帧、29 Hz、一帧不漏**（相机 ~29 fps）。

★ 三条操作纪律：
  ① 停止直接 Ctrl+C —— 已用 try/except 接住，会正常收尾并打总结；
     所有 import 都在循环外面，中断不会打断 import（那会把 numpy 搞成半初始化）。
  ② 跑着的时候【不能跑别的 cell】—— Jupyter 内核一次只跑一个 cell，要改参数先 Ctrl+C。
  ③ 改完参数要重跑 `%run detect.py`：Ctrl+C 停 → 改参数 → %run detect.py → 再跑本文件。
"""

import time, hashlib                                 # 计时 / 指纹
import numpy as np                                   # 数组
import cv2                                           # 画框
from IPython.display import clear_output, display    # notebook 里刷新显示
from PIL import Image                                # 数组 → 图片

# ==================== 可调 ====================
DUR        = 0       # ★ 0 = 一直跑（Ctrl+C 停）；>0 = 跑这么多秒后自己退出
SY, SX     = 2, 2    # 掩膜读法：行、列各隔 1（数据量 1/4）；想更准就都设 1
ROWS       = 4       # 指纹取画面底部几行
POLL       = 0.004   # 探测新帧的间隔（秒）
STAT_EVERY = 2.0     # 每几秒刷一次状态
SHOW_IMG   = True    # ★ True = 每次刷状态时把带红框的画面显示出来
IMG_EVERY  = 2.0     # 刷图的间隔（秒）

ROWBYTES = FRAME_W * 3                        # 一行字节数
OFFB     = (720 - ROWS) * ROWBYTES            # 指纹起点（底部 ROWS 行）
LENB     = ROWS * ROWBYTES                    # 指纹字节数

def read_mask():
    """读掩膜：行取 1/SY、列取 1/SX（只用来找框）"""
    buf1.invalidate()                                        # 丢 cache，取新帧
    return np.ascontiguousarray(np.asarray(v1[0])[::SY, OFF_PX:OFF_PX+IMG_W:SX, 0])

def find_boxes(bin_mask):
    """找框：不再二值化、不做 PS 闭运算（PL 已经做过）；框乘回真实坐标"""
    n, lab, st, cen = cv2.connectedComponentsWithStats(bin_mask, connectivity=8)
    out = []                                                 # 结果
    for i in range(1, n):                                    # 0 是背景，跳过
        if st[i, 4] < MIN_AREA / (SX * SY):                  # 面积阈值同比例缩
            continue                                         # 当碎屑扔掉
        out.append([int(st[i,0])*SX, int(st[i,1])*SY,        # ★ 框乘回真实坐标
                    int(st[i,2])*SX, int(st[i,3])*SY])
    if MERGE_GAP > 0 and len(out) > 1:                       # 需要合并
        out = merge_boxes(out, MERGE_GAP)                    # 按间距合并
    return out                                               # 返回框列表

def crop_all(boxes):
    """裁图：★ 从彩色原图 v0 全分辨率裁，步长 1，一个像素都不跳"""
    buf0.invalidate()                                        # 彩色原图缓冲
    v0img = np.asarray(v0[0])                                # 全分辨率
    out = []                                                 # 裁出的 ROI
    for (x, y, w, h) in boxes:                               # 逐个框
        x0 = max(0, x - SHIFT_X - PAD)                       # 补偿固定偏移 + 外扩
        y0 = max(0, y - SHIFT_Y - PAD)
        x1 = min(IMG_W, x + w - SHIFT_X + PAD)
        y1 = min(v0img.shape[0], y + h - SHIFT_Y + PAD)
        out.append(np.array(v0img[y0:y1, x0+OFF_PX:x1+OFF_PX, :]))
    return out                                               # 返回

def sigs_all():
    """三个帧缓冲的底部指纹（判断来没来新帧）"""
    buf0.invalidate()                                        # 一次失效覆盖三个槽
    out = []                                                 # 三个指纹
    for k in range(3):                                       # 逐槽
        flat = np.asarray(v0[k]).reshape(-1)                 # 展平是视图
        out.append(hashlib.md5(flat[OFFB:OFFB+LENB].tobytes()).hexdigest())
    return out                                               # 返回

set_disp(5); time.sleep(0.3)                                 # 切到最终掩膜，等一帧生效

sigs = sigs_all()                                            # 初始指纹
n_frame = 0; tsum = 0.0; tmax = 0.0                          # 帧数 / 累计耗时 / 最慢一轮
t_start = time.perf_counter()                                # 起点
t_stat  = t_start; n_stat = 0                                # 统计窗口
t_img   = t_start                                            # 上次刷图时刻
print("=== 开始实时检测（%s）===" % ("Ctrl+C 停止" if DUR == 0 else "跑 %.0f 秒" % DUR), flush=True)

try:
    while True:                                              # ★★ 主循环
        if DUR > 0 and time.perf_counter() - t_start >= DUR:  # 定时模式到点退出
            break                                             # 跳出循环
        new = sigs_all()                                     # 取三个槽的指纹
        slot = -1                                            # 哪个槽来了新帧
        for k in range(3):                                   # ★ 三个槽都要比
            if new[k] != sigs[k]:                            # 变了
                sigs[k] = new[k]; slot = k                   # 更新并记住槽号
                break                                        # 一个就够
        if slot < 0:                                         # 还没新帧
            time.sleep(POLL)                                 # 等一会儿，别空转烧 CPU
            continue                                         # 回到循环开头
        t1 = time.perf_counter()                             # 这一帧计时
        boxes = find_boxes(read_mask())                      # ① 读掩膜 + 找框
        crops = crop_all(boxes)                              # ② 裁图（全分辨率）
        dt1 = time.perf_counter() - t1                       # 这一帧花了多久
        n_frame += 1; n_stat += 1; tsum += dt1               # 累计
        if dt1 > tmax: tmax = dt1                            # 记最慢
        now = time.perf_counter()                            # 当前时刻
        if now - t_stat >= STAT_EVERY:                       # 到点刷新状态
            line = "[%6.1fs] 帧 %5d   刷新率 %5.1f Hz   平均 %5.2f ms   最慢 %5.2f ms   目标 %d" % (
                now - t_start, n_frame, n_stat / (now - t_stat),
                tsum / max(n_frame, 1) * 1000, tmax * 1000, len(boxes))
            if SHOW_IMG and now - t_img >= IMG_EVERY:        # 要刷画面
                clear_output(wait=True)                      # 清掉上一屏
                print(line, flush=True)                      # 先打状态
                buf0.invalidate()                            # 彩色原图
                vis = np.array(np.asarray(v0[slot]))         # 复制来画框
                for (x, y, w, h) in boxes:                   # 每个框
                    cv2.rectangle(vis, (x+OFF_PX, y),        # 红框画在【掩膜坐标】上（校准尺）
                                  (x+OFF_PX+w, y+h), (0,0,255), 2)
                display(Image.fromarray(to_show(vis)))       # 显示带框的画面
                t_img = now                                  # 记下刷图时刻
            else:                                            # 只打状态
                print(line, flush=True)
            t_stat = now; n_stat = 0                         # 重置统计窗口
except KeyboardInterrupt:                                    # ★ Ctrl+C 安全退出
    print("", flush=True)
    print("=== 已停止（Ctrl+C）===", flush=True)

el = time.perf_counter() - t_start                           # 实际跑了多久
print("跑了 %.1f 秒   处理 %d 帧   ⇒ 平均刷新率 %.1f Hz   每帧 %.2f ms   最慢 %.2f ms"
      % (el, n_frame, n_frame / max(el, 1e-9), tsum / max(n_frame, 1) * 1000, tmax * 1000), flush=True)
print("★ 判据：刷新率 ≈ 相机 fps（~29）⇒ 一帧不漏 ✓", flush=True)
