# char.tcl — characterize the reusable core (tick2trade_top), out of context.
#
# Out-of-context synthesis inserts no I/O buffers, so this measures the logic,
# not the pads — the right way to characterize a core with no fixed board.
# The 4 ns clock is a probe, not a target: read WNS from the report and
# compute Fmax = 1 / (4 ns - WNS).
#
# Run from the repo root:
#   vivado -mode batch -source synth/char.tcl
#
# Part defaults to the Arty A7-100T; override for other devices:
#   ARTY_PART=xc7a35ticsg324-1L vivado -mode batch -source synth/char.tcl

set part [expr {[info exists ::env(ARTY_PART)] ? $::env(ARTY_PART) : "xc7a100tcsg324-1"}]

file mkdir build

# core files only: the board wrapper (fpga_top, uart_tx) is excluded on purpose
read_verilog -sv {
    rtl/axis_skid.sv
    rtl/eth_parser.sv
    rtl/ipv4_parser.sv
    rtl/udp_parser.sv
    rtl/md_parser.sv
    rtl/trade_trigger.sv
    rtl/sync_fifo.sv
    rtl/decision_emitter.sv
    rtl/tick2trade_top.sv
}

synth_design -top tick2trade_top -part $part -mode out_of_context
create_clock -name clk -period 4.000 [get_ports clk]

report_timing_summary -file build/char_timing.rpt
report_utilization    -file build/char_utilization.rpt

puts "==== characterization done: see build/char_timing.rpt (WNS -> Fmax) ===="
