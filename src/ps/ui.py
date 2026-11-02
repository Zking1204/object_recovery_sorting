###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：ui.py
# 角色   ：ipywidgets 图形控制台，本作品的唯一操作入口：5 个按钮 + 参数面板。加载时只搭界面、不做任何硬件动作，所有硬件动作只能由按钮触发
# 依赖   ：无模块级依赖；按按钮时才去执行其它脚本
# 启动   ：板端 Jupyter 中 %run ui.py，然后依次按 ①→②→③→④
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ui.py —— 实时垃圾分类识别与计数 控制台（ipywidgets）

【怎么用】  就一句：
    %run ui.py
  ★ **加载本文件只搭界面**：不碰 PL、不碰相机、不加载任何模块 —— 只把按钮和滑块建出来。
    然后按下面 5 个按钮的先后顺序操作。

【界面上有】（按顺序点，全部是"按按钮 = run 对应文件"）
    ① 加载位流     ⇒ `%run cam_full.py`
    ② 加载识别     ⇒ `%run config.py` → `%run detect.py`（整份，含尾部 5 次检测演示）
                      → `%run cnn_pl_infer.py` → `clf_pl.selftest()` → `%run servo.py`
    ③ 采集背景     ⇒ `capture_bg()`
    ④ 开始识别     ⇒ `%run osd.py`，再在后台线程跑 `osd_live(...)`（可用⑤中止）
    ⑤ 中止
    ⑥ 曝光·增益·白平衡
    ⑦ 掩膜：灰度阈值 / 中值 / 闭运算 / 阴影四项
    ⑧ 找框：最小面积 / 两框融合 + 融合间距 / 框左右移（SHIFT_X/Y）+ 外扩
    ⑨ 舵机：偏转角（°）/ 偏转延时 / 保持时间 / 返回斜坡 + 三路测试 + 急停
    ⑩ 分拣线：屏上画不画 / 屏幕列位置（默认 640 = 屏幕正中）/ 运动方向（右→左 或 左→右）
    ⑪ DISP 预览：0 原图 / 5 掩膜 / 6 灰度 / 7 背景 / 8 亮度差 / 9 色度差 / 10 阴影标记

【分拣规则】
    物体 **从右向左** 走；质心越过分拣线的那一刻，按**屏幕上显示的那一类**触发对应舵机：
    舵机1 = can（易拉罐）｜舵机2 = plastic_bottle（塑料瓶）｜舵机3 = cardboard（纸壳）
    ★ **直接凭空出现在竖线左边的目标不管**（它从没在线右侧出现过 ⇒ 不触发）。
    ★ 坐标换算：屏幕列 = 掩膜列 − SHIFT_X + OFF_PX ⇒ 屏幕正中 640 列 ⇔ 掩膜列 494。

【两个必须知道的约束】
  ★ DISP 只影响 `buf1`（PS 找框和调试看的那种图），**不影响 HDMI 画面** —— HDMI 走 `buf0`
    的干净彩色。所以"看 DISP"是在 notebook 里出图，不是看屏幕。
  ★ 识别循环运行时 DISP 必须留在 **5**（`detect()` 就是按掩膜找框的）。

【设计要点】
  · 参数一改立刻生效，**不用重启内核、不用重传文件**（写寄存器 / 改 detect 模块的参数）。
  · 所有文件都用 `exec(..., ns, ns)` 跑进 **notebook 的同一个命名空间** —— 这样不存在
    `%run` 那种"每个文件一个独立命名空间、互相看不见变量"的坑。
"""

import os
import time
import threading
import numpy as np
import cv2

# ---------------------------------------------------------------- ipywidgets
try:
    import ipywidgets as W                                   # 图形控件
    from IPython.display import display, clear_output        # 显示 / 清输出
except Exception as _e:                                      # 板上没装
    raise SystemExit(
        "!! 没有 ipywidgets，界面起不来：%s\n"
        "   板上没外网，pip 装不了；先确认 `import ipywidgets` 是否报错。\n"
        "   若确实没有，可退回命令行方式：%run osd.py 那种手动流程。" % _e)


# ---------------------------------------------------------------- 命名空间
def _ipy_ns():
    """notebook 的交互命名空间（所有文件都往这里跑，共用一套变量）
       ★ 必须 `from IPython import get_ipython` 显式导入：
         `get_ipython` 只是 IPython 在**执行 cell 时**临时注入 builtins 的名字，
         在函数体里（尤其 widget 回调里）直接写 `get_ipython()` 会 NameError。
         （2026-10-29 上板踩过：ui.py 里两处都抛 NameError，`_ipy_ns()` 被 except 吞掉后
           静默退回 globals()，`_run_magic()` 直接把异常抛到界面上。）"""
    try:
        from IPython import get_ipython as _gi                # IPython 自带的取壳函数
        ip = _gi()                                            # notebook 里有
        return ip.user_ns if ip is not None else globals()
    except Exception:
        return globals()

NS = _ipy_ns()                                               # ★ 全局只用这一个命名空间


def _have(*names):
    """这些名字是不是都已经在命名空间里了"""
    return all(n in NS for n in names)


def _exec_file(fname):
    """把同目录的某个 .py 跑进 notebook 命名空间（等价于 %run，但共享变量）
       ★ 为什么不直接 %run：%run 默认在独立命名空间执行，文件之间互相看不见变量
         （本工程踩过：config.py 找不到 wr16、osd.py 找不到 a0）。"""
    path = os.path.join(os.getcwd(), fname)                  # 当前目录下的文件
    if not os.path.exists(path):                             # 没传上来
        raise RuntimeError("找不到 %s（要放在和本文件同一个目录）" % path)
    src = open(path, encoding="utf-8").read()                # 读源码
    exec(compile(src, path, "exec"), NS, NS)                 # 在同一个命名空间里执行


def _exec_file_head(fname, marker):
    """只执行某个 .py 的"前半段"（到 marker 那一行为止）
       ★ 为什么要这样：detect.py 的**尾部会真的跑一次检测并出图**（它是交互脚本），
         自动加载时不需要那些副作用，只要它前面的参数和函数定义。

       ★★ 2026-10-29 上板踩过一个坑：本来判断条件是"这一行里含有 marker"，
         结果 `osd.py` 里**一行注释**（我写的说明性注释）里恰好也含 `if AUTO_RUN:`，
         截断点就被提前到了那行注释处 ⇒ 整个文件只剩头部常量、函数一个都没定义 ⇒
         表现为"点开始识别说找不到 osd_live，手动 %run 一遍 osd.py 之后就好了"。
       ⇒ 所以这里必须**跳过注释行**：去掉行首空白后以 `#` 开头的行不参与匹配。"""
    path = os.path.join(os.getcwd(), fname)
    if not os.path.exists(path):
        raise RuntimeError("找不到 %s" % path)
    lines = open(path, encoding="utf-8").read().splitlines(True)
    m_is_comment = marker.lstrip().startswith("#")       # marker 本身就是注释（如 detect.py 那种）
    cut = len(lines)
    for i, ln in enumerate(lines):
        if (not m_is_comment) and ln.lstrip().startswith("#"):   # ★ 普通 marker 时跳过注释行
            continue                                             #    （我的注释踩过这个坑）
        if marker in ln:                                     # 找到真正的代码分界行
            cut = i
            break
    else:                                                    # ★ 没找到分界就不许整份跑
        raise RuntimeError("%s 里找不到分界行 %r（拒绝整份执行，防止它末尾的副作用）"
                           % (fname, marker))
    exec(compile("".join(lines[:cut]), path, "exec"), NS, NS)


def _install_cnn_settle(clf, wait_ms=200):
    """★ 给 CNN 推理补两件事，直接针对 `CTRL=0x00000001` 卡死：

    ① **强制清一次 AP_START**（最关键）
       AP_START 是**边沿触发**的。只要它被上一轮留在了 1，之后每次写 1 **都不是新的
       上升沿**，内核永远不会再启动 —— 现象就是 `CTRL` 一直是 `0x00000001`、
       每帧都"等 AP_DONE 超时"，而且点多少次都一样。
       这里在 `write_ptrs()` 末尾先写 `CTRL=0` 把它清掉，紧随其后的 `write(CTRL,1)`
       就是一次干净的 0→1 上升沿。**这一步不需要重烧位流。**
       （`infer()` 内部先调 `self.write_ptrs()` 再写 AP_START，所以清与启动的先后天然正确。）

    ② **写完基地址先等内核空闲（AP_IDLE=1）再启动**
       `selftest()` 就是「写基地址 → 空等 → 写 AP_START」，它能 PASS；
       `infer()` 是「写基地址 → 立刻写 AP_START」。这里把等待补上，让两者时序一致。

    ★ 只改这个**实例**的方法，不动 `cnn_pl_infer.py` 文件；重新 `%run cnn_pl_infer.py` 即可恢复。
    ★ 判据：装上之后循环里的 `CNN N 次` 开始增长；装不上就还是 0 次 + 超时。"""
    if clf is None or getattr(clf, "_settle_installed", False):
        return clf                                    # 没有分类器 / 已经装过，直接返回
    _orig = clf.write_ptrs                            # 记住原来的方法

    def _write_ptrs_then_settle():                    # 包装版：写完基地址 → 清 AP_START → 等空闲
        _orig()                                       # ① 先正常写完 6 个基地址（各 32×2 位）
        ip = clf.ip                                   # ② 拿 IP 句柄
        ip.write(0x00, 0)                             # ③ ★ 清 AP_START/DONE：把卡住的 0x01 打回 0x00
        dl = time.time() + wait_ms / 1000.0           #    等待上限（毫秒 → 秒）
        while time.time() < dl:                       # ④ 等内核回到空闲
            if ip.read(0x00) & 0x04:                  #    CTRL bit2 = AP_IDLE
                break                                 #    空闲了就能启动
        ip.read(0x00)                                 # ⑤ 再读一次：把在途的 AXI-Lite 写冲干净

    clf.write_ptrs = _write_ptrs_then_settle          # 绑到**实例**上（覆盖类方法）
    clf._settle_installed = True                      # 打标记，避免重复包装
    print("   CNN 时序补丁已装：每次推理前先清 AP_START、等 AP_IDLE 再启动"
          "（针对 CTRL=0x00000001 卡死；未改 cnn_pl_infer.py）", flush=True)
    return clf


def _pl_loaded():
    """PL 里是不是**已经**有正在跑的位流（只读 sysfs，绝不访问任何 PL 地址）

    为什么必须有这个判据：再调一次 `Overlay()` 会**重新编程 PL** —— VDMA / VTC / dynclk /
    cnn_top / servo_pwm 的寄存器全部被复位，正在跑的相机链路当场断掉。这就是
    "重复加载位流出问题"的来源。
    判据：`/sys/class/fpga_manager/fpga0/state` == "operating" ⇒ 位流已配置。
    （P0 红线：加载 overlay 之前绝不读 PL 地址，所以只敢看这个 sysfs 文件。）"""
    try:
        return open("/sys/class/fpga_manager/fpga0/state").read().strip() == "operating"
    except Exception:                                    # 文件不存在 / 读不到
        return False


def _cam_full_no_use():                                  # ★ 已废弃，保留仅为说明历史
    """✗ 已废弃：不要用 `Overlay(download=False)` 来"跳过重烧位流"。

    2026-10-29 上板实测：这样跑 cam_full.py 会在"读传感器芯片 ID"那一步炸
    （`cam_full.py:227  cid != 0x5640 ⇒ raise SystemExit`）。
    根因：**PL 里确实有某个位流（fpga_manager=operating），但我们无法确认它是哪一版**。
      SCCB 是走 **PS EMIO GPIO** 位敲的，而 EMIO 到外部引脚的路由写在**位流**里 ——
      位流不对（旧版/别的设计）⇒ SCCB 完全不通 ⇒ 读回 ID=0 ⇒ cam_full 主动停手。
    结论：**只要 PS 侧链路没建起来，就必须老老实实烧一遍正确的位流。**
    （这正是 `_pl_loaded()` 只能当"信息"用、不能当"跳过依据"的原因。）"""
    raise RuntimeError("已废弃：请直接 _exec_file('cam_full.py')")


def _reload_pl():
    """★ 把 PL 彻底重来一遍（重载位流 → 重下 config → 重建 clf_pl）
       为什么必须有这个函数：
         `cnn_top` 一旦卡在 `AP_START=1`（写进去没被硬件消费），后续每次写 AP_START=1
         **都不是新的上升沿**，内核永远不会再启动 ⇒ 表现为 selftest 读到 6 个 0、
         识别时"等 AP_DONE 超时 CTRL=0x00000001"，而且**软件侧无法中止**
         （AP_START 清零不会中止已启动的 HLS 内核）。
         唯一的复位手段 = 重新编程 PL，也就是再跑一次 cam_full.py 里的 Overlay()。
         而 cam_full.py 本身没有"跑过就跳过"的门，重跑它就等于硬复位。
       顺序不能改：cam_full 会把曝光/AWB 打回默认 ⇒ 必须重跑 config；
       并且重跑 cam_full 会清掉 cnn_top 的 6 个基地址寄存器 ⇒ 必须重建 clf_pl。"""
    print(">>> ★ 重载位流复位 PL（约 15~20 秒，屏幕会黑一下）", flush=True)
    NS.pop("clf_pl", None)                       # 丢掉旧分类器（它占的 CMA 缓冲随之回收）
    NS.pop("PLClassifier", None)                 # 清掉类名，让下面的 exec 真的重建
    _exec_file("cam_full.py")                    # ① Overlay() 重新编程 PL ⇒ 挂死的内核复位
    _exec_file("config.py")                      # ② 曝光/AWB 被打回了，重下一遍默认值
    _exec_file("cnn_pl_infer.py")                # ③ ★ 重建 clf_pl，并重写 6 个基地址寄存器
    _c = _get("clf_pl")                          # 重建出来了没
    print(">>> 重载完成，clf_pl = %s" % ("OK" if _c is not None else "None（看上面报错）"),
          flush=True)
    return _c


# ---------------------------------------------------------------- 小工具
def _get(name, default=None):
    return NS.get(name, default)


def _detect_globals():
    """`detect()` 函数自己的 globals（改 MIN_AREA / MERGE_GAP / SHIFT_X… 要改这里）"""
    d = NS.get("detect")
    return getattr(d, "__globals__", NS) if d is not None else NS


def _set_status(msg):
    """底部状态栏"""
    _lbl_status.value = msg


# ================================================================= 硬件动作
def apply_exposure(exp_lines, gain, en=True):
    """曝光 + 增益（切手动才生效）。曝光单位是 1/16 行 ⇒ ×16"""
    wr16 = _get("wr16")
    if wr16 is None:
        raise RuntimeError("没有 wr16 —— 先跑 cam_full.py")
    if not en:
        wr16(0x3503, 0x00)                                   # 全部回自动
        return "曝光=自动"
    wr16(0x3503, 0x03)                                       # AEC 手动 + AGC 手动
    wr16(0x350A, (gain >> 8) & 0x03)                         # 增益高 2 位
    wr16(0x350B, gain & 0xFF)                                # 增益低 8 位
    v = int(exp_lines) * 16                                  # 曝光 20 位，单位 1/16 行
    wr16(0x3500, (v >> 16) & 0x0F)                           # 高 4 位
    wr16(0x3501, (v >> 8) & 0xFF)                            # 中 8 位
    wr16(0x3502, v & 0xFF)                                   # 低 8 位
    return "曝光 %d 行 @ %.1fx（手动）" % (exp_lines, gain / 16.0)


def apply_awb(lock):
    """白平衡：锁定当前值 / 回自动。★ 阴影判据靠色度差，锁了才稳"""
    wr16, rd8 = _get("wr16"), _get("rd8")
    if wr16 is None or rd8 is None:
        raise RuntimeError("没有 wr16/rd8 —— 先跑 cam_full.py")
    if not lock:
        wr16(0x3406, 0x00)                                   # 回自动
        return "AWB = 自动（未锁定，色度判据会漂）"
    r = (rd8(0x3400) << 8) | rd8(0x3401)                     # 读当前 R 增益
    g = (rd8(0x3402) << 8) | rd8(0x3403)                     # 读当前 G 增益
    b = (rd8(0x3404) << 8) | rd8(0x3405)                     # 读当前 B 增益
    wr16(0x3406, 0x01)                                       # 先切手动，防被自动覆盖
    wr16(0x3400, r)                                          # 写回刚读到的值
    wr16(0x3402, g)
    wr16(0x3404, b)
    return "AWB 已锁定 R=0x%04X G=0x%04X B=0x%04X" % (r, g, b)


def apply_mask(th, med, morph):
    """掩膜参数 0x20 DEF_TH = [15:8]阈值 | [3]闭运算 | [2]中值 | [1]极性 | [0]支路A使能
       ★ 极性固定 0（报"比背景亮"的）、支路B 固定关（开了会把边缘混进掩膜）"""
    g = _get("GLASS")
    if g is None:
        raise RuntimeError("没有 GLASS —— 先跑 cam_full.py")
    g.write(0x20, (int(th) << 8) | (1 << 3 if morph else 0) | (1 << 2 if med else 0) | (0 << 1) | 1)
    return "掩膜：阈值=%d 中值=%d 闭运算=%d" % (th, med, morph)


def apply_shadow(en, wy, wc, tau, alpha):
    """阴影参数 0x28 = [31:24]αmin | [23:16]τc | [11:8]wC | [7:4]wY | [0]使能"""
    g = _get("GLASS")
    if g is None:
        raise RuntimeError("没有 GLASS —— 先跑 cam_full.py")
    g.write(0x28, (int(alpha) << 24) | (int(tau) << 16) | (int(wc) << 8) | (int(wy) << 4) | (1 if en else 0))
    return "阴影：使能=%d wY=%d wC=%d τc=%d αmin=%.2f" % (en, wy, wc, tau, alpha / 256.0)


def apply_detect(min_area, merge_on, merge_gap, shift_x, shift_y, pad):
    """改 detect() 用的参数（它读的是自己模块的全局变量，所以要写进它的 __globals__）"""
    g = _detect_globals()
    g["MIN_AREA"]  = int(min_area)                           # 过滤多少面积以下的小白块
    g["MERGE_GAP"] = int(merge_gap) if merge_on else 0        # 0 = 不融合
    g["SHIFT_X"]   = int(shift_x)                            # 框左右移（掩膜→原图列补偿）
    g["SHIFT_Y"]   = int(shift_y)                            # 框上下移
    g["PAD"]       = int(pad)                                # 框外扩（防切边）
    return ("找框：最小面积=%d 融合=%s(间距%d) 偏移 X=%d Y=%d 外扩=%d"
            % (min_area, "开" if merge_on else "关", merge_gap, shift_x, shift_y, pad))


def do_capture_bg():
    """采背景（必须在空场景、放物体之前）"""
    cb = _get("capture_bg")
    if cb is None:
        raise RuntimeError("没有 capture_bg —— 先跑 cam_full.py")
    cb()
    return "背景已采好并打开差分"


def apply_enables():
    """总使能 + DISP 固定 5（背景差分由【采集背景】自己打开）"""
    g = _get("GLASS")
    if g is None:
        raise RuntimeError("没有 GLASS —— 先跑 cam_full.py")
    g.write(0x04, 1)                                         # 总使能 CTRL
    g.write(0x1C, 5)                                         # DISP=5 最终掩膜
    return "使能：CTRL=1  DISP=5"


# ---------------------------------------------------------------- 舵机
# 两点实测标定：PW_IDLE=1500 µs ↔ 0°（中位）、PW_ACT=2000 µs ↔ 60°
_SERVO_US_PER_DEG = 500.0 / 60.0                             # 每度多少 µs


def servo_deg2us(deg):
    """角度 → 脉宽（µs）。以 1500 µs 为 0°，线性外推"""
    idle = int(_get("PW_IDLE", 1500))                        # 中位（0°）
    return int(round(idle + float(deg) * _SERVO_US_PER_DEG))


def apply_servo_ch(ch, deg, dly, act, ret, rev=False, idle_us=None):
    """★ 只设置**第 ch 路**（0/1/2）的参数：中位脉宽 / 偏转角 / 偏转延时 / 偏转保持 / 返回斜坡

    `idle_us` = 这一路的**中位脉宽**（回正后停住的位置），1000~2000 µs、可直接输到 1 µs。
      ★ 为什么要有这个：装上挡板后舵机带上转动惯量，某些停住位置会让它
        在死区边界上来回过冲修正（表现为"回正后一直抖"）。把中位挪开几 µs
        常常就能落到一个安静的位置 —— 这是软件唯一能做的规避手段。
    `rev=False` 正向：脉宽 = 中位 + 角度×8.333 µs；`rev=True` 反向：中位 − 角度×8.333。

    ★ 限幅顺序：**必须先放宽限幅寄存器再写脉宽**。正向放宽 `PW_MAX`（硬上限 2500）；
      反向放宽 `PW_MIN`（硬下限 500，反向目标夹在 ≥700 µs）。"""
    sv = _get("sv")                                          # 舵机驱动
    if sv is None:                                           # 没建起来
        raise RuntimeError("没有 sv —— 先点【② 加载识别】或重跑 %run servo.py")
    reg_pwmax = int(_get("R_PWMAX", 0x38))                   # 限幅上限寄存器
    reg_pwmin = int(_get("R_PWMIN", 0x34))                   # 限幅下限寄存器
    reg_ctrl = int(_get("R_CTRL", 0x04))                     # 总使能寄存器（servo 侧的 0x04）
    if idle_us is not None:                                  # ★ 先写中位（后续换算都用新中位）
        _iu = max(1000, min(int(idle_us), 2000))             #   夹在安全范围 1000~2000 µs
        sv.set_angles_ch(ch, idle_us=_iu)                    #   写这一路的 PWx_IDLE
        idle = _iu                                           #   换算基准跟着更新
    else:                                                    # 没给就沿用当前值
        idle = int(_get("PW_IDLE", 1500))
    span = int(round(abs(float(deg)) * _SERVO_US_PER_DEG))   # |角度| 对应多少 µs
    warn = ""                                                # 提示文字
    if rev:                                                  # ---- 反向：脉宽比中位小 ----
        us = idle - span                                     # 目标脉宽
        us = max(us, 700)                                    # SG90 安全下限 700 µs
        pw_min = min(int(_get("PW_MIN", 1000)), us, idle)    # ★ 先放宽下限（也要 ≤ 中位）
        pw_min = max(pw_min, 500)                            #   但不能低于 RTL 硬下限 500
        sv.ip.write(reg_pwmin, pw_min)                       # ① 写下限
        NS["PW_MIN"] = pw_min                                #   常量跟着更新
        if (idle - span) < 700:                              # 角度要求超出安全下限
            warn = "  ⚠ 反向角度过大，已夹到 700 µs"
    else:                                                    # ---- 正向：脉宽比中位大 ----
        us = idle + span                                     # 目标脉宽
        pw_max = max(2000, us, idle, int(_get("PW_MAX", 2000)))   # 上限 ≥2000 且不低于目标/中位
        pw_max = min(pw_max, 2500)                           # 硬上限 2500（再高会撞限位堵转）
        us = min(us, pw_max)                                 # 目标不能超过上限
        sv.ip.write(reg_pwmax, pw_max)                       # ① 写上限
        NS["PW_MAX"] = pw_max                                #   常量跟着更新
        if us >= 2500:                                       # 顶到硬上限了
            warn = "  ⚠ 角度过大被 PW_MAX 硬上限夹住（2500 µs）"
    sv.set_angles_ch(ch, act_us=us)                          # ② 写**这一路**的偏转脉宽
    sv.set_times_ch(ch, dly_ms=int(dly), act_ms=int(act),    # ③ 写**这一路**的三个时间
                    ret_ms=int(ret))
    sv.ip.write(reg_ctrl, 1)                                 # ④ 使能（正常 PWM）
    eff = sv.pw_eff()                                        # 读回三路实际脉宽（已限幅）
    got = sv.get_times_ch(ch)                                # ★ 回读这一路实际生效的三个时间
    return ("ch%d %s：中位 %d µs｜%.0f° = %d µs｜延时 %d → 保持 %d → 斜坡 %d ms"
            "｜回读 延时%d 保持%d 斜坡%d｜三路实测脉宽 %s%s"
            % (ch + 1, "反向" if rev else "正向", idle, deg, us, dly, act, ret,
               got[0], got[1], got[2], eff, warn))


def apply_servo(deg, dly, act, ret, en=True, rev=False):
    """设置**三路一起**的四个参数（老行为，内部就是逐路调 apply_servo_ch）"""
    msgs = [apply_servo_ch(ch, deg, dly, act, ret, rev) for ch in range(3)]  # 三路各写一遍
    return "三路统一：" + msgs[0]                             # 回显第一路详情（三路一致）


def servo_kick(ch):
    """测试：立刻踢第 ch 路一次（走完 延时→偏转→保持→斜坡回中位）"""
    sv = _get("sv")
    if sv is None:
        raise RuntimeError("没有 sv —— 先跑 servo.py")
    sv.kick(ch)                                              # 触发这一路
    d, a, r = sv.get_times_ch(ch)                            # ★ 读**这一路**实际生效的三个时间
    return "已触发 ch%d（延时 %d ms → 保持 %d ms → 斜坡 %d ms 回中位）" % (ch + 1, d, a, r)


def servo_estop(on):
    """急停：CTRL=0 停 PWM（舵机失力、可手动掰）；on=False 恢复"""
    sv = _get("sv")
    if sv is None:
        raise RuntimeError("没有 sv —— 先跑 servo.py")
    sv.ip.write(int(_get("R_CTRL", 0x04)), 0 if on else 1)
    return "舵机 PWM 已停（失力，可手动掰）" if on else "舵机 PWM 已恢复"


DISP_NAMES = {0: "原图", 1: "尺寸", 2: "支路A", 3: "支路B", 4: "A|B",
              5: "最终掩膜", 6: "当前帧灰度", 7: "背景（彩色）",
              8: "亮度差 |ΔY|", 9: "色度差", 10: "阴影标记"}


def show_disp(mode):
    """切 DISP 并在 notebook 里把那一档画出来（★ 只影响 buf1，不影响 HDMI）"""
    set_disp = _get("set_disp")
    v1, buf1, OFF, IMG = _get("v1"), _get("buf1"), _get("OFF_PX", 0), _get("IMG_W", 972)
    if set_disp is None:
        raise RuntimeError("没有 set_disp —— 先跑 cam_full.py")
    set_disp(int(mode), wait=0.25)                           # 切档并等它生效
    buf1.invalidate()                                        # 丢 cache 取新帧
    img = np.asarray(v1[0])[:, OFF:OFF + IMG]                # 只取图像区（丢掉两侧黑边）
    fig, ax = _plt.subplots(1, 1, figsize=(8, 5))            # 新画一张
    if int(mode) == 7:                                       # 背景是彩色（BGR）
        ax.imshow(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    else:                                                    # 其余都是单通道灰度/二值
        ax.imshow(img[:, :, 0], cmap="gray", vmin=0, vmax=255)
    ax.set_title("DISP=%d  %s   (%dx%d)" % (mode, DISP_NAMES.get(mode, "?"), img.shape[1], img.shape[0]))
    ax.axis("off")
    _plt.tight_layout(); _plt.show()


def _mask_col():
    """分拣线：屏幕列 → 掩膜列。屏幕列 = 掩膜列 − SHIFT_X + OFF_PX ⇒ 掩膜列 = 屏幕列 − OFF_PX + SHIFT_X"""
    off = int(_get("OFF_PX", 160))                           # 行内留边（图像从第 160 列起）
    sx = int(_get("SHIFT_X", 14))                            # 掩膜相对彩色原图右移的列数
    m = int(round(sl_line.value - off + sx))                 # 换算
    return max(0, min(m, int(_get("IMG_W", 972)) - 1))       # 夹在图像区内


def apply_sort_line(screen_col, sort_dir, show_line):
    """分拣线位置 + 运动方向 + 是否画线
       ★ 位置/方向在**循环运行时也能实时改**（直接改内存里那张目标表）；画线开关每帧都读"""
    off = int(_get("OFF_PX", 160))                           # 只为打印
    sx = int(_get("SHIFT_X", 14))
    mask_col = max(0, min(int(round(screen_col - off + sx)),
                          int(_get("IMG_W", 972)) - 1))      # 屏幕列 → 掩膜列
    NS["SORT_LINE_SHOW"] = bool(show_line)                   # ★ 立即生效（osd_draw 每帧读它）
    tab = _get("_live_tab")                                  # 循环在跑时 osd_live 会把表挂出来
    if tab is not None:                                      # 有表 ⇒ 实时改
        tab.x_trig   = mask_col                              #   分拣线
        tab.sort_dir = int(sort_dir)                         #   方向
        note = "（已实时生效）"
    else:                                                    # 没在跑
        note = "（下次【② 开始识别】生效）"
    return ("分拣线：屏幕第 %d 列 ⇔ 掩膜列 %d｜方向 %s｜画线 %s%s"
            % (screen_col, mask_col, "右→左" if sort_dir < 0 else "左→右",
               "开" if show_line else "关", note))


# ================================================================= 实时循环
_loop_thread = None                                          # 后台线程
_loop_stop = threading.Event()                               # 停止标志


def _loop_alive():
    """识别循环是否正在后台线程里跑。
       用途：跑着的时候**不许**把内核判成挂死、更不许重载位流（会当场把循环打断）"""
    return _loop_thread is not None and _loop_thread.is_alive()


def start_loop():
    """在后台线程里跑 osd_live（界面不阻塞）"""
    global _loop_thread
    if _loop_thread is not None and _loop_thread.is_alive():  # 已经在跑
        return "识别循环已在运行"
    # ★ ④ 开始识别时加载 osd.py，但**只取函数**，不让它自己进循环。
    #   为什么必须这样：osd.py 里 AUTO_RUN=True（`%run osd.py` 就会进循环，那是手动那条路）；
    #   这里如果把整份 %run 了，循环会占住主线程、后台线程永远起不来，⑤中止也就点不动。
    #   所以用 _exec_file_head 截在 `if AUTO_RUN:` 之前 —— 拿到的 osd_live 与 %run 完全等价。
    if _get("osd_live") is None:
        print(">>> 加载 osd.py（只取函数，不进循环）", flush=True)
        _exec_file_head("osd.py", "if AUTO_RUN:")
    live = _get("osd_live")
    if live is None:
        raise RuntimeError("没有 osd_live —— 确认 osd.py 已上传到同目录")
    if _get("set_disp") is None or _get("v1") is None:
        raise RuntimeError("相机链路没起来 —— 重跑 %run ui.py")
    if _get("TargetTable") is None:
        raise RuntimeError("没有 TargetTable —— 先跑 track.py")

    # 循环里 DISP 必须是 5（detect 按掩膜找框）
    try:
        _get("set_disp")(5, wait=0.2)
    except Exception:
        pass

    clf = _get("clf_pl") or _get("_clf")                     # 优先 PL 分类器
    # ★ 不再打任何补丁：2026-10-29 实测证明"主线程 + 完全照手动 + 无补丁"一样卡在
    #   CTRL=0x00000001，所以补丁既不必要也不见效，去掉以免干扰对照。
    sv = _get("sv") if ck_servo.value else None              # 舵机（勾了"启用分拣"才接）
    # ★ 勾了"启用分拣"却没有驱动 ⇒ 现场补建。
    #   为什么要这一段：servo.py 排在自检门禁之后，门禁一旦中止它就没被加载，sv 是 None，
    #   而循环里只会打一行 "分拣 --(未启用)"，看起来像"没触发"，其实是**根本没接舵机**。
    if ck_servo.value and sv is None:
        if _get("ServoKick") is None:                        # servo.py 还没加载
            try:
                print(">>> %run servo.py（要分拣但还没有舵机驱动）", flush=True)
                _run_magic("servo.py")                       # 它末尾会自动建 sv
            except Exception as _e:                          # 加载失败不该拦住识别
                print("   !! 加载 servo.py 失败：%r" % (_e,), flush=True)
        _SK = _get("ServoKick")                              # 再拿一次类
        if _SK is not None and _get("sv") is None:           # 有类没实例 ⇒ 自己 new 一个
            try:
                NS["sv"] = _SK()                             # 打开 0x43C40000 + 写参数 + 使能
                print("   分拣：已补建舵机驱动 sv", flush=True)
            except Exception as _e:                          # 位流不带 servo_pwm 之类
                print("   !! 舵机驱动建不起来（本次只识别不分拣）：%r" % (_e,), flush=True)
        sv = _get("sv")                                      # 重新取
        if sv is None:                                       # 还是没建成 ⇒ 明确说不分拣
            print("   !! 分拣没接上：sv 是 None ⇒ 本次循环不会触发任何舵机", flush=True)
    _loop_stop.clear()

    def body():
        try:
            live(None, clf=clf, servo=sv, stop=_loop_stop.is_set,
                 x_trig=_mask_col(), sort_dir=int(dd_dir.value))   # ★ 带上界面上的线位置/方向
        except Exception as e:                               # 循环里出错别静默
            print("!! 识别循环异常退出：%r" % (e,), flush=True)
            # ★ 兜底提示：如果后台线程这条路还是不行，用手动那条"已知可用"的路跑 ——
            #   新建一个 cell、只跑下面这一行（等价于你手动 %run osd.py，osd_live 在主线程）。
            #   它跑的时候界面会卡住，用 Jupyter 工具栏的 ■ 中断即可。
            print("   ── 若想完全照手动那条路跑（主线程，界面会卡住，用 ■ 中断）：", flush=True)
            print("      osd_live(None, clf=clf_pl, servo=sv)", flush=True)

    _loop_thread = threading.Thread(target=body, daemon=True)
    _loop_thread.start()
    return "识别循环已启动（分类器=%s，分拣=%s）" % (
        type(clf).__name__ if clf is not None else "None（只找框）",
        "开" if sv is not None else "关")


def stop_loop():
    """按停止标志让后台线程自己退出"""
    _loop_stop.set()
    return "已请求停止（循环会在下一次迭代退出）"


# ================================================================= 控件
head_style = {"description_width": "110px"}

# ★ 按钮流程（和手动跑的顺序一一对应）：
#   加载 ui.py 本身 = 只搭界面，什么都不跑
#   ① 加载位流        ⇒ 只跑 cam（位流 + 相机 + 切 buf0 显示）
#   ② 加载识别        ⇒ config → detect(整份) → cnn_pl_infer → selftest → servo
#   ③ 采集背景        ⇒ capture_bg()
#   ④ 开始识别（主线程）⇒ **整份 exec osd.py，和手动 %run osd.py 完全一致**（用 ■ 中断）
#   ⑤ 开始识别（后台）  ⇒ 截断 osd.py 只取函数，在后台线程跑 osd_live（可用⑥中止）
#   ⑥ 中止            ⇒ 置停止标志，后台循环在下一轮退出
btn_loader = W.Button(description="① 加载位流", button_style="success", icon="download",
                      layout=W.Layout(width="130px"))
btn_load = W.Button(description="② 加载识别", button_style="warning", icon="gears",
                    layout=W.Layout(width="130px"))
btn_bg = W.Button(description="③ 采集背景", button_style="info", icon="camera",
                  layout=W.Layout(width="130px"))
btn_start = W.Button(description="④ 开始识别", button_style="primary", icon="play",
                     layout=W.Layout(width="130px"))
btn_stop = W.Button(description="⑤ 中止", button_style="danger", icon="stop",
                    layout=W.Layout(width="100px"))

# ---- 曝光 ----
sl_exp = W.IntSlider(value=950, min=1, max=980, step=1, description="曝光行数",
                     style=head_style, continuous_update=False)
dd_gain = W.Dropdown(value=0x80, options=[("1x", 0x10), ("2x", 0x20), ("4x", 0x40),
                                          ("8x", 0x80), ("12x", 0xC0), ("15.5x", 0xF8)],
                     description="增益", style=head_style)
ck_exp_en = W.Checkbox(value=True, description="手动曝光")
ck_awb = W.Checkbox(value=False, description="锁定白平衡")
btn_exp = W.Button(description="应用曝光/AWB", button_style="info")

# ---- 掩膜 ----
sl_th = W.IntSlider(value=30, min=0, max=255, step=1, description="灰度阈值 DEF_TH",
                    style=head_style, continuous_update=False)
ck_med = W.Checkbox(value=True, description="中值滤波")
ck_morph = W.Checkbox(value=True, description="闭运算")
btn_mask = W.Button(description="应用掩膜", button_style="info")

# ---- 阴影 ----
ck_sh = W.Checkbox(value=True, description="阴影抑制")
sl_wy = W.IntSlider(value=1, min=0, max=15, step=1, description="亮度权重 wY",
                    style=head_style, continuous_update=False)
sl_wc = W.IntSlider(value=1, min=0, max=15, step=1, description="色度权重 wC",
                    style=head_style, continuous_update=False)
sl_tau = W.IntSlider(value=12, min=8, max=255, step=1, description="色度阈值 τc",
                     style=head_style, continuous_update=False)
sl_alpha = W.IntSlider(value=60, min=0, max=255, step=1, description="暗度上限 αmin",
                       style=head_style, continuous_update=False)
btn_sh = W.Button(description="应用阴影", button_style="info")

# ---- 找框 ----
sl_area = W.IntSlider(value=500, min=0, max=5000, step=10, description="过滤小白块 <",
                      style=head_style, continuous_update=False)
ck_merge = W.Checkbox(value=True, description="两框融合")
sl_gap = W.IntSlider(value=3, min=0, max=50, step=1, description="融合间距",
                     style=head_style, continuous_update=False)
sl_sx = W.IntSlider(value=14, min=0, max=40, step=1, description="框 左/右移 X",
                    style=head_style, continuous_update=False)
sl_sy = W.IntSlider(value=2, min=0, max=40, step=1, description="框 上/下移 Y",
                    style=head_style, continuous_update=False)
sl_pad = W.IntSlider(value=4, min=0, max=40, step=1, description="框外扩 PAD",
                     style=head_style, continuous_update=False)
btn_det = W.Button(description="应用找框参数", button_style="info")

# ---- 舵机（★ 2026-10-29：三路各自独立参数）----
#   每路一组：偏转角 / 偏转延时 / 偏转保持 / 返回斜坡 + 一个"应用 chN"按钮
#   ★ 默认值按"拍飞"场景给（物体过线→等它走到挡片→猛挥一下→立刻回正）：
#       延时 1000 ms（要按带速/挡片位置标定）、保持 200 ms（约等于 SG90 走完 60° 的时间
#       + 一点余量）、斜坡 200 ms（再快就变成瞬跳，电流冲击会打屏）
ck_servo = W.Checkbox(value=True, description="启用分拣")
# ★ 2026-10-30：每个滑块显式给 380px 宽（原来 4 个挤一行，每个只有 ~180px，拖动像素太窄）
_sl_layout = W.Layout(width="380px")                         # 滑块统一宽度
# ★ 2026-10-30：角度上限 90 → **120°**（放宽；正向到 120° 需 2500µs = PW_MAX 硬上限，
#   反向受 700µs 安全下限约束，约 96° 封顶）
sl_deg = [W.IntSlider(value=60, min=0, max=120, step=1,
                      description="ch%d 角度°" % (i + 1), style=head_style,
                      layout=_sl_layout,
                      continuous_update=False) for i in range(3)]      # 三路偏转角
# ★ 2026-10-30：范围收窄 + 步进变细（原来 0~5000/步进50，轻轻一拉就跳几千，没法细调）
#   · 延时：**上限 10000 ms（10 秒）**、步进 10 —— 单独给 560px 宽，一格约 18 ms
#     （RTL 里 t_dly 是 16 位毫秒 ⇒ 最大 65535 ms，10 秒完全够用）
#   · 保持：拍飞只用 50~500 ms   ⇒ 上限 1000、步进 10
#   · 斜坡：拍飞只用 50~500 ms   ⇒ 上限 1000、步进 10
_sl_layout_dly = W.Layout(width="560px")                     # 延时滑块单独更宽
sl_dly = [W.IntSlider(value=1000, min=0, max=10000, step=10,
                      description="ch%d 延时ms" % (i + 1), style=head_style,
                      layout=_sl_layout_dly,
                      continuous_update=False) for i in range(3)]     # 三路偏转延时
sl_act = [W.IntSlider(value=200, min=0, max=1000, step=10,
                      description="ch%d 保持ms" % (i + 1), style=head_style,
                      layout=_sl_layout,
                      continuous_update=False) for i in range(3)]     # 三路偏转保持
sl_ret = [W.IntSlider(value=200, min=0, max=1000, step=10,
                      description="ch%d 斜坡ms" % (i + 1), style=head_style,
                      layout=_sl_layout,
                      continuous_update=False) for i in range(3)]     # 三路返回斜坡
# ★ 2026-10-30 新增：每路一个"反向"开关
#   不勾 = 正向（脉宽 = 中位 + 角度×8.333 µs，脉宽变**大**）
#   勾上 = 反向（脉宽 = 中位 − 角度×8.333 µs，脉宽变**小**）—— 硬件本来就支持两个方向
ck_rev = [W.Checkbox(value=False, description="反向", indent=False,
                     layout=W.Layout(width="70px")) for i in range(3)]
# ★★ 2026-10-30 新增：每路一个「中位 µs」精确微调（1000~2000，步进 1µs，可直接输入）
#   为什么需要它：装上挡板后舵机有转动惯量，某些"停住的位置"上它会在死区边界上来回
#   过冲修正 ⇒ 一直抖。把中位挪开几 µs（甚至几十 µs）常常就能落到一个安静的位置。
#   这就是"回正后一直抖"唯一的软件解法 —— 抖动本身是舵机闭环动力学，改不了，只能躲。
ti_idle = [W.BoundedIntText(value=1500, min=1000, max=2000, step=1,
                            description="ch%d 中位µs" % (i + 1), style=head_style,
                            layout=W.Layout(width="170px")) for i in range(3)]
btn_servo = [W.Button(description="应用 ch%d" % (i + 1), button_style="info",
                      layout=W.Layout(width="100px")) for i in range(3)]   # 每路一个应用按钮
btn_servo_all = W.Button(description="应用全部三路", button_style="warning",
                         layout=W.Layout(width="130px"))      # 按各路**自己的**滑块值分别写
btn_kick = [W.Button(description="测试 舵机%d" % (i + 1), layout=W.Layout(width="108px"))
            for i in range(3)]
btn_estop = W.Button(description="急停/失力", button_style="danger", layout=W.Layout(width="108px"))
btn_resume = W.Button(description="恢复 PWM", button_style="warning", layout=W.Layout(width="100px"))

# ---- 分拣线 ----
ck_line = W.Checkbox(value=True, description="屏上画分拣线")
sl_line = W.IntSlider(value=640, min=160, max=1130, step=1, description="分拣线 屏幕列",
                      style=head_style, continuous_update=False)
dd_dir = W.Dropdown(value=-1, options=[("右 → 左", -1), ("左 → 右", 1)],
                    description="运动方向", style=head_style)
btn_line = W.Button(description="应用分拣线", button_style="info")

# ---- DISP ----
btn_disp = [W.Button(description="%d %s" % (k, v), layout=W.Layout(width="128px"))
            for k, v in DISP_NAMES.items()]

# ---- 状态栏 ----
_lbl_status = W.HTML(value="<b>状态：</b>界面就绪（未触碰 PL / 相机）｜ 请点【① 加载位流】")
_out = W.Output()                                            # 大块输出（错误/预览）


# ================================================================= 自动加载
def _run_magic(target):
    """★ 用**真正的 `%run`** 执行 —— 和你在 cell 里手打 `%run xxx.py` 完全同一条代码路径

    为什么不用 `exec(compile(...))`：虽然两者在语义上等价，但你要求"按按钮就等于 run 对应
    文件"，那最不含歧义的做法就是直接调 IPython 的 run magic —— 连"文件是用什么方式执行的"
    这个变量都不再存在。
    ★ 注意：`%run` 在 IPython 里默认就把文件跑进 notebook 的同一个 user_ns，所以
      cam_full.py 建的 `ol` / `wr16` / `GLASS` / `a0` 后面的文件都能直接用。"""
    from IPython import get_ipython as _gi                # ★ 显式导入，不能只写 get_ipython()
    ip = _gi()                                            # 拿 IPython 交互壳
    if ip is None:                                        # 不在 notebook 里
        raise RuntimeError("没有 IPython 环境，无法 %run")
    ip.run_line_magic("run", target)                      # ← 等价于手打 `%run <target>`


def _load_cam(_=None):
    """★ ① 加载位流：**只跑 cam** —— 位流 + 相机。

    加载 ui.py 本身**不会**调这个函数，只有点【① 加载位流】才会跑。
    两条分支：
      ① 命名空间里 wr16 / GLASS / a0 都在 ⇒ 相机链路已经建好，**全跳过**，直接沿用；
      ② 否则 ⇒ 老老实实跑一遍 `%run cam_full.py`（**包含重烧位流**）。
         ★ 为什么不能在"fpga_manager 已有位流"时跳过重烧：我们没法确认那是不是这一版，
           而 SCCB 走的 EMIO GPIO 路由就写在位流里；位流不对 ⇒ 读传感器 ID 得 0 ⇒ cam_full 停手。
           （2026-10-29 实测踩过，见 `_cam_full_no_use()` 的注释。）
    ★ 识别链**不在这里**，交给【② 加载识别】。"""
    with _out:
        clear_output()
        try:
            if _get("wr16") is not None and _get("GLASS") is not None and _get("a0") is not None:
                print(">>> 相机链路已在（wr16/GLASS/a0 都在）⇒ 不重复烧，直接沿用", flush=True)
            else:
                _set_status("正在跑 cam_full.py（约 15~20 秒，屏幕会黑一下）…")
                print(">>> %run cam_full.py", flush=True)
                _run_magic("cam_full.py")                     # ★ 就是 %run cam_full.py，仅此一句
                # ★ 立刻验证 %run 的变量真的落在同一个命名空间里。
                #   如果 IPython 的 %run 用的是独立命名空间，这里就会立刻报出来，
                #   而不是等到【② 加载识别】才莫名其妙地"没有 GLASS"。
                if _get("wr16") is None or _get("GLASS") is None or _get("a0") is None:
                    raise RuntimeError(
                        "%run cam_full.py 跑完了，但 wr16/GLASS/a0 不在同一个命名空间里 "
                        "⇒ 这个 IPython 的 %run 用的是独立命名空间")
                print("   ✓ cam_full 的变量已就位（wr16 / GLASS / a0 都在）", flush=True)
            _set_status("<b>状态：</b>相机就绪 ✓ 屏幕应已有实时画面 ｜ 下一步【② 加载识别】")
        except BaseException as e:                        # ★ 必须接 BaseException
            if isinstance(e, KeyboardInterrupt):          # 用户按 ■ 中断 ⇒ 正常，往上抛
                raise
            _set_status("<b style='color:red'>加载位流失败：</b>%r" % (e,))
            print("!! 加载位流失败：%r" % (e,), flush=True)   # ★ 不 raise：界面必须还能用
            # ★ cam_full.py 里有 `raise SystemExit`（传感器 ID 读不到时会主动停手），
            #   SystemExit **不是** Exception 的子类 ⇒ 这里必须用 BaseException 才接得住。
            if isinstance(e, SystemExit):
                print("   ⇒ 这条 SystemExit 来自 cam_full.py 自己的判据（常见是传感器 "
                      "ID≠0x5640，即 SCCB 没通）。先把上面几行 cam_full 的日志看一下。",
                      flush=True)
            import traceback                                 # 细节打出来便于定位
            traceback.print_exc()


def _load_rec(_=None):
    """★ ② 加载识别：完完整整跑你手动那几行，一样不少、顺序不动

        %run config.py            # 判据：打印 总使能=1 背景差分=1 → 实际生效=1
        %run detect.py            # 判据：连续 5 次目标数一致
        %run cnn_pl_infer.py      # 判据：PL 加速器句柄：ol.cnn_top_0
        clf_pl.selftest()         # 判据：=== PASS ===
        %run servo.py             # 判据：舵机就绪（分拣要用）

    ★ `detect.py` 这里**整份跑**，不再用 `_exec_file_head` 截断：
      它的判据"连续 5 次目标数一致"就写在文件**尾部那段演示**里，截掉就等于把判据丢了。
    ★ 本函数**绝不**自动重载位流 —— 烧位流只归【① 加载位流】，不许在此处偷偷做。
    """
    with _out:
        clear_output()
        try:
            if _get("GLASS") is None or _get("a0") is None:      # 相机没起来就没法往后走
                raise RuntimeError("相机链路没起来 —— 先点【① 加载位流】")

            # ---- ① %run config.py ----
            print(">>> %run config.py", flush=True)
            _run_magic("config.py")                              # ★ 就是 %run config.py
            print("   判据：上面应打印 总使能=1 背景差分=1 → 实际生效=1", flush=True)

            # ---- ② %run detect.py（整份，含尾部连续检测 5 次）----
            print(">>> %run detect.py（整份跑：尾部会连续检测 5 次并出图）", flush=True)
            _run_magic("detect.py")                              # ★ 就是 %run detect.py
            print("   判据：上面 5 次的目标数应一致", flush=True)

            # ---- ③ %run cnn_pl_infer.py ----
            print(">>> %run cnn_pl_infer.py", flush=True)
            _run_magic("cnn_pl_infer.py")                        # ★ 就是 %run cnn_pl_infer.py
            _clf = _get("clf_pl")                                # 拿到分类器
            if _clf is None:                                     # 没建成
                raise RuntimeError("clf_pl 是 None —— 看上面 cnn_pl_infer.py 打印的原因")
            print("   判据：上面应打印 PL 加速器句柄：ol.cnn_top_0", flush=True)

            # ---- ④ clf_pl.selftest() ----
            print(">>> clf_pl.selftest()", flush=True)
            _ok = _clf.selftest()                                # 内部自己打印 期望/实际/结论
            print("   判据：上面应是 === PASS ===（本次结果 %s）"
                  % ("PASS" if _ok else "FAIL"), flush=True)

            # ---- ⑤ %run servo.py ----
            print(">>> %run servo.py", flush=True)
            _run_magic("servo.py")                               # ★ 就是 %run servo.py

            # ---- 收尾：把屏幕切回"干净彩色原图"（纯显示动作，不碰硬件逻辑）----
            # config.py 会把 DISP 设成 5（最终掩膜）⇒ 屏幕变成一片掩膜（空带子全黑）。
            # ④ 开始识别时 osd_live 自己会把显示切到 buf0 并置 DISP=5，这里只是不让你
            # 在中间几步看到一个黑屏而已。
            try:
                ds = _get("display_source")                  # osd.py 里的切源函数
                if ds is not None:                           # 已加载 osd.py
                    ds(True)                                 # 显示读 buf0 干净彩色
                    print("   显示：已切到 buf0（干净彩色）", flush=True)
                else:                                        # 没加载 osd.py
                    _get("set_disp")(0, wait=0.2)            # DISP=0 ⇒ buf1 出原图
                    print("   显示：DISP=0（buf1 出原图）", flush=True)
            except Exception as _e:                          # 切显示失败不该让加载失败
                print("   显示切换失败（不影响识别）：%r" % (_e,), flush=True)

            clf = _get("clf_pl")                                 # 分类器
            sv = _get("sv")                                      # 舵机
            _set_status(
                "<b>状态：</b>识别链就绪 ✓ 分类器=<b>%s</b> 分拣=%s ｜ 下一步【③ 采集背景】"
                % (type(clf).__name__ if clf is not None else "<span style='color:red'>None</span>",
                   "开" if sv is not None else "关"))
            if not _ok:                                          # 自检没过要明确提示
                print("!! 注意：selftest 没 PASS，先别点【④ 开始识别】", flush=True)

            # ---- ★ 结果汇总（**故意放在最后**：你贴日志时只贴尾部，这样一定能看到）----
            print("", flush=True)
            print("=" * 64, flush=True)
            print(" 加载识别结果汇总 —— 请把下面整段发我", flush=True)
            print("   句柄类型 : %s" % type(_clf.ip).__name__, flush=True)
            print("   selftest : %s" % ("PASS" if _ok else "FAIL"), flush=True)
            try:
                _clf.status()                                    # 打 CTRL + blob/in/out 三个基地址
            except Exception as _e:                              # 读不到也别炸
                print("   status() 读失败：%r" % (_e,), flush=True)
            print("=" * 64, flush=True)
        except BaseException as e:                        # ★ 必须接 BaseException
            if isinstance(e, KeyboardInterrupt):          # 用户按 ■ 中断 ⇒ 正常，往上抛
                raise
            _set_status("<b style='color:red'>加载识别失败：</b>%r" % (e,))
            print("!! 加载识别失败：%r" % (e,), flush=True)   # ★ 不 raise：界面必须还能用
            if isinstance(e, SystemExit):                 # 被执行的脚本自己停手（如 detect/cam）
                print("   ⇒ 这条 SystemExit 来自被执行的脚本自己的判据，看上面几行日志。",
                      flush=True)
            import traceback                                 # 细节打出来便于定位
            traceback.print_exc()


# ================================================================= 事件
def _bg(_=None):
    with _out:
        try:
            _set_status(do_capture_bg() + " ｜ 可以放物体了")
        except Exception as e:
            _set_status("<b style='color:red'>采集背景失败：</b>%r" % (e,))


def _start(_=None):
    with _out:
        try:
            _set_status(start_loop())
        except Exception as e:
            _set_status("<b style='color:red'>启动识别失败：</b>%r" % (e,))


def _stop(_=None):
    _set_status(stop_loop())


def _run_manual(_=None):
    """★ ④ 开始识别（**与手动完全一致**）：整份 exec osd.py，循环跑在主线程

    这一条就是照你手动那一步改的，一一对应：
        你手动：  %run osd.py
        这里：    _exec_file("osd.py")     ← 整份执行，不截断
    区别清零：
      · **不截断** `if AUTO_RUN:` 段 —— 让 osd.py 自己按它末尾那句去进循环；
      · **在主线程**跑（和你手动同一个线程）；
      · **不传** stop / x_trig / sort_dir —— 和 osd.py 末尾那句 `osd_live(LIVE_SECONDS, clf=_clf, servo=_sv)` 一模一样的参数；
      · **不打任何补丁**（不碰 write_ptrs）。
    ★ 如果板上那份 osd.py 的 AUTO_RUN 是 False（不会自己进循环），这里补一句
      `osd_live(None, clf=clf_pl, servo=sv)` —— 参数与 osd.py 末尾那句完全相同。
    ★ 代价：循环占着主线程，界面会卡住；用 Jupyter 工具栏的 ■ 中断。
      想"点中止按钮停"请用【⑤ 开始识别（后台·可中止）】。"""
    with _out:
        try:
            if _get("clf_pl") is None:                        # 还没加载识别链
                raise RuntimeError("还没有 clf_pl —— 先点【② 加载识别】")
            print(">>> %run osd.py（整份跑，和你手动完全一样；界面会卡住，用 ■ 中断）",
                  flush=True)
            _run_magic("osd.py")                             # ★ 就是 %run osd.py
            if not _get("AUTO_RUN", False):                  # 板上是 False ⇒ 它不会自己进循环
                print("   osd.py 的 AUTO_RUN=False（不会自己进循环）⇒ 按它末尾那 12 行照抄一遍",
                      flush=True)
                # ★ 下面逐行照抄 osd.py 末尾 `if AUTO_RUN:` 块里的逻辑，一个字都不改：
                _clf = _get("clf_pl")                        # ① 分类器（osd.py 里是 globals().get('clf_pl')）
                _sv = _get("sv")                             # ② 舵机：有现成的就用
                if _sv is None:                              #    没有就自己建（和 osd.py 一样）
                    try:
                        from servo import ServoKick as _ServoKick   # 同目录的 servo.py
                        _sv = _ServoKick()                           # 打开 0x43C40000 + 写参数 + 使能
                        print("分拣：已建舵机驱动（servo.ServoKick）", flush=True)
                    except Exception as _e:                          # 建不起来
                        _sv = None                                   # 分拣关掉
                        print("!! 舵机不可用，本次只识别不分拣：%s" % _e, flush=True)
                print("开始实时循环：屏幕 = buf0 干净彩色 + 框/英文名/汇总；按 ■ 中断", flush=True)
                _get("osd_live")(None, clf=_clf, servo=_sv)  # ★ 参数与 osd.py 末尾那句完全一致
            print(">>> osd 循环已结束", flush=True)
        except BaseException as e:                           # 接 BaseException：osd.py 也可能 SystemExit
            if isinstance(e, KeyboardInterrupt):             # 用 ■ 中断
                print(">>> 已用 ■ 中断 osd 循环", flush=True)
                return
            print("!! 开始识别失败：%r" % (e,), flush=True)
            import traceback
            traceback.print_exc()


def _apply_exp(_=None):
    with _out:
        try:
            a = apply_exposure(sl_exp.value, dd_gain.value, ck_exp_en.value)
            b = apply_awb(ck_awb.value)
            _set_status(a + " ｜ " + b)
        except Exception as e:
            _set_status("<b style='color:red'>失败：</b>%r" % (e,))


def _apply_mask(_=None):
    with _out:
        try:
            _set_status(apply_mask(sl_th.value, ck_med.value, ck_morph.value))
        except Exception as e:
            _set_status("<b style='color:red'>失败：</b>%r" % (e,))


def _apply_sh(_=None):
    with _out:
        try:
            _set_status(apply_shadow(ck_sh.value, sl_wy.value, sl_wc.value,
                                     sl_tau.value, sl_alpha.value))
        except Exception as e:
            _set_status("<b style='color:red'>失败：</b>%r" % (e,))


def _apply_det(_=None):
    with _out:
        try:
            _set_status(apply_detect(sl_area.value, ck_merge.value, sl_gap.value,
                                     sl_sx.value, sl_sy.value, sl_pad.value))
        except Exception as e:
            _set_status("<b style='color:red'>失败：</b>%r" % (e,))


def _mk_servo_cb(ch):
    """生成"应用 chN"按钮的回调（ch = 0/1/2）"""
    def cb(_=None):
        with _out:
            try:
                _set_status(apply_servo_ch(ch,
                                           sl_deg[ch].value, sl_dly[ch].value,
                                           sl_act[ch].value, sl_ret[ch].value,
                                           ck_rev[ch].value,          # ★ 这一路的"反向"
                                           ti_idle[ch].value))        # ★ 这一路的中位 µs
            except Exception as e:
                _set_status("<b style='color:red'>舵机 ch%d 参数失败：</b>%r" % (ch + 1, e))
    return cb


def _apply_servo(_=None):
    """三路各自写一次（每路用自己的滑块值）"""
    with _out:
        try:
            msgs = []
            for ch in range(3):                               # 逐路写
                msgs.append(apply_servo_ch(ch,
                                           sl_deg[ch].value, sl_dly[ch].value,
                                           sl_act[ch].value, sl_ret[ch].value,
                                           ck_rev[ch].value,        # ★ 每路自己的"反向"
                                           ti_idle[ch].value))      # ★ 每路自己的中位 µs
            for m in msgs:                                    # 三行都打出来，便于核对
                print("   " + m, flush=True)
            _set_status("<br>".join(msgs))                    # 状态栏三行
        except Exception as e:
            _set_status("<b style='color:red'>舵机参数失败：</b>%r" % (e,))


def _mk_kick_cb(ch):
    def cb(_=None):
        with _out:
            try:
                _set_status(servo_kick(ch))
            except Exception as e:
                _set_status("<b style='color:red'>测试舵机失败：</b>%r" % (e,))
    return cb


def _estop(_=None, on=True):
    with _out:
        try:
            _set_status(servo_estop(on))
        except Exception as e:
            _set_status("<b style='color:red'>失败：</b>%r" % (e,))


def _apply_line(_=None):
    with _out:
        try:
            _set_status(apply_sort_line(sl_line.value, dd_dir.value, ck_line.value))
        except Exception as e:
            _set_status("<b style='color:red'>分拣线设置失败：</b>%r" % (e,))


def _mk_disp_cb(mode):
    def cb(_=None):
        with _out:
            try:
                show_disp(mode)
                extra = "" if mode == 5 else "  ★ 识别循环运行时 DISP 必须是 5"
                _set_status("DISP=%d %s（只影响 buf1 / notebook 预览，不影响 HDMI）%s"
                            % (mode, DISP_NAMES[mode], extra))
            except Exception as e:
                _set_status("<b style='color:red'>预览失败：</b>%r" % (e,))
    return cb


btn_loader.on_click(_load_cam)
btn_load.on_click(_load_rec)
btn_bg.on_click(_bg)
btn_start.on_click(_start)
btn_stop.on_click(_stop)
btn_exp.on_click(_apply_exp)
btn_mask.on_click(_apply_mask)
btn_sh.on_click(_apply_sh)
btn_det.on_click(_apply_det)
for _i in range(3):                                          # 三路各接一个"应用"按钮
    btn_servo[_i].on_click(_mk_servo_cb(_i))
btn_servo_all.on_click(_apply_servo)                         # 三路一起应用
for _i, _b in enumerate(btn_kick):
    _b.on_click(_mk_kick_cb(_i))
btn_estop.on_click(lambda _=None: _estop(None, True))
btn_resume.on_click(lambda _=None: _estop(None, False))
btn_line.on_click(_apply_line)
ck_line.observe(lambda chg: NS.__setitem__("SORT_LINE_SHOW", bool(chg["new"])), names="value")
for _b, _m in zip(btn_disp, list(DISP_NAMES.keys())):
    _b.on_click(_mk_disp_cb(_m))


# ================================================================= 面板
def _box(title, *kids):
    return W.VBox([W.HTML("<b>%s</b>" % title), W.HBox(list(kids))])


def _servo_group(ch):
    """★ 一路舵机占**两行**（每行两个滑块）—— 让每个滑块有足够像素宽度去拖
       第 0 行：标题 + 反向开关 + 应用按钮
       第 1 行：角度° + 延时ms
       第 2 行：保持ms + 斜坡ms"""
    head = W.HBox([W.HTML("<b style='margin-right:10px'>舵机 %d</b>" % (ch + 1)),
                   ck_rev[ch], ti_idle[ch], btn_servo[ch]])          # 标题行 + 中位微调
    return W.VBox([head,
                   W.HBox([sl_deg[ch], sl_dly[ch]]),                 # 第 1 行：角度 + 延时
                   W.HBox([sl_act[ch], sl_ret[ch]])],                # 第 2 行：保持 + 斜坡
                  layout=W.Layout(border="1px solid #d8d8d8", padding="4px",
                                  margin="0 0 4px 0"))               # 加个边框便于分组


import matplotlib.pyplot as _plt                            # 预览用（放最后，避免上面失败时白装）

_ui = W.VBox([
    W.HTML("<h3 style='margin:4px 0'>实时垃圾分类识别与计数 —— 控制台</h3>"),
    _lbl_status,
    W.HBox([btn_loader, btn_load, btn_bg, btn_start, btn_stop]),
    _box("曝光 / 白平衡", W.VBox([sl_exp, dd_gain, W.HBox([ck_exp_en, ck_awb, btn_exp])])),
    _box("掩膜（PL）", W.VBox([sl_th, W.HBox([ck_med, ck_morph, btn_mask])])),
    _box("阴影抑制（PL）", W.VBox([W.HBox([ck_sh, sl_wy, sl_wc]),
                                 W.HBox([sl_tau, sl_alpha, btn_sh])])),
    _box("找框（PS）", W.VBox([sl_area, W.HBox([ck_merge, sl_gap]),
                              W.HBox([sl_sx, sl_sy, sl_pad, btn_det])])),
    _box("舵机分拣（PL · 三路独立参数）",
         W.VBox([ck_servo,
                 _servo_group(0),                                 # 舵机1：占两行
                 _servo_group(1),                                 # 舵机2：占两行
                 _servo_group(2),                                 # 舵机3：占两行
                 W.HBox([btn_servo_all] + btn_kick + [btn_estop, btn_resume])])),
    _box("分拣线（右→左）", W.VBox([W.HBox([ck_line, dd_dir]), sl_line, W.HBox([btn_line])])),
    _box("DISP 预览（只影响 buf1 / notebook；不影响 HDMI）",
         W.VBox([W.HBox(btn_disp[:6]), W.HBox(btn_disp[6:])])),
    _out,
])

display(_ui)
print("=" * 70, flush=True)
print("界面已生成。★ 本次加载**没有**烧位流、没有碰相机、没有加载任何识别模块。", flush=True)
print("一切硬件动作都只能由你按按钮触发：", flush=True)
print("  ① 加载位流（只跑 cam）→ ② 加载识别 → ③ 采集背景 → ④ 开始识别 → ⑤ 中止", flush=True)
print("=" * 70, flush=True)
