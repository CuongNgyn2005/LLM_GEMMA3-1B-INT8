/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Q8_Scale_Accum
 * Description : Scale-aware accumulator for Q8_0 raw dot-product blocks.
 *
 * Each accepted entry represents one VPU raw INT32 dot product and its Q8_0
 * activation/weight scales:
 *
 *     contribution = raw * fp16_to_q0_32(d_a) * fp16_to_q0_32(d_w)
 *
 * The accumulator output is signed Q16.16 fixed-point, but the product scale
 * is held internally as Q0.32 so small Q8_0 scale products do not round to
 * zero before multiplication by the INT32 raw dot product.  The module rejects
 * negative, NaN, and infinity FP16 scales.  Zero scale is allowed for zero
 * blocks and contributes zero.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Q8_Scale_Accum #(
    parameter integer ROW_ID_WIDTH     = 16,
    parameter integer MAX_ROWS         = 256,
    parameter integer ACC_WIDTH        = 64,
    parameter integer FIXED_FRAC_BITS  = 16
) (
    input  wire                              clk,
    input  wire                              resetn,
    input  wire                              start,

    input  wire signed [31:0]                raw_in,
    input  wire [15:0]                       act_scale_fp16,
    input  wire [15:0]                       weight_scale_fp16,
    input  wire [ROW_ID_WIDTH-1:0]           row_id,
    input  wire                              clear_accum,
    input  wire                              last_block,

    output wire                              busy,
    output reg                               entry_done,
    output reg                               out_valid,
    output reg  [ROW_ID_WIDTH-1:0]           out_row_id,
    output reg  signed [ACC_WIDTH-1:0]       out_accum_q16,
    output reg                               error,
    output reg  [3:0]                        error_code
);

    localparam [3:0] S_IDLE           = 4'd0;
    localparam [3:0] S_SCALE          = 4'd1;
    localparam [3:0] S_PRODUCT_MUL    = 4'd2;
    localparam [3:0] S_PRODUCT_CROSS  = 4'd3;
    localparam [3:0] S_PRODUCT_MID    = 4'd4;
    localparam [3:0] S_PRODUCT_FULL   = 4'd5;
    localparam [3:0] S_PRODUCT_CLAMP  = 4'd6;
    localparam [3:0] S_RAW_MUL        = 4'd7;
    localparam [3:0] S_CONTRIB_Q16    = 4'd8;
    localparam [3:0] S_ACCUM          = 4'd9;

    localparam [3:0] ERR_NONE      = 4'd0;
    localparam [3:0] ERR_BAD_SCALE = 4'd1;
    localparam [3:0] ERR_ROW_RANGE = 4'd2;

    reg [3:0] state_r;

    reg signed [31:0] raw_r;
    reg [15:0] act_scale_r;
    reg [15:0] weight_scale_r;
    reg [ROW_ID_WIDTH-1:0] row_id_r;
    reg clear_accum_r;
    reg last_block_r;

    reg [63:0] act_scale_q32_r;
    reg [63:0] weight_scale_q32_r;
    // The scale product is split into four 32x32 partial products.  The
    // partial, cross-term, and carry assembly registers keep each DSP chain
    // within one clk_pl_0 cycle instead of inferring one long 64x64 path.
    reg [63:0] product_scale_ll_r;
    reg [63:0] product_scale_lh_r;
    reg [63:0] product_scale_hl_r;
    reg [63:0] product_scale_hh_r;
    reg [64:0] product_scale_cross_r;
    reg [65:0] product_scale_mid_r;
    reg [127:0] product_scale_full_r;
    // Keep this architectural pipeline boundary as fabric flip-flops.  If the
    // register is absorbed into the following multiplier's DSP A/B input,
    // product_scale_full_r drives the clamp logic and the distant DSP input in
    // one cycle, creating the routed scale-product critical path.
    (* dont_touch = "yes" *) reg [63:0] product_scale_q32_r;
    reg signed [96:0] contribution_full_r;
    reg signed [ACC_WIDTH-1:0] contribution_q16_r;

    (* ram_style = "block" *) reg signed [ACC_WIDTH-1:0] accum_mem [0:MAX_ROWS-1];
    reg signed [ACC_WIDTH-1:0] accum_prev_r;

    function fp16_is_nonnegative_finite;
        input [15:0] value;
        begin
            fp16_is_nonnegative_finite =
                (value[15] == 1'b0) && (value[14:10] != 5'h1f);
        end
    endfunction

    function [63:0] fp16_to_q0_32;
        input [15:0] value;
        reg [4:0] exp;
        reg [9:0] frac;
        reg [10:0] mantissa;
        reg [63:0] shifted;
        integer shift;
        begin
            exp = value[14:10];
            frac = value[9:0];
            shifted = 64'd0;

            if (exp == 5'd0) begin
                // Subnormal half: frac * 2^-24.  In Q0.32 this is frac << 8.
                fp16_to_q0_32 = {54'd0, frac} << 8;
            end else begin
                mantissa = {1'b1, frac};
                shift = exp;
                shift = shift + 7;
                if (shift >= 0)
                    shifted = {53'd0, mantissa} << shift;
                else
                    shifted = {53'd0, mantissa} >> (-shift);

                fp16_to_q0_32 = shifted;
            end
        end
    endfunction

    wire row_in_range = (row_id_r < MAX_ROWS);
    (* use_dsp = "yes" *) wire [63:0] product_scale_ll_w =
        act_scale_q32_r[31:0] * weight_scale_q32_r[31:0];
    (* use_dsp = "yes" *) wire [63:0] product_scale_lh_w =
        act_scale_q32_r[31:0] * weight_scale_q32_r[63:32];
    (* use_dsp = "yes" *) wire [63:0] product_scale_hl_w =
        act_scale_q32_r[63:32] * weight_scale_q32_r[31:0];
    (* use_dsp = "yes" *) wire [63:0] product_scale_hh_w =
        act_scale_q32_r[63:32] * weight_scale_q32_r[63:32];
    wire [64:0] product_scale_cross_w =
        {1'b0, product_scale_lh_r} + {1'b0, product_scale_hl_r};
    wire [65:0] product_scale_mid_w =
        {34'd0, product_scale_ll_r[63:32]} +
        {1'b0, product_scale_cross_r};
    wire [64:0] product_scale_upper_w =
        {1'b0, product_scale_hh_r} +
        {31'd0, product_scale_mid_r[65:32]};
    wire [127:0] product_scale_full_w = {
        product_scale_upper_w[63:0],
        product_scale_mid_r[31:0],
        product_scale_ll_r[31:0]
    };
    wire product_scale_overflow_w = |product_scale_full_r[127:96];
    wire signed [96:0] contribution_mul_w =
        $signed(raw_r) * $signed({1'b0, product_scale_q32_r});
    wire signed [96:0] contribution_shifted_w =
        contribution_full_r >>> (32 - FIXED_FRAC_BITS);
    wire signed [ACC_WIDTH-1:0] contribution_shifted_q16_w =
        contribution_shifted_w[ACC_WIDTH-1:0];
    wire signed [ACC_WIDTH-1:0] accum_next_w =
        accum_prev_r + contribution_q16_r;

    assign busy = (state_r != S_IDLE);

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            raw_r <= 32'sd0;
            act_scale_r <= 16'd0;
            weight_scale_r <= 16'd0;
            row_id_r <= {ROW_ID_WIDTH{1'b0}};
            clear_accum_r <= 1'b0;
            last_block_r <= 1'b0;
            accum_prev_r <= {ACC_WIDTH{1'b0}};
            act_scale_q32_r <= 64'd0;
            weight_scale_q32_r <= 64'd0;
            product_scale_ll_r <= 64'd0;
            product_scale_lh_r <= 64'd0;
            product_scale_hl_r <= 64'd0;
            product_scale_hh_r <= 64'd0;
            product_scale_cross_r <= 65'd0;
            product_scale_mid_r <= 66'd0;
            product_scale_full_r <= 128'd0;
            product_scale_q32_r <= 64'd0;
            contribution_full_r <= 97'sd0;
            contribution_q16_r <= {ACC_WIDTH{1'b0}};
            entry_done <= 1'b0;
            out_valid <= 1'b0;
            out_row_id <= {ROW_ID_WIDTH{1'b0}};
            out_accum_q16 <= {ACC_WIDTH{1'b0}};
            error <= 1'b0;
            error_code <= ERR_NONE;
        end else begin
            entry_done <= 1'b0;
            out_valid <= 1'b0;

            case (state_r)
                S_IDLE: begin
                    if (start) begin
                        raw_r <= raw_in;
                        act_scale_r <= act_scale_fp16;
                        weight_scale_r <= weight_scale_fp16;
                        row_id_r <= row_id;
                        clear_accum_r <= clear_accum;
                        last_block_r <= last_block;
                        error <= 1'b0;
                        error_code <= ERR_NONE;
                        state_r <= S_SCALE;
                    end
                end

                S_SCALE: begin
                    if (!fp16_is_nonnegative_finite(act_scale_r) ||
                        !fp16_is_nonnegative_finite(weight_scale_r)) begin
                        error <= 1'b1;
                        error_code <= ERR_BAD_SCALE;
                        entry_done <= 1'b1;
                        state_r <= S_IDLE;
                    end else if (!row_in_range) begin
                        error <= 1'b1;
                        error_code <= ERR_ROW_RANGE;
                        entry_done <= 1'b1;
                        state_r <= S_IDLE;
                    end else begin
                        act_scale_q32_r <= fp16_to_q0_32(act_scale_r);
                        weight_scale_q32_r <= fp16_to_q0_32(weight_scale_r);
                        state_r <= S_PRODUCT_MUL;
                    end
                end

                S_PRODUCT_MUL: begin
                    product_scale_ll_r <= product_scale_ll_w;
                    product_scale_lh_r <= product_scale_lh_w;
                    product_scale_hl_r <= product_scale_hl_w;
                    product_scale_hh_r <= product_scale_hh_w;
                    accum_prev_r <= clear_accum_r ? {ACC_WIDTH{1'b0}} : accum_mem[row_id_r];
                    state_r <= S_PRODUCT_CROSS;
                end

                S_PRODUCT_CROSS: begin
                    product_scale_cross_r <= product_scale_cross_w;
                    state_r <= S_PRODUCT_MID;
                end

                S_PRODUCT_MID: begin
                    product_scale_mid_r <= product_scale_mid_w;
                    state_r <= S_PRODUCT_FULL;
                end

                S_PRODUCT_FULL: begin
                    product_scale_full_r <= product_scale_full_w;
                    state_r <= S_PRODUCT_CLAMP;
                end

                S_PRODUCT_CLAMP: begin
                    product_scale_q32_r <= product_scale_overflow_w ?
                                           64'hffff_ffff_ffff_ffff :
                                           product_scale_full_r[95:32];
                    state_r <= S_RAW_MUL;
                end

                S_RAW_MUL: begin
                    contribution_full_r <= contribution_mul_w;
                    state_r <= S_CONTRIB_Q16;
                end

                S_CONTRIB_Q16: begin
                    contribution_q16_r <= contribution_shifted_q16_w;
                    state_r <= S_ACCUM;
                end

                S_ACCUM: begin
                    accum_mem[row_id_r] <= accum_next_w;
                    entry_done <= 1'b1;
                    if (last_block_r) begin
                        out_valid <= 1'b1;
                        out_row_id <= row_id_r;
                        out_accum_q16 <= accum_next_w;
                    end
                    state_r <= S_IDLE;
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
        end
    end

endmodule
