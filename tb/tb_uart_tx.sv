// -----------------------------------------------------------------------------
// File        : tb_uart_tx.sv
// Description : Self-checking unit testbench for uart_tx. Drives baud_tick_i
//               directly at a fixed, TB-controlled rate (no baud_rate_gen
//               needed) and decodes the tx_o serial waveform bit-by-bit,
//               independent of any RX module, to cross-check against the
//               byte that was written in.
//
//               Covers four parameter configurations in parallel DUT
//               instances: no-parity/1-stop, even-parity/1-stop,
//               odd-parity/1-stop, no-parity/2-stop.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_uart_tx;

    localparam int DATA_BITS      = 8;
    localparam int CLK_PERIOD     = 10;  // ns
    localparam int BAUD_TICK_DIV  = 8;   // clk cycles per bit period (fast sim)

    logic clk_i  = 0;
    logic rst_ni = 0;

    always #(CLK_PERIOD/2) clk_i = ~clk_i;

    // Free-running baud_tick_i, shared by all DUT instances.
    logic baud_tick_i;
    int   tick_cnt;
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            tick_cnt    <= 0;
            baud_tick_i <= 1'b0;
        end else if (tick_cnt == BAUD_TICK_DIV - 1) begin
            tick_cnt    <= 0;
            baud_tick_i <= 1'b1;
        end else begin
            tick_cnt    <= tick_cnt + 1;
            baud_tick_i <= 1'b0;
        end
    end

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("[FAIL] %0t: %s", $time, msg);
        end
    endtask

    // ---- Generic driver/checker, instantiated once per DUT config ----
    localparam int NUM_CFG = 4;

    logic [DATA_BITS-1:0] tx_data_i  [NUM_CFG];
    logic                 tx_valid_i [NUM_CFG];
    logic                 tx_ready_o [NUM_CFG];
    logic                 tx_o       [NUM_CFG];
    logic                 tx_busy_o  [NUM_CFG];

    // cfg 0: no parity,  1 stop
    uart_tx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(1)) dut0 (
        .clk_i(clk_i), .rst_ni(rst_ni), .baud_tick_i(baud_tick_i),
        .tx_data_i(tx_data_i[0]), .tx_valid_i(tx_valid_i[0]), .tx_ready_o(tx_ready_o[0]),
        .tx_o(tx_o[0]), .tx_busy_o(tx_busy_o[0])
    );
    // cfg 1: even parity, 1 stop
    uart_tx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b1), .PARITY_ODD(1'b0), .STOP_BITS(1)) dut1 (
        .clk_i(clk_i), .rst_ni(rst_ni), .baud_tick_i(baud_tick_i),
        .tx_data_i(tx_data_i[1]), .tx_valid_i(tx_valid_i[1]), .tx_ready_o(tx_ready_o[1]),
        .tx_o(tx_o[1]), .tx_busy_o(tx_busy_o[1])
    );
    // cfg 2: odd parity, 1 stop
    uart_tx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b1), .PARITY_ODD(1'b1), .STOP_BITS(1)) dut2 (
        .clk_i(clk_i), .rst_ni(rst_ni), .baud_tick_i(baud_tick_i),
        .tx_data_i(tx_data_i[2]), .tx_valid_i(tx_valid_i[2]), .tx_ready_o(tx_ready_o[2]),
        .tx_o(tx_o[2]), .tx_busy_o(tx_busy_o[2])
    );
    // cfg 3: no parity, 2 stop
    uart_tx #(.DATA_BITS(DATA_BITS), .PARITY_EN(1'b0), .PARITY_ODD(1'b0), .STOP_BITS(2)) dut3 (
        .clk_i(clk_i), .rst_ni(rst_ni), .baud_tick_i(baud_tick_i),
        .tx_data_i(tx_data_i[3]), .tx_valid_i(tx_valid_i[3]), .tx_ready_o(tx_ready_o[3]),
        .tx_o(tx_o[3]), .tx_busy_o(tx_busy_o[3])
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
        cfg_parity_en[0]  = 1'b0; cfg_parity_odd[0] = 1'b0; cfg_stop_bits[0] = 1; cfg_name[0] = "no-parity/1-stop";
        cfg_parity_en[1]  = 1'b1; cfg_parity_odd[1] = 1'b0; cfg_stop_bits[1] = 1; cfg_name[1] = "even-parity/1-stop";
        cfg_parity_en[2]  = 1'b1; cfg_parity_odd[2] = 1'b1; cfg_stop_bits[2] = 1; cfg_name[2] = "odd-parity/1-stop";
        cfg_parity_en[3]  = 1'b0; cfg_parity_odd[3] = 1'b0; cfg_stop_bits[3] = 2; cfg_name[3] = "no-parity/2-stop";
    end

    // Send one byte into cfg `idx` and decode the resulting serial frame,
    // checking it against expectations for that configuration.
    task automatic send_and_check(input int idx, input logic [DATA_BITS-1:0] data);
        int total_bits;
        logic bits_captured [$];
        logic [DATA_BITS-1:0] rx_byte;
        logic exp_parity;
        int i;

        bits_captured.delete();
        total_bits = 1 + DATA_BITS + (cfg_parity_en[idx] ? 1 : 0) + cfg_stop_bits[idx];

        // Wait until ready, then issue a one-cycle write handshake.
        @(posedge clk_i);
        while (!tx_ready_o[idx]) @(posedge clk_i);
        // Nonblocking, not just stylistic: guarantees the DUT's always_ff
        // sees this pulse regardless of process scheduling order, rather
        // than relying on it happening to win a same-edge race.
        tx_data_i[idx]  <= data;
        tx_valid_i[idx] <= 1'b1;
        @(posedge clk_i);
        tx_valid_i[idx] <= 1'b0;
        #1; // let the DUT's registered outputs settle before reading them

        check(tx_busy_o[idx] || tx_ready_o[idx] == 1'b0, "tx_busy_o/tx_ready_o didn't reflect the accepted byte");

        // Capture one bit per baud_tick_i pulse, starting with the tick that
        // drives the start bit onto the line.
        for (i = 0; i < total_bits; i++) begin
            @(posedge clk_i);
            while (!baud_tick_i) @(posedge clk_i);
            #1; // let the registered tx_o settle after this edge
            bits_captured.push_back(tx_o[idx]);
        end

        check(bits_captured[0] == 1'b0, $sformatf("[%s] start bit was not 0", cfg_name[idx]));

        rx_byte = '0;
        for (i = 0; i < DATA_BITS; i++) begin
            rx_byte[i] = bits_captured[1 + i];
        end
        check(rx_byte == data,
              $sformatf("[%s] decoded data 0x%0h != expected 0x%0h", cfg_name[idx], rx_byte, data));

        if (cfg_parity_en[idx]) begin
            exp_parity = ^data ^ cfg_parity_odd[idx];
            check(bits_captured[1 + DATA_BITS] == exp_parity,
                  $sformatf("[%s] parity bit %b != expected %b", cfg_name[idx],
                            bits_captured[1 + DATA_BITS], exp_parity));
        end

        for (i = 0; i < cfg_stop_bits[idx]; i++) begin
            int stop_idx = 1 + DATA_BITS + (cfg_parity_en[idx] ? 1 : 0) + i;
            check(bits_captured[stop_idx] == 1'b1,
                  $sformatf("[%s] stop bit #%0d was not 1", cfg_name[idx], i));
        end

        // Line should return to / stay at idle-high once framing completes.
        @(posedge clk_i);
        while (!baud_tick_i) @(posedge clk_i);
        #1;
        check(tx_o[idx] == 1'b1, $sformatf("[%s] line not idle-high after frame", cfg_name[idx]));
    endtask

    initial begin
        for (int c = 0; c < NUM_CFG; c++) begin
            tx_data_i[c]  = '0;
            tx_valid_i[c] = 1'b0;
        end

        rst_ni = 0;
        repeat (3) @(posedge clk_i);
        rst_ni = 1;
        repeat (2) @(posedge clk_i);

        for (int c = 0; c < NUM_CFG; c++) begin
            check(tx_o[c] == 1'b1, $sformatf("[%s] line not idle-high out of reset", cfg_name[c]));
            check(tx_ready_o[c] == 1'b1, $sformatf("[%s] tx_ready_o not high out of reset", cfg_name[c]));
        end

        // Directed values covering edge patterns, plus a couple of random bytes,
        // sent through every configuration.
        begin
            logic [7:0] vectors [6];
            vectors[0] = 8'h00; vectors[1] = 8'hFF; vectors[2] = 8'hA5;
            vectors[3] = 8'h01; vectors[4] = 8'h80; vectors[5] = 8'h55;
            for (int c = 0; c < NUM_CFG; c++) begin
                foreach (vectors[v]) send_and_check(c, vectors[v]);
                repeat (3) send_and_check(c, $urandom_range(0, 255));
            end
        end

        // Back-to-back sends (write next byte the instant tx_ready_o is high
        // again) on cfg 0, to exercise the loaded_q pipelining path.
        for (int i = 0; i < 5; i++) send_and_check(0, 8'h10 + i);

        if (errors == 0) $display("=== tb_uart_tx: PASS ===");
        else begin
            $display("=== tb_uart_tx: FAIL (%0d error(s)) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * BAUD_TICK_DIV * 200 * 60);
        $display("[FAIL] %0t: watchdog timeout", $time);
        $fatal(1);
    end

endmodule
