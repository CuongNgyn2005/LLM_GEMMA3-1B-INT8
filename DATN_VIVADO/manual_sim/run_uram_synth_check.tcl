set origin_dir [file normalize [file dirname [info script]]]
set report_dir [file join $origin_dir uram_synth_check]
file mkdir $report_dir

create_project -in_memory -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]

read_verilog -sv [file normalize [file join $origin_dir .. .. RTL Dual_Port_BRAM.v]]
read_verilog -sv [file join $origin_dir uram_synth_check.v]

synth_design -top uram_synth_check -part xczu7ev-ffvc1156-2-e

report_utilization -file [file join $report_dir uram_synth_check_util.rpt]
report_utilization -hierarchical -file [file join $report_dir uram_synth_check_util_hier.rpt]
write_checkpoint -force [file join $report_dir uram_synth_check.dcp]

close_project
