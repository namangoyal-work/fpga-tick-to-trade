# program.tcl — load build/fpga_top.bit onto an attached Arty A7 over JTAG.
#
# Volatile: takes effect immediately and is lost on power cycle (SRAM config).
# Run from the repo root, on the machine the board is plugged into:
#   vivado -mode batch -source synth/program.tcl
#
# For a persistent load (survives power cycle), flash the SPI instead — see
# the write_cfgmem block at the bottom, commented out.

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE [pwd]/build/fpga_top.bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "==== programmed [get_property PART $dev] with build/fpga_top.bit ===="
puts "==== led\[3\] should now blink ~1.5 Hz; led\[0\]/led\[1\] ~3/s ===="

close_hw_target
disconnect_hw_server
close_hw_manager

# --- persistent (SPI flash) alternative -------------------------------------
# The Arty A7 boots from an s25fl128s (128 Mbit) SPI flash. To survive power
# cycles, generate an .mcs and program the flash instead of the SRAM:
#
#   write_cfgmem -format mcs -interface spix4 -size 16 \
#       -loadbit "up 0x0 build/fpga_top.bit" -force build/fpga_top.mcs
#   # then in the hw_manager: create_hw_cfgmem, program_hw_cfgmem targeting
#   # the s25fl128sxxxxxx0-spi-x1_x2_x4 part. (Easiest done once in the GUI.)

