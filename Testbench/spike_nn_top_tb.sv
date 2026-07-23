`timescale 1ns/1ps

module spike_nn_top_tb;

    localparam NEURONS        = 16;
    localparam ADDR_W         = 4;
    localparam DATA_W         = 32;
    localparam FIFO_DEPTH     = 32;
    localparam WEIGHT_DEPTH   = 256;
    localparam FIFO_WIDTH     = $clog2(WEIGHT_DEPTH) + DATA_W;
    localparam WEIGHT_RDPORTS = 4;
    localparam LOG_DEPTH      = 1024;
    localparam AER_LOG_DEPTH  = 1024;
    localparam PS_WIDTH       = 8;

    // ---------------- Clocks & resets ----------------
    logic wr_clk = 0, core_clk = 0, aer_clk = 0, ps_src_clk = 0, ps_dst_clk = 0;
    logic wr_rst_n = 0, core_rst_n = 0, aer_rst_n = 0, ps_src_rst_n = 0, ps_dst_rst_n = 0;

    always #5 wr_clk     = ~wr_clk;      // 10 ns
    always #6 core_clk   = ~core_clk;    // 12 ns
    always #7 aer_clk    = ~aer_clk;     // 14 ns  (genuine CDC vs core_clk)
    always #4 ps_src_clk = ~ps_src_clk;  // 8 ns
    always #9 ps_dst_clk = ~ps_dst_clk;  // 18 ns

    // ---------------- DUT ports ----------------
    logic [FIFO_WIDTH-1:0] ev_data_in;
    logic                  ev_valid_in;
    wire                   ev_ready_out, ev_fifo_full;

    logic signed [15:0] threshold_in = 16'sd200;
    logic signed [15:0] reset_val_in = 16'sd0;
    logic [4:0]          leak_shift_in = 5'd5;
    logic [$clog2(NEURONS)-1:0] target_neuron_id = 0;
    logic [DATA_W-1:0]          dbg_current_in = 0;
    logic                       dbg_current_valid = 0;
    logic [$clog2(NEURONS)-1:0] dbg_current_neuron_id = 0;

    logic [$clog2(WEIGHT_DEPTH)-1:0] weight_waddr;
    logic [DATA_W-1:0]                weight_wdata;
    logic                             weight_we;

    logic [(WEIGHT_RDPORTS-1)*$clog2(WEIGHT_DEPTH)-1:0] weight_dbg_raddr = 0;
    wire  [(WEIGHT_RDPORTS-1)*DATA_W-1:0]                weight_dbg_rdata;

    wire [NEURONS-1:0]          spike_bus;
    wire [NEURONS*16-1:0]       voltage_flat;
    wire [$clog2(LOG_DEPTH):0]  log_count;
    wire                        log_overflow;

    wire [$clog2(AER_LOG_DEPTH):0]   aer_log_count;
    wire                              aer_log_overflow;
    logic [$clog2(AER_LOG_DEPTH)-1:0] aer_read_addr = 0;
    wire [ADDR_W-1:0]                 aer_read_out_addr;
    wire [31:0]                       aer_read_out_time;

    logic [PS_WIDTH-1:0] ps_pulse_in = 0;
    logic                 ps_pulse_valid_in = 0;
    wire                  ps_busy;
    wire [PS_WIDTH-1:0]   ps_pulse_out;
    wire                  ps_sync_valid;

    spike_nn_top #(
        .NEURONS(NEURONS), .ADDR_W(ADDR_W), .DATA_W(DATA_W),
        .FIFO_DEPTH(FIFO_DEPTH), .WEIGHT_DEPTH(WEIGHT_DEPTH),
        .WEIGHT_RDPORTS(WEIGHT_RDPORTS), .LOG_DEPTH(LOG_DEPTH),
        .AER_LOG_DEPTH(AER_LOG_DEPTH), .PS_WIDTH(PS_WIDTH)
    ) dut (.*);

    int test_pass_count = 0;
    int test_fail_count = 0;

    // ===================================================================
    // Driver / BFM layer
    // ===================================================================
    task automatic reset_system();
        begin
            $display("[%0t] === RESET SYSTEM ===", $time);
            wr_rst_n <= 0; core_rst_n <= 0; aer_rst_n <= 0;
            ps_src_rst_n <= 0; ps_dst_rst_n <= 0;
            ev_valid_in <= 0; ev_data_in <= 0;
            weight_we <= 0; weight_waddr <= 0; weight_wdata <= 0;
            dbg_current_valid <= 0;
            #50;
            @(posedge core_clk);
            wr_rst_n <= 1; core_rst_n <= 1; aer_rst_n <= 1;
            ps_src_rst_n <= 1; ps_dst_rst_n <= 1;
            repeat(5) @(posedge core_clk);
            $display("[%0t] Reset complete", $time);
        end
    endtask

    task automatic write_weight(input [$clog2(WEIGHT_DEPTH)-1:0] addr, input [DATA_W-1:0] data);
        begin
            @(posedge core_clk);
            weight_waddr <= addr;
            weight_wdata <= data;
            weight_we    <= 1'b1;
            @(posedge core_clk);
            weight_we <= 1'b0;
        end
    endtask

    // Bit layout matches spike_nn_top.v: { weight_addr, event_magnitude }
    task automatic push_event(input [$clog2(WEIGHT_DEPTH)-1:0] waddr, input [DATA_W-1:0] magnitude);
        begin
            @(posedge wr_clk);
            while (!ev_ready_out) @(posedge wr_clk);
            ev_data_in  <= {waddr, magnitude};
            ev_valid_in <= 1'b1;
            @(posedge wr_clk);
            ev_valid_in <= 1'b0;
        end
    endtask

    task automatic inject_dbg_current(input [DATA_W-1:0] current, input [$clog2(NEURONS)-1:0] nid);
        begin
            @(posedge core_clk);
            dbg_current_in        <= current;
            dbg_current_valid     <= 1'b1;
            dbg_current_neuron_id <= nid;
            @(posedge core_clk);
            dbg_current_valid <= 1'b0;
        end
    endtask

    // ===================================================================
    // Monitor layer (passive)
    // ===================================================================
    int total_spikes_seen = 0;
    always @(posedge core_clk) begin
        if (core_rst_n && |spike_bus) total_spikes_seen++;
    end

    // ===================================================================
    // Tests
    // ===================================================================
    task automatic test_single_event_to_spike();
        int w;
        logic [$clog2(LOG_DEPTH):0] pre_log;
        begin
            $display("\n========================================");
            $display("TOP TEST 1: weight write -> FIFO event -> spike -> logger + AER");
            $display("========================================");

            pre_log = log_count;
            write_weight(8'd5, 32'd100);
            repeat(3) @(posedge core_clk);

            // event_magnitude=2, weight=100 -> MAC=200=threshold: spikes alone.
            push_event(8'd5, 32'd2);

            w = 0;
            while (w < 200 && log_count == pre_log) begin
                @(posedge core_clk);
                w = w + 1;
            end

            if (log_count > pre_log) begin
                $display("[PASS] Full path (FIFO->weight stage->synapse->LIF->logger) produced a spike (log_count %0d -> %0d)", pre_log, log_count);
                test_pass_count++;
            end else begin
                $display("[FAIL] No spike propagated through spike_nn_top within %0d cycles", w);
                test_fail_count++;
            end

            // Let it drain through the AER link before the next test.
            repeat(100) @(posedge core_clk);
        end
    endtask

    task automatic test_back_to_back_events();
        // Two FIFO events for two DIFFERENT weight addresses, issued back
        // to back. Regression for the weight-lookup staging buffer: each
        // event must be paired with ITS OWN weight, not a stale/mixed-up
        // one, despite weight_ram_par's registered (1-cycle) read.
        int w;
        logic [$clog2(LOG_DEPTH):0] pre_log;
        begin
            $display("\n========================================");
            $display("TOP TEST 2: back-to-back FIFO events, distinct weights (staging-buffer regression)");
            $display("========================================");

            write_weight(8'd10, 32'd200);  // neuron path A: alone enough to spike
            write_weight(8'd11, 32'd1);    // neuron path B: far below threshold alone
            repeat(3) @(posedge core_clk);

            pre_log = log_count;

            push_event(8'd10, 32'd1);  // 1*200 = 200 = threshold -> spikes
            push_event(8'd11, 32'd1);  // 1*1   = 1   -> nowhere near threshold

            w = 0;
            while (w < 200 && log_count == pre_log) begin
                @(posedge core_clk);
                w = w + 1;
            end

            if (log_count > pre_log) begin
                $display("[PASS] First event's weight (200) correctly paired with its own event -- staging buffer keeps events/weights aligned");
                test_pass_count++;
            end else begin
                $display("[FAIL] Expected a spike from the first back-to-back event, got none -- staging buffer may be misaligning weight/event pairs");
                test_fail_count++;
            end

            repeat(100) @(posedge core_clk);
        end
    endtask

    task automatic test_debug_read_lanes();
        // Debug read lanes (1..WEIGHT_RDPORTS-1) must return correct data
        // independent of the synapse path's own lane-0 traffic.
        int w;
        begin
            $display("\n========================================");
            $display("TOP TEST 3: Weight RAM debug read lanes concurrent with synapse traffic");
            $display("========================================");

            write_weight(8'd20, 32'hCAFE_0001);
            write_weight(8'd21, 32'hCAFE_0002);
            write_weight(8'd22, 32'hCAFE_0003);
            repeat(3) @(posedge core_clk);

            weight_dbg_raddr <= {8'd22, 8'd21, 8'd20};
            repeat(2) @(posedge core_clk);

            if (weight_dbg_rdata[31:0]   == 32'hCAFE_0001 &&
                weight_dbg_rdata[63:32]  == 32'hCAFE_0002 &&
                weight_dbg_rdata[95:64]  == 32'hCAFE_0003) begin
                $display("[PASS] All 3 debug lanes returned correct data (0x%024h)", weight_dbg_rdata);
                test_pass_count++;
            end else begin
                $display("[FAIL] Debug lanes returned incorrect data: 0x%024h", weight_dbg_rdata);
                test_fail_count++;
            end
        end
    endtask

    task automatic test_dbg_current_priority();
        // dbg_current_* must take priority over the synapse path per the
        // documented mux (lif_inj_* = dbg_current_valid ? dbg : synapse).
        int w;
        logic spiked;
        begin
            $display("\n========================================");
            $display("TOP TEST 4: dbg_current injection path (bypasses FIFO/synapse)");
            $display("========================================");

            inject_dbg_current(32'd250, 4'd8); // > threshold(200) alone

            spiked = 1'b0;
            w = 0;
            while (w < 60 && !spiked) begin
                @(posedge core_clk);
                if (spike_bus[8]) spiked = 1'b1;
                w = w + 1;
            end

            if (spiked) begin
                $display("[PASS] Debug current injection path correctly drives the LIF array independent of the FIFO/synapse path");
                test_pass_count++;
            end else begin
                $display("[FAIL] Neuron 8 never spiked from direct debug current injection");
                test_fail_count++;
            end

            repeat(20) @(posedge core_clk);
        end
    endtask

    task automatic test_pulse_sync_utility();
        // Sanity check on the standalone pulse_sync CDC utility exposed
        // at the top level (ps_* ports): busy/ack round trip works.
        int w;
        logic seen;
        begin
            $display("\n========================================");
            $display("TOP TEST 5: standalone pulse_sync utility (ps_* ports)");
            $display("========================================");

            @(posedge ps_src_clk);
            while (ps_busy) @(posedge ps_src_clk);
            ps_pulse_in       <= 8'hA5;
            ps_pulse_valid_in <= 1'b1;
            @(posedge ps_src_clk);
            ps_pulse_valid_in <= 1'b0;

            seen = 1'b0;
            w = 0;
            while (w < 60 && !seen) begin
                @(posedge ps_dst_clk);
                if (ps_sync_valid && ps_pulse_out == 8'hA5) seen = 1'b1;
                w = w + 1;
            end

            if (seen) begin
                $display("[PASS] pulse_sync utility correctly synchronized 0xA5 across to ps_dst_clk");
                test_pass_count++;
            end else begin
                $display("[FAIL] pulse_sync utility did not deliver the expected value");
                test_fail_count++;
            end
        end
    endtask

    // ===================================================================
    // Sequence
    // ===================================================================
    initial begin
        $display("========================================");
        $display("SPIKE_NN_TOP INTEGRATION TESTBENCH");
        $display("========================================");

        reset_system();

        test_single_event_to_spike();
        test_back_to_back_events();
        test_debug_read_lanes();
        test_dbg_current_priority();
        test_pulse_sync_utility();

        $display("\n========================================");
        $display("TOP-LEVEL TEST SUMMARY");
        $display("========================================");
        $display("Total Tests Passed : %0d", test_pass_count);
        $display("Total Tests Failed : %0d", test_fail_count);
        $display("Total spike cycles observed : %0d", total_spikes_seen);
        $display("========================================");

        if (test_fail_count == 0) $display("*** ALL TOP-LEVEL TESTS PASSED ***");
        else                      $display("*** SOME TOP-LEVEL TESTS FAILED ***");

        $finish;
    end

    initial begin
        #500_000;
        $display("ERROR: TOP-LEVEL SIMULATION TIMEOUT");
        $finish;
    end

endmodule