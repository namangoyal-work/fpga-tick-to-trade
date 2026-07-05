# build_bitstream.tcl — full flow for the Arty A7 board demo (fpga_top).
#
# Run from the repo root:
#   vivado -mode batch -source synth/build_bitstream.tcl
# Program build/fpga_top.bit onto the board (Hardware Manager or openFPGALoader).
#
# Part defaults to the Arty A7-100T; for the A7-35T:
#   ARTY_PART=xc7a35ticsg324-1L vivado -mode batch -source synth/build_bitstream.tcl

set part [expr {[info exists ::env(ARTY_PART)] ? $::env(ARTY_PART) : "xc7a100tcsg324-1"}]

file mkdir build

read_verilog -sv [glob rtl/*.sv]
read_xdc synth/arty_a7.xdc

synth_design -top fpga_top -part $part -include_dirs rtl
opt_design
place_design
route_design

report_timing_summary -file build/timing_summary.rpt
report_utilization    -file build/utilization.rpt

write_bitstream -force build/fpga_top.bit
puts "==== bitstream written: build/fpga_top.bit ===="
