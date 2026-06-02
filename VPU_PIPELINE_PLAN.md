# VPU Pipeline Plan for Gemma3-1B INT8 on ZCU104

## Paper Anchor

The paper's Figure 5 places the VPU between the memory/dequant path and the scalar/misc path.  Its VPU is a simple DOT engine: many parallel multipliers, a registered adder tree, a scaling multiplier, and an accumulator.  The key design choice is not a full matrix engine, but a bandwidth-area balanced vector DOT engine that can keep up with the memory stream during decode.

For this RTL project, the same strategy maps to:

```text
AXI4-Stream activation ----\
                            PMAU_Streaming -> AXI4-Stream dot result -> CPU/SPU path
AXI4-Stream weight+scale --/
```

## RTL Changes Applied

- `RTL/PMAU_Streaming.v` now has a fully registered multiply/reduction pipeline:
  - Stage 0: `NUM_LANES` signed `INT8 x INT8` multipliers.
  - Stage 1..`log2(NUM_LANES)`: binary adder-tree levels, one register per level.
  - Commit stage: row accumulator, fixed-point dequant placeholder, result FIFO.
- The input AXI4-Stream channels are joined safely:
  - a beat is accepted only when activation and weight are both valid;
  - `tlast` marks the end of one dot-product row/token segment.
- The output path is AXI-compliant:
  - `result_valid` is held until `result_ready`;
  - a small result FIFO prevents overwriting completed rows when downstream stalls.
- `RTL/VPU_Top.v` remains a thin wrapper so the Vivado block design sees stable AXI4-Stream names.

## Lane Width Choices

- Current default: `NUM_LANES=16`, matching a 128-bit stream for `16 x INT8`.
- If you aggregate four 128-bit HP streams like the paper's 512-bit MCU, use `NUM_LANES=64` for packed `INT8` weights/activations.
- The paper's 128-multiplier VPU comes from `512-bit W4 -> 128 FP16 dequantized values`.  That is a different datapath from this INT8 RTL.  To match it exactly, replace the INT8 multiply stage with FP16 multiply IPs and set the dequant path before the VPU.

## Integration Checklist

1. Keep activation and weight streams aligned: same beat count and same `tlast` position per row.
2. Choose `NUM_LANES` from real stream width and DSP budget on ZCU104.
   Keep `RESULT_FIFO_DEPTH` as a power of two.
3. Decide the scale format:
   - current RTL uses positive fixed-point scale with `SCALE_FRAC_BITS=15`;
   - `16'h3c00` bypasses dequant for existing raw-accumulator tests;
   - use a Xilinx FP16 multiplier/converter if you want paper-accurate FP16.
4. Run behavioral simulation, then synthesize with the target lane count.
5. Add ILA probes on `axis_*_tvalid/tready/tlast`, FIFO count, and `status_state` first.  Debug the stream boundaries before tuning Fmax.

## Timing Notes

The critical path is now limited to one multiply or one adder level per clock.  For larger `NUM_LANES`, latency increases by `log2(NUM_LANES)`, but steady-state throughput remains one accepted beat per clock when downstream is ready.
