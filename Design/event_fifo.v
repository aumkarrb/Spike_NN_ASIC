`timescale 1ns/1ps

module event_fifo #(
    parameter DEPTH = 32,
    parameter WIDTH = 16
)(
    
    input  wire             wr_clk,
    input  wire             wr_rst_n,
    input  wire [WIDTH-1:0] data_in,
    input  wire             valid_in,
    output wire             ready_out,
    output wire             fifo_full,
    
    input  wire             rd_clk,
    input  wire             rd_rst_n,
    output reg  [WIDTH-1:0] data_out,
    output reg              valid_out,
    input  wire             ready_in,
    output wire             fifo_empty
);

    localparam AW = $clog2(DEPTH);

    reg [WIDTH-1:0] fifo_mem [0:DEPTH-1];

    reg [AW:0] wr_bin, wr_gray;
    reg [AW:0] rd_bin, rd_gray;

    // Gray pointers synchronized across the clock boundary (2-flop each)
    reg [AW:0] rd_gray_sync1, rd_gray_sync2;   // read ptr,  into wr_clk
    reg [AW:0] wr_gray_sync1, wr_gray_sync2;   // write ptr, into rd_clk

    wire write_en = valid_in && !fifo_full;
    wire read_en  = ready_in && !fifo_empty;

    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = (b >> 1) ^ b;
    endfunction

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else if (write_en) begin
            fifo_mem[wr_bin[AW-1:0]] <= data_in;
            wr_bin  <= wr_bin + 1'b1;
            wr_gray <= bin2gray(wr_bin + 1'b1);
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_sync1 <= {(AW+1){1'b0}};
            rd_gray_sync2 <= {(AW+1){1'b0}};
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    assign fifo_full = (wr_gray == {~rd_gray_sync2[AW:AW-1], rd_gray_sync2[AW-2:0]});
    assign ready_out = !fifo_full;

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin    <= {(AW+1){1'b0}};
            rd_gray   <= {(AW+1){1'b0}};
            data_out  <= {WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else begin
            valid_out <= read_en;
            if (read_en) begin
                data_out <= fifo_mem[rd_bin[AW-1:0]];
                rd_bin   <= rd_bin + 1'b1;
                rd_gray  <= bin2gray(rd_bin + 1'b1);
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_sync1 <= {(AW+1){1'b0}};
            wr_gray_sync2 <= {(AW+1){1'b0}};
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

    assign fifo_empty = (rd_gray == wr_gray_sync2);

endmodule