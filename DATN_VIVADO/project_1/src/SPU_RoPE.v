/*
 * Module      : SPU_RoPE
 * Description : Architecture marker for future rotary embedding offload.
 *
 * Target operation:
 *     rotate Q/K pairs by position-dependent sin/cos coefficients.
 *
 * This phase advertises RoPE through REG_SPU_CAPS and gives the SPU scheduler
 * a concrete command boundary.  The later numerical datapath will add the
 * sin/cos LUT, position/head address generation, and Gemma3-specific RoPE
 * parameter handling that matches llama.cpp.
 */

`timescale 1ns/1ps

module SPU_RoPE (
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
