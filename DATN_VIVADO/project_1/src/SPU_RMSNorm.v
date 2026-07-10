/*
 * Module      : SPU_RMSNorm
 * Description : Architecture marker for future RMSNorm offload.
 *
 * Target operation:
 *     rms = rsqrt(mean(x^2) + eps)
 *     y[i] = x[i] * rms * weight[i]
 *
 * This phase advertises RMSNorm through REG_SPU_CAPS and gives the SPU
 * scheduler a concrete command boundary.  The later numerical datapath will
 * add the two-pass fixed-point square-sum/rsqrt/scale flow with norm weights
 * read from SPU_PARAM.
 */

`timescale 1ns/1ps

module SPU_RMSNorm (
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
