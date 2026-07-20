`timescale 1ns/1ps


module spike_nn_tb_layered;

    parameter CLK_PERIOD     = 10;  // main / write-clock domain
    parameter DST_CLK_PERIOD = 14;  // pulse_sync destination clock (different freq -> real CDC)
    parameter RD_CLK_PERIOD  = 17;  // event_fifo read clock (different freq -> real CDC)

    parameter FIFO_DEPTH      = 16; // power of two, required by gray-code pointers
    parameter WEIGHT_DEPTH    = 256;
    parameter WEIGHT_RD_PORTS = 4;
    parameter LOG_DEPTH       = 256;
    parameter NUM_NEURONS     = 16;

    logic clk, rst_n;
    logic dst_clk, dst_rst_n;
    logic rd_clk, rd_rst_n;

    // Pulse sync interface
    logic [15:0] pulse_in;
    logic        pulse_valid_in;
    logic [15:0] pulse_sync_out;
    logic        pulse_sync_valid;

    // FIFO interface
    logic [47:0] fifo_data_in;
    logic        fifo_valid_in;
    logic        fifo_ready_out;
    logic        fifo_full;
    logic [47:0] fifo_data_out;
    logic        fifo_valid_out;
    logic        fifo_ready_in;
    logic        fifo_empty;

    // Weight RAM interface (parallel read lanes)
    logic [WEIGHT_RD_PORTS*8-1:0]  weight_addr;
    logic [WEIGHT_RD_PORTS*32-1:0] weight_data_out;
    logic [7:0]  weight_waddr;
    logic [31:0] weight_data_in;
    logic        weight_we;

    // Synapse pipeline interface
    logic [31:0] synapse_event_data;
    logic        synapse_event_valid;
    logic        synapse_event_ready;
    logic [31:0] synapse_weight_in;
    logic [31:0] synapse_current_out;
    logic        synapse_current_valid;
    logic        synapse_current_ready;

    // LIF neuron array interface
    logic [31:0] lif_current_in;
    logic        lif_current_valid;
    logic [3:0]  lif_current_neuron_id;   // $clog2(NUM_NEURONS)
    logic signed [15:0] lif_threshold_in;
    logic signed [15:0] lif_reset_val_in;
    logic [4:0]  lif_leak_shift_in;
    logic        lif_spike_out;
    logic [15:0] lif_voltage_out;
    logic [NUM_NEURONS-1:0]      lif_voltage_bus;
    logic [NUM_NEURONS-1:0]      lif_spike_bus;
    logic [NUM_NEURONS*16-1:0]   lif_voltage_flat;

    // Spike logger interface
    logic        logger_spike_in;
    logic        logger_valid_in;
    logic        logger_ready_out;
    logic [7:0]  logger_count;
    logic        logger_overflow;


    pulse_sync #(
        .WIDTH(16)
    ) dut_pulse_sync (
        .src_clk(clk), .src_rst_n(rst_n),
        .pulse_in(pulse_in), .pulse_valid_in(pulse_valid_in),
        .dst_clk(dst_clk), .dst_rst_n(dst_rst_n),
        .pulse_out(pulse_sync_out), .sync_valid(pulse_sync_valid)
    );

    event_fifo #(
        .DEPTH(FIFO_DEPTH),
        .WIDTH(48)
    ) dut_fifo (
        .wr_clk(clk), .wr_rst_n(rst_n),
        .data_in(fifo_data_in), .valid_in(fifo_valid_in),
        .ready_out(fifo_ready_out), .fifo_full(fifo_full),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
        .data_out(fifo_data_out), .valid_out(fifo_valid_out),
        .ready_in(fifo_ready_in), .fifo_empty(fifo_empty)
    );

    weight_ram_par #(
        .DEPTH(WEIGHT_DEPTH),
        .WIDTH(32),
        .RD_PORTS(WEIGHT_RD_PORTS)
    ) dut_weight_ram (
        .clk(clk),
        .addr(weight_addr), .data_out(weight_data_out),
        .waddr(weight_waddr), .data_in(weight_data_in), .we(weight_we)
    );

    synapse_pipeline #(
        .WIDTH(32),
        .DELAY(8)
    ) dut_synapse (
        .clk(clk), .rst_n(rst_n),
        .event_data(synapse_event_data),
        .event_valid(synapse_event_valid),
        .event_ready(synapse_event_ready),
        .weight_in(synapse_weight_in),
        .current_out(synapse_current_out),
        .current_valid(synapse_current_valid),
        .current_ready(synapse_current_ready)
    );

    pipelined_lif #(
        .Neurons(NUM_NEURONS),
        .Pipeline_Stages(4)
    ) dut_lif (
        .clk(clk), .rst_n(rst_n),
        .current_in(lif_current_in),
        .current_valid(lif_current_valid),
        .current_neuron_id(lif_current_neuron_id),
        .threshold_in(lif_threshold_in),
        .reset_val_in(lif_reset_val_in),
        .leak_shift_in(lif_leak_shift_in),
        .spike_out(lif_spike_out),
        .voltage_out(lif_voltage_out),
        .voltage_bus(lif_voltage_bus),
        .spike_bus(lif_spike_bus),
        .voltage_flat(lif_voltage_flat)
    );

    spike_logger #(
        .DEPTH(LOG_DEPTH)
    ) dut_logger (
        .clk(clk), .rst_n(rst_n),
        .spike_in(logger_spike_in),
        .valid_in(logger_valid_in),
        .ready_out(logger_ready_out),
        .log_count(logger_count),
        .overflow(logger_overflow)
    );

    int test_pass_count;
    int test_fail_count;
    int total_spikes_generated;
    int total_spikes_logged;
    int total_cycles;


    initial begin clk = 0;     forever #(CLK_PERIOD/2)     clk = ~clk;     end
    initial begin dst_clk = 0; forever #(DST_CLK_PERIOD/2) dst_clk = ~dst_clk; end
    initial begin rd_clk = 0;  forever #(RD_CLK_PERIOD/2)  rd_clk = ~rd_clk;  end

    task automatic reset_system();
        begin
            $display("[%0t] === RESET SYSTEM ===", $time);
            rst_n = 0; dst_rst_n = 0; rd_rst_n = 0;

            pulse_in = 16'h0000; pulse_valid_in = 1'b0;
            fifo_data_in = 48'h0; fifo_valid_in = 1'b0; fifo_ready_in = 1'b1;
            weight_addr = '0; weight_waddr = 8'h00; weight_data_in = 32'h0; weight_we = 1'b0;
            synapse_event_data = 32'h0; synapse_event_valid = 1'b0; synapse_current_ready = 1'b1;
            synapse_weight_in = 32'h0010;
            lif_current_in = 32'h0; lif_current_valid = 1'b0; lif_current_neuron_id = 4'd0;
            lif_threshold_in = 16'sd200; lif_reset_val_in = 16'sd0; lif_leak_shift_in = 5'd5;
            logger_spike_in = 1'b0; logger_valid_in = 1'b0;

            #200;
            @(posedge clk);
            rst_n = 1; dst_rst_n = 1; rd_rst_n = 1;
            repeat(5) @(posedge clk);
            $display("[%0t] Reset complete", $time);
        end
    endtask


    task automatic send_pulse(input [15:0] addr);
        begin
            @(posedge clk);
            pulse_in = addr;
            pulse_valid_in = 1'b1;
            @(posedge clk);
            pulse_valid_in = 1'b0;
            total_spikes_generated++;
            $display("[%0t] Pulse sent: addr=0x%04h", $time, addr);
        end
    endtask


    task automatic write_fifo(input [47:0] data);
        begin
            @(posedge clk);
            if (!fifo_full) begin
                fifo_data_in = data;
                fifo_valid_in = 1'b1;
                @(posedge clk);
                fifo_valid_in = 1'b0;

                $display("[%0t] FIFO write: data=0x%012h", $time, data);
            end else begin
                $display("[%0t] FIFO write failed: FIFO full", $time);
            end
        end
    endtask


    task automatic write_weight(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            weight_waddr = addr;
            weight_data_in = data;
            weight_we = 1'b1;
            @(posedge clk);
            weight_we = 1'b0;
            $display("[%0t] Weight write: addr=0x%02h, data=0x%08h", $time, addr, data);
        end
    endtask

    task automatic read_weight(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            weight_addr[7:0] = addr;  // lane 0
            @(posedge clk);
            @(posedge clk);
            data = weight_data_out[31:0];
            $display("[%0t] Weight read: addr=0x%02h, data=0x%08h", $time, addr, data);
        end
    endtask


    task automatic send_synapse_event(input [31:0] event_data, input [31:0] weight, output logic accepted);
        begin
            @(posedge clk);
            synapse_event_data = event_data;
            synapse_event_valid = 1'b1;
            synapse_weight_in = weight;
            accepted = synapse_event_ready;
            @(posedge clk);
            synapse_event_valid = 1'b0;
            $display("[%0t] Synapse event sent: data=0x%08h, weight=0x%08h, accepted=%b", $time, event_data, weight, accepted);
        end
    endtask

    task automatic inject_lif_current(input [15:0] current, input [3:0] neuron_id);
        begin
            @(posedge clk);
            lif_current_in = {16'h0, current};
            lif_current_valid = 1'b1;
            lif_current_neuron_id = neuron_id;
            @(posedge clk);
            lif_current_valid = 1'b0;
            $display("[%0t] LIF current injected to neuron %0d: 0x%04h", $time, neuron_id, current);
        end
    endtask


    task automatic wait_for_spike(input int max_cycles, output logic spike_detected);
        int cycle_cnt;
        begin
            cycle_cnt = 0;
            spike_detected = 1'b0;
            while (cycle_cnt < max_cycles && !spike_detected) begin
                @(posedge clk);
                if (lif_spike_out) begin
                    $display("[%0t] *** SPIKE DETECTED *** Voltage: 0x%04h", $time, lif_voltage_out);
                    spike_detected = 1'b1;
                end
                cycle_cnt++;
            end
            if (!spike_detected) begin
                $display("[%0t] No spike detected within %0d cycles", $time, max_cycles);
            end
        end
    endtask

    task automatic test_pulse_sync();
        int check_cycles;
        logic found_valid1, found_valid2;
        begin
            $display("\n========================================");
            $display("TEST 1: Pulse Synchronization (true CDC)");
            $display("========================================");

            send_pulse(16'hABCD);

            check_cycles = 0;
            found_valid1 = 1'b0;
            while (check_cycles < 30 && !found_valid1) begin
                @(posedge clk);
                if (pulse_sync_valid) begin
                    found_valid1 = 1'b1;
                end
                check_cycles++;
            end

            if (found_valid1) begin
                $display("[PASS] Pulse sync generated valid signal at cycle %0d", check_cycles);
                test_pass_count++;
            end else begin
                $display("[FAIL] Pulse sync did not generate valid");
                test_fail_count++;
            end

            repeat(5) @(posedge clk);

            send_pulse(16'h1234);
            check_cycles = 0; found_valid1 = 1'b0;
            while (check_cycles < 30 && !found_valid1) begin
                @(posedge clk);
                if (pulse_sync_valid) begin found_valid1 = 1'b1; end
                check_cycles++;
            end
            repeat(5) @(posedge clk);

            send_pulse(16'h1234); // repeated identical value
            check_cycles = 0; found_valid2 = 1'b0;
            while (check_cycles < 30 && !found_valid2) begin
                @(posedge clk);
                if (pulse_sync_valid) begin found_valid2 = 1'b1; end
                check_cycles++;
            end

            if (found_valid1 && found_valid2) begin
                $display("[PASS] Repeated identical pulse value was NOT dropped (Gap #6 fix verified)");
                test_pass_count++;
            end else begin
                $display("[FAIL] Repeated identical pulse value was dropped");
                test_fail_count++;
            end

            repeat(10) @(posedge clk);
        end
    endtask


    task automatic test_fifo_operation();
        int i;
        int items_written;
        begin
            $display("\n========================================");
            $display("TEST 2: FIFO Operation (async, wr_clk != rd_clk)");
            $display("========================================");

            fifo_ready_in = 1'b0;  // hold off draining while we fill
            items_written = 0;
            i = 0;
            while (i < 10) begin
                write_fifo({16'h0, i[15:0], 16'h0100 + i[15:0]});
                if (fifo_ready_out) items_written = items_written + 1;
                @(posedge clk);
                i = i + 1;
            end

            // Time-based (not cycle-based) settle so the write pointer's
            // Gray code has time to cross into the read clock domain
            // through its 2-flop synchronizer, regardless of clock ratio.
            #300;

            $display("        FIFO status after fill (reads held off): items_written=%0d, empty=%b, full=%b",
                     items_written, fifo_empty, fifo_full);

            if (!fifo_empty) begin
                $display("[PASS] Written data crossed the wr_clk -> rd_clk boundary (fifo_empty deasserted)");
                test_pass_count++;
            end else begin
                $display("[FAIL] FIFO still empty after fill+settle (wrote %0d items)", items_written);
                test_fail_count++;
            end

            // Now drain and confirm the FIFO empties back out again
            fifo_ready_in = 1'b1;
            #300;

            if (fifo_empty) begin
                $display("[PASS] FIFO drained back to empty after enabling reads");
                test_pass_count++;
            end else begin
                $display("[FAIL] FIFO did not drain (empty=%b)", fifo_empty);
                test_fail_count++;
            end

            fifo_ready_in = 1'b0;
        end
    endtask

    task automatic test_weight_ram();
        logic [31:0] read_data;
        int addr_idx;
        begin
            $display("\n========================================");
            $display("TEST 3: Weight RAM Access (lane 0)");
            $display("========================================");

            addr_idx = 0;
            while (addr_idx < 8) begin
                write_weight(addr_idx[7:0], 32'h0000_0020 + addr_idx);
                addr_idx = addr_idx + 1;
            end

            repeat(5) @(posedge clk);

            addr_idx = 0;
            while (addr_idx < 8) begin
                read_weight(addr_idx[7:0], read_data);
                if (read_data == (32'h0000_0020 + addr_idx)) begin
                    test_pass_count++;
                end else begin
                    $display("[FAIL] Weight mismatch at addr 0x%02h: expected=0x%08h, got=0x%08h",
                             addr_idx, 32'h0000_0020 + addr_idx, read_data);
                    test_fail_count++;
                end
                addr_idx = addr_idx + 1;
            end

            weight_addr = {8'd3, 8'd2, 8'd1, 8'd0};
            @(posedge clk); @(posedge clk);
            if (weight_data_out[31:0]    == 32'h0000_0020 &&
                weight_data_out[63:32]   == 32'h0000_0021 &&
                weight_data_out[95:64]   == 32'h0000_0022 &&
                weight_data_out[127:96]  == 32'h0000_0023) begin
                $display("[PASS] All %0d read lanes returned correct data in parallel, same cycle", WEIGHT_RD_PORTS);
                test_pass_count++;
            end else begin
                $display("[FAIL] Parallel read lanes returned incorrect data: 0x%032h", weight_data_out);
                test_fail_count++;
            end
        end
    endtask


    task automatic test_synapse_pipeline();
        int event_idx;
        int wait_cycles;
        int idle_cycles;
        logic accepted;
        logic [31:0] expected_sum;
        logic [31:0] drained_sum;
        begin
            $display("\n========================================");
            $display("TEST 4: Synapse Pipeline (real MAC + accumulate)");
            $display("========================================");


            synapse_current_ready = 1'b0;
            expected_sum = 32'h0;

            event_idx = 0;
            while (event_idx < 5) begin
                send_synapse_event(32'h0000_0002, 32'h0000_0064, accepted); // event_data=2, weight=100
                if (accepted) begin
                    expected_sum = expected_sum + (32'h0000_0002 * 32'h0000_0064);
                end
                repeat(2) @(posedge clk);
                event_idx = event_idx + 1;
            end

            repeat(20) @(posedge clk);

            // Drain fully: accept every beat and sum it, until several
            // idle cycles pass with nothing further arriving.
            synapse_current_ready = 1'b1;
            drained_sum = 32'h0;
            idle_cycles = 0;
            wait_cycles = 0;
            while (idle_cycles < 10 && wait_cycles < 60) begin
                @(posedge clk);
                if (synapse_current_valid) begin
                    drained_sum = drained_sum + synapse_current_out;
                    idle_cycles = 0;
                    $display("        Synapse beat: current=0x%08h running_sum=0x%08h", synapse_current_out, drained_sum);
                end else begin
                    idle_cycles = idle_cycles + 1;
                end
                wait_cycles = wait_cycles + 1;
            end

            if (expected_sum != 32'h0 && drained_sum == expected_sum) begin
                $display("[PASS] Synapse pipeline MAC+accumulate: drained 0x%08h matches expected 0x%08h", drained_sum, expected_sum);
                test_pass_count++;
            end else begin
                $display("[FAIL] Synapse drained=0x%08h expected=0x%08h", drained_sum, expected_sum);
                test_fail_count++;
            end
            synapse_current_ready = 1'b1;
        end
    endtask


    task automatic test_lif_neuron();
        int inj_idx;
        int w;
        logic spike_detected;
        begin
            $display("\n========================================");
            $display("TEST 5: LIF Neuron Operation (neuron 0, gradual leaky-integrate)");
            $display("========================================");

            spike_detected = 1'b0;

            inj_idx = 0;
            // Space injections one round-robin period apart: neuron 0 is
            // only serviced once every NUM_NEURONS cycles now that all 16
            // neurons are live (Known Gap #2 fix), so injecting faster
            // than that just overwrites the still-pending current instead
            // of adding to it.
            while (inj_idx < 20 && !spike_detected) begin
                @(posedge clk);
                lif_current_in        = {16'h0, 16'h0020};
                lif_current_valid     = 1'b1;
                lif_current_neuron_id = 4'd0;
                if (lif_spike_out) spike_detected = 1'b1;
                @(posedge clk);
                lif_current_valid = 1'b0;
                if (lif_spike_out) spike_detected = 1'b1;
                for (w = 0; w < (NUM_NEURONS-2) && !spike_detected; w = w + 1) begin
                    @(posedge clk);
                    if (lif_spike_out) spike_detected = 1'b1;
                end
                inj_idx = inj_idx + 1;
            end

            if (spike_detected) begin
                $display("[PASS] Neuron 0 spiked after %0d injections (leaky-integrate accumulation)", inj_idx);
                test_pass_count++;
            end else begin
                $display("[FAIL] Neuron 0 did not spike after %0d injections", inj_idx);
                test_fail_count++;
            end

            repeat(10) @(posedge clk);
        end
    endtask


    task automatic test_spike_logger();
        int log_idx;
        begin
            $display("\n========================================");
            $display("TEST 6: Spike Logger");
            $display("========================================");

            log_idx = 0;
            while (log_idx < 10) begin
                @(posedge clk);
                logger_spike_in = 1'b1;
                logger_valid_in = 1'b1;
                @(posedge clk);
                logger_spike_in = 1'b0;
                logger_valid_in = 1'b0;
                repeat(2) @(posedge clk);
                log_idx = log_idx + 1;
            end

            repeat(5) @(posedge clk);

            if (logger_count == 10) begin
                $display("[PASS] Logger recorded correct count: %0d", logger_count);
                test_pass_count++;
            end else begin
                $display("[FAIL] Logger count mismatch: expected=10, got=%0d", logger_count);
                test_fail_count++;
            end
        end
    endtask


    task automatic test_multi_neuron_array();
        int n;
        int id_list[0:4];
        int wait_cycles;
        logic [NUM_NEURONS-1:0] seen_spike;
        begin
            $display("\n========================================");
            $display("TEST 7: Multi-Neuron Array (neurons 0,3,7,11,15)");
            $display("========================================");

            id_list[0]=0; id_list[1]=3; id_list[2]=7; id_list[3]=11; id_list[4]=15;
            seen_spike = '0;
            
            for (n = 0; n < 5; n = n + 1) begin
                @(posedge clk);
                lif_current_in       = {16'h0, 16'h0100}; // 256 > THRESHOLD(200)
                lif_current_valid    = 1'b1;
                lif_current_neuron_id = id_list[n][3:0];
                seen_spike = seen_spike | lif_spike_bus;
                $display("[%0t] LIF current injected to neuron %0d: 0x0100", $time, id_list[n]);
                @(posedge clk);
                lif_current_valid = 1'b0;
                seen_spike = seen_spike | lif_spike_bus;
            end

            wait_cycles = 0;
            while (wait_cycles < 80) begin
                @(posedge clk);
                seen_spike = seen_spike | lif_spike_bus;
                wait_cycles++;
            end

            if (seen_spike[0] && seen_spike[3] && seen_spike[7] &&
                seen_spike[11] && seen_spike[15]) begin
                $display("[PASS] All 5 targeted neurons in the array spiked independently (spike_bus=0x%04h)", seen_spike);
                test_pass_count++;
            end else begin
                $display("[FAIL] Not all targeted neurons spiked, seen_spike=0x%04h", seen_spike);
                test_fail_count++;
            end
        end
    endtask


    task automatic test_datapath_integration();
        integer cyc;
        integer pushed;
        logic [7:0] pre_log_count;
        begin
            $display("\n========================================");
            $display("TEST 8: Full Datapath Integration");
            $display("(event_fifo -> synapse_pipeline -> pipelined_lif -> spike_logger)");
            $display("========================================");

            write_weight(8'h00, 32'h0000_0064); // weight = 100 at addr 0
            repeat(3) @(posedge clk);

            pre_log_count = logger_count;
            synapse_current_ready = 1'b1;
            weight_addr[7:0] = 8'h00;
            fifo_ready_in    = 1'b0;   // hold reads off until all writes have settled

            // event_data=2, weight=100 -> MAC term = 200 = THRESHOLD, so a
            // single event alone is enough to make neuron 0 spike.
            pushed = 0;
            while (pushed < 6) begin
                write_fifo({32'h0000_0002, 16'h0000});
                pushed = pushed + 1;
            end
            #300; // let the write pointer cross into the read clock domain
            fifo_ready_in = 1'b1;

            for (cyc = 0; cyc < 400; cyc = cyc + 1) begin
                @(posedge clk);
                // event_fifo -> synapse_pipeline
                synapse_event_data   <= fifo_data_out[47:16];
                synapse_event_valid  <= fifo_valid_out;
                synapse_weight_in    <= weight_data_out[31:0];

                // synapse_pipeline -> pipelined_lif (target neuron 0)
                lif_current_in        <= synapse_current_out;
                lif_current_valid     <= synapse_current_valid;
                lif_current_neuron_id <= 4'd0;

                // pipelined_lif -> spike_logger
                logger_spike_in <= lif_spike_out;
                logger_valid_in <= lif_spike_out;
            end

            synapse_event_valid <= 1'b0;
            lif_current_valid   <= 1'b0;
            logger_valid_in      <= 1'b0;
            repeat(10) @(posedge clk);

            if (logger_count > pre_log_count) begin
                $display("[PASS] Datapath integration: spike propagated fifo->synapse->lif->logger (log_count %0d -> %0d)",
                         pre_log_count, logger_count);
                test_pass_count++;
            end else begin
                $display("[FAIL] No spike propagated through the full datapath (log_count stayed %0d)", logger_count);
                test_fail_count++;
            end
        end
    endtask


    initial begin
        $display("========================================");
        $display("LAYERED SPIKE-NN TESTBENCH V3 (post-fix)");
        $display("========================================");

        test_pass_count = 0;
        test_fail_count = 0;
        total_spikes_generated = 0;
        total_spikes_logged = 0;
        total_cycles = 0;

        reset_system();

        test_pulse_sync();
        test_fifo_operation();
        test_weight_ram();
        test_synapse_pipeline();
        test_lif_neuron();
        test_spike_logger();
        test_multi_neuron_array();
        test_datapath_integration();

        repeat(50) @(posedge clk);

        $display("\n========================================");
        $display("TEST SUMMARY");
        $display("========================================");
        $display("Total Tests Passed : %0d", test_pass_count);
        $display("Total Tests Failed : %0d", test_fail_count);
        $display("Spikes Generated   : %0d", total_spikes_generated);
        $display("Total Cycles       : %0d", total_cycles);
        $display("========================================");

        if (test_fail_count == 0) begin
            $display("*** ALL TESTS PASSED ***");
        end else begin
            $display("*** SOME TESTS FAILED ***");
        end

        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) total_cycles++;
    end

    always @(posedge clk) begin
        if (rst_n && lif_spike_out) total_spikes_logged++;
    end

    always @(posedge clk) begin
        if (rst_n && fifo_full && fifo_valid_in) begin
            $display("[%0t] WARNING: FIFO overflow attempt", $time);
        end
    end

    always @(posedge clk) begin
        if (rst_n && logger_overflow) begin
            $display("[%0t] WARNING: Logger overflow", $time);
        end
    end

    initial begin
        #2_000_000;
        $display("\n========================================");
        $display("ERROR: SIMULATION TIMEOUT");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("spike_nn_layered.vcd");
        $dumpvars(0, spike_nn_tb_layered);
    end

endmodule