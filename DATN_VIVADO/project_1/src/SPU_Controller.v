/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Controller
 * Description : Command FSM for the Scalar Processing Unit.
 *
 * The controller implements the first SPU command set:
 * - SPU_MODE_QUANT_Q8_0: fixed-point INT16 block -> VPU-ready INT8 payload;
 * - SPU_MODE_SILU_MUL : command boundary for gated-FFN SiLU(x)*up(x);
 * - SPU_MODE_RMSNORM  : command boundary for RMSNorm offload;
 * - SPU_MODE_ROPE     : command boundary for rotary embedding offload;
 * - SPU_MODE_SOFTMAX  : command boundary for attention softmax offload;
 * - SPU_MODE_COPY      : self-test copy from SPU_IN to SPU_OUT.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Controller #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH     = 4096
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

    localparam [7:0] SPU_MODE_QUANT_Q8_0 = 8'd1;
    localparam [7:0] SPU_MODE_SILU_MUL   = 8'd2;
    localparam [7:0] SPU_MODE_RMSNORM    = 8'd3;
    localparam [7:0] SPU_MODE_ROPE       = 8'd4;
    localparam [7:0] SPU_MODE_SOFTMAX    = 8'd5;
    localparam [7:0] SPU_MODE_COPY       = 8'h7f;

    localparam [7:0] ERR_NONE         = 8'd0;
    localparam [7:0] ERR_BAD_MODE     = 8'd1;
    localparam [7:0] ERR_BAD_LENGTH   = 8'd2;
    localparam [7:0] ERR_RANGE        = 8'd3;

    localparam [3:0] S_IDLE           = 4'd0;
    localparam [3:0] S_DECODE         = 4'd1;
    localparam [3:0] S_COPY_READ      = 4'd2;
    localparam [3:0] S_COPY_WAIT      = 4'd3;
    localparam [3:0] S_COPY_WRITE     = 4'd4;
    localparam [3:0] S_Q_READ         = 4'd5;
    localparam [3:0] S_Q_WAIT         = 4'd6;
    localparam [3:0] S_Q_CAPTURE      = 4'd7;
    localparam [3:0] S_Q_COMPUTE      = 4'd8;
    localparam [3:0] S_Q_WRITE0       = 4'd9;
    localparam [3:0] S_Q_WRITE1       = 4'd10;
    localparam [3:0] S_Q_WRITE_SCALE  = 4'd11;
    localparam [3:0] S_DONE           = 4'd12;
    localparam [3:0] S_ERROR          = 4'd13;
    localparam [3:0] S_MARKER_RUN     = 4'd14;
    localparam [3:0] S_Q_WAIT_COMPUTE = 4'd15;

    localparam integer INPUT_LANES_PER_WORD = AXI_DATA_WIDTH / 16;
    localparam integer Q8_BLOCK_VALUES      = 32;
    localparam integer Q8_INPUT_WORDS       = Q8_BLOCK_VALUES / INPUT_LANES_PER_WORD;
    localparam integer Q8_OUTPUT_WORDS      = 2;

    reg [3:0]  state_r;
    reg [31:0] word_idx_r;
    reg [31:0] block_idx_r;
    reg [31:0] block_count_r;
    reg [1:0]  q_word_idx_r;
    reg [16*Q8_BLOCK_VALUES-1:0] quant_values_r;

    wire [8*Q8_BLOCK_VALUES-1:0] quant_qs;
    wire [15:0] quant_amax;
    wire quant_zero;
    wire quant_busy;
    wire quant_done;

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
            q_word_idx_r   <= 2'd0;
            quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
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
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
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
                    end else if ((mode == SPU_MODE_SILU_MUL) ||
                                 (mode == SPU_MODE_RMSNORM) ||
                                 (mode == SPU_MODE_ROPE) ||
                                 (mode == SPU_MODE_SOFTMAX)) begin
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
                            state_r <= S_MARKER_RUN;
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

                S_MARKER_RUN: begin
                    // The dedicated SPU_<function> modules are instantiated in
                    // SPU_Top and receive the same start pulse.  Their first
                    // phase is a one-cycle command boundary; later phases will
                    // replace this marker state with streaming memory work.
                    done    <= 1'b1;
                    state_r <= S_DONE;
                end

                S_DONE: begin
                    if (start) begin
                        done           <= 1'b0;
                        error          <= 1'b0;
                        error_code     <= ERR_NONE;
                        word_idx_r     <= 32'd0;
                        block_idx_r    <= 32'd0;
                        block_count_r  <= ceil_div32(len);
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
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
                        q_word_idx_r   <= 2'd0;
                        quant_values_r <= {16*Q8_BLOCK_VALUES{1'b0}};
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
