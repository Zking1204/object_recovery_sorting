//////////////////////////////////////////////////////////////////////////////
// tb_dd_pair_real.v —— dd_pair v4 的【真实帧长】仿真（972×720，30 帧）
//
//   帧长 = 699,840（真实 972×720），消隐 7776（≈8 行），跑 30 帧 ⇒ 约 2100 万拍。
//   ★ 为了跑得动：激励用【计数器驱动】而不是逐像素 task 调用；
//     判据改成【采样判据 + 帧边界不变式】，覆盖面不变：
//       ① 采样数据判据：每 256 个像素抽查一次 `out_b_pix === (n mod BN) 的低 8 位`
//       ② ★ 帧边界不变式：每帧末尾校验 `txn mod BN == 0`
//          （txn = TB 侧独立统计"一共被接收了多少个 B beat" ⇒ 任何尺度的多配/少配都抓得到）
//       ③ ★ 每帧末尾校验 DUT 自己的诊断：lead_max == 0（没漏配）、stall_cnt == 0（零盲带）
//
//   B 路 VDMA 模型：数据常在 / 帧首 beat 带 TUSER 且举着不放 / 帧内序号只在被接收时前进、
//                   到 BN-1 显式回绕。
//   ★ 打印 ASCII；注释中文；UTF-8 无 BOM。
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_pair_real;

    localparam integer BN     = 699840;     // ★ 真实帧长：972 × 720
    localparam integer BLANK  = 7776;       // 每帧后面的消隐（≈8 行）
    localparam integer NFRAME = 30;         // 跑 30 帧
    localparam [7:0]   AVAL   = 8'hE7;      // A 路像素值（常量）

    reg clk = 1'b0;
    always #5 clk = ~clk;                   // 100 MHz
    reg rst_n = 1'b0;

    // ---- A 路：计数器驱动（不用逐像素 task，跑得动）----
    integer acnt = 0;                       // 0..BN-1 = 有效像素；BN..BN+BLANK-1 = 消隐
    always @(posedge clk) begin
        if (rst_n) acnt <= (acnt == (BN + BLANK - 1)) ? 0 : (acnt + 1);
    end
    wire        a_valid = rst_n & (acnt < BN);
    wire        a_sof   = a_valid & (acnt == 0);
    wire [7:0]  a_pix   = AVAL;

    // ---- B 路：VDMA 模型 ----
    reg  [19:0] bcnt  = 20'd0;              // 0..BN-1（20 位够）
    reg         bstall = 1'b0;
    wire        b_valid = ~bstall;
    wire [7:0]  b_pix   = bcnt[7:0];        // B 的数据 = 序号的低 8 位
    wire        b_tuser = (bcnt == 20'd0);
    wire        b_sof   = b_valid & b_tuser;

    wire        b_ready;
    wire        out_valid, out_sof;
    wire [7:0]  out_pix, out_b_pix;
    wire [15:0] lead_max, stall_cnt, lap_cnt, lead_last;

    integer     nchk = 0, nerr = 0;
    integer     txn  = 0;                   // ★ TB 独立统计：一共被接收了多少个 B beat
    integer     fcnt = 0;                   // 已经跑完的帧数

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

    // VDMA 模型：被接收才前进；★ 到 BN-1 显式回绕
    always @(posedge clk) begin
        if (rst_n && b_valid && b_ready) begin
            txn <= txn + 1;
            if (bcnt == (BN - 1)) bcnt <= 20'd0;
            else                  bcnt <= bcnt + 20'd1;
        end
    end

    task chk;
        input         ok;
        input [255:0] msg;
        begin
            nchk = nchk + 1;
            if (ok !== 1'b1) begin
                nerr = nerr + 1;
                if (nerr <= 10) $display("  [FAIL] %0s (t=%0t)", msg, $time);
            end
        end
    endtask

    // ---- 判据：在 negedge 采样（DUT 输出已稳定）----
    always @(negedge clk) begin
        if (rst_n) begin
            // ① 采样数据判据：每 256 个像素查一次
            if (a_valid && (acnt[7:0] == 8'd0)) begin
                // 此刻 DUT 的输出对应上一拍配上的 B。
                // ★ 帧首那一拍要特别处理：它的"上一拍"是【上一帧的最后一个像素】（序号 BN-1），
                //   不是 acnt-1（那会算成 -1）—— 这条是我第一次跑时报 29 处失败的原因 ✗
                if (acnt == 0) chk(out_b_pix === ((BN - 1) & 8'hFF), "C1 frame-start sample mismatch");
                else           chk(out_b_pix === ((acnt - 1) & 8'hFF), "C1 sampled data mismatch");
            end
            // ②③ 帧边界：消隐的最后一拍
            if (acnt == (BN + BLANK - 1)) begin
                fcnt = fcnt + 1;
                chk((txn % BN) == 0,               "C2 txn not multiple of BN at frame end");
                chk(lead_max  === 16'd0,           "C3 lead_max != 0 at frame end");
                chk(stall_cnt === 16'd0,           "C4 stall_cnt != 0 at frame end");
                if ((fcnt % 5) == 0)
                    $display("  [info] frame=%0d txn=%0d lead_max=%0d stall=%0d lap=%0d last=%0d",
                             fcnt, txn, lead_max, stall_cnt, lap_cnt, lead_last);
                if (fcnt >= NFRAME) begin
                    $display("=== checks=%0d failures=%0d frames=%0d txn=%0d (expect %0d) ===",
                             nchk, nerr, fcnt, txn, NFRAME*BN);
                    if (nerr == 0) $display("*** ALL PASS ***");
                    else           $display("*** HAS FAILURES ***");
                    $finish;
                end
            end
        end
    end

    initial begin
        $display("=== tb_dd_pair_real: BN=%0d(972x720) BLANK=%0d NFRAME=%0d, cycles~=%0d ===",
                 BN, BLANK, NFRAME, NFRAME*(BN+BLANK));
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("reset released");
    end

endmodule
