# ============================================================================
#  ooc_syn.tcl -- out-of-context synthesis of the HLS-generated CNN kernel
#
#  Purpose: the `Slack` column in the Vitis HLS report is a *scheduling*
#  estimate that does NOT include place-and-route.  This script synthesises the
#  exact RTL that HLS produced, against the real xc7z020 speed grade, so we get
#  a trustworthy WNS for the 100 MHz clock.
#
#  It touches nothing in the main project: no block design, no synth_1/impl_1,
#  no bitstream.  Everything lands in D:/AMD/PROJECT/hls_cnn/_ooc.
#
#  Usage:
#    vivado -mode batch -source ooc_syn.tcl
# ============================================================================

set RTL_DIR  "D:/AMD/PROJECT/hls_cnn/work/hls/syn/verilog"
set OUT_DIR  "D:/AMD/PROJECT/hls_cnn/_ooc"
set PART     "xc7z020clg400-1"
set PERIOD   10.000

file mkdir $OUT_DIR

# ---- clock constraint, written out so synth_design can consume it ----------
set xdc "$OUT_DIR/cnn_top.xdc"
set fh [open $xdc w]
puts $fh "# 100 MHz PL clock"
puts $fh "create_clock -name ap_clk -period $PERIOD \[get_ports ap_clk\]"
close $fh

# ---- read the generated RTL ------------------------------------------------
set files [glob -nocomplain $RTL_DIR/*.v]
puts "INFO: reading [llength $files] generated verilog files"
read_verilog $files

# read_xdc queues the constraints; in non-project mode they are applied while
# synth_design elaborates the design (get_ports needs that to exist first).
read_xdc $xdc

# ---- synthesise (out of context: no I/O delays, pure logic timing) ---------
synth_design -top cnn_top -part $PART -mode out_of_context

# ---- reports ---------------------------------------------------------------
report_utilization    -file "$OUT_DIR/util.rpt"
report_timing_summary -file "$OUT_DIR/timing.rpt" -max_paths 20
write_checkpoint -force "$OUT_DIR/cnn_top_ooc.dcp"

puts "=============================================================="
puts "OOC synthesis finished.  Reports in $OUT_DIR"
puts "=============================================================="
