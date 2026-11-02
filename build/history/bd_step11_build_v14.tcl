# ============================================================================
#  bd_step11_build_v14.tcl -- full build after the cnn_top 1.4 upgrade
#
#  No general.maxThreads: setting it to 8 was measured to hang synthesis in
#  Tech Mapping on this machine.  launch_runs stays at -jobs 1 because more
#  parallel runs OOM on 16 GB.
# ============================================================================
set OUT "D:/AMD/PROJECT/hls_cnn/_bd"
file mkdir $OUT

open_project D:/AMD/PROJECT/video_fd_pz2/ov5640_hdmi_fd.xpr

puts "########## RESET RUNS ##########"
foreach r [get_runs -quiet *synth*] { reset_run $r ; puts "  reset $r" }
reset_run impl_1 -quiet

puts "########## SYNTHESIS ##########"
launch_runs synth_1 -jobs 1
wait_on_run synth_1
puts "SYNTH = [get_property PROGRESS [get_runs synth_1]] / [get_property STATUS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "########## SYNTH FAILED ##########"
    close_project
    exit 1
}

puts "########## IMPLEMENTATION ##########"
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
puts "IMPL = [get_property PROGRESS [get_runs impl_1]] / [get_property STATUS [get_runs impl_1]]"
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "########## IMPL FAILED ##########"
    close_project
    exit 1
}

open_run impl_1
report_utilization     -file "$OUT/util_impl_v14.rpt"
report_timing_summary  -file "$OUT/timing_impl_v14.rpt"
puts "########## WNS = [get_property SLACK [get_timing_paths -delay_type max]] ns ##########"
close_design
close_project
puts "########## BUILD DONE ##########"
