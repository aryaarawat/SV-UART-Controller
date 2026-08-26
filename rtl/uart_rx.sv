// -----------------------------------------------------------------------------
// File        : uart_rx.sv
// Description : UART receiver. Oversampling FSM that synchronizes an
//               asynchronous serial input, locates the start-bit edge,
//               samples each bit at its cell midpoint, and deserializes
//               START - DATA[DATA_BITS] - [PARITY] - STOP(s) into a parallel
//               byte, flagging framing and parity errors.
//
//               Timed by an external 16x (OVERSAMPLE) baud tick (see
//               baud_rate_gen.sv, tick_x16_o) rather than the 1x tick TX
//               uses: unlike TX, RX cannot assume phase alignment with the
//               incoming line, so it has to *find* the start bit by watching
//               for a falling edge, then re-derive bit-cell timing from that
//               edge rather than from tick_x1_o.
//
// Synchronization: rx_i is treated as fully asynchronous to clk_i. A 2-stage
//               synchronizer hardens it against metastability; a 3rd flop
//               provides a one-cycle-delayed copy for edge detection.
//
// Edge -> sample alignment:
//               1. S_IDLE watches the synchronized line for a high->low
//                  transition (start-bit edge).
//               2. S_START waits OVERSAMPLE/2 ticks (half a bit period) and
//                  re-checks the line. Still low -> real start bit, and this
//                  point is now the *midpoint* of the start bit, so bit-cell
//                  timing is anchored here. Back high -> was a glitch/noise,
//                  return to S_IDLE.
//               3. Every subsequent bit (data, parity, stop) is sampled
//                  exactly OVERSAMPLE ticks later, i.e. one full bit period
//                  after the previous sample -- which lands on that bit's
//                  midpoint too, since all bit periods are equal length.
//
// Parameters  : DATA_BITS  - number of data bits per frame (default 8)
//               PARITY_EN  - 1 = expect a parity bit, 0 = no parity bit
//               PARITY_ODD - 0 = even parity, 1 = odd parity (when PARITY_EN)
//               STOP_BITS  - number of stop bits to check, 1 or 2
//               OVERSAMPLE - ticks per bit period on tick_x16_i; must match
//                            the OVERSAMPLE used to generate tick_x16_i, and
//                            must be even (default 16)
// -----------------------------------------------------------------------------

module uart_rx #(
    parameter int DATA_BITS  = 8,
    parameter bit PARITY_EN  = 1'b0,
    parameter bit PARITY_ODD = 1'b0,
    parameter int STOP_BITS  = 1,
    parameter int OVERSAMPLE = 16
) (
    input  logic clk_i,
    input  logic rst_ni,      // active-low, synchronous reset
    input  logic tick_x16_i,  // OVERSAMPLE x baud strobe from baud_rate_gen.tick_x16_o
    input  logic rx_i,        // asynchronous serial input

    output logic [DATA_BITS-1:0] rx_data_o,     // valid the cycle rx_valid_o pulses
    output logic                 rx_valid_o,    // 1-cycle pulse: a full frame was received
    output logic                 rx_busy_o,     // mid-frame (not idle/watching for an edge)
    output logic                 framing_err_o, // valid alongside rx_valid_o
    output logic                 parity_err_o   // valid alongside rx_valid_o (tied 0 if !PARITY_EN)
);

    localparam int OS_CNT_W   = $clog2(OVERSAMPLE);
    localparam int HALF_TICKS = OVERSAMPLE / 2;
    localparam int BIT_CNT_W  = (DATA_BITS <= 1) ? 1 : $clog2(DATA_BITS);
    localparam int STOP_CNT_W = (STOP_BITS <= 1) ? 1 : $clog2(STOP_BITS);

    // synthesis translate_off
    initial begin
        if (OVERSAMPLE < 4 || (OVERSAMPLE % 2) != 0) begin
            $fatal(1, "uart_rx: OVERSAMPLE must be an even number >= 4 (got %0d)", OVERSAMPLE);
        end
    end
    // synthesis translate_on

    // -------------------------------------------------------------------
    // Input synchronizer (2 stages) + 1 extra flop for edge detection
    // -------------------------------------------------------------------
    logic rx_meta_q, rx_sync_q, rx_sync_d1_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rx_meta_q    <= 1'b1; // idle/mark state
            rx_sync_q    <= 1'b1;
            rx_sync_d1_q <= 1'b1;
        end else begin
            rx_meta_q    <= rx_i;
            rx_sync_q    <= rx_meta_q;
            rx_sync_d1_q <= rx_sync_q;
        end
    end

    wire falling_edge = rx_sync_d1_q && !rx_sync_q;

    // -------------------------------------------------------------------
    // Deserializer FSM
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,
        S_START,
        S_DATA,
        S_PARITY,
        S_STOP
    } state_e;

    state_e                state_q;
    logic [OS_CNT_W-1:0]   os_cnt_q;
    logic [BIT_CNT_W-1:0]  bit_idx_q;
    logic [STOP_CNT_W-1:0] stop_idx_q;
    logic [DATA_BITS-1:0]  shift_q;
    logic                  parity_bit_q;
    logic                  stop_err_q; // sticky across multiple stop bits

    function automatic logic calc_parity(input logic [DATA_BITS-1:0] data);
        calc_parity = ^data ^ PARITY_ODD;
    endfunction

    assign rx_busy_o = (state_q != S_IDLE);

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q       <= S_IDLE;
            os_cnt_q      <= '0;
            bit_idx_q     <= '0;
            stop_idx_q    <= '0;
            shift_q       <= '0;
            parity_bit_q  <= 1'b0;
            stop_err_q    <= 1'b0;
            rx_data_o     <= '0;
            rx_valid_o    <= 1'b0;
            framing_err_o <= 1'b0;
            parity_err_o  <= 1'b0;
        end else begin
            rx_valid_o <= 1'b0; // default: single-cycle pulse, only set below

            unique case (state_q)
                S_IDLE: begin
                    if (falling_edge) begin
                        state_q  <= S_START;
                        os_cnt_q <= '0;
                    end
                end

                S_START: begin
                    if (tick_x16_i) begin
                        if (os_cnt_q == OS_CNT_W'(HALF_TICKS - 1)) begin
                            // midpoint of the putative start bit
                            if (!rx_sync_q) begin
                                state_q   <= S_DATA;
                                os_cnt_q  <= '0;
                                bit_idx_q <= '0;
                            end else begin
                                state_q <= S_IDLE; // glitch: line already back high
                            end
                        end else begin
                            os_cnt_q <= os_cnt_q + 1'b1;
                        end
                    end
                end

                S_DATA: begin
                    if (tick_x16_i) begin
                        if (os_cnt_q == OS_CNT_W'(OVERSAMPLE - 1)) begin
                            // one full bit period after the previous sample -> this bit's midpoint
                            os_cnt_q <= '0;
                            shift_q  <= {rx_sync_q, shift_q[DATA_BITS-1:1]}; // received LSB-first
                            if (bit_idx_q == BIT_CNT_W'(DATA_BITS - 1)) begin
                                state_q    <= PARITY_EN ? S_PARITY : S_STOP;
                                stop_idx_q <= '0;
                                stop_err_q <= 1'b0;
                            end else begin
                                bit_idx_q <= bit_idx_q + 1'b1;
                            end
                        end else begin
                            os_cnt_q <= os_cnt_q + 1'b1;
                        end
                    end
                end

                S_PARITY: begin
                    if (tick_x16_i) begin
                        if (os_cnt_q == OS_CNT_W'(OVERSAMPLE - 1)) begin
                            os_cnt_q     <= '0;
                            parity_bit_q <= rx_sync_q;
                            state_q      <= S_STOP;
                            stop_idx_q   <= '0;
                            stop_err_q   <= 1'b0;
                        end else begin
                            os_cnt_q <= os_cnt_q + 1'b1;
                        end
                    end
                end

                S_STOP: begin
                    if (tick_x16_i) begin
                        if (os_cnt_q == OS_CNT_W'(OVERSAMPLE - 1)) begin
                            os_cnt_q <= '0;
                            if (stop_idx_q == STOP_CNT_W'(STOP_BITS - 1)) begin
                                // last stop bit: frame complete, deliver it
                                state_q       <= S_IDLE;
                                rx_data_o     <= shift_q;
                                rx_valid_o    <= 1'b1;
                                framing_err_o <= stop_err_q | !rx_sync_q;
                                parity_err_o  <= PARITY_EN && (parity_bit_q != calc_parity(shift_q));
                            end else begin
                                stop_idx_q <= stop_idx_q + 1'b1;
                                stop_err_q <= stop_err_q | !rx_sync_q;
                            end
                        end else begin
                            os_cnt_q <= os_cnt_q + 1'b1;
                        end
                    end
                end

                default: state_q <= S_IDLE; // recover from an illegal/SEU state
            endcase
        end
    end

endmodule
