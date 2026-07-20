# Spike NN ASIC — Digital Spiking Neural Network for ASIC Implementation

> RTL Design and Verification of a Pipelined, Multi-Neuron, Asynchronous Leaky Integrate-and-Fire Spiking Neural Network Core in Verilog, targeting ASIC implementation

![Language](https://img.shields.io/badge/Language-Verilog%20%7C%20SystemVerilog-blue)
![Domain](https://img.shields.io/badge/Domain-Neuromorphic%20Computing-purple)
![Verification](https://img.shields.io/badge/Verification-18%2F18%20checks%20passing-brightgreen)
![License](https://img.shields.io/badge/License-See%20LICENSE-lightgrey)

---
## Overview

This project implements a digital spiking neural network (SNN) core built from six RTL blocks: an asynchronous AER-style event FIFO, a clock-domain-crossing pulse synchronizer, a parallel-access synaptic weight RAM, a pipelined multiply-accumulate synapse unit, a time-multiplexed 16-neuron leaky integrate-and-fire (LIF) array, and a spike event logger.

The blocks are genuinely wired into a single datapath and verified as such: `event_fifo → synapse_pipeline → pipelined_lif → spike_logger` is exercised end-to-end in simulation, in addition to per-module unit tests. Two of the six blocks (`event_fifo`, `pulse_sync`) cross real, independently-clocked domains using standard CDC structures (Gray-coded pointers with two-flop synchronizers, and a toggle-based handshake respectively) rather than sharing a single clock. The LIF core services all 16 neurons through a round-robin scheduler with a genuinely pipelined per-neuron update, rather than only observing one neuron out of sixteen declared.


## Repository Structure

```
Spike_NN_ASIC/
├── Design/
│   ├── event_fifo.v                   # Asynchronous (dual-clock) AER event FIFO
│   ├── pipelined_lif.v                # Round-robin pipelined, multi-neuron LIF array
│   ├── pulse_sync.v                   # Toggle-based CDC pulse synchronizer
│   ├── spike_logger.v                 # Spike event logger / monitor module
│   ├── synapse_pipeline.v             # Pipelined synaptic multiply-accumulate unit
│   └── weight_ram_par.v               # Parallel-access weight RAM (synapse memory)
│
├── References/
|
│
├── Reports/
│   ├── Team7_DSD_Mini_Project-1.pdf   # Full project report: design, simulation, analysis
│   └── New_Waveform.png               # Waveform capture: post-fix simulation results
│
├── Testbench/
│   └── spike_nn_tb_layered.sv         # Layered SystemVerilog testbench, including full-datapath integration test
│
├── LICENSE                            # License file
└── README.md                          # This file
```
---

## Module Reference

### `pipelined_lif.v` — round-robin pipelined LIF neuron array

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `current_in[31:0]`, `current_valid`, `current_neuron_id[$clog2(Neurons)-1:0]`, `threshold_in[15:0]`, `reset_val_in[15:0]`, `leak_shift_in[4:0]`, `spike_out`, `voltage_out[15:0]`, `voltage_bus[Neurons-1:0]`, `spike_bus[Neurons-1:0]`, `voltage_flat[Neurons*16-1:0]` |
| **Parameters** | `Neurons = 16`, `Pipeline_Stages = 4` |

- Implements leaky-integrate-and-fire dynamics as `v_new = v − (v >>> leak_shift_in) + injected_current`, with spike-on-threshold and reset-to-`reset_val_in`.
- **All 16 neurons are live.** A single shared state array (`neuron_v[0:Neurons-1]`) is serviced by a free-running round-robin scheduler — exactly one neuron enters the pipeline per cycle, so full array coverage takes `Neurons` cycles. There is no per-neuron hardware duplication and therefore no way for a neuron to be silently unconnected.
- **Genuine pipelining.** `Pipeline_Stages` sets real update latency: stage 0 applies the leak, stage 1 adds any pending synaptic current, middle stages pass state through, and the final stage performs the threshold compare and commit. Throughput remains one neuron issued per cycle regardless of `Pipeline_Stages`; only latency scales with it.
- **Decoupled current injection.** A per-neuron pending-current register latches `current_in` against `current_neuron_id` on arrival and is consumed the next time that neuron is serviced by the scheduler — so a synaptic current arriving between two service slots is never lost. A second injection to the same neuron before it has been serviced overwrites the pending value rather than accumulating with it; this is an intentional consequence of time-multiplexing a single physical update unit across 16 neurons, not a defect.
- `threshold_in`, `reset_val_in`, and `leak_shift_in` are runtime input ports, not fixed `localparam`s.
- `spike_bus`/`voltage_flat` expose every neuron's spike flag and voltage; `spike_out`/`voltage_out`/`voltage_bus` are retained as neuron-0 aliases for backward compatibility with single-neuron consumers.

### `event_fifo.v` — asynchronous (dual-clock) AER event FIFO

| | |
|---|---|
| **Ports** | `wr_clk`, `wr_rst_n`, `data_in`, `valid_in`, `ready_out`, `fifo_full`, `rd_clk`, `rd_rst_n`, `data_out`, `valid_out`, `ready_in`, `fifo_empty` |
| **Parameters** | `DEPTH = 32` (must be a power of two), `WIDTH = 16` |

- A genuine dual-clock asynchronous FIFO: independent `wr_clk`/`rd_clk` domains, binary-plus-Gray write and read pointers, each Gray pointer carried across the clock boundary through a true two-flop synchronizer.
- `fifo_full`/`fifo_empty` are derived from the standard Gray-code MSB-invert comparison between local and synchronized pointers — safe against the multi-bit metastability risk of synchronizing a binary counter directly.
- `DEPTH` must be a power of two, which is a requirement of the Gray-code pointer/wraparound scheme used here, not an arbitrary restriction.

### `pulse_sync.v` — toggle-based clock-domain-crossing synchronizer

| | |
|---|---|
| **Ports** | `src_clk`, `src_rst_n`, `pulse_in[WIDTH-1:0]`, `pulse_valid_in`, `dst_clk`, `dst_rst_n`, `pulse_out[WIDTH-1:0]`, `sync_valid` |
| **Parameters** | `WIDTH = 8` |

- Crosses two genuinely independent clock domains (`src_clk`/`dst_clk`) using a toggle-on-every-valid-event scheme in the source domain and a true two-flop synchronizer on the toggle bit in the destination domain, with a third register for edge detection.
- Because the toggle bit flips on every valid strobe regardless of the data value, **repeated identical values are never dropped** — "new data arrived" is decoupled from "the value changed," which a level-comparison approach cannot guarantee.
- `pulse_valid_in` is an explicit strobe input; the source-domain data register is held stable for the full toggle period, so the destination domain can safely capture it with a plain two-stage register once the toggle edge is detected.

### `synapse_pipeline.v` — pipelined synaptic multiply-accumulate unit

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `event_data[31:0]`, `event_valid`, `event_ready`, `weight_in[31:0]`, `current_out[31:0]`, `current_valid`, `current_ready` |
| **Parameters** | `WIDTH = 32`, `DELAY = 8` |

- Computes a real multiply-accumulate term (`event_data × weight_in`) per synaptic event, propagates it through a `DELAY`-deep pipeline, and integrates it into a running accumulator that persists across multiple synaptic inputs.
- `DELAY` genuinely controls pipeline depth via a parameterized delay-line array, rather than a hardcoded stage count.
- **Real backpressure.** `event_ready` deasserts whenever the output register holds an undrained result and `current_ready` is low, so a new event is not accepted (and silently lost) while the consumer is stalled. Accumulated backlog is folded into `current_out` on the next successful handshake once the consumer becomes ready again.

### `weight_ram_par.v` — parallel-access weight RAM

| | |
|---|---|
| **Ports** | `clk`, `addr[RD_PORTS*$clog2(DEPTH)-1:0]`, `data_out[RD_PORTS*WIDTH-1:0]`, `waddr[$clog2(DEPTH)-1:0]`, `data_in[31:0]`, `we` |
| **Parameters** | `DEPTH = 256`, `WIDTH = 32`, `RD_PORTS = 4` |

- One synchronous write port plus `RD_PORTS` independent combinational read lanes, each with its own address, so `RD_PORTS` weights can genuinely be fetched in the same cycle — e.g. to feed multiple synapse lanes or multiple neurons in parallel.
- All locations initialize to `32'h00000010`.
- Read/write addresses are bit-packed across lanes (`addr[p*AW +: AW]` / `data_out[p*WIDTH +: WIDTH]` for lane `p`) to keep the port list a fixed width regardless of `RD_PORTS`.

### `spike_logger.v` — spike counter and log

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `spike_in`, `valid_in`, `ready_out`, `log_count[$clog2(DEPTH)-1:0]`, `overflow` |
| **Parameters** | `DEPTH = 1024` |

- Records a free-running cycle-count timestamp into a log array each time `spike_in && valid_in` is true and capacity remains, incrementing `log_count`.
- Asserts `overflow` for one cycle whenever a spike arrives while the log is full; clears it on the next successful write. `ready_out` reflects remaining capacity.
- Unchanged from the original implementation — its behavior already matched its description, so no fix was required here.

---

## Datapath (Verified End-to-End)

```
External Spike Input
        │
        ▼
┌───────────────────┐   wr_clk domain          rd_clk domain
│   event_fifo.v    │───────────────╫─────────────►
└─────────┬──────────┘   (Gray-coded pointers, 2-flop CDC sync)
          │
          ▼
┌────────────────────────┐    ┌────────────────────┐
│  synapse_pipeline.v     │◄───│  weight_ram_par.v   │
│  (real MAC + accumulate,│    │  (RD_PORTS parallel │
│   DELAY-stage pipeline) │    │   read lanes)        │
└─────────┬────────────────┘    └────────────────────┘
          │
          ▼
┌───────────────────────────┐
│    pipelined_lif.v        │  round-robin, all 16 neurons live,
│                            │  genuinely pipelined update
└─────────┬───────────────────┘
          │
          ▼
┌────────────────────┐
│  spike_logger.v     │  Counts spikes, logs timestamps
└────────────────────┘
```

`Testbench/spike_nn_tb_layered.sv`'s Test 8 wires this exact chain together procedurally, cycle by cycle, and confirms `spike_logger`'s count increments as a direct result of an event entering `event_fifo` — proving the full datapath, not just each module in isolation.

---

## Testbench

`Testbench/spike_nn_tb_layered.sv` instantiates all six RTL modules — including three independent clock domains (`clk`, `dst_clk`, `rd_clk`, at 10ns/14ns/17ns periods respectively, to genuinely exercise the CDC paths at unrelated frequencies) — and runs 8 tests in sequence.

| Test | What it checks |
|---|---|
| 1. Pulse Synchronization | True CDC across `src_clk`/`dst_clk`; explicit regression for the repeated-identical-value case |
| 2. FIFO Operation | Data written on `wr_clk` correctly crosses into the `rd_clk` domain and drains back to empty |
| 3. Weight RAM Access | All `RD_PORTS` read lanes return correct, independent data in parallel, same cycle |
| 4. Synapse Pipeline | Real MAC output value, accumulated correctly across multiple synaptic events, honoring backpressure |
| 5. LIF Neuron (neuron 0) | Gradual leaky-integrate accumulation across repeated sub-threshold injections correctly reaches threshold and spikes |
| 6. Spike Logger | Baseline counting/timestamping behavior |
| 7. Multi-Neuron Array | Five distinct neurons (0, 3, 7, 11, 15) targeted individually and confirmed to spike independently via `spike_bus` |
| 8. **Full Datapath Integration** | `event_fifo → synapse_pipeline → pipelined_lif → spike_logger` wired together and verified end-to-end |

A 2 ms simulation timeout (`#2_000_000`) guards against hangs, and `$dumpvars` writes a VCD (`spike_nn_layered.vcd`) for waveform inspection in GTKWave or similar tools.

---

## Design Notes

A few behaviors worth understanding before integrating or extending these blocks — none of these are defects, but they follow directly from the architectural choices made:

- **Pending-current overwrite, not accumulation, in `pipelined_lif.v`.** Because a single per-neuron register holds the "current waiting to be applied," injecting current into the same neuron faster than its round-robin service interval (`Neurons` cycles) causes the earlier injection to be overwritten rather than summed. Upstream logic driving `current_in`/`current_valid` at a high rate for a single neuron should account for this cadence.
- **`event_fifo.v`'s `DEPTH` must be a power of two.** This is a structural requirement of the Gray-code pointer scheme used for safe full/empty detection across the clock boundary, not an implementation shortcut.
- **`synapse_pipeline.v` uses a full-width signed multiplier** (`WIDTH × WIDTH → 2×WIDTH`, truncated to `WIDTH` on output). At `WIDTH = 32` this is a real 32×32 multiplier in the critical path of every synaptic event; area/timing budgets for a target process node should account for this rather than assume a pass-through delay line.
- **`pipelined_lif.v`'s legacy `spike_out`/`voltage_out`/`voltage_bus` ports reflect neuron 0 only.** They are provided for backward compatibility with single-neuron consumers; new integrations should use `spike_bus`/`voltage_flat` to observe the full array.

---

## License

MIT License — see `LICENSE`.

- Done as part of Digital Systems Design Elective Mini-Project Assignment
