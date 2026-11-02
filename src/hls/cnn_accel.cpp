// ============================================================================
//  cnn_accel.cpp -- int8 CNN accelerator for the 64x64 garbage classifier
//                   (motion_count / 瀹炴椂鍨冨溇鍒嗙被璇嗗埆涓庤鏁扮郴缁?
//
//  Model : CONV3->POOL -> CONV3->POOL -> CONV3->POOL -> CONV3 -> GAP -> FC
//          64x64x3 -> 32x32x32 -> 16x16x64 -> 8x8x128 -> 8x8x256 -> 256 -> 6
//
//  Design decisions, each forced by a measured synthesis result:
//    * ONE conv engine serves all four layers (runtime descriptor table), so the
//      POC*PIC = 128-multiplier array exists once instead of four times (4 copies
//      = 512 DSP, far more than the 220 the device has).
//    * the weight tile holds only ONE input-channel block: [POC][3][3][PIC] =
//      576 B.  A full [POC][9][CINP] tile would be 9216 B and HLS always maps
//      that into flip-flops (73728 of them) because a memory needs more than 64
//      read ports -- which is 70% of the whole FF budget for one block of RAM.
//      With a 576 B tile the accumulators instead live in the int32 plane
//      g_acc, which is walked one input-channel block at a time.
//    * every activation tensor is stored WITH a 1-pixel zero-point border in the
//      arena, so the inner loop needs no boundary test.  A branch there makes
//      HLS refuse to pipeline ("control-flow is too complicated") and costs a
//      factor of ~20 in latency.
//    * pooling is fused into the requantisation pass and the max is taken on the
//      int32 accumulator: requantisation is monotone, so max-after and
//      max-before-requantisation are bit identical.
//    * nothing floating point, no frexp(): the per-channel tflite
//      (multiplier, shift) pairs are pre-computed by gen_data.py.
//
//  Bit-exactness: every layer reproduces the tflite int8 reference byte for
//  byte (verified by tb_cnn.cpp against golden_*.bin).
// ============================================================================
#include <stdint.h>
#include <ap_int.h>
#include "model_meta.h"

// ---------------------------------------------------------------- tuning knobs
// POC 8 -> 16 (v1.4).  Measured facts that forced this:
//   * the inner MAC loop already runs at II=1, but the whole kernel still took
//     22.96 ms while the MAC work alone is only 60.2 MMAC / 64 MAC-per-cycle
//     = ~1.03 M cycles (10.3 ms), so half the runtime was not arithmetic;
//   * the weight-load loop ran at II=64 because HLS refused to widen the int8
//     DDR reads (log: "Widen Fail ... max_widen_bitwidth threshold of 0"), which
//     alone cost 294,912 cycles (~2.9 ms) in conv4;
//   * the inner loop only used 34 DSP for 64 MAC (HLS already packs ~2 int8
//     MACs per DSP48E1), so doubling the array costs ~+34 DSP out of 161 free.
// Doubling POC halves the inner-loop iteration count (1,032,192 -> 516,096)
// with NO extra padding waste: conv1 keeps CINP=8 because CIN stays 3.
#define POC      16     // output channels computed in parallel
#define PIC      8      // input  channels computed in parallel
#define MAXCINP  128    // widest padded input channel count (= conv4)
// The weight tile is fetched from DDR as aligned 64-bit words instead of
// byte-by-byte: with byte accesses the load loop could only reach II=64 (and
// II=128 once POC went to 16), which cost ~0.39 M cycles = 3.9 ms of the 23 ms.
typedef ap_uint<64> WTQ;                          // one DDR beat of weights (8 bytes)
#define WTQ_PER_WORD (POC * PIC / 8)              // 64-bit words per tile word (= 16)

// ---------------------------------------------------------------- arena layout
// Each region holds a tensor PLUS a 1-pixel border of its zero point, so the
// conv can read (oy+kh, ox+kw) with kh,kw in 0..2 without any test.
//   input   66 x 66 x 3   = 13068  -> padded to 13072 (multiple of 8)
//   p1      34 x 34 x 32  = 36992
//   p2      18 x 18 x 64  = 20736
//   p3      10 x 10 x 128 = 12800
//   c4      10 x 10 x 256 = 25600
#define A_IN    0               // quantised input image + border      13072 B
#define A_P1    13072           // conv1 + relu + 2x2 max pool         36992 B
#define A_P2    50064           // conv2 + relu + 2x2 max pool         20736 B
#define A_P3    70800           // conv3 + relu + 2x2 max pool         12800 B
#define A_C4    83600           // conv4 + relu (no pool)              25600 B
#define A_END   109200          // total arena size

// ============================================================================
//  fixed point helpers -- byte-for-byte copies of the tflite semantics
// ============================================================================

// (a*b*2) >> 31, i.e. SaturatingRoundingDoublingHighMul(), with rounding and
// saturation.  This is the primitive tflite uses for requantisation.
static inline int32_t sat_round_double_high_mul(int32_t a, int32_t b)
{
    int64_t ab    = (int64_t)a * (int64_t)b;                         // exact 64-bit product
    int64_t nudge = (ab >= 0) ? (int64_t)(1 << 30)                    // round-half-up for >=0
                              : (int64_t)(1 - (1 << 30));             // round-half-away for <0
    int64_t r = (ab + nudge) / (int64_t)(1LL << 31);                  // divide by 2^31, truncating
    if (r > 2147483647LL)  r = 2147483647LL;                          // saturate high
    if (r < -2147483648LL) r = -2147483648LL;                         // saturate low
    return (int32_t)r;
}

// x / 2^exp with round-half-away-from-zero (tflite RoundingDivideByPOT).
static inline int32_t round_divide_by_pot(int32_t x, int exp)
{
    if (exp <= 0) return x;                                           // no shift requested
    int32_t mask      = (int32_t)((1 << exp) - 1);                    // low exp bits = remainder
    int32_t remainder = x & mask;                                     // what is being discarded
    int32_t threshold = (mask >> 1) + (x < 0 ? 1 : 0);                // half, biased for negatives
    return (x >> exp) + ((remainder > threshold) ? 1 : 0);            // shift then round up
}

// tflite MultiplyByQuantizedMultiplier(): x * 2^shift * multiplier / 2^31.
static inline int32_t mul_by_quant_mult(int32_t x, int32_t mul, int shift)
{
    int left  = (shift > 0) ? shift : 0;                              // positive shift -> pre-scale
    int right = (shift > 0) ? 0 : -shift;                             // negative shift -> post-shift
    int32_t xs = (int32_t)((int64_t)x * (int64_t)(1 << left));        // apply the left shift
    return round_divide_by_pot(sat_round_double_high_mul(xs, mul), right);
}

// int32 -> int8 with saturation.  Every activation zero point is -128, so this
// saturation IS the fused ReLU of the model.
static inline int8_t clamp_i8(int32_t v)
{
    if (v > 127)  return (int8_t)127;
    if (v < -128) return (int8_t)-128;
    return (int8_t)v;
}

// ============================================================================
//  On-chip buffers
//  Declared at file scope so the partitioning pragmas bind to one fixed variable
//  and the C testbench can inspect every layer without debug ports.
// ============================================================================
int8_t  g_arena[A_END];                   // 109200 B  activation tensors + borders
// NOTE: the int32 accumulator PLANE (g_acc, 131072 B) has been removed.  With
// the output-channel-stationary dataflow v5 the accumulators for one output
// pixel live in POC (=16) registers, so the plane and all of its BRAM traffic
// are gone.
// The three per-channel tables are small (486 + 742 + 742 int32 = 7.9 KB), so
// they are copied into BRAM once at the start.  Reading them straight from DDR
// inside the layer loop put an AXI address path on the critical path of a
// pipelined loop (synthesis reported slack 0.00) and cost ~1.3 ms of read
// latency stalls per inference.
int32_t g_bias[B_BLOB_ITEMS];             // per output channel, all layers
int32_t g_mmul[M_BLOB_ITEMS];             // requantisation multiplier
int32_t g_mshf[M_BLOB_ITEMS];             // requantisation shift
int8_t  g_gap[256];                       //    256 B  global average pool result
int8_t  g_out[6];                         //      6 B  logits (int8, internal)
int32_t g_out32[2];                       //      8 B  logits packed for the AXI write
                                          // [0] = cls0..3, [1] = cls4..5

// ============================================================================
//  Layer descriptor table -- this is what makes the conv engine reusable.
//  Order must match the pipeline: c1, c2, c3, c4.
// ============================================================================
static const int LAY_H   [4] = { 64, 32, 16,  8 };   // conv input/output height
static const int LAY_W   [4] = { 64, 32, 16,  8 };   // conv input/output width
static const int LAY_CIN [4] = { C1_CIN,  C2_CIN,  C3_CIN,  C4_CIN  };  // real channels
static const int LAY_CINP[4] = { C1_CINP, C2_CINP, C3_CINP, C4_CINP };  // padded channels
static const int LAY_COUT[4] = { C1_COUT, C2_COUT, C3_COUT, C4_COUT };  // out channels
static const int LAY_OH  [4] = { 32, 16,  8,  8 };   // stored output height
static const int LAY_OW  [4] = { 32, 16,  8,  8 };   // stored output width
static const int LAY_PIX [4] = {  2,  2,  2,  1 };   // conv pixels per stored pixel
static const int LAY_IOFF[4] = { A_IN, A_P1, A_P2, A_P3 };   // input region offset
static const int LAY_OOFF[4] = { A_P1, A_P2, A_P3, A_C4 };   // output region offset
static const int LAY_WOFF[4] = { W_c1_OFF, W_c2_OFF, W_c3_OFF, W_c4_OFF };  // weight blob
static const int LAY_WB  [4] = { C1_WB,   C2_WB,   C3_WB,   C4_WB   };  // bytes per oc
static const int LAY_BOFF[4] = { B_c1_OFF, B_c2_OFF, B_c3_OFF, B_c4_OFF };  // bias
static const int LAY_MOFF[4] = { M_c1_OFF, M_c2_OFF, M_c3_OFF, M_c4_OFF };  // mult
static const int LAY_IZP [4] = { IN_ZP, C1_ZP, C2_ZP, C3_ZP };  // input zero point
                                     // kept for documentation only -- it is folded
                                     // into model_bias.bin on the PC side, so the
                                     // MAC loop no longer subtracts it
static const int LAY_OZP [4] = { C1_ZP, C2_ZP, C3_ZP, C4_ZP };  // output zero point

// ============================================================================
//  Top level -- the only function that is synthesised
//    blob : int8 weights, tile-ordered   (layout in model_meta.h)
//    bias : int32 biases, concatenated
//    mmul : int32 requant multipliers, one per output channel
//    mshf : int32 requant shifts,      one per output channel
//    in   : int8 quantised image  [64][64][3]
//    out  : 4 int32 words.
//           out[0] = logits cls0..3, out[1] = logits cls4..5  (little endian)
//           out[2] = PHASE BEACON -- written at every stage boundary so the PS
//                    can sample it while the kernel runs and reconstruct a
//                    timeline of where the 55 ms actually goes.  HLS C cannot
//                    read a cycle counter, and cosim is far too slow (measured
//                    ~64 cycles/s), so this is the only practical profiler.
//           out[3] = spare
// ============================================================================
extern "C" void cnn_top(const int8_t  *blob,
                        const int32_t *bias,
                        const int32_t *mmul,
                        const int32_t *mshf,
                        const int8_t  *in,
                        int32_t       *out)
{
    // One single AXI4 master port (bundle=gmem) for all six buffers, plus one
    // AXI-Lite slave for control.  Keeping them separate would give the block
    // design six masters and six HP ports; bundling them costs one arbiter here
    // and leaves a single master port, while `offset=slave` still gives each
    // buffer its own base-address register in the AXI-Lite map.
    // NOTE: every port in one bundle must carry IDENTICAL adapter parameters
    // (latency / num_read_outstanding / max_read_burst_length), otherwise HLS
    // rejects the bundle with [HLS 214-215].  Only `depth` stays per-port.
#pragma HLS INTERFACE m_axi port=blob offset=slave bundle=gmem depth=W_BLOB_BYTES latency=64 num_read_outstanding=16 max_read_burst_length=256 max_widen_bitwidth=64
#pragma HLS INTERFACE m_axi port=bias offset=slave bundle=gmem depth=B_BLOB_ITEMS latency=64 num_read_outstanding=16 max_read_burst_length=256 max_widen_bitwidth=64
#pragma HLS INTERFACE m_axi port=mmul offset=slave bundle=gmem depth=M_BLOB_ITEMS latency=64 num_read_outstanding=16 max_read_burst_length=256 max_widen_bitwidth=64
#pragma HLS INTERFACE m_axi port=mshf offset=slave bundle=gmem depth=M_BLOB_ITEMS latency=64 num_read_outstanding=16 max_read_burst_length=256 max_widen_bitwidth=64
#pragma HLS INTERFACE m_axi port=in   offset=slave bundle=gmem depth=12288 latency=64 num_read_outstanding=16 max_read_burst_length=256 max_widen_bitwidth=64
#pragma HLS INTERFACE m_axi port=out  offset=slave bundle=gmem depth=4 latency=64 num_read_outstanding=16 max_read_burst_length=256 max_widen_bitwidth=64
#pragma HLS INTERFACE s_axilite port=return

    // ---- on-chip memory shaping -------------------------------------------
    // 8 banks so the POC=8 channels of a group are fetched in one cycle; every
    // region offset is a multiple of 8, so a group access hits 8 distinct banks.
#pragma HLS ARRAY_PARTITION variable=g_arena cyclic factor=POC

    // ---- 0a. copy the three per-channel tables into BRAM (one AXI burst each)
    for (int e = 0; e < B_BLOB_ITEMS; ++e) {
#pragma HLS PIPELINE II=1
        g_bias[e] = bias[e];
    }
    for (int e = 0; e < M_BLOB_ITEMS; ++e) {
#pragma HLS PIPELINE II=1
        g_mmul[e] = mmul[e];
    }
    for (int e = 0; e < M_BLOB_ITEMS; ++e) {
#pragma HLS PIPELINE II=1
        g_mshf[e] = mshf[e];
    }

    // ---- 0b. arena-wide zero-point fill: all conv borders become C1_ZP=-128
    for (int e = 0; e < A_END; e += PIC) {
#pragma HLS PIPELINE II=1
        for (int t = 0; t < PIC; ++t) {
#pragma HLS UNROLL
            g_arena[e + t] = (int8_t)(-128);
        }
    }

    // ---- 0c. the INPUT region border must be the input zero point (-12)
    for (int e = 0; e < A_P1; e += PIC) {
#pragma HLS PIPELINE II=1
        for (int t = 0; t < PIC; ++t) {
#pragma HLS UNROLL
            g_arena[e + t] = (int8_t)IN_ZP;
        }
    }

    // ---- 0d. copy the 64x64x3 image into the interior of the padded region.
    // One source row is 64*3 = 192 bytes and is contiguous in BOTH layouts.
    for (int y = 0; y < 64; ++y) {
        const int so  = y * 192;                          // source row offset
        const int dof = A_IN + ((y + 1) * 66 + 1) * 3;    // dest row offset (+ border)
        for (int e = 0; e < 192; e += PIC) {
#pragma HLS PIPELINE II=1
            for (int t = 0; t < PIC; ++t) {
#pragma HLS UNROLL
                g_arena[dof + e + t] = in[so + e + t];
            }
        }
    }

    // ========================================================================
    //  1..4  the four conv layers, all served by this one engine
    // ========================================================================
    // PROFILER: beacon 1 = input copy done.  The PS samples out[2] while the
    // kernel runs and turns the sequence of codes into a wall-clock timeline.
    out[2] = 1;

    for (int l = 0; l < 4; ++l) {
#pragma HLS LOOP_TRIPCOUNT min=4 max=4

        out[2] = 100 + l;                                    // PROFILER: layer l begins

        const int H    = LAY_H   [l];        // conv output height
        const int W    = LAY_W   [l];        // conv output width
        const int CIN  = LAY_CIN [l];        // real input channels (may be < CINP)
        const int CINP = LAY_CINP[l];        // padded input channels
        const int COUT = LAY_COUT[l];        // output channels
        const int OH   = LAY_OH  [l];        // stored output height
        const int OW   = LAY_OW  [l];        // stored output width
        const int PIX  = LAY_PIX [l];        // conv pixels per stored output pixel
        const int NPI  = CINP / PIC;         // input channel blocks
        const int IOF  = LAY_IOFF[l];        // arena offset of the input tensor
        const int OOF  = LAY_OOFF[l];        // arena offset of the output tensor
        const int IW2  = W + 2;              // padded row stride of the input
        const int OW2  = OW + 2;             // padded row stride of the output
        // (the input zero point of this layer is NOT needed here any more: it is
        //  folded into the bias array by gen_data.py -- see LAY_IZP's note)
        const int ozp  = LAY_OZP [l];        // output zero point
        const int WB   = LAY_WB  [l];        // weight bytes per output channel

        // Byte offset of each of the 9 taps inside a row-padded tensor, ALREADY
        // multiplied by CIN.  Built once per layer (constant trip count -> 9
        // registers).  Pre-multiplying here is what keeps a runtime multiplier
        // off the address path of the pipelined inner loop: the loop then only
        // needs a 9-way mux plus adds.
        int relb[9];
#pragma HLS ARRAY_PARTITION variable=relb complete
        for (int kk = 0; kk < 9; ++kk) {
#pragma HLS UNROLL
            relb[kk] = ((kk / 3) * IW2 + (kk % 3)) * CIN;
        }

        for (int og = 0; og < COUT / POC; ++og) {

            // ---- 1a. this group's bias / multiplier / shift -> registers ----
            int32_t bg[POC];                                 // bias per channel
            int32_t mg[POC];                                 // multiplier per channel
            int32_t sg[POC];                                 // shift per channel
#pragma HLS ARRAY_PARTITION variable=bg complete
#pragma HLS ARRAY_PARTITION variable=mg complete
#pragma HLS ARRAY_PARTITION variable=sg complete
            for (int j = 0; j < POC; ++j) {
                bg[j] = g_bias[LAY_BOFF[l] + og * POC + j];   // on-chip, no AXI
                mg[j] = g_mmul[LAY_MOFF[l] + og * POC + j];
                sg[j] = g_mshf[LAY_MOFF[l] + og * POC + j];
            }

            // ---- 1b. load this group's WHOLE weight block into block RAM ----
            // wblk[oc][tap][ic] = 9*CINP bytes per output channel (conv4: 9216 B
            // for the whole group).  Holding ALL input channels on chip is what
            // lets the accumulator stay in registers (section 1c) instead of a
            // BRAM plane -- that plane was 83% of the runtime before.
            // 8 banks (one per oc) x 8-byte words => 8 parallel 64-bit reads per
            // cycle feed the 64 MACs.  BIND_STORAGE forces block RAM: without it
            // HLS maps this shape into 73728 flip-flops.
            // ONE contiguous array, no partitioning: after a complete partition
            // the sub-arrays become scalars and BIND_STORAGE is silently ignored
            // (that is what pushed this block into 73728 flip-flops).  Layout is
            // [tap][ic-block][64] so a single 512-bit word holds POC*PIC weights.
            // One 1024-bit word holds POC*PIC = 128 weights, so the block is read
            // with a SINGLE BRAM port per cycle -- no replication.  Declaring the
            // element type as ap_uint<POC*PIC*8> avoids HLS's 128-bit reshape limit
            // (with ARRAY_RESHAPE the same block was widened only to 128 bits and
            // then replicated for the parallel reads, giving BRAM 119%).
            ap_uint<POC * PIC * 8> wblk[9][MAXCINP / PIC];
#pragma HLS BIND_STORAGE variable=wblk type=RAM_2P impl=BRAM

            for (int kk = 0; kk < 9; ++kk) {
                // per (og,tap) sub-block is POC*CINP bytes, laid out [ib][oc][ic]
                const int8_t *src = blob + LAY_WOFF[l] + (og * 9 + kk) * (POC * CINP);
                for (int w = 0; w < NPI; ++w) {
#pragma HLS PIPELINE II=1
                    // Read the POC*PIC = 128 B tile as WTQ_PER_WORD aligned 64-bit
                    // words.  Reading it byte-by-byte made the single m_axi port
                    // serve 128 separate byte operations, so the loop could not go
                    // below II=128 -- that was 0.39 M cycles (~3.9 ms) of the run
                    // time, i.e. 17% of the whole inference.
                    const WTQ *wsrc = reinterpret_cast<const WTQ *>(src) + w * WTQ_PER_WORD;
                    ap_uint<POC * PIC * 8> tmp;              // the whole tile word
                    for (int t = 0; t < WTQ_PER_WORD; ++t) {
#pragma HLS UNROLL
                        tmp.range((t + 1) * 64 - 1, t * 64) = wsrc[t];
                    }
                    wblk[kk][w] = tmp;
                }
            }

            // ---- 1c. one stored output pixel at a time, acc in registers -----
            for (int ob = 0; ob < OH * OW; ++ob) {
                const int orow = ob / OW;                    // stored output row
                const int ocol = ob % OW;                    // stored output column
                const int prow = (PIX > 1) ? (orow * 2) : orow;
                const int pcol = (PIX > 1) ? (ocol * 2) : ocol;

                int32_t amax[POC];                           // max over the pool window
#pragma HLS ARRAY_PARTITION variable=amax complete
                for (int j = 0; j < POC; ++j) amax[j] = -2147483647 - 1;

                for (int dh = 0; dh < PIX; ++dh) {           // pool row
#pragma HLS LOOP_TRIPCOUNT min=1 max=2
                    for (int dw = 0; dw < PIX; ++dw) {       // pool column
#pragma HLS LOOP_TRIPCOUNT min=1 max=2
                        const int oy = prow + dh;            // conv output row
                        const int ox = pcol + dw;            // conv output column
                        const int obase = IOF + (oy * IW2 + ox) * CIN;

                        int32_t acc0[POC];                   // ic low half
                        int32_t acc1[POC];                   // ic high half
#pragma HLS ARRAY_PARTITION variable=acc0 complete
#pragma HLS ARRAY_PARTITION variable=acc1 complete
                        for (int j = 0; j < POC; ++j) {
                            acc0[j] = 0;                     // fresh pixel
                            acc1[j] = 0;
                        }

                        // (tap, input-block) flattened, advanced by selects so
                        // the body stays branch-free and pipelines at II=1.
                        int kk = 0;
                        int ib = 0;
                        for (int e = 0; e < 9 * NPI; ++e) {
#pragma HLS PIPELINE II=1
                            const int base = obase + relb[kk] + ib * PIC;

                            int8_t iv[PIC];                  // PIC activations
#pragma HLS ARRAY_PARTITION variable=iv complete
                            for (int t = 0; t < PIC; ++t)
                                iv[t] = g_arena[base + t];    // one wide word

                            const ap_uint<POC * PIC * 8> wv = wblk[kk][ib];  // ONE read
                            for (int j = 0; j < POC; ++j) {          // POC parallel
#pragma HLS UNROLL
                                for (int t = 0; t < PIC / 2; ++t) {  // x PIC = 64 MAC
#pragma HLS UNROLL
                                    // no "- izp": folded into the bias on the PC
                                    acc0[j] += (int32_t)iv[t] * (int32_t)
                                        (int8_t)wv.range(((j * PIC + t) * 8) + 7,
                                                          (j * PIC + t) * 8);
                                    acc1[j] += (int32_t)iv[t + PIC / 2] * (int32_t)
                                        (int8_t)wv.range(((j * PIC + t + PIC / 2) * 8) + 7,
                                                          (j * PIC + t + PIC / 2) * 8);
                                }
                            }

                            const int ni = ib + 1;
                            const bool wrp = (ni == NPI);
                            ib = wrp ? 0 : ni;
                            kk = kk + (wrp ? 1 : 0);
                        }

                        for (int j = 0; j < POC; ++j) {              // bias + pool max
#pragma HLS UNROLL
                            const int32_t s = acc0[j] + acc1[j] + bg[j];
                            if (s > amax[j]) amax[j] = s;
                        }
                    }
                }

                // ---- 1d. requantise once per stored pixel -------------------
                // Requantisation is monotone, so max-before == max-after and the
                // max above is bit-identical to pooling the int8 values.
                const int oob = OOF + ((orow + 1) * OW2 + (ocol + 1)) * COUT;
                for (int j = 0; j < POC; ++j) {
#pragma HLS UNROLL factor=2
                    g_arena[oob + og * POC + j] =
                        clamp_i8(mul_by_quant_mult(amax[j], mg[j], sg[j]) + ozp);
                }
            }
        }
    }

    // ========================================================================
    //  5. global average pool 8x8x256 -> 256 (POC channels at a time)
    //    c4 is stored with a border, so its row stride is 10 pixels.
    // ========================================================================
    out[2] = 2;                                              // PROFILER: all conv layers done

    for (int c0 = 0; c0 < 256; c0 += POC) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=32
        int32_t s[POC];
#pragma HLS ARRAY_PARTITION variable=s complete
        for (int j = 0; j < POC; ++j) s[j] = 0;              // clear the sums
        for (int p = 0; p < 64; ++p) {                       // 8x8 = 64 real pixels
#pragma HLS PIPELINE II=1
            const int pob = A_C4 + ((p / 8 + 1) * 10 + (p % 8 + 1)) * 256;
            for (int j = 0; j < POC; ++j) {                  // POC parallel adds
#pragma HLS UNROLL
                s[j] += (int32_t)g_arena[pob + c0 + j] - C4_ZP;
            }
        }
        for (int j = 0; j < POC; ++j) {                      // mean + requantise
#pragma HLS UNROLL
            g_gap[c0 + j] = clamp_i8(mul_by_quant_mult(s[j],
                                        g_mmul[M_gap_OFF + c0 + j],
                                        g_mshf[M_gap_OFF + c0 + j]) + GAP_ZP);
        }
    }

    // ========================================================================
    //  6. fully connected 256 -> 6  (one MAC per cycle: 6*256 = 1536 cycles)
    // ========================================================================
    out[2] = 3;                                              // PROFILER: GAP done

    for (int oc = 0; oc < 6; ++oc) {
        int32_t s = 0;                                       // dot product accumulator
        for (int ic = 0; ic < 256; ++ic) {
#pragma HLS PIPELINE II=1
            s += ((int32_t)g_gap[ic] - GAP_ZP)               // centred activation
               * (int32_t)blob[W_fc_OFF + oc * 256 + ic];    // int8 weight
        }
        s += g_bias[B_fc_OFF + oc];                          // int32 bias (on-chip)
        g_out[oc] = clamp_i8(mul_by_quant_mult(s,
                                    g_mmul[M_fc_OFF + oc],
                                    g_mshf[M_fc_OFF + oc]) + FC_ZP);   // final logit
    }

    // ========================================================================
    //  7. pack the 6 int8 logits into 2 words and write them back to DDR
    // ========================================================================
    out[2] = 4;                                              // PROFILER: FC done
    g_out32[0] = (uint32_t)(uint8_t)g_out[0]
               | ((uint32_t)(uint8_t)g_out[1] << 8)
               | ((uint32_t)(uint8_t)g_out[2] << 16)
               | ((uint32_t)(uint8_t)g_out[3] << 24);
    g_out32[1] = (uint32_t)(uint8_t)g_out[4]
               | ((uint32_t)(uint8_t)g_out[5] << 8);

    for (int i6 = 0; i6 < 2; ++i6) {          // two full-width aligned beats
#pragma HLS LOOP_TRIPCOUNT min=2 max=2
#pragma HLS PIPELINE II=4
        out[i6] = g_out32[i6];
    }
}
