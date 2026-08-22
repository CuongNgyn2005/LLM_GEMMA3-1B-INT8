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
 *
 * A finite nonnegative FP16 value has an exact Q0.32 representation of an
 * 11-bit significand shifted by a small integer amount.  Multiplying those
 * significands first and applying the combined shift is bit-identical to the
 * previous 64x64 Q0.32 product.  Input validation, FP16 decode and the
 * accumulator-memory read are performed on the accepted start edge, leaving
 * the product/alignment/raw-multiply register boundaries intact for timing.
 *
 * Non-final entries advertise completion one cycle before S_ACCUM so the
 * bundle stream can present the following block on the same edge that the
 * current accumulation commits.  S_ACCUM accepts that next entry directly and
 * bypasses accum_next_w when it targets the same row, reducing the steady P2
 * start interval from five clocks to four without collapsing DSP stages.
 * Invalid entries traverse the same control latency as valid entries and pulse
 * completion at the matching non-final/final boundary.  This keeps paired/x8
 * lanes synchronized without leaving a stale completion asserted into the next
 * command.  Invalid entries never update accumulator RAM or publish an output.
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

    localparam [2:0] S_IDLE          = 3'd0;
    localparam [2:0] S_PRODUCT_MUL   = 3'd1;
    localparam [2:0] S_PRODUCT_ALIGN = 3'd2;
    localparam [2:0] S_RAW_MUL       = 3'd3;
    localparam [2:0] S_ACCUM         = 3'd4;

    localparam [3:0] ERR_NONE      = 4'd0;
    localparam [3:0] ERR_BAD_SCALE = 4'd1;
    localparam [3:0] ERR_ROW_RANGE = 4'd2;

    reg [2:0] state_r;

    reg signed [31:0] raw_r;
    reg [ROW_ID_WIDTH-1:0] row_id_r;
    reg last_block_r;
    reg pending_error_r;

    reg [10:0] act_scale_sig_r;
    reg [10:0] weight_scale_sig_r;
    reg [5:0] act_scale_shift_r;
    reg [5:0] weight_scale_shift_r;
    reg [21:0] product_scale_sig_r;
    reg [6:0] product_scale_shift_r;

    // Keep a register boundary before the signed raw multiply.  Besides
    // preserving timing margin, this keeps the compact scale-product rewrite
    // local to the scale path and leaves the raw/contribution arithmetic
    // bit-identical to the previous implementation.
    (* dont_touch = "yes" *) reg [63:0] product_scale_q32_r;
    reg signed [96:0] contribution_full_r;

    (* ram_style = "block" *) reg signed [ACC_WIDTH-1:0] accum_mem [0:MAX_ROWS-1];
    reg signed [ACC_WIDTH-1:0] accum_prev_r;

    function fp16_is_nonnegative_finite;
        input [15:0] value;
        begin
            fp16_is_nonnegative_finite =
                (value[15] == 1'b0) && (value[14:10] != 5'h1f);
        end
    endfunction

    // Exact significand used by fp16_to_q0_32:
    //   normal    -> {1, frac}
    //   subnormal -> {0, frac}
    function [10:0] fp16_q32_significand;
        input [15:0] value;
        begin
            fp16_q32_significand =
                (value[14:10] == 5'd0) ? {1'b0, value[9:0]} :
                                         {1'b1, value[9:0]};
        end
    endfunction

    // For finite nonnegative FP16 values:
    //   fp16_to_q0_32(value) = significand << q32_shift
    // Normal exponent e uses e+7; subnormals use the exact frac<<8 form.
    function [5:0] fp16_q32_shift;
        input [15:0] value;
        begin
            fp16_q32_shift =
                (value[14:10] == 5'd0) ? 6'd8 :
                                         ({1'b0, value[14:10]} + 6'd7);
        end
    endfunction

    (* use_dsp = "yes" *) wire [21:0] product_scale_sig_w =
        act_scale_sig_r * weight_scale_sig_r;
    wire [6:0] product_scale_shift_w =
        {1'b0, act_scale_shift_r} + {1'b0, weight_scale_shift_r};
    wire [63:0] product_scale_sig_ext_w = {42'd0, product_scale_sig_r};
    wire [63:0] product_scale_aligned_w =
        (product_scale_shift_r >= 7'd32) ?
            (product_scale_sig_ext_w << (product_scale_shift_r - 7'd32)) :
            (product_scale_sig_ext_w >> (7'd32 - product_scale_shift_r));

    wire signed [96:0] contribution_mul_w =
        $signed(raw_r) * $signed({1'b0, product_scale_q32_r});
    wire signed [96:0] contribution_shifted_w =
        contribution_full_r >>> (32 - FIXED_FRAC_BITS);
    wire signed [ACC_WIDTH-1:0] contribution_shifted_q16_w =
        contribution_shifted_w[ACC_WIDTH-1:0];
    wire signed [ACC_WIDTH-1:0] accum_next_w =
        accum_prev_r + contribution_shifted_q16_w;

    assign busy = (state_r != S_IDLE);

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            raw_r <= 32'sd0;
            row_id_r <= {ROW_ID_WIDTH{1'b0}};
            last_block_r <= 1'b0;
            pending_error_r <= 1'b0;
            act_scale_sig_r <= 11'd0;
            weight_scale_sig_r <= 11'd0;
            act_scale_shift_r <= 6'd0;
            weight_scale_shift_r <= 6'd0;
            product_scale_sig_r <= 22'd0;
            product_scale_shift_r <= 7'd0;
            product_scale_q32_r <= 64'd0;
            contribution_full_r <= 97'sd0;
            accum_prev_r <= {ACC_WIDTH{1'b0}};
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
                        last_block_r <= last_block;
                        if (!fp16_is_nonnegative_finite(act_scale_fp16) ||
                            !fp16_is_nonnegative_finite(weight_scale_fp16)) begin
                            pending_error_r <= 1'b1;
                            error <= 1'b1;
                            error_code <= ERR_BAD_SCALE;
                            state_r <= S_PRODUCT_MUL;
                        end else if (row_id >= MAX_ROWS) begin
                            pending_error_r <= 1'b1;
                            error <= 1'b1;
                            error_code <= ERR_ROW_RANGE;
                            state_r <= S_PRODUCT_MUL;
                        end else begin
                            raw_r <= raw_in;
                            row_id_r <= row_id;
                            act_scale_sig_r <= fp16_q32_significand(act_scale_fp16);
                            weight_scale_sig_r <= fp16_q32_significand(weight_scale_fp16);
                            act_scale_shift_r <= fp16_q32_shift(act_scale_fp16);
                            weight_scale_shift_r <= fp16_q32_shift(weight_scale_fp16);
                            accum_prev_r <= clear_accum ?
                                            {ACC_WIDTH{1'b0}} : accum_mem[row_id];
                            pending_error_r <= 1'b0;
                            error <= 1'b0;
                            error_code <= ERR_NONE;
                            state_r <= S_PRODUCT_MUL;
                        end
                    end
                end

                S_PRODUCT_MUL: begin
                    if (!pending_error_r) begin
                        product_scale_sig_r <= product_scale_sig_w;
                        product_scale_shift_r <= product_scale_shift_w;
                    end
                    state_r <= S_PRODUCT_ALIGN;
                end

                S_PRODUCT_ALIGN: begin
                    if (!pending_error_r)
                        product_scale_q32_r <= product_scale_aligned_w;
                    state_r <= S_RAW_MUL;
                end

                S_RAW_MUL: begin
                    if (pending_error_r) begin
                        // Match the normal non-final completion cycle so an
                        // invalid lane stays aligned with valid lanes in an x8 bundle.
                        if (!last_block_r)
                            entry_done <= 1'b1;
                    end else begin
                        contribution_full_r <= contribution_mul_w;
                        // A non-final block has no output payload to capture.  Its
                        // contribution is fully registered here, so advertise that
                        // the stream may present the next block during S_ACCUM.
                        if (!last_block_r)
                            entry_done <= 1'b1;
                    end
                    state_r <= S_ACCUM;
                end

                S_ACCUM: begin
                    if (pending_error_r) begin
                        // Failed entries retire without touching accumulator RAM.
                        // A non-final failed entry may still receive the next
                        // prefetched block on this edge, exactly like the valid path.
                        if (last_block_r) begin
                            entry_done <= 1'b1;
                            state_r <= S_IDLE;
                        end else if (start) begin
                            last_block_r <= last_block;
                            if (!fp16_is_nonnegative_finite(act_scale_fp16) ||
                                !fp16_is_nonnegative_finite(weight_scale_fp16)) begin
                                pending_error_r <= 1'b1;
                                error <= 1'b1;
                                error_code <= ERR_BAD_SCALE;
                                state_r <= S_PRODUCT_MUL;
                            end else if (row_id >= MAX_ROWS) begin
                                pending_error_r <= 1'b1;
                                error <= 1'b1;
                                error_code <= ERR_ROW_RANGE;
                                state_r <= S_PRODUCT_MUL;
                            end else begin
                                raw_r <= raw_in;
                                row_id_r <= row_id;
                                act_scale_sig_r <= fp16_q32_significand(act_scale_fp16);
                                weight_scale_sig_r <= fp16_q32_significand(weight_scale_fp16);
                                act_scale_shift_r <= fp16_q32_shift(act_scale_fp16);
                                weight_scale_shift_r <= fp16_q32_shift(weight_scale_fp16);
                                // The failed entry made no commit, so there is
                                // intentionally no same-row accum_next_w bypass here.
                                accum_prev_r <= clear_accum ?
                                                {ACC_WIDTH{1'b0}} : accum_mem[row_id];
                                pending_error_r <= 1'b0;
                                error <= 1'b0;
                                error_code <= ERR_NONE;
                                state_r <= S_PRODUCT_MUL;
                            end
                        end else begin
                            state_r <= S_IDLE;
                        end
                    end else begin
                        // Commit the current contribution first.  If the producer
                        // presents the next non-final block on this same edge, the
                        // same-row bypass below feeds it accum_next_w rather than
                        // the pre-write RAM value.
                        accum_mem[row_id_r] <= accum_next_w;

                        if (last_block_r) begin
                            entry_done <= 1'b1;
                            out_valid <= 1'b1;
                            out_row_id <= row_id_r;
                            out_accum_q16 <= accum_next_w;
                            state_r <= S_IDLE;
                        end else if (start) begin
                            last_block_r <= last_block;
                            if (!fp16_is_nonnegative_finite(act_scale_fp16) ||
                                !fp16_is_nonnegative_finite(weight_scale_fp16)) begin
                                pending_error_r <= 1'b1;
                                error <= 1'b1;
                                error_code <= ERR_BAD_SCALE;
                                state_r <= S_PRODUCT_MUL;
                            end else if (row_id >= MAX_ROWS) begin
                                pending_error_r <= 1'b1;
                                error <= 1'b1;
                                error_code <= ERR_ROW_RANGE;
                                state_r <= S_PRODUCT_MUL;
                            end else begin
                                raw_r <= raw_in;
                                row_id_r <= row_id;
                                act_scale_sig_r <= fp16_q32_significand(act_scale_fp16);
                                weight_scale_sig_r <= fp16_q32_significand(weight_scale_fp16);
                                act_scale_shift_r <= fp16_q32_shift(act_scale_fp16);
                                weight_scale_shift_r <= fp16_q32_shift(weight_scale_fp16);
                                accum_prev_r <= clear_accum ?
                                                {ACC_WIDTH{1'b0}} :
                                                ((row_id == row_id_r) ? accum_next_w :
                                                                        accum_mem[row_id]);
                                pending_error_r <= 1'b0;
                                error <= 1'b0;
                                error_code <= ERR_NONE;
                                state_r <= S_PRODUCT_MUL;
                            end
                        end else begin
                            state_r <= S_IDLE;
                        end
                    end
                end

                default: begin
                    state_r <= S_IDLE;
                    pending_error_r <= 1'b0;
                end
            endcase
        end
    end

endmodule
