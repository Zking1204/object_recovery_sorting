// ===========================================================================
// 物品回收智能分拣系统 · PL 侧源码（提交包副本）
// 本文件逻辑与工程内原件完全一致，仅在文件头追加本注释块，未改动任何一行代码。
// 文件   ：glass_defect_core_v2.v
// 层级   ：BD 顶层（自研，当前在用）
// 作用   ：检测核顶层：AXI4-Lite 寄存器 + 双 AXIS 输入（相机流与背景流）+ 掩膜 AXIS 输出
// 例化者 ：BD 中的 glass_defect_core_0
// 备注   ：AXI-Lite 基地址 0x43C2_0000；模块名沿用早期命名，未改动以免破坏 BD 单元引用
// ===========================================================================
//////////////////////////////////////////////////////////////////////////////
// glass_defect_core_v2.v
//
//   ★ 为什么叫 _v2（不是改名玩）：
//     上一版 glass_defect_core.v 的**端口表已冻结**（见下面那段规矩），
//     而"放置物识别与计数"要在 PL 里做背景差分，就必须**新增一个背景输入口**
//     s_axis_bg（← axi_vdma_0/M_AXIS_MM2S，背景从 DDR 循环读回来）。
//     按工程定的规矩：**改端口 = 换新模块名 + 重做 BD 里的 cell** ✓
//     ⇒ 本文件 = 上一版全部内容 + 背景口 + 背景差分使能 + 三个诊断寄存器。
//
//   目标检测 / 放置物识别流水线的顶层模块。
//
//   在链路里的位置：
//       axis_broadcaster_0/M00_AXIS  ->  本模块  ->  axi_vdma_1/S_AXIS_S2MM
//       axi_vdma_0/M_AXIS_MM2S（背景）->  本模块 s_axis_bg
//
//   时钟：aclk = FCLK_CLK0 (100MHz)。上游和下游都在同一个时钟域，
//         所以本模块内部没有任何跨时钟处理。
//
//   *** 端口表已冻结（对 v2 而言）***
//   Vivado 会把 module_ref 的端口表缓存在工程里，改动下面任何一个端口
//   都必须换新模块名并重新编辑 BD。只能改模块体，不能改端口。
//   （2026-10-11 实测确认：update_module_reference / 删 mref 缓存 /
//     update_ip_catalog -rebuild 三条路都刷不掉旧端口表，改名是唯一稳的路。）
//
//   --------------------------------------------------------------------
//   阶段0 结构
//   --------------------------------------------------------------------
//
//       s_axis ---+--------------------------------> m_axis   （像素直通）
//                 |
//                 +--> 观测信号：
//                 |       px_valid / px_sof / px_eol / px_eof
//                 |
//                 +--> size_detect_0     （放置物尺寸：包围盒 宽/高/面积）
//                 +--> defect_detect_0   （目标：与背景的差异区）
//                 |
//       寄存器文件  <---- 结果
//       s_axi <---- ps7_0_axi_periph/M04 @ 0x43C20000
//
//   两个检测子模块都是**纯旁听者**：只读像素流、完全不碰握手信号，
//   所以它们无论如何都不会把视频卡住。屏幕上的画面不受它们影响。
//
//   --------------------------------------------------------------------
//   寄存器表  （字地址 = s_axi_*addr[5:2]）
//   --------------------------------------------------------------------
//       0x00  ID          RO   0xDEADBEEF
//       0x04  CTRL        RW   bit0 = 总使能
//       0x08  STATUS      RO   bit0 尺寸完成、bit1 目标完成、
//                              bit2 目标标志、bit3 帧同步正常
//                              （写任意值清掉这四个粘滞位）
//       0x0C  SIZE_TH     RW   bit0 尺寸使能、bit1 极性、
//                              bit[15:8] 灰度阈值              【队友】
//       0x10  SIZE_W      RO   放置物宽（像素）                  【队友】
//       0x14  SIZE_H      RO   放置物高（像素）                  【队友】
//       0x18  AREA        RO   放置物像素数                      【队友】
//       0x1C  DISP        RW   0 = 摄像头原图（默认）
//                              1 = size_detect   二值图
//                              2 = defect_detect **支路 A**（灰度阈值）二值图 ← 里程碑 2 的语义，未变
//                              3 = defect_detect **支路 B**（Sobel）二值图
//                              4 = defect_detect **A|B**（取或）二值图
//                              5 = defect_detect **形态学之后的最终掩膜**            【新】
//       0x20  DEF_TH      RW   bit0 目标使能、bit1 极性、bit2 中值使能、
//                              **bit3 形态学（闭运算）使能**、        【新】用户
//                              bit[15:8] 灰度阈值
//       0x24  DEF_CRACK   RO   细线数量                        【用户】
//                              当前临时语义 = 本帧目标像素总数（按**形态学之后**的掩膜计）
//       0x28  DEF_STAIN   RO   斑块数量                        【用户】
//       0x2C  DEF_BUBBLE  RO   斑块数量                        【用户】
//       0x30  SOB_TH      RW   bit0 支路 B 使能、               【新】用户
//                              bit[15:8] Sobel 梯度阈值
//                              ★ 复位值 0 ⇒ 支路 B 默认关闭
//       0x34  SOB_CNT     RO   本帧**支路 B 单独**的命中像素数  【新】
//                              （上板扫 Sobel 阈值时唯一的量化依据）
//
//   ★ 三个"零成本"的默认值合起来保证：**复位后本模块的行为与里程碑 2 完全一致**
//       DEF_TH[0]=0（目标不使能）｜SOB_TH[0]=0（支路 B 关）｜DEF_TH[3]=0（形态学旁路）
//
//   ★ DISP=2/3/4/5 四者的关系：2 只看支路 A、3 只看支路 B、4 看两条支路的或、
//     5 看形态学之后的最终结果。上板调试时按 **2 → 3 → 4 → 5** 顺序各看一遍，
//     就能一眼分清"哪些是灰度阈值报的、哪些是 Sobel 报的、合起来是什么样、
//     闭运算之后又变成什么样"。再配合 `DEF_TH[3]` 开/关对比，
//     形态学到底带来了什么就是**可量化**的（看 0x24 的计数变化）。
//   ★ 支路 B（Sobel）报的是**边**不是目标：一条 1 像素宽的细线在 DISP=3 上
//     会显示成**两条**平行的白线（细线两侧），细线正中间反而是黑的。
//     这不是 bug，是 Sobel 核的固有性质（中间行/列权重为 0）——
//     而 DISP=5（闭运算之后）会把它连成**一条实心带**，这正是形态学存在的理由。
//
//   --------------------------------------------------------------------
//   px_data 数据格式（这是发给两个检测子模块的东西）
//   --------------------------------------------------------------------
//       是 RGB565 **左对齐补 0** 塞进 24 位，不是真 RGB888：
//           [23:16] = {R5, 3'b000}    [15:8] = {G6, 2'b00}    [7:0] = {B5, 3'b000}
//       求灰度用 **2:4:1** 权重（≈ Rec.601 的 0.299:0.587:0.114），3 个加法器、0 个 DSP：
//           S    = 2·(R5 + G6) + B5      范围 0..219（通道比例已经是 2:4:1）
//           gray = S + (S>>3)            范围 0..246（≈ S×9/8，只改标度不改权重）
//       ★ 两个检测子模块必须用**同一个**公式，否则二值图对不上（合体交叉验证点）。
//
//   --------------------------------------------------------------------
//   注释规范（项目要求，2026-09-24）
//   --------------------------------------------------------------------
//       每一行有实际功能的代码，行尾都跟一条中文注释，说明"这行在做什么 / 为什么"。
//       本文件以 **UTF-8（无 BOM）** 编码保存。
//       纯声明、空行、end / endmodule / begin 之类不强制加注释。
//////////////////////////////////////////////////////////////////////////////

module glass_defect_core_v2 #(
    parameter integer H_ACTIVE = 972,   // 每行有效像素数（摄像头实际输出 972 个）
    parameter integer V_ACTIVE = 720    // 每帧有效行数
)(
    // ------------------------------------------------------------------
    // 时钟与复位
    // ------------------------------------------------------------------
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axis:m_axis:s_axis_bg:s_axi, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, INSERT_VIP 0" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input  wire        aclk,                                // 主时钟 100MHz，本模块所有触发器都用它
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input  wire        aresetn,                             // 低有效复位，来自 peripheral_aresetn

    // ------------------------------------------------------------------
    // 视频输入（来自 axis_broadcaster_0 的 M00_AXIS）
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [23:0] s_axis_tdata,                        // 像素：RGB565 左对齐补 0（见文件头）
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire        s_axis_tvalid,                       // 上游本拍有一个像素要给我们
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire        s_axis_tready,                       // 我们随时能收（直通下游的 ready）
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire        s_axis_tlast,                        // 本像素是**一行**的最后一个
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TUSER" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis, TDATA_NUM_BYTES 3, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 1, FREQ_HZ 100000000, PHASE 0.0, INSERT_VIP 0" *)
    input  wire        s_axis_tuser,                        // 本像素是**一帧**的第一个

    // ------------------------------------------------------------------
    // 视频输出（送到 axi_vdma_1 的 S_AXIS_S2MM）
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [23:0] m_axis_tdata,                        // 摄像头原图，或调试用的二值图
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire        m_axis_tvalid,                       // 原样复制 s_axis_tvalid
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire        m_axis_tready,                       // 下游 VDMA 能不能收
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire        m_axis_tlast,                        // 原样复制 s_axis_tlast
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TUSER" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 3, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 1, FREQ_HZ 100000000, PHASE 0.0, INSERT_VIP 0" *)
    output wire        m_axis_tuser,                        // 原样复制 s_axis_tuser

    // ------------------------------------------------------------------
    // 背景输入（来自 axi_vdma_0 的 M_MM2S）
    //
    //   PS 采好"空场景背景"后写进 DDR 的 bg_buf，由 axi_vdma_0/MM2S 循环读出来。
    //   ★ 只取最低字节 [7:0] 当 8 位灰度：PS 往 DDR 里填的就是 {g, g, g}，
    //     三个字节本来就相同 ⇒ 取哪个字节都一样，**不需要任何颜色换算**。
    //   ★ 这一路**允许被反压**（tready 由配对器给）：它是 VDMA 的独立通道，
    //     让它等一会儿不影响 HDMI 显示，也不会丢像素。
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_bg TDATA" *)
    input  wire [23:0] s_axis_bg_tdata,                     // ★ 背景彩色原图（PS 采背景时写进 buf_bg 的真实 RGB）
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_bg TVALID" *)
    input  wire        s_axis_bg_tvalid,                    // 背景本拍有一个像素
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_bg TREADY" *)
    output wire        s_axis_bg_tready,                    // 配对器要求背景稍等时拉低
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_bg TUSER" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis_bg, TDATA_NUM_BYTES 3, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, INSERT_VIP 0" *)
    input  wire        s_axis_bg_tuser,                     // 背景帧首（VDMA 每帧第一个像素拉高）

    // ------------------------------------------------------------------
    // AXI4-Lite 从口：统计量上报 PS，参数由 PS 下发
    //（BD 给本模块保留了 64KB 地址范围，我们只用到最底下几个寄存器）
    // ------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4LITE, ADDR_WIDTH 12, DATA_WIDTH 32, FREQ_HZ 100000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 2, INSERT_VIP 0" *)
    input  wire [11:0] s_axi_awaddr,                        // 写地址，只译码 [5:2] 这四位
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire        s_axi_awvalid,                       // 主机送来了有效的写地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire        s_axi_awready,                       // 我们现在能收写地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0] s_axi_wdata,                         // 写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]  s_axi_wstrb,                         // 字节选通，**本设计不使用**（只按整字写）
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire        s_axi_wvalid,                        // 主机送来了有效的写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire        s_axi_wready,                        // 我们现在能收写数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]  s_axi_bresp,                         // 写响应，恒为 OKAY
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire        s_axi_bvalid,                        // 一笔写已完成，响应可以取走
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire        s_axi_bready,                        // 主机取走写响应
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [11:0] s_axi_araddr,                        // 读地址，只译码 [5:2] 这四位
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire        s_axi_arvalid,                       // 主机送来了有效的读地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire        s_axi_arready,                       // 我们现在能收读地址
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0] s_axi_rdata,                         // 读数据
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]  s_axi_rresp,                         // 读响应，恒为 OKAY
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire        s_axi_rvalid,                        // 读数据已在总线上且稳定
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire        s_axi_rready                         // 主机取走读数据
);

    //=====================================================================
    // 寄存器编号（字地址 = addr[5:2]）
    //
    // 每个寄存器都落在 4 字节边界上，所以字节地址的 [5:2] 位
    // **就是**寄存器编号，不需要拿完整地址去比较。
    //=====================================================================
    //   ★ 2026-10-13：编号位宽由 [4:0] 扩到 [6:0]，译码从 addr[6:2] 扩到 addr[8:2]，
    //     才能覆盖 OSD 的 0x44~0x14C。**已用到的编号数值一个都没变**，向后兼容。
    localparam [6:0] IDX_ID      = 7'h00;   // 0x00  ID        只读
    localparam [6:0] IDX_CTRL    = 7'h01;   // 0x04  CTRL      读写
    localparam [6:0] IDX_STATUS  = 7'h02;   // 0x08  STATUS    只读（写 = 清粘滞位）
    localparam [6:0] IDX_SIZE_TH = 7'h03;   // 0x0C  SIZE_TH   读写
    localparam [6:0] IDX_SIZE_W  = 7'h04;   // 0x10  SIZE_W    只读
    localparam [6:0] IDX_SIZE_H  = 7'h05;   // 0x14  SIZE_H    只读
    localparam [6:0] IDX_AREA    = 7'h06;   // 0x18  AREA      只读
    localparam [6:0] IDX_DISP    = 7'h07;   // 0x1C  DISP      读写
    localparam [6:0] IDX_DEF_TH  = 7'h08;   // 0x20  DEF_TH    读写
    localparam [6:0] IDX_CRACK   = 7'h09;   // 0x24  DEF_CRACK 只读
    localparam [6:0] IDX_SHADOW = 7'h0A;    // 0x28  SHADOW_CFG 读写（★ 阴影抑制参数；原 DEF_STAIN 位置）
    localparam [6:0] IDX_BUBBLE  = 7'h0B;   // 0x2C  DEF_BUBBLE 只读
    localparam [6:0] IDX_SOB_TH  = 7'h0C;   // 0x30  SOB_TH    读写（支路 B）
    localparam [6:0] IDX_SOB_CNT = 7'h0D;   // 0x34  SOB_CNT   只读（支路 B 单独计数）
    localparam [6:0] IDX_BG_CTL  = 7'h0E;   // 0x38  BG_CTL    读写（bit0 = 背景差分使能）
    localparam [6:0] IDX_ALIGN1  = 7'h0F;   // 0x3C  ALIGN1    只读 {lead_max, lead_last}
    localparam [6:0] IDX_ALIGN2  = 7'h10;   // 0x40  ALIGN2    只读 {lap_cnt, stall_cnt}
    //   ★ OSD 的寄存器（0x44~0x14C）由 dd_osd 自己保管，这里的读 mux 只是转发（见文件末尾）

    // ---- 可写寄存器（保存 PS 最后一次写进来的值）----
    reg [31:0] ctrl_reg;        // 0x04：bit0 = 整条算法级的总使能
    reg [31:0] size_th_reg;     // 0x0C：bit0 使能、bit1 极性、[15:8] 灰度阈值
    reg [31:0] disp_reg;        // 0x1C：显示模式 0..8
    reg [31:0] def_th_reg;      // 0x20：bit0 使能、bit1 极性、bit2 中值使能、[15:8] 灰度阈值
    reg [31:0] sob_th_reg;      // 0x30：bit0 支路 B 使能、[15:8] Sobel 梯度阈值
    reg [31:0] bg_ctl_reg;      // 0x38：bit0 = 背景差分使能（背景没采好时必须为 0）
    reg [31:0] shadow_cfg_reg;  // 0x28：阴影抑制参数
                                //   [0]     阴影判据使能（0 ⇒ 退回纯 |ΔY| 的旧行为，安全阀）
                                //   [7:4]   亮度项权重 wY
                                //   [11:8]  色度项权重 wC
                                //   [23:16] 色度阈值 τc（建议 10~12，下限 8）
                                //   [31:24] αmin 定点码（128 = 0.5、192 = 0.75）

    // ---- 粘滞状态位：硬件置位、写 STATUS 清零 ----
    reg        st_size_done;    // STATUS bit0：尺寸检测至少发出过一次 done
    reg        st_def_done;     // STATUS bit1：目标检测至少发出过一次 done
    reg        st_def_flag;     // STATUS bit2：目标检测报告过有目标
    reg        st_sync_ok;      // STATUS bit3：至少见到过一次帧边界

    //=====================================================================
    // 发给两个检测子模块的观测信号
    //
    // AXIS 里"一个像素被传输了"的定义是 tvalid 与 tready 同时为 1，
    // 所以 px_valid 就是这两者的与。三个脉冲**都已经带 px_valid 限定**，
    // 子模块可以直接判断，不必再自己与一次 px_valid。
    //=====================================================================
    wire px_valid = s_axis_tvalid & s_axis_tready;      // 本拍确实在传一个像素
    wire px_sof   = px_valid & s_axis_tuser;            // ……而且它是一帧的第一个像素
    wire px_eol   = px_valid & s_axis_tlast;            // ……而且它是一行的最后一个像素

    reg [9:0] line_cnt;                                 // 本帧已经过了多少行（0..719）

    always @(posedge aclk) begin
        if (!aresetn)
            line_cnt <= 10'd0;                          // 复位后行计数归零
        else if (px_sof)
            line_cnt <= 10'd0;                          // 每帧开头重新同步，误差不会累积
        else if (px_eol)
            line_cnt <= (line_cnt == V_ACTIVE - 1) ? 10'd0 : line_cnt + 10'd1;  // 最后一行之后回卷
    end

    // 帧末 = 行计数正好停在第 719 行时又来了一个行尾。
    // px_eol 本身已经带 px_valid 限定，这里不用再与。
    wire px_eof = px_eol & (line_cnt == V_ACTIVE - 1);  // 每帧结束处的单拍脉冲

    //=====================================================================
    // 背景流的观测信号（来自 s_axis_bg，同样都带上 valid 限定）
    //=====================================================================
    // ★ 2026-10-12 改：这里**不再与 tready 相与**，直接用原始 tvalid。
    //   原因：dd_pair 现在会"挂起"（看到 B 帧首后把 b_ready 拉低、等 A 的帧首），
    //   如果这里带了 tready，挂起期间 bg_valid_i 恒为 0 ⇒ **看不见 B 的帧首** ✗
    //   ⇒ 帧首匹配直接失效。改成原始 tvalid 之后：
    //       · bg_valid_i = "B 这一拍有没有数据"（挂起期间也看得见）
    //       · "这一拍到底收没收" 由 dd_pair 内部算（b_valid & b_ready）
    wire        bg_valid_i = s_axis_bg_tvalid;                     // 背景本拍是否有数据（原始 tvalid，不受 ready 影响）
    wire [23:0] bg_pix_i   = s_axis_bg_tdata;                      // ★ 背景彩色原图（24 位直通，不再只取低字节）
    wire        bg_sof_i   = bg_valid_i & s_axis_bg_tuser;         // 背景帧首

    // 背景差分使能：总使能 CTRL[0] 与自己的使能位同时为 1 才工作。
    // ★ 不额外做帧首锁存 —— 配对器内部每帧都会重新对齐，
    //   使能中途变化最多让当帧输出无效（掩膜全黑），绝不会产生坏数据。
    wire        bg_diff_en = ctrl_reg[0] & bg_ctl_reg[0];

    //=====================================================================
    // 检测子模块。两个都是在同一条流上的纯旁听者：
    // 它们能看见像素，但既不能卡流、也不能延迟或修改像素。
    //=====================================================================
    wire [15:0] size_w, size_h;         // 放置物包围盒的宽和高（像素）
    wire [31:0] size_area;              // 本帧放置物像素的个数
    wire        size_done, size_hit;    // done = 帧末脉冲，hit = 当前像素是放置物

    wire [15:0] def_crack, def_stain, def_bubble;   // 本帧的各类计数
    wire [15:0] def_sob;                            // 【新】支路 B 单独的命中像素数
    wire        def_done, def_flag, def_hit;        // done = 帧末脉冲，flag = 本帧有目标
    wire        def_hit_b, def_hit_or;              // 【新】支路 B 的掩膜 / 取或之后的掩膜
    wire        def_hit_fin;                        // 【新】形态学之后的最终掩膜
    wire [7:0]  def_gray, def_diff;                 // 【新】当前帧灰度 Y_A / |ΔY|（供 DISP=6 / 8）
    wire [23:0] def_bg;                             // 【新】配对后的背景**彩色**（供 DISP=7）
    wire [7:0]  def_cdiff, def_shadow;              // ★ 色度差 / 阴影标记（供 DISP=9 / 10）
    wire        bg_ready;                           // 【新】配对器给背景流的反压
    wire [15:0] align_lead, align_leadmax;          // 【新】对齐诊断
    wire [15:0] align_stall, align_lap;             // 【新】对齐诊断

    size_detect #(
        .H_ACTIVE (H_ACTIVE),           // 把几何参数传下去，子模块自己也能用
        .V_ACTIVE (V_ACTIVE)            // ……
    ) size_detect_0 (
        .clk      (aclk),               // 与全工程同一个 100MHz 域
        .rst_n    (aresetn),            // 低有效，和顶层一致
        .px_data  (s_axis_tdata),       // 原始像素，不做任何加工
        .px_valid (px_valid),           // 像素传输选通
        .px_sof   (px_sof),             // 帧首（已带 px_valid 限定）
        .px_eol   (px_eol),             // 行尾（已带 px_valid 限定）
        .px_eof   (px_eof),             // 帧尾（已带 px_valid 限定）
        .en       (ctrl_reg[0] & size_th_reg[0]),   // 总使能和自己的使能都为 1 才工作
        .polarity (size_th_reg[1]),     // 0 = 放置物比背景亮
        .th       (size_th_reg[15:8]),  // PS 下发的灰度阈值
        .w        (size_w),             // 结果：包围盒宽度
        .h        (size_h),             // 结果：包围盒高度
        .area     (size_area),          // 结果：放置物像素数
        .done     (size_done),          // 帧末单拍脉冲
        .px_hit   (size_hit)            // 调试用：喂给 DISP 显示二值图
    );

    defect_detect #(
        .H_ACTIVE (H_ACTIVE),           // 同样的几何参数
        .V_ACTIVE (V_ACTIVE)            // ……
    ) defect_detect_0 (
        .clk         (aclk),            // 与全工程同一个 100MHz 域
        .rst_n       (aresetn),         // 低有效
        .px_data     (s_axis_tdata),    // 原始像素，不做任何加工
        .px_valid    (px_valid),        // 像素传输选通
        .px_sof      (px_sof),          // 帧首（已带 px_valid 限定）
        .px_eol      (px_eol),          // 行尾（已带 px_valid 限定）
        .px_eof      (px_eof),          // 帧尾（已带 px_valid 限定）
        .en          (ctrl_reg[0] & def_th_reg[0]), // 总使能门控
        .polarity    (def_th_reg[1]),   // 0 = 目标比放置物亮
        .med_en      (def_th_reg[2]),   // 1 = 启用 3x3 中值（去孤立噪点）/ 0 = 旁路（保 3.6px 小目标）
        .morph_en    (def_th_reg[3]),   // 【新】1 = 启用闭运算 / 0 = 旁路（输出=取或的原始掩膜）
        .th          (def_th_reg[15:8]),// PS 下发的灰度阈值
        .sob_en      (ctrl_reg[0] & sob_th_reg[0]), // 【新】支路 B 使能，同样受总使能门控
        .sob_th      (sob_th_reg[15:8]),// 【新】Sobel 梯度阈值
        .bg_valid    (bg_valid_i),      // 【新】背景流（来自 s_axis_bg）
        .bg_pix      (bg_pix_i),        // ★ 背景彩色原图（24 位）
        .bg_sof      (bg_sof_i),        // 【新】背景帧首
        .diff_en     (bg_diff_en),      // 【新】背景差分使能（受总使能门控）
        .sh_en       (shadow_cfg_reg[0]),       // ★ 阴影判据使能
        .sh_wy       (shadow_cfg_reg[7:4]),     // ★ 亮度项权重 wY
        .sh_wc       (shadow_cfg_reg[11:8]),    // ★ 色度项权重 wC
        .sh_tau      (shadow_cfg_reg[23:16]),   // ★ 色度阈值 τc
        .sh_alpha    (shadow_cfg_reg[31:24]),   // ★ αmin 定点码
        .bg_ready    (bg_ready),        // 【新】配对器反压 -> 回 s_axis_bg_tready
        .crack_cnt   (def_crack),       // 结果：本帧细线计数
        .stain_cnt   (def_stain),       // 结果：本帧斑块数量
        .bubble_cnt  (def_bubble),      // 结果：本帧斑块计数
        .defect_flag (def_flag),        // 结果：本帧至少有一个目标（按形态学之后的掩膜判定）
        .done        (def_done),        // 帧末单拍脉冲
        .sob_cnt     (def_sob),         // 【新】结果：支路 B 单独的命中像素数
        .px_hit      (def_hit),         // 支路 A 的命中（DISP=2，语义冻结）
        .px_hit_b    (def_hit_b),       // 【新】支路 B 的命中（DISP=3）
        .px_hit_or   (def_hit_or),      // 【新】A|B 的命中（DISP=4）
        .px_hit_fin  (def_hit_fin),     // 【新】形态学之后的最终掩膜（DISP=5）
        .px_gray     (def_gray),        // 【新】当前帧灰度 Y_A（DISP=6）
        .px_diff     (def_diff),        // 【新】|ΔY| 亮度差（DISP=8）
        .px_bg       (def_bg),          // 【新】配对后的背景彩色（DISP=7）
        .px_cdiff    (def_cdiff),       // ★ 色度差 |ΔCb|+|ΔCr|（DISP=9）
        .px_shadow   (def_shadow),      // ★ 阴影标记（DISP=10）
        .align_lead  (align_lead),      // 【新】对齐诊断：最近量到的两路领先量
        .align_leadmax(align_leadmax),  // 【新】对齐诊断：峰值领先量
        .align_stall (align_stall),     // 【新】对齐诊断：停顿拍数
        .align_lap   (align_lap)        // 【新】对齐诊断：越圈拍数
    );

    //=====================================================================
    // 显示选择
    //
    // 模式在**每帧开头重新锁存**，这样同一帧里不会出现
    // 上半屏原图、下半屏二值图（那会撕裂）。
    //   0 = 摄像头原图
    //   1 = size_detect   二值图（白 = 命中）
    //   2 = defect_detect **支路 A**（灰度阈值）二值图
    //   3 = defect_detect **支路 B**（Sobel）二值图
    //   4 = defect_detect **A|B**（取或）二值图
    //   5 = defect_detect **形态学之后的最终掩膜**
    //   6 = 【新】当前帧**灰度图**（dd_gray 输出，三通道填同值 ⇒ 屏上黑白）
    //   7 = 【新】**背景图**（DDR 里 PS 采好的空场景，用来确认背景采得对不对）
    //   8 = 【新】**差分图 |A−B|**（0 = 与背景一模一样，越亮差得越多）
    //   ≥9 = 非法值 ⇒ 全部选择信号为 0 ⇒ 显示原图（不会出乱码）
    //
    // ★ 总使能 CTRL[0] 也**一起在帧首锁存**（原来是在输出处再串一个多路选择）。
    //   好处：输出那一段少一级组合逻辑 —— 这条链原来是
    //       disp_cur 寄存器 → 比大小 → 24 位多路选择 → CTRL 多路选择 → VDMA
    //   现在只剩
    //       disp_cur 寄存器 → 2 个 1 位判断（并行）→ 24 位多路选择 → VDMA
    //   少的一级大约值 1ns 的组合延迟，直接还给时序余量。
    //   代价：CTRL[0] 关掉显示的效果**下一帧开头**才生效（≤35ms，肉眼无感），
    //         而不再是同一拍立刻生效。这个代价值得。
    //=====================================================================
    wire [3:0] disp_next = ctrl_reg[0] ? disp_reg[3:0] : 4'd0;  // 总使能关掉时强制回原图

    reg [3:0] disp_cur;                                 // 当前这一帧实际使用的显示模式（0..8）

    always @(posedge aclk) begin
        if (!aresetn)
            disp_cur <= 4'd0;                           // 复位后显示摄像头原图
        else if (px_sof)
            disp_cur <= disp_next;                      // 只在帧边界处换模式（含总使能）
    end

    // 各个"选择"信号**并行**做，彼此不串（都是拿 disp_cur 跟常数比），
    // 最后只用一级与、一级或收起来 ⇒ 组合深度仍只有 3 级 LUT。
    //   d1 = 显示尺寸二值图        d2 = 显示支路 A 的掩膜
    //   d3 = 显示支路 B 的掩膜      d4 = 显示取或的掩膜
    //   d5 = 显示形态学之后的最终掩膜
    //   d6 = 灰度图（新）           d7 = 背景图（新）   d8 = 差分图（新）
    //   注意 disp_cur 写了 9 及以上的非法值时：全部 d* 都是 0 ⇒
    //   disp_bin = disp_gray = 0 ⇒ 老老实实显示原图，不会出乱码。
    wire d1 = (disp_cur == 4'd1);                       // 选尺寸
    wire d2 = (disp_cur == 4'd2);                       // 选支路 A
    wire d3 = (disp_cur == 4'd3);                       // 选支路 B
    wire d4 = (disp_cur == 4'd4);                       // 选取或
    wire d5 = (disp_cur == 4'd5);                       // 选形态学之后
    wire d6 = (disp_cur == 4'd6);                       // 【新】选灰度图
    wire d7 = (disp_cur == 4'd7);                       // 【新】选背景图
    wire d8 = (disp_cur == 4'd8);                       // 【新】选差分图
    wire d9  = (disp_cur == 4'd9);                      // ★ 选色度差 |ΔCb|+|ΔCr|（调 τc 就看这一档）
    wire d10 = (disp_cur == 4'd10);                     // ★ 选阴影标记（255 = 判为阴影）
    wire disp_bin  = d1 | d2 | d3 | d4 | d5;            // 是否显示二值图视图（1..5 都是）
    wire disp_gray = d6 | d7 | d8 | d9 | d10;           // 【新】是否显示灰度/彩色视图（6..10）
    wire disp_hit = (d1 & size_hit) | (d2 & def_hit)    // 尺寸 / 支路 A
                  | (d3 & def_hit_b)                    // 支路 B
                  | (d4 & def_hit_or)                   // 取或
                  | (d5 & def_hit_fin);                 // 形态学之后（并行五路取或，不串延迟）

    // 灰度视图的像素：三通道填同一个值 ⇒ 屏上是黑白图。
    //   d6 = 当前帧灰度（dd_gray 输出）、d7 = **配对后的**背景（和屏同源 ⇒ 不会被切）、d8 = 差分绝对值
    //   ★ d7 以前直接显示原始 B 流（s_axis_bg_tdata）—— 那条流和屏的行场时序不同源，
    //     屏上必然出现"同一张图被拦腰切断"（实测：每次采集切口还不一样）✗
    //     现在改成显示配对器的输出 p_b_pix ⇒ 逐像素对齐 ⇒ 是完整一帧 ✓
    wire [23:0] gray_pix = d6 ? {def_gray, def_gray, def_gray}       // 灰度图 Y_A
                         : d7 ? def_bg                              // ★ 配对后的背景**彩色**（24 位直出）
                         : d8 ? {def_diff,  def_diff,  def_diff}     // |ΔY| 亮度差
                         : d9 ? {def_cdiff, def_cdiff, def_cdiff}    // ★ 色度差（阴影区应接近黑）
                         :      {def_shadow, def_shadow, def_shadow};// ★ 阴影标记（白 = 判为阴影）

    wire [23:0] disp_pix = disp_bin  ? (disp_hit ? 24'hFFFFFF : 24'h000000)  // 二值图：白 = 命中、黑 = 未命中
                         : disp_gray ? gray_pix                              // 灰度视图（6/7/8）
                         : s_axis_tdata;                                     // 常规：摄像头原图

    // 视频通路 —— 纯组合直通
    //
    // 故意做成组合逻辑，这样 tdata / tvalid / tuser / tlast 永远处在同一拍；
    // 如果在这里插一级流水寄存器却忘了同样延迟 tuser 和 tlast，整个画面就会错位。
    // CTRL[0] = 0 时完全旁路显示选择（在 disp_cur 那一级就旁路掉了），
    // 模块行为与原来的直通骨架一模一样。
    // 绝不能把 s_axis_tready 拉低：上游 broadcaster 没有缓冲，
    // 这里一卡，连原图存档那一路会一起卡死。
    //
    // ★ 已知的 1 像素错位（只影响调试观察，不影响检测）：
    //   DISP=1 用的是 size_detect 的命中标志，与像素同为 0 拍 ⇒ 完全对齐；
    //   DISP=2 用的是 defect_detect 的命中标志，那条链因为插了流水寄存器，
    //   比像素晚 1 拍 ⇒ 黑白图在屏幕上**右移 1 个像素**（每行最左边 1 个像素
    //   是上一拍留下的残值）。要彻底对齐就得把整条视频通路也延迟 1 拍，
    //   而那会动到 AXIS 握手，风险远大于收益，暂不做。
    //=====================================================================
    // ★ 2026-10-13：这四根 assign 挪到**文件末尾**了 —— 因为 OSD 要接 AXI-Lite 的写提交信号
    //   （wr_fire / awaddr_r / wdata_r），那些信号在下面才声明，Verilog 不允许"先用后声明"。
    //   同时输出改成"经 OSD 叠加 + 打一拍寄存"，见末尾「OSD 叠加与输出寄存」一节。
    // ★ 背景口的 ready 必须驱动（2026-10-11 踩过大坑）：
    //   漏了这一行 ⇒ 综合把 s_axis_bg_tready 当常量 0 ⇒ b_valid 恒 0 ⇒ 配对器永不出数
    //   ⇒ 下游差分/中值/阈值/形态学**整条被判成死逻辑剪掉**（OOC 从 800 LUT/4 RAMB18
    //   掉到 177 LUT/0 RAMB18，总量反而少了 586 LUT）。判据就是看 OOC 资源有没有涨。
    assign s_axis_bg_tready = bg_ready;                             // 配对器说能收才收（不影响显示那一路）

    //=====================================================================
    // AXI4-Lite 从口 —— 寄存器文件
    //=====================================================================
    reg        aw_got, w_got;       // "地址到了" / "数据到了" 两个标志
    reg [11:0] awaddr_r;            // 锁存的写地址（用于译码）
    reg [31:0] wdata_r;             // 锁存的写数据
    reg        bvalid_r, rvalid_r;  // 写响应待取 / 读数据待取
    reg [31:0] rdata_r;             // 送到 RDATA 上的读数据寄存器

    wire       wr_fire = aw_got & w_got;    // 写的两半都到齐 -> 提交
    wire [6:0] wr_idx  = awaddr_r[8:2];     // 正在写的寄存器编号（★ 2026-10-13 扩到 [8:2]，够着 OSD 的 0x44~0x14C）
    wire [6:0] rd_idx  = s_axi_araddr[8:2]; // 正在读的寄存器编号（同上）
    wire [31:0] osd_rd;                     // OSD 寄存器的读回值（由文件末尾的 dd_osd 实例驱动）

    // ---- 读多路选择：纯组合，在 AR 被接受的那一拍采样 ----
    reg [31:0] rdata_c;                                 // 即将装进 rdata_r 的值
    always @(*) begin
        case (rd_idx)
            IDX_ID:      rdata_c = 32'hDEADBEEF;        // 固定标记：读一次就能证明通路活着
            IDX_CTRL:    rdata_c = ctrl_reg;            // 回读 PS 写进来的值
            IDX_STATUS:  rdata_c = {28'd0, st_sync_ok, st_def_flag, st_def_done, st_size_done}; // 四个粘滞位
            IDX_SIZE_TH: rdata_c = size_th_reg;         // 回读
            IDX_SIZE_W:  rdata_c = {16'd0, size_w};     // 16 位结果零扩展
            IDX_SIZE_H:  rdata_c = {16'd0, size_h};     // 16 位结果零扩展
            IDX_AREA:    rdata_c = size_area;           // 本来就是 32 位
            IDX_DISP:    rdata_c = disp_reg;            // 回读
            IDX_DEF_TH:  rdata_c = def_th_reg;          // 回读
            IDX_CRACK:   rdata_c = {16'd0, def_crack};  // 零扩展
            IDX_SHADOW:  rdata_c = shadow_cfg_reg;      // ★ 回读阴影抑制参数（原 DEF_STAIN 位置）
            IDX_BUBBLE:  rdata_c = {16'd0, def_bubble}; // 零扩展
            IDX_SOB_TH:  rdata_c = sob_th_reg;          // 【新】回读支路 B 的参数
            IDX_SOB_CNT: rdata_c = {16'd0, def_sob};    // 【新】支路 B 单独的命中像素数
            IDX_BG_CTL:  rdata_c = bg_ctl_reg;          // 【新】回读背景差分使能
            IDX_ALIGN1:  rdata_c = {align_leadmax, align_lead};    // 【新】{峰值领先量, 最近领先量}
            IDX_ALIGN2:  rdata_c = {align_lap, align_stall};       // 【新】{越圈拍数, 停顿拍数}
            default:     rdata_c = (rd_idx >= 7'd17) ? osd_rd : 32'd0;  // ★ 0x44 以上交给 OSD，其余读 0
        endcase
    end

    // ---- 写通道 ----
    // AW 和 W 是两条独立通道，可能相隔好几个周期才到，
    // 所以分别锁存，**两者都到齐**才真正提交寄存器。
    // 只读地址也会被接受并回 OKAY，只是不写任何东西。
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_got       <= 1'b0;           // 没有待处理的地址
            w_got        <= 1'b0;           // 没有待处理的数据
            awaddr_r     <= 12'd0;          // 清写地址锁存
            wdata_r      <= 32'd0;          // 清写数据锁存
            bvalid_r     <= 1'b0;           // 没有待取的写响应
            ctrl_reg     <= 32'd0;          // 总使能关闭 -> 画面原样透传
            size_th_reg  <= 32'd0;          // 尺寸检测关闭
            disp_reg     <= 32'd0;          // 显示 = 摄像头原图
            def_th_reg   <= 32'd0;          // 目标检测关闭
            sob_th_reg    <= 32'd0;          // ★ 支路 B 关闭（默认 ⇒ 行为与里程碑 2 完全一致）
            bg_ctl_reg    <= 32'd0;          // ★ 背景差分关闭（默认 ⇒ 掩膜全黑，不会误报）
            shadow_cfg_reg<= 32'd0;          // ★ 阴影抑制默认关闭 ⇒ 行为与旧版逐像素一致（安全阀）
            st_size_done <= 1'b0;           // 清空全部粘滞状态位
            st_def_done  <= 1'b0;           // ……
            st_def_flag  <= 1'b0;           // ……
            st_sync_ok   <= 1'b0;           // ……
        end else begin
            // 粘滞状态位放在**最前面**赋值，这样下面"写 STATUS 清零"
            // 在同一拍发生时能够覆盖掉这里的置位
            if (px_eof)              st_sync_ok   <= 1'b1;  // 见到过一次帧边界
            if (size_done)           st_size_done <= 1'b1;  // 尺寸检测跑完了一帧
            if (def_done)            st_def_done  <= 1'b1;  // 目标检测跑完了一帧
            if (def_done & def_flag) st_def_flag  <= 1'b1;  // ……而且它检出了问题

            // 收 AW：锁存地址并记下"地址这一半到了"
            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_r <= s_axi_awaddr;                   // 留到下面译码用
                aw_got   <= 1'b1;                           // 标记地址已到
            end
            // 收 W：锁存数据并记下"数据这一半到了"
            if (s_axi_wready && s_axi_wvalid) begin
                wdata_r <= s_axi_wdata;                     // 留到下面提交用
                w_got   <= 1'b1;                            // 标记数据已到
            end

            // 两半都到齐 -> 提交寄存器，然后回响应
            if (wr_fire) begin
                aw_got   <= 1'b0;                           // 消费掉地址那一半
                w_got    <= 1'b0;                           // 消费掉数据那一半
                bvalid_r <= 1'b1;                           // 拉起 BVALID：响应可以取了
                case (wr_idx)
                    IDX_CTRL:    ctrl_reg    <= wdata_r;    // 写 0x04
                    IDX_SIZE_TH: size_th_reg <= wdata_r;    // 写 0x0C
                    IDX_DISP:    disp_reg    <= wdata_r;    // 写 0x1C
                    IDX_DEF_TH:  def_th_reg  <= wdata_r;    // 写 0x20
                    IDX_SOB_TH:  sob_th_reg  <= wdata_r;    // 写 0x30（支路 B 参数）
                    IDX_BG_CTL:  bg_ctl_reg  <= wdata_r;    // 写 0x38（背景差分使能）
                    IDX_SHADOW:  shadow_cfg_reg <= wdata_r; // ★ 写 0x28（阴影抑制参数）
                    IDX_STATUS: begin                       // 写 0x08 = 清粘滞位
                        st_size_done <= 1'b0;               // 清
                        st_def_done  <= 1'b0;               // 清
                        st_def_flag  <= 1'b0;               // 清
                        st_sync_ok   <= 1'b0;               // 清
                    end
                    default: ;                              // 只读/未用地址：忽略
                endcase
            end
            // 本拍没有提交 -> 若有响应待取且主机取走了，就撤销它
            else if (bvalid_r && s_axi_bready) begin
                bvalid_r <= 1'b0;                           // 写响应已被主机取走
            end
        end
    end

    // ready 只在空闲时为高，所以上一笔写没被取走响应之前不会开始下一笔。
    // 逻辑简单，对 PS 那几笔配置写来说足够快。
    assign s_axi_awready = ~aw_got & ~bvalid_r;             // 无待处理项才收写地址
    assign s_axi_wready  = ~w_got  & ~bvalid_r;             // 无待处理项才收写数据
    assign s_axi_bvalid  = bvalid_r;                        // 待响应标志直接驱动 BVALID
    assign s_axi_bresp   = 2'b00;                           // OKAY —— 本设计从不报错

    // ---- 读通道 ----
    // AR 只有一条通道，所以读比写简单得多：
    // 把译码出来的值锁存住，等主机取走即可。
    always @(posedge aclk) begin
        if (!aresetn) begin
            rvalid_r <= 1'b0;                               // 复位后没有待取的读数据
            rdata_r  <= 32'd0;                              // 清读数据寄存器
        end else if (s_axi_arready && s_axi_arvalid) begin
            rvalid_r <= 1'b1;                               // 拉起 RVALID：下一拍 RDATA 上有数据
            rdata_r  <= rdata_c;                            // 此刻采样组合读多路选择
        end else if (rvalid_r && s_axi_rready) begin
            rvalid_r <= 1'b0;                               // 主机取走了数据，撤销 RVALID
        end
    end

    assign s_axi_arready = ~rvalid_r;                       // 上一笔读被取走后才收新的读
    assign s_axi_rvalid  = rvalid_r;                        // 待取标志直接驱动 RVALID
    assign s_axi_rresp   = 2'b00;                           // OKAY —— 本设计从不报错
    assign s_axi_rdata   = rdata_r;                         // 寄存器输出的读数据

    //=====================================================================
    // OSD 叠加与输出寄存（2026-10-13 新增）
    //
    // 【为什么放这里】OSD 要接 AXI-Lite 的写提交信号（wr_fire/awaddr_r/wdata_r），
    //   那些在上面才声明；Verilog 不允许先用后声明，所以整块挪到文件末尾。
    //
    // 【为什么要打一拍】OSD 是"8 个框比较器 + 每框 16 选 1 + 字模 ROM + 取位"，
    //   组合路径远长于原来的 disp_pix 直通，必须寄存器隔断，否则时序打穿。
    //   ★ sideband（tvalid/tlast/tuser）**跟着一起打** ⇒ 整幅画面一起晚 1 拍，
    //     **相对偏移不变** ⇒ PS 侧的 SHIFT_X / SHIFT_Y 一个字都不用改。
    //
    // 【AXIS 语义】只在"下游能收、或我们自己的寄存器空着"时推进，保证不丢像素。
    //   m_axis_tready 常为 1 时，行为与原来完全一致（吞吐仍是 1 像素/拍）。
    //=====================================================================

    // ---- 列计数器（行计数 line_cnt 上面已经有了，直接复用）----
    reg [10:0] col_cnt;                                     // 本行已经过了多少列（0..H_ACTIVE-1）
    always @(posedge aclk) begin
        if (!aresetn)
            col_cnt <= 11'd0;                               // 复位归零
        else if (px_eol)
            col_cnt <= 11'd0;                               // 行尾清 0（这一拍本身还是最后一列）
        else if (px_valid)
            col_cnt <= col_cnt + 11'd1;                     // 每传一个像素 +1
    end

    // ---- 先声明所有寄存器/wire（Verilog 不允许"先用后声明"）----
    reg        o_v, o_l, o_u;                               // 输出级：寄存后的 valid / last / user
    reg [23:0] o_p;                                         // 输出级：寄存后的像素
    reg        d_v, d_l, d_u;                               // 中间级：sideband 延迟 1 拍
    // 流水使能：下游能收、或本机输出级空着 ⇒ 两级流水一起推进；反压时一起冻结
    wire       o_adv = m_axis_tready | ~o_v;

    // ---- OSD 叠加（内部 1 级流水 ⇒ pix_out 对应 **1 拍之前** 的输入）----
    wire [23:0] osd_pix;                                    // 叠加后的像素
    dd_osd #(
        .N_BOX   (8),                                       // 最多 8 个框
        .MAX_CHAR(16),                                      // 每框最多 16 个字符
        .THICK   (2)                                        // 框线 2 像素粗
    ) u_osd (
        .clk     (aclk),                                    // 100MHz
        .rstn    (aresetn),                                 // 低有效复位
        .en      (o_adv),                                   // ★ 流水使能（与 sideband 延迟级同步）
        .pix_in  (disp_pix),                                // 送进来的是 DISP 选好的那一路
        .col     (col_cnt),                                 // 当前列（画面坐标）
        .row     (line_cnt),                                // 当前行（复用已有行计数）
        .wr_en   (wr_fire),                                 // AXI 写提交脉冲（单拍）
        .wr_addr (awaddr_r),                                // 写字节地址
        .wr_data (wdata_r),                                 // 写数据
        .rd_idx  (rd_idx),                                  // 读寄存器编号
        .rd_data (osd_rd),                                  // 读回（接到上面的读 mux）
        .pix_out (osd_pix)                                  // 叠加结果（晚 1 拍）
    );

    // ---- 中间级：sideband 延迟 1 拍，与 dd_osd 内部那一级对齐 ----
    always @(posedge aclk) begin
        if (!aresetn) begin
            d_v <= 1'b0;                                    // 空
            d_l <= 1'b0;                                    // 行尾
            d_u <= 1'b0;                                    // 帧首
        end else if (o_adv) begin
            d_v <= s_axis_tvalid;                           // 这一拍有没有像素
            d_l <= s_axis_tlast;                            // 行尾跟着走
            d_u <= s_axis_tuser;                            // 帧首跟着走
        end
    end

    // ---- 输出级寄存（第 2 级）----
    always @(posedge aclk) begin
        if (!aresetn) begin
            o_v <= 1'b0;                                    // 空
            o_l <= 1'b0;                                    // 行尾
            o_u <= 1'b0;                                    // 帧首
            o_p <= 24'h000000;                              // 像素
        end else if (o_adv) begin
            o_v <= d_v;                                     // 与 osd_pix 同拍
            o_l <= d_l;                                     // 与 osd_pix 同拍
            o_u <= d_u;                                     // 与 osd_pix 同拍
            o_p <= osd_pix;                                 // 叠加后的像素
        end
    end

    assign m_axis_tdata  = o_p;                             // 输出像素（已叠加、已寄存）
    assign m_axis_tvalid = o_v;                             // 与之同拍
    assign m_axis_tlast  = o_l;                             // 与之同拍
    assign m_axis_tuser  = o_u;                             // 与之同拍
    assign s_axis_tready = o_adv;                           // 我们能收就收（等价于原来"下游能收"，多 1 格缓冲）

endmodule
