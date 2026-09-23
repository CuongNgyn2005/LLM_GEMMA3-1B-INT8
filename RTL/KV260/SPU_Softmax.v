/*
 * Module      : SPU_Softmax
 * Description : Fixed-point softmax helper.
 *
 * Memory contract used by SPU_Controller:
 *   SPU_IN      word N : eight signed Q8.8 logits
 *   SPU_SCRATCH word N : eight unsigned Q0.15 exp-score approximations
 *   SPU_OUT     word N : eight unsigned Q0.15 probabilities
 *
 * The controller performs three passes.  This module supplies the per-word
 * max, exp-score, and normalization datapaths.  The normalization divider is
 * iterative to avoid synthesizing a wide variable divider on the timing path.
 */

`timescale 1ns/1ps

module SPU_Softmax #(
    parameter integer AXI_DATA_WIDTH = 128
) (
    input  wire                              clk,
    input  wire                              resetn,
    input  wire                              start,
    input  wire [1:0]                        op,
    input  wire [AXI_DATA_WIDTH-1:0]         input_word,
    input  wire signed [15:0]                max_value_q8,
    input  wire [63:0]                       sum_value,
    input  wire [7:0]                        lane_valid,
    output reg                               busy,
    output reg                               done,
    output reg  [AXI_DATA_WIDTH-1:0]         output_word,
    output reg  signed [15:0]                word_max_q8,
    output reg  [63:0]                       word_sum,
    output wire                              supported
);
    localparam integer LANES = AXI_DATA_WIDTH / 16;
    localparam [1:0] OP_MAX   = 2'd0;
    localparam [1:0] OP_SCORE = 2'd1;
    localparam [1:0] OP_NORM  = 2'd2;

    localparam [2:0] S_IDLE        = 3'd0;
    localparam [2:0] S_LANE        = 3'd1;
    localparam [2:0] S_WRITE_SCORE = 3'd2;
    localparam [2:0] S_DIV         = 3'd3;
    localparam [2:0] S_DIV_OUT     = 3'd4;
    localparam [2:0] S_WRITE_NORM  = 3'd5;
    localparam [2:0] S_NEXT        = 3'd6;

    assign supported = 1'b1;

    reg [2:0] state_r;
    reg [2:0] lane_idx_r;
    reg [1:0] op_r;
    reg [AXI_DATA_WIDTH-1:0] input_word_r;
    reg signed [15:0] max_value_q8_r;
    reg [63:0] sum_value_r;
    reg [7:0] lane_valid_r;
    reg lane_active_r;
    reg signed [15:0] lane_value_r;
    reg [15:0] lane_score_r;

    reg [63:0] div_num_r;
    reg [64:0] div_rem_r;
    reg [63:0] div_quot_r;
    reg [63:0] div_denom_r;
    reg [6:0] div_count_r;
    reg [64:0] div_rem_shift;
    reg [64:0] div_denom_ext;

    function [15:0] exp_score_q15;
        input signed [15:0] delta_q8;
        begin
            if (delta_q8 >= 16'sd0)
                exp_score_q15 = 16'd32768;
            else if (delta_q8 >= -16'sd128)
                exp_score_q15 = 16'd19872;
            else if (delta_q8 >= -16'sd256)
                exp_score_q15 = 16'd12055;
            else if (delta_q8 >= -16'sd384)
                exp_score_q15 = 16'd7310;
            else if (delta_q8 >= -16'sd512)
                exp_score_q15 = 16'd4435;
            else if (delta_q8 >= -16'sd640)
                exp_score_q15 = 16'd2690;
            else if (delta_q8 >= -16'sd768)
                exp_score_q15 = 16'd1631;
            else if (delta_q8 >= -16'sd896)
                exp_score_q15 = 16'd989;
            else if (delta_q8 >= -16'sd1024)
                exp_score_q15 = 16'd600;
            else if (delta_q8 >= -16'sd1280)
                exp_score_q15 = 16'd221;
            else if (delta_q8 >= -16'sd1536)
                exp_score_q15 = 16'd81;
            else if (delta_q8 >= -16'sd1792)
                exp_score_q15 = 16'd30;
            else if (delta_q8 >= -16'sd2048)
                exp_score_q15 = 16'd11;
            else
                exp_score_q15 = 16'd0;
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            lane_idx_r <= 3'd0;
            op_r <= OP_MAX;
            busy <= 1'b0;
            done <= 1'b0;
            output_word <= {AXI_DATA_WIDTH{1'b0}};
            word_max_q8 <= -16'sd32768;
            word_sum <= 64'd0;
            input_word_r <= {AXI_DATA_WIDTH{1'b0}};
            max_value_q8_r <= 16'sd0;
            sum_value_r <= 64'd0;
            lane_valid_r <= 8'd0;
            lane_active_r <= 1'b0;
            lane_value_r <= 16'sd0;
            lane_score_r <= 16'd0;
            div_num_r <= 64'd0;
            div_rem_r <= 65'd0;
            div_quot_r <= 64'd0;
            div_denom_r <= 64'd0;
            div_count_r <= 7'd0;
        end else begin
            done <= 1'b0;

            case (state_r)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        op_r <= op;
                        lane_idx_r <= 3'd0;
                        input_word_r <= input_word;
                        max_value_q8_r <= max_value_q8;
                        sum_value_r <= sum_value;
                        lane_valid_r <= lane_valid;
                        lane_active_r <= lane_valid[0];
                        lane_value_r <= input_word[15:0];
                        output_word <= {AXI_DATA_WIDTH{1'b0}};
                        word_max_q8 <= -16'sd32768;
                        word_sum <= 64'd0;
                        state_r <= S_LANE;
                    end
                end

                S_LANE: begin
                    busy <= 1'b1;
                    if (op_r == OP_MAX) begin
                        if (lane_active_r && (lane_value_r > word_max_q8))
                            word_max_q8 <= lane_value_r;
                        state_r <= S_NEXT;
                    end else if (op_r == OP_SCORE) begin
                        lane_score_r <= exp_score_q15(lane_value_r - max_value_q8_r);
                        state_r <= S_WRITE_SCORE;
                    end else begin
                        lane_score_r <= lane_value_r;
                        if (lane_active_r && (sum_value_r != 64'd0)) begin
                            div_num_r <= ({48'd0, lane_value_r} << 15);
                            div_rem_r <= 65'd0;
                            div_quot_r <= 64'd0;
                            div_denom_r <= sum_value_r;
                            div_count_r <= 7'd64;
                            state_r <= S_DIV;
                        end else begin
                            lane_score_r <= 16'd0;
                            state_r <= S_WRITE_NORM;
                        end
                    end
                end

                S_WRITE_SCORE: begin
                    busy <= 1'b1;
                    if (lane_active_r) begin
                        output_word[16*lane_idx_r +: 16] <= lane_score_r;
                        word_sum <= word_sum + {48'd0, lane_score_r};
                    end
                    state_r <= S_NEXT;
                end

                S_DIV: begin
                    busy <= 1'b1;
                    div_rem_shift = {div_rem_r[63:0], div_num_r[63]};
                    div_denom_ext = {1'b0, div_denom_r};
                    div_num_r <= {div_num_r[62:0], 1'b0};
                    if (div_rem_shift >= div_denom_ext) begin
                        div_rem_r <= div_rem_shift - div_denom_ext;
                        div_quot_r <= {div_quot_r[62:0], 1'b1};
                    end else begin
                        div_rem_r <= div_rem_shift;
                        div_quot_r <= {div_quot_r[62:0], 1'b0};
                    end

                    if (div_count_r == 7'd1)
                        state_r <= S_DIV_OUT;
                    div_count_r <= div_count_r - 7'd1;
                end

                S_DIV_OUT: begin
                    busy <= 1'b1;
                    lane_score_r <= div_quot_r[15:0];
                    state_r <= S_WRITE_NORM;
                end

                S_WRITE_NORM: begin
                    busy <= 1'b1;
                    if (lane_active_r)
                        output_word[16*lane_idx_r +: 16] <= lane_score_r;
                    state_r <= S_NEXT;
                end

                S_NEXT: begin
                    busy <= 1'b1;
                    if (lane_idx_r == (LANES - 1)) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state_r <= S_IDLE;
                    end else begin
                        lane_idx_r <= lane_idx_r + 3'd1;
                        lane_active_r <= lane_valid_r[lane_idx_r + 3'd1];
                        lane_value_r <= input_word_r[16*(lane_idx_r + 3'd1) +: 16];
                        state_r <= S_LANE;
                    end
                end

                default: begin
                    busy <= 1'b0;
                    state_r <= S_IDLE;
                end
            endcase
        end
    end
endmodule
