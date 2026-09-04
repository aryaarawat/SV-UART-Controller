# SV-UART-Controller

A configurable UART controller in SystemVerilog: baud-rate generator, TX and
RX FSMs, and a register-style top-level integration suitable for driving
from a CPU/APB/AXI-lite adapter.

## Architecture

```mermaid
---
config:
  theme: forest
---
block-beta
  columns 7

  clk["clk_i"] space rst["rst_ni"] space en["en_i"] space space
  space baud["baud_rate_gen"] space space space status["TX/RX status"] space
  space tick16["tick_x16_o"] space tick1["tick_x1_o"] space space space

  block:uart_top:5
    columns 5

    cpu["CPU / host\ninterface"] space txfifo["TX FIFO"] space tx["uart_tx\nSerializer"]
    space space space space space
    rx["uart_rx\nSync + sampler"] space rxfifo["RX FIFO"] space space
  end

  txline["tx_o"] space wire["UART wire /\nloopback"] space rxin["rx_i"] space space

  clk --> baud
  rst --> baud
  en --> baud
  baud --> tick16
  baud --> tick1

  cpu -- "tx_wdata_i, tx_wr_en_i" --> txfifo
  txfifo --> tx
  tick1 --> tx
  tx --> txline
  txline --> wire
  wire --> rxin
  rxin --> rx
  tick16 --> rx
  rx --> rxfifo
  cpu -- "rx_rd_en_i" --> rxfifo
  tx -- "tx_ready_o, tx_full_o" --> status

  classDef clock fill:#eef2ff,stroke:#818cf8,color:#1e1b4b
  classDef timing fill:#ecfeff,stroke:#22d3ee,color:#164e63
  classDef uart fill:#f0fdfa,stroke:#2dd4bf,color:#134e4a
  classDef fifo fill:#f7fee7,stroke:#a3e635,color:#365314
  classDef interface fill:#fff7ed,stroke:#fb923c,color:#7c2d12
  classDef transport fill:#ecfeff,stroke:#22d3ee,color:#164e63
  classDef status fill:#fdf4ff,stroke:#e879f9,color:#701a75

  class clk,rst,en clock
  class baud,tick16,tick1 timing
  class tx,rx uart
  class txfifo,rxfifo fifo
  class cpu interface
  class txline,wire,rxin transport
  class status status
```

## RTL

| File | Description |
| --- | --- |
| `rtl/baud_rate_gen.sv` | Clock divider producing 16x-oversample and 1x baud tick strobes |
| `rtl/uart_tx.sv` | Transmit FSM: parallel-to-serial, start/data/parity/stop framing |
| `rtl/uart_rx.sv` | Receive FSM: oversampling synchronizer + serial-to-parallel deframing |
| `rtl/fifo.sv` | Generic synchronous FIFO (circular buffer + fill-level counter) |
| `rtl/uart_top.sv` | Integrates the above behind TX/RX FIFOs and a CPU-friendly register interface |
| `rtl/uart_apb.sv` | AMBA APB4 slave wrapper around `uart_top` -- a 3-register memory-mapped interface |

Parameters (set on `uart_top`, propagated down): `CLK_FREQ_HZ`, `BAUD_RATE`,
`DATA_BITS`, `PARITY_EN`, `PARITY_ODD`, `STOP_BITS`, `OVERSAMPLE`,
`TX_FIFO_DEPTH`, `RX_FIFO_DEPTH` (each FIFO defaults to 16 entries).

TX: write `tx_wdata_i` with `tx_wr_en_i` pulsed whenever `tx_ready_o` (TX
FIFO not full) is high; queued bytes drain into the line automatically.
RX: `rx_rdata_o` + `rx_valid_o` (RX FIFO not empty) behave like an RXDATA
register + status bit; each `rx_rd_en_i` pulse pops the oldest queued byte,
along with its own `rx_framing_err_o`/`rx_parity_err_o`. `rx_overrun_o` is
sticky and flags a byte that arrived while the RX FIFO was completely full
(and was therefore dropped).

### APB wrapper

`uart_apb` puts `uart_top` behind an AMBA APB4 slave port (`psel_i`,
`penable_i`, `pwrite_i`, `paddr_i`, `pwdata_i`, `prdata_o`, `pready_o`,
`pslverr_o`) -- `paddr_i` is just the offset within this peripheral's own
space; a system-level address decoder is assumed to produce `psel_i` from
the upper address bits. It never inserts wait states (`pready_o` is tied
high), and reports `pslverr_o` -- the transfer still completes; APB has no
way to stall or retry a response -- for a handful of real mistakes a host
could make: writing `TXDATA` while the TX FIFO is full (the byte is
dropped, same as it would be through the raw `uart_top` port), reading
`RXDATA` while the RX FIFO is empty, writing a read-only register, or
accessing an unmapped offset.

| Offset | Register | Access | Description |
| --- | --- | --- | --- |
| `0x0` | `TXDATA` | W | `PWDATA[DATA_BITS-1:0]`: write a byte into the TX FIFO |
| `0x4` | `RXDATA` | R | `PRDATA[DATA_BITS-1:0]`: pop and return the oldest queued RX byte |
| `0x8` | `STATUS` | R | packed status bits, see below |

`STATUS` bit layout:

| Bit | Signal | Bit | Signal |
| --- | --- | --- | --- |
| 0 | `tx_ready_o` | 5 | `rx_full_o` |
| 1 | `tx_full_o` | 6 | `rx_busy_o` |
| 2 | `tx_busy_o` | 7 | `rx_overrun_o` |
| 3 | `rx_valid_o` | 8 | `rx_framing_err_o` |
| 4 | `rx_empty_o` | 9 | `rx_parity_err_o` |

`[31:10]` reserved, read as 0.

## Testbenches

Self-checking SystemVerilog testbenches live in `tb/`, one per RTL module
plus a full-stack loopback integration test:

| Testbench | Covers |
| --- | --- |
| `tb/tb_fifo.sv` | Fill/drain/overflow/underflow, simultaneous push+pop, randomized stress vs. a queue model |
| `tb/tb_baud_rate_gen.sv` | tick_x16/tick_x1 period and phase relationship, `en_i` gating |
| `tb/tb_uart_tx.sv` | Serial framing across parity/stop-bit configurations, back-to-back sends |
| `tb/tb_uart_rx.sv` | Deframing, framing/parity error injection, start-bit glitch rejection |
| `tb/tb_uart_top.sv` | Self-loopback round trips, streaming, TX FIFO fill, RX FIFO fill + overrun |
| `tb/tb_uart_apb.sv` | Drives the real APB4 SETUP/ACCESS handshake; register map, round trip, all `pslverr_o` cases |

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

## cocotb

A second, independent testbench for `uart_top` lives in `cocotb/`, written in
Python against [cocotb](https://www.cocotb.org/) instead of SystemVerilog.
It drives `uart_top` through a thin loopback wrapper
(`cocotb/uart_top_loopback.sv`) and covers the same scenarios as
`tb/tb_uart_top.sv`: reset state, single-byte round trips, back-to-back
streaming with a scoreboard, TX FIFO fill, and RX FIFO fill + overrun.

### Running

Requires Icarus Verilog (as above) plus Python 3.9+.

```sh
cd cocotb
python3 -m venv .venv && source .venv/bin/activate  # optional but recommended
pip install -r requirements.txt
make
```

## Synthesis check

`synth/synth_check.ys` runs the design through Yosys's generic `synth` flow
(no target cell library) as a sanity check -- proves it's synthesizable at
all, with no inferred latches and no dangling-wire/multiple-driver/
combinational-loop problems (`check -assert`). Checked as two separate
tops, `uart_top` and `uart_apb`. It's not a target-specific (FPGA/ASIC)
flow, and it's a supplement to simulation, not a replacement -- this only
proves the design synthesizes cleanly, not that it behaves correctly.

### Running

Requires [Yosys](https://yosyshq.net/yosys/).

```sh
cd synth
make
```
