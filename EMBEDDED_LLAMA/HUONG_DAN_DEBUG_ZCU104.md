# Hướng dẫn tạo log khi nạp bitstream và chạy model trên ZCU104

Mục tiêu của file này là tạo đủ log để kiểm tra ba việc:

- Bitstream `SoC_wrapper.bit` đã được nạp đúng chưa.
- Binary `llama-cli` có thật sự dùng `fpga_host.cpp` mới chưa.
- Dữ liệu có đi qua ACT/WEIGHT/RESULT window của VPU hay không.

## 1. Kết luận từ log hiện tại

File `DATN_RTL/EMBEDDED_LLAMA/fpga_debug.log` bạn gửi cho thấy:

- Host mmap được IP tại `0xA0000000`.
- `REG_LIMITS` đọc được `raw_limits=0x01000080`, tương ứng `rows=128`, `col_beats=256`.
- Host đã đi vào FPGA path nhiều lần với dòng `done via FPGA`.

Nhưng log này chưa phải bản host trace mới, vì không có các dòng:

- `host trace version: 2026-06-09-zcu104-inline-trace-v2`
- `address safety: ...`
- `ACT_WRITE`
- `WEIGHT_WRITE`
- `RESULT_READ`
- `dst sample`

Nếu log mới vẫn không có các dòng này, nguyên nhân gần như chắc chắn là source trên ZCU104 chưa được cập nhật hoặc `build_mem` vẫn dùng cache/object cũ.

## 2. Kiểm tra source trên ZCU104 trước khi build

Đứng tại thư mục repo đang chạy model, ví dụ:

```bash
cd ~/Cuong_test/GEMMA3.cpp-MODEL-IN-FPGA
```

Kiểm tra file host có marker mới:

```bash
grep -n "FPGA_HOST_TRACE_VERSION" ggml/src/ggml-cpu/fpga_host.cpp
grep -n "ACT_WRITE" ggml/src/ggml-cpu/fpga_host.cpp
grep -n "RESULT_READ" ggml/src/ggml-cpu/fpga_host.cpp
```

Kỳ vọng có output. Nếu không có output, source trên ZCU104 vẫn là bản cũ.

## 3. Rebuild sạch để tránh CMake cache cũ

```bash
rm -rf build_mem

cmake -S . -B build_mem \
    -DUSE_FPGA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=OFF

cmake --build build_mem --target llama-cli -j2 | tee build_mem_fpga.log
```

Sau build, kiểm tra:

```bash
grep -n "ggml-cpu/fpga_host.cpp.o" build_mem_fpga.log
grep -n "src/CMakeFiles/llama.dir/fpga_host.cpp.o" build_mem_fpga.log
```

Kỳ vọng:

- Có `ggml-cpu/fpga_host.cpp.o`.
- Không có `src/CMakeFiles/llama.dir/fpga_host.cpp.o`.

Nếu vẫn có `src/CMakeFiles/llama.dir/fpga_host.cpp.o`, source/CMake trên ZCU104 chưa đồng bộ với bản local hiện tại.

## 4. Nạp bitstream `SoC_wrapper.bit`

Đặt `SoC_wrapper.bit` trong repo root hoặc `/lib/firmware`.

```bash
sudo su
echo 0 > /sys/class/fpga_manager/fpga0/flags
cp SoC_wrapper.bit /lib/firmware/
echo SoC_wrapper.bit > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state
exit
```

Kỳ vọng:

```text
operating
```

## 5. Chạy model và tạo log FPGA

Terminal 1:

```bash
sudo rm -f /tmp/fpga_debug.log
sudo touch /tmp/fpga_debug.log
sudo chmod 666 /tmp/fpga_debug.log
tail -f /tmp/fpga_debug.log
```

Terminal 2:

```bash
sudo env FPGA_TRACE_CALLS=32 ./build_mem/bin/llama-cli \
    -m /home/debian/soc/models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 64 2>&1 | tee model_run_fpga.log
```

Sau khi chạy xong:

```bash
cp /tmp/fpga_debug.log ./fpga_debug.log
```

## 6. Chạy CPU-only để so sánh

Lệnh này không dùng FPGA, giúp xác định lỗi do model/prompt hay do FPGA path:

```bash
sudo env FPGA_DISABLE=1 ./build_mem/bin/llama-cli \
    -m /home/debian/soc/models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 64 2>&1 | tee model_run_cpu_only.log
```

Diễn giải:

- CPU-only có response, FPGA không response: lỗi nằm trong FPGA path.
- CPU-only cũng không response: kiểm tra prompt/chat mode/model runtime trước.

## 7. Cách đọc log FPGA

Trong `fpga_debug.log`, cần thấy:

```text
[FPGA][INFO  ] host trace version: 2026-06-09-zcu104-inline-trace-v2
[FPGA][INFO  ] address safety: IP segment phys=...
[FPGA][INFO  ] map ACT_IN ...
[FPGA][DATA  ] ACT_WRITE ...
[FPGA][DATA  ] WEIGHT_WRITE ...
[FPGA][DATA  ] RESULT_READ ...
[FPGA][DATA  ] dst sample ...
```

Nếu không có `host trace version`, binary đang chạy không phải bản mới.

Nếu có `ACT_WRITE` và `WEIGHT_WRITE` nhưng `RESULT_READ` luôn bằng 0 hoặc bất thường, tập trung kiểm tra RTL/AXI/VPU result path.

Nếu có `RESULT_READ` hợp lý nhưng `dst sample` ra `NaN`, `Inf`, hoặc giá trị cực lớn, tập trung kiểm tra scale/q8 layout/tích lũy trong host.

Nếu không có `ACT_WRITE`, model chưa đi vào nhánh FPGA matmul; kiểm tra hook `ggml-cpu.c`, CMake, hoặc shape filter trong `fpga_host.cpp`.

## 8. Script capture log tự động

Tôi đã tạo script:

```text
DATN_RTL/EMBEDDED_LLAMA/capture_zcu104_deploy_logs.sh
```

Copy script này sang repo trên ZCU104 rồi chạy:

```bash
bash capture_zcu104_deploy_logs.sh
```

Script sẽ tạo một thư mục log gồm:

- `system_before.log`
- `build_source_check.log`
- `fpga_manager.log`
- `model_run_fpga.log`
- `fpga_debug.log`
- `dmesg_after.log`
- file `.tar.gz` để gửi lại.

## 9. Địa chỉ đang dùng

Host hiện tại chỉ mmap IP:

- IP base: `0xA0000000`
- mmap size: `0x00300000`
- vùng host chạm tới: `0xA0000000 - 0xA02FFFFF`

Các window:

- ACT input: `0xA0010000 - 0xA001FFFF`
- WEIGHT input: `0xA0100000 - 0xA01FFFFF`
- RESULT output: `0xA0200000 - 0xA020FFFF`

Vùng DDR `0x70000000 - 0x7FFFFFFF` hiện chưa bị host mmap hoặc ghi.
