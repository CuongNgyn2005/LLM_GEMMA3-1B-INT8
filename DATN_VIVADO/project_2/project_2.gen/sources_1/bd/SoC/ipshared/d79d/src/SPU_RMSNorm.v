/*
 * Module      : SPU_RMSNorm
 * Description : Fixed-point RMSNorm lane helper.
 *
 * Memory contract used by SPU_Controller:
 *   SPU_IN    word N : eight signed Q8.8 input values
 *   SPU_PARAM word N : eight signed Q8.8 weight values
 *   SPU_OUT   word N : eight signed Q8.8 normalized values
 *
 * The controller performs the vector square-sum pass and provides inv_rms_q15.
 * This helper processes one lane at a time through registered multiply stages
 * so the RMSNorm lane arithmetic is not an 8-lane combinational cone.
 */

`timescale 1ns/1ps

module SPU_RMSNorm #(
    parameter integer AXI_DATA_WIDTH = 128
) (
    input  wire                              clk,
    input  wire                              resetn,
    input  wire                              start,
    input  wire [AXI_DATA_WIDTH-1:0]         input_word,
    input  wire [AXI_DATA_WIDTH-1:0]         weight_word,
    input  wire [31:0]                       inv_rms_q15,
    input  wire [7:0]                        lane_valid,
    output reg                               busy,
    output reg                               done,
    output reg  [AXI_DATA_WIDTH-1:0]         result_word,
    output reg  [63:0]                       word_sumsq_q16,
    output wire                              supported
);
    localparam integer LANES = AXI_DATA_WIDTH / 16;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_MUL_A = 2'd1;
    localparam [1:0] S_MUL_B = 2'd2;
    localparam [1:0] S_WRITE = 2'd3;

    assign supported = 1'b1;

    reg [1:0] state_r;
    reg [2:0] lane_idx_r;
    reg [AXI_DATA_WIDTH-1:0] input_word_r;
    reg [AXI_DATA_WIDTH-1:0] weight_word_r;
    reg [7:0] lane_valid_r;
    reg [31:0] inv_rms_q15_r;
    reg lane_active_r;
    reg signed [31:0] value_ext_r;
    reg signed [31:0] weight_ext_r;
    reg signed [63:0] value_weight_r;
    reg signed [63:0] norm_product_r;
    reg [63:0] sumsq_product_r;

    // Keep the normalization multiplier off the FSM-state enable path.  The
    // operands are already registered one state earlier, and S_WRITE
    // consumes norm_product_r one cycle after this product is captured.
    wire signed [63:0] norm_product_w =
        value_weight_r * $signed({1'b0, inv_rms_q15_r[30:0]});

    // The Q8.8 result is norm_product_r >>> 23.  Retain only the 41 bits
    // that can affect the signed-16 saturation decision, then detect whether
    // bits above bit 15 are a valid sign extension.  This is equivalent to
    // the former two 64-bit signed comparisons, but avoids their long carry
    // chains on the DSP-output-to-result-word timing path.
    wire signed [40:0] norm_scaled_w = norm_product_r[63:23];
    wire norm_pos_sat_w = !norm_scaled_w[40] && |norm_scaled_w[39:15];
    wire norm_neg_sat_w =  norm_scaled_w[40] && ~&norm_scaled_w[39:15];
    wire signed [15:0] norm_sat16_w = norm_pos_sat_w ? 16'sd32767 :
                                      norm_neg_sat_w ? -16'sd32768 :
                                                       norm_scaled_w[15:0];

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            lane_idx_r <= 3'd0;
            busy <= 1'b0;
            done <= 1'b0;
            result_word <= {AXI_DATA_WIDTH{1'b0}};
            word_sumsq_q16 <= 64'd0;
            input_word_r <= {AXI_DATA_WIDTH{1'b0}};
            weight_word_r <= {AXI_DATA_WIDTH{1'b0}};
            lane_valid_r <= 8'd0;
            inv_rms_q15_r <= 32'd0;
            lane_active_r <= 1'b0;
            value_ext_r <= 32'sd0;
            weight_ext_r <= 32'sd0;
            value_weight_r <= 64'sd0;
            norm_product_r <= 64'sd0;
            sumsq_product_r <= 64'd0;
        end else begin
            done <= 1'b0;
            norm_product_r <= lane_active_r ? norm_product_w : 64'sd0;

            case (state_r)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        lane_idx_r <= 3'd0;
                        input_word_r <= input_word;
                        weight_word_r <= weight_word;
                        lane_valid_r <= lane_valid;
                        inv_rms_q15_r <= inv_rms_q15;
                        result_word <= {AXI_DATA_WIDTH{1'b0}};
                        word_sumsq_q16 <= 64'd0;
                        state_r <= S_MUL_A;
                    end
                end

                S_MUL_A: begin
                    busy <= 1'b1;
                    lane_active_r <= lane_valid_r[lane_idx_r];
                    value_ext_r <= {{16{input_word_r[16*lane_idx_r + 15]}},
                                    input_word_r[16*lane_idx_r +: 16]};
                    weight_ext_r <= {{16{weight_word_r[16*lane_idx_r + 15]}},
                                     weight_word_r[16*lane_idx_r +: 16]};
                    value_weight_r <=
                        $signed({{16{input_word_r[16*lane_idx_r + 15]}},
                                 input_word_r[16*lane_idx_r +: 16]}) *
                        $signed({{16{weight_word_r[16*lane_idx_r + 15]}},
                                 weight_word_r[16*lane_idx_r +: 16]});
                    sumsq_product_r <=
                        $signed({{16{input_word_r[16*lane_idx_r + 15]}},
                                 input_word_r[16*lane_idx_r +: 16]}) *
                        $signed({{16{input_word_r[16*lane_idx_r + 15]}},
                                 input_word_r[16*lane_idx_r +: 16]});
                    state_r <= S_MUL_B;
                end

                S_MUL_B: begin
                    busy <= 1'b1;
                    if (lane_active_r) begin
                        word_sumsq_q16 <= word_sumsq_q16 + sumsq_product_r;
                    end
                    state_r <= S_WRITE;
                end

                S_WRITE: begin
                    busy <= 1'b1;
                    if (lane_active_r)
                        result_word[16*lane_idx_r +: 16] <=
                            norm_sat16_w;

                    if (lane_idx_r == (LANES - 1)) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state_r <= S_IDLE;
                    end else begin
                        lane_idx_r <= lane_idx_r + 3'd1;
                        state_r <= S_MUL_A;
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
