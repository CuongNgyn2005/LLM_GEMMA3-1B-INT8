# DATN SoC Architecture Overview

## Architecture Goal

This project targets an INT8-quantized Gemma3-1B accelerator on the Xilinx ZCU104. The current architecture prioritizes:

- extending usable context length through tiled tensor, weight, and KV-cache management;
- keeping the VPU as a fast and timing-friendly INT8 datapath;
- running the SPU and scalar/non-linear operations on the CPU/PS;
- using AXI4-Full memory-mapped access for PS-side data loading, runtime configuration, VPU start control, and result readback.

## High-Level Block Diagram

```text
          Zynq UltraScale+ MPSoC PS
        +---------------------------+
        | CPU/SPU software          |
        | - RoPE/RMSNorm/Softmax    |
        | - SiLU/Quant/KV packing   |
        | - tile scheduling         |
        +-------------+-------------+
                      |
                      | AXI4-Full memory-mapped
                      v
        +-------------+-------------+
        | VPU_Top                   |
        | - project top module      |
        | - AXI4-Full ports         |
        +-------------+-------------+
                      |
                      v
        +-------------+-------------+
        | MY_IP                     |
        | - AXI4-Full slave         |
        | - AW/W/B/AR/R protocol    |
        | - burst sequencing        |
        +-------------+-------------+
                      |
                      v
        +-------------+-------------+
        | AXI4_Mapping              |
        | - local address map       |
        | - config/status registers |
        | - memory-window decode    |
        +-------------+-------------+
                      |
                      v
        +-------------+-------------+
        | Matrix_Vector_Multiplication
        | - runtime rows/cols       |
        | - activation/weight BRAM  |
        | - result BRAM             |
        +-------------+-------------+
                      |
                      v
        +-------------+-------------+
        | PMAU_Full                 |
        | - 16-lane INT8 MAC        |
        | - registered adder tree   |
        | - INT32 accumulation      |
        +---------------------------+
```

## AXI4-Full Address Map

`AXI4_Mapping.v` is now an internal module under `MY_IP`. It owns the local register map, memory-window decode, and optional physical-base translation from `40'h00A0_0000_00` into the local VPU offset space. If the Vivado AXI interconnect already strips the base address, the local address is passed through unchanged.

| Local offset | Purpose |
|---:|---|
| `0x0000_0000` | CTRL: start / clear done |
| `0x0000_0010` | STATUS: done, busy, error |
| `0x0000_0020` | ROWS |
| `0x0000_0030` | COLS |
| `0x0000_0040` | COL_BEATS, write 0 to derive it from COLS in hardware |
| `0x0000_0050` | SCALE placeholder / fixed-point scale |
| `0x0000_0060` | MODE placeholder |
| `0x0000_0070` | LIMITS: MAX_ROWS, MAX_COL_BEATS |
| `0x0000_0080` | PROGRESS: active row / column beat |
| `0x0001_0000` | Activation BRAM write window |
| `0x0010_0000` | Weight BRAM write window |
| `0x0020_0000` | Result BRAM read window |

## Local Memory Organization

The VPU uses `Dual_Port_BRAM.v` for three internal storage regions:

- activation BRAM: written by the PS through AXI, read by the VPU during compute;
- weight BRAM: written by the PS through AXI, read by the VPU using `row * MAX_COL_BEATS + col_beat`;
- result BRAM: written by the VPU with INT32 row results, read by the PS through AXI.

Default parameters:

| Parameter | Value |
|---|---:|
| `NUM_LANES` | 16 |
| `AXI_DATA_WIDTH` | 128 |
| `MAX_ROWS` | 128 |
| `MAX_COL_BEATS` | 256 |

Local tile capacity:

- activation: `256 * 16 bytes = 4096 bytes`;
- weight: `128 * 256 * 16 bytes = 524288 bytes`;
- result: `128 * 4 bytes = 512 bytes`;
- maximum vector length per row: `256 * 16 = 4096` INT8 elements.

Activation and weight tiles should be written as full 128-bit beats with all WSTRB bits enabled. If the last vector beat has fewer than 16 INT8 elements, software should zero-pad the unused lanes before starting the VPU.

## Runtime Flow

1. The CPU computes or loads the activation and weight tile from DDR.
2. The CPU writes activation data to `ACT_BASE`.
3. The CPU writes weight data to `WEIGHT_BASE`.
4. The CPU writes `ROWS`, `COLS`, and optionally `COL_BEATS`.
5. The CPU writes CTRL start.
6. The VPU reads BRAM beats and feeds them into `PMAU_Full`.
7. `PMAU_Full` computes INT8 dot products and returns INT32 row results.
8. The GEMV core writes results into result BRAM.
9. The CPU polls or receives the done status and reads results.
10. CPU/SPU software runs RoPE, RMSNorm, Softmax, SiLU, quantization, and KV packing.

## Pipeline Boundary

The high-speed pipeline is inside the VPU:

```text
BRAM read -> PMAU input register -> INT8 multipliers
          -> registered adder tree -> accumulator/result FIFO
          -> result BRAM
```

The SPU currently runs on the CPU. CPU-side functions that can be pipelined or vectorized include RoPE, RMSNorm, Softmax, SiLU, quantization, Serial2Parallel packing, and scale-zero FIFO packing.

## ZCU104 Integration Notes

- The IP should be connected inside a Vivado Block Design through an AXI interconnect. The AXI signals should not be mapped directly to FPGA package pins.
- Full-system implementation must be rerun after connecting the real PS, AXI interconnect, clock, and reset network.
- `Dual_Port_BRAM.v` is only a local memory primitive wrapper. It does not replace DDR or a large KV cache.
- For longer context lengths, tensors and weights should be tiled from DDR while BRAM is used as near-compute staging storage.
