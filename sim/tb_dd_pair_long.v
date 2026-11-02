//////////////////////////////////////////////////////////////////////////////
// tb_dd_pair_long.v —— dd_pair v4 的【长帧长 + 长跑 + 双判据】仿真
//
//   相比上一版（BN=256 / 20 帧）的放大：
//     · 帧长 256 → **4096**，消除帧 8 → **256**
//     · 跑 12 帧；逐像素比对 12×4096 = **49152 条**
//
//   【★ 两条判据（第二条是这次新加的，补上了上一版的盲点）】
//     判据 1（数据值）：`out_b_pix === n[7:0]`  ← B 的数据就是它的帧内序号
//        ⇒ 直接回答"这一拍配上的到底是不是第 n 个"
//        ⚠️ 盲点：数据只有 8 位 ⇒ **落后 256 个像素的错位看不出来** ✗
//     判据 2（数量不变式，★ 新加）：TB 侧独立数"一共被接收了多少个 B beat"（txn），
//        在每一帧的第一个像素处校验 **`(txn−1) mod BN == 0`**
//        ⇒ 含义 = "进入本帧之前，累计消费的 beat 数必须是帧长的整数倍"
//        ⇒ **任何尺度的多配/少配都会被抓住**（不受 8 位重复影响）✓
//
//   B 路 VDMA 模型三条性质与真实器件一致：
//     ① 数据常在（tvalid 恒 1，除非注入缺拍）
//     ② 帧首 beat 带 TUSER=1，没被接收就一直举着（电平）
//     ③ 帧内序号只在被接收时前进，到 BN-1 **显式回绕**
//
//   ★ 打印 ASCII（xsim 控制台 GBK）；注释中文；UTF-8 无 BOM。
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_pair_long;

    localparam integer BN     = 4096;       // 一帧的像素/beat 数（长帧长）
    localparam integer BLANK  = 256;        // 每帧之后的消隐拍数
    localparam integer NFRAME = 12;         // 总帧数
    localparam [7:0]   AVAL   = 8'hE7;      // A 路像素值（常量，方便识别"顶替"）

    reg clk = 1'b0;
    always #5 clk = ~clk;                   // 100 MHz
    reg rst_n = 1'b0;

    reg        a_valid = 1'b0;
    reg  [7:0] a_pix   = AVAL;
    reg        a_sof   = 1'b0;

    reg  [12:0] bcnt  = 13'd0;              // B 帧内序号 0..BN-1（13 位够放 4096）
    reg         bstall = 1'b0;

    wire        b_valid = ~bstall;
    wire [7:0]  b_pix   = bcnt[7:0];        // B 的数据 = 序号的低 8 位
    wire        b_tuser = (bcnt == 13'd0);
    wire        b_sof   = b_valid & b_tuser;

    wire        b_ready;
    wire        out_valid, out_sof;
    wire [7:0]  out_pix, out_b_pix;
    wire [15:0] lead_max, stall_cnt, lap_cnt, lead_last;

    integer     nchk = 0, nerr = 0;
    integer     txn  = 0;                   // ★ TB 侧独立统计：一共被接收了多少个 B beat
    reg         expect_strict = 1'b1;

    dd_pair dut (
        .clk (clk), .rst_n (rst_n), .cfg_en (1'b1),
        .a_valid (a_valid), .a_pix (a_pix), .a_sof (a_sof),
        .a_eol (1'b0), .a_eof (1'b0),
        .b_valid (b_valid), .b_pix (b_pix), .b_sof (b_sof), .b_ready (b_ready),
        .out_valid (out_valid), .out_pix (out_pix),
        .out_sof (out_sof), .out_eol (), .out_eof (),
        .out_b_pix (out_b_pix),
        .lead_max (lead_max), .stall_cnt (stall_cnt),
        .lap_cnt (lap_cnt), .lead_last (lead_last)
    );

    // VDMA 模型：帧内序号只在被接收时前进；★ 到 BN-1 显式回绕
    always @(posedge clk) begin
        if (rst_n && b_valid && b_ready) begin
            txn <= txn + 1;                                     // 计数（判据 2 用）
            if (bcnt == BN[12:0] - 13'd1) bcnt <= 13'd0;
            else                          bcnt <= bcnt + 13'd1;
        end
    end

    task chk;
        input         ok;
        input [255:0] msg;
        begin
            nchk = nchk + 1;
            if (ok !== 1'b1) begin
                nerr = nerr + 1;
                if (nerr <= 15) $display("  [FAIL] %0s (t=%0t)", msg, $time);
            end
        end
    endtask

    task a_step;
        input        av;  input [7:0] ap;  input asof;
        begin
            @(negedge clk);
            a_valid = av; a_pix = ap; a_sof = asof;
            @(posedge clk); #1;
        end
    endtask

    integer f, n;
    reg [7:0] exp_off1;
    task a_frame;
        input integer fid;
        input integer inject_at;            // -1 = 不注入
        begin
            for (n = 0; n < BN; n = n + 1) begin
                if (inject_at == n) bstall = 1'b1;
                a_step(1'b1, AVAL, (n == 0));
                if (inject_at == n) begin
                    bstall = 1'b0;
                    chk(out_b_pix === AVAL, "stall pixel must be substituted");
                end else if (expect_strict && (inject_at < 0 || n < inject_at)) begin
                    // 判据 1：数据值
                    chk(out_b_pix === n[7:0], "C1 data value mismatch");
                    // 判据 2：★ 数量不变式 —— 每帧第一个像素处，进入本帧前的累计数必须是 BN 的整数倍
                    if (n == 0) chk(((txn - 1) % BN) == 0, "C2 txn not multiple of BN at frame start");
                end else begin
                    exp_off1 = n[7:0] - 8'd1;               // 8 位自然回绕 = B[N-1]
                    chk((out_b_pix === AVAL) || (out_b_pix === exp_off1),
                        "fault-window: substitute or off-by-1");
                end
            end
            for (n = 0; n < BLANK; n = n + 1) a_step(1'b0, 8'h00, 1'b0);
        end
    endtask

    initial begin
        $display("=== tb_dd_pair_long: BN=%0d BLANK=%0d NFRAME=%0d (per-pixel checks=%0d) ===",
                 BN, BLANK, NFRAME, NFRAME*BN);
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("reset released");

        a_frame(1, -1);
        $display("  [info] after f1 : lead_max=%0d stall=%0d lap=%0d last=%0d txn=%0d",
                 lead_max, stall_cnt, lap_cnt, lead_last, txn);

        for (f = 2; f <= 5; f = f + 1) begin
            a_frame(f, -1);
            chk(lead_max === 16'd0, "steady: lead_max=0");
            chk(stall_cnt === 16'd0, "steady: stall_cnt=0");
        end
        $display("  [info] steady 5 frames: checks=%0d fail=%0d txn=%0d", nchk, nerr, txn);

        a_frame(6, 2000);                   // 第 6 帧第 2000 个像素注入缺拍
        expect_strict = 1'b0;
        a_frame(7, -1);                     // 故障窗口
        $display("  [info] after f7 : lead_max=%0d stall=%0d lap=%0d last=%0d txn=%0d",
                 lead_max, stall_cnt, lap_cnt, lead_last, txn);

        expect_strict = 1'b1;
        for (f = 8; f <= NFRAME; f = f + 1) begin
            a_frame(f, -1);
            chk(lead_max === 16'd0, "post-heal: lead_max=0");
            chk(stall_cnt === 16'd0, "post-heal: stall_cnt=0");
        end
        $display("  [info] after f%0d: lead_max=%0d stall=%0d lap=%0d last=%0d txn=%0d",
                 NFRAME, lead_max, stall_cnt, lap_cnt, lead_last, txn);

        repeat (3) @(posedge clk);
        $display("=== checks=%0d failures=%0d ===", nchk, nerr);
        if (nerr == 0) $display("*** ALL PASS ***"); else $display("*** HAS FAILURES ***");
        $finish;
    end

endmodule
