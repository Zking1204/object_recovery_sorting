# -*- coding: utf-8 -*-
"""
ref_cnn.py -- bit-exact numpy reference of the int8 TFLite model.

Implements the same fixed-point arithmetic TFLite uses, so the results can be
compared 1:1 against the board's tflite_runtime AND against the HLS C-sim.

Quantised pipeline (from weights.npz produced by dump_tflite.py):
    QUANTIZE -> CONV(3x3,'same',relu) -> MAXPOOL2 -> CONV -> MAXPOOL2
             -> CONV -> MAXPOOL2 -> CONV -> MEAN(global avg) -> FC -> DEQUANTIZE

Usage:
    python ref_cnn.py                 # random input, print shapes + logits
    python ref_cnn.py in.npy out.npz  # run on a float32 input .npy
"""
import sys
import os
import numpy as np

NPZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'weights.npz')

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


# ------------------------------------------------------- fixed point helpers
def quantize_multiplier(real_mult):
    """TFLite QuantizeMultiplier(): (int32 multiplier, shift)"""
    if real_mult == 0.0:
        return 0, 0
    m, e = np.frexp(np.float64(real_mult))          # real_mult = m * 2**e, m in [0.5,1)
    q = int(round(m * (1 << 31)))                   # 31-bit signed multiplier
    if q == (1 << 31):                              # overflow guard
        q //= 2
        e += 1
    return q, e


def sat_round_double_high_mul(a, b):
    """TFLite SaturatingRoundingDoublingHighMul(), elementwise on int arrays."""
    a64 = a.astype(np.int64)
    ab = a64 * np.int64(b)
    nudge = np.where(ab >= 0, np.int64(1) << 30, np.int64(1) - (np.int64(1) << 30))
    res = np.floor_divide(ab + nudge, np.int64(1) << 31)
    return np.clip(res, INT32_MIN, INT32_MAX).astype(np.int32)


def round_divide_by_pot(x, exponent):
    """TFLite RoundingDivideByPOT(): x / 2**exponent with round-half-away."""
    if exponent <= 0:
        return x.astype(np.int32)
    x64 = x.astype(np.int64)
    mask = np.int64((1 << exponent) - 1)
    remainder = x64 & mask
    threshold = np.int64((mask >> 1)) + np.where(x64 < 0, np.int64(1), np.int64(0))
    return ((x64 >> exponent) + (remainder > threshold).astype(np.int64)).astype(np.int32)


def multiply_by_quant_mult(x, multiplier, shift):
    """TFLite MultiplyByQuantizedMultiplier()"""
    left = shift if shift > 0 else 0
    right = -shift if shift < 0 else 0
    x = x.astype(np.int32) * np.int32(1 << left)
    return round_divide_by_pot(sat_round_double_high_mul(x, multiplier), right)


# ------------------------------------------------------------- layer kernels
def quantize_input(x_float, scale, zp):
    """float32 NHWC -> int8, q = round(x/scale) + zp, clamped"""
    q = np.round(x_float.astype(np.float32) / np.float32(scale)).astype(np.int32) + int(zp)
    return np.clip(q, -128, 127).astype(np.int8)


def conv3x3_relu(x_q, W, B, in_scale, w_scale, w_zp, out_scale, out_zp,
                 in_zp, pad=1):
    """
    int8 3x3 'same' stride-1 convolution with fused ReLU.
    W: [OC,3,3,IC] int8, B: [OC] int32, w_scale: [OC] float32 (per channel)
    Returns int8 [H,W,OC].
    """
    H, Wd, IC = x_q.shape
    OC = W.shape[0]
    x = x_q.astype(np.int32) - int(in_zp)                 # centred activations
    xp = np.pad(x, ((pad, pad), (pad, pad), (0, 0)))      # SAME padding with zp
    acc = np.zeros((H, Wd, OC), np.int32)                 # int32 accumulator
    for kh in range(3):
        for kw in range(3):
            patch = xp[kh:kh + H, kw:kw + Wd, :]          # [H,W,IC]
            wgt = W[:, kh, kw, :].astype(np.int32)        # [OC,IC]
            if np.any(w_zp):
                wgt = wgt - int(w_zp[0])
            acc += (patch.reshape(-1, IC) @ wgt.T).reshape(H, Wd, OC)   # [H,W,OC]
    acc = acc.reshape(H, Wd, OC) + B.astype(np.int32)[None, None, :]
    out = np.empty((H, Wd, OC), np.int8)
    act_min, act_max = -128, 127                          # ReLU with zp=-128
    for oc in range(OC):
        rm = float(in_scale) * float(w_scale[oc]) / float(out_scale)
        mul, sh = quantize_multiplier(rm)
        v = multiply_by_quant_mult(acc[:, :, oc], mul, sh) + int(out_zp)
        out[:, :, oc] = np.clip(v, act_min, max(act_min, act_max)).astype(np.int8)
    return out


def maxpool2(x_q):
    """int8 2x2 stride-2 max pool (monotonic, zero point irrelevant)."""
    H, Wd, C = x_q.shape
    v = x_q.astype(np.int16).reshape(H // 2, 2, Wd // 2, 2, C)
    return v.max(axis=(1, 3)).astype(np.int8)


def global_avg(x_q, in_scale, in_zp, out_scale, out_zp):
    """int8 global average pooling (TFLite MEAN over H,W)."""
    H, Wd, C = x_q.shape
    acc = (x_q.astype(np.int32) - int(in_zp)).sum(axis=(0, 1))   # [C] int32
    rm = float(in_scale) / float(H * Wd * out_scale)
    mul, sh = quantize_multiplier(rm)
    v = multiply_by_quant_mult(acc, mul, sh) + int(out_zp)
    return np.clip(v, -128, 127).astype(np.int8)[None, :]        # [1,C]


def fully_connected(x_q, W, B, in_scale, in_zp, w_scale, w_zp,
                    out_scale, out_zp):
    """int8 FC: y = W x + b with per-channel output scale."""
    OC = W.shape[0]
    x = x_q.astype(np.int32) - int(in_zp)                        # [1,IC]
    wg = W.astype(np.int32)
    if np.any(w_zp):
        wg = wg - int(w_zp[0])
    acc = (wg @ x.reshape(-1)).astype(np.int32) + B.astype(np.int32)
    out = np.empty(OC, np.int8)
    for oc in range(OC):
        rm = float(in_scale) * float(w_scale[oc]) / float(out_scale)
        mul, sh = quantize_multiplier(rm)
        v = int(multiply_by_quant_mult(np.array([acc[oc]], np.int32), mul, sh)[0]) + int(out_zp)
        out[oc] = np.clip(v, -128, 127)
    return out[None, :]


# ---------------------------------------------------------------- full model
class RefCNN(object):
    def __init__(self, npz=NPZ):
        d = np.load(npz)
        self.d = {k: d[k] for k in d.files}
        g = self.d

        def s(k):
            return float(g[k][0])

        def z(k):
            return int(g[k][0])

        # per-op quant params, keyed by the names dump_tflite.py produced
        self.q_in = (s('00_quantize_out0_scale'), z('00_quantize_out0_zp'))
        self.q_c1 = (s('01_conv_2d_out0_scale'), z('01_conv_2d_out0_zp'))
        self.q_p1 = (s('02_max_pool_2d_out0_scale'), z('02_max_pool_2d_out0_zp'))
        self.q_c2 = (s('03_conv_2d_out0_scale'), z('03_conv_2d_out0_zp'))
        self.q_p2 = (s('04_max_pool_2d_out0_scale'), z('04_max_pool_2d_out0_zp'))
        self.q_c3 = (s('05_conv_2d_out0_scale'), z('05_conv_2d_out0_zp'))
        self.q_p3 = (s('06_max_pool_2d_out0_scale'), z('06_max_pool_2d_out0_zp'))
        self.q_c4 = (s('07_conv_2d_out0_scale'), z('07_conv_2d_out0_zp'))
        self.q_gap = (s('08_mean_out0_scale'), z('08_mean_out0_zp'))
        self.q_fc = (s('09_fully_connected_out0_scale'), z('09_fully_connected_out0_zp'))

    def forward(self, x_float, dump=None):
        """x_float: [1,64,64,3] float32 already normalised. Returns logits [6]."""
        g = self.d
        t = {}
        t['in_q'] = quantize_input(x_float[0], *self.q_in)

        t['c1'] = conv3x3_relu(t['in_q'],
                               g['01_conv_2d_in1'], g['01_conv_2d_in2'],
                               self.q_in[0], g['01_conv_2d_in1_scale'],
                               g['01_conv_2d_in1_zp'], *self.q_c1,
                               in_zp=self.q_in[1])
        t['p1'] = maxpool2(t['c1'])

        t['c2'] = conv3x3_relu(t['p1'],
                               g['03_conv_2d_in1'], g['03_conv_2d_in2'],
                               self.q_p1[0], g['03_conv_2d_in1_scale'],
                               g['03_conv_2d_in1_zp'], *self.q_c2,
                               in_zp=self.q_p1[1])
        t['p2'] = maxpool2(t['c2'])

        t['c3'] = conv3x3_relu(t['p2'],
                               g['05_conv_2d_in1'], g['05_conv_2d_in2'],
                               self.q_p2[0], g['05_conv_2d_in1_scale'],
                               g['05_conv_2d_in1_zp'], *self.q_c3,
                               in_zp=self.q_p2[1])
        t['p3'] = maxpool2(t['c3'])

        t['c4'] = conv3x3_relu(t['p3'],
                               g['07_conv_2d_in1'], g['07_conv_2d_in2'],
                               self.q_p3[0], g['07_conv_2d_in1_scale'],
                               g['07_conv_2d_in1_zp'], *self.q_c4,
                               in_zp=self.q_p3[1])

        t['gap'] = global_avg(t['c4'], self.q_c4[0], self.q_c4[1], *self.q_gap)
        t['fc'] = fully_connected(t['gap'],
                                  g['09_fully_connected_in1'],
                                  g['09_fully_connected_in2'],
                                  self.q_gap[0], self.q_gap[1],
                                  g['09_fully_connected_in1_scale'],
                                  g['09_fully_connected_in1_zp'],
                                  *self.q_fc)
        logits = (t['fc'][0].astype(np.float32) - self.q_fc[1]) * self.q_fc[0]
        if dump is not None:
            for k, v in t.items():
                dump[k] = v.copy()
            dump['logits'] = logits
        return logits


def main():
    net = RefCNN()
    if len(sys.argv) > 1:
        x = np.load(sys.argv[1]).astype(np.float32)
        if x.ndim == 3:
            x = x[None, ...]
    else:
        rng = np.random.default_rng(1234)
        x = rng.standard_normal((1, 64, 64, 3)).astype(np.float32)

    dump = {}
    logits = net.forward(x, dump)
    print("input      : %s %s   mean=%.3f" % (x.shape, x.dtype, float(x.mean())))
    print("layer shapes:")
    for k in ('in_q', 'c1', 'p1', 'c2', 'p2', 'c3', 'p3', 'c4', 'gap', 'fc'):
        a = dump[k]
        print("  %-5s %-18s dtype=%-6s min=%-5d max=%-5d" %
              (k, str(a.shape), str(a.dtype), int(a.min()), int(a.max())))
    print("logits     : %s" % np.array2string(logits, precision=4))
    e = np.exp(logits - logits.max())
    p = e / e.sum()
    print("softmax    : %s" % np.array2string(p, precision=4))
    print("argmax     : %d  (conf %.4f)" % (int(p.argmax()), float(p.max())))

    if len(sys.argv) > 2:
        out = dict(dump)
        out['input'] = x
        np.savez_compressed(sys.argv[2], **out)
        print("dumped -> %s" % sys.argv[2])


if __name__ == '__main__':
    main()
