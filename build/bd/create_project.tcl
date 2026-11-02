# =============================================================================
# create_project.tcl —— 从源码重建 Vivado 工程并恢复 block design
#
# 用法（Vivado 2026.1 的 Tcl Console，或 vivado -mode batch -source 本文件）：
#     source <本包>/build/bd/create_project.tcl
#
# 做的事：新建工程 → 注册 IP 仓库 → 加 RTL 与约束 → 放回 .bd/.bda 并打开
#         → 校验 → 生成 HDL wrapper → 设为顶层
#
# 重要：
#   * 必须配 Vivado/Vitis 2026.1（BD 里锁定了 axi_vdma:6.3 / v_tc:6.2 /
#     axis_broadcaster:1.1，换版本会触发 IP 自动升级，BD 不再等价）。
#   * .bd 与 .bda 必须成对拷贝：.bd 存的是与 IP 默认值不同的参数和连线，
#     .bda 存的是地址映射；丢了 .bda 所有 IP 的基地址会重排，PS 侧脚本全错。
#   * 脚本不改 BD、不改 RTL，只负责"把文件摆回原位"。
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
set pkg_root   [file normalize [file join $script_dir .. ..]]
set proj_dir   [file join $pkg_root _build project]
set part_name  xc7z020clg400-1

# 允许用环境变量把工程目录放到别处（做重建验证时用，避免在提交包里生成中间产物）
if {[info exists ::env(OBJRS_PROJ_DIR)] && $::env(OBJRS_PROJ_DIR) ne ""} {
    set proj_dir [file normalize $::env(OBJRS_PROJ_DIR)]
}

puts "== 包根目录：$pkg_root"
puts "== 工程目录：$proj_dir"

# --- 1. 新建工程 ---------------------------------------------------------
if {[file exists $proj_dir]} {
    puts "== 已存在的工程目录将被清空：$proj_dir"
    file delete -force $proj_dir
}
file mkdir $proj_dir
create_project objrs $proj_dir -part $part_name -force

# 恢复板卡定义。原工程用的是 PYNQ-Z2 板卡定义，它会写进 .hwh 的 <SYSTEMINFO BOARD=...>。
# 没装该板卡也能正常建工程，只影响 .hwh 里那个属性（PYNQ 的 Overlay 不读它）。
set board_name "tul.com.tw:pynq-z2:part0:1.0"
if {[llength [get_board_parts -quiet $board_name]] > 0} {
    set_property board_part $board_name [current_project]
    puts "== 已设置板卡定义：$board_name"
} else {
    puts "== 未安装板卡定义 $board_name，仅按器件 $part_name 建工程（不影响 PYNQ 上板）"
}

# --- 2. 注册 IP 仓库（相对路径，换机器才不会红）---------------------------
set ip_repo [file normalize [file join $pkg_root src ip_repo]]
if {![file isdirectory $ip_repo]} {
    error "找不到 IP 仓库：$ip_repo"
}
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog -rebuild
puts "== IP 仓库已注册：$ip_repo"

# 确认四个第三方 / 自研 IP 都能被识别
foreach vlnv {alientek.com:user:ov5640_capture_data:1.0 \
              openedv.com:user:DVI_Transmitter:1.0 \
              digilentinc.com:ip:axi_dynclk:1.0 \
              xilinx.com:hls:cnn_top:1.4} {
    if {[llength [get_ipdefs -all $vlnv]] == 0} {
        puts "!! 警告：IP 仓库里没找到 $vlnv —— BD 会对该单元报红"
        puts "CHECK ip_MISSING   = $vlnv"
    } else {
        puts "== 已找到 $vlnv"
        puts "CHECK ip_found     = $vlnv"
    }
}

# --- 3. 加入 RTL 与约束 --------------------------------------------------
set rtl_dir [file join $pkg_root src rtl]
set rtl_files [glob -nocomplain -directory $rtl_dir *.v *.sv]
if {[llength $rtl_files] == 0} { error "src/rtl 下没有源文件" }
add_files -norecurse -fileset sources_1 $rtl_files
puts "== 已加入 [llength $rtl_files] 个 RTL 源文件"

set xdc [file join $pkg_root build constraints top.xdc]
if {[file exists $xdc]} {
    add_files -norecurse -fileset constrs_1 $xdc
    puts "== 已加入约束：$xdc"
} else {
    error "找不到约束文件：$xdc"
}

# --- 4. 放回 block design 并打开 -----------------------------------------
set bd_dir [file join $proj_dir objrs.srcs sources_1 bd design_1]
file mkdir $bd_dir
foreach f {design_1.bd design_1.bda} {
    set s [file join $pkg_root build bd $f]
    if {![file exists $s]} { error "找不到 $s" }
    file copy -force $s [file join $bd_dir $f]
}
puts "== 已放回 design_1.bd / design_1.bda"

add_files -norecurse -fileset sources_1 [file join $bd_dir design_1.bd]
open_bd_design [file join $bd_dir design_1.bd]

# --- 5. 校验 BD ---------------------------------------------------------
set n_cells [llength [get_bd_cells]]
puts "== BD 单元数：$n_cells（应为 20）"

set n_addr [llength [get_bd_addr_segs -of_objects [get_bd_addr_spaces]]]
puts "== 地址段数：$n_addr"

set issues [validate_bd_design]
if {[llength $issues] > 0} {
    puts "!! validate_bd_design 报出 [llength $issues] 条问题："
    foreach i $issues { puts "   $i" }
} else {
    puts "== validate_bd_design 通过"
}

# 关键：确认两个分频参数（BD 里改不生效，真正的补丁在 .hwh 上做，见 build/deliver.py）
puts "== PS7 的 FCLK0 期望值：100 MHz（实际以 .hwh 补丁为准）"

save_bd_design

# --- 5b. 可选：生成 BD 输出产物（含各 IP 的 OOC 综合，耗时较长）----------
# 默认不执行。设 OBJRS_GENERATE=1 才跑。这一步会把"IP 源缺失 / VLNV 对不上"
# 这类问题暴露出来，是判断"包是否完整"的最强检查，但本身要花十几分钟。
if {[info exists ::env(OBJRS_GENERATE)] && $::env(OBJRS_GENERATE) eq "1"} {
    puts "== 开始生成 BD 输出产物（含 IP OOC 综合）..."
    generate_target all [get_files design_1.bd]
    puts "== 输出产物生成完成"
} else {
    puts "== 已跳过输出产物生成（如需执行：设环境变量 OBJRS_GENERATE=1）"
}

# --- 6. 生成 wrapper 并设为顶层 -----------------------------------------
make_wrapper -top -files [get_files design_1.bd] -import -force
set wrapper [get_files -quiet design_1_wrapper.v]
if {[llength $wrapper] == 0} { error "HDL wrapper 生成失败" }
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "== 顶层已设为 design_1_wrapper"

puts ""
puts "================ 工程重建完成 ================"
puts "下一步：python [file join $pkg_root build deliver.py]  ;# 给 .hwh 打 FCLK0 补丁，漏跑会黑屏"
puts "（要出位流先跑 build/bd/build_bitstream.tcl）"
puts "=============================================="

# -----------------------------------------------------------------------------
# ASCII 判据汇总 —— 给复现者 grep 用
#
# 为什么还要单独打这一组：Vivado 的 .log 里，Tcl 的 puts 输出是 UTF-8，而 Vivado
# 自己的消息是系统 ANSI(GBK)，同一个文件混了两种编码，单一编码读一定乱码，中文
# 判据根本 grep 不到。下面这些行全 ASCII，`findstr CHECK` 就能一次看全。
# -----------------------------------------------------------------------------
set validate_state [expr {[llength $issues] > 0 ? "ISSUES" : "PASS"}]
puts "================ ASCII CHECK SUMMARY ================"
puts "CHECK bd_cells     = $n_cells  (expect 20)"
puts "CHECK addr_segs    = $n_addr"
puts "CHECK validate     = $validate_state"
puts "CHECK top          = [get_property top [current_fileset]]"
puts "CHECK proj_dir     = [get_property DIRECTORY [current_project]]"
puts "CHECK part         = [get_property PART [current_project]]"
puts "CHECK REBUILD_DONE"
puts "====================================================="
