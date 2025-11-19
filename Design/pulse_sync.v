`timescale 1ns / 1ps
module pulse_sync #(
    parameter WIDTH = 8
)(
    input wire clk,
    input wire rst_n,
    input wire [WIDTH-1:0] pulse_in,
    output reg [WIDTH-1:0] pulse_out,
    output reg sync_valid
);

    reg [WIDTH-1:0] sync_reg1, sync_reg2, sync_reg3;
    reg [WIDTH-1:0] pulse_last;
    
    // Sequential block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_reg1 <= {WIDTH{1'b0}};
            sync_reg2 <= {WIDTH{1'b0}};
            sync_reg3 <= {WIDTH{1'b0}};
            pulse_out <= {WIDTH{1'b0}};
            pulse_last <= {WIDTH{1'b0}};
            sync_valid <= 1'b0;
        end else begin
            // Three-stage synchronizer
            sync_reg1 <= pulse_in;
            sync_reg2 <= sync_reg1;
            sync_reg3 <= sync_reg2;
            
            // Detect edge (change from previous)
            if (sync_reg3 != pulse_last && sync_reg3 != {WIDTH{1'b0}}) begin
                pulse_out <= sync_reg3;
                pulse_last <= sync_reg3;
                sync_valid <= 1'b1;
            end else begin
                sync_valid <= 1'b0;
            end
        end
    end

endmodule
