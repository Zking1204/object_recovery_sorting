// ===========================================================================
// 物品回收智能分拣系统 · PL 侧源码（提交包副本）
// 本文件逻辑与工程内原件完全一致，仅在文件头追加本注释块，未改动任何一行代码。
// 文件   ：dd_osd_axis.v
// 层级   ：BD 顶层（自研）
// 作用   ：把 dd_osd 封装成带 AXI4-Lite 从口与 AXIS 输入输出的 BD IP
// 例化者 ：BD 中的 dd_osd_axis_0
// 备注   ：AXI-Lite 基地址 0x4000_0000
// ===========================================================================
//=============================================================================
// dd_osd_axis.v —— OSD 叠加的 AXIS 包装（2026-10-20 新增）
//
// 【这个模块干什么】
//   把已有的 dd_osd 包成一个带 AXIS 从口/主口 + AXI4-Lite 从口的"可插进 BD 的 IP"，
//   插在  axis_broadcaster_0/M01_AXIS  →  axi_vdma_0/S2MM  之间。
//   这样写进 buf0 的原始彩色就**带上了框和字**，而 buf1 那边（core 输出）保持干净。
//
// 【为什么需要它】
//   屏幕那一路 VDMA 只有一条、读 buf1，而 buf1 装什么由 DISP 决定；
//   PS 找框又必须从 buf1 读掩膜（DISP=5）⇒ 显示彩色 和 读掩膜 抢同一块缓冲。
//   把 OSD 挪到 buf0 支路之后：
//     · buf0 = 彩色 + 框 + 字      → 屏幕读它（display_source(True)）
//     · buf1 = 掩膜（DISP=5 常驻） → PS 读它
//   ⇒ 屏幕一秒都不闪，PS 还能 29Hz 实时读掩膜。
//
// 【数据格式】24 位 RGB565 左对齐补 0，和 cam_full / dd_osd 完全一致，不做任何变换。
//
// 【延迟】整条 2 拍（dd_osd 内部 1 拍 + 本模块 1 拍）。
//   ★ sideband（tvalid/tlast/tuser）**跟着一起打** ⇒ 整幅一起晚 2 拍，
//     buf0 与 buf1 各自独立读取，相对关系不受影响。
//
// 【AXIS 语义】反压时两级流水一起冻结（en 门控），保证不丢像素、不重复。
//
// 【寄存器】与 core 里的 OSD **完全相同**的编号，只是基地址不同：
//     0x00        ID       RO  0x4F534432（'OSD2'，自检用：读到就说明这块 IP 在）
//     0x44        OSD_CTRL [0]=画框 [1]=画字（0 = 旁路，逐像素直通）
//     0x48        OSD_N    [3:0]=有效框个数
//     0x4C+32k+0x0  {by[31:16], bx[15:0]}
//     0x4C+32k+0x4  {bh[31:16], bw[15:0]}
//     0x4C+32k+0x8  {ty[31:16], tx[15:0]}
//     0x4C+32k+0xC  {nchar[6:2], color[1:0]}     0 = 红（不可回收）/ 1 = 绿（可回收）
//     0x4C+32k+0x10..0x1C   4×32bit 装 16 个字符（每字节一个 ASCII，小端）
//
// 【★ 与 core 那套 OSD 的分工】
//   core 里的 OSD 继续工作（不旁路），但它画在 buf1 的掩膜上、只画框不画字
//   （PS 侧把它的 nchar 写 0）。原因：detect() 读的是蓝通道，
//   纯红/纯绿框的蓝 = 0 ⇒ 读不到；而白字的蓝 = 255 ⇒ 会被当成前景目标。
//   本模块这一路画框 + 画字，给屏幕看。
//=============================================================================
`timescale 1ns / 1ps

module dd_osd_axis #(
    parameter N_BOX    = 8,                                 // 最多几个框（与 dd_osd 一致）
    parameter MAX_CHAR = 16,                                // 每框最多几个字符
    parameter THICK    = 2                                  // 框线粗细（像素）
)(
    // ---------------- 时钟与复位 ----------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis:s_axi, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000, PHASE 0.0" *)
    input  wire        aclk,                                // 主时钟 100MHz
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
    input  wire        aresetn,                             // 低有效复位

    // ---------------- AXIS 从口（来自 broadcaster M01）----------------
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis, TDATA_NUM_BYTES 3, HAS_TKEEP 0, HAS_TSTRB 0, HAS_TLAST 1, HAS_TUSER 1, HAS_TREADY 1, PHASE 0.0" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [23:0] s_axis_tdata,                        // 像素：RGB565 左对齐补 0
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire        s_axis_tvalid,                       // 本拍有像素
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire        s_axis_tready,                       // 我们能收
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire        s_axis_tlast,                        // 本像素是一行最后一个
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TUSER" *)
    input  wire        s_axis_tuser,                        // 本像素是一帧第一个

    // ---------------- AXIS 主口（去 axi_vdma_0/S2MM）----------------
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 3, HAS_TKEEP 0, HAS_TSTRB 0, HAS_TLAST 1, HAS_TUSER 1, HAS_TREADY 1, PHASE 0.0" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [23:0] m_axis_tdata,                        // 叠加后的像素
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire        m_axis_tvalid,                       // 与数据同拍
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire        m_axis_tready,                       // 下游能不能收
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire        m_axis_tlast,                        // 与数据同拍
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TUSER" *)
    output wire        m_axis_tuser,                        // 与数据同拍

    // ---------------- AXI4-Lite 从口 ----------------
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4LITE, ADDR_WIDTH 12, DATA_WIDTH 32, FREQ_HZ 100000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 2, INSERT_VIP 0" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [11:0] s_axi_awaddr,                        // 写地址（只译码 [8:2]）
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire        s_axi_awvalid,                       // 写地址有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire        s_axi_awready,                       // 能收写地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0] s_axi_wdata,                         // 写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]  s_axi_wstrb,                         // 字节选通（本设计按整字写，不用）
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire        s_axi_wvalid,                        // 写数据有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire        s_axi_wready,                        // 能收写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]  s_axi_bresp,                         // 写响应，恒 OKAY
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire        s_axi_bvalid,                        // 写响应可取
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire        s_axi_bready,                        // 主机取走写响应
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [11:0] s_axi_araddr,                        // 读地址（只译码 [8:2]）
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire        s_axi_arvalid,                       // 读地址有效
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire        s_axi_arready,                       // 能收读地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0] s_axi_rdata,                         // 读数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]  s_axi_rresp,                         // 读响应，恒 OKAY
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire        s_axi_rvalid,                        // 读数据可取
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire        s_axi_rready                         // 主机取走读数据
);

    //=========================================================================
    // 1) 寄存器编号
    //=========================================================================
    localparam [6:0] IDX_ID       = 7'h00;                  // 0x00 ID   只读，自检用
    localparam [6:0] IDX_OSD_BASE = 7'd17;                  // 0x44 起交给 dd_osd
    localparam [31:0] ID_VALUE    = 32'h4F53_4432;          // 'O','S','D','2' —— 读到就说明这块 IP 在

    //=========================================================================
    // 2) AXI4-Lite 写通道（照 core 的写法搬过来：AW/W 分别锁存，两半到齐才提交）
    //=========================================================================
    reg        aw_got, w_got;                               // 地址到了 / 数据到了
    reg [11:0] awaddr_r;                                    // 锁存的写地址
    reg [31:0] wdata_r;                                     // 锁存的写数据
    reg        bvalid_r;                                    // 写响应待取

    wire       wr_fire = aw_got & w_got;                    // 写的两半都到齐 ⇒ 提交（单拍脉冲）
    wire [6:0] wr_idx  = awaddr_r[8:2];                     // 正在写的寄存器编号
    wire [31:0] osd_rd;                                     // dd_osd 的读回值

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_got   <= 1'b0;                               // 复位：没有待处理的地址
            w_got    <= 1'b0;                               // 复位：没有待处理的数据
            awaddr_r <= 12'd0;                              // 清写地址
            wdata_r  <= 32'd0;                              // 清写数据
            bvalid_r <= 1'b0;                               // 没有待取的写响应
        end else begin
            if (s_axi_awready && s_axi_awvalid) begin       // 收 AW
                awaddr_r <= s_axi_awaddr;                   // 锁存地址
                aw_got   <= 1'b1;                           // 标记地址已到
            end
            if (s_axi_wready && s_axi_wvalid) begin         // 收 W
                wdata_r <= s_axi_wdata;                     // 锁存数据
                w_got   <= 1'b1;                            // 标记数据已到
            end
            if (wr_fire) begin                              // 两半到齐 ⇒ 这一拍就是写提交
                aw_got   <= 1'b0;                           // 消费掉地址
                w_got    <= 1'b0;                           // 消费掉数据
                bvalid_r <= 1'b1;                           // 拉起 BVALID
            end else if (bvalid_r && s_axi_bready) begin    // 没有新提交、且响应被取走
                bvalid_r <= 1'b0;                           // 撤销 BVALID
            end
        end
    end

    assign s_axi_awready = ~aw_got & ~bvalid_r;             // 空闲才收地址
    assign s_axi_wready  = ~w_got  & ~bvalid_r;             // 空闲才收数据
    assign s_axi_bvalid  = bvalid_r;                        // 直接驱动
    assign s_axi_bresp   = 2'b00;                           // 恒 OKAY

    //=========================================================================
    // 3) AXI4-Lite 读通道
    //=========================================================================
    reg        rvalid_r;                                    // 读数据待取
    reg [31:0] rdata_r;                                     // 送到 RDATA 的寄存器
    reg [31:0] rdata_c;                                     // 组合读多路选择的结果
    wire [6:0] rd_idx = s_axi_araddr[8:2];                  // 正在读的寄存器编号

    always @(*) begin
        case (rd_idx)
            IDX_ID:  rdata_c = ID_VALUE;                    // 自检寄存器
            default: rdata_c = (rd_idx >= IDX_OSD_BASE) ? osd_rd : 32'd0;  // 0x44 以上交给 dd_osd
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            rvalid_r <= 1'b0;                               // 复位：没有待取的读数据
            rdata_r  <= 32'd0;                              // 清读数据
        end else if (s_axi_arready && s_axi_arvalid) begin  // AR 被接受那一拍采样
            rvalid_r <= 1'b1;                               // 拉起 RVALID
            rdata_r  <= rdata_c;                            // 锁存组合读结果
        end else if (rvalid_r && s_axi_rready) begin        // 数据被取走
            rvalid_r <= 1'b0;                               // 撤销 RVALID
        end
    end

    assign s_axi_arready = ~rvalid_r;                       // 上一笔读被取走才收新的
    assign s_axi_rvalid  = rvalid_r;                        // 待取标志
    assign s_axi_rresp   = 2'b00;                           // 恒 OKAY
    assign s_axi_rdata   = rdata_r;                         // 读数据

    //=========================================================================
    // 4) 行列计数器（OSD 判断"当前画到第几列第几行"）
    //    列：行尾清零；行：帧首清零、行尾 +1
    //=========================================================================
    reg [10:0] col_cnt;                                     // 本行第几列（0..2047）
    reg [9:0]  row_cnt;                                     // 本帧第几行（0..1023）

    always @(posedge aclk) begin
        if (!aresetn) begin
            col_cnt <= 11'd0;                               // 复位归零
            row_cnt <= 10'd0;                               // 复位归零
        end else if (s_axis_tvalid && s_axis_tready) begin  // ★ 只有"这一拍真的收下了"才推进计数
            //   反压时 tready=0、像素被上游扛着，计数绝对不能走，否则框会画错位置。
            //   s_axis_tready = o_adv 正是 dd_osd 的 en，二者必须严格同拍。
            if (s_axis_tlast) col_cnt <= 11'd0;             // 行尾 ⇒ 下一拍从 0 开始
            else              col_cnt <= col_cnt + 11'd1;   // 否则列 +1
            if (s_axis_tuser)      row_cnt <= 10'd0;        // 帧首 ⇒ 行 = 0
            else if (s_axis_tlast) row_cnt <= row_cnt + 10'd1;  // 行尾 ⇒ 下一行
        end
    end

    //=========================================================================
    // 5) 流水线：dd_osd（内部 1 拍）→ 中间级（1 拍）→ 输出级
    //    反压时两级一起冻结，保证不丢、不重。
    //=========================================================================
    wire [23:0] osd_pix;                                    // 叠加后的像素（晚 1 拍）
    reg  [23:0] o_p;                                        // 输出级像素
    reg         o_v, o_l, o_u;                              // 输出级 sideband
    reg         d_v, d_l, d_u;                              // 中间级 sideband

    wire        o_adv = m_axis_tready | ~o_v;               // 下游能收、或输出级空着 ⇒ 整条流水推进

    dd_osd #(
        .N_BOX   (N_BOX),                                   // 最多 8 个框
        .MAX_CHAR(MAX_CHAR),                                // 每框最多 16 字符
        .THICK   (THICK)                                    // 框线 2 像素
    ) u_osd (
        .clk     (aclk),                                    // 100MHz
        .rstn    (aresetn),                                 // 低有效复位
        .en      (o_adv),                                   // ★ 流水使能（与 sideband 同步推进）
        .pix_in  (s_axis_tdata),                            // 送进来的是原始彩色像素
        .col     (col_cnt),                                 // 当前列（画面坐标）
        .row     (row_cnt),                                 // 当前行（画面坐标）
        .wr_en   (wr_fire),                                 // AXI 写提交脉冲
        .wr_addr (awaddr_r),                                // 写字节地址
        .wr_data (wdata_r),                                 // 写数据
        .rd_idx  (rd_idx),                                  // 读寄存器编号
        .rd_data (osd_rd),                                  // 读回值（接到上面的读 mux）
        .pix_out (osd_pix)                                  // 叠加结果（晚 1 拍）
    );

    // ---- 中间级：sideband 延迟 1 拍，与 dd_osd 内部那一级对齐 ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            d_v <= 1'b0;                                    // 空
            d_l <= 1'b0;                                    // 行尾
            d_u <= 1'b0;                                    // 帧首
        end else if (o_adv) begin                           // 只在推进那一拍更新（反压时冻结）
            d_v <= s_axis_tvalid;                           // 这一拍有没有像素
            d_l <= s_axis_tlast;                            // 行尾跟着走
            d_u <= s_axis_tuser;                            // 帧首跟着走
        end
    end

    // ---- 输出级：再打一拍，像素与 sideband 同拍输出 ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            o_v <= 1'b0;                                    // 空
            o_l <= 1'b0;                                    // 行尾
            o_u <= 1'b0;                                    // 帧首
            o_p <= 24'h000000;                              // 像素清零
        end else if (o_adv) begin                           // 同样受反压门控
            o_v <= d_v;                                     // 与 o_p 同拍
            o_l <= d_l;                                     // 与 o_p 同拍
            o_u <= d_u;                                     // 与 o_p 同拍
            o_p <= osd_pix;                                 // 叠加后的像素
        end
    end

    //=========================================================================
    // 6) 输出
    //=========================================================================
    assign m_axis_tdata  = o_p;                             // 像素（已叠加、已寄存）
    assign m_axis_tvalid = o_v;                             // 与之同拍
    assign m_axis_tlast  = o_l;                             // 与之同拍
    assign m_axis_tuser  = o_u;                             // 与之同拍
    assign s_axis_tready = o_adv;                           // 能收就收（等价于下游能收，多 1 格缓冲）

endmodule
