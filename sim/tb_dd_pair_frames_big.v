//////////////////////////////////////////////////////////////////////////////
// tb_dd_pair_frames_big.v —— dd_pair v4 的【放大版】多帧长跑仿真
//
//   相比 tb_dd_pair_frames 的放大点：
//     · 帧长 8 → **256**（A 每帧 256 个像素 / B 每帧 256 个 beat）
//     · 帧数 7 → **20 帧**（专门看"会不会累积漂移"）
//     · 消隐 6 → **64 拍**（更接近真实 A 路的大空洞比例）
//     · 比对总数 58 → **5000+ 条**（每帧逐像素都查）
//
//   B 路仍是【VDMA 模型】，三条性质与真实器件一致：
//     ① 数据常在（tvalid 恒 1，除非手动注入缺拍）
//     ② 帧首那个 beat 带 TUSER=1，没被接收就一直举着（= 电平）
//     ③ 帧内序号只在【被接收】时前进，到 BN-1 显式回绕到 0
//
//   【本轮的三个判据坑（上一轮踩过，这次一开始就避开）】
//     · 帧长回绕必须显式写（不能靠计数器自然溢出）
//     · 放宽判据的窗口要精确到"从哪一拍起"（注入点之前仍严格）
//     · 跨帧比较要按帧长取模（落后 1 个 = B[N-1]，不是 -1）
//
//   ★ 打印用 ASCII（xsim 控制台是 GBK）；注释用中文。UTF-8 无 BOM。
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_pair_frames_big;

    localparam integer BN     = 256;        // 一帧的像素/beat 数
    localparam integer BLANK  = 64;         // 每帧之后的消隐拍数
    localparam integer NFRAME = 20;         // 总帧数
    localparam [7:0]   AVAL   = 8'hE7;      // A 路的像素值（常量，方便识别"顶替"）

    reg clk = 1'b0;
    always #5 clk = ~clk;                   // 100 MHz
    reg rst_n = 1'b0;

    // ---------------- A 路（TB 驱动）----------------
    reg        a_valid = 1'b0;
    reg  [7:0] a_pix   = AVAL;
    reg        a_sof   = 1'b0;

    // ---------------- B 路：VDMA 模型 ----------------
    reg  [7:0] bcnt   = 8'd0;               // B 帧内序号 0..255
    reg        bstall = 1'b0;               // 1 = 这一拍强行没有数据

    wire        b_valid = ~bstall;                          // ① 数据常在
    wire [7:0]  b_pix   = bcnt;                             // 用序号本身当数据 ⇒ 一眼看出配的是第几个
    wire        b_tuser = (bcnt == 8'd0);                   // ② 帧首标记
    wire        b_sof   = b_valid & b_tuser;                //    没被接收就一直举着（电平）

    wire        b_ready;
    wire        out_valid, out_sof;
    wire [7:0]  out_pix, out_b_pix;
    wire [15:0] lead_max, stall_cnt, lap_cnt, lead_last;

    integer nchk = 0, nerr = 0;
    reg expect_strict = 1'b1;               // 1 = 严格 A[n]↔B[n]；0 = 故障窗口

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

    // VDMA 模型：帧内序号只在【被接收】时前进；★ 到 BN-1 显式回绕
    always @(posedge clk) begin
        if (rst_n && b_valid && b_ready) begin
            if (bcnt == (BN[7:0] - 8'd1)) bcnt <= 8'd0;     // ★ 显式回绕（不靠自然溢出）
            else                          bcnt <= bcnt + 8'd1;
        end
    end

    task chk;
        input         ok;
        input [255:0] msg;
        begin
            nchk = nchk + 1;
            if (ok !== 1'b1) begin
                nerr = nerr + 1;
                if (nerr <= 20) $display("  [FAIL] %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    task a_step;
        input        av;
        input [7:0]  ap;
        input        asof;
        begin
            @(negedge clk);
            a_valid = av; a_pix = ap; a_sof = asof;
            @(posedge clk); #1;
        end
    endtask

    // 跑一帧：BN 个像素（第 0 个带 a_sof）+ BLANK 拍消隐
    //   inject_at >= 0 时，在该像素处注入一拍缺数据
    task a_frame;
        input integer fid;
        input integer inject_at;            // -1 = 不注入
        integer n;
        reg [7:0] exp_off1;
        begin
            for (n = 0; n < BN; n = n + 1) begin
                if (inject_at == n) bstall = 1'b1;                  // 制造一拍"没数据"
                a_step(1'b1, AVAL, (n == 0));
                if (inject_at == n) begin
                    bstall = 1'b0;
                    // 缺拍那一拍：必须是顶替（差分 0），不能是别的 B 值
                    chk(out_b_pix === AVAL, "stall pixel must be substituted");
                end else if (expect_strict && (inject_at < 0 || n < inject_at)) begin
                    // 严格：正常帧、以及"注入点之前"的像素
                    if (out_b_pix !== n[7:0]) begin
                        $display("  [info] frame=%0d pix=%0d got=%02x want=%02x bcnt=%02x lap=%0d lead=%0d stall=%0d",
                                 fid, n, out_b_pix, n[7:0], bcnt, lap_cnt, lead_max, stall_cnt);
                    end
                    chk(out_b_pix === n[7:0], "strict A[n]<->B[n] mismatch");
                end else begin
                    // 故障窗口（注入点之后）：只要求"不是乱数据"
                    exp_off1 = n[7:0] - 8'd1;                        // ★ 8 位自然回绕 = B[N-1]
                    chk((out_b_pix === AVAL) || (out_b_pix === exp_off1),
                        "fault-window: must be substitute or off-by-1");
                end
            end
            for (n = 0; n < BLANK; n = n + 1) a_step(1'b0, 8'h00, 1'b0);   // 消隐
        end
    endtask

    integer f;
    initial begin
        $display("=== tb_dd_pair_frames_big start: BN=%0d BLANK=%0d NFRAME=%0d ===", BN, BLANK, NFRAME);
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("reset released");

        // ---- 第 1 帧（对完账后打印一次读数）----
        a_frame(1, -1);
        $display("  [info] after f1 : lead_max=%0d stall_cnt=%0d lap_cnt=%0d lead_last=%0d",
                 lead_max, stall_cnt, lap_cnt, lead_last);

        // ---- 第 2..8 帧：稳态长跑（逐像素严格）----
        for (f = 2; f <= 8; f = f + 1) begin
            a_frame(f, -1);
            chk(lead_max  === 16'd0, "steady frame: lead_max must be 0");
            chk(stall_cnt === 16'd0, "steady frame: stall_cnt must be 0");
        end
        $display("  [info] steady 8 frames done, checks=%0d failures=%0d", nchk, nerr);

        // ---- 第 9 帧：在第 100 个像素处注入一拍缺数据 ----
        a_frame(9, 100);

        // ---- 第 10 帧：故障窗口（允许顶替/落后1）----
        expect_strict = 1'b0;
        a_frame(10, -1);
        $display("  [info] after f10: lead_max=%0d stall_cnt=%0d lap_cnt=%0d lead_last=%0d",
                 lead_max, stall_cnt, lap_cnt, lead_last);

        // ---- 第 11..20 帧：★ 必须完全恢复，而且长期不再漂 ----
        expect_strict = 1'b1;
        for (f = 11; f <= NFRAME; f = f + 1) begin
            a_frame(f, -1);
            chk(lead_max  === 16'd0, "post-heal frame: lead_max must be 0");
            chk(stall_cnt === 16'd0, "post-heal frame: stall_cnt must be 0");
        end
        $display("  [info] after f%0d: lead_max=%0d stall_cnt=%0d lap_cnt=%0d lead_last=%0d",
                 NFRAME, lead_max, stall_cnt, lap_cnt, lead_last);

        repeat (3) @(posedge clk);
        $display("=== checks=%0d failures=%0d ===", nchk, nerr);
        if (nerr == 0) $display("*** ALL PASS ***"); else $display("*** HAS FAILURES ***");
        $finish;
    end

endmodule
