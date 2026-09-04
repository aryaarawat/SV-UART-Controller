// -----------------------------------------------------------------------------
// File        : tb_uart_apb.sv
// Description : Self-checking testbench for uart_apb. Drives the DUT through
//               the actual APB4 SETUP/ACCESS handshake (not the underlying
//               uart_top ports directly) with tx_o looped back to rx_i.
//               Covers:
//                 - reset state, read via STATUS
//                 - a byte round trip via TXDATA write + RXDATA read
//                 - PSLVERR on writing TXDATA while the TX FIFO is full
//                   (and that the accepted bytes still arrive correctly)
//                 - PSLVERR on reading RXDATA while the RX FIFO is empty
//                 - PSLVERR on writing a read-only register (RXDATA/STATUS)
//                 - PSLVERR on an access to an unmapped offset
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_uart_apb;

    localparam int DATA_BITS      = 8;
    localparam int CLK_FREQ_HZ    = 50_000_000;
    localparam int BAUD_RATE      = 115_200;
    localparam int OVERSAMPLE     = 16;
    localparam int TX_FIFO_DEPTH_TB = 4;
    localparam int RX_FIFO_DEPTH_TB = 4;
    localparam int PDATA_WIDTH    = 32;
    localparam int ADDR_WIDTH     = 4;
    localparam int CLK_PERIOD     = 20; // ns (50 MHz, matches CLK_FREQ_HZ)

    // Mirrors baud_rate_gen's own round-to-nearest divisor calc.
    localparam int DIVISOR_X16     = (CLK_FREQ_HZ + (BAUD_RATE * OVERSAMPLE) / 2) / (BAUD_RATE * OVERSAMPLE);
    localparam int BIT_PERIOD_CLKS = DIVISOR_X16 * OVERSAMPLE;
    localparam int FRAME_CLKS      = BIT_PERIOD_CLKS * (1 + DATA_BITS + 1); // no parity, 1 stop

    localparam logic [ADDR_WIDTH-1:0] ADDR_TXDATA = 'h0;
    localparam logic [ADDR_WIDTH-1:0] ADDR_RXDATA = 'h4;
    localparam logic [ADDR_WIDTH-1:0] ADDR_STATUS = 'h8;
    localparam logic [ADDR_WIDTH-1:0] ADDR_BOGUS  = 'hC; // unmapped

    // STATUS bit positions (mirrors uart_apb.sv's header comment).
    localparam int ST_TX_READY = 0, ST_TX_FULL = 1, ST_TX_BUSY = 2;
    localparam int ST_RX_VALID = 3, ST_RX_EMPTY = 4, ST_RX_FULL = 5, ST_RX_BUSY = 6;
    localparam int ST_RX_OVERRUN = 7, ST_RX_FRAMING = 8, ST_RX_PARITY = 9;

    logic clk_i  = 0;
    logic rst_ni = 0;

    always #(CLK_PERIOD/2) clk_i = ~clk_i;

    logic                   psel, penable, pwrite;
    logic [ADDR_WIDTH-1:0]  paddr;
    logic [PDATA_WIDTH-1:0] pwdata;
    logic [PDATA_WIDTH-1:0] prdata;
    logic                   pready, pslverr;
    logic                   serial_line;

    uart_apb #(
        .CLK_FREQ_HZ  (CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE), .DATA_BITS(DATA_BITS),
        .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(1), .OVERSAMPLE(OVERSAMPLE),
        .TX_FIFO_DEPTH(TX_FIFO_DEPTH_TB), .RX_FIFO_DEPTH(RX_FIFO_DEPTH_TB),
        .PDATA_WIDTH(PDATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite),
        .paddr_i(paddr), .pwdata_i(pwdata), .prdata_o(prdata),
        .pready_o(pready), .pslverr_o(pslverr),
        .tx_o(serial_line), .rx_i(serial_line)
    );

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("[FAIL] %0t: %s", $time, msg);
        end
    endtask

    // Drives one full APB4 SETUP+ACCESS write transfer. Nonblocking
    // assignment throughout, matching the rest of this repo's testbenches.
    //
    // pslverr_o/prdata_o must be sampled *during* the ACCESS-phase cycle,
    // not after crossing the clock edge that ends it: that edge is exactly
    // when the underlying FIFO commits its push/pop, so by the time
    // execution resumes after that @(posedge), tx_full/rx_empty/rx_rdata
    // already reflect the *post*-transfer state -- one transfer too late
    // for what this transfer's own pslverr_o/prdata_o describe.
    task automatic apb_write(input logic [ADDR_WIDTH-1:0] addr, input logic [PDATA_WIDTH-1:0] data,
                              output bit slverr);
        @(posedge clk_i);
        psel    <= 1'b1;
        penable <= 1'b0;
        pwrite  <= 1'b1;
        paddr   <= addr;
        pwdata  <= data;
        @(posedge clk_i); // end of SETUP, start of ACCESS
        penable <= 1'b1;
        #1; // let penable's new value settle through the combinational cloud
        check(pready, "pready_o not high during ACCESS (this slave never inserts wait states)");
        slverr = pslverr;
        @(posedge clk_i); // end of ACCESS -- transfer (and the FIFO push, if any) commits here
        psel    <= 1'b0;
        penable <= 1'b0;
        @(posedge clk_i);
    endtask

    // See the timing note on apb_write above -- same reasoning applies here.
    task automatic apb_read(input logic [ADDR_WIDTH-1:0] addr,
                             output logic [PDATA_WIDTH-1:0] data, output bit slverr);
        @(posedge clk_i);
        psel    <= 1'b1;
        penable <= 1'b0;
        pwrite  <= 1'b0;
        paddr   <= addr;
        @(posedge clk_i); // end of SETUP, start of ACCESS
        penable <= 1'b1;
        #1;
        check(pready, "pready_o not high during ACCESS (this slave never inserts wait states)");
        data   = prdata;
        slverr = pslverr;
        @(posedge clk_i); // end of ACCESS -- transfer (and the FIFO pop, if any) commits here
        psel    <= 1'b0;
        penable <= 1'b0;
        @(posedge clk_i);
    endtask

    task automatic read_status(output logic [PDATA_WIDTH-1:0] status, output bit slverr);
        apb_read(ADDR_STATUS, status, slverr);
    endtask

    initial begin
        logic [PDATA_WIDTH-1:0] status, rdata;
        bit slverr;

        psel = 0; penable = 0; pwrite = 0; paddr = '0; pwdata = '0;

        // ---- Reset ----
        rst_ni = 0;
        repeat (5) @(posedge clk_i);
        rst_ni = 1;
        repeat (5) @(posedge clk_i);

        read_status(status, slverr);
        check(!slverr, "STATUS read asserted pslverr_o out of reset");
        check(status[ST_TX_READY] == 1'b1, "STATUS.tx_ready not set out of reset");
        check(status[ST_TX_FULL]  == 1'b0, "STATUS.tx_full set out of reset");
        check(status[ST_TX_BUSY]  == 1'b0, "STATUS.tx_busy set out of reset");
        check(status[ST_RX_VALID] == 1'b0, "STATUS.rx_valid set out of reset");
        check(status[ST_RX_EMPTY] == 1'b1, "STATUS.rx_empty not set out of reset");
        check(status[ST_RX_FULL]  == 1'b0, "STATUS.rx_full set out of reset");
        check(status[ST_RX_BUSY]  == 1'b0, "STATUS.rx_busy set out of reset");
        check(status[ST_RX_OVERRUN] == 1'b0, "STATUS.rx_overrun set out of reset");
        check(status[31:10] == '0, "STATUS reserved bits not 0 out of reset");

        // ---- RXDATA read while empty must flag pslverr_o ----
        apb_read(ADDR_RXDATA, rdata, slverr);
        check(slverr, "RXDATA read while empty didn't assert pslverr_o");

        // ---- Writing a read-only register must flag pslverr_o, harmlessly ----
        apb_write(ADDR_RXDATA, 32'hDEAD_BEEF, slverr);
        check(slverr, "write to RXDATA (read-only) didn't assert pslverr_o");
        apb_write(ADDR_STATUS, 32'hDEAD_BEEF, slverr);
        check(slverr, "write to STATUS (read-only) didn't assert pslverr_o");

        // ---- Unmapped offset must flag pslverr_o ----
        apb_read(ADDR_BOGUS, rdata, slverr);
        check(slverr, "read from an unmapped offset didn't assert pslverr_o");
        apb_write(ADDR_BOGUS, 32'h0, slverr);
        check(slverr, "write to an unmapped offset didn't assert pslverr_o");

        // Confirm none of the above corrupted anything.
        read_status(status, slverr);
        check(!slverr, "STATUS read asserted pslverr_o after the error-case accesses above");
        check(status[ST_TX_READY] == 1'b1, "STATUS.tx_ready wrong after the error-case accesses above");
        check(status[ST_RX_EMPTY] == 1'b1, "STATUS.rx_empty wrong after the error-case accesses above");

        // ---- Single-byte round trip ----
        $display("--- round trip ---");
        apb_write(ADDR_TXDATA, 32'h0000_00A5, slverr);
        check(!slverr, "TXDATA write of 0xA5 unexpectedly asserted pslverr_o");

        repeat (FRAME_CLKS * 3) @(posedge clk_i);

        read_status(status, slverr);
        check(!slverr, "STATUS read asserted pslverr_o after round-trip byte arrived");
        check(status[ST_RX_VALID] == 1'b1, "STATUS.rx_valid not set after round-trip byte arrived");
        check(status[ST_RX_OVERRUN] == 1'b0, "STATUS.rx_overrun unexpectedly set after round-trip byte");

        apb_read(ADDR_RXDATA, rdata, slverr);
        check(!slverr, "RXDATA read unexpectedly asserted pslverr_o");
        check(rdata == 32'h0000_00A5, $sformatf("RXDATA=0x%0h, expected 0x000000a5", rdata));

        read_status(status, slverr);
        check(status[ST_RX_VALID] == 1'b0, "STATUS.rx_valid still set after draining the only queued byte");
        check(status[ST_RX_EMPTY] == 1'b1, "STATUS.rx_empty not set after draining the only queued byte");

        // ---- TXDATA write while full must flag pslverr_o, and drop the byte ----
        $display("--- TX FIFO full ---");
        // Fill it: TX_FIFO_DEPTH_TB+1 writes, since uart_tx's own 1-deep
        // holding register eagerly absorbs the first one (see
        // tb/tb_uart_top.sv's tx_burst_test for the same reasoning).
        for (int i = 0; i < TX_FIFO_DEPTH_TB + 1; i++) begin
            apb_write(ADDR_TXDATA, 32'h0000_00C0 + i, slverr);
            check(!slverr, $sformatf("TXDATA write #%0d unexpectedly asserted pslverr_o", i));
        end
        read_status(status, slverr);
        check(status[ST_TX_FULL] == 1'b1, "STATUS.tx_full not set after filling the TX FIFO");

        apb_write(ADDR_TXDATA, 32'h0000_00FF, slverr);
        check(slverr, "TXDATA write while full didn't assert pslverr_o");

        // Drain RX and confirm exactly the accepted bytes arrive, in order
        // (0xFF above was dropped, not queued).
        for (int i = 0; i < TX_FIFO_DEPTH_TB + 1; i++) begin
            repeat (FRAME_CLKS * 3) @(posedge clk_i);
            read_status(status, slverr);
            check(status[ST_RX_VALID] == 1'b1, $sformatf("byte #%0d never arrived", i));
            apb_read(ADDR_RXDATA, rdata, slverr);
            check(!slverr, $sformatf("RXDATA read #%0d unexpectedly asserted pslverr_o", i));
            check(rdata == (32'h0000_00C0 + i),
                  $sformatf("RXDATA=0x%0h, expected 0x%0h", rdata, 32'h0000_00C0 + i));
        end
        read_status(status, slverr);
        check(status[ST_RX_EMPTY] == 1'b1, "RX FIFO not empty after draining exactly the accepted bytes");

        if (errors == 0) $display("=== tb_uart_apb: PASS ===");
        else begin
            $display("=== tb_uart_apb: FAIL (%0d error(s)) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * FRAME_CLKS * 100);
        $display("[FAIL] %0t: watchdog timeout", $time);
        $fatal(1);
    end

endmodule
