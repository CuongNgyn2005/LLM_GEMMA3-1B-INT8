/*
 *-----------------------------------------------------------------------------
 * Module      : VPU_Result_Requantizer
 * Description : INT32 accumulator to INT8 result conversion.
 *
 * Requantization is the step that converts a wide INT32 MAC accumulator back to
 * a compact INT8 value.  This first hardware version uses an arithmetic
 * right-shift followed by signed saturation to [-128, 127].  Matrix_Vector_
 * Multiplication uses it as the production writeback path: PMAU keeps the
 * required INT32 internal accumulator, while CPU/DMA only observes compact
 * INT8 final rows from Result BRAM.
 *
 * A later numerically complete version should feed this block with a scale
 * derived from activation/weight/output q8_0 scales instead of a simple shift.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module VPU_Result_Requantizer #(
    parameter integer ACC_WIDTH   = 32,
    parameter integer SHIFT_WIDTH = 5
) (
    input  wire signed [ACC_WIDTH-1:0]        value_in,
    input  wire [SHIFT_WIDTH-1:0]             requant_shift,
    output reg  signed [7:0]                  value_out
);

    reg signed [ACC_WIDTH-1:0] shifted_value;

    always @* begin
        shifted_value = value_in >>> requant_shift;
        if (shifted_value > 32'sd127)
            value_out = 8'sd127;
        else if (shifted_value < -32'sd128)
            value_out = -8'sd128;
        else
            value_out = shifted_value[7:0];
    end

endmodule
