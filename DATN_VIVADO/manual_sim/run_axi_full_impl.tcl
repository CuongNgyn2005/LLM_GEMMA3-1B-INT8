read_verilog ../../RTL/Dual_Port_BRAM.v
read_verilog ../../RTL/PMAU_Full.v
read_verilog ../../RTL/Matrix_Vector_Multiplication.v
read_verilog ../../RTL/AXI4_Mapping.v
read_verilog ../../RTL/MY_IP.v
read_verilog ../../RTL/VPU_Top.v

synth_design -top VPU_Top -part xczu7ev-ffvc1156-2-e -mode out_of_context
create_clock -period 3.333 -name s00_axi_aclk [get_ports s00_axi_aclk]

opt_design
place_design
route_design

report_utilization -file axi_full_impl_utilization.rpt
report_timing_summary -file axi_full_impl_timing_300mhz.rpt
write_checkpoint -force axi_full_impl_route.dcp
