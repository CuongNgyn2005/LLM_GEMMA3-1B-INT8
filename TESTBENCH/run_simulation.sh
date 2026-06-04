#!/bin/bash

# ============================================================================
# Simulation Run Script for VPU_Top RTL Testbenches
# ============================================================================
# 
# Usage:
#   ./run_simulation.sh <testbench_name> [verbosity_level]
#
# Supported testbenches:
#   - tb_PMAU_Full     (Unit test for PMAU core)
#   - tb_VPU_Top            (Integration test for VPU)
#
# Verbosity levels:
#   0 = Standard output
#   1 = Verbose (show all nets)
#   2 = Debug (include waveform dump)
#
# ============================================================================

set -e

# Configuration
VIVADO_PATH="/opt/xilinx/Vivado/2023.2"  # Adjust to your Vivado version
WORK_DIR="$(pwd)"
SIM_DIR="${WORK_DIR}/sim"
LOG_DIR="${WORK_DIR}/logs"
WAVE_DIR="${WORK_DIR}/waveforms"

# RTL Sources
RTL_DIR="../RTL"
TESTBENCH_DIR="."

# Testbench selection
TB_NAME="${1:-tb_VPU_Top}"
VERBOSITY="${2:-0}"

# ============================================================================
# Function: Print colored output
# ============================================================================
print_header() {
    echo ""
    echo "=================================="
    echo "$1"
    echo "=================================="
    echo ""
}

print_status() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ============================================================================
# Main flow
# ============================================================================

print_header "VPU RTL Simulation Script"

# Check Vivado installation
if [ ! -d "$VIVADO_PATH" ]; then
    echo "ERROR: Vivado not found at $VIVADO_PATH"
    exit 1
fi

# Setup directories
mkdir -p "$SIM_DIR" "$LOG_DIR" "$WAVE_DIR"
cd "$SIM_DIR"

print_status "Testbench: $TB_NAME"
print_status "Verbosity: $VERBOSITY"
print_status "Working directory: $SIM_DIR"

# ============================================================================
# Generate Vivado simulation project using xsim
# ============================================================================

print_status "Compiling RTL sources with xvlog..."

# Compile RTL modules
xvlog -work xsim_work \
    "${RTL_DIR}/PMAU_Full.v" \
    "${RTL_DIR}/VPU_Top.v" \
    2>&1 | tee -a "${LOG_DIR}/compile.log"

if [ $? -ne 0 ]; then
    echo "ERROR: RTL compilation failed!"
    exit 1
fi

print_status "Compiling testbench..."

# Compile testbench
xvlog -work xsim_work \
    "${TESTBENCH_DIR}/${TB_NAME}.v" \
    2>&1 | tee -a "${LOG_DIR}/compile.log"

if [ $? -ne 0 ]; then
    echo "ERROR: Testbench compilation failed!"
    exit 1
fi

print_status "Elaborating design..."

# Elaborate
xelab -work xsim_work \
    -top ${TB_NAME} \
    -debug ${TB_NAME} \
    2>&1 | tee -a "${LOG_DIR}/elab.log"

if [ $? -ne 0 ]; then
    echo "ERROR: Elaboration failed!"
    exit 1
fi

# ============================================================================
# Run simulation
# ============================================================================

print_status "Running simulation..."

# Create simulation run configuration
if [ "$VERBOSITY" -eq 2 ]; then
    # Enable waveform dump
    xsim -work xsim_work \
        ${TB_NAME} \
        -log "${LOG_DIR}/simulation.log" \
        -wdb "${WAVE_DIR}/${TB_NAME}.wdb" \
        -tcl run_vcd.tcl \
        2>&1 | tee -a "${LOG_DIR}/simulation.log"
else
    xsim -work xsim_work \
        ${TB_NAME} \
        -log "${LOG_DIR}/simulation.log" \
        2>&1 | tee -a "${LOG_DIR}/simulation.log"
fi

SIM_RESULT=$?

# ============================================================================
# Check results
# ============================================================================

print_header "Simulation Complete"

if [ $SIM_RESULT -eq 0 ]; then
    print_status "✓ Simulation passed!"
    grep -E "\[PASS\]|\[FAIL\]" "${LOG_DIR}/simulation.log" || true
else
    print_status "✗ Simulation failed with code $SIM_RESULT"
    tail -30 "${LOG_DIR}/simulation.log"
    exit 1
fi

print_status "Log files saved to: $LOG_DIR"
if [ -d "$WAVE_DIR" ] && [ "$(ls -A $WAVE_DIR)" ]; then
    print_status "Waveforms saved to: $WAVE_DIR"
fi

echo ""
print_status "Done!"
