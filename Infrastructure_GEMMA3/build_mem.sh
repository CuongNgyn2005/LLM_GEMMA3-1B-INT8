cmake -S . -B build_mem \
    -DUSE_FPGA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=OFF

cmake --build build_mem --target llama-cli -j2
