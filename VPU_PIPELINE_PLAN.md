# VPU Pipeline Plan for Gemma3-1B INT8 on ZCU104

## 1. Ket luan sau khi double-check bai bao

Bai bao "Pushing up to the Limit of Memory Bandwidth and Capacity Utilization for Efficient LLM Decoding on Embedded FPGA" dat VPU trong Figure 5B nhu mot DOT engine bandwidth-area balanced: multiplier song song, adder tree, scaling multiplier, accumulator. Bai bao dung W4A16 va FP16 compute sau dequantization, nhung huong hien tai cua project la INT8 quantized.

Vi vay plan RTL cua project nay giu lai y tuong pipeline DOT engine cua bai bao, nhung doi numeric contract thanh:

```text
activation INT8 + weight INT8 -> parallel INT8 x INT8 -> INT32 reduction
                                -> INT32 row accumulator -> optional fixed-point scale
                                -> result BRAM INT32
```

Khong dung FP16 multiplier trong VPU. Neu can scale/dequant, scale nen la fixed-point hoac duoc xu ly o CPU/SPU, khong dua FP16 vao datapath VPU.

## 2. Interface dung cho kien truc hien tai

Top-level VPU hien tai khong con AXI-Stream. Bus ngoai la AXI4-Full memory-mapped:

```text
PS/AXI master
  -> AXI4_Mapping.v: physical address translation, S_AXI_* board-facing ports
  -> VPU_Top.v: thin AXI4-Full wrapper
  -> MY_IP.v: AXI4-Full slave, register map, burst write/read
  -> Matrix_Vector_Multiplication.v: BRAM-backed INT8 GEMV engine
  -> PMAU_Streaming.v: internal valid/ready MAC pipeline
```

Ten `PMAU_Streaming` chi con la ten module noi bo. Cac tin hieu valid/ready trong PMAU la handshake noi bo giua GEMV FSM va MAC pipeline, khong phai AXI-Stream top-level.

Address map can giu thong nhat:

| Local offset | Purpose |
|---:|---|
| `0x0000_0000` | CTRL: start / clear done |
| `0x0000_0010` | STATUS: done, busy, error |
| `0x0000_0020` | ROWS |
| `0x0000_0030` | COLS |
| `0x0000_0040` | COL_BEATS, ghi 0 de hardware tu suy ra tu COLS |
| `0x0000_0050` | SCALE, fixed-point/control placeholder |
| `0x0001_0000` | Activation BRAM window |
| `0x0010_0000` | Weight BRAM window |
| `0x0020_0000` | Result BRAM window |

`AXI4_Mapping.v` dat physical base mac dinh `40'h00A0_0000_00` va tru base de dua vao local offset. Neu Vivado interconnect da strip base address, wrapper se pass-through local address.

## 3. Pipeline VPU da dung trong RTL

Pipeline dung hien tai gom cac stage sau:

```text
AXI4-Full burst write
  -> registered AXI decode/write request
  -> activation/weight BRAM
  -> GEMV FSM issue read
  -> BRAM read output register
  -> PMAU input register
  -> NUM_LANES parallel INT8 multipliers
  -> registered binary adder tree
  -> row accumulator
  -> fixed-point scale/bypass stage
  -> result FIFO
  -> result BRAM
  -> AXI4-Full result read
```

Chi tiet quan trong:

- `MY_IP.v` dang register hoa write request truoc khi dua vao BRAM, giup cat timing tu AXI channel sang BRAM enable/address/data.
- `Matrix_Vector_Multiplication.v` co them register stage sau BRAM read truoc PMAU, giup cat duong BRAM cascade -> multiplier/add tree.
- `PMAU_Streaming.v` thuc hien `NUM_LANES` phep nhan signed `INT8 x INT8` song song.
- Adder tree duoc register moi level, nen critical path chi la mot multiplier hoac mot adder level.
- Result FIFO giu ket qua den khi GEMV core nhan va ghi vao result BRAM.
- Activation/weight readback qua AXI da tat de giu timing. CPU ghi activation/weight va chi doc status/result.

Voi `NUM_LANES=16`, moi 128-bit beat chua 16 phan tu INT8. Throughput muc tieu sau warm-up la mot beat MAC moi clock neu khong bi stall boi FIFO/result path.

## 4. Runtime shape va context capacity

Thong so mac dinh hien tai:

| Parameter | Value | Meaning |
|---|---:|---|
| `NUM_LANES` | 16 | 16 INT8 lanes per 128-bit beat |
| `MAX_ROWS` | 128 | so output rows toi da moi run |
| `MAX_COL_BEATS` | 256 | so beat toi da moi row |
| `AXI_DATA_WIDTH` | 128 | AXI4-Full data width |

Dung luong noi bo:

- Activation BRAM: `MAX_COL_BEATS * 16 bytes = 4096 bytes`
- Weight BRAM: `MAX_ROWS * MAX_COL_BEATS * 16 bytes = 524288 bytes`
- Result BRAM: `MAX_ROWS * 4 bytes = 512 bytes`
- So cot INT8 toi da moi row: `MAX_COL_BEATS * NUM_LANES = 4096`

Neu input size khong biet truoc, software chi can ghi `ROWS`, `COLS`, va co the ghi `COL_BEATS=0`. Hardware se suy ra:

```text
effective_col_beats = ceil(COLS / NUM_LANES)
```

Neu `COLS` khong chia het cho 16, beat cuoi phai zero-pad cac lane du. Day la cach giu pipeline don gian va khong them mask logic vao critical path.

## 5. Huong mo rong de luu duoc tensor/weight nhieu hon

Muc tieu context dai hon phu thuoc vao dung luong KV cache, activation trung gian, va cach tile weight. Trong VPU hien tai, BRAM chu yeu duoc dung cho activation/weight tile gan compute. Nen mo rong theo thu tu sau:

1. Tang `MAX_COL_BEATS` neu muon vector dai hon trong mot dot product. Chi phi BRAM weight tang tuyen tinh theo `MAX_ROWS * MAX_COL_BEATS`.
2. Tang `MAX_ROWS` neu muon tinh nhieu output rows hon moi run. Chi phi BRAM weight cung tang tuyen tinh.
3. Neu BRAM khong du, giu `MAX_ROWS/MAX_COL_BEATS` vua phai va tile theo row/column tu DDR qua AXI4-Full burst. Day phu hop hon voi context dai vi DDR moi la noi chua weight/KV cache lon.
4. Dung ping-pong buffer activation/weight tile neu sau nay can overlap CPU/AXI load voi VPU compute. Ban hien tai chua lam double buffer de giu RTL gon va timing tot.
5. Neu can luu KV cache dai hon, uu tien INT8 KV cache + scale/zero packing nhu bai bao, khong dua toan bo KV vao BRAM. BRAM chi nen lam staging/cache gan compute.

## 6. Timing target va double-check pipeline

Ket qua route OOC truoc do dat 300 MHz tren part ZCU104 voi WNS duong. De giu ket qua nay khi mo rong:

- Khong ghep lai AXI decode truc tiep vao BRAM write enable/address.
- Khong doc nguoc activation/weight qua AXI neu khong bat buoc.
- Giu BRAM output register truoc PMAU.
- Giu adder tree dang registered binary tree.
- Khong tang `NUM_LANES` len 32/64 neu chua chay lai timing, vi multiplier fanout va adder tree se lon hon.
- Neu tang BRAM capacity, uu tien tang depth hon tang width de tranh widening data path.
- Neu can 512-bit bandwidth nhu bai bao, nen lam o MCU/interconnect/tile loader roi nap thanh cac burst 128-bit vao VPU, thay vi doi ngay VPU core thanh 512-bit.

Approx latency cho mot row:

```text
row_latency ~= col_beats
             + BRAM/FSM feed latency
             + (1 multiply stage + log2(NUM_LANES) adder stages)
             + accumulator/scale/result FIFO latency
```

Voi `NUM_LANES=16`, adder tree co 4 level. Latency tang theo `log2(NUM_LANES)`, nhung throughput van co the giu mot beat moi clock sau warm-up.

## 7. Viec can lam tiep

1. Chay lai sim/timing moi khi doi `MAX_ROWS`, `MAX_COL_BEATS`, hoac `NUM_LANES`.
2. Tao testbench burst dai hon de stress `COL_BEATS=0`, zero-padding, va nhieu rows hon.
3. Bo sentinel `16'h3c00` khoi y nghia FP16 trong tai lieu/code sau khi chot fixed-point scale format. Trong ban hien tai no chi la bypass marker de giu raw INT32 accumulator tests.
4. Neu CPU/SPU se xu ly dequant/activation tiep theo, giu VPU output la INT32 va truyen kem scale/zero metadata o software layer.
