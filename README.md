# Spike NN ASIC — Digital Spiking Neural Network for ASIC Implementation

> RTL Design and Verification of a Pipelined Leaky Integrate-and-Fire Spiking Neural Network in Verilog, targeting ASIC implementation

![Language](https://img.shields.io/badge/Language-Verilog%20%7C%20SystemVerilog-blue)
![Domain](https://img.shields.io/badge/Domain-Neuromorphic%20Computing-purple)
![License](https://img.shields.io/badge/License-See%20LICENSE-lightgrey)

---
## Overview

This project implements a small set of digital building blocks commonly
found in spiking neural network (SNN) hardware: a leaky integrate-and-fire
(LIF) neuron, a synchronous event FIFO, a multi-stage pulse delay/edge
detector, a synaptic weight RAM, a fixed-depth pipeline that forwards
synaptic weights, and a spike event logger.

The blocks share a single clock domain and are functionally independent —
each is exercised by its own dedicated test in the testbench, with no signal
path wiring one module's output into another's input. This is a unit-level
verification environment, not an integration test of an end-to-end datapath.


## Repository Structure

```
Spike_NN_ASIC/
├── Design/
│   ├── event_fifo.v                   # Asynchronous event FIFO for AER spike buffering
│   ├── pipelined_lif.v                # Pipelined Leaky Integrate-and-Fire neuron core
│   ├── pulse_sync.v                   # Pulse synchronizer for clock-domain crossing
│   ├── spike_logger.v                 # Spike event logger / monitor module
│   ├── synapse_pipeline.v             # Pipelined synaptic weight accumulation unit
│   └── weight_ram_par.v               # Parallel-access weight RAM (synapse memory)
│
├── References/
|
│
├── Reports/
│   └── Team7_DSD_Mini_Project-1.pdf   # Full project report: design, simulation, analysis
│
├── Testbench/
│   └── spike_nn_tb_layered.sv         # Layered SystemVerilog testbench for full SNN datapath
│
├── LICENSE                            # License file
└── README.md                          # This file
```
---

## Module Reference

### `pipelined_lif.v` — LIF neuron array

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `current_in[31:0]`, `current_valid`, `spike_out`, `voltage_out[15:0]`, `voltage_bus[Neurons-1:0]` |
| **Parameters** | `Neurons = 16`, `Pipeline_Stages = 4` |

- Implements leaky-integrate-and-fire dynamics as `v_new = v - (v >>> 5) + current_in` per cycle, with a fixed threshold (`16'sd200`) and reset-to-zero on spike. The leak is a fixed right-shift, not a multiplicative, programmable leak factor.
- **Only neuron 0 drives the module's outputs.** `spike_out` and `voltage_out` reflect neuron 0 exclusively. Neurons 1–3 compute their own leak/integrate/threshold logic and update their own internal state register, but their spike condition is never connected to any output port.
- **Neurons 4–15 are non-functional.** They are declared and reset to `0` but are never updated in any clocked or combinational logic afterward — they hold a constant value of zero for the lifetime of the simulation.
- `voltage_bus` outputs bit `[0]` of each of the 16 neuron voltage registers. Since neurons 4–15 never change, 12 of the 16 bits on this bus are permanently `0`.
- The `Pipeline_Stages` parameter is declared but not referenced anywhere in the module body. There is no pipelined datapath inside this module — each neuron's update is single-cycle combinational logic followed by one register stage.
- `THRESHOLD`, `RESET_VAL`, and `LEAK_SHIFT` are fixed `localparam`s, not runtime-configurable inputs.

**In short:** this module behaves as a single working LIF neuron (neuron 0). The 16-neuron array and pipelining implied by the parameters are not implemented.

### `event_fifo.v` — synchronous FIFO

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `data_in`, `valid_in`, `ready_out`, `data_out`, `valid_out`, `ready_in`, `fifo_full`, `fifo_empty` |
| **Parameters** | `DEPTH = 32`, `WIDTH = 16` |

- A standard single-clock FIFO using a write pointer, read pointer, and occupancy counter, with a ready/valid handshake on both sides.
- There is **one clock domain**. The module has no separate write-clock/read-clock ports, so it does not perform clock-domain crossing. Any description of this block as an *asynchronous* FIFO refers to design intent, not the current implementation.
- `fifo_full`, `fifo_empty`, and `data_out` are registered one cycle after the occupancy count that produced them, so downstream logic sampling these flags combinationally will see them one cycle later than the corresponding `count` transition.

### `pulse_sync.v` — same-clock pulse/edge detector

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `pulse_in[WIDTH-1:0]`, `pulse_out[WIDTH-1:0]`, `sync_valid` |
| **Parameters** | `WIDTH = 8` |

- Contains a **three-stage** register chain (`sync_reg1` → `sync_reg2` → `sync_reg3`), not a two-flop synchronizer.
- Runs entirely on a single `clk`. `pulse_in` and the synchronizing registers are in the same clock domain, so this module does not perform clock-domain crossing as a true CDC synchronizer would; functionally it is a multi-cycle delay with edge detection.
- `sync_valid` asserts when the delayed value differs from the last captured value and is nonzero. **Known limitation:** if the same nonzero value is presented twice in a row, the second occurrence is indistinguishable from "no change" and `sync_valid` will not assert for it. Repeated identical addresses are silently dropped.

### `synapse_pipeline.v` — fixed delay line

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `event_data[31:0]`, `event_valid`, `event_ready`, `weight_in[31:0]`, `current_out[31:0]`, `current_valid`, `current_ready` |
| **Parameters** | `WIDTH = 32`, `DELAY = 8` |

- Shifts `weight_in` through eight register stages and presents it on `current_out` once the corresponding `event_valid` has propagated through all eight stages.
- **There is no multiplication or accumulation.** The output stage is `current_out <= pipe_weight_7;` — the weight value is passed through unchanged after an 8-cycle delay. `event_data` is also pipelined but not combined with the weight in any arithmetic operation.
- The `DELAY` parameter is declared but not used; the pipeline depth (8 stages) is hardcoded regardless of its value.
- `event_ready` is permanently tied to `1`. `current_ready` is an input but is never read, so there is no real backpressure on the output side.

### `weight_ram_par.v` — single-port RAM

| | |
|---|---|
| **Ports** | `clk`, `addr[$clog2(DEPTH)-1:0]`, `data_out[31:0]`, `data_in[31:0]`, `we` |
| **Parameters** | `DEPTH = 256`, `WIDTH = 32` |

- A standard single-port memory: synchronous write on `we`, combinational read on `addr`. All locations initialize to `32'h00000010`.
- There is a single address port shared between read and write. The module does not provide parallel or multi-lane access — only one location can be addressed per cycle.

### `spike_logger.v` — spike counter and log

| | |
|---|---|
| **Ports** | `clk`, `rst_n`, `spike_in`, `valid_in`, `ready_out`, `log_count[$clog2(DEPTH)-1:0]`, `overflow` |
| **Parameters** | `DEPTH = 1024` |

- Records a 32-bit timestamp (free-running cycle counter) into a log array each time `spike_in && valid_in` is true and the log has capacity, and increments `log_count`.
- Asserts `overflow` for one cycle whenever a spike arrives while the log is full; clears it on the next successful write.
- `ready_out` reflects whether the log has remaining capacity (`can_write`).
- This module's behavior is consistent with its description: a straightforward counting/timestamping logger with overflow detection.

---

## Datapath Diagram (Design Intent)
```
External Spike Input
        │
        ▼
┌─────────────────┐
│  event_fifo.v   │  Single-clock FIFO, ready/valid handshake
└────────┬────────┘
         │ (not wired in current testbench)
         ▼
┌──────────────────────┐    ┌──────────────────┐
│  synapse_pipeline.v  │◄───│ weight_ram_par.v  │
│  (8-cycle delay,     │    │  (single-port RAM)│
│   weight pass-through)│   └──────────────────┘
└────────┬─────────────┘
         │ (not wired in current testbench)
         ▼
┌──────────────────┐
│ pipelined_lif.v  │  1 of 16 declared neurons functional
└────────┬─────────┘
         │ (not wired in current testbench)
         ▼
┌──────────────────┐
│ spike_logger.v   │  Counts spikes, logs timestamps
└──────────────────┘
```

---

## Testbench

`Testbench/spike_nn_tb_layered.sv` instantiates all six RTL modules under a
single shared `clk`/`rst_n` and runs six independent tests in sequence. Each
test drives its DUT's inputs directly with testbench-generated stimulus —
**no module's output is connected to another module's input.** This is a
per-module (unit) verification environment, not a datapath integration test.

| Test | What it checks | Notes |
|---|---|---|
| 1. Pulse Sync | Sends one pulse, checks `pulse_sync_valid` asserts within 10 cycles | Only the first pulse is checked for `sync_valid`; two later pulses are sent with no assertion. Does not exercise the repeated-value drop case noted above. |
| 2. FIFO Operation | Writes 10 entries, checks `!fifo_empty && fifo_valid_out` | Reasonable coverage of fill/non-empty behavior for the single-clock FIFO. |
| 3. Weight RAM | Writes 8 addresses, reads back, checks exact value match | Solid read-after-write check for the single-port RAM. |
| 4. Synapse Pipeline | Sends 5 events with a fixed weight, checks `current_valid` asserts within 20 cycles | Only checks that *some* output appears, not that the value is correct. Because the module passes weight through unmodified, this test cannot distinguish a working multiply-accumulate from a simple delay line. |
| 5. LIF Neuron | Repeatedly injects current, checks `spike_out` eventually asserts | Exercises neuron 0 only, since that is the only neuron connected to any output. Cannot validate behavior of the other 15 declared neurons, because none of them are observable from outside the module. |
| 6. Spike Logger | Fires 10 spaced spike pulses, checks `log_count == 10` | Solid check for normal-operation counting. Does not exercise the overflow path. |

A 2 ms simulation timeout (`#2_000_000`) guards against hangs, and `$dumpvars`
writes a VCD (`spike_nn_layered.vcd`) for waveform inspection in GTKWave or
similar tools.

---

## Known Gaps / Suggested Next Steps

These are the concrete deltas between what this project's name/structure
suggests and what is currently implemented. Listed roughly in order of
impact if the goal is a genuinely multi-neuron, pipelined, asynchronous SNN
core:

1. **No datapath integration test.** The six modules are never wired
   together in simulation. Connecting `event_fifo` → `synapse_pipeline` →
   `pipelined_lif` → `spike_logger` and verifying spikes flow correctly
   end-to-end is the largest remaining gap.
2. **15 of 16 neurons in `pipelined_lif.v` are unused or dead.** Neurons 1–3
   compute state but aren't observable; neurons 4–15 never update. Exposing
   per-neuron spike/voltage outputs (or multiplexing them) would be needed
   for this to function as a multi-neuron array.
3. **No actual pipelining in `pipelined_lif.v`.** The `Pipeline_Stages`
   parameter has no effect; the neuron update is single-cycle.
4. **No multiply-accumulate in `synapse_pipeline.v`.** `weight_in` is
   delayed and passed through unchanged; it is never combined with
   `event_data` or accumulated across multiple synaptic inputs.
5. **No clock-domain crossing anywhere in the design.** `event_fifo.v` and
   `pulse_sync.v` both operate on a single clock. If true AER-style
   asynchronous communication between domains is a goal, both modules need
   a second clock port and a proper CDC structure (e.g., gray-coded pointers
   for the FIFO, a true two-register synchronizer for the pulse path).
6. **`pulse_sync.v` drops repeated identical values.** The edge-detection
   condition (`sync_reg3 != pulse_last`) treats a repeated nonzero value as
   "no change." A valid-toggle or separate strobe signal would resolve this.
7. **`weight_ram_par.v` is single-port, not parallel.** Multi-lane access
   would require multiple address/data ports or banking.
8. **Threshold, reset value, and leak factor are fixed `localparam`s.**
   Making these runtime-programmable inputs would match the "configurable
   neuron parameters" framing implied by the module's parameter list.

---


## License

MIT License — see `LICENSE`.

Done as part of a Digital Systems Design elective mini-project assignment.
Benchmarked using hardcoded dummy stimulus values, not a real dataset.
---


- Done as part of Digital Systems Design Elective Mini-Project Assignment
