# SPU Pipeline Guide from "Pushing up to the Limit..."

## What Can Be Pipelined

The paper's SPU contains RoPE, RMSNorm, Softmax, SiLU, Quantization, Serial2Parallel, and FIFO packing for scale/zero metadata.  These functions can be pipelined, but not all at the same granularity.

## Best Pipeline Candidates

### RoPE

RoPE is the cleanest stream pipeline.  A practical hardware or CPU-vector pipeline is:

```text
input q/k pair -> invFreq address -> sin/cos ROM read -> FP/fixed mul -> add/sub rotator -> output
```

Use one pipeline lane per pair.  Cache the first half-vector as the paper describes, then rotate pairs when the matching second half arrives.

### SiLU

SiLU is also pipeline-friendly because each element is independent:

```text
x -> clamp/range reduce -> exp(-x) LUT or PWL -> 1+exp -> reciprocal -> x*reciprocal -> multiply upProj
```

If SPU stays on CPU, vectorize this loop and fuse `SiLU(gateProjOut) * upProjOut` so gate/up data is read once.

### Quantization

Quantization has two passes:

```text
pass 1: stream x -> min/max reduction -> scale and zero
pass 2: stream x -> affine quant -> saturate -> pack -> Serial2Parallel -> AXI/DMA
```

Pass 1 is a reduction pipeline.  Pass 2 is a pure per-element pipeline.  The paper's `szFIFO` idea should be kept: pack scale/zero entries until they fill the bus width before writing them back.

## Pipeline With Multi-Pass Dependency

### RMSNorm

RMSNorm has two sequential passes:

```text
pass 1: sum(x*x) -> mean -> rsqrt
pass 2: x * rsqrt(mean) * normWeight
```

The paper notes pass 1 can be bypassed if the DOT engine already computes the square sum.  For this project, the useful pipeline is to have VPU produce or assist `sum(x*x)`, then CPU/SPU applies pass 2 as a vectorized streaming multiply.

### Softmax

The paper uses a numerically stable three-pass softmax:

```text
pass 1: max(x)
pass 2: sum(exp(x - max))
pass 3: exp(x - max) / sum
```

Each pass can be internally pipelined, but pass 2 depends on pass 1 and pass 3 depends on pass 2.  For CPU execution, keep the three-pass form for correctness and vectorize the exp/div loops.  For hardware later, use an exp LUT/PWL block and store intermediate `exp(x-max)` only if the memory tradeoff is acceptable.

## Recommended CPU/SPU Task Pipeline

Because you plan to keep SPU behavior on the Zynq CPU, pipeline at the task level with ping-pong buffers:

```text
buffer A: VPU writes DOT result for head/layer n
buffer B: CPU runs RoPE/Softmax/RMSNorm/SiLU/Quant for head/layer n-1
```

Use DMA completion interrupts or polling flags to swap buffers.  This hides CPU scalar work behind the next VPU DOT stream, matching the paper's goal of hiding miscellaneous operations under dense computation.

## Practical Priority

1. Pipeline/verify RoPE first because it is deterministic and pair-local.
2. Add RMSNorm pass 2 after deciding whether VPU will output square sums.
3. Keep Softmax on CPU until the VPU stream is stable.
4. Implement Quantization packing last, because its correctness depends on the final KV-cache memory layout.
