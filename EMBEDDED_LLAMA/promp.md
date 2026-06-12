đầu tiên: tải cái thư mục mà hom trức t copy cho m trên con zcu về để cho Ai hiểu ngữ cảnh 
m tìm cái file fpga_host.cpp hình như nó ở trong cái thư mục ggml/ggml-c. Đây là cái file bữa giờ mình điều khiển nó bằng hls 
bây giờ dựa vào  cái file FPGA_Driver.c của ô Luân viết trong thư mục EMBEDded_software á thì m chỉnh lại cái file fpga_host.cpp này sao cho lúc mô hình gọi tới phép toán ma trận thì nó sẽ cấp phát và chạy cái bitstream này trên FPGA
đại loại là m phải prompt cho AI nó hiểu ngữ  cảnh mình đang làm bộ tăng tốc phần cứng cho mô hình ngôn ngữ lớn, mình chọn tăng tốc vector 

yêu cầu về file fpga_host.cpp: 
- Địa chỉ RAM truy cập ( mà để lấy trọng số từ mô hình á hay nói cách khác là địa chỉ RAM để IP mình lấy dữ liệu) thì không được vượt ngoài range 0x70000000 - 0x7FFFFFFF
đây là cái địa chỉ mà sau khi mình trừ đi cái hệ điều hành linux á là nó còn range đó là RAM TRỐNG THÔI 
m có thể chạy lệnh này để xem : cat /proc/meminfo | grep -E "MemTotal|MemFree|CmaTotal|CmaFree"
- Địa chỉ base của IP mình thiết kế là từ 0xA000_0000 đến 0xAFFF_FFFF ( m vào vivado mở design_1_wrapper,  cái mục address editor trong vivado là thấy). File host dựa vào địa chỉ IP này để cấp phát 
- các địa chỉ DMA_BASE hay mấy cái liên quan  tới DMA nó nằm trong cái file C mà ô luân viết đó, m cũng prompt cho nó áp dụng vào cái file fpga_host.cpp của mình 
- nên tạo log để debug dữ liệu xem nó đã đúng chưa, cái cũ t làm là fpga_debug.log (m prompt AI nó làm cho), sao cho khi ta chạy mô hình á, vì mày bấm một cái tab khác và nhập cái này tail -f /tmp/fpga_debug.log là nó sẽ hiện thông tin dữ liệu 

- sau khi tạo xong file điều khiển, nạp bitstream theo câu lệnh này ( nhớ là đưa cái file bistream_matrix.bit ở trong thư mục BITSTREAM lên linux thư mục GEMMA3.cpp-MODEL-IN-FPGA trên FPGA đã )
câu lênh ( pass: temppwd): 
sudo su 
echo 0 > /sys/class/fpga_manager/fpga0/flags
cp bitstream_matrix.bit /lib/firmware/
echo bitstream_matrix.bit > /sys/class/fpga_manager/fpga0/firmware

kiểm tra đã nạp thành công chưa : cat /sys/class/fpga_manager/fpga0/state 

- Build_project ( nên làm trước khi nạp bitstream)
khi nhập pwd mày phải đang ở thư mục GEMMA3.cpp-MODEL-IN-FPGA
Lần đầu tiên build, thì m xoá cái thư mục cũ t đã build từ trước là build_mem, từ lần thứ 2 thì m không cần xóa thư mục này, 
câu lệnh build 
cmake -S . -B build_mem \
    -DUSE_FPGA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=OFF

cmake --build build_mem --target llama-cli -j2

sudo ./build_mem/bin/llama-cli \
    -m ./models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 64