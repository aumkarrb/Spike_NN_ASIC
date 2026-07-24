`timescale 1ns/1ps
module pulse_sync #(
    parameter WIDTH = 8
)(
    
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire [WIDTH-1:0] pulse_in,
    input  wire             pulse_valid_in,  
    
    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output reg  [WIDTH-1:0] pulse_out,
    output reg              sync_valid
);

 
    reg [WIDTH-1:0] data_reg;
    reg             toggle;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            data_reg <= {WIDTH{1'b0}};
            toggle   <= 1'b0;
        end else if (pulse_valid_in) begin
            data_reg <= pulse_in;
            toggle   <= ~toggle;   // toggles even if pulse_in repeats
        end
    end

    reg toggle_sync1, toggle_sync2, toggle_sync3;
    reg [WIDTH-1:0] data_sync1, data_sync2;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            toggle_sync1 <= 1'b0;
            toggle_sync2 <= 1'b0;
            toggle_sync3 <= 1'b0;
            data_sync1   <= {WIDTH{1'b0}};
            data_sync2   <= {WIDTH{1'b0}};
            pulse_out    <= {WIDTH{1'b0}};
            sync_valid   <= 1'b0;
        end else begin
            
            toggle_sync1 <= toggle;
            toggle_sync2 <= toggle_sync1;
            toggle_sync3 <= toggle_sync2;

            data_sync1 <= data_reg;
            data_sync2 <= data_sync1;

            sync_valid <= (toggle_sync2 != toggle_sync3);
            if (toggle_sync2 != toggle_sync3) begin
                pulse_out <= data_sync2;
            end
        end
    end

endmodule
