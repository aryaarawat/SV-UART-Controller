// -----------------------------------------------------------------------------
// File        : uart_top.sv
// Description : Top-level UART controller. Integrates baud_rate_gen, uart_tx
//               and uart_rx behind a simple parallel register-style
//               interface, the kind a CPU (or an APB/AXI-lite adapter placed
//               in front of this module) would drive:
//
//                 TX side  - write tx_wdata_i with tx_wr_en_i pulsed high
//                            whenever tx_ready_o is high, same as writing a
//                            memory-mapped TXDATA register only when a
//                            "TX empty" status bit is set.
//                 RX side  - rx_rdata_o + rx_valid_o behave like an RXDATA
//                            register plus its RXNE ("receive not empty")
//                            status bit: rx_valid_o goes high and STAYS high
//                            (unlike uart_rx's raw 1-cycle rx_valid_o pulse)
//                            until the read is acknowledged with rx_rd_en_i,
//                            so a CPU polling occasionally can't miss a byte.
//                            rx_overrun_o flags a byte that arrived before
//                            the previous one was acknowledged (i.e. it
//                            overwrote rx_rdata_o before it was read); it is
//                            sticky and clears together with the read ack.
//
//               This holding-register + sticky-valid layer is the buffering
//               uart_rx deliberately leaves out (see its header comment) --
//               it belongs at the integration level, not inside the FSM.
// -----------------------------------------------------------------------------

module uart_top #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200,
    parameter int DATA_BITS   = 8,
    parameter bit PARITY_EN   = 1'b0,
    parameter bit PARITY_ODD  = 1'b0,
    parameter int STOP_BITS   = 1,
    parameter int OVERSAMPLE  = 16
) (
    input  logic clk_i,
    input  logic rst_ni, // active-low, synchronous reset

    // Serial line
    output logic tx_o,
    input  logic rx_i,

    // ---- TX register interface ----
    input  logic [DATA_BITS-1:0] tx_wdata_i,
    input  logic                 tx_wr_en_i, // pulse: accepted iff tx_ready_o is high this cycle
    output logic                 tx_ready_o, // holding reg empty, can accept a new byte
    output logic                 tx_busy_o,  // a frame is currently being shifted out

    // ---- RX register interface ----
    output logic [DATA_BITS-1:0] rx_rdata_o,       // last received byte, held until acknowledged
    output logic                 rx_valid_o,       // sticky "byte available" flag
    input  logic                 rx_rd_en_i,       // pulse: acknowledge/consume rx_rdata_o
    output logic                 rx_busy_o,        // mid-frame reception in progress
    output logic                 rx_overrun_o,     // sticky; previous byte wasn't read before being overwritten
    output logic                 rx_framing_err_o, // latched alongside rx_rdata_o
    output logic                 rx_parity_err_o   // latched alongside rx_rdata_o (always 0 if !PARITY_EN)
);

    logic tick_x16, tick_x1;

    baud_rate_gen #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE),
        .OVERSAMPLE  (OVERSAMPLE)
    ) u_baud_gen (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .en_i       (1'b1),
        .tick_x16_o (tick_x16),
        .tick_x1_o  (tick_x1)
    );

    uart_tx #(
        .DATA_BITS  (DATA_BITS),
        .PARITY_EN  (PARITY_EN),
        .PARITY_ODD (PARITY_ODD),
        .STOP_BITS  (STOP_BITS)
    ) u_tx (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .baud_tick_i (tick_x1),
        .tx_data_i   (tx_wdata_i),
        .tx_valid_i  (tx_wr_en_i),
        .tx_ready_o  (tx_ready_o),
        .tx_o        (tx_o),
        .tx_busy_o   (tx_busy_o)
    );

    // Raw, single-cycle-pulse outputs straight from the RX FSM -- captured
    // into the sticky holding register below.
    logic [DATA_BITS-1:0] rx_data_raw;
    logic                 rx_valid_raw;
    logic                 rx_framing_err_raw;
    logic                 rx_parity_err_raw;

    uart_rx #(
        .DATA_BITS  (DATA_BITS),
        .PARITY_EN  (PARITY_EN),
        .PARITY_ODD (PARITY_ODD),
        .STOP_BITS  (STOP_BITS),
        .OVERSAMPLE (OVERSAMPLE)
    ) u_rx (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .tick_x16_i    (tick_x16),
        .rx_i          (rx_i),
        .rx_data_o     (rx_data_raw),
        .rx_valid_o    (rx_valid_raw),
        .rx_busy_o     (rx_busy_o),
        .framing_err_o (rx_framing_err_raw),
        .parity_err_o  (rx_parity_err_raw)
    );

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rx_rdata_o       <= '0;
            rx_valid_o       <= 1'b0;
            rx_overrun_o     <= 1'b0;
            rx_framing_err_o <= 1'b0;
            rx_parity_err_o  <= 1'b0;
        end else begin
            // Read acknowledge clears the sticky flags; a same-cycle new
            // arrival (handled below) re-asserts rx_valid_o so the fresh
            // byte is never dropped.
            if (rx_rd_en_i) begin
                rx_valid_o   <= 1'b0;
                rx_overrun_o <= 1'b0;
            end

            if (rx_valid_raw) begin
                rx_rdata_o       <= rx_data_raw;
                rx_framing_err_o <= rx_framing_err_raw;
                rx_parity_err_o  <= rx_parity_err_raw;
                rx_valid_o       <= 1'b1;
                // Overrun iff the previous byte was still unread AND isn't
                // being acknowledged in this very same cycle.
                if (rx_valid_o && !rx_rd_en_i) begin
                    rx_overrun_o <= 1'b1;
                end
            end
        end
    end

endmodule
