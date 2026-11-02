//=============================================================================
// tb_dd_osd_axis.v —— dd_osd_axis 的自检式 testbench（2026-10-20 新增）
//
// 【它验什么】五个用例，每个都手算期望值，不靠"跑通就算对"：
//   A) ID 读回        → 0x4F534432（证明 AXI-Lite 读通路活着）
//   B) 旁路           → CTRL=0 时输出逐像素等于输入，tlast/tuser 位置一模一样，延迟 2 拍
//   C) 只画绿框       → 四条边带上手算出的 4 个点必须是绿、框内 1 点必须原样、全帧无白点
//   D) 框 + 白字      → 文字区内出现白点，且绿框仍在
//   E) 带反压重跑 C   → 输出序列与 C 的完全一致（证明反压不丢帧、不重复）
//
// 【为什么这么写】
//   · FB-1 教训：手算期望值写进 TB，而不是拿 DUT 输出反推期望。
//   · 边框几何按 dd_osd.v 第 169~174 行的条件手工推：
//       上下边带 row ∈ {by, by+1} / {y1k-1, y1k}，左右边带 col ∈ {bx, bx+1} / {x1k-1, x1k}
//   · 反压用例是这类流水线最容易错的地方（丢/重/错位），必须单独验。
//=============================================================================
`timescale 1ns / 1ps

module tb_dd_osd_axis;

    // ---------------- 帧尺寸与测试常量 ----------------
    localparam W     = 40;                                  // 测试帧宽（像素）
    localparam H     = 24;                                  // 测试帧高（行）
    localparam NPIX  = W * H;                               // 一帧像素数

    localparam [23:0] C_GREEN = 24'h00FC00;                 // 可回收 = 绿
    localparam [23:0] C_RED   = 24'hF80000;                 // 不可回收 = 红
    localparam [23:0] C_WHITE = 24'hFFFFFF;                 // 文字恒白

    // 框参数（用例 C/D/E 共用）
    localparam BX = 4, BY = 8, BW = 10, BH = 6;             // 左上角 (4,8)，宽 10、高 6
    localparam X1K = BX + BW;                               // 右边界 = 14
    localparam Y1K = BY + BH;                               // 下边界 = 14

    // ---------------- DUT 连线 ----------------
    reg         clk   = 1'b0;                               // 100MHz
    reg         rstn  = 1'b0;                               // 低有效复位
    always #5 clk = ~clk;                                   // 半周期 5ns ⇒ 100MHz

    reg  [23:0] s_tdata  = 24'd0;                           // AXIS 从口：像素
    reg         s_tvalid = 1'b0;                            // AXIS 从口：有像素
    reg         s_tlast  = 1'b0;                            // AXIS 从口：行尾
    reg         s_tuser  = 1'b0;                            // AXIS 从口：帧首
    wire        s_tready;                                   // AXIS 从口：能收

    wire [23:0] m_tdata;                                    // AXIS 主口：像素
    wire        m_tvalid;                                   // AXIS 主口：有像素
    wire        m_tlast;                                    // AXIS 主口：行尾
    wire        m_tuser;                                    // AXIS 主口：帧首
    reg         m_tready = 1'b1;                            // AXIS 主口：下游能收（默认一直收）
    reg         bp_en    = 1'b0;                            // 反压发生器开关（用例 E 才打开）
    integer     bp_t     = 0;                               // 反压发生器的拍计数

    reg  [11:0] awaddr  = 12'd0;                            // AXI-Lite：写地址
    reg         awvalid = 1'b0;                             // AXI-Lite：写地址有效
    wire        awready;                                    // AXI-Lite：能收地址
    reg  [31:0] wdata   = 32'd0;                            // AXI-Lite：写数据
    reg         wvalid  = 1'b0;                             // AXI-Lite：写数据有效
    wire        wready;                                     // AXI-Lite：能收数据
    wire [1:0]  bresp;                                      // AXI-Lite：写响应
    wire        bvalid;                                     // AXI-Lite：写响应有效
    reg         bready  = 1'b1;                             // AXI-Lite：主机一直取响应
    reg  [11:0] araddr  = 12'd0;                            // AXI-Lite：读地址
    reg         arvalid = 1'b0;                             // AXI-Lite：读地址有效
    wire        arready;                                    // AXI-Lite：能收读地址
    wire [31:0] rdata;                                      // AXI-Lite：读数据
    wire [1:0]  rresp;                                      // AXI-Lite：读响应
    wire        rvalid;                                     // AXI-Lite：读数据有效
    reg         rready  = 1'b1;                             // AXI-Lite：主机一直取读数据

    dd_osd_axis #(
        .N_BOX   (8),                                       // 与 BD 里保持一致
        .MAX_CHAR(16),
        .THICK   (2)                                        // 框线 2 像素
    ) dut (
        .aclk         (clk),
        .aresetn      (rstn),
        .s_axis_tdata (s_tdata),
        .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready),
        .s_axis_tlast (s_tlast),
        .s_axis_tuser (s_tuser),
        .m_axis_tdata (m_tdata),
        .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready),
        .m_axis_tlast (m_tlast),
        .m_axis_tuser (m_tuser),
        .s_axi_awaddr (awaddr),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata  (wdata),
        .s_axi_wstrb  (4'hF),
        .s_axi_wvalid (wvalid),
        .s_axi_wready (wready),
        .s_axi_bresp  (bresp),
        .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata  (rdata),
        .s_axi_rresp  (rresp),
        .s_axi_rvalid (rvalid),
        .s_axi_rready (rready)
    );

    // ---------------- 输入像素表 / 输出采集 ----------------
    reg [23:0] in_pix  [0:NPIX-1];                          // 送进去的像素
    reg [23:0] out_pix [0:NPIX-1];                          // 抓到的输出像素
    reg        out_l   [0:NPIX-1];                          // 抓到的 tlast
    reg        out_u   [0:NPIX-1];                          // 抓到的 tuser
    reg [23:0] ref_pix [0:NPIX-1];                          // 用例 C 的输出（给 E 当基准）
    integer    n_out;                                       // 已抓到的像素数
    integer    fails;                                       // 失败计数
    integer    checks;                                      // 检查计数

    // 反压发生器：只在用例 E 打开，每 7 拍卡 2 拍（简单可复现，比随机更利于查错）
    always @(negedge clk) begin
        if (bp_en) begin
            bp_t     = bp_t + 1;                            // 拍计数
            m_tready = ((bp_t % 7) != 0) && ((bp_t % 7) != 3);  // 每 7 拍里有 2 拍不收
        end else begin
            m_tready = 1'b1;                                // 平时一直收
        end
    end

    // 输出监视：只在 m_tvalid 且 m_tready 那一拍收一个像素（AXIS 语义）
    always @(posedge clk) begin
        if (m_tvalid && m_tready && (n_out < NPIX)) begin
            out_pix[n_out] = m_tdata;                       // 收像素
            out_l[n_out]   = m_tlast;                       // 收 tlast
            out_u[n_out]   = m_tuser;                       // 收 tuser
            n_out          = n_out + 1;                     // 计数
        end
    end

    // ---------------- 通用检查任务 ----------------
    task check_pix(input integer idx, input [23:0] exp, input [127:0] what);
        begin
            checks = checks + 1;                            // 检查数 +1
            if (out_pix[idx] !== exp) begin
                fails = fails + 1;                          // 记一次失败
                $display("  FAIL [%0s] 像素 #%0d: 得到 %06h，期望 %06h", what, idx, out_pix[idx], exp);
            end
        end
    endtask

    task check_int(input integer got, input integer exp, input [127:0] what);
        begin
            checks = checks + 1;                            // 检查数 +1
            if (got !== exp) begin
                fails = fails + 1;                          // 记一次失败
                $display("  FAIL [%0s] 得到 %0d，期望 %0d", what, got, exp);
            end
        end
    endtask

    // ---------------- AXI-Lite 写任务 ----------------
    task axi_write(input [11:0] a, input [31:0] d);
        begin
            @(negedge clk);
            awaddr  = a;      awvalid = 1'b1;               // 同时给出地址
            wdata   = d;      wvalid  = 1'b1;               // 和数据（两半一起到）
            @(negedge clk);
            awvalid = 1'b0;   wvalid  = 1'b0;               // 握手完成，撤掉请求
            repeat (4) @(negedge clk);                      // 等 bvalid 走完
        end
    endtask

    // ---------------- AXI-Lite 读任务 ----------------
    task axi_read(input [11:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr  = a;      arvalid = 1'b1;               // 给出读地址
            @(negedge clk);
            arvalid = 1'b0;                                 // 地址已被接受
            wait (rvalid === 1'b1);                         // 等数据回来
            #1 d = rdata;                                   // 采样（错开半拍避免竞争）
            @(negedge clk);
        end
    endtask

    // ---------------- 送一帧 ----------------
    task drive_frame;
        integer i;                                          // 像素序号
        integer c;                                          // 当前列
        integer tw;                                         // 排空超时计数
        begin
            i = 0;                                          // 从第一个像素开始
            while (i < NPIX) begin                          // ★ 必须按 s_tready 握手，绝不能盲发
                @(negedge clk);                             // 下降沿驱动，避开建立/保持竞争
                s_tdata  = in_pix[i];                       // 送这一像素
                s_tvalid = 1'b1;                            // 有效
                c        = i % W;                           // 当前列
                s_tlast  = (c == W - 1);                    // 每行最后一个
                s_tuser  = (i == 0);                        // 全帧第一个
                @(posedge clk);                             // 到上升沿看这一拍握手成不成
                if (s_tready) i = i + 1;                    // ★ 被接收才换下一个；没接收就继续扛着
            end
            @(negedge clk);
            s_tvalid = 1'b0;  s_tlast = 1'b0;  s_tuser = 1'b0;  // 帧结束，撤掉 valid
            tw = 0;                                         // 超时计数清零
            while ((n_out < NPIX) && (tw < 20000)) begin    // 等两级流水把像素全部吐出来
                @(negedge clk);
                tw = tw + 1;
            end
            repeat (4) @(negedge clk);                      // 再稳几拍
        end
    endtask

    // ---------------- 复位 + 清采集 ----------------
    task do_reset;
        begin
            rstn = 1'b0;                                    // 拉低复位
            s_tvalid = 1'b0;  s_tlast = 1'b0;  s_tuser = 1'b0;
            repeat (3) @(negedge clk);                      // 保持几个周期
            rstn = 1'b1;                                    // 放开
            repeat (2) @(negedge clk);
            n_out = 0;                                      // 清输出计数
        end
    endtask

    // ---------------- 统计某种颜色出现次数 ----------------
    function integer count_color(input [23:0] col);
        integer i;                                          // 循环变量
        begin
            count_color = 0;                                // 从 0 开始数
            for (i = 0; i < NPIX; i = i + 1)
                if (out_pix[i] === col) count_color = count_color + 1;  // 命中就 +1
        end
    endfunction

    // ---------------- 统计某矩形区域内某种颜色的像素数 ----------------
    function integer count_color_region(input [23:0] col, input integer c0, input integer r0,
                                        input integer c1, input integer r1);
        integer c, r;                                       // 循环变量
        begin
            count_color_region = 0;                         // 从 0 开始数
            for (r = r0; r <= r1; r = r + 1)
                for (c = c0; c <= c1; c = c + 1)
                    if (out_pix[r * W + c] === col)
                        count_color_region = count_color_region + 1;  // 命中就 +1
        end
    endfunction

    // ---------------- 主流程 ----------------
    integer i, k, t;                                        // 循环变量
    reg [31:0] idval;                                       // 读回的 ID
    reg [23:0] base_word;                                   // 一个 32bit 寄存器值（装 4 个字符）
    initial begin
        fails = 0;  checks = 0;  n_out = 0;

        // ---- 造输入图案：每个像素都不一样，且不会撞上绿/红/白 ----
        for (i = 0; i < NPIX; i = i + 1)
            in_pix[i] = 24'h100000 + i;                     // 0x100000..0x1003BF

        $display("==== tb_dd_osd_axis 开始 ====");

        //=====================================================================
        // 用例 A：ID 读回
        //=====================================================================
        do_reset;
        axi_read(12'h000, idval);
        check_int(idval, 32'h4F534432, "A:ID");

        //=====================================================================
        // 用例 B：旁路 —— CTRL=0，输出逐像素等于输入，sideband 位置不变
        //=====================================================================
        do_reset;
        axi_write(12'h044, 32'h0);                          // CTRL = 0 ⇒ 完全旁路
        drive_frame;
        check_int(n_out, NPIX, "B:像素数");
        for (i = 0; i < NPIX; i = i + 1) begin
            check_pix(i, in_pix[i], "B:旁路像素");           // 逐像素相同
            check_int(out_l[i], (i % W == W - 1), "B:tlast");// 行尾位置不变
            check_int(out_u[i], (i == 0),         "B:tuser");// 帧首位置不变
        end

        //=====================================================================
        // 用例 C：只画绿框（CTRL=1，nchar=0）
        //   框：左上(4,8) 宽10 高6 ⇒ 右边界14、下边界14
        //   边带：上 row∈{8,9}  下 row∈{13,14}  左 col∈{4,5}  右 col∈{13,14}
        //=====================================================================
        do_reset;
        axi_write(12'h048, 32'd1);                                            // N = 1 个框
        axi_write(12'h04C + 12'h000, (BY << 16) | BX);                        // {by,bx}
        axi_write(12'h04C + 12'h004, (BH << 16) | BW);                        // {bh,bw}
        axi_write(12'h04C + 12'h008, (16'd0 << 16) | 16'd0);                  // {ty,tx} 文字不用
        axi_write(12'h04C + 12'h00C, (32'd0 << 2) | 32'd1);                   // nchar=0, color=1(绿)
        axi_write(12'h044, 32'h1);                                            // CTRL=1：只画框
        drive_frame;
        check_int(n_out, NPIX, "C:像素数");
        check_pix(BY * W + BX,        C_GREEN, "C:左边带");   // (col=4,row=8)  左上角
        check_pix(11 * W + BX,        C_GREEN, "C:左边带2");  // (col=4,row=11) 左边中段
        check_pix(BY * W + 9,         C_GREEN, "C:上边带");   // (col=9,row=8)  上边中段
        check_pix(11 * W + X1K,       C_GREEN, "C:右边带");   // (col=14,row=11) 右边界
        check_pix(Y1K * W + 9,        C_GREEN, "C:下边带");   // (col=9,row=14) 下边界
        check_pix(11 * W + 9,         in_pix[11 * W + 9], "C:框内不动");  // (9,11) 内部
        check_pix(0,                  in_pix[0],          "C:远方不动");  // (0,0) 远离
        check_int(count_color(C_WHITE), 0, "C:不应有白点");    // 没写 nchar ⇒ 一个字都不该有
        for (i = 0; i < NPIX; i = i + 1) ref_pix[i] = out_pix[i];  // 存下来给用例 E 用

        //=====================================================================
        // 用例 D：框 + 白字（CTRL=3，nchar=3，文字左上角 (4,16)，写 'A''A''A'）
        //=====================================================================
        do_reset;
        axi_write(12'h048, 32'd1);                                            // N = 1
        axi_write(12'h04C + 12'h000, (BY << 16) | BX);                        // 框位置不变
        axi_write(12'h04C + 12'h004, (BH << 16) | BW);                        // 框大小不变
        axi_write(12'h04C + 12'h008, (16'd16 << 16) | 16'd4);                 // {ty=16, tx=4}
        axi_write(12'h04C + 12'h00C, (32'd3 << 2) | 32'd1);                   // nchar=3, 绿
        for (k = 0; k < 4; k = k + 1) begin                                   // 4 个字符寄存器
            base_word = {8'h41, 8'h41, 8'h41, 8'h41};                         // 全部写 'A'(0x41)
            axi_write(12'h04C + 12'h010 + k * 4, base_word);                  // +0x10/+0x14/+0x18/+0x1C
        end
        axi_write(12'h044, 32'h3);                                            // CTRL=3：框 + 字
        drive_frame;
        check_int(n_out, NPIX, "D:像素数");
        check_pix(11 * W + BX, C_GREEN, "D:框还在");                          // 左边带仍是绿
        // 真正的判据：文字区里必须出现过白点
        checks = checks + 1;
        if (count_color_region(C_WHITE, 4, 16, 27, 23) <= 0) begin
            fails = fails + 1;
            $display("  FAIL [D:白字] 文字区 (col 4..27, row 16..23) 一个白点都没有");
        end
        checks = checks + 1;
        if (count_color_region(C_WHITE, 0, 0, W - 1, 15) != 0) begin         // 文字区之外
            fails = fails + 1;
            $display("  FAIL [D:白字越界] 上半帧出现了 %0d 个白点",
                     count_color_region(C_WHITE, 0, 0, W - 1, 15));
        end

        //=====================================================================
        // 用例 E：带反压重跑用例 C，输出序列必须与 C 完全一致
        //        （反压是这类流水线最容易丢像素/重复/错位的地方）
        //=====================================================================
        do_reset;
        axi_write(12'h048, 32'd1);
        axi_write(12'h04C + 12'h000, (BY << 16) | BX);
        axi_write(12'h04C + 12'h004, (BH << 16) | BW);
        axi_write(12'h04C + 12'h008, (16'd0 << 16) | 16'd0);
        axi_write(12'h04C + 12'h00C, (32'd0 << 2) | 32'd1);
        axi_write(12'h044, 32'h1);
        // 用周期性反压：每 7 拍卡 2 拍（由上面的 bp_en always 块产生，不在本任务里分叉）
        bp_t  = 0;                                            // 反压计数清零
        bp_en = 1'b1;                                         // 打开反压
        drive_frame;                                          // 送帧（drive_frame 内部会等到全部排空）
        bp_en = 1'b0;                                         // 关掉反压
        repeat (10) @(negedge clk);

        check_int(n_out, NPIX, "E:反压下像素数");
        for (i = 0; i < NPIX; i = i + 1) begin
            check_pix(i, ref_pix[i], "E:反压下像素");           // 与用例 C 逐像素一致
            check_int(out_l[i], (i % W == W - 1), "E:反压下 tlast");
            check_int(out_u[i], (i == 0),         "E:反压下 tuser");
        end

        //=====================================================================
        // 汇总
        //=====================================================================
        $display("==== 结束：%0d 次检查，%0d 次失败 ====", checks, fails);
        if (fails == 0) $display("ALL PASS");
        else            $display("HAS FAILURES");
        $finish;
    end

endmodule
