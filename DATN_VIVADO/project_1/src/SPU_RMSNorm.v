/*
 * Module      : SPU_RMSNorm
 * Description : Reserved interface for future RMSNorm offload.
 *
 * Target operation:
 *     rms = rsqrt(mean(x^2) + eps)
 *     y[i] = x[i] * rms * weight[i]
 *
 * The two-pass square-sum/rsqrt/scale datapath and SPU_PARAM weight reader are
 * not implemented yet.  This interface therefore reports supported=0 rather
 * than advertising a marker completion as an RMSNorm result.
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
