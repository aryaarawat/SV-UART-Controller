# -----------------------------------------------------------------------------
# Runs the cocotb testbench (test_uart_top.py) against uart_top_loopback,
# using Icarus Verilog as the simulator.
#
#   pip install -r requirements.txt   (ideally inside a venv)
#   make
#
# Requires: iverilog + vvp (Icarus Verilog) on PATH.
# -----------------------------------------------------------------------------

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

RTL_DIR := $(CURDIR)/../rtl

VERILOG_SOURCES += $(RTL_DIR)/fifo.sv
VERILOG_SOURCES += $(RTL_DIR)/baud_rate_gen.sv
VERILOG_SOURCES += $(RTL_DIR)/uart_tx.sv
VERILOG_SOURCES += $(RTL_DIR)/uart_rx.sv
VERILOG_SOURCES += $(RTL_DIR)/uart_top.sv
VERILOG_SOURCES += $(CURDIR)/uart_top_loopback.sv

TOPLEVEL = uart_top_loopback
MODULE = test_uart_top

COMPILE_ARGS += -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
