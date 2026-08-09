/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Controller
 * Description : Command FSM for the Scalar Processing Unit.
 *
 * Implemented command set:
 * - SPU_MODE_QUANT_Q8_0     : fixed-point INT16 block -> VPU-ready INT8 payload;
 * - SPU_MODE_SILU_MUL       : signed Q8.8 SiLU(gate) * up;
 * - SPU_MODE_RMSNORM        : signed Q8.8 RMSNorm using SPU_PARAM weights;
 * - SPU_MODE_ROPE           : signed Q8.8 RoPE using SPU_PARAM Q1.15 cos/sin;
 * - SPU_MODE_SOFTMAX        : signed Q8.8 logits -> unsigned Q0.15 probabilities;
 * - SPU_MODE_Q8_SCALE_ACCUM : raw INT32 + FP16 scales -> Q16.16 accumulator;
 * - SPU_MODE_COPY           : self-test copy from SPU_IN to SPU_OUT.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Controller #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH     = 4096,
    parameter integer SCALE_ACCUM_ROWS = 256
) (
    input  wire                              clk,
    input  wire                              resetn,

    input  wire                              start,
    input  wire                              clear_done,
    input  wire                              soft_reset,
    input  wire [7:0]                        mode,
    input  wire [31:0]                       len,
    input  wire [31:0]                       aux0,
    input  wire [31:0]                       aux1,

    output wire                              busy,
    output reg                               done,
    output reg                               error,
    output reg  [7:0]                        error_code,

    output reg                               mem_en,
    output reg                               mem_we,
    output reg  [1:0]                        mem_region,
    output reg  [31:0]                       mem_index,
    output reg  [AXI_DATA_WIDTH-1:0]         mem_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0]     mem_wstrb,
    input  wire [AXI_DATA_WIDTH-1:0]         mem_rdata
);

    localparam [1:0] REGION_IN      = 2'd0;
    localparam [1:0] REGION_OUT     = 2'd1;
    localparam [1:0] REGION_PARAM   = 2'd2;
    localparam [1:0] REGION_SCRATCH = 2'd3;

    localparam [7:0] SPU_MODE_QUANT_Q8_0       = 8'd1;
    localparam [7:0] SPU_MODE_SILU_MUL         = 8'd2;
    localparam [7:0] SPU_MODE_RMSNORM          = 8'd3;
    localparam [7:0] SPU_MODE_ROPE             = 8'd4;
    localparam [7:0] SPU_MODE_SOFTMAX          = 8'd5;
    localparam [7:0] SPU_MODE_Q8_SCALE_ACCUM   = 8'd6;
    localparam [7:0] SPU_MODE_COPY             = 8'h7f;

    localparam [7:0] ERR_NONE         = 8'd0;
    localparam [7:0] ERR_BAD_MODE     = 8'd1;
    localparam [7:0] ERR_BAD_LENGTH   = 8'd2;
    localparam [7:0] ERR_RANGE        = 8'd3;
    localparam [7:0] ERR_BAD_SCALE    = 8'd4;

    localparam [5:0] S_IDLE              = 6'd0;
    localparam [5:0] S_DECODE            = 6'd1;
    localparam [5:0] S_COPY_READ         = 6'd2;
    localparam [5:0] S_COPY_WAIT         = 6'd3;
    localparam [5:0] S_COPY_WRITE        = 6'd4;
    localparam [5:0] S_Q_READ            = 6'd5;
    localparam [5:0] S_Q_WAIT            = 6'd6;
    localparam [5:0] S_Q_CAPTURE         = 6'd7;
    localparam [5:0] S_Q_COMPUTE         = 6'd8;
    localparam [5:0] S_Q_WRITE0          = 6'd9;
    localparam [5:0] S_Q_WRITE1          = 6'd10;
    localparam [5:0] S_Q_WRITE_SCALE     = 6'd11;
    localparam [5:0] S_DONE              = 6'd12;
    localparam [5:0] S_ERROR             = 6'd13;
    localparam [5:0] S_Q_WAIT_COMPUTE    = 6'd15;
    localparam [5:0] S_SA_READ           = 6'd16;
    localparam [5:0] S_SA_WAIT           = 6'd17;
    localparam [5:0] S_SA_CAPTURE        = 6'd18;
    localparam [5:0] S_SA_START          = 6'd19;
    localparam [5:0] S_SA_WAIT_ACCUM     = 6'd20;
    localparam [5:0] S_SA_WRITE_OUT      = 6'd21;
    localparam [5:0] S_SA_WRITE_STATUS   = 6'd22;
    localparam [5:0] S_VEC_READ_IN       = 6'd23;
    localparam [5:0] S_VEC_WAIT_IN       = 6'd24;
    localparam [5:0] S_VEC_CAPTURE_IN    = 6'd25;
    localparam [5:0] S_VEC_READ_PARAM    = 6'd26;
    localparam [5:0] S_VEC_WAIT_PARAM    = 6'd27;
    localparam [5:0] S_VEC_CAPTURE_PARAM = 6'd28;
    localparam [5:0] S_VEC_START         = 6'd29;
    localparam [5:0] S_VEC_WAIT_OP       = 6'd30;
    localparam [5:0] S_VEC_WRITE_OUT     = 6'd31;
    localparam [5:0] S_RMS_SUM_READ      = 6'd32;
    localparam [5:0] S_RMS_SUM_WAIT      = 6'd33;
    localparam [5:0] S_RMS_SUM_CAPTURE   = 6'd34;
    localparam [5:0] S_RMS_SUM_START     = 6'd35;
    localparam [5:0] S_RMS_SUM_WAIT_OP   = 6'd36;
    localparam [5:0] S_RMS_INV_START     = 6'd37;
    localparam [5:0] S_SOFT_MAX_READ     = 6'd38;
    localparam [5:0] S_SOFT_MAX_WAIT     = 6'd39;
    localparam [5:0] S_SOFT_MAX_CAPTURE  = 6'd40;
    localparam [5:0] S_SOFT_MAX_START    = 6'd41;
    localparam [5:0] S_SOFT_MAX_WAIT_OP  = 6'd42;
    localparam [5:0] S_SOFT_SCORE_READ   = 6'd43;
    localparam [5:0] S_SOFT_SCORE_WAIT   = 6'd44;
    localparam [5:0] S_SOFT_SCORE_CAPTURE= 6'd45;
    localparam [5:0] S_SOFT_SCORE_START  = 6'd46;
    localparam [5:0] S_SOFT_SCORE_WAIT_OP= 6'd47;
    localparam [5:0] S_SOFT_SCORE_WRITE  = 6'd48;
    localparam [5:0] S_SOFT_NORM_READ    = 6'd49;
    localparam [5:0] S_SOFT_NORM_WAIT    = 6'd50;
    localparam [5:0] S_SOFT_NORM_CAPTURE = 6'd51;
    localparam [5:0] S_SOFT_NORM_START   = 6'd52;
    localparam [5:0] S_SOFT_NORM_WAIT_OP = 6'd53;
    localparam [5:0] S_SOFT_NORM_WRITE   = 6'd54;
    localparam [5:0] S_RMS_INV_WAIT      = 6'd55;

    localparam integer INPUT_LANES_PER_WORD = AXI_DATA_WIDTH / 16;
    localparam integer Q8_BLOCK_VALUES      = 32;
    localparam integer Q8_INPUT_WORDS       = Q8_BLOCK_VALUES / INPUT_LANES_PER_WORD;
    localparam integer Q8_OUTPUT_WORDS      = 2;

    reg [5:0]  state_r;
    reg [7:0]  mode_r;
    reg [31:0] len_r;
    reg [31:0] word_idx_r;
    reg [31:0] word_count_r;
    reg [31:0] block_idx_r;
    reg [31:0] block_count_r;
    reg [31:0] scale_out_count_r;
    reg [1:0]  q_word_idx_r;
    reg [16*Q8_BLOCK_VALUES-1:0] quant_values_r;
    reg [AXI_DATA_WIDTH-1:0] scale_entry_word_r;
    reg [15:0] scale_out_row_r;
    reg signed [63:0] scale_out_accum_r;
    reg scale_accum_start_r;

    reg [AXI_DATA_WIDTH-1:0] vec_input_word_r;
    reg [AXI_DATA_WIDTH-1:0] vec_param_word_r;
    reg [AXI_DATA_WIDTH-1:0] vec_result_word_r;
    reg [7:0] vec_lane_mask_r;

    reg [63:0] rms_sumsq_total_r;
    reg [31:0] rms_inv_q15_r;

    reg signed [15:0] softmax_max_q8_r;
    reg [63:0] softmax_sum_r;
    reg [1:0] softmax_op_r;

    wire [8*Q8_BLOCK_VALUES-1:0] quant_qs;
    wire [15:0] quant_amax;
    wire quant_zero;
    wire quant_done;
    wire scale_accum_entry_done;
    wire scale_accum_out_valid;
    wire [15:0] scale_accum_out_row_id;
    wire signed [63:0] scale_accum_out_accum_q16;
    wire scale_accum_error;
    wire [3:0] scale_accum_error_code;

    wire silu_done;
    wire [AXI_DATA_WIDTH-1:0] silu_result_word;
    wire rms_done;
    wire [AXI_DATA_WIDTH-1:0] rms_result_word;
    wire [63:0] rms_word_sumsq_q16;
    wire rms_inv_busy;
    wire rms_inv_done;
    wire rms_inv_error;
    wire [31:0] rms_inv_value_q15;
    wire rope_done;
    wire [AXI_DATA_WIDTH-1:0] rope_result_word;
    wire softmax_done;
    wire [AXI_DATA_WIDTH-1:0] softmax_output_word;
    wire signed [15:0] softmax_word_max_q8;
    wire [63:0] softmax_word_sum;

    wire vec_done =
        (mode_r == SPU_MODE_SILU_MUL) ? silu_done :
        (mode_r == SPU_MODE_RMSNORM)  ? rms_done  :
        (mode_r == SPU_MODE_ROPE)     ? rope_done : 1'b0;
    wire [AXI_DATA_WIDTH-1:0] vec_result =
        (mode_r == SPU_MODE_SILU_MUL) ? silu_result_word :
        (mode_r == SPU_MODE_RMSNORM)  ? rms_result_word  :
        (mode_r == SPU_MODE_ROPE)     ? rope_result_word : {AXI_DATA_WIDTH{1'b0}};

    wire silu_start = (state_r == S_VEC_START) && (mode_r == SPU_MODE_SILU_MUL);
    wire rms_start =
        ((state_r == S_VEC_START) && (mode_r == SPU_MODE_RMSNORM)) ||
        (state_r == S_RMS_SUM_START);
    wire rms_inv_start = (state_r == S_RMS_INV_START);
    wire rope_start = (state_r == S_VEC_START) && (mode_r == SPU_MODE_ROPE);
    wire softmax_start =
        (state_r == S_SOFT_MAX_START) ||
        (state_r == S_SOFT_SCORE_START) ||
        (state_r == S_SOFT_NORM_START);

    assign busy = (state_r != S_IDLE) && (state_r != S_DONE) && (state_r != S_ERROR);

    SPU_Quantize_Q8_0 u_quantize_q8_0 (
        .clk        (clk),
        .resetn     (resetn),
        .start      (state_r == S_Q_COMPUTE),
        .values_in  (quant_values_r),
        .busy       (),
        .done       (quant_done),
        .qs_out     (quant_qs),
        .scale_amax (quant_amax),
        .zero_block (quant_zero)
    );

    SPU_Q8_Scale_Accum #(
        .ROW_ID_WIDTH    (16),
        .MAX_ROWS        (SCALE_ACCUM_ROWS),
        .ACC_WIDTH       (64),
        .FIXED_FRAC_BITS (16)
    ) u_q8_scale_accum (
        .clk               (clk),
        .resetn            (resetn),
        .start             (scale_accum_start_r),
        .raw_in            (scale_entry_word_r[31:0]),
        .act_scale_fp16    (scale_entry_word_r[47:32]),
        .weight_scale_fp16 (scale_entry_word_r[63:48]),
        .row_id            (scale_entry_word_r[79:64]),
        .clear_accum       (scale_entry_word_r[81]),
        .last_block        (scale_entry_word_r[80]),
        .busy              (),
        .entry_done        (scale_accum_entry_done),
        .out_valid         (scale_accum_out_valid),
        .out_row_id        (scale_accum_out_row_id),
        .out_accum_q16     (scale_accum_out_accum_q16),
        .error             (scale_accum_error),
        .error_code        (scale_accum_error_code)
    );

    SPU_SiLU_Mul #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
    ) u_silu_mul (
        .clk         (clk),
        .resetn      (resetn),
        .start       (silu_start),
        .gate_word   (vec_input_word_r),
        .up_word     (vec_param_word_r),
        .lane_valid  (vec_lane_mask_r),
        .busy        (),
        .done        (silu_done),
        .result_word (silu_result_word),
        .supported   ()
    );

    SPU_RMSNorm #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
    ) u_rmsnorm (
        .clk           (clk),
        .resetn        (resetn),
        .start         (rms_start),
        .input_word    (vec_input_word_r),
        .weight_word   (vec_param_word_r),
        .inv_rms_q15   (rms_inv_q15_r),
        .lane_valid    (vec_lane_mask_r),
        .busy          (),
        .done          (rms_done),
        .result_word   (rms_result_word),
        .word_sumsq_q16(rms_word_sumsq_q16),
        .supported     ()
    );

    SPU_RMSInv_Engine u_rms_inv_engine (
        .clk           (clk),
        .resetn        (resetn),
        .start         (rms_inv_start),
        .sumsq_q16     (rms_sumsq_total_r),
        .element_count (len_r),
        .epsilon_q16   ((aux0 == 32'd0) ? 32'd1 : aux0),
        .busy          (rms_inv_busy),
        .done          (rms_inv_done),
        .error         (rms_inv_error),
        .inv_rms_q15   (rms_inv_value_q15)
    );

    SPU_RoPE #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
    ) u_rope (
        .clk         (clk),
        .resetn      (resetn),
        .start       (rope_start),
        .input_word  (vec_input_word_r),
        .trig_word   (vec_param_word_r),
        .lane_valid  (vec_lane_mask_r),
        .busy        (),
        .done        (rope_done),
        .result_word (rope_result_word),
        .supported   ()
    );

    SPU_Softmax #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH)
    ) u_softmax (
        .clk          (clk),
        .resetn       (resetn),
        .start        (softmax_start),
        .op           (softmax_op_r),
        .input_word   (vec_input_word_r),
        .max_value_q8 (softmax_max_q8_r),
        .sum_value    (softmax_sum_r),
        .lane_valid   (vec_lane_mask_r),
        .busy         (),
        .done         (softmax_done),
        .output_word  (softmax_output_word),
        .word_max_q8  (softmax_word_max_q8),
        .word_sum     (softmax_word_sum),
        .supported    ()
    );

    function [31:0] ceil_div32;
        input [31:0] value;
        begin
            ceil_div32 = (value + 32'd31) >> 5;
        end
    endfunction

    function [31:0] ceil_div8;
        input [31:0] value;
        begin
            ceil_div8 = (value + 32'd7) >> 3;
        end
    endfunction

    function [7:0] lane_mask8;
        input [31:0] word_idx;
        input [31:0] element_count;
        reg [31:0] base;
        reg [31:0] remaining;
        integer lane;
        begin
            base = word_idx << 3;
            if (base >= element_count)
                remaining = 32'd0;
            else
                remaining = element_count - base;

            lane_mask8 = 8'd0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                if (remaining > lane)
                    lane_mask8[lane] = 1'b1;
            end
        end
    endfunction

    function [AXI_DATA_WIDTH-1:0] masked_input_word;
        input [AXI_DATA_WIDTH-1:0] word_value;
        input [31:0] block_idx;
        input [1:0] word_idx;
        input [31:0] element_count;
        integer lane;
        reg [31:0] element_index;
        begin
            masked_input_word = word_value;
            for (lane = 0; lane < INPUT_LANES_PER_WORD; lane = lane + 1) begin
                element_index =
                    block_idx * Q8_BLOCK_VALUES +
                    word_idx * INPUT_LANES_PER_WORD +
                    lane;
                if (element_index >= element_count)
                    masked_input_word[16*lane +: 16] = 16'd0;
            end
        end
    endfunction

    task restart_command;
        begin
            done           <= 1'b0;
            error          <= 1'b0;
            error_code     <= ERR_NONE;
            mode_r         <= mode;
            len_r          <= len;
            word_idx_r     <= 32'd0;
            word_count_r   <= 32'd0;
            block_idx_r    <= 32'd0;
            block_count_r  <= ceil_div32(len);
            scale_out_count_r <= 32'd0;
            q_word_idx_r   <= 2'd0;
            quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
            scale_entry_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_input_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_param_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_result_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_lane_mask_r <= 8'd0;
            rms_sumsq_total_r <= 64'd0;
            rms_inv_q15_r <= 32'd0;
            softmax_max_q8_r <= -16'sd32768;
            softmax_sum_r <= 64'd0;
            softmax_op_r <= 2'd0;
            state_r <= S_DECODE;
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            state_r        <= S_IDLE;
            mode_r         <= 8'd0;
            len_r          <= 32'd0;
            done           <= 1'b0;
            error          <= 1'b0;
            error_code     <= ERR_NONE;
            word_idx_r     <= 32'd0;
            word_count_r   <= 32'd0;
            block_idx_r    <= 32'd0;
            block_count_r  <= 32'd0;
            scale_out_count_r <= 32'd0;
            q_word_idx_r   <= 2'd0;
            quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
            scale_entry_word_r <= {AXI_DATA_WIDTH{1'b0}};
            scale_out_row_r <= 16'd0;
            scale_out_accum_r <= 64'sd0;
            scale_accum_start_r <= 1'b0;
            vec_input_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_param_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_result_word_r <= {AXI_DATA_WIDTH{1'b0}};
            vec_lane_mask_r <= 8'd0;
            rms_sumsq_total_r <= 64'd0;
            rms_inv_q15_r <= 32'd0;
            softmax_max_q8_r <= -16'sd32768;
            softmax_sum_r <= 64'd0;
            softmax_op_r <= 2'd0;
            mem_en         <= 1'b0;
            mem_we         <= 1'b0;
            mem_region     <= REGION_IN;
            mem_index      <= 32'd0;
            mem_wdata      <= {AXI_DATA_WIDTH{1'b0}};
            mem_wstrb      <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            mem_en    <= 1'b0;
            mem_we    <= 1'b0;
            mem_wstrb <= {(AXI_DATA_WIDTH/8){1'b0}};
            mem_wdata <= {AXI_DATA_WIDTH{1'b0}};
            scale_accum_start_r <= 1'b0;

            if (soft_reset) begin
                state_r    <= S_IDLE;
                done       <= 1'b0;
                error      <= 1'b0;
                error_code <= ERR_NONE;
                word_idx_r <= 32'd0;
                scale_accum_start_r <= 1'b0;
            end else begin
            if (clear_done && (state_r == S_DONE || state_r == S_ERROR || state_r == S_IDLE)) begin
                done       <= 1'b0;
                error      <= 1'b0;
                error_code <= ERR_NONE;
                if (state_r != S_IDLE)
                    state_r <= S_IDLE;
            end

            case (state_r)
                S_IDLE: begin
                    if (start)
                        restart_command();
                end

                S_DECODE: begin
                    if (mode_r == SPU_MODE_COPY) begin
                        if (len_r == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if (len_r > WORD_DEPTH) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            state_r <= S_COPY_READ;
                        end
                    end else if (mode_r == SPU_MODE_QUANT_Q8_0) begin
                        if (len_r == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if ((ceil_div32(len_r) * Q8_INPUT_WORDS > WORD_DEPTH) ||
                                     (ceil_div32(len_r) * Q8_OUTPUT_WORDS > WORD_DEPTH) ||
                                     (ceil_div32(len_r) > WORD_DEPTH)) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            state_r <= S_Q_READ;
                        end
                    end else if (mode_r == SPU_MODE_Q8_SCALE_ACCUM) begin
                        if (len_r == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if (len_r > WORD_DEPTH) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            scale_out_count_r <= 32'd0;
                            state_r <= S_SA_READ;
                        end
                    end else if (mode_r == SPU_MODE_SILU_MUL ||
                                 mode_r == SPU_MODE_RMSNORM ||
                                 mode_r == SPU_MODE_ROPE ||
                                 mode_r == SPU_MODE_SOFTMAX) begin
                        if (len_r == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if ((ceil_div8(len_r) > WORD_DEPTH) ||
                                     ((mode_r == SPU_MODE_ROPE) && len_r[0])) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            word_count_r <= ceil_div8(len_r);
                            word_idx_r <= 32'd0;
                            if (mode_r == SPU_MODE_RMSNORM) begin
                                rms_sumsq_total_r <= 64'd0;
                                state_r <= S_RMS_SUM_READ;
                            end else if (mode_r == SPU_MODE_SOFTMAX) begin
                                softmax_max_q8_r <= -16'sd32768;
                                softmax_sum_r <= 64'd0;
                                state_r <= S_SOFT_MAX_READ;
                            end else begin
                                state_r <= S_VEC_READ_IN;
                            end
                        end
                    end else begin
                        error <= 1'b1;
                        error_code <= ERR_BAD_MODE;
                        done <= 1'b1;
                        state_r <= S_ERROR;
                    end
                end

                S_COPY_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= word_idx_r;
                    state_r    <= S_COPY_WAIT;
                end

                S_COPY_WAIT: begin
                    state_r <= S_COPY_WRITE;
                end

                S_COPY_WRITE: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_OUT;
                    mem_index  <= word_idx_r;
                    mem_wdata  <= mem_rdata;
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    if (word_idx_r + 32'd1 >= len_r) begin
                        done    <= 1'b1;
                        state_r <= S_DONE;
                    end else begin
                        word_idx_r <= word_idx_r + 32'd1;
                        state_r    <= S_COPY_READ;
                    end
                end

                S_Q_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= block_idx_r * Q8_INPUT_WORDS + q_word_idx_r;
                    state_r    <= S_Q_WAIT;
                end

                S_Q_WAIT: begin
                    state_r <= S_Q_CAPTURE;
                end

                S_Q_CAPTURE: begin
                    quant_values_r[AXI_DATA_WIDTH*q_word_idx_r +: AXI_DATA_WIDTH] <=
                        masked_input_word(mem_rdata, block_idx_r, q_word_idx_r, len_r);
                    if (q_word_idx_r == Q8_INPUT_WORDS - 1) begin
                        q_word_idx_r <= 2'd0;
                        state_r      <= S_Q_COMPUTE;
                    end else begin
                        q_word_idx_r <= q_word_idx_r + 2'd1;
                        state_r      <= S_Q_READ;
                    end
                end

                S_Q_COMPUTE: begin
                    state_r <= S_Q_WAIT_COMPUTE;
                end

                S_Q_WAIT_COMPUTE: begin
                    if (quant_done)
                        state_r <= S_Q_WRITE0;
                end

                S_Q_WRITE0: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_OUT;
                    mem_index  <= block_idx_r * Q8_OUTPUT_WORDS;
                    mem_wdata  <= quant_qs[127:0];
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    state_r    <= S_Q_WRITE1;
                end

                S_Q_WRITE1: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_OUT;
                    mem_index  <= block_idx_r * Q8_OUTPUT_WORDS + 32'd1;
                    mem_wdata  <= quant_qs[255:128];
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    state_r    <= S_Q_WRITE_SCALE;
                end

                S_Q_WRITE_SCALE: begin
                    mem_en           <= 1'b1;
                    mem_we           <= 1'b1;
                    mem_region       <= REGION_SCRATCH;
                    mem_index        <= block_idx_r;
                    mem_wdata        <= {AXI_DATA_WIDTH{1'b0}};
                    mem_wdata[15:0]  <= quant_amax;
                    mem_wdata[16]    <= quant_zero;
                    mem_wstrb        <= 16'h0007;
                    if (block_idx_r + 32'd1 >= block_count_r) begin
                        done    <= 1'b1;
                        state_r <= S_DONE;
                    end else begin
                        block_idx_r    <= block_idx_r + 32'd1;
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
                        state_r        <= S_Q_READ;
                    end
                end

                S_SA_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= word_idx_r;
                    state_r    <= S_SA_WAIT;
                end

                S_SA_WAIT: begin
                    state_r <= S_SA_CAPTURE;
                end

                S_SA_CAPTURE: begin
                    scale_entry_word_r <= mem_rdata;
                    state_r <= S_SA_START;
                end

                S_SA_START: begin
                    scale_accum_start_r <= 1'b1;
                    state_r <= S_SA_WAIT_ACCUM;
                end

                S_SA_WAIT_ACCUM: begin
                    if (scale_accum_entry_done) begin
                        if (scale_accum_error) begin
                            error <= 1'b1;
                            error_code <= (scale_accum_error_code == 4'd1) ?
                                          ERR_BAD_SCALE : ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if (scale_accum_out_valid) begin
                            scale_out_row_r <= scale_accum_out_row_id;
                            scale_out_accum_r <= scale_accum_out_accum_q16;
                            state_r <= S_SA_WRITE_OUT;
                        end else if (word_idx_r + 32'd1 >= len_r) begin
                            state_r <= S_SA_WRITE_STATUS;
                        end else begin
                            word_idx_r <= word_idx_r + 32'd1;
                            state_r <= S_SA_READ;
                        end
                    end
                end

                S_SA_WRITE_OUT: begin
                    mem_en            <= 1'b1;
                    mem_we            <= 1'b1;
                    mem_region        <= REGION_OUT;
                    mem_index         <= scale_out_count_r;
                    mem_wdata         <= {AXI_DATA_WIDTH{1'b0}};
                    mem_wdata[15:0]   <= scale_out_row_r;
                    mem_wdata[79:16]  <= scale_out_accum_r;
                    mem_wstrb         <= 16'h03ff;
                    scale_out_count_r <= scale_out_count_r + 32'd1;
                    if (word_idx_r + 32'd1 >= len_r) begin
                        state_r <= S_SA_WRITE_STATUS;
                    end else begin
                        word_idx_r <= word_idx_r + 32'd1;
                        state_r <= S_SA_READ;
                    end
                end

                S_SA_WRITE_STATUS: begin
                    mem_en           <= 1'b1;
                    mem_we           <= 1'b1;
                    mem_region       <= REGION_SCRATCH;
                    mem_index        <= 32'd0;
                    mem_wdata        <= {AXI_DATA_WIDTH{1'b0}};
                    mem_wdata[31:0]  <= scale_out_count_r;
                    mem_wstrb        <= 16'h000f;
                    done             <= 1'b1;
                    state_r          <= S_DONE;
                end

                S_VEC_READ_IN: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= word_idx_r;
                    state_r    <= S_VEC_WAIT_IN;
                end

                S_VEC_WAIT_IN: begin
                    state_r <= S_VEC_CAPTURE_IN;
                end

                S_VEC_CAPTURE_IN: begin
                    vec_input_word_r <= mem_rdata;
                    vec_lane_mask_r <= lane_mask8(word_idx_r, len_r);
                    state_r <= S_VEC_READ_PARAM;
                end

                S_VEC_READ_PARAM: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_PARAM;
                    mem_index  <= word_idx_r;
                    state_r    <= S_VEC_WAIT_PARAM;
                end

                S_VEC_WAIT_PARAM: begin
                    state_r <= S_VEC_CAPTURE_PARAM;
                end

                S_VEC_CAPTURE_PARAM: begin
                    vec_param_word_r <= mem_rdata;
                    state_r <= S_VEC_START;
                end

                S_VEC_START: begin
                    state_r <= S_VEC_WAIT_OP;
                end

                S_VEC_WAIT_OP: begin
                    if (vec_done) begin
                        vec_result_word_r <= vec_result;
                        state_r <= S_VEC_WRITE_OUT;
                    end
                end

                S_VEC_WRITE_OUT: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_OUT;
                    mem_index  <= word_idx_r;
                    mem_wdata  <= vec_result_word_r;
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    if (word_idx_r + 32'd1 >= word_count_r) begin
                        done <= 1'b1;
                        state_r <= S_DONE;
                    end else begin
                        word_idx_r <= word_idx_r + 32'd1;
                        state_r <= S_VEC_READ_IN;
                    end
                end

                S_RMS_SUM_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= word_idx_r;
                    state_r    <= S_RMS_SUM_WAIT;
                end

                S_RMS_SUM_WAIT: begin
                    state_r <= S_RMS_SUM_CAPTURE;
                end

                S_RMS_SUM_CAPTURE: begin
                    vec_input_word_r <= mem_rdata;
                    vec_param_word_r <= {AXI_DATA_WIDTH{1'b0}};
                    vec_lane_mask_r <= lane_mask8(word_idx_r, len_r);
                    state_r <= S_RMS_SUM_START;
                end

                S_RMS_SUM_START: begin
                    state_r <= S_RMS_SUM_WAIT_OP;
                end

                S_RMS_SUM_WAIT_OP: begin
                    if (rms_done) begin
                        rms_sumsq_total_r <= rms_sumsq_total_r + rms_word_sumsq_q16;
                        if (word_idx_r + 32'd1 >= word_count_r) begin
                            state_r <= S_RMS_INV_START;
                        end else begin
                            word_idx_r <= word_idx_r + 32'd1;
                            state_r <= S_RMS_SUM_READ;
                        end
                    end
                end

                S_RMS_INV_START: begin
                    state_r <= S_RMS_INV_WAIT;
                end

                S_RMS_INV_WAIT: begin
                    if (rms_inv_done) begin
                        if (rms_inv_error) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            rms_inv_q15_r <= rms_inv_value_q15;
                            word_idx_r <= 32'd0;
                            state_r <= S_VEC_READ_IN;
                        end
                    end
                end

                S_SOFT_MAX_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= word_idx_r;
                    state_r    <= S_SOFT_MAX_WAIT;
                end

                S_SOFT_MAX_WAIT: begin
                    state_r <= S_SOFT_MAX_CAPTURE;
                end

                S_SOFT_MAX_CAPTURE: begin
                    vec_input_word_r <= mem_rdata;
                    vec_lane_mask_r <= lane_mask8(word_idx_r, len_r);
                    softmax_op_r <= 2'd0;
                    state_r <= S_SOFT_MAX_START;
                end

                S_SOFT_MAX_START: begin
                    state_r <= S_SOFT_MAX_WAIT_OP;
                end

                S_SOFT_MAX_WAIT_OP: begin
                    if (softmax_done) begin
                        if (softmax_word_max_q8 > softmax_max_q8_r)
                            softmax_max_q8_r <= softmax_word_max_q8;
                        if (word_idx_r + 32'd1 >= word_count_r) begin
                            word_idx_r <= 32'd0;
                            softmax_sum_r <= 64'd0;
                            state_r <= S_SOFT_SCORE_READ;
                        end else begin
                            word_idx_r <= word_idx_r + 32'd1;
                            state_r <= S_SOFT_MAX_READ;
                        end
                    end
                end

                S_SOFT_SCORE_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_IN;
                    mem_index  <= word_idx_r;
                    state_r    <= S_SOFT_SCORE_WAIT;
                end

                S_SOFT_SCORE_WAIT: begin
                    state_r <= S_SOFT_SCORE_CAPTURE;
                end

                S_SOFT_SCORE_CAPTURE: begin
                    vec_input_word_r <= mem_rdata;
                    vec_lane_mask_r <= lane_mask8(word_idx_r, len_r);
                    softmax_op_r <= 2'd1;
                    state_r <= S_SOFT_SCORE_START;
                end

                S_SOFT_SCORE_START: begin
                    state_r <= S_SOFT_SCORE_WAIT_OP;
                end

                S_SOFT_SCORE_WAIT_OP: begin
                    if (softmax_done) begin
                        vec_result_word_r <= softmax_output_word;
                        softmax_sum_r <= softmax_sum_r + softmax_word_sum;
                        state_r <= S_SOFT_SCORE_WRITE;
                    end
                end

                S_SOFT_SCORE_WRITE: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_SCRATCH;
                    mem_index  <= word_idx_r;
                    mem_wdata  <= vec_result_word_r;
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    if (word_idx_r + 32'd1 >= word_count_r) begin
                        word_idx_r <= 32'd0;
                        state_r <= S_SOFT_NORM_READ;
                    end else begin
                        word_idx_r <= word_idx_r + 32'd1;
                        state_r <= S_SOFT_SCORE_READ;
                    end
                end

                S_SOFT_NORM_READ: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b0;
                    mem_region <= REGION_SCRATCH;
                    mem_index  <= word_idx_r;
                    state_r    <= S_SOFT_NORM_WAIT;
                end

                S_SOFT_NORM_WAIT: begin
                    state_r <= S_SOFT_NORM_CAPTURE;
                end

                S_SOFT_NORM_CAPTURE: begin
                    vec_input_word_r <= mem_rdata;
                    vec_lane_mask_r <= lane_mask8(word_idx_r, len_r);
                    softmax_op_r <= 2'd2;
                    state_r <= S_SOFT_NORM_START;
                end

                S_SOFT_NORM_START: begin
                    state_r <= S_SOFT_NORM_WAIT_OP;
                end

                S_SOFT_NORM_WAIT_OP: begin
                    if (softmax_done) begin
                        vec_result_word_r <= softmax_output_word;
                        state_r <= S_SOFT_NORM_WRITE;
                    end
                end

                S_SOFT_NORM_WRITE: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_OUT;
                    mem_index  <= word_idx_r;
                    mem_wdata  <= vec_result_word_r;
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    if (word_idx_r + 32'd1 >= word_count_r) begin
                        done <= 1'b1;
                        state_r <= S_DONE;
                    end else begin
                        word_idx_r <= word_idx_r + 32'd1;
                        state_r <= S_SOFT_NORM_READ;
                    end
                end

                S_DONE: begin
                    if (start)
                        restart_command();
                end

                S_ERROR: begin
                    if (start)
                        restart_command();
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
            end
        end
    end

endmodule
