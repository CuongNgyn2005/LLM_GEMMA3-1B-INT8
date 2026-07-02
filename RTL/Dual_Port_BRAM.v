/*
 *-----------------------------------------------------------------------------
 * Module      : Dual_Port_BRAM
 * Description : True dual-port block RAM wrapper shared by the VPU.
 *
 * This module is the local storage primitive used for activation, weight, and
 * result memories.  It does not implement AXI.  The AXI and mapping layers
 * have already converted transactions into addresses, write data, and byte
 * enables before data reaches this BRAM wrapper.
 *
 * Main properties:
 * - parameterized address/data width;
 * - byte write strobes for 128-bit AXI beats and 32-bit result words;
 * - synchronous read on both ports;
 * - read-first behavior on same-port read/write.
 *
 * Port A and Port B can read/write independently on their own clocks.  In the
 * current VPU integration, one port usually serves CPU/DMA access through the
 * mapping layer while the other port serves the GEMV compute path.
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

    // Port A performs synchronous read and byte-enable write.  Because
    // douta_mem samples mem before the byte write loop updates it, same-port
    // read/write to the same address is read-first: the output sees the old
    // value and the RAM array is updated afterward.
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

    // Port B mirrors Port A behavior.  Keeping the two ports in independent
    // clocked blocks helps Vivado infer a true dual-port block RAM.
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

    // OUTPUT_REG adds an optional output register for timing closure when this
    // BRAM sits in front of the PMAU pipeline.  When OUTPUT_REG is zero, the
    // output is the RAM's internal synchronous read register.
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
