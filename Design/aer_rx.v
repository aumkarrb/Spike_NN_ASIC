`timescale 1ns/1ps

module aer_rx #(
    parameter ADDR_W = 4
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire [ADDR_W-1:0]  addr,        
    input  wire                aer_req,     
    output reg                 aer_ack,     

    output reg  [ADDR_W-1:0]  addr_out,    
    output reg                 event_valid  
);

    reg req_sync1, req_sync2, req_sync3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_sync3 <= 1'b0;
        end else begin
            req_sync1 <= aer_req;
            req_sync2 <= req_sync1;
            req_sync3 <= req_sync2;
        end
    end

    wire req_rise = req_sync2 && !req_sync3;

    localparam S_IDLE     = 1'b0;
    localparam S_WAIT_LOW = 1'b1;

    reg state, next_state;
    reg next_aer_ack;
    reg [ADDR_W-1:0] next_addr_out;
    reg next_event_valid;

    always @* begin
        next_state       = state;
        next_aer_ack     = aer_ack;
        next_addr_out    = addr_out;
        next_event_valid = 1'b0;

        case (state)
            S_IDLE: begin
                if (req_rise) begin
                    next_addr_out    = addr;
                    next_event_valid = 1'b1;
                    next_aer_ack     = 1'b1;
                    next_state       = S_WAIT_LOW;
                end
            end

            S_WAIT_LOW: begin
                if (!req_sync2) begin
                    next_aer_ack = 1'b0;
                    next_state   = S_IDLE;
                end
            end

            default: next_state = S_IDLE;
        endcase
    end


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            aer_ack     <= 1'b0;
            addr_out    <= {ADDR_W{1'b0}};
            event_valid <= 1'b0;
        end else begin
            state       <= next_state;
            aer_ack     <= next_aer_ack;
            addr_out    <= next_addr_out;
            event_valid <= next_event_valid;
        end
    end

endmodule