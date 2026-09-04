// -----------------------------------------------------------------------------
// File        : baud_rate_gen.sv
// Description : Configurable baud-rate generator / clock divider for the UART
//               controller. Derives two synchronous, single-cycle-pulse "tick"
//               strobes from the system clock:
//                 - tick_x16_o : fires at 16x the target baud rate. This is
//                                the strobe the RX FSM uses to oversample the
//                                incoming line and locate the start-bit edge
//                                and bit-cell midpoints.
//                 - tick_x1_o  : fires once per bit period (i.e. every 16th
//                                tick_x16_o pulse), phase-aligned to the 16x
//                                tick. This is the strobe the TX FSM uses to
//                                shift out one bit per pulse.
//
//               Deriving tick_x1_o from tick_x16_o (rather than from an
//               independent divider) guarantees the two strobes stay phase
//               locked, which keeps TX and RX bit timing consistent when both
//               share this generator (e.g. in a loopback test).
//
// Parameters  : CLK_FREQ_HZ  - system clock frequency in Hz
//               BAUD_RATE    - desired baud rate in bits/sec (9600, 115200, ...)
//               OVERSAMPLE   - oversampling factor for tick_x16_o (default 16)
//
// Notes       : Uses a simple round-to-nearest integer divider. Baud error
//               for common CLK_FREQ_HZ/BAUD_RATE pairs is well under 2%,
//               which is within the tolerance UART links generally accept.
//               A elaboration-time check flags configurations whose error
//               exceeds that budget.
// -----------------------------------------------------------------------------

module baud_rate_gen #(
    parameter int CLK_FREQ_HZ = 50_000_000,
    parameter int BAUD_RATE   = 115_200,
    parameter int OVERSAMPLE  = 16
) (
    input  logic clk_i,
    input  logic rst_ni,     // active-low, synchronous reset
    input  logic en_i,       // hold generator at reset count while low (power/idle gating)

    output logic tick_x16_o, // 1-cycle pulse at OVERSAMPLE * BAUD_RATE
    output logic tick_x1_o   // 1-cycle pulse at BAUD_RATE, aligned to tick_x16_o
);

    // -------------------------------------------------------------------
    // Divisor computation (elaboration-time constants)
    // -------------------------------------------------------------------
    // Round to nearest instead of truncating to minimize baud error.
    localparam int unsigned DIVISOR_X16 =
        (CLK_FREQ_HZ + (BAUD_RATE * OVERSAMPLE) / 2) / (BAUD_RATE * OVERSAMPLE);

    localparam int CLK_CNT_W = (DIVISOR_X16 <= 1) ? 1 : $clog2(DIVISOR_X16);
    localparam int OS_CNT_W  = (OVERSAMPLE  <= 1) ? 1 : $clog2(OVERSAMPLE);

    // synthesis translate_off
    // ACTUAL_BAUD_X16_HZ/ACTUAL_BAUD/BAUD_ERROR_PCT (and BAUD_ERROR_PCT's
    // `real` type) are pure simulation-time diagnostics with no bearing on
    // the synthesized hardware, so they -- like the initial block that uses
    // them -- live entirely inside this pragma. Some synthesis frontends
    // (e.g. Yosys) don't parse the `real` type at all, even in dead code,
    // so keeping this outside the pragma would break synthesis for no
    // synthesizable benefit.
    localparam int unsigned ACTUAL_BAUD_X16_HZ = CLK_FREQ_HZ / DIVISOR_X16;
    localparam real ACTUAL_BAUD = real'(ACTUAL_BAUD_X16_HZ) / real'(OVERSAMPLE);
    localparam real BAUD_ERROR_PCT =
        100.0 * (ACTUAL_BAUD - real'(BAUD_RATE)) / real'(BAUD_RATE);

    initial begin
        if (DIVISOR_X16 < 1) begin
            $fatal(1, "baud_rate_gen: CLK_FREQ_HZ=%0d too low for BAUD_RATE=%0d x OVERSAMPLE=%0d",
                   CLK_FREQ_HZ, BAUD_RATE, OVERSAMPLE);
        end
        if (BAUD_ERROR_PCT > 2.0 || BAUD_ERROR_PCT < -2.0) begin
            $warning("baud_rate_gen: baud error %.2f%% exceeds +/-2%% (target=%0d actual=%.1f)",
                      BAUD_ERROR_PCT, BAUD_RATE, ACTUAL_BAUD);
        end
    end
    // synthesis translate_on

    // -------------------------------------------------------------------
    // 16x tick generator: free-running clock-cycle counter
    // -------------------------------------------------------------------
    logic [CLK_CNT_W-1:0] clk_cnt_q;
    logic                 clk_wrap;

    assign clk_wrap = (clk_cnt_q == CLK_CNT_W'(DIVISOR_X16 - 1));

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            clk_cnt_q  <= '0;
            tick_x16_o <= 1'b0;
        end else if (!en_i) begin
            clk_cnt_q  <= '0;
            tick_x16_o <= 1'b0;
        end else if (clk_wrap) begin
            clk_cnt_q  <= '0;
            tick_x16_o <= 1'b1;
        end else begin
            clk_cnt_q  <= clk_cnt_q + 1'b1;
            tick_x16_o <= 1'b0;
        end
    end

    // -------------------------------------------------------------------
    // 1x tick generator: counts OVERSAMPLE tick_x16_o pulses
    // -------------------------------------------------------------------
    logic [OS_CNT_W-1:0] os_cnt_q;
    logic                os_wrap;

    assign os_wrap = (os_cnt_q == OS_CNT_W'(OVERSAMPLE - 1));

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            os_cnt_q  <= '0;
            tick_x1_o <= 1'b0;
        end else if (!en_i) begin
            os_cnt_q  <= '0;
            tick_x1_o <= 1'b0;
        end else if (tick_x16_o) begin
            os_cnt_q  <= os_wrap ? '0 : (os_cnt_q + 1'b1);
            tick_x1_o <= os_wrap;
        end else begin
            tick_x1_o <= 1'b0;
        end
    end

endmodule
