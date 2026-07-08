`timescale 1ns/1ps

module uram_synth_check (
    input  wire        clka,
    input  wire        clkb,
    input  wire        ena,
    input  wire        enb,
    input  wire [3:0]  wea,
    input  wire [13:0] addra,
    input  wire [13:0] addrb,
    input  wire [31:0] dina,
    output wire [31:0] douta,
    output wire [31:0] doutb
);

    Dual_Port_BRAM #(
        .AWIDTH     (14),
        .DWIDTH     (32),
        .OUTPUT_REG (1),
        .USE_URAM   (1)
    ) u_weight_uram_check (
        .clka  (clka),
        .ena   (ena),
        .wea   (wea),
        .addra (addra),
        .dina  (dina),
        .douta (douta),
        .clkb  (clkb),
        .enb   (enb),
        .web   (4'b0000),
        .addrb (addrb),
        .dinb  (32'h00000000),
        .doutb (doutb)
    );

endmodule
