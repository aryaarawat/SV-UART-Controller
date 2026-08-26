// -----------------------------------------------------------------------------
// File        : uart_tx.sv
// Description : UART transmitter. FSM-driven serializer that frames a
//               parallel byte as START - DATA[DATA_BITS] - [PARITY] - STOP(s)
//               and shifts it out LSB-first on tx_o, timed by an external 1x
//               baud tick (see baud_rate_gen.sv, tick_x1_o).
//
//               Parallel-side interface is a simple ready/valid handshake:
//               the caller drives tx_data_i + tx_valid_i, and the module
//               asserts tx_ready_o whenever it is idle and able to accept a
//               new byte. Once accepted, the byte is latched into an internal
//               holding register (tx_ready_o drops) and framing begins on the
//               next baud_tick_i pulse, so all bit periods -- including the
//               start bit -- are a full, consistent bit-time long regardless
//               of when within a tick period the handshake occurred. Worst
//               case this adds up to one bit-period of latency between
//               handshake and the line actually going low; it never drops or
//               corrupts data.
//
// Parameters  : DATA_BITS  - number of data bits per frame (default 8)
//               PARITY_EN  - 1 = append a parity bit, 0 = no parity bit
//               PARITY_ODD - 0 = even parity, 1 = odd parity (when PARITY_EN)
//               STOP_BITS  - number of stop bits, 1 or 2
// -----------------------------------------------------------------------------

module uart_tx #(
    parameter int DATA_BITS  = 8,
    parameter bit PARITY_EN  = 1'b0,
    parameter bit PARITY_ODD = 1'b0,
    parameter int STOP_BITS  = 1
) (
    input  logic clk_i,
    input  logic rst_ni,      // active-low, synchronous reset
    input  logic baud_tick_i, // 1x baud strobe from baud_rate_gen.tick_x1_o

    // Parallel ready/valid input
    input  logic [DATA_BITS-1:0] tx_data_i,
    input  logic                 tx_valid_i,
    output logic                 tx_ready_o,

    // Serial line + status
    output logic tx_o,
    output logic tx_busy_o
);

    localparam int BIT_CNT_W  = (DATA_BITS <= 1) ? 1 : $clog2(DATA_BITS);
    localparam int STOP_CNT_W = (STOP_BITS <= 1) ? 1 : $clog2(STOP_BITS);

    typedef enum logic [2:0] {
        S_IDLE,
        S_START,
        S_DATA,
        S_PARITY,
        S_STOP
    } state_e;

    state_e                state_q;
    logic [DATA_BITS-1:0]  shift_q;
    logic [BIT_CNT_W-1:0]  bit_idx_q;
    logic [STOP_CNT_W-1:0] stop_idx_q;
    logic                  loaded_q;    // byte latched, awaiting next baud_tick_i to start
    logic                  parity_bit_q;

    // Idle and not already holding an accepted-but-unsent byte.
    assign tx_ready_o = (state_q == S_IDLE) && !loaded_q;
    assign tx_busy_o  = (state_q != S_IDLE) || loaded_q;

    function automatic logic calc_parity(input logic [DATA_BITS-1:0] data);
        calc_parity = ^data ^ PARITY_ODD; // XOR-reduce gives even parity; PARITY_ODD flips it
    endfunction

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q      <= S_IDLE;
            tx_o         <= 1'b1;   // line idles high (mark state)
            shift_q      <= '0;
            bit_idx_q    <= '0;
            stop_idx_q   <= '0;
            loaded_q     <= 1'b0;
            parity_bit_q <= 1'b0;
        end else begin
            // Accept a new byte any cycle we're ready, independent of baud_tick_i.
            if (tx_ready_o && tx_valid_i) begin
                shift_q      <= tx_data_i;
                parity_bit_q <= calc_parity(tx_data_i);
                loaded_q     <= 1'b1;
            end

            unique case (state_q)
                S_IDLE: begin
                    tx_o <= 1'b1;
                    if (loaded_q && baud_tick_i) begin
                        state_q   <= S_START;
                        tx_o      <= 1'b0; // start bit
                        loaded_q  <= 1'b0;
                        bit_idx_q <= '0;
                    end
                end

                S_START: begin
                    if (baud_tick_i) begin
                        state_q   <= S_DATA;
                        tx_o      <= shift_q[0]; // data bit 0
                        shift_q   <= shift_q >> 1;
                        bit_idx_q <= '0;
                    end
                end

                S_DATA: begin
                    if (baud_tick_i) begin
                        if (bit_idx_q == BIT_CNT_W'(DATA_BITS - 1)) begin
                            // final data bit is currently on the line; move on
                            if (PARITY_EN) begin
                                state_q <= S_PARITY;
                                tx_o    <= parity_bit_q;
                            end else begin
                                state_q    <= S_STOP;
                                tx_o       <= 1'b1;
                                stop_idx_q <= '0;
                            end
                        end else begin
                            tx_o      <= shift_q[0];
                            shift_q   <= shift_q >> 1;
                            bit_idx_q <= bit_idx_q + 1'b1;
                        end
                    end
                end

                S_PARITY: begin
                    if (baud_tick_i) begin
                        state_q    <= S_STOP;
                        tx_o       <= 1'b1; // stop bit
                        stop_idx_q <= '0;
                    end
                end

                S_STOP: begin
                    if (baud_tick_i) begin
                        if (stop_idx_q == STOP_CNT_W'(STOP_BITS - 1)) begin
                            state_q <= S_IDLE;
                            tx_o    <= 1'b1;
                        end else begin
                            stop_idx_q <= stop_idx_q + 1'b1;
                            tx_o       <= 1'b1;
                        end
                    end
                end

                default: begin // recover from an illegal/SEU state
                    state_q <= S_IDLE;
                    tx_o    <= 1'b1;
                end
            endcase
        end
    end

endmodule
