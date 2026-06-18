set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ".." ".."]]
set rtl_dir [file join $root_dir "RTL"]

cd $script_dir

exec xvlog -work xsim_dma_axis_work \
    [file join $script_dir "mult_gen_0_stub.v"] \
    [file join $rtl_dir "Dual_Port_BRAM.v"] \
    [file join $rtl_dir "PMAU_Full.v"] \
    [file join $rtl_dir "Matrix_Vector_Multiplication.v"] \
    [file join $rtl_dir "AXI4_Mapping.v"] \
    [file join $rtl_dir "MY_IP.v"] \
    [file join $rtl_dir "VPU_Top.v"] \
    [file join $script_dir "tb_vpu_dma_axis.v"] \
    > [file join $script_dir "dma_axis_xvlog.log"] 2>@1

exec xelab xsim_dma_axis_work.tb_vpu_dma_axis -s tb_vpu_dma_axis \
    > [file join $script_dir "dma_axis_xelab.log"] 2>@1

exec xsim tb_vpu_dma_axis -runall \
    > [file join $script_dir "dma_axis_xsim.log"] 2>@1
