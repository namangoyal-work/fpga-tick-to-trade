# Per-module cocotb benches. Usage:
#   make DUT=axis_skid
#   make DUT=tick2trade_top COCOTB_TEST_MODULES=test_fuzz
#   make regress    # every bench in sequence
#
# The aggregate target is "regress", not "all": cocotb's included Makefile.sim
# already defines "all" as its default target, and overriding it makes every
# sub-make recurse into the override instead of running the simulation.
#
# Each DUT gets its own build directory: make's staleness check compares
# timestamps only and does not know the DUT variable changed, so a shared
# build directory can rerun the wrong module's compiled simulation.

DUT ?= axis_skid

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(wildcard $(PWD)/../rtl/*.sv)
COMPILE_ARGS += -g2012 -I$(PWD)/../rtl

COCOTB_TOPLEVEL = $(DUT)
COCOTB_TEST_MODULES ?= test_$(DUT)
SIM_BUILD = sim_build_$(DUT)

include $(shell cocotb-config --makefiles)/Makefile.sim

DUTS = axis_skid sync_fifo eth_parser ipv4_parser udp_parser md_parser \
       decision_emitter tick2trade_top

.PHONY: regress fuzz
regress:
	@for d in $(DUTS); do \
	  $(MAKE) --no-print-directory DUT=$$d sim || exit 1; \
	done
	$(MAKE) --no-print-directory DUT=tick2trade_top COCOTB_TEST_MODULES=test_fuzz sim

fuzz:
	$(MAKE) --no-print-directory DUT=tick2trade_top COCOTB_TEST_MODULES=test_fuzz sim
