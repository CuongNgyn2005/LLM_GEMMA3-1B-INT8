$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Remove-Item -Recurse -Force .\work_dsp -ErrorAction SilentlyContinue
Remove-Item -Force .\dsp_matmul_sim_results.csv, .\dsp_matmul_modelsim_compile.log, .\dsp_matmul_modelsim_sim.log, .\dsp_matmul_modelsim_transcript.log -ErrorAction SilentlyContinue

$vlib = "E:\altera\13.0sp1\modelsim_ase\win32aloem\vlib.exe"
$vlog = "E:\altera\13.0sp1\modelsim_ase\win32aloem\vlog.exe"
$vsim = "E:\altera\13.0sp1\modelsim_ase\win32aloem\vsim.exe"

if (-not (Test-Path $vlog)) {
    $vlib = "vlib"
    $vlog = "vlog"
    $vsim = "vsim"
}

& $vlib work_dsp
& $vlog -sv -work work_dsp `
    .\mult_gen_0_stub.v `
    ..\src\Dual_Port_BRAM.v `
    ..\src\PMAU_Full.v `
    ..\src\Matrix_Vector_Multiplication.v `
    .\tb_matmul_dsp_core.v 2>&1 | Tee-Object -FilePath .\dsp_matmul_modelsim_compile.log
if ($LASTEXITCODE -ne 0) { throw "vlog failed" }

$vsimCmd = '"' + $vsim + '" -c work_dsp.tb_matmul_dsp_core -l .\dsp_matmul_modelsim_transcript.log -do "run -all; quit -f" 2>&1'
& cmd.exe /d /s /c $vsimCmd | Tee-Object -FilePath .\dsp_matmul_modelsim_sim.log
$simExit = $LASTEXITCODE
if ((-not (Test-Path .\dsp_matmul_sim_results.csv)) -or ($simExit -ne 0 -and -not (Test-Path .\dsp_matmul_sim_results.csv))) {
    throw "Simulation did not produce dsp_matmul_sim_results.csv"
}

Write-Host "DSP matmul simulation result: $PSScriptRoot\dsp_matmul_sim_results.csv"
