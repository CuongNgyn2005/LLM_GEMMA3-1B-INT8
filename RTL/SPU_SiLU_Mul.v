/*
 * Module      : SPU_SiLU_Mul
 * Description : Architecture marker for the future FFN activation helper.
 *
 * Target operation:
 *     y = SiLU(gate) * up
 *
 * This phase advertises the module through SPU_Top and gives the scheduler a
 * concrete command boundary.  The numerical streaming datapath will be widened
 * in the next SPU phase; for now the module provides a valid start/done
 * hardware hook so host software no longer treats SiLU/Mul as unsupported RTL.
 */

`timescale 1ns/1ps

module SPU_SiLU_Mul (
    input  wire clk,
    input  wire resetn,
    input  wire start,
    output reg  busy,
    output reg  done,
    output wire supported
);
    assign supported = 1'b1;

    always @(posedge clk) begin
        if (!resetn) begin
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            busy <= 1'b0;
            done <= start;
        end
    end
endmodule
