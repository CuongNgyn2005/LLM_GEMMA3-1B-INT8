/*
 * Module      : SPU_SiLU_Mul
 * Description : Fixed-point FFN activation helper.
 *
 * Memory contract used by SPU_Controller:
 *   SPU_IN    word N : eight signed Q8.8 gate values
 *   SPU_PARAM word N : eight signed Q8.8 up values
 *   SPU_OUT   word N : eight signed Q8.8 SiLU(gate) * up values
 *
 * The sigmoid is a clipped linear hardware approximation:
 *   sigmoid(x) = 0                    for x <= -4
 *              = 1                    for x >=  4
 *              = 0.5 + x/8            otherwise
 */

`timescale 1ns/1ps

module SPU_SiLU_Mul #(
    parameter integer AXI_DATA_WIDTH = 128
) (
    input  wire                              clk,
    input  wire                              resetn,
    input  wire                              start,
    input  wire [AXI_DATA_WIDTH-1:0]         gate_word,
    input  wire [AXI_DATA_WIDTH-1:0]         up_word,
    input  wire [7:0]                        lane_valid,
    output reg                               busy,
    output reg                               done,
    output reg  [AXI_DATA_WIDTH-1:0]         result_word,
    output wire                              supported
);
    localparam integer LANES = AXI_DATA_WIDTH / 16;

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_SILU   = 3'd1;
    localparam [2:0] S_MUL    = 3'd2;
    localparam [2:0] S_WRITE  = 3'd3;
    localparam [2:0] S_COMMIT = 3'd4;

    assign supported = 1'b1;

    reg [2:0] state_r;
    reg [2:0] lane_idx_r;
    reg [AXI_DATA_WIDTH-1:0] gate_word_r;
    reg [AXI_DATA_WIDTH-1:0] up_word_r;
    reg [7:0] lane_valid_r;
    reg lane_active_r;
    reg signed [15:0] gate_q8_r;
    reg signed [15:0] up_q8_r;
    reg signed [31:0] sigmoid_q15_r;
    // After (gate_q8 * sigmoid_q15) >>> 15, the full mathematical range is
    // signed Q8.8 [-32768, 32767].  Keeping this value at 16 bits lets the
    // following SiLU*up operation map to one native 16x16 DSP multiply rather
    // than a cascaded 48x16 implementation.
    reg signed [15:0] silu_q8_r;
    reg signed [31:0] result_q8_r;

    function signed [15:0] sat16;
        input signed [31:0] value;
        begin
            if (value > 32'sd32767)
                sat16 = 16'sd32767;
            else if (value < -32'sd32768)
                sat16 = -16'sd32768;
            else
                sat16 = value[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            lane_idx_r <= 3'd0;
            busy <= 1'b0;
            done <= 1'b0;
            result_word <= {AXI_DATA_WIDTH{1'b0}};
            gate_word_r <= {AXI_DATA_WIDTH{1'b0}};
            up_word_r <= {AXI_DATA_WIDTH{1'b0}};
            lane_valid_r <= 8'd0;
            lane_active_r <= 1'b0;
            gate_q8_r <= 16'sd0;
            up_q8_r <= 16'sd0;
            sigmoid_q15_r <= 32'sd0;
            silu_q8_r <= 16'sd0;
            result_q8_r <= 32'sd0;
        end else begin
            done <= 1'b0;

            case (state_r)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        gate_word_r <= gate_word;
                        up_word_r <= up_word;
                        lane_valid_r <= lane_valid;
                        lane_idx_r <= 3'd0;
                        result_word <= {AXI_DATA_WIDTH{1'b0}};
                        state_r <= S_SILU;
                    end
                end

                S_SILU: begin
                    busy <= 1'b1;
                    gate_q8_r <= gate_word_r[16*lane_idx_r +: 16];
                    up_q8_r <= up_word_r[16*lane_idx_r +: 16];
                    lane_active_r <= lane_valid_r[lane_idx_r];
                    if ($signed(gate_word_r[16*lane_idx_r +: 16]) >= 16'sd1024)
                        sigmoid_q15_r <= 32'sd32768;
                    else if ($signed(gate_word_r[16*lane_idx_r +: 16]) <= -16'sd1024)
                        sigmoid_q15_r <= 32'sd0;
                    else
                        sigmoid_q15_r <= 32'sd16384 +
                                         ($signed(gate_word_r[16*lane_idx_r +: 16]) <<< 4);
                    state_r <= S_MUL;
                end

                S_MUL: begin
                    busy <= 1'b1;
                    silu_q8_r <= ($signed(gate_q8_r) * sigmoid_q15_r) >>> 15;
                    state_r <= S_WRITE;
                end

                S_WRITE: begin
                    busy <= 1'b1;
                    result_q8_r <= (silu_q8_r * $signed(up_q8_r)) >>> 8;
                    state_r <= S_COMMIT;
                end

                S_COMMIT: begin
                    busy <= 1'b1;
                    if (lane_active_r)
                        result_word[16*lane_idx_r +: 16] <=
                            sat16(result_q8_r);

                    if (lane_idx_r == (LANES - 1)) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state_r <= S_IDLE;
                    end else begin
                        lane_idx_r <= lane_idx_r + 3'd1;
                        state_r <= S_SILU;
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
