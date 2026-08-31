/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Quantize_Q8_0
 * Description : Timing-safe exact fixed-point activation quantizer for SPU.
 *
 * One q8 block contains 32 signed INT16 values.  The module scans for amax,
 * then quantizes one value at a time with a 23-step restoring divider.  The
 * arithmetic matches round-to-nearest (magnitude) q8 quantization but never
 * infers the large combinational variable divider that previously created a
 * 29 ns, 184-level timing path at 187.5 MHz.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Quantize_Q8_0 #(
    parameter integer INPUT_WIDTH  = 16,
    parameter integer OUTPUT_WIDTH = 8,
    parameter integer BLOCK_SIZE   = 32
) (
    input  wire                                  clk,
    input  wire                                  resetn,
    input  wire                                  start,
    input  wire [INPUT_WIDTH*BLOCK_SIZE-1:0]     values_in,
    output reg                                   busy,
    output reg                                   done,
    output reg  [OUTPUT_WIDTH*BLOCK_SIZE-1:0]   qs_out,
    output reg  [15:0]                          scale_amax,
    output reg                                   zero_block
);

    localparam integer INDEX_WIDTH    = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE);
    localparam integer DIVIDEND_WIDTH = 23;
    localparam integer REM_WIDTH      = 17;

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_FIND_MAX = 3'd1;
    localparam [2:0] S_PREPARE  = 3'd2;
    localparam [2:0] S_DIVIDE   = 3'd3;

    reg [2:0] state_r;
    reg [INPUT_WIDTH*BLOCK_SIZE-1:0] values_r;
    reg [INDEX_WIDTH-1:0] sample_index_r;
    reg [15:0] max_abs_r;
    reg sign_r;

    reg [DIVIDEND_WIDTH-1:0] dividend_r;
    reg [REM_WIDTH-1:0] div_remainder_r;
    reg [DIVIDEND_WIDTH-1:0] div_quotient_r;
    reg [4:0] div_bits_left_r;

    function [15:0] abs16;
        input signed [15:0] value;
        begin
            if (value == -16'sd32768)
                abs16 = 16'd32768;
            else if (value < 0)
                abs16 = 16'd0 - value[15:0];
            else
                abs16 = value[15:0];
        end
    endfunction

    function [7:0] signed_quantized_byte;
        input sign_bit;
        input [DIVIDEND_WIDTH-1:0] magnitude;
        begin
            if (sign_bit) begin
                if (magnitude > 23'd128)
                    signed_quantized_byte = 8'h80;
                else
                    signed_quantized_byte = (~magnitude[7:0]) + 8'd1;
            end else begin
                if (magnitude > 23'd127)
                    signed_quantized_byte = 8'h7f;
                else
                    signed_quantized_byte = magnitude[7:0];
            end
        end
    endfunction

    wire signed [15:0] selected_value_w =
        values_r[INPUT_WIDTH*sample_index_r +: INPUT_WIDTH];
    wire [15:0] selected_abs_w = abs16(selected_value_w);
    wire [15:0] max_after_scan_w =
        (selected_abs_w > max_abs_r) ? selected_abs_w : max_abs_r;

    // |x| * 127 + amax / 2.  The shift/subtract form avoids a multiplier and
    // creates the same positive magnitude used by round-to-nearest division.
    wire [DIVIDEND_WIDTH-1:0] rounded_dividend_w =
        ({7'd0, selected_abs_w} << 7) - {7'd0, selected_abs_w} +
        {7'd0, (max_abs_r >> 1)};

    // One restoring-division bit is generated each cycle.  Quotient shifts
    // left, so there is no variable barrel shifter in the timing-critical path.
    wire [REM_WIDTH-1:0] div_trial_w =
        {div_remainder_r[REM_WIDTH-2:0], dividend_r[div_bits_left_r - 5'd1]};
    wire div_ge_w = div_trial_w >= {1'b0, max_abs_r};
    wire [REM_WIDTH-1:0] div_remainder_next_w =
        div_ge_w ? (div_trial_w - {1'b0, max_abs_r}) : div_trial_w;
    wire [DIVIDEND_WIDTH-1:0] div_quotient_next_w =
        {div_quotient_r[DIVIDEND_WIDTH-2:0], div_ge_w};

    always @(posedge clk) begin
        if (!resetn) begin
            state_r          <= S_IDLE;
            values_r         <= {INPUT_WIDTH*BLOCK_SIZE{1'b0}};
            sample_index_r   <= {INDEX_WIDTH{1'b0}};
            max_abs_r        <= 16'd0;
            sign_r           <= 1'b0;
            dividend_r       <= {DIVIDEND_WIDTH{1'b0}};
            div_remainder_r  <= {REM_WIDTH{1'b0}};
            div_quotient_r   <= {DIVIDEND_WIDTH{1'b0}};
            div_bits_left_r  <= 5'd0;
            busy             <= 1'b0;
            done             <= 1'b0;
            qs_out           <= {OUTPUT_WIDTH*BLOCK_SIZE{1'b0}};
            scale_amax       <= 16'd0;
            zero_block       <= 1'b1;
        end else begin
            case (state_r)
                S_IDLE: begin
                    if (start) begin
                        values_r        <= values_in;
                        sample_index_r  <= {INDEX_WIDTH{1'b0}};
                        max_abs_r       <= 16'd0;
                        qs_out          <= {OUTPUT_WIDTH*BLOCK_SIZE{1'b0}};
                        scale_amax      <= 16'd0;
                        zero_block      <= 1'b1;
                        done            <= 1'b0;
                        busy            <= 1'b1;
                        state_r         <= S_FIND_MAX;
                    end
                end

                S_FIND_MAX: begin
                    max_abs_r <= max_after_scan_w;
                    if (sample_index_r == BLOCK_SIZE - 1) begin
                        scale_amax     <= max_after_scan_w;
                        zero_block     <= (max_after_scan_w == 16'd0);
                        sample_index_r <= {INDEX_WIDTH{1'b0}};
                        state_r        <= S_PREPARE;
                    end else begin
                        sample_index_r <= sample_index_r + 1'b1;
                    end
                end

                S_PREPARE: begin
                    if (max_abs_r == 16'd0) begin
                        qs_out[OUTPUT_WIDTH*sample_index_r +: OUTPUT_WIDTH] <= 8'd0;
                        if (sample_index_r == BLOCK_SIZE - 1) begin
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            state_r <= S_IDLE;
                        end else begin
                            sample_index_r <= sample_index_r + 1'b1;
                        end
                    end else begin
                        sign_r          <= selected_value_w[INPUT_WIDTH-1];
                        dividend_r      <= rounded_dividend_w;
                        div_remainder_r <= {REM_WIDTH{1'b0}};
                        div_quotient_r  <= {DIVIDEND_WIDTH{1'b0}};
                        div_bits_left_r <= DIVIDEND_WIDTH;
                        state_r         <= S_DIVIDE;
                    end
                end

                S_DIVIDE: begin
                    div_remainder_r <= div_remainder_next_w;
                    div_quotient_r  <= div_quotient_next_w;
                    if (div_bits_left_r == 5'd1) begin
                        qs_out[OUTPUT_WIDTH*sample_index_r +: OUTPUT_WIDTH] <=
                            signed_quantized_byte(sign_r, div_quotient_next_w);
                        if (sample_index_r == BLOCK_SIZE - 1) begin
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            state_r <= S_IDLE;
                        end else begin
                            sample_index_r <= sample_index_r + 1'b1;
                            state_r        <= S_PREPARE;
                        end
                    end else begin
                        div_bits_left_r <= div_bits_left_r - 1'b1;
                    end
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
        end
    end

endmodule
