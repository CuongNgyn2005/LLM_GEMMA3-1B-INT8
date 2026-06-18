# ZCU104 Board Review - 2026-06-14

## Observed board signature

- `REG_LIMITS=0x01000100`: 256 rows, 256 col-beats.
- `REG_CAPS=0x04001001`: packed q8 mode advertised.
- Basic result: 16, expected 32.
- Packed result: `[16,48,-16,80]`, expected `[32,64,-32,192]`.
- Runtime falls back to legacy q8-block mode and reaches only about 0.38-0.39 tokens/s.

## Local reproduction result

The packaged block-design RTL, multiplier `C_LATENCY=3`, and
`MAX_COL_BEATS=256` were simulated together with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\run_packaged_256_packed_xsim.ps1
```

Result: `[32,64,-32,192]`, PASS.

This means the current source tree does not reproduce the loaded board result.
Regenerate the custom-IP output products and rebuild/reload the bitstream before
making another PMAU latency adjustment.

## Hardware performance finding

The actual block design clocks the VPU at 100 MHz and overrides
`MAX_COL_BEATS` to 256. Synthesis reports 264 BRAM36. The standalone 32-beat
implementation uses 40 BRAM36 and meets the 300 MHz test constraint.

CPU-driven MMIO weight loading is the hard throughput limit. Full transformer
offload would transfer roughly 700 MB of INT8 weights per generated token. A PL
AXI master or DMA reader connected to a PS S_AXI_HP/HPC DDR port is required for
the 2.5 tokens/s target.
