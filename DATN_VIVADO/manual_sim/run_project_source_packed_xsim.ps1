$vivado = "D:\Xlinx\Vivado\2022.2\bin\vivado.bat"
& $vivado -mode batch -source .\run_project_source_packed_xsim.tcl -log project_source_packed_xsim.log
exit $LASTEXITCODE
