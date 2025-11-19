`timescale 1ns/1ps
module synapse_pipeline #(
    parameter WIDTH = 32,
    parameter DELAY = 8
)(
    input wire clk,
    input wire rst_n,
    input wire [WIDTH-1:0] event_data,
    input wire event_valid,
    output reg event_ready,
    input wire [WIDTH-1:0] weight_in,
    output reg [WIDTH-1:0] current_out,
    output reg current_valid,
    input wire current_ready
);

    // Pipeline stages
    reg [WIDTH-1:0] pipe_data_0, pipe_data_1, pipe_data_2, pipe_data_3;
    reg [WIDTH-1:0] pipe_data_4, pipe_data_5, pipe_data_6, pipe_data_7;
    reg pipe_valid_0, pipe_valid_1, pipe_valid_2, pipe_valid_3;
    reg pipe_valid_4, pipe_valid_5, pipe_valid_6, pipe_valid_7;
    reg [WIDTH-1:0] pipe_weight_0, pipe_weight_1, pipe_weight_2, pipe_weight_3;
    reg [WIDTH-1:0] pipe_weight_4, pipe_weight_5, pipe_weight_6, pipe_weight_7;
    
    // Sequential block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_data_0 <= {WIDTH{1'b0}};
            pipe_data_1 <= {WIDTH{1'b0}};
            pipe_data_2 <= {WIDTH{1'b0}};
            pipe_data_3 <= {WIDTH{1'b0}};
            pipe_data_4 <= {WIDTH{1'b0}};
            pipe_data_5 <= {WIDTH{1'b0}};
            pipe_data_6 <= {WIDTH{1'b0}};
            pipe_data_7 <= {WIDTH{1'b0}};
            
            pipe_valid_0 <= 1'b0;
            pipe_valid_1 <= 1'b0;
            pipe_valid_2 <= 1'b0;
            pipe_valid_3 <= 1'b0;
            pipe_valid_4 <= 1'b0;
            pipe_valid_5 <= 1'b0;
            pipe_valid_6 <= 1'b0;
            pipe_valid_7 <= 1'b0;
            
            pipe_weight_0 <= {WIDTH{1'b0}};
            pipe_weight_1 <= {WIDTH{1'b0}};
            pipe_weight_2 <= {WIDTH{1'b0}};
            pipe_weight_3 <= {WIDTH{1'b0}};
            pipe_weight_4 <= {WIDTH{1'b0}};
            pipe_weight_5 <= {WIDTH{1'b0}};
            pipe_weight_6 <= {WIDTH{1'b0}};
            pipe_weight_7 <= {WIDTH{1'b0}};
            
            current_out <= {WIDTH{1'b0}};
            current_valid <= 1'b0;
        end else begin
            // Input stage
            pipe_data_0 <= event_data;
            pipe_valid_0 <= event_valid;
            pipe_weight_0 <= weight_in;
            
            // Pipeline propagation
            pipe_data_1 <= pipe_data_0;
            pipe_valid_1 <= pipe_valid_0;
            pipe_weight_1 <= pipe_weight_0;
            
            pipe_data_2 <= pipe_data_1;
            pipe_valid_2 <= pipe_valid_1;
            pipe_weight_2 <= pipe_weight_1;
            
            pipe_data_3 <= pipe_data_2;
            pipe_valid_3 <= pipe_valid_2;
            pipe_weight_3 <= pipe_weight_2;
            
            pipe_data_4 <= pipe_data_3;
            pipe_valid_4 <= pipe_valid_3;
            pipe_weight_4 <= pipe_weight_3;
            
            pipe_data_5 <= pipe_data_4;
            pipe_valid_5 <= pipe_valid_4;
            pipe_weight_5 <= pipe_weight_4;
            
            pipe_data_6 <= pipe_data_5;
            pipe_valid_6 <= pipe_valid_5;
            pipe_weight_6 <= pipe_weight_5;
            
            pipe_data_7 <= pipe_data_6;
            pipe_valid_7 <= pipe_valid_6;
            pipe_weight_7 <= pipe_weight_6;
            
            // Output stage - multiply weight by event data
            if (pipe_valid_7) begin
                current_out <= pipe_weight_7;  // Direct weight output
                current_valid <= 1'b1;
            end else begin
                current_out <= {WIDTH{1'b0}};
                current_valid <= 1'b0;
            end
        end
    end
    
    // Combinational block
    always @(*) begin
        event_ready = 1'b1;
    end

endmodule