#!/usr/bin/env bash
set -euo pipefail

# Run on ZCU104 from either:
# - the parent directory that contains llama.cpp and DATN_RTL, or
# - the llama.cpp repository root itself.

ROOT_DIR="$(pwd)"
if [[ -d "${ROOT_DIR}/llama.cpp" && -f "${ROOT_DIR}/llama.cpp/CMakeLists.txt" ]]; then
    REPO_DIR="${ROOT_DIR}/llama.cpp"
else
    REPO_DIR="${ROOT_DIR}"
fi

cd "${REPO_DIR}"
echo "[info] repo dir: ${REPO_DIR}"

echo "[1/8] Check memory state"
cat /proc/meminfo | grep -E "MemTotal|MemFree|CmaTotal|CmaFree"
dmesg | grep -iE "memory|reserved|linear" | tail -n 20 || true

echo "[2/8] Clean old CMake build to avoid stale src/fpga_host.cpp objects"
rm -rf build_mem

echo "[3/8] Build llama-cli with FPGA support"
cmake -S . -B build_mem \
    -DUSE_FPGA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=OFF

cmake --build build_mem --target llama-cli -j2

echo "[4/8] Program bitstream"
if [[ -f "${ROOT_DIR}/DATN_RTL/BITSTREAM/bitstream_matrix.bit" ]]; then
    BITSTREAM_SRC="${ROOT_DIR}/DATN_RTL/BITSTREAM/bitstream_matrix.bit"
elif [[ -f "${REPO_DIR}/bitstream_matrix.bit" ]]; then
    BITSTREAM_SRC="${REPO_DIR}/bitstream_matrix.bit"
else
    echo "bitstream_matrix.bit not found. Put it in repo root or DATN_RTL/BITSTREAM." >&2
    exit 1
fi

sudo cp "${BITSTREAM_SRC}" /lib/firmware/bitstream_matrix.bit
echo 0 | sudo tee /sys/class/fpga_manager/fpga0/flags >/dev/null
echo bitstream_matrix.bit | sudo tee /sys/class/fpga_manager/fpga0/firmware >/dev/null
cat /sys/class/fpga_manager/fpga0/state

echo "[5/8] Build and run standalone MMIO smoke test"
SMOKE_SRC="${SMOKE_SRC:-}"
if [[ -z "${SMOKE_SRC}" && -f "${ROOT_DIR}/DATN_RTL/MANUAL_UPLOADED/fpga_mmio_smoke_test.cpp" ]]; then
    SMOKE_SRC="${ROOT_DIR}/DATN_RTL/MANUAL_UPLOADED/fpga_mmio_smoke_test.cpp"
elif [[ -z "${SMOKE_SRC}" && -f "${REPO_DIR}/fpga_mmio_smoke_test.cpp" ]]; then
    SMOKE_SRC="${REPO_DIR}/fpga_mmio_smoke_test.cpp"
fi

if [[ -n "${SMOKE_SRC}" && -f "${SMOKE_SRC}" ]]; then
    g++ -O2 -std=c++17 "${SMOKE_SRC}" -o fpga_mmio_smoke_test
    sudo ./fpga_mmio_smoke_test | tee fpga_mmio_smoke_test.log
else
    echo "fpga_mmio_smoke_test.cpp not found; skipping standalone smoke test." >&2
fi

echo "[6/8] Run llama-cli with FPGA self-test enabled"
sudo rm -f /tmp/fpga_debug.log
sudo env FPGA_SELF_TEST=1 ./build_mem/bin/llama-cli \
    -m /home/debian/soc/models/gemma-3-1b-it-Q8_0.gguf \
    -p "Please write about AI" \
    -n 64 \
    -no-cnv \
    --no-warmup | tee fpga_model_run.log

echo "[7/8] Save FPGA debug log"
sudo test -f /tmp/fpga_debug.log && sudo cp /tmp/fpga_debug.log ./fpga_debug.log || true
sudo test -f /tmp/fpga_debug.log && sudo tail -n 120 /tmp/fpga_debug.log || true

echo "[8/8] Optional CPU-only comparison command"
echo "sudo env FPGA_DISABLE=1 ./build_mem/bin/llama-cli -m /home/debian/soc/models/gemma-3-1b-it-Q8_0.gguf -p 'Please write about AI' -n 64 -no-cnv --no-warmup"
