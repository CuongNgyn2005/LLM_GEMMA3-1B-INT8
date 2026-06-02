# AXI4-Full VPU INT8 Simulation And Timing Report

Ngày tạo: 2026-06-02  
Board mục tiêu: ZCU104, part `xczu7ev-ffvc1156-2-e`  
Vivado dùng để kiểm chứng: Vivado 2022.2

## 1. Tóm tắt thay đổi

Kiến trúc VPU đã được đổi từ hướng AXI-Stream top-level sang AXI4-Full memory-mapped. Đường tính toán vẫn giữ INT8 theo định hướng hiện tại, không chuyển sang FP16. CPU/PS ghi activation và weight vào vùng nhớ BRAM nội bộ qua AXI4-Full, cấu hình kích thước runtime, phát lệnh `start`, sau đó đọc kết quả INT32 từ vùng result.

Các file chính đã được chỉnh:

- `RTL/VPU_Top.v`: top-level AXI4-Full wrapper, không còn port AXI-Stream.
- `RTL/MY_IP.v`: AXI4-Full slave, address map, burst write/read, điều khiển start/status/config.
- `RTL/Matrix_Vector_Multiplication.v`: lõi GEMV INT8 có BRAM cho activation/weight/result, hỗ trợ runtime shape.
- `TESTBENCH/tb_VPU_Top.v`: testbench AXI4-Full mới.
- `DATN_VIVADO/manual_sim/run_axi_full_synth.tcl`: script synth OOC.
- `DATN_VIVADO/manual_sim/run_axi_full_impl.tcl`: script route OOC.

`Matrix_Vector_Multiplication.v` là cần thiết trong kiến trúc mới. File này đã được thay từ module nhân ma trận kiểu giáo trình sang lõi INT8 GEMV có BRAM backing, pipeline trước PMAU, và điều khiển kích thước runtime. File `AXI4_Mapping.v` trong thư mục course chỉ dùng để tham khảo, không nằm trong kiến trúc mới.

## 2. Address map AXI4-Full

Bus dữ liệu mặc định: 128 bit, tương ứng 16 phần tử INT8 mỗi beat.

| Offset | Chức năng |
|---:|---|
| `0x0000_0000` | `CTRL`: bit 0 start, bit 1 clear done. Đọc trả status alias. |
| `0x0000_0010` | `STATUS`: `{error, busy, done}`. |
| `0x0000_0020` | `ROWS`: số hàng output cần tính. |
| `0x0000_0030` | `COLS`: số cột thực tế. |
| `0x0000_0040` | `COL_BEATS`: số beat 128-bit mỗi hàng. Ghi `0` để tự suy ra từ `COLS`. |
| `0x0000_0050` | `SCALE`: scale 16 bit, hiện đang dùng raw bypass trong PMAU. |
| `0x0000_0060` | `MODE`: giữ chỗ cho mode mở rộng. |
| `0x0000_0070` | `LIMITS`: `{MAX_COL_BEATS, MAX_ROWS}`. |
| `0x0000_0080` | `PROGRESS`: `{active_col_beat, active_row}`. |
| `0x0001_0000` | `ACT_BASE`: vùng ghi activation. |
| `0x0010_0000` | `WEIGHT_BASE`: vùng ghi weight. |
| `0x0020_0000` | `RESULT_BASE`: vùng đọc result INT32. |

Activation được index theo `col_beat`. Weight được index theo `row * MAX_COL_BEATS + col_beat`. Result được index theo `row`.

## 3. Dung lượng context trên BRAM

Thông số mặc định của lõi:

- `NUM_LANES = 16`
- `AXI_DATA_WIDTH = 128`
- `MAX_ROWS = 128`
- `MAX_COL_BEATS = 256`

Suy ra dung lượng lưu trữ nội bộ:

- Activation: `256 * 16 bytes = 4096 bytes`
- Weight: `128 * 256 * 16 bytes = 524288 bytes`
- Result: `128 * 4 bytes = 512 bytes`
- Số cột tối đa mỗi hàng: `256 * 16 = 4096` phần tử INT8

Như vậy cấu hình hiện tại cho phép một vector activation dài tối đa 4096 phần tử INT8 và 128 hàng weight/output trong một lần chạy. Nếu cần context dài hơn nữa, có thể tăng `MAX_COL_BEATS`, nhưng chi phí BRAM sẽ tăng tuyến tính. Nếu tăng `MAX_ROWS`, vùng weight cũng tăng tuyến tính theo `MAX_ROWS * MAX_COL_BEATS`.

Với `COL_BEATS = 0`, hardware tự suy ra số beat từ `COLS`. Nếu `COLS` không chia hết cho 16, phần software/PS cần zero-pad các lane dư trong beat cuối để kết quả dot product đúng.

## 4. Pipeline và tối ưu timing

Các điểm đã giữ hoặc thêm để bảo toàn timing:

- PMAU vẫn là datapath INT8 MAC có pipeline nội bộ.
- Dữ liệu đọc từ BRAM activation/weight được đăng ký thêm một tầng trước khi đưa vào PMAU. Mục tiêu là cắt đường timing từ BRAM cascade sang multiplier/add tree.
- AXI write request được đăng ký một chu kỳ trước khi ghi vào BRAM. Việc này tránh đường dài từ AXI decode/write channel vào enable/address/data của BRAM.
- Vùng activation/weight chỉ hỗ trợ CPU ghi. CPU readback activation/weight được trả lỗi `SLVERR` để tránh kéo dài đường timing không cần thiết. CPU vẫn đọc được status/config/result.
- AXI4-Full slave hiện hỗ trợ mô hình đơn giản, một read transaction và một write transaction outstanding tại một thời điểm. INCR burst được hỗ trợ cho việc nạp activation/weight/result access.

## 5. Kết quả mô phỏng chức năng

Lệnh mô phỏng đã chạy trong `DATN_VIVADO/manual_sim`:

```text
D:\Xlinx\Vivado\2022.2\bin\xvlog.bat ..\..\RTL\PMAU_Streaming.v ..\..\RTL\Matrix_Vector_Multiplication.v ..\..\RTL\MY_IP.v ..\..\RTL\VPU_Top.v ..\..\TESTBENCH\tb_VPU_Top.v -log axi_full_compile.log
D:\Xlinx\Vivado\2022.2\bin\xelab.bat tb_VPU_Top -debug typical -s tb_VPU_Top_axi_full -log axi_full_elab.log
D:\Xlinx\Vivado\2022.2\bin\xsim.bat tb_VPU_Top_axi_full -runall -log axi_full_sim.log
```

Log chính: `DATN_VIVADO/manual_sim/axi_full_sim.log`

Kết quả:

| Test | Cấu hình | Kết quả |
|---|---|---|
| Case 1 | `rows=3`, `cols=64`, `load_beats=4`, `cfg_col_beats=4` | PASS, kết quả từng hàng: `-613`, `1039`, `115` |
| Case 2 | `rows=2`, `cols=17`, `load_beats=2`, `cfg_col_beats=0` | PASS, tự suy ra beat, kết quả từng hàng: `145`, `328` |

Tổng kết testbench:

```text
[TB] pass_count=5 fail_count=0
[TB] AXI4-Full VPU TEST PASSED
```

Số chu kỳ `compute+poll` quan sát trong testbench:

- Case 1: 57 cycles
- Case 2: 35 cycles

Con số này bao gồm cả overhead polling qua AXI trong testbench. Latency tính toán thuần của core phụ thuộc chủ yếu vào `rows * col_beats` cộng với các tầng pipeline BRAM/PMAU/result writeback.

## 6. Kết quả timing và tài nguyên

Script route OOC đã chạy:

```text
D:\Xlinx\Vivado\2022.2\bin\vivado.bat -mode batch -source run_axi_full_impl.tcl -nojournal -log axi_full_impl_vivado.log
```

Report timing: `DATN_VIVADO/manual_sim/axi_full_impl_timing_300mhz.rpt`

Clock constraint: 3.333 ns, tương đương khoảng 300 MHz.

Kết quả post-route OOC:

- WNS: `+0.085 ns`
- TNS: `0.000 ns`
- Failing endpoints: `0`
- WHS: `+0.044 ns`
- THS: `0.000 ns`
- Vivado báo: `All user specified timing constraints are met.`

Report utilization: `DATN_VIVADO/manual_sim/axi_full_impl_utilization.rpt`

Tài nguyên chính:

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| CLB LUTs | 2399 | 230400 | 1.04% |
| CLB Registers | 1875 | 460800 | 0.41% |
| Block RAM Tile | 130.5 | 312 | 41.83% |
| RAMB36E2 | 130 |  |  |
| RAMB18E2 | 1 |  |  |
| DSP48E2 | 2 | 1728 | 0.12% |

BRAM đang là tài nguyên chính vì mục tiêu đã chuyển sang tăng khả năng lưu activation/weight để hỗ trợ context dài hơn. Timing vẫn đạt 300 MHz OOC sau khi tăng BRAM nhờ thêm register stage ở đường BRAM sang PMAU và register stage ở đường AXI write.

## 7. Ghi chú tích hợp Vivado/ZCU104

Mô phỏng behavioral đã đúng chức năng với AXI4-Full. Timing post-route OOC đạt constraint 300 MHz. Khi đưa vào block design thật trên ZCU104, cần lưu ý:

- Đây là kết quả out-of-context cho IP. Khi nối vào PS/NoC/interconnect thật, nên chạy lại implementation toàn hệ thống.
- OOC report có warning liên quan `HD.CLK_SRC` chưa được set cho `s00_axi_aclk`. Đây là warning thường gặp khi synth/route IP rời khỏi block design. Trong design hoàn chỉnh cần constraint clock đầy đủ từ clock wizard/PS.
- Nếu chạy implementation không OOC trực tiếp với toàn bộ AXI port là top-level IO, Vivado sẽ báo thiếu IO pin. Cách đúng là dùng VPU như IP nội bộ trong block design, không map tất cả AXI signal ra chân FPGA.
- AXI4-Full slave hiện là subset thực dụng cho accelerator: burst tuần tự, không hỗ trợ nhiều ID/outstanding phức tạp. Điều này phù hợp với PS/DMA điều khiển đơn giản, nhưng nếu dùng interconnect có nhiều master đồng thời thì cần bổ sung arbitration/ID handling sâu hơn.
- Vì readback activation/weight đã tắt để bảo toàn timing, quá trình debug nên kiểm tra dữ liệu qua testbench hoặc ILA trên write channel, không đọc ngược vùng ACT/WEIGHT qua AXI.

## 8. Kết luận

Phiên bản AXI4-Full INT8 hiện tại đã pass testbench chức năng và đạt timing 300 MHz OOC trên part ZCU104. Hướng tối ưu context đã được phản ánh bằng BRAM-backed activation/weight store với kích thước runtime, thay vì phụ thuộc kích thước cố định của input. Thiết kế hiện ưu tiên giữ throughput và timing trong khi mở rộng dung lượng weight/tensor trên BRAM.
