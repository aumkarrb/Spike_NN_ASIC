`timescale 1ns/1ps
//
// spike_nn_top.v -- SYNTHESIS TOP (physical pins only)
// Demo interface uses Blackboard's onboard switches/buttons/LEDs instead
// of wide runtime config/data ports. spike_nn_core is untouched and keeps
// its full port list for simulation (see the testbenches).
//
module spike_nn_top (
    input  wire        ref_clk,     // H16, 100 MHz onboard oscillator
    input  wire [3:0]  btn,         // btn[0]=reset, btn[1]=load weight,
                                     // btn[2]=inject event, btn[3]=spare
    input  wire [7:0]  sw,          // magnitude/weight value for demo loads
    output wire [3:0]  led          // spike_bus[3:0], one LED per neuron
);

    // =====================================================================
    // Clock / reset generation
    // =====================================================================
    wire wr_clk, core_clk, aer_clk;     // 100 / 83.33 / 71.43 MHz respectively
    wire mmcm_locked;
    wire ref_rst_n = ~btn[0];           // buttons are active-HIGH when pressed
    wire sys_rst_n = ref_rst_n & mmcm_locked;

    clk_wiz_1 u_clkgen (
        .clk_in1  (ref_clk),           // IP's default input port name
        .reset    (btn[0]),            // IP's default reset port, active-HIGH
        .clk_out1 (wr_clk),            // 100 MHz
        .clk_out2 (core_clk),          //  83.33 MHz
        .clk_out3 (aer_clk),           //  71.43 MHz
        .locked   (mmcm_locked)
    );

    // ps_* domain unused physically -- tie to core clock/reset
    wire ps_src_clk = core_clk, ps_dst_clk = core_clk;
    wire ps_src_rst_n = sys_rst_n, ps_dst_rst_n = sys_rst_n;

    // =====================================================================
    // Config fixed at synthesis time (was runtime ports, testbench-only)
    // =====================================================================
    localparam signed [15:0] THRESHOLD  = 16'sd200;
    localparam signed [15:0] RESET_VAL  = 16'sd0;
    localparam        [4:0]  LEAK_SHIFT = 5'd5;
    localparam        [3:0]  TARGET_NID = 4'd0;   // unused in datapath

    // =====================================================================
    // Minimal demo loader: switches + buttons instead of wide runtime ports
    // =====================================================================
    // btn[1] (debounced-ish via single-cycle pulse assumption for now):
    //   writes weight_wdata = {24'b0, sw} to weight address 0
    wire        weight_we     = btn[1];
    wire [7:0]  weight_waddr  = 8'd0;
    wire [31:0] weight_wdata  = {24'b0, sw};

    // btn[2]: injects one event -- {weight_addr[7:0], magnitude[31:0]}
    wire        ev_valid_in = btn[2];
    wire [39:0] ev_data_in  = {8'd0, 24'b0, sw};
    wire        ev_ready_out, ev_fifo_full;   // unused physically

    // =====================================================================
    // Debug/observability nets -- NOT top-level pins
    // =====================================================================
    wire [255:0] voltage_flat;
    wire [10:0]  log_count;
    wire         log_overflow;

    wire [10:0]  aer_log_count;
    wire         aer_log_overflow;
    wire [9:0]   aer_read_addr;
    wire [3:0]   aer_read_out_addr;
    wire [31:0]  aer_read_out_time;

    wire [23:0]  weight_dbg_raddr;
    wire [95:0]  weight_dbg_rdata;

    wire [31:0]  dbg_current_in;
    wire         dbg_current_valid;
    wire [3:0]   dbg_current_neuron_id;

    wire [7:0]   ps_pulse_in       = 8'd0;
    wire         ps_pulse_valid_in = 1'b0;
    wire         ps_busy, ps_sync_valid;
    wire [7:0]   ps_pulse_out;

    wire [15:0]  spike_bus;
    assign led = spike_bus[3:0];

    // =====================================================================
    // Core instance -- explicit connections
    // =====================================================================
    spike_nn_core #(
        .NEURONS(16), .ADDR_W(4), .DATA_W(32),
        .FIFO_DEPTH(32), .WEIGHT_DEPTH(256),
        .WEIGHT_RDPORTS(4), .LOG_DEPTH(1024),
        .AER_LOG_DEPTH(1024), .PS_WIDTH(8)
    ) dut (
        .wr_clk(wr_clk), .core_clk(core_clk), .aer_clk(aer_clk),
        .ps_src_clk(ps_src_clk), .ps_dst_clk(ps_dst_clk),
        .wr_rst_n(sys_rst_n), .core_rst_n(sys_rst_n), .aer_rst_n(sys_rst_n),
        .ps_src_rst_n(ps_src_rst_n), .ps_dst_rst_n(ps_dst_rst_n),

        .ev_data_in(ev_data_in), .ev_valid_in(ev_valid_in),
        .ev_ready_out(ev_ready_out), .ev_fifo_full(ev_fifo_full),

        .threshold_in(THRESHOLD), .reset_val_in(RESET_VAL),
        .leak_shift_in(LEAK_SHIFT), .target_neuron_id(TARGET_NID),

        .dbg_current_in(dbg_current_in), .dbg_current_valid(dbg_current_valid),
        .dbg_current_neuron_id(dbg_current_neuron_id),

        .weight_waddr(weight_waddr), .weight_wdata(weight_wdata), .weight_we(weight_we),
        .weight_dbg_raddr(weight_dbg_raddr), .weight_dbg_rdata(weight_dbg_rdata),

        .spike_bus(spike_bus), .voltage_flat(voltage_flat),
        .log_count(log_count), .log_overflow(log_overflow),

        .aer_log_count(aer_log_count), .aer_log_overflow(aer_log_overflow),
        .aer_read_addr(aer_read_addr),
        .aer_read_out_addr(aer_read_out_addr), .aer_read_out_time(aer_read_out_time),

        .ps_pulse_in(ps_pulse_in), .ps_pulse_valid_in(ps_pulse_valid_in),
        .ps_busy(ps_busy), .ps_pulse_out(ps_pulse_out), .ps_sync_valid(ps_sync_valid)
    );

    // =====================================================================
    // ILA -- watch everything that used to be a debug pin
    // =====================================================================
    debug_ila u_ila (
        .clk    (core_clk),
        .probe0 (voltage_flat),
        .probe1 (weight_dbg_rdata),
        .probe2 (spike_bus),
        .probe3 (aer_read_out_time)
    );

    // =====================================================================
    // VIO -- drive/read weight debug + AER log readback live over JTAG
    // =====================================================================
    debug_vio u_vio (
        .clk        (core_clk),
        .probe_out0 (dbg_current_in),
        .probe_out1 (dbg_current_valid),
        .probe_out2 (dbg_current_neuron_id),
        .probe_out3 (weight_dbg_raddr),
        .probe_out4 (aer_read_addr)
    );

endmodule