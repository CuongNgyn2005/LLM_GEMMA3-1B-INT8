# ZCU104 INT8 VPU Review - 2026-06-12

## Verified RTL

- Source under test: `D:/DOAN/DATN_RTL/RTL`
- Packed q8_0 XSim: PASS, result `[32,64,-32,192]`
- Legacy XSim: PASS for `4x4`, `3x17`, and `4x64`
- Post-route clock: 300 MHz
- WNS: `+0.238 ns`
- TNS: `0 ns`
- Failing setup/hold endpoints: `0 / 0`
- Utilization: `1665 LUT`, `40 BRAM36`, `18 DSP`

The timing fix reduces `MAX_COL_BEATS` to 32, which is exactly 16 packed q8_0 blocks. This removes the 256-BRAM deep weight buffer and its cascade critical path. Larger K dimensions are handled by host tiling.

## Reproduce

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\run_packed_q8_xsim.ps1
powershell.exe -ExecutionPolicy Bypass -File .\run_current_rtl_impl.ps1
```

Reports:

- `current_rtl_impl_timing_300mhz.rpt`
- `current_rtl_impl_utilization.rpt`
- `current_rtl_impl_hier_utilization.rpt`
- `current_rtl_impl_route.dcp`

## Board Register Contract

- `REG_LIMITS` (`0xA0000070`): expected `0x00200100`
- `REG_CAPS` (`0xA0000090`): expected `0x04001001`
- Packed self-test result: `[32,64,-32,192]`

## Integration Blocker

The actual Vivado project contains stale copies under `DATN_VIVADO/project_1/src`. They do not include the packed capability/flow used by the verified `RTL` tree. Those project files and IP packaging were not modified because they are outside `manual_sim` and require explicit permission.

Do not treat a host-only deployment as the new flow. A board reporting `REG_CAPS=0` is still using the legacy bitstream.
