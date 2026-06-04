# VPU RTL Testbench Documentation

## Overview

This directory contains comprehensive testbenches for verifying the VPU (Vector Processing Unit) RTL design:

1. **tb_PMAU_Full.v** - Unit testbench for PMAU_Full core
2. **tb_VPU_Top.v** - Integration testbench for VPU_Top module

## Test Coverage

### tb_PMAU_Full.v

Tests the parallel multiply-accumulate unit with streaming interface.

**Test Cases:**
- **Test 1: Single DOT Product**
  - Verifies correct computation of a 64-element vector DOT product
  - Checks pipeline latency
  - Uses INT8 random inputs
  
- **Test 2: Multiple Back-to-Back DOT Products**
  - Sends 3 consecutive DOT product computations
  - Verifies data flow between iterations
  - No gaps between transactions

- **Test 3: Input Stalling & Flow Control**
  - Randomly stalls input `tvalid` signals
  - Verifies FSM handles backpressure correctly
  - No data loss or corruption

**Key Metrics:**
- Pipeline latency measurement
- Golden model verification
- Input/output ready/valid handshaking

### tb_VPU_Top.v

Tests the complete VPU with FSM-controlled streaming.

**Test Cases:**
- **Test Case 1: Ideal Streaming (No Backpressure)**
  - Output `tready` always high
  - 4 rows of weight matrix (4x64) × 1 activation vector (1x64)
  - Verifies FSM state transitions (WAIT_DATA → COMPUTE → STREAM_OUT)
  - Expected results computed by golden model

- **Test Case 2: Backpressure Handling (Random tready/tvalid)**
  - Random backpressure on input `tvalid` signals
  - Random backpressure on output `tready` signal
  - Verifies data integrity under realistic conditions
  - All 4 results must match golden model despite stalling

**Key Metrics:**
- FSM robustness
- Backpressure tolerance
- Self-checking with golden model
- Test result statistics (PASS/FAIL counts)

## Running Simulations

### Option 1: Vivado GUI (Recommended for debugging)

1. Open Vivado 2023.2 (or compatible version)
2. File → Create Project
3. Add sources:
   - RTL: `../RTL/PMAU_Full.v`, `../RTL/VPU_Top.v`
   - Testbench: `tb_VPU_Top.v` or `tb_PMAU_Full.v`
4. Tools → Run Simulation → Run Behavioral Simulation
5. View waveforms in Wave window

### Option 2: Command Line (xsim)

**Prerequisites:**
- Xilinx Vivado 2023.2+ installed
- Bash shell (Linux/macOS) or PowerShell (Windows)

**Run PMAU_Full testbench:**
```bash
cd TESTBENCH
xvlog -work xsim_work ../RTL/PMAU_Full.v ../RTL/VPU_Top.v tb_PMAU_Full.v
xelab -work xsim_work -top tb_PMAU_Full tb_PMAU_Full
xsim -work xsim_work tb_PMAU_Full
```

**Run VPU_Top testbench:**
```bash
cd TESTBENCH
xvlog -work xsim_work ../RTL/PMAU_Full.v ../RTL/VPU_Top.v tb_VPU_Top.v
xelab -work xsim_work -top tb_VPU_Top tb_VPU_Top
xsim -work xsim_work tb_VPU_Top
```

### Option 3: Using run_simulation.sh (Linux/macOS)

```bash
cd TESTBENCH
chmod +x run_simulation.sh

# Run VPU_Top testbench (default)
./run_simulation.sh tb_VPU_Top

# Run PMAU_Full testbench
./run_simulation.sh tb_PMAU_Full

# Run with debug/waveform output
./run_simulation.sh tb_VPU_Top 2
```

### Option 4: PowerShell Script (Windows)

Create file `run_simulation.ps1`:

```powershell
# Vivado xsim compilation
$vivado_path = "C:\Xilinx\Vivado\2023.2\bin"
$rtl_dir = "..\RTL"
$tb_name = "tb_VPU_Top"

# Compile and run
& "$vivado_path\xvlog.bat" -work xsim_work "$rtl_dir\PMAU_Full.v" "$rtl_dir\VPU_Top.v" "$tb_name.v"
& "$vivado_path\xelab.bat" -work xsim_work -top $tb_name $tb_name
& "$vivado_path\xsim.bat" -work xsim_work $tb_name
```

Then run:
```powershell
.\run_simulation.ps1
```

## Expected Output

### For tb_PMAU_Full.v

```
[TB] ============================================================
[TB] PMAU_Full Unit Test Started
[TB] Configuration: NUM_LANES=16, VEC_SIZE=64, NUM_BEATS=4
[TB] Clock Period: 10 ns (100.0 MHz)
[TB] ============================================================

[TB] Generating random test vectors...
[TB] Activation vector: [45, -67, 23, ..., -12]
[TB] Weight vector:     [-34, 56, -78, ..., 89]
[TB] Golden DOT Product: 12345 (0x00003039)

[TB] TEST 1: Single Vector DOT Product
[TB] ============================================================
[TB] Starting single DOT product test...
[TB] Sending beat 0 (elements 0-15)...
[TB] Sending beat 1 (elements 16-31)...
[TB] Sending beat 2 (elements 32-47)...
[TB] Sending beat 3 (elements 48-63)...
[TB] Waiting for DOT product result...
[TB] Result received after 6 cycles latency
[TB] Received: 0x00003039, Expected: 0x00003039
[PASS] DOT product correct!

...

[TB] Final Results:
[TB]   Total Tests: 6
[TB]   PASS: 6
[TB]   FAIL: 0
[TB] ============================================================
[TB] [PASS] All tests passed!
```

### For tb_VPU_Top.v

```
[TB] ============================================================
[TB] VPU_Top Testbench Started
[TB] Matrix: Activation (1x64) * Weight (4x64)
[TB] NUM_LANES: 16, Clock Period: 10ns (100.0 MHz)
[TB] ============================================================

[TB] TEST CASE 1: Ideal Streaming (axis_out_tready = 1'b1 always)
[TB] ============================================================
[TB] Starting ideal streaming test...

[TB] Sending Weight Row 0 + Activation...
[TB]   Beat 0: ...
[TB]   Beat 1: ...
[TB]   Beat 2: ...
[TB]   Beat 3: TLast set (last beat of row)

[TB] Waiting for output results...
[TB] Received Result[0] = 54321 (0x0000d431)
[TB] Received Result[1] = -12345 (0xffffcfc7)
[TB] Received Result[2] = 98765 (0x000181cd)
[TB] Received Result[3] = -56789 (0xffffdd2b)

[TB] Checking results for Test Case 1:
[PASS] Row 0: Got 0x0000d431, Expected 0x0000d431
[PASS] Row 1: Got 0xffffcfc7, Expected 0xffffcfc7
[PASS] Row 2: Got 0x000181cd, Expected 0x000181cd
[PASS] Row 3: Got 0xffffdd2b, Expected 0xffffdd2b

[TB] Final Results:
[TB]   Total Tests: 8
[TB]   PASS: 8
[TB]   FAIL: 0
[TB] ============================================================
[TB] [PASS] All tests passed!
```

## Understanding the Test Output

- **[TB]** - Testbench informational messages
- **[PASS]** - Test assertion passed
- **[FAIL]** - Test assertion failed

## Verifying Results

### Golden Model Approach

Both testbenches include a "golden model" (software reference) that:

1. Takes the same input vectors
2. Computes DOT product using simple loops
3. Stores expected results
4. Compares RTL output with expected values
5. Reports PASS/FAIL for each test case

### Self-Checking

The testbenches automatically:
- Compare every output against golden model
- Count PASS/FAIL results
- Print summary statistics
- Exit with code 0 (success) or 1 (failure)

## Waveform Analysis

To view simulation waveforms in Vivado GUI:

1. Run simulation (Options 1-3 above)
2. Once testbench completes, right-click in Waveform window
3. Add signals: 
   - Clock: `clk`, `rst`
   - Input: `axis_act_in_tvalid`, `axis_weight_in_tvalid`
   - Output: `axis_out_tvalid`, `axis_out_tdata`
   - FSM state: `dut.state_r` (for VPU_Top)
4. Trace through test execution

## Debugging Failed Tests

If a test fails:

1. **Check the error message** - [FAIL] line shows which result is wrong
2. **Enable verbose output** - Re-run with verbosity level 1-2
3. **Inspect waveforms** - Open `.wdb` or `.vcd` files in Vivado Wave window
4. **Check golden model** - Verify test data generation in task `generate_test_data()`
5. **Review FSM state transitions** - For VPU_Top, trace state_r through the test

## Architecture Details

### PMAU_Full Pipeline

```
Input (Beat 0-3)
    ↓
Stage 1: Input Register
    ↓
Stage 2: Multiply (INT8 × INT8 → INT16)
    ↓
Stages 3-5: Pipelined Adder Tree
    ↓
Stage 6: Accumulator
    ↓
Stage 7: Dequantization (placeholder)
    ↓
Output (Result valid after ~5-7 cycles)
```

### VPU_Top FSM

```
┌─────────┐
│WAIT_DATA│ ← Wait for activation_valid AND weight_valid
└────┬────┘
     │
     v
┌────────┐
│COMPUTE │ ← Stream data through PMAU while data flows
└────┬───┘   
     │ (when tlast AND tvalid)
     v
┌──────────┐
│STREAM_OUT│ ← Capture and send PMAU result
└────┬─────┘
     │ (when result_valid AND tready)
     v
   [WAIT_DATA]
```

## Parameters

Easily modify testbench behavior by changing these parameters:

```verilog
// tb_VPU_Top.v
parameter NUM_LANES    = 16;      // Parallel lanes
parameter ACT_WIDTH    = 8;       // INT8 inputs
parameter ACC_WIDTH    = 32;      // INT32 output
parameter MATRIX_ROWS  = 4;       // Test matrix size
parameter MATRIX_COLS  = 64;      
parameter CLOCK_PERIOD = 10;      // 100 MHz (10ns)
```

## Known Limitations

1. **Dequantization**: Currently a placeholder in PMAU_Full
   - FP16 multiply IP needs to be integrated
   - Tests verify accumulation, not dequantization accuracy

2. **AXPY Mode**: Not fully tested (placeholder scalar input)
   - Can be enabled by setting `compute_mode = 2'b01`
   - Requires additional scalar data path implementation

3. **Scale Factor**: Fixed at 1.0 (FP16 0x3C00)
   - Can be randomized for more thorough testing
   - Currently in placeholder dequantization stage

## Performance Metrics

Based on testbench execution:

- **Pipeline Latency**: ~5-7 cycles (measurable in Test 1)
- **Throughput**: 1 result per (NUM_BEATS × CLOCK_PERIOD) + latency
- **Backpressure Tolerance**: Fully robust (Test 2 verifies)

## Future Enhancements

1. Add protocol checker for internal valid/ready handshake compliance
2. Parameterize NUM_LANES and test with 8, 32 lanes
3. Add code coverage metrics
4. Formal property verification (SVA assertions)
5. Performance benchmarking for different input patterns

---

**Last Updated**: 29.05.2026  
**Author**: Testbench Generation System  
**Version**: 1.0
