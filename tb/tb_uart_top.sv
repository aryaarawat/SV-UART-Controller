// -----------------------------------------------------------------------------
// File        : tb_uart_top.sv
// Description : Integration testbench for uart_top. Wires tx_o straight back
//               to rx_i (self-loopback) and drives the register-style
//               TX/RX interface the way a CPU would, using the real
//               baud_rate_gen (not a TB-fabricated tick). Covers:
//                 - reset state of all status signals
//                 - single-byte round trip
//                 - back-to-back streaming with in-order data integrity
//                 - TX FIFO fill: bursting more bytes than fit in one frame
//                   period and confirming tx_full_o/tx_ready_o track it
//                 - RX FIFO fill + genuine overrun: sending exactly
//                   RX_FIFO_DEPTH_TB bytes with no reads fills it without
//                   loss, and the FIFO-first-byte behaves correctly; one
//                   more byte overflows it (rx_overrun_o) and is the one
//                   that's dropped -- the earlier queued bytes are not
//                   overwritten, unlike the old single-register design
//                 - a full loopback pass with parity enabled
//
//               Both DUT instances below override TX_FIFO_DEPTH/
//               RX_FIFO_DEPTH down to a small depth (rather than uart_top's
//               own default of 16) purely so the FIFO-boundary tests above
//               don't need to burst dozens of bytes to reach "full".
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

    // Small on purpose -- see the file header comment above.
    localparam int TX_FIFO_DEPTH_TB = 4;
    localparam int RX_FIFO_DEPTH_TB = 4;

    logic [DATA_BITS-1:0] tx_wdata_i     [NUM_CFG];
    logic                 tx_wr_en_i     [NUM_CFG];
    logic                 tx_ready_o     [NUM_CFG];
    logic                 tx_full_o      [NUM_CFG];
    logic                 tx_busy_o      [NUM_CFG];
    logic [DATA_BITS-1:0] rx_rdata_o     [NUM_CFG];
    logic                 rx_valid_o     [NUM_CFG];
    logic                 rx_rd_en_i     [NUM_CFG];
    logic                 rx_empty_o     [NUM_CFG];
    logic                 rx_full_o      [NUM_CFG];
    logic                 rx_busy_o      [NUM_CFG];
    logic                 rx_overrun_o   [NUM_CFG];
    logic                 rx_framing_err_o [NUM_CFG];
    logic                 rx_parity_err_o  [NUM_CFG];
    logic                 serial_line    [NUM_CFG]; // tx_o looped back to rx_i

    uart_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .DATA_BITS(DATA_BITS),
        .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH_TB), .RX_FIFO_DEPTH(RX_FIFO_DEPTH_TB)
    ) dut0 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .tx_o(serial_line[0]), .rx_i(serial_line[0]),
        .tx_wdata_i(tx_wdata_i[0]), .tx_wr_en_i(tx_wr_en_i[0]),
        .tx_ready_o(tx_ready_o[0]), .tx_full_o(tx_full_o[0]), .tx_busy_o(tx_busy_o[0]),
        .rx_rdata_o(rx_rdata_o[0]), .rx_valid_o(rx_valid_o[0]), .rx_rd_en_i(rx_rd_en_i[0]),
        .rx_empty_o(rx_empty_o[0]), .rx_full_o(rx_full_o[0]),
        .rx_busy_o(rx_busy_o[0]), .rx_overrun_o(rx_overrun_o[0]),
        .rx_framing_err_o(rx_framing_err_o[0]), .rx_parity_err_o(rx_parity_err_o[0])
    );

    uart_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .DATA_BITS(DATA_BITS),
        .PARITY_EN(1'b1), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH_TB), .RX_FIFO_DEPTH(RX_FIFO_DEPTH_TB)
    ) dut1 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .tx_o(serial_line[1]), .rx_i(serial_line[1]),
        .tx_wdata_i(tx_wdata_i[1]), .tx_wr_en_i(tx_wr_en_i[1]),
        .tx_ready_o(tx_ready_o[1]), .tx_full_o(tx_full_o[1]), .tx_busy_o(tx_busy_o[1]),
        .rx_rdata_o(rx_rdata_o[1]), .rx_valid_o(rx_valid_o[1]), .rx_rd_en_i(rx_rd_en_i[1]),
        .rx_empty_o(rx_empty_o[1]), .rx_full_o(rx_full_o[1]),
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
        #1; // let the TX FIFO's own always_ff (tx_ready_o/tx_full_o/tx_busy_o)
            // settle before a caller reads them right after this returns
    endtask

    // Waits for rx_valid_o, captures the byte + error flags, then acks it.
    task automatic rx_recv(input int idx, input int max_cycles,
                            output bit got, output logic [DATA_BITS-1:0] data,
                            output bit overrun, output bit framing_err, output bit parity_err);
        // Loop condition carries the exit, rather than "break" -- unsupported
        // on older Icarus Verilog.
        got = 1'b0;
        for (int c = 0; c < max_cycles && !got; c++) begin
            @(posedge clk_i);
            if (rx_valid_o[idx]) begin
                got         = 1'b1;
                data        = rx_rdata_o[idx];
                overrun     = rx_overrun_o[idx];
                framing_err = rx_framing_err_o[idx];
                parity_err  = rx_parity_err_o[idx];
            end
        end
        if (got) begin
            rx_rd_en_i[idx] <= 1'b1;
            @(posedge clk_i);
            rx_rd_en_i[idx] <= 1'b0;
            #1; // let the RX FIFO's own always_ff (rx_empty_o/rx_full_o)
                // settle before a caller reads them right after this returns
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
                    end else begin
                        // "else" rather than an early "continue" -- unsupported
                        // on older Icarus Verilog.
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
            end
        join

        errors += mismatches;
        check(mismatches == 0, $sformatf("[%s] streaming test of %0d bytes had failures (see above)", cfg_name[idx], n));
    endtask

    // Fills the TX FIFO faster than any byte can finish transmitting (each
    // write takes ~1-2 cycles; one full UART frame takes thousands),
    // confirms tx_full_o/tx_ready_o/tx_busy_o track that, then drains RX
    // and confirms every byte still arrives correctly.
    //
    // Writes TX_FIFO_DEPTH_TB+1 bytes, not TX_FIFO_DEPTH_TB: uart_tx has its
    // own 1-deep internal holding register (loaded_q) that eagerly pulls
    // the first byte out of the FIFO the moment it's written (well before
    // any baud tick), so the FIFO itself only actually reaches "full" once
    // one extra byte is queued behind that.
    task automatic tx_burst_test(input int idx);
        logic [DATA_BITS-1:0] expected [$];
        logic [DATA_BITS-1:0] b, exp_b;
        bit got, ov, fe, pe;
        int n;

        n = TX_FIFO_DEPTH_TB + 1;
        check(!tx_full_o[idx], $sformatf("[%s] tx_burst: tx_full_o set before the burst started", cfg_name[idx]));
        expected.delete();

        for (int i = 0; i < n; i++) begin
            b = 8'hC0 + i;
            expected.push_back(b);
            tx_send(idx, b);
        end

        check(tx_full_o[idx], $sformatf("[%s] tx_burst: tx_full_o not set after filling the TX FIFO", cfg_name[idx]));
        check(!tx_ready_o[idx], $sformatf("[%s] tx_burst: tx_ready_o still high while the TX FIFO is full", cfg_name[idx]));
        check(tx_busy_o[idx], $sformatf("[%s] tx_burst: tx_busy_o not set while the TX FIFO has queued work", cfg_name[idx]));

        for (int i = 0; i < n; i++) begin
            rx_recv(idx, frame_clks(cfg_parity_en[idx], 1) * 3, got, b, ov, fe, pe);
            check(got, $sformatf("[%s] tx_burst: byte #%0d never arrived", cfg_name[idx], i));
            if (got) begin
                exp_b = expected.pop_front();
                check(b == exp_b, $sformatf("[%s] tx_burst: byte #%0d = 0x%0h, expected 0x%0h", cfg_name[idx], i, b, exp_b));
                check(!(ov || fe || pe), $sformatf("[%s] tx_burst: byte #%0d unexpected error flags", cfg_name[idx], i));
            end
        end

        check(!tx_full_o[idx], $sformatf("[%s] tx_burst: tx_full_o still set after everything drained", cfg_name[idx]));
    endtask

    // Fills the RX FIFO to exactly RX_FIFO_DEPTH_TB bytes with no reads in
    // between -- none of them should be lost. One more byte then overflows
    // it: that byte (the new arrival, not anything already queued) is the
    // one that's dropped, which is the real behavioral difference from the
    // old single-register design this replaced.
    task automatic rx_overrun_test(input int idx);
        logic [DATA_BITS-1:0] queued [$];
        logic [DATA_BITS-1:0] seed_byte, overflow_byte, got_data, exp_b;
        bit got, ov, fe, pe;

        queued.delete();
        check(rx_empty_o[idx], $sformatf("[%s] rx_overrun: RX FIFO not empty before the test started", cfg_name[idx]));

        for (int i = 0; i < RX_FIFO_DEPTH_TB; i++) begin
            seed_byte = 8'h80 + i;
            queued.push_back(seed_byte);
            tx_send(idx, seed_byte);
        end
        // Give all RX_FIFO_DEPTH_TB frames time to fully land.
        repeat (frame_clks(cfg_parity_en[idx], 1) * (RX_FIFO_DEPTH_TB + 2)) @(posedge clk_i);

        check(rx_full_o[idx], $sformatf("[%s] rx_overrun: RX FIFO not full after %0d unread bytes", cfg_name[idx], RX_FIFO_DEPTH_TB));
        check(!rx_overrun_o[idx], $sformatf("[%s] rx_overrun: rx_overrun_o set before the FIFO actually overflowed", cfg_name[idx]));

        // One more, with the FIFO already full -- this one has nowhere to go.
        overflow_byte = 8'hFE;
        tx_send(idx, overflow_byte);
        repeat (frame_clks(cfg_parity_en[idx], 1) * 2) @(posedge clk_i);

        check(rx_overrun_o[idx], $sformatf("[%s] rx_overrun: rx_overrun_o not set after the RX FIFO overflowed", cfg_name[idx]));
        check(rx_full_o[idx], $sformatf("[%s] rx_overrun: RX FIFO unexpectedly not full right after overflow", cfg_name[idx]));

        // Drain; the FIFO should hold exactly the original queued bytes, in
        // order -- proof the overflow byte was dropped, not that it
        // overwrote something already queued.
        for (int i = 0; i < RX_FIFO_DEPTH_TB; i++) begin
            rx_recv(idx, frame_clks(cfg_parity_en[idx], 1) * 3, got, got_data, ov, fe, pe);
            check(got, $sformatf("[%s] rx_overrun: queued byte #%0d never came back", cfg_name[idx], i));
            if (got) begin
                exp_b = queued.pop_front();
                check(got_data == exp_b, $sformatf("[%s] rx_overrun: queued byte #%0d = 0x%0h, expected 0x%0h",
                                                     cfg_name[idx], i, got_data, exp_b));
            end
        end

        check(rx_empty_o[idx], $sformatf("[%s] rx_overrun: RX FIFO not empty after draining exactly %0d bytes",
                                          cfg_name[idx], RX_FIFO_DEPTH_TB));
        check(!rx_overrun_o[idx], $sformatf("[%s] rx_overrun: rx_overrun_o didn't clear after draining", cfg_name[idx]));

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
            check(!tx_full_o[c], $sformatf("[%s] tx_full_o high out of reset", cfg_name[c]));
            check(!tx_busy_o[c], $sformatf("[%s] tx_busy_o high out of reset", cfg_name[c]));
            check(!rx_valid_o[c], $sformatf("[%s] rx_valid_o high out of reset", cfg_name[c]));
            check(rx_empty_o[c], $sformatf("[%s] rx_empty_o not high out of reset", cfg_name[c]));
            check(!rx_full_o[c], $sformatf("[%s] rx_full_o high out of reset", cfg_name[c]));
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

        $display("--- TX FIFO fill ---");
        for (int c = 0; c < NUM_CFG; c++) tx_burst_test(c);

        $display("--- RX FIFO fill + overrun ---");
        for (int c = 0; c < NUM_CFG; c++) rx_overrun_test(c);

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
