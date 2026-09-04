// -----------------------------------------------------------------------------
// File        : uart_apb.sv
// Description : AMBA APB4 slave wrapper around uart_top. Exposes the UART's
//               TX/RX FIFOs and status flags as a 3-register, word-aligned
//               memory-mapped interface -- the kind an APB address decoder
//               would route a peripheral's base-address range to. PADDR here
//               is just the offset *within* this peripheral's own space
//               (ADDR_WIDTH bits); a system-level decoder is assumed to
//               produce psel_i from the upper address bits.
//
//               Register map (word-aligned byte offsets):
//                 0x0  TXDATA   (W)  write a byte into the TX FIFO
//                                    (PWDATA[DATA_BITS-1:0]; upper bits ignored)
//                 0x4  RXDATA   (R)  pop and return the oldest queued RX byte
//                                    (PRDATA[DATA_BITS-1:0]; upper bits 0)
//                 0x8  STATUS   (R)  packed status bits, see below
//
//               STATUS bit layout:
//                 [0] tx_ready_o        [5] rx_full_o
//                 [1] tx_full_o         [6] rx_busy_o
//                 [2] tx_busy_o         [7] rx_overrun_o
//                 [3] rx_valid_o        [8] rx_framing_err_o
//                 [4] rx_empty_o        [9] rx_parity_err_o
//                 [31:10] reserved, read as 0
//
//               This is a "no wait states" slave: pready_o is tied high, so
//               every transfer is exactly a 2-cycle SETUP+ACCESS sequence.
//               pslverr_o is asserted (the transfer still completes; APB has
//               no way to retry/stall a response) for:
//                 - writing TXDATA while tx_full_o is set (the byte is
//                   dropped by the TX FIFO itself, same as any other write
//                   while full -- this just tells the host it happened)
//                 - reading RXDATA while rx_empty_o is set (nothing was
//                   there to read; PRDATA reflects whatever stale value the
//                   RX FIFO's read pointer happens to be parked on)
//                 - any write to RXDATA or STATUS (both read-only)
//                 - any access to an offset outside the 3 registers above
// -----------------------------------------------------------------------------

module uart_apb #(
    parameter int CLK_FREQ_HZ   = 50_000_000,
    parameter int BAUD_RATE     = 115_200,
    parameter int DATA_BITS     = 8,
    parameter bit PARITY_EN     = 1'b0,
    parameter bit PARITY_ODD    = 1'b0,
    parameter int STOP_BITS     = 1,
    parameter int OVERSAMPLE    = 16,
    parameter int TX_FIFO_DEPTH = 16,
    parameter int RX_FIFO_DEPTH = 16,
    parameter int PDATA_WIDTH   = 32, // must be >= DATA_BITS
    parameter int ADDR_WIDTH    = 4   // bits of paddr_i this slave decodes
) (
    input  logic clk_i,
    input  logic rst_ni, // active-low, synchronous reset

    // ---- APB4 slave port ----
    input  logic                   psel_i,
    input  logic                   penable_i,
    input  logic                   pwrite_i,
    input  logic [ADDR_WIDTH-1:0]  paddr_i,
    input  logic [PDATA_WIDTH-1:0] pwdata_i,
    output logic [PDATA_WIDTH-1:0] prdata_o,
    output logic                   pready_o,
    output logic                   pslverr_o,

    // ---- Serial line ----
    output logic tx_o,
    input  logic rx_i
);

    // synthesis translate_off
    initial begin
        if (PDATA_WIDTH < DATA_BITS) begin
            $fatal(1, "uart_apb: PDATA_WIDTH=%0d must be >= DATA_BITS=%0d", PDATA_WIDTH, DATA_BITS);
        end
    end
    // synthesis translate_on

    localparam logic [ADDR_WIDTH-1:0] ADDR_TXDATA = 'h0;
    localparam logic [ADDR_WIDTH-1:0] ADDR_RXDATA = 'h4;
    localparam logic [ADDR_WIDTH-1:0] ADDR_STATUS = 'h8;

    logic [DATA_BITS-1:0] tx_wdata, rx_rdata;
    logic tx_wr_en, tx_ready, tx_full, tx_busy;
    logic rx_rd_en, rx_valid, rx_empty, rx_full, rx_busy, rx_overrun, rx_framing_err, rx_parity_err;

    uart_top #(
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .BAUD_RATE    (BAUD_RATE),
        .DATA_BITS    (DATA_BITS),
        .PARITY_EN    (PARITY_EN),
        .PARITY_ODD   (PARITY_ODD),
        .STOP_BITS    (STOP_BITS),
        .OVERSAMPLE   (OVERSAMPLE),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH),
        .RX_FIFO_DEPTH(RX_FIFO_DEPTH)
    ) u_uart (
        .clk_i (clk_i),
        .rst_ni(rst_ni),

        .tx_o(tx_o),
        .rx_i(rx_i),

        .tx_wdata_i(tx_wdata),
        .tx_wr_en_i(tx_wr_en),
        .tx_ready_o(tx_ready),
        .tx_full_o (tx_full),
        .tx_busy_o (tx_busy),

        .rx_rdata_o      (rx_rdata),
        .rx_valid_o      (rx_valid),
        .rx_rd_en_i      (rx_rd_en),
        .rx_empty_o      (rx_empty),
        .rx_full_o       (rx_full),
        .rx_busy_o       (rx_busy),
        .rx_overrun_o    (rx_overrun),
        .rx_framing_err_o(rx_framing_err),
        .rx_parity_err_o (rx_parity_err)
    );

    // No wait states: a transfer completes in the access-phase cycle
    // (PENABLE high), the same cycle it starts, since pready_o is tied high.
    assign pready_o = 1'b1;

    wire access_phase = psel_i && penable_i;
    wire write_xfer    = access_phase && pwrite_i;
    wire read_xfer      = access_phase && !pwrite_i;

    wire sel_txdata = (paddr_i == ADDR_TXDATA);
    wire sel_rxdata = (paddr_i == ADDR_RXDATA);
    wire sel_status = (paddr_i == ADDR_STATUS);

    assign tx_wdata = pwdata_i[DATA_BITS-1:0];
    assign tx_wr_en = write_xfer && sel_txdata;
    assign rx_rd_en = read_xfer && sel_rxdata;

    logic [PDATA_WIDTH-1:0] status_word;
    always_comb begin
        status_word = '0;
        status_word[0] = tx_ready;
        status_word[1] = tx_full;
        status_word[2] = tx_busy;
        status_word[3] = rx_valid;
        status_word[4] = rx_empty;
        status_word[5] = rx_full;
        status_word[6] = rx_busy;
        status_word[7] = rx_overrun;
        status_word[8] = rx_framing_err;
        status_word[9] = rx_parity_err;
    end

    // Driven purely combinationally from paddr_i (stable through the whole
    // SETUP+ACCESS sequence), so it's valid as soon as SETUP begins -- an
    // earlier guarantee than APB requires, which is always safe.
    always_comb begin
        prdata_o = '0;
        if (sel_rxdata) prdata_o = {{(PDATA_WIDTH - DATA_BITS){1'b0}}, rx_rdata};
        else if (sel_status) prdata_o = status_word;
    end

    assign pslverr_o = access_phase &&
        ((write_xfer && sel_txdata && tx_full) ||
         (read_xfer  && sel_rxdata && rx_empty) ||
         (write_xfer && (sel_rxdata || sel_status)) ||
         !(sel_txdata || sel_rxdata || sel_status));

endmodule
