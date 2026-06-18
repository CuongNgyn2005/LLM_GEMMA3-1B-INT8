set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ".." ".."]]
set project_dir [file join $script_dir "vpu_top_xsim_project"]
set part_name "xczu7ev-ffvc1156-2-e"

create_project vpu_top_xsim $project_dir -part $part_name -force

add_files [file join $repo_root "RTL" "Dual_Port_BRAM.v"]
add_files [file join $repo_root "RTL" "PMAU_Full.v"]
add_files [file join $repo_root "RTL" "Matrix_Vector_Multiplication.v"]
add_files [file join $repo_root "RTL" "AXI4_Mapping.v"]
add_files [file join $repo_root "RTL" "MY_IP.v"]
add_files [file join $repo_root "RTL" "VPU_Top.v"]
add_files [file join $repo_root "TESTBENCH" "tb_VPU_Top.v"]
add_files [file join $repo_root "DATN_VIVADO" "project_1" "project_1.srcs" "sources_1" "ip" "mult_gen_0" "mult_gen_0.xci"]

generate_target all [get_ips mult_gen_0]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property top tb_VPU_Top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {200 us} -objects [get_filesets sim_1]

launch_simulation
close_sim
close_project
