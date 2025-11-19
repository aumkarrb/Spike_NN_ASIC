`timescale 1ns/1ps
module spike_logger #(
    parameter DEPTH = 1024
)(
    input wire clk,
    input wire rst_n,
    input wire spike_in,
    input wire valid_in,
    output wire ready_out,
    output reg [$clog2(DEPTH)-1:0] log_count,  // FIXED: Changed from $clog2(DEPTH):0
    output reg overflow
);

    reg [31:0] spike_log [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] write_ptr;
    reg [31:0] time_counter;
    
    wire can_write = (log_count < (DEPTH-1));
    wire do_write = spike_in && valid_in && can_write;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr <= {$clog2(DEPTH){1'b0}};
            log_count <= {$clog2(DEPTH){1'b0}};
            overflow <= 1'b0;
            time_counter <= 32'h0;
        end else begin
            time_counter <= time_counter + 32'h1;
            
            if (do_write) begin
                spike_log[write_ptr] <= time_counter;
                write_ptr <= write_ptr + 1'b1;
                log_count <= log_count + 1'b1;
                overflow <= 1'b0;
            end else if (spike_in && valid_in && !can_write) begin
                overflow <= 1'b1;
            end
        end
    end
    
    assign ready_out = can_write;

endmodule