/*
 * Module      : SPU_RMSInv_Engine
 * Description : Multi-cycle RMS inverse helper for SPU_RMSNorm.
 *
 * Computes:
 *   inv_rms_q15 = floor(2^23 / sqrt((sumsq_q16 / element_count) + epsilon))
 *
 * The divider and square-root datapaths are one-bit/two-bit iterative engines.
 * They intentionally avoid "/" and combinational sqrt functions in the command
 * path that previously created a routed critical path around 200 ns.
 */

`timescale 1ns/1ps

module SPU_RMSInv_Engine (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire [63:0] sumsq_q16,
    input  wire [31:0] element_count,
    input  wire [31:0] epsilon_q16,
    output wire        busy,
    output reg         done,
    output reg         error,
    output reg  [31:0] inv_rms_q15
);
    localparam [3:0] S_IDLE       = 4'd0;
    localparam [3:0] S_DIV_MEAN   = 4'd1;
    localparam [3:0] S_MEAN       = 4'd2;
    localparam [3:0] S_SQRT       = 4'd3;
    localparam [3:0] S_RECIP_INIT = 4'd4;
    localparam [3:0] S_RECIP      = 4'd5;
    localparam [3:0] S_RECIP_OUT  = 4'd6;
    localparam [3:0] S_DONE       = 4'd7;

    reg [3:0] state_r;

    reg [63:0] div_num_r;
    reg [64:0] div_rem_r;
    reg [63:0] div_quot_r;
    reg [31:0] div_denom_r;
    reg [6:0]  div_count_r;

    reg [63:0] mean_q16_r;
    reg [63:0] sqrt_rad_r;
    reg [65:0] sqrt_rem_r;
    reg [31:0] sqrt_root_r;
    reg [5:0]  sqrt_count_r;

    reg [31:0] recip_num_r;
    reg [64:0] recip_rem_r;
    reg [63:0] recip_quot_r;
    reg [63:0] recip_denom_r;
    reg [6:0]  recip_count_r;

    reg [64:0] div_rem_shift;
    reg [64:0] div_denom_ext;
    reg [64:0] recip_rem_shift;
    reg [64:0] recip_denom_ext;
    reg [65:0] sqrt_rem_shift;
    reg [65:0] sqrt_trial;
    reg [64:0] mean_sum;

    assign busy = (state_r != S_IDLE);

    always @(posedge clk) begin
        if (!resetn) begin
            state_r       <= S_IDLE;
            done          <= 1'b0;
            error         <= 1'b0;
            inv_rms_q15   <= 32'd0;
            div_num_r     <= 64'd0;
            div_rem_r     <= 65'd0;
            div_quot_r    <= 64'd0;
            div_denom_r   <= 32'd0;
            div_count_r   <= 7'd0;
            mean_q16_r    <= 64'd0;
            sqrt_rad_r    <= 64'd0;
            sqrt_rem_r    <= 66'd0;
            sqrt_root_r   <= 32'd0;
            sqrt_count_r  <= 6'd0;
            recip_num_r   <= 32'd0;
            recip_rem_r   <= 65'd0;
            recip_quot_r  <= 64'd0;
            recip_denom_r <= 64'd0;
            recip_count_r <= 7'd0;
        end else begin
            done <= 1'b0;

            case (state_r)
                S_IDLE: begin
                    error <= 1'b0;
                    if (start) begin
                        if (element_count == 32'd0) begin
                            error       <= 1'b1;
                            inv_rms_q15 <= 32'd0;
                            state_r     <= S_DONE;
                        end else begin
                            div_num_r     <= sumsq_q16;
                            div_rem_r     <= 65'd0;
                            div_quot_r    <= 64'd0;
                            div_denom_r   <= element_count;
                            div_count_r   <= 7'd64;
                            state_r       <= S_DIV_MEAN;
                        end
                    end
                end

                S_DIV_MEAN: begin
                    div_rem_shift = {div_rem_r[63:0], div_num_r[63]};
                    div_denom_ext = {33'd0, div_denom_r};
                    div_num_r     <= {div_num_r[62:0], 1'b0};

                    if (div_rem_shift >= div_denom_ext) begin
                        div_rem_r  <= div_rem_shift - div_denom_ext;
                        div_quot_r <= {div_quot_r[62:0], 1'b1};
                    end else begin
                        div_rem_r  <= div_rem_shift;
                        div_quot_r <= {div_quot_r[62:0], 1'b0};
                    end

                    if (div_count_r == 7'd1)
                        state_r <= S_MEAN;
                    div_count_r <= div_count_r - 7'd1;
                end

                S_MEAN: begin
                    mean_sum = {1'b0, div_quot_r} + {33'd0, epsilon_q16};
                    mean_q16_r <= mean_sum[64] ? 64'hffff_ffff_ffff_ffff :
                                                  mean_sum[63:0];
                    sqrt_rad_r   <= mean_sum[64] ? 64'hffff_ffff_ffff_ffff :
                                                    mean_sum[63:0];
                    sqrt_rem_r   <= 66'd0;
                    sqrt_root_r  <= 32'd0;
                    sqrt_count_r <= 6'd32;
                    state_r      <= S_SQRT;
                end

                S_SQRT: begin
                    sqrt_rem_shift = {sqrt_rem_r[63:0], sqrt_rad_r[63:62]};
                    sqrt_trial     = {32'd0, sqrt_root_r, 2'b01};
                    sqrt_rad_r     <= {sqrt_rad_r[61:0], 2'b00};

                    if (sqrt_rem_shift >= sqrt_trial) begin
                        sqrt_rem_r  <= sqrt_rem_shift - sqrt_trial;
                        sqrt_root_r <= {sqrt_root_r[30:0], 1'b1};
                    end else begin
                        sqrt_rem_r  <= sqrt_rem_shift;
                        sqrt_root_r <= {sqrt_root_r[30:0], 1'b0};
                    end

                    if (sqrt_count_r == 6'd1)
                        state_r <= S_RECIP_INIT;
                    sqrt_count_r <= sqrt_count_r - 6'd1;
                end

                S_RECIP_INIT: begin
                    if (sqrt_root_r == 32'd0) begin
                        inv_rms_q15 <= 32'h7fff_ffff;
                        state_r     <= S_DONE;
                    end else begin
                        recip_num_r   <= 32'd8388608;
                        recip_rem_r   <= 65'd0;
                        recip_quot_r  <= 64'd0;
                        recip_denom_r <= {32'd0, sqrt_root_r};
                        recip_count_r <= 7'd32;
                        state_r       <= S_RECIP;
                    end
                end

                S_RECIP: begin
                    recip_rem_shift = {recip_rem_r[63:0], recip_num_r[31]};
                    recip_denom_ext = {1'b0, recip_denom_r};
                    recip_num_r     <= {recip_num_r[30:0], 1'b0};

                    if (recip_rem_shift >= recip_denom_ext) begin
                        recip_rem_r  <= recip_rem_shift - recip_denom_ext;
                        recip_quot_r <= {recip_quot_r[62:0], 1'b1};
                    end else begin
                        recip_rem_r  <= recip_rem_shift;
                        recip_quot_r <= {recip_quot_r[62:0], 1'b0};
                    end

                    if (recip_count_r == 7'd1)
                        state_r <= S_RECIP_OUT;
                    recip_count_r <= recip_count_r - 7'd1;
                end

                S_RECIP_OUT: begin
                    if (recip_quot_r[63:31] != 33'd0)
                        inv_rms_q15 <= 32'h7fff_ffff;
                    else
                        inv_rms_q15 <= recip_quot_r[30:0];
                    state_r <= S_DONE;
                end

                S_DONE: begin
                    done    <= 1'b1;
                    state_r <= S_IDLE;
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
        end
    end
endmodule
