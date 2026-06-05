read_verilog ../../RTL/Dual_Port_BRAM.v
read_verilog ../../RTL/PMAU_Full.v
read_verilog ../../RTL/VPU_Top.v

synth_design -top VPU_Top -part xczu7ev-ffvc1156-2-e
create_clock -period 3.333 -name vpu_clk [get_ports CLK]

report_utilization -file vpu_synth_utilization.rpt
report_timing_summary -file vpu_synth_timing_300mhz.rpt
write_checkpoint -force vpu_synth.dcp
