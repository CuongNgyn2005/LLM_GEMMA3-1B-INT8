param(
    [string]$VivadoBin = "D:\Xlinx\Vivado\2022.2\bin"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$vivado = Join-Path $VivadoBin "vivado.bat"
if (!(Test-Path $vivado)) {
    throw "Vivado was not found at '$vivado'."
}

& $vivado -mode batch -source .\run_packed_q8_xsim.tcl -nojournal -log .\packed_q8_xsim.log
if ($LASTEXITCODE -ne 0) {
    throw "Packed-Q8 XSim failed with exit code $LASTEXITCODE"
}

$log = Get-Content -Raw .\packed_q8_xsim.log
if (($log -notmatch '\[PACKED_Q8\] PASS') -or
    ($log -notmatch '\[SUMMARY\] pass_cases=3 fail_cases=0') -or
    ($log -match '\[FAIL\]') -or
    ($log -match '\[PACKED_Q8\] FAIL')) {
    throw "Packed-Q8 XSim completed but functional checks failed. See packed_q8_xsim.log."
}
