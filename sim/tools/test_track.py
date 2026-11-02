#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_track.py —— track.py 自检式单元测试（PC 上跑，不碰硬件）
   第二版：**每帧实时识别 + 滑动投票**。
   重点验：① 真的是每帧都认；② 手挡着时认错也能自己纠正回来；③ 多目标只轮着一个认。
"""
import os, sys
# 被测试的 track.py 在 <包>/src/ps/ 下，按本文件位置推过去（不写死绝对路径）
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(_HERE, '..', '..', 'src', 'ps')))
import track

FAILS = 0
CHECKS = 0


def ck(cond, what):
    global FAILS, CHECKS
    CHECKS += 1
    if not cond:
        FAILS += 1
        print("  FAIL:", what)


class Roi:
    size = 12


def crop(box):
    return Roi()


class SwitchClf:
    """可切换答案的假分类器：模拟"手挡着时认错、手走了认对" """
    def __init__(self):
        self.n = 0
        self.wrong = False

    def classify(self, roi):
        self.n += 1
        if self.wrong:                       # 手还在画面里 ⇒ 认成别的
            return (5, 'tissue', '不可回收', 0.85)
        return (1, 'can', '可回收', 0.90)


OBJ  = [120, 130, 60, 60]
OBJ2 = [400, 130, 60, 60]

# ---------- 用例 A：单目标 ⇒ 每帧都认（真·实时） ----------
clf = SwitchClf()
tab = track.TargetTable(clf=clf, k_confirm=3, k_lost=12, cls_per_frame=1, vote_n=5)
tab.update([OBJ], crop)
ck(clf.n == 1, "A1: 第 1 帧就应该认一次（实时）（实际 %d）" % clf.n)
tab.update([OBJ], crop)
tab.update([OBJ], crop)
ck(clf.n == 3, "A2: 3 帧应认 3 次（实际 %d）" % clf.n)
ck(tab.n_ok() == 1, "A3: 3 帧后应确认")
dl = tab.draw_list()
ck(len(dl) == 1 and dl[0][1] == 'can' and dl[0][2] is True, "A4: 应显示 can、绿色")

# ---------- 用例 B：★ 手挡着认错 ⇒ 手走后自己纠正 ----------
clf2 = SwitchClf()
clf2.wrong = True                                  # 手在画面里
tab2 = track.TargetTable(clf=clf2, k_confirm=3, k_lost=12, cls_per_frame=1, vote_n=5)
for _ in range(5):                                 # 手挡着 5 帧
    tab2.update([OBJ], crop)
dl = tab2.draw_list()
ck(len(dl) == 1 and dl[0][1] == 'tissue', "B1: 手挡着时先显示错的（正常，迟早纠正）")
ck(tab2.counts() == (0, 1, 0), "B2: 此时汇总按错的算")
clf2.wrong = False                                 # 手走了
for _ in range(3):                                 # 走 3 帧（正确票 3 : 错误票 2 已过半）
    tab2.update([OBJ], crop)
dl = tab2.draw_list()
ck(dl and dl[0][1] == 'can', "B3: 3 帧正确票后应翻成 can（3 票 vs 2 票）")
ck(tab2.counts() == (1, 0, 0), "B4: 汇总也跟着翻成可回收")

# ---------- 用例 C：多目标 ⇒ 每帧只轮着认一个 ----------
clf3 = SwitchClf()
tab3 = track.TargetTable(clf=clf3, k_confirm=3, k_lost=12, cls_per_frame=1, vote_n=5)
for _ in range(6):                                 # 两个目标喂 6 帧
    tab3.update([OBJ, OBJ2], crop)
ck(len(tab3.tgts) == 2, "C1: 应有两个目标")
ck(clf3.n == 6, "C2: 6 帧应只认 6 次（每帧 1 个，轮着来）（实际 %d）" % clf3.n)
ck(tab3.n_ok() == 2 and len(tab3.draw_list()) == 2, "C3: 两个都应确认并显示")

# ---------- 用例 D：cls_per_frame=2 ⇒ 每帧认两个 ----------
clf4 = SwitchClf()
tab4 = track.TargetTable(clf=clf4, k_confirm=3, k_lost=12, cls_per_frame=2, vote_n=5)
for _ in range(6):
    tab4.update([OBJ, OBJ2], crop)
ck(clf4.n == 12, "D1: 每帧认 2 个 ⇒ 6 帧应 12 次（实际 %d）" % clf4.n)

# ---------- 用例 E：投票压住偶发错票 ----------
clf5 = SwitchClf()
tab5 = track.TargetTable(clf=clf5, k_confirm=3, k_lost=12, cls_per_frame=1, vote_n=5)
for _ in range(5):                                 # 先 5 次正确
    tab5.update([OBJ], crop)
clf5.wrong = True                                  # 突然错 1 帧
tab5.update([OBJ], crop)
dl = tab5.draw_list()
ck(dl and dl[0][1] == 'can', "E1: 单次错票不应改变显示（5 对 1）")

# ---------- 用例 F：丢失 / 删除 ----------
tab6 = track.TargetTable(clf=SwitchClf(), k_confirm=3, k_lost=12, cls_per_frame=1)
for _ in range(4):
    tab6.update([OBJ], crop)
ck(len(tab6.tgts) == 1, "F1: 有 1 个目标")
for _ in range(11):                                # 丢 11 帧（<12）
    tab6.update([], crop)
ck(len(tab6.tgts) == 1, "F2: 丢 11 帧应还在")
tab6.update([], crop)                              # 第 12 帧
ck(len(tab6.tgts) == 0, "F3: 第 12 帧应删除")


# ---------- 用例 G：拒识 ⇒ 计 U、不画框 ----------
class RejClf:
    def classify(self, roi):
        return (-1, '未知', '未知', 0.31)


tab7 = track.TargetTable(clf=RejClf(), k_confirm=3, k_lost=12, cls_per_frame=1)
for _ in range(4):
    tab7.update([OBJ], crop)
ck(tab7.counts() == (0, 0, 1), "G1: 拒识计入 U")
ck(len(tab7.draw_list()) == 0, "G2: 拒识不画框")

# ---------- 用例 H：clf=None ⇒ 只跟框 ----------
tab8 = track.TargetTable(clf=None, k_confirm=3, k_lost=12)
for _ in range(6):
    tab8.update([OBJ], crop)
ck(tab8.n_ok() == 1 and len(tab8.draw_list()) == 0, "H1: 无分类器时确认但不画")
ck(tab8.n_cnn == 0, "H2: 无分类器时不该有 CNN 调用")

print("==== %d 次检查，%d 次失败 ====" % (CHECKS, FAILS))
print("ALL PASS" if FAILS == 0 else "HAS FAILURES")
