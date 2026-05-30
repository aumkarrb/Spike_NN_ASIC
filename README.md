# Spike_NN_ASIC

# Spike NN ASIC — Digital Spiking Neural Network for ASIC Implementation

> RTL Design and Verification of a Pipelined Leaky Integrate-and-Fire Spiking Neural Network in Verilog, targeting ASIC implementation

![Language](https://img.shields.io/badge/Language-Verilog%20%7C%20SystemVerilog-blue)
![Domain](https://img.shields.io/badge/Domain-Neuromorphic%20Computing-purple)
![License](https://img.shields.io/badge/License-See%20LICENSE-lightgrey)

---

## Overview

This project implements a **Digital Spiking Neural Network (SNN)** in Verilog targeting ASIC fabrication. The design follows the biologically inspired **Leaky Integrate-and-Fire (LIF)** neuron model and communicates spike events using the **Address Event Representation (AER)** protocol — the standard asynchronous spike-routing protocol used in neuromorphic chips such as Intel Loihi.

The architecture is structured as a multi-module RTL design featuring a pipelined LIF neuron core, a parallel weight RAM, a synapse pipeline for accumulation, event-driven FIFO buffering, pulse-domain clock synchronization, and a spike logging unit. A layered SystemVerilog testbench validates the full datapath end-to-end.

---

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

## Design Architecture

The SNN datapath is composed of six cooperating Verilog modules. Spike events flow from external stimulus → AER FIFO → synapse pipeline → LIF neuron → spike output → spike logger:

```
External Spike Input (AER events)
        │
        ▼
┌─────────────────┐
│  event_fifo.v   │  ◄── Buffers incoming AER spike events asynchronously
│  (AER FIFO)     │
└────────┬────────┘
         │  pulse_sync.v (CDC for FIFO read/write domains)
         ▼
┌──────────────────────┐    ┌──────────────────┐
│  synapse_pipeline.v  │◄───│ weight_ram_par.v  │
│  (weighted accum.)   │    │  (synaptic RAM)   │
└────────┬─────────────┘    └──────────────────┘
         │  Weighted synaptic current
         ▼
┌──────────────────┐
│ pipelined_lif.v  │  ◄── Integrates input, applies leak, checks threshold
│  (LIF neuron)    │
└────────┬─────────┘
         │  Output spike (AER address-event)
         ▼
┌──────────────────┐
│ spike_logger.v   │  ◄── Records spike time and neuron address
└──────────────────┘
```

### Module Details

| Module | Key Function | Interface |
|--------|-------------|-----------|
| `pipelined_lif.v` | Membrane potential integration with programmable leak factor and threshold; fires spike when V_mem ≥ V_th; resets after firing | `clk`, `rst`, `i_current`, `o_spike` |
| `synapse_pipeline.v` | Fetches weight from RAM, multiplies by pre-synaptic spike, accumulates into post-synaptic current over pipeline stages | `clk`, `rst`, `i_spike_addr`, `o_current` |
| `weight_ram_par.v` | Stores synaptic weight matrix; parallel read for simultaneous multi-lane synapse access | `clk`, `we`, `addr`, `din`, `dout` |
| `event_fifo.v` | AER event FIFO with independent write/read clocks; generates `full` / `empty` flags | `wclk`, `rclk`, `wrst_n`, `rrst_n`, `winc`, `rinc` |
| `pulse_sync.v` | Two-flop synchronizer for spike pulse CDC; prevents metastability at clock-domain boundary | `clk_dst`, `rst_n`, `pulse_in`, `pulse_out` |
| `spike_logger.v` | Timestamps and records each output spike with neuron address for waveform/log analysis | `clk`, `rst`, `i_spike`, `i_addr`, log output |

---

## SNN Design Principles

### Leaky Integrate-and-Fire (LIF) Neuron

The LIF model is the standard digital neuron model for ASIC neuromorphic designs:

```
V_mem[t+1] = λ · V_mem[t] + I_syn[t]     (integrate with leak λ < 1)

if V_mem[t] ≥ V_th:
    fire spike → reset V_mem to V_reset
```

| Parameter | Description |
|-----------|-------------|
| `V_mem` | Membrane potential register |
| `λ` | Leak factor (programmable decay per timestep) |
| `I_syn` | Weighted synaptic input current |
| `V_th` | Firing threshold |
| `V_reset` | Post-spike reset potential |

### Address Event Representation (AER)

AER is the standard spike communication protocol for neuromorphic chips. When a neuron fires, it places its address on a shared bus asynchronously — enabling sparse, event-driven communication that scales with network activity rather than network size. The `event_fifo.v` and `pulse_sync.v` modules implement AER-compatible inter-module communication.

---

## Testbench

`Testbench/spike_nn_tb_layered.sv` is a layered SystemVerilog testbench that:

- Instantiates all six RTL modules and wires them into the full SNN datapath
- Generates independent write and read clocks for the AER FIFO
- Applies reset sequences and pre-loads the weight RAM with test weight configurations
- Injects AER spike stimulus at the FIFO input
- Monitors `spike_logger` output and checks that output spikes occur at the expected timesteps
- Dumps waveforms for GTKWave analysis

---


## References

| File | Full Title / Source |
|------|---------------------|
| `AER_Stanford.pdf` | Address Event Representation — Stanford Neuromorphic Engineering reference (Boahen group) |
| `A_Review_of_Spiking_Neural_Ne...` | A Review of Spiking Neural Networks: hardware implementations, learning rules, and applications |
| `AnIntroductoryReviewofSpiking...` | An Introductory Review of Spiking Neural Networks — LIF models, digital ASIC design, encoding schemes |
| `Intel_Loihi_Chip.pdf` | Davies et al., *Loihi: A Neuromorphic Manycore Processor with On-Chip Learning*, IEEE Micro 2018 |
| `Introduction_to_Spiking_Neural...` | Introduction to Spiking Neural Networks — biological motivation and computational models |
| `Neuromorphic_Computing_Wit...` | Neuromorphic Computing — architectures, chip designs, and digital implementation strategies |
| `Samwi_Reconfigurable_Digital_F...` | Samwi et al., *Reconfigurable Digital FPGA Implementations for Neuromorphic Computing: A Survey* |
| `fnins-16-1018166.pdf` | Frontiers in Neuroscience, Volume 16, Article 1018166 — neuromorphic engineering peer-reviewed paper |

---

## Topics
- Done as part of Digital Systems Design Elective Mini-Project Assignment
