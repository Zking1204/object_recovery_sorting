//=============================================================================
// tb_servo_pwm.sv —— servo_pwm v2 的自检式 testbench（SystemVerilog）
//
// 【为什么用 1 MHz 时钟测】
//   DUT 里时间都以时钟周期为单位：CLK_PER_US = 1MHz/1MHz = 1，
//   CLK_PER_MS = 1000 拍，PWM 周期 = 1×20000 = 20000 拍。
//   于是"脉宽 µs 的数值 == 高电平拍数"、"1 ms == 1000 拍"，期望值一眼看得懂。
//   100 MHz 下的真值由同一套逻辑保证（只是 CLK_PER_US=100、CLK_PER_MS=100000）。
//
// 【测什么】（全带期望值，失败 +1 并打印期望/实际）
//   ① ID 读回
//   ② 复位默认值：脉宽 1500 / T_DLY 2000 / T_ACT 3000 / T_RET 500 / 限幅 1000~2000 / 不输出
//   ③ 使能后三路都是中位 1500、周期 20000 拍
//   ④ ★ 完整动作时序：KICK 后
//        0 ~ 5 ms   脉宽 = 中位 1500
//        5 ms       跳到偏位 1800
//        5 ~ 15 ms  保持 1800
//        15 ~ 19 ms 线性斜坡回到 1500
//        ≥19 ms     回待机（STATUS=0）
//   ⑤ 三路互不影响：踢通道0 时通道1/2 一直不动
//   ⑥ 限幅：PW_MAX=2000 时偏位 2400 实际只输出 2000；PW_MIN=1600 时中位 1500 被抬到 1600
//   ⑦ T_RET=0 ⇒ 直接跳回中位，不做斜坡
//   ⑧ 三个时间全 0 ⇒ 踢了也不动
//   ⑨ 测试模式三路周期 128 / 64 / 32 拍
//   ⑩ 关使能 ⇒ 三路恒低
//   ⑪ ★ 三路时间参数逐路独立（2026-10-29 新增，寄存器 0x4C~0x6C）：
//       写全局扇出到三路 / 单改某一路另两路不动 / 三路不同 T_DLY 时偏位窗口各自错开
//
// 【怎么跑】
//   xvlog -sv servo_ch.v servo_pwm.v tb_servo_pwm.sv
//   xelab -debug typical tb_servo_pwm -s tb_servo_pwm_sim
//   xsim tb_servo_pwm_sim -R
//=============================================================================
`timescale 1ns / 1ps

module tb_servo_pwm;

    //------------------------------------------------------------------
    // 参数
    //------------------------------------------------------------------
    localparam integer CLK_HZ  = 1_000_000;   // 1 MHz
    localparam integer CLK_NS  = 1000;        // 一个时钟 1000 ns
    localparam integer PERIOD  = 20000;       // PWM 周期（拍）
    localparam integer MS      = 1000;        // 1 ms = 1000 拍
    localparam integer PW_DEF  = 1500;        // 默认中位
    localparam integer PWMIN_D = 1000;        // 默认限幅下限
    localparam integer PWMAX_D = 2000;        // 默认限幅上限
    localparam integer TDLY_D  = 2000;        // 默认偏转延时 ms
    localparam integer TACT_D  = 3000;        // 默认偏转保持 ms
    localparam integer TRET_D  = 500;         // 默认恢复时间 ms
    localparam integer TEST_HI = 6;

    reg  clk  = 1'b0;
    reg  rstn = 1'b0;
    wire [2:0] servo;

    reg  [7:0]  awaddr  = 8'd0;
    reg  [2:0]  awprot  = 3'd0;
    reg         awvalid = 1'b0;
    wire        awready;
    reg  [31:0] wdata   = 32'd0;
    reg  [3:0]  wstrb   = 4'hF;
    reg         wvalid  = 1'b0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready  = 1'b0;
    reg  [7:0]  araddr  = 8'd0;
    reg  [2:0]  arprot  = 3'd0;
    reg         arvalid = 1'b0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready  = 1'b0;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    servo_pwm #(
        .CLK_HZ  (CLK_HZ),
        .PERIOD_US(PERIOD),
        .PW_DEF  (PW_DEF),
        .TDLY_DEF(TDLY_D),
        .TACT_DEF(TACT_D),
        .TRET_DEF(TRET_D),
        .TEST_HI (TEST_HI)
    ) dut (
        .s_axi_aclk   (clk),      .s_axi_aresetn(rstn),
        .s_axi_awaddr (awaddr),   .s_axi_awprot (awprot),  .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata  (wdata),    .s_axi_wstrb  (wstrb),   .s_axi_wvalid (wvalid),  .s_axi_wready (wready),
        .s_axi_bresp  (bresp),    .s_axi_bvalid (bvalid),  .s_axi_bready (bready),
        .s_axi_araddr (araddr),   .s_axi_arprot (arprot),  .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata  (rdata),    .s_axi_rresp  (rresp),   .s_axi_rvalid (rvalid),  .s_axi_rready (rready),
        .servo_o      (servo)
    );

    always #(CLK_NS/2) clk = ~clk;            // 1 MHz

    //------------------------------------------------------------------
    // 记分板
    //------------------------------------------------------------------
    integer n_pass = 0;
    integer n_fail = 0;
    integer hi_cnt, per_cnt;                  // 波形测量结果
    integer busy_edges = 0;                   // ★ 通道0 busy 上升沿计数（数"做了几轮动作"）
    integer e0;                               // ★ 记起点用
    reg     busy_prev  = 1'b0;                // 上一拍的 busy[0]
    reg [31:0] rd;

    // ★ 一直统计通道0 的 busy 上升沿（每轮动作恰好一次）
    always @(negedge clk) begin
        if (dut.busy[0] && !busy_prev) busy_edges = busy_edges + 1;
        busy_prev = dut.busy[0];
    end

    task automatic chk(input string tag, input integer got, input integer exp);
        begin
            if (got === exp) begin
                n_pass = n_pass + 1;
                $display("  [PASS] %-36s got=%0d", tag, got);
            end else begin
                n_fail = n_fail + 1;
                $display("  [FAIL] %-36s got=%0d  exp=%0d", tag, got, exp);
            end
        end
    endtask

    // 允许误差的检查（时序类）
    task automatic chk_rng(input string tag, input integer got, input integer exp, input integer tol);
        begin
            if ((got >= exp - tol) && (got <= exp + tol)) begin
                n_pass = n_pass + 1;
                $display("  [PASS] %-36s got=%0d  exp=%0d±%0d", tag, got, exp, tol);
            end else begin
                n_fail = n_fail + 1;
                $display("  [FAIL] %-36s got=%0d  exp=%0d±%0d", tag, got, exp, tol);
            end
        end
    endtask

    //------------------------------------------------------------------
    // AXI-Lite 读写
    //------------------------------------------------------------------
    task automatic axi_wr(input [7:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            awaddr = a; awvalid = 1'b1;
            wdata  = d; wvalid  = 1'b1;
            while (!(awready && wready)) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            awvalid = 1'b0; wvalid = 1'b0;
            while (!bvalid) begin @(posedge clk); #1; end
            bready = 1'b1;
            @(posedge clk); #1;
            bready = 1'b0;
        end
    endtask

    task automatic axi_rd(input [7:0] a, output [31:0] d);
        begin
            @(posedge clk); #1;
            araddr = a; arvalid = 1'b1;
            while (!arready) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            arvalid = 1'b0;
            while (!rvalid) begin @(posedge clk); #1; end
            d = rdata;
            rready = 1'b1;
            @(posedge clk); #1;
            rready = 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // 量波形：高电平拍数 + 周期拍数（negedge 采样，显式检测低→高）
    //------------------------------------------------------------------
    task automatic probe(input integer ch, output integer hi, output integer per);
        integer t0, t1;
        reg     prev;
        begin
            @(negedge clk);
            prev = servo[ch];
            forever begin
                @(negedge clk);
                if (servo[ch] === 1'b1 && prev === 1'b0) break;
                prev = servo[ch];
            end
            t0 = $time; hi = 0;
            while (servo[ch] === 1'b1) begin
                hi = hi + 1;
                @(negedge clk);
            end
            prev = 1'b0;
            forever begin
                @(negedge clk);
                if (servo[ch] === 1'b1 && prev === 1'b0) break;
                prev = servo[ch];
            end
            t1  = $time;
            per = (t1 - t0) / CLK_NS;
        end
    endtask

    //------------------------------------------------------------------
    // 跟踪通道0 的完整动作：返回"开始偏转"和"回到中位"各自的时刻（单位：拍，从 KICK 起算）
    //   做法：每 100 拍读一次 PW0_EFF（0x40），看它什么时候从 1500 跳到 1800、再回到 1500。
    //   ★ 用 PWn_EFF 而不是量波形：PWM 周期 20 ms 比整个动作还长，量波形根本跟不上。
    //------------------------------------------------------------------
    task automatic trace0(output integer t_out, output integer t_back);
        integer t, prevv, curv;
        begin
            t_out = -1; t_back = -1; t = 0;
            axi_rd(8'h40, rd); prevv = rd;               // 当前有效脉宽（应 = 中位）
            while (t < 40 * MS && t_back < 0) begin
                repeat (100) @(negedge clk);             // 等 100 拍再看一次
                t = t + 100;
                axi_rd(8'h40, rd); curv = rd;
                if (t_out < 0 && prevv == PW_DEF && curv > PW_DEF) t_out = t;  // 跳到偏位
                if (t_out >= 0 && curv == PW_DEF && prevv != PW_DEF) t_back = t; // 回到中位
                prevv = curv;
            end
        end
    endtask

    //------------------------------------------------------------------
    // 主流程
    //------------------------------------------------------------------
    integer ch, t_out, t_back;

    initial begin
        $display("==================== tb_servo_pwm v2 开始 ====================");

        rstn = 1'b0;
        repeat (5) @(posedge clk);
        #1 rstn = 1'b1;
        repeat (5) @(posedge clk);

        // ---- ① ID ----
        axi_rd(8'h00, rd); chk("ID 读回", rd[31:0], 32'h53525630);

        // ---- ② 复位默认值 ----
        chk("复位后 servo_o", servo, 3'b000);
        axi_rd(8'h30, rd); chk("复位后 STATUS", rd, 0);
        axi_rd(8'h08, rd); chk("默认 PW0_ACT", rd, PW_DEF);
        axi_rd(8'h14, rd); chk("默认 PW0_IDLE", rd, PW_DEF);
        axi_rd(8'h20, rd); chk("默认 T_DLY", rd, TDLY_D);
        axi_rd(8'h24, rd); chk("默认 T_ACT", rd, TACT_D);
        axi_rd(8'h28, rd); chk("默认 T_RET", rd, TRET_D);
        axi_rd(8'h34, rd); chk("默认 PW_MIN", rd, PWMIN_D);
        axi_rd(8'h38, rd); chk("默认 PW_MAX", rd, PWMAX_D);
        axi_rd(8'h40, rd); chk("默认 PW0_EFF", rd, PW_DEF);

        // ---- ③ 使能后三路都是中位 ----
        axi_wr(8'h04, 32'h0000_0001);
        repeat (20) @(negedge clk);
        for (ch = 0; ch < 3; ch = ch + 1) begin
            probe(ch, hi_cnt, per_cnt);
            chk($sformatf("通道%0d 高电平拍数(中位)", ch), hi_cnt, PW_DEF);
            chk($sformatf("通道%0d 周期拍数",        ch), per_cnt, PERIOD);
        end

        // ---- ④ 配置一次快速动作：延时 5 ms / 保持 10 ms / 恢复 4 ms ----
        axi_wr(8'h38, 32'd2200);                 // PW_MAX = 2200（允许 1800 不被打回 2000 的旧限幅）
        axi_wr(8'h08, 32'd1800);                 // PW0_ACT  = 1800
        axi_wr(8'h14, 32'd1500);                 // PW0_IDLE = 1500
        axi_wr(8'h20, 32'd5);                    // T_DLY = 5 ms
        axi_wr(8'h24, 32'd10);                   // T_ACT = 10 ms
        axi_wr(8'h28, 32'd4);                    // T_RET = 4 ms
        axi_rd(8'h40, rd); chk("踢之前 PW0_EFF", rd, PW_DEF);

        // ★ 踢一脚，跟踪整条动作曲线
        axi_wr(8'h2C, 32'h0000_0001);            // KICK bit0
        axi_rd(8'h30, rd); chk("踢后 STATUS 忙位", rd & 3'h7, 3'b001);
        trace0(t_out, t_back);
        chk_rng("开始偏转时刻(拍)", t_out,  5 * MS, 400);
        chk_rng("回到中位时刻(拍)", t_back, 19 * MS, 600);
        axi_rd(8'h30, rd); chk("动作结束后 STATUS", rd, 0);
        axi_rd(8'h40, rd); chk("动作结束后 PW0_EFF", rd, PW_DEF);
        axi_rd(8'h44, rd); chk("通道1 全程未动", rd, PW_DEF);
        axi_rd(8'h48, rd); chk("通道2 全程未动", rd, PW_DEF);

        // ---- ⑤ 限幅：上限 2000 时，偏位写 2400 实际只出 2000 ----
        axi_wr(8'h38, 32'd2000);                 // PW_MAX = 2000
        axi_wr(8'h08, 32'd2400);                 // PW0_ACT 写 2400（超上限）
        axi_wr(8'h24, 32'd2);                    // T_ACT = 2 ms
        axi_wr(8'h28, 32'd0);                    // T_RET = 0（直接回中位，方便快速测）
        axi_wr(8'h2C, 32'd1);                    // KICK
        // ★ 时序：T_DLY 仍是 5 ms、T_ACT=2 ms、T_RET=0 ⇒ 5~7 ms 之间在偏位，
        //   7 ms 那一刻就回中位了。所以必须取 6 ms 这个"还在偏位"的点去读。
        repeat (6 * MS) @(negedge clk);          // 停在偏位保持期内
        axi_rd(8'h40, rd);
        chk("限幅后偏位实际输出", rd, 2000);
        repeat (5 * MS) @(negedge clk);
        axi_rd(8'h40, rd); chk("T_RET=0 已直接回中位", rd, PW_DEF);

        // ---- ⑥ 限幅：下限 1600 时中位 1500 被抬到 1600 ----
        axi_wr(8'h34, 32'd1600);                 // PW_MIN = 1600
        repeat (5) @(negedge clk);
        axi_rd(8'h40, rd); chk("下限抬高中位", rd, 1600);
        axi_wr(8'h34, 32'd1000);                 // 还原
        repeat (5) @(negedge clk);
        axi_rd(8'h40, rd); chk("还原下限后中位", rd, PW_DEF);

        // ---- ⑦ 三个时间全 0 ⇒ 踢了也不动 ----
        axi_wr(8'h08, 32'd1800);                 // PW0_ACT = 1800
        axi_wr(8'h20, 32'd0);                    // T_DLY = 0
        axi_wr(8'h24, 32'd0);                    // T_ACT = 0
        axi_wr(8'h28, 32'd0);                    // T_RET = 0
        axi_wr(8'h2C, 32'd1);                    // KICK
        repeat (3 * MS) @(negedge clk);
        axi_rd(8'h40, rd); chk("三时间全0时脉宽不变", rd, PW_DEF);
        axi_rd(8'h30, rd); chk("三时间全0时 STATUS", rd, 0);

        // ---- ⑧ 测试模式：三路周期 128 / 64 / 32 拍 ----
        axi_wr(8'h04, 32'h0000_0003);            // CTRL = 使能 + 测试模式
        repeat (200) @(negedge clk);
        probe(0, hi_cnt, per_cnt); chk("测试模式 通道0 周期", per_cnt, (1 << (TEST_HI+1)));
        probe(1, hi_cnt, per_cnt); chk("测试模式 通道1 周期", per_cnt, (1 << (TEST_HI)));
        probe(2, hi_cnt, per_cnt); chk("测试模式 通道2 周期", per_cnt, (1 << (TEST_HI-1)));

        // ---- ⑨ 关使能 ----
        axi_wr(8'h04, 32'h0000_0000);
        repeat (200) @(negedge clk);
        chk("关使能后 servo_o", servo, 3'b000);

        // ---- ⑩ ★ 三路时间参数逐路独立（2026-10-29 新增能力，寄存器 0x4C~0x6C）----
        //   证明四件事：
        //     ① 写全局 0x20/0x24/0x28 ⇒ 三路**同时**跟着变（向后兼容，老 PS 代码不用改）
        //     ② 写某一路（如 0x50 = 通道1 延时）⇒ **只有那一路变**，另两路不动
        //     ③ 三路保持 / 斜坡 同样各自独立
        //     ④ 真的跑起来：三路给不同 T_DLY，同时 KICK 后"开始偏转的时刻"各不相同
        axi_wr(8'h04, 32'h0000_0001);            // 重新使能（正常 PWM）
        axi_wr(8'h08, 32'd1800);                 // PW0_ACT
        axi_wr(8'h0C, 32'd1800);                 // PW1_ACT
        axi_wr(8'h10, 32'd1800);                 // PW2_ACT
        axi_wr(8'h34, 32'd1000);                 // PW_MIN 还原
        axi_wr(8'h38, 32'd2000);                 // PW_MAX 还原
        repeat (5) @(negedge clk);

        // ① 写全局 ⇒ 三路一起变（0x4C/0x50/0x54 都要读到同一个值）
        axi_wr(8'h20, 32'd700);                  // T_DLY = 700（全局，应扇出到三路）
        repeat (5) @(negedge clk);
        axi_rd(8'h4C, rd); chk("全局写后 ch0 延时", rd, 700);
        axi_rd(8'h50, rd); chk("全局写后 ch1 延时", rd, 700);
        axi_rd(8'h54, rd); chk("全局写后 ch2 延时", rd, 700);

        // ② 只改 ch1（0x50）⇒ ch0 / ch2 保持 700
        axi_wr(8'h50, 32'd300);                  // 只改通道1 的延时
        repeat (5) @(negedge clk);
        axi_rd(8'h4C, rd); chk("单改ch1后 ch0 延时不变", rd, 700);
        axi_rd(8'h50, rd); chk("单改ch1后 ch1 延时=300", rd, 300);
        axi_rd(8'h54, rd); chk("单改ch1后 ch2 延时不变", rd, 700);

        // ③ 保持（0x58/0x5C/0x60）与斜坡（0x64/0x68/0x6C）同样独立
        axi_wr(8'h24, 32'd50);                   // 全局 T_ACT = 50
        axi_wr(8'h28, 32'd20);                   // 全局 T_RET = 20
        repeat (5) @(negedge clk);
        axi_rd(8'h58, rd); chk("全局写后 ch0 保持", rd, 50);
        axi_rd(8'h60, rd); chk("全局写后 ch2 保持", rd, 50);
        axi_rd(8'h6C, rd); chk("全局写后 ch2 斜坡", rd, 20);
        axi_wr(8'h60, 32'd999);                  // 只改通道2 的保持
        repeat (5) @(negedge clk);
        axi_rd(8'h58, rd); chk("单改ch2后 ch0 保持不变", rd, 50);
        axi_rd(8'h5C, rd); chk("单改ch2后 ch1 保持不变", rd, 50);
        axi_rd(8'h60, rd); chk("单改ch2后 ch2 保持=999", rd, 999);
        axi_wr(8'h64, 32'd77);                   // 只改通道0 的斜坡
        repeat (5) @(negedge clk);
        axi_rd(8'h64, rd); chk("单改ch0后 ch0 斜坡=77", rd, 77);
        axi_rd(8'h68, rd); chk("单改ch0后 ch1 斜坡不变", rd, 20);
        axi_rd(8'h6C, rd); chk("单改ch0后 ch2 斜坡不变", rd, 20);

        // ④ 行为验证：ch0 延时 2ms / ch1 6ms / ch2 10ms，保持都 2ms、斜坡都 0
        //    ⇒ 同时 KICK 之后，三路的"偏位窗口"分别是 [2,4] [6,8] [10,12] ms
        axi_wr(8'h4C, 32'd2);                    // ch0 延时 2 ms
        axi_wr(8'h50, 32'd6);                    // ch1 延时 6 ms
        axi_wr(8'h54, 32'd10);                   // ch2 延时 10 ms
        axi_wr(8'h58, 32'd2);                    // ch0 保持 2 ms
        axi_wr(8'h5C, 32'd2);                    // ch1 保持 2 ms
        axi_wr(8'h60, 32'd2);                    // ch2 保持 2 ms
        axi_wr(8'h64, 32'd0);                    // ch0 斜坡 0（直接回中，方便判点）
        axi_wr(8'h68, 32'd0);                    // ch1 斜坡 0
        axi_wr(8'h6C, 32'd0);                    // ch2 斜坡 0
        axi_wr(8'h2C, 32'h0000_0007);            // ★ 三路同时 KICK
        repeat (3 * MS) @(negedge clk);          // t = 3 ms
        axi_rd(8'h40, rd); chk("t=3ms ch0 已偏位", rd, 1800);
        axi_rd(8'h44, rd); chk("t=3ms ch1 仍在延时", rd, PW_DEF);
        axi_rd(8'h48, rd); chk("t=3ms ch2 仍在延时", rd, PW_DEF);
        repeat (4 * MS) @(negedge clk);          // t = 7 ms
        axi_rd(8'h40, rd); chk("t=7ms ch0 已回中", rd, PW_DEF);
        axi_rd(8'h44, rd); chk("t=7ms ch1 已偏位", rd, 1800);
        axi_rd(8'h48, rd); chk("t=7ms ch2 仍在延时", rd, PW_DEF);
        repeat (4 * MS) @(negedge clk);          // t = 11 ms
        axi_rd(8'h40, rd); chk("t=11ms ch0 已回中", rd, PW_DEF);
        axi_rd(8'h44, rd); chk("t=11ms ch1 已回中", rd, PW_DEF);
        axi_rd(8'h48, rd); chk("t=11ms ch2 已偏位", rd, 1800);

        // ---- ⑪ ★ 2026-10-30 新增：PWM 周期边界锁存（治"中途改脉宽产生第二个脉冲 ⇒ 抖动"）----
        //   机理：pwm_i = (p_cnt < c)，c 由脉宽组合算出。脉宽在一个周期中途变大时，
        //   (p_cnt < c) 会再次成立 ⇒ 本周期出现第二个高电平 ⇒ 舵机收到畸形帧 ⇒ 抖。
        //   修法：只在 p_cnt==0 把 pw0_q 锁进 pw0_s，用 pw0_s 参与比较。
        //   ★ 刺激怎么选：不能写 PW0_ACT（待机时 pw0_q 跟的是**中位 1500**，写了也不变），
        //     要改的是 **PW_MIN 限幅** —— 抬到 1600 会把待机的 1500 抬成 1600，
        //     这样 pw0_q 在周期中途真的变了，正好检验锁存有没有拦住它。
        while (dut.busy[0]) @(negedge clk);      // 等通道0 回到待机
        axi_wr(8'h34, 32'd1000);                 // PW_MIN = 1000（先保证中位 1500 不被限）
        axi_wr(8'h38, 32'd2000);                 // PW_MAX = 2000
        repeat (3) @(negedge clk);
        while (dut.p_cnt < 21'd5000) @(negedge clk);   // ★ 停在本周期"高电平已结束"的位置
        axi_wr(8'h34, 32'd1600);                 // 周期中途抬下限 ⇒ pw0_q 应由 1500 变 1600
        repeat (4) @(negedge clk);               // 给 pw0_q 两拍去更新
        chk("中途改脉宽：指令值 pw0_q 已变", dut.pw0_q, 1600);
        chk("中途改脉宽：比较用 pw0_s 仍锁着", dut.pw0_s, 1500);   // ★ 关键：没被中途改动
        while (dut.p_cnt != 21'd0) @(negedge clk);     // 等下一个周期起点
        repeat (4) @(negedge clk);               // 边界后 pw0_s 才更新
        chk("过了周期边界：pw0_s 跟上新值", dut.pw0_s, 1600);
        axi_wr(8'h34, 32'd1000);                 // 还原下限
        repeat (4) @(negedge clk);

        // 顺带用真实波形复核：整周期不该被切碎（per 必须还是 20000）
        probe(0, hi_cnt, per_cnt);
        chk("周期边界锁存后 PWM 周期完好", per_cnt, PERIOD);

        // ---- ⑫ ★ 2026-10-30 新增：忙时来的 kick 进队列、不丢弃 ----
        //   原来 kick 只在 S_IDLE 被采样 ⇒ 舵机还在上一轮动作时来的请求被静默丢掉。
        //   现在：非 IDLE 时 pending++（饱和 3），回到 S_IDLE 立刻取出来接着做。
        while (dut.busy[0]) @(negedge clk);      // 等通道0 空闲
        axi_wr(8'h08, 32'd1800);                 // PW0_ACT
        axi_wr(8'h4C, 32'd5);                    // ch0 延时 5 ms
        axi_wr(8'h58, 32'd2);                    // ch0 保持 2 ms
        axi_wr(8'h64, 32'd0);                    // ch0 斜坡 0  ⇒ 一轮约 7 ms
        repeat (3) @(negedge clk);
        e0 = busy_edges;                         // ★ 在**第 1 次 kick 之前**记基线
        axi_wr(8'h2C, 32'h1);                    // 第 1 次 kick（立即执行）
        repeat (1 * MS) @(negedge clk);          // 1 ms 后（还在延时中）
        axi_wr(8'h2C, 32'h1);                    // 第 2 次 kick ⇒ 应进队列
        repeat (1 * MS) @(negedge clk);
        axi_wr(8'h2C, 32'h1);                    // 第 3 次 kick ⇒ 应进队列
        repeat (2) @(negedge clk);
        axi_rd(8'h30, rd);
        chk("忙时两次 kick ⇒ ch0 队列 = 2", (rd >> 6) & 3'h3, 2);
        // 数 busy 上升沿：应该能看到 3 轮动作（基线已在第 1 次 kick 之前取）
        repeat (30 * MS) @(negedge clk);         // 30 ms 足够跑完 3 轮（每轮约 7 ms）
        chk("三轮动作都执行了（busy 上升沿）", busy_edges - e0, 3);
        axi_rd(8'h30, rd);
        chk("三轮跑完后 ch0 队列清空", (rd >> 6) & 3'h3, 0);
        chk("三轮跑完后 ch0 不再忙", (rd & 3'h1), 0);

        // ---- 收尾 ----
        $display("==========================================================");
        if (n_fail == 0) $display("==== PASS：%0d 项全部通过 ====", n_pass);
        else             $display("==== FAIL：%0d 项失败 / %0d 项通过 ====", n_fail, n_pass);
        $display("==========================================================");
        $finish;
    end

    // 总超时保护（乘积必须 < 2.1e9，否则 #() 溢出成负延时）
    initial begin
        #(CLK_NS * 900_000);                     // 90 万拍上限
        $display("!! 超时退出：仿真跑超了 90 万拍，检查是否有死等");
        $finish;
    end

endmodule
