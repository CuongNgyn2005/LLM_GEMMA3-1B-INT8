# VPU Simulation and Pipeline Report

Date: 2026-06-02  
Tool: Vivado / XSim 2022.2 (`D:/Xlinx/Vivado/2022.2`)  
Target: ZCU104, `xczu7ev-ffvc1156-2-e`  

## Scope

RTL under test:

- `../RTL/PMAU_Streaming.v`
- `../RTL/VPU_Top.v`

Main testbenches:

- `../TESTBENCH/tb_PMAU_Streaming.v`
- `../TESTBENCH/tb_VPU_Top.v`

Working/log directory:

- `DATN_VIVADO/manual_sim/`

## Simulation Results

### PMAU_Streaming

Command flow: `xvlog -> xelab -> xsim -runall`

Final log:

- `DATN_VIVADO/manual_sim/pmau_sim_final.log`

Result:

```text
Total Tests: 5
PASS: 5
FAIL: 0
```

Coverage in this testbench:

- Single 64-element INT8 dot product.
- Multiple back-to-back dot products.
- Source-side input stall before one beat.
- Signed INT8 golden model corrected with explicit INT32 sign extension.

Observed result latency:

```text
Result received after 7 cycles latency
```

The latency increased after adding the dequant output pipeline, but the input pipeline still accepts one paired activation/weight beat per clock when both streams are valid and output reserve is available.

### VPU_Top

Command flow: `xvlog -> xelab -> xsim -runall`

Final log:

- `DATN_VIVADO/manual_sim/vpu_sim_final.log`

Result:

```text
TEST FINISHED! Passed: 4, Failed: 0
```

Coverage in this testbench:

- Four matrix rows.
- 64 columns per row.
- 16 INT8 lanes, 4 beats per row.
- Q1.15 fixed-point scale path via `axis_weight_in_scale`.

Important testbench fixes made during verification:

- `axis_weight_in_scale` is now connected to `VPU_Top`.
- Golden model uses explicit INT32 sign extension before multiplication.
- Stimulus waits for AXI4-Stream handshake safely. The old stimulus could hold beat 0 for two accept cycles because it checked `tready` immediately after changing `tvalid/tdata`.

## Pipeline Assessment

Current PMAU pipeline:

```text
input beat
  -> INT8xINT8 multiply register
  -> registered adder tree level 1
  -> registered adder tree level 2
  -> registered adder tree level 3
  -> registered adder tree level 4
  -> accumulator commit
  -> dequant stage 1 register
  -> dequant stage 2 register
  -> result FIFO
```

For `NUM_LANES=16`, this gives a steady-state throughput of 1 accepted beat/clock. The extra dequant stages reduce the critical path from final adder/accumulator/dequant/FIFO to shorter registered segments.

## Timing and Utilization

Out-of-project implementation was run with:

```tcl
create_clock -period 3.333 -name vpu_clk [get_ports CLK]
opt_design
place_design
route_design
```

Reports:

- `DATN_VIVADO/manual_sim/vpu_impl_timing_300mhz.rpt`
- `DATN_VIVADO/manual_sim/vpu_impl_utilization.rpt`

Post-route timing at 300 MHz:

```text
Setup WNS: +0.342 ns
Setup failing endpoints: 0
Hold WHS: +0.004 ns
Hold failing endpoints: 0
Pulse width slack: +1.391 ns
```

Post-route utilization:

```text
CLB LUTs:       1555 / 230400  (0.67%)
CLB Registers:  1096 / 460800  (0.24%)
CARRY8:          188 / 28800   (0.65%)
DSP48E2:           2 / 1728    (0.12%)
BRAM:              0
URAM:              0
```

Conclusion: for the current `NUM_LANES=16` INT8 design, the pipeline is effective enough for 300 MHz after route on ZCU104 in this isolated VPU implementation.

## Current Limitations

- `compute_mode` and `scalar_axpy` are still reserved/unused. DOT mode is verified; AXPY is not implemented.
- Dequant is fixed-point Q1.15. `16'h3c00` is treated as a raw-output bypass for legacy raw-dot tests, not as a true FP16 multiply.
- This is not yet the paper's exact FP16 VPU with 128 FP16 multipliers. Current INT8 multipliers are mostly inferred into LUT/CARRY logic; only the dequant multiply used DSP48E2s in this build.
- The route report is for isolated `VPU_Top`, not the full SoC with DMA/PS/SPU integration and real XDC pin/clock constraints.
- Output backpressure should still get a dedicated integration test where `axis_out_tready` is randomly deasserted for several cycles. The RTL has a result FIFO for this, but the main VPU test currently keeps output ready high.

## Recommendation

Next RTL step: decide whether Gemma3-1B INT8 should keep this INT8 VPU path or move closer to the paper's FP16 dequant-before-DOT path. If matching Figure 5 more closely, the next major change is replacing the fixed-point dequant placeholder with Xilinx FP16 conversion/multiply IP and scaling `NUM_LANES` toward the real stream width/resource budget.
