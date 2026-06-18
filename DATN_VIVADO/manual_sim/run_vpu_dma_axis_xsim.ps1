param(
    [string]$VivadoBin = "D:\Xlinx\Vivado\2022.2\bin"
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Rtl = Join-Path $Root "RTL"
$Tb = Join-Path $PSScriptRoot "tb_vpu_dma_axis.v"
$Work = Join-Path $PSScriptRoot "xsim_dma_axis_work"
$LogPrefix = Join-Path $PSScriptRoot "dma_axis"

New-Item -ItemType Directory -Force -Path $Work | Out-Null
Push-Location $PSScriptRoot
try {
    & (Join-Path $VivadoBin "xvlog.bat") -work xsim_dma_axis_work `
        (Join-Path $PSScriptRoot "mult_gen_0_stub.v") `
        (Join-Path $Rtl "Dual_Port_BRAM.v") `
        (Join-Path $Rtl "PMAU_Full.v") `
        (Join-Path $Rtl "Matrix_Vector_Multiplication.v") `
        (Join-Path $Rtl "AXI4_Mapping.v") `
        (Join-Path $Rtl "MY_IP.v") `
        (Join-Path $Rtl "VPU_Top.v") `
        $Tb *>&1 | Tee-Object -FilePath "${LogPrefix}_xvlog.log"

    & (Join-Path $VivadoBin "xelab.bat") `
        xsim_dma_axis_work.tb_vpu_dma_axis -s tb_vpu_dma_axis *>&1 | Tee-Object -FilePath "${LogPrefix}_xelab.log"

    & (Join-Path $VivadoBin "xsim.bat") `
        tb_vpu_dma_axis -runall *>&1 | Tee-Object -FilePath "${LogPrefix}_xsim.log"
} finally {
    Pop-Location
}
