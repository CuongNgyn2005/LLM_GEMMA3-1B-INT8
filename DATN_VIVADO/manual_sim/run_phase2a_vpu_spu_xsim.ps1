$ErrorActionPreference = "Stop"

function Invoke-VivadoStep {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado simulation step failed: $Name (exit code $LASTEXITCODE)"
    }
}

function Assert-XsimLogPassed {
    param(
        [string]$Name
    )

    $logPath = Join-Path (Get-Location) "xsim.log"
    if (-not (Test-Path $logPath)) {
        throw "Vivado simulation step did not produce xsim.log: $Name"
    }

    $logText = Get-Content -Raw $logPath
    if ($logText -match "TEST FAILED" -or
        $logText -match "tests failed" -or
        $logText -match "Fatal:") {
        throw "Vivado simulation reported failure in xsim.log: $Name"
    }
}

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
        throw "$tool was not found in PATH. Checked PATH and $vivadoBin."
    }
}

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    xsim.dir, .Xil, webtalk*.jou, webtalk*.log, xvlog*.log, xelab*.log, xsim*.log, xsim*.jou

Write-Host "[SIM] Running VPU + INT8 result-mode simulation"
Invoke-VivadoStep "xvlog VPU" { xvlog --sv -f .\source_files.f }
Invoke-VivadoStep "xelab VPU" { xelab -L xpm tb_VPU_Top -debug typical -s phase2a_vpu_int8_sim }
Invoke-VivadoStep "xsim VPU" { xsim phase2a_vpu_int8_sim -runall }
Assert-XsimLogPassed "VPU"

Write-Host "[SIM] Running SPU framework simulation"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    xsim.dir, .Xil, webtalk*.jou, webtalk*.log, xvlog*.log, xelab*.log, xsim*.log, xsim*.jou
Invoke-VivadoStep "xvlog SPU" { xvlog --sv -f .\source_files_spu.f }
Invoke-VivadoStep "xelab SPU" { xelab tb_SPU_Top -debug typical -s phase2a_spu_sim }
Invoke-VivadoStep "xsim SPU" { xsim phase2a_spu_sim -runall }
Assert-XsimLogPassed "SPU"
