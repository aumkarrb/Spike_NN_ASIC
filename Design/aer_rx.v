`timescale 1ns/1ps
module aer_rx #(
    parameter ADDR_W = 4
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire [ADDR_W-1:0]  addr,        // AER address bus (from the TX side)
    input  wire                aer_req,     // four-phase request (async to this domain)
    output reg                 aer_ack,     // four-phase acknowledge

    output reg  [ADDR_W-1:0]  addr_out,    // captured address, valid when event_valid pulses
    output reg                 event_valid  // one-cycle pulse: a new event was received
);
    reg req_sync1, req_sync2, req_sync3;

    localparam S_IDLE     = 1'b0;
    localparam S_WAIT_LOW = 1'b1;
    reg state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_sync1   <= 1'b0;
            req_sync2   <= 1'b0;
            req_sync3   <= 1'b0;
            aer_ack     <= 1'b0;
            addr_out    <= {ADDR_W{1'b0}};
            event_valid <= 1'b0;
            state       <= S_IDLE;
        end else begin
            req_sync1 <= aer_req;
            req_sync2 <= req_sync1;
            req_sync3 <= req_sync2;

            event_valid <= 1'b0; 

            case (state)
                S_IDLE: begin
                    // Rising edge of the synchronized request: a new event
                    // has arrived and the address bus is stable.
                    if (req_sync2 && !req_sync3) begin
                        addr_out    <= addr;
                        event_valid <= 1'b1;
                        aer_ack     <= 1'b1;
                        state       <= S_WAIT_LOW;
                    end
                end

                S_WAIT_LOW: begin
                    if (!req_sync2) begin
                        aer_ack <= 1'b0;
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
