# ZCU104 Decode-Performance Audit and Optimization Plan — 2026-08-16

## Evidence boundary

- Owner-run evidence: `DATN_RTL/result_prompt.txt`, SHA-256 `2241BFBF6282446B47ED9D857E22725102D5438790A12134804BAC550D3513B6`; `DATN_RTL/fpga_debug.log`, SHA-256 `D6CD5183F8A0C92F5B9CC7E4F06EDB0E06FF6E67C786E62B7CC490DC41F30E29`.
- Repository identities during audit: parent `57737d34103862f697c65eaa93ff76bce6d04169`; host `2111ace5be3a2b4e87b3dc1d329d80a9a686bb26`; RTL `24c52f0bf5d1a29a9fa2ecc66c5e9acf7397d1c0`.
- Owner binary reports llama build `198 (b9d4df9)` and host manifest `zcu104-gemma3-q8-v88-p2-pack-threshold1`, built `Aug 15 2026 15:55:11`. The source/board binary relationship is corroborated by the manifest and telemetry fields but is not cryptographically sealed because the binary, GGUF, and bitstream file hashes were not logged.
- Evidence level is owner-provided ZCU104 execution plus local source inspection. No synthesis, implementation, bit generation, simulation, or board operation was performed in this audit.
- All stage timers below are measured aggregates and are not additive where preparation overlaps FPGA execution.

## A. Current System Context

1. GGML enters `ggml_compute_forward_mul_mat()` in `llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c:1259`; worker 0 calls `fpga_try_matmul_extended()` and publishes the route to the other workers (`ggml-cpu.c:1280-1306`).
2. `fpga_try_matmul_extended()` validates/routs eligible Q8_0×F32 GEMV and calls the monolithic host data path (`fpga_host.cpp:11783+`); intentional attention/vocabulary CPU routes remain separate.
3. `fpga_hw_q8_0_matmul_dma_to_ip()` quantizes/reuses activation scratch data, probes weight cache/residency, and selects the P2 PL-scale ping-pong path (`fpga_host.cpp:10239-10331`).
4. Each tile is prepared by `fpga_prepare_q8_tile_job()` (`fpga_host.cpp:8134`): bounds and addresses are checked, static Q8 weights are either selected from sealed residency or repacked directly into mapped DDR, activation/weight scale data are prepared, and job metadata are constructed.
5. `fpga_submit_q8_tile_job()` (`fpga_host.cpp:8876`) serially commits descriptors/configuration, transfers ACT, WEIGHT and SPU scale payloads through ZDMA, selects banks, and starts the VPU.
6. `fpga_wait_and_drain_q8_tile_job()` (`fpga_host.cpp:9121`) polls VPU completion, waits for SPU final visibility, DMA-copies SPU output to host DDR, and advances descriptor ownership; `fpga_accumulate_pl_scaled_q8_tile_job()` reads Q16.16 rows, accumulates FP32, and frees the slot (`fpga_host.cpp:9277+`).
7. The measured production configuration is P2 scale, two pack workers, ping-pong enabled, preload requested, P3 disabled, and a fixed non-evicting 32 MiB residency set (`fpga_debug.log:6`).
8. The terminal reports 0.37 token/s over three decode evaluations; decode token-wall samples are 2644.054, 2639.093, and 2782.406 ms, with a median of 2644.054 ms (`result_prompt.txt:176-178`; `fpga_debug.log:15,20,25`).
9. Median decode preparation is 1612.958 ms, dominated by 1277.503 ms of direct static-weight packing; host-observed IP compute is 471.071 ms, H2IP DMA 341.752 ms, IP2H DMA 34.536 ms, and host result read 199.256 ms.
10. All 910 expected Q8 hooks completed in hardware with zero unavailable fallback, reject, mismatch, restage, stream-drop, or stream-error counters (`fpga_debug.log:31,35`).

## B. Bottleneck Evidence

| Rank | Bottleneck | Evidence | Measured cost per decode token | Why it happens |
| ---- | ---------- | -------- | ------------------------------ | -------------- |
| 1 | Repacking immutable Q8 weights into pair-major mapped DDR | `prep_direct_weight_pack_ms=1277.503` median; 697,761,792 weight bytes/token; cleanup reports 11,684,118,528 direct-pack bytes at 626.391 MiB/s (`fpga_debug.log:15-16,20-21,25-26,34-35`) | 1.261–1.298 s; median 1.278 s, 48.3% of median token wall | On every residency miss, `fpga_prepare_q8_tile_job()` calls `fpga_pack_direct_weight_pair_range()` and writes the static tensor again to volatile DDR (`fpga_host.cpp:8320-8452`). Only 32 MiB of roughly 665.5 MiB transferred weights can remain resident. |
| 2 | Scale-table preparation | `prep_scale_pack_ms=317.218–317.898`; 87,220,224 scale bytes/token (`fpga_debug.log:15-16,20-21,25-26`) | Median 317.835 ms | P2 packs activation and weight FP16 scales into the shared SPU parameter layout for each job. Activation scale changes each token, so the existing combined P2 table cannot be wholly static. |
| 3 | Host-observed FPGA/SPU execution | `ip_compute_ms=470.873–477.742`; down projection contributes about 329 ms, gate/up about 60 ms each, attention projections about 22 ms (`fpga_debug.log:17,22,27`) | Median 471.071 ms | 2,210 small VPU runs are launched per token. This timer includes host observation/wait around hardware completion and is not an internal-PL-only counter. |
| 4 | Fragmented ZDMA input movement and descriptor control | 18,070 descriptors and 796,596,736 bytes/token: 2,210 ACT, 11,440 WEIGHT, 2,210 SCALE, 2,210 RESULT; ZDMA descriptor elapsed 231.117–231.535 ms; H2IP 341.481–341.821 ms (`fpga_debug.log:18,23,28`) | Median H2IP 341.752 ms; weight 274.265 ms, scale 43.637 ms, activation 23.861 ms | `fpga_dma_copy()` chunks transfers at 65,536 bytes and programs/waits each descriptor (`fpga_host.cpp:4433+`). Static residency changes the source address but does not eliminate WEIGHT DDR→IP DMA. |
| 5 | Host result consumption and launch gaps | Host result read 199.122–199.274 ms; IP2H 34.453–34.708 ms; output-ready→next-launch about 113 ms; retire→next-launch about 70.5 ms (`fpga_debug.log:15-16,20-21,25-26`) | Median result read 199.256 ms plus IP2H 34.536 ms | Every tile waits for final SPU output, copies it back, reads Q16.16 rows from mapped DDR, updates FP32 accumulation, frees the descriptor, and only then commits the deferred next launch (`fpga_host.cpp:9121-9340,9959-10070`). |

The costs in this table overlap; they must not be summed into a predicted token wall time.

### Hot-path issue map

| File → function | Actual behavior | Measured consequence |
| --------------- | --------------- | -------------------- |
| `ggml-cpu.c` → `ggml_compute_forward_mul_mat()` | One FPGA route decision by worker 0; barriers make every worker consume the same destination-ownership result. | Necessary correctness synchronization; no isolated timer proves it is material. |
| `fpga_host.cpp` → `ensure_quantized_activation_matrix()` (`4769`) | Converts/reuses the changing F32 activation as Q8_0 in persistent scratch storage. | `prep_act_pack_ms` median 6.486 ms; low priority. |
| `fpga_host.cpp` → `fpga_p2_residency_select_or_build()` (`8103`) | Looks up a sealed immutable tile or constructs a non-evicting resident tile while the device is quiescent. | 1,802 hits versus 36,910 misses; 565,051,392 CPU-pack bytes avoided for the complete run, but zero DDR→IP bytes avoided (`fpga_debug.log:34`). |
| `fpga_host.cpp` → `fpga_prepare_q8_tile_job()` (`8134`) | On a residency miss, pair-interleaves and writes the same static weight bytes into `WEIGHT_BASE` for the current job. | Primary 1.278 s/token direct-pack cost. Address/range checking and weight selection are only about 2.8 ms/token and are not the problem. |
| `fpga_host.cpp` → two-worker `fpga_pack_direct_weight_pair_range()` (`5281`, called around `8397`) | Main and helper divide row pairs for payloads at least 256 KiB; the caller waits for helper completion before DMA. | 34,221 parallel jobs, 11.23 GB parallel bytes, 1.178 s aggregate caller-wait for the complete run (`fpga_debug.log:32`). The mechanism is active, but no single-worker A/B is present, so its exact saved time is unproven. |
| `fpga_host.cpp` → `fpga_preload_q8_tile_inputs()` (`8708`) | After preparing N+1, it admits ACT/WEIGHT DMA only if N is still exactly BUSY; otherwise terminal N is drained and N+1 submits serially. | 390/390 decode attempts were terminal skips, zero were admitted, and `input_preload_us=0`; preload provides no transfer overlap in this run (`fpga_debug.log:19,24,30`). |
| `fpga_host.cpp` → `fpga_hw_q8_0_matmul_dma_to_ip_pipelined()` (`9959`) | Prepares N+1 while N runs, then waits/drains/accumulates N and submits N+1. | About 320 ms preparation overlap is measured, but preparation is about 1.6 s and finishes after short FPGA jobs; compute utilization is only 17.6–18.7%. |
| `fpga_host.cpp` → `fpga_dma_copy()` (`4433`) | Constructs, commits, starts, polls, clears, and verifies every bounded ZDMA chunk. | 18,070 descriptors/token and about 231.5 ms descriptor elapsed; material but smaller than weight packing. |
| `fpga_host.cpp` → `fpga_accumulate_pl_scaled_q8_tile_job()` (`9277+`) | Reads SPU Q16.16 output and adds it to FP32 accumulation. | `host_accum_ms` is about 5.5 ms; FPGA-side scale/partial accumulation is effective and not a current target. |

### Existing optimization verdicts

- **Preload: ineffective in this run.** It is enabled, but all 390 decode opportunities see the previous job already terminal because N+1 preparation precedes the admission check and is longer than N's execution. No ACT or WEIGHT preload overlaps compute.
- **Weight residency: correct but capacity-limited.** The 32 MiB set fills 106 slots and leaves 16 KiB. Its byte hit fraction is `565,051,392 / (11,684,118,528 + 565,051,392) = 4.61%`; it reduces packing for that fraction but intentionally does not avoid weight DMA.
- **Ping-pong: partially useful.** Alternating banks and preparation overlap are active, but the design has one running job and the shared descriptor/SPU state is committed only after retirement. It overlaps about 320 ms of preparation, not DMA or VPU execution.
- **Two pack workers: active, benefit not numerically closed.** Main/helper service times are similar and caller wait is lower, consistent with overlap, but an otherwise identical one-worker run is required for a measured speedup.
- **DMA batching: not present beyond 64 KiB chunking.** The implementation performs bounded sequential descriptors; 11,440 weight descriptors/token dominate the descriptor count. Larger chunks or linked descriptors need a separate safety/throughput experiment after the primary bottleneck.
- **CRC optimization: not a bottleneck.** `cache_crc_ms=0.000`; residency metadata validation is 0.529 ms for the entire run.
- **Descriptor reuse: not implemented.** Per-descriptor construction is measurable, but the whole ZDMA descriptor cost is still far below direct pack cost.
- **FPGA-side accumulation: effective.** Only approximately 5.5 ms/token remains in host FP32 accumulation; do not move more accumulation work before eliminating static repack.
- **Repeated allocation/copy claim: not supported.** Scratch vectors and two job slots are reused. Residency construction allocates temporary vectors only while filling the fixed set. No allocation timer proves allocator cost on the decode critical path.

## C. Root Cause

The primary limitation is host preprocessing of immutable model data, not demonstrated FPGA arithmetic throughput. The hardware protocol consumes a pair-major packed weight tile from a fixed local `WEIGHT_BASE` window for each of 2,210 runs, while the model stores Q8_0 weights in GGML layout. For every tile not covered by the small sealed residency set, the ARM cores reread, rearrange, and volatile-write the same static bytes during every decode token. Because preparing the next tile takes longer than the currently running hardware job, the running job has already reached DONE before the preload gate is evaluated; consequently ping-pong cannot overlap its ACT/WEIGHT transfers. The system therefore behaves as a host-produced stream of many small hardware jobs, with FPGA execution repeatedly waiting for static-data preparation and serialized descriptor retirement.

## D. Recommended Optimization

Choose one direction: **expand the existing sealed packed-weight residency mechanism within the already approved `[0x70000000,0x80000000)` low-DDR carveout, using graduated capacity gates.** Do not introduce a second cache, alter Q8/P2 layout, or redesign RTL. Generalize `P2_WEIGHT_RESIDENCY_END`, `P2_WEIGHT_RESIDENCY_MAX_MB`, slot-directory capacity, hash-index capacity, and mapping admission in `fpga_host.cpp`; retain the existing immutable tensor/tile identity, epoch, protocol/bitstream/P2-ABI seal, alignment, quiescence, no-eviction, fail-closed metadata checks, UIO-only mapping, and physical-range checks. Populate resident tiles once during warm-up/prefill and reuse their `qs_off`/scale metadata during decode, so the covered static bytes bypass `fpga_pack_direct_weight_pair_range()` on every later token. Keep WEIGHT DDR→IP DMA unchanged in the first implementation: the measured 274 ms weight DMA is secondary, and eliminating CPU repack is the smallest change addressing the 1.278 s primary cost. Do not attempt to repair preload first; it cannot become effective while N+1 weight preparation remains longer than N compute.

The current source hard-limits residency to 32 MiB in `[0x01000000,0x03000000)` and 128 slots (`fpga_host.cpp:345-364`), although the host physical contract covers 256 MiB. Expansion is prohibited until the deployed UIO resource and Linux ownership prove the requested range is fully reserved and non-System-RAM. The ZCU104 board has 2 GiB PS DDR according to AMD UG1267, but this project must obey its narrower approved 256 MiB carveout rather than infer that other DDR is safe. AMD UG1087 confirms that the controller at `0xFD500000` is ZDMA/GDMA0; it does not by itself authorize larger mappings or transfers.

## E. Implementation Plan

### Phase 1 — Prove and parameterize safe residency capacity

- **Files/functions:** `llama.cpp/ggml/src/ggml-cpu/fpga_host.cpp`; constants around `WEIGHT_CACHE_BASE/P2_WEIGHT_RESIDENCY_END`; `configure_ddr_mapping_policy()`; residency directory/index initialization; `fpga_p2_residency_select_or_build_impl()`.
- **Exact change:** first capture deployed `/sys/class/uio/uio15/maps/map0/{name,addr,size}` and `/proc/iomem`; require `name=fpga_ddr_low`, base `0x70000000`, and a resource covering the requested half-open range without overlap with `System RAM`. Replace the fixed 32 MiB maximum with an explicit operator-selected graduated maximum no larger than 240 MiB (`0x01000000` through `0x10000000`). Increase sealed-slot and bounded hash-index capacities proportionally; reject insufficient UIO size, arithmetic overflow, directory exhaustion, or physical overlap before mmap/write/DMA/start. Preserve the 32 MiB default so existing commands do not silently map more memory.
- **Reason:** this removes repeated static packing using the already qualified mechanism and does not change FPGA-visible bytes, register protocol, DMA destination, numerical accumulation, or job scheduling.
- **Completion criterion:** host self-tests cover 32/64/128/240 MiB range arithmetic and directory/index bounds; 32 MiB behavior is unchanged; owner preflight proves the requested map; a 64 MiB owner run reports zero rejects/build failures/mismatches and `p2_residency_allocated_bytes <= budget_bytes`.

### Phase 2 — Graduate residency and measure steady-state decode

- **Files/functions:** same host residency path only; no RTL change.
- **Exact change:** run 64 MiB, then 128 MiB, then at most 240 MiB. Stop at the first functional, mapping, thermal, or performance regression. Keep selection fixed/non-evicting and reuse sealed offsets; do not add per-hit DDR readback or CRC. Record resident bytes, avoided pack bytes, hit/miss reasons, build time, direct-pack time, token wall, and unchanged WEIGHT DMA bytes.
- **Reason:** each additional resident MiB should eliminate approximately one MiB of decode-time volatile pair-major packing while preserving current transport and correctness.
- **Completion criterion:** three independent `-n 64` runs at the selected capacity; after excluding the first decode token, median `prep_direct_weight_pack_ms` and token wall are lower than the 32 MiB baseline, `q8_expected_fpga == q8_hw_completed`, and all reject/mismatch/restage/stream-error counters remain zero.

Do not begin descriptor batching, P3 scale separation, preload restructuring, or RTL work until Phase 2 establishes the residual critical path.

## F. Validation

### Required preflight evidence

```bash
for f in name addr size; do
  printf '%s=' "$f"
  cat "/sys/class/uio/uio15/maps/map0/$f"
done
grep -iE '70000000|7fffffff|System RAM|reserved' /proc/iomem
sha256sum build_mem/bin/llama-cli models/gemma-3-1b-it-Q8_0.gguf
git rev-parse HEAD
```

If the actual DDR UIO number is not 15, identify it by `name=fpga_ddr_low` and use that number. Evidence must show the full proposed range; absence from `/proc/iomem` is not proof of safety.

### Baseline and candidate benchmark

Run the current 32 MiB baseline and each accepted candidate three independent times with the same binary/model/bitstream/board state except `FPGA_P2_WEIGHT_RESIDENCY_MB`:

```bash
sudo rm -f /tmp/fpga_debug.log
sudo env \
  FPGA_PL_SCALE_ENABLE=1 \
  FPGA_P3_SPLIT_SCALE=0 \
  FPGA_P2_INPUT_PRELOAD=1 \
  FPGA_P2_WEIGHT_RESIDENCY=1 \
  FPGA_P2_WEIGHT_RESIDENCY_DIAGNOSTIC=1 \
  FPGA_P2_WEIGHT_RESIDENCY_MB=32 \
  FPGA_P2_PACK_PARALLEL_MIN_KB=256 \
  FPGA_P1_SCHED_SUMMARY=1 \
  FPGA_TOKEN_TIMING=1 \
  FPGA_BOTTLENECK_SUMMARY=1 \
  FPGA_SUMMARY_DETAIL_EVERY=1 \
  FPGA_DETAIL_EVERY=0 \
  FPGA_PROFILE_EVERY=0 \
  ./build_mem/bin/llama-cli \
  -m ./models/gemma-3-1b-it-Q8_0.gguf \
  -p "Please write about AI" \
  -n 64 --single-turn --temp 0
```

Change only the residency size for a candidate. Archive terminal output and `/tmp/fpga_debug.log` together with UTC start/end, binary/GGUF/bitstream hashes, governor, temperature, and PL clock. Compare median post-first-decode values for token wall, preparation, direct weight pack, scale pack, IP compute, H2IP, IP2H/result-read, matmuls, VPU jobs, descriptor count/bytes, residency hits/avoided bytes, and tokens/s.

### Evidence still required for conclusions not made here

- **Exact synchronization/wait split:** current `ip_compute_sum_ms` is host-observed and `device_noncompute_ms` is derived; they do not isolate VPU busy cycles, SPU-finality polling, or descriptor-retirement wait. If residency leaves hardware wait dominant, instrument `wait_vpu_done()`, `wait_spu_stream_outputs()`, `zdma_wait_channel_disabled()`, and the final FREE/FREE readback with monotonic start/stop around only their polling loops. Emit one token aggregate:

```text
[FPGA][WAIT_BREAKDOWN] graph_seq=<n> vpu_wait_ms=<x> spu_finality_wait_ms=<x> zdma_idle_wait_ms=<x> descriptor_retire_wait_ms=<x> polls=<n>
```

- **Two-worker benefit:** run the same three-run benchmark once with the production two-worker setting and once with the existing one-worker opt-out; do not estimate its gain from cumulative service timers.
- **Larger ZDMA descriptor benefit:** requires an isolated owner A/B with the same bytes and explicit ZDMA completion/error evidence. The present audit does not assume that a larger descriptor is supported or faster.

## G. Expected Outcome

- **Measured current value:** median 2644.054 ms/decode token (approximately 0.378 token/s from FPGA token timing; terminal aggregate reports 0.37 token/s), with median 1277.503 ms direct packing at 32 MiB residency.
- **Evidence-supported removable cost:** the current cleanup rate is 626.391 MiB/s and residency already demonstrates byte-for-byte avoided CPU packing. Expanding from 32 to 128 MiB adds at most 96 MiB resident coverage, corresponding to approximately 153 ms/token of direct-pack work at the measured aggregate rate. Expanding to the carveout ceiling of 240 MiB adds at most 208 MiB, corresponding to approximately 332 ms/token. These are proportional estimates, not measured candidate results; one-time residency construction and overlap prevent treating them as exact wall-time savings.
- **Conservative resulting range:** if the 128 MiB candidate realizes most of the proportional saving without adding critical-path cost, expect approximately 2.45–2.55 s/token, or 0.39–0.41 token/s. A safe 240 MiB candidate could approach approximately 2.3–2.4 s/token, or 0.42–0.44 token/s. Do not claim either range until the required three-run board benchmark passes.
- **Target limitation:** even perfect use of the currently approved 240 MiB residency capacity cannot support a 2.5 token/s claim. It addresses the measured primary bottleneck; subsequent optimization must be selected from the new residual telemetry.

## External primary references

- AMD, Zynq UltraScale+ Devices Register Reference UG1087, ZDMA module: https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers/ZDMA-Module
- AMD, ZCU104 Evaluation Board User Guide UG1267: https://docs.amd.com/v/u/en-US/ug1267-zcu104-eval-bd
