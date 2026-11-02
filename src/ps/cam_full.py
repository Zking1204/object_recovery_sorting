###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：cam_full.py
# 角色   ：按钮①：加载位流。Overlay 下载 + FCLK0 频率自检 + EMIO 位敲 SCCB 配置 OV5640 + dynclk/VTC 初始化 + 四条 VDMA 与 GenLock + 算法槽位自检
# 依赖   ：pz2_video、dynclk_tables
# 启动   ：按钮①，或 %run cam_full.py
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cam_full.py —— PYNQ-Z2 摄像头一键启动（2026-09-20 成功版；2026-10-11 加背景差分）

★ 2026-10-11 新增（"放置物识别与计数"的第一条链路：背景差分）：
    · 位流换新版：**MD5 847369033FDEB8946F60998696BC4642**，BD 里自研模块已换成
      `glass_defect_core_v2`（多一个背景入口 s_axis_bg）
    · **vdma0/MM2S 重新启用**（通道数回到 4 条）：它读 `buf_bg`，把 PS 采好的
      "空场景背景"送回 PL —— 这是"ddr 送差分"的那一趟
    · PL 侧新链路：灰度 → 与背景配对(dd_pair) → 差分(dd_diff) → 中值 → 阈值 → 闭运算 → 掩膜
    · 新增寄存器：`0x38 BG_CTL`(bit0=差分使能) / `0x3C`、`0x40` 对齐诊断
    · 新增显示档位：DISP **6=灰度 / 7=背景 / 8=差分图**（0=原图 / 5=最终掩膜）
    · 新增函数（文件末尾）：`capture_bg()` 采背景 / `set_disp()` / `set_thresh()` / `align_check()`
    · ★ 上板顺序：先用空场景跑一次 → `capture_bg()` → 再放物体 → `set_disp(5)` 看掩膜

用法（Jupyter）：  %run cam_full.py
前提：
  * pz2_video.py 与 dynclk_tables.py 与本文件在同一目录
  * design_1_wrapper.bit 与 .hwh 已上传（同名同目录）

这一版把 2026-09-20 调出来的"能用状态"全部固化，重跑一次就回到现在的效果：

  1) 找位流 → 按 MD5 核对 → Overlay 加载（当前 MD5 = 1C3325010780EB62A5DC0B14DDCEFDDD）
  2) 定义 SCCB 位敲底层（EMIO GPIO 严格开漏）
  3) 写 OV5640 初始化表，本版相对原表的三处结论：
       · 采集窗口 = 整幅阵列（X 0…2623、Y 4…1947）        → 视场最大（横向 100%、纵向 100%）
       · 输出 972×720（972/720 = 2624/1944 = 1.350）       → 与阵列同比 ⇒ 画面比例不变
       · 保留 2 抽 1（0x3814/0x3815 = 0x31）                → ~30 fps；关掉它（0x11）会更清楚但只 ~7 fps
       · 曝光上限从表里遗留的 5904（5MP 档的值）改成 976 行（≈ 一帧）
       · 显式写 0x3503 = 0x00 → AEC 自动（★ 原始表不写这条，手动曝光过就必须靠它复位）
  4) 显示时序：dynclk 74.25MHz + vtc 720p60
  5) 四条 VDMA：★"行内留边"写法（画面在缓冲里居中 972 宽，两侧留黑）
                ★ 打开 GenLock（这是"运动物体一卡一卡 + 重影"的正解）
       · 采集 S2MM（动态主）：HSIZE=972*3、stride=1280*3、地址+480、CR=0x0B
       · 显示 MM2S（动态从）：HSIZE=1280*3、stride=1280*3、地址 0、  CR=0x800B
         CR 里：bit3 SYNC_EN=0x8 开 GenLock；bit15 GENLCK_RPT=0x8000 让从通道
         "没有新帧就重复上一帧"；bit7 GENLCK_SRC=0 ⇒ 源是 S2MM（采集）
       · 不开 GenLock：显示端 MM2S 会以 60Hz 在 3 帧环里空转、"套圈"到写指针前面
         ⇒ 屏幕在旧帧/新帧之间来回切 ⇒ 运动一顿一顿 + 两个位置（重影），静止看不出来 ✗
  6) 看屏：中间 972×720 画面 + 两侧黑边（显示器再把它放大到 1920×1080）

可调开关在下面"可调开关"区：FRMDLY / DO_SHARP / AGC_CEIL
"""
import os, glob, time, hashlib
import numpy as np                                  # 【新】背景采集要求逐像素平均
from pynq import MMIO, Overlay
import pz2_video as pz

def log(*a):
    print(*a, flush=True)

# ==================== 可调开关 ====================
BIT_MD5  = "847369033FDEB8946F60998696BC4642"   # 2026-10-11 版：背景差分（dd_pair + dd_diff + 显示 6/7/8 档）
#   ★ 位流 MD5 每次重新综合都会变。这个值只用来"顺手核对一下"，
#     不一致时**不再中断**（见下面第 1 步的逻辑）—— 否则每重编一次就要改这个文件。
#     真正要防的是"bit 与 hwh 不配套"；它俩是一起交付的，靠同名同目录保证。
FRMDLY   = 1       # S2MM 帧延迟（治"写覆盖正在读的帧"；0/1/2 可试）
DO_SHARP = False   # True = 关掉 2 抽 1（更清楚，但帧率掉到 ~7fps）；False = 保留抽点（~30fps）
AGC_CEIL = 0xF8    # 自动增益上限：0x40=4x / 0x80=8x / 0xC0=12x / 0xF8=15.5x（暗环境用 0xF8）

# ==================== 1) 找位流并加载 ====================
log("=== 1) 加载位流 ===")
cands = []
for r in ("/home/xilinx/jupyter_notebooks", "/home/xilinx"):
    if os.path.isdir(r):
        cands += glob.glob(os.path.join(r, "**", "design_1_wrapper*.bit"), recursive=True)
cands = sorted(set(cands))
for q in cands:
    log("  找到:", q, "md5=", hashlib.md5(open(q, "rb").read()).hexdigest().upper())
hit = [q for q in cands
       if hashlib.md5(open(q, "rb").read()).hexdigest().upper() == BIT_MD5]
if not hit:
    if not cands:
        # 一个位流都没找到：这是真没得跑，必须停
        log("!! 一个位流都没找到 —— 先把 design_1_wrapper.bit 上传到 /home/xilinx/jupyter_notebooks/")
        raise SystemExit
    # ★ 版本不匹配**不再中断**：取按时间最新的那个继续跑，但把话说清楚。
    #   原因：每次重新综合位流 MD5 都会变，硬中断会让脚本每编一次就废一次。
    hit = [max(cands, key=os.path.getmtime)]
    log("!! ⚠️ 没有位流匹配 BIT_MD5 =", BIT_MD5)
    log("!! ⚠️ 改用最新的:", hit[0])
    log("!! ⚠️ 刚重新综合过  -> 正常，新位流就是这个 MD5，继续跑。")
    log("!! ⚠️ 没重新综合过   -> 传错文件了！停下来核对！")
ol = Overlay(hit[0])
log("已加载:", hit[0])
_s = "/sys/class/fpga_manager/fpga0/state"
log("fpga state:", open(_s).read().strip() if os.path.exists(_s) else "(无此文件)")

# ★ 2026-10-11 新增自检：FCLK0 必须是 100MHz —— 这条能直接救"黑屏"
#   原因：交付的 .hwh **必须**是打过 FCLK0 分频补丁的那份（跑提交包里的 build/deliver.py）。
#   没打补丁的原始 hwh 里 DIVISOR0/1 = 4/4 ⇒ PYNQ 会把 FCLK0 设成 62.5MHz
#   ⇒ 整个 PL（视频流/VDMA/算法/显示）慢 37.5% ⇒ 现象是**屏幕直接黑**，
#   而 PS 侧一切"看着正常"（SCCB、寄存器读写、ALGO ID 全对）—— 极具迷惑性。
try:
    from pynq.ps import Clocks                      # PYNQ 的 PS 时钟接口
    _f0 = Clocks.fclk0_mhz                          # 读当前 FCLK0（MHz）
    log("  FCLK0 = %.1f MHz   (期望 100.0)" % _f0)
    if abs(_f0 - 100.0) > 1.0:                      # 明显偏了就是 hwh 没打补丁
        log("  !! ⚠️ FCLK0 不是 100MHz ⇒ PL 全跑错速 ⇒ 会黑屏！")
        log("  !! ⚠️ 说明上传的 design_1_wrapper.hwh 是没打补丁的那一份，")
        log("  !! ⚠️ 请重跑 D:\\AMD\\PROJECT\\k_deliver.py，再把新的 hwh 传上板。")
except Exception as _e:                             # 读不到就跳过，不因为自检而中断启动
    log("  (FCLK0 自检跳过:", _e, ")")

# ==================== 2) SCCB 位敲底层（EMIO GPIO，严格开漏）====================
log("=== 2) SCCB 底层 ===")
GPIO_BASE = 0xE000A000
DATA2, DATARO2, DIRM2, OEN2 = 0x048, 0x068, 0x284, 0x288
SCL, SDA = 0x1, 0x2            # bank2 bit0=SCL(=GPIO54), bit1=SDA(=GPIO55)
g = MMIO(GPIO_BASE, 0x1000)
HALF = 50e-6
def _d(): time.sleep(HALF)

def _low(bits):                # 拉低：★先设方向/使能，最后才写 0（输入位写不进 DATA）
    g.write(OEN2,  g.read(OEN2)  | bits)
    g.write(DIRM2, g.read(DIRM2) | bits)
    g.write(DATA2, g.read(DATA2) & ~bits & 0xFFFFFFFF)
def _rel(bits):                # 释放：方向和使能都关（只关一个会出假 ACK）
    g.write(DIRM2, g.read(DIRM2) & ~bits & 0xFFFFFFFF)
    g.write(OEN2,  g.read(OEN2)  & ~bits & 0xFFFFFFFF)
def _lvl(bits): return g.read(DATARO2) & bits
def bus_init():
    g.write(DIRM2, 0); g.write(OEN2, 0); g.write(DATA2, 0); _d()
def _start():
    _rel(SCL | SDA); _d(); _low(SDA); _d(); _low(SCL); _d()
def _stop():
    _low(SDA); _d(); _rel(SCL); _d(); _rel(SDA); _d()
def _wr_bit(b):
    (_rel if b else _low)(SDA); _d(); _rel(SCL); _d(); _low(SCL); _d()
def _rd_bit():
    _rel(SDA); _d(); _rel(SCL); _d()
    v = 1 if _lvl(SDA) else 0
    _low(SCL); _d(); return v
def _wr_byte(v):
    for i in range(7, -1, -1): _wr_bit((v >> i) & 1)
def _ack():
    _rel(SDA); _d(); _rel(SCL); _d()
    ok = (_lvl(SDA) == 0); _low(SCL); _d(); return ok
def _rd_byte():
    v = 0
    for _ in range(8): v = (v << 1) | _rd_bit()
    _rel(SDA); _d(); _rel(SCL); _d(); _low(SCL); _d()   # SCCB 的 NA 拍
    return v

SCCB_ID = 0x78
def wr16(reg, val):
    _start(); _wr_byte(SCCB_ID); _ack()
    _wr_byte(reg >> 8); _ack(); _wr_byte(reg & 0xFF); _ack()
    _wr_byte(val & 0xFF); _ack(); _stop()
def rd8(reg):
    _start(); _wr_byte(SCCB_ID); _ack()
    _wr_byte(reg >> 8); _ack(); _wr_byte(reg & 0xFF); _ack(); _stop()
    _start(); _wr_byte(SCCB_ID | 1); _ack()
    v = _rd_byte(); _stop(); return v

# ==================== 3) OV5640 初始化表（1280→972 宽、整幅窗口、RGB565）====================
log("=== 3) 摄像头初始化 ===")
CMOS_H, CMOS_V, TOTAL_H, TOTAL_V = 972, 720, 2570, 980   # ★ 972/720 = 2624/1944 ⇒ 与阵列同比
TABLE = [
    (0x3008,0x82), (0x3008,0x02), (0x3103,0x02),
    (0x3017,0xff), (0x3018,0xff), (0x3037,0x13), (0x3108,0x01),
    (0x3630,0x36), (0x3631,0x0e), (0x3632,0xe2), (0x3633,0x12), (0x3621,0xe0),
    (0x3704,0xa0), (0x3703,0x5a), (0x3715,0x78), (0x3717,0x01), (0x370b,0x60),
    (0x3705,0x1a), (0x3905,0x02), (0x3906,0x10), (0x3901,0x0a), (0x3731,0x12),
    (0x3600,0x08), (0x3601,0x33), (0x302d,0x60), (0x3620,0x52), (0x371b,0x20),
    (0x471c,0x50), (0x3a13,0x43), (0x3a18,0x00), (0x3a19,0xf8),
    (0x3635,0x13), (0x3636,0x03), (0x3634,0x40), (0x3622,0x01),
    (0x3c01,0x34), (0x3c04,0x28), (0x3c05,0x98), (0x3c06,0x00), (0x3c07,0x08),
    (0x3c08,0x00), (0x3c09,0x1c), (0x3c0a,0x9c), (0x3c0b,0x40),
    (0x3810,0x00), (0x3811,0x10), (0x3812,0x00),
    (0x3708,0x64), (0x4001,0x02), (0x4005,0x1a),
    (0x3000,0x00), (0x3004,0xff),
    (0x4300,0x61), (0x501f,0x01), (0x440e,0x00), (0x5000,0xa7),
    (0x3a0f,0x30), (0x3a10,0x28), (0x3a1b,0x30), (0x3a1e,0x26), (0x3a11,0x60), (0x3a1f,0x14),
    (0x5800,0x23),(0x5801,0x14),(0x5802,0x0f),(0x5803,0x0f),(0x5804,0x12),(0x5805,0x26),
    (0x5806,0x0c),(0x5807,0x08),(0x5808,0x05),(0x5809,0x05),(0x580a,0x08),(0x580b,0x0d),
    (0x580c,0x08),(0x580d,0x03),(0x580e,0x00),(0x580f,0x00),(0x5810,0x03),(0x5811,0x09),
    (0x5812,0x07),(0x5813,0x03),(0x5814,0x00),(0x5815,0x01),(0x5816,0x03),(0x5817,0x08),
    (0x5818,0x0d),(0x5819,0x08),(0x581a,0x05),(0x581b,0x06),(0x581c,0x08),(0x581d,0x0e),
    (0x581e,0x29),(0x581f,0x17),(0x5820,0x11),(0x5821,0x11),(0x5822,0x15),(0x5823,0x28),
    (0x5824,0x46),(0x5825,0x26),(0x5826,0x08),(0x5827,0x26),(0x5828,0x64),(0x5829,0x26),
    (0x582a,0x24),(0x582b,0x22),(0x582c,0x24),(0x582d,0x24),(0x582e,0x06),(0x582f,0x22),
    (0x5830,0x40),(0x5831,0x42),(0x5832,0x24),(0x5833,0x26),(0x5834,0x24),(0x5835,0x22),
    (0x5836,0x22),(0x5837,0x26),(0x5838,0x44),(0x5839,0x24),(0x583a,0x26),(0x583b,0x28),
    (0x583c,0x42),(0x583d,0xce),
    (0x5180,0xff),(0x5181,0xf2),(0x5182,0x00),(0x5183,0x14),(0x5184,0x25),(0x5185,0x24),
    (0x5186,0x09),(0x5187,0x09),(0x5188,0x09),(0x5189,0x75),(0x518a,0x54),(0x518b,0xe0),
    (0x518c,0xb2),(0x518d,0x42),(0x518e,0x3d),(0x518f,0x56),(0x5190,0x46),(0x5191,0xf8),
    (0x5192,0x04),(0x5193,0x70),(0x5194,0xf0),(0x5195,0xf0),(0x5196,0x03),(0x5197,0x01),
    (0x5198,0x04),(0x5199,0x12),(0x519a,0x04),(0x519b,0x00),(0x519c,0x06),(0x519d,0x82),
    (0x519e,0x38),
    (0x5480,0x01),(0x5481,0x08),(0x5482,0x14),(0x5483,0x28),(0x5484,0x51),(0x5485,0x65),
    (0x5486,0x71),(0x5487,0x7d),(0x5488,0x87),(0x5489,0x91),(0x548a,0x9a),(0x548b,0xaa),
    (0x548c,0xb8),(0x548d,0xcd),(0x548e,0xdd),(0x548f,0xea),(0x5490,0x1d),
    (0x5381,0x1e),(0x5382,0x5b),(0x5383,0x08),(0x5384,0x0a),(0x5385,0x7e),(0x5386,0x88),
    (0x5387,0x7c),(0x5388,0x6c),(0x5389,0x10),(0x538a,0x01),(0x538b,0x98),
    (0x5580,0x06),(0x5583,0x40),(0x5584,0x10),(0x5589,0x10),(0x558a,0x00),(0x558b,0xf8),
    (0x501d,0x40),
    (0x5300,0x08),(0x5301,0x30),(0x5302,0x10),(0x5303,0x00),(0x5304,0x08),(0x5305,0x30),
    (0x5306,0x08),(0x5307,0x16),(0x5309,0x08),(0x530a,0x30),(0x530b,0x04),(0x530c,0x06),
    (0x5025,0x00),
    (0x3035,0x11), (0x3036,0x5A), (0x3c07,0x08),
    (0x3820,0x46), (0x3821,0x01), (0x3814,0x31), (0x3815,0x31),
    (0x3800,0x00), (0x3801,0x00), (0x3802,0x00), (0x3803,0x04),
    (0x3804,0x0a), (0x3805,0x3f), (0x3806,0x07), (0x3807,0x9b),
    (0x3808, CMOS_H >> 8),  (0x3809, CMOS_H & 0xFF),
    (0x380a, CMOS_V >> 8),  (0x380b, CMOS_V & 0xFF),
    (0x380c, TOTAL_H >> 8), (0x380d, TOTAL_H & 0xFF),
    (0x380e, TOTAL_V >> 8), (0x380f, TOTAL_V & 0xFF),
    (0x3813,0x00), (0x3618,0x00), (0x3612,0x29), (0x3709,0x52), (0x370c,0x03),
    # ★ 曝光上限：原表 0x1710(=5904 行，5MP 档遗留) → 改成 976 行(≈一帧)，60/50Hz 两条都写
    (0x3a02,0x03), (0x3a03,0xd0), (0x3a0e,0x03), (0x3a0f,0xd0),
    (0x3a14,0x03), (0x3a15,0xd0),
    (0x4004,0x02), (0x4713,0x03), (0x4407,0x04), (0x460c,0x22), (0x4837,0x22),
    (0x3824,0x02), (0x5001,0xa3), (0x3b07,0x0a), (0x503d,0x00),
    (0x3016,0x02), (0x301c,0x02), (0x3019,0x02), (0x3019,0x00),
    # ★ 最后显式复位 AEC/AGC 手动位：AEC 回到自动（原表不写这条，手动曝光过就必须靠它）
    (0x3503,0x00),
]

bus_init()
cid = (rd8(0x300A) << 8) | rd8(0x300B)
log("chip id = %#06x   (期望 0x5640)" % cid)
if cid != 0x5640:
    log("!! ID 不对，停手（检查接线/供电）")
    raise SystemExit

time.sleep(0.02)
t0 = time.time()
for i, (r, v) in enumerate(TABLE):
    wr16(r, v)
    if i == 0:
        time.sleep(0.01)            # 0x3008=0x82 软件复位后等 10ms
log("写了 %d 条寄存器，用时 %.2f 秒" % (len(TABLE), time.time() - t0))

# ---- 可选：关掉 2 抽 1 ⇒ 画面更清楚，但帧率掉到 ~7fps ----
if DO_SHARP:
    wr16(0x3814,0x11); wr16(0x3815,0x11)     # 关抽点（整幅 2624 列全读）
    wr16(0x380c,0x14); wr16(0x380d,0xB4)     # HTS = 5300（容得下 2624 列）
    wr16(0x380e,0x07); wr16(0x380f,0xB0)     # VTS = 1968
    log("DO_SHARP = True：已关抽点（帧率会掉到 ~7fps）")

# ---- 回读校验 ----
chk = [rd8(0x3808), rd8(0x3809), rd8(0x380a), rd8(0x380b)]
log("回读 0x3808..0x380b = %s  (期望 ['0x3','0xcc','0x2','0xd0'] = 972x720)" % [hex(x) for x in chk])
log("0x3814/0x3815 = %#04x/%#04x   HTS/VTS = %d/%d   0x3036 = %#04x" % (
    rd8(0x3814), rd8(0x3815),
    (rd8(0x380c) << 8) | rd8(0x380d), (rd8(0x380e) << 8) | rd8(0x380f), rd8(0x3036)))
log("0x3503 (AEC 手动位) = %#04x  (期望 0x00 = 自动)   当前曝光 = %d 行(1/16 单位)" % (
    rd8(0x3503), (rd8(0x3500) << 16) | (rd8(0x3501) << 8) | rd8(0x3502)))

# ---- 增益上限（噪点/亮度取舍）----
wr16(0x3A18, 0x00); wr16(0x3A19, AGC_CEIL)
log("AGC 上限 = 0x%02X%02X" % (rd8(0x3A18), rd8(0x3A19)))

# ==================== 4) 显示时序 ====================
log("=== 4) 显示时序 ===")
pz.dynclk_set(74.25)
pz.vtc_set_720p()

# ==================== 5) 四条 VDMA：留边居中 + GenLock ====================
log("=== 5) VDMA（972 宽留边 + GenLock）===")
VDMA0, VDMA1 = MMIO(0x43000000, 0x10000), MMIO(0x43010000, 0x10000)
V_CR, V_SR, V_FRMSTORE, V_PARKPTR = 0x00, 0x04, 0x18, 0x28
A_VSIZE, A_HSIZE, A_STRD, A_ADDR = 0x00, 0x04, 0x08, 0x0C
CH_MM2S, CH_S2MM, AD_MM2S, AD_S2MM = 0x00, 0x30, 0x50, 0xA0
CR_RUNSTOP, CR_TAIL_EN, CR_RESET = 0x1, 0x2, 0x4
CR_SYNC_EN   = 0x8        # ★ Gen-lock enable
CR_GENLCK_RPT = 0x8000    # ★ 从通道"没有新帧就重复上一帧"
SR_HALTED = 0x1

FRAME_W = 1280            # 缓冲里的行宽（像素）
IMG_W   = 972             # 图像在行内的宽度（= 传感器输出宽度）
OFF_PX  = 160             # 图像在行内的起始列（(1280-972)/2 = 154，取 160 保证 16 字节对齐）
OFF_B   = OFF_PX * 3      # = 480 字节

def start_ch(mm, ch, ad, addrs, tag, hsize, stride, cr, frmdly=0, h=720):
    """复位 → 配置 → 循环启动（VSIZE 最后写触发）★ CR 里带 GenLock 位"""
    mm.write(ch + V_SR, 0xFFFFFFFF)
    mm.write(ch + V_CR, CR_RESET)
    t0 = time.time()
    while not (mm.read(ch + V_SR) & SR_HALTED):
        if time.time() - t0 > 2.0:
            log("  %s 复位超时" % tag); return
    mm.write(ad + A_HSIZE, hsize)
    mm.write(ad + A_STRD, ((stride) & 0xFFFF) | (frmdly << 24))   # 帧延迟在 bit[27:24]
    for i in range(3):
        mm.write(ad + A_ADDR + i * 4, addrs[i])
    mm.write(ch + V_FRMSTORE, 3)
    mm.write(ch + V_PARKPTR, 0)
    mm.write(ch + V_CR, cr)                       # ★ RUNSTOP|TAIL_EN|SYNC_EN(|GENLCK_RPT)
    mm.write(ad + A_VSIZE, h)                     # 最后写 VSIZE 触发
    time.sleep(0.05)
    sr = mm.read(ch + V_SR)
    log("  %-18s CR=%#06x SR=%#010x %s" % (tag, mm.read(ch + V_CR), sr,
        "HALTED" if sr & SR_HALTED else "OK"))

buf0, v0, a0 = pz.make_frames(3, FRAME_W, 720)     # 采集用
buf1, v1, a1 = pz.make_frames(3, FRAME_W, 720)     # 显示用（也是 PS 抓帧的来源）
buf_bg, vbg, abg = pz.make_frames(3, FRAME_W, 720) # 【新】背景缓冲：PS 写、PL 通过 vdma0/MM2S 读
for v in v0: v.fill(0)                             # ★ 铺黑：两侧黑边就是"没被写入的区域"
for v in v1: v.fill(0)
for v in vbg: v.fill(0)                            # 【新】先铺 0：背景没采之前，差分图 = 当前帧灰度
buf0.flush(); buf1.flush(); buf_bg.flush()         # 三个缓冲都刷回 DDR
log("缓冲已铺黑（两侧黑边靠它）；背景缓冲已就绪（%d 帧）" % len(vbg))

# 启动顺序：采集（主）→ 显示（从）→ 背景（从）
start_ch(VDMA0, CH_S2MM, AD_S2MM, [a + OFF_B for a in a0], "vdma0 S2MM 972(主)",
         IMG_W * 3, FRAME_W * 3, CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN, FRMDLY)
# ★ 2026-10-11：vdma0/MM2S **重新启用**（以前的注释说它悬空、不用启动 —— 那条已作废）。
#   现在它的消费者是 PL 里新加的 s_axis_bg 口：把 PS 采好的空场景背景送进配对器/差分模块。
#   ★★ 两个关键配置（踩过坑才改对，别改回去）：
#     1) **972 像素/行 + 偏移 480**（和采集口 vdma0/S2MM 完全一样）——
#        因为 A 路（视频流）每行只有 972 个有效像素 ✗ 不是 1280；
#        显示那一路读 1280 是因为 vid_out 要凑满 720p 的 1280 个像素，
#        但差分这条路上 A、B 每行像素数**必须一致**，否则每行差 308 个、越走越偏 ✗
#     2) PL 侧的 dd_pair（v4）**只在 A 有像素那一拍收 B**（`b_ready = a_valid & ~挂起`）
#        ⇒ 这条 VDMA 被视频时序**限速** ✓
#        （以前下游恒 ready，VDMA 会把整帧 9ms 冲完 vs A 的 35ms ⇒ 节拍差 4 倍 ⇒ 配对全废）
#        ★ 另外 dd_pair 会用"挂起"来锚定配对起点（看到 B 帧首就按住、等 A 的帧首）。
#          反压期间 VDMA 内部那 512 字节行缓冲（C_MM2S_LINEBUFFER_DEPTH）会灌满并停在那儿，
#          所以**我们一放开 ready，数据立刻就在总线上** ⇒ 这就是"不需要自己再做队列"的原因 ✓
start_ch(VDMA0, CH_MM2S, AD_MM2S, [a + OFF_B for a in abg], "vdma0 MM2S 972(从)",
         IMG_W * 3, FRAME_W * 3, CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN | CR_GENLCK_RPT, 0)
start_ch(VDMA1, CH_S2MM, AD_S2MM, [a + OFF_B for a in a1], "vdma1 S2MM 972(主)",
         IMG_W * 3, FRAME_W * 3, CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN, FRMDLY)
start_ch(VDMA1, CH_MM2S, AD_MM2S, a1, "vdma1 MM2S 1280(从)",
         FRAME_W * 3, FRAME_W * 3, CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN | CR_GENLCK_RPT, 0)

log("")
log(">>> 全部完成。看屏：中间 972×720 画面 + 两侧黑边（视场 = 整幅阵列，比例不变）。")
log(">>> 运动卡顿/重影靠 GenLock 治：S2MM(主) CR=0x%X、MM2S(从) CR=0x%X" %
    (CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN, CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN | CR_GENLCK_RPT))
log(">>> 画质旋钮：AGC_CEIL（0x40/0x80/0xC0/0xF8）；更清楚但掉帧：把 DO_SHARP 改 True")
log(">>> 想更广/更清楚要到 1080p 显示链路，那要重编一次（VTC 改 1080p）")

# ==================== 6) 算法槽位自检（2026-09-22 新增）====================
# 新的 BD 里，broadcaster/M00 后面接的是我们自己的 glass_defect_core_0，
# 它的 AXI-Lite 从口挂在 ps7_0_axi_periph 的 M04 上，地址 0x43C20000。
# 骨架版对任何读都返回 0xDEADBEEF —— 读到了就说明整条 M04 通路是通的。
log("")
log("=== 6) 算法槽位 glass_defect_core (0x43C20000) ===")
GLASS = MMIO(0x43C20000, 0x1000)
try:
    gid = GLASS.read(0x00)
    if gid == 0xDEADBEEF:
        log("  ALGO ID = %#010x   OK  M04 通路正常（PS <-> PL 通了）" % gid)
    else:
        log("  ALGO ID = %#010x   !! 不等于 0xdeadbeef —— M04/AXI-Lite 通路有问题" % gid)
except Exception as e:
    log("  !! 读 0x43C20000 失败:", e)
log("")
log(">>> 本次预期：居中 972x720 画面 + 两侧黑边、运动不卡、无红框；算法槽位自检通过")

# ==================== 7) 背景差分（2026-10-11 新增）====================
# PL 侧已经全部做好：灰度 → 配对(dd_pair) → 差分(dd_diff) → 中值 → 阈值 → 闭运算 → 掩膜
# PS 这边只做三件事：
#   ① 采一次空场景背景，平均后写进 buf_bg（PL 通过 vdma0/MM2S 读回去）← "ddr 送差分"那一趟
#   ② 打开 BG_CTL[0]（差分使能）
#   ③ 想看哪张图就切 DISP
log("")
log("=== 7) 背景差分 ===")
R_CTRL, R_DISP, R_DEF_TH     = 0x04, 0x1C, 0x20     # 总使能 / 显示档位 / 阈值+极性
R_BG_CTL, R_ALIGN1, R_ALIGN2 = 0x38, 0x3C, 0x40     # 差分使能 / 对齐诊断 ×2
DISP_RAW, DISP_MASK, DISP_GRAY, DISP_BG, DISP_DIFF = 0, 5, 6, 7, 8

GLASS.write(R_CTRL, 1)          # ★ 总使能：不写这条，顶层会把 DISP 强制成 0（永远只看原图）
GLASS.write(R_DISP, DISP_RAW)   # 默认先看原图
GLASS.write(R_BG_CTL, 0)        # ★ 差分默认关：背景还没采，掩膜全黑是"正常"，不是故障

def set_disp(mode, wait=0.15):
    """切显示档位。模块内部在**帧首锁存**，下一帧才生效（约 35ms）"""
    GLASS.write(R_DISP, mode)   # 写 DISP 寄存器
    time.sleep(wait)            # 等过一个帧边界
    log("   DISP = %d" % mode)

def set_thresh(th=60, med=False, morph=True):
    """设阈值。★ 差分图是"越亮差得越多" ⇒ pol=0（命中比参考亮的），与玻璃时代相反"""
    v = ((th & 0xFF) << 8) | (0 << 1) | ((1 if med else 0) << 2) | ((1 if morph else 0) << 3) | 1
    GLASS.write(R_DEF_TH, v)    # 写 DEF_TH（bit0 使能 / bit1 极性 / bit2 中值 / bit3 闭运算 / [15:8] 阈值）
    log("   DEF_TH = %#010x  (th=%d, pol=0, 中值=%s, 闭运算=%s)" % (v, th, med, morph))

def align_check():
    """读配对器诊断（★ 2026-10-11 v4 新语义：去掉队列、改成"帧首匹配 + 紧反压 1:1"）
        0x3C = {lead_max, lead_last}  高 16 = 本帧"没配上"次数（应 0）
                                      低 16 = 重锚时牺牲掉的 A 有效像素数（应 0）
        0x40 = {lap_cnt,  stall_cnt}  高 16 = 本帧 b_sof 出现次数（应 = 1）
                                      低 16 = 盲带拍数（应 0）
      判据（稳态四个数全对，才算这条链路干净）：
        b_sof 次数 == 1 ⇒ MM2S 每帧给了一个帧首、我们也抓到了 ✓  是"对齐锚点"的活证据
        b_sof 次数 == 0 ⇒ 帧首根本没来 ⇒ 查 TUSER 接线 / c_mm2s_sof_enable=1 / vdma0 MM2S 是否在跑 ✗
        没配上 == 0     ⇒ 每一拍都配上了 B ✓（>0 说明 VDMA 偶尔没供上；会自愈，但那一帧有损）
        盲带/重锚牺牲 == 0 ⇒ 挂起精确落在消隐期 ⇒ 帧首匹配零代价 ✓
      ★ 高低位不要弄反：RTL 里是 rdata_c = {高 16, 低 16}
    """
    a1, a2 = GLASS.read(R_ALIGN1), GLASS.read(R_ALIGN2)        # 读两个诊断寄存器
    nomatch, sacrificed = (a1 >> 16) & 0xFFFF, a1 & 0xFFFF      # 没配上次数 / 重锚牺牲的 A 像素数
    bsof, blind         = (a2 >> 16) & 0xFFFF, a2 & 0xFFFF      # 每帧 b_sof 次数 / 盲带拍数
    log("   配对器：没配上=%d 拍，重锚牺牲=%d 像素；盲带=%d 拍，每帧 b_sof=%d 次"
        % (nomatch, sacrificed, blind, bsof))
    if bsof == 0:
        log("   !! 每帧 b_sof=0 ⇒ 没收到 B 帧首（查 TUSER 接线 / c_mm2s_sof_enable=1 / vdma0 MM2S 是否在跑）")
    if nomatch:
        log("   !! 有 %d 拍没配上 B ⇒ 那几拍差分=0（VDMA 偶尔没供上；会自愈，但这一帧有损）" % nomatch)
    if blind or sacrificed:
        log("   !! 盲带 %d 拍 / 重锚牺牲 %d 像素 ⇒ 挂起撞进了有效视频（相位不对，或刚丢过拍）"
            % (blind, sacrificed))
    return nomatch, sacrificed, blind, bsof

def capture_bg(n=15):
    """采空场景背景：切原图 → 读 n 帧平均 → 写进 buf_bg → 打开差分

    ★ 2026-10-21 变更（抗阴影改造）：
      以前这里取的是 DISP=6 的**灰度图**，存进 buf_bg 的背景只有亮度；
      现在改成取 DISP=0 的**彩色原图**，背景带着真实 RGB。
      原因：抗阴影判据要用色度（阴影只改亮度、不改色度），灰度背景里没有这个信息。
      ★ DISP=0 走的是 m_axis_tdata <= s_axis_tdata（0 拍直通），**没有列位移**，
        所以原来那行"+1 列补偿"必须去掉 —— 否则存进去的背景会整体偏 1 列。
    """
    GLASS.write(R_BG_CTL, 0)                            # ★ 先关差分：采的时候掩膜全黑，绝不会误报
    set_disp(DISP_RAW)                                  # 让 PL 把"彩色原图"送进显示缓冲 buf1
    acc  = np.zeros((720, IMG_W, 3), dtype=np.int32)    # 累加器（图像区 972 宽 × 3 通道）
    got  = 0
    for i in range(n):                                  # 读 n 帧
        buf1.invalidate()                               # 丢掉 cache，重新从 DDR 取
        img  = np.asarray(v1[i % 3])                    # 3 帧环形，轮着取（免得总取到同一帧）
        # ★ DISP=0 与原图 0 拍对齐 ⇒ 直接取 OFF_PX 起的 972 列，**不需要任何列补偿**
        seg  = img[:, OFF_PX:OFF_PX + IMG_W, :].astype(np.int32)   # 取图像区三通道原图
        acc += seg                                                   # 累加
        got += 1
        time.sleep(0.04)                                # ≈一帧时间，保证下次取到的是新帧
    bg = (acc // max(got, 1)).astype(np.uint8)          # 求平均（降噪），形状 (720,972,3)
    # ---- 自检：三通道统计（彩色背景三通道应当各不同；全 0 说明没出图）----
    log("   背景统计：mean=%.1f  min=%d  max=%d  B/G/R 均值=%.1f/%.1f/%.1f" % (
        bg.mean(), bg.min(), bg.max(),
        bg[:, :, 0].mean(), bg[:, :, 1].mean(), bg[:, :, 2].mean()))
    if bg.max() < 5:
        log("   !! 警告：背景几乎全黑 ⇒ 摄像头没出图或画面太暗，这样差分没有意义")
    # ---- 写进三个背景缓冲（VDMA 在循环读，三个都得写）----
    for i in range(len(vbg)):
        fr = np.asarray(vbg[i])                         # 取第 i 帧的视图
        fr[:, OFF_PX:OFF_PX + IMG_W, :] = bg            # ★ 三通道写真实彩色（PL 侧直接按 RGB 用）
    buf_bg.flush()                                      # 刷回 DDR（PL 才读得到）
    time.sleep(0.1)                                     # 等 VDMA 至少过一帧，把新背景读进去
    GLASS.write(R_BG_CTL, 1)                            # ★ 打开差分
    time.sleep(0.15)                                    # 等配对器在帧边界重新对齐
    log("   背景已采好（%d 帧平均）并写入 buf_bg，差分已打开" % got)
    align_check()                                       # 顺手看一眼两路对不对齐
    log("   接下来：set_disp(8) 看亮度差 / set_disp(9) 看色度差 / set_disp(10) 看阴影标记")

log("")
log("可用命令：")
log("   capture_bg()          # 【空场景时】采背景并打开差分（这是唯一必须手动做的一步）")
log("   set_disp(6/7/8)       # 看 灰度 / 背景 / 差分图（0=原图，5=最终掩膜）")
log("   set_thresh(th=60)     # 调阈值（极性固定 pol=0）")
log("   align_check()         # 看两路配对诊断")
log("   GLASS.write(0x38, 0)  # 关差分（掩膜立刻全黑，安全）")
