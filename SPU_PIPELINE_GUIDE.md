# SPU Pipeline Guide for the INT8 Quantized Flow

## 1. Paper Cross-Check Summary

The paper "Pushing up to the Limit of Memory Bandwidth and Capacity Utilization for Efficient LLM Decoding on Embedded FPGA" places the Scalar Processing Unit (SPU) beside the VPU so miscellaneous LLM operations can run concurrently with dense DOT computation. The SPU modules shown in Figure 5C and described in Section VI-C are:

- RoPE
- RMSNorm
- Softmax
- SiLU
- Quantization
- Serial2Parallel
- scale/zero FIFO packing

Section V-A also shows the intended dataflow: RoPE, Softmax, residual add, square-sum generation, and KV quantization are scheduled so that they are hidden behind attention-layer DOT operations instead of adding extra cycle penalties.

The paper uses W4A16/FP16 compute. This project is now targeting an INT8 quantized VPU, so the SPU plan should be adapted as:

```text
VPU:     INT8 x INT8 -> INT32 dot result
SPU/CPU: fixed-point dequant, RoPE, RMSNorm, Softmax, SiLU, requantization
Memory:  AXI4-Full burst movement, INT8 KV cache, packed scale/zero metadata
```

For the current ZCU104 design, the SPU is expected to run mainly on the CPU/PS. Pipeline decisions therefore have two levels:

- function-level pipeline: vectorized loops, staged reductions, LUT/PWL approximations;
- task-level pipeline: overlap CPU-side SPU work for tile/head/layer `n-1` while the VPU computes tile/head/layer `n`.

## 2. Pipeline Suitability Table

| SPU module | Pipeline suitability | Good pipeline form | Main limitation |
|---|---|---|---|
| RoPE | Excellent | Pair-local fixed-point multiply/add with sin/cos ROM or CPU lookup table | Needs pair buffering and sin/cos address generation |
| SiLU / gated MLP | Excellent | Element-wise LUT/PWL sigmoid plus multiply with up-projection | Exp/sigmoid approximation cost if moved to PL |
| Serial2Parallel | Excellent | Pack serial INT8/fixed values into 128-bit AXI words | Needs final-beat WSTRB or zero-padding logic |
| Scale-zero FIFO | Excellent | Accumulate small metadata fields until one full bus beat is ready | Needs metadata format discipline across layers/heads |
| Residual add + square sum | Excellent | Stream add residual and accumulate `x*x` in the same pass | Accumulator width must be chosen carefully |
| Quantization | Good, but two-pass | Pass 1 min/max or absmax reduction, pass 2 affine quantize/saturate/pack | Scale/zero are not known until pass 1 completes |
| RMSNorm | Medium | Pass 1 sum-of-squares reduction, pass 2 normalize/scale/requantize | Requires vector buffering or rereading; rsqrt is expensive |
| Softmax | Medium to poor as a full PL pipeline | Three staged passes: max, exp/sum, normalize | Exp/divide cost, numerical stability, and full-vector buffering |

## 3. Best Pipeline Candidates

### RoPE

The paper describes RoPE as a rotator, sin/cos generator, and address generator. This is one of the cleanest SPU pipeline candidates because each element pair is independent after its sine/cosine values are known.

Recommended INT8/fixed-point pipeline:

```text
q/k INT32 or fixed input
  -> optional dequant to Q format
  -> pair buffer
  -> token-position/inv-frequency address
  -> sin/cos ROM or CPU lookup
  -> fixed-point multiply: even*cos, odd*sin
  -> add/sub rotator
  -> optional requant for KV cache
```

Why it is good:

- pair-local computation;
- predictable memory access;
- sin/cos values can be cached by token position;
- hardware implementation can use ROM plus fixed-point multipliers and add/sub units.

Main cost:

- the rotator must buffer one half or one paired element until the matching pair is available;
- a large context may require either a larger sin/cos table, interpolation, or CPU-generated cached values.

### SiLU / Gated MLP

The paper lists SiLU as a pipeline in the SPU: the gate projection output is passed through `x / (1 + exp(-x))`, then multiplied by the up-projection output before the down projection.

Recommended CPU/SPU pipeline:

```text
gate_int32/fixed
  -> clamp/range reduce
  -> sigmoid LUT/PWL approximation
  -> silu = gate * sigmoid(gate)
  -> multiply with up_projection
  -> requant/fixed output for down projection
```

Why it is good:

- fully element-wise;
- no cross-element reduction dependency;
- easy to vectorize on CPU;
- `SiLU(gate[i]) * up[i]` should be fused to read gate/up once and write output once.

Main cost:

- if moved to PL, exp/sigmoid approximation needs LUT/PWL resources;
- accuracy must be checked carefully after fixed-point approximation.

### Serial2Parallel

The paper uses Serial2Parallel to pack serial hidden-state outputs into bus-width words. This is very suitable for pipeline because it is mostly a counter plus a shift/pack register.

For the current 128-bit AXI4-Full path:

```text
serial INT8/fixed output
  -> lane counter 0..15
  -> 128-bit pack register
  -> final-beat WSTRB or zero-padding
  -> AXI4-Full burst write
```

Why it is good:

- very low arithmetic cost;
- improves burst efficiency;
- directly supports INT8 KV cache and packed intermediate tensors.

Main cost:

- final partial beats must be handled correctly;
- software and hardware must agree on packing order.

### Scale-Zero FIFO

The paper emphasizes packing scales and zero points to avoid inefficient small DDR transactions. This is highly relevant for longer context because KV cache metadata grows with token count.

Recommended packing for the current 128-bit bus:

```text
scale[15:0] + zero_point[7:0] + pad[7:0] = 32-bit metadata pack
4 metadata packs -> 128-bit AXI beat
```

Why it is good:

- converts small metadata writes into aligned burst writes;
- reduces bandwidth waste;
- keeps scale/zero metadata close to its INT8 tensor group.

Main cost:

- requires strict metadata layout discipline;
- readback/dequant must use the exact same grouping rule.

### Residual Add + Square Sum

The paper notes that as output projection results are generated, residual addition and the square sum for the next normalization can be computed at the same time. This is a strong pipeline candidate.

Recommended INT8/fixed-point pipeline:

```text
output_projection_result + residual
  -> normalized hidden candidate
  -> square
  -> accumulate sum_sq
  -> forward hidden value
```

Why it is good:

- one streaming pass;
- combines two operations that would otherwise require separate memory reads;
- helps RMSNorm by producing sum-of-squares early.

Main cost:

- accumulator width must be large enough;
- scale alignment between residual and projection output must be defined.

## 4. Modules That Are Pipeline-Friendly Only With Caveats

### Quantization

Quantization is useful and should be implemented, especially for KV8 storage, but the full operation is not a pure one-pass stream because scale and zero point depend on a prior reduction.

Two-pass flow:

```text
pass 1:
  x -> min/max or absmax reduction -> scale, zero_point

pass 2:
  x -> affine quantize -> round -> saturate INT8 -> pack
```

Pipeline suitability:

- Pass 1 is a reduction pipeline.
- Pass 2 is an excellent element-wise pipeline.

Why it is not perfect:

- pass 2 cannot start correctly until pass 1 produces scale/zero;
- the input vector must be buffered or reread;
- per-token/per-head/per-group scale metadata increases control complexity.

Recommendation:

- prioritize KV8 quantization because it directly supports longer context;
- keep group size and metadata layout simple first;
- fuse pass 2 with Serial2Parallel and scale-zero FIFO packing.

### RMSNorm

The paper states that RMSNorm requires two sequential passes. The first pass computes the RMS value, and the second pass normalizes elements using that RMS.

Recommended flow:

```text
pass 1:
  x_fixed -> widen -> x*x -> sum_sq accumulator

rsqrt:
  mean_sq = sum_sq / hidden_size
  inv_rms = approx_rsqrt(mean_sq + eps)

pass 2:
  x -> x * inv_rms -> * norm_weight -> requant/fixed output
```

Pipeline suitability:

- Pass 1 can be pipelined as a reduction.
- Pass 2 can be pipelined as element-wise multiply/scale.

Why it is not ideal:

- pass 2 depends on the final result of pass 1;
- the vector must be buffered or reread;
- `rsqrt` is resource-heavy in PL if implemented accurately;
- fixed-point overflow risk is higher than in simple element-wise functions.

Recommendation:

- keep RMSNorm on CPU first;
- vectorize both passes;
- fuse pass 2 with requantization if possible;
- consider moving only residual add + square sum to PL before moving full RMSNorm.

### Softmax

Softmax is the weakest full-function PL pipeline candidate among the paper's SPU modules. The paper uses a numerically stable three-pass softmax.

Stable flow:

```text
pass 1: score -> max_score reduction
pass 2: score -> exp(score - max_score) -> sum_exp reduction
pass 3: exp_value -> reciprocal(sum_exp) multiply -> probability
```

Pipeline suitability:

- each pass can be internally pipelined;
- the full function has unavoidable inter-pass dependencies.

Why it is difficult:

- pass 2 depends on the max from pass 1;
- pass 3 depends on the sum from pass 2;
- exp approximation consumes LUT/BRAM/DSP resources;
- reciprocal/division is also expensive;
- attention scores must be buffered or recomputed between passes;
- accuracy errors can directly change token selection quality.

Recommendation:

- keep Softmax on CPU for the current design phase;
- use fixed-point LUT/PWL exp only after the VPU, RoPE, and quantization paths are stable;
- if moved to PL later, implement it as a multi-pass tiled engine with explicit score buffering.

## 5. Task-Level Pipeline When SPU Runs on CPU

Because the SPU is planned to run on the Zynq CPU/PS, the most important pipeline is the overlap between CPU-side SPU work and VPU GEMV compute.

Recommended task pipeline:

```text
time slot n:
  VPU computes INT8 GEMV for head/layer/tile n
  CPU runs SPU functions for head/layer/tile n-1

time slot n+1:
  buffers swap
```

Minimum buffer set:

- `buf_dot_result_A/B`: INT32 output from the VPU;
- `buf_spu_work_A/B`: fixed-point/INT8 tensor workspace for RoPE, RMSNorm, Softmax, SiLU, and quantization;
- `buf_kv_pack_A/B`: INT8 KV cache and packed scale-zero metadata.

Synchronization:

- CPU writes activation and weight tiles to the VPU through AXI4-Full.
- CPU starts the VPU and polls or handles `STATUS.done`.
- While the VPU is busy, CPU processes the previous SPU buffer.
- After VPU completion, CPU reads result data and swaps buffers.
- Cache flush/invalidate is required if buffers are stored in DDR shared with PL.

## 6. Recommended Implementation Priority

1. **Quantization + Serial2Parallel + scale-zero packing for KV8**  
   Highest priority for longer context because it reduces KV-cache memory pressure and improves burst efficiency.

2. **RoPE fixed-point pipeline**  
   Strong candidate because it is pair-local and easy to verify against a CPU golden model.

3. **Residual add + square sum**  
   Good streaming operation that helps prepare RMSNorm and avoids an extra memory pass.

4. **RMSNorm pass 2 fused with requantization**  
   Useful after sum-of-squares and fixed-point scale rules are stable.

5. **SiLU / gated MLP fused CPU loop**  
   Very pipeline-friendly, but move to PL only if CPU profiling shows it is a bottleneck.

6. **Softmax**  
   Keep on CPU first. Move to PL only after a stable fixed-point approximation and buffering strategy are defined.

## 7. INT8 Accuracy Checklist

- Define a consistent scale format: activation scale, weight scale, result scale, and KV scale.
- Use INT32 for dot-product accumulation.
- Use INT64 for large CPU-side reductions if `sum_sq` or fixed-point `sum_exp` can overflow.
- Zero-pad unused lanes in the final beat when `COLS % 16 != 0`.
- Saturate during INT8 requantization; never wrap around.
- Store scale/zero metadata per group/head/layer/token with a layout that is easy to read back.
- Compare each SPU function against a Python/C golden model before fusing multiple functions into one pipeline.
