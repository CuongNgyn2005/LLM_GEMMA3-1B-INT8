# DMA AXI-Stream Behavioral Simulation

## Files

- `tb_vpu_dma_axis.v`: self-checking behavioral testbench for the DMA frame protocol.
- `run_vpu_dma_axis_xsim.ps1`: Windows PowerShell runner using `D:\Xlinx\Vivado\2022.2\bin`.
- `run_vpu_dma_axis_xsim.tcl`: Vivado Tcl batch runner.
- `dma_axis_xvlog.log`, `dma_axis_xelab.log`, `dma_axis_xsim.log`: generated compile/elab/sim logs.

## Protocol Under Test

Input MM2S stream uses 128-bit words:

- Header word:
  - `[31:0]`: magic `0x33414d44`
  - `[39:32]`: frame type
  - `[47:40]`: mode
  - `[63:48]`: rows
  - `[79:64]`: col beats
  - `[95:80]`: tile id
  - `[127:96]`: payload words
- Frame types:
  - `1`: CONFIG
  - `2`: ACT
  - `3`: WEIGHT
  - `4`: START
  - `5`: RESULT

Output S2MM stream returns one RESULT header followed by packed 128-bit INT32 result words. `m_axis_dma_tlast` must assert on the final RESULT payload word.

## Coverage

- DMA basic CONFIG/ACT/WEIGHT/START/RESULT path.
- Packed Q8 self-test with expected result `[32, 64, -32, 192]`.
- Multi-row packed mode.
- Multi-group-block packed mode.
- Input `tvalid` gaps and output `tready` backpressure.
- Large matrix tiling behavior using multiple DMA tile runs and partial accumulation.

## Run

From PowerShell:

```powershell
cd D:\DOAN\DATN_RTL\DATN_VIVADO\manual_sim
.\run_vpu_dma_axis_xsim.ps1
```

Expected final line:

```text
[TB][PASS] tb_vpu_dma_axis completed successfully
```

Pass criteria: `fail=0` in `dma_axis_xsim.log`.
