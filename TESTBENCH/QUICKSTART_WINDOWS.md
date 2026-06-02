# VPU Testbench - Quick Start Guide (Windows/PowerShell)

## Prerequisites

1. **Xilinx Vivado 2023.2** (or compatible version) installed
2. **PowerShell 5.0+** (or PowerShell Core)
3. Add Vivado to your system PATH or modify `$vivado_path` below

## Quick Start: 3 Ways to Run

### Method 1: Vivado GUI (Recommended for Debugging)

This is the easiest way if you want to see waveforms and step through execution.

**Steps:**
1. Open Vivado 2023.2
2. In Vivado Tcl Console, run:
   ```tcl
   source {path/to/TESTBENCH/run_sim.tcl}
   ```
   Or use: File → Run Tcl Script → Select `run_sim.tcl`

3. Wait for behavioral simulation to launch
4. In Wave window, click "Run All" (or press Ctrl+F5)
5. Watch console for `[PASS]` / `[FAIL]` output
6. Inspect waveforms to debug if needed

---

### Method 2: PowerShell Command Line (Fastest)

**Step 1: Open PowerShell**
```powershell
# Navigate to TESTBENCH directory
cd h:\DATN\DATN_RTL\TESTBENCH
```

**Step 2: Run Simulation**

For **VPU_Top** testbench:
```powershell
# Compile and run
$vivado = "C:\Xilinx\Vivado\2023.2\bin"  # Adjust path if needed
$rtl = "..\RTL"

# Create work directory
mkdir -Force .\sim | Out-Null

# Compile
& "$vivado\xvlog.bat" -work .\sim\xsim_work $rtl\PMAU_Streaming.v $rtl\VPU_Top.v .\tb_VPU_Top.v

# Elaborate
& "$vivado\xelab.bat" -work .\sim\xsim_work -top tb_VPU_Top tb_VPU_Top

# Simulate
& "$vivado\xsim.bat" -work .\sim\xsim_work tb_VPU_Top
```

For **PMAU_Streaming** testbench (unit test):
```powershell
# Same steps, but use tb_PMAU_Streaming.v at the end
& "$vivado\xvlog.bat" -work .\sim\xsim_work $rtl\PMAU_Streaming.v $rtl\VPU_Top.v .\tb_PMAU_Streaming.v
& "$vivado\xelab.bat" -work .\sim\xsim_work -top tb_PMAU_Streaming tb_PMAU_Streaming
& "$vivado\xsim.bat" -work .\sim\xsim_work tb_PMAU_Streaming
```

**Expected Output:**
```
[TB] ============================================================
[TB] VPU_Top Testbench Started
[TB] Matrix: Activation (1x64) * Weight (4x64)
...
[PASS] Row 0: Got 0x0000d431, Expected 0x0000d431
[PASS] Row 1: Got 0xffffcfc7, Expected 0xffffcfc7
...
[TB] [PASS] All tests passed!
```

---

### Method 3: PowerShell Script (Most Convenient)

**Create file: `run_test.ps1`**

```powershell
# ============================================================================
# VPU Testbench Runner for Windows PowerShell
# ============================================================================

param(
    [string]$testbench = "tb_VPU_Top",
    [string]$vivado_path = "C:\Xilinx\Vivado\2023.2\bin",
    [string]$action = "run"  # run, clean, or both
)

# Configuration
$work_dir = ".\sim\xsim_work"
$rtl_dir = "..\RTL"
$log_dir = ".\logs"

# Function to run xvlog
function Compile-RTL {
    param([string]$tb)
    
    Write-Host "[COMPILE] Compiling RTL sources..." -ForegroundColor Green
    mkdir -Force $work_dir | Out-Null
    mkdir -Force $log_dir | Out-Null
    
    & "$vivado_path\xvlog.bat" -work $work_dir `
        "$rtl_dir\PMAU_Streaming.v" `
        "$rtl_dir\VPU_Top.v" `
        "$tb.v" | Tee-Object -FilePath "$log_dir\compile.log"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
        exit 1
    }
}

# Function to elabor ate
function Elaborate {
    param([string]$tb)
    
    Write-Host "[ELAB] Elaborating design..." -ForegroundColor Green
    & "$vivado_path\xelab.bat" -work $work_dir -top $tb $tb | `
        Tee-Object -FilePath "$log_dir\elab.log"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Elaboration failed!" -ForegroundColor Red
        exit 1
    }
}

# Function to simulate
function Simulate {
    param([string]$tb)
    
    Write-Host "[SIM] Running simulation..." -ForegroundColor Green
    & "$vivado_path\xsim.bat" -work $work_dir $tb | `
        Tee-Object -FilePath "$log_dir\simulation.log"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[PASS] Simulation completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Simulation failed!" -ForegroundColor Red
        exit 1
    }
}

# Function to clean
function Clean-Artifacts {
    Write-Host "[CLEAN] Removing simulation artifacts..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force ".\sim" -ErrorAction SilentlyContinue
    Write-Host "[CLEAN] Done." -ForegroundColor Yellow
}

# Main flow
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "VPU RTL Testbench Runner"
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "Testbench: $testbench" -ForegroundColor White
Write-Host "Vivado: $vivado_path" -ForegroundColor White
Write-Host ""

# Check Vivado installation
if (!(Test-Path "$vivado_path\xvlog.bat")) {
    Write-Host "[ERROR] Vivado not found at: $vivado_path" -ForegroundColor Red
    exit 1
}

# Run
if ($action -eq "clean" -or $action -eq "both") {
    Clean-Artifacts
}

if ($action -eq "run" -or $action -eq "both") {
    Compile-RTL $testbench
    Elaborate $testbench
    Simulate $testbench
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "Log files saved to: $log_dir" -ForegroundColor White
Write-Host "============================================================================" -ForegroundColor Cyan
```

**Then run:**
```powershell
# Run VPU_Top testbench
.\run_test.ps1 -testbench "tb_VPU_Top"

# Run PMAU_Streaming testbench
.\run_test.ps1 -testbench "tb_PMAU_Streaming"

# Clean and run fresh
.\run_test.ps1 -testbench "tb_VPU_Top" -action "both"

# Clean only
.\run_test.ps1 -action "clean"
```

---

## Understanding Testbench Output

### Success Case
```
[TB] ============================================================
[TB] VPU_Top Testbench Started
...
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

### Failure Case
```
[FAIL] Row 2: Got 0x000181cc, Expected 0x000181cd

[TB] Final Results:
[TB]   Total Tests: 8
[TB]   PASS: 7
[TB]   FAIL: 1
[TB] ============================================================
[TB] [FAIL] Some tests failed!
```

---

## Testbench Details

### What Each Test Does

**tb_VPU_Top.v:**
- **Test Case 1**: Ideal streaming (no backpressure)
  - Sends 4 rows of 64-element weight matrix
  - Checks all 4 results against golden model
  - Tests FSM transitions (WAIT_DATA → COMPUTE → STREAM_OUT)

- **Test Case 2**: Random backpressure
  - Simulates slow upstream (random tvalid drops)
  - Simulates slow downstream (random tready drops)
  - Verifies data integrity under realistic conditions

**tb_PMAU_Streaming.v:**
- **Test 1**: Single DOT product
  - Measures pipeline latency (~6 cycles)
  - Verifies correct INT8×INT8 → INT32 accumulation

- **Test 2**: Multiple back-to-back operations
  - 3 consecutive DOT products
  - Verifies accumulator reset between tokens

- **Test 3**: Input stalling
  - Random tvalid drops during streaming
  - Verifies proper handshaking under stall

---

## If Tests Fail

1. **Check error message** - Which row/test failed?
2. **Run with Vivado GUI** (Method 1) to see waveforms
3. **Verify Vivado version** - Should be 2023.2 compatible
4. **Check file paths** - Adjust `$vivado_path`, `$rtl_dir` as needed
5. **Read logs** - Check `logs/` directory for detailed errors

---

## File Locations

After running simulation:
- **Logs**: `logs/` directory
  - `compile.log` - Compilation messages
  - `elab.log` - Elaboration messages
  - `simulation.log` - Test output
- **Simulation DB**: `sim/xsim_work/` directory
- **Waveforms**: `waveforms/` directory (if enabled)

---

## Clean Up

To remove simulation artifacts:
```powershell
# Manual cleanup
Remove-Item -Recurse -Force ".\sim"

# Or using script
.\run_test.ps1 -action "clean"
```

---

## Customization

Edit testbench parameters in the `.v` files:

```verilog
// tb_VPU_Top.v - Line 20
parameter NUM_LANES    = 16;      // Change to 8, 32, etc.
parameter MATRIX_ROWS  = 4;       // Change matrix size
parameter MATRIX_COLS  = 64;
parameter CLOCK_PERIOD = 10;      // 10ns = 100MHz
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Vivado not found | Update `$vivado_path` in script |
| Compilation error | Check RTL files exist in `../RTL/` |
| Elaboration fails | Verify testbench module name matches `-top` parameter |
| Tests timeout | Simulation may be stuck; check FSM in waveform |
| All tests fail | Check golden model generation in `generate_test_data()` |

---

## Next Steps

1. ✅ Run testbenches to verify RTL logic
2. 📊 Review waveforms for timing/handshaking
3. 🔧 Integrate PMAU_Streaming into Vivado Block Design
4. 🚀 Implement dequantization IP for FP16 output
5. 📈 Run full system integration tests

---

**Last Updated**: 29.05.2026  
**Version**: 1.0
