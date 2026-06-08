# Vivado RTL Verification Report

Date: 2026-06-08

## Scope

Verified the current `RTL/` matrix-vector datapath with Vivado 2022.2 XSim and synthesis after integrating the existing Vivado IP `mult_gen_0` inside `PMAU_Full`.

## Root Cause Found

The failing XSim log was caused by a mixed Verilog/VHDL timing issue at the `mult_gen_0` input boundary.

`Matrix_Vector_Multiplication` can load the next activation/weight beat into `act_pmau_data` and `weight_pmau_data` on the same clock edge where `PMAU_Full` consumes the current beat. The Verilog view showed the current beat, but the VHDL `mult_gen_0` simulation could sample the newly loaded next beat. This made the first beat of a row get replaced by the second beat in cases such as 17 columns.

## RTL Change

Changed `PMAU_Full` so every `mult_gen_0` lane is driven from PMAU-owned input registers:

- `mult_act_reg[lane]`
- `mult_weight_reg[lane]`

These registers capture `activation_data` and `weight_data` only on `input_fire`. The multiplier IP then samples stable registered data on the following clock while the existing valid/last/scale latency pipeline remains aligned to `MULT_IP_LATENCY = 2`.

Synced copies:

- `RTL/PMAU_Full.v`
- `DATN_VIVADO/src/PMAU_Full.v`
- `DATN_VIVADO/project_1/project_1.ip_user_files/bd/SoC/ipshared/6810/src/PMAU_Full.v`
- `DATN_VIVADO/project_1/project_1.gen/sources_1/bd/SoC/ipshared/6810/src/PMAU_Full.v`

## XSim Results

All simulations below used the real Vivado `mult_gen_0` VHDL model, not the local ModelSim stub.

| Level | Log | Cases | Result |
|---|---|---:|---|
| `PMAU_Full` direct | `pmau_direct_xsim.log` | 3 cases / 11 row checks | PASS |
| `Matrix_Vector_Multiplication` core | `matrix_core_fixed_xsim.log` | 3 cases | PASS |
| `VPU_Top` AXI4-Full | `vpu_top_fixed_xsim.log` | 2 cases / 5 row checks | PASS |

Key AXI top results:

- Case 1: `rows=3`, `cols=64`, `cfg_col_beats=4` -> results `-613`, `1039`, `115`
- Case 2: `rows=2`, `cols=17`, `cfg_col_beats=0` auto-derived -> results `145`, `328`
- Final: `pass_count=5 fail_count=0`, `AXI4-Full VPU TEST PASSED`

## Debug Evidence

The failing pre-fix trace is in `matrix_trace_xsim.log`. It shows PMAU receiving two correct beats, but `mult_gen_0` outputting the second beat product for both captures:

- row 0 beat 0 expected sum: `1042`
- row 0 beat 1 expected sum: `-759`
- pre-fix captured sums: `-759`, `-759`
- pre-fix row result: `-1518`

After registering the multiplier inputs, `matrix_core_fixed_xsim.log` passes the same 17-column case.

## Synthesis / Utilization

Vivado synth completed successfully for top `VPU_Top` on `xczu7ev-ffvc1156-2-e`.

Reports:

- `dsp_vivado_synth.log`
- `dsp_vpu_synth_utilization.rpt`
- `dsp_vpu_synth_hier_utilization.rpt`
- `dsp_vpu_synth_dsp_utilization.rpt`
- `dsp_vpu_synth_timing.rpt`
- `dsp_vpu_synth.dcp`

Main utilization:

| Resource | Used |
|---|---:|
| LUT as Logic | 3251 |
| FF | 6286 |
| DSP48E2 | 18 |
| Block RAM Tile | 145.5 |
| Bonded IOB | 402 |

DSP note:

- `dsp_vpu_synth_dsp_utilization.rpt` reports `DSP48E2 instance count: 18`.
- 16 instances come from `GEN_MULT[0..15].u_mult_gen_0`.
- 2 additional DSPs are inferred for `dequant_mul`.
- This is higher than the original 2-DSP observation.

IO note:

- Standalone synth of `VPU_Top` exposes the full AXI bus as top-level pins, so `Bonded IOB = 402` exceeds the ZCU104 device pin count. In the block design flow those AXI signals are internal to the PS/PL integration, so this standalone IO count should not be interpreted as the final board-level IO usage.

Timing note:

- `dsp_vpu_synth_timing.rpt` says all user-specified timing constraints are met, but WNS/TNS are `NA` because this standalone synth script does not add an explicit clock XDC.

## Manual Sim Workspace

Vivado runs were placed under:

- `DATN_VIVADO/manual_sim/xsim_scratch`

The generated `project_1.sim` work library previously showed stale/locked behavior when manually recompiling individual files, so the final verification used a clean scratch XSim work directory.
