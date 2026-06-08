# DSP Multiplier Integration Report

Date: 2026-06-08

## Change Summary

The PMAU multiply stage now instantiates one Vivado `mult_gen_0` multiplier IP per lane directly inside `PMAU_Full`.

Files changed/added:

- `RTL/PMAU_Full.v`
- `DATN_VIVADO/src/PMAU_Full.v`
- `DATN_VIVADO/manual_sim/mult_gen_0_stub.v`
- `DATN_VIVADO/manual_sim/tb_matmul_dsp_core.v`

The generated IP config in `DATN_VIVADO/project_1/project_1.srcs/sources_1/ip/mult_gen_0/mult_gen_0.xci` is:

- `PortAType = Signed`
- `PortBType = Signed`
- `PortAWidth = 8`
- `PortBWidth = 8`
- `PipeStages = 2`
- `Multiplier_Construction = Use_Mults`
- target device family: Zynq UltraScale+ / ZCU104

Because `PipeStages=2`, `PMAU_Full` now delays `valid`, `last`, and `scale` through a multiplier-latency pipeline before entering the adder tree.

## Simulation Result

Manual simulation output:

`DATN_VIVADO/manual_sim/dsp_matmul_sim_results.csv`

Result:

| Case | Rows | Cols | Status | Mismatches |
| ---: | ---: | ---: | --- | ---: |
| 1 | 4 | 4 | pass | 0 |
| 2 | 3 | 17 | pass | 0 |
| 3 | 4 | 64 | pass | 0 |

The older full verification set in `MatMul_Verification` was also rerun after this RTL change:

- 7 valid cases: pass, 0 mismatches
- invalid config case `rows=129`: pass, expected error

## Baseline Utilization From Existing Vivado Reports

From `DATN_VIVADO/manual_sim/axi_full_synth_utilization.rpt`:

| Resource | Used |
| --- | ---: |
| LUT | 2293 |
| FF | 1886 |
| BRAM Tile | 133 |
| DSP | 2 |
| IO | 0 |

This matches the low-DSP issue: the pre-change design only used 2 DSP48E2.

## Expected DSP Effect

`NUM_LANES=16`, and the new multiply stage instantiates 16 direct `mult_gen_0` IP instances.

Expected post-synthesis result: DSP usage should increase above the old value of 2, normally to at least 16 DSP48-class multiplier instances if Vivado preserves one DSP per `mult_gen_0`.

The exact LUT/FF/DSP/IO values must come from Vivado synthesis because the current shell environment does not expose `vivado`, `xvlog`, `xelab`, or `xsim`.

## Vivado Synthesis Command

Run from `DATN_VIVADO/manual_sim`:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_dsp_vivado_synth.ps1 -VivadoBin C:\Xilinx\Vivado\2022.2\bin
```

or if Vivado is already on PATH:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_dsp_vivado_synth.ps1
```

Expected generated reports:

- `dsp_vpu_synth_utilization.rpt`
- `dsp_vpu_synth_dsp_utilization.rpt`
- `dsp_vpu_synth_timing.rpt`
- `dsp_vpu_synth.dcp`

## Current Blocker

Vivado CLI is not available in this execution environment. The functional simulation was run with ModelSim ASE and a cycle-accurate `mult_gen_0` stub with two pipeline stages. Vivado synthesis/report generation is scripted but was not executed here.
