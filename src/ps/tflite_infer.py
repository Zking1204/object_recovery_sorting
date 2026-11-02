###########################################################################
# 物品回收智能分拣系统 · 板端 PS 侧脚本（提交包副本，逻辑与板端运行版本一致，仅加本注释块）
# 文件   ：tflite_infer.py
# 角色   ：PS 侧 TFLite 回退推理与预处理（letterbox、归一化、标签表、拒识阈值）。PL 通路可用时仅提供常量 ★ 提交包内已把 SIZE 由 42 修正为 64，与 cnn_pl_infer.py 的门禁及 model_int8_64.tflite 对齐
# 依赖   ：tflite_runtime
# 启动   ：被 cnn_pl_infer.py import；osd.py 在无 PL 句柄时回退使用
###########################################################################
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
板端 TFLite 推理模块（在 PYNQ 板的 Jupyter 里用，比 numpy 推理快一个量级）。

输入：队友检测出的 ROI（BGR 彩色裁剪图，任意尺寸）
输出：(class_id, 类名, 垃圾类别, 置信度)
      ★ 置信度低于 self.th ⇒ 判为"未知"：返回 (-1, '未知', '未知', 置信度)，不硬塞进某一类

★ 2026-10-13 板端补丁：classify 增加 softmax + 拒识阈值。
  原版直接 argmax(logits) —— 没有概率、没有阈值 ⇒ 没教过的东西会被硬塞进某一类。
  备份：tflite_infer.py.bak_before_reject（★ 队友若重新发这个文件，本补丁要重打）

预处理和训练完全一致，输出 NHWC (1,42,42,3)：
  1) BGR → RGB
  2) letterbox 到 42×42（等比缩放 + 居中补黑边）
  3) /255 到 0~1
  4) 减 mean 除 std（ImageNet）
"""
import numpy as np
import cv2

# 板上用 tflite_runtime（队友确认过 armv7l 有 wheel）
import tflite_runtime.interpreter as tflite

SIZE                 = 64
IMGNET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMGNET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

LABELS = ['banana_peel', 'can', 'cardboard', 'orange_peel', 'plastic_bottle', 'tissue']

GARBAGE = {
    'banana_peel': '不可回收',
    'can': '可回收',
    'cardboard': '可回收',
    'orange_peel': '不可回收',
    'plastic_bottle': '可回收',
    'tissue': '不可回收',
}


def letterbox(img, size=SIZE):
    """等比缩放到 size×size、居中补黑边（和训练一致，别改）。"""
    h, w = img.shape[:2]
    s = size / max(h, w)
    nh, nw = max(1, int(round(h * s))), max(1, int(round(w * s)))
    interp = cv2.INTER_AREA if s < 1 else cv2.INTER_LINEAR
    small = cv2.resize(img, (nw, nh), interpolation=interp)
    out = np.zeros((size, size, 3), dtype=np.uint8)
    y0, x0 = (size - nh) // 2, (size - nw) // 2
    out[y0:y0 + nh, x0:x0 + nw] = small
    return out


def preprocess(roi_bgr):
    """ROI(BGR,0~255,任意尺寸) -> (1,42,42,3) float32 归一化。"""
    rgb = cv2.cvtColor(roi_bgr, cv2.COLOR_BGR2RGB)
    lb = letterbox(rgb)
    x = lb.astype(np.float32) / 255.0
    x = (x - IMGNET_MEAN) / IMGNET_STD
    return x[np.newaxis, ...]                                # (1,42,42,3) NHWC


class Classifier:
    """加载 TFLite 模型，对单个 ROI 分类。"""

    def __init__(self, model_path='model.tflite'):
        self.interp = tflite.Interpreter(model_path=model_path)
        self.interp.allocate_tensors()
        self.in_idx = self.interp.get_input_details()[0]['index']
        self.out_idx = self.interp.get_output_details()[0]['index']
        self.th = 0.5                                    # ★ 拒识阈值：最高概率低于它就报"未知"（后续按队友给的分布调）

    def classify(self, roi_bgr):
        """返回 (class_id, 类名, 垃圾类别, 置信度)；判为"未知"时 class_id = -1。"""
        x = preprocess(roi_bgr)                              # 预处理：与训练端完全一致（含 mean/std 归一化）
        self.interp.set_tensor(self.in_idx, x)               # 把 (1,42,42,3) 喂进模型
        self.interp.invoke()                                 # 跑一次推理
        z = self.interp.get_tensor(self.out_idx)[0]          # ★ 模型给的是 logits（模型里没有 softmax）
        e = np.exp(z - z.max())                              # softmax 第一步：先减最大值，防止 exp 溢出
        p = e / e.sum()                                      # softmax 第二步：归一化 ⇒ 概率，和为 1
        cid = int(np.argmax(p))                              # 概率最大的那一类
        conf = float(p[cid])                                 # 它的概率
        if conf < self.th:                                   # ★ 低于拒识阈值 ⇒ 当作"没教过的东西"
            return -1, '未知', '未知', conf                   #   报"未知"，绝不硬塞进某一类
        name = LABELS[cid]                                   # 类名
        return cid, name, GARBAGE[name], conf                # 正常返回（带置信度，画框时显示用）
