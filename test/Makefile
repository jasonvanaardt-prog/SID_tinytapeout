# SPDX-FileCopyrightText: 2026 Jason van Aardt
# SPDX-License-Identifier: CERN-OHL-S-2.0

SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = sid_voice.v sid_envelope.v sid_fc_curve.v sid_q_table.v \
                  sid_audio.v sid_dac.v sid_core.v project.v

ifneq ($(GATES),yes)

# RTL simulation
SIM_BUILD        = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate-level simulation of the hardened netlist
SIM_BUILD         = sim_build/gl
COMPILE_ARGS     += -DGL_TEST
COMPILE_ARGS     += -DFUNCTIONAL
COMPILE_ARGS     += -DUSE_POWER_PINS
COMPILE_ARGS     += -DSIM
COMPILE_ARGS     += -DUNIT_DELAY=\#1
VERILOG_SOURCES  += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES  += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
VERILOG_SOURCES  += $(PWD)/gate_level_netlist.v

endif

VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
MODULE   = test
PLUSARGS ?= +vcd

include $(shell cocotb-config --makefiles)/Makefile.sim

# Render a short demo to sid_demo.wav.  Much slower than the regression,
# so it runs without waveform dumping and at the minimum clk/phi2 ratio.
.PHONY: record
record:
	$(MAKE) MODULE=record PLUSARGS= SIM_BUILD=sim_build/record
