/*
 * Module      : SPU_Softmax
 * Description : Architecture marker for future attention softmax offload.
 *
 * Target operation:
 *     softmax(x) = exp(x - max(x)) / sum(exp(x - max(x)))
 *
 * This phase advertises Softmax through REG_SPU_CAPS and gives the SPU
 * scheduler a concrete command boundary.  The later numerical datapath will
 * add the multi-pass max/sum/normalize flow, exp approximation, scratch
 * storage, and attention-path integration.
 */

`timescale 1ns/1ps

module SPU_Softmax (
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
