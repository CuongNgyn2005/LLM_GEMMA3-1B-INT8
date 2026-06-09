# Chẩn đoán host runtime ngày 2026-06-09

## Log đầu vào

File đã phân tích:

```text
DATN_RTL/EMBEDDED_LLAMA/fpga_debug.log
```

Bitstream người dùng nạp:

```text
DATN_RTL/BITSTREAM/SoC_wrapper.bit
```

## Kết luận nhanh

Địa chỉ IP trong Vivado `project_1` đúng với `fpga_host.cpp`:

- Vivado segment: `SEG_VPU_Top_0_reg0`
- Offset: `0x00A0000000`
- Range: `256M`
- Physical range: `0xA0000000 - 0xAFFFFFFF`

Host hiện tại cấu hình:

- `VPU_BASE_PHYS = 0xA0000000`
- `VPU_RANGE_PHYS = 0x10000000`
- `VPU_MMAP_SIZE = 0x00300000`
- Host chỉ chạm `0xA0000000 - 0xA02FFFFF`

Vì vậy lỗi hiện tại không phải do host vượt IP range.

## Vấn đề chính trong log hiện tại

`fpga_debug.log` có:

```text
[FPGA][INFO  ] VPU mapped: base=0xa0000000 range=0x10000000 mmap_size=0x300000
[FPGA][INFO  ] VPU limits: rows=128 col_beats=256 cols=4096 raw_limits=0x01000080
[FPGA][MATMUL] done via FPGA ...
```

Điều này xác nhận:

- `/dev/mem` mmap được IP.
- `REG_LIMITS` đọc đúng: `MAX_ROWS=128`, `MAX_COL_BEATS=256`.
- GGML hook có gọi vào FPGA path.

Nhưng log thiếu toàn bộ marker của host trace mới:

```text
host trace version: 2026-06-09-zcu104-inline-trace-v2
address safety:
ACT_WRITE
WEIGHT_WRITE
RESULT_READ
dst sample
```

Kết luận: lần chạy này vẫn dùng `fpga_host.cpp` cũ hoặc build cache cũ trên ZCU104.

## Điều kiện bắt buộc cho lần chạy kế tiếp

Trên ZCU104, trước khi build:

```bash
grep -n "FPGA_HOST_TRACE_VERSION" ggml/src/ggml-cpu/fpga_host.cpp
grep -n "ACT_WRITE" ggml/src/ggml-cpu/fpga_host.cpp
grep -n "RESULT_READ" ggml/src/ggml-cpu/fpga_host.cpp
```

Nếu không có output, source chưa được sync.

Sau đó build sạch:

```bash
rm -rf build_mem
cmake -S . -B build_mem -DUSE_FPGA=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
cmake --build build_mem --target llama-cli -j2 | tee build_mem_fpga.log
```

Kiểm tra object:

```bash
grep -n "ggml-cpu/fpga_host.cpp.o" build_mem_fpga.log
grep -n "src/CMakeFiles/llama.dir/fpga_host.cpp.o" build_mem_fpga.log
```

Kỳ vọng:

- Có object trong `ggml-cpu`.
- Không có object trong `src/CMakeFiles/llama.dir`.

## Ghi chú về AXI

`project_1.srcs/sources_1/bd/SoC/SoC.bd` vẫn có:

```text
SUPPORTS_NARROW_BURST = 0
```

Trong khi host hiện tại ghi ACT/WEIGHT bằng các store 32-bit vào cửa sổ AXI 128-bit. Vì vậy cần trace thực tế:

- `ACT_WRITE`
- `WEIGHT_WRITE`
- `RESULT_READ`

Nếu các dòng này xuất hiện và `RESULT_READ` bất thường, lúc đó mới tập trung debug lane/strobe/AXI write path.

## Không chạy lại Vivado simulation ở bước này

Lý do: log hiện tại cho thấy IP base và `REG_LIMITS` đã đọc đúng trên phần cứng. Điểm nghẽn trước mắt là binary host chưa phải bản trace mới, nên chạy simulation RTL lúc này chưa trả lời được vì sao model không response.
