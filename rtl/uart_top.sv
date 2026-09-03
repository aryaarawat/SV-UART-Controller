// -----------------------------------------------------------------------------
// File        : uart_top.sv
// Description : Top-level UART controller. Integrates baud_rate_gen, uart_tx
//               and uart_rx behind TX/RX FIFOs and a simple parallel
//               register-style interface, the kind a CPU (or an APB/AXI-lite
//               adapter placed in front of this module) would drive:
//
//                 TX side  - write tx_wdata_i with tx_wr_en_i pulsed high
//                            whenever tx_ready_o is high (TX FIFO not full),
//                            same as writing a memory-mapped TXDATA register
//                            only when a "TX FIFO not full" status bit is
//                            set. Bytes queue in the FIFO and drain into
//                            uart_tx automatically, so the CPU can burst
//                            several bytes in without waiting for each one
//                            to actually finish shifting out.
//                 RX side  - rx_rdata_o + rx_valid_o behave like an RXDATA
//                            register plus its RXNE ("receive not empty")
//                            status bit, backed by the RX FIFO instead of a
//                            single holding register: rx_valid_o stays high
//                            as long as the FIFO holds at least one byte,
//                            and each rx_rd_en_i pulse pops the oldest one.
//                            rx_overrun_o flags a byte that arrived while
//                            the RX FIFO was completely full (and was
//                            therefore dropped); it is sticky and clears on
//                            the next successful pop.
//
//               This FIFO + register layer is the buffering uart_rx
//               deliberately leaves out (see its header comment) and the
//               single-byte handshake uart_tx already provides on its own
//               -- it belongs at the integration level, not inside either
//               FSM.
// -----------------------------------------------------------------------------

module uart_top #(
    parameter int CLK_FREQ_HZ   = 50_000_000,
    parameter int BAUD_RATE     = 115_200,
    parameter int DATA_BITS     = 8,
    parameter bit PARITY_EN     = 1'b0,
    parameter bit PARITY_ODD    = 1'b0,
    parameter int STOP_BITS     = 1,
    parameter int OVERSAMPLE    = 16,
    parameter int TX_FIFO_DEPTH = 16,
    parameter int RX_FIFO_DEPTH = 16
) (
    input  logic clk_i,
    input  logic rst_ni, // active-low, synchronous reset

    // Serial line
    output logic tx_o,
    input  logic rx_i,

    // ---- TX FIFO write interface ----
    input  logic [DATA_BITS-1:0] tx_wdata_i,
    input  logic                 tx_wr_en_i, // pulse: accepted iff tx_ready_o is high this cycle
    output logic                 tx_ready_o, // TX FIFO not full, can accept a new byte
    output logic                 tx_full_o,  // TX FIFO full (== !tx_ready_o; explicit for convenience)
    output logic                 tx_busy_o,  // TX FIFO not empty, or a frame is currently shifting out

    // ---- RX FIFO read interface ----
    output logic [DATA_BITS-1:0] rx_rdata_o,       // oldest queued byte, valid while rx_valid_o is high
    output logic                 rx_valid_o,       // RX FIFO not empty ("byte available")
    input  logic                 rx_rd_en_i,       // pulse: pop rx_rdata_o (and its error flags below)
    output logic                 rx_empty_o,       // RX FIFO empty (== !rx_valid_o; explicit for convenience)
    output logic                 rx_full_o,        // RX FIFO full
    output logic                 rx_busy_o,        // mid-frame reception in progress
    output logic                 rx_overrun_o,     // sticky; a byte arrived while the RX FIFO was full and was dropped
    output logic                 rx_framing_err_o, // valid alongside rx_rdata_o (the byte at the head of the FIFO)
    output logic                 rx_parity_err_o   // valid alongside rx_rdata_o (always 0 if !PARITY_EN)
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

    // -------------------------------------------------------------------
    // TX: FIFO drains straight into uart_tx's own ready/valid handshake --
    // FIFO-not-empty is uart_tx's tx_valid_i, uart_tx's tx_ready_o gates
    // the pop, exactly like chaining two ready/valid stages together.
    // -------------------------------------------------------------------
    logic                  tx_fifo_full, tx_fifo_empty;
    logic [DATA_BITS-1:0]  tx_fifo_rdata;
    logic                  tx_uart_ready, tx_fifo_pop;

    assign tx_ready_o  = !tx_fifo_full;
    assign tx_full_o   = tx_fifo_full;
    assign tx_fifo_pop = !tx_fifo_empty && tx_uart_ready;

    fifo #(
        .DATA_WIDTH (DATA_BITS),
        .DEPTH      (TX_FIFO_DEPTH)
    ) u_tx_fifo (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .wr_en_i   (tx_wr_en_i),
        .wr_data_i (tx_wdata_i),
        .full_o    (tx_fifo_full),
        .rd_en_i   (tx_fifo_pop),
        .rd_data_o (tx_fifo_rdata),
        .empty_o   (tx_fifo_empty),
        .count_o   ()
    );

    logic tx_busy_raw;

    uart_tx #(
        .DATA_BITS  (DATA_BITS),
        .PARITY_EN  (PARITY_EN),
        .PARITY_ODD (PARITY_ODD),
        .STOP_BITS  (STOP_BITS)
    ) u_tx (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .baud_tick_i (tick_x1),
        .tx_data_i   (tx_fifo_rdata),
        .tx_valid_i  (!tx_fifo_empty),
        .tx_ready_o  (tx_uart_ready),
        .tx_o        (tx_o),
        .tx_busy_o   (tx_busy_raw)
    );

    assign tx_busy_o = !tx_fifo_empty || tx_busy_raw;

    // -------------------------------------------------------------------
    // RX: uart_rx's raw, single-cycle-pulse outputs get pushed straight
    // into the RX FIFO. Framing/parity error flags travel alongside the
    // data byte as extra FIFO bits, so each popped byte carries its own
    // error status rather than one flag shared across the whole queue.
    // -------------------------------------------------------------------
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

    localparam int RX_FIFO_W = DATA_BITS + 2; // {parity_err, framing_err, data}

    logic                    rx_fifo_full;
    logic [RX_FIFO_W-1:0]    rx_fifo_rdata;

    assign rx_valid_o = !rx_empty_o;
    assign rx_full_o  = rx_fifo_full;

    fifo #(
        .DATA_WIDTH (RX_FIFO_W),
        .DEPTH      (RX_FIFO_DEPTH)
    ) u_rx_fifo (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .wr_en_i   (rx_valid_raw),
        .wr_data_i ({rx_parity_err_raw, rx_framing_err_raw, rx_data_raw}),
        .full_o    (rx_fifo_full),
        .rd_en_i   (rx_rd_en_i),
        .rd_data_o (rx_fifo_rdata),
        .empty_o   (rx_empty_o),
        .count_o   ()
    );

    assign {rx_parity_err_o, rx_framing_err_o, rx_rdata_o} = rx_fifo_rdata;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rx_overrun_o <= 1'b0;
        end else begin
            if (rx_valid_raw && rx_fifo_full) begin
                // A byte finished arriving with nowhere to put it -- the
                // FIFO itself safely drops the write; this just records
                // that it happened. Sticky until the next successful pop.
                rx_overrun_o <= 1'b1;
            end else if (rx_rd_en_i && !rx_empty_o) begin
                rx_overrun_o <= 1'b0;
            end
        end
    end

endmodule
