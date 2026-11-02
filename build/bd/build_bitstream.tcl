# =============================================================================
# build_bitstream.tcl —— 在 create_project.tcl 建好的工程上，综合布线并出位流
#
# 用法：
#     set OBJRS_PROJ_DIR=D:\objrs_build
#     vivado.bat -mode batch -notrace -nojournal -log build.log ^
#         -source <本包>\build\bd\build_bitstream.tcl
#
# 环境变量（都可省略）：
#     OBJRS_PROJ_DIR  工程目录，必须与 create_project.tcl 用的那个一致
#     OBJRS_OUT       产物输出目录，默认 <工程目录>/_bit
#     OBJRS_JOBS      并行 jobs，默认 1
#
# ★ 必须走 run 流程（launch_runs），不能用内存流程（直接 synth_design）。
#   原因：BD 里的每个 IP 都要先各自做一次 out-of-context 综合、产出 .dcp，
#   BD 生成的 design_1.v 才找得到 design_1_<ip>_0_0 这些模块。直接在内存里跑
#   synth_design 会报：
#       ERROR: [Synth 8-439] module 'design_1_DVI_Transmitter_0_0' not found
#   launch_runs 会自动把这些 IP 的 OOC 综合先行跑完。
#
# ★ 不要并行多个 run：本机 16 GB 内存下 -jobs > 1 会 OOM；也不要
#   `set_param general.maxThreads 8`，会让综合卡死在 Tech Mapping。
#
# ★ 出完位流必须跑 build/deliver.py 给 .hwh 打 FCLK0 分频补丁，否则屏幕全黑。
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
set pkg_root   [file normalize [file join $script_dir .. ..]]

set proj_dir [file join $pkg_root _build project]
if {[info exists ::env(OBJRS_PROJ_DIR)] && $::env(OBJRS_PROJ_DIR) ne ""} {
    set proj_dir [file normalize $::env(OBJRS_PROJ_DIR)]
}
set out_dir [file join $proj_dir _bit]
if {[info exists ::env(OBJRS_OUT)] && $::env(OBJRS_OUT) ne ""} {
    set out_dir [file normalize $::env(OBJRS_OUT)]
}
set jobs 1
if {[info exists ::env(OBJRS_JOBS)] && $::env(OBJRS_JOBS) ne ""} { set jobs $::env(OBJRS_JOBS) }

set xpr [file join $proj_dir objrs.xpr]
if {![file exists $xpr]} { error "找不到工程：$xpr —— 请先跑 create_project.tcl" }
file mkdir $out_dir

puts "== 打开工程：$xpr"
open_project $xpr
set part_name [get_property PART [current_project]]
puts "== 器件：$part_name"
set top_name [get_property top [current_fileset]]
puts "== 顶层：$top_name"
if {$top_name ne "design_1_wrapper"} {
    error "工程顶层不是 design_1_wrapper（实际是 '$top_name'），请先跑 create_project.tcl"
}
puts "== 产物目录：$out_dir"
puts "== 并行 jobs：$jobs"

# --- 1. 综合 run -----------------------------------------------------------
if {[llength [get_runs -quiet synth_1]] == 0} {
    if {[catch {create_run synth_1 -part $part_name} err]} {
        puts "!! create_run synth_1 失败：$err"
        if {![catch {get_flows} fl]} {
            puts "   本机可用的 flow（供手工指定 -flow）："
            foreach f $fl { if {![catch {get_property NAME $f} nm]} { puts "     $nm" } }
        }
        error "无法创建综合 run"
    }
    puts "== 已创建 synth_1"
} else {
    puts "== 复用已存在的 synth_1"
}

puts "== launch_runs synth_1（会先把 BD 里所有 IP 各做一次 OOC 综合）"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set prg [get_property PROGRESS [get_runs synth_1]]
puts "== synth_1 PROGRESS = $prg"
if {$prg ne "100%"} { error "综合未完成（PROGRESS=$prg）" }

# --- 2. 实现 run -----------------------------------------------------------
if {[llength [get_runs -quiet impl_1]] == 0} {
    create_run impl_1 -parent_run synth_1 -part $part_name
    puts "== 已创建 impl_1"
} else {
    puts "== 复用已存在的 impl_1"
}

puts "== launch_runs impl_1 -to_step write_bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set prg2 [get_property PROGRESS [get_runs impl_1]]
puts "== impl_1 PROGRESS = $prg2"
if {$prg2 ne "100%"} { error "实现未完成（PROGRESS=$prg2）" }

# --- 3. 出报告 + 拷位流 ----------------------------------------------------
open_run impl_1
report_utilization    -file [file join $out_dir util_impl.rpt]
report_timing_summary -file [file join $out_dir timing_impl.rpt]
report_drc            -file [file join $out_dir drc.rpt]
report_methodology    -file [file join $out_dir methodology.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

set src_bit [file join $proj_dir objrs.runs impl_1 design_1_wrapper.bit]
if {![file exists $src_bit]} { error "没找到位流：$src_bit" }
set dst_bit [file join $out_dir design_1_wrapper.bit]
file copy -force $src_bit $dst_bit

puts "---------------------------------------------"
puts "  WNS = $wns ns"
puts "  WHS = $whs ns"
puts "  位流 = $dst_bit"
puts "  大小 = [file size $dst_bit] 字节"
puts "  报告目录 = $out_dir"
puts "---------------------------------------------"
puts "下一步：python [file join $pkg_root build deliver.py]   ;# 给 .hwh 打 FCLK0 补丁"

close_project
puts "== 完成"
