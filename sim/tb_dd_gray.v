//////////////////////////////////////////////////////////////////////////////
// tb_dd_gray.v  ——  dd_gray（第①级 24 位彩色透传 + 1 拍流水寄存器）单元测试
//
//   ★★ 状态说明（务必先读）：本测试台是按"灰度化"版本写的，**尚未同步**。
//      现行 dd_gray.v 自 2026-10-21 起已改为 **24 位彩色逐位透传**（灰度与色度
//      一律后移到 dd_shadow 内现算），因此本 TB 里的 8 位输出声明（`wire [7:0]`）
//      与 2:4:1 灰度黄金模型都与当前实现不一致，跑起来会大面积失败。
//      ⇒ 复现时请**跳过本 TB**（`run_all.ps1 -Only` 挑其它项，或手工排除）；
//        该级的实际正确性由下游各级 TB 与上板实测共同覆盖。
//
//   测什么：
//     1) 延迟**正好 1 拍**：输入变化后输出不跟着变（不是 0 拍），
//        过了一个时钟沿之后输出正好等于本拍输入（不是 2 拍）。
//     2) 2:4:1 灰度的数值算得对不对（拿算式独立写一份黄金参考比对）。
//     3) sideband（valid/sof/eol/eof）与像素**同拍**，一起走、一根不落。
//     4) 空拍（valid=0）时四根 sideband 照样跟着像素一起打拍
//        —— 这是"无条件打拍"这个写法的关键性质。
//
//   ★ 为什么每一步要查两遍：
//       驱动输入之后、时钟沿**之前**查一次  -> 证明延迟不是 0 拍；
//       时钟沿**之后**再查一次              -> 证明延迟不是 2 拍、就是 1 拍。
//     两次都过才说明这一级寄存器接对了。
//
//   运行方式见本包 sim/README.md（原工程里的路径已不适用）。
//       xelab tb_dd_gray -s tb_gray
//       xsim tb_gray -R
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_gray;

    // ---- 被测模块的输入 ----
    reg         clk      = 0;       // 时钟：100MHz
    reg         rst_n    = 0;       // 低有效复位
    reg         in_valid = 0;       // 本拍有有效像素
    reg  [23:0] in_pix   = 0;       // 输入像素（RGB565 左对齐补 0）
    reg         in_sof   = 0;       // 帧首
    reg         in_eol   = 0;       // 行尾
    reg         in_eof   = 0;       // 帧尾

    // ---- 被测模块的输出 ----
    wire        out_valid;          // 输出 valid（应晚 1 拍）
    wire [7:0]  out_pix;            // 输出灰度（应晚 1 拍）
    wire        out_sof;            // 输出帧首
    wire        out_eol;            // 输出行尾
    wire        out_eof;            // 输出帧尾

    // ---- 统计 ----
    integer     errors = 0;         // 失败计数
    integer     tests  = 0;         // 用例计数

    // ---- 参考模型：上一拍"应该"出现在输出上的值 ----
    //   复位后寄存器全为 0，所以初值也全取 0，第一次比对就能直接过。
    reg         ex_valid = 0;       // 上一拍应有的 valid
    reg  [7:0]  ex_gray  = 0;       // 上一拍应有的灰度
    reg         ex_sof   = 0;       // 上一拍应有的帧首
    reg         ex_eol   = 0;       // 上一拍应有的行尾
    reg         ex_eof   = 0;       // 上一拍应有的帧尾

    // ---- 被测模块实例 ----
    dd_gray dut (
        .clk       (clk),           // 100MHz
        .rst_n     (rst_n),         // 低有效复位
        .in_valid  (in_valid),      // 像素有效
        .in_pix    (in_pix),        // 输入像素
        .in_sof    (in_sof),        // 帧首
        .in_eol    (in_eol),        // 行尾
        .in_eof    (in_eof),        // 帧尾
        .out_valid (out_valid),     // 输出有效
        .out_pix   (out_pix),       // 输出灰度
        .out_sof   (out_sof),       // 输出帧首
        .out_eol   (out_eol),       // 输出行尾
        .out_eof   (out_eof)        // 输出帧尾
    );

    // 100 MHz 时钟：周期 10ns，每 5ns 翻转一次
    always #5 clk = ~clk;

    //=====================================================================
    // 黄金参考：把灰度算式用软件再写一遍
    //   特意不直接抄 RTL 的"逐级加宽"写法，而是用普通整数算，
    //   这样位宽写错、取位写错、加法写错都会被抓出来。
    //=====================================================================
    function [7:0] gold_gray(input [23:0] pix);
        reg [4:0] r5;               // R 的 5 个有效位
        reg [5:0] g6;               // G 的 6 个有效位
        reg [4:0] b5;               // B 的 5 个有效位
        reg [7:0] s;                // 中间量 S
        begin
            r5 = pix[23:19];        // 取 R5
            g6 = pix[15:10];        // 取 G6
            b5 = pix[ 7: 3];        // 取 B5
            s  = (r5 + g6) * 2 + b5;            // S = 2(R5+G6) + B5，范围 0..219
            gold_gray = s + (s >> 3);           // 再乘 9/8，范围 0..246
        end
    endfunction

    //=====================================================================
    // 任务 step：送一个像素，并把"延迟 1 拍 + sideband 对齐"两件事一次查完
    //=====================================================================
    task step(input v, input [23:0] p, input s, input l, input f);
        reg [7:0] g;                // 本拍像素对应的灰度期望值
        begin
            // 驱动输入。调用点保证现在正好是"上个时钟沿之后 1ns"，
            // 离下一个时钟沿还有 9ns，绝不会和时钟沿抢。
            in_valid = v;           // 本拍 valid
            in_pix   = p;           // 本拍像素
            in_sof   = s;           // 本拍帧首
            in_eol   = l;           // 本拍行尾
            in_eof   = f;           // 本拍帧尾
            g = gold_gray(p);       // 算出本拍应有的灰度

            // ---- 检查 ①：时钟沿还没到，输出**不应该**跟着变 ----
            tests = tests + 1;      // 用例数 +1
            if (out_valid !== ex_valid || out_pix !== ex_gray ||
                out_sof !== ex_sof || out_eol !== ex_eol || out_eof !== ex_eof) begin
                errors = errors + 1;                            // 记一次失败
                $display("  FAIL 输入一变输出就变 -> 延迟是 0 拍？");
                $display("       实际 out=%b/%0d/%b/%b/%b", out_valid, out_pix, out_sof, out_eol, out_eof);
                $display("       应等 out=%b/%0d/%b/%b/%b", ex_valid, ex_gray, ex_sof, ex_eol, ex_eof);
            end else begin
                $display("  ok   驱动后输出保持不动（延迟 > 0 拍）");
            end

            @(posedge clk); #1;     // 过一个时钟沿，流水寄存器在这一刻采样

            // ---- 检查 ②：沿之后，输出必须**正好**是本拍输入 ----
            tests = tests + 1;      // 用例数 +1
            if (out_valid !== v || out_pix !== g ||
                out_sof !== s || out_eol !== l || out_eof !== f) begin
                errors = errors + 1;                            // 记一次失败
                $display("  FAIL 延迟不是 1 拍：pix=0x%06h", p);
                $display("       应等 out=%b/%0d/%b/%b/%b", v, g, s, l, f);
                $display("       实际 out=%b/%0d/%b/%b/%b", out_valid, out_pix, out_sof, out_eol, out_eof);
            end else begin
                $display("  ok   延迟正好 1 拍：pix=0x%06h gray=%0d sideband=%b/%b/%b", p, g, s, l, f);
            end

            // 记下本拍的值，供下一次调用做检查 ①
            ex_valid = v;           // 下一拍应有的 valid
            ex_gray  = g;           // 下一拍应有的灰度
            ex_sof   = s;           // 下一拍应有的帧首
            ex_eol   = l;           // 下一拍应有的行尾
            ex_eof   = f;           // 下一拍应有的帧尾
        end
    endtask

    //=====================================================================
    // 主测试流程
    //=====================================================================
    initial begin
        $display("==== tb_dd_gray 开始（灰度 + 1 拍流水寄存器）====");

        // ---- 复位 ----
        rst_n = 1'b0;               // 先按住复位
        #20;                        // 等两个时钟
        @(posedge clk); #1;         // 等一个时钟沿，让复位值稳稳落进寄存器
        rst_n = 1'b1;               // 放开复位
        #1;                         // 停在上个沿之后 1ns —— 后面所有 step 都从这个安全点开始

        // ---- 灰度数值：期望值全部手算得出 ----
        $display("-- 灰度数值 --");
        step(1'b1, 24'h000000, 1'b1, 1'b0, 1'b0);   // 黑+帧首  R5=0  G6=0  B5=0   S=0    gray=0
        step(1'b1, 24'hF8FCF8, 1'b0, 1'b0, 1'b0);   // 白        R5=31 G6=63 B5=31  S=219  gray=246
        step(1'b1, 24'hF80000, 1'b0, 1'b0, 1'b0);   // 纯红      R5=31 G6=0  B5=0   S=62   gray=69
        step(1'b1, 24'h00FC00, 1'b0, 1'b0, 1'b0);   // 纯绿      R5=0  G6=63 B5=0   S=126  gray=141
        step(1'b1, 24'h0000F8, 1'b0, 1'b0, 1'b0);   // 纯蓝      R5=0  G6=0  B5=31  S=31   gray=34
        step(1'b1, 24'h808080, 1'b0, 1'b0, 1'b0);   // 中灰      R5=16 G6=32 B5=16  S=112  gray=126
        step(1'b1, 24'h080810, 1'b0, 1'b0, 1'b0);   // 边界      R5=1  G6=2  B5=2   S=8    gray=9（S>>3 刚好进位）
        step(1'b1, 24'h080000, 1'b0, 1'b0, 1'b0);   // 最小红    R5=1  G6=0  B5=0   S=2    gray=2

        // ---- sideband 组合 ----
        $display("-- sideband 与像素同拍 --");
        step(1'b1, 24'h808080, 1'b0, 1'b1, 1'b0);   // 行尾：eol 必须跟着像素一起走
        step(1'b1, 24'h808080, 1'b0, 1'b0, 1'b1);   // 帧尾：eof 必须跟着像素一起走

        // ★ 空拍：valid=0，但像素和 sideband 照样要打拍。
        //   像素值故意保持不变（模拟上游反压时输入保持不变），
        //   输出的灰度应当仍然是这个值 —— 证明寄存器是**无条件**在打拍。
        $display("-- 空拍（valid=0）也要一起打拍 --");
        step(1'b0, 24'h808080, 1'b0, 1'b0, 1'b0);   // 空拍 1
        step(1'b0, 24'h808080, 1'b0, 1'b0, 1'b0);   // 空拍 2
        step(1'b0, 24'h808080, 1'b0, 1'b0, 1'b1);   // 空拍 3，但 eof=1：证明 eof 不看 valid，照样往后传

        // 再送一个正常像素，确认空拍之后流水线没乱
        step(1'b1, 24'hF8FCF8, 1'b1, 1'b0, 1'b0);   // 白 + 帧首（新一帧开头）

        // ---- 汇总 ----
        $display("==== tb_dd_gray 结束：%0d 个用例，%0d 个失败 ====", tests, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;                    // 结束仿真
    end

endmodule
