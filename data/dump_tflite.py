# -*- coding: utf-8 -*-
"""
dump_tflite.py -- parse a .tflite flatbuffer WITHOUT tensorflow.
Purpose: extract, for every operator, its tensors / weights / biases /
         per-channel scale & zero_point, and save them to weights.npz.
This npz is the single source of truth for:
   (1) the numpy reference implementation (golden model), and
   (2) the HLS ROM initialisation of the PL CNN accelerator.

Usage:  python dump_tflite.py <model.tflite> [out.npz]
"""
import struct
import sys
import os
import numpy as np

# ---------------------------------------------------------------- byte access
class FB(object):
    def __init__(self, buf):
        self.b = buf

    def u8(self, o):
        return self.b[o]

    def i8(self, o):
        return struct.unpack_from('<b', self.b, o)[0]

    def u16(self, o):
        return struct.unpack_from('<H', self.b, o)[0]

    def u32(self, o):
        return struct.unpack_from('<I', self.b, o)[0]

    def i32(self, o):
        return struct.unpack_from('<i', self.b, o)[0]

    def i64(self, o):
        return struct.unpack_from('<q', self.b, o)[0]

    def f32(self, o):
        return struct.unpack_from('<f', self.b, o)[0]

    # ---- flatbuffer table helpers -------------------------------------
    def field(self, t, i):
        """absolute offset of field i of table t, or None"""
        vt = t - self.i32(t)                 # vtable position
        vtlen = self.u16(vt)                 # vtable length in bytes
        o = 4 + 2 * i                        # slot inside vtable
        if o >= vtlen:
            return None
        off = self.u16(vt + o)               # offset from table start
        return None if off == 0 else t + off

    def table(self, t, i):
        """absolute offset of the sub-table in field i, or None"""
        f = self.field(t, i)
        return None if f is None else f + self.u32(f)

    def vec(self, t, i):
        """(count, data_offset) of the vector in field i"""
        f = self.field(t, i)
        if f is None:
            return 0, 0
        v = f + self.u32(f)
        return self.u32(v), v + 4

    def str(self, t, i):
        f = self.field(t, i)
        if f is None:
            return None
        v = f + self.u32(f)
        n = self.u32(v)
        return self.b[v + 4:v + 4 + n].decode('utf-8', 'replace')

    def su32(self, t, i):
        f = self.field(t, i)
        return None if f is None else self.u32(f)

    def si32(self, t, i):
        f = self.field(t, i)
        return None if f is None else self.i32(f)

    def si8(self, t, i):
        f = self.field(t, i)
        return None if f is None else self.i8(f)

    def su8(self, t, i):
        f = self.field(t, i)
        return None if f is None else self.u8(f)

    def table_at(self, vdata, k):
        p = vdata + 4 * k
        return p + self.u32(p)

    def bytes_at(self, t, i):
        """vector of ubyte -> python bytes"""
        f = self.field(t, i)
        if f is None:
            return b''
        v = f + self.u32(f)
        n = self.u32(v)
        return self.b[v + 4:v + 4 + n]


# ---------------------------------------------------------------- enums
TENSOR_TYPE = {0: 'float32', 1: 'float16', 2: 'int32', 3: 'uint8',
               4: 'int64', 5: 'string', 6: 'bool', 9: 'int8',
               10: 'int16', 12: 'uint32'}

BUILTIN = {0: 'ADD', 1: 'AVERAGE_POOL_2D', 2: 'CONCATENATION', 3: 'CONV_2D',
           4: 'DEPTHWISE_CONV_2D', 6: 'DEQUANTIZE', 9: 'FULLY_CONNECTED',
           17: 'MAX_POOL_2D', 18: 'MUL', 19: 'RELU', 20: 'RELU_N1_TO_1',
           21: 'RELU6', 22: 'RESHAPE', 25: 'SOFTMAX', 28: 'SUB',
           40: 'MEAN', 114: 'QUANTIZE'}

ACT = {0: 'NONE', 1: 'RELU', 2: 'RELU_N1_TO_1', 3: 'RELU6'}
PAD = {0: 'SAME', 1: 'VALID'}

NP_DTYPE = {'float32': np.float32, 'int8': np.int8, 'uint8': np.uint8,
            'int32': np.int32, 'int64': np.int64}


# ---------------------------------------------------------------- main
def main():
    src = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), 'model_int8_64.tflite')
    dst = sys.argv[2] if len(sys.argv) > 2 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), 'weights.npz')

    buf = open(src, 'rb').read()
    fb = FB(buf)
    print("file   : %s" % src)
    print("size   : %d bytes" % len(buf))
    print("magic  : %s" % buf[4:8].decode('latin1'))
    assert buf[4:8] == b'TFL3', "not a tflite flatbuffer"

    root = fb.u32(0)

    # ---- operator codes -------------------------------------------------
    n_oc, oc_v = fb.vec(root, 1)
    codes = []
    for k in range(n_oc):
        t = fb.table_at(oc_v, k)
        dep = fb.si8(t, 0)          # deprecated_builtin_code is int8 !
        cus = fb.str(t, 1)
        bc = fb.si32(t, 3)
        v = bc if (bc is not None and bc != 0) else (dep or 0)
        codes.append(BUILTIN.get(v, 'OP%d' % v))
    print("opcode : %s" % ', '.join(codes))

    # ---- buffers --------------------------------------------------------
    n_buf, buf_v = fb.vec(root, 4)

    def buffer_bytes(idx):
        if idx is None or idx >= n_buf:
            return b''
        t = fb.table_at(buf_v, idx)
        return fb.bytes_at(t, 0)

    # ---- subgraph 0 -----------------------------------------------------
    n_sg, sg_v = fb.vec(root, 2)
    sg = fb.table_at(sg_v, 0)
    print("subgraph count : %d" % n_sg)

    n_t, t_v = fb.vec(sg, 0)
    tensors = []
    for k in range(n_t):
        t = fb.table_at(t_v, k)
        ns, sh_v = fb.vec(t, 0)
        shape = [fb.i32(sh_v + 4 * j) for j in range(ns)]
        ty = TENSOR_TYPE.get(fb.su8(t, 1), '?')   # Tensor.type is a 1-byte enum !
        bidx = fb.su32(t, 2)
        name = fb.str(t, 3) or ''
        scales, zps, qdim = [], [], None
        qt = fb.table(t, 4)
        if qt is not None:
            nsc, sc_v = fb.vec(qt, 2)
            scales = [fb.f32(sc_v + 4 * j) for j in range(nsc)]
            nzp, zp_v = fb.vec(qt, 3)
            zps = [fb.i64(zp_v + 8 * j) for j in range(nzp)]
            qdim = fb.si32(qt, 6)
        tensors.append(dict(idx=k, name=name, shape=shape, type=ty,
                            bidx=bidx, scales=scales, zps=zps, qdim=qdim))

    # ---- operators ------------------------------------------------------
    n_op, op_v = fb.vec(sg, 3)
    ops = []
    for k in range(n_op):
        t = fb.table_at(op_v, k)
        oi = fb.si32(t, 0) or 0
        ni, in_v = fb.vec(t, 1)
        ins = [fb.i32(in_v + 4 * j) for j in range(ni)]
        no, out_v = fb.vec(t, 2)
        outs = [fb.i32(out_v + 4 * j) for j in range(no)]
        bot = fb.si32(t, 3)
        ops.append(dict(name=codes[oi], ins=ins, outs=outs, bot=bot,
                        opts=fb.table(t, 4)))

    def tstr(i):
        if i < 0:
            return '-'
        x = tensors[i]
        return "%s%s" % (x['name'] or '?', x['shape'])

    print("\n================ OPERATORS ================")
    for k, op in enumerate(ops):
        print("[%02d] %-16s  in=%-42s out=%s" %
              (k, op['name'], tstr(op['ins'][0]), tstr(op['outs'][0])))
        extra = []
        if op['name'] in ('CONV_2D', 'DEPTHWISE_CONV_2D'):
            o = op['opts']
            if o is not None:
                extra.append('pad=%s' % PAD.get(fb.si32(o, 0), '?'))
                extra.append('stride=%dx%d' % (fb.si32(o, 1) or 1,
                                               fb.si32(o, 2) or 1))
                extra.append('act=%s' % ACT.get(fb.si32(o, 3) or 0, '?'))
        elif op['name'] == 'MAX_POOL_2D':
            o = op['opts']
            if o is not None:
                extra.append('k=%dx%d' % (fb.si32(o, 3) or 2,
                                          fb.si32(o, 4) or 2))
                extra.append('stride=%dx%d' % (fb.si32(o, 1) or 2,
                                               fb.si32(o, 2) or 2))
                extra.append('pad=%s' % PAD.get(fb.si32(o, 0), '?'))
        elif op['name'] == 'FULLY_CONNECTED':
            o = op['opts']
            if o is not None:
                extra.append('act=%s' % ACT.get(fb.si32(o, 0) or 0, '?'))
        elif op['name'] == 'MEAN':
            o = op['opts']
            if o is not None:
                extra.append('keep_dims=%d' % (fb.si32(o, 0) or 0))
        if extra:
            print("     %s" % '  '.join(extra))
        for j, ti in enumerate(op['ins']):
            x = tensors[ti]
            s = x['scales'][:2]
            z = x['zps'][:2]
            nb = len(buffer_bytes(x['bidx']))
            if nb:
                print("     in%-2d W/B %-10s shape=%-16s n=%d/%d scale=%s zp=%s"
                      % (j, x['type'], x['shape'], len(x['scales']),
                         nb, s, z))

    # ---- save npz -------------------------------------------------------
    out = {}
    for k, op in enumerate(ops):
        tag = "%02d_%s" % (k, op['name'].lower())
        for j, ti in enumerate(op['ins']):
            if ti < 0:
                continue
            x = tensors[ti]
            raw = buffer_bytes(x['bidx'])
            if not raw:
                continue
            dt = NP_DTYPE.get(x['type'])
            if dt is None:
                continue
            arr = np.frombuffer(raw, dtype=dt)
            n = int(np.prod(x['shape'])) if x['shape'] else arr.size
            if arr.size != n:
                print("!! %s in%d size mismatch %d vs %d" % (tag, j, arr.size, n))
                continue
            out["%s_in%d" % (tag, j)] = arr.reshape(x['shape']).copy()
            if x['scales']:
                out["%s_in%d_scale" % (tag, j)] = np.array(x['scales'], np.float32)
                out["%s_in%d_zp" % (tag, j)] = np.array(x['zps'], np.int32)
        # also record the output quant params (needed for requantisation)
        for j, ti in enumerate(op['outs']):
            x = tensors[ti]
            if x['scales']:
                out["%s_out%d_scale" % (tag, j)] = np.array(x['scales'], np.float32)
                out["%s_out%d_zp" % (tag, j)] = np.array(x['zps'], np.int32)
                out["%s_out%d_qdim" % (tag, j)] = np.array([x['qdim'] or 0], np.int32)

    np.savez_compressed(dst, **out)
    print("\nsaved %d arrays -> %s (%.1f KB)" %
          (len(out), dst, os.path.getsize(dst) / 1024.0))


if __name__ == '__main__':
    main()
