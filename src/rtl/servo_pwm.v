// ===========================================================================
// 物品回收智能分拣系统 · PL 侧源码（提交包副本）
// 本文件逻辑与工程内原件完全一致，仅在文件头追加本注释块，未改动任何一行代码。
// 文件   ：servo_pwm.v
// 层级   ：BD 顶层（自研）
// 作用   ：三路 SG90 PWM 生成 + AXI4-Lite 寄存器（每路独立的延时/角度/保持/斜坡/中位）
// 例化者 ：BD 中的 servo_pwm_0
// 备注   ：AXI-Lite 基地址 0x43C4_0000；脉宽在 PWM 周期边界影子锁存
// ===========================================================================
//=============================================================================
// servo_pwm.v —— 三路舵机驱动（AXI-Lite 从设备）  ★ v2：动作时序全部 PS 可控
//
// 【用途】SG90 之类的航模舵机：20 ms 周期、高电平脉宽决定角度。
//         一次完整动作 = 延时 → 偏转 → 保持 → 斜坡回中位，四个时间全部由寄存器给。
//
// 【为什么做在 PL】
//   1) PS 的 EMIO 只有 2 位，已被摄像头 SCCB(SCL/SDA) 占满；
//   2) Linux 下 Python 位敲脉宽抖动 10~20 µs ⇒ 舵机抖、导流板位置不稳；
//   3) 100 MHz 计数器分频出来的脉宽抖动是 0（一个时钟 10 ns）。
//   ★ 而且动作时序放在硬件里：PS 只管"踢一脚"(KICK)，之后哪怕 PS 卡顿/被打断，
//     硬件也会自己按时把舵机送回中位，不会出现"导流板永远歪着"的现场事故。
//
// 【时序】aclk = 100 MHz：周期 = 2^21 / 100 MHz = 20.97 ms；1 µs 高电平 = 100 拍。
//
// 【★ 三个可调的毫秒级时间（PS 写寄存器，改完下一次动作立即生效）】
//   T_DLY (0x20)  偏转延时：KICK 之后先等这么多 ms 才开始偏转（物体走过去的时间）
//   T_ACT (0x24)  偏转保持：到达偏位后停多久（让物体通过）
//   T_RET (0x28)  恢复时间：脉宽从偏位**线性**回到中位用多少 ms（斜坡，冲击小）
//
// 【安全设计】
//   · CTRL[0]=0 时三路输出**恒低**（无脉冲 ⇒ 舵机不受力）。上电默认就是关的。
//   · 脉宽**在使用时**限幅到 [PW_MIN, PW_MAX]（两者也是寄存器，可在 500~2500 内调）。
//     ★ 用"使用时限幅"而不是"写入时限幅"：标定时先写 PW_MAX=2200 再改 ACT，
//       新上限会立刻作用到已经写进去的值上，不用重写一遍。
//   · 回读 PWn_EFF 得到的是**限幅之后真正输出的脉宽**，上板可以直接核对。
//
// 【测试模式】CTRL[1]=1 时三路改输出三个不同频率的慢方波（0.75 / 1.49 / 2.98 Hz），
//   配合一颗 LED 逐个孔比，用来确认"排针丝印 ↔ FPGA 球号"的对应关系。
//
// 【寄存器表】（偏移，4 字节对齐；基址由 BD 分配，本项目用 0x43C40000）
//   0x00 ID        R   固定 0x53525630 ("SRV0")
//   0x04 CTRL      R/W bit0 总使能 / bit1 测试模式
//   0x08 PW0_ACT   R/W 通道0 偏转脉宽 µs        ┐
//   0x0C PW1_ACT   R/W 通道1 偏转脉宽 µs        ├ 标定后填（如 60° 对应 2140）
//   0x10 PW2_ACT   R/W 通道2 偏转脉宽 µs        ┘
//   0x14 PW0_IDLE  R/W 通道0 中位脉宽 µs        ┐
//   0x18 PW1_IDLE  R/W 通道1 中位脉宽 µs        ├ 一般 1500
//   0x1C PW2_IDLE  R/W 通道2 中位脉宽 µs        ┘
//   0x20 T_DLY     R/W ★ 偏转延时 ms（复位默认 2000）
//   0x24 T_ACT     R/W ★ 偏转保持 ms（复位默认 3000）
//   0x28 T_RET     R/W ★ 恢复斜坡 ms（复位默认 500）
//   0x2C KICK      W   写 bit n=1 ⇒ 通道 n 立刻开始一次完整动作（自清零）
//   0x30 STATUS    R   bit[2:0] = 忙（动过正中）  bit[5:3] = 正在延时等待段
//   0x34 PW_MIN    R/W 限幅下限 µs（默认 1000，硬限 500~2500）
//   0x38 PW_MAX    R/W 限幅上限 µs（默认 2000，硬限 500~2500）
//   0x3C CNT       R   周期计数器当前值（调试：连读两次应该在变）
//   0x40 PW0_EFF   R   通道0 **实际输出**的脉宽 µs（已限幅）
//   0x44 PW1_EFF   R   通道1 实际输出的脉宽 µs
//   0x48 PW2_EFF   R   通道2 实际输出的脉宽 µs
//
// 【AXI】端口名用标准 s_axi_ 前缀，Vivado 在 BD 里能自动推断出 S_AXI 接口。
//       awprot / arprot / wstrb 不用（只按整字访问）。
//=============================================================================

`timescale 1ns / 1ps

module servo_pwm #(
    parameter integer CLK_HZ    = 100_000_000,  // aclk 频率（仿真时可调小）
    parameter integer PERIOD_US = 20000,        // PWM 周期 µs（舵机标准 20 ms）
    parameter integer PW_DEF    = 1500,         // 复位默认脉宽 µs（中位）
    parameter integer TDLY_DEF  = 2000,         // 复位默认「偏转延时」ms
    parameter integer TACT_DEF  = 3000,         // 复位默认「偏转保持」ms
    parameter integer TRET_DEF  = 500,          // 复位默认「恢复时间」ms
    parameter integer TEST_HI   = 26            // 测试方波取 t_cnt 的位（仿真调到 6）
)(
    // ---------------- 时钟与复位 ----------------
    input  wire        s_axi_aclk,              // 主时钟 100 MHz
    input  wire        s_axi_aresetn,           // 低有效复位
    // ---------------- AXI-Lite 写地址通道 ----------------
    input  wire [7:0]  s_axi_awaddr,            // 写地址，只译码 [7:2]（64 个寄存器）
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    // ---------------- AXI-Lite 写数据通道 ----------------
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    // ---------------- AXI-Lite 写响应通道 ----------------
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    // ---------------- AXI-Lite 读地址通道 ----------------
    input  wire [7:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    // ---------------- AXI-Lite 读数据通道 ----------------
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    // ---------------- 三路舵机输出 ----------------
    output wire [2:0]  servo_o                 // 每路一根
);

    //=====================================================================
    // 常数
    //=====================================================================
    localparam integer CLK_PER_US = CLK_HZ / 1000000;            // 1 µs = 多少拍（100 MHz ⇒ 100）
    localparam integer CLK_PER_MS = CLK_HZ / 1000;               // 1 ms = 多少拍（100 MHz ⇒ 100000）
    localparam integer PERIOD_CYC = CLK_PER_US * PERIOD_US;       // 一个 PWM 周期 = 2,000,000 拍
    localparam integer CNT_W      = 21;                           // 2^21 = 2,097,152 > 2,000,000
    localparam integer MSD_W      = 17;                           // 1 ms 分频计数器位宽（≤131071）
    localparam integer PW_W       = 12;                           // 脉宽位宽（µs，0..4095）

    localparam [PW_W-1:0] HARD_MIN = 12'd500;                    // 硬下限：任何情况下不低于 500 µs
    localparam [PW_W-1:0] HARD_MAX = 12'd2500;                   // 硬上限：任何情况下不超过 2500 µs

    // 寄存器索引（地址 [7:2]）
    localparam [5:0] IDX_ID      = 6'd0;    // 0x00
    localparam [5:0] IDX_CTRL    = 6'd1;    // 0x04
    localparam [5:0] IDX_PW0A    = 6'd2;    // 0x08
    localparam [5:0] IDX_PW1A    = 6'd3;    // 0x0C
    localparam [5:0] IDX_PW2A    = 6'd4;    // 0x10
    localparam [5:0] IDX_PW0I    = 6'd5;    // 0x14
    localparam [5:0] IDX_PW1I    = 6'd6;    // 0x18
    localparam [5:0] IDX_PW2I    = 6'd7;    // 0x1C
    localparam [5:0] IDX_T_DLY   = 6'd8;    // 0x20
    localparam [5:0] IDX_T_ACT   = 6'd9;    // 0x24
    localparam [5:0] IDX_T_RET   = 6'd10;   // 0x28
    localparam [5:0] IDX_KICK    = 6'd11;   // 0x2C
    localparam [5:0] IDX_STATUS  = 6'd12;   // 0x30
    localparam [5:0] IDX_PWMIN   = 6'd13;   // 0x34
    localparam [5:0] IDX_PWMAX   = 6'd14;   // 0x38
    localparam [5:0] IDX_CNT     = 6'd15;   // 0x3C
    localparam [5:0] IDX_PW0EFF  = 6'd16;   // 0x40
    localparam [5:0] IDX_PW1EFF  = 6'd17;   // 0x44
    localparam [5:0] IDX_PW2EFF  = 6'd18;   // 0x48
    // ★ 2026-10-29 新增：三路各自独立的时间参数（三只舵机的带速/安装位置不同，必须分别调）
    //   写入规则：写 0x20/0x24/0x28 这三个"全局"寄存器 ⇒ **同时灌进三路**（向后兼容：
    //   老 PS 代码只写全局，效果还是"三路一样"）；写下面 9 个 ⇒ 只改对应的那一路。
    localparam [5:0] IDX_T_DLY0  = 6'd19;   // 0x4C 通道0 偏转延时 ms
    localparam [5:0] IDX_T_DLY1  = 6'd20;   // 0x50 通道1 偏转延时 ms
    localparam [5:0] IDX_T_DLY2  = 6'd21;   // 0x54 通道2 偏转延时 ms
    localparam [5:0] IDX_T_ACT0  = 6'd22;   // 0x58 通道0 偏转保持 ms
    localparam [5:0] IDX_T_ACT1  = 6'd23;   // 0x5C 通道1 偏转保持 ms
    localparam [5:0] IDX_T_ACT2  = 6'd24;   // 0x60 通道2 偏转保持 ms
    localparam [5:0] IDX_T_RET0  = 6'd25;   // 0x64 通道0 恢复斜坡 ms
    localparam [5:0] IDX_T_RET1  = 6'd26;   // 0x68 通道1 恢复斜坡 ms
    localparam [5:0] IDX_T_RET2  = 6'd27;   // 0x6C 通道2 恢复斜坡 ms

    //=====================================================================
    // 限幅函数
    //=====================================================================
    // 把脉宽夹到 [mn, mx] —— ★ 用在**送出脉宽的那一刻**，不是写入时
    function [PW_W-1:0] clamp_pw;
        input [PW_W-1:0] v;
        input [PW_W-1:0] mn;
        input [PW_W-1:0] mx;
        begin
            clamp_pw = (v < mn) ? mn : ((v > mx) ? mx : v);
        end
    endfunction
    // 把 PW_MIN/PW_MAX 寄存器本身夹到硬限 500~2500
    function [PW_W-1:0] clamp_hard;
        input [31:0] v;
        begin
            clamp_hard = (v < HARD_MIN) ? HARD_MIN : ((v > HARD_MAX) ? HARD_MAX : v[PW_W-1:0]);
        end
    endfunction

    //=====================================================================
    // 寄存器
    //=====================================================================
    reg [31:0]      ctrl_reg;              // 总控
    reg [PW_W-1:0]  pw0a_reg, pw1a_reg, pw2a_reg;   // 各路偏转脉宽
    reg [PW_W-1:0]  pw0i_reg, pw1i_reg, pw2i_reg;   // 各路中位脉宽
    reg [PW_W-1:0]  pwmin_reg, pwmax_reg;           // 限幅上下限
    reg [15:0]      tdly_reg, tact_reg, tret_reg;   // ★ 三个毫秒级时间（全局默认值 / 写它们会灌到三路）
    // ★ 2026-10-29 新增：每路各自一份时间参数 ⇒ 三只舵机可以独立调节
    reg [15:0] tdly_ch0, tdly_ch1, tdly_ch2;       // 0x4C/0x50/0x54  各通道偏转延时 ms
    reg [15:0] tact_ch0, tact_ch1, tact_ch2;       // 0x58/0x5C/0x60  各通道偏转保持 ms
    reg [15:0] tret_ch0, tret_ch1, tret_ch2;       // 0x64/0x68/0x6C  各通道恢复斜坡 ms
    reg [2:0]       kick_r;                         // 单拍动作请求

    // 写通道锁存
    reg        aw_got;
    reg        w_got;
    reg [7:0]  awaddr_r;
    reg [31:0] wdata_r;
    reg        bvalid_r;
    // 读通道锁存
    reg        rvalid_r;
    reg [31:0] rdata_r;

    wire       wr_fire = aw_got & w_got;
    wire [5:0] wr_idx  = awaddr_r[7:2];
    wire [5:0] rd_idx  = s_axi_araddr[7:2];

    //=====================================================================
    // 1 ms 单拍脉冲：每 CLK_PER_MS 拍出现一次，用来驱动 servo_ch 的四段时序
    //=====================================================================
    reg [MSD_W-1:0] ms_div;                // 1 ms 分频计数
    wire            ms_tick = (ms_div == CLK_PER_MS[MSD_W-1:0] - 1'b1);
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            ms_div <= {MSD_W{1'b0}};                        // 复位清零
        end else if (ms_tick) begin
            ms_div <= {MSD_W{1'b0}};                        // 满 1 ms 回零
        end else begin
            ms_div <= ms_div + 1'b1;                        // 继续数
        end
    end

    //=====================================================================
    // 1 µs 单拍脉冲：给恢复斜坡（servo_ch 的 ④ 段）做 DDA 时间基准
    //=====================================================================
    reg [MSD_W-1:0] us_div;                // 1 µs 分频计数
    wire            us_tick = (us_div == CLK_PER_US[MSD_W-1:0] - 1'b1);
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            us_div <= {MSD_W{1'b0}};                        // 复位清零
        end else if (us_tick) begin
            us_div <= {MSD_W{1'b0}};                        // 满 1 µs 回零
        end else begin
            us_div <= us_div + 1'b1;                        // 继续数
        end
    end

    //=====================================================================
    // 恢复斜坡阈值 thr = t_ret(ms) × 1000（µs），**在这里算一次并寄存**
    //   ★ 三个通道共用一份：省 2 个 DSP，而且乘法结果进了寄存器，
    //     后面 通道里的"加法 → 比较"就不会和乘法串在同一条组合链上
    //     （没寄存时实测关键路径 11.2 ns、WNS −1.288，就是这么来的）
    //=====================================================================
    reg [26:0] thr_r;                      // 斜坡阈值（µs）—— 全局默认（保留，作参考/兼容）
    // ★ 2026-10-29 新增：每路自己的斜坡阈值（t_ret × 1000），同样是"父模块寄存好再送进去"，
    //   保持原来那条时序修法的形状不变（乘法结果先进寄存器，通道里只剩"加法→比较"）。
    reg [26:0] thr0_r, thr1_r, thr2_r;     // 三路各自的斜坡阈值（µs）
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            thr_r  <= 27'd0;               // 全局阈值清零
            thr0_r <= 27'd0;               // 通道0 阈值清零
            thr1_r <= 27'd0;               // 通道1 阈值清零
            thr2_r <= 27'd0;               // 通道2 阈值清零
        end else begin
            thr_r  <= {11'd0, tret_reg}  * 27'd1000;   // 全局：t_ret(ms) × 1000 → µs
            thr0_r <= {11'd0, tret_ch0}  * 27'd1000;   // 通道0：各自 t_ret × 1000
            thr1_r <= {11'd0, tret_ch1}  * 27'd1000;   // 通道1
            thr2_r <= {11'd0, tret_ch2}  * 27'd1000;   // 通道2
        end
    end

    //=====================================================================
    // 送进 servo_ch 的脉宽：使用时限幅 ⇒ 改 PW_MIN/PW_MAX 立即作用到已写的值
    //=====================================================================
    wire [PW_W-1:0] act0 = clamp_pw(pw0a_reg, pwmin_reg, pwmax_reg);   // 通道0 偏位
    wire [PW_W-1:0] act1 = clamp_pw(pw1a_reg, pwmin_reg, pwmax_reg);   // 通道1 偏位
    wire [PW_W-1:0] act2 = clamp_pw(pw2a_reg, pwmin_reg, pwmax_reg);   // 通道2 偏位
    wire [PW_W-1:0] idl0 = clamp_pw(pw0i_reg, pwmin_reg, pwmax_reg);   // 通道0 中位
    wire [PW_W-1:0] idl1 = clamp_pw(pw1i_reg, pwmin_reg, pwmax_reg);   // 通道1 中位
    wire [PW_W-1:0] idl2 = clamp_pw(pw2i_reg, pwmin_reg, pwmax_reg);   // 通道2 中位

    //=====================================================================
    // 三个通道的状态机
    //=====================================================================
    wire [PW_W-1:0] pw0, pw1, pw2;         // 各通道当前脉宽
    wire [2:0]      busy, in_dly;          // 忙 / 正在延时等待
    wire [1:0] pend0, pend1, pend2;        // ★ 三路各自的待发队列深度（0~3）

    servo_ch #(.PW_W(PW_W)) u_ch0 (
        .clk    (s_axi_aclk),
        .rstn   (s_axi_aresetn),
        .ms_tick(ms_tick),
        .us_tick(us_tick),
        .kick   (kick_r[0]),
        .t_dly  (tdly_ch0),
        .t_act  (tact_ch0),
        .t_ret  (tret_ch0),
        .thr_us (thr0_r),
        .act_in (act0),
        .idle_in(idl0),
        .pw_out (pw0),
        .busy   (busy[0]),
        .in_dly (in_dly[0]),
        .pending(pend0)
    );
    servo_ch #(.PW_W(PW_W)) u_ch1 (
        .clk    (s_axi_aclk),
        .rstn   (s_axi_aresetn),
        .ms_tick(ms_tick),
        .us_tick(us_tick),
        .kick   (kick_r[1]),
        .t_dly  (tdly_ch1),
        .t_act  (tact_ch1),
        .t_ret  (tret_ch1),
        .thr_us (thr1_r),
        .act_in (act1),
        .idle_in(idl1),
        .pw_out (pw1),
        .busy   (busy[1]),
        .in_dly (in_dly[1]),
        .pending(pend1)
    );
    servo_ch #(.PW_W(PW_W)) u_ch2 (
        .clk    (s_axi_aclk),
        .rstn   (s_axi_aresetn),
        .ms_tick(ms_tick),
        .us_tick(us_tick),
        .kick   (kick_r[2]),
        .t_dly  (tdly_ch2),
        .t_act  (tact_ch2),
        .t_ret  (tret_ch2),
        .thr_us (thr2_r),
        .act_in (act2),
        .idle_in(idl2),
        .pw_out (pw2),
        .busy   (busy[2]),
        .in_dly (in_dly[2]),
        .pending(pend2)
    );

    //=====================================================================
    // 周期计数器（自由跑）
    //=====================================================================
    reg [CNT_W-1:0] p_cnt;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            p_cnt <= {CNT_W{1'b0}};
        end else if (p_cnt == PERIOD_CYC[CNT_W-1:0] - 1'b1) begin
            p_cnt <= {CNT_W{1'b0}};
        end else begin
            p_cnt <= p_cnt + 1'b1;
        end
    end

    //=====================================================================
    // ★ 把"限幅后的脉宽"再打一拍再去做乘法
    //   限幅本身是 2 个比较器 + 2 个 mux，紧接"×100 再与周期计数比较"会拉长组合链。
    //   打一拍只让 PWM 晚 10 ns（20 ms 周期里的 0.00005%），完全无感。
    //=====================================================================
    reg [PW_W-1:0] pw0_q, pw1_q, pw2_q;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            pw0_q <= PW_DEF[PW_W-1:0];
            pw1_q <= PW_DEF[PW_W-1:0];
            pw2_q <= PW_DEF[PW_W-1:0];
        end else begin
            pw0_q <= clamp_pw(pw0, pwmin_reg, pwmax_reg);   // 通道0 实际输出脉宽（寄存）
            pw1_q <= clamp_pw(pw1, pwmin_reg, pwmax_reg);   // 通道1
            pw2_q <= clamp_pw(pw2, pwmin_reg, pwmax_reg);   // 通道2
        end
    end

    //=====================================================================
    // ★★ 2026-10-30 新增 A：脉宽在 **PWM 周期边界** 再锁存一次
    //
    // 为什么必须加：`pwm0_i = (p_cnt < c0)` 是**纯电平比较**，而 c0 是从 pw0_q 组合算出来的。
    //   如果 pw 在一个周期**中途变大**（典型：kick 那一拍从 idle 1500 跳到 act 2000），
    //   而此刻 p_cnt 已经超过旧的 c0，那么 (p_cnt < c0) 会**再次成立** ⇒ 本周期出现**第二个高电平**
    //   ⇒ 舵机收到畸形帧 ⇒ 抖动/哆嗦。
    //   这正是"连续点测试舵机，第 2、3 次开始抖"的根因（kick 的相位随机，
    //   落在前 1500 µs 里没事、落在后面 92% 就会多一个脉冲）。
    // 做法：只在 p_cnt == 0（周期起点）把 pw0_q 锁进 pw0_s，本周期内 c0 恒定 ⇒ 不可能半周期变宽。
    // 代价：3×PW_W 个 FF，几乎为零；对外回读的 PWn_EFF 仍报 pw0_q（"我要求的值"），不受影响。
    //=====================================================================
    reg [PW_W-1:0] pw0_s, pw1_s, pw2_s;        // 周期边界锁存后的脉宽（真正参与比较）
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            pw0_s <= PW_DEF[PW_W-1:0];         // 复位给默认中位
            pw1_s <= PW_DEF[PW_W-1:0];
            pw2_s <= PW_DEF[PW_W-1:0];
        end else if (p_cnt == {CNT_W{1'b0}}) begin   // ★ 只在每个 PWM 周期起点更新一次
            pw0_s <= pw0_q;                    //   通道0 本周期用的脉宽
            pw1_s <= pw1_q;                    //   通道1
            pw2_s <= pw2_q;                    //   通道2
        end
    end

    //=====================================================================
    // 脉宽 → 高电平拍数（★ 用周期边界锁存版 pwX_s，保证一个周期内恒定）
    //=====================================================================
    wire [19:0] c0 = pw0_s * CLK_PER_US[19:0];   // 通道0 高电平拍数
    wire [19:0] c1 = pw1_s * CLK_PER_US[19:0];   // 通道1
    wire [19:0] c2 = pw2_s * CLK_PER_US[19:0];   // 通道2

    wire pwm0_i = (p_cnt < c0);                // 计数值小于脉宽 ⇒ 高
    wire pwm1_i = (p_cnt < c1);
    wire pwm2_i = (p_cnt < c2);

    //=====================================================================
    // 测试模式：三个不同频率的慢方波（0.75 / 1.49 / 2.98 Hz @100 MHz）
    //=====================================================================
    reg [26:0] t_cnt;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) t_cnt <= 27'd0;
        else                t_cnt <= t_cnt + 27'd1;
    end
    wire test0 = t_cnt[TEST_HI];               // 0.75 Hz
    wire test1 = t_cnt[TEST_HI-1];             // 1.49 Hz
    wire test2 = t_cnt[TEST_HI-2];             // 2.98 Hz

    //=====================================================================
    // 输出选择 + 打一拍
    //=====================================================================
    reg [2:0] servo_r;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            servo_r <= 3'b000;                                  // 复位：三路都低
        end else if (!ctrl_reg[0]) begin
            servo_r <= 3'b000;                                  // 未使能：三路都低
        end else if (ctrl_reg[1]) begin
            servo_r <= {test2, test1, test0};                    // 测试模式
        end else begin
            servo_r <= {pwm2_i, pwm1_i, pwm0_i};                // 正常 PWM
        end
    end
    assign servo_o = servo_r;

    //=====================================================================
    // AXI-Lite 写通道
    //=====================================================================
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_got    <= 1'b0;
            w_got     <= 1'b0;
            awaddr_r  <= 8'd0;
            wdata_r   <= 32'd0;
            bvalid_r  <= 1'b0;
            kick_r    <= 3'b000;
            ctrl_reg  <= 32'd0;                                 // ★ 复位后不输出
            pw0a_reg  <= PW_DEF[PW_W-1:0];                      // 各路偏位默认 = 中位
            pw1a_reg  <= PW_DEF[PW_W-1:0];
            pw2a_reg  <= PW_DEF[PW_W-1:0];
            pw0i_reg  <= PW_DEF[PW_W-1:0];                      // 中位默认 1500
            pw1i_reg  <= PW_DEF[PW_W-1:0];
            pw2i_reg  <= PW_DEF[PW_W-1:0];
            tdly_reg  <= TDLY_DEF[15:0];                        // 偏转延时默认 2000 ms
            tact_reg  <= TACT_DEF[15:0];                        // 偏转保持默认 3000 ms
            tret_reg  <= TRET_DEF[15:0];                        // 恢复斜坡默认 500 ms
            // ★ 三路各自的默认值：上电时与全局一致（等于"三路一样"），之后可单独改
            tdly_ch0 <= TDLY_DEF[15:0];  tdly_ch1 <= TDLY_DEF[15:0];  tdly_ch2 <= TDLY_DEF[15:0];  // 三路延时默认
            tact_ch0 <= TACT_DEF[15:0];  tact_ch1 <= TACT_DEF[15:0];  tact_ch2 <= TACT_DEF[15:0];  // 三路保持默认
            tret_ch0 <= TRET_DEF[15:0];  tret_ch1 <= TRET_DEF[15:0];  tret_ch2 <= TRET_DEF[15:0];  // 三路斜坡默认
            pwmin_reg <= 12'd1000;                              // 限幅默认 1000~2000
            pwmax_reg <= 12'd2000;
        end else begin
            kick_r <= 3'b000;                                   // ★ 动作请求只维持一拍
            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_r <= s_axi_awaddr;
                aw_got   <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                wdata_r <= s_axi_wdata;
                w_got   <= 1'b1;
            end
            if (wr_fire) begin
                aw_got   <= 1'b0;
                w_got    <= 1'b0;
                bvalid_r <= 1'b1;
                case (wr_idx)
                    IDX_CTRL:  ctrl_reg <= wdata_r;
                    // 偏位/中位都按 12 位截取存储；真正的限幅在送出时做（clamp_pw）
                    IDX_PW0A:  pw0a_reg <= wdata_r[PW_W-1:0];
                    IDX_PW1A:  pw1a_reg <= wdata_r[PW_W-1:0];
                    IDX_PW2A:  pw2a_reg <= wdata_r[PW_W-1:0];
                    IDX_PW0I:  pw0i_reg <= wdata_r[PW_W-1:0];
                    IDX_PW1I:  pw1i_reg <= wdata_r[PW_W-1:0];
                    IDX_PW2I:  pw2i_reg <= wdata_r[PW_W-1:0];
                    // ★ 写"全局"时间 = 同时灌进三路（向后兼容：老 PS 代码只写全局，效果不变）
                    IDX_T_DLY: begin tdly_reg <= wdata_r[15:0];   // ★ 偏转延时 ms
                                     tdly_ch0 <= wdata_r[15:0];   //   三路一起跟着变
                                     tdly_ch1 <= wdata_r[15:0];
                                     tdly_ch2 <= wdata_r[15:0]; end
                    IDX_T_ACT: begin tact_reg <= wdata_r[15:0];   // ★ 偏转保持 ms
                                     tact_ch0 <= wdata_r[15:0];   //   三路一起跟着变
                                     tact_ch1 <= wdata_r[15:0];
                                     tact_ch2 <= wdata_r[15:0]; end
                    IDX_T_RET: begin tret_reg <= wdata_r[15:0];   // ★ 恢复斜坡 ms
                                     tret_ch0 <= wdata_r[15:0];   //   三路一起跟着变
                                     tret_ch1 <= wdata_r[15:0];
                                     tret_ch2 <= wdata_r[15:0]; end
                    // ★ 2026-10-29 新增：只改某一路的时间（独立调节）
                    IDX_T_DLY0: tdly_ch0 <= wdata_r[15:0];        // 通道0 偏转延时 ms
                    IDX_T_DLY1: tdly_ch1 <= wdata_r[15:0];        // 通道1 偏转延时 ms
                    IDX_T_DLY2: tdly_ch2 <= wdata_r[15:0];        // 通道2 偏转延时 ms
                    IDX_T_ACT0: tact_ch0 <= wdata_r[15:0];        // 通道0 偏转保持 ms
                    IDX_T_ACT1: tact_ch1 <= wdata_r[15:0];        // 通道1 偏转保持 ms
                    IDX_T_ACT2: tact_ch2 <= wdata_r[15:0];        // 通道2 偏转保持 ms
                    IDX_T_RET0: tret_ch0 <= wdata_r[15:0];        // 通道0 恢复斜坡 ms
                    IDX_T_RET1: tret_ch1 <= wdata_r[15:0];        // 通道1 恢复斜坡 ms
                    IDX_T_RET2: tret_ch2 <= wdata_r[15:0];        // 通道2 恢复斜坡 ms
                    // ★ 写 KICK 的 bit n=1 ⇒ 通道 n 开始一次动作（下一拍传给状态机）
                    IDX_KICK:  kick_r   <= wdata_r[2:0];
                    // 限幅上下限：先夹到硬限 500~2500，再保证 min < max
                    IDX_PWMIN: begin
                        pwmin_reg <= (clamp_hard(wdata_r) > (pwmax_reg - 1'b1))
                                     ? (pwmax_reg - 1'b1) : clamp_hard(wdata_r);
                    end
                    IDX_PWMAX: begin
                        pwmax_reg <= (clamp_hard(wdata_r) < (pwmin_reg + 1'b1))
                                     ? (pwmin_reg + 1'b1) : clamp_hard(wdata_r);
                    end
                    default: ;                                      // 其余只读/未用
                endcase
            end else if (bvalid_r && s_axi_bready) begin
                bvalid_r <= 1'b0;
            end
        end
    end

    assign s_axi_awready = ~aw_got & ~bvalid_r;
    assign s_axi_wready  = ~w_got  & ~bvalid_r;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = 2'b00;

    //=====================================================================
    // AXI-Lite 读通道
    //=====================================================================
    reg [31:0] rdata_c;
    always @(*) begin
        case (rd_idx)
            IDX_ID:     rdata_c = 32'h53525630;                 // "SRV0"
            IDX_CTRL:   rdata_c = ctrl_reg;
            IDX_PW0A:   rdata_c = {20'd0, pw0a_reg};            // 回读原始写入值
            IDX_PW1A:   rdata_c = {20'd0, pw1a_reg};
            IDX_PW2A:   rdata_c = {20'd0, pw2a_reg};
            IDX_PW0I:   rdata_c = {20'd0, pw0i_reg};
            IDX_PW1I:   rdata_c = {20'd0, pw1i_reg};
            IDX_PW2I:   rdata_c = {20'd0, pw2i_reg};
            IDX_T_DLY:  rdata_c = {16'd0, tdly_reg};            // ★ 三个时间回读（全局）
            IDX_T_ACT:  rdata_c = {16'd0, tact_reg};
            IDX_T_RET:  rdata_c = {16'd0, tret_reg};
            // ★ 2026-10-29 新增：三路各自的时间回读（PS 可以直接核对每路实际生效的值）
            IDX_T_DLY0: rdata_c = {16'd0, tdly_ch0};            // 通道0 偏转延时
            IDX_T_DLY1: rdata_c = {16'd0, tdly_ch1};            // 通道1 偏转延时
            IDX_T_DLY2: rdata_c = {16'd0, tdly_ch2};            // 通道2 偏转延时
            IDX_T_ACT0: rdata_c = {16'd0, tact_ch0};            // 通道0 偏转保持
            IDX_T_ACT1: rdata_c = {16'd0, tact_ch1};            // 通道1 偏转保持
            IDX_T_ACT2: rdata_c = {16'd0, tact_ch2};            // 通道2 偏转保持
            IDX_T_RET0: rdata_c = {16'd0, tret_ch0};            // 通道0 恢复斜坡
            IDX_T_RET1: rdata_c = {16'd0, tret_ch1};            // 通道1 恢复斜坡
            IDX_T_RET2: rdata_c = {16'd0, tret_ch2};            // 通道2 恢复斜坡
            // ★ 2026-10-30：STATUS 扩展 —— bit[7:6] ch0 / [9:8] ch1 / [11:10] ch2 的待发队列深度
            //   0 = 没排队；非 0 = 忙时又来了请求、正在排队等
            //   （物理下限：同一路两轮动作不能重叠 ⇒ 最小可分辨间隔 = t_dly + t_act + t_ret）
            IDX_STATUS: rdata_c = {20'd0, pend2, pend1, pend0, in_dly, busy};
            IDX_PWMIN:  rdata_c = {20'd0, pwmin_reg};
            IDX_PWMAX:  rdata_c = {20'd0, pwmax_reg};
            IDX_CNT:    rdata_c = {{(32-CNT_W){1'b0}}, p_cnt};
            IDX_PW0EFF: rdata_c = {20'd0, pw0_q};               // ★ 实际输出脉宽（已限幅）
            IDX_PW1EFF: rdata_c = {20'd0, pw1_q};
            IDX_PW2EFF: rdata_c = {20'd0, pw2_q};
            default:    rdata_c = 32'd0;
        endcase
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rvalid_r <= 1'b0;
            rdata_r  <= 32'd0;
        end else if (s_axi_arready && s_axi_arvalid) begin
            rvalid_r <= 1'b1;
            rdata_r  <= rdata_c;
        end else if (rvalid_r && s_axi_rready) begin
            rvalid_r <= 1'b0;
        end
    end

    assign s_axi_arready = ~rvalid_r;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rdata   = rdata_r;

endmodule
