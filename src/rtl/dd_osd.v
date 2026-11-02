// ===========================================================================
// 物品回收智能分拣系统 · PL 侧源码（提交包副本）
// 本文件逻辑与工程内原件完全一致，仅在文件头追加本注释块，未改动任何一行代码。
// 文件   ：dd_osd.v
// 层级   ：OSD 子模块
// 作用   ：在像素流上叠加矩形框与 ASCII 文字
// 例化者 ：dd_osd_axis.v、glass_defect_core_v2.v
// 备注   ：纯逻辑，寄存器经 wen/addr 写入
// ===========================================================================
`timescale 1ns / 1ps
//=============================================================================
// dd_osd.v —— 在像素流上叠加"框 + 文字"（OSD = On-Screen Display）
//
// 【位置】glass_defect_core_v2 的**输出级**、m_axis 之前。
// 【原理】逐个像素判断"当前 (row, col) 属不属于要画的图案"：
//           框 = 落在矩形的边带上；
//           字 = 落在文字矩形内 → 算第几个字符 → 查字模 → 取那一列的点。
//         命中 ⇒ 该像素换成目标颜色；否则原样输出。画框和画字本质是同一件事。
//
// ★【2 级流水 —— 这是被时序逼出来的，别合回去】
//   第 1 级（组合 → 寄存器）：8 组边界比较 → 优先编码 → 选出字符码
//   第 2 级（组合 → 输出）  ：字模 ROM 读 → 取位 → 三路合成
//   2026-10-13 第一次综合时 WNS = -3.840ns，关键路径是
//   `u_osd/tx_reg[4][3] → o_p_reg[9]` —— 整条判定链是一大坨纯组合。
//   拆成两级之后每级只剩一半深度。
//   ★ 整幅画面一起晚 2 拍 ⇒ 掩膜与原图的**相对偏移不变** ⇒ PS 的 SHIFT_X/SHIFT_Y 不用改。
//
// 【坐标系】col = 0..H_ACTIVE-1、row = 0..V_ACTIVE-1，
//           ★ 是**画面坐标**（不含 VDMA 行内留边的 OFF_PX）—— PS 侧要减掉。
//
// 【寄存器】由顶层 s_axi 转发（字节地址，顶层已锁存）
//   0x44 OSD_CTRL   [0]=画框使能  [1]=画字使能
//   0x48 OSD_N      [3:0]=有效框个数（0~8）
//   0x4C + 32*k + 0x0   {by[31:16], bx[15:0]}      框左上角
//                + 0x4   {bh[31:16], bw[15:0]}      框宽高
//                + 0x8   {ty[31:16], tx[15:0]}      文字左上角（PS 算好"放上还是放下"）
//                + 0xC   {nchar[6:2], color[1:0]}   字符数(0~16) / 颜色
//                + 0x10  4 个字符(8bit ASCII)；+0x14/+0x18/+0x1C 依次 4/4/4 个
//
// 【颜色】color=0 ⇒ 红（不可回收）24'hF80000 ；color=1 ⇒ 绿（可回收）24'h00FC00
//        ★ 输入是 RGB565 左对齐补 0 ⇒ R/B 最大 0xF8、G 最大 0xFC（写 0xFF 也出不来）
//        文字固定白色 24'hFF_FFFF
//
// 【多框重叠】编号小的优先（低编号覆盖高编号）。
// 【旁路】osd_ctrl = 0 ⇒ pix_out 逐像素等于 pix_in ⇒ 一键恢复原样，不用重编。
//=============================================================================
module dd_osd #(
    parameter N_BOX    = 8,                                 // 最多几个框
    parameter MAX_CHAR = 16,                                // 每个框最多几个字符
    parameter THICK    = 2                                  // 框线粗细（像素）
)(
    input  wire        clk,                                 // 100MHz
    input  wire        rstn,                                // 低有效复位
    input  wire        en,                                  // ★ 流水使能：反压时冻结（与顶层 o_adv 同步）
    // 像素与坐标（与 s_axis 同拍）
    input  wire [23:0] pix_in,                              // 当前像素
    input  wire [10:0] col,                                 // 当前列 0..H_ACTIVE-1
    input  wire [9:0]  row,                                 // 当前行 0..V_ACTIVE-1
    // AXI-Lite 写的转发（wr_en 是一拍脉冲）
    input  wire        wr_en,                               // 提交一笔写
    input  wire [11:0] wr_addr,                             // 写字节地址
    input  wire [31:0] wr_data,                             // 写数据
    // AXI-Lite 读回（组合）
    input  wire [6:0]  rd_idx,                              // 读寄存器编号（= addr[8:2]）
    output reg  [31:0] rd_data,                             // 读数据
    // 结果（对应 **1 拍之前** 的输入像素）
    output wire [23:0] pix_out                              // 叠加后的像素
);

    // ---- 颜色常量（RGB565 左对齐补 0 的真实上限）----
    localparam [23:0] C_RED   = 24'hF8_00_00;               // 纯红
    localparam [23:0] C_GREEN = 24'h00_FC_00;               // 纯绿
    localparam [23:0] C_WHITE = 24'hFF_FF_FF;               // 文字白

    // ---- 寄存器编号（对应字节地址 [8:2]）----
    localparam [6:0] IDX_CTRL = 7'd17;                      // 0x44
    localparam [6:0] IDX_N    = 7'd18;                      // 0x48
    localparam [6:0] IDX_BASE = 7'd19;                      // 0x4C
    localparam [6:0] IDX_END  = 7'd19 + 7'd64;              // 框区结束（不含）

    //=====================================================================
    // 寄存器组
    //=====================================================================
    reg [1:0]  osd_ctrl;                                    // 0x44：bit0 画框、bit1 画字
    reg [3:0]  osd_n;                                       // 0x48：有效框个数
    reg [15:0] bx  [0:N_BOX-1];                             // 左上角 x
    reg [15:0] by  [0:N_BOX-1];                             // 左上角 y
    reg [15:0] bw  [0:N_BOX-1];                             // 宽
    reg [15:0] bh  [0:N_BOX-1];                             // 高
    reg [15:0] tx  [0:N_BOX-1];                             // 文字左上角 x
    reg [15:0] ty  [0:N_BOX-1];                             // 文字左上角 y
    reg [1:0]  bcol[0:N_BOX-1];                             // 颜色（0 红 / 1 绿）
    reg [4:0]  bnch[0:N_BOX-1];                             // 字符数（0~16）
    reg [7:0]  bch [0:N_BOX*MAX_CHAR-1];                    // 字符码（ASCII）

    // ---- 写地址译码 ----
    wire [6:0] wi   = wr_addr[8:2];                         // 写的寄存器编号
    wire [6:0] wrel = (wi >= IDX_BASE) ? (wi - IDX_BASE) : 7'd0;
    wire [2:0] wk   = wrel[6:3];                            // 第几个框
    wire [2:0] wj   = wrel[2:0];                            // 框内第几个字
    wire [6:0] wk16 = {wk, 4'b0};                           // = wk*16

    integer m;                                              // 复位循环变量
    always @(posedge clk) begin
        if (!rstn) begin                                    // 复位：全部清零
            osd_ctrl <= 2'd0;                               // 旁路（逐像素等于输入）
            osd_n    <= 4'd0;                               // 没有框
            for (m = 0; m < N_BOX; m = m + 1) begin
                bx[m] <= 16'd0;   by[m] <= 16'd0;           // 位置
                bw[m] <= 16'd0;   bh[m] <= 16'd0;           // 宽高
                tx[m] <= 16'd0;   ty[m] <= 16'd0;           // 文字位置
                bcol[m] <= 2'd0;  bnch[m] <= 5'd0;          // 颜色 / 字符数
            end
            for (m = 0; m < N_BOX*MAX_CHAR; m = m + 1)
                bch[m] <= 8'h20;                            // 字符缓冲先填空格
        end else if (wr_en) begin                           // 写提交
            case (wi)
                IDX_CTRL: osd_ctrl <= wr_data[1:0];         // 写 0x44
                IDX_N:    osd_n    <= wr_data[3:0];         // 写 0x48
                default: begin
                    if (wi >= IDX_BASE && wi < IDX_END) begin
                        case (wj)
                            3'd0: begin bx[wk] <= wr_data[15:0]; by[wk] <= wr_data[31:16]; end
                            3'd1: begin bw[wk] <= wr_data[15:0]; bh[wk] <= wr_data[31:16]; end
                            3'd2: begin tx[wk] <= wr_data[15:0]; ty[wk] <= wr_data[31:16]; end
                            3'd3: begin bcol[wk] <= wr_data[1:0]; bnch[wk] <= wr_data[6:2]; end
                            3'd4: begin
                                bch[wk16+7'd0]  <= wr_data[7:0];   bch[wk16+7'd1]  <= wr_data[15:8];
                                bch[wk16+7'd2]  <= wr_data[23:16]; bch[wk16+7'd3]  <= wr_data[31:24];
                            end
                            3'd5: begin
                                bch[wk16+7'd4]  <= wr_data[7:0];   bch[wk16+7'd5]  <= wr_data[15:8];
                                bch[wk16+7'd6]  <= wr_data[23:16]; bch[wk16+7'd7]  <= wr_data[31:24];
                            end
                            3'd6: begin
                                bch[wk16+7'd8]  <= wr_data[7:0];   bch[wk16+7'd9]  <= wr_data[15:8];
                                bch[wk16+7'd10] <= wr_data[23:16]; bch[wk16+7'd11] <= wr_data[31:24];
                            end
                            3'd7: begin
                                bch[wk16+7'd12] <= wr_data[7:0];   bch[wk16+7'd13] <= wr_data[15:8];
                                bch[wk16+7'd14] <= wr_data[23:16]; bch[wk16+7'd15] <= wr_data[31:24];
                            end
                            default: ;                      // 不会到这里
                        endcase
                    end
                end
            endcase
        end
    end

    //=====================================================================
    // 第 1 级（组合）：逐框判断 + 优先级编码 + 选字符码
    //   ⚠️ 只算判定和定位，**不碰字模 ROM** —— ROM 在第 2 级。
    //=====================================================================
    reg        b_hit_c;                                     // 框线命中
    reg [1:0]  b_sel_c;                                     // 命中框的颜色
    reg        t_hit_c;                                     // 文字命中
    reg [6:0]  t_ch_c;                                      // 选中的字符码
    reg [3:0]  t_rr_c;                                      // 字符内行
    reg [2:0]  t_cc_c;                                      // 字符内列

    integer k;                                              // 框循环变量
    reg [15:0] x1k, y1k;                                    // 第 k 框的右下角
    reg [15:0] wch;                                         // 文字总宽 = nchar*8
    reg [15:0] dc16, dr16;                                  // 相对文字左上角的偏移
    reg [4:0]  ci5;                                         // 第几个字符（0~15）

    always @(*) begin
        b_hit_c = 1'b0;  b_sel_c = 2'd0;                    // 默认：无命中
        t_hit_c = 1'b0;  t_ch_c = 7'h20;  t_rr_c = 4'd0;  t_cc_c = 3'd0;
        for (k = N_BOX-1; k >= 0; k = k - 1) begin          // ★ 倒序 ⇒ 编号小的最后写、优先
            if (k < osd_n) begin                            // 只处理有效框
                x1k = bx[k] + bw[k];                        // 右边界
                y1k = by[k] + bh[k];                        // 下边界
                wch = {11'd0, bnch[k]} * 16'd8;             // 文字总宽 = 字符数 × 8
                // ---------- 框线 ----------
                if (osd_ctrl[0]) begin
                    if (((col >= bx[k]) && (col <= x1k) &&
                         (((row >= by[k]) && (row < by[k] + THICK)) ||
                          ((row + THICK > y1k) && (row <= y1k))))
                     || ((row >= by[k]) && (row <= y1k) &&
                         (((col >= bx[k]) && (col < bx[k] + THICK)) ||
                          ((col + THICK > x1k) && (col <= x1k))))) begin
                        b_hit_c = 1'b1;                     // 落在边带上
                        b_sel_c = bcol[k];                  // 用这个框的颜色
                    end
                end
                // ---------- 文字 ----------
                if (osd_ctrl[1] && (bnch[k] != 5'd0)) begin
                    dc16 = col - tx[k];                     // 列偏移
                    dr16 = row - ty[k];                     // 行偏移
                    if ((col >= tx[k]) && (col < tx[k] + wch) &&
                        (row >= ty[k]) && (row < ty[k] + 16'd16)) begin
                        ci5     = {1'b0, dc16[6:3]};        // 第几个字符（列偏移 ÷ 8）
                        t_cc_c  = dc16[2:0];                // 字符内列
                        t_rr_c  = dr16[3:0];                // 字符内行
                        t_ch_c  = bch[k*MAX_CHAR + ci5];    // ★ 该框的 16 选 1
                        t_hit_c = 1'b1;                     // 要画
                    end
                end
            end
        end
    end

    //=====================================================================
    // 第 1 级 → 第 2 级的流水寄存器（en 门控：反压时冻结）
    //=====================================================================
    reg [23:0] pix_d1;                                      // 延迟 1 拍的像素
    reg        b_hit_d1, t_hit_d1;                          // 延迟 1 拍的命中标志
    reg [1:0]  b_sel_d1;                                    // 延迟 1 拍的颜色
    reg [6:0]  t_ch_d1;                                     // 延迟 1 拍的字符码
    reg [3:0]  t_rr_d1;                                     // 延迟 1 拍的字符内行
    reg [2:0]  t_cc_d1;                                     // 延迟 1 拍的字符内列

    always @(posedge clk) begin
        if (!rstn) begin                                    // 复位清零
            pix_d1   <= 24'h000000;
            b_hit_d1 <= 1'b0;   t_hit_d1 <= 1'b0;  b_sel_d1 <= 2'd0;
            t_ch_d1  <= 7'h20;  t_rr_d1  <= 4'd0;  t_cc_d1  <= 3'd0;
        end else if (en) begin                              // ★ 只在能推进时才走
            pix_d1   <= pix_in;
            b_hit_d1 <= b_hit_c;   t_hit_d1 <= t_hit_c;   b_sel_d1 <= b_sel_c;
            t_ch_d1  <= t_ch_c;    t_rr_d1  <= t_rr_c;    t_cc_d1  <= t_cc_c;
        end
    end

    //=====================================================================
    // 第 2 级（组合）：字模 ROM 读 → 取位 → 三路合成
    //=====================================================================
    wire [7:0] font_bits;                                   // 该字符该行的 8 个点
    dd_font_rom u_font (
        .ch  (t_ch_d1),                                     // 字符码
        .row (t_rr_d1),                                     // 字符内行号
        .bits(font_bits)                                    // bit7 = 最左
    );

    wire t_dot = font_bits[7 - t_cc_d1];                    // 取第 cc 列那一位

    assign pix_out = b_hit_d1           ? (b_sel_d1 == 2'd1 ? C_GREEN : C_RED)
                   : (t_hit_d1 & t_dot) ? C_WHITE
                   :                      pix_d1;        // 旁路：等于 1 拍前的输入

    //=====================================================================
    // 读回（给 PS 调试用，不参与画图）
    //=====================================================================
    wire [6:0] rrel = (rd_idx >= IDX_BASE) ? (rd_idx - IDX_BASE) : 7'd0;
    wire [2:0] rk   = rrel[6:3];                            // 读的框号
    wire [2:0] rj   = rrel[2:0];                            // 框内第几个字

    always @(*) begin
        rd_data = 32'd0;                                    // 默认 0
        case (rd_idx)
            IDX_CTRL: rd_data = {30'd0, osd_ctrl};          // 回读控制字
            IDX_N:    rd_data = {28'd0, osd_n};             // 回读框数
            default: begin
                if (rd_idx >= IDX_BASE && rd_idx < IDX_END) begin
                    case (rj)
                        3'd0: rd_data = {by[rk], bx[rk]};   // 位置
                        3'd1: rd_data = {bh[rk], bw[rk]};   // 宽高
                        3'd2: rd_data = {ty[rk], tx[rk]};   // 文字位置
                        3'd3: rd_data = {25'd0, bnch[rk], bcol[rk]};  // 字符数 + 颜色
                        3'd4: rd_data = {bch[rk*MAX_CHAR+3],  bch[rk*MAX_CHAR+2],
                                         bch[rk*MAX_CHAR+1],  bch[rk*MAX_CHAR+0]};
                        3'd5: rd_data = {bch[rk*MAX_CHAR+7],  bch[rk*MAX_CHAR+6],
                                         bch[rk*MAX_CHAR+5],  bch[rk*MAX_CHAR+4]};
                        3'd6: rd_data = {bch[rk*MAX_CHAR+11], bch[rk*MAX_CHAR+10],
                                         bch[rk*MAX_CHAR+9],  bch[rk*MAX_CHAR+8]};
                        3'd7: rd_data = {bch[rk*MAX_CHAR+15], bch[rk*MAX_CHAR+14],
                                         bch[rk*MAX_CHAR+13], bch[rk*MAX_CHAR+12]};
                        default: rd_data = 32'd0;
                    endcase
                end
            end
        endcase
    end

endmodule
