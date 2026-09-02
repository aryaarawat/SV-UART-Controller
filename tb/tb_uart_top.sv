// -----------------------------------------------------------------------------
// File        : tb_uart_top.sv
// Description : Integration testbench for uart_top. Wires tx_o straight back
//               to rx_i (self-loopback) and drives the register-style
//               TX/RX interface the way a CPU would, using the real
//               baud_rate_gen (not a TB-fabricated tick). Covers:
//                 - reset state of all status signals
//                 - single-byte round trip
//                 - back-to-back streaming with in-order data integrity
//                 - the rx_overrun_o sticky flag when a byte is left unread
//                 - a full loopback pass with parity enabled
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_uart_top;

    localparam int DATA_BITS     = 8;
    localparam int CLK_FREQ_HZ   = 50_000_000;
    localparam int BAUD_RATE     = 115_200;
    localparam int OVERSAMPLE    = 16;
    localparam int CLK_PERIOD    = 20; // ns (50 MHz, matches CLK_FREQ_HZ)

    // Mirrors baud_rate_gen's own round-to-nearest divisor calc, purely so
    // this TB can size its wait/timeout windows without a hierarchical
    // reference into the DUT.
    localparam int DIVISOR_X16     = (CLK_FREQ_HZ + (BAUD_RATE * OVERSAMPLE) / 2) / (BAUD_RATE * OVERSAMPLE);
    localparam int BIT_PERIOD_CLKS = DIVISOR_X16 * OVERSAMPLE;

    function automatic int frame_clks(bit parity_en, int stop_bits);
        return BIT_PERIOD_CLKS * (1 + DATA_BITS + (parity_en ? 1 : 0) + stop_bits);
    endfunction

    logic clk_i  = 0;
    logic rst_ni = 0;

    always #(CLK_PERIOD/2) clk_i = ~clk_i;

    localparam int NUM_CFG = 2; // 0: no parity, 1: even parity -- both 1 stop bit

    logic [DATA_BITS-1:0] tx_wdata_i     [NUM_CFG];
    logic                 tx_wr_en_i     [NUM_CFG];
    logic                 tx_ready_o     [NUM_CFG];
    logic                 tx_busy_o      [NUM_CFG];
    logic [DATA_BITS-1:0] rx_rdata_o     [NUM_CFG];
    logic                 rx_valid_o     [NUM_CFG];
    logic                 rx_rd_en_i     [NUM_CFG];
    logic                 rx_busy_o      [NUM_CFG];
    logic                 rx_overrun_o   [NUM_CFG];
    logic                 rx_framing_err_o [NUM_CFG];
    logic                 rx_parity_err_o  [NUM_CFG];
    logic                 serial_line    [NUM_CFG]; // tx_o looped back to rx_i

    uart_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .DATA_BITS(DATA_BITS),
        .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE)
    ) dut0 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .tx_o(serial_line[0]), .rx_i(serial_line[0]),
        .tx_wdata_i(tx_wdata_i[0]), .tx_wr_en_i(tx_wr_en_i[0]),
        .tx_ready_o(tx_ready_o[0]), .tx_busy_o(tx_busy_o[0]),
        .rx_rdata_o(rx_rdata_o[0]), .rx_valid_o(rx_valid_o[0]), .rx_rd_en_i(rx_rd_en_i[0]),
        .rx_busy_o(rx_busy_o[0]), .rx_overrun_o(rx_overrun_o[0]),
        .rx_framing_err_o(rx_framing_err_o[0]), .rx_parity_err_o(rx_parity_err_o[0])
    );

    uart_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .DATA_BITS(DATA_BITS),
        .PARITY_EN(1'b1), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE)
    ) dut1 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .tx_o(serial_line[1]), .rx_i(serial_line[1]),
        .tx_wdata_i(tx_wdata_i[1]), .tx_wr_en_i(tx_wr_en_i[1]),
        .tx_ready_o(tx_ready_o[1]), .tx_busy_o(tx_busy_o[1]),
        .rx_rdata_o(rx_rdata_o[1]), .rx_valid_o(rx_valid_o[1]), .rx_rd_en_i(rx_rd_en_i[1]),
        .rx_busy_o(rx_busy_o[1]), .rx_overrun_o(rx_overrun_o[1]),
        .rx_framing_err_o(rx_framing_err_o[1]), .rx_parity_err_o(rx_parity_err_o[1])
    );

    // Populated via an initial block (rather than an aggregate '{...}
    // literal assigned to the whole array) for portability -- older Icarus
    // Verilog releases (e.g. the 12.0 apt package on Ubuntu) don't support
    // whole-array aggregate assignment.
    bit    cfg_parity_en [NUM_CFG];
    string cfg_name      [NUM_CFG];
    initial begin
        cfg_parity_en[0] = 1'b0; cfg_name[0] = "no-parity";
        cfg_parity_en[1] = 1'b1; cfg_name[1] = "even-parity";
    end

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("[FAIL] %0t: %s", $time, msg);
        end
    endtask

    // Drives DUT inputs with nonblocking assignment throughout this file --
    // required (not just stylistic) here: tx_send/rx_recv run concurrently
    // with sibling processes inside fork/join blocks, and a blocking
    // assignment's set-then-clear of a single-cycle pulse can lose the
    // scheduling race against another process triggered by the same clk_i
    // edge, so the DUT's own always_ff never observes the pulse at all.
    task automatic tx_send(input int idx, input logic [DATA_BITS-1:0] data);
        @(posedge clk_i);
        while (!tx_ready_o[idx]) @(posedge clk_i);
        tx_wdata_i[idx] <= data;
        tx_wr_en_i[idx] <= 1'b1;
        @(posedge clk_i);
        tx_wr_en_i[idx] <= 1'b0;
    endtask

    // Waits for rx_valid_o, captures the byte + error flags, then acks it.
    task automatic rx_recv(input int idx, input int max_cycles,
                            output bit got, output logic [DATA_BITS-1:0] data,
                            output bit overrun, output bit framing_err, output bit parity_err);
        got = 1'b0;
        for (int c = 0; c < max_cycles; c++) begin
            @(posedge clk_i);
            if (rx_valid_o[idx]) begin
                got         = 1'b1;
                data        = rx_rdata_o[idx];
                overrun     = rx_overrun_o[idx];
                framing_err = rx_framing_err_o[idx];
                parity_err  = rx_parity_err_o[idx];
                break;
            end
        end
        if (got) begin
            rx_rd_en_i[idx] <= 1'b1;
            @(posedge clk_i);
            rx_rd_en_i[idx] <= 1'b0;
        end
    endtask

    task automatic round_trip(input int idx, input logic [DATA_BITS-1:0] data);
        bit got, overrun, framing_err, parity_err;
        logic [DATA_BITS-1:0] rdata;
        fork
            tx_send(idx, data);
            rx_recv(idx, frame_clks(cfg_parity_en[idx], 1) * 3, got, rdata, overrun, framing_err, parity_err);
        join
        check(got, $sformatf("[%s] round trip of 0x%0h: rx_valid_o never pulsed", cfg_name[idx], data));
        // Guard with "if (got)" rather than an early "return" -- unsupported
        // from tasks on older Icarus Verilog.
        if (got) begin
            check(rdata == data, $sformatf("[%s] round trip: got 0x%0h, expected 0x%0h", cfg_name[idx], rdata, data));
            check(!overrun, $sformatf("[%s] round trip of 0x%0h: unexpected overrun", cfg_name[idx], data));
            check(!framing_err, $sformatf("[%s] round trip of 0x%0h: unexpected framing error", cfg_name[idx], data));
            check(!parity_err, $sformatf("[%s] round trip of 0x%0h: unexpected parity error", cfg_name[idx], data));
        end
    endtask

    // Streams `n` random bytes back-to-back (writer keeps feeding tx as soon
    // as tx_ready_o allows) while a concurrent reader drains rx as soon as
    // rx_valid_o pulses, checking strict in-order data integrity.
    task automatic streaming_test(input int idx, input int n);
        logic [DATA_BITS-1:0] expected [$];
        int mismatches;
        expected.delete();
        mismatches = 0;

        fork
            begin : writer
                logic [DATA_BITS-1:0] b;
                for (int i = 0; i < n; i++) begin
                    b = $urandom_range(0, 255);
                    expected.push_back(b);
                    tx_send(idx, b);
                end
            end
            begin : reader
                bit got, ov, fe, pe;
                logic [DATA_BITS-1:0] rd;
                logic [DATA_BITS-1:0] exp_b;
                for (int i = 0; i < n; i++) begin
                    rx_recv(idx, frame_clks(cfg_parity_en[idx], 1) * 4, got, rd, ov, fe, pe);
                    if (!got) begin
                        mismatches++;
                        $display("[FAIL] %0t: [%s] streaming: byte #%0d never arrived", $time, cfg_name[idx], i);
                        continue;
                    end
                    exp_b = expected.pop_front();
                    if (rd !== exp_b) begin
                        mismatches++;
                        $display("[FAIL] %0t: [%s] streaming: byte #%0d = 0x%0h, expected 0x%0h",
                                  $time, cfg_name[idx], i, rd, exp_b);
                    end
                    if (ov || fe || pe) begin
                        mismatches++;
                        $display("[FAIL] %0t: [%s] streaming: byte #%0d unexpected error flags (ov=%0b fe=%0b pe=%0b)",
                                  $time, cfg_name[idx], i, ov, fe, pe);
                    end
                end
            end
        join

        errors += mismatches;
        check(mismatches == 0, $sformatf("[%s] streaming test of %0d bytes had failures (see above)", cfg_name[idx], n));
    endtask

    task automatic overrun_test(input int idx);
        logic [DATA_BITS-1:0] byte1, byte2;
        bit got, overrun, framing_err, parity_err;
        logic [DATA_BITS-1:0] rdata;

        byte1 = 8'hAA;
        byte2 = 8'h55;

        // Send two bytes back-to-back with no reads in between.
        tx_send(idx, byte1);
        tx_send(idx, byte2);

        // Give both frames plenty of time to land in the holding register
        // (2nd overwrites 1st) before we look.
        repeat (frame_clks(cfg_parity_en[idx], 1) * 3) @(posedge clk_i);

        check(rx_valid_o[idx], $sformatf("[%s] overrun test: rx_valid_o not set after two unacked bytes", cfg_name[idx]));
        check(rx_overrun_o[idx], $sformatf("[%s] overrun test: rx_overrun_o not set after byte2 overwrote unread byte1", cfg_name[idx]));
        check(rx_rdata_o[idx] == byte2, $sformatf("[%s] overrun test: rx_rdata_o=0x%0h, expected byte2=0x%0h",
                                                    cfg_name[idx], rx_rdata_o[idx], byte2));

        // Ack it; overrun + valid must clear together.
        rx_rd_en_i[idx] <= 1'b1;
        @(posedge clk_i);
        rx_rd_en_i[idx] <= 1'b0;
        @(posedge clk_i);
        check(!rx_valid_o[idx], $sformatf("[%s] overrun test: rx_valid_o didn't clear after ack", cfg_name[idx]));
        check(!rx_overrun_o[idx], $sformatf("[%s] overrun test: rx_overrun_o didn't clear after ack", cfg_name[idx]));

        // Confirm the link is still healthy afterward.
        round_trip(idx, 8'h42);
    endtask

    initial begin
        for (int c = 0; c < NUM_CFG; c++) begin
            tx_wdata_i[c] = '0;
            tx_wr_en_i[c] = 1'b0;
            rx_rd_en_i[c] = 1'b0;
        end

        rst_ni = 0;
        repeat (5) @(posedge clk_i);
        for (int c = 0; c < NUM_CFG; c++) begin
            check(tx_ready_o[c], $sformatf("[%s] tx_ready_o not high out of reset", cfg_name[c]));
            check(!tx_busy_o[c], $sformatf("[%s] tx_busy_o high out of reset", cfg_name[c]));
            check(!rx_valid_o[c], $sformatf("[%s] rx_valid_o high out of reset", cfg_name[c]));
            check(!rx_busy_o[c], $sformatf("[%s] rx_busy_o high out of reset", cfg_name[c]));
            check(!rx_overrun_o[c], $sformatf("[%s] rx_overrun_o high out of reset", cfg_name[c]));
        end

        rst_ni = 1;
        repeat (5) @(posedge clk_i);

        $display("--- single-byte round trips ---");
        for (int c = 0; c < NUM_CFG; c++) begin
            round_trip(c, 8'h00);
            round_trip(c, 8'hFF);
            round_trip(c, 8'hA5);
            repeat (3) round_trip(c, $urandom_range(0, 255));
        end

        $display("--- back-to-back streaming ---");
        for (int c = 0; c < NUM_CFG; c++) streaming_test(c, 20);

        $display("--- overrun handling ---");
        for (int c = 0; c < NUM_CFG; c++) overrun_test(c);

        if (errors == 0) $display("=== tb_uart_top: PASS ===");
        else begin
            $display("=== tb_uart_top: FAIL (%0d error(s)) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * frame_clks(1'b1, 1) * 400);
        $display("[FAIL] %0t: watchdog timeout", $time);
        $fatal(1);
    end

endmodule
