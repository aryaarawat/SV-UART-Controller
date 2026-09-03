// -----------------------------------------------------------------------------
// File        : fifo.sv
// Description : Generic synchronous FIFO (single clock domain). Circular
//               buffer + a fill-level counter, first-word-fall-through read
//               semantics: rd_data_o always shows the current head entry
//               whenever !empty_o, no extra cycle of latency to "pop" it --
//               asserting rd_en_i for one cycle just advances the read
//               pointer to the next entry on the following clock edge.
//
//               Both wr_en_i and rd_en_i are safely ignored (no state
//               change, no wraparound/corruption) when the FIFO is
//               respectively full or empty, so a caller doesn't strictly
//               have to gate writes/reads on full_o/empty_o itself -- though
//               for a write that's usually a real overrun the caller will
//               want to detect (see uart_top's rx_overrun_o for an example).
//
// Parameters  : DATA_WIDTH - width of each entry
//               DEPTH      - number of entries (any positive integer, not
//                            required to be a power of 2)
// -----------------------------------------------------------------------------

module fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 16,
    // Declared here (rather than inline as $clog2(DEPTH+1) in the port list
    // below) and referenced from there -- Icarus Verilog hits an internal
    // "pop_value" assertion crash when a $clog2(...) expression on a module
    // parameter is used directly as a port's bit-range.
    localparam int COUNT_W = $clog2(DEPTH + 1)
) (
    input  logic                  clk_i,
    input  logic                  rst_ni, // active-low, synchronous reset

    // Write port
    input  logic                  wr_en_i,
    input  logic [DATA_WIDTH-1:0] wr_data_i,
    output logic                  full_o,

    // Read port (first-word-fall-through)
    input  logic                  rd_en_i,
    output logic [DATA_WIDTH-1:0] rd_data_o,
    output logic                  empty_o,

    // Fill level, 0..DEPTH inclusive
    output logic [COUNT_W-1:0] count_o
);

    localparam int PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [DATA_WIDTH-1:0] mem [DEPTH];
    logic [PTR_W-1:0]      wr_ptr_q, rd_ptr_q;
    logic [COUNT_W-1:0]    count_q;

    wire wr_fire = wr_en_i && !full_o;
    wire rd_fire = rd_en_i && !empty_o;

    assign full_o    = (count_q == DEPTH);
    assign empty_o   = (count_q == 0);
    assign count_o   = count_q;
    assign rd_data_o = mem[rd_ptr_q];

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            wr_ptr_q <= '0;
        end else if (wr_fire) begin
            mem[wr_ptr_q] <= wr_data_i;
            wr_ptr_q      <= (wr_ptr_q == PTR_W'(DEPTH - 1)) ? '0 : (wr_ptr_q + 1'b1);
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            rd_ptr_q <= '0;
        end else if (rd_fire) begin
            rd_ptr_q <= (rd_ptr_q == PTR_W'(DEPTH - 1)) ? '0 : (rd_ptr_q + 1'b1);
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            count_q <= '0;
        end else begin
            case ({wr_fire, rd_fire})
                2'b10:   count_q <= count_q + 1'b1;
                2'b01:   count_q <= count_q - 1'b1;
                default: count_q <= count_q; // 00: no change: 11: push+pop cancel out
            endcase
        end
    end

endmodule
