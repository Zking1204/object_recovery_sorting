//////////////////////////////////////////////////////////////////////////////
// tb_dd_thresh.v  ——  dd_thresh（第⑤级 二值化）单元测试
//
//   测什么：
//     1) 极性 = 0 时：灰度 > 阈值 算命中
//     2) 极性 = 1 时：灰度 < 阈值 算命中
//     3) 阈值边界：等于阈值时**不算**命中（用的是 > 和 <，不是 >= / <=）
//     4) 使能 = 0 时：全部不命中
//     5) ★ 参数只在帧首（in_sof）锁存 —— 帧中间改寄存器不影响本帧
//
//   ★ 第 5 条是本模块最容易出错的地方，也是这里专门测的重点：
//     PS 随时可能改阈值，如果不在帧首锁存，同一帧里会出现
//     "上半部分一个阈值、下半部分另一个阈值"（撕裂）。
//
//   运行方式见本包 sim/README.md（原工程里的路径已不适用）。
//       xvlog ...\dd_thresh.v tb_dd_thresh.v
//       xelab tb_dd_thresh -s tb_thresh
//       xsim tb_thresh -R
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_dd_thresh;

    // ---- 被测模块的输入 ----
    reg        clk      = 0;        // 100MHz
    reg        rst_n    = 0;        // 低有效复位
    reg        in_valid = 0;        // 本拍有有效像素
    reg  [7:0] in_pix   = 0;        // 输入灰度
    reg        in_sof   = 0;        // 帧首
    reg        in_eol   = 0;        // 行尾
    reg        in_eof   = 0;        // 帧尾
    reg        cfg_en   = 0;        // 使能（模拟 AXI-Lite 寄存器）
    reg        cfg_pol  = 0;        // 极性
    reg  [7:0] cfg_th   = 0;        // 阈值

    // ---- 被测模块的输出 ----
    wire       out_valid;           // 输出有效
    wire       out_hit;             // 命中标志
    wire       out_sof;             // 输出帧首
    wire       out_eol;             // 输出行尾
    wire       out_eof;             // 输出帧尾

    // ---- 统计 ----
    integer    errors = 0;          // 失败计数
    integer    tests  = 0;          // 用例计数

    // ---- 被测模块实例 ----
    dd_thresh dut (
        .clk       (clk),           // 100MHz
        .rst_n     (rst_n),         // 低有效复位
        .in_valid  (in_valid),      // 像素有效
        .in_pix    (in_pix),        // 输入灰度
        .in_sof    (in_sof),        // 帧首
        .in_eol    (in_eol),        // 行尾
        .in_eof    (in_eof),        // 帧尾
        .cfg_en    (cfg_en),        // 使能
        .cfg_pol   (cfg_pol),       // 极性
        .cfg_th    (cfg_th),        // 阈值（里程碑 4 的端口名；第④级那版曾改名 cfg_ref，现已回退）
        .out_valid (out_valid),     // 输出有效
        .out_hit   (out_hit),       // 命中
        .out_sof   (out_sof),       // 输出帧首
        .out_eol   (out_eol),       // 输出行尾
        .out_eof   (out_eof)        // 输出帧尾
    );

    // 100 MHz 时钟
    always #5 clk = ~clk;

    //=====================================================================
    // 任务：先设参数，再用 in_sof 把它们锁进本帧
    //   时序：negedge 摆参数 -> 下一个 posedge 时 in_sof 为高 -> 锁存
    //=====================================================================
    task set_cfg(input e, input p, input [7:0] t);
        begin
            cfg_en  = e;            // 摆好使能
            cfg_pol = p;            // 摆好极性
            cfg_th  = t;            // 摆好阈值
            @(negedge clk);         // 等时钟低电平再动 in_sof，避免竞争
            in_sof  = 1'b1;         // 拉高帧首
            @(posedge clk);         // ★ 这一拍把参数锁进 th_cur/pol_cur/en_cur
            @(negedge clk);         // 等时钟低电平
            in_sof  = 1'b0;         // 拉低帧首，锁存完成
        end
    endtask

    //=====================================================================
    // 任务：给一个灰度值，检查命中标志
    //=====================================================================
    task check_hit(input [7:0] g, input exp);
        begin
            @(negedge clk);         // 在时钟低电平改输入，避免竞争
            in_pix   = g;           // 送上灰度值
            in_valid = 1'b1;        // 标记有效
            #1;                     // 纯组合逻辑，等输出稳定
            tests = tests + 1;      // 用例数 +1
            if (out_hit !== exp) begin                      // 严格比对
                errors = errors + 1;                        // 记失败
                $display("  FAIL  gray=%0d  hit=%b  期望=%b  (th=%0d pol=%b en=%b)",
                         g, out_hit, exp, cfg_th, cfg_pol, cfg_en);
            end else begin
                $display("  ok    gray=%0d  hit=%b", g, out_hit);
            end
            #4;                     // 走完剩下的半个周期
        end
    endtask

    //=====================================================================
    // 主测试流程
    //=====================================================================
    initial begin
        $display("==== tb_dd_thresh 开始 ====");

        // ---- 复位 ----
        rst_n = 1'b0;               // 按住复位
        #20;                        // 等两个时钟
        rst_n = 1'b1;               // 放开复位

        // ---- 1) 极性 0：大于阈值算命中，阈值 = 100 ----
        $display("-- 极性0，阈值=100：gray > 100 算命中 --");
        set_cfg(1'b1, 1'b0, 8'd100);        // 使能=1，极性=0，阈值=100
        check_hit(8'd126, 1'b1);            // 126 > 100  -> 命中
        check_hit(8'd101, 1'b1);            // 101 > 100  -> 命中
        check_hit(8'd100, 1'b0);            // 100 不大于 100 -> 不命中（边界）
        check_hit(8'd99,  1'b0);            // 99  -> 不命中
        check_hit(8'd69,  1'b0);            // 69  -> 不命中
        check_hit(8'd0,   1'b0);            // 0   -> 不命中

        // ---- 2) 极性 1：小于阈值算命中，阈值 = 100 ----
        $display("-- 极性1，阈值=100：gray < 100 算命中 --");
        set_cfg(1'b1, 1'b1, 8'd100);        // 换极性，重新锁存
        check_hit(8'd69,  1'b1);            // 69 < 100 -> 命中
        check_hit(8'd99,  1'b1);            // 99 < 100 -> 命中
        check_hit(8'd100, 1'b0);            // 100 不小于 100 -> 不命中（边界）
        check_hit(8'd101, 1'b0);            // 101 -> 不命中
        check_hit(8'd126, 1'b0);            // 126 -> 不命中

        // ---- 3) 使能 = 0：全部不命中 ----
        $display("-- 使能=0：全部不命中 --");
        set_cfg(1'b0, 1'b0, 8'd100);        // 关掉使能
        check_hit(8'd126, 1'b0);            // 就算灰度很高也不命中
        check_hit(8'd246, 1'b0);            // 最高灰度也不命中

        // ---- 4) ★ 参数只在帧首锁存（本模块最关键的行为）----
        $display("-- 帧中间改阈值：本帧不受影响，下帧才生效 --");
        set_cfg(1'b1, 1'b0, 8'd100);        // 本帧阈值 = 100
        @(negedge clk);
        cfg_th   = 8'd200;                  // ★ 帧中间偷改寄存器（模拟 PS 写 AXI-Lite）
        in_pix   = 8'd150;                  // 150 > 100 但 150 < 200
        in_valid = 1'b1;
        #1;
        tests = tests + 1;
        if (out_hit !== 1'b1) begin                         // 应该仍按旧阈值 100 判 -> 命中
            errors = errors + 1;
            $display("  FAIL  帧中间改阈值被立刻生效了！hit=%b 期望=1（应保持旧阈值100）", out_hit);
        end else begin
            $display("  ok    帧中间改阈值未影响本帧（仍按 100 判定）");
        end
        #4;
        set_cfg(1'b1, 1'b0, 8'd200);        // 下一帧首才把 200 锁进去
        check_hit(8'd150, 1'b0);            // 现在 150 < 200 -> 不命中，说明新阈值生效了

        // ---- 汇总 ----
        $display("==== tb_dd_thresh 结束：%0d 个用例，%0d 个失败 ====", tests, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
