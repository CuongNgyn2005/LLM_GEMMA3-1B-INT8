# SPU Pipeline Guide for INT8 Quantized Flow

## 1. Ket luan sau khi double-check bai bao

Trong Figure 5C va Section VI-C, bai bao chia SPU thanh cac submodule miscellaneous chay song song voi VPU de khong tao cycle penalty: RoPE, RMSNorm, Softmax, SiLU, Quantization, Serial2Parallel, va FIFO dong goi scale/zero. Section V-A cung mo ta cach cac tac vu nay duoc an duoi dense computation cua attention layer.

Bai bao goc dung W4A16/FP16 compute, nhung project hien tai chot INT8 quantized. Vi vay guide nay doi cach hien thuc sang fixed-point/INT8:

```text
VPU: INT8 x INT8 -> INT32 dot result
SPU/CPU: fixed-point dequant, RoPE/RMSNorm/Softmax/activation, requant INT8/KV8
Memory: AXI4-Full burst, scale/zero metadata duoc pack theo bus width
```

SPU hien tai du kien day len CPU tren ZCU104. "Pipeline" vi vay co hai muc:

- pipeline trong tung ham bang loop/vectorization/fixed-point stages;
- pipeline task-level bang ping-pong buffer de CPU lam SPU cho tile/head/layer truoc trong khi VPU tinh tile/head/layer tiep theo.

## 2. Function co the pipeline trong SPU

| Function | Pipeline duoc khong | Dang pipeline phu hop voi INT8 |
|---|---|---|
| RoPE | Rat tot | pair-local, LUT sin/cos, fixed-point multiply/add |
| RMSNorm | Duoc, nhung co reduction dependency | pass 1 sum of squares, pass 2 normalize + scale |
| Softmax | Duoc tung pass, khong phai single-pass don gian | max reduction, exp/sum, normalize |
| SiLU | Rat tot | element-wise LUT/PWL sigmoid, multiply voi up projection |
| Quantization | Rat tot sau pass scale/zero | min/max reduction, affine quant, saturate, pack |
| Serial2Parallel | Rat tot | pack INT8/metadata thanh 128-bit AXI words |
| Scale-zero FIFO | Rat tot | accumulate metadata den khi du bus width roi burst write |
| Residual add + square sum | Rat tot | add residual va accumulate x*x trong cung mot pass |

## 3. RoPE pipeline

Bai bao mo ta RoPE gom rotator, sin/cos generator, va address generator. Voi INT8/fixed-point, pipeline nen la:

```text
q/k INT32 or fixed input
  -> optional dequant to Q format
  -> pair buffer: even/odd or first-half/second-half
  -> inv_freq/token-position address
  -> sin/cos ROM lookup
  -> fixed-point mul: x_even*cos, x_odd*sin
  -> add/sub rotator
  -> optional requant for KV cache
```

Ly do nen uu tien:

- moi cap rotation doc lap, rat hop voi pipeline;
- sin/cos co the dung ROM/LUT, khong can CORDIC luc dau;
- neu chay tren CPU, co the vectorize theo pair va cache sin/cos theo token position;
- neu dua len PL sau nay, moi lane RoPE chi can LUT + fixed-point multipliers + add/sub.

Can luu y cho context dai: ROM 4096 diem quarter-cycle trong bai bao la mot diem tham chieu. Neu context lon hon, co the noi suy, dung LUT phase nho hon, hoac tinh sin/cos tren CPU va cache theo token.

## 4. RMSNorm pipeline

Bai bao noi RMSNorm co hai pass va pass tinh RMS co the bo qua neu mean square da duoc DOT engine tinh giup. Voi INT8 flow, nen viet nhu sau:

```text
pass 1:
  x_int or x_fixed -> widen -> x*x -> accumulator sum_sq

rsqrt:
  mean_sq = sum_sq / hidden_size
  inv_rms = approx_rsqrt(mean_sq + eps)

pass 2:
  x -> x * inv_rms -> * norm_weight -> requant/fixed output
```

Pipeline duoc o hai noi:

- pass 1 la reduction pipeline: moi cycle/iteration nap mot hoac nhieu phan tu, accumulate `sum_sq`;
- pass 2 la element-wise pipeline: multiply-normalize-scale-saturate.

Neu SPU chay tren CPU, loop pass 1 nen dung INT32/INT64 accumulator tuy hidden size va scale. Pass 2 nen fuse normalize + norm weight + quantization de giam so lan doc/ghi memory.

Neu sau nay dua mot phan sang VPU/PL, ung vien tot nhat la "residual add + square sum" vi bai bao cung tinh square sum dong thoi khi output projection sinh ra ket qua.

## 5. Softmax pipeline

Bai bao dung softmax on dinh so hoc voi ba pass. Voi INT8/fixed-point, khong nen ep thanh mot pass trong phien ban dau vi de sai so:

```text
pass 1: score -> max_score reduction
pass 2: score -> exp(score - max_score) LUT/PWL -> sum_exp reduction
pass 3: exp_value -> divide or reciprocal multiply -> probability
```

Pipeline duoc ben trong tung pass:

- pass 1: comparator tree/reduction;
- pass 2: subtract max, range clamp, exp LUT/PWL, accumulate sum;
- pass 3: reciprocal `1/sum_exp`, multiply, quantize/fixed output.

Khuyen nghi cho project hien tai:

- giu Softmax tren CPU truoc de de debug accuracy;
- dung fixed-point LUT/PWL cho exp neu can tang toc;
- chi dua Softmax len PL sau khi VPU + RoPE + quantization da on dinh;
- voi context dai, Softmax la ham nhay voi memory traffic, nen can buffer attention scores hoac tinh lai exp o pass 3. Lua chon phu thuoc BRAM con lai.

## 6. SiLU / gated MLP pipeline

Bai bao liet ke SiLU trong SPU: SiLU cua gate projection duoc nhan voi output cua up projection de tao input cho down projection.

Pipeline fixed-point:

```text
gate_int32/fixed
  -> clamp/range reduce
  -> sigmoid LUT/PWL
  -> silu = gate * sigmoid(gate)
  -> multiply with up_projection
  -> requant/fixed output for down projection
```

Day la ung vien pipeline rat tot vi moi phan tu doc lap. Tren CPU, nen fuse:

```text
for i:
  y[i] = SiLU(gate[i]) * up[i]
```

Fuse giup gate/up chi doc mot lan va output chi ghi mot lan. Neu model Gemma3 config dung activation khac SiLU, vi du GELU/GeGLU, van giu cung mau pipeline: LUT/PWL activation theo element -> multiply gating/up -> requant.

## 7. Quantization va scale-zero packing

Bai bao co hai diem rat quan trong cho context dai: KV8 quantization va FIFO pack scale-zero. Day la phan nen uu tien vi lien quan truc tiep den context length.

Quantization hai pass:

```text
pass 1:
  x -> min/max or absmax reduction -> scale, zero_point

pass 2:
  x -> affine quant -> round -> saturate INT8 -> pack
```

Scale-zero packing:

```text
scale[15:0] + zero_point[7:0] + pad[7:0] = 32-bit metadata pack
metadata packs -> FIFO -> 128-bit or bus-width aligned burst write
```

Voi AXI4-Full 128-bit hien tai, moi beat pack duoc:

- 16 gia tri INT8; hoac
- 4 metadata packs 32-bit.

Neu sau nay dung 512-bit loader nhu bai bao, moi beat pack duoc 64 INT8 hoac 16 metadata packs. Nhung voi ZCU104 project hien tai, giu 128-bit se don gian hon va da khop `NUM_LANES=16`.

## 8. Serial2Parallel pipeline

Serial2Parallel trong bai bao co vai tro gom output nho thanh bus-width word de tang hieu qua burst. Voi AXI4-Full hien tai:

```text
serial INT8/fixed output
  -> lane counter 0..15
  -> 128-bit pack register
  -> WSTRB mask for final partial beat
  -> AXI4-Full burst write
```

Dung cho:

- KV cache INT8;
- activation/tensor trung gian neu can ghi ra DDR;
- scale-zero metadata sau khi da pack 32-bit.

Beat cuoi neu khong du 16 byte thi can WSTRB dung va/hoac zero-pad. Trong VPU hien tai, activation/weight compute gia dinh beat cuoi da zero-pad truoc khi start.

## 9. Task-level pipeline khi SPU chay tren CPU

Vi ban du kien day SPU len CPU, pipeline quan trong nhat la overlap CPU va VPU:

```text
time slot n:
  VPU computes INT8 GEMV for head/layer/tile n
  CPU runs SPU functions for head/layer/tile n-1

time slot n+1:
  buffers swap
```

Can co it nhat hai buffer:

- `buf_dot_result_A/B`: INT32 output tu VPU;
- `buf_spu_work_A/B`: fixed-point/INT8 tensor cho RoPE/Softmax/RMSNorm/SiLU/Quant;
- `buf_kv_pack_A/B`: INT8 KV cache + scale-zero packs.

Dong bo:

- CPU ghi activation/weight tile vao VPU qua AXI4-Full;
- CPU start VPU va poll/interrupt `STATUS.done`;
- trong luc VPU busy, CPU xu ly SPU cua buffer truoc;
- khi done, CPU doc result va swap buffer;
- can cache flush/invalidate neu buffer nam trong DDR shared voi PL.

## 10. Thu tu uu tien implement

1. Quantization + Serial2Parallel + scale-zero packing cho KV8, vi day anh huong truc tiep den context dai.
2. RoPE fixed-point pipeline, vi pair-local va de verify bang golden CPU.
3. Residual add + square sum de ho tro RMSNorm pass 1 va giam pass rieng.
4. RMSNorm pass 2 fuse voi quantization/output format.
5. SiLU/gated MLP fuse loop tren CPU; dua len PL chi khi CPU thanh bottleneck.
6. Softmax giu CPU truoc, sau do moi toi uu bang LUT/PWL hoac PL pipeline.

## 11. Checklist accuracy cho INT8

- Xac dinh scale format thong nhat: activation scale, weight scale, result scale, KV scale.
- Dung INT32 accumulator cho dot product; dung INT64 cho reduction lon neu CPU tinh `sum_sq` hoac `sum_exp` fixed-point co nguy co overflow.
- Zero-pad lane du trong beat cuoi khi `COLS % 16 != 0`.
- Saturate khi requant INT8, khong wrap-around.
- Luu scale/zero theo tung group/head/layer/token ro rang de doc lai KV cache dung.
- So sanh tung ham SPU voi golden Python/C truoc, sau do moi fuse pipeline de tranh kho debug.
