# Standalone synthesis gate for the SPU memory architecture.
# This avoids waiting for the complete Zynq block design when validating that
# SPU_Local_Memory is inferred as BRAM rather than LUT/register logic.

set origin_dir [file normalize [file dirname [info script]]]
set rtl_dir [file normalize [file join $origin_dir .. .. RTL]]
set report_dir [file join $origin_dir spu_synth_check]
file mkdir $report_dir

create_project -in_memory -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]

read_verilog -sv [file join $rtl_dir Dual_Port_BRAM.v]
read_verilog -sv [file join $rtl_dir SPU_Quantize_Q8_0.v]
read_verilog -sv [file join $rtl_dir SPU_Q8_Scale_Accum.v]
read_verilog -sv [file join $rtl_dir SPU_SiLU_Mul.v]
read_verilog -sv [file join $rtl_dir SPU_RMSNorm.v]
read_verilog -sv [file join $rtl_dir SPU_RoPE.v]
read_verilog -sv [file join $rtl_dir SPU_Softmax.v]
read_verilog -sv [file join $rtl_dir SPU_Local_Memory.v]
read_verilog -sv [file join $rtl_dir SPU_Controller.v]
read_verilog -sv [file join $rtl_dir SPU_Top.v]

synth_design -top SPU_Top -part xczu7ev-ffvc1156-2-e

set bram_cells [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $bram_cells] == 0} {
    error "SPU synthesis did not infer any RAMB primitive."
}

puts "SPU BRAM inference passed: [llength $bram_cells] RAMB primitive(s)."
report_utilization -file [file join $report_dir spu_synth_check_util.rpt]
report_utilization -hierarchical -file [file join $report_dir spu_synth_check_util_hier.rpt]
write_checkpoint -force [file join $report_dir spu_synth_check.dcp]
close_project
