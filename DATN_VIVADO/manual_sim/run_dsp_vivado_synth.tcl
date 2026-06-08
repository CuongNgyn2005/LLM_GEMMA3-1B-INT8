set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ".." ".."]]
set project_dir [file join $script_dir "dsp_vpu_synth_project"]
set part_name "xczu7ev-ffvc1156-2-e"

create_project dsp_vpu_synth $project_dir -part $part_name -force

add_files [file join $repo_root "DATN_VIVADO" "src" "Dual_Port_BRAM.v"]
add_files [file join $repo_root "DATN_VIVADO" "src" "PMAU_Full.v"]
add_files [file join $repo_root "DATN_VIVADO" "src" "Matrix_Vector_Multiplication.v"]
add_files [file join $repo_root "DATN_VIVADO" "src" "AXI4_Mapping.v"]
add_files [file join $repo_root "DATN_VIVADO" "src" "MY_IP.v"]
add_files [file join $repo_root "DATN_VIVADO" "src" "VPU_Top.v"]

add_files [file join $repo_root "DATN_VIVADO" "project_1" "project_1.srcs" "sources_1" "ip" "mult_gen_0" "mult_gen_0.xci"]
add_files [file join $repo_root "DATN_VIVADO" "project_1" "project_1.srcs" "sources_1" "ip" "ila_0" "ila_0.xci"]

generate_target all [get_ips mult_gen_0]
generate_target all [get_ips ila_0]
update_compile_order -fileset sources_1

synth_design -top VPU_Top -part $part_name

report_utilization -file [file join $script_dir "dsp_vpu_synth_utilization.rpt"]
report_timing_summary -file [file join $script_dir "dsp_vpu_synth_timing.rpt"]
report_utilization -hierarchical -hierarchical_depth 6 \
    -file [file join $script_dir "dsp_vpu_synth_hier_utilization.rpt"]

set dsp_fh [open [file join $script_dir "dsp_vpu_synth_dsp_utilization.rpt"] "w"]
set dsp_cells [get_cells -hierarchical -filter {REF_NAME == DSP48E2}]
puts $dsp_fh "DSP48E2 instance count: [llength $dsp_cells]"
foreach dsp_cell $dsp_cells {
    puts $dsp_fh $dsp_cell
}
close $dsp_fh
write_checkpoint -force [file join $script_dir "dsp_vpu_synth.dcp"]

set util_lines [report_utilization -return_string]
set fh [open [file join $script_dir "dsp_vpu_synth_summary.txt"] "w"]
puts $fh $util_lines
close $fh
