###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：osd.py
# 角色   ：按钮④：硬件 OSD 画框与 ASCII 字符 + osd_live 实时主循环（定位 → 裁图 → 识别 → 计数 → 叠加 → 分拣分派）
# 依赖   ：track、servo
# 启动   ：按钮④
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
osd.py —— PS 端：实时找框 + 识别 + 上屏（2026-10-20 接入识别）

【整条链路】
    buf1（掩膜，DISP=5） --detect()--> boxes ──> 目标表(track.py) ──> 新目标才跑一次 CNN
                                              |                        （从 buf0 干净彩色裁 ROI）
                                              +--> 每帧：跟着已确认目标画框
    buf0（干净彩色） --vdma1/MM2S--> [dd_osd_axis] --> vid_out --> HDMI（彩色 + 框 + 名 + 汇总）
                                   ↑ PS 写框/字到这个模块（基址 0x40000000）

  ★ 屏幕读 buf0、PS 读 buf1 ⇒ 互不干扰，**一帧都不闪**
  ★ CNN 每帧轮转认 1 个目标（CLS_PER_FRAME=1）+ 滑动投票，不是"只认一次"；
    走 PL 加速器时一次约 **14.6 ms**，走 PS tflite 时约 44 ms

【上屏规则】
    · 可回收 → 绿框 + 英文名；不可回收 → 红框 + 英文名
    · 拒识（认不出来）→ **不画框**，只在汇总里计 U（硬件只有红/绿两色，硬画成红会误导）
    · 汇总（如 "R:3 N:2"）放在图像区左上角，占用**最后一个槽位** ⇒ 同时最多标 OSD_MAX-1 个目标

【★ 2026-10-26 分拣改动（只有 3 处）】
    ① osd_live 增加 servo=None 参数；② 传给 TargetTable；③ 每秒打印多一个"分拣 N"。
    servo=None ⇒ 行为与改动前**完全一致**。

【用法】必须按顺序：
    %run cam_full.py      # 建 set_disp / v0 / v1 / buf0 / buf1 / OFF_PX / IMG_W / GLASS / a0 / a1 / start_ch
    capture_bg()          # ★ 空场景时采背景（放物体之前！）
    %run config.py        # 曝光 + 使能 + 掩膜参数（BG_EN 必须 1）
    %run detect.py        # 建 detect() / SHIFT_X / SHIFT_Y / SY / SX / PAD
    %run cnn_pl_infer.py  # ★ 建 PL 分类器 clf_pl（需新位流 + 5 个 model_*.bin）
    %run servo.py         # （可选）建 sv = ServoKick()
    %run osd.py           # 本文件：进实时循环（按 ■ 中断）

  ★★ 2026-10-28：分类器**自动选源**，不用再手写 osd_live(...)
      命名空间里已有 clf_pl  ⇒ 走 PL 加速器（≈14.6 ms/次）
      没有 clf_pl           ⇒ 退回 PS tflite（要先 %run tflite_infer.py，
                               且 model_int8_64.tflite 在同目录）
    启动时会打印到底是哪一种 —— **先看清这一行**，再判断"识别有没有走 PL"。

【关掉】osd_bypass()   # 写新模块 CTRL=0，框和字立刻消失，不用重编
"""

import numpy as np, time                                 # 数值 / 计时
import importlib, sys as _sys                            # ★ 强制重载用（防 Jupyter 模块缓存）
from pynq import MMIO                                    # 新 OSD 模块要单独开一个 MMIO


# ============================================================================
#  ★★ 2026-10-28：跨 %run 的命名空间桥
#  IPython 的 `%run` **默认在一个独立命名空间里执行文件**（只有 `%run -i` 才共享交互
#  命名空间）⇒ 本文件里的 globals() 看不到 cam_full.py / config.py / detect.py /
#  track.py / cnn_pl_infer.py 在 notebook 里建的那些变量。
#  实测踩过两次：① osd_live() 报 "name 'a0' is not defined"；② AUTO_RUN 找不到 clf_pl。
#  这里一次性把交互命名空间的变量搬进本文件的 globals()，下面所有引用都不用改。
#  （用 `%run -i osd.py` 也能规避，但直接把桥修好更省事。）
# ============================================================================
def _ipy_ns():                                           # 取 notebook 的交互命名空间
    try:
        ip = get_ipython()                               # notebook 里有，纯 python 里没有
        return ip.user_ns if ip is not None else {}
    except Exception:
        return {}

_BRIDGED = 0                                             # 搬了多少个名字（打印用）
for _k, _v in list(_ipy_ns().items()):                   # 交互命名空间里的每个名字
    if _k not in globals():                              # 本文件还没有的才搬
        globals()[_k] = _v                               # 搬进来 ⇒ 后面直接引用即可
        _BRIDGED += 1


def _det_par(name, default):
    """取 detect.py 里的参数（SHIFT_X / SHIFT_Y / PAD 的**单一真相源**）
       ★ 为什么：ui.py 改的是 detect 模块自己的全局变量，而本文件里画框(to_screen)、
         裁图(crop_color)、画分拣线都用这几个偏移量。各读各的 globals 就会出现
         "框跟着动了、裁图没动" ⇒ 识别区域和框错位。统一从 detect 模块取。"""
    d = globals().get("detect")                          # detect 函数（bridge 后在本文件 globals 里）
    if d is None:                                        # 还没加载
        return default                                   #   用本文件的兜底值
    return getattr(d, "__globals__", {}).get(name, default)   # 取 detect 模块里的值


def _load_target_table():
    """★ 拿到目标表类，并**保证用的是磁盘上最新的 track.py**
       为什么不能直接 `import track`：Jupyter 的 sys.modules 会缓存已 import 的模块，
       重新上传 track.py 之后 `import track` 仍然返回**旧模块** ⇒ 改了代码等于没改。
       三条路依次尝试：
         ① 本 cell 之前已经 `%run track.py` 过 ⇒ 直接用它放进命名空间的 TargetTable（最新）；
         ② 没跑过 ⇒ import 一次，再 **importlib.reload** 强制按磁盘重新加载；
         ③ 都没有 ⇒ 报清楚，别丢一个看不懂的 NameError。"""
    if "TargetTable" in globals():                       # ① %run track.py 已经建好了
        return globals()["TargetTable"], globals().get("TRACK_VERSION", "(来自 %run)")
    import track                                         # ② 首次导入
    importlib.reload(track)                              # ★ 关键：强制按磁盘最新版重载
    return track.TargetTable, getattr(track, "TRACK_VERSION", "(无版本戳)")


try:
    TargetTable, TRACK_VER = _load_target_table()        # 目标表类 + 版本戳
    print("目标表就绪：track 版本 = %s" % TRACK_VER, flush=True)
except Exception as _e:                                  # 没上传 / 语法错
    TargetTable, TRACK_VER = None, None                  # 置空，后面 osd_live 会报
    print("!! 目标表加载失败：%s —— 确认 track.py 已上传到同一目录" % _e, flush=True)

# ============ 可调参数：改完重跑本 cell ============
OSD_BASE   = 0x40000000        # ★ 新 OSD 模块基址（设计 .hwh 里的 MEMRANGE BASEVALUE）
OSD_RANGE  = 0x1000            # 4KB 地址窗口
SCREEN_W   = 1280              # 显示通路全宽（列计数 0..1279）
SCREEN_H   = 720               # 显示行数（行计数 0..719）
OSD_MAX    = 8                 # 硬件框数上限（N_BOX）
TEXT_H     = 16                # 字高：8×16 点阵
TEXT_GAP   = 2                 # 文字与框留几像素
DISP_MASK  = 5                 # PS 找框用的档：最终掩膜（固定，屏幕不受影响）
SHOW_SUMMARY = True            # 是否在左上角显示 "R:3 N:2"（占用最后一个槽位）
SORT_LINE_SHOW = True          # ★ 2026-10-28：是否在屏上画出那条分拣线（占用一个槽位）
                               #   线位置取 TrackTable 的 x_trig（唯一真相源，不在这里另设）
AUTO_RUN   = True              # ★ 2026-10-29 改回 True（此前一度被我改成 False，是个错误）：
                               #   True  ⇒ `%run osd.py` 立刻进实时循环（**手动那条路就是这个**）
                               #   False ⇒ 只建函数、不进循环 —— 会让手动 `%run osd.py` 看着"没反应"
                               #   ui.py 需要"只取函数"时自己在下面那个开关行之前截断加载，
                               #   所以这里保持 True 不会和界面冲突。
                               #   ★ 注意：这一行注释里**故意不写出那个开关行的完整字面**，
                               #     否则按字符串截断的地方会误把它当成分界行（已踩过一次）。
LIVE_SECONDS = None            # None = 一直跑（■ 中断）

# ---- 寄存器偏移（与 dd_osd.v 一一对应）----
R_ID     = 0x00                # 自检 ID
R_CTRL   = 0x44                # OSD 总控
R_N      = 0x48                # 有效元素个数
R_BASE   = 0x4C                # 元素区基址
STRIDE   = 32                  # 每个元素 32 字节 = 8 个 32bit

# ---- 打开新模块 ----
try:
    OSD = MMIO(OSD_BASE, OSD_RANGE)                      # 新 OSD 模块的寄存器窗口
    _id = OSD.read(R_ID)                                 # 读自检 ID
    print("OSD 模块就绪：base=%#010x  ID=%#010x  %s"
          % (OSD_BASE, _id, "OK" if _id == 0x4F534432 else "!! 不等于 0x4F534432"), flush=True)
except Exception as e:
    OSD = None                                           # 打不开就置空
    print("!! 打开 OSD(%#010x) 失败: %s —— 先确认位流/.hwh 是 2026-10-20 那版" % (OSD_BASE, e), flush=True)


def display_source(use_buf0=True):
    """★ 切换 HDMI 显示的数据源（纯 PS 操作）
       True  → 显示读 buf0（干净彩色）—— 本架构下**必须**是 True
       False → 显示读 buf1（算法输出，跟 DISP 走）—— 会显示掩膜，仅调试用
       ★ 切换会让 VDMA 重启一次 ⇒ 屏幕黑一下，正常"""
    src = a0 if use_buf0 else a1                         # buf0 = 干净彩色 / buf1 = 算法输出
    tag = "vdma1 MM2S 1280(buf0 color)" if use_buf0 else "vdma1 MM2S 1280(buf1 algo)"  # 打印用
    # ★★ 2026-10-28：帧延迟 0 → 1，治"反复启动 osd 后运动物体轻微撕裂"。
    #   根因：每次跑本文件都会调 start_ch **重启显示 MM2S**，重启后"读指针 vs 相机写入的
    #   写指针"的相位是随机的；恰好同相位时，读的就是 S2MM 正在写的那一帧 ⇒ 撕裂。
    #   （显示读的是 buf0，而 buf0 由 **vdma0/S2MM** 写 —— 那是另一个 VDMA 实例，
    #     GenLock 只在本实例内部配对，跨实例没有同步，所以相位靠不住。）
    #   帧延迟 1 ⇒ 显示永远读"上一帧"，绝不会读正在写的那一帧 ⇒ 撕裂消失、行为确定化。
    #   代价：画面晚一帧（33 ms），肉眼看不出来。
    start_ch(VDMA1, CH_MM2S, AD_MM2S, src, tag,            # 复用 cam_full.py 的启动函数（内部先复位通道）
             FRAME_W * 3, FRAME_W * 3,                     # 全宽：每行 1280×3、步长同
             CR_RUNSTOP | CR_TAIL_EN | CR_SYNC_EN | CR_GENLCK_RPT,  # 与原显示那一路相同
             1)                                            # ★ 帧延迟 1（原 0 ⇒ 会撕裂）
    print("显示已切到 %s" % ("buf0（干净彩色 + OSD 叠加）" if use_buf0 else "buf1（算法输出）"), flush=True)


def osd_bypass():
    """一键关叠加：CTRL=0 ⇒ 输出逐像素等于输入"""
    if OSD is not None:                                  # 模块在才写
        OSD.write(R_CTRL, 0)                             # 关掉


def core_osd_off():
    """关掉 core 里那个旧 OSD（它挂在掩膜通路上，开着会污染 buf1 的掩膜）"""
    GLASS.write(0x44, 0)                                 # core 的 OSD_CTRL 也是 0x44


def _chars16(text):
    """把字符串打包成 4 个 32bit（每字节一个 ASCII，小端，不足补空格）"""
    cs = [ord(c) & 0x7F for c in text[:16]]              # 截到 16 个字符
    cs += [0x20] * (16 - len(cs))                        # 不够补空格
    words = []                                           # 结果
    for r in range(4):                                   # 4 个寄存器
        w = 0                                            # 从 0 开始拼
        for j in range(4):                               # 每个装 4 个字符
            w |= cs[4 * r + j] << (8 * j)                # 第 j 个放第 j 字节（小端）
        words.append(w)                                  # 存下
    return words                                         # 返回


def osd_put(ip, k, bx, by, bw, bh, tx, ty, text, green):
    """把「一个框 + 一串字」写进第 k 号槽位，坐标是**画面坐标**"""
    base = R_BASE + STRIDE * k                           # 第 k 号的基址
    n = len(text[:16])                                   # 字符数
    ip.write(base + 0x00, (by << 16) | bx)               # ★ 高 16 位 y、低 16 位 x
    ip.write(base + 0x04, (bh << 16) | bw)               # 高 16 位高、低 16 位宽
    ip.write(base + 0x08, (ty << 16) | tx)               # 文字左上角
    ip.write(base + 0x0C, (n << 2) | (1 if green else 0))  # [6:2] 字符数、[1:0] 颜色
    for r, w in enumerate(_chars16(text)):               # 4 个 32bit
        ip.write(base + 0x10 + 4 * r, w)                 # +0x10/+0x14/+0x18/+0x1C


def text_xy(bx, by, bh, nchar):
    """文字左上角：优先框上方，放不下放框下方，左右夹在图像区内"""
    w  = 8 * nchar                                       # 文字总宽
    lo = OFF_PX                                          # 图像左边界
    hi = OFF_PX + IMG_W                                  # 图像右边界
    tx = bx                                              # 默认与框左对齐
    if tx + w > hi:                                      # 右边出界
        tx = hi - w                                      # 往左挪
    tx = max(lo, tx)                                     # 别越左边界
    ty = by - TEXT_H - TEXT_GAP                          # 先试上方
    if ty < 0:                                           # 上方放不下
        ty = by + bh + TEXT_GAP                          # 放下方
    if ty + TEXT_H > SCREEN_H:                           # 下方也放不下
        ty = SCREEN_H - TEXT_H                           # 夹在底部
    ty = max(0, ty)                                      # 兜底
    return tx, ty                                        # 返回


def to_screen(box):
    """掩膜坐标 → 画面坐标。★ 列要多加 OFF_PX（显示通路全宽 1280，图像从第 160 列起）"""
    x, y, w, h = box                                     # 拆开
    sx = _det_par("SHIFT_X", SHIFT_X)                    # ★ 偏移量以 detect 模块为准
    sy = _det_par("SHIFT_Y", SHIFT_Y)                    #   （ui.py 改的就是它）
    bx = (x - sx) + OFF_PX                               # 掩膜列 → 画面列
    by = y - sy                                          # 掩膜行 → 画面行
    lo = OFF_PX                                          # 图像左边界
    hi = OFF_PX + IMG_W                                  # 图像右边界
    bx = max(lo, min(bx, hi - 1))                        # 夹进图像区
    by = max(0,  min(by, SCREEN_H - 1))                  # 夹进屏幕
    bw = max(2, min(w, hi - bx))                         # 宽：至少 2，不出右边界
    bh = max(2, min(h, SCREEN_H - by))                   # 高：至少 2，不出下边界
    return bx, by, bw, bh                                # 返回


def osd_summary(ip, k, text, green=True):
    """写一个「只有字、没有框」的元素：把框放到画面外（bx=2040）⇒ 框不画，只画字"""
    osd_put(ip, k, 2040, 0, 2, 2, OFF_PX + 4, 4, text, green)   # 框在 2040 列 ⇒ 永不命中


def crop_color(box):
    """从 buf0（干净彩色）裁 ROI 给 CNN —— 列要加 OFF_PX
       ★ 用 buf0 而不是 buf1：buf1 是掩膜，buf0 才是没有框线的原始彩色"""
    x, y, w, h = box                                     # 拆开
    buf0.invalidate()                                    # 丢 cache ⇒ 读到新帧
    img = np.asarray(v0[0])                              # buf0 第 0 帧视图
    sx = _det_par("SHIFT_X", SHIFT_X)                    # ★ 偏移量以 detect 模块为准（和画框同源）
    sy = _det_par("SHIFT_Y", SHIFT_Y)
    pd = _det_par("PAD", PAD)                            #   外扩
    x0 = max(0, x - sx - pd)                             # 左边界（补偿右移 + 外扩）
    y0 = max(0, y - sy - pd)                             # 上边界
    x1 = min(IMG_W, x + w - sx + pd)                     # 右边界
    y1 = min(img.shape[0], y + h - sy + pd)              # 下边界
    return np.array(img[y0:y1, x0 + OFF_PX:x1 + OFF_PX, :])   # 裁出来（列加留边）


def osd_draw(ip, items, summary=None, verbose=False, ctrl=True, sort_line=None):
    """items = [(box, 英文名, 是否绿色), ...]（掩膜坐标）
       summary   = 汇总文字或 None（占用最后一个槽位）
       sort_line = 分拣线的**掩膜列**（None = 不画）；给了就画一条贯穿全屏的 2px 竖线
       返回总共写了几个元素"""
    if ip is None:                                       # 模块没打开
        return 0                                         # 直接返回
    if ctrl:                                             # 一次性画法才先关叠加
        ip.write(R_CTRL, 0)                              # 从干净状态起步
    cap = OSD_MAX - (1 if summary else 0) - (1 if sort_line is not None else 0)
    n   = min(len(items), cap)                           # 这次画几个（要给汇总和竖线留槽）
    for k in range(n):                                   # 逐个
        box, lab, grn = items[k]                         # 取出
        bx, by, bw, bh = to_screen(box)                  # 掩膜坐标 → 画面坐标
        tx, ty = text_xy(bx, by, bh, len(lab))           # 算文字位置
        osd_put(ip, k, bx, by, bw, bh, tx, ty, lab, grn) # 写这一槽位
        if verbose:                                      # 打印换算过程
            print("  #%d 掩膜(%d,%d,%d,%d) → 画面(%d,%d) %d×%d  '%s'@(%d,%d)"
                  % (k, box[0], box[1], box[2], box[3], bx, by, bw, bh, lab, tx, ty), flush=True)
    total = n                                            # 已写元素数
    if summary:                                          # 要写汇总
        osd_summary(ip, n, summary)                      # 紧接在目标后面
        total = n + 1                                    # 元素数 +1
    # ★ 2026-10-28：画分拣线（只有框、没有字 ⇒ 文字 0 个字符）
    if sort_line is not None and total < OSD_MAX:        # 还有空槽
        bx = int(round(float(sort_line) - _det_par("SHIFT_X", SHIFT_X) + OFF_PX))   # 掩膜列 → 画面列
        if OFF_PX <= bx < OFF_PX + IMG_W:                # 只画在图像区内（不画到黑边上）
            osd_put(ip, total, bx, 0, 2, SCREEN_H, 0, 0, "", True)  # 竖条：2 宽 × 全屏高
            total += 1                                   # 元素数 +1
    ip.write(R_N, total)                                 # 有效元素个数
    if ctrl:                                             # 一次性画法才重新打开叠加
        ip.write(R_CTRL, 3)                              # CTRL=3：画框 + 画字
    return total                                         # 返回写了几个


def grab_boxes():
    """抢一帧 → 读掩膜 → 找框（返回 boxes, 这一帧花多少秒）
       ★ 不切 DISP：掩膜档固定 5，屏幕走 buf0 完全不受影响"""
    ts = time.time()                                     # 计时起点
    buf1.invalidate()                                    # 丢 cache ⇒ 读到新帧
    m = np.ascontiguousarray(np.asarray(v1[0])[::SY, OFF_PX:OFF_PX + IMG_W:SX, 0])  # 隔行隔列读掩膜
    boxes = detect(m)                                    # 找框（框已乘回真实坐标）
    return boxes, time.time() - ts                       # 返回框 + 耗时


def osd_live(seconds=None, clf=None, verbose=True, servo=None, stop=None,
             x_trig=None, sort_dir=None):
    """★ 实时循环：找框 → 目标表 → 新目标才认一次 → 上屏
       seconds = None 一直跑（■ 中断）；clf = Classifier 实例或 None（None 时只跟框不识别）
       ★ servo = 舵机驱动实例（有 kick(ch) 方法即可）或 None（None 时不做分拣，行为与旧版一致）
       ★ stop = 无参可调用对象（返回 True 就退出）；ui.py 用它做"停止"按钮。None ⇒ 只能 ■ 中断
       ★ x_trig / sort_dir = 覆盖 track.py 的默认值（分拣线位置 / 运动方向），None = 用 track 的"""
    if OSD is None:                                      # 模块没打开
        print("!! OSD 未就绪，退出", flush=True)          # 提示
        return 0                                         # 返回
    if TargetTable is None:                              # 目标表没加载成功
        print("!! 目标表未就绪，退出（先确认 track.py 已上传）", flush=True)  # 提示
        return 0                                         # 返回
    # ★ 2026-10-28：前置检查。少了 cam_full.py 建的那些变量时，原来会在
    #   display_source() 里抛 "name 'a0' is not defined" —— 栈很深、看不出真正原因。
    #   最容易踩的场景：Restart Kernel 之后 PL 里的位流还在、OSD 也还能读 ID，
    #   看着"一切就绪"，其实 Python 侧的 a0/v0/v1/start_ch 全没了。
    _need = ('a0', 'a1', 'v0', 'v1', 'set_disp', 'start_ch', 'OFF_PX', 'IMG_W')
    _miss = [n for n in _need if n not in globals()]      # 缺哪些
    if _miss:                                            # 缺了就明确说清楚
        print("!! 缺变量 %s —— 这个内核里没跑过 %%run cam_full.py" % ",".join(_miss), flush=True)
        print("   （Restart Kernel 会丢掉这些 Python 变量，但 PL 里的位流仍在，所以看着像'就绪'）", flush=True)
        print("   先 %%run cam_full.py（→ capture_bg() → %%run config.py → %%run detect.py → %%run cnn_pl_infer.py），再回来", flush=True)
        return 0                                         # 不往下走
    display_source(True)                                 # ★ 显示改读 buf0（屏幕黑一下，正常）
    core_osd_off()                                       # ★ 关掉 core 旧 OSD（否则掩膜被框污染）
    set_disp(DISP_MASK, wait=0.0)                        # ★ 掩膜档固定 5，之后再也不动
    OSD.write(R_CTRL, 3)                                 # 只在开头开一次叠加
    # ★ 2026-10-26：兜住"板上 track.py 是旧版"这种情况。
    #   旧版的 TargetTable 没有 servo 参数，直接构造会抛一个看不懂的 TypeError。
    #   这里改成：报一句人话 + 退化成"只识别不分拣"，把循环跑起来。
    _kw = {}                                             # ★ 允许从外部覆盖分拣线/方向
    if x_trig   is not None: _kw["x_trig"]   = int(x_trig)   #   分拣线（掩膜列）
    if sort_dir is not None: _kw["sort_dir"] = int(sort_dir) #   -1 右→左 / +1 左→右
    try:
        tab = TargetTable(clf=clf, servo=servo, **_kw)    # 新版 track.py
    except TypeError:
        tab = TargetTable(clf=clf)                       # 旧版 track.py（没有 servo/x_trig 参数）
        servo = None                                     # 分拣关掉
        print("!! 板上 track.py 是旧版（TargetTable 没有 servo 参数）⇒ 本次不分拣。", flush=True)
        print("   ★ 重新上传 track.py，然后**必须重新 %run track.py**，再 %run osd.py", flush=True)
    try:                                                 # ★ 2026-10-28：把目标表挂到命名空间
        _ipy_ns()["_live_tab"] = tab                     #   ui.py 靠它**实时**改分拣线位置/方向
    except Exception:                                    #   拿不到命名空间就算了（不影响循环）
        pass
    # ★ 2026-10-26：开机就把"到底用没用分类器 / 到底开没开分拣"打出来。
    #   这两个都是 None 时旧代码会静默什么都不做、也不报错，极难查。
    print("循环就绪：分类器 = %s ；分拣 = %s"
          % (type(clf).__name__ if clf is not None else "None（不识别！）",
             ("已启用（X_TRIG=%d，映射 %s）" % (getattr(tab, 'x_trig', -1),
                                            getattr(tab, 'c2s', {})))
             if servo is not None else "未启用（servo=None）"), flush=True)
    t0     = time.time()                                 # 起始时刻
    frames = 0                                           # 已处理帧数
    tsum, tmax = 0.0, 0.0                                # 找框耗时：累计 / 最慢
    n_new_all = 0                                        # 累计新分类了几个
    tprint = t0                                          # 上次打印时刻
    try:                                                 # 让 ■ 能干净退出
        while True:                                      # 主循环
            if seconds is not None and time.time() - t0 >= seconds:  # 限时到了
                break                                    # 跳出
            if stop is not None and stop():              # ★ ui.py 的"停止"按钮
                print("  (已按停止)", flush=True)          # 提示
                break                                    # 跳出
            boxes, dt = grab_boxes()                     # ① 找框
            frames += 1                                  # 帧数 +1
            tsum += dt                                   # 累计
            tmax  = max(tmax, dt)                        # 更新最慢
            tgts, n_new = tab.update(boxes, crop_color)  # ② 匹配 +（新目标才）分类（★ 内含过线分拣）
            n_new_all += n_new                           # 累计新分类数
            items = tab.draw_list()                      # ③ 该画的（已确认且认出来的）
            summ  = None                                 # 汇总文字
            if SHOW_SUMMARY:                             # 要显示汇总
                r, n, u = tab.counts()                   # 可回收 / 不可回收 / 未知
                summ = "R:%d N:%d" % (r, n)              # 基本汇总
                if u:                                    # 有拒识的
                    summ += " U:%d" % u                  # 补上未知数
            # ★ 2026-10-28：把分拣线也画到屏上（位置取 TrackTable 的 x_trig，唯一真相源）
            _line = getattr(tab, "x_trig", None) if SORT_LINE_SHOW else None
            osd_draw(OSD, items, summary=summ, ctrl=False, sort_line=_line)   # ④ 上屏（不动 CTRL）
            if verbose and (time.time() - tprint >= 1.0):    # 每秒一行
                el = time.time() - t0                    # 已运行时间
                print("  [%5.1fs] %4d 帧  %5.1f Hz  找框 %.1f ms  目标 %d  已认 %d  CNN %d 次(均 %.1f ms)  %s"
                      % (el, frames, frames / max(el, 1e-9), (tsum / frames) * 1000,
                         tab.n_all(), tab.n_ok(), tab.n_cnn,
                         (tab.t_cnn / tab.n_cnn) * 1000 if tab.n_cnn else 0.0,
                         # ★ 未启用时打 "--"，不要打 0 —— 否则"没开分拣"和"开了但没触发"看起来一样
                         ("分拣 %d" % getattr(tab, "n_fire", 0))
                         if servo is not None else "分拣 --(未启用)"), flush=True)
                tprint = time.time()                     # 更新打印时刻
    except KeyboardInterrupt:                            # 用户按了 ■
        print("  (已中断)", flush=True)                    # 提示
    el = time.time() - t0                                # 总时长
    if verbose:                                          # 收尾汇总
        print("实时循环结束：%d 帧 / %.1f 秒 = %.1f Hz；找框 平均 %.1f ms、最慢 %.1f ms"
              % (frames, el, frames / max(el, 1e-9), (tsum / max(frames, 1)) * 1000, tmax * 1000), flush=True)
        print("  ★ CNN 一共调用了 %d 次（新目标 %d 个，平均 %.1f ms）；表里还有 %d 个目标"
              % (tab.n_cnn, n_new_all, (tab.t_cnn / tab.n_cnn) * 1000 if tab.n_cnn else 0.0,
                 tab.n_all()), flush=True)
        print("  ★ 分拣触发 %d 次（每个目标过线只触发一次）" % getattr(tab, "n_fire", 0), flush=True)
        print("  框会停住不动；要清掉用 osd_bypass()", flush=True)  # 一键关
    return frames                                        # 返回处理了多少帧


# ---- 自动跑 ----
if AUTO_RUN:                                             # 关掉就改上面 AUTO_RUN
    # ★ 2026-10-28：分类器自动选源 —— 不用再手写 osd_live(...)，也不用改 AUTO_RUN
    #   ① 命名空间里已有 clf_pl（%run cnn_pl_infer.py 建的 PL 加速器）⇒ 走 PL
    #   ② 没有 ⇒ 退回 PS 的 tflite Classifier（与改动前行为完全一致）
    #   查找范围放宽：%run 有时把变量放进 __main__，globals() 不一定都能看到
    _m = getattr(_sys, 'modules', {}).get('__main__')    # 兜底：__main__ 命名空间
    _clf = globals().get('clf_pl') or getattr(_m, '__dict__', {}).get('clf_pl')   # ① 先找 PL 分类器
    if _clf is not None:                                 #    有 ⇒ 就用 PL
        print("分类器就绪：**PL 加速器** clf_pl（cnn_pl_infer.PLClassifier）  拒识阈值 th=%.2f"
              % getattr(_clf, 'th', 0.5), flush=True)
    else:                                                # ② 没有 ⇒ 退回 PS
        try:                                             #    需要先 %run tflite_infer.py
            _clf = Classifier('model_int8_64.tflite', num_threads=2)   # PS 推理（双核）
            print("分类器就绪：PS tflite（model_int8_64.tflite）  拒识阈值 th=%.2f" % _clf.th, flush=True)
        except Exception as _e:                          #    两条路都不通
            _clf = None                                  #    只找框、不识别
            print("!! 分类器初始化失败：%s —— 要么先 %%run cnn_pl_infer.py 走 PL，要么 %%run tflite_infer.py 走 PS" % _e, flush=True)
    print("开始实时循环：屏幕 = buf0 干净彩色 + 框/英文名/汇总；按 ■ 中断；osd_bypass() 可清屏", flush=True)
    # ★ 2026-10-26：分拣不需要任何额外的前置步骤 —— 这里自己把舵机驱动建起来。
    #   ① 命名空间里已经有 sv ⇒ 直接用；② 没有 ⇒ import servo 建一个；
    #   ③ 都失败 ⇒ 只识别不分拣，并把失败原因打出来。
    _sv = globals().get('sv')                            # ① 有现成的就用
    if _sv is None:                                      # ② 没有就自己建
        try:
            from servo import ServoKick as _ServoKick    #    同目录的 servo.py
            _sv = _ServoKick()                           #    打开 0x43C40000 + 写参数 + 使能
            print("分拣：已建舵机驱动（servo.ServoKick）", flush=True)
        except Exception as _e:                          # ③ 建不起来
            _sv = None                                   #    分拣关掉
            print("!! 舵机不可用，本次只识别不分拣：%s" % _e, flush=True)
    osd_live(LIVE_SECONDS, clf=_clf, servo=_sv)          # 进循环
