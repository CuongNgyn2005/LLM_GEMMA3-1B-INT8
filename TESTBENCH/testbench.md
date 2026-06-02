# Yêu Cầu Viết Testbench cho module VPU_Top (AXI-Stream)

## Mục tiêu:
Viết một module testbench (`tb_VPU_Top.v`) bằng Verilog để kiểm tra tính đúng đắn của khối `VPU_Top`. Khối này sử dụng giao diện AXI-Stream thuần túy.

## Thông số cấu hình (Parameters) cho Testbench:
* Kích thước ma trận Test: 1 Vector Activation (1x64) nhân với Ma trận Weight (4x64). 
* `NUM_LANES` = 16. Vậy cần 4 nhịp clock (64/16 = 4) để truyền xong 1 hàng của ma trận trọng số.
* Xung nhịp (Clock): Chu kỳ 10ns (100MHz).

## Các thành phần cần có trong Testbench:
### 1. BFM (Bus Functional Model) / Tasks:
Tạo các task để mô phỏng hành vi của AXI DMA:
* `task send_stream_data()`: Bơm mảng dữ liệu INT8 vào `axis_act_in_tdata` và `axis_weight_in_tdata`. 
* Điều khiển tín hiệu `tvalid` đúng chuẩn: Chỉ cập nhật data mới khi cả `tvalid` và `tready` đều bằng 1 ở sườn lên của clock.
* Tín hiệu `tlast`: Phải được bật lên mức 1 ở nhịp truyền thứ 4 (nhịp cuối cùng của 1 hàng 64 phần tử).

### 2. Kịch bản Mô phỏng (Test Scenarios):
* **Test Case 1 - Ideal Streaming (Không Backpressure):**
  - Cố định `axis_out_tready = 1` (Mạch đích luôn sẵn sàng nhận).
  - Bơm liên tục 4 hàng (tương đương 4 vòng lặp, mỗi vòng 4 nhịp có `tlast` ở cuối).
* **Test Case 2 - Backpressure (Có nghẽn mạng):**
  - Đang truyền dữ liệu, ngẫu nhiên kéo `axis_out_tready = 0` trong vài chu kỳ clock để xem FSM của `VPU_Top` có bị treo hoặc mất dữ liệu ở `STREAM_OUT` hay không. Ngẫu nhiên kéo `tvalid` của ngõ vào xuống 0 để mô phỏng RAM phản hồi chậm.

### 3. Self-Checking (Tự động kiểm tra):
* Viết một mô hình tham chiếu (Golden Model) bằng code logic phần mềm ngay trong Testbench (các vòng lặp `for` đơn giản của Verilog).
* So sánh kết quả `axis_out_tdata` thu được từ VPU_Top (sau khi `tvalid` ngõ ra bật lên) với kết quả của Golden Model.
* In ra console: `[PASS]` nếu trùng khớp, `[FAIL]` nếu sai lệch.

## Yêu cầu Coding:
* Dùng `$urandom_range(-128, 127)` để tạo random data cho Activation và Weight (ép kiểu về bù 2 INT8).
* Testbench phải tự động kết thúc bằng `$finish` sau khi hoàn thành các Test cases.
* Output file Verilog/SystemVerilog hoàn chỉnh.