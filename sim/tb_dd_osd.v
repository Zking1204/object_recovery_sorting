`timescale 1ns / 1ps
//=============================================================================
// tb_dd_osd.v —— dd_osd（OSD 叠加）的单元测试台
//
// 判据：**黄金模型逐像素比对**，任何一处不符就打印 FAIL 并累加 errors。
//   黄金模型是**独立写的**（用常量 + 独立的字模表），不复用 RTL 的循环结构，
//   这样 RTL 写错（比如边带范围、优先级、取位方向）一定会被抓到。
//
// 五个用例：
//   A 旁路      ：ctrl=0 ⇒ 每个像素都必须等于输入（保证"一键恢复原样"）
//   B 单框红    ：只有框线区域变红，其余等于输入
//   C 绿框+文字 ：框线绿；文字矩形逐位按字模；其余等于输入
//   D 双框重叠  ：编号小的框优先（应显示红）
//   E 读回      ：写进去的值能原样读出来
//
// 运行： xvlog dd_font_rom.v dd_osd.v tb_dd_osd.v
//        xelab tb_dd_osd -s tb_osd ; xsim tb_osd -R
//=============================================================================
module tb_dd_osd;

    localparam W = 48;                                      // 测试画面宽（列）
    localparam H = 48;                                      // 测试画面高（行）

    // ---- 颜色常量（与 RTL 同一个约定：RGB565 左对齐补 0）----
    localparam [23:0] RED   = 24'hF8_00_00;                 // 红（不可回收）
    localparam [23:0] GREEN = 24'h00_FC_00;                 // 绿（可回收）
    localparam [23:0] WHITE = 24'hFF_FF_FF;                 // 文字白

    reg         clk, rstn;
    reg  [23:0] pix_in;
    reg  [10:0] col;
    reg  [9:0]  row;
    reg         wr_en;
    reg  [11:0] wr_addr;
    reg  [31:0] wr_data;
    reg  [6:0]  rd_idx;
    wire [31:0] rd_data;
    wire [23:0] pix_out;

    integer errors;                                         // 失败计数
    integer checks;                                         // 比对计数（覆盖率自证）

    // ---- 被测模块 ----
    dd_osd #(.N_BOX(8), .MAX_CHAR(16), .THICK(2)) dut (
        .clk     (clk),
        .rstn    (rstn),
        .en      (1'b1),                                    // 本测试台不模拟反压，流水常开
        .pix_in  (pix_in),
        .col     (col),
        .row     (row),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_idx  (rd_idx),
        .rd_data (rd_data),
        .pix_out (pix_out)
    );

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //=====================================================================
    // 独立黄金字模：只放本次要验证的两个字符（其余一律 0）
    //   'A' = 0x41 / 'b' = 0x62 的字形来自字体渲染结果，手抄进本表
    //=====================================================================
    function [7:0] gold_glyph;
        input [7:0] ch;
        input [3:0] rr;
        begin
            gold_glyph = 8'h00;                             // 默认空
            if (ch == 8'h41) begin                          // 'A'
                case (rr)
                    4'd1: gold_glyph = 8'h18;               // ...##...
                    4'd2: gold_glyph = 8'h28;               // ..#.#...
                    4'd3: gold_glyph = 8'h28;               // ..#.#...
                    4'd4: gold_glyph = 8'h6C;               // .##.##..
                    4'd5: gold_glyph = 8'h44;               // .#...#..
                    4'd6: gold_glyph = 8'h44;               // .#...#..
                    4'd7: gold_glyph = 8'hFE;               // #######.
                    4'd8: gold_glyph = 8'h82;               // #.....#.
                    4'd9: gold_glyph = 8'h82;               // #.....#.
                    default: gold_glyph = 8'h00;
                endcase
            end else if (ch == 8'h62) begin                 // 'b'
                case (rr)
                    4'd0: gold_glyph = 8'h40;               // .#......
                    4'd1: gold_glyph = 8'h40;               // .#......
                    4'd2: gold_glyph = 8'h40;               // .#......
                    4'd3: gold_glyph = 8'h5C;               // .#.###..
                    4'd4: gold_glyph = 8'h66;               // .##..##.
                    4'd5: gold_glyph = 8'h42;               // .#....#.
                    4'd6: gold_glyph = 8'h42;               // .#....#.
                    4'd7: gold_glyph = 8'h42;               // .#....#.
                    4'd8: gold_glyph = 8'h44;               // .#...#..
                    4'd9: gold_glyph = 8'h78;               // .####...
                    default: gold_glyph = 8'h00;
                endcase
            end
        end
    endfunction

    //=====================================================================
    // 测试激励：写一个 32 位寄存器
    //=====================================================================
    task wr;
        input [11:0] a;
        input [31:0] d;
        begin
            @(negedge clk);                                 // 负沿摆好
            wr_addr = a;  wr_data = d;  wr_en = 1'b1;       // 有效一拍
            @(negedge clk);                                 // 已过正沿 ⇒ 提交完成
            wr_en = 1'b0;
        end
    endtask

    //=====================================================================
    // 定义一个框（写 8 个字）
    //=====================================================================
    task def_box;
        input [8:0] base;                                   // 框基址（字节）
        input [15:0] bx;
        input [15:0] by;
        input [15:0] bw;
        input [15:0] bh;
        input [15:0] tx;
        input [15:0] ty;
        input [1:0]  color;
        input [4:0]  nchar;
        input [31:0] w3;                                    // 字符 0~3 打包
        input [31:0] w4;                                    // 字符 4~7 打包
        input [31:0] w5;                                    // 字符 8~11 打包
        input [31:0] w6;                                    // 字符 12~15 打包
        begin
            wr(base + 12'd0, {by[15:0], bx[15:0]});         // 位置
            wr(base + 12'd4, {bh[15:0], bw[15:0]});         // 宽高
            wr(base + 12'd8, {ty[15:0], tx[15:0]});         // 文字位置
            wr(base + 12'd12, {25'd0, nchar, color});       // 字符数 + 颜色
            wr(base + 12'd16, w3);                          // 字符 0~3
            wr(base + 12'd20, w4);                          // 字符 4~7
            wr(base + 12'd24, w5);                          // 字符 8~11
            wr(base + 12'd28, w6);                          // 字符 12~15
        end
    endtask

    //=====================================================================
    // 造一个"永远不会撞上颜色常量"的输入像素，便于识别"是否被改动"
    //=====================================================================
    function [23:0] mk_pix;
        input [10:0] c;
        input [9:0]  r;
        begin
            mk_pix = {8'hA5, c[7:0], r[7:0]};                // 高字节固定 A5，不会等于红/绿/白
        end
    endfunction

    //=====================================================================
    // 用例 A：全部旁路
    //=====================================================================
    integer c, r;
    reg [23:0] exp_pix;

    task case_bypass;
        begin
            wr(12'h44, 32'h0);                              // ctrl = 0
            wr(12'h48, 32'h0);                              // 框数 = 0
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    @(negedge clk);
                    col = c[10:0];  row = r[9:0];  pix_in = mk_pix(c[10:0], r[9:0]);
                    @(posedge clk);                         // ★ dd_osd 是 1 级流水：正沿采样第 1 级
                    #1;                                     // 等组合稳定
                    checks = checks + 1;
                    if (pix_out !== pix_in) begin           // 必须逐像素等于输入
                        $display("FAIL[A] col=%0d row=%0d got=%h want=%h", c, r, pix_out, pix_in);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    //=====================================================================
    // 用例 B：单个红框（bx=10,by=4,bw=20,bh=10 ⇒ x0=10,x1=30,y0=4,y1=14，线宽 2）
    //=====================================================================
    task case_box_red;
        begin
            def_box(12'h4C, 16'd10, 16'd4, 16'd20, 16'd10, 16'd0, 16'd0,
                    2'd0, 5'd0, 32'h0, 32'h0, 32'h0, 32'h0);
            wr(12'h48, 32'd1);                              // 框数 = 1
            wr(12'h44, 32'd1);                              // ctrl = 画框
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    @(negedge clk);
                    col = c[10:0];  row = r[9:0];  pix_in = mk_pix(c[10:0], r[9:0]);
                    @(posedge clk);                         // ★ dd_osd 是 1 级流水：正沿采样第 1 级
                    #1;
                    // ---- 黄金模型：独立用常量写 ----
                    exp_pix = pix_in;                       // 默认不变
                    if (((c >= 10) && (c <= 30) && (((r >= 4) && (r < 6))  || ((r > 12) && (r <= 14)))) ||
                        ((r >= 4)  && (r <= 14) && (((c >= 10) && (c < 12)) || ((c > 28) && (c <= 30)))))
                        exp_pix = RED;                      // 落在边带 ⇒ 红
                    checks = checks + 1;
                    if (pix_out !== exp_pix) begin
                        $display("FAIL[B] col=%0d row=%0d got=%h want=%h", c, r, pix_out, exp_pix);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    //=====================================================================
    // 用例 C：绿框 + 文字（'A','b'），文字矩形 tx=10,ty=16,nchar=2
    //=====================================================================
    reg [23:0] gg;
    reg        dot_ok;
    integer    ci, cc, rr2;

    task case_box_text;
        begin
            def_box(12'h4C, 16'd10, 16'd4, 16'd20, 16'd10, 16'd10, 16'd16,
                    2'd1, 5'd2, 32'h20206241, 32'h0, 32'h0, 32'h0);   // 字符0='A', 字符1='b'
            wr(12'h48, 32'd1);                              // 框数 = 1
            wr(12'h44, 32'd3);                              // ctrl = 画框 + 画字
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    @(negedge clk);
                    col = c[10:0];  row = r[9:0];  pix_in = mk_pix(c[10:0], r[9:0]);
                    @(posedge clk);                         // ★ dd_osd 是 1 级流水：正沿采样第 1 级
                    #1;
                    exp_pix = pix_in;                       // 默认不变
                    // ---- 框线优先（绿）----
                    if (((c >= 10) && (c <= 30) && (((r >= 4) && (r < 6))  || ((r > 12) && (r <= 14)))) ||
                        ((r >= 4)  && (r <= 14) && (((c >= 10) && (c < 12)) || ((c > 28) && (c <= 30)))))
                        exp_pix = GREEN;
                    // ---- 其次文字（白）----
                    else if ((r >= 16) && (r < 32) && (c >= 10) && (c < 26)) begin
                        ci  = (c - 10) / 8;                 // 第几个字符
                        cc  = (c - 10) % 8;                 // 字符内列
                        rr2 = r - 16;                       // 字符内行
                        gg  = (ci == 0) ? gold_glyph(8'h41, rr2[3:0])
                                        : gold_glyph(8'h62, rr2[3:0]);
                        dot_ok = gg[7 - cc];                // MSB 是最左 ⇒ 取第 cc 位
                        if (dot_ok) exp_pix = WHITE;        // 有点 ⇒ 白
                    end
                    checks = checks + 1;
                    if (pix_out !== exp_pix) begin
                        $display("FAIL[C] col=%0d row=%0d got=%h want=%h", c, r, pix_out, exp_pix);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    //=====================================================================
    // 用例 D：两个重叠框，编号小的优先（应显示红）
    //   框0：bx=5, by=32, bw=20, bh=8  ⇒ x0=5, x1=25, y0=32, y1=40，红
    //   框1：bx=10,by=30, bw=20, bh=12 ⇒ x0=10,x1=30, y0=30, y1=42，绿
    //=====================================================================
    reg hit0, hit1;

    task case_overlap;
        begin
            def_box(12'h4C, 16'd5,  16'd32, 16'd20, 16'd8,  16'd0, 16'd0,
                    2'd0, 5'd0, 32'h0, 32'h0, 32'h0, 32'h0);           // 框0 红
            def_box(12'h6C, 16'd10, 16'd30, 16'd20, 16'd12, 16'd0, 16'd0,
                    2'd1, 5'd0, 32'h0, 32'h0, 32'h0, 32'h0);           // 框1 绿
            wr(12'h48, 32'd2);                              // 框数 = 2
            wr(12'h44, 32'd1);                              // 只画框
            for (r = 0; r < H; r = r + 1) begin
                for (c = 0; c < W; c = c + 1) begin
                    @(negedge clk);
                    col = c[10:0];  row = r[9:0];  pix_in = mk_pix(c[10:0], r[9:0]);
                    @(posedge clk);                         // ★ dd_osd 是 1 级流水：正沿采样第 1 级
                    #1;
                    // 框0 的边带
                    hit0 = ((c >= 5)  && (c <= 25) && (((r >= 32) && (r < 34)) || ((r > 38) && (r <= 40))))
                        || ((r >= 32) && (r <= 40) && (((c >= 5)  && (c < 7))  || ((c > 23) && (c <= 25))));
                    // 框1 的边带
                    hit1 = ((c >= 10) && (c <= 30) && (((r >= 30) && (r < 32)) || ((r > 40) && (r <= 42))))
                        || ((r >= 30) && (r <= 42) && (((c >= 10) && (c < 12)) || ((c > 28) && (c <= 30))));
                    exp_pix = hit0 ? RED : (hit1 ? GREEN : pix_in);     // ★ 编号小的优先
                    checks = checks + 1;
                    if (pix_out !== exp_pix) begin
                        $display("FAIL[D] col=%0d row=%0d got=%h want=%h (hit0=%b hit1=%b)",
                                 c, r, pix_out, exp_pix, hit0, hit1);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    //=====================================================================
    // 用例 E：读回
    //=====================================================================
    task case_readback;
        begin
            $display("---- 读回检查 ----");
            rd_idx = 7'd17;  #1;                            // 0x44
            if (rd_data[1:0] !== 2'd1) begin
                $display("FAIL[E] OSD_CTRL got=%h want=1", rd_data);  errors = errors + 1;
            end
            checks = checks + 1;
            rd_idx = 7'd18;  #1;                            // 0x48
            if (rd_data[3:0] !== 4'd2) begin
                $display("FAIL[E] OSD_N got=%h want=2", rd_data);     errors = errors + 1;
            end
            checks = checks + 1;
            rd_idx = 7'd19;  #1;                            // 0x4C = 框0 位置
            if (rd_data !== {16'd32, 16'd5}) begin
                $display("FAIL[E] box0 pos got=%h want=%h", rd_data, {16'd32, 16'd5});
                errors = errors + 1;
            end
            checks = checks + 1;
            rd_idx = 7'd19 + 7'd8;  #1;                     // 0x6C = 框1 位置
            if (rd_data !== {16'd30, 16'd10}) begin
                $display("FAIL[E] box1 pos got=%h want=%h", rd_data, {16'd30, 16'd10});
                errors = errors + 1;
            end
            checks = checks + 1;
        end
    endtask

    //=====================================================================
    // 说明：字模 ROM 不单独做用例 —— 用例 C 已经把 "字符码 → 点阵行 → 取哪一位"
    // 整条路径按**独立手抄的字形表**逐像素比对过了，再单独测 ROM 是重复的。
    // （而且层次化驱动实例的 input 端口在 xelab 里不被允许。）
    //=====================================================================

    //=====================================================================
    // 主流程
    //=====================================================================
    initial begin
        errors = 0;  checks = 0;
        rstn = 1'b0;  wr_en = 1'b0;  wr_addr = 12'd0;  wr_data = 32'd0;
        rd_idx = 7'd0;  col = 11'd0;  row = 10'd0;  pix_in = 24'd0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;
        repeat (2) @(negedge clk);

        $display("==== 用例 A：旁路 ====");
        case_bypass;

        $display("==== 用例 B：单框红 ====");
        case_box_red;

        $display("==== 用例 C：绿框 + 文字 ====");
        case_box_text;

        $display("==== 用例 D：双框重叠优先级 ====");
        case_overlap;

        $display("==== 用例 E：读回 ====");
        case_readback;

        $display("==================================================");
        $display("比对次数 = %0d   失败 = %0d", checks, errors);
        if (errors == 0 && checks > 0)
            $display("PASS：全部通过");
        else
            $display("FAIL：有 %0d 处不符（或比对次数为 0 = 空验证）", errors);
        $display("==================================================");
        $finish;
    end

endmodule
