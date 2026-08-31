# -----------------------------------------------------------------------------
# Runs the self-checking testbenches under Icarus Verilog.
#
#   make          - run every testbench, stop at the first failure
#   make TB=tb_uart_rx  - run just one
#   make clean    - remove compiled .vvp outputs
#
# Requires: iverilog + vvp (Icarus Verilog) on PATH.
# -----------------------------------------------------------------------------

RTL_DIR := ../rtl
BUILD_DIR := build

RTL_SRCS := $(RTL_DIR)/baud_rate_gen.sv $(RTL_DIR)/uart_tx.sv $(RTL_DIR)/uart_rx.sv $(RTL_DIR)/uart_top.sv

TESTBENCHES := tb_baud_rate_gen tb_uart_tx tb_uart_rx tb_uart_top

IVFLAGS := -g2012

.PHONY: all clean $(TESTBENCHES)

all: $(TESTBENCHES)

$(TESTBENCHES): %: $(BUILD_DIR)/%.vvp
	vvp $<

$(BUILD_DIR)/%.vvp: %.sv $(RTL_SRCS) | $(BUILD_DIR)
	iverilog $(IVFLAGS) -o $@ $(RTL_SRCS) $<

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
