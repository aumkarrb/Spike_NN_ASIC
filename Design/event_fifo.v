`timescale 1ns/1ps
module event_fifo #(
    parameter DEPTH = 32,
    parameter WIDTH = 16
)(
    input wire clk,
    input wire rst_n,
    input wire [WIDTH-1:0] data_in,
    input wire valid_in,
    output reg ready_out,
    output reg [WIDTH-1:0] data_out,
    output reg valid_out,
    input wire ready_in,
    output reg fifo_full,
    output reg fifo_empty
);

    reg [WIDTH-1:0] fifo_mem [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] write_ptr, read_ptr;
    reg [$clog2(DEPTH):0] count;
    
    // Combinational: generate enables based on current state
    wire write_en;
    wire read_en;
    wire [$clog2(DEPTH):0] count_next;
    
    assign write_en = valid_in && !fifo_full;
    assign read_en = ready_in && !fifo_empty;
    assign count_next = count + (write_en ? 1'b1 : 1'b0) - (read_en ? 1'b1 : 1'b0);
    
    // Sequential block
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr <= {$clog2(DEPTH){1'b0}};
            read_ptr <= {$clog2(DEPTH){1'b0}};
            count <= {($clog2(DEPTH)+1){1'b0}};
            data_out <= {WIDTH{1'b0}};
            fifo_full <= 1'b0;
            fifo_empty <= 1'b1;
            valid_out <= 1'b0;
            ready_out <= 1'b1;
        end else begin
            // Write operation
            if (write_en) begin
                fifo_mem[write_ptr] <= data_in;
                write_ptr <= (write_ptr == (DEPTH-1)) ? {$clog2(DEPTH){1'b0}} : write_ptr + 1'b1;
            end
            
            // Read operation
            if (read_en) begin
                read_ptr <= (read_ptr == (DEPTH-1)) ? {$clog2(DEPTH){1'b0}} : read_ptr + 1'b1;
            end
            
            // Update count
            count <= count_next;
            
            // Update outputs based on next count
            data_out <= fifo_mem[read_ptr];
            fifo_full <= (count_next >= DEPTH);
            fifo_empty <= (count_next == 0);
            valid_out <= (count_next > 0);
            ready_out <= (count_next < DEPTH);
        end
    end

endmodule