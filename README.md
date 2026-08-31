# SV-UART-Controller

A configurable UART controller in SystemVerilog: baud-rate generator, TX and
RX FSMs, and a register-style top-level integration suitable for driving
from a CPU/APB/AXI-lite adapter.

## RTL

| File | Description |
| --- | --- |
| `rtl/baud_rate_gen.sv` | Clock divider producing 16x-oversample and 1x baud tick strobes |
| `rtl/uart_tx.sv` | Transmit FSM: parallel-to-serial, start/data/parity/stop framing |
| `rtl/uart_rx.sv` | Receive FSM: oversampling synchronizer + serial-to-parallel deframing |
| `rtl/uart_top.sv` | Integrates the above behind a ready/valid TX register and a sticky-valid RX register |

Parameters (set on `uart_top`, propagated down): `CLK_FREQ_HZ`, `BAUD_RATE`,
`DATA_BITS`, `PARITY_EN`, `PARITY_ODD`, `STOP_BITS`, `OVERSAMPLE`.

## Testbenches

Self-checking SystemVerilog testbenches live in `tb/`, one per RTL module
plus a full-stack loopback integration test:

| Testbench | Covers |
| --- | --- |
| `tb/tb_baud_rate_gen.sv` | tick_x16/tick_x1 period and phase relationship, `en_i` gating |
| `tb/tb_uart_tx.sv` | Serial framing across parity/stop-bit configurations, back-to-back sends |
| `tb/tb_uart_rx.sv` | Deframing, framing/parity error injection, start-bit glitch rejection |
| `tb/tb_uart_top.sv` | Self-loopback round trips, streaming data integrity, RX overrun handling |

Each testbench prints `PASS`/`FAIL` and exits non-zero on failure (via
`$fatal`), so they're CI-friendly as-is.

### Running

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog` + `vvp`
on `PATH`).

```sh
cd tb
make            # run every testbench
make tb_uart_rx # run just one
make clean      # remove build/ output
```
