`timescale 1ns/1ps

module spike_nn_tb_layered;

    parameter CLK_PERIOD = 10;
    parameter FIFO_DEPTH = 16;
    parameter WEIGHT_DEPTH = 256;
    parameter LOG_DEPTH = 256;
    parameter NUM_NEURONS = 16;
    

    logic clk;
    logic rst_n;
    
    // Pulse sync interface
    logic [15:0] pulse_in;
    logic [15:0] pulse_sync_out;
    logic pulse_sync_valid;
    
    // FIFO interface
    logic [47:0] fifo_data_in;
    logic fifo_valid_in;
    logic fifo_ready_out;
    logic [47:0] fifo_data_out;
    logic fifo_valid_out;
    logic fifo_ready_in;
    logic fifo_full;
    logic fifo_empty;
    
    // Weight RAM interface
    logic [7:0] weight_addr;
    logic [31:0] weight_data_out;
    logic [31:0] weight_data_in;
    logic weight_we;
    
    // Synapse pipeline interface
    logic [31:0] synapse_event_data;
    logic synapse_event_valid;
    logic synapse_event_ready;
    logic [31:0] synapse_weight_in;
    logic [31:0] synapse_current_out;
    logic synapse_current_valid;
    logic synapse_current_ready;
    
    // LIF neuron interface
    logic [31:0] lif_current_in;
    logic lif_current_valid;
    logic lif_spike_out;
    logic [15:0] lif_voltage_out;
    logic [NUM_NEURONS-1:0] lif_voltage_bus;
    
    // Spike logger interface
    logic logger_spike_in;
    logic logger_valid_in;
    logic logger_ready_out;
    logic [7:0] logger_count; 
    logic logger_overflow;
    
   
    pulse_sync #(
        .WIDTH(16)
    ) dut_pulse_sync (
        .clk(clk),
        .rst_n(rst_n),
        .pulse_in(pulse_in),
        .pulse_out(pulse_sync_out),
        .sync_valid(pulse_sync_valid)
    );
    
    event_fifo #(
        .DEPTH(FIFO_DEPTH),
        .WIDTH(48)
    ) dut_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(fifo_data_in),
        .valid_in(fifo_valid_in),
        .ready_out(fifo_ready_out),
        .data_out(fifo_data_out),
        .valid_out(fifo_valid_out),
        .ready_in(fifo_ready_in),
        .fifo_full(fifo_full),
        .fifo_empty(fifo_empty)
    );
    
    weight_ram_par #(
        .DEPTH(WEIGHT_DEPTH),
        .WIDTH(32)
    ) dut_weight_ram (
        .clk(clk),
        .addr(weight_addr),
        .data_out(weight_data_out),
        .data_in(weight_data_in),
        .we(weight_we)
    );
    
    synapse_pipeline #(
        .WIDTH(32),
        .DELAY(8)
    ) dut_synapse (
        .clk(clk),
        .rst_n(rst_n),
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
        .clk(clk),
        .rst_n(rst_n),
        .current_in(lif_current_in),
        .current_valid(lif_current_valid),
        .spike_out(lif_spike_out),
        .voltage_out(lif_voltage_out),
        .voltage_bus(lif_voltage_bus)
    );
    
    spike_logger #(
        .DEPTH(LOG_DEPTH)
    ) dut_logger (
        .clk(clk),
        .rst_n(rst_n),
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
    
   
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    task automatic reset_system();
        begin
            $display("[%0t] === RESET SYSTEM ===", $time);
            rst_n = 0;
            
            // Initialize all inputs
            pulse_in = 16'h0000;
            fifo_data_in = 48'h0;
            fifo_valid_in = 1'b0;
            fifo_ready_in = 1'b1;
            weight_addr = 8'h00;
            weight_data_in = 32'h0;
            weight_we = 1'b0;
            synapse_event_data = 32'h0;
            synapse_event_valid = 1'b0;
            synapse_current_ready = 1'b1;
            synapse_weight_in = 32'h0010;
            lif_current_in = 32'h0;
            lif_current_valid = 1'b0;
            logger_spike_in = 1'b0;
            logger_valid_in = 1'b0;
            
            repeat(10) @(posedge clk);
            rst_n = 1;
            repeat(5) @(posedge clk);
            $display("[%0t] Reset complete", $time);
        end
    endtask
    

    task automatic send_pulse(input [15:0] addr);
        begin
            @(posedge clk);
            pulse_in = addr;
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);  // Hold for multiple cycles
            pulse_in = 16'h0000;
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
                fifo_data_in = 48'h0;
                $display("[%0t] FIFO write: data=0x%012h", $time, data);
            end else begin
                $display("[%0t] FIFO write failed: FIFO full", $time);
            end
        end
    endtask
    
 
    task automatic write_weight(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            weight_addr = addr;
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
            weight_addr = addr;
            weight_we = 1'b0;
            @(posedge clk);
            @(posedge clk);  // Wait for read
            data = weight_data_out;
            $display("[%0t] Weight read: addr=0x%02h, data=0x%08h", $time, addr, data);
        end
    endtask
    

    task automatic send_synapse_event(input [31:0] event_data, input [31:0] weight);
        begin
            @(posedge clk);
            synapse_event_data = event_data;
            synapse_event_valid = 1'b1;
            synapse_weight_in = weight;
            @(posedge clk);
            synapse_event_valid = 1'b0;
            synapse_event_data = 32'h0;
            $display("[%0t] Synapse event sent: data=0x%08h, weight=0x%08h", $time, event_data, weight);
        end
    endtask
    
    task automatic inject_lif_current(input [15:0] current);
        begin
            @(posedge clk);
            lif_current_in = {16'h0, current};
            lif_current_valid = 1'b1;
            @(posedge clk);
            // Check spike on same cycle as valid goes low
            if (lif_spike_out) begin
                $display("[%0t] LIF current injected: 0x%04h - SPIKE DETECTED!", $time, current);
            end else begin
                $display("[%0t] LIF current injected: 0x%04h", $time, current);
            end
            lif_current_valid = 1'b0;
            lif_current_in = 32'h0;
        end
    endtask
    

    task automatic wait_for_spike(input int max_cycles, output logic spike_detected);
        int cycle_cnt;
        begin
            cycle_cnt = 0;
            spike_detected = 1'b0;
            while (cycle_cnt < max_cycles) begin
                @(posedge clk);
                if (lif_spike_out) begin
                    $display("[%0t] *** SPIKE DETECTED *** Voltage: 0x%04h", $time, lif_voltage_out);
                    spike_detected = 1'b1;
                    return;
                end
                cycle_cnt++;
            end
            $display("[%0t] No spike detected within %0d cycles", $time, max_cycles);
        end
    endtask

    task automatic test_pulse_sync();
        int check_cycles;
        logic found_valid;
        begin
            $display("\n========================================");
            $display("TEST 1: Pulse Synchronization");
            $display("========================================");
            
            send_pulse(16'hABCD);
            
            // Check for valid within reasonable time
            check_cycles = 0;
            found_valid = 1'b0;
            while (check_cycles < 10) begin
                @(posedge clk);
                if (pulse_sync_valid) begin
                    found_valid = 1'b1;
                    break;
                end
                check_cycles++;
            end
            
            if (found_valid) begin
                $display("[PASS] Pulse sync generated valid signal at cycle %0d", check_cycles);
                test_pass_count++;
            end else begin
                $display("[FAIL] Pulse sync did not generate valid");
                test_fail_count++;
            end
            
            repeat(5) @(posedge clk);
            
            send_pulse(16'h1234);
            repeat(10) @(posedge clk);
            
            send_pulse(16'h5678);
            repeat(10) @(posedge clk);
        end
    endtask
    
    
    task automatic test_fifo_operation();
        int i;
        int items_written;
        begin
            $display("\n========================================");
            $display("TEST 2: FIFO Operation");
            $display("========================================");
            
            items_written = 0;
            
            // Write multiple entries
            i = 0;
            while (i < 10) begin
                write_fifo({16'h0, i[15:0], 16'h0100 + i[15:0]});
                if (fifo_ready_out) begin
                    items_written = items_written + 1;
                end
                @(posedge clk);  // Extra cycle for write to complete
                i = i + 1;
            end
            
            // Wait for writes to fully settle
            repeat(10) @(posedge clk);
            
            // Check FIFO status
            $display("        FIFO status: items_written=%0d, empty=%b, full=%b, valid_out=%b", 
                     items_written, fifo_empty, fifo_full, fifo_valid_out);
            
            if (!fifo_empty && fifo_valid_out) begin
                $display("[PASS] FIFO contains data - empty=%b, valid_out=%b", fifo_empty, fifo_valid_out);
                test_pass_count++;
            end else begin
                $display("[FAIL] FIFO empty=%b, valid_out=%b (wrote %0d items)", 
                         fifo_empty, fifo_valid_out, items_written);
                test_fail_count++;
            end
            
            // Read entries
            fifo_ready_in = 1'b1;
            repeat(15) @(posedge clk);
            fifo_ready_in = 1'b0;  // Stop reading
        end
    endtask
    
    task automatic test_weight_ram();
        logic [31:0] read_data;
        int addr_idx;
        begin
            $display("\n========================================");
            $display("TEST 3: Weight RAM Access");
            $display("========================================");
            
            // Write weights
            addr_idx = 0;
            while (addr_idx < 8) begin
                write_weight(addr_idx[7:0], 32'h0000_0020 + addr_idx);
                addr_idx = addr_idx + 1;
            end
            
            repeat(5) @(posedge clk);
            
            // Read back and verify
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
        end
    endtask
    

    task automatic test_synapse_pipeline();
        int event_idx;
        int wait_cycles;
        logic found_output;
        begin
            $display("\n========================================");
            $display("TEST 4: Synapse Pipeline");
            $display("========================================");
            
            event_idx = 0;
            while (event_idx < 5) begin
                send_synapse_event(32'h0000_0001, 32'h0000_0030);
                repeat(2) @(posedge clk);
                event_idx = event_idx + 1;
            end
            
            // Wait for pipeline delay (8 stages) plus margin
            wait_cycles = 0;
            found_output = 1'b0;
            while (wait_cycles < 20) begin
                @(posedge clk);
                if (synapse_current_valid) begin
                    found_output = 1'b1;
                    $display("        Synapse output at cycle %0d: current=0x%08h", wait_cycles, synapse_current_out);
                end
                wait_cycles++;
            end
            
            if (found_output) begin
                $display("[PASS] Synapse pipeline produced output");
                test_pass_count++;
            end else begin
                $display("[FAIL] No synapse output detected");
                test_fail_count++;
            end
        end
    endtask
    

    task automatic test_lif_neuron();
        int inj_idx;
        logic spike_detected;
        begin
            $display("\n========================================");
            $display("TEST 5: LIF Neuron Operation");
            $display("========================================");
            
            spike_detected = 1'b0;
            
            // Inject multiple currents to reach threshold
            inj_idx = 0;
            while (inj_idx < 20 && !spike_detected) begin
                inject_lif_current(16'h0020);
                
                // Check immediately after injection
                @(posedge clk);
                $display("        Post-injection: Voltage: 0x%04h, Spike: %b", lif_voltage_out, lif_spike_out);
                
                if (lif_spike_out) begin
                    spike_detected = 1'b1;
                    $display("[PASS] Neuron spiked at injection %0d", inj_idx);
                    test_pass_count++;
                    break;
                end
                
                inj_idx = inj_idx + 1;
            end
            
            if (!spike_detected) begin
                $display("[FAIL] Neuron did not spike after %0d injections", inj_idx);
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
    
 
    initial begin
        $display("========================================");
        $display("LAYERED SPIKE-NN TESTBENCH V2");
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
    
    // 
    // Cycle counter
    always @(posedge clk) begin
        if (rst_n) total_cycles++;
    end
    
    // Spike monitor
    always @(posedge clk) begin
        if (rst_n && lif_spike_out) begin
            total_spikes_logged++;
        end
    end
    
    // FIFO overflow monitor
    always @(posedge clk) begin
        if (rst_n && fifo_full && fifo_valid_in) begin
            $display("[%0t] WARNING: FIFO overflow attempt", $time);
        end
    end
    
    // Logger overflow monitor
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