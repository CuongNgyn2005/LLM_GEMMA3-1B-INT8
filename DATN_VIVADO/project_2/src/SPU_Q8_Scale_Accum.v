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
 * The accumulator output is signed Q16.16 fixed-point.  The product scale is
 * held internally as Q0.32.  Negative, NaN and infinity FP16 scales are
 * rejected; zero scale is valid and contributes zero.
 *
 * Throughput note: the exact 11x11 significand product and exponent-shift sum
 * are captured directly on the accepted start edge.  Alignment, signed raw
 * multiply, and accumulation keep their existing register boundaries.  This
 * removes the otherwise idle S_PRODUCT_MUL handoff stage without combining
 * the 64-bit aligner with the signed raw multiply, reducing the steady P2
 * accepted-start interval from four clocks to three while preserving the
 * numerical operation and the one-cycle-early non-final entry_done contract.
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

    // S_PRODUCT_MUL is retained as a defensive compatibility state but normal
    // accepted entries now jump directly to S_PRODUCT_ALIGN.
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

    reg [21:0] product_scale_sig_r;
    reg [6:0] product_scale_shift_r;

    // Keep a register boundary before the signed raw multiply.  The only
    // throughput change is moving the compact 11x11 significand multiply onto
    // the accepted-start edge; align/raw-multiply boundaries remain intact.
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
    function [5:0] fp16_q32_shift;
        input [15:0] value;
        begin
            fp16_q32_shift =
                (value[14:10] == 5'd0) ? 6'd8 :
                                         ({1'b0, value[14:10]} + 6'd7);
        end
    endfunction

    // These are the same compact scale-product operands previously evaluated
    // in S_PRODUCT_MUL; only the capture edge changes.
    (* use_dsp = "yes" *) wire [21:0] start_product_scale_sig_w =
        fp16_q32_significand(act_scale_fp16) *
        fp16_q32_significand(weight_scale_fp16);
    wire [6:0] start_product_scale_shift_w =
        {1'b0, fp16_q32_shift(act_scale_fp16)} +
        {1'b0, fp16_q32_shift(weight_scale_fp16)};

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

    task capture_valid_start;
        begin
            raw_r <= raw_in;
            row_id_r <= row_id;
            last_block_r <= last_block;
            product_scale_sig_r <= start_product_scale_sig_w;
            product_scale_shift_r <= start_product_scale_shift_w;
            accum_prev_r <= clear_accum ?
                            {ACC_WIDTH{1'b0}} : accum_mem[row_id];
            pending_error_r <= 1'b0;
            error <= 1'b0;
            error_code <= ERR_NONE;
            state_r <= S_PRODUCT_ALIGN;
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            raw_r <= 32'sd0;
            row_id_r <= {ROW_ID_WIDTH{1'b0}};
            last_block_r <= 1'b0;
            pending_error_r <= 1'b0;
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
                            state_r <= S_PRODUCT_ALIGN;
                        end else if (row_id >= MAX_ROWS) begin
                            pending_error_r <= 1'b1;
                            error <= 1'b1;
                            error_code <= ERR_ROW_RANGE;
                            state_r <= S_PRODUCT_ALIGN;
                        end else begin
                            capture_valid_start();
                        end
                    end
                end

                // Normal traffic no longer enters this state.  Keeping the
                // redirect makes a corrupted/legacy state value fail benignly
                // into the same pipeline rather than changing state encoding.
                S_PRODUCT_MUL: begin
                    state_r <= S_PRODUCT_ALIGN;
                end

                S_PRODUCT_ALIGN: begin
                    if (!pending_error_r)
                        product_scale_q32_r <= product_scale_aligned_w;
                    state_r <= S_RAW_MUL;
                end

                S_RAW_MUL: begin
                    if (pending_error_r) begin
                        if (!last_block_r)
                            entry_done <= 1'b1;
                    end else begin
                        contribution_full_r <= contribution_mul_w;
                        if (!last_block_r)
                            entry_done <= 1'b1;
                    end
                    state_r <= S_ACCUM;
                end

                S_ACCUM: begin
                    if (pending_error_r) begin
                        // Failed entries never touch accumulator RAM.  Preserve
                        // the same handoff/error retirement boundary as valid lanes.
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
                                state_r <= S_PRODUCT_ALIGN;
                            end else if (row_id >= MAX_ROWS) begin
                                pending_error_r <= 1'b1;
                                error <= 1'b1;
                                error_code <= ERR_ROW_RANGE;
                                state_r <= S_PRODUCT_ALIGN;
                            end else begin
                                capture_valid_start();
                            end
                        end else begin
                            state_r <= S_IDLE;
                        end
                    end else begin
                        // Commit current contribution.  The same-row bypass is
                        // required when the next block is accepted on this edge.
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
                                state_r <= S_PRODUCT_ALIGN;
                            end else if (row_id >= MAX_ROWS) begin
                                pending_error_r <= 1'b1;
                                error <= 1'b1;
                                error_code <= ERR_ROW_RANGE;
                                state_r <= S_PRODUCT_ALIGN;
                            end else begin
                                raw_r <= raw_in;
                                row_id_r <= row_id;
                                last_block_r <= last_block;
                                product_scale_sig_r <= start_product_scale_sig_w;
                                product_scale_shift_r <= start_product_scale_shift_w;
                                accum_prev_r <= clear_accum ?
                                                {ACC_WIDTH{1'b0}} :
                                                ((row_id == row_id_r) ? accum_next_w :
                                                                        accum_mem[row_id]);
                                pending_error_r <= 1'b0;
                                error <= 1'b0;
                                error_code <= ERR_NONE;
                                state_r <= S_PRODUCT_ALIGN;
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
