# ============================================================================
#  bd_step10_v14.tcl -- register cnn_top IP 1.4 and upgrade design_1's instance
#
#  Order matters (each step was learned the hard way):
#    - keep the 1.3 definition in the repo while opening the project, otherwise
#      the existing 1.3 cell has no definition to resolve against;
#    - update_ip_catalog -add_ip + -rebuild, then upgrade_ip on the IP INSTANCE
#      (design_1_cnn_top_0_3), not on the BD cell;
#    - only then generate_target all, otherwise "Block design contains locked IPs";
#    - the BD is only saved when validate_bd_design succeeds (self-check gate).
#  This script does NOT build: synthesis/implementation is a separate run.
# ============================================================================
set OUT "D:/AMD/PROJECT/hls_cnn/_bd"
file mkdir $OUT
set ZIP "D:/AMD/PROJECT/hls_cnn/work_v6/cnn_top.zip"
set REPO "D:/AMD/PROJECT/video_fd_pz2/ip_repo"

open_project D:/AMD/PROJECT/video_fd_pz2/ov5640_hdmi_fd.xpr

puts "########## REGISTER IP 1.4 ##########"
update_ip_catalog -add_ip $ZIP -repo_path $REPO
update_ip_catalog -rebuild
set defs [get_ipdefs -quiet xilinx.com:hls:cnn_top:*]
puts "IPDEFS: $defs"
if {[lsearch -glob $defs "xilinx.com:hls:cnn_top:1.4"] < 0} {
    puts "########## FAIL: 1.4 NOT REGISTERED ##########"
    close_project
    exit 1
}

puts "########## UPGRADE INSTANCE ##########"
set ipi [get_ips -quiet *cnn_top*]
puts "BEFORE: $ipi vlnv=[get_property IPDEF $ipi]"
upgrade_ip $ipi
puts "AFTER : [get_property IPDEF [get_ips -quiet *cnn_top*]]"

puts "########## OPEN BD ##########"
open_bd_design [get_files design_1.bd]
set cell [get_bd_cells cnn_top_0]
puts "CELL vlnv = [get_property VLNV $cell]"
if {[get_property VLNV $cell] ne "xilinx.com:hls:cnn_top:1.4"} {
    puts "########## FAIL: cell still not at 1.4 ##########"
    close_bd_design [current_bd_design]
    close_project
    exit 1
}
puts "  M_AXI data width = [get_property CONFIG.C_M_AXI_GMEM_DATA_WIDTH $cell]"

puts "########## GENERATE / VALIDATE ##########"
if {[catch { generate_target all [get_files design_1.bd] } e]} {
    puts "########## FAIL generate_target: $e ##########"
    close_bd_design [current_bd_design]
    close_project
    exit 1
}
if {[catch { validate_bd_design } e]} {
    puts "########## FAIL validate: $e  (BD NOT SAVED) ##########"
    close_bd_design [current_bd_design]
    close_project
    exit 1
}
save_bd_design
puts "########## BD SAVED ##########"

foreach seg [get_bd_addr_segs -quiet -of_objects $cell] {
    puts "  SEG [get_property OFFSET $seg] [get_property RANGE $seg] $seg"
}
close_bd_design [current_bd_design]
close_project
puts "########## BD STEP DONE ##########"
