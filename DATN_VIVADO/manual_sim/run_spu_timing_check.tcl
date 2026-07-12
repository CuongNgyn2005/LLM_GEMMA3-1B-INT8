# Place-and-route timing gate for the SPU quantizer at the ZCU104 PL clock rate.
# The full SoC run reports clk_pl_0 = 5.333 ns (187.5 MHz).  The wrapper avoids
# making SPU_Top's internal AXI ports physical top-level device I/O.

set origin_dir [file normalize [file dirname [info script]]]
set rtl_dir [file normalize [file join $origin_dir .. .. RTL]]
set report_dir [file join $origin_dir spu_timing_check]
file mkdir $report_dir

create_project -in_memory -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]

read_verilog -sv [file join $rtl_dir SPU_Quantize_Q8_0.v]
read_verilog -sv [file join $origin_dir spu_quant_timing_wrapper.v]

synth_design -top spu_quant_timing_wrapper -part xczu7ev-ffvc1156-2-e
create_clock -name clk_pl_0 -period 5.333 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -delay_type max -max_paths 10 -warn_on_violation \
    -file [file join $report_dir spu_timing_summary_routed.rpt]
report_utilization -file [file join $report_dir spu_utilization_routed.rpt]
write_checkpoint -force [file join $report_dir spu_timing_check_routed.dcp]

set worst_path [get_timing_paths -delay_type max -max_paths 1]
set wns [get_property SLACK $worst_path]
puts "SPU timing WNS at 187.5 MHz: $wns ns"
if {$wns < 0.0} {
    error "SPU timing check failed: WNS is $wns ns"
}

close_project
