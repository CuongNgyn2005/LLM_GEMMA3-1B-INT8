param(
    [string]$VivadoBin = "D:\Xlinx\Vivado\2022.2\bin"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$vivado = Join-Path $VivadoBin "vivado.bat"
if (!(Test-Path $vivado)) {
    throw "Vivado was not found at '$vivado'."
}

& $vivado -mode batch -source .\run_vpu_top_xsim.tcl -nojournal -log .\vpu_top_xsim.log
if ($LASTEXITCODE -ne 0) {
    throw "VPU top-level XSim failed with exit code $LASTEXITCODE"
}

$log = Get-Content -Raw .\vpu_top_xsim.log
if (($log -notmatch '\[TB\] pass_count=149 fail_count=0') -or
    ($log -notmatch '\[TB\] AXI4-Full VPU TEST PASSED') -or
    ($log -match '\[TB\]\[FAIL\]') -or
    ($log -match '\[TB\] AXI4-Full VPU TEST FAILED')) {
    throw "VPU top-level XSim completed but functional checks failed. See vpu_top_xsim.log."
}
