$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$simDir = Join-Path $repo "DATN_VIVADO\project_1\project_1.sim\sim_1\behav\xsim"
$manual = Join-Path $repo "DATN_VIVADO\manual_sim"
$env:PATH = "D:\Xlinx\Vivado\2022.2\bin;" + $env:PATH

Set-Location $simDir

xvlog --relax --work xil_defaultlib -log "$manual\mult_gen_latency_xvlog.log" "$manual\tb_mult_gen_latency.v"
if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }

xvhdl --relax --work xil_defaultlib -log "$manual\mult_gen_latency_xvhdl.log" "..\..\..\..\project_1.gen\sources_1\ip\mult_gen_0\sim\mult_gen_0.vhd"
if ($LASTEXITCODE -ne 0) { throw "xvhdl failed" }

xelab --debug typical --relax --mt 2 `
    -L xil_defaultlib `
    -L xbip_utils_v3_0_10 `
    -L xbip_pipe_v3_0_6 `
    -L xbip_bram18k_v3_0_6 `
    -L mult_gen_v12_0_18 `
    -L unisims_ver `
    -L unimacro_ver `
    -L secureip `
    -L xpm `
    --snapshot tb_mult_gen_latency_behav `
    xil_defaultlib.tb_mult_gen_latency `
    -log "$manual\mult_gen_latency_xelab.log"
if ($LASTEXITCODE -ne 0) { throw "xelab failed" }

$tcl = Join-Path $manual "mult_gen_latency_run.tcl"
Set-Content -Path $tcl -Value "run -all`nquit`n"
$tclXsim = $tcl -replace "\\", "/"
xsim tb_mult_gen_latency_behav -tclbatch "$tclXsim" -log "$manual\mult_gen_latency_xsim.log"
if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
