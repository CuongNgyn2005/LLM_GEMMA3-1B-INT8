# VPU Pipeline Plan for Gemma3-1B INT8 on ZCU104

## 1. Conclusion After Double-Checking the Paper

The paper "Pushing up to the Limit of Memory Bandwidth and Capacity Utilization for Efficient LLM Decoding on Embedded FPGA" places the VPU in Figure 5B as a bandwidth-area balanced DOT engine: parallel multipliers, an adder tree, a scaling multiplier, and an accumulator. The paper uses W4A16 and FP16 compute after dequantization, but this project is currently targeting an INT8-quantized datapath.

Therefore, this RTL plan keeps the paper's DOT-engine pipeline idea, but changes the numeric contract to:

```text
activation INT8 + weight INT8 -> parallel INT8 x INT8 -> INT32 reduction
                                -> INT32 row accumulator -> optional fixed-point scale
                                -> result BRAM INT32
```

The VPU does not use FP16 multipliers. If scale or dequantization is required, the scale should be fixed-point or handled by CPU/SPU software instead of introducing FP16 into the VPU datapath.

## 2. Interface for the Current Architecture

The current top-level VPU no longer uses AXI-Stream. The external bus is AXI4-Full memory-mapped.

Current hierarchy:

```text
PS/AXI master
  -> VPU_Top.v: project-facing AXI4-Full top module
  -> MY_IP.v: AXI4-Full protocol shell and burst sequencing
  -> AXI4_Mapping.v: local register/address mapping layer
  -> Matrix_Vector_Multiplication.v: BRAM-backed INT8 GEMV engine
  -> PMAU_Full.v: internal valid/ready MAC pipeline
```

`PMAU_Full` only uses internal valid/ready handshaking between the GEMV FSM and the MAC pipeline. It is not an AXI-Stream top-level interface.

The address map should remain consistent:

| Local offset | Purpose |
|---:|---|
| `0x0000_0000` | CTRL: start / clear done |
| `0x0000_0010` | STATUS: done, busy, error |
| `0x0000_0020` | ROWS |
| `0x0000_0030` | COLS |
| `0x0000_0040` | COL_BEATS, write 0 to let hardware derive it from COLS |
| `0x0000_0050` | SCALE, fixed-point/control placeholder |
| `0x0001_0000` | Activation BRAM window |
| `0x0010_0000` | Weight BRAM window |
| `0x0020_0000` | Result BRAM window |

`AXI4_Mapping.v` is now an internal module under `MY_IP`. It owns the local register map, memory-window decode, and optional physical-base translation from `40'h00A0_0000_00` into local offsets. If the Vivado AXI interconnect already strips the base address, the address is passed through unchanged.

## 3. VPU Pipeline Used in the RTL

The current pipeline contains these stages:

```text
AXI4-Full burst write
  -> MY_IP AXI protocol shell
  -> AXI4_Mapping local decode/config
  -> registered write request into activation/weight BRAM
  -> GEMV FSM issue read
  -> BRAM read output register
  -> PMAU input register
  -> NUM_LANES parallel INT8 multipliers
  -> registered binary adder tree
  -> row accumulator
  -> fixed-point scale/bypass stage
  -> result FIFO
  -> result BRAM
  -> AXI4-Full result read
```

Important details:

- `MY_IP.v` handles AXI4-Full protocol behavior, including AW/W/B/AR/R channels, burst sequencing, IDs, and responses.
- `AXI4_Mapping.v` decodes local registers and memory windows, stores configuration/status registers, and instantiates the GEMV core.
- `Matrix_Vector_Multiplication.v` uses BRAM-backed activation, weight, and result storage through `Dual_Port_BRAM.v`.
- `Matrix_Vector_Multiplication.v` has a register stage after BRAM read and before PMAU input, cutting the BRAM cascade to multiplier/add-tree timing path.
- `PMAU_Full.v` performs `NUM_LANES` signed `INT8 x INT8` multiplications in parallel.
- The adder tree is registered at every level, so the critical path is limited to one multiplier or one adder level.
- The result FIFO holds completed row results until the GEMV core writes them into result BRAM.
- AXI readback of activation/weight is disabled to preserve timing. The CPU writes activation/weight and reads only status/result.

With `NUM_LANES=16`, each 128-bit beat contains 16 INT8 elements. The target steady-state throughput after warm-up is one MAC beat per clock when the FIFO/result path does not stall.

## 4. Runtime Shape and Context Capacity

Current default parameters:

| Parameter | Value | Meaning |
|---|---:|---|
| `NUM_LANES` | 16 | 16 INT8 lanes per 128-bit beat |
| `MAX_ROWS` | 128 | Maximum output rows per run |
| `MAX_COL_BEATS` | 256 | Maximum 128-bit beats per row |
| `AXI_DATA_WIDTH` | 128 | AXI4-Full data width |

Internal storage capacity:

- Activation BRAM: `MAX_COL_BEATS * 16 bytes = 4096 bytes`
- Weight BRAM: `MAX_ROWS * MAX_COL_BEATS * 16 bytes = 524288 bytes`
- Result BRAM: `MAX_ROWS * 4 bytes = 512 bytes`
- Maximum INT8 columns per row: `MAX_COL_BEATS * NUM_LANES = 4096`

If the input size is not known beforehand, software only needs to write `ROWS`, `COLS`, and optionally `COL_BEATS=0`. Hardware derives:

```text
effective_col_beats = ceil(COLS / NUM_LANES)
```

If `COLS` is not divisible by 16, the final beat must be zero-padded. This keeps the pipeline simple and avoids adding mask logic to the critical path.

## 5. Direction for Storing More Tensor/Weight Data

Longer context depends on KV-cache capacity, intermediate activations, and weight tiling. In the current VPU, BRAM is primarily used as near-compute staging storage for activation and weight tiles. Scaling should follow this order:

1. Increase `MAX_COL_BEATS` if a longer vector is needed for one dot product. The weight BRAM cost grows linearly with `MAX_ROWS * MAX_COL_BEATS`.
2. Increase `MAX_ROWS` if more output rows are needed per run. The weight BRAM cost also grows linearly.
3. If BRAM is insufficient, keep `MAX_ROWS/MAX_COL_BEATS` moderate and tile rows/columns from DDR through AXI4-Full bursts. This is more suitable for long context because DDR is the large storage resource for weights and KV cache.
4. Add ping-pong activation/weight tile buffers if future versions need to overlap CPU/AXI loading with VPU compute. The current design does not include double buffering to keep the RTL compact and timing-friendly.
5. For longer KV cache, prioritize INT8 KV cache plus scale/zero packing, as suggested by the paper. Do not try to keep the full KV cache in BRAM; BRAM should be used as staging/cache near compute.

## 6. Timing Target and Pipeline Double-Check

The previous out-of-context route result reached 300 MHz on the ZCU104 part with positive WNS. To preserve this when extending the design:

- Do not reconnect AXI decode logic directly to BRAM write enable/address paths.
- Do not enable AXI readback for activation/weight unless it is absolutely required.
- Keep the BRAM output register before PMAU.
- Keep the adder tree as a registered binary tree.
- Do not increase `NUM_LANES` to 32 or 64 without rerunning timing, because multiplier fanout and the adder tree become larger.
- If increasing BRAM capacity, prefer increasing depth over increasing datapath width.
- If 512-bit bandwidth similar to the paper is required, implement it in the MCU/interconnect/tile-loader layer and feed the VPU through 128-bit bursts instead of immediately changing the VPU core to 512-bit.

Approximate latency for one row:

```text
row_latency ~= col_beats
             + BRAM/FSM feed latency
             + (1 multiply stage + log2(NUM_LANES) adder stages)
             + accumulator/scale/result FIFO latency
```

With `NUM_LANES=16`, the adder tree has 4 levels. Latency grows with `log2(NUM_LANES)`, but throughput can still remain one beat per clock after warm-up.

## 7. Next Work Items

1. Rerun simulation and timing whenever `MAX_ROWS`, `MAX_COL_BEATS`, or `NUM_LANES` changes.
2. Add longer AXI burst testbenches to stress `COL_BEATS=0`, zero-padding, and more output rows.
3. Remove the FP16 meaning of the `16'h3c00` sentinel in documentation/code after the fixed-point scale format is finalized. In the current version it is only a bypass marker for raw INT32 accumulator tests.
4. If CPU/SPU software handles dequantization or activation processing next, keep the VPU output as INT32 and pass scale/zero metadata at the software layer.
