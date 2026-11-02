###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：config.py
# 角色   ：按钮②第 1 步：曝光 / 增益 / AWB 锁定 + 掩膜阈值 / 抗阴影参数 / 显示档位
# 依赖   ：无 import；通过 IPython 命名空间取 cam_full 建立的句柄
# 启动   ：按钮②，或 %run config.py
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import time                                          # ★ AWB 锁定要 sleep（若 cam_full 已 import 也无害）
"""
config.py —— 曝光/增益 + PL 端各使能与值域 的一键配置（用户 2026-10-13 提供，原样保存）

用途：一个 cell 把"影响掩膜的所有旋钮"一次设好并打印出来。
      ★ 漏写或写错其中任何一项，症状都是"掩膜全黑"而且不报错 —— 所以这些项必须一起设。

Jupyter 用法（★ 必须在 cam_full.py 跑完之后，本文件用到它建立的 GLASS 和 wr16）：
    %run cam_full.py      ← 先启动（建 Overlay / 摄像头 / 四条 VDMA / GLASS）
    %run config.py        ← 再配置（曝光 + 使能 + 掩膜参数 + 显示档）

★ 两个必须记住的点：
  1) 每次重跑 %run cam_full.py，摄像头初始化表的最后一条会把曝光打回自动（0x3503=0x00）
     ⇒ 要用手动曝光就得重跑本文件。
  2) BG_EN=1 之前必须先采背景（cam_full.py 里的 capture_bg()），否则掩膜是"当前帧 vs 全黑背景"，
     出来的是整幅灰度二值图，不是放置物。

★ 基线纪律：这份是用户手上正在跑的版本，**逻辑一字未改**（只在最上面加了这段文件头）。
"""

# ==================== ★★★ 只改这一段 ★★★ ====================
# ---- 曝光 / 增益（切手动才生效）----
EXP_LINES = 950     # 曝光行数 1..980（980 = 一帧）。暗场景先给足；每行 ≈ 35.7us
GAIN      = 0x80    # 增益：0x10=1x  0x20=2x  0x40=4x  0x80=8x  0xC0=12x  0xF8=15.5x
                    #   ★ 增益越高雪花越多；能在光上解决就别堆增益
EXP_EN    = 1       # 1 = 锁手动（必须）；=0 时下面 GAIN/EXP_LINES 根本不执行

# ---- 三个使能（★ 缺一个掩膜就是全黑，而且是串联的）----
CTRL_EN   = 1       # 总使能：=0 时 DISP 被强制回原图
BG_EN     = 1       # ★【新】背景差分使能：=0 掩膜全黑（采背景前必须 0，采完才置 1）
                    #   实际生效 = (CTRL_EN & BG_EN)，两个都要 1

# ---- 掩膜参数（0x20 DEF_TH）----
DEF_TH    = 30      # ★ 主旋钮：灰度阈值 0..255。物体内部有洞就往下调，噪点多就往上调
POL       = 0       # 极性：0 = 报"比背景亮"的（本项目固定 0，别改成 1）
MED       = 1       # 中值：1 = 开（去椒盐噪点；代价是吃掉 ≤4 像素的小点）
MORPH     = 1       # ★ 闭运算：1 = 开。★ 要"白色实心块"主要靠它（填内部空洞、连断裂轮廓）
EN_A      = 1       # 支路 A（灰度阈值）使能：本项目必须 1

# ---- 支路 B（Sobel）★ 本项目必须关 ----
EN_B      = 0       # ★★★ 必须 =0！形态学吃的是 (支路A | 支路B)，
                    #     开了它，边缘会混进最终掩膜，把背景差分的结果搞脏
SOB_TH    = 12      # 支路 B 关了，这个随意

# ---- 显示档位 ----
DISP      = 5       # 0=原图 1=尺寸 2=支路A 3=支路B 4=A|B
                    # 5=最终掩膜(★白色实心块看这个) 6=当前帧灰度 7=背景(彩色) 8=亮度差|ΔY|
                    # ★ 9=色度差|ΔCb|+|ΔCr|  10=阴影标记(白=判为阴影) —— 调 τc/αmin 就看这两档

# ---- 阴影抑制（0x28 SHADOW_CFG）★ 新增 2026-10-21 ----
SH_EN     = 1       # 1 = 开阴影判据；0 = 退回纯 |ΔY| 的旧行为（出问题写 0 一键回退，不用换位流）
W_Y       = 1       # 亮度项权重 wY（只用"变亮"那一半 ⇒ 阴影在亮度项上永远加不到分）
W_C       = 1       # 色度项权重 wC
TAU_C     = 12      # 色度阈值 τc —— ★ 不能低于 8：RGB565 补零让 ΔC 的量化步长约 3~8
ALPHA_MIN = 60     # αmin 定点码：128 = 0.5，192 = 0.75
                    #   ⇒ 只有"暗得没超过 αmin"的才可能是阴影；更暗的当深色物体保留

# ---- AWB 白平衡锁定 ★ 色度判据的前提，不做则整套失效 ----
AWB_LOCK  = 0       # 1 = 锁住当前白平衡（★ 先布好光、等 AWB 稳定，再跑本文件）
# =================================================================

# ---------------- 下面不用改 ----------------
# ★★ 2026-10-28：跨 %run 的命名空间桥。
#   IPython 的 `%run` **默认在一个独立命名空间里执行文件**（只有 `%run -i` 才共享 notebook
#   的交互命名空间）⇒ 本文件里看不到 cam_full.py 建的 wr16 / rd8 / GLASS，
#   表现就是 "NameError: name 'wr16' is not defined"。**粘进 cell 里手跑反而正常**（那是交互命名空间）。
#   这里把交互命名空间的变量搬进本文件 globals()，下面所有引用一行都不用改。
def _ipy_ns():
    try:
        ip = get_ipython()                               # notebook 里有，纯 python 里没有
        return ip.user_ns if ip is not None else {}
    except Exception:
        return {}

for _k, _v in list(_ipy_ns().items()):                   # 交互命名空间里的每个名字
    if _k not in globals():                              # 本文件还没有的才搬
        globals()[_k] = _v

if EXP_EN:
    wr16(0x3503, 0x03)                       # AEC 手动 + AGC 手动
    wr16(0x350A, (GAIN >> 8) & 0x03)         # 增益高 2 位（寄存器是 0x350A）
    wr16(0x350B,  GAIN       & 0xFF)         # 增益低 8 位（寄存器是 0x350B）
    _v = int(EXP_LINES) * 16                 # ★ 曝光单位是 1/16 行 ⇒ ×16
    wr16(0x3500, (_v >> 16) & 0x0F)          # 曝光 20 位：高 4 位
    wr16(0x3501, (_v >> 8)  & 0xFF)          #              中 8 位
    wr16(0x3502,  _v        & 0xFF)          #              低 8 位
else:
    wr16(0x3503, 0x00)                       # 全部回自动

GLASS.write(0x04, 1 if CTRL_EN else 0)                                              # 总使能
GLASS.write(0x38, 1 if BG_EN  else 0)                                               # ★ 背景差分使能
GLASS.write(0x20, (DEF_TH << 8) | (MORPH << 3) | (MED << 2) | (POL << 1) | EN_A)    # 掩膜参数
GLASS.write(0x30, (SOB_TH << 8) | EN_B)                                             # 支路 B
GLASS.write(0x28, (ALPHA_MIN << 24) | (TAU_C << 16) | (W_C << 8) | (W_Y << 4) | SH_EN)  # ★ 阴影抑制参数
GLASS.write(0x1C, DISP)                                                             # 显示档

# ★ 锁白平衡（放在最后：它要等 AWB 自动收敛之后才锁得对）
if AWB_LOCK:
    time.sleep(2.5)                                 # 让 AWB 自动适应当前光照（重跑 cam_full 后它是自动态）
    _r = (rd8(0x3400) << 8) | rd8(0x3401)           # 读回当前 R 增益（0x3400 高字节 / 0x3401 低字节）
    _g = (rd8(0x3402) << 8) | rd8(0x3403)           # 读回当前 G 增益
    _b = (rd8(0x3404) << 8) | rd8(0x3405)           # 读回当前 B 增益
    wr16(0x3406, 0x01)                              # ★ 先切手动，防止随后又被自动覆盖
    wr16(0x3400, _r)                                # 把刚读到的值写回（保险）
    wr16(0x3402, _g)
    wr16(0x3404, _b)
    print("AWB 已锁定  R=0x%04X  G=0x%04X  B=0x%04X  （★ 换光照后必须重跑本文件）"
          % (_r, _g, _b), flush=True)
else:
    wr16(0x3406, 0x00)                              # 回自动白平衡
    print("AWB = 自动（未锁定，色度判据会不稳）", flush=True)

print("曝光 = %d 行 @ 增益 %.1fx  (%s)" % (EXP_LINES, GAIN/16.0, "手动" if EXP_EN else "自动"), flush=True)
print("总使能=%d  背景差分=%d  → 实际生效=%d  (★ 必须 1)" % (
    CTRL_EN, BG_EN, 1 if (CTRL_EN and BG_EN) else 0), flush=True)
print("掩膜：阈值=%d  极性=%d  中值=%d  闭运算=%d" % (DEF_TH, POL, MED, MORPH), flush=True)
print("阴影抑制：使能=%d  wY=%d  wC=%d  τc=%d  αmin=%.2f（0x28=0x%08X）" % (
    SH_EN, W_Y, W_C, TAU_C, ALPHA_MIN/256.0,
    (ALPHA_MIN << 24) | (TAU_C << 16) | (W_C << 8) | (W_Y << 4) | SH_EN), flush=True)
print("支路B(Sobel) 使能=%d  (★ 本项目应为 0)" % EN_B, flush=True)
print("DISP = %d" % DISP, flush=True)
print("命中像素数(0x24) = %6d" % GLASS.read(0x24), flush=True)
