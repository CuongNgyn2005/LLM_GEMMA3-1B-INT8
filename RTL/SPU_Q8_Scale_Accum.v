/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Q8_Scale_Accum
 * Description : Scale-aware accumulator for Q8_0 raw dot-product blocks.
 *
 * Each accepted entry represents one VPU raw INT32 dot product and its Q8_0
 * activation/weight scales:
 *
 *     contribution = raw * fp16_to_q16_16(d_a) * fp16_to_q16_16(d_w)
 *
 * The accumulator is stored as signed Q16.16 fixed-point.  The module rejects
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

    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_SCALE   = 3'd1;
    localparam [2:0] S_PRODUCT = 3'd2;
    localparam [2:0] S_ACCUM   = 3'd3;

    localparam [3:0] ERR_NONE      = 4'd0;
    localparam [3:0] ERR_BAD_SCALE = 4'd1;
    localparam [3:0] ERR_ROW_RANGE = 4'd2;

    reg [2:0] state_r;

    reg signed [31:0] raw_r;
    reg [15:0] act_scale_r;
    reg [15:0] weight_scale_r;
    reg [ROW_ID_WIDTH-1:0] row_id_r;
    reg clear_accum_r;
    reg last_block_r;

    reg [31:0] act_scale_q16_r;
    reg [31:0] weight_scale_q16_r;
    reg [63:0] product_scale_q16_r;

    (* ram_style = "block" *) reg signed [ACC_WIDTH-1:0] accum_mem [0:MAX_ROWS-1];
    reg signed [ACC_WIDTH-1:0] accum_prev_r;

    function fp16_is_nonnegative_finite;
        input [15:0] value;
        begin
            fp16_is_nonnegative_finite =
                (value[15] == 1'b0) && (value[14:10] != 5'h1f);
        end
    endfunction

    function [31:0] fp16_to_q16_16;
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
                // Subnormal half: frac * 2^-24.  In Q16.16 this is frac >> 8.
                fp16_to_q16_16 = {22'd0, frac} >> 8;
            end else begin
                mantissa = {1'b1, frac};
                shift = exp;
                shift = shift - 9;
                if (shift >= 0)
                    shifted = {53'd0, mantissa} << shift;
                else
                    shifted = {53'd0, mantissa} >> (-shift);

                if (shifted > 64'h0000_0000_ffff_ffff)
                    fp16_to_q16_16 = 32'hffff_ffff;
                else
                    fp16_to_q16_16 = shifted[31:0];
            end
        end
    endfunction

    wire row_in_range = (row_id_r < MAX_ROWS);
    wire signed [96:0] contribution_full_w =
        $signed(raw_r) * $signed({1'b0, product_scale_q16_r});
    wire signed [ACC_WIDTH-1:0] contribution_q16_w =
        contribution_full_w[ACC_WIDTH-1:0];
    wire signed [ACC_WIDTH-1:0] accum_next_w =
        accum_prev_r + contribution_q16_w;

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
            act_scale_q16_r <= 32'd0;
            weight_scale_q16_r <= 32'd0;
            product_scale_q16_r <= 64'd0;
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
                        act_scale_q16_r <= fp16_to_q16_16(act_scale_r);
                        weight_scale_q16_r <= fp16_to_q16_16(weight_scale_r);
                        state_r <= S_PRODUCT;
                    end
                end

                S_PRODUCT: begin
                    product_scale_q16_r <=
                        ({32'd0, act_scale_q16_r} * {32'd0, weight_scale_q16_r}) >>
                        FIXED_FRAC_BITS;
                    accum_prev_r <= clear_accum_r ? {ACC_WIDTH{1'b0}} : accum_mem[row_id_r];
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
