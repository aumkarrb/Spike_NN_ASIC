`timescale 1ns/1ps
module weight_ram_par #(
    parameter DEPTH = 256,
    parameter WIDTH = 32
)(
    input wire clk,
    input wire [$clog2(DEPTH)-1:0] addr,
    output reg [WIDTH-1:0] data_out,
    input wire [WIDTH-1:0] data_in,
    input wire we
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    
    integer init_idx;
    initial begin
        init_idx = 0;
        while (init_idx < DEPTH) begin
            mem[init_idx] = 32'h0000_0010;
            init_idx = init_idx + 1;
        end
    end
    
    always @(posedge clk) begin
        if (we) begin
            mem[addr] <= data_in;
        end
    end
    
    always @(*) begin
        data_out = mem[addr];
    end

endmodule