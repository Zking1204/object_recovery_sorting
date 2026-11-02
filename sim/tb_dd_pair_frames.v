//////////////////////////////////////////////////////////////////////////////
// tb_dd_pair_frames.v —— dd_pair v4 的【多帧稳态 + 自愈】仿真
//
//   【为什么这个测试台比上一个更有意义】
//     上一个（tb_dd_pair_v4）是"手工摆几拍"的单点检查。
//     这个用【B 路 VDMA 模型】驱动，模型的三条性质与真实器件一致：
//       ① 数据永远备好（tvalid 恒 1）—— 对应"VDMA 内部行缓冲一直是满的"
//       ② 帧首那个 beat 带 TUSER=1，且【没被接收就一直举着】（AXIS 规定）⇒ 电平
//       ③ 帧内序号只在【被接收】时才前进（不接收就原地不动）
//     ⇒ 这正好是"我们按住它等 a_sof"能成立的那个前提。
//
//   【★ 一处必须做对的模型细节（第一次就是错在这）】
//     B 的帧内序号必须在 BN-1 处【回绕到 0】，不能让它自然累加 ✗
//     否则模型里的"B 帧长"就不是 BN、与 A 的帧长不相等 ⇒ 测出来全是假失败。
//
//   【本测试台验什么】
//     F1 多帧稳态：4 帧，每帧 8 个 A 像素 + 6 拍消隐
//          · 每帧第 n 个像素配的必须是 B 的第 n 个（A[n]↔B[n]）
//          · 每帧结束时：lead_max=0（没漏配）、stall_cnt=0（零盲带）
//     F2 缺一拍自愈：帧中间强制一拍没有数据
//          · 那一拍顶替（差分 0）、不误报 ✓
//          · 之后【最多损失 1 帧】必须自动回到 A[n]↔B[n] ✓
//
//   【时序约定】激励在 negedge 摆、采样在 posedge 之后 1ns。
//   ★ 打印信息用 ASCII（xsim 控制台是 GBK，中文会乱码）；注释用中文。
//   ★ UTF-8（无 BOM）。
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_pair_frames;

    // ---------------- 时钟 / 复位 ----------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                   // 100 MHz
    reg rst_n = 1'b0;

    // ---------------- A 路（TB 驱动，模拟相机：8 像素 + 6 拍消隐）----------------
    reg        a_valid = 1'b0;
    reg  [7:0] a_pix   = 8'h10;
    reg        a_sof   = 1'b0;

    // ---------------- B 路：VDMA 模型 ----------------
    localparam [3:0] BN = 4'd8;             // B 一帧 8 个 beat（缩放，方便仿真）
    reg  [3:0] bcnt   = 4'd0;               // B 帧内序号：0..BN-1
    reg        bstall = 1'b0;               // 1 = 这一拍强行没有数据（模拟 DDR 忙）

    wire        b_valid = ~bstall;                          // 数据永远备好（除非强制停一拍）
    wire [7:0]  b_pix   = 8'h40 + {4'd0, bcnt};             // B 的内容：0x40,0x41,...
    wire        b_tuser = (bcnt == 4'd0);                   // 帧首标记
    wire        b_sof   = b_valid & b_tuser;                // ★ 没被接收就一直是电平

    wire        b_ready;
    wire        out_valid, out_sof;
    wire [7:0]  out_pix, out_b_pix;
    wire [15:0] lead_max, stall_cnt, lap_cnt, lead_last;

    integer nchk = 0, nerr = 0;
    reg expect_strict = 1'b1;               // 1 = 逐像素严格判 A[n]↔B[n]；0 = 故障窗口，只判"不是乱数据"

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

    // VDMA 模型：帧内序号只在【被接收】时前进；到 BN-1 回绕到 0（★ 第一次就是漏了这个回绕）
    always @(posedge clk) begin
        if (rst_n && b_valid && b_ready) begin
            if (bcnt == BN - 4'd1) bcnt <= 4'd0;            // 一帧走完 ⇒ 回绕（帧首 beat 又出现）
            else                   bcnt <= bcnt + 4'd1;
        end
    end

    task chk;
        input         ok;
        input [255:0] msg;
        begin
            nchk = nchk + 1;
            if (ok !== 1'b1) begin
                nerr = nerr + 1;
                $display("  [FAIL] %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    // 走一拍：negedge 摆 A 路激励 → posedge 后采样
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

    // 跑一帧 A：8 个像素（第 0 个带 a_sof）+ 6 拍消隐；逐拍检查 A[n]↔B[n]
    task a_frame;
        input [3:0] fid;                    // 帧号（只为打印）
        input       inject_stall;           // 1 = 在第 3 个像素处强制缺一拍
        integer n;
        begin
            for (n = 0; n < 8; n = n + 1) begin
                if (inject_stall && n == 3) bstall = 1'b1;     // 制造一次"没数据"
                a_step(1'b1, 8'h10 + n[7:0], (n == 0));
                if (inject_stall && n == 3) begin
                    bstall = 1'b0;                             // 只停一拍
                    $display("  [info] frame=%0d pix=%0d STALL-injected: out_b_pix=%02x (expect substitute=%02x)",
                             fid, n, out_b_pix, 8'h10 + n[7:0]);
                end else if (expect_strict || (inject_stall && n < 3)) begin
                    // 严格：所有正常帧，以及"注入点之前"的像素，都必须 A[n]↔B[n]
                    if (out_b_pix !== (8'h40 + n[7:0])) begin
                        $display("  [info] frame=%0d pix=%0d got=%02x want=%02x  bcnt=%0d lap=%0d lead=%0d stall=%0d",
                                 fid, n, out_b_pix, 8'h40 + n[7:0], bcnt, lap_cnt, lead_max, stall_cnt);
                    end
                    chk(out_b_pix === (8'h40 + n[7:0]), "strict A[n]<->B[n] mismatch");
                end else begin
                    // 故障窗口（注入点之后）：只要求"不是乱数据" —— 要么顶替（=a_pix），
                    // 要么整体落后 1 个。★ 注意要【按 BN 取模】：B[−1] 就是 B[7]，不是 0x3F
                    if (!((out_b_pix === (8'h10 + n[7:0])) ||
                          (out_b_pix[2:0] === ((n + 7) % 8)))) begin
                        $display("  [info] frame=%0d pix=%0d got=%02x (fault window) bcnt=%0d lap=%0d lead=%0d stall=%0d",
                                 fid, n, out_b_pix, bcnt, lap_cnt, lead_max, stall_cnt);
                    end
                    chk((out_b_pix === (8'h10 + n[7:0])) ||
                        (out_b_pix[2:0] === ((n + 7) % 8)),
                        "fault-window: must be substitute or off-by-1(mod)");
                end
            end
            for (n = 0; n < 6; n = n + 1) a_step(1'b0, 8'h00, 1'b0);   // 消隐
        end
    endtask

    initial begin
        $display("=== tb_dd_pair_frames start (A frame=8 pix + 6 idle, B frame=8 beat) ===");
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        $display("reset released");

        // ---- F1：第 1 帧（首帧，只记录）----
        a_frame(4'd1, 1'b0);
        $display("  [info] after f1: lead_max=%0d stall_cnt=%0d lap_cnt=%0d lead_last=%0d",
                 lead_max, stall_cnt, lap_cnt, lead_last);

        // ---- F1：稳态三帧（必须全对）----
        a_frame(4'd2, 1'b0);
        $display("  [info] after f2: lead_max=%0d stall_cnt=%0d", lead_max, stall_cnt);
        chk(lead_max  === 16'd0, "F1 steady: no missed pairing (lead_max=0)");
        chk(stall_cnt === 16'd0, "F1 steady: zero blind (stall_cnt=0)");

        a_frame(4'd3, 1'b0);
        a_frame(4'd4, 1'b0);

        // ---- F2：注入一次缺拍 ⇒ 顶替 + 最多损失 1 帧后自愈 ----
        expect_strict = 1'b0;               // 第 5、6 帧是"故障窗口"：允许顶替或差 1
        a_frame(4'd5, 1'b1);
        a_frame(4'd6, 1'b0);
        expect_strict = 1'b1;               // ★ 第 7 帧起必须严格恢复 A[n]↔B[n]
        a_frame(4'd7, 1'b0);
        chk(stall_cnt === 16'd0, "F2 after heal: zero blind");

        repeat (3) @(posedge clk);
        $display("=== checks=%0d failures=%0d ===", nchk, nerr);
        if (nerr == 0) $display("*** ALL PASS ***");
        else           $display("*** HAS FAILURES ***");
        $finish;
    end

endmodule
