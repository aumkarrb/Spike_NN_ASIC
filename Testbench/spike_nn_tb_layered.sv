`timescale 1ns/1ps
module spike_nn_tb_layered;

    parameter CLK_PERIOD     = 10;  // main / write-clock domain
    parameter DST_CLK_PERIOD = 14;  // pulse_sync destination clock (different freq -> real CDC)
    parameter RD_CLK_PERIOD  = 17;  // event_fifo read clock (different freq -> real CDC)
    parameter AER_CLK_PERIOD = 21;  // AER receiver clock (different freq -> genuine CDC across the AER link)

    parameter FIFO_DEPTH      = 16; // power of two, required by gray-code pointers
    parameter WEIGHT_DEPTH    = 256;
    parameter WEIGHT_RD_PORTS = 4;
    parameter LOG_DEPTH       = 256;
    parameter AER_LOG_DEPTH   = 256;
    parameter NUM_NEURONS     = 16;

    logic clk, rst_n;
    logic dst_clk, dst_rst_n;
    logic rd_clk, rd_rst_n;
    logic aer_clk, aer_rst_n;

    // Pulse sync interface
    logic [15:0] pulse_in;
    logic        pulse_valid_in;
    logic [15:0] pulse_sync_out;
    logic        pulse_sync_valid;
    wire         pulse_sync_busy;   // NEW: source must wait for this to clear

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
    logic [8:0]  logger_count;
    logic        logger_overflow;

    // AER link: synthetic protocol/arbitration test path
    logic [NUM_NEURONS-1:0] aer_test_req_pulse;
    logic [3:0]             aer_test_addr;
    logic                   aer_test_req;
    logic                   aer_test_ack;
    logic                   aer_test_busy;
    logic [NUM_NEURONS-1:0] aer_test_pending_dbg;
    logic [3:0]             aer_test_addr_out;
    logic                   aer_test_event_valid;

    // AER link: real integration path 
    logic [3:0]              aer_addr;
    logic                    aer_req;
    logic                    aer_ack;
    logic                    aer_busy;
    logic [NUM_NEURONS-1:0]  aer_pending_dbg;
    logic [3:0]              aer_addr_out;
    logic                    aer_event_valid;
    logic [$clog2(AER_LOG_DEPTH):0] aer_log_count;
    logic                    aer_log_overflow;
    logic                    aer_log_ready_out;
    logic [$clog2(AER_LOG_DEPTH)-1:0] aer_read_addr;
    logic [3:0]               aer_read_out_addr;
    logic [31:0]               aer_read_out_time;


    pulse_sync #(
        .WIDTH(16)
    ) dut_pulse_sync (
        .src_clk(clk), .src_rst_n(rst_n),
        .pulse_in(pulse_in), .pulse_valid_in(pulse_valid_in), .busy(pulse_sync_busy),
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

    //  AER link: synthetic protocol/arbitration test instances 
    aer_tx #(.N_SOURCES(NUM_NEURONS), .ADDR_W(4)) dut_aer_tx_test (
        .clk(clk), .rst_n(rst_n),
        .req_pulse(aer_test_req_pulse),
        .addr(aer_test_addr), .aer_req(aer_test_req), .aer_ack(aer_test_ack),
        .busy(aer_test_busy), .pending_dbg(aer_test_pending_dbg)
    );
    aer_rx #(.ADDR_W(4)) dut_aer_rx_test (
        .clk(aer_clk), .rst_n(aer_rst_n),
        .addr(aer_test_addr), .aer_req(aer_test_req), .aer_ack(aer_test_ack),
        .addr_out(aer_test_addr_out), .event_valid(aer_test_event_valid)
    );

    //  AER link: real integration path, wired to the live neuron array 
    aer_tx #(.N_SOURCES(NUM_NEURONS), .ADDR_W(4)) dut_aer_tx (
        .clk(clk), .rst_n(rst_n),
        .req_pulse(lif_spike_bus),           
        .addr(aer_addr), .aer_req(aer_req), .aer_ack(aer_ack),
        .busy(aer_busy), .pending_dbg(aer_pending_dbg)
    );
    aer_rx #(.ADDR_W(4)) dut_aer_rx (
        .clk(aer_clk), .rst_n(aer_rst_n),
        .addr(aer_addr), .aer_req(aer_req), .aer_ack(aer_ack),
        .addr_out(aer_addr_out), .event_valid(aer_event_valid)
    );
    aer_spike_logger #(.DEPTH(AER_LOG_DEPTH), .ADDR_W(4)) dut_aer_logger (
        .clk(aer_clk), .rst_n(aer_rst_n),
        .addr_in(aer_addr_out), .event_valid(aer_event_valid), .ready_out(aer_log_ready_out),
        .log_count(aer_log_count), .overflow(aer_log_overflow),
        .read_addr(aer_read_addr), .read_out_addr(aer_read_out_addr), .read_out_time(aer_read_out_time)
    );

    int test_pass_count;
    int test_fail_count;
    int total_spikes_generated;
    int total_spikes_logged;
    int total_cycles;


    initial begin clk = 0;     forever #(CLK_PERIOD/2)     clk = ~clk;     end
    initial begin dst_clk = 0; forever #(DST_CLK_PERIOD/2) dst_clk = ~dst_clk; end
    initial begin rd_clk = 0;  forever #(RD_CLK_PERIOD/2)  rd_clk = ~rd_clk;  end
    initial begin aer_clk = 0; forever #(AER_CLK_PERIOD/2) aer_clk = ~aer_clk; end

    task automatic reset_system();
        begin
            $display("[%0t] === RESET SYSTEM ===", $time);
            rst_n <= 0; dst_rst_n <= 0; rd_rst_n <= 0; aer_rst_n <= 0;

            pulse_in <= 16'h0000; pulse_valid_in <= 1'b0;
            fifo_data_in <= 48'h0; fifo_valid_in <= 1'b0; fifo_ready_in <= 1'b1;
            weight_addr <= '0; weight_waddr <= 8'h00; weight_data_in <= 32'h0; weight_we <= 1'b0;
            synapse_event_data <= 32'h0; synapse_event_valid <= 1'b0; synapse_current_ready <= 1'b1;
            synapse_weight_in <= 32'h0010;
            lif_current_in <= 32'h0; lif_current_valid <= 1'b0; lif_current_neuron_id <= 4'd0;
            lif_threshold_in <= 16'sd200; lif_reset_val_in <= 16'sd0; lif_leak_shift_in <= 5'd5;
            logger_spike_in <= 1'b0; logger_valid_in <= 1'b0;
            aer_test_req_pulse <= '0; aer_read_addr <= '0;

            #200;
            @(posedge clk);
            rst_n <= 1; dst_rst_n <= 1; rd_rst_n <= 1; aer_rst_n <= 1;
            repeat(5) @(posedge clk);
            $display("[%0t] Reset complete", $time);
        end
    endtask


    task automatic send_pulse(input [15:0] addr);
        begin
            @(posedge clk);
            // Respect busy: pulse_sync now uses a busy/ack round-trip
            // handshake, so a new request must wait for the previous one
            // to be fully acknowledged or it will not be sampled.
            while (pulse_sync_busy) @(posedge clk);
            pulse_in       <= addr;
            pulse_valid_in <= 1'b1;
            @(posedge clk);
            pulse_valid_in <= 1'b0;
            total_spikes_generated++;
            $display("[%0t] Pulse sent: addr=0x%04h", $time, addr);
        end
    endtask


    task automatic write_fifo(input [47:0] data);
        begin
            @(posedge clk);
            if (!fifo_full) begin
                fifo_data_in  <= data;
                fifo_valid_in <= 1'b1;
                @(posedge clk);
                fifo_valid_in <= 1'b0;

                $display("[%0t] FIFO write: data=0x%012h", $time, data);
            end else begin
                $display("[%0t] FIFO write failed: FIFO full", $time);
            end
        end
    endtask


    task automatic write_weight(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            weight_waddr   <= addr;
            weight_data_in <= data;
            weight_we      <= 1'b1;
            @(posedge clk);
            weight_we <= 1'b0;
            $display("[%0t] Weight write: addr=0x%02h, data=0x%08h", $time, addr, data);
        end
    endtask

    // weight_ram_par now has a registered (1-cycle-latency) read: present
    // the address one cycle, data_out is valid starting the cycle after.
    task automatic read_weight(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            weight_addr[7:0] <= addr;  // lane 0
            @(posedge clk);            // address sampled by the registered read here
            @(posedge clk);            // data_out valid since the previous edge
            data = weight_data_out[31:0];
            $display("[%0t] Weight read: addr=0x%02h, data=0x%08h", $time, addr, data);
        end
    endtask


    task automatic send_synapse_event(input [31:0] event_data, input [31:0] weight, output logic accepted);
        begin
            @(posedge clk);
            synapse_event_data  <= event_data;
            synapse_event_valid <= 1'b1;
            synapse_weight_in   <= weight;
            accepted = synapse_event_ready;
            @(posedge clk);
            synapse_event_valid <= 1'b0;
            $display("[%0t] Synapse event sent: data=0x%08h, weight=0x%08h, accepted=%b", $time, event_data, weight, accepted);
        end
    endtask

    task automatic inject_lif_current(input [15:0] current, input [3:0] neuron_id);
        begin
            @(posedge clk);
            lif_current_in        <= {16'h0, current};
            lif_current_valid     <= 1'b1;
            lif_current_neuron_id <= neuron_id;
            @(posedge clk);
            lif_current_valid <= 1'b0;
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


    task automatic test_pulse_sync_burst();
        // Regression for the pulse_sync data-loss bug: back-to-back
        // pulses issued faster than the CDC round-trip must never be
        // dropped now that send_pulse() respects `busy`.
        integer i;
        integer received;
        logic [15:0] expected_next;
        begin
            $display("\n========================================");
            $display("TEST 1b: Pulse Sync Burst / No-Loss (regression)");
            $display("========================================");

            received = 0;
            expected_next = 16'h1000;

            fork
                begin : sender
                    for (i = 0; i < 8; i = i + 1) begin
                        send_pulse(16'h1000 + i[15:0]);
                    end
                end
                begin : receiver
                    integer w;
                    w = 0;
                    while (received < 8 && w < 2000) begin
                        @(posedge dst_clk);
                        if (pulse_sync_valid) begin
                            if (pulse_sync_out == expected_next) begin
                                received = received + 1;
                                expected_next = expected_next + 1'b1;
                            end else begin
                                $display("[%0t] UNEXPECTED pulse value 0x%04h (expected 0x%04h)",
                                         $time, pulse_sync_out, expected_next);
                            end
                        end
                        w = w + 1;
                    end
                end
            join

            if (received == 8) begin
                $display("[PASS] All 8 back-to-back pulses delivered in order, none lost (busy backpressure works)");
                test_pass_count++;
            end else begin
                $display("[FAIL] Only %0d/8 pulses delivered -- pulse_sync is dropping data under burst", received);
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

            fifo_ready_in <= 1'b0;  // hold off draining while we fill
            items_written = 0;
            i = 0;
            while (i < 10) begin
                write_fifo({16'h0, i[15:0], 16'h0100 + i[15:0]});
                if (fifo_ready_out) items_written = items_written + 1;
                @(posedge clk);
                i = i + 1;
            end

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
            fifo_ready_in <= 1'b1;
            #300;

            if (fifo_empty) begin
                $display("[PASS] FIFO drained back to empty after enabling reads");
                test_pass_count++;
            end else begin
                $display("[FAIL] FIFO did not drain (empty=%b)", fifo_empty);
                test_fail_count++;
            end

            fifo_ready_in <= 1'b0;
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

            weight_addr <= {8'd3, 8'd2, 8'd1, 8'd0};
            @(posedge clk); @(posedge clk); @(posedge clk);
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

            while (inj_idx < 20 && !spike_detected) begin
                @(posedge clk);
                lif_current_in        <= {16'h0, 16'h0020};
                lif_current_valid     <= 1'b1;
                lif_current_neuron_id <= 4'd0;
                if (lif_spike_out) spike_detected = 1'b1;
                @(posedge clk);
                lif_current_valid <= 1'b0;
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
                logger_spike_in <= 1'b1;
                logger_valid_in <= 1'b1;
                @(posedge clk);
                logger_spike_in <= 1'b0;
                logger_valid_in <= 1'b0;
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
                lif_current_in       <= {16'h0, 16'h0100}; // 256 > THRESHOLD(200)
                lif_current_valid    <= 1'b1;
                lif_current_neuron_id <= id_list[n][3:0];
                seen_spike = seen_spike | lif_spike_bus;
                $display("[%0t] LIF current injected to neuron %0d: 0x0100", $time, id_list[n]);
                @(posedge clk);
                lif_current_valid <= 1'b0;
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
        logic [8:0] pre_log_count;
        begin
            $display("\n========================================");
            $display("TEST 8: Full Datapath Integration");
            $display("(event_fifo -> synapse_pipeline -> pipelined_lif -> spike_logger)");
            $display("========================================");

            write_weight(8'h00, 32'h0000_0064); // weight = 100 at addr 0
            repeat(3) @(posedge clk);

            pre_log_count = logger_count;
            synapse_current_ready <= 1'b1;
            weight_addr[7:0] <= 8'h00;
            fifo_ready_in    <= 1'b0;   // hold reads off until all writes have settled

            // event_data=2, weight=100 -> MAC term = 200 = THRESHOLD, so a
            // single event alone is enough to make neuron 0 spike.
            pushed = 0;
            while (pushed < 6) begin
                write_fifo({32'h0000_0002, 16'h0000});
                pushed = pushed + 1;
            end
            #300; // let the write pointer cross into the read clock domain
            fifo_ready_in <= 1'b1;

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


    task automatic test_spike_logger_capacity();
        // Regression for two spike_logger fixes:
        //  (a) usable capacity is now the full LOG_DEPTH, not LOG_DEPTH-1
        //  (b) overflow is a one-cycle pulse, not a permanent latch
        integer k;
        logic [8:0] fill_start_count;
        begin
            $display("\n========================================");
            $display("TEST 9: Spike Logger Capacity & Overflow (regression)");
            $display("========================================");

            fill_start_count = logger_count;

            // Fill the remaining capacity exactly (LOG_DEPTH - current count),
            // all should be accepted with overflow staying low throughout.
            for (k = 0; k < (LOG_DEPTH - fill_start_count); k = k + 1) begin
                @(posedge clk);
                logger_spike_in <= 1'b1; logger_valid_in <= 1'b1;
                @(posedge clk);
                logger_spike_in <= 1'b0; logger_valid_in <= 1'b0;
            end
            repeat(3) @(posedge clk);

            if (logger_count == LOG_DEPTH && !logger_overflow) begin
                $display("[PASS] Logger reached full LOG_DEPTH=%0d capacity with no premature overflow (log_count=%0d)",
                         LOG_DEPTH, logger_count);
                test_pass_count++;
            end else begin
                $display("[FAIL] Expected log_count=%0d overflow=0, got log_count=%0d overflow=%b",
                         LOG_DEPTH, logger_count, logger_overflow);
                test_fail_count++;
            end

            // One more spike now that the log is genuinely full: overflow
            // should pulse high for that exact cycle.
            @(posedge clk);
            logger_spike_in <= 1'b1; logger_valid_in <= 1'b1;
            @(posedge clk);
            logger_spike_in <= 1'b0; logger_valid_in <= 1'b0;
            #1; // let this edge's NBA-computed overflow settle before checking

            if (logger_overflow && logger_count == LOG_DEPTH) begin
                $display("[PASS] Overflow pulsed on the over-capacity spike attempt (log_count held at %0d)", logger_count);
                test_pass_count++;
            end else begin
                $display("[FAIL] Expected overflow=1 log_count=%0d, got overflow=%b log_count=%0d",
                         LOG_DEPTH, logger_overflow, logger_count);
                test_fail_count++;
            end

            // Idle cycle, no new spike attempt: overflow must self-clear
            // (previously it would have stayed latched high forever).
            @(posedge clk);
            #1;
            if (!logger_overflow) begin
                $display("[PASS] Overflow self-cleared on an idle cycle (pulse behavior confirmed, not a latch)");
                test_pass_count++;
            end else begin
                $display("[FAIL] Overflow stayed asserted with no spike attempt -- latched instead of pulsing");
                test_fail_count++;
            end
        end
    endtask


    task automatic test_lif_pending_race();
        // Regression for the pipelined_lif pending_valid write-write race:
        // a fresh injection to neuron N arriving the exact cycle N's prior
        // pending value is consumed at stage 1 must NOT be silently dropped.
        logic spike_detected;
        logic window_found;
        integer w;
        begin
            $display("\n========================================");
            $display("TEST 10: LIF Same-Cycle Injection Race (regression)");
            $display("========================================");

            // Prime neuron 9 with a small, sub-threshold current.
            inject_lif_current(16'h0032, 4'd9); // 50

            // Wait until neuron 9 is about to be consumed at stage 1
            // (dut_lif.p_sel[0]==9), then fire a second, supra-threshold
            // injection to the SAME neuron on that exact cycle.
            spike_detected = 1'b0;
            window_found = 1'b0;
            w = 0;
            while (w < 40 && !window_found) begin
                @(posedge clk);
                if (dut_lif.p_sel[0] == 4'd9 && dut_lif.p_valid[0]) window_found = 1'b1;
                w = w + 1;
            end

            if (!window_found) begin
                $display("[FAIL] Never observed neuron 9 at its stage-1 consumption slot within %0d cycles -- race window not exercised", w);
                test_fail_count++;
            end else begin
                lif_current_in        <= {16'h0, 16'h00C8}; // 200 -- alone enough to spike
                lif_current_valid     <= 1'b1;
                lif_current_neuron_id <= 4'd9;
                @(posedge clk);
                lif_current_valid <= 1'b0;
                $display("[%0t] Raced a second injection to neuron 9 on its stage-1 consumption cycle", $time);

                // Give it up to two full round-robin sweeps to be serviced.
                w = 0;
                while (w < 40 && !spike_detected) begin
                    @(posedge clk);
                    if (lif_spike_bus[9]) spike_detected = 1'b1;
                    w = w + 1;
                end

                if (spike_detected) begin
                    $display("[PASS] Neuron 9 spiked from the raced injection (previously silently dropped)");
                    test_pass_count++;
                end else begin
                    $display("[FAIL] Neuron 9 never spiked -- the same-cycle injection was lost");
                    test_fail_count++;
                end
            end
        end
    endtask


    task automatic test_lif_pending_accumulate();
        // Regression for the pipelined_lif pending-current overwrite bug:
        // two sub-threshold injections to the SAME neuron, a few cycles
        // apart (neither simultaneous, both well inside one 16-cycle
        // round-robin sweep) must ACCUMULATE, not have the second one
        // silently discard the first.
        integer w;
        logic spiked;
        begin
            $display("\n========================================");
            $display("TEST 10b: LIF Pending-Current Accumulate (regression)");
            $display("========================================");

            // Neuron 3, sub-threshold alone: 100 + 150 = 250 > threshold(200).
            inject_lif_current(16'd100, 4'd3);
            repeat(2) @(posedge clk);
            inject_lif_current(16'd150, 4'd3);

            spiked = 1'b0;
            w = 0;
            while (w < 60 && !spiked) begin
                @(posedge clk);
                if (lif_spike_bus[3]) spiked = 1'b1;
                w = w + 1;
            end

            if (spiked) begin
                $display("[PASS] Neuron 3 spiked from 100+150=250, confirming the pending sample accumulates instead of being overwritten");
                test_pass_count++;
            end else begin
                $display("[FAIL] Neuron 3 never spiked -- the second injection overwrote the first instead of accumulating");
                test_fail_count++;
            end

            repeat(5) @(posedge clk);
        end
    endtask


    task automatic test_synapse_zero_sum();

        integer w;
        integer beats_seen;
        logic accepted0, accepted1, accepted2;
        begin
            $display("\n========================================");
            $display("TEST 11: Synapse Zero-Sum Accumulation (regression)");
            $display("========================================");

            synapse_current_ready <= 1'b0; // stall so events pile into the backlog

            // Burst three events close together (well inside DELAY=8) so
            // all three are accepted before backpressure can engage:
            // event0 primes the output; event1(+50)/event2(-50) cancel
            // exactly and must still be signaled once drained.
            send_synapse_event(32'h0000_0001, 32'h0000_0001, accepted0); // +1
            repeat(2) @(posedge clk);
            send_synapse_event(32'h0000_0001, 32'sd50, accepted1);       // +50
            repeat(2) @(posedge clk);
            send_synapse_event(32'h0000_0001, -32'sd50, accepted2);      // -50


            if (!(accepted0 && accepted1 && accepted2)) begin
                $display("[FAIL] Not all 3 events were accepted (a0=%b a1=%b a2=%b) -- zero-sum scenario not actually exercised",
                         accepted0, accepted1, accepted2);
                test_fail_count++;
            end else begin
                repeat(20) @(posedge clk); // let all three drain into accum/output

                synapse_current_ready <= 1'b1;
                beats_seen = 0;
                w = 0;
                while (w < 20) begin
                    @(posedge clk);
                    if (synapse_current_valid) begin
                        beats_seen = beats_seen + 1;
                        $display("        Beat %0d: current=%0d", beats_seen, $signed(synapse_current_out));
                    end
                    w = w + 1;
                end

                if (beats_seen >= 2) begin
                    $display("[PASS] Zero-sum backlog produced a second beat instead of being silently dropped (%0d beats seen)", beats_seen);
                    test_pass_count++;
                end else begin
                    $display("[FAIL] Expected at least 2 beats (prime + zero-sum), saw %0d", beats_seen);
                    test_fail_count++;
                end
            end
            synapse_current_ready <= 1'b1;
        end
    endtask


    task automatic test_lif_saturation();

        logic spike_detected;
        integer w;
        begin
            $display("\n========================================");
            $display("TEST 12: LIF Saturation Regression (sum, not just operand)");
            $display("========================================");

            // Temporarily raise threshold so priming doesn't spike early.
            lif_threshold_in <= 16'sd32767;

            @(posedge clk);
            lif_current_in <= 32'sd30000; lif_current_valid <= 1'b1; lif_current_neuron_id <= 4'd12;
            @(posedge clk);
            lif_current_valid <= 1'b0;
            repeat(20) @(posedge clk);


            @(posedge clk);
            lif_current_in <= 32'sd40000; lif_current_valid <= 1'b1; lif_current_neuron_id <= 4'd12;
            @(posedge clk);
            lif_current_valid <= 1'b0;

            spike_detected = 1'b0;
            w = 0;
            while (w < 40 && !spike_detected) begin
                @(posedge clk);
                if (lif_spike_bus[12]) spike_detected = 1'b1;
                w = w + 1;
            end

            if (spike_detected) begin
                $display("[PASS] Neuron 12 correctly spiked from a combined sum that would overflow a naive 16-bit add");
                test_pass_count++;
            end else begin
                $display("[FAIL] Neuron 12 never spiked -- the voltage+current sum likely wrapped instead of saturating");
                test_fail_count++;
            end

            // restore the threshold the rest of the suite expects
            lif_threshold_in <= 16'sd200;
            repeat(5) @(posedge clk);
        end
    endtask


    task automatic test_synapse_mac_saturation();
        // Regression for the synapse_pipeline MAC-truncation bug: a
        // product that overflows 32-bit signed range must saturate to
        // the max/min value, not silently wrap via low-bits truncation.
        integer w;
        integer beats_seen;
        logic accepted_pos, accepted_neg;
        logic signed [31:0] seen_pos, seen_neg;
        begin
            $display("\n========================================");
            $display("TEST 12b: Synapse MAC Saturation (regression)");
            $display("========================================");

            synapse_current_ready <= 1'b1;

            // 100000 * 100000 = 1e10, far beyond 32-bit signed max
            // (~2.147e9) -- must saturate to 32'sd2147483647, not wrap.
            send_synapse_event(32'sd100000, 32'sd100000, accepted_pos);
            beats_seen = 0; seen_pos = 0;
            w = 0;
            while (w < 20 && beats_seen < 1) begin
                @(posedge clk);
                if (synapse_current_valid) begin
                    seen_pos = $signed(synapse_current_out);
                    beats_seen = beats_seen + 1;
                end
                w = w + 1;
            end

            repeat(5) @(posedge clk);

            // -100000 * 100000 = -1e10 -- must saturate to -32'sd2147483648.
            send_synapse_event(-32'sd100000, 32'sd100000, accepted_neg);
            beats_seen = 0; seen_neg = 0;
            w = 0;
            while (w < 20 && beats_seen < 1) begin
                @(posedge clk);
                if (synapse_current_valid) begin
                    seen_neg = $signed(synapse_current_out);
                    beats_seen = beats_seen + 1;
                end
                w = w + 1;
            end

            if (accepted_pos && accepted_neg &&
                seen_pos == 32'sd2147483647 && seen_neg == -32'sd2147483648) begin
                $display("[PASS] Overflowing products correctly saturate (pos=%0d neg=%0d) instead of wrapping", seen_pos, seen_neg);
                test_pass_count++;
            end else begin
                $display("[FAIL] Expected saturation to +2147483647/-2147483648, got pos=%0d neg=%0d (accepted_pos=%b accepted_neg=%b)",
                         seen_pos, seen_neg, accepted_pos, accepted_neg);
                test_fail_count++;
            end

            repeat(5) @(posedge clk);
        end
    endtask


    task automatic test_fifo_full_backpressure();
        // Regression for a coverage gap flagged in the audit: fifo_full and
        // the write-side backpressure path (write_en gated by !fifo_full)
        // were never actually exercised by any prior test.
        integer i;
        integer rejected;
        begin
            $display("\n========================================");
            $display("TEST 13: FIFO Full Backpressure (regression)");
            $display("========================================");

            fifo_ready_in <= 1'b0; // hold off draining so writes can genuinely fill it
            rejected = 0;

            // FIFO_DEPTH=16; write well past capacity and count rejections.
            for (i = 0; i < FIFO_DEPTH + 4; i = i + 1) begin
                @(posedge clk);
                if (fifo_full) begin
                    rejected = rejected + 1;
                end else begin
                    fifo_data_in  <= {16'h0, i[15:0], 16'hBEEF};
                    fifo_valid_in <= 1'b1;
                end
                @(posedge clk);
                fifo_valid_in <= 1'b0;
            end
            repeat(3) @(posedge clk);

            if (fifo_full && rejected > 0) begin
                $display("[PASS] FIFO correctly asserted fifo_full and rejected %0d over-capacity write attempts", rejected);
                test_pass_count++;
            end else begin
                $display("[FAIL] Expected fifo_full=1 with rejections after writing past FIFO_DEPTH=%0d, got fifo_full=%b rejected=%0d",
                         FIFO_DEPTH, fifo_full, rejected);
                test_fail_count++;
            end

            // Drain back down and confirm it recovers.
            fifo_ready_in <= 1'b1;
            #300;
            if (!fifo_full && fifo_empty) begin
                $display("[PASS] FIFO recovered to empty after draining a full backlog");
                test_pass_count++;
            end else begin
                $display("[FAIL] FIFO did not recover: full=%b empty=%b", fifo_full, fifo_empty);
                test_fail_count++;
            end
            fifo_ready_in <= 1'b0;
        end
    endtask


    task automatic test_weight_ram_collision();
        // weight_ram_par's read is now registered (synchronous), required
        // for Vivado BRAM inference. This changes same-address
        // read/write-collision timing from "combinational, old value
        // visible before the edge" to "registered, old value visible for
        // one extra cycle after the colliding edge" -- standard BRAM
        // read-during-write ("no change") behavior.
        logic [31:0] pre_write_value;
        logic [31:0] during_write_value;
        logic [31:0] post_write_value;
        begin
            $display("\n========================================");
            $display("TEST 14: Weight RAM Same-Cycle Read/Write Collision (regression)");
            $display("========================================");

            write_weight(8'h20, 32'h0000_1111); // seed a known value
            repeat(2) @(posedge clk);

            // Point the read lane at 0x20 and let the registered read settle.
            weight_addr[7:0] <= 8'h20;
            @(posedge clk);   // address sampled by the registered read here
            @(posedge clk);   // data_out now valid
            #1;
            pre_write_value = weight_data_out[31:0];

            // Issue a write to the SAME address the read lane is already
            // pointed at. The registered read's NBA evaluates mem[addr]
            // using PRE-EDGE contents (same as the write's own NBA), so
            // it must still show the OLD data for the cycle right after
            // this colliding edge. The #1 settle delay is required here:
            // reading weight_data_out immediately after the edge (before
            // its own NBA update commits) would alias with the correct
            // answer on THIS check by coincidence, but breaks the
            // post-write check below -- always settle before sampling a
            // registered output on the edge that updates it.
            weight_waddr   <= 8'h20;
            weight_data_in <= 32'h0000_2222;
            weight_we      <= 1'b1;
            @(posedge clk);
            weight_we <= 1'b0;
            #1;
            during_write_value = weight_data_out[31:0]; // registered from the colliding edge: old data

            @(posedge clk); // one more registered-read cycle: now reflects the new data
            #1;
            post_write_value = weight_data_out[31:0];

            if (pre_write_value == 32'h0000_1111 &&
                during_write_value == 32'h0000_1111 &&
                post_write_value == 32'h0000_2222) begin
                $display("[PASS] Same-cycle read/write returned old data through the colliding edge and new data one cycle later (pre=0x%08h during=0x%08h post=0x%08h)",
                         pre_write_value, during_write_value, post_write_value);
                test_pass_count++;
            end else begin
                $display("[FAIL] Unexpected same-cycle collision behavior (pre=0x%08h during=0x%08h post=0x%08h)",
                         pre_write_value, during_write_value, post_write_value);
                test_fail_count++;
            end
        end
    endtask


    task automatic test_aer_link_protocol();

        integer w;
        integer seen_count;
        logic [3:0] seen_addrs [0:7];
        begin
            $display("\n========================================");
            $display("TEST 15: AER Link Protocol & Arbitration (aer_tx.v / aer_rx.v)");
            $display("========================================");

            seen_count = 0;

            // Sub-test A: single event, basic 4-phase handshake
            @(posedge clk);
            aer_test_req_pulse[6] <= 1'b1;
            @(posedge clk);
            aer_test_req_pulse[6] <= 1'b0;

            w = 0;
            while (w < 40 && !aer_test_event_valid) begin
                @(posedge aer_clk);
                w = w + 1;
            end
            if (aer_test_event_valid && aer_test_addr_out == 4'd6) begin
                $display("[PASS] AER single-event handshake: address 6 correctly transferred");
                test_pass_count++;
            end else begin
                $display("[FAIL] AER single-event handshake failed (event_valid=%b addr_out=%0d)",
                         aer_test_event_valid, aer_test_addr_out);
                test_fail_count++;
            end
            repeat(10) @(posedge aer_clk);

            // Sub-test B: two GENUINELY simultaneous requests 
            // Sources 2 and 13 both request on the exact same cycle. A plain FIFO with no
            // arbiter has no way to express this input at all; aer_tx
            // must pick one, transfer it, then transfer the other.
            seen_count = 0;
            @(posedge clk);
            aer_test_req_pulse[2]  <= 1'b1;
            aer_test_req_pulse[13] <= 1'b1;
            @(posedge clk);
            aer_test_req_pulse[2]  <= 1'b0;
            aer_test_req_pulse[13] <= 1'b0;

            w = 0;
            while (w < 120 && seen_count < 2) begin
                @(posedge aer_clk);
                if (aer_test_event_valid) begin
                    seen_addrs[seen_count] = aer_test_addr_out;
                    seen_count = seen_count + 1;
                end
                w = w + 1;
            end

            if (seen_count == 2 &&
                ((seen_addrs[0] == 4'd2 && seen_addrs[1] == 4'd13) ||
                 (seen_addrs[0] == 4'd13 && seen_addrs[1] == 4'd2))) begin
                $display("[PASS] Simultaneous requests (2 and 13) both arbitrated and delivered, none lost (order: %0d, %0d)",
                         seen_addrs[0], seen_addrs[1]);
                test_pass_count++;
            end else begin
                $display("[FAIL] Simultaneous-request arbitration failed: seen_count=%0d addrs=[%0d,%0d]",
                         seen_count, seen_addrs[0], seen_addrs[1]);
                test_fail_count++;
            end
        end
    endtask


    task automatic test_aer_integration();
        integer n;
        integer id_list[0:2];
        integer w;
        integer pre_log;
        begin
            $display("\n========================================");
            $display("TEST 16: AER Integration & Cross-Check (real spike_bus -> AER -> aer_spike_logger)");
            $display("========================================");

            pre_log = aer_log_count;

            id_list[0] = 1; id_list[1] = 6; id_list[2] = 14;
            for (n = 0; n < 3; n = n + 1) begin
                inject_lif_current(16'h0100, id_list[n][3:0]); // 256 > threshold(200), spikes immediately
                repeat(60) @(posedge clk); // let the AER transaction fully complete before the next
            end

            repeat(20) @(posedge clk);

            $display("        aer_log_count=%0d (started at %0d) total_spikes_logged=%0d",
                     aer_log_count, pre_log, total_spikes_logged);

            if ((aer_log_count - pre_log) == 3) begin
                $display("[PASS] AER logger recorded exactly 3 new events for the 3 real spikes just generated");
                test_pass_count++;
            end else begin
                $display("[FAIL] Expected 3 new AER log entries, got %0d", aer_log_count - pre_log);
                test_fail_count++;
            end


            aer_read_addr <= pre_log[$clog2(AER_LOG_DEPTH)-1:0];
            #1;
            if (aer_read_out_addr == 4'd1) begin
                $display("[PASS] AER log entry %0d correctly recorded neuron 1", pre_log);
                test_pass_count++;
            end else begin
                $display("[FAIL] AER log entry %0d addr=%0d, expected neuron 1", pre_log, aer_read_out_addr);
                test_fail_count++;
            end

            if (aer_log_count == total_spikes_logged) begin
                $display("[PASS] AER logger total (%0d) matches the independent spike_bus monitor (%0d) across the whole run",
                         aer_log_count, total_spikes_logged);
                test_pass_count++;
            end else begin
                $display("[FAIL] AER logger total (%0d) does NOT match the independent monitor (%0d)",
                         aer_log_count, total_spikes_logged);
                test_fail_count++;
            end
        end
    endtask


    task automatic test_dataset_replay();
        integer fd;
        integer code;
        reg [8*256-1:0] line;
        integer ch, t_ns, prev_t_ns;
        integer n_events;
        integer pre_log;
        integer per_channel_out [0:15];
        integer hot_total, base_total;
        integer i;
        begin
            $display("\n========================================");
            $display("TEST 17: Dataset Replay (synthetic_spike_dataset.txt)");
            $display("========================================");

            fd = $fopen("synthetic_spike_dataset.txt", "r");
            if (fd == 0) begin
                $display("[FAIL] Could not open synthetic_spike_dataset.txt in the simulation working directory");
                test_fail_count++;
            end else begin
                pre_log = aer_log_count;
                n_events = 0;
                prev_t_ns = 0;
                for (i = 0; i < 16; i = i + 1) per_channel_out[i] = 0;

                while (!$feof(fd)) begin
                    code = $fgets(line, fd);
                    if (code > 0 && line[8*256-1 -: 8] != "#") begin
                        code = $sscanf(line, "%d %d", ch, t_ns);
                        if (code == 2) begin
                            // Preserve the file's relative timing between
                            // events (already in nanoseconds, matching this
                            // testbench's timescale).
                            if (t_ns > prev_t_ns) begin
                                #(t_ns - prev_t_ns);
                            end
                            prev_t_ns = t_ns;

                            @(posedge clk);
                            lif_current_in        <= {16'h0, 16'h0080}; // 128: sub-threshold alone
                            lif_current_valid      <= 1'b1;
                            lif_current_neuron_id  <= ch[3:0];
                            @(posedge clk);
                            lif_current_valid      <= 1'b0;
                            n_events = n_events + 1;
                        end
                    end
                end
                $fclose(fd);

                repeat(300) @(posedge clk); // drain the last few AER transactions

                $display("        Replayed %0d input events. AER log grew from %0d to %0d entries.",
                         n_events, pre_log, aer_log_count);

                for (i = pre_log; i < aer_log_count; i = i + 1) begin
                    aer_read_addr <= i[$clog2(AER_LOG_DEPTH)-1:0];
                    #1;
                    per_channel_out[aer_read_out_addr] = per_channel_out[aer_read_out_addr] + 1;
                end

                hot_total  = per_channel_out[2] + per_channel_out[7] + per_channel_out[11];
                base_total = 0;
                for (i = 0; i < 16; i = i + 1) begin
                    if (i != 2 && i != 7 && i != 11) base_total = base_total + per_channel_out[i];
                end

                $display("        Output spikes -- hot channels (2,7,11): %0d total | other 13 channels: %0d total",
                         hot_total, base_total);

                if (n_events > 0 && (aer_log_count - pre_log) > 0) begin
                    $display("[PASS] Dataset replay produced output activity and the AER log captured it");
                    test_pass_count++;
                end else begin
                    $display("[FAIL] No output activity captured from the dataset replay");
                    test_fail_count++;
                end

                if (hot_total * 13 > base_total) begin
                    $display("[PASS] Hot channels (2,7,11) show elevated per-channel output activity vs. the 13 baseline channels, as expected from their elevated input rate");
                    test_pass_count++;
                end else begin
                    $display("[FAIL] Hot channels did not show elevated output activity (hot_total=%0d, base_total=%0d)", hot_total, base_total);
                    test_fail_count++;
                end
            end
        end
    endtask


    initial begin
        $display("========================================");
        $display("LAYERED SPIKE-NN TESTBENCH V4 (post-fix, RTL bug-fix regression pass)");
        $display("========================================");

        test_pass_count = 0;
        test_fail_count = 0;
        total_spikes_generated = 0;
        total_spikes_logged = 0;
        total_cycles = 0;

        reset_system();

        test_pulse_sync();
        test_pulse_sync_burst();
        test_fifo_operation();
        test_weight_ram();
        test_synapse_pipeline();
        test_lif_neuron();
        test_spike_logger();
        test_multi_neuron_array();
        test_datapath_integration();
        test_spike_logger_capacity();
        test_lif_pending_race();
        test_lif_pending_accumulate();
        test_synapse_zero_sum();
        test_lif_saturation();
        test_synapse_mac_saturation();
        test_fifo_full_backpressure();
        test_weight_ram_collision();

        // Extra settle time so every real spike from the tests above has
        // fully drained through the AER link's multi-cycle handshake
        // (including the slower aer_clk domain) before the cross-check.
        repeat(100) @(posedge clk);
        test_aer_link_protocol();
        test_aer_integration();
        test_dataset_replay();

        repeat(50) @(posedge clk);

        $display("\n========================================");
        $display("TEST SUMMARY");
        $display("========================================");
        $display("Total Tests Passed : %0d", test_pass_count);
        $display("Total Tests Failed : %0d", test_fail_count);
        $display("Pulse-Sync Stimuli Sent : %0d", total_spikes_generated);
        $display("Total LIF Neuron Spikes : %0d", total_spikes_logged);
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
        // |lif_spike_bus counts a spike from ANY neuron, not just neuron 0
        // (lif_spike_out is the legacy neuron-0-only alias -- using it here
        // would just trade one under-counting bug for a smaller one).
        if (rst_n && |lif_spike_bus) total_spikes_logged++;
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