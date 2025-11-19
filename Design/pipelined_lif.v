`timescale 1ns/1ps
module pipelined_lif #(
    parameter Neurons = 16,
    parameter Pipeline_Stages = 4
)(
    input wire clk,
    input wire rst_n,
    input wire [31:0] current_in,
    input wire current_valid,
    output reg spike_out,
    output reg [15:0] voltage_out,
    output wire [Neurons-1:0] voltage_bus
);

    localparam signed [15:0] THRESHOLD = 16'sd200;
    localparam signed [15:0] RESET_VAL = 16'sd0;
    localparam LEAK_SHIFT = 5;

    // Neuron voltage states
    reg signed [15:0] neuron_v_0, neuron_v_1, neuron_v_2, neuron_v_3;
    reg signed [15:0] neuron_v_4, neuron_v_5, neuron_v_6, neuron_v_7;
    reg signed [15:0] neuron_v_8, neuron_v_9, neuron_v_10, neuron_v_11;
    reg signed [15:0] neuron_v_12, neuron_v_13, neuron_v_14, neuron_v_15;
    
    // Computation wires for neuron 0
    wire signed [15:0] leak_0 = neuron_v_0 >>> LEAK_SHIFT;
    wire signed [15:0] v_after_leak_0 = neuron_v_0 - leak_0;
    wire signed [15:0] current_contrib_0 = current_valid ? $signed(current_in[15:0]) : 16'sd0;
    wire signed [15:0] v_new_0 = v_after_leak_0 + current_contrib_0;
    wire will_spike_0 = (v_new_0 >= THRESHOLD);

    // Sequential block - Neuron 0 with proper spike generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            neuron_v_0 <= 16'sd0;
            spike_out <= 1'b0;
            voltage_out <= 16'h0;
        end else begin
            // Default: no spike
            spike_out <= 1'b0;
            
            if (will_spike_0) begin
                // Spike condition met
                neuron_v_0 <= RESET_VAL;
                spike_out <= 1'b1;  // Assert spike for one cycle
                voltage_out <= THRESHOLD;  // Show we reached threshold
            end else begin
                // Normal update
                neuron_v_0 <= v_new_0;
                voltage_out <= v_new_0[15:0];
            end
        end
    end

    // Neurons 1-3
    wire signed [15:0] leak_1 = neuron_v_1 >>> LEAK_SHIFT;
    wire signed [15:0] v_new_1 = neuron_v_1 - leak_1 + (current_valid ? $signed(current_in[15:0]) : 16'sd0);
    wire will_spike_1 = (v_new_1 >= THRESHOLD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            neuron_v_1 <= 16'sd0;
        end else begin
            neuron_v_1 <= will_spike_1 ? RESET_VAL : v_new_1;
        end
    end

    wire signed [15:0] leak_2 = neuron_v_2 >>> LEAK_SHIFT;
    wire signed [15:0] v_new_2 = neuron_v_2 - leak_2 + (current_valid ? $signed(current_in[15:0]) : 16'sd0);
    wire will_spike_2 = (v_new_2 >= THRESHOLD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            neuron_v_2 <= 16'sd0;
        end else begin
            neuron_v_2 <= will_spike_2 ? RESET_VAL : v_new_2;
        end
    end

    wire signed [15:0] leak_3 = neuron_v_3 >>> LEAK_SHIFT;
    wire signed [15:0] v_new_3 = neuron_v_3 - leak_3 + (current_valid ? $signed(current_in[15:0]) : 16'sd0);
    wire will_spike_3 = (v_new_3 >= THRESHOLD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            neuron_v_3 <= 16'sd0;
        end else begin
            neuron_v_3 <= will_spike_3 ? RESET_VAL : v_new_3;
        end
    end

    // Neurons 4-15 minimal
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            neuron_v_4 <= 16'sd0;
            neuron_v_5 <= 16'sd0;
            neuron_v_6 <= 16'sd0;
            neuron_v_7 <= 16'sd0;
            neuron_v_8 <= 16'sd0;
            neuron_v_9 <= 16'sd0;
            neuron_v_10 <= 16'sd0;
            neuron_v_11 <= 16'sd0;
            neuron_v_12 <= 16'sd0;
            neuron_v_13 <= 16'sd0;
            neuron_v_14 <= 16'sd0;
            neuron_v_15 <= 16'sd0;
        end
    end

    // Voltage bus output
    assign voltage_bus = {
        neuron_v_15[0], neuron_v_14[0], neuron_v_13[0], neuron_v_12[0],
        neuron_v_11[0], neuron_v_10[0], neuron_v_9[0], neuron_v_8[0],
        neuron_v_7[0], neuron_v_6[0], neuron_v_5[0], neuron_v_4[0],
        neuron_v_3[0], neuron_v_2[0], neuron_v_1[0], neuron_v_0[0]
    };

endmodule