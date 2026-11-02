//////////////////////////////////////////////////////////////////////////////
// tb_dd_pair_v4.v —— dd_pair v4（去队列 + 帧首匹配）的单元测试台
//
//   【它验什么（每一条都要能说清"失败时会打印什么"）】
//     T1  A 有像素 + B 有数据        ⇒ 同拍配上，out_b_pix = b_pix
//     T2  A 没像素（消隐）           ⇒ b_ready=0、out_valid=0
//     T3  b_sof 出现且 A 不在帧首    ⇒ 当拍不收（不把 B[0] 配到帧中间）；边沿计数 = 1
//     T3b 保持 b_sof 为【电平】+ 消隐 ⇒ 一直挂起，且★盲带计数保持 0（不把消隐算成盲带）
//     T4  a_sof 到了（b_sof 仍是电平）⇒ ★ 当拍放开、收走队首 B[0]，与 A[0] 同拍
//     T5  收走后边带落下             ⇒ 回到 1:1；★稳态 lead_max=0、stall_cnt=0
//     T6  B 没供上（b_valid=0）      ⇒ 用 A 顶替（差分 0）+ "没配上"计数 +1
//     T7  b_sof 与 a_sof 同拍        ⇒ 不挂起
//     T8  稳态重锚（b_sof 落在消隐期）⇒ ★零代价（lead_last=0），重锚后仍是队首配 A[0]
//
//   【时序约定】激励在 negedge 摆、采样在 posedge 之后 1ns（避免沿上竞争）。
//   ★ 本文件以 UTF-8（无 BOM）保存；逐行中文注释。
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_pair_v4;

    reg clk = 1'b0;                         // 时钟
    always #5 clk = ~clk;                   // 100 MHz
    reg rst_n = 1'b0;                       // 低有效复位

    reg        a_valid = 1'b0;              // A 路有效
    reg  [7:0] a_pix   = 8'h10;             // A 路灰度
    reg        a_sof   = 1'b0;              // A 路帧首
    reg        a_eol   = 1'b0;              // A 路行尾
    reg        a_eof   = 1'b0;              // A 路帧尾
    reg        b_valid = 1'b0;              // B 路 tvalid（原始，未门控）
    reg  [7:0] b_pix   = 8'h80;             // B 路灰度
    reg        b_sof   = 1'b0;              // B 路帧首（挂起期间会保持为电平）

    wire        b_ready;                    // 给 VDMA 的 tready
    wire        out_valid, out_sof, out_eol, out_eof;
    wire [7:0]  out_pix, out_b_pix;
    wire [15:0] lead_max, stall_cnt, lap_cnt, lead_last;

    integer nchk = 0;                       // 比对总数
    integer nerr = 0;                       // 失败数

    dd_pair dut (
        .clk (clk), .rst_n (rst_n), .cfg_en (1'b1),
        .a_valid (a_valid), .a_pix (a_pix), .a_sof (a_sof), .a_eol (a_eol), .a_eof (a_eof),
        .b_valid (b_valid), .b_pix (b_pix), .b_sof (b_sof), .b_ready (b_ready),
        .out_valid (out_valid), .out_pix (out_pix), .out_sof (out_sof),
        .out_eol (out_eol), .out_eof (out_eof), .out_b_pix (out_b_pix),
        .lead_max (lead_max), .stall_cnt (stall_cnt),
        .lap_cnt (lap_cnt), .lead_last (lead_last)
    );

    task chk;                               // 一条判据
        input         ok;                   //   条件
        input [255:0] msg;                  //   说明
        begin
            nchk = nchk + 1;                //   比对总数 +1
            if (ok !== 1'b1) begin          //   不成立
                nerr = nerr + 1;            //     失败数 +1
                $display("  [FAIL] %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    task step;                              // 走一拍：negedge 摆 → posedge 后采样
        input        av;  input [7:0] ap;  input asof;
        input        bv;  input [7:0] bp;  input bsof;
        begin
            @(negedge clk);                 // 负沿摆激励
            a_valid = av;  a_pix = ap;  a_sof = asof;
            b_valid = bv;  b_pix = bp;  b_sof = bsof;
            @(posedge clk); #1;             // 过正沿后采样
        end
    endtask

    initial begin
        $display("=== tb_dd_pair_v4 开始 ===");
        a_valid = 0; b_valid = 0; a_sof = 0; b_sof = 0;
        repeat (4) @(posedge clk);          // 复位 4 拍
        @(negedge clk); rst_n = 1'b1;       // 释放
        $display("复位释放");

        // ---- T1：A 有像素 + B 有数据 ⇒ 同拍配上 ----
        step(1'b1, 8'h11, 1'b0, 1'b1, 8'hA0, 1'b0);
        chk(b_ready === 1'b1,    "T1 A有像素⇒拉高ready收B");
        chk(out_valid === 1'b1,  "T1 输出有效（跟A节拍）");
        chk(out_b_pix === 8'hA0, "T1 同拍配上B");

        // ---- T2：消隐 ⇒ 不收 B、输出无效 ----
        step(1'b0, 8'h00, 1'b0, 1'b1, 8'hA1, 1'b0);
        chk(b_ready === 1'b0,    "T2 A无像素⇒拉低ready");
        chk(out_valid === 1'b0,  "T2 A无像素⇒输出无效");

        // ---- T3：b_sof 出现、A 不在帧首 ⇒ 当拍不收 ----
        step(1'b1, 8'h12, 1'b0, 1'b1, 8'hB0, 1'b1);
        chk(b_ready === 1'b0,    "T3 b_sof且A不在帧首⇒当拍不收");
        chk(out_b_pix === 8'h12, "T3 没配上⇒用A顶替");
        chk(lap_cnt === 16'd1,   "T3 ★b_sof 用边沿计数=1（不是数电平）");

        // ---- T3b：保持 b_sof 为电平 + 消隐若干拍（AXIS 协议要求保持）----
        step(1'b0, 8'h00, 1'b0, 1'b1, 8'hB0, 1'b1);
        step(1'b0, 8'h00, 1'b0, 1'b1, 8'hB0, 1'b1);
        step(1'b0, 8'h00, 1'b0, 1'b1, 8'hB0, 1'b1);
        chk(b_ready === 1'b0,    "T3b 挂起中⇒一直不收");
        chk(out_valid === 1'b0,  "T3b A无像素⇒输出无效");
        chk(stall_cnt === 16'd0, "T3b ★挂起但无A像素⇒盲带计数保持0（不会饱和）");

        // ---- T4：a_sof 到了、b_sof 仍是电平 ⇒ 当拍放开、收走 B[0] ----
        step(1'b1, 8'h20, 1'b1, 1'b1, 8'hB0, 1'b1);
        chk(b_ready === 1'b1,    "T4 ★a_sof当拍组合放开（不错1个像素）");
        chk(out_b_pix === 8'hB0, "T4 ★队首B[0]与A[0]同拍配上");
        chk(out_pix === 8'h20,   "T4 A[0]输出");
        chk(out_sof === 1'b1,    "T4 A帧首跟着打拍");

        // ---- T5：B 的帧首边带落下，回到 1:1 ----
        step(1'b1, 8'h21, 1'b0, 1'b1, 8'hB1, 1'b0);
        chk(out_b_pix === 8'hB1, "T5 逐拍一一对应");
        chk(lead_max === 16'd0,  "T5 ★稳态：本帧没配上次数=0");
        chk(stall_cnt === 16'd0, "T5 ★稳态：盲带=0");
        step(1'b1, 8'h22, 1'b0, 1'b1, 8'hB2, 1'b0);
        chk(out_b_pix === 8'hB2, "T5b 逐拍一一对应（第2拍）");

        // ---- T6：B 没供上 ⇒ 顶替 + 计数 ----
        step(1'b1, 8'h23, 1'b0, 1'b0, 8'hFF, 1'b0);
        chk(b_ready === 1'b1,    "T6 A有像素⇒仍拉高ready（在等B）");
        chk(out_b_pix === 8'h23, "T6 ★没收到B⇒用A顶替（差分=0，不误报）");
        chk(lead_max >= 1,       "T6 没配上计数+1");

        // ---- T7：b_sof 与 a_sof 同拍 ⇒ 不挂起 ----
        step(1'b1, 8'h30, 1'b1, 1'b1, 8'hC0, 1'b1);
        chk(b_ready === 1'b1,    "T7 b_sof与a_sof同拍⇒不挂起");
        chk(out_b_pix === 8'hC0, "T7 同拍配上");
        step(1'b1, 8'h31, 1'b0, 1'b1, 8'hC1, 1'b0);
        chk(b_ready === 1'b1,    "T7b 之后照常1:1");

        // ---- T8：稳态重锚（b_sof 落在消隐期）⇒ 零代价 ----
        step(1'b0, 8'h00, 1'b0, 1'b1, 8'hD0, 1'b1);   // 消隐中来了 B 帧首
        chk(b_ready === 1'b0,    "T8 b_sof在消隐期⇒挂起（本来也没像素可收）");
        step(1'b0, 8'h00, 1'b0, 1'b1, 8'hD0, 1'b1);   // 继续消隐
        step(1'b1, 8'h40, 1'b1, 1'b1, 8'hD0, 1'b1);   // a_sof ⇒ 放开
        chk(b_ready === 1'b1,    "T8 a_sof放开");
        chk(out_b_pix === 8'hD0, "T8 ★重锚后仍是队首配A[0]（对齐不变）");
        chk(lead_last === 16'd0, "T8 ★b_sof→a_sof 之间牺牲 0 个 A 像素（重锚零代价）");
        step(1'b1, 8'h41, 1'b0, 1'b1, 8'hD1, 1'b0);
        chk(out_b_pix === 8'hD1, "T8b 重锚后继续1:1");

        // ---- 收尾 ----
        repeat (3) @(posedge clk);
        $display("=== 比对 %0d 条，失败 %0d 条 ===", nchk, nerr);
        if (nerr == 0) $display("*** 全部通过 ***");
        else           $display("*** 有失败 ***");
        $finish;
    end

endmodule
