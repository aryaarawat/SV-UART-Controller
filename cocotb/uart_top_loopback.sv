// -----------------------------------------------------------------------------
// File        : uart_top_loopback.sv
// Description : Thin wrapper that instantiates uart_top with tx_o wired
//               straight back to rx_i (self-loopback), so the cocotb test
//               has a single flat toplevel with only the register-style
//               interface exposed -- no serial-line ports to juggle from
//               Python. Uses uart_top's default parameters (no parity,
//               1 stop bit, 50 MHz / 115200 baud, 16x oversample), except
//               TX/RX FIFO depth: those default small here (rather than
//               uart_top's own default of 16) purely so the cocotb
//               FIFO-boundary tests don't need to burst dozens of bytes to
//               reach "full".
//
//               This exists only for the cocotb harness; it isn't part of
//               the synthesizable design (tb/tb_uart_top.sv does the same
//               loopback wiring directly in its SystemVerilog testbench).
// -----------------------------------------------------------------------------

module uart_top_loopback #(
    parameter int TX_FIFO_DEPTH = 4,
    parameter int RX_FIFO_DEPTH = 4
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [7:0] tx_wdata_i,
    input  logic       tx_wr_en_i,
    output logic       tx_ready_o,
    output logic       tx_full_o,
    output logic       tx_busy_o,

    output logic [7:0] rx_rdata_o,
    output logic       rx_valid_o,
    input  logic       rx_rd_en_i,
    output logic       rx_empty_o,
    output logic       rx_full_o,
    output logic       rx_busy_o,
    output logic       rx_overrun_o,
    output logic       rx_framing_err_o,
    output logic       rx_parity_err_o
);

    logic serial_line; // tx_o looped back to rx_i

    uart_top #(
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
    ) dut (
        .clk_i (clk_i),
        .rst_ni(rst_ni),

        .tx_o(serial_line),
        .rx_i(serial_line),

        .tx_wdata_i(tx_wdata_i),
        .tx_wr_en_i(tx_wr_en_i),
        .tx_ready_o(tx_ready_o),
        .tx_full_o (tx_full_o),
        .tx_busy_o (tx_busy_o),

        .rx_rdata_o      (rx_rdata_o),
        .rx_valid_o      (rx_valid_o),
        .rx_rd_en_i      (rx_rd_en_i),
        .rx_empty_o      (rx_empty_o),
        .rx_full_o       (rx_full_o),
        .rx_busy_o       (rx_busy_o),
        .rx_overrun_o    (rx_overrun_o),
        .rx_framing_err_o(rx_framing_err_o),
        .rx_parity_err_o (rx_parity_err_o)
    );

endmodule
