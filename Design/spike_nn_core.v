`timescale 1ns/1ps
//
// spike_nn_core.v -- full-visibility datapath (simulation target).
// Instantiated directly by the testbenches. spike_nn_top.v wraps THIS
// module for synthesis and hides everything but the physical pins.
//
module spike_nn_core #(
    parameter NEURONS        = 16,
    parameter ADDR_W         = 4,
    parameter DATA_W         = 32,
    parameter FIFO_DEPTH     = 32,
    parameter WEIGHT_DEPTH   = 256,
    parameter WEIGHT_RDPORTS = 4,
    parameter LOG_DEPTH      = 1024,
    parameter AER_LOG_DEPTH  = 1024,
    parameter PS_WIDTH       = 8
)(
    // ---- clocks / resets (independent domains, genuine CDC) ----
    input  wire wr_clk, core_clk, aer_clk, ps_src_clk, ps_dst_clk,
    input  wire wr_rst_n, core_rst_n, aer_rst_n, ps_src_rst_n, ps_dst_rst_n,

    // ---- event stimulus input: {weight_addr, event_magnitude} ----
    input  wire [$clog2(WEIGHT_DEPTH)+DATA_W-1:0] ev_data_in,
    input  wire        ev_valid_in,
    output wire         ev_ready_out,
    output wire         ev_fifo_full,

    // ---- LIF config ----
    input  wire signed [15:0]        threshold_in,
    input  wire signed [15:0]        reset_val_in,
    input  wire [4:0]                leak_shift_in,
    input  wire [$clog2(NEURONS)-1:0] target_neuron_id,

    // ---- debug current-injection backdoor (bypasses FIFO/synapse) ----
    input  wire [DATA_W-1:0]         dbg_current_in,
    input  wire                      dbg_current_valid,
    input  wire [$clog2(NEURONS)-1:0] dbg_current_neuron_id,

    // ---- weight RAM write port ----
    input  wire [$clog2(WEIGHT_DEPTH)-1:0] weight_waddr,
    input  wire [DATA_W-1:0]               weight_wdata,
    input  wire                            weight_we,

    // ---- weight RAM debug read lanes (1..WEIGHT_RDPORTS-1) ----
    input  wire [(WEIGHT_RDPORTS-1)*$clog2(WEIGHT_DEPTH)-1:0] weight_dbg_raddr,
    output wire [(WEIGHT_RDPORTS-1)*DATA_W-1:0]                weight_dbg_rdata,

    // ---- neuron array outputs ----
    output wire [NEURONS-1:0]     spike_bus,
    output wire [NEURONS*16-1:0]  voltage_flat,

    // ---- simple spike logger ----
    output wire [$clog2(LOG_DEPTH):0] log_count,
    output wire                       log_overflow,

    // ---- AER logger + readback ----
    output wire [$clog2(AER_LOG_DEPTH):0]   aer_log_count,
    output wire                              aer_log_overflow,
    input  wire [$clog2(AER_LOG_DEPTH)-1:0] aer_read_addr,
    output wire [ADDR_W-1:0]                aer_read_out_addr,
    output wire [31:0]                      aer_read_out_time,

    // ---- standalone pulse_sync utility (unit-test pass-through) ----
    input  wire [PS_WIDTH-1:0] ps_pulse_in,
    input  wire                ps_pulse_valid_in,
    output wire                ps_busy,
    output wire [PS_WIDTH-1:0] ps_pulse_out,
    output wire                ps_sync_valid
);

    localparam FIFO_WIDTH = $clog2(WEIGHT_DEPTH) + DATA_W;
    localparam AW         = $clog2(WEIGHT_DEPTH);
    localparam NID_W      = $clog2(NEURONS);

    // =====================================================================
    // 1. Event FIFO -- wr_clk (host side) -> core_clk (datapath side)
    // =====================================================================
    wire [FIFO_WIDTH-1:0] fifo_data_out;
    wire                  fifo_valid_out;

    event_fifo #(.DEPTH(FIFO_DEPTH), .WIDTH(FIFO_WIDTH)) u_event_fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
        .data_in(ev_data_in), .valid_in(ev_valid_in),
        .ready_out(ev_ready_out), .fifo_full(ev_fifo_full),
        .rd_clk(core_clk), .rd_rst_n(core_rst_n),
        .data_out(fifo_data_out), .valid_out(fifo_valid_out),
        .ready_in(1'b1),           // core side accepts up to 1 event/cycle
        .fifo_empty()
    );

    // Bit layout: { weight_addr, event_magnitude }
    wire [AW-1:0]     fifo_waddr    = fifo_data_out[FIFO_WIDTH-1:DATA_W];
    wire [DATA_W-1:0] fifo_magnitude = fifo_data_out[DATA_W-1:0];

    // =====================================================================
    // 2. Weight RAM -- lane 0 = live synapse lookup, lanes 1..N-1 = debug
    // =====================================================================
    wire [WEIGHT_RDPORTS*AW-1:0]   weight_rd_addr = {weight_dbg_raddr, fifo_waddr};
    wire [WEIGHT_RDPORTS*DATA_W-1:0] weight_rd_data;

    weight_ram_par #(.DEPTH(WEIGHT_DEPTH), .WIDTH(DATA_W), .RD_PORTS(WEIGHT_RDPORTS)) u_weight_ram (
        .clk(core_clk),
        .addr(weight_rd_addr), .data_out(weight_rd_data),
        .waddr(weight_waddr), .data_in(weight_wdata), .we(weight_we)
    );

    wire [DATA_W-1:0] weight_lane0_data = weight_rd_data[DATA_W-1:0];
    assign weight_dbg_rdata = weight_rd_data[WEIGHT_RDPORTS*DATA_W-1:DATA_W];

    // Weight RAM's read is registered (1-cycle latency) -- stage the
    // magnitude by exactly 1 cycle so it re-aligns with its own weight
    // the cycle the weight data becomes valid (fixes the back-to-back
    // event/weight pairing regression).
    reg [DATA_W-1:0] staged_magnitude;
    reg              staged_valid;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            staged_magnitude <= {DATA_W{1'b0}};
            staged_valid     <= 1'b0;
        end else begin
            staged_magnitude <= fifo_magnitude;
            staged_valid     <= fifo_valid_out;
        end
    end

    // =====================================================================
    // 3. Synapse pipeline (MAC: magnitude * weight -> post-synaptic current)
    // =====================================================================
    wire [DATA_W-1:0] synapse_current_out;
    wire              synapse_current_valid;

    synapse_pipeline #(.WIDTH(DATA_W)) u_synapse (
        .clk(core_clk), .rst_n(core_rst_n),
        .event_data(staged_magnitude), .event_valid(staged_valid),
        .event_ready(),                      // unused: pipelined_lif never backpressures
        .weight_in(weight_lane0_data),
        .current_out(synapse_current_out), .current_valid(synapse_current_valid),
        .current_ready(1'b1)
    );

    // =====================================================================
    // 4. Debug current-injection mux (takes priority over synapse path)
    // =====================================================================
    wire [DATA_W-1:0] lif_current_in    = dbg_current_valid ? dbg_current_in        : synapse_current_out;
    wire              lif_current_valid = dbg_current_valid ? 1'b1                  : synapse_current_valid;
    wire [NID_W-1:0]  lif_current_nid   = dbg_current_valid ? dbg_current_neuron_id : target_neuron_id;

    // =====================================================================
    // 5. LIF neuron array
    // =====================================================================
    pipelined_lif #(.Neurons(NEURONS)) u_lif (
        .clk(core_clk), .rst_n(core_rst_n),
        .current_in(lif_current_in), .current_valid(lif_current_valid),
        .current_neuron_id(lif_current_nid),
        .threshold_in(threshold_in), .reset_val_in(reset_val_in), .leak_shift_in(leak_shift_in),
        .spike_out(), .voltage_out(),        // legacy neuron-0 alias, unused here
        .voltage_bus(),                      // not exposed at this level
        .spike_bus(spike_bus), .voltage_flat(voltage_flat)
    );

    // =====================================================================
    // 6. Simple spike logger (any-neuron spike counter)
    // =====================================================================
    spike_logger #(.DEPTH(LOG_DEPTH)) u_spike_logger (
        .clk(core_clk), .rst_n(core_rst_n),
        .spike_in(|spike_bus), .valid_in(1'b1), .ready_out(),
        .log_count(log_count), .overflow(log_overflow)
    );

    // =====================================================================
    // 7. AER link: spike_bus -> aer_tx (core_clk) --CDC--> aer_rx (aer_clk)
    // =====================================================================
    wire aer_req_w, aer_ack_w;
    wire [ADDR_W-1:0] aer_addr_w;

    aer_tx #(.N_SOURCES(NEURONS), .ADDR_W(ADDR_W)) u_aer_tx (
        .clk(core_clk), .rst_n(core_rst_n),
        .req_pulse(spike_bus),
        .addr(aer_addr_w), .aer_req(aer_req_w), .aer_ack(aer_ack_w),
        .busy(), .pending_dbg()
    );

    wire [ADDR_W-1:0] aer_rx_addr_out;
    wire              aer_rx_event_valid;

    aer_rx #(.ADDR_W(ADDR_W)) u_aer_rx (
        .clk(aer_clk), .rst_n(aer_rst_n),
        .addr(aer_addr_w), .aer_req(aer_req_w), .aer_ack(aer_ack_w),
        .addr_out(aer_rx_addr_out), .event_valid(aer_rx_event_valid)
    );

    aer_spike_logger #(.DEPTH(AER_LOG_DEPTH), .ADDR_W(ADDR_W)) u_aer_logger (
        .clk(aer_clk), .rst_n(aer_rst_n),
        .addr_in(aer_rx_addr_out), .event_valid(aer_rx_event_valid), .ready_out(),
        .log_count(aer_log_count), .overflow(aer_log_overflow),
        .read_addr(aer_read_addr), .read_out_addr(aer_read_out_addr), .read_out_time(aer_read_out_time)
    );

    // =====================================================================
    // 8. Standalone pulse_sync CDC utility -- exposed for its own unit test
    // =====================================================================
    pulse_sync #(.WIDTH(PS_WIDTH)) u_pulse_sync (
        .src_clk(ps_src_clk), .src_rst_n(ps_src_rst_n),
        .pulse_in(ps_pulse_in), .pulse_valid_in(ps_pulse_valid_in), .busy(ps_busy),
        .dst_clk(ps_dst_clk), .dst_rst_n(ps_dst_rst_n),
        .pulse_out(ps_pulse_out), .sync_valid(ps_sync_valid)
    );

endmodule