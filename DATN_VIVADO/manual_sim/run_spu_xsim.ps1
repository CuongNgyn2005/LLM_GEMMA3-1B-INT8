$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$vivadoBin = "D:\Xlinx\Vivado\2022.2\bin"
if ((-not (Get-Command xvlog -ErrorAction SilentlyContinue)) -and
    (Test-Path (Join-Path $vivadoBin "xvlog.bat"))) {
    $env:PATH = "$vivadoBin;$env:PATH"
}

$required = @("xvlog", "xelab", "xsim")
foreach ($tool in $required) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool was not found in PATH. Run this script from a Vivado Tcl/PowerShell environment."
    }
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    xsim.dir, .Xil, webtalk*.jou, webtalk*.log, xvlog*.log, xelab*.log, xsim*.log, xsim*.jou

xvlog --sv -f .\source_files_spu.f
xelab tb_SPU_Top -debug typical -s spu_top_sim
xsim spu_top_sim -runall
