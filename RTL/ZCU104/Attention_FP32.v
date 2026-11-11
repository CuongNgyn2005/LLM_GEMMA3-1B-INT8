/*
 * Shared finite FP32 arithmetic helper used by Attention_Engine.
 * No real/shortreal, vendor IP, flush-to-zero, or saturation is used.
 *
 * Interface: synchronous active-low resetn. Pulse start while !busy. Inputs are
 * captured on that edge; starts while busy are ignored. done pulses for one
 * clock with busy=0. result/error hold until the next completion (error clears
 * on an accepted start). Reset aborts an operation without producing done.
 *
 * op 0: a+b, 1: a*b, 2: a/b, 3: exp(a), 4: FP32 a -> FP16 in result[15:0],
 * op 5: FP32 a -> signed int32, nearest-even (AArch64 NEON Q8 conversion).
 * b is ignored for unary operations. Codes 6/7 are errors. All used operands
 * must be finite; NaN/Inf, division by either signed zero, finite output
 * overflow, and integer overflow produce error=1/result=0. Subnormal inputs
 * and gradual underflow are supported. Add/mul/div/FP16 use nearest-even.
 * Exact cancellation adds to +0 except -0+-0=-0; mul/div preserve XOR signs.
 *
 * exp accepts only a<=0 (including both zeros). It computes t=-a in Q7.48,
 * t=k*ln(2)+r by repeated subtraction, then evaluates exp(-r) with a degree-12
 * Taylor polynomial in Q1.48, Horner form, before scaling by 2^-k. ln(2) and
 * coefficients are rounded to Q48. On 0<=r<ln(2), the omitted Taylor term is
 * <1.4e-12; fixed-point/range-reduction error is conservatively <1e-10 relative
 * before FP32 rounding. Declared acceptance target: <=2e-6 relative for normal
 * outputs; <=2 minimum-subnormal ULP absolute near underflow. This is a numeric
 * target, not a substitute for independent simulation. t>=104 returns zero:
 * exp(-104)<2^-150, the nearest-even zero threshold. No normal output clamps.
 *
 * Latency after acceptance: 9 cycles for add, 7 for multiply/FP16 conversion,
 * 58 for nonzero division, <=195 for exp, and 2 for integer conversion/early
 * exits. Exact addition and packing use registered stages without changing
 * arithmetic widths or rounding. Physical timing still requires verification.
 */
`timescale 1ns/1ps

module Attention_FP32 (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire [2:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire        busy,
    output reg         done,
    output reg  [31:0] result,
    output reg         error
);
    localparam [3:0] S_IDLE = 4'd0, S_EXEC = 4'd1, S_DIV = 4'd2,
                     S_EXP_RANGE = 4'd3, S_EXP_POLY = 4'd4,
                     S_EXP_PACK = 4'd5, S_DONE = 4'd6,
                     S_ADD_SELECT = 4'd7, S_ADD_SUM = 4'd8,
                     S_PACK_META = 4'd9, S_PACK_SHIFT = 4'd10,
                     S_PACK_ROUND = 4'd11, S_PACK_ENCODE = 4'd12,
                     S_EXP_ROUND = 4'd13, S_EXP_UPDATE = 4'd14,
                     S_PACK_EXP_META = 4'd15;
    localparam [55:0] LN2_Q48 = 56'd195103586505167;
    localparam [48:0] ONE_Q48 = 49'd281474976710656;

    reg [3:0] state_r;
    reg [2:0] op_r;
    reg [31:0] a_r, b_r;
    reg [31:0] pending_result_r;
    reg pending_error_r;
    reg [50:0] dividend_r, quotient_r;
    reg [24:0] remainder_r;
    reg [23:0] denominator_r;
    reg [5:0] div_count_r;
    reg signed [31:0] div_exponent_r;
    reg signed [31:0] norm_exp_a_r, norm_exp_b_r;
    reg div_sign_r;
    reg [55:0] exp_remainder_r;
    reg [7:0] exp_scale_r;
    reg [48:0] exp_poly_r;
    reg [104:0] exp_product_r, exp_product_rounded_r;
    reg [3:0] exp_index_r;
    reg [319:0] aligned_a_r, aligned_b_r, add_lhs_r, add_rhs_r;
    reg add_subtract_r;
    reg [319:0] pack_magnitude_r, pack_shifted_r, pack_rounded_r;
    reg pack_sign_r, pack_half_r, pack_guard_r, pack_sticky_r;
    integer pack_unit_exp_r, pack_top_r, pack_value_exp_r, pack_shift_count_r;

    reg [24:0] div_remainder_next;
    reg [50:0] div_quotient_next;

    reg [23:0] sig_a, sig_b, norm_a, norm_b;
    integer field_a, field_b, norm_exp_a, norm_exp_b;
    integer i, exp_shift;
    reg [47:0] exact_product;
    reg [55:0] exp_input_q48;
    reg [32:0] simple_result;
    integer pack_top, pack_j, pack_frac_bits, pack_min_exp, pack_max_exp, pack_bias;
    integer pack_value_exp, pack_shift_count, pack_normal_exp, pack_encoded_exp;
    reg [319:0] pack_shifted, pack_normalized;
    reg pack_guard, pack_sticky;
    reg [32:0] pack_encoded_result;

    assign busy = (state_r != S_IDLE);

    // The original exact pack operation is split only at register boundaries:
    // leading bit -> exponent metadata -> shift/guard/sticky -> round -> encode.
    // The 320-bit magnitude and rounded value retain the original widths.
    always @* begin
        pack_frac_bits = pack_half_r ? 10 : 23;
        pack_min_exp = pack_half_r ? -14 : -126;
        pack_max_exp = pack_half_r ? 15 : 127;
        pack_bias = pack_half_r ? 15 : 127;
        pack_top = -1;
        for (pack_j = 0; pack_j < 320; pack_j = pack_j + 1)
            if (pack_magnitude_r[pack_j]) pack_top = pack_j;
        pack_value_exp = pack_top_r + pack_unit_exp_r;
        if (pack_value_exp < pack_min_exp) pack_value_exp = pack_min_exp;
        pack_shift_count = pack_value_exp - pack_frac_bits - pack_unit_exp_r;

        pack_shifted = 320'd0;
        pack_guard = 1'b0;
        pack_sticky = 1'b0;
        if (pack_top_r >= 0) begin
            if (pack_shift_count_r > 0) begin
                pack_shifted = pack_magnitude_r >> pack_shift_count_r;
                if (pack_shift_count_r <= 320)
                    pack_guard = pack_magnitude_r[pack_shift_count_r-1];
                for (pack_j = 0; pack_j < 320; pack_j = pack_j + 1)
                    if (pack_j < pack_shift_count_r-1)
                        pack_sticky = pack_sticky | pack_magnitude_r[pack_j];
            end else begin
                pack_shifted = pack_magnitude_r << (-pack_shift_count_r);
            end
        end

        pack_normalized = pack_rounded_r;
        pack_normal_exp = pack_value_exp_r;
        if ((pack_top_r >= 0) && pack_rounded_r[pack_frac_bits+1]) begin
            pack_normalized = pack_rounded_r >> 1;
            pack_normal_exp = pack_value_exp_r + 1;
        end
        pack_encoded_exp = pack_normalized[pack_frac_bits] ? pack_normal_exp + pack_bias : 0;
        if ((pack_top_r >= 0) && (pack_normal_exp > pack_max_exp))
            pack_encoded_result = {1'b1, 32'd0};
        else if (pack_half_r)
            pack_encoded_result = {1'b0, 16'd0, pack_sign_r, pack_encoded_exp[4:0], pack_normalized[9:0]};
        else
            pack_encoded_result = {1'b0, pack_sign_r, pack_encoded_exp[7:0], pack_normalized[22:0]};
    end

    function [32:0] round_integer;
        input sign_bit;
        input [23:0] significand;
        input integer unit_exp;
        reg [319:0] magnitude, rounded;
        reg guard_bit, sticky_bit;
        integer shift_count, j;
        begin
            magnitude = {296'd0, significand};
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            shift_count = -unit_exp;
            if (unit_exp >= 0) rounded = magnitude << unit_exp;
            else begin
                rounded = magnitude >> shift_count;
                if (shift_count <= 320) guard_bit = magnitude[shift_count-1];
                for (j = 0; j < 320; j = j + 1)
                    if (j < shift_count-1) sticky_bit = sticky_bit | magnitude[j];
                if (guard_bit && (sticky_bit || rounded[0]))
                    rounded = rounded + 320'd1;
            end
            if ((!sign_bit && (rounded > 320'd2147483647)) ||
                (sign_bit && (rounded > 320'd2147483648)))
                round_integer = {1'b1, 32'd0};
            else
                round_integer = {1'b0, (sign_bit ? (~rounded[31:0] + 32'd1) : rounded[31:0])};
        end
    endfunction

    function [48:0] exp_coefficient;
        input [3:0] index;
        begin
            // round(2^48/n!), generated independently with decimal arithmetic.
            case (index)
                0, 1: exp_coefficient = ONE_Q48;
                2: exp_coefficient = 49'd140737488355328;
                3: exp_coefficient = 49'd46912496118443;
                4: exp_coefficient = 49'd11728124029611;
                5: exp_coefficient = 49'd2345624805922;
                6: exp_coefficient = 49'd390937467654;
                7: exp_coefficient = 49'd55848209665;
                8: exp_coefficient = 49'd6981026208;
                9: exp_coefficient = 49'd775669579;
                10: exp_coefficient = 49'd77566958;
                11: exp_coefficient = 49'd7051542;
                default: exp_coefficient = 49'd587628;
            endcase
        end
    endfunction

    always @* begin
        field_a = (a_r[30:23] == 0) ? 1 : {24'd0, a_r[30:23]};
        field_b = (b_r[30:23] == 0) ? 1 : {24'd0, b_r[30:23]};
        sig_a = {(a_r[30:23] != 0), a_r[22:0]};
        sig_b = {(b_r[30:23] != 0), b_r[22:0]};
        exact_product = sig_a * sig_b;
        norm_a = sig_a;
        norm_b = sig_b;
        norm_exp_a = field_a - 127;
        norm_exp_b = field_b - 127;
        for (i = 0; i < 23; i = i + 1) begin
            if (!norm_a[23]) begin
                norm_a = norm_a << 1;
                norm_exp_a = norm_exp_a - 1;
            end
            if (!norm_b[23]) begin
                norm_b = norm_b << 1;
                norm_exp_b = norm_exp_b - 1;
            end
        end
        exp_shift = field_a - 102;
        if (exp_shift >= 0) exp_input_q48 = {32'd0, sig_a} << exp_shift;
        else exp_input_q48 = {32'd0, sig_a} >> (-exp_shift);
        case (op_r)
            3'd5: simple_result = round_integer(a_r[31], sig_a, field_a-150);
            default: simple_result = {1'b1, 32'd0};
        endcase
        div_remainder_next = {remainder_r[23:0], dividend_r[50]};
        div_quotient_next = {quotient_r[49:0], 1'b0};
        if (div_remainder_next >= {1'b0, denominator_r}) begin
            div_remainder_next = div_remainder_next - {1'b0, denominator_r};
            div_quotient_next[0] = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= S_IDLE;
            op_r <= 3'd0;
            a_r <= 32'd0;
            b_r <= 32'd0;
            done <= 1'b0;
            error <= 1'b0;
            result <= 32'd0;
            pending_result_r <= 32'd0;
            pending_error_r <= 1'b0;
            dividend_r <= 51'd0;
            quotient_r <= 51'd0;
            remainder_r <= 25'd0;
            denominator_r <= 24'd0;
            div_count_r <= 6'd0;
            div_exponent_r <= 0;
            norm_exp_a_r <= 0;
            norm_exp_b_r <= 0;
            div_sign_r <= 1'b0;
            exp_remainder_r <= 56'd0;
            exp_scale_r <= 8'd0;
            exp_poly_r <= 49'd0;
            exp_product_r <= 105'd0;
            exp_product_rounded_r <= 105'd0;
            exp_index_r <= 4'd0;
            aligned_a_r <= 320'd0;
            aligned_b_r <= 320'd0;
            add_lhs_r <= 320'd0;
            add_rhs_r <= 320'd0;
            add_subtract_r <= 1'b0;
            pack_magnitude_r <= 320'd0;
            pack_shifted_r <= 320'd0;
            pack_rounded_r <= 320'd0;
            pack_sign_r <= 1'b0;
            pack_half_r <= 1'b0;
            pack_guard_r <= 1'b0;
            pack_sticky_r <= 1'b0;
            pack_unit_exp_r <= 0;
            pack_top_r <= -1;
            pack_value_exp_r <= 0;
            pack_shift_count_r <= 0;
        end else begin
            done <= 1'b0;
            case (state_r)
                S_IDLE: if (start) begin
                    a_r <= a;
                    b_r <= b;
                    op_r <= op;
                    error <= 1'b0;
                    pending_error_r <= 1'b0;
                    state_r <= S_EXEC;
                end
                S_EXEC: begin
                    if ((a_r[30:23] == 8'hff) ||
                        ((op_r <= 3'd2) && (b_r[30:23] == 8'hff)) || (op_r >= 3'd6)) begin
                        pending_result_r <= 32'd0;
                        pending_error_r <= 1'b1;
                        state_r <= S_DONE;
                    end else if (op_r == 3'd2) begin
                        if (b_r[30:0] == 0) begin
                            pending_result_r <= 32'd0;
                            pending_error_r <= 1'b1;
                            state_r <= S_DONE;
                        end else if (a_r[30:0] == 0) begin
                            pending_result_r <= {a_r[31] ^ b_r[31], 31'd0};
                            state_r <= S_DONE;
                        end else begin
                            dividend_r <= {norm_a, 27'd0};
                            denominator_r <= norm_b;
                            quotient_r <= 51'd0;
                            remainder_r <= 25'd0;
                            div_count_r <= 6'd0;
                            norm_exp_a_r <= norm_exp_a;
                            norm_exp_b_r <= norm_exp_b;
                            div_sign_r <= a_r[31] ^ b_r[31];
                            state_r <= S_DIV;
                        end
                    end else if (op_r == 3'd3) begin
                        if (!a_r[31] && (a_r[30:0] != 0)) begin
                            pending_result_r <= 32'd0;
                            pending_error_r <= 1'b1;
                            state_r <= S_DONE;
                        end else if (a_r[30:0] >= 31'h42d00000) begin
                            pending_result_r <= 32'd0;
                            state_r <= S_DONE;
                        end else begin
                            exp_remainder_r <= exp_input_q48;
                            exp_scale_r <= 8'd0;
                            state_r <= S_EXP_RANGE;
                        end
                    end else if (op_r == 3'd0) begin
                        aligned_a_r <= {296'd0, sig_a} << (field_a-1);
                        aligned_b_r <= {296'd0, sig_b} << (field_b-1);
                        state_r <= S_ADD_SELECT;
                    end else if (op_r == 3'd1) begin
                        pack_magnitude_r <= {272'd0, exact_product};
                        pack_unit_exp_r <= field_a+field_b-300;
                        pack_sign_r <= a_r[31] ^ b_r[31];
                        pack_half_r <= 1'b0;
                        state_r <= S_PACK_META;
                    end else if (op_r == 3'd4) begin
                        pack_magnitude_r <= {296'd0, sig_a};
                        pack_unit_exp_r <= field_a-150;
                        pack_sign_r <= a_r[31];
                        pack_half_r <= 1'b1;
                        state_r <= S_PACK_META;
                    end else begin
                        {pending_error_r, pending_result_r} <= simple_result;
                        state_r <= S_DONE;
                    end
                end
                S_DIV: begin
                    if (div_count_r == 6'd0)
                        div_exponent_r <= norm_exp_a_r - norm_exp_b_r - 28;
                    dividend_r <= {dividend_r[49:0], 1'b0};
                    remainder_r <= div_remainder_next;
                    quotient_r <= div_quotient_next;
                    div_count_r <= div_count_r + 6'd1;
                    if (div_count_r == 6'd50) begin
                        // The residual OR is below all retained rounding bits.
                        pack_magnitude_r <= {291'd0, div_quotient_next[27:0], (|div_remainder_next)};
                        pack_unit_exp_r <= div_exponent_r;
                        pack_sign_r <= div_sign_r;
                        pack_half_r <= 1'b0;
                        state_r <= S_PACK_META;
                    end
                end
                S_EXP_RANGE: begin
                    if (exp_remainder_r >= LN2_Q48) begin
                        exp_remainder_r <= exp_remainder_r - LN2_Q48;
                        exp_scale_r <= exp_scale_r + 8'd1;
                    end else begin
                        exp_poly_r <= exp_coefficient(4'd12);
                        exp_index_r <= 4'd11;
                        state_r <= S_EXP_POLY;
                    end
                end
                S_EXP_POLY: begin
                    exp_product_r <= exp_remainder_r * exp_poly_r;
                    state_r <= S_EXP_ROUND;
                end
                S_EXP_ROUND: begin
                    exp_product_rounded_r <= exp_product_r + 105'd140737488355328;
                    state_r <= S_EXP_UPDATE;
                end
                S_EXP_UPDATE: begin
                    exp_poly_r <= exp_coefficient(exp_index_r) - exp_product_rounded_r[96:48];
                    if (exp_index_r == 0) state_r <= S_EXP_PACK;
                    else begin
                        exp_index_r <= exp_index_r - 4'd1;
                        state_r <= S_EXP_POLY;
                    end
                end
                S_EXP_PACK: begin
                    pack_magnitude_r <= {271'd0, exp_poly_r};
                    pack_unit_exp_r <= -48-$signed({24'd0, exp_scale_r});
                    pack_sign_r <= 1'b0;
                    pack_half_r <= 1'b0;
                    state_r <= S_PACK_META;
                end
                S_ADD_SELECT: begin
                    add_subtract_r <= a_r[31] != b_r[31];
                    if (a_r[31] == b_r[31] || aligned_a_r > aligned_b_r) begin
                        add_lhs_r <= aligned_a_r;
                        add_rhs_r <= aligned_b_r;
                        pack_sign_r <= a_r[31];
                    end else begin
                        add_lhs_r <= aligned_b_r;
                        add_rhs_r <= aligned_a_r;
                        // Opposite signs with equal magnitudes cancel to +0.
                        pack_sign_r <= (aligned_b_r > aligned_a_r) ? b_r[31] : 1'b0;
                    end
                    state_r <= S_ADD_SUM;
                end
                S_ADD_SUM: begin
                    pack_magnitude_r <= add_subtract_r ? add_lhs_r-add_rhs_r : add_lhs_r+add_rhs_r;
                    pack_unit_exp_r <= -149;
                    pack_half_r <= 1'b0;
                    state_r <= S_PACK_META;
                end
                S_PACK_META: begin
                    pack_top_r <= pack_top;
                    state_r <= S_PACK_EXP_META;
                end
                S_PACK_EXP_META: begin
                    pack_value_exp_r <= pack_value_exp;
                    pack_shift_count_r <= pack_shift_count;
                    state_r <= S_PACK_SHIFT;
                end
                S_PACK_SHIFT: begin
                    pack_shifted_r <= pack_shifted;
                    pack_guard_r <= pack_guard;
                    pack_sticky_r <= pack_sticky;
                    state_r <= S_PACK_ROUND;
                end
                S_PACK_ROUND: begin
                    pack_rounded_r <= (pack_guard_r && (pack_sticky_r || pack_shifted_r[0])) ?
                                      pack_shifted_r+320'd1 : pack_shifted_r;
                    state_r <= S_PACK_ENCODE;
                end
                S_PACK_ENCODE: begin
                    {pending_error_r, pending_result_r} <= pack_encoded_result;
                    state_r <= S_DONE;
                end
                S_DONE: begin
                    result <= pending_result_r;
                    error <= pending_error_r;
                    done <= 1'b1;
                    state_r <= S_IDLE;
                end
                default: begin
                    pending_result_r <= 32'd0;
                    pending_error_r <= 1'b1;
                    state_r <= S_DONE;
                end
            endcase
        end
    end
endmodule
