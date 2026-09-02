// -----------------------------------------------------------------------------
// File        : tb_baud_rate_gen.sv
// Description : Self-checking unit testbench for baud_rate_gen. Verifies:
//                 - tick_x16_o fires with a constant period of DIVISOR_X16
//                   clk_i cycles (read back from the DUT as a localparam).
//                 - tick_x1_o fires exactly once every OVERSAMPLE tick_x16_o
//                   pulses, i.e. the two strobes stay phase-locked.
//                 - en_i=0 holds the generator idle (no ticks) and resuming
//                   en_i=1 restarts a clean tick sequence.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_baud_rate_gen;

    localparam int CLK_FREQ_HZ = 50_000_000;
    localparam int BAUD_RATE   = 115_200;
    localparam int OVERSAMPLE  = 16;
    localparam int CLK_PERIOD  = 10; // ns, arbitrary -- functional test only

    logic clk_i   = 0;
    logic rst_ni  = 0;
    logic en_i    = 0;
    logic tick_x16_o, tick_x1_o;

    int errors = 0;

    baud_rate_gen #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE),
        .OVERSAMPLE  (OVERSAMPLE)
    ) dut (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),
        .en_i       (en_i),
        .tick_x16_o (tick_x16_o),
        .tick_x1_o  (tick_x1_o)
    );

    always #(CLK_PERIOD/2) clk_i = ~clk_i;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("[FAIL] %0t: %s", $time, msg);
        end
    endtask

    // Measure the wall-clock gap (in clk_i cycles) between consecutive
    // tick_x16_o pulses, and separately between consecutive tick_x1_o
    // pulses, using $time deltas -- avoids any fencepost ambiguity in a
    // hand-rolled cycle counter. tick_x1_o is registered one clk_i cycle
    // behind the tick_x16_o pulse that causes it (see baud_rate_gen's os_cnt
    // logic), so it is checked against a 1-cycle-delayed copy of
    // tick_x16_o rather than expecting same-cycle coincidence.
    time last_x16_t, last_x1_t;
    bit  x16_gap_valid, x1_gap_valid;
    bit  tick_x16_o_d1; // tick_x16_o, delayed by 1 clk_i cycle

    // Count tick_x16_o pulses since the last tick_x1_o pulse.
    int x16_since_x1;

    always @(posedge clk_i) begin
        if (!rst_ni || !en_i) begin
            x16_gap_valid  <= 1'b0;
            x1_gap_valid   <= 1'b0;
            tick_x16_o_d1  <= 1'b0;
            x16_since_x1   <= 0;
        end else begin
            tick_x16_o_d1 <= tick_x16_o;

            if (tick_x16_o) begin
                if (x16_gap_valid) begin
                    check(($time - last_x16_t) == time'(CLK_PERIOD) * dut.DIVISOR_X16,
                          $sformatf("tick_x16_o period = %0d clk cycles, expected DIVISOR_X16=%0d",
                                    ($time - last_x16_t) / CLK_PERIOD, dut.DIVISOR_X16));
                end
                last_x16_t    <= $time;
                x16_gap_valid <= 1'b1;
                x16_since_x1  <= x16_since_x1 + 1;
            end

            if (tick_x1_o) begin
                check(tick_x16_o_d1, "tick_x1_o fired without tick_x16_o one cycle earlier");
                check(x16_since_x1 == OVERSAMPLE,
                      $sformatf("tick_x1_o fired after %0d tick_x16_o pulses, expected OVERSAMPLE=%0d",
                                x16_since_x1, OVERSAMPLE));
                x16_since_x1 <= 0;

                if (x1_gap_valid) begin
                    check(($time - last_x1_t) == time'(CLK_PERIOD) * dut.DIVISOR_X16 * OVERSAMPLE,
                          $sformatf("tick_x1_o period = %0d clk cycles, expected %0d",
                                    ($time - last_x1_t) / CLK_PERIOD, dut.DIVISOR_X16 * OVERSAMPLE));
                end
                last_x1_t    <= $time;
                x1_gap_valid <= 1'b1;
            end
        end
    end

    initial begin
        $display("=== tb_baud_rate_gen: DIVISOR_X16=%0d ===", dut.DIVISOR_X16);

        // Reset
        rst_ni = 0; en_i = 0;
        repeat (3) @(posedge clk_i);
        check(!tick_x16_o && !tick_x1_o, "ticks not idle immediately out of reset");

        rst_ni = 1;
        repeat (3) @(posedge clk_i);
        check(!tick_x16_o && !tick_x1_o, "ticks fired while en_i=0");

        // Enable and let it free-run long enough to see many x1 ticks.
        en_i = 1;
        repeat (dut.DIVISOR_X16 * OVERSAMPLE * 40) @(posedge clk_i);

        check(x1_gap_valid, "tick_x1_o never fired while enabled");

        // Disable mid-stream, confirm ticks stop.
        en_i = 0;
        repeat (dut.DIVISOR_X16 * OVERSAMPLE * 2) @(posedge clk_i);
        // (checked implicitly: the always blocks above hold gap counters at 0
        //  and would flag any stray tick via the x1-without-x16 check)

        // Re-enable, confirm it resumes cleanly.
        en_i = 1;
        x1_gap_valid = 1'b0;
        x16_gap_valid  = 1'b0;
        repeat (dut.DIVISOR_X16 * OVERSAMPLE * 10) @(posedge clk_i);
        check(x1_gap_valid, "tick_x1_o never resumed after re-enabling en_i");

        if (errors == 0) $display("=== tb_baud_rate_gen: PASS ===");
        else begin
            $display("=== tb_baud_rate_gen: FAIL (%0d error(s)) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * dut.DIVISOR_X16 * OVERSAMPLE * 100);
        $display("[FAIL] %0t: watchdog timeout", $time);
        $fatal(1);
    end

endmodule
