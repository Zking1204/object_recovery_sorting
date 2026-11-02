###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：track.py
# 角色   ：跨帧跟踪与计数：质心距离匹配、3 帧确认、12 帧丢失删除、每个目标最近 5 次识别结果多数投票、过线触发
# 依赖   ：无
# 启动   ：被 osd.py import
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
track.py —— 目标表 + **实时识别**（2026-10-20 第二版，纯 Python，不碰硬件）

【这一版为什么改成"实时识别"】
  第一版是"每个目标只认一次（等画面稳定后认）"。用户判断：**不太行** ——
  实测下来"等稳定"这套判据不好用（手放物体时掩膜一直在变，稳定点抓不准）。
  改成 **每帧都重新认**：手走了下一帧自然就认对了，**自愈，不需要稳定判据**。
  代价是循环变慢（见下），但**屏幕上的视频完全不受影响**（显示是硬件 MM2S 独立跑的），
  只有"框和名字"的刷新率降到 ~15 Hz —— 物体静止，肉眼看不出差别。

【两个必须的配套设计，否则实时识别会很难看】
  ① **每帧最多认 CLS_PER_FRAME 个**（默认 1，轮着来）：
     一帧时间 = 找框 25 ms + 认一次 38.7 ms ≈ **64 ms（约 15.6 Hz）**；
     如果一帧把 N 个都认 ⇒ 25+38.7×N，N=3 就掉到 ~7 Hz。
     轮着来的好处：**只有一个物体时它每帧都被认**（就是真正的实时），多个物体时轮流刷新。
  ② **滑动窗口多数投票**（VOTE_N=5）：
     模型本身有抖动，每帧重认会让名字每秒跳十几次。
     所以每个目标留最近 N 次结果，**显示票数最多的那一类**（票数相同比置信度和）。
     顺带解决"手还在画面里认错"：手的那 1~2 票会被后面正确的票压过去。

【其余职责不变】
  · 质心距离匹配 ⇒ 给每个物体一个稳定编号（计数的前提）
  · 连续 K_CONFIRM 帧出现才算"有东西"（防单帧噪声）
  · 连续 K_LOST 帧没匹配上才删除（手挡住物体时别删太快）

【依赖】不依赖任何硬件；CNN 通过构造函数注入（clf.classify(roi_bgr) 返回 4 元组），
        裁图也通过 crop_fn 注入 ⇒ 本文件可以脱离板子上跑单元测试。
"""

import time                                             # 只给 CNN 计时

# ★ 版本戳：每次改了 track.py 就把这里改一下。
#   板上启动时 osd.py 会把它打出来 —— 用来确认"跑的是新版还是缓存里的旧版"。
TRACK_VERSION = "v3.2-sortline R->L xtrig=494 2026-10-28"

# ============ 可调参数 ============
K_CONFIRM     = 3       # 连续几帧出现才算"这里有个东西"（防单帧噪声）
K_LOST        = 12      # 连续几帧没匹配上才删除（手挡住物体时别删太快，≈0.4 s @15Hz）
MATCH_K       = 0.6     # 质心距离阈值 = MATCH_K × max(宽,高)
CLS_PER_FRAME = 1       # ★ 每帧最多认几个（1 = 轮着来，循环 ≈64 ms/15.6 Hz）
VOTE_N        = 5       # ★ 显示用最近几次结果的多数投票（抗抖动 + 抗"手挡住的错票"）

# ============ 分拣（2026-10-26 新增；★ 2026-10-28 改成"屏幕中心 · 右→左"）============
# ★ 触发判据：**质心从右向左越过 X_TRIG 线，且该目标此前在线的右侧出现过**。
#   ① 不用"目标 ID 消失"——K_LOST=12 帧超时会慢约 0.4 s，且大小不同的物体消失时刻不同。
#   ② 方向是 **右 → 左**（cx 递减）⇒ 越线 = "曾在线右边（passed_side=True），现在已经跑到线左边"。
#   ③ **"直接凭空出现在竖线左边"的目标不当**（用户 2026-10-28 要求）⇒
#      它从没在线的右侧出现过，passed_side 永远 False ⇒ 不会被触发。
SORT_DIR      = -1      # 运动方向：-1 = 右→左（cx 递减，本项目当前场景）；+1 = 左→右
X_TRIG        = 494     # 触发线，**掩膜列坐标**（0..971）
                        #   ★ 两种坐标的换算（唯一真相源，别记错）：
                        #       屏幕列 = 掩膜列 − SHIFT_X + OFF_PX = 掩膜列 + 146
                        #     所以 **屏幕正中第 640 列 ⇒ 掩膜列 = 640 − 160 + 14 = 494**
                        #   （SHIFT_X=14 是掩膜相对彩色原图右移的列数，OFF_PX=160 是行内留边）
CLASS2SERVO   = {       # 类别索引 → 舵机通道（0/1/2）
    1: 0,               # can（易拉罐）      → 1 号舵机
    4: 1,               # plastic_bottle（塑料瓶）→ 2 号舵机
    2: 2,               # cardboard（纸壳）  → 3 号舵机
}                       # 其余三类（banana_peel / orange_peel / tissue）不在表里 ⇒ 不动作


def _cen(box):
    """框的质心（掩膜坐标）"""
    x, y, w, h = box                                    # 拆开
    return (x + w * 0.5, y + h * 0.5)                   # 中心点


class Target:
    """一个目标（物体）的全部状态"""

    def __init__(self, tid, box):
        self.id      = tid                              # 内部编号（自增，不复用）
        self.box     = list(box)                        # 当前框 [x,y,w,h]（掩膜坐标）
        self.cx, self.cy = _cen(box)                    # 当前质心
        self.hit     = 1                                # 连续出现帧数
        self.miss    = 0                                # 连续丢失帧数
        self.ok      = False                            # 是否已确认（确认后才画框）
        self.hist    = []                               # ★ 最近 VOTE_N 次分类结果 [(cid,name,garb,conf)]
        self.last_cls = -1                              # 上次被认的帧号（轮转用；-1 = 还没认过）
        self.matched = False                            # 本帧是否被匹配上（内部用）
        self.n_cls   = 0                                # 一共认过几次（调试用）
        self.counted = False                            # ★ 是否已经过线处理过（触发过、或判定不动作）
        self.passed_side = False                        # ★ 是否曾出现在触发线的"来向那侧"（右→左时=右侧）
                                                        #   用来排除"凭空出现在竖线左边"的目标
        self.fired_cls = -1                             # ★ 触发时用的是哪一类（-1 = 没触发）


class TargetTable:
    """目标表：匹配给编号 → 每帧轮着认 CLS_PER_FRAME 个 → 多数投票定显示"""

    def __init__(self, clf=None, k_confirm=K_CONFIRM, k_lost=K_LOST, match_k=MATCH_K,
                 cls_per_frame=CLS_PER_FRAME, vote_n=VOTE_N,
                 servo=None, x_trig=X_TRIG, c2s=None, sort_dir=SORT_DIR):
        self.clf           = clf                        # 分类器（None ⇒ 只跟框不识别）
        self.servo         = servo                      # ★ 舵机驱动（None ⇒ 不做分拣；有 kick(ch) 方法即可）
        self.x_trig        = x_trig                     # ★ 触发线（掩膜列坐标）
        self.sort_dir      = sort_dir                   # ★ 运动方向：-1 右→左 / +1 左→右
        self.c2s           = dict(CLASS2SERVO if c2s is None else c2s)   # 类别 → 舵机通道
        self.n_fire        = 0                          # ★ 累计触发（踢）次数
        self.k_confirm     = k_confirm                  # 出现多少帧算"有东西"
        self.k_lost        = k_lost                     # 丢多少帧才删除
        self.match_k       = match_k                    # 匹配阈值系数
        self.cls_per_frame = cls_per_frame              # 每帧最多认几个
        self.vote_n        = vote_n                     # 投票窗口
        self.tgts          = []                         # 目标列表
        self.nid           = 0                          # 下一个编号
        self.frame         = 0                          # 帧计数（轮转用）
        self.n_cnn         = 0                          # 累计 CNN 调用次数（判据用）
        self.t_cnn         = 0.0                        # 累计 CNN 耗时

    def reset(self):
        """全部清空（换场景时用）"""
        self.tgts  = []
        self.nid   = 0
        self.frame = 0
        self.n_cnn = 0
        self.t_cnn = 0.0
        self.n_fire = 0                                 # ★ 分拣触发次数也要清零

    # ---------------- 内部：对一个目标跑一次 CNN，压进投票窗口 ----------------
    def _classify(self, t, crop_fn):
        if (self.clf is None) or (crop_fn is None):     # 没有分类器 / 没有裁图函数
            return False                                # 什么都不做
        roi = crop_fn(t.box)                            # 从干净彩色裁 ROI
        if roi is None or getattr(roi, "size", 0) <= 0:  # 裁不到东西
            return False                                # 跳过（等下一轮）
        ts = time.time()                                # 开始计时
        cid, name, garb, conf = self.clf.classify(roi)   # ★ 认这一次
        self.t_cnn += time.time() - ts                  # 累计耗时
        self.n_cnn += 1                                 # 累计次数
        t.hist.append((cid, name, garb, conf))          # 压进投票窗口
        if len(t.hist) > self.vote_n:                   # 窗口满了
            t.hist.pop(0)                               # 丢掉最老的一票
        t.last_cls = self.frame                         # 记下"这一帧认过它"
        t.n_cls   += 1                                  # 该目标累计认了几次
        return True                                     # 成功了

    # ---------------- 内部：多数投票 → 显示用的那个结果 ----------------
    def _vote(self, t):
        """返回 (cid, name, garbage, conf)：票数最多的那类；票数相同比置信度和"""
        if not t.hist:                                  # 还没认过
            return (-1, None, None, 0.0)                # 当作无结果
        score = {}                                      # cid -> [票数, 置信度和, name, garb]
        for cid, name, garb, conf in t.hist:            # 扫投票窗口
            s = score.get(cid)                          # 取这个类的累计
            if s is None:                               # 第一次出现
                s = [0, 0.0, name, garb]                # 新建
                score[cid] = s                          # 存表
            s[0] += 1                                   # 票数 +1
            s[1] += float(conf)                         # 置信度和 +
        best_cid, best = max(score.items(), key=lambda kv: (kv[1][0], kv[1][1]))
        return (best_cid, best[2], best[3], best[1] / best[0])   # 票数优先、其次置信度和

    # ---------------- 主入口 ----------------
    def update(self, boxes, crop_fn=None):
        """喂进本帧的框列表，返回 (目标列表, 本帧认了几个)
           boxes   : [[x,y,w,h], ...] 掩膜坐标
           crop_fn : box -> BGR ndarray（从干净彩色缓冲裁），可为 None"""
        self.frame += 1                                 # 帧号 +1（轮转用）

        for t in self.tgts:                             # ① 先把所有目标标成"本帧未匹配"
            t.matched = False

        for b in boxes:                                 # ② 逐个当前框找最近的目标
            cx, cy = _cen(b)                            # 本框质心
            thr    = self.match_k * max(b[2], b[3])     # 匹配阈值随框大小缩放
            best   = None                               # 最近的目标
            bd     = 1e18                               # 最近距离
            for t in self.tgts:                         # 扫全表
                if t.matched:                           # 已被别的框占了
                    continue                            # 跳过（一帧内一对一）
                d = ((cx - t.cx) ** 2 + (cy - t.cy) ** 2) ** 0.5   # 质心距离
                if d < thr and d < bd:                  # 够近且更近
                    best = t                            # 记下
                    bd   = d                            # 更新最近距离
            if best is None:                            # 没匹配上 ⇒ 新目标
                t = Target(self.nid, b)                 # 建条目
                self.nid += 1                           # 编号自增
                t.matched = True                        # 标记本帧已匹配
                self.tgts.append(t)                     # 进表
            else:                                       # 匹配上了 ⇒ 更新位置
                best.box     = list(b)                  # 更新框
                best.cx, best.cy = cx, cy               # 更新质心
                best.hit    += 1                        # 连续出现 +1
                best.miss    = 0                        # 丢失清零
                best.matched = True                     # 标记本帧已匹配

        for t in self.tgts:                             # ③ 没匹配上的累计丢失
            if not t.matched:
                t.miss += 1                             # 丢失 +1

        self.tgts = [t for t in self.tgts if t.miss < self.k_lost]   # 丢够久就删

        for t in self.tgts:                             # ④ 出现过够久 ⇒ 确认（可以画框）
            if t.miss == 0 and (not t.ok) and t.hit >= self.k_confirm:
                t.ok = True                             # 转正

        # ⑤ ★ 实时识别：本帧轮着认 CLS_PER_FRAME 个（优先认"最久没被认过"的）
        cands = [t for t in self.tgts if t.miss == 0]   # 这一帧看得见的目标
        cands.sort(key=lambda t: t.last_cls)            # 最久没认过的排前面（-1 最先）
        n_new = 0                                       # 本帧真的认了几个
        for t in cands[:self.cls_per_frame]:            # 只认前 CLS_PER_FRAME 个
            if self._classify(t, crop_fn):              # 认一次
                n_new += 1                              # 计数
        # ⑥ ★ 过线触发分拣（方向 右→左：曾在线右侧、现在已到左侧 = 刚越过）
        #    判据：本帧看得见 + 已确认 + 还没处理过 + **曾在线右侧出现过** + 已越线
        if self.servo is not None:                      # 注入了舵机驱动才做这一节
            for t in self.tgts:                         # 扫全表
                if t.miss == 0:                         # 本帧看得见才更新"曾在哪一侧"
                    if self.sort_dir < 0:               #   右→左：来向在右边
                        if t.cx > self.x_trig:          #     还在线的右侧
                            t.passed_side = True        #       记住"它在右侧待过"
                    else:                               #   左→右：来向在左边
                        if t.cx < self.x_trig:          #     还在线的左侧
                            t.passed_side = True        #       记住"它在左侧待过"
                if (not t.ok) or t.miss:                # 还没转正 / 本帧丢了
                    continue                            # 跳过
                if t.counted:                           # ★ 已经处理过
                    continue                            # 跳过（保证每个目标只触发一次）
                if not t.passed_side:                   # ★ 从没在触发线的"来向那侧"出现过
                    continue                            #   ⇒ 凭空出现在竖线左边，不管它
                crossed = (t.cx <= self.x_trig) if self.sort_dir < 0 else (t.cx >= self.x_trig)
                if not crossed:                         # 还没走到触发线
                    continue                            # 等下一帧
                cid, name, garb, conf = self._vote(t)   # ★ 用**投票结果**定类别
                                                        #   = 屏幕上此刻显示的那一类，两者同源
                ch = self.c2s.get(cid)                  # 查"类别 → 舵机通道"
                t.counted = True                        # ★ 无论动不动，都标记已处理，避免每帧重复判定
                if ch is None:                          # 这个类别不接舵机（或还没认出来）
                    continue                            # 不动作
                self.servo.kick(ch)                     # ★ 踢一脚：延时/保持/回中位全由硬件走完
                t.fired_cls = cid                       # 记下触发用的是哪一类
                self.n_fire += 1                        # 累计分拣次数

        return self.tgts, n_new                         # 返回

    # ---------------- 对外：给 OSD 用 ----------------
    def draw_list(self):
        """返回 [(box, 英文名, 是否绿色), ...]，只含「已确认且投票出来不是拒识」的"""
        out = []                                        # 结果
        for t in self.tgts:                             # 扫全表
            if not t.ok:                                # 还没确认
                continue                                # 跳过
            cid, name, garb, conf = self._vote(t)       # 取投票结果
            if cid >= 0 and name:                       # 认出来了（不是拒识）
                out.append((t.box, name, garb == '可回收'))   # 可回收 = 绿
        return out                                      # 返回

    def counts(self):
        """汇总计数：(可回收数, 不可回收数, 未知数) —— 用投票结果算"""
        r = n = u = 0                                   # 三个计数器
        for t in self.tgts:                             # 扫全表
            if not t.ok:                                # 还没确认的不算
                continue                                # 跳过
            cid, name, garb, conf = self._vote(t)       # 取投票结果
            if cid < 0:                                 # ★ 拒识
                u += 1                                  # 未知 +1
            elif garb == '可回收':                       # 可回收
                r += 1                                  # 可回收 +1
            else:                                       # 其余按不可回收
                n += 1                                  # 不可回收 +1
        return r, n, u                                  # 返回

    def n_ok(self):
        """已确认的目标数"""
        return sum(1 for t in self.tgts if t.ok)        # 数一遍

    def n_all(self):
        """表里所有目标数（含候选）"""
        return len(self.tgts)                           # 直接长度
