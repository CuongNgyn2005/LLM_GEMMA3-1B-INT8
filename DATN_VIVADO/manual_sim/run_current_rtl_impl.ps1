param(
    [string]$VivadoBin = "D:\Xlinx\Vivado\2022.2\bin"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$vivado = Join-Path $VivadoBin "vivado.bat"
if (!(Test-Path $vivado)) {
    throw "Vivado was not found at '$vivado'."
}

& $vivado -mode batch -source .\run_current_rtl_impl.tcl -nojournal -log .\current_rtl_impl.log
if ($LASTEXITCODE -ne 0) {
    throw "Current RTL implementation failed with exit code $LASTEXITCODE"
}
