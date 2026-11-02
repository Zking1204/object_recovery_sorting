###########################################################################
# 历史快照，不要用于构建。
# 实际 build 使用的引脚约束是本目录上级的 top.xdc（源自工程 constrs_1\new\top.xdc，2026-10-26）。
# 本文件是 2026-09-17 的手写旧版，端口命名已过时（cam_rst_n/cam_pwdn/cam_data[]，SCCB 走引脚），仅作沿革留档。
###########################################################################
##########################################################################
# top.xdc  --  PYNQ-Z2  +  wuxx PMOD-CAMERA v1.0  +  HDMI (direct TMDS)
#
# Ported onto the ov5640_hdmi_fd block design.
#
# 摄像头 16 信号铺满 PmodA + PmodB：
#   PmodA(8): rst pwd data[0..5]
#   PmodB(8): data[6] data[7] pclk vsync href xclk scl sda
#
# Pmod 上没有专用时钟引脚，所以 cam_pclk 要放开时钟布线限制。
# XCLK 由 FPGA 供给：24MHz XCLK -> OV5640 内部 x3 -> 72MHz PCLK。
##########################################################################

#------------------------- 摄像头接口时钟 -------------------------
create_clock -period 13.888 -name cam_pclk [get_ports cam_pclk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets cam_pclk_IBUF]

# FPGA 送给摄像头的 24MHz（clk_wiz 产生），声明成输出时钟
create_clock -period 41.667 -name cam_xclk [get_ports cam_xclk]

#------------------------- 摄像头：PmodA -------------------------
#                   模块丝印      PYNQ-Z2 引脚
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports cam_rst_n]          ;# D2  ja_p[1]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {cam_data[1]}]      ;# C2  ja_n[1]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {cam_data[3]}]      ;# B2  ja_p[2]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {cam_data[5]}]      ;# A2  ja_n[2]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports cam_pwdn]           ;# H2  ja_p[3]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {cam_data[0]}]      ;# G2  ja_n[3]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {cam_data[2]}]      ;# F2  ja_p[4]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {cam_data[4]}]      ;# E2  ja_n[4]

#------------------------- 摄像头：PmodB -------------------------
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {cam_data[7]}]      ;# D1  jb_p[1]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports cam_pclk]           ;# C1  jb_n[1]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports cam_vsync]          ;# B1  jb_p[2]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {emio_sccb_tri_io[0]}] ;# A1 jb_n[2]  SCL
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {cam_data[6]}]      ;# H1  jb_p[3]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports cam_xclk]           ;# G1  jb_n[3]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports cam_href]           ;# F1  jb_p[4]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {emio_sccb_tri_io[1]}] ;# E1 jb_n[4]  SDA

# SCCB 需要上拉（回到 Pmod 的 3.3V）
set_property PULLUP true [get_ports {emio_sccb_tri_io[0]}]
set_property PULLUP true [get_ports {emio_sccb_tri_io[1]}]

#------------------------- HDMI TX（PYNQ-Z2 直出 TMDS）-------------------------
set_property -dict {PACKAGE_PIN L17 IOSTANDARD TMDS_33} [get_ports TMDS_tmds_clk_n]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD TMDS_33} [get_ports TMDS_tmds_clk_p]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_n[0]}]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_p[0]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_n[1]}]
set_property -dict {PACKAGE_PIN K19 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_p[1]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_n[2]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD TMDS_33} [get_ports {TMDS_tmds_data_p[2]}]
