// -----------------------------------------------------------------------------
// File        : tb_uart_rx.sv
// Description : Self-checking unit testbench for uart_rx. tick_x16_i is a
//               free-running, TB-generated strobe (no baud_rate_gen needed);
//               rx_i is bit-banged directly by the TB -- independent of
//               uart_tx -- so the error-injection paths (framing, parity,
//               start-bit glitch rejection) can be driven precisely.
//
//               Covers three parameter configurations in parallel DUT
//               instances: no-parity/1-stop, even-parity/1-stop,
//               no-parity/2-stop.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_uart_rx;

    localparam int DATA_BITS   = 8;
    localparam int OVERSAMPLE  = 16;
    localparam int CLK_PERIOD  = 10; // ns
    localparam int TICK16_DIV  = 4;  // clk cycles per tick_x16_i pulse (fast sim)
    localparam int BIT_PERIOD_CLKS = OVERSAMPLE * TICK16_DIV;

    logic clk_i  = 0;
    logic rst_ni = 0;

    always #(CLK_PERIOD/2) clk_i = ~clk_i;

    // Free-running tick_x16_i, shared by all DUT instances.
    logic tick_x16_i;
    int   tick_cnt;
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            tick_cnt   <= 0;
            tick_x16_i <= 1'b0;
        end else if (tick_cnt == TICK16_DIV - 1) begin
            tick_cnt   <= 0;
            tick_x16_i <= 1'b1;
        end else begin
            tick_cnt   <= tick_cnt + 1;
            tick_x16_i <= 1'b0;
        end
    end

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("[FAIL] %0t: %s", $time, msg);
        end
    endtask

    localparam int NUM_CFG = 3;

    logic [DATA_BITS-1:0] rx_data_o     [NUM_CFG];
    logic                 rx_valid_o    [NUM_CFG];
    logic                 rx_busy_o     [NUM_CFG];
    logic                 framing_err_o [NUM_CFG];
    logic                 parity_err_o  [NUM_CFG];
    logic                 rx_i          [NUM_CFG];

    // cfg 0: no parity,  1 stop
    uart_rx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE)) dut0 (
        .clk_i(clk_i), .rst_ni(rst_ni), .tick_x16_i(tick_x16_i), .rx_i(rx_i[0]),
        .rx_data_o(rx_data_o[0]), .rx_valid_o(rx_valid_o[0]), .rx_busy_o(rx_busy_o[0]),
        .framing_err_o(framing_err_o[0]), .parity_err_o(parity_err_o[0])
    );
    // cfg 1: even parity, 1 stop
    uart_rx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b1), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE)) dut1 (
        .clk_i(clk_i), .rst_ni(rst_ni), .tick_x16_i(tick_x16_i), .rx_i(rx_i[1]),
        .rx_data_o(rx_data_o[1]), .rx_valid_o(rx_valid_o[1]), .rx_busy_o(rx_busy_o[1]),
        .framing_err_o(framing_err_o[1]), .parity_err_o(parity_err_o[1])
    );
    // cfg 2: no parity, 2 stop
    uart_rx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(2), .OVERSAMPLE(OVERSAMPLE)) dut2 (
        .clk_i(clk_i), .rst_ni(rst_ni), .tick_x16_i(tick_x16_i), .rx_i(rx_i[2]),
        .rx_data_o(rx_data_o[2]), .rx_valid_o(rx_valid_o[2]), .rx_busy_o(rx_busy_o[2]),
        .framing_err_o(framing_err_o[2]), .parity_err_o(parity_err_o[2])
    );

    // Populated via an initial block (rather than an aggregate '{...}
    // literal assigned to the whole array) for portability -- older Icarus
    // Verilog releases (e.g. the 12.0 apt package on Ubuntu) don't support
    // whole-array aggregate assignment.
    bit    cfg_parity_en  [NUM_CFG];
    bit    cfg_parity_odd [NUM_CFG];
    int    cfg_stop_bits  [NUM_CFG];
    string cfg_name       [NUM_CFG];
    initial begin
        cfg_parity_en[0] = 1'b0; cfg_parity_odd[0] = 1'b0; cfg_stop_bits[0] = 1; cfg_name[0] = "no-parity/1-stop";
        cfg_parity_en[1] = 1'b1; cfg_parity_odd[1] = 1'b0; cfg_stop_bits[1] = 1; cfg_name[1] = "even-parity/1-stop";
        cfg_parity_en[2] = 1'b0; cfg_parity_odd[2] = 1'b0; cfg_stop_bits[2] = 2; cfg_name[2] = "no-parity/2-stop";
    end

    // Generous upper bound (in clk cycles) on how long a full frame can take
    // to arrive: 1 leading idle bit + start + data + parity + stop bits,
    // plus margin for the RX input synchronizer's few cycles of latency.
    function automatic int frame_timeout_clks(input int idx);
        return (DATA_BITS + cfg_stop_bits[idx] + 6) * BIT_PERIOD_CLKS;
    endfunction

    // Bit-bang one frame onto rx_i[idx]. force_framing_err drives every stop
    // bit low; force_parity_err flips the transmitted parity bit.
    task automatic send_frame(input int idx, input logic [DATA_BITS-1:0] data,
                               input bit force_framing_err = 1'b0,
                               input bit force_parity_err  = 1'b0);
        logic p;
        rx_i[idx] <= 1'b1;
        repeat (BIT_PERIOD_CLKS) @(posedge clk_i);

        rx_i[idx] <= 1'b0; // start bit
        repeat (BIT_PERIOD_CLKS) @(posedge clk_i);

        for (int i = 0; i < DATA_BITS; i++) begin
            rx_i[idx] <= data[i];
            repeat (BIT_PERIOD_CLKS) @(posedge clk_i);
        end

        if (cfg_parity_en[idx]) begin
            p = ^data ^ cfg_parity_odd[idx];
            if (force_parity_err) p = ~p;
            rx_i[idx] <= p;
            repeat (BIT_PERIOD_CLKS) @(posedge clk_i);
        end

        for (int i = 0; i < cfg_stop_bits[idx]; i++) begin
            rx_i[idx] <= force_framing_err ? 1'b0 : 1'b1;
            repeat (BIT_PERIOD_CLKS) @(posedge clk_i);
        end

        rx_i[idx] <= 1'b1; // back to idle/mark
    endtask

    task automatic wait_for_valid(input int idx, input int max_cycles, output bit got);
        // Loop condition carries the exit, rather than "break" -- unsupported
        // on older Icarus Verilog.
        got = 1'b0;
        for (int c = 0; c < max_cycles && !got; c++) begin
            @(posedge clk_i);
            if (rx_valid_o[idx]) got = 1'b1;
        end
    endtask

    task automatic send_and_check(input int idx, input logic [DATA_BITS-1:0] data,
                                   input bit force_framing_err = 1'b0,
                                   input bit force_parity_err  = 1'b0);
        bit got;
        fork
            send_frame(idx, data, force_framing_err, force_parity_err);
            wait_for_valid(idx, frame_timeout_clks(idx), got);
        join

        check(got, $sformatf("[%s] rx_valid_o never pulsed for 0x%0h (framing_err=%0b parity_err=%0b)",
                              cfg_name[idx], data, force_framing_err, force_parity_err));

        // Guard the rest with "if (got)" rather than an early "return" --
        // unsupported from tasks on older Icarus Verilog.
        if (got) begin
            check(rx_data_o[idx] == data,
                  $sformatf("[%s] decoded data 0x%0h != expected 0x%0h", cfg_name[idx], rx_data_o[idx], data));
            check(framing_err_o[idx] == force_framing_err,
                  $sformatf("[%s] framing_err_o=%0b, expected %0b", cfg_name[idx], framing_err_o[idx], force_framing_err));
            if (cfg_parity_en[idx]) begin
                check(parity_err_o[idx] == force_parity_err,
                      $sformatf("[%s] parity_err_o=%0b, expected %0b", cfg_name[idx], parity_err_o[idx], force_parity_err));
            end else begin
                check(parity_err_o[idx] == 1'b0, $sformatf("[%s] parity_err_o set with parity disabled", cfg_name[idx]));
            end

            // Settle back to idle before the next frame.
            repeat (2 * BIT_PERIOD_CLKS) @(posedge clk_i);
            check(!rx_busy_o[idx], $sformatf("[%s] rx_busy_o still high after frame + idle gap", cfg_name[idx]));
        end
    endtask

    initial begin
        for (int c = 0; c < NUM_CFG; c++) rx_i[c] = 1'b1;

        rst_ni = 0;
        repeat (3) @(posedge clk_i);
        rst_ni = 1;
        repeat (5) @(posedge clk_i);

        for (int c = 0; c < NUM_CFG; c++) begin
            check(!rx_busy_o[c], $sformatf("[%s] rx_busy_o high out of reset", cfg_name[c]));
            check(!rx_valid_o[c], $sformatf("[%s] rx_valid_o high out of reset", cfg_name[c]));
        end

        // Directed + random clean frames on every configuration.
        begin
            logic [7:0] vectors [6];
            vectors[0] = 8'h00; vectors[1] = 8'hFF; vectors[2] = 8'hA5;
            vectors[3] = 8'h01; vectors[4] = 8'h80; vectors[5] = 8'h55;
            for (int c = 0; c < NUM_CFG; c++) begin
                foreach (vectors[v]) send_and_check(c, vectors[v]);
                repeat (3) send_and_check(c, $urandom_range(0, 255));
            end
        end

        // Framing error injection (stop bit(s) forced low). Positional args
        // throughout (rather than named .force_framing_err(...) connections)
        // for portability -- older Icarus Verilog releases don't support
        // named task-argument connections combined with default values.
        send_and_check(0, 8'h3C, 1'b1, 1'b0);
        send_and_check(2, 8'h3C, 1'b1, 1'b0); // 2-stop-bit config

        // Parity error injection (only meaningful on the parity-enabled cfg).
        send_and_check(1, 8'h6D, 1'b0, 1'b1);
        send_and_check(1, 8'h6D, 1'b0, 1'b0); // and confirm clean frame still passes after an error

        // Start-bit glitch rejection: a low pulse much shorter than half a
        // bit period must NOT be mistaken for a start bit.
        begin
            bit got;
            rx_i[0] <= 1'b1;
            repeat (BIT_PERIOD_CLKS) @(posedge clk_i);
            fork
                begin
                    rx_i[0] <= 1'b0;
                    repeat (2 * TICK16_DIV) @(posedge clk_i); // << half-bit-period (8*TICK16_DIV)
                    rx_i[0] <= 1'b1;
                end
                wait_for_valid(0, frame_timeout_clks(0), got);
            join
            check(!got, "[no-parity/1-stop] glitch shorter than half a bit period was accepted as a start bit");
            check(!rx_busy_o[0], "[no-parity/1-stop] rx_busy_o stuck high after glitch");
            // DUT should still decode a real frame right afterward.
            send_and_check(0, 8'h5A);
        end

        // Back-to-back frames with no idle gap, to check the FSM re-arms
        // immediately for the next start-bit edge.
        for (int i = 0; i < 5; i++) send_and_check(0, 8'h20 + i);

        if (errors == 0) $display("=== tb_uart_rx: PASS ===");
        else begin
            $display("=== tb_uart_rx: FAIL (%0d error(s)) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * BIT_PERIOD_CLKS * 2000);
        $display("[FAIL] %0t: watchdog timeout", $time);
        $fatal(1);
    end

endmodule
