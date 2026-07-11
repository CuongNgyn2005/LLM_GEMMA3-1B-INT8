/*
 * Module      : SPU_RoPE
 * Description : Reserved interface for future rotary embedding offload.
 *
 * Target operation:
 *     rotate Q/K pairs by position-dependent sin/cos coefficients.
 *
 * The sin/cos LUT, position/head address generation, and Gemma3-specific RoPE
 * parameter handling are not implemented yet.  This interface reports
 * supported=0 so command completion cannot be interpreted as rotated data.
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
