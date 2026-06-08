param(
    [string]$VivadoBin = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Find-Vivado {
    param([string]$RequestedBin)

    if ($RequestedBin -ne "") {
        $vivadoBat = Join-Path $RequestedBin "vivado.bat"
        $vivadoExe = Join-Path $RequestedBin "vivado.exe"
        if (Test-Path $vivadoBat) { return $vivadoBat }
        if (Test-Path $vivadoExe) { return $vivadoExe }
        throw "VivadoBin '$RequestedBin' does not contain vivado.bat or vivado.exe."
    }

    $cmd = Get-Command vivado -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($base in @("C:\Xilinx\Vivado", "D:\Xilinx\Vivado", "D:\Xlinx\Vivado", "E:\Xilinx\Vivado")) {
        if (Test-Path $base) {
            $bins = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "bin" }
            foreach ($bin in $bins) {
                $vivadoBat = Join-Path $bin "vivado.bat"
                $vivadoExe = Join-Path $bin "vivado.exe"
                if (Test-Path $vivadoBat) { return $vivadoBat }
                if (Test-Path $vivadoExe) { return $vivadoExe }
            }
        }
    }

    throw "Vivado was not found. Pass -VivadoBin C:\Xilinx\Vivado\<version>\bin."
}

$vivado = Find-Vivado $VivadoBin
& $vivado -mode batch -source .\run_dsp_vivado_synth.tcl -nojournal -log .\dsp_vivado_synth.log
if ($LASTEXITCODE -ne 0) {
    throw "Vivado synthesis failed with exit code $LASTEXITCODE"
}

Write-Host "Vivado synthesis reports:"
Write-Host "  $PSScriptRoot\dsp_vpu_synth_utilization.rpt"
Write-Host "  $PSScriptRoot\dsp_vpu_synth_dsp_utilization.rpt"
Write-Host "  $PSScriptRoot\dsp_vpu_synth_timing.rpt"
