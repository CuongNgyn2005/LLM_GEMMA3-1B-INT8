read_verilog ../../RTL/PMAU_Streaming.v
read_verilog ../../RTL/Matrix_Vector_Multiplication.v
read_verilog ../../RTL/MY_IP.v
read_verilog ../../RTL/VPU_Top.v

synth_design -top VPU_Top -part xczu7ev-ffvc1156-2-e -mode out_of_context
create_clock -period 3.333 -name s00_axi_aclk [get_ports s00_axi_aclk]

report_utilization -file axi_full_synth_utilization.rpt
report_timing_summary -file axi_full_synth_timing_300mhz.rpt
write_checkpoint -force axi_full_synth.dcp
