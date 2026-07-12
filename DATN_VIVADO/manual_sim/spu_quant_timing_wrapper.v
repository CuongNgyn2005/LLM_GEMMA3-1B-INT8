`timescale 1ns/1ps

// Small implementation wrapper for timing closure of the quantizer.  SPU_Top
// exposes more I/O ports than the device package, so it cannot be placed as a
// standalone top-level design.  This wrapper retains the same clocked
// register-to-register quantization path without the artificial I/O problem.
module spu_quant_timing_wrapper (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire [15:0] sample_seed,
    output wire        probe
);

    reg [511:0] values_r;
    always @(posedge clk) begin
        values_r <= {32{sample_seed}};
    end

    (* keep = "true" *) wire [255:0] qs_out;
    (* keep = "true" *) wire [15:0] scale_amax;
    (* keep = "true" *) wire busy;
    (* keep = "true" *) wire done;
    (* keep = "true" *) wire zero_block;

    (* dont_touch = "true" *) SPU_Quantize_Q8_0 u_quantize_q8_0 (
        .clk        (clk),
        .resetn     (resetn),
        .start      (start),
        .values_in  (values_r),
        .busy       (busy),
        .done       (done),
        .qs_out     (qs_out),
        .scale_amax (scale_amax),
        .zero_block (zero_block)
    );

    assign probe = qs_out[0] ^ scale_amax[0] ^ busy ^ done ^ zero_block;

endmodule
