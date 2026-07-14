# Tổng quan RTL và dataflow VPU–SPU

**Cập nhật:** 14-07-2026  
**Nguồn mô tả:** RTL canonical trong thư mục này. Các thay đổi phải được đồng bộ qua flow nguồn IP trước khi tạo bitstream mới; thư mục generated của `project_1` không được sửa trực tiếp.

## 1. Mục tiêu kiến trúc

IP là AXI4-Full peripheral tại `0xA0000000`. PS/host dùng ZDMA để chuyển block dữ liệu giữa vùng DDR staging và các local-memory window của IP. VPU thực hiện GEMV INT8; SPU cung cấp scratchpad và các phép scalar/vector quanh GEMV.

Dataflow production đã được log chứng minh là:

```text
GGML Q8_0 weight + F32 activation
  -> host quantize activation thành Q8_0
  -> ZDMA nạp payload INT8 ACT/WEIGHT
  -> VPU tạo raw INT32 theo row và Q8 block
  -> ZDMA đọc raw RESULT
  -> CPU nhân d_a*d_w, cộng block và ghi dst F32
```

Đường VPU raw→SPU hiện dùng FIFO và giao thức ready/valid lossless. VPU giữ toàn bộ token và metadata khi `ready=0`; FIFO đầy mới kéo `ready` xuống. Capability PL scale vẫn là opt-in và chỉ được host bật khi protocol/bitstream ID khớp.

## 2. Cây module

```text
VPU_Top
└── MY_IP
    └── AXI4_Mapping
        ├── Matrix_Vector_Multiplication
        │   ├── Dual_Port_BRAM / XPM-backed ACT memory
        │   ├── banked WEIGHT URAM/BRAM
        │   ├── PMAU_Full
        │   └── VPU_Result_Requantizer
        └── SPU_Top
            ├── SPU_Local_Memory
            ├── SPU_Controller
            │   ├── SPU_Quantize_Q8_0
            │   ├── SPU_Q8_Scale_Accum
            │   ├── SPU_RMSInv_Engine
            │   ├── SPU_RMSNorm
            │   ├── SPU_SiLU_Mul
            │   ├── SPU_RoPE
            │   └── SPU_Softmax
            └── SPU_Q8_Scale_Accum (instance dành cho VPU raw stream)
```

## 3. Chức năng từng file

| File | Vai trò |
|---|---|
| `VPU_Top.v` | Wrapper tham số của IP, đưa AXI clock/reset và bus vào `MY_IP`. |
| `MY_IP.v` | AXI4-Full slave front-end; capture address/data, tạo local map request/response. |
| `AXI4_Mapping.v` | Decode register và memory window; giữ config VPU/SPU; nối GEMV với SPU; xuất capability/status. |
| `Matrix_Vector_Multiplication.v` | FSM GEMV: validate config, đọc ACT/WEIGHT, feed PMAU, ghi RESULT, quản lý row/block/group/bank/job. |
| `PMAU_Full.v` | Multiply-accumulate INT8 theo lane, reduction, raw INT32 result; có dequant/requant helper path. |
| `VPU_Result_Requantizer.v` | Chuyển accumulator sang INT8 theo shift/saturation cho mode tùy chọn; không thay thế Q8_0 scale theo block. |
| `Dual_Port_BRAM.v` | Wrapper RAM hai port, hỗ trợ BRAM/URAM inference theo tham số. |
| `SPU_Top.v` | Ghép controller, local memory và consumer VPU raw stream; xuất SPU capability/counter. |
| `SPU_Local_Memory.v` | Các window `SPU_IN`, `SPU_OUT`, `SPU_PARAM`, `SPU_SCRATCH`. |
| `SPU_Controller.v` | FSM command SPU, điều phối đọc/ghi memory và các arithmetic engine. |
| `SPU_Quantize_Q8_0.v` | Quantize fixed-point input thành payload INT8; phải đi kèm scale metadata để tạo block Q8_0 hoàn chỉnh. |
| `SPU_Q8_Scale_Accum.v` | Nhận raw INT32 + FP16 `d_a`, `d_w`; tạo contribution fixed-point và accumulate theo row. |
| `SPU_RMSInv_Engine.v` | Tính inverse RMS nhiều chu kỳ, tránh sqrt/divider tổ hợp rất dài. |
| `SPU_RMSNorm.v` | RMSNorm fixed-point theo lane với gamma/inverse RMS. |
| `SPU_SiLU_Mul.v` | Xấp xỉ SiLU và nhân gate×up fixed-point. |
| `SPU_RoPE.v` | Rotate cặp even/odd bằng cos/sin fixed-point. |
| `SPU_Softmax.v` | Max, exp-score xấp xỉ và normalize nhiều pass. |
| `SOC_ARCHITECTURE_OVERVIEW.md` | Mô tả cấp hệ thống cũ; tài liệu này là mô tả chi tiết theo source hiện tại. |

## 4. Address map

### 4.1 Register

| Offset | Chức năng |
|---:|---|
| `0x0000` | VPU control: start/clear done |
| `0x0010` | VPU status: done/busy/error |
| `0x0020` | rows |
| `0x0030` | cols |
| `0x0040` | col beats |
| `0x0050` | scale/requant config |
| `0x0060` | mode |
| `0x0070` | limits |
| `0x0080` | progress |
| `0x0090` | VPU capabilities |
| `0x00A0–0x00E4` | SPU control/status/config |
| `0x00F0` | SPU capabilities |
| `0x00F4` | stream protocol version (`1`) |
| `0x00F8` | bitstream identity (`VPU1`) |
| `0x0100` | ACT/RESULT bank select |
| `0x0110–0x01B0` | job/slot/tensor/row/block/group/token descriptor |
| `0x01C0/0x01C4` | VPU raw stream accepted/done counter |
| `0x01D0/0x01D4/0x01D8` | stream drop/output/error counter |
| `0x01E8/0x01EC` | job ID/bank của entry stream cuối cùng |
| `0x01E0–0x01FC` | last raw/meta/accumulator debug |

### 4.2 Local memory windows

| Offset từ `0xA0000000` | Vùng | Dùng cho |
|---:|---|---|
| `0x00010000–0x0001FFFF` | ACT | INT8 activation beats |
| `0x00100000–0x001FFFFF` | WEIGHT | compact row-major weight tile |
| `0x00200000–0x0020FFFF` | RESULT | packed raw INT32 hoặc optional INT8 result |
| `0x00300000–0x0033FFFF` | SPU_IN | input vector SPU |
| `0x00340000–0x0037FFFF` | SPU_OUT | output vector/stream result |
| `0x00380000–0x003BFFFF` | SPU_PARAM | scales, gamma, trig, parameters |
| `0x003C0000–0x003FFFFF` | SPU_SCRATCH | intermediate/multi-pass state |

Base/size phải khớp device tree và UIO. Register address không được dùng thay cho DDR staging address.

## 5. VPU dataflow chi tiết

### 5.1 Config và validate

Host ghi rows, col beats, mode, bank và descriptor. `Matrix_Vector_Multiplication` latch config khi start, sau đó kiểm tra:

- `rows <= MAX_ROWS`;
- `col_beats <= MAX_COL_BEATS`;
- packed Q8 dùng 2 beat 128-bit cho một block 32 INT8;
- group block/result index nằm trong window;
- bank/job descriptor hợp lệ.

### 5.2 ACT/WEIGHT layout

Một beat AXI 128-bit chứa 16 INT8. Một block Q8_0 có 32 payload INT8 nên cần 2 beat.

ACT layout:

```text
ACT[block * 2 + beat]
```

WEIGHT layout compact:

```text
WEIGHT[row * active_col_beats + block * 2 + beat]
```

Scale FP16 không nằm trong hai payload beat. Production raw path để host giữ `d_a`, đọc `d_w` từ Q8_0 weight và scale trên CPU. Stream path mới nạp pair scale vào `SPU_PARAM`.

### 5.3 Read pipeline

FSM phát ACT/WEIGHT read request. Dữ liệu RAM đi qua valid pipeline D/Q/X để align latency activation, weight shard và flag last. Chỉ khi `feed_valid && activation_ready && weight_ready`, beat mới được PMAU nhận.

### 5.4 PMAU

PMAU thực hiện 16 phép INT8×INT8 mỗi beat và reduction. Hai beat tạo raw dot của một Q8 block:

```text
raw[row,block] = Σ(i=0..31) qa[i] * qw[row,i]
```

Raw cần INT32. Đây chưa phải F32/Q8_0 output cuối vì mỗi block có scale khác nhau.

### 5.5 Result path

Raw mode:

- pack bốn INT32 vào một RESULT word 128-bit;
- layout logical `row * group_blocks + block`;
- pulse metadata sang SPU stream;
- host có thể DMA RESULT về và scale/accumulate.

Optional INT8 mode:

- accumulator qua group;
- `VPU_Result_Requantizer` shift/saturate;
- pack INT8 result.

INT8 shift global không phải Q8_0 output đúng nếu thiếu `d_out` và per-block scale-aware accumulation.

## 6. SPU command dataflow

`SPU_Controller` nhận command qua register, đọc word từ local memory, start arithmetic engine, chờ done rồi ghi output. Những op nhiều pass dùng scratch/parameter memory.

### 6.1 Q8 scale-accumulate

Input logic:

```text
raw INT32
d_a FP16
d_w FP16
row_id, clear_accum, last_block
```

Arithmetic target:

```text
contribution = raw * fp16(d_a) * fp16(d_w)
acc[row] += contribution
```

Output stream hiện là Q16.16 64-bit kèm row ID trong `SPU_OUT`, không phải block Q8_0 hoàn chỉnh và không phải trực tiếp F32 GGML.

### 6.2 RMSNorm

Pass 1 tích lũy sum-square. `SPU_RMSInv_Engine` tính mean, sqrt/reciprocal nhiều chu kỳ. Pass 2 nhân input×gamma×inverse-RMS và ghi output.

### 6.3 SiLU-Mul

Đọc gate từ `SPU_IN`, up từ `SPU_PARAM`, xấp xỉ sigmoid tuyến tính có clamp, nhân và saturate Q8.8 sang `SPU_OUT`.

### 6.4 RoPE

Đọc vector pair và cos/sin Q1.15, thực hiện bốn multiply và add/sub, ghi pair rotated Q8.8.

### 6.5 Softmax

Ba bước: max, score xấp xỉ exp, normalize bằng divider tuần tự. Scratch giữ score giữa các pass.

Các engine có unit-level RTL không đồng nghĩa llama.cpp đã dùng chúng. Source host hiện chỉ offload hook matrix multiplication; integration graph cho RMSNorm/SiLU/RoPE/Softmax chưa được chứng minh end-to-end.

## 7. Tương tác VPU–SPU hiện tại

### 7.1 Đường intended

```text
PMAU raw result
  -> raw + row/block/group metadata
  -> SPU đọc scale tương ứng từ SPU_PARAM
  -> SPU_Q8_Scale_Accum
  -> accumulator theo row
  -> SPU_OUT khi last_block
```

Host v12 nạp scale table, start VPU, đợi VPU done, đợi `SPU_STREAM_OUT` tăng thêm `rows`, rồi DMA `SPU_OUT` về.

### 7.2 Giao thức đã sửa

`Matrix_Vector_Multiplication` xuất `spu_raw_valid` cùng toàn bộ data/metadata và chỉ tiến row/block sau handshake với `spu_raw_ready`. `SPU_Top` có FIFO raw depth 32; consumer lấy entry khi scale-accumulate sẵn sàng. Một entry có metadata scale không hợp lệ mới tăng `stream_drop`, còn backpressure bình thường không làm mất dữ liệu.

### 7.3 Giao thức mục tiêu

```text
VPU producer -- valid,data,metadata --> FIFO --> SPU consumer
VPU producer <-- ready ------------------------ SPU/FIFO
```

Quy tắc:

- valid giữ nguyên cho tới handshake;
- data/metadata stable khi stalled;
- FIFO full kéo ready xuống;
- VPU không tăng row/block khi chưa handshake;
- done chỉ sau row cuối commit SPU_OUT;
- job ID và bank theo entry;
- drop hợp lệ luôn bằng 0.

## 8. Ping-pong

ACT/WEIGHT/RESULT đã có bank select và descriptor, nhưng ping-pong hệ thống chưa hoàn chỉnh:

- SPU_PARAM/SPU_OUT chưa bank theo job;
- ZDMA là một channel và các copy còn tuần tự;
- result drain chưa độc lập input fill;
- scheduler hai bank chưa được host kích hoạt;
- capability PL scale không tự bật; cần cờ opt-in, protocol/bitstream ID đúng và full-scale validation.

State ownership bắt buộc:

```text
FREE -> FILLING -> READY -> COMPUTING -> RESULT_READY -> DRAINING -> FREE
```

Host chỉ ghi `FREE/FILLING`; PL chỉ đọc `READY/COMPUTING`; không bên nào overwrite bank còn owner khác.

## 9. Bottleneck RTL và timing

Implementation hiện đạt setup timing 187,5 MHz (`WNS +0,604 ns`), nhưng:

- hold margin chỉ +0,010 ns;
- 83 DSP pipeline warnings;
- raw mode tạo một result cho từng block và dừng/chuyển state nhiều lần;
- 16 lane làm effective compute thấp khi cộng toàn bộ DMA/control overhead;
- Q8 scale path không streaming một entry/cycle;
- output projection cần 1024 run/token ở host v9.

Sau khi sửa correctness, pipeline DSP input/MREG/PREG tại PMAU dequant, stream scale index, Q8 scale accumulator, RMSNorm và RoPE. Metadata valid/job/row/block phải được delay đúng số stage.

## 10. Tiêu chí production

Không bật capability mới nếu chưa đạt:

```text
full 256 row × 64 block simulation
random consumer stall
drop_count = 0
accepted = processed
mixed-scale numerical reference pass
two-bank ownership pass
host/bitstream capability version khớp
primary prompt sinh tiếng Anh
timing setup/hold pass ở 187,5 MHz
```

Cho đến lúc đó, compatibility path là raw INT32→CPU scale/accumulate; chậm nhưng đã có log sinh tiếng Anh hợp lệ.
