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
├── docs/
│   ├── spike_nn_asic_top_level_architecture.svg   # System-level architecture diagram
│   └── pipelined_lif_datapath.svg                 # pipelined_lif.v internal datapath diagram
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

![Spike_NN_ASIC top-level architecture](docs/spike_nn_asic_top_level_architecture.svg)

`Testbench` (left) drives the `RTL Core` (right) through SystemVerilog stimulus tasks and reads results back via `spike_bus`/`log_count`. All six `Design/*.v` modules are shown with their key parameters: `event_fifo` and `weight_ram_par` feed `synapse_pipeline`, which feeds `pipelined_lif`, which feeds `spike_logger`. `pulse_sync` is drawn with a dashed outline because it's a standalone CDC utility, exercised independently in the testbench rather than being part of that chain.

---

## Pipelined LIF Datapath

![pipelined_lif.v internal datapath](docs/pipelined_lif_datapath.svg)

One neuron is serviced per cycle by a free-running round-robin counter (`rr_sel`). Each service slot fetches that neuron's pending synaptic current, applies leak and injection, compares the result against `threshold_in`, and commits the neuron's state — spiking and resetting to `reset_val_in` when `v' ≥ threshold_in`, otherwise writing back the new voltage. `threshold_in`, `reset_val_in`, and `leak_shift_in` are live input ports rather than fixed `localparam`s, and `spike_bus`/`voltage_flat` expose every neuron's state for observability, not just neuron 0.

This diagram zooms into `pipelined_lif.v` specifically; the full chain it sits in is verified end-to-end by `Testbench/spike_nn_tb_layered.sv`'s Test 8, which wires `event_fifo → synapse_pipeline → pipelined_lif → spike_logger` together procedurally, cycle by cycle, and confirms `spike_logger`'s count increments as a direct result of an event entering `event_fifo`.

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
