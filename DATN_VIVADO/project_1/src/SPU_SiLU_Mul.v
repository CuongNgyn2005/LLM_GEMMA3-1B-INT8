/*
 * Module      : SPU_SiLU_Mul
 * Description : Reserved interface for the future FFN activation helper.
 *
 * Target operation:
 *     y = SiLU(gate) * up
 *
 * The numerical streaming datapath has not been implemented yet.  Keep this
 * named interface in the hierarchy, but report supported=0 so software cannot
 * mistake a start/done marker for a computed SiLU(gate)*up payload.
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
    assign supported = 1'b0;

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
