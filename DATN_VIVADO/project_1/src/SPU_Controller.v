/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Controller
 * Description : Command FSM for the Scalar Processing Unit.
 *
 * The controller implements the first SPU command set:
 * - SPU_MODE_QUANT_Q8_0: fixed-point INT16 block -> VPU-ready INT8 payload;
 * - SPU_MODE_Q8_SCALE_ACCUM: raw INT32 + FP16 scales -> Q16.16 accumulator;
 * - SPU_MODE_SILU_MUL : reserved until the gated-FFN streaming datapath exists;
 * - SPU_MODE_RMSNORM  : reserved until the RMSNorm datapath exists;
 * - SPU_MODE_ROPE     : reserved until the rotary-embedding datapath exists;
 * - SPU_MODE_SOFTMAX  : reserved until the attention-softmax datapath exists;
 * - SPU_MODE_COPY      : self-test copy from SPU_IN to SPU_OUT.
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
    localparam [7:0] SPU_MODE_Q8_SCALE_ACCUM   = 8'd6;
    localparam [7:0] SPU_MODE_COPY             = 8'h7f;

    localparam [7:0] ERR_NONE         = 8'd0;
    localparam [7:0] ERR_BAD_MODE     = 8'd1;
    localparam [7:0] ERR_BAD_LENGTH   = 8'd2;
    localparam [7:0] ERR_RANGE        = 8'd3;
    localparam [7:0] ERR_BAD_SCALE    = 8'd4;

    localparam [4:0] S_IDLE              = 5'd0;
    localparam [4:0] S_DECODE            = 5'd1;
    localparam [4:0] S_COPY_READ         = 5'd2;
    localparam [4:0] S_COPY_WAIT         = 5'd3;
    localparam [4:0] S_COPY_WRITE        = 5'd4;
    localparam [4:0] S_Q_READ            = 5'd5;
    localparam [4:0] S_Q_WAIT            = 5'd6;
    localparam [4:0] S_Q_CAPTURE         = 5'd7;
    localparam [4:0] S_Q_COMPUTE         = 5'd8;
    localparam [4:0] S_Q_WRITE0          = 5'd9;
    localparam [4:0] S_Q_WRITE1          = 5'd10;
    localparam [4:0] S_Q_WRITE_SCALE     = 5'd11;
    localparam [4:0] S_DONE              = 5'd12;
    localparam [4:0] S_ERROR             = 5'd13;
    localparam [4:0] S_Q_WAIT_COMPUTE    = 5'd15;
    localparam [4:0] S_SA_READ           = 5'd16;
    localparam [4:0] S_SA_WAIT           = 5'd17;
    localparam [4:0] S_SA_CAPTURE        = 5'd18;
    localparam [4:0] S_SA_START          = 5'd19;
    localparam [4:0] S_SA_WAIT_ACCUM     = 5'd20;
    localparam [4:0] S_SA_WRITE_OUT      = 5'd21;
    localparam [4:0] S_SA_WRITE_STATUS   = 5'd22;

    localparam integer INPUT_LANES_PER_WORD = AXI_DATA_WIDTH / 16;
    localparam integer Q8_BLOCK_VALUES      = 32;
    localparam integer Q8_INPUT_WORDS       = Q8_BLOCK_VALUES / INPUT_LANES_PER_WORD;
    localparam integer Q8_OUTPUT_WORDS      = 2;

    reg [4:0]  state_r;
    reg [31:0] word_idx_r;
    reg [31:0] block_idx_r;
    reg [31:0] block_count_r;
    reg [31:0] scale_out_count_r;
    reg [1:0]  q_word_idx_r;
    reg [16*Q8_BLOCK_VALUES-1:0] quant_values_r;
    reg [AXI_DATA_WIDTH-1:0] scale_entry_word_r;
    reg [15:0] scale_out_row_r;
    reg signed [63:0] scale_out_accum_r;
    reg scale_accum_start_r;

    wire [8*Q8_BLOCK_VALUES-1:0] quant_qs;
    wire [15:0] quant_amax;
    wire quant_zero;
    wire quant_busy;
    wire quant_done;
    wire scale_accum_busy;
    wire scale_accum_entry_done;
    wire scale_accum_out_valid;
    wire [15:0] scale_accum_out_row_id;
    wire signed [63:0] scale_accum_out_accum_q16;
    wire scale_accum_error;
    wire [3:0] scale_accum_error_code;

    SPU_Quantize_Q8_0 u_quantize_q8_0 (
        .clk        (clk),
        .resetn     (resetn),
        .start      (state_r == S_Q_COMPUTE),
        .values_in  (quant_values_r),
        .busy       (quant_busy),
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
        .busy              (scale_accum_busy),
        .entry_done        (scale_accum_entry_done),
        .out_valid         (scale_accum_out_valid),
        .out_row_id        (scale_accum_out_row_id),
        .out_accum_q16     (scale_accum_out_accum_q16),
        .error             (scale_accum_error),
        .error_code        (scale_accum_error_code)
    );

    assign busy = (state_r != S_IDLE) && (state_r != S_DONE) && (state_r != S_ERROR);

    function [31:0] ceil_div32;
        input [31:0] value;
        begin
            ceil_div32 = (value + 32'd31) >> 5;
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

    always @(posedge clk) begin
        if (!resetn || soft_reset) begin
            state_r        <= S_IDLE;
            done           <= 1'b0;
            error          <= 1'b0;
            error_code     <= ERR_NONE;
            word_idx_r     <= 32'd0;
            block_idx_r    <= 32'd0;
            block_count_r  <= 32'd0;
            scale_out_count_r <= 32'd0;
            q_word_idx_r   <= 2'd0;
            quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
            scale_entry_word_r <= {AXI_DATA_WIDTH{1'b0}};
            scale_out_row_r <= 16'd0;
            scale_out_accum_r <= 64'sd0;
            scale_accum_start_r <= 1'b0;
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

            if (clear_done && (state_r == S_DONE || state_r == S_ERROR || state_r == S_IDLE)) begin
                done       <= 1'b0;
                error      <= 1'b0;
                error_code <= ERR_NONE;
                if (state_r != S_IDLE)
                    state_r <= S_IDLE;
            end

            case (state_r)
                S_IDLE: begin
                    if (start) begin
                        done           <= 1'b0;
                        error          <= 1'b0;
                        error_code     <= ERR_NONE;
                        word_idx_r     <= 32'd0;
                        block_idx_r    <= 32'd0;
                        block_count_r  <= ceil_div32(len);
                        scale_out_count_r <= 32'd0;
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
                        scale_entry_word_r <= {AXI_DATA_WIDTH{1'b0}};
                        state_r        <= S_DECODE;
                    end
                end

                S_DECODE: begin
                    if (mode == SPU_MODE_COPY) begin
                        if (len == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if (len > WORD_DEPTH) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            state_r <= S_COPY_READ;
                        end
                    end else if (mode == SPU_MODE_QUANT_Q8_0) begin
                        if (len == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if ((ceil_div32(len) * Q8_INPUT_WORDS > WORD_DEPTH) ||
                                     (ceil_div32(len) * Q8_OUTPUT_WORDS > WORD_DEPTH) ||
                                     (ceil_div32(len) > WORD_DEPTH)) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            state_r <= S_Q_READ;
                        end
                    end else if (mode == SPU_MODE_Q8_SCALE_ACCUM) begin
                        if (len == 32'd0) begin
                            error <= 1'b1;
                            error_code <= ERR_BAD_LENGTH;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else if (len > WORD_DEPTH) begin
                            error <= 1'b1;
                            error_code <= ERR_RANGE;
                            done <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            scale_out_count_r <= 32'd0;
                            state_r <= S_SA_READ;
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
                    state_r    <= S_COPY_WRITE;
                end

                S_COPY_WRITE: begin
                    mem_en     <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_region <= REGION_OUT;
                    mem_index  <= word_idx_r;
                    mem_wdata  <= mem_rdata;
                    mem_wstrb  <= {(AXI_DATA_WIDTH/8){1'b1}};
                    if (word_idx_r + 32'd1 >= len) begin
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
                    state_r    <= S_Q_CAPTURE;
                end

                S_Q_CAPTURE: begin
                    quant_values_r[AXI_DATA_WIDTH*q_word_idx_r +: AXI_DATA_WIDTH] <=
                        masked_input_word(mem_rdata, block_idx_r, q_word_idx_r, len);
                    if (q_word_idx_r == Q8_INPUT_WORDS - 1) begin
                        q_word_idx_r <= 2'd0;
                        state_r      <= S_Q_COMPUTE;
                    end else begin
                        q_word_idx_r <= q_word_idx_r + 2'd1;
                        state_r      <= S_Q_READ;
                    end
                end

                S_Q_COMPUTE: begin
                    // SPU_Quantize_Q8_0 reuses one divider across the 32
                    // lanes of this block.  Wait for its local result before
                    // exposing the payload to SPU_OUT/SPU_SCRATCH.
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
                        end else if (word_idx_r + 32'd1 >= len) begin
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
                    if (word_idx_r + 32'd1 >= len) begin
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

                S_DONE: begin
                    if (start) begin
                        done           <= 1'b0;
                        error          <= 1'b0;
                        error_code     <= ERR_NONE;
                        word_idx_r     <= 32'd0;
                        block_idx_r    <= 32'd0;
                        block_count_r  <= ceil_div32(len);
                        scale_out_count_r <= 32'd0;
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
                        scale_entry_word_r <= {AXI_DATA_WIDTH{1'b0}};
                        state_r        <= S_DECODE;
                    end
                end

                S_ERROR: begin
                    if (start) begin
                        done           <= 1'b0;
                        error          <= 1'b0;
                        error_code     <= ERR_NONE;
                        word_idx_r     <= 32'd0;
                        block_idx_r    <= 32'd0;
                        block_count_r  <= ceil_div32(len);
                        scale_out_count_r <= 32'd0;
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
                        scale_entry_word_r <= {AXI_DATA_WIDTH{1'b0}};
                        state_r        <= S_DECODE;
                    end
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
        end
    end

endmodule
