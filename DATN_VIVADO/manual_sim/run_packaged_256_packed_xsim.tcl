set script_dir [file normalize [file dirname [info script]]]
set vivado_root [file normalize [file join $script_dir ".." "project_1"]]
set packaged_src [file join $vivado_root "project_1.gen" "sources_1" "bd" "SoC" "ipshared" "dc8d" "src"]
set project_dir [file join $script_dir "packaged_256_packed_xsim_project"]
set part_name "xczu7ev-ffvc1156-2-e"

create_project packaged_256_packed_xsim $project_dir -part $part_name -force

add_files [file join $packaged_src "Dual_Port_BRAM.v"]
add_files [file join $packaged_src "PMAU_Full.v"]
add_files [file join $packaged_src "Matrix_Vector_Multiplication.v"]
add_files [file join $script_dir "tb_packed_q8_core.v"]
add_files [file join $script_dir "tb_packed_q8_core_256.v"]
add_files [file join $vivado_root "project_1.srcs" "sources_1" "ip" "mult_gen_0" "mult_gen_0.xci"]

generate_target all [get_ips mult_gen_0]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property top tb_packed_q8_core_256 [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {20 us} -objects [get_filesets sim_1]

launch_simulation
close_sim
close_project
