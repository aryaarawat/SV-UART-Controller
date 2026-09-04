# -----------------------------------------------------------------------------
# Runs the Yosys synthesis sanity check.
#
#   make        - run the check
#   make clean  - remove nothing (no build output; kept for consistency
#                 with tb/ and cocotb/'s Makefiles)
#
# Requires: yosys on PATH.
# -----------------------------------------------------------------------------

.PHONY: all clean

all:
	yosys -s synth_check.ys

clean:
