// ============================================================================
//  tb_cnn.cpp -- C testbench for the int8 CNN accelerator
//
//  Loads the exported model + one fixed golden test vector, runs cnn_top() and
//  compares EVERY on-chip layer buffer against the numpy/tflite reference.
//  The activation arena and the logits are file-scope globals of cnn_accel.cpp,
//  so the kernel needs no debug ports at all.
//
//  Pass criterion: mismatch = 0 on every layer (bit exact).
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "model_meta.h"

// golden_*.bin 所在目录。默认假设 csim 的 work_dir 在 <包>/src/hls/work_v6，
// 即相对当前目录往上三级到包根，再进 data/csim。
// 若换 work_dir 或用绝对路径，用 -DDATADIR="<路径>" 覆盖。
#ifndef DATADIR
#define DATADIR "../../../data/csim"
#endif

// arena regions (must match cnn_accel.cpp)
#define A_IN    0
#define A_P1    13072
#define A_P2    50064
#define A_P3    70800
#define A_C4    83600

// the production entry point (out = 2 packed int32 words)
extern "C" void cnn_top(const int8_t  *blob,
                        const int32_t *bias,
                        const int32_t *mmul,
                        const int32_t *mshf,
                        const int8_t  *in,
                        int32_t       *out);

// on-chip buffers defined in cnn_accel.cpp
extern int8_t g_arena[];
extern int8_t g_gap[256];
extern int8_t g_out[6];

// a file into a malloc'd buffer, returns 1 on success
static int load(const char *name, void *dst, size_t n)
{
    char path[1024];                                            // full path of the file
    sprintf(path, "%s/%s", DATADIR, name);                      // build it from the data dir
    FILE *f = fopen(path, "rb");                                // open binary for reading
    if (!f) { printf("!! cannot open %s\n", path); return 0; }  // missing data set
    size_t got = fread(dst, 1, n, f);                           // read exactly n bytes
    fclose(f);                                                  // done with the file
    if (got != n) {                                             // wrong size -> mismatch
        printf("!! %s: read %zu of %zu bytes\n", name, got, n);
        return 0;                                               // report failure
    }
    return 1;                                                   // success
}

// compare one PADDED layer against its golden tensor, 1 = identical.
// The accelerator stores every tensor with a 1-pixel border, so the interior is
// rows x cols x ch values at stride pcols per row, starting one pixel in.
static int cmp_pad(const char *tag, const int8_t *base, int rows, int cols,
                   int ch, int pcols, const int8_t *ref)
{
    size_t bad = 0;                                            // number of differing elements
    int    maxd = 0;                                           // largest absolute difference
    for (int r = 0; r < rows; ++r) {                           // row by row
        const int8_t *g = base + ((r + 1) * pcols + 1) * ch;    // skip the border
        const int8_t *f = ref + (size_t)r * cols * ch;          // golden row
        for (int i = 0; i < cols * ch; ++i) {                   // all pixels of the row
            int d = (int)g[i] - (int)f[i];                      // signed difference
            if (d != 0) { ++bad; if (abs(d) > maxd) maxd = abs(d); }  // track worst case
        }
    }
    printf("  %-4s n=%7zu  mismatch=%8zu  maxdiff=%3d  %s\n",
           tag, (size_t)rows * cols * ch, bad, maxd, bad ? "FAIL" : "OK");
    return bad == 0;                                            // pass only when exact
}

// compare one flat tensor against its golden copy, 1 = identical
static int cmp(const char *tag, const int8_t *got, const int8_t *ref, size_t n)
{
    size_t bad = 0;                                             // number of differing elements
    int    maxd = 0;                                            // largest absolute difference
    for (size_t i = 0; i < n; ++i) {                            // scan the whole tensor
        int d = (int)got[i] - (int)ref[i];                      // signed difference
        if (d != 0) { ++bad; if (abs(d) > maxd) maxd = abs(d); } // track worst case
    }
    printf("  %-4s n=%7zu  mismatch=%8zu  maxdiff=%3d  %s\n",
           tag, n, bad, maxd, bad ? "FAIL" : "OK");             // one line per layer
    return bad == 0;                                            // pass only when exact
}

int main()
{
    printf("=== cnn_accel C testbench ===\n");
    printf("data dir : %s\n", DATADIR);

    int8_t  *blob  = (int8_t  *)malloc(W_BLOB_BYTES);                     // int8 weights
    int32_t *bias  = (int32_t *)malloc(B_BLOB_ITEMS * sizeof(int32_t));   // int32 biases
    int32_t *mmul  = (int32_t *)malloc(M_BLOB_ITEMS * sizeof(int32_t));   // requant mult
    int32_t *mshf  = (int32_t *)malloc(M_BLOB_ITEMS * sizeof(int32_t));   // requant shifts
    int8_t  *in    = (int8_t  *)malloc(64 * 64 * 3);                      // quantised image
    int32_t  out32[4];                                                    // logits + beacon
    int8_t   out[6];                                                      // unpacked logits

    int8_t *g_in_f  = (int8_t *)malloc(64 * 64 * 3);                      // golden input
    int8_t *g_p1_f  = (int8_t *)malloc(32 * 32 * 32);                     // golden pool1
    int8_t *g_p2_f  = (int8_t *)malloc(16 * 16 * 64);                     // golden pool2
    int8_t *g_p3_f  = (int8_t *)malloc(8 * 8 * 128);                      // golden pool3
    int8_t *g_c4_f  = (int8_t *)malloc(8 * 8 * 256);                      // golden conv4
    int8_t *g_gap_f = (int8_t *)malloc(256);                              // golden gap
    int8_t *g_fc_f  = (int8_t *)malloc(N_CLASS);                          // golden logits

    int ok = 1;                                                           // load status
    ok &= load("model_blob.bin",   blob,  W_BLOB_BYTES);                  // weights
    ok &= load("model_bias.bin",   bias,  B_BLOB_ITEMS * sizeof(int32_t));// biases
    ok &= load("model_mmult.bin",  mmul,  M_BLOB_ITEMS * sizeof(int32_t));// multipliers
    ok &= load("model_mshift.bin", mshf,  M_BLOB_ITEMS * sizeof(int32_t));// shifts
    ok &= load("golden_in.bin",    g_in_f,  64 * 64 * 3);                 // input vector
    ok &= load("golden_p1.bin",    g_p1_f,  32 * 32 * 32);                // after conv1+pool
    ok &= load("golden_p2.bin",    g_p2_f,  16 * 16 * 64);                // after conv2+pool
    ok &= load("golden_p3.bin",    g_p3_f,  8 * 8 * 128);                 // after conv3+pool
    ok &= load("golden_c4.bin",    g_c4_f,  8 * 8 * 256);                 // after conv4
    ok &= load("golden_gap.bin",   g_gap_f, 256);                         // after GAP
    ok &= load("golden_fc.bin",    g_fc_f,  N_CLASS);                     // final logits
    if (!ok) { printf("!! data loading failed\n"); return 1; }            // nothing to test

    memcpy(in, g_in_f, 64 * 64 * 3);        // same quantised image as the golden run

    printf("\nrunning cnn_top ...\n");
    cnn_top(blob, bias, mmul, mshf, in, out32);

    for (int i = 0; i < 4; ++i)                                           // unpack word 0
        out[i] = (int8_t)((out32[0] >> (8 * i)) & 0xFF);
    for (int i = 0; i < 2; ++i)                                           // unpack word 1
        out[4 + i] = (int8_t)((out32[1] >> (8 * i)) & 0xFF);

    printf("\nper-layer comparison (got vs golden):\n");
    int pass = 1;                                                         // overall result
    pass &= cmp_pad("in",  g_arena + A_IN, 64, 64,  3, 66,  g_in_f);      // input copy
    pass &= cmp_pad("p1",  g_arena + A_P1, 32, 32, 32, 34,  g_p1_f);      // conv1 + pool
    pass &= cmp_pad("p2",  g_arena + A_P2, 16, 16, 64, 18,  g_p2_f);      // conv2 + pool
    pass &= cmp_pad("p3",  g_arena + A_P3,  8,  8,128, 10,  g_p3_f);      // conv3 + pool
    pass &= cmp_pad("c4",  g_arena + A_C4,  8,  8,256, 10,  g_c4_f);      // conv4
    pass &= cmp("gap", g_gap,          g_gap_f, 256);                     // global average
    pass &= cmp("fc",  g_out,          g_fc_f,  N_CLASS);                 // logits

    printf("\nlogits(int8) :");                                           // raw int8 output
    for (int i = 0; i < N_CLASS; ++i) printf(" %4d", out[i]);
    printf("\nlogits(float):");                                           // dequantised
    for (int i = 0; i < N_CLASS; ++i)
        printf(" %9.4f", (out[i] - FC_ZP) * FC_SCALE);

    FILE *lf = fopen(DATADIR "/golden_logits.txt", "r");                  // reference logits
    if (lf) {
        float v; printf("\nexpected     :");
        while (fscanf(lf, "%f", &v) == 1) printf(" %9.4f", v);            // print as stored
        printf("\n"); fclose(lf);
    }

    printf("\n==== %s ====\n", pass ? "PASS (bit-exact on every layer)"
                                    : "FAIL");                            // final verdict
    return pass ? 0 : 1;                                                  // exit code
}
