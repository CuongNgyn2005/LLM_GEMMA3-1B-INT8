/*
 *-----------------------------------------------------------------------------
 * Module      : Dual_Port_BRAM
 * Description : Project-generic true dual-port block RAM wrapper.
 *
 * This module is a cleaned-up version of the course BRAM block, adapted for the
 * current AXI4-Full INT8 VPU project:
 * - parameterized address/data width;
 * - byte write strobes for 128-bit AXI beats and 32-bit result words;
 * - synchronous read on both ports;
 * - read-first behavior on same-port read/write.
 *
 * The block is not an AXI slave by itself.  AXI address decoding and burst
 * handling stay in MY_IP; this module only provides local storage for tensor,
 * weight, and result tiles.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module Dual_Port_BRAM #(
    parameter integer AWIDTH = 8,
    parameter integer DWIDTH = 128,
    parameter integer OUTPUT_REG = 0
) (
    input  wire                         clka,
    input  wire                         ena,
    input  wire [(DWIDTH/8)-1:0]        wea,
    input  wire [AWIDTH-1:0]            addra,
    input  wire [DWIDTH-1:0]            dina,
    output wire [DWIDTH-1:0]            douta,

    input  wire                         clkb,
    input  wire                         enb,
    input  wire [(DWIDTH/8)-1:0]        web,
    input  wire [AWIDTH-1:0]            addrb,
    input  wire [DWIDTH-1:0]            dinb,
    output wire [DWIDTH-1:0]            doutb
);

    localparam integer BYTE_COUNT = DWIDTH / 8;
    localparam integer DEPTH      = (1 << AWIDTH);

    (* ram_style = "block" *) reg [DWIDTH-1:0] mem [0:DEPTH-1];
    reg [DWIDTH-1:0] douta_mem;
    reg [DWIDTH-1:0] doutb_mem;

    integer byte_i_a;
    always @(posedge clka) begin
        if (ena) begin
            douta_mem <= mem[addra];
            for (byte_i_a = 0; byte_i_a < BYTE_COUNT; byte_i_a = byte_i_a + 1) begin
                if (wea[byte_i_a])
                    mem[addra][8*byte_i_a +: 8] <= dina[8*byte_i_a +: 8];
            end
        end
    end

    integer byte_i_b;
    always @(posedge clkb) begin
        if (enb) begin
            doutb_mem <= mem[addrb];
            for (byte_i_b = 0; byte_i_b < BYTE_COUNT; byte_i_b = byte_i_b + 1) begin
                if (web[byte_i_b])
                    mem[addrb][8*byte_i_b +: 8] <= dinb[8*byte_i_b +: 8];
            end
        end
    end

    generate
        if (OUTPUT_REG != 0) begin : GEN_OUTPUT_REG
            reg [DWIDTH-1:0] douta_reg;
            reg [DWIDTH-1:0] doutb_reg;

            always @(posedge clka)
                douta_reg <= douta_mem;

            always @(posedge clkb)
                doutb_reg <= doutb_mem;

            assign douta = douta_reg;
            assign doutb = doutb_reg;
        end else begin : GEN_NO_OUTPUT_REG
            assign douta = douta_mem;
            assign doutb = doutb_mem;
        end
    endgenerate

endmodule
