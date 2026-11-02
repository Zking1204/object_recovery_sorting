###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：bench.py
# 角色   ：刷新率基准测试（一次性验证脚本）
# 依赖   ：见文件内 import
# 启动   ：独立运行（不属于生产链）
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bench.py —— 刷新率测试：让"识别 + 裁图"持续跑，量它每秒能跑几轮（2026-10-13 新建）

作用：回答"这套检测+裁图能跑多快" —— 也就是 CNN 之前那一段的 CPU 时间预算。
      分三段分别量，好看出瓶颈落在哪一段。

Jupyter 用法（★ 必须先跑 cam_full.py / config.py / detect.py）：
    %run cam_full.py
    %run config.py
    %run detect.py
    %run bench.py

★ 怎么读结果（重要）：
  · 循环里读的是【同一帧】（没有"哪一帧刚写完"的握手），所以量到的是
    "CPU 算完一轮要多久" ⇒ 这是刷新率的【上限】。
  · 真正"看到新内容"的频率被相机锁死：相机 ~28.6 fps ⇒ 每秒最多 28.6 次新画面。
  · 判据：③ 的 Hz 远大于 28.6 ⇒ 检测+裁图【完全不构成瓶颈】，可以放心上 CNN。
  · ⚠ 场景里【没有物体】时，裁图那一步不花时间，③ 会偏乐观 —— 测的时候放个东西。
"""

import time
import numpy as np

# ==================== 可调 ====================
DUR  = 5            # 每项测试跑多少秒
WARM = 3            # 预热轮数（首次访问 DDR / OpenCV 首次调用会偏慢，先吃掉）

def bench(name, fn, dur=DUR):
    """跑 dur 秒，打印 轮数 / 每轮毫秒 / 刷新率 Hz"""
    for _ in range(WARM):                       # 预热：吃掉首次的页表与缓存代价
        fn()                                    # 空跑几轮，不计时
    n = 0                                       # 轮数
    t0 = time.perf_counter()                    # 起点
    while time.perf_counter() - t0 < dur:       # 跑够 dur 秒
        fn()                                    # 跑一轮
        n += 1                                  # 计数
    dt = time.perf_counter() - t0               # 实际用时
    print("  %-24s %6d 轮  %7.2f ms/轮  → %7.1f Hz" % (name, n, dt*1000.0/n, n/dt), flush=True)
    return n, dt * 1000.0 / n, n / dt           # 返回给下面做结论

set_disp(5)                                     # 切到最终掩膜
time.sleep(0.3)                                 # 等一帧生效

def f_read_mask():
    """① 只把掩膜从 DDR 读进内存"""
    buf1.invalidate()                                   # ★ 必须：丢 cache 才是真的从 DDR 读
    m = np.asarray(v1[0])[:, OFF_PX:OFF_PX+IMG_W, 0]    # 视图（此时还没搬数据）
    return int((m > 128).sum())                          # ★ 这一步才真正逐像素搬 972×720

def f_detect():
    """② 读掩膜 + 闭运算 + 连通域 + 去碎屑 + 合并（= detect() 的全部内容）"""
    buf1.invalidate()                                   # 丢 cache 取新帧
    m = np.asarray(v1[0])[:, OFF_PX:OFF_PX+IMG_W, 0]    # 掩膜图像区
    return detect((m > 128).astype(np.uint8))           # 找框

def f_full():
    """③ 读掩膜 + 找框 + 从彩色原图裁 ROI（完整链路，不含 CNN）"""
    boxes = f_detect()                          # 找框
    buf0.invalidate()                           # 彩色原图缓冲
    v0img = np.asarray(v0[0])                   # 视图
    crops = []                                  # 收到的 ROI
    for (x, y, w, h) in boxes:                  # 逐个裁
        x0 = max(0, x - SHIFT_X - PAD)          # 补偿固定偏移 + 外扩
        y0 = max(0, y - SHIFT_Y - PAD)
        x1 = min(IMG_W, x + w - SHIFT_X + PAD)
        y1 = min(v0img.shape[0], y + h - SHIFT_Y + PAD)
        crops.append(np.array(v0img[y0:y1, x0+OFF_PX:x1+OFF_PX, :]))   # ★ 只读 ROI 涉及的页
    return boxes, crops                         # 返回框和 ROI

nobj = len(f_detect())                          # 先看当前场景有几个目标
print("=== 刷新率测试（每项 %.0f 秒）===" % DUR, flush=True)
print("当前目标数 = %d%s" % (nobj, "   ⚠ 0 个 ⇒ 裁图那一步几乎不花时间，结果偏乐观" if nobj == 0 else ""), flush=True)
print("", flush=True)
bench("① 只读掩膜", f_read_mask)                 # 量"从 DDR 搬一整幅掩膜"的代价
bench("② 读掩膜→找框", f_detect)                 # 量"加一步连通域+形态学"的代价
n, ms, hz = bench("③ 完整链路(读→找框→裁图)", f_full)   # 量完整链路
print("", flush=True)
print("★ 检测+裁图刷新率 = %.1f Hz   （每轮 %.2f ms）" % (hz, ms), flush=True)
print("★ 相机 ~28.6 fps ⇒ 新内容最多 28.6 次/秒", flush=True)
print("★ 结论：%s" % ("远快于相机 ⇒ 不构成瓶颈 ✓" if hz > 2 * 28.6 else "接近或低于相机 ⇒ 需要优化 ⚠"), flush=True)
