// -----------------------------------------------------------------------------
// File        : tb_fifo.sv
// Description : Self-checking unit testbench for the generic fifo module.
//               Covers: reset state, fill-to-full + verifying an extra push
//               while full is safely dropped, drain-to-empty + verifying an
//               extra pop while empty is safely a no-op, simultaneous
//               push+pop steady-state behavior, and a randomized
//               push/pop stress run cross-checked against a software-model
//               queue every cycle (data order, count_o, full_o/empty_o).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_fifo;

    localparam int DATA_WIDTH = 8;
    localparam int DEPTH      = 4;
    localparam int CLK_PERIOD = 10;
    localparam int COUNT_W    = $clog2(DEPTH + 1);

    logic clk_i  = 0;
    logic rst_ni = 0;

    logic wr_en_i;
    logic [DATA_WIDTH-1:0] wr_data_i;
    logic full_o;

    logic rd_en_i;
    logic [DATA_WIDTH-1:0] rd_data_o;
    logic empty_o;

    logic [COUNT_W-1:0] count_o;

    fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (DEPTH)
    ) dut (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .wr_en_i   (wr_en_i),
        .wr_data_i (wr_data_i),
        .full_o    (full_o),
        .rd_en_i   (rd_en_i),
        .rd_data_o (rd_data_o),
        .empty_o   (empty_o),
        .count_o   (count_o)
    );

    always #(CLK_PERIOD/2) clk_i = ~clk_i;

    int errors = 0;
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("[FAIL] %0t: %s", $time, msg);
        end
    endtask

    task automatic idle_cycle();
        wr_en_i = 1'b0;
        rd_en_i = 1'b0;
        @(posedge clk_i);
    endtask

    // Push one entry (assumes !full_o); returns after the write has landed
    // and DUT outputs have settled (see the #1 note below).
    task automatic push(input logic [DATA_WIDTH-1:0] data);
        wr_data_i = data;
        wr_en_i   = 1'b1;
        rd_en_i   = 1'b0;
        @(posedge clk_i);
        wr_en_i = 1'b0;
        #1; // let count_o/full_o/empty_o (driven by a separate always_ff)
            // settle before a caller reads them right after this returns
    endtask

    // Pop one entry (assumes !empty_o); checks rd_data_o against `expected`
    // before popping, since this is a first-word-fall-through FIFO.
    task automatic pop_and_check(input logic [DATA_WIDTH-1:0] expected);
        check(rd_data_o == expected,
              $sformatf("pop: rd_data_o=0x%0h, expected head=0x%0h", rd_data_o, expected));
        rd_en_i = 1'b1;
        wr_en_i = 1'b0;
        @(posedge clk_i);
        rd_en_i = 1'b0;
        #1;
    endtask

    initial begin
        wr_en_i = 0; rd_en_i = 0; wr_data_i = '0;

        // ---- Reset ----
        rst_ni = 0;
        repeat (3) @(posedge clk_i);
        #1;
        check(empty_o && !full_o && count_o == 0, "FIFO not idle-empty out of reset");
        rst_ni = 1;
        @(posedge clk_i);

        // ---- Fill to full, in order ----
        for (int i = 0; i < DEPTH; i++) begin
            check(!full_o, $sformatf("full_o asserted early, before pushing entry #%0d", i));
            push(8'h10 + i);
        end
        check(full_o, "full_o not asserted after pushing DEPTH entries");
        check(count_o == DEPTH, $sformatf("count_o=%0d, expected DEPTH=%0d", count_o, DEPTH));

        // ---- Push while full must be silently dropped ----
        push(8'hFF); // should have no effect
        check(full_o, "full_o dropped after an over-push");
        check(count_o == DEPTH, "count_o changed after a push while full");

        // ---- Drain to empty, confirming FIFO order (0x10, 0x11, 0x12, 0x13) ----
        for (int i = 0; i < DEPTH; i++) begin
            check(!empty_o, $sformatf("empty_o asserted early, before popping entry #%0d", i));
            pop_and_check(8'h10 + i);
        end
        check(empty_o, "empty_o not asserted after draining DEPTH entries");
        check(count_o == 0, $sformatf("count_o=%0d, expected 0", count_o));

        // ---- Pop while empty must be a safe no-op ----
        rd_en_i = 1'b1;
        @(posedge clk_i);
        rd_en_i = 1'b0;
        #1;
        check(empty_o && count_o == 0, "pop while empty corrupted FIFO state");
        // Confirm a fresh push right after still lands correctly (no stale
        // read-pointer corruption from the spurious pop above).
        push(8'hAB);
        pop_and_check(8'hAB);
        check(empty_o, "FIFO not empty after single push+pop round trip");

        // ---- Simultaneous push+pop steady-state: fill to DEPTH-1, then
        //      push+pop together for a while; count should hold steady and
        //      FIFO order should still track exactly. ----
        for (int i = 0; i < DEPTH - 1; i++) push(8'h20 + i);
        check(count_o == DEPTH - 1, "count_o wrong before steady-state push/pop");
        begin
            logic [DATA_WIDTH-1:0] expected_q [$];
            logic [DATA_WIDTH-1:0] new_byte;
            logic [DATA_WIDTH-1:0] seed_byte;
            logic [DATA_WIDTH-1:0] head; // holds expected_q[0] -- see note below
            for (int i = 0; i < DEPTH - 1; i++) begin
                // Assigned to a plain variable first, rather than
                // push_back(8'h20 + i) directly -- with a DUT present,
                // Icarus Verilog crashes (the same internal assertion noted
                // above) on a queue push_back() call whose argument is a
                // computed expression referencing the loop variable.
                seed_byte = 8'h20 + i;
                expected_q.push_back(seed_byte);
            end

            for (int i = 0; i < 10; i++) begin
                new_byte = 8'h40 + i;
                // Read the live queue index into a plain variable before
                // passing it into check()/$sformatf -- with a DUT present,
                // Icarus Verilog crashes (an internal "pop_value"/"wid"
                // assertion) on a queue-index expression used directly as
                // an argument nested inside a task call's $sformatf arg.
                head = expected_q[0];
                check(rd_data_o == head,
                      $sformatf("steady-state: rd_data_o=0x%0h, expected head=0x%0h", rd_data_o, head));
                wr_data_i = new_byte;
                wr_en_i   = 1'b1;
                rd_en_i   = 1'b1;
                @(posedge clk_i);
                wr_en_i = 1'b0;
                rd_en_i = 0;
                #1;
                expected_q.push_back(new_byte);
                void'(expected_q.pop_front());
                check(count_o == DEPTH - 1, $sformatf("count_o=%0d changed during simultaneous push+pop", count_o));
            end
            // Drain what's left and confirm it matches the model exactly.
            while (expected_q.size() > 0) begin
                pop_and_check(expected_q.pop_front());
            end
            check(empty_o, "FIFO not empty after draining steady-state remainder");
        end

        // ---- Randomized push/pop stress, cross-checked against a queue
        //      model every cycle. Exercises pointer wraparound heavily
        //      since DEPTH is small relative to the iteration count. ----
        begin
            logic [DATA_WIDTH-1:0] model_q [$];
            int do_wr, do_rd;
            logic [DATA_WIDTH-1:0] wdata;
            logic [DATA_WIDTH-1:0] head; // holds model_q[0] -- see tb_fifo note above

            model_q.delete();
            for (int i = 0; i < 500; i++) begin
                do_wr = $urandom_range(0, 1) && !full_o;
                do_rd = $urandom_range(0, 1) && !empty_o;
                wdata = $urandom_range(0, 255);

                wr_en_i   = do_wr[0];
                wr_data_i = wdata;
                rd_en_i   = do_rd[0];

                if (!empty_o) begin
                    head = model_q[0];
                    check(rd_data_o == head,
                          $sformatf("stress[%0d]: rd_data_o=0x%0h, expected head=0x%0h", i, rd_data_o, head));
                end

                @(posedge clk_i);
                wr_en_i = 1'b0;
                rd_en_i = 1'b0;
                #1;

                if (do_rd) void'(model_q.pop_front());
                if (do_wr) model_q.push_back(wdata);

                check(count_o == model_q.size(),
                      $sformatf("stress[%0d]: count_o=%0d, expected %0d", i, count_o, model_q.size()));
                check(empty_o == (model_q.size() == 0), $sformatf("stress[%0d]: empty_o mismatch", i));
                check(full_o == (model_q.size() == DEPTH), $sformatf("stress[%0d]: full_o mismatch", i));
            end

            // Drain and confirm final order matches the model exactly.
            while (model_q.size() > 0) begin
                pop_and_check(model_q.pop_front());
            end
        end

        if (errors == 0) $display("=== tb_fifo: PASS ===");
        else begin
            $display("=== tb_fifo: FAIL (%0d error(s)) ===", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 20000);
        $display("[FAIL] %0t: watchdog timeout", $time);
        $fatal(1);
    end

endmodule
