# -*- coding: utf-8 -*-
"""
gen_data.py -- export the model into flat binaries + golden tensors for HLS.

Outputs (into  <hls_cnn>/build/ ):
    model_blob.bin    all int8 weights, concatenated in fixed offset order
    model_bias.bin    all int32 biases, concatenated
    model_mshift.bin  per-channel right-shift for the requantisation (int32)
    model_mmult.bin   per-channel multiplier   for the requantisation (int32)
    model_meta.h      C header: offsets / sizes / zero points / activation scales
    golden_in.bin     int8 quantised input for seed=1234 test vector
    golden_c1.bin     expected int8 output of conv1   (same for c2..c4, p1..p3)
    golden_gap.bin / golden_fc.bin / golden_logits.txt

Tensor layout order for weights (int8):
    W1 [32,3,3,3]  W2 [64,3,3,32]  W3 [128,3,3,64]  W4 [256,3,3,128]  WFC [6,256]
Bias (int32):  B1[32]  B2[64]  B3[128]  B4[256]  BFC[6]
Scale(float32): S1[32] S2[64] S3[128] S4[256] SFC[6]

Requantisation table: for every output channel we pre-compute the tflite pair
(int32 multiplier, shift) from   rm = in_scale * weight_scale / out_scale  .
Doing it here (instead of in the kernel) keeps frexp() and all floating point
out of the synthesised datapath -- frexp has no hardware implementation.
Offset layout of model_mmult.bin / model_mshift.bin is identical to
model_bias.bin (one entry per output channel, same order).
"""
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ref_cnn import RefCNN, quantize_multiplier          # noqa: E402

OUT = os.path.join(HERE, 'build')

# Must match POC / PIC in cnn_accel.cpp: one weight tile is
# POC_TILE output channels x 9 taps x PIC_TILE input channels.
POC_TILE = 16
PIC_TILE = 8

# layer descriptors: (tag, weight key, bias key, cin, cout)
LAYERS = [
    ('c1', '01_conv_2d_in1', '01_conv_2d_in2', 3, 32),
    ('c2', '03_conv_2d_in1', '03_conv_2d_in2', 32, 64),
    ('c3', '05_conv_2d_in1', '05_conv_2d_in2', 64, 128),
    ('c4', '07_conv_2d_in1', '07_conv_2d_in2', 128, 256),
    ('fc', '09_fully_connected_in1', '09_fully_connected_in2', 256, 6),
]


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    net = RefCNN()
    g = net.d

    # (scale, zero_point) of every activation tensor, plus which tensor feeds
    # which layer.  Needed early because the conv bias is corrected below.
    acts = {'in': net.q_in, 'c1': net.q_c1, 'c2': net.q_c2, 'c3': net.q_c3,
            'c4': net.q_c4, 'gap': net.q_gap, 'fc': net.q_fc}
    src_of = {'c1': 'in', 'c2': 'c1', 'c3': 'c2', 'c4': 'c3',
              'gap': 'c4', 'fc': 'gap'}

    # ---------------- weights / bias / scale blobs ----------------
    # The conv weights are re-laid out for the accelerator's on-chip tile:
    #   per output channel the bytes are  [kh][kw][ic]  with ic padded up to a
    #   multiple of 8 (= PIC).  That makes the whole DSP-block of one output
    #   channel ONE contiguous run, so the kernel can stream it out of DDR with
    #   a plain linear copy (burst) instead of a strided gather.
    # The fully connected layer keeps its natural [COUT][CIN] order.
    w_blob, b_blob, s_blob = [], [], []
    off = 0
    layout = []
    for tag, wk, bk, cin, cout in LAYERS:
        w = g[wk].astype(np.int8)
        b = g[bk].astype(np.int32)
        s = g[wk + '_scale'].astype(np.float32)
        if w.shape[0] != cout:
            raise SystemExit("bad weight shape for %s: %s" % (tag, w.shape))
        if s.size != cout:
            raise SystemExit("bad scale count for %s: %d" % (tag, s.size))
        if tag == 'fc':
            cinp = cin                                        # already a multiple of 8
            wpad = np.ascontiguousarray(w)                    # [COUT][CIN]
        else:
            cinp = ((cin + 7) // 8) * 8                       # pad channels to 8
            wp = np.zeros((cout, 3, 3, cinp), np.int8)        # zero padded kernel
            wp[:, :, :, :cin] = w                             # real taps in place
            # ---- lay out one tile as [tap][oc-in-group][ic] ----------------
            # A tile is POC*9*PIC = 576 B and must be contiguous in DDR so the
            # kernel can fetch it with ONE long burst.  Within a tile the tap
            # index is the OUTER index: then, for a fixed tap, the 64 (oc,ic)
            # bytes are contiguous, so the on-chip tile can be 64 static banks
            # of one 9-byte column each -- no dynamic bank select, which is what
            # used to serialise the 72 reads into 8 x 9 latency-bound streams.
            og_n = cout // POC_TILE
            ib_n = cinp // PIC_TILE
            wp = wp.reshape(cout, 9, cinp)                    # [oc][tap][ic]
            wp = wp.reshape(og_n, POC_TILE, 9, ib_n, PIC_TILE)  # [og][oc][tap][ib][t]
            # Re-order so that, for one (tap, input-block), the POC*PIC weights
            # are 64 CONTIGUOUS bytes: [og][tap][ib][oc][ic].  The kernel then
            # reads them as ONE 512-bit word from a single block-RAM array.
            # (Do NOT split this into 8 per-oc banks: after a complete partition
            # the sub-arrays become scalars and BIND_STORAGE is silently ignored,
            # which is what pushed the block into 73728 flip-flops.)
            wpad = np.ascontiguousarray(wp.transpose(0, 2, 3, 1, 4))
            if wpad.size != cout * 9 * cinp:
                raise SystemExit('tile reorder lost data for %s' % tag)
        layout.append(dict(tag=tag, wk=wk, off=off, n=wpad.size,
                           cout=cout, cin=cin, cinp=cinp,
                           wb=(cinp if tag == 'fc' else 9 * cinp)))
        # ---- fold the input zero point into the bias ----------------------
        # The conv really computes  sum (iv - izp) * w + bias.  Expanding it as
        #   sum iv*w - izp*sum(w) + bias
        # turns "izp*sum(w)" into a per-channel CONSTANT, because izp is a
        # per-layer constant and sum(w) is the sum of all weights of that output
        # channel.  Moving it into the bias removes PIC subtractors from the
        # critical path of the inner MAC loop at zero cost.  Exactly equal in
        # integer arithmetic; checked to fit in int32 below.
        if tag == 'fc':
            b_out = b                                          # FC path is unchanged
        else:
            # wpad is [og][tap][ib][oc-in-group][t]; the bias counts output
            # channels, so sum every axis except oc (axis 3) and flatten
            # og-major / oc-minor, which is exactly the absolute oc order.
            wsum  = wpad.astype(np.int64).sum(axis=(1, 2, 4)).reshape(-1)
            izp   = int(acts[src_of[tag]][1])                   # input zero point
            b_cor = b.astype(np.int64) - np.int64(izp) * wsum    # new bias
            if b_cor.min() < -(1 << 31) or b_cor.max() > (1 << 31) - 1:
                raise SystemExit('bias correction overflows int32 for %s' % tag)
            b_out = b_cor.astype(np.int32)
        w_blob.append(wpad.tobytes())
        b_blob.append(b_out.tobytes())
        s_blob.append(s.tobytes())
        off += wpad.size

    open(os.path.join(OUT, 'model_blob.bin'), 'wb').write(b''.join(w_blob))
    open(os.path.join(OUT, 'model_bias.bin'), 'wb').write(b''.join(b_blob))
    open(os.path.join(OUT, 'model_scale.bin'), 'wb').write(b''.join(s_blob))

    # bias / scale offsets
    boff = 0
    soff = 0
    for L in layout:
        L['boff'] = boff
        L['soff'] = soff
        boff += L['cout']
        soff += L['cout']

    # ---------------- per-channel (multiplier, shift) for requantisation ------
    # rm = in_scale * weight_scale / out_scale   -- identical to tflite's
    # QuantizeMultiplier() input, so the kernel just does the fixed-point MAC.
    # Order MUST match the call order inside cnn_top(): c1 c2 c3 c4 gap fc.
    # acts / src_of were defined at the top (the bias correction needs them).
    by_tag = {L0['tag']: L0 for L0 in layout}
    mmult_i, mshift_i = [], []
    m_layers = []
    m_off = 0
    for t in ('c1', 'c2', 'c3', 'c4', 'gap', 'fc'):
        if t == 'gap':
            # global average pooling: no weight scale, just divide by H*W (8x8)
            cout = by_tag['c4']['cout']
            rms = np.full(cout, np.float64(acts['c4'][0])
                          / (np.float64(8 * 8) * np.float64(acts['gap'][0])),
                          np.float64)
        else:
            cout = by_tag[t]['cout']
            rms = (np.float64(acts[src_of[t]][0])
                   * g[by_tag[t]['wk'] + '_scale'].astype(np.float64)
                   / np.float64(acts[t][0]))
        m_layers.append(dict(tag=t, off=m_off, n=cout))
        m_off += cout
        for rm in rms:
            q, e = quantize_multiplier(float(rm))
            mmult_i.append(q)
            mshift_i.append(e)
    mmult = np.array(mmult_i, np.int32)
    mshift = np.array(mshift_i, np.int32)
    if mmult.size != m_off:
        raise SystemExit('multiplier count %d != %d'
                         % (mmult.size, m_off))
    open(os.path.join(OUT, 'model_mmult.bin'), 'wb').write(mmult.tobytes())
    open(os.path.join(OUT, 'model_mshift.bin'), 'wb').write(mshift.tobytes())

    # ---------------- golden tensors for one fixed test vector -------------
    rng = np.random.default_rng(1234)
    x = rng.standard_normal((1, 64, 64, 3)).astype(np.float32)
    dump = {}
    logits = net.forward(x, dump)

    def save(name, arr):
        a = np.ascontiguousarray(arr)
        open(os.path.join(OUT, name), 'wb').write(a.tobytes())
        return a

    save('golden_in.bin',   dump['in_q'].astype(np.int8))
    save('golden_c1.bin',   dump['c1'])
    save('golden_p1.bin',   dump['p1'])
    save('golden_c2.bin',   dump['c2'])
    save('golden_p2.bin',   dump['p2'])
    save('golden_c3.bin',   dump['c3'])
    save('golden_p3.bin',   dump['p3'])
    save('golden_c4.bin',   dump['c4'])
    save('golden_gap.bin',  dump['gap'])
    save('golden_fc.bin',   dump['fc'])
    with open(os.path.join(OUT, 'golden_logits.txt'), 'w') as f:
        f.write(' '.join('%.6f' % v for v in logits) + '\n')

    # ---------------- C header ----------------
    L = []
    L.append('/* auto-generated by gen_data.py -- do not edit */')
    L.append('#ifndef MODEL_META_H')
    L.append('#define MODEL_META_H')
    L.append('')
    L.append('#define IMG_W       64')
    L.append('#define IMG_H       64')
    L.append('#define IMG_C       3')
    L.append('#define N_CLASS     6')
    L.append('')
    # per layer
    for L0 in layout:
        t = L0['tag']
        L.append('#define W_%s_OFF   %d' % (t, L0['off']))
        L.append('#define W_%s_N     %d' % (t, L0['n']))
        L.append('#define B_%s_OFF   %d' % (t, L0['boff']))
        L.append('#define S_%s_OFF   %d' % (t, L0['soff']))
        L.append('#define %s_CIN     %d' % (t.upper(), L0['cin']))
        L.append('#define %s_CINP    %d' % (t.upper(), L0['cinp']))
        L.append('#define %s_COUT    %d' % (t.upper(), L0['cout']))
        L.append('#define %s_WB      %d' % (t.upper(), L0['wb']))
        L.append('')
    # zero points + activation scales (float, used to build the multipliers)
    L.append('#define IN_SCALE    %.9ff' % net.q_in[0])
    L.append('#define IN_ZP       (%d)' % net.q_in[1])
    L.append('#define C1_SCALE    %.9ff' % net.q_c1[0])
    L.append('#define C1_ZP       (%d)' % net.q_c1[1])
    L.append('#define C2_SCALE    %.9ff' % net.q_c2[0])
    L.append('#define C2_ZP       (%d)' % net.q_c2[1])
    L.append('#define C3_SCALE    %.9ff' % net.q_c3[0])
    L.append('#define C3_ZP       (%d)' % net.q_c3[1])
    L.append('#define C4_SCALE    %.9ff' % net.q_c4[0])
    L.append('#define C4_ZP       (%d)' % net.q_c4[1])
    L.append('#define GAP_SCALE   %.9ff' % net.q_gap[0])
    L.append('#define GAP_ZP      (%d)' % net.q_gap[1])
    L.append('#define FC_SCALE    %.9ff' % net.q_fc[0])
    L.append('#define FC_ZP       (%d)' % net.q_fc[1])
    L.append('')
    L.append('#define W_BLOB_BYTES  %d' % off)
    L.append('#define B_BLOB_ITEMS  %d' % boff)
    L.append('#define S_BLOB_ITEMS  %d' % soff)
    # requantisation table: one entry per output channel, order c1 c2 c3 c4
    # gap fc -- differs from the bias order, so it gets its own offsets.
    for L0 in m_layers:
        L.append('#define M_%s_OFF   %d' % (L0['tag'], L0['off']))
        L.append('#define M_%s_N     %d' % (L0['tag'], L0['n']))
    L.append('')
    L.append('#define M_BLOB_ITEMS  %d' % m_off)
    L.append('')
    L.append('#endif')
    open(os.path.join(HERE, 'model_meta.h'), 'w').write('\n'.join(L) + '\n')

    print("build dir : %s" % OUT)
    print("weights   : %d B" % off)
    print("biases    : %d items" % boff)
    print("scales    : %d items" % soff)
    print("requant   : %d items (mult/shift)" % mmult.size)
    print("golden logits: %s" % ' '.join('%.6f' % v for v in logits))
    print("layer sizes:")
    for k in ('in_q', 'c1', 'p1', 'c2', 'p2', 'c3', 'p3', 'c4', 'gap', 'fc'):
        print("  %-4s %s" % (k, dump[k].shape))


if __name__ == '__main__':
    main()
