`timescale 1ns/1ps
module aer_spike_logger #(
    parameter DEPTH  = 1024,
    parameter ADDR_W = 4
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // AER-side write interface (from aer_rx.v)
    input  wire [ADDR_W-1:0]     addr_in,
    input  wire                  event_valid,
    output wire                  ready_out,

    output reg  [$clog2(DEPTH):0] log_count,
    output reg                    overflow,

    // Read-back interface: dump the (address, timestamp) log after the
    // fact, e.g. to compare against a reference event-based dataset.
    input  wire [$clog2(DEPTH)-1:0] read_addr,
    output wire [ADDR_W-1:0]        read_out_addr,
    output wire [31:0]              read_out_time
);

    reg [ADDR_W-1:0] log_addr [0:DEPTH-1];
    reg [31:0]       log_time [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] write_ptr;
    reg [31:0] time_counter;

    wire can_write = (log_count < DEPTH);
    wire do_write  = event_valid && can_write;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr    <= {$clog2(DEPTH){1'b0}};
            log_count    <= {($clog2(DEPTH)+1){1'b0}};
            overflow     <= 1'b0;
            time_counter <= 32'h0;
        end else begin
            time_counter <= time_counter + 32'h1;

            if (do_write) begin
                log_addr[write_ptr] <= addr_in;
                log_time[write_ptr] <= time_counter;
                write_ptr <= write_ptr + 1'b1;
                log_count <= log_count + 1'b1;
            end
            overflow <= (event_valid && !can_write);
        end
    end

    assign ready_out = can_write;
    assign read_out_addr = log_addr[read_addr];
    assign read_out_time = log_time[read_addr];

endmodule
