# Revert DMA/v17 to MMIO/Hybrid - 2026-06-16

## Scope

- Removed active v17 DMA host path and restored the runtime to safe MMIO/hybrid policy.
- Reverted `RTL/VPU_Top.v`, `RTL/MY_IP.v`, and `RTL/AXI4_Mapping.v` to the pre-DMA top-level interface.
- Removed v17 DMA artifacts from `manual_sim`, including integration checklist/report/scripts and DMA simulation logs.
- Kept the existing packed Q8 GEMV MMIO datapath, register map, ACT/WEIGHT/RESULT windows, and large-matrix MMIO telemetry.

## Source Checks

- RTL source scan: no `s_axis_dma`, `m_axis_dma`, `REG_DMA`, AXI DMA, or DMA stream interface remains in the active RTL path.
- Host source scan: no `FPGA_DMA_BASE`, AXI DMA programming, reserved DDR DMA mmap, DMA metadata cache, or DMA self-test remains in `fpga_host.cpp`.
- If `FPGA_PATH=dma` is set by mistake, the host logs that DMA is disabled in this reverted MMIO/hybrid build and continues with safe hybrid/MMIO policy.
- Canonical host and board host are synchronized:
  - `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`
  - `DATN_RTL/EMBEDDED_LLAMA/fpga_host.cpp`

## Verification

- Host C++11 syntax check: PASS.
  - Log: `revert_mmio_host_syntax.log`
- Packed Q8 core regression: PASS.
  - Result: `[PACKED_Q8] results=[32,64,-32,192] expected=[32,64,-32,192]`
  - Result: `[SHARD_BOUNDARY] PASS`
  - Log: `revert_mmio_current_256_packed_xsim.log`
- AXI4-Full/MMIO VPU top regression: PASS.
  - Result: `[TB] pass_count=149 fail_count=0`
  - Result: `[TB] AXI4-Full VPU TEST PASSED`
  - Log: `revert_mmio_vpu_top_xsim.log`

## Runtime Notes

- Default runtime remains safe hybrid/MMIO.
- `FPGA_PATH=mmio` is accepted as an explicit MMIO/hybrid selection.
- `FPGA_PATH=dma`, `FPGA_DMA_BASE`, AXI DMA, `S_AXI_HP0_FPD`, and reserved DDR `0x70000000-0x7fffffff` are not required by this reverted build.
- Large FFN offload through MMIO is still controlled by the existing guard/policy variables. It is not automatically enabled by this revert.
