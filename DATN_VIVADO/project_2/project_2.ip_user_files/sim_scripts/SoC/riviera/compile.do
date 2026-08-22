vlib work
vlib riviera

vlib riviera/xilinx_vip
vlib riviera/xpm
vlib riviera/axi_infrastructure_v1_1_0
vlib riviera/axi_vip_v1_1_13
vlib riviera/zynq_ultra_ps_e_vip_v1_0_13
vlib riviera/xil_defaultlib
vlib riviera/xbip_utils_v3_0_10
vlib riviera/xbip_pipe_v3_0_6
vlib riviera/xbip_bram18k_v3_0_6
vlib riviera/mult_gen_v12_0_18
vlib riviera/xlconstant_v1_1_7
vlib riviera/lib_cdc_v1_0_2
vlib riviera/proc_sys_reset_v5_0_13
vlib riviera/smartconnect_v1_0
vlib riviera/axi_register_slice_v2_1_27

vmap xilinx_vip riviera/xilinx_vip
vmap xpm riviera/xpm
vmap axi_infrastructure_v1_1_0 riviera/axi_infrastructure_v1_1_0
vmap axi_vip_v1_1_13 riviera/axi_vip_v1_1_13
vmap zynq_ultra_ps_e_vip_v1_0_13 riviera/zynq_ultra_ps_e_vip_v1_0_13
vmap xil_defaultlib riviera/xil_defaultlib
vmap xbip_utils_v3_0_10 riviera/xbip_utils_v3_0_10
vmap xbip_pipe_v3_0_6 riviera/xbip_pipe_v3_0_6
vmap xbip_bram18k_v3_0_6 riviera/xbip_bram18k_v3_0_6
vmap mult_gen_v12_0_18 riviera/mult_gen_v12_0_18
vmap xlconstant_v1_1_7 riviera/xlconstant_v1_1_7
vmap lib_cdc_v1_0_2 riviera/lib_cdc_v1_0_2
vmap proc_sys_reset_v5_0_13 riviera/proc_sys_reset_v5_0_13
vmap smartconnect_v1_0 riviera/smartconnect_v1_0
vmap axi_register_slice_v2_1_27 riviera/axi_register_slice_v2_1_27

vlog -work xilinx_vip  -sv2k12 "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/axi4stream_vip_axi4streampc.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/axi_vip_axi4pc.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/xil_common_vip_pkg.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/axi4stream_vip_pkg.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/axi_vip_pkg.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/axi4stream_vip_if.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/axi_vip_if.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/clk_vip_if.sv" \
"D:/Xilinx/Vivado/2022.2/data/xilinx_vip/hdl/rst_vip_if.sv" \

vlog -work xpm  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"D:/Xilinx/Vivado/2022.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \

vcom -work xpm -93  \
"D:/Xilinx/Vivado/2022.2/data/ip/xpm/xpm_VCOMP.vhd" \

vlog -work axi_infrastructure_v1_1_0  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl/axi_infrastructure_v1_1_vl_rfs.v" \

vlog -work axi_vip_v1_1_13  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/ffc2/hdl/axi_vip_v1_1_vl_rfs.sv" \

vlog -work zynq_ultra_ps_e_vip_v1_0_13  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl/zynq_ultra_ps_e_vip_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_zynq_ultra_ps_e_0_0/sim/SoC_zynq_ultra_ps_e_0_0_vip_wrapper.v" \

vcom -work xbip_utils_v3_0_10 -93  \
"../../../../project_2.gen/sources_1/bd/SoC/ip/SoC_VPU_Top_0_0/project_2.srcs/sources_1/ip/mult_gen_0/hdl/xbip_utils_v3_0_vh_rfs.vhd" \

vcom -work xbip_pipe_v3_0_6 -93  \
"../../../../project_2.gen/sources_1/bd/SoC/ip/SoC_VPU_Top_0_0/project_2.srcs/sources_1/ip/mult_gen_0/hdl/xbip_pipe_v3_0_vh_rfs.vhd" \

vcom -work xbip_bram18k_v3_0_6 -93  \
"../../../../project_2.gen/sources_1/bd/SoC/ip/SoC_VPU_Top_0_0/project_2.srcs/sources_1/ip/mult_gen_0/hdl/xbip_bram18k_v3_0_vh_rfs.vhd" \

vcom -work mult_gen_v12_0_18 -93  \
"../../../../project_2.gen/sources_1/bd/SoC/ip/SoC_VPU_Top_0_0/project_2.srcs/sources_1/ip/mult_gen_0/hdl/mult_gen_v12_0_vh_rfs.vhd" \

vcom -work xil_defaultlib -93  \
"../../../bd/SoC/ip/SoC_VPU_Top_0_0/project_2.srcs/sources_1/ip/mult_gen_0/sim/mult_gen_0.vhd" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ipshared/d79d/src/AXI4_Mapping.v" \
"../../../bd/SoC/ipshared/d79d/src/Dual_Port_BRAM.v" \
"../../../bd/SoC/ipshared/d79d/src/MY_IP.v" \
"../../../bd/SoC/ipshared/d79d/src/Matrix_Vector_Multiplication.v" \
"../../../bd/SoC/ipshared/d79d/src/PMAU_Full.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_Controller.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_Local_Memory.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_Q8_Scale_Accum.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_Quantize_Q8_0.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_RMSInv_Engine.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_RMSNorm.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_RoPE.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_SiLU_Mul.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_Softmax.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_Top.v" \
"../../../bd/SoC/ipshared/d79d/src/SPU_VPU_Stream8.v" \
"../../../bd/SoC/ipshared/d79d/src/VPU_Result_Requantizer.v" \
"../../../bd/SoC/ipshared/d79d/src/VPU_Top.v" \
"../../../bd/SoC/ip/SoC_VPU_Top_0_0/sim/SoC_VPU_Top_0_0.v" \

vlog -work xlconstant_v1_1_7  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/badb/hdl/xlconstant_v1_1_vl_rfs.v" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_0/sim/bd_d7be_one_0.v" \

vcom -work lib_cdc_v1_0_2 -93  \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/ef1e/hdl/lib_cdc_v1_0_rfs.vhd" \

vcom -work proc_sys_reset_v5_0_13 -93  \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/8842/hdl/proc_sys_reset_v5_0_vh_rfs.vhd" \

vcom -work xil_defaultlib -93  \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_1/sim/bd_d7be_psr_aclk_0.vhd" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/sc_util_v1_0_vl_rfs.sv" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/c012/hdl/sc_switchboard_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_2/sim/bd_d7be_arsw_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_3/sim/bd_d7be_rsw_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_4/sim/bd_d7be_awsw_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_5/sim/bd_d7be_wsw_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_6/sim/bd_d7be_bsw_0.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/be1f/hdl/sc_mmu_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_7/sim/bd_d7be_s00mmu_0.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/4fd2/hdl/sc_transaction_regulator_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_8/sim/bd_d7be_s00tr_0.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/637d/hdl/sc_si_converter_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_9/sim/bd_d7be_s00sic_0.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/f38e/hdl/sc_axi2sc_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_10/sim/bd_d7be_s00a2s_0.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/sc_node_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_11/sim/bd_d7be_sarn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_12/sim/bd_d7be_srn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_13/sim/bd_d7be_sawn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_14/sim/bd_d7be_swn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_15/sim/bd_d7be_sbn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_16/sim/bd_d7be_s01mmu_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_17/sim/bd_d7be_s01tr_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_18/sim/bd_d7be_s01sic_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_19/sim/bd_d7be_s01a2s_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_20/sim/bd_d7be_sarn_1.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_21/sim/bd_d7be_srn_1.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_22/sim/bd_d7be_sawn_1.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_23/sim/bd_d7be_swn_1.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_24/sim/bd_d7be_sbn_1.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/9cc5/hdl/sc_sc2axi_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_25/sim/bd_d7be_m00s2a_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_26/sim/bd_d7be_m00arn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_27/sim/bd_d7be_m00rn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_28/sim/bd_d7be_m00awn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_29/sim/bd_d7be_m00wn_0.sv" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_30/sim/bd_d7be_m00bn_0.sv" \

vlog -work smartconnect_v1_0  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/6bba/hdl/sc_exit_v1_0_vl_rfs.sv" \

vlog -work xil_defaultlib  -sv2k12 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/ip/ip_31/sim/bd_d7be_m00e_0.sv" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/bd_0/sim/bd_d7be.v" \

vlog -work axi_register_slice_v2_1_27  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b4/hdl/axi_register_slice_v2_1_vl_rfs.v" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/ip/SoC_axi_smc_0/sim/SoC_axi_smc_0.v" \

vcom -work xil_defaultlib -93  \
"../../../bd/SoC/ip/SoC_rst_ps8_0_100M_0/sim/SoC_rst_ps8_0_100M_0.vhd" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/ec67/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/abef/hdl" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/f0b6/hdl/verilog" "+incdir+../../../../project_2.gen/sources_1/bd/SoC/ipshared/66be/hdl/verilog" "+incdir+D:/Xilinx/Vivado/2022.2/data/xilinx_vip/include" \
"../../../bd/SoC/sim/SoC.v" \

vlog -work xil_defaultlib \
"glbl.v"

