`ifndef TB_SPU_STREAM8_COMPAT_V
`define TB_SPU_STREAM8_COMPAT_V
`include "tb_SPU_VPU_Stream8.v"
`timescale 1ns/1ps
// Retain the earlier top name; the checked implementation now matches the RTL filename.
module tb_SPU_Stream8;
    wire completed;
    tb_SPU_VPU_Stream8 testbench(.completed(completed));
endmodule
`endif