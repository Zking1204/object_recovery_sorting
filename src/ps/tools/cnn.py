###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：cnn.py
# 角色   ：裁图到模型输入的可视化核对（早期一次性脚本）
# 依赖   ：见文件内 import
# 启动   ：独立运行（不属于生产链）
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cnn.py —— 裁剪图 → 模型输入 → 画出来核对（可直接整段粘进 cell 跑）

★ 前置：本段之前，这同一个内核里要先跑过下面几段（顺序不能反）：
    ① cam_full 那段   → 给 v0 / v1 / buf0 / buf1 / OFF_PX / IMG_W / set_disp
    ② capture_bg()    → 空场景采背景、打开差分
    ③ config 那段     → 曝光 + 使能（BG_EN=1）
    ④ detect 那段     → 给 letterbox / detect / to_show / SHIFT_X / SHIFT_Y / PAD / SY / SX
    ⑤ tflite_infer 那段 → 给 preprocess / IMGNET_MEAN / IMGNET_STD
  ★ 内核重启过 ⇒ 这些变量全没了，必须从头按顺序全跑一遍。

作用：把"裁剪图 → preprocess() → 模型输入"跑通并可视化：
      第 1 行 = 从 v0 裁出来的原始 ROI
      第 2 行 = letterbox 42×42
      第 3 行 = 模型真正吃到的（反归一化还原后显示）
      ★ 第 2 行和第 3 行应当长得一模一样。

★ 2026-10-13 改动：去掉"缺变量就 raise"的自检 —— 它把原因指向别处、还整段拦住不跑。
  现在缺哪个变量就自然 NameError，一眼看得见缺的是哪个。
"""

import numpy as np
import matplotlib.pyplot as plt

def to_view(x):                                            # 把归一化后的模型输入还原成"能看的图"（只为显示）
    img = x[0] * IMGNET_STD + IMGNET_MEAN                  # 反归一化：先乘标准差、再加均值
    return np.clip(img, 0.0, 1.0)                          # 夹回 0~1，matplotlib 才画得对

set_disp(5)                                                # 切到最终掩膜
buf1.invalidate()                                          # 掩膜取新帧
m = np.ascontiguousarray(np.asarray(v1[0])[::SY, OFF_PX:OFF_PX+IMG_W:SX, 0])   # 隔行隔列读掩膜
blocks = detect(m)                                         # 找框（坐标已乘回真实尺寸）
print('目标数 =', len(blocks), flush=True)                  # 数到几个

buf0.invalidate()                                          # 彩色原图取新帧
v0img = np.asarray(v0[0])                                  # BGR 的彩色原图
K = max(len(blocks), 1)                                    # 至少留一格（0 块时也不报错）
fig, ax = plt.subplots(3, K, figsize=(3*K, 9))             # 3 行 K 列：原始 / letterbox / 模型输入
if K == 1:                                                 # 只有 1 块时
    ax = ax.reshape(3, 1)                                  # 强行变 3x1，下面索引才一致

for k, (x, y, w, h) in enumerate(blocks):                  # 逐块（与 detect 那段完全同一套换算）
    x0 = max(0, x - SHIFT_X - PAD)                         # 原图左边界：补偿偏移 + 外扩
    y0 = max(0, y - SHIFT_Y - PAD)                         # 原图上边界
    x1 = min(IMG_W, x + w - SHIFT_X + PAD)                 # 原图右边界
    y1 = min(v0img.shape[0], y + h - SHIFT_Y + PAD)        # 原图下边界
    roi = np.array(v0img[y0:y1, x0+OFF_PX:x1+OFF_PX, :])   # ★ 从彩色原图裁（列要加 OFF_PX）
    x_in = preprocess(roi)                                 # ★ 用 tflite_infer 那段（含 mean/std 归一化）
    print('#%d roi=%s -> x=%s %s  min=%.2f max=%.2f' % (k+1, roi.shape, x_in.shape, x_in.dtype,
          float(x_in.min()), float(x_in.max())), flush=True)   # ★ min/max 应落在 -2.1~+2.6（否则归一化没生效）
    ax[0][k].imshow(to_show(roi))                          # 第 1 行：原始 ROI
    ax[0][k].set_title('#%d roi %dx%d' % (k+1, roi.shape[1], roi.shape[0])); ax[0][k].axis('off')
    ax[1][k].imshow(to_show(letterbox(roi)))               # 第 2 行：letterbox 42×42
    ax[1][k].set_title('#%d letterbox 42' % (k+1)); ax[1][k].axis('off')
    ax[2][k].imshow(to_view(x_in))                         # 第 3 行：模型输入（反归一化还原后显示）
    ax[2][k].set_title('#%d model in (1,42,42,3)' % (k+1)); ax[2][k].axis('off')
plt.tight_layout(); plt.show()                             # 出图
