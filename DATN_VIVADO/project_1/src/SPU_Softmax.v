/*
 * Module      : SPU_Softmax
 * Description : Reserved interface for future attention softmax offload.
 *
 * Target operation:
 *     softmax(x) = exp(x - max(x)) / sum(exp(x - max(x)))
 *
 * The multi-pass max/sum/normalize flow, exp approximation, scratch storage,
 * and attention-path integration are not implemented yet.  This interface
 * reports supported=0 so a marker completion is never treated as Softmax data.
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
