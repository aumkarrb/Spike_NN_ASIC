`timescale 1ns/1ps
module aer_tx #(
    parameter N_SOURCES = 16,
    parameter ADDR_W    = 4          // must satisfy 2**ADDR_W >= N_SOURCES
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire [N_SOURCES-1:0]   req_pulse,   // one-cycle pulse per source wanting to send

    output reg  [ADDR_W-1:0]      addr,        // AER address bus (bundled data: stable while aer_req is high)
    output reg                    aer_req,     // four-phase request
    input  wire                   aer_ack,     // four-phase acknowledge (from the RX's domain)

    output wire                   busy,        // at least one source is pending or being serviced
    output wire [N_SOURCES-1:0]   pending_dbg  
);

    localparam S_IDLE          = 2'd0;
    localparam S_REQ_ASSERTED  = 2'd1;  // driving addr+req, waiting for ack to rise
    localparam S_WAIT_ACK_LOW  = 2'd2;  // req dropped, waiting for ack to fall (return to zero)

    reg [1:0] state;
    reg [N_SOURCES-1:0] pending;
    reg [ADDR_W-1:0]    rr_ptr;       // round-robin starting point, advances each service

    reg ack_sync1, ack_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= aer_ack;
            ack_sync2 <= ack_sync1;
        end
    end
    // Round-robin priority pick among currently-pending sources, starting
    // the scan at rr_ptr so no single low-address source can starve
    // higher-address ones under sustained load.
    reg [ADDR_W-1:0] next_sel;
    reg              next_sel_valid;
    integer k;
    integer idx;
    always @* begin
        next_sel       = {ADDR_W{1'b0}};
        next_sel_valid = 1'b0;
        for (k = 0; k < N_SOURCES; k = k + 1) begin
            idx = rr_ptr + k;
            if (idx >= N_SOURCES) idx = idx - N_SOURCES;
            if (!next_sel_valid && pending[idx]) begin
                next_sel       = idx[ADDR_W-1:0];
                next_sel_valid = 1'b1;
            end
        end
    end

    assign busy        = (state != S_IDLE) || (|pending);
    assign pending_dbg = pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            pending  <= {N_SOURCES{1'b0}};
            rr_ptr   <= {ADDR_W{1'b0}};
            addr     <= {ADDR_W{1'b0}};
            aer_req  <= 1'b0;
        end else begin
            // Latch new requests every cycle regardless of FSM state, so
            // nothing arriving mid-transaction is lost.
            pending <= pending | req_pulse;

            case (state)
                S_IDLE: begin
                    if (next_sel_valid) begin
                        addr    <= next_sel;
                        aer_req <= 1'b1;
                        state   <= S_REQ_ASSERTED;
                        rr_ptr  <= (next_sel == N_SOURCES-1) ? {ADDR_W{1'b0}} : next_sel + 1'b1;
                        if (!req_pulse[next_sel]) begin
                            pending[next_sel] <= 1'b0;
                        end
                    end
                end

                S_REQ_ASSERTED: begin
                    if (ack_sync2) begin
                        aer_req <= 1'b0;      // sender's half of the return-to-zero handshake
                        state   <= S_WAIT_ACK_LOW;
                    end
                end

                S_WAIT_ACK_LOW: begin
                    if (!ack_sync2) begin
                        state <= S_IDLE;      // full four-phase cycle complete
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
