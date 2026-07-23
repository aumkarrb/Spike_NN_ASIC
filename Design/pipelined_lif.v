`timescale 1ns/1ps

module pipelined_lif #(
    parameter Neurons         = 16,
    parameter Pipeline_Stages = 4
)(
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire [31:0]                   current_in,
    input  wire                          current_valid,
    input  wire [$clog2(Neurons)-1:0]    current_neuron_id,

    input  wire signed [15:0]            threshold_in,
    input  wire signed [15:0]            reset_val_in,
    input  wire [4:0]                    leak_shift_in,

    output reg                           spike_out,
    output reg  [15:0]                   voltage_out,
    output wire [Neurons-1:0]            voltage_bus,

    output wire [Neurons-1:0]            spike_bus,
    output wire [Neurons*16-1:0]         voltage_flat
);

    localparam SEL_W  = (Neurons <= 1) ? 1 : $clog2(Neurons);
    localparam STAGES = (Pipeline_Stages < 3) ? 3 : Pipeline_Stages;

    function automatic signed [15:0] sat16_sum(input signed [15:0] base,
                                                input signed [31:0] delta,
                                                input                delta_valid);
        reg signed [32:0] wide;
        begin
            wide = {{17{base[15]}}, base} + (delta_valid ? {{1{delta[31]}}, delta} : 33'sd0);
            if (wide > 33'sd32767)
                sat16_sum = 16'sd32767;
            else if (wide < -33'sd32768)
                sat16_sum = -16'sd32768;
            else
                sat16_sum = wide[15:0];
        end
    endfunction

    reg signed [15:0] neuron_v [0:Neurons-1];
    reg signed [31:0] pending_current [0:Neurons-1];
    reg               pending_valid   [0:Neurons-1];

    integer i;

    // Round-robin neuron scheduler: one neuron enters the pipeline / cycle
    reg [SEL_W-1:0] rr_sel;

    // Pipeline tag/data registers, one set per stage
    reg               p_valid [0:STAGES-1];
    reg [SEL_W-1:0]   p_sel   [0:STAGES-1];
    reg signed [15:0] p_v     [0:STAGES-1];
    reg               p_spike [0:STAGES-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_sel <= {SEL_W{1'b0}};
            for (i = 0; i < Neurons; i = i + 1) begin
                neuron_v[i]        <= 16'sd0;
                pending_current[i] <= 32'sd0;
                pending_valid[i]   <= 1'b0;
            end
            for (i = 0; i < STAGES; i = i + 1) begin
                p_valid[i] <= 1'b0;
                p_sel[i]   <= {SEL_W{1'b0}};
                p_v[i]     <= 16'sd0;
                p_spike[i] <= 1'b0;
            end
            spike_out   <= 1'b0;
            voltage_out <= 16'h0;
        end else begin

            if (current_valid) begin
                if (pending_valid[current_neuron_id] &&
                    !(p_valid[0] && pending_valid[current_neuron_id] &&
                      p_sel[0] == current_neuron_id)) begin
                    pending_current[current_neuron_id] <=
                        pending_current[current_neuron_id] + $signed(current_in);
                end else begin
                    pending_current[current_neuron_id] <= $signed(current_in);
                end
                pending_valid[current_neuron_id] <= 1'b1;
            end

            // Stage 0: issue neuron `rr_sel` + apply leak 
            p_valid[0] <= 1'b1;
            p_sel[0]   <= rr_sel;
            p_v[0]     <= neuron_v[rr_sel] - (neuron_v[rr_sel] >>> leak_shift_in);
            p_spike[0] <= 1'b0;
            rr_sel     <= (rr_sel == Neurons-1) ? {SEL_W{1'b0}} : rr_sel + 1'b1;

            // Stage 1: add pending synaptic current, then consume it.
            p_valid[1] <= p_valid[0];
            p_sel[1]   <= p_sel[0];
            p_spike[1] <= 1'b0;
            p_v[1]     <= sat16_sum(p_v[0], pending_current[p_sel[0]], pending_valid[p_sel[0]]);
            if (p_valid[0] && pending_valid[p_sel[0]] &&
                !(current_valid && current_neuron_id == p_sel[0])) begin
                pending_valid[p_sel[0]] <= 1'b0;
            end

            // Middle pass-through stages (extra latency budget)
            for (i = 2; i <= STAGES-2; i = i + 1) begin
                p_valid[i] <= p_valid[i-1];
                p_sel[i]   <= p_sel[i-1];
                p_v[i]     <= p_v[i-1];
                p_spike[i] <= p_spike[i-1];
            end

            // Final stage: threshold compare + commit 
            p_valid[STAGES-1] <= p_valid[STAGES-2];
            p_sel[STAGES-1]   <= p_sel[STAGES-2];
            p_v[STAGES-1]     <= p_v[STAGES-2];
            p_spike[STAGES-1] <= p_valid[STAGES-2] && (p_v[STAGES-2] >= threshold_in);

            if (p_valid[STAGES-2]) begin
                if (p_v[STAGES-2] >= threshold_in) begin
                    neuron_v[p_sel[STAGES-2]] <= reset_val_in;
                end else begin
                    neuron_v[p_sel[STAGES-2]] <= p_v[STAGES-2];
                end
            end

            // Legacy neuron-0 aliases
            spike_out   <= p_valid[STAGES-1] && (p_sel[STAGES-1] == {SEL_W{1'b0}}) && p_spike[STAGES-1];
            voltage_out <= neuron_v[0][15:0];
        end
    end

    // Multi-neuron observability 
    assign spike_bus = (p_valid[STAGES-1] && p_spike[STAGES-1])
                        ? ({{(Neurons-1){1'b0}}, 1'b1} << p_sel[STAGES-1])
                        : {Neurons{1'b0}};

    genvar gv;
    generate
        for (gv = 0; gv < Neurons; gv = gv + 1) begin : VOLT_PACK
            assign voltage_flat[gv*16 +: 16] = neuron_v[gv][15:0];
            assign voltage_bus[gv]           = neuron_v[gv][0];
        end
    endgenerate

endmodule