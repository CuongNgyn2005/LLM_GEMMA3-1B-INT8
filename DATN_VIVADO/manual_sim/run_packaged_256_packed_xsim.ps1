param(
    [string]$VivadoBin = "D:\Xlinx\Vivado\2022.2\bin"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$vivado = Join-Path $VivadoBin "vivado.bat"
if (!(Test-Path $vivado)) {
    throw "Vivado was not found at '$vivado'."
}

& $vivado -mode batch -source .\run_packaged_256_packed_xsim.tcl -nojournal -log .\packaged_256_packed_xsim.log
if ($LASTEXITCODE -ne 0) {
    throw "Packaged MAX_COL_BEATS=256 XSim failed with exit code $LASTEXITCODE"
}

$log = Get-Content -Raw .\packaged_256_packed_xsim.log
if (($log -notmatch '\[PACKED_Q8\] PASS') -or
    ($log -match '\[PACKED_Q8\] FAIL')) {
    throw "Packaged MAX_COL_BEATS=256 XSim completed but functional checks failed."
}
