$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$required = @("xvlog", "xelab", "xsim")
foreach ($tool in $required) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool was not found in PATH. Run this script from a Vivado Tcl/PowerShell environment."
    }
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    xsim.dir, .Xil, webtalk*.jou, webtalk*.log, xvlog*.log, xelab*.log, xsim*.log, xsim*.jou

$sources = Get-Content .\source_files.f | Where-Object { $_ -and -not $_.StartsWith("#") }
xvlog --sv -f .\source_files.f
xelab -L xpm tb_VPU_Top -debug typical -s phase1a_compact_sim
xsim phase1a_compact_sim -runall
