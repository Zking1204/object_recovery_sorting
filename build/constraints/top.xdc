##########################################################################
# top.xdc  --  PYNQ-Z2  +  wuxx PMOD-CAMERA v1.0  +  HDMI (direct TMDS)
#
# 摄像头引脚依据（用户实物确认）：转接板丝印 + PYNQ-Z2 原理图 + 板卡文件 part0_pins.xml
#   用户接线：J2 -> PmodA，J3 -> PmodB
#   ★ 转接板与 Pmod 是**跨排对接**（不是同号对接！）：
#         板子 pad 1-6   <->  转接板 7-12
#         板子 pad 7-12  <->  转接板 1-6
#   J2 控制口（转接板丝印）：1=NC 2=XMCLK 3=VSYNC 4=SDA 5=GND 6=3V3
#                            7=NC 8=PCLK  9=HREF 10=SCL 11=GND 12=3V3
#   J3 数据口（转接板丝印）：1=D6 2=D4 3=D2 4=D0 5=GND 6=3V3
#                            7=D7 8=D5 9=D3 10=D1 11=GND 12=3V3
#   转接板 PWDN/RESET 由板上 R6/R7(10K) 自己拉死，FPGA 不引出（BD 已删这两个脚）
#   电源四脚跨排后仍然对得上：板 5/11=GND <-> 转接板 11/5，板 6/12=3V3 <-> 转接板 12/6
#
# Pmod 上没有专用时钟引脚，所以 cam_pclk 要放开时钟布线限制。
# XCLK 由 FPGA 供给：24MHz XCLK -> OV5640 内部 x3 -> 72MHz PCLK。
##########################################################################

#------------------------- 摄像头接口时钟 -------------------------
create_clock -period 13.888 -name cam_pclk [get_ports cam_pclk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_IBUF]

# FPGA 送给摄像头的 24MHz（clk_wiz 产生），声明成输出时钟
create_clock -period 41.667 -name cam_xclk [get_ports cam_xclk]

#------------------------- 摄像头：J2 -> PmodA（控制口，跨排对接）-------------------------
# 转接板 J2 丝印：1=NC 2=XMCLK 3=VSYNC 4=SDA 5=GND 6=3V3 | 7=NC 8=PCLK 9=HREF 10=SCL 11=GND 12=3V3
# 跨排 => 转接板 2/3/4 落在板 pad 8/9/10；转接板 8/9/10 落在板 pad 2/3/4
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports cam_xclk]               ;# 转接板J2-2  XMCLK <- 板pad8  (JA3N)  FPGA->CAM 24MHz
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports cam_vsync]              ;# 转接板J2-3  VSYNC <- 板pad9  (JA4P)  CAM->FPGA
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {emio_sccb_tri_io[1]}]  ;# 转接板J2-4  SDA   <- 板pad10 (JA4N)  (I2C 数据)
#                                                                  转接板J2-1/7 = NC -> 板 pad7/pad1 (U18/Y18)，不分配
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports cam_pclk]               ;# 转接板J2-8  PCLK  <- 板pad2  (JA1N)  CAM->FPGA 72MHz
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports cam_href]               ;# 转接板J2-9  HREF  <- 板pad3  (JA2P)  CAM->FPGA
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {emio_sccb_tri_io[0]}]  ;# 转接板J2-10 SCL   <- 板pad4  (JA2N)  (I2C 时钟)

#------------------------- 摄像头：J3 -> PmodB（数据口，跨排对接）-------------------------
# 转接板 J3 丝印：1=D6 2=D4 3=D2 4=D0 | 7=D7 8=D5 9=D3 10=D1（5/11=GND、6/12=3V3）
# 跨排 => 转接板 1-4 落在板 pad 7-10；转接板 7-10 落在板 pad 1-4
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {cam_data[6]}] ;# 转接板J3-1  D6 <- 板pad7  (JB3P)
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {cam_data[4]}] ;# 转接板J3-2  D4 <- 板pad8  (JB3N)
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {cam_data[2]}] ;# 转接板J3-3  D2 <- 板pad9  (JB4P)
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {cam_data[0]}] ;# 转接板J3-4  D0 <- 板pad10 (JB4N)
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {cam_data[7]}] ;# 转接板J3-7  D7 <- 板pad1  (JB1P)
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports {cam_data[5]}] ;# 转接板J3-8  D5 <- 板pad2  (JB1N)
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {cam_data[3]}] ;# 转接板J3-9  D3 <- 板pad3  (JB2P)
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {cam_data[1]}] ;# 转接板J3-10 D1 <- 板pad4  (JB2N)

# SCCB 需要上拉
set_property PULLUP true [get_ports {emio_sccb_tri_io[0]}]
set_property PULLUP true [get_ports {emio_sccb_tri_io[1]}]

#------------------------- 摄像头输入延时（清 TIMING-18）-------------------------
# 值按 OV5640 DVP"PCLK 边沿后约 5ns 数据有效"的工程估值，非数据手册取值；
# PCLK 周期 13.888ns，所以 -min 1.0 / -max 5.5 给采样留足窗口。后续可用 ILA 校准。
set_input_delay -clock cam_pclk -max 5.5 [get_ports {cam_data[*] cam_vsync cam_href}]
set_input_delay -clock cam_pclk -min 1.0 [get_ports {cam_data[*] cam_vsync cam_href}]

#------------------------- HDMI TX（PYNQ-Z2 直出 TMDS）-------------------------
set_property -dict {PACKAGE_PIN L17 IOSTANDARD TMDS_33} [get_ports TMDS_tmds_clk_n]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD TMDS_33} [get_ports TMDS_tmds_clk_p]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_n[0]}]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_n[1]}]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_n[2]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_p[2]}]

#------------------------- 摄像头引脚：2026-09-19 采集通路接回，false_path 取消 -------------------------
# 采集 IP `ov5640_capture_data_0` 已加回 BD（替掉内部彩条源 patgen_0），cam_* 现在真的按
# cam_pclk 域采样、并送进 v_vid_in_axi4s，所以原来那两行 set_false_path（彩条源时代加的）
# 必须删掉 —— 这正是当时注释里写下的做法（"接回采集 IP 时把这两行删掉"）。
# 上面的 set_input_delay（-max 5.5 / -min 1.0）现在是真实约束，保留不动。
# ★ 本文件里所有 PACKAGE_PIN 一行都没有改动（跨排修正后的引脚保持原样）。

#------------------------- 舵机 PWM 输出（2026-10-26 新增）-------------------------
# 三路 SG90 信号接 Arduino 排针 A0/A1/A2（不用 Pmod，PmodA/PmodB 已被摄像头占满）
#   ★ 舵机电源必须来自**外部 5V 独立电源**，这里只出信号；
#     外部电源负极要引一根细线到板子 GND 共地（否则舵机乱跳或不动）
#   ★ 三个脚都不是复用脚（不在 PmodA / RPi 前 6 位那批共享球号里）
set_property -dict {PACKAGE_PIN Y11 IOSTANDARD LVCMOS33} [get_ports {servo_pwm_o[0]}]   ;# A0 -> 舵机1（can）
set_property -dict {PACKAGE_PIN Y12 IOSTANDARD LVCMOS33} [get_ports {servo_pwm_o[1]}]   ;# A1 -> 舵机2（plastic_bottle）
set_property -dict {PACKAGE_PIN W11 IOSTANDARD LVCMOS33} [get_ports {servo_pwm_o[2]}]   ;# A2 -> 舵机3（cardboard）
