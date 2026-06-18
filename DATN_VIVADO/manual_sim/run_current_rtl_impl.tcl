set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ".." ".."]]
set project_dir [file join $script_dir "current_rtl_impl_project"]
set part_name "xczu7ev-ffvc1156-2-e"

create_project current_rtl_impl $project_dir -part $part_name -force

add_files [file join $repo_root "RTL" "Dual_Port_BRAM.v"]
add_files [file join $repo_root "RTL" "PMAU_Full.v"]
add_files [file join $repo_root "RTL" "Matrix_Vector_Multiplication.v"]
add_files [file join $repo_root "RTL" "AXI4_Mapping.v"]
add_files [file join $repo_root "RTL" "MY_IP.v"]
add_files [file join $repo_root "RTL" "VPU_Top.v"]

add_files [file join $repo_root "DATN_VIVADO" "project_1" "project_1.srcs" "sources_1" "ip" "mult_gen_0" "mult_gen_0.xci"]

generate_target all [get_ips mult_gen_0]
update_compile_order -fileset sources_1

synth_design -top VPU_Top -part $part_name -mode out_of_context
create_clock -period 3.333 -name s00_axi_aclk [get_ports s00_axi_aclk]

report_utilization -file [file join $script_dir "current_rtl_synth_utilization.rpt"]
report_utilization -hierarchical -hierarchical_depth 7 \
    -file [file join $script_dir "current_rtl_synth_hier_utilization.rpt"]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $script_dir "current_rtl_synth_timing_300mhz.rpt"]

opt_design
place_design
phys_opt_design
route_design
phys_opt_design

report_utilization -file [file join $script_dir "current_rtl_impl_utilization.rpt"]
report_utilization -hierarchical -hierarchical_depth 7 \
    -file [file join $script_dir "current_rtl_impl_hier_utilization.rpt"]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $script_dir "current_rtl_impl_timing_300mhz.rpt"]
write_checkpoint -force [file join $script_dir "current_rtl_impl_route.dcp"]

close_project
