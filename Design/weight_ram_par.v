`timescale 1ns/1ps
module weight_ram_par #(
    parameter DEPTH    = 256,
    parameter WIDTH    = 32,
    parameter RD_PORTS = 4        // number of parallel read lanes
)(
    input  wire                              clk,
    input  wire [RD_PORTS*$clog2(DEPTH)-1:0] addr,
    output reg  [RD_PORTS*WIDTH-1:0]         data_out,

    // single write port
    input  wire [$clog2(DEPTH)-1:0]          waddr,
    input  wire [WIDTH-1:0]                  data_in,
    input  wire                              we
);

    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // Synchronous write (single port)
    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= data_in;
        end
    end

    genvar p;
    generate
        for (p = 0; p < RD_PORTS; p = p + 1) begin : READ_LANES
            always @(posedge clk) begin
                data_out[p*WIDTH +: WIDTH] <= mem[addr[p*AW +: AW]];
            end
        end
    endgenerate

endmodule