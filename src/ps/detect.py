###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：detect.py
# 角色   ：按钮②第 2 步：读掩膜 → 二次阈值 → 连通域 → 合并 → 裁彩色 ROI
# 依赖   ：通过 IPython 命名空间取句柄
# 启动   ：按钮②，或 %run detect.py
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
detect.py —— PS 端：连通域参数调节 + 找框 + 裁图 + letterbox 预览（用户 2026-10-13 提供）

★ 2026-10-13 性能优化（实测：整条链 265 ms/帧 → 25 ms/帧，29 Hz、一帧不漏）：
  ① CLOSE_K 默认改成 0 —— PL 的 3×3 已经做过，PS 再闭一次【目标数完全一样】却要 139 ms
  ② 不再二值化 —— PL 出来就是 0/255，OpenCV 的连通域/形态学本来就把非零当前景，省 15 ms
  ③ 掩膜按 行/列各取 1/2 读（SY=SX=2，数据量 1/4）—— 省约 36 ms；框自动乘回真实坐标
  ④ ★ 裁图【完全不受影响】：仍从彩色原图 v0 全分辨率裁，步长 1，一个像素都不跳
  备份：detect.py.bak_before_fast

作用：一个 cell 把"PL 掩膜 → 目标框 → 彩色 ROI → 64×64"这条 PS 侧链路跑通并画出来看。
      上半是【可调参数】（改完直接重跑本 cell，不用重启内核），下半是执行与出图。

Jupyter 用法（★ 必须先跑 cam_full.py，本文件用到它建的 set_disp / v0 / v1 / buf0 / buf1 / OFF_PX / IMG_W）：
    %run cam_full.py      ← 先启动
    %run config.py        ← 再配置（曝光 + 使能 + 掩膜参数；★ BG_EN 必须是 1）
    %run detect.py        ← 本文件：找目标 + 裁图 + 显示

★ 三个读图要点：
  1) 图1 的红框画在【掩膜坐标】（故意不补偿）—— 它是"校准尺"，用来读 SHIFT_X/SHIFT_Y：
     红框比物体偏右多少列 ⇒ SHIFT_X 就填多少。当前 SHIFT_X=14 / SHIFT_Y=2（已实测），
     所以红框会正常地偏右 14 列、偏下 2 行 —— 这是对的，不是 bug。
  2) 下排的裁剪【已经补偿】：原图列 = 掩膜列 − SHIFT_X，行 = 掩膜行 − SHIFT_Y，再外扩 PAD。
  3) "连续 N 次检测到的目标数"是体检：5 次都是同一个数 ⇒ 稳；出现 1,2,1 ⇒ 目标时断时连，
     先加大 CLOSE_K（不够再上 MERGE_GAP）。

★ 基线纪律：改动前是用户手上正在跑的版本（备份 detect.py.bak_before_fast）。本次只做性能优化 ——
  去掉的两步是 PL 已经做过的重复劳动，算法行为不变；**裁图那一段一个字没动**。
"""

# ★ 先 Ctrl+A 清空本 cell，再整段粘贴（句号别一起粘进去）
import numpy as np, time, cv2
import matplotlib.pyplot as plt


# ★★ 2026-10-28：跨 %run 的命名空间桥。
#   IPython 的 `%run` **默认在一个独立命名空间里执行文件**（只有 `%run -i` 才共享 notebook
#   的交互命名空间）⇒ 本文件里看不到 cam_full.py 建的 set_disp / v0 / v1 / buf0 / buf1 /
#   OFF_PX / IMG_W，表现就是 "NameError: name 'set_disp' is not defined"。
#   **粘进 cell 里手跑反而正常**（那才是交互命名空间）。
#   这里把交互命名空间的变量搬进本文件 globals()，下面所有引用一行都不用改。
#   ★ 放在参数定义之前：本文件自己的 def/赋值在后面，会正常覆盖搬进来的同名项。
def _ipy_ns():
    try:
        ip = get_ipython()                               # notebook 里有，纯 python 里没有
        return ip.user_ns if ip is not None else {}
    except Exception:
        return {}

for _k, _v in list(_ipy_ns().items()):                   # 交互命名空间里的每个名字
    if _k not in globals():                              # 本文件还没有的才搬
        globals()[_k] = _v

# ============ 可调参数：改完直接重跑本 cell，不用重启内核 ============
MIN_AREA  = 500      # 小于这么多像素的块直接扔掉（去碎屑）
CLOSE_K   = 0       # ★0 = 不做 PS 闭运算（PL 的 3×3 已经做过；实测 CLOSE_K=5 时目标数完全一样，
                    #   却要多花 139 ms）—— 只有需要补更宽的缝时才设 3/5/7…
                    #   ★ 注意：降采样后等效核会放大 SY/SX 倍（SY=SX=2 时 5×5 相当于原图 10×10）
SY        = 2       # ★行步长：读掩膜时隔 1 行（1=不隔行 / 2=读 1/2 的行）
SX        = 2       # ★列步长：读掩膜时隔 1 列（1=不隔列 / 2=读 1/2 的列）⇒ 数据量 1/(SY*SX)
MERGE_GAP = 3       # ★两个框的间距 ≤ 这个值就并成一个（0=不合并）—— 治"两块离得有点开、其实是同一个物体"
N_SAMPLE  = 5       # 连续检测几次（看目标数稳不稳；1=只测一次）
SIZE      = 64      # CNN 输入边长
SHIFT_X   = 14      # 掩膜相对原图右移的列数 —— 看"图1"里红框比物体偏右多少列就填多少
                    # ★ 2026-10-22 由 10 改成 14：加了阴影抑制那一级（dd_shadow 5 拍，
                    #   替掉原来的 dd_diff 1 拍 ⇒ 整链 10 拍变 14 拍），列位移 = 延迟拍数
SHIFT_Y   = 2       # 掩膜相对原图下移的行数 —— 同理
PAD       = 4       # 框往外扩几像素（防切边）
CH_SWAP   = True    # 缓冲里是 BGR ⇒ 显示前换 RGB。若显示出来红蓝反了，改成 False

def letterbox(roi, size=SIZE):
    """保持宽高比缩放到 size×size，居中补黑边"""
    h, w = roi.shape[:2]                                    # 原图高、宽
    s = size / max(h, w)                                    # 缩放比：让长边刚好占满
    nh, nw = max(1, int(round(h*s))), max(1, int(round(w*s)))# 缩放后的高、宽（至少 1 像素）
    interp = cv2.INTER_AREA if s < 1 else cv2.INTER_LINEAR  # 缩小用 AREA、放大用 LINEAR
    small = cv2.resize(roi, (nw, nh), interpolation=interp) # 真正缩放
    out = np.zeros((size, size, 3), dtype=np.uint8)         # 黑底
    y0, x0 = (size - nh)//2, (size - nw)//2                 # 居中偏移
    out[y0:y0+nh, x0:x0+nw] = small                         # 贴到中间
    return out                                              # 返回 size×size×3

def gap_of(a, b):
    """两个框 (x,y,w,h) 的间距：某一轴重叠就算 0，两轴取大的那个"""
    dx = max(0, max(a[0], b[0]) - min(a[0]+a[2], b[0]+b[2]))# 水平空隙
    dy = max(0, max(a[1], b[1]) - min(a[1]+a[3], b[1]+b[3]))# 垂直空隙
    return max(dx, dy)                                      # 取大的（对角线距离口径）

def merge_boxes(boxes, gap):
    """把间距 ≤ gap 的框反复合并，直到一个都合不动为止"""
    cur = [list(b) for b in boxes]                          # 转成可变列表
    while True:                                             # 反复扫
        out = []                                            # 本轮结果
        for b in cur:                                       # 逐个拿
            hit = None                                      # 能合进去的位置
            for k, o in enumerate(out):                     # 在结果里找
                if gap_of(b, o) <= gap:                     # 够近
                    hit = k                                 # 记下
                    break                                   # 一个就够
            if hit is None:                                 # 没找到
                out.append(list(b))                         # 新开一个
            else:                                           # 找到了
                o = out[hit]                                # 取出那个框
                x0 = min(o[0], b[0]); y0 = min(o[1], b[1])  # 新的左上角
                x1 = max(o[0]+o[2], b[0]+b[2]); y1 = max(o[1]+o[3], b[1]+b[3])  # 新的右下角
                out[hit] = [x0, y0, x1-x0, y1-y0]           # 写回并集
        if len(out) == len(cur):                            # 长度没变 = 这一轮没合并
            return out                                      # 收敛，返回
        cur = out                                           # 否则拿新结果再扫一轮

def detect(bin_mask, sx=SX, sy=SY):
    """掩膜 → 框列表（坐标已乘回真实尺寸）。顺序：闭运算(可选) → 连通域 → 去碎屑 → 按间距合并
       ★ PL 出来的掩膜已经是 0/255 二值图 ⇒ 不再二值化（OpenCV 的连通域/形态学把非零当前景）
       ★ 传进来的掩膜可以是隔行隔列读出来的，靠 sx/sy 把框乘回真实坐标"""
    m = np.array(bin_mask, copy=True)                       # ★ 强制拷一份：下面要往里写 0，绝不能动调用者的数组
    # ★★ 2026-10-29 新增：把"绕回垃圾带"清零，治"物体贴右边缘时框从左边边缘溢出来"。
    #   原因：PL 检测核是流水线，掩膜相对彩色原图横向延迟 SHIFT_X 拍、纵向延迟 SHIFT_Y 拍，
    #   而这串延迟寄存器是**连续喂像素**的、它不知道行边界/帧边界在哪。于是：
    #     · 每行最左 SHIFT_X 列 = **上一行最后 SHIFT_X 个像素**（绕回）
    #     · 最上 SHIFT_Y 行       = **上一帧的最后几行**（同理）
    #   物体贴右边缘时，它最后 SHIFT_X 个像素绕回下一行行首 ⇒ 8 连通域在左边边缘凭空多出一块，
    #   面积（14 列 × 物体高）能过 MIN_AREA ⇒ 多出一个"从左边伸出来"的假框。
    #   真实画面内容从第 SHIFT_X 列 / 第 SHIFT_Y 行才开始 ⇒ 清掉这两条垃圾带**不损失任何真实像素**，
    #   也**不改任何参数**（SHIFT_X / SHIFT_Y / PAD / OFF_PX 全部原样，裁 ROI 的公式一个字不动）。
    _nc = -(-int(SHIFT_X) // int(sx))                       # 行首要清几列（向上取整，避免 SX 不整除时漏）
    if _nc > 0:                                             # 有垃圾带才清
        m[:, :_nc] = 0                                      # 行首垃圾列清零
    _nr = -(-int(SHIFT_Y) // int(sy))                       # 顶部要清几行（同理向上取整）
    if _nr > 0:                                             # 有垃圾带才清
        m[:_nr, :] = 0                                      # 顶部垃圾行清零
    if CLOSE_K >= 3:                                        # 默认 0 ⇒ 这一段不执行
        k = CLOSE_K if CLOSE_K % 2 == 1 else CLOSE_K + 1    # 核必须是奇数
        ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))  # 椭圆核（比方核更不伤尖角）
        m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, ker)       # 闭 = 先膨胀后腐蚀 ⇒ 补缝、大小基本不变
    n, lab, st, cen = cv2.connectedComponentsWithStats(m, connectivity=8)  # 8 连通域
    boxes = []                                              # 结果
    for i in range(1, n):                                   # 0 是背景，跳过
        if st[i, 4] < MIN_AREA / (sx * sy):                 # ★ 面积阈值按降采样比例缩小
            continue                                        # 当碎屑扔掉
        boxes.append([int(st[i,0])*sx, int(st[i,1])*sy,     # ★ 框乘回真实坐标
                      int(st[i,2])*sx, int(st[i,3])*sy])    #   宽高同样乘回去
    if MERGE_GAP > 0 and len(boxes) > 1:                    # 需要合并
        boxes = merge_boxes(boxes, MERGE_GAP)               # 按间距合并
    return boxes                                            # 返回

def to_show(img):
    """缓冲里的图 → matplotlib 能正确显示的顺序"""
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB) if CH_SWAP else img  # BGR→RGB 或原样

# ---- ① 连续检测 N_SAMPLE 次，看目标数稳不稳 ----
set_disp(5); time.sleep(0.3)                                # 切到最终掩膜，等一帧生效
counts, blocks = [], []                                     # 每次的目标数 / 最后一次的框
for t in range(max(1, N_SAMPLE)):                           # 连测 N_SAMPLE 次
    buf1.invalidate()                                       # 丢 cache，取新帧
    m = np.ascontiguousarray(np.asarray(v1[0])[::SY, OFF_PX:OFF_PX+IMG_W:SX, 0])  # ★ 隔行隔列读掩膜（数据量 1/(SY*SX)）
    boxes = detect(m)                                       # 检测（框已在 detect 内乘回真实坐标）
    counts.append(len(boxes))                               # 记下这次数到几个
    if t == max(1, N_SAMPLE) - 1:                           # 最后一次
        blocks = boxes                                      # 留着画图
    time.sleep(0.05)                                        # 隔开一点，换一帧
print("连续 %d 次检测到的目标数：%s" % (len(counts), counts), flush=True)   # 打印波动
if min(counts) != max(counts):                              # 次数不一致 = 不稳
    print("   ⚠ 次数在变 ⇒ 目标时断时连，先加大 CLOSE_K", flush=True)      # 提示
print("本次用参数：MIN_AREA=%d  CLOSE_K=%d  MERGE_GAP=%d  SY=%d SX=%d" % (MIN_AREA, CLOSE_K, MERGE_GAP, SY, SX), flush=True)

# ---- ② 全景图：红框画在【掩膜坐标】上，用来读 SHIFT_X/SHIFT_Y ----
buf0.invalidate()                                           # 原图缓冲
v0img = np.asarray(v0[0])                                   # ★ 原图只抓一次，所有块都从它裁
vis = np.array(v0img)                                       # 复制一份，画框不污染缓冲
for x, y, w, h in blocks:                                   # 每个框
    cv2.rectangle(vis, (x+OFF_PX, y), (x+OFF_PX+w, y+h), (0,0,255), 2)  # 画红框（掩膜坐标，未补偿）
plt.figure(figsize=(12, 7))                                 # 大图
plt.imshow(to_show(vis)); plt.axis('off')                   # 显示
plt.title('图1 全景：红框 = 掩膜给出的位置（红框比物体偏右 N 列 ⇒ SHIFT_X = N）')  # 读法写在标题里
plt.show()                                                  # 出图

# ---- ③ 每块：上排=原始裁剪，下排=letterbox SIZE×SIZE ----
K = max(len(blocks), 1)                                     # 至少留一格，避免 0 块时框图报错
fig, axes = plt.subplots(2, K, figsize=(3*K, 6.5))          # 2 行 K 列
if K == 1:                                                  # 只有 1 块时
    axes = axes.reshape(2, 1)                               # 强行变成 2×1，下面索引才一致
for k, (x, y, w, h) in enumerate(blocks):                   # 逐块
    x0 = max(0, x - SHIFT_X - PAD)                          # 原图左边界（补偿偏移 + 外扩）
    y0 = max(0, y - SHIFT_Y - PAD)                          # 原图上边界
    x1 = min(IMG_W, x + w - SHIFT_X + PAD)                  # 原图右边界
    y1 = min(v0img.shape[0], y + h - SHIFT_Y + PAD)         # 原图下边界
    roi = np.array(v0img[y0:y1, x0+OFF_PX : x1+OFF_PX, :])  # ★ 从彩色原图裁（列要加 OFF_PX）
    lb = letterbox(roi)                                     # 缩到 SIZE×SIZE
    print("  #%d 掩膜bbox=(%d,%d,%d,%d) → 原图裁 (%d,%d)-(%d,%d)   %d×%d → %d×%d"
          % (k+1, x, y, w, h, x0, y0, x1, y1, roi.shape[1], roi.shape[0], SIZE, SIZE), flush=True)  # 打印换算过程
    axes[0][k].imshow(to_show(roi))                         # 上排：原始裁剪
    axes[0][k].set_title("#%d 原始 %d×%d" % (k+1, roi.shape[1], roi.shape[0])); axes[0][k].axis('off')  # 标注
    axes[1][k].imshow(to_show(lb))                          # 下排：letterbox 后
    axes[1][k].set_title("#%d letterbox %d×%d" % (k+1, SIZE, SIZE)); axes[1][k].axis('off')  # 标注
plt.tight_layout(); plt.show()                              # 出图
