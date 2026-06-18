# ZDMA DDR-to-IP Memory-Mapped Flow Simulation

This simulation matches the current GEMMA3-1B Q8_0 host path:

1. Host packs ACT/WEIGHT into DRAM.
2. Zynq/FPD ZDMA copies DRAM data into the MY_IP/VPU AXI memory-mapped windows:
   - `ACT_BASE    = 0x00010000`
   - `WEIGHT_BASE = 0x00100000`
3. Host writes small control registers and starts the VPU.
4. VPU writes RESULT window.
5. ZDMA copies `RESULT_BASE = 0x00200000` back to DRAM.

The behavioral testbench does not model the ZDMA controller. It models the effect of the ZDMA copies by issuing AXI4-Full writes into ACT/WEIGHT windows and AXI4-Full reads from RESULT.

## Files

- Testbench: `D:/DOAN/DATN_RTL/TESTBENCH/tb_VPU_Top.v`
- Runner: `D:/DOAN/DATN_RTL/DATN_VIVADO/manual_sim/run_vpu_top_xsim.ps1`
- Tcl: `D:/DOAN/DATN_RTL/DATN_VIVADO/manual_sim/run_vpu_top_xsim.tcl`
- Log: `D:/DOAN/DATN_RTL/DATN_VIVADO/manual_sim/vpu_top_xsim.log`

## Run

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
powershell -ExecutionPolicy Bypass -File .\run_vpu_top_xsim.ps1
```

## Expected Pass Criteria

The log must contain:

```text
[TB] pass_count=149 fail_count=0
[TB] AXI4-Full VPU TEST PASSED
```

The covered cases include:

- basic GEMV window write/start/result read;
- non-multiple-of-16 columns;
- multi-row behavior;
- packed Q8 multi-group-block behavior;
- large row tiling behavior through repeated AXI window transactions.

The AXI-Stream DMA testbench and README are legacy artifacts from the previous optional stream experiment and are not the main path for this ZDMA DDR-to-IP flow.
