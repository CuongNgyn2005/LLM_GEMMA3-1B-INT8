/*
 * Module      : SPU_RoPE
 * Description : Fixed-point rotary embedding helper.
 *
 * Memory contract used by SPU_Controller:
 *   SPU_IN    word N : four signed Q8.8 pairs {x0, x1}
 *   SPU_PARAM word N : four Q1.15 pairs {cos, sin}
 *   SPU_OUT   word N : four signed Q8.8 rotated pairs
 */

`timescale 1ns/1ps

module SPU_RoPE #(
    parameter integer AXI_DATA_WIDTH = 128
) (
    input  wire                              clk,
    input  wire                              resetn,
    input  wire                              start,
    input  wire [AXI_DATA_WIDTH-1:0]         input_word,
    input  wire [AXI_DATA_WIDTH-1:0]         trig_word,
    input  wire [7:0]                        lane_valid,
    output reg                               busy,
    output reg                               done,
    output reg  [AXI_DATA_WIDTH-1:0]         result_word,
    output wire                              supported
);
    localparam integer PAIRS = AXI_DATA_WIDTH / 32;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_MUL0  = 2'd1;
    localparam [1:0] S_MUL1  = 2'd2;
    localparam [1:0] S_WRITE = 2'd3;

    assign supported = 1'b1;

    reg [1:0] state_r;
    reg [1:0] pair_idx_r;
    reg [AXI_DATA_WIDTH-1:0] input_word_r;
    reg [AXI_DATA_WIDTH-1:0] trig_word_r;
    reg [7:0] lane_valid_r;
    reg pair_active_r;
    reg signed [15:0] x0_q8_r;
    reg signed [15:0] x1_q8_r;
    reg signed [15:0] cos_q15_r;
    reg signed [15:0] sin_q15_r;
    reg signed [47:0] x0_cos_r;
    reg signed [47:0] x1_sin_r;
    reg signed [47:0] x0_sin_r;
    reg signed [47:0] x1_cos_r;

    function signed [15:0] sat16;
        input signed [47:0] value;
        begin
            if (value > 48'sd32767)
                sat16 = 16'sd32767;
            else if (value < -48'sd32768)
                sat16 = -16'sd32768;
            else
                sat16 = value[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            pair_idx_r <= 2'd0;
            busy <= 1'b0;
            done <= 1'b0;
            result_word <= {AXI_DATA_WIDTH{1'b0}};
            input_word_r <= {AXI_DATA_WIDTH{1'b0}};
            trig_word_r <= {AXI_DATA_WIDTH{1'b0}};
            lane_valid_r <= 8'd0;
            pair_active_r <= 1'b0;
            x0_q8_r <= 16'sd0;
            x1_q8_r <= 16'sd0;
            cos_q15_r <= 16'sd0;
            sin_q15_r <= 16'sd0;
            x0_cos_r <= 48'sd0;
            x1_sin_r <= 48'sd0;
            x0_sin_r <= 48'sd0;
            x1_cos_r <= 48'sd0;
        end else begin
            done <= 1'b0;

            case (state_r)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        pair_idx_r <= 2'd0;
                        input_word_r <= input_word;
                        trig_word_r <= trig_word;
                        lane_valid_r <= lane_valid;
                        result_word <= {AXI_DATA_WIDTH{1'b0}};
                        state_r <= S_MUL0;
                    end
                end

                S_MUL0: begin
                    busy <= 1'b1;
                    x0_q8_r <= input_word_r[32*pair_idx_r +: 16];
                    x1_q8_r <= input_word_r[32*pair_idx_r + 16 +: 16];
                    cos_q15_r <= trig_word_r[32*pair_idx_r +: 16];
                    sin_q15_r <= trig_word_r[32*pair_idx_r + 16 +: 16];
                    pair_active_r <=
                        lane_valid_r[2*pair_idx_r] ||
                        lane_valid_r[2*pair_idx_r + 1];
                    x0_cos_r <=
                        $signed(input_word_r[32*pair_idx_r +: 16]) *
                        $signed(trig_word_r[32*pair_idx_r +: 16]);
                    x1_sin_r <=
                        $signed(input_word_r[32*pair_idx_r + 16 +: 16]) *
                        $signed(trig_word_r[32*pair_idx_r + 16 +: 16]);
                    state_r <= S_MUL1;
                end

                S_MUL1: begin
                    busy <= 1'b1;
                    x0_sin_r <= $signed(x0_q8_r) * $signed(sin_q15_r);
                    x1_cos_r <= $signed(x1_q8_r) * $signed(cos_q15_r);
                    state_r <= S_WRITE;
                end

                S_WRITE: begin
                    busy <= 1'b1;
                    if (pair_active_r) begin
                        if (lane_valid_r[2*pair_idx_r])
                            result_word[32*pair_idx_r +: 16] <=
                                sat16((x0_cos_r - x1_sin_r) >>> 15);
                        if (lane_valid_r[2*pair_idx_r + 1])
                            result_word[32*pair_idx_r + 16 +: 16] <=
                                sat16((x0_sin_r + x1_cos_r) >>> 15);
                    end

                    if (pair_idx_r == (PAIRS - 1)) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state_r <= S_IDLE;
                    end else begin
                        pair_idx_r <= pair_idx_r + 2'd1;
                        state_r <= S_MUL0;
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
