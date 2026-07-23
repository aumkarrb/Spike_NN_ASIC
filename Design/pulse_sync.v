`timescale 1ns/1ps
module pulse_sync #(
    parameter WIDTH = 8
)(
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire [WIDTH-1:0] pulse_in,
    input  wire             pulse_valid_in,
    output wire              busy,

    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output reg  [WIDTH-1:0] pulse_out,
    output reg              sync_valid
);


    reg [WIDTH-1:0] data_reg;
    reg             req_toggle;
    reg             ack_sync1, ack_sync2;
    wire            ack_toggle_w;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle_w;
            ack_sync2 <= ack_sync1;
        end
    end

    assign busy = (req_toggle != ack_sync2);

    wire             accept = pulse_valid_in && !busy;
    reg              next_req_toggle;
    reg [WIDTH-1:0]  next_data_reg;
    always @* begin
        next_req_toggle = req_toggle;
        next_data_reg   = data_reg;
        if (accept) begin
            next_req_toggle = ~req_toggle;
            next_data_reg   = pulse_in;
        end
    end

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            data_reg   <= {WIDTH{1'b0}};
            req_toggle <= 1'b0;
        end else begin
            data_reg   <= next_data_reg;
            req_toggle <= next_req_toggle;
        end
    end


    reg toggle_sync1, toggle_sync2, toggle_sync3;
    reg [WIDTH-1:0] data_sync1, data_sync2;
    reg ack_toggle;
    assign ack_toggle_w = ack_toggle;


    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            toggle_sync1 <= 1'b0;
            toggle_sync2 <= 1'b0;
            toggle_sync3 <= 1'b0;
            data_sync1   <= {WIDTH{1'b0}};
            data_sync2   <= {WIDTH{1'b0}};
        end else begin
            toggle_sync1 <= req_toggle;
            toggle_sync2 <= toggle_sync1;
            toggle_sync3 <= toggle_sync2;
            data_sync1   <= data_reg;
            data_sync2   <= data_sync1;
        end
    end

    wire new_event = (toggle_sync2 != toggle_sync3);

    
    reg              next_sync_valid;
    reg [WIDTH-1:0]  next_pulse_out;
    reg              next_ack_toggle;
    always @* begin
        next_sync_valid = new_event;
        next_pulse_out  = pulse_out;
        next_ack_toggle = ack_toggle;
        if (new_event) begin
            next_pulse_out  = data_sync2;
            next_ack_toggle = ~ack_toggle;
        end
    end

   
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            pulse_out  <= {WIDTH{1'b0}};
            sync_valid <= 1'b0;
            ack_toggle <= 1'b0;
        end else begin
            pulse_out  <= next_pulse_out;
            sync_valid <= next_sync_valid;
            ack_toggle <= next_ack_toggle;
        end
    end

endmodule