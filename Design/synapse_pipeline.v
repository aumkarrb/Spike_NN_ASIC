`timescale 1ns/1ps

module synapse_pipeline #(
    parameter WIDTH = 32,
    parameter DELAY = 8      // pipeline depth, now actually used
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [WIDTH-1:0]       event_data,   // spike activation / multiplier
    input  wire                   event_valid,
    output wire                   event_ready,
    input  wire [WIDTH-1:0]       weight_in,    // synaptic weight
    output reg  [WIDTH-1:0]       current_out,  // accumulated post-synaptic current
    output reg                    current_valid,
    input  wire                   current_ready
);

    // Parameterized delay line carrying each event's MAC term
    reg [WIDTH-1:0] pipe_product [0:DELAY-1];
    reg             pipe_valid   [0:DELAY-1];
    integer i;

    wire signed [WIDTH-1:0]   s_event_data = event_data;
    wire signed [WIDTH-1:0]   s_weight_in  = weight_in;
    wire signed [2*WIDTH-1:0] mac_full     = s_event_data * s_weight_in;

    function automatic signed [WIDTH-1:0] sat_mac(input signed [2*WIDTH-1:0] wide);
        reg signed [WIDTH-1:0] mac_max, mac_min;
        begin
            mac_max = {1'b0, {(WIDTH-1){1'b1}}};   // +(2^(WIDTH-1) - 1)
            mac_min = {1'b1, {(WIDTH-1){1'b0}}};   // -(2^(WIDTH-1))
            if (wide > mac_max)      sat_mac = mac_max;
            else if (wide < mac_min) sat_mac = mac_min;
            else                     sat_mac = wide[WIDTH-1:0];
        end
    endfunction

    assign event_ready = !(current_valid && !current_ready);

    reg [WIDTH-1:0] accum;
    reg accum_pending;

    wire term_valid     = pipe_valid[DELAY-1];
    wire [WIDTH-1:0] term = pipe_product[DELAY-1];
    wire [WIDTH-1:0] merged   = accum + (term_valid ? term : {WIDTH{1'b0}});
    wire             has_data = accum_pending || term_valid;
    wire             out_free = !current_valid || current_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DELAY; i = i + 1) begin
                pipe_product[i] <= {WIDTH{1'b0}};
                pipe_valid[i]   <= 1'b0;
            end
            accum         <= {WIDTH{1'b0}};
            accum_pending <= 1'b0;
            current_out   <= {WIDTH{1'b0}};
            current_valid <= 1'b0;
        end else begin
            // Stage 0: entry - compute this cycle's saturated MAC term
            pipe_product[0] <= (event_valid && event_ready) ? sat_mac(mac_full) : {WIDTH{1'b0}};
            pipe_valid[0]   <= event_valid && event_ready;

            // Propagate through the DELAY-deep pipeline
            for (i = 1; i < DELAY; i = i + 1) begin
                pipe_product[i] <= pipe_product[i-1];
                pipe_valid[i]   <= pipe_valid[i-1];
            end

            if (out_free) begin
                current_out   <= merged;
                current_valid <= has_data;
                accum         <= {WIDTH{1'b0}};
                accum_pending <= 1'b0;
            end else begin
                accum <= merged;
                if (term_valid) accum_pending <= 1'b1;
            end
        end
    end

endmodule