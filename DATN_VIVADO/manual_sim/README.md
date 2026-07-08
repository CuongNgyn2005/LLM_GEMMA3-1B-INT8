# Phase 1A manual simulation

This folder contains a standalone simulation setup for the Phase 1A RTL changes.

What it checks:

- `REG_LIMITS` reports `MAX_ROWS = 256` and `MAX_COL_BEATS = 128`.
- `REG_CAPS[0]` reports packed q8 support.
- `REG_CAPS[1]` reports compact active-stride weight layout support.
- `REG_CAPS[15:8]` reports `MAX_GROUP_Q8_BLOCKS = 64`.
- Weight rows are written with compact runtime stride, `row * active_col_beats + beat`.
- Packed q8 mode is tested at a 64-block boundary.

Run from a Vivado-enabled PowerShell:

```powershell
.\run_phase1a_xsim.ps1
```

The script links the Vivado `xpm` library because the weight-memory branch uses `xpm_memory_tdpram` with UltraRAM selected. The local `mult_gen_0_behav.v` model replaces the Vivado multiplier IP for simulation and keeps the three-cycle latency expected by `PMAU_Full.v`.

If Vivado/xsim is not available on the current machine, run the lightweight layout model:

```powershell
python .\phase1a_layout_model.py
```

This model does not replace RTL simulation. It verifies the Phase 1A constants, capability packing, compact weight addressing, result depth, and expected group-tile reduction.
