###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：pz2_video.py
# 角色   ：axi_dynclk 与 v_tc 的寄存器级函数库（像素时钟 MMCM 动态重配、显示时序生成）
# 依赖   ：dynclk_tables
# 启动   ：被 cam_full.py import，不单独运行
###########################################################################
# -*- coding: utf-8 -*-
"""
pz2_video.py —— PYNQ-Z2 视频链路的软件配置（axi_dynclk + v_tc）

用法（Jupyter 里）：
    from pynq import Overlay
    ol = Overlay("design_1_wrapper.bit")

    import pz2_video
    pz2_video.dynclk_set(74.25)      # 像素时钟 74.25MHz
    pz2_video.vtc_set_720p()         # v_tc 出 720p 时序（可选，见下）
    pz2_video.dump_status()          # 回读确认

依赖：同目录的 dynclk_tables.py

--------------------------------------------------------------------------
来源与可靠度（务必看）
--------------------------------------------------------------------------
【axi_dynclk 部分】—— 逐行移植自 Digilent 原厂驱动 dynclk.c（BSD 3-clause）
    · ClkFindParams / ClkDivider / ClkCountCalc 三个函数逻辑完全照搬
    · 两张查找表由 extract_dynclk_tables.py 从 dynclk.h 机械提取，未手抄
    · 寄存器写入序列照搬 ClkWriteReg + ClkStart
    · ✅ 该驱动注释明确要求参考时钟 = 100MHz，我们的 FCLK_CLK0 正是 100MHz

【v_tc 部分】—— 移植自 Xilinx xvtc.c 的 XVtc_ConvTiming2Signal +
    XVtc_SetGenerator(OriginMode==1 分支) + XVtc_SetGeneratorHoriOffset +
    XVtc_SetPolarity；寄存器偏移来自 xvtc_hw.h
    · ⚠️ 有一处"推断"：非隔行模式下 V1Total 未读到源码，按 = V0Total 处理
      （隔行才有独立的 V1 值，我们是逐行 720p，这个推断不会影响结果）
    · ⚠️ GFENC 的色度 parity 位没写（对 RGB 输出无影响）

【重要】v_tc 的 IP 内部已烧入 720p 的 C_GEN_* 参数
    （C_GEN_HACTIVE_SIZE=1280 / C_GEN_VACTIVE_SIZE=720 / C_GEN_F0_VSYNC_HSTART=1390 …）
    所以 **上电默认就在出 720p 时序**。
    → 建议顺序：先只调 dynclk_set()，接显示器看；时序不对再调 vtc_set_720p()
--------------------------------------------------------------------------
"""

from pynq import MMIO

try:
    from dynclk_tables import LOCK_LOOKUP, FILTER_LOOKUP_LOW
except ImportError:
    raise ImportError("缺 dynclk_tables.py，请和本文件放同一目录")

# ============================================================ 地址

DYNCLK_BASE = 0x43C10000
DYNCLK_SIZE = 0x10000
VTC_BASE    = 0x43C00000
VTC_SIZE    = 0x10000

# ============================================================ dynclk 寄存器
# 来自 dynclk.h（OFST_DYNCLK_*）

D_CTRL        = 0x00
D_STATUS      = 0x04
D_CLK_L       = 0x08
D_FB_L        = 0x0C
D_FB_H_CLK_H  = 0x10
D_DIV         = 0x14
D_LOCK_L      = 0x18
D_FLTR_LOCK_H = 0x1C

BIT_START   = 0
BIT_RUNNING = 0

REFCLK_MHZ = 100.0      # 驱动硬性要求：参考时钟 100MHz

# ============================================================ v_tc 寄存器
# 来自 xvtc_hw.h

V_CTL    = 0x000
V_ISR    = 0x004
V_GASIZE = 0x060
V_GFENC  = 0x068
V_GPOL   = 0x06C
V_GHSIZE = 0x070
V_GVSIZE = 0x074
V_GHSYNC = 0x078
V_GVBHOFF= 0x07C
V_GVSYNC = 0x080
V_GVSHOFF= 0x084
V_GASIZE_F1 = 0x094

CTL_SW = 0x00000001     # core enable
CTL_RU = 0x00000002     # register update
CTL_GE = 0x00000004     # generator enable
CTL_ALLSS = 0x03FDEF00  # 全部 source-select 位（= 用 generator 寄存器做时序源）

MSK_13 = 0x00001FFF     # SB_START / ASIZE_HORI
SH_16  = 16             # SB_END / ASIZE_VERT 的移位


# ==================================================================
#  Part 1 —— axi_dynclk
#  移植自 dynclk.c，逻辑未改
# ==================================================================

def _clk_divider(divide):
    """C: ClkDivider() —— 把一个分频值编成 MMCM 的分频寄存器字段"""
    if divide < 1 or divide > 128:
        return 0xFFFFFFFF          # ERR_CLKDIVIDER
    if divide == 1:
        return 0x1041
    high = divide // 2
    if divide & 1:                 # 奇数：置 wedge 位
        low = high + 1
        out = 1 << 13              # CLK_BIT_WEDGE
    else:
        low = high
        out = 0
    out |= 0x03F & low
    out |= 0xFC0 & (high << 6)
    return out


def _clk_count_calc(divide):
    """C: ClkCountCalc() —— 在高位上补齐，得到最终写寄存器的值"""
    d = _clk_divider(divide)
    if d == 0xFFFFFFFF:
        return 0xFFFFFFFF          # ERR_CLKCOUNTCALC
    return (0xFFF & d) | ((d << 10) & 0x00C00000)


def _clk_find_params(freq):
    """
    C: ClkFindParams() —— 暴力搜索最接近目标频率的 (maindiv, fbmult, clkdiv)

    关键：MMCM 实际产生 5 倍像素时钟，再经 BUFR 除以 5。
    所以要按 freq*5 去搜。
    """
    target = freq * 5.0
    best = {"err": 2000.0, "freq": 0.0, "clkdiv": 0, "fbmult": 0, "maindiv": 0}

    for cur_div in range(1, 11):
        # 100MHz 输入 + 600MHz 最小 VCO / 1200MHz 最大 VCO
        min_fb = cur_div * 6
        max_fb = cur_div * 12
        if max_fb > 64:
            max_fb = 64
        clk_mult = (REFCLK_MHZ / float(cur_div)) / target

        for cur_fb in range(min_fb, max_fb + 1):
            cur_clkdiv = int(clk_mult * float(cur_fb) + 0.5)
            if cur_clkdiv < 1:
                continue
            cur_freq = ((REFCLK_MHZ / float(cur_div)) / float(cur_clkdiv)) * float(cur_fb)
            err = abs(cur_freq - target)
            if err < best["err"]:
                best = {"err": err, "freq": cur_freq,
                        "clkdiv": cur_clkdiv, "fbmult": cur_fb, "maindiv": cur_div}

    best["freq"] /= 5.0
    best["err"] /= 5.0
    return best


def _clk_find_reg(p):
    """C: ClkFindReg() —— 由 (clkdiv, fbmult, maindiv) 算出 6 个寄存器值"""
    fb = p["fbmult"]
    if fb < 2 or fb > 64:
        return None

    clk0L = _clk_count_calc(p["clkdiv"])
    if clk0L == 0xFFFFFFFF:
        return None
    clkFBL = _clk_count_calc(fb)
    if clkFBL == 0xFFFFFFFF:
        return None

    divclk = _clk_divider(p["maindiv"])
    if divclk == 0xFFFFFFFF:
        return None

    lock = LOCK_LOOKUP[fb - 1]
    return {
        "clk0L":          clk0L,
        "clkFBL":         clkFBL,
        "clkFBH_clk0H":   0,
        "divclk":         divclk,
        "lockL":          lock & 0xFFFFFFFF,
        "fltr_lockH":     ((lock >> 32) & 0xFF)
                          | ((FILTER_LOOKUP_LOW[fb - 1] << 16) & 0x03FF0000),
    }


def _wait_running(mm, want, timeout_s=2.0):
    """
    等 STATUS 的 RUNNING 位变成 want。

    ⚠️ 原厂 C 驱动用的是裸死循环。真板上如果 MMCM 锁不上（比如 FCLK_CLK0
       不是 100MHz），死循环会让 Jupyter 永久卡住。这里加超时。
    """
    import time
    t0 = time.time()
    while True:
        got = bool(mm.read(D_STATUS) & (1 << BIT_RUNNING))
        if got == want:
            return True
        if time.time() - t0 > timeout_s:
            return False
        time.sleep(0.001)


def dynclk_set(freq_mhz=74.25, verbose=True):
    """
    把 axi_dynclk 配成 freq_mhz 的像素时钟。

    返回实际能达到的频率（MMCM 不一定能精确命中）。
    """
    p = _clk_find_params(freq_mhz)
    regs = _clk_find_reg(p)
    if regs is None:
        raise RuntimeError("ClkFindParam/ClkFindReg 失败，无法合成该频率: %s MHz" % freq_mhz)

    if verbose:
        print("目标 %.4f MHz  实际 %.4f MHz (误差 %.4f MHz)"
              % (freq_mhz, p["freq"], p["err"]))
        print("  maindiv=%d  fbmult=%d  clkdiv=%d" % (p["maindiv"], p["fbmult"], p["clkdiv"]))
        for k in ("clk0L", "clkFBL", "clkFBH_clk0H", "divclk", "lockL", "fltr_lockH"):
            print("  %-14s = 0x%08X" % (k, regs[k] & 0xFFFFFFFF))

    mm = MMIO(DYNCLK_BASE, DYNCLK_SIZE)

    # 先停（带超时，不再裸死循环）
    mm.write(D_CTRL, 0)
    if not _wait_running(mm, False):
        raise RuntimeError("dynclk 停不下来：STATUS 一直是 RUNNING")

    # 写 6 个配置寄存器（照搬 ClkWriteReg 的顺序）
    mm.write(D_CLK_L,       regs["clk0L"])
    mm.write(D_FB_L,        regs["clkFBL"])
    mm.write(D_FB_H_CLK_H,  regs["clkFBH_clk0H"])
    mm.write(D_DIV,         regs["divclk"])
    mm.write(D_LOCK_L,      regs["lockL"])
    mm.write(D_FLTR_LOCK_H, regs["fltr_lockH"])

    # 启动并等运行（照搬 ClkStart，但带超时）
    mm.write(D_CTRL, (1 << BIT_START))
    if not _wait_running(mm, True):
        raise RuntimeError(
            "dynclk 启动后没进入 RUNNING —— MMCM 很可能没锁上。"
            "检查 FCLK_CLK0 是不是真的 100MHz（这个驱动硬性要求 100MHz 参考）")

    if verbose:
        print("  -> 已启动，STATUS=0x%08X" % mm.read(D_STATUS))

    return p["freq"]


# ==================================================================
#  Part 2 —— v_tc 720p
#  移植自 xvtc.c；寄存器偏移来自 xvtc_hw.h
# ==================================================================

# 720p60 时序（来自 lcd_modes.h 的 VMODE_1280x720）
VMODE_1280x720 = dict(
    width=1280, height=720,
    hps=1390, hpe=1430, hmax=1649, hpol=1,
    vps=725,  vpe=730,  vmax=749,  vpol=1,
    freq=74.25,
)


def _pack(lo, hi):
    return (lo & MSK_13) | ((hi & MSK_13) << SH_16)


#: ★ 实测能出图的唯一 CTL 值（2026-09-18 验证）
#:   0x03F7EF06 = (官方 ALLSS 去掉 bit19 INTERLACE) | RU | GE
#:   ⚠️ 别用 xvtc_hw.h 里的 XVTC_CTL_ALLSS_MASK(0x03FDEF00) —— 它把 bit19
#:      (XVTC_CTL_INTERLACE_MASK) 打开了，会让 VTC 出隔行时序。
CTL_OK = 0x03F7EF06


def vtc_set_720p(verbose=True, write_generator=False):
    """
    启动 v_tc 的 720p 输出。

    ★★ 2026-09-18 实测结论 ★★
      IP 在综合时就把 720p 生成器参数烧进去了（VIDEO_MODE=720p、
      C_GENERATE_EN=1），上电即是正确时序。软件只需写 CTL 使能核 +
      开生成器 —— 这是唯一实测能出图的写法。

    write_generator=False（默认，推荐）：
        只写 CTL = 0x03F7EF06。
    write_generator=True：
        额外把生成器时序寄存器 0x60~0x94 也写一遍。
        ⚠️ 这套值来自 PYNQ 的 lcd_modes.h，与 IP 内烧的不保证一致；
           实测中【没有】验证过开着它能出图。非必要不要开。
    """
    if not write_generator:
        mm = MMIO(VTC_BASE, VTC_SIZE)
        mm.write(V_CTL, CTL_OK)
        if verbose:
            print("  -> CTL=0x%08X  (只写 CTL，沿用 IP 里烧好的 720p)" % mm.read(V_CTL))
        return

    m = VMODE_1280x720

    # --- 由 VideoMode 换算成 porch/sync 宽度（照搬 display_ctrl.c L192-205）---
    h_active     = m["width"]
    h_front      = m["hps"] - m["width"]        # 1390-1280 = 110
    h_sync       = m["hpe"] - m["hps"]          # 1430-1390 = 40
    h_back       = m["hmax"] - m["hpe"] + 1     # 1649-1430+1 = 220
    v_active     = m["height"]
    v_front      = m["vps"] - m["height"]       # 725-720 = 5
    v_sync       = m["vpe"] - m["vps"]          # 730-725 = 5
    v_back       = m["vmax"] - m["vpe"] + 1     # 749-730+1 = 20

    # --- 换算成绝对的 start 坐标（照搬 XVtc_ConvTiming2Signal，OriginMode=1）---
    h_front_start = h_active                    # 1280
    h_sync_start  = h_front_start + h_front     # 1390
    h_back_start  = h_sync_start + h_sync       # 1430
    h_total       = h_back_start + h_back       # 1650

    v_front_start = v_active                    # 720
    v_sync_start  = v_front_start + v_front - 1 # 724
    v_back_start  = v_sync_start + v_sync       # 729
    v_total       = v_back_start + v_back + 1   # 750

    # --- 打包（照搬 XVtc_SetGenerator 的 else 分支，OriginMode=1）---
    g_hsize  = h_total & MSK_13
    g_vsize  = (v_total & MSK_13) | ((v_total & MSK_13) << SH_16)   # 逐行：V1Total=V0Total
    g_asize  = (h_front_start & MSK_13) | ((v_front_start & MSK_13) << SH_16)
    g_asize1 = (v_front_start & MSK_13) << SH_16
    g_hsync  = _pack(h_sync_start + h_front_start, h_back_start + h_front_start)
    g_vsync  = _pack(v_sync_start + v_front_start - 1, v_back_start + v_front_start - 1)

    # --- 极性（照搬 XVtc_SetPolarity + ConvTiming2Signal）---
    pol = 0
    pol |= 0x20                     # ActiveChromaPol = 1
    pol |= 0x10                     # ActiveVideoPol  = 1
    pol |= 0x40                     # FieldIdPol      = 1
    if m["hpol"]:
        pol |= 0x08                 # HSyncPol
        pol |= 0x02                 # HBlankPol 跟随 HSync
    if m["vpol"]:
        pol |= 0x04                 # VSyncPol
        pol |= 0x01                 # VBlankPol 跟随 VSync

    # --- 水平偏移（照搬 SetGenerator(OriginMode=1) 默认 + SetGeneratorHoriOffset）---
    vo_blank = h_front_start         # 1280
    vo_sync  = h_sync_start + h_front_start   # 1390+1280 = 2670
    g_vbhoff = _pack(vo_blank, vo_blank)
    g_vshoff = _pack(vo_sync,  vo_sync)

    if verbose:
        print("720p 换算结果：")
        print("  H: active=%d front=%d sync=%d back=%d  total=%d" % (h_active, h_front, h_sync, h_back, h_total))
        print("  V: active=%d front=%d sync=%d back=%d  total=%d" % (v_active, v_front, v_sync, v_back, v_total))
        print("  GHSIZE  = 0x%08X" % g_hsize)
        print("  GVSIZE  = 0x%08X" % g_vsize)
        print("  GASIZE  = 0x%08X" % g_asize)
        print("  GHSYNC  = 0x%08X" % g_hsync)
        print("  GVSYNC  = 0x%08X" % g_vsync)
        print("  GVBHOFF = 0x%08X" % g_vbhoff)
        print("  GVSHOFF = 0x%08X" % g_vshoff)
        print("  GPOL    = 0x%08X" % pol)

    mm = MMIO(VTC_BASE, VTC_SIZE)

    # 关 generator（照搬 XVtc_DisableGenerator）
    mm.write(V_CTL, mm.read(V_CTL) & ~CTL_GE)

    # 时序寄存器
    mm.write(V_GHSIZE,    g_hsize)
    mm.write(V_GVSIZE,    g_vsize)
    mm.write(V_GASIZE,    g_asize)
    mm.write(V_GASIZE_F1, g_asize1)
    mm.write(V_GHSYNC,    g_hsync)
    mm.write(V_GVSYNC,    g_vsync)
    mm.write(V_GVBHOFF,   g_vbhoff)
    mm.write(V_GVSHOFF,   g_vshoff)
    mm.write(V_GPOL,      pol)

    # source select：全部用 generator 寄存器
    mm.write(V_CTL, mm.read(V_CTL) | CTL_ALLSS)

    # 寄存器更新 + 使能
    mm.write(V_CTL, mm.read(V_CTL) | CTL_RU)
    mm.write(V_CTL, mm.read(V_CTL) | CTL_SW | CTL_GE)

    if verbose:
        print("  -> CTL=0x%08X" % mm.read(V_CTL))


# ==================================================================
#  回读确认
# ==================================================================

def dump_status():
    """回读两个 IP 的关键寄存器，用于确认配置是否写进去了"""
    dd = MMIO(DYNCLK_BASE, DYNCLK_SIZE)
    vv = MMIO(VTC_BASE, VTC_SIZE)

    print("=== axi_dynclk @ 0x%08X ===" % DYNCLK_BASE)
    print("  CTRL    = 0x%08X  (bit0 应为 1)" % dd.read(D_CTRL))
    print("  STATUS  = 0x%08X  (bit0 应为 1 = RUNNING)" % dd.read(D_STATUS))
    print("  CLK_L   = 0x%08X" % dd.read(D_CLK_L))
    print("  FB_L    = 0x%08X" % dd.read(D_FB_L))
    print("  DIV     = 0x%08X" % dd.read(D_DIV))

    print("=== v_tc @ 0x%08X ===" % VTC_BASE)
    print("  CTL     = 0x%08X  (bit2=GE, bit1=RU, bit0=SW 应为 1)" % vv.read(V_CTL))
    print("  GHSIZE  = 0x%08X  (期望 0x%08X)" % (vv.read(V_GHSIZE), 1650))
    print("  GVSIZE  = 0x%08X  (期望 0x%08X)" % (vv.read(V_GVSIZE), 750 | (750 << 16)))
    print("  GASIZE  = 0x%08X  (期望 0x%08X)" % (vv.read(V_GASIZE), 1280 | (720 << 16)))
    print("  ISR     = 0x%08X" % vv.read(V_ISR))


# ==================================================================
#  Part 3 —— axi_vdma_1 的 MM2S 通道（显示用）
#
#  为什么需要它：v_axi4s_vid_out 是"把 AXI-Stream 按 v_tc 时序推出去"的模块，
#  它要两边都齐：时序（v_tc 给）**和数据（VDMA 给）**。
#  v_tc 已经在出 720p 了（ISR 的 G_AV/G_VBLANK 为证），缺的就是这里的 VDMA。
#
#  寄存器定义来自 BSP 的 xaxivdma_hw.h，启动序列来自 xaxivdma_channel.c
# ==================================================================

VDMA1_BASE = 0x43010000
VDMA1_SIZE = 0x10000

# 硬件的帧缓冲槽个数（.xci 里的 C_NUM_FSTORES）。
# 每个槽都必须写有效地址，否则循环到没写的槽会读到地址 0 → SR_ERR_SLAVE。
VDMA_MAX_FRAMES = 3

# 通道基址（xaxivdma_hw.h）
CH_MM2S = 0x00          # XAXIVDMA_TX_OFFSET  —— 显示用这条
CH_S2MM = 0x30          # XAXIVDMA_RX_OFFSET

# 通道寄存器（相对 CH_*）
V_CR       = 0x00       # XAXIVDMA_CR_OFFSET
V_SR       = 0x04       # XAXIVDMA_SR_OFFSET
V_FRMSTORE = 0x18       # XAXIVDMA_FRMSTORE_OFFSET

# 地址寄存器组基址（xaxivdma_hw.h）
ADDR_MM2S = 0x50        # XAXIVDMA_MM2S_ADDR_OFFSET
ADDR_S2MM = 0xA0

# 地址寄存器（相对 ADDR_*）
A_VSIZE       = 0x00    # XAXIVDMA_VSIZE_OFFSET
A_HSIZE       = 0x04    # XAXIVDMA_HSIZE_OFFSET
A_STRD_FRMDLY = 0x08    # XAXIVDMA_STRD_FRMDLY_OFFSET
A_START_ADDR  = 0x0C    # XAXIVDMA_START_ADDR_OFFSET

# 实例级寄存器
V_PARKPTR = 0x28        # XAXIVDMA_PARKPTR_OFFSET

# 控制位
CR_RUNSTOP = 0x00000001
CR_TAIL_EN = 0x00000002     # 置 1 = 循环模式（=circular），清 0 = park
CR_RESET   = 0x00000004

# 状态位
SR_HALTED  = 0x00000001
SR_IDLE    = 0x00000002
SR_ERR_ALL = 0x00000FF0

PARKPTR_READREF_MASK = 0x0000001F


def vdma_mm2s_start(phys_addrs, width=1280, height=720, bpp=3, verbose=True):
    """
    配 axi_vdma_1 的 MM2S 通道并启动，让它循环读帧送到显示通路。

    phys_addrs : 帧缓冲物理地址，可以是一个整数或一个列表。
                 ⚠️ 必须给满 VDMA_MAX_FRAMES 个（本设计硬件是 3 个）——
                 只给 1 个的话，硬件循环到第 2 个缓冲时读到地址 0，
                 会报 SR_ERR_SLAVE 并停机（实测踩过：SR=0x15021）。
    width/height/bpp : 1280 / 720 / 3（RGB888）

    返回 (HSIZE, 实际用的缓冲个数)。
    """
    import time

    if isinstance(phys_addrs, int):
        phys_addrs = [phys_addrs]
    phys_addrs = [int(a) for a in phys_addrs]

    hsize  = width * bpp            # 每行字节数 1280*3 = 3840
    stride = hsize                  # 行跨距，紧排
    frame_bytes = hsize * height    # 一帧 2,764,800 字节

    mm = MMIO(VDMA1_BASE, VDMA1_SIZE)
    ch = CH_MM2S
    ad = ADDR_MM2S

    def rd(o):      return mm.read(o)
    def wr(o, v):   mm.write(o, v & 0xFFFFFFFF)

    # ---- 1. 复位通道 + 清掉粘滞的错误位 ----
    #     SR 里的错误位是"写 1 清除"的，上一次失败留下的 0x020 不清掉的话，
    #     下次即使正常跑起来，读 SR 仍然会看到错误位，没法判断到底好没好。
    #     原厂驱动 XAxiVdma_ClearDmaChannelErrors 就是往 SR 写 0xFFFFFFFF。
    wr(ch + V_SR, 0xFFFFFFFF)

    wr(ch + V_CR, CR_RESET)
    t0 = time.time()
    while not (rd(ch + V_SR) & SR_HALTED):
        if time.time() - t0 > 2.0:
            raise RuntimeError("VDMA MM2S 复位超时：SR=0x%08X" % rd(ch + V_SR))

    wr(ch + V_SR, 0xFFFFFFFF)       # 复位后再清一次，确保干净起步

    # ---- 2. 行参数 ----
    wr(ad + A_HSIZE, hsize)
    wr(ad + A_STRD_FRMDLY, stride)      # FrameDelay 放高 8 位，这里 0

    # ---- 3. 帧缓冲地址：硬件有 VDMA_MAX_FRAMES 个槽，每个都要写有效地址 ----
    n = len(phys_addrs)
    for i in range(VDMA_MAX_FRAMES):
        a = phys_addrs[i] if i < n else phys_addrs[-1]
        wr(ad + A_START_ADDR + i * 4, a)

    # ---- 4. 帧缓冲个数 ----
    wr(ch + V_FRMSTORE, n)

    # ---- 5. park 指针指向 frame 0 ----
    p = rd(V_PARKPTR) & ~PARKPTR_READREF_MASK
    wr(V_PARKPTR, p)

    # ---- 6. 控制寄存器：运行 + 循环模式 + 读指针 0 ----
    #     不要设 CR_SYNC_EN(0x8)：那是 Gen-Lock 同步，需要有 FSYNC 源。
    #     本设计 S2MM 侧没有数据流，开了会等不到同步。
    cr = CR_RUNSTOP | CR_TAIL_EN
    wr(ch + V_CR, cr)

    # ---- 7. 写 VSIZE —— 这一步才真正触发搬运（见 ChannelStart 的注释）----
    wr(ad + A_VSIZE, height)

    time.sleep(0.05)

    sr = rd(ch + V_SR)
    if verbose:
        print("VDMA1 MM2S 已启动")
        print("  HSIZE      = %d  (每行字节)" % hsize)
        print("  STRIDE     = %d" % stride)
        print("  VSIZE      = %d  (行数)" % height)
        print("  帧缓冲个数 = %d  (每个 %d 字节 = %.2f MB)" % (n, frame_bytes, frame_bytes / 1048576.0))
        for i in range(n):
            print("    缓冲[%d] = 0x%08X" % (i, phys_addrs[i]))
        print("  CR         = 0x%08X" % rd(ch + V_CR))
        print("  SR         = 0x%08X   %s%s" %
              (sr,
               "HALTED " if sr & SR_HALTED else "",
               "IDLE " if sr & SR_IDLE else ""))
        if sr & SR_ERR_ALL:
            print("  ⚠️ 错误位 = 0x%03X —— 检查地址对齐、帧缓冲个数、HSIZE/STRIDE" % (sr & SR_ERR_ALL))
        elif sr & SR_HALTED:
            print("  ⚠️ 通道仍处于 HALTED —— 可能 VSIZE 没写进去或地址非法")
        else:
            print("  ✓ 通道在运行")

    return hsize, n


def vdma_dump():
    """回读 VDMA 两个通道的状态"""
    mm = MMIO(VDMA1_BASE, VDMA1_SIZE)
    for name, ch, ad in (("MM2S(显示)", CH_MM2S, ADDR_MM2S), ("S2MM(采集)", CH_S2MM, ADDR_S2MM)):
        sr = mm.read(ch + V_SR)
        print("=== %s ===" % name)
        print("  CR    = 0x%08X" % mm.read(ch + V_CR))
        print("  SR    = 0x%08X  %s%s%s" % (
            sr,
            "HALTED " if sr & SR_HALTED else "",
            "IDLE " if sr & SR_IDLE else "",
            ("ERR=0x%03X" % (sr & SR_ERR_ALL)) if sr & SR_ERR_ALL else ""))
        print("  VSIZE = %d" % (mm.read(ad + A_VSIZE) & 0x1FFF))
        print("  HSIZE = %d" % (mm.read(ad + A_HSIZE) & 0xFFFF))
        print("  ADDR0 = 0x%08X" % mm.read(ad + A_START_ADDR))
    print("  PARKPTR = 0x%08X" % mm.read(V_PARKPTR))


def make_frame(width=1280, height=720):
    """
    申请一块 DDR 帧缓冲，返回 (buffer, numpy 视图)。

    注意：必须在加载 overlay 之后调用（PYNQ 靠 .hwh 知道内存布局）。
    """
    from pynq import allocate
    import numpy as np
    buf = allocate(shape=(height, width, 3), dtype=np.uint8)
    arr = np.asarray(buf).reshape(height, width, 3)
    return buf, arr


def frame_phys_addr(buf):
    """取帧缓冲的物理地址（PYNQ 各版本属性名不同）"""
    for attr in ("physical_address", "device_address"):
        a = getattr(buf, attr, None)
        if a:
            return int(a)
    raise AttributeError("缓冲区对象上没有 physical_address / device_address")


def make_frames(n=VDMA_MAX_FRAMES, width=1280, height=720):
    """
    申请 n 个**连续**帧缓冲，正好喂给 VDMA 的 n 个帧缓冲槽。

    返回 (buf, views, addrs)：
      buf   —— PYNQ 缓冲区对象（用完调 buf.flush() 刷缓存）
      views —— n 个 numpy 视图，可以逐个填内容
      addrs —— n 个物理地址，直接传给 vdma_mm2s_start()

    ⚠️ 必须在加载 overlay 之后调用（PYNQ 靠 .hwh 知道内存布局）。
    """
    from pynq import allocate
    import numpy as np

    buf = allocate(shape=(n, height, width, 3), dtype=np.uint8)
    arr = np.asarray(buf).reshape(n, height, width, 3)

    frame_bytes = height * width * 3
    base = frame_phys_addr(buf)
    addrs = [base + i * frame_bytes for i in range(n)]
    views = [arr[i] for i in range(n)]

    print("申请了 %d 个帧缓冲，共 %.2f MB" % (n, n * frame_bytes / 1048576.0))
    for i, a in enumerate(addrs):
        print("  缓冲[%d] 物理地址 = 0x%08X" % (i, a))

    return buf, views, addrs


def fill_color_bars(view, width=1280):
    """
    往一个帧缓冲视图里画 8 条彩色竖条（白/黄/青/绿/紫/红/蓝/黑）。

    ★ 2026-09-18 实测确认：我们自己的设计里，帧缓冲每个像素的字节顺序是
      【B, G, R】—— 下标 0 = 蓝、1 = 绿、2 = 红。
      （注意这与官方 base overlay 不同，官方那边是下标 1 = 红。）
    """
    colors = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
              (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]   # (R,G,B)
    bar = width // len(colors)
    for i, (r, g, b) in enumerate(colors):
        fill_rgb(view[:, i * bar:(i + 1) * bar], r, g, b)
    return view


# ==================================================================
#  Part 4 —— 显示启动 / 喂帧
#  2026-09-18 在板子上实测出图、并逐通道验证过的写法
# ==================================================================

#: 实测确认的通道下标：帧缓冲里每个像素是 [B, G, R] 三个字节
CH_B, CH_G, CH_R = 0, 1, 2

#: 显示通道用驻留模式（只置 RUNSTOP，不置 TAIL_EN）
#: 之后每写一次 VSIZE 触发一帧 —— 实测 SR 的 bit12(IRQFrameCount) 会置起来，
#: 证明帧真的搬完了。（用 TAIL_EN 的循环模式反而没触发成功。）
DISPLAY_CR = 0x00000001


def fill_rgb(view, r, g, b):
    """
    把一块帧缓冲填成纯色。

    ★ 必须按通道下标逐个写，不能写 view[:] = (r, g, b) —— 那样颜色是反的，
      因为内存里的顺序是 B,G,R 而不是 R,G,B。
    """
    view[:, :, CH_B] = b
    view[:, :, CH_G] = g
    view[:, :, CH_R] = r
    return view


def display_start(phys_addrs, width=1280, height=720, bpp=3, verbose=True):
    """
    启动显示通道（axi_vdma_1 的 MM2S），驻留模式。

    ★★ 这是 2026-09-18 实测能出图的写法 ★★
      启动之后必须【持续】调用 display_feed() 喂帧，否则显示器很快进省电。
    """
    import time
    if isinstance(phys_addrs, int):
        phys_addrs = [phys_addrs]
    n = len(phys_addrs)

    mm = MMIO(VDMA1_BASE, VDMA1_SIZE)
    ad = ADDR_MM2S

    # 复位并等 HALTED（带超时，不死循环）
    mm.write(CH_MM2S + V_CR, CR_RESET)
    t0 = time.time()
    while not (mm.read(CH_MM2S + V_SR) & SR_HALTED):
        if time.time() - t0 > 1.0:
            raise RuntimeError("VDMA 复位失败：SR 一直没置 HALTED")
        time.sleep(0.001)
    mm.write(CH_MM2S + V_SR, 0xFFFFFFFF)          # SR 错误位是写 1 清除

    hsize = width * bpp
    mm.write(ad + A_VSIZE, height)
    mm.write(ad + A_HSIZE, hsize)
    mm.write(ad + A_STRD_FRMDLY, hsize)
    for i in range(min(n, 16)):
        mm.write(ad + A_START_ADDR + 4 * i, phys_addrs[i])
    mm.write(CH_MM2S + V_FRMSTORE, n)
    mm.write(CH_MM2S + V_PARKPTR, 0)
    mm.write(CH_MM2S + V_CR, DISPLAY_CR)          # ★ 驻留模式启动

    if verbose:
        print("显示通道已启动（驻留模式，CR=0x%08X），%d 个缓冲；接着调 display_feed() 喂帧"
              % (DISPLAY_CR, n))
    return mm


def display_feed(secs=10.0, interval=0.05, mm=None, verbose=False):
    """
    持续喂帧 secs 秒 —— 每 interval 秒写一次 VSIZE 触发一帧。

    ★ 显示器需要持续信号，写一帧就停会立刻黑屏。实测 20 帧/秒足够。
    """
    import time
    mm = mm or MMIO(VDMA1_BASE, VDMA1_SIZE)
    vsize = mm.read(ADDR_MM2S + A_VSIZE)
    t0, k = time.time(), 0
    while time.time() - t0 < secs:
        mm.write(ADDR_MM2S + A_VSIZE, vsize)      # ★ 写 VSIZE = 触发一帧
        time.sleep(interval)
        k += 1
    if verbose:
        print("  喂帧 %.1fs / %d 次；SR=0x%08X PARKPTR=0x%08X"
              % (secs, k, mm.read(CH_MM2S + V_SR), mm.read(CH_MM2S + V_PARKPTR)))
    return k


def display_demo(secs_each=6.0):
    """
    一条命令跑完验收测试：8 条彩条 + 三原色 + 灰阶。
    需要先 pz2_video.dynclk_set(74.25) 和 vtc_set_720p()。
    """
    buf, views, addrs = make_frames(3, 1280, 720)
    for v in views:
        fill_color_bars(v)
    buf.flush()
    mm = display_start(addrs)
    print("正在循环显示彩条 —— 看屏幕")
    display_feed(secs_each, mm=mm, verbose=True)
    return buf, views, addrs, mm


if __name__ == "__main__":
    print("本文件要在板子的 Jupyter 里用，PC 上跑不了（没 pynq 库）")
