/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Top
 * Description : Top-level Scalar Processing Unit wrapper.
 *
 * SPU_Top is integrated below AXI4_Mapping, next to the existing VPU/GEMV
 * core.  It exposes a small command interface, local memory windows, status,
 * and capability bits.  Quantization, Q8 scale accumulation, SiLU/Mul,
 * RMSNorm, RoPE, Softmax, and copy self-test are exposed through local-memory
 * commands.  The VPU raw stream input lets GEMV partial INT32 results exercise
 * the SPU accumulator directly, with counters exposed for host/testbench
 * observability.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Top #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH     = 4096,
    parameter integer SCALE_ACCUM_ROWS = 256,
    parameter integer STREAM_FIFO_DEPTH = 32,
    parameter integer STREAM_TEST_STALL_ENABLE = 0
) (
    input  wire                              clk,
    input  wire                              resetn,

    input  wire                              spu_start,
    input  wire                              spu_clear_done,
    input  wire                              spu_soft_reset,
    input  wire [7:0]                        spu_mode,
    input  wire [31:0]                       spu_len,
    input  wire [31:0]                       spu_aux0,
    input  wire [31:0]                       spu_aux1,

    output wire                              spu_busy,
    output wire                              spu_done,
    output wire                              spu_error,
    output wire [7:0]                        spu_error_code,
    output wire [31:0]                       spu_caps,

    input  wire                              vpu_raw_valid,
    output wire                              vpu_raw_ready,
    input  wire signed [31:0]                vpu_raw_data,
    input  wire [15:0]                       vpu_raw_row,
    input  wire [15:0]                       vpu_raw_block,
    input  wire [15:0]                       vpu_raw_group_blocks,
    input  wire                              vpu_raw_last_block,
    input  wire                              vpu_raw_clear_accum,
    input  wire [31:0]                       vpu_raw_job_id,
    input  wire                              vpu_raw_bank,
    input  wire                              vpu_raw_done,
    output wire [31:0]                       vpu_stream_count,
    output wire [31:0]                       vpu_stream_done_count,
    output wire [31:0]                       vpu_stream_drop_count,
    output wire [31:0]                       vpu_stream_out_count,
    output wire [31:0]                       vpu_stream_error_count,
    output wire [31:0]                       vpu_stream_last_raw,
    output wire [31:0]                       vpu_stream_last_meta,
    output wire [31:0]                       vpu_stream_last_accum_lo,
    output wire [31:0]                       vpu_stream_last_accum_hi,
    output wire [31:0]                       vpu_stream_last_job,
    output wire [31:0]                       vpu_stream_last_bank,
    // Read-only stream ownership status.  This is consumed by the host before
    // it overwrites SPU_PARAM or drains SPU_OUT for a new P2 tile.
    output wire [31:0]                       vpu_stream_status,

    input  wire                              mm_wr_en,
    input  wire [1:0]                        mm_wr_region,
    input  wire [31:0]                       mm_wr_index,
    input  wire [AXI_DATA_WIDTH-1:0]         mm_wr_data,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     mm_wr_strb,

    input  wire                              mm_rd_en,
    input  wire [1:0]                        mm_rd_region,
    input  wire [31:0]                       mm_rd_index,
    output wire [AXI_DATA_WIDTH-1:0]         mm_rd_data,
    output wire                              mm_rd_valid,
    output wire                              mm_rd_error
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    wire                              ctrl_mem_en;
    wire                              ctrl_mem_we;
    wire [1:0]                        ctrl_mem_region;
    wire [31:0]                       ctrl_mem_index;
    wire [AXI_DATA_WIDTH-1:0]         ctrl_mem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]     ctrl_mem_wstrb;
    wire [AXI_DATA_WIDTH-1:0]         core_mem_rdata;
    localparam [31:0] WORD_DEPTH_32 = WORD_DEPTH;
    localparam [15:0] WORD_DEPTH_16 = WORD_DEPTH_32[15:0];
    localparam [1:0] REGION_OUT     = 2'd1;
    localparam [1:0] REGION_PARAM   = 2'd2;
    localparam integer STREAM_SCALE_LANES = AXI_DATA_WIDTH / 32;
    localparam [31:0] STREAM_SCALE_ENTRY_DEPTH_32 = WORD_DEPTH * STREAM_SCALE_LANES;
    localparam integer STREAM_FIFO_PTR_WIDTH = clog2(STREAM_FIFO_DEPTH);
    localparam integer STREAM_FIFO_COUNT_WIDTH = clog2(STREAM_FIFO_DEPTH + 1);

    // Unit engines exist, but they are not yet wired through the GGML graph.
    // Keep their capability bits clear until end-to-end numerical validation.
    wire silu_supported = 1'b0;
    wire rmsnorm_supported = 1'b0;
    wire rope_supported = 1'b0;
    wire softmax_supported = 1'b0;
    reg stream_accum_start_r;
    wire stream_accum_busy;
    wire stream_accum_entry_done;
    wire stream_accum_out_valid;
    wire [15:0] stream_accum_out_row_id;
    wire signed [63:0] stream_accum_out_q16;
    wire stream_accum_error;
    wire [3:0] stream_accum_error_code;

    localparam [2:0] STREAM_IDLE          = 3'd0;
    localparam [2:0] STREAM_READ_SCALE    = 3'd1;
    localparam [2:0] STREAM_CAPTURE_SCALE = 3'd2;
    localparam [2:0] STREAM_START         = 3'd3;
    localparam [2:0] STREAM_WAIT          = 3'd4;

    reg [2:0] stream_state_r;
    reg signed [31:0] stream_raw_r;
    reg [15:0] stream_row_r;
    reg stream_last_block_r;
    reg stream_clear_accum_r;
    reg [31:0] stream_scale_word_index_r;
    reg [1:0] stream_scale_lane_r;
    reg [31:0] stream_scale_word_r;
    reg [31:0] vpu_stream_count_r;
    reg [31:0] vpu_stream_done_count_r;
    reg [31:0] vpu_stream_drop_count_r;
    reg [31:0] vpu_stream_out_count_r;
    reg [31:0] vpu_stream_error_count_r;
    reg [31:0] vpu_stream_last_raw_r;
    reg [31:0] vpu_stream_last_meta_r;
    reg [31:0] vpu_stream_last_accum_lo_r;
    reg [31:0] vpu_stream_last_accum_hi_r;
    reg [31:0] vpu_stream_last_job_r;
    reg [31:0] vpu_stream_last_bank_r;
    reg [STREAM_FIFO_PTR_WIDTH-1:0] stream_fifo_wr_ptr_r;
    reg [STREAM_FIFO_PTR_WIDTH-1:0] stream_fifo_rd_ptr_r;
    reg [STREAM_FIFO_COUNT_WIDTH-1:0] stream_fifo_count_r;
    reg signed [31:0] stream_fifo_raw [0:STREAM_FIFO_DEPTH-1];
    reg [15:0] stream_fifo_row [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_last_block [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_clear_accum [0:STREAM_FIFO_DEPTH-1];
    // Store the complete SPU_PARAM lookup result when the raw entry is
    // accepted.  Do not recompute row * group_blocks + block from an
    // asynchronously-read FIFO entry on the dequeue/FSM path: that was the
    // reported setup-critical cone into stream_state_r.
    reg [31:0] stream_fifo_scale_word_index [0:STREAM_FIFO_DEPTH-1];
    reg [1:0] stream_fifo_scale_lane [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_scale_index_ok [0:STREAM_FIFO_DEPTH-1];
    reg [31:0] stream_fifo_job_id [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_bank [0:STREAM_FIFO_DEPTH-1];
    reg [15:0] stream_test_lfsr_r;
    reg [5:0] stream_test_stall_count_r;

    function [STREAM_FIFO_PTR_WIDTH-1:0] stream_fifo_next_ptr;
        input [STREAM_FIFO_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == STREAM_FIFO_DEPTH - 1)
                stream_fifo_next_ptr = {STREAM_FIFO_PTR_WIDTH{1'b0}};
            else
                stream_fifo_next_ptr = ptr + {{(STREAM_FIFO_PTR_WIDTH-1){1'b0}}, 1'b1};
        end
    endfunction

    // This arithmetic is intentionally on the enqueue data path.  It is
    // captured in FIFO metadata only after ready/valid acceptance and is not
    // part of vpu_raw_ready, FIFO count, or the dequeue FSM control cone.
    wire [31:0] stream_enqueue_scale_index_w =
        ({16'd0, vpu_raw_row} * {16'd0, vpu_raw_group_blocks}) +
        {16'd0, vpu_raw_block};
    wire [31:0] stream_enqueue_scale_word_index_w =
        stream_enqueue_scale_index_w >> 2;
    wire stream_enqueue_scale_index_ok =
        (vpu_raw_group_blocks != 16'd0) &&
        (vpu_raw_block < vpu_raw_group_blocks) &&
        (stream_enqueue_scale_index_w < STREAM_SCALE_ENTRY_DEPTH_32);
    wire stream_idle = (stream_state_r == STREAM_IDLE);
    wire stream_fifo_empty = (stream_fifo_count_r == 0);
    wire stream_fifo_full = (stream_fifo_count_r == STREAM_FIFO_DEPTH);
    wire stream_test_stall = (STREAM_TEST_STALL_ENABLE != 0) &&
                            (stream_test_stall_count_r != 0);
    wire stream_push = vpu_raw_valid && vpu_raw_ready;
    wire stream_pop = stream_idle && !stream_fifo_empty;
    assign vpu_raw_ready = resetn && !stream_fifo_full && !stream_test_stall;
    wire stream_result_write = stream_accum_out_valid;
    wire stream_scale_read = (stream_state_r == STREAM_READ_SCALE);
    wire stream_scale_port =
        (stream_state_r == STREAM_READ_SCALE) ||
        (stream_state_r == STREAM_CAPTURE_SCALE);
    wire [AXI_DATA_WIDTH-1:0] stream_result_wdata =
        {{(AXI_DATA_WIDTH-80){1'b0}},
         stream_accum_out_q16,
         stream_accum_out_row_id};
    wire                              core_mem_en =
        stream_result_write ? 1'b1 :
        stream_scale_read   ? 1'b1 : ctrl_mem_en;
    wire                              core_mem_we =
        stream_result_write ? 1'b1 :
        stream_scale_read   ? 1'b0 : ctrl_mem_we;
    wire [1:0]                        core_mem_region =
        stream_result_write ? REGION_OUT :
        stream_scale_port   ? REGION_PARAM : ctrl_mem_region;
    wire [31:0]                       core_mem_index =
        stream_result_write ? {16'd0, stream_accum_out_row_id} :
        stream_scale_port   ? stream_scale_word_index_r : ctrl_mem_index;
    wire [AXI_DATA_WIDTH-1:0]         core_mem_wdata =
        stream_result_write ? stream_result_wdata : ctrl_mem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]     core_mem_wstrb =
        stream_result_write ? 16'h03ff : ctrl_mem_wstrb;

    // Capability map:
    // bit 0  : SPU framework present
    // bit 1  : fixed-point quantize-to-INT8 payload supported
    // bit 2  : SPU_SiLU_Mul numerical datapath supported
    // bit 3  : SPU_RMSNorm numerical datapath supported
    // bit 4  : SPU_RoPE numerical datapath supported
    // bit 5  : SPU_Softmax numerical datapath supported
    // bit 6  : Q8 raw-block scale accumulation supported
    // bit 7  : COPY self-test command supported
    // bit 8  : VPU raw-result stream accumulator connected
    // bit 9  : VPU stream uses SPU_PARAM scale table and writes SPU_OUT rows
    // bits 31:16 expose implemented words per SPU memory window.
    assign spu_caps = {WORD_DEPTH_16, 6'd0, 1'b1, 1'b1, 1'b1, 1'b1,
                       softmax_supported, rope_supported, rmsnorm_supported,
                       silu_supported, 1'b1, 1'b1};

    assign vpu_stream_count         = vpu_stream_count_r;
    assign vpu_stream_done_count    = vpu_stream_done_count_r;
    assign vpu_stream_drop_count    = vpu_stream_drop_count_r;
    assign vpu_stream_out_count     = vpu_stream_out_count_r;
    assign vpu_stream_error_count   = vpu_stream_error_count_r;
    assign vpu_stream_last_raw      = vpu_stream_last_raw_r;
    assign vpu_stream_last_meta     = vpu_stream_last_meta_r;
    assign vpu_stream_last_accum_lo = vpu_stream_last_accum_lo_r;
    assign vpu_stream_last_accum_hi = vpu_stream_last_accum_hi_r;
    assign vpu_stream_last_job      = vpu_stream_last_job_r;
    assign vpu_stream_last_bank     = vpu_stream_last_bank_r;
    // bit 0: dequeue FSM idle, bit 1: FIFO empty, bit 2: scale accumulator
    // idle, bit 3: no SPU_OUT write in this cycle, bit 4: all of the above.
    // The host requires bit 4 before it may reuse SPU_PARAM/SPU_OUT.
    assign vpu_stream_status[0]     = stream_idle;
    assign vpu_stream_status[1]     = stream_fifo_empty;
    assign vpu_stream_status[2]     = !stream_accum_busy;
    assign vpu_stream_status[3]     = !stream_result_write;
    assign vpu_stream_status[4]     = stream_idle && stream_fifo_empty &&
                                      !stream_accum_busy && !stream_result_write;
    assign vpu_stream_status[31:5]  = 27'd0;

    always @(posedge clk) begin
        if (!resetn) begin
            stream_accum_start_r      <= 1'b0;
            stream_state_r            <= STREAM_IDLE;
            stream_raw_r              <= 32'sd0;
            stream_row_r              <= 16'd0;
            stream_last_block_r       <= 1'b0;
            stream_clear_accum_r      <= 1'b0;
            stream_scale_word_index_r <= 32'd0;
            stream_scale_lane_r       <= 2'd0;
            stream_scale_word_r       <= 32'd0;
            vpu_stream_count_r         <= 32'd0;
            vpu_stream_done_count_r    <= 32'd0;
            vpu_stream_drop_count_r    <= 32'd0;
            vpu_stream_out_count_r     <= 32'd0;
            vpu_stream_error_count_r   <= 32'd0;
            vpu_stream_last_raw_r      <= 32'd0;
            vpu_stream_last_meta_r     <= 32'd0;
            vpu_stream_last_accum_lo_r <= 32'd0;
            vpu_stream_last_accum_hi_r <= 32'd0;
            vpu_stream_last_job_r      <= 32'd0;
            vpu_stream_last_bank_r     <= 32'd0;
            stream_fifo_wr_ptr_r       <= {STREAM_FIFO_PTR_WIDTH{1'b0}};
            stream_fifo_rd_ptr_r       <= {STREAM_FIFO_PTR_WIDTH{1'b0}};
            stream_fifo_count_r        <= {STREAM_FIFO_COUNT_WIDTH{1'b0}};
            stream_test_lfsr_r         <= 16'h1;
            stream_test_stall_count_r  <= 6'd0;
        end else begin
            stream_accum_start_r <= 1'b0;

            if (spu_soft_reset) begin
                stream_state_r            <= STREAM_IDLE;
                stream_raw_r              <= 32'sd0;
                stream_row_r              <= 16'd0;
                stream_last_block_r       <= 1'b0;
                stream_clear_accum_r      <= 1'b0;
                stream_scale_word_index_r <= 32'd0;
                stream_scale_lane_r       <= 2'd0;
                stream_scale_word_r       <= 32'd0;
                vpu_stream_count_r         <= 32'd0;
                vpu_stream_done_count_r    <= 32'd0;
                vpu_stream_drop_count_r    <= 32'd0;
                vpu_stream_out_count_r     <= 32'd0;
                vpu_stream_error_count_r   <= 32'd0;
                vpu_stream_last_raw_r      <= 32'd0;
                vpu_stream_last_meta_r     <= 32'd0;
                vpu_stream_last_accum_lo_r <= 32'd0;
                vpu_stream_last_accum_hi_r <= 32'd0;
                vpu_stream_last_job_r      <= 32'd0;
                vpu_stream_last_bank_r     <= 32'd0;
                stream_fifo_wr_ptr_r       <= {STREAM_FIFO_PTR_WIDTH{1'b0}};
                stream_fifo_rd_ptr_r       <= {STREAM_FIFO_PTR_WIDTH{1'b0}};
                stream_fifo_count_r        <= {STREAM_FIFO_COUNT_WIDTH{1'b0}};
                stream_test_lfsr_r         <= 16'h1;
                stream_test_stall_count_r  <= 6'd0;
            end else begin
            stream_test_lfsr_r <= {stream_test_lfsr_r[14:0],
                                   stream_test_lfsr_r[15] ^ stream_test_lfsr_r[13] ^
                                   stream_test_lfsr_r[12] ^ stream_test_lfsr_r[10]};
            if (STREAM_TEST_STALL_ENABLE == 0) begin
                stream_test_stall_count_r <= 6'd0;
            end else if (stream_test_stall_count_r != 0) begin
                stream_test_stall_count_r <= stream_test_stall_count_r - 6'd1;
            end else if (stream_pop && stream_test_lfsr_r[3:0] == 4'h0) begin
                if (stream_test_lfsr_r[5:0] == 0)
                    stream_test_stall_count_r <= 6'd1;
                else if (stream_test_lfsr_r[5:0] > 6'd50)
                    stream_test_stall_count_r <= 6'd50;
                else
                    stream_test_stall_count_r <= stream_test_lfsr_r[5:0];
            end

            if (stream_push) begin
                stream_fifo_raw[stream_fifo_wr_ptr_r]          <= vpu_raw_data;
                stream_fifo_row[stream_fifo_wr_ptr_r]          <= vpu_raw_row;
                stream_fifo_last_block[stream_fifo_wr_ptr_r]   <= vpu_raw_last_block;
                stream_fifo_clear_accum[stream_fifo_wr_ptr_r]  <= vpu_raw_clear_accum;
                stream_fifo_scale_word_index[stream_fifo_wr_ptr_r] <=
                    stream_enqueue_scale_word_index_w;
                stream_fifo_scale_lane[stream_fifo_wr_ptr_r] <=
                    stream_enqueue_scale_index_w[1:0];
                stream_fifo_scale_index_ok[stream_fifo_wr_ptr_r] <=
                    stream_enqueue_scale_index_ok;
                stream_fifo_job_id[stream_fifo_wr_ptr_r]       <= vpu_raw_job_id;
                stream_fifo_bank[stream_fifo_wr_ptr_r]         <= vpu_raw_bank;
                stream_fifo_wr_ptr_r <= stream_fifo_next_ptr(stream_fifo_wr_ptr_r);
                vpu_stream_count_r <= vpu_stream_count_r + 32'd1;
                vpu_stream_last_raw_r <= vpu_raw_data;
                vpu_stream_last_meta_r <= {vpu_raw_clear_accum,
                                           vpu_raw_last_block,
                                           vpu_raw_block[13:0],
                                           vpu_raw_row};
                vpu_stream_last_job_r <= vpu_raw_job_id;
                vpu_stream_last_bank_r <= {31'd0, vpu_raw_bank};
            end

            if (stream_pop)
                stream_fifo_rd_ptr_r <= stream_fifo_next_ptr(stream_fifo_rd_ptr_r);

            case ({stream_push, stream_pop})
                2'b10: stream_fifo_count_r <= stream_fifo_count_r + {{(STREAM_FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                2'b01: stream_fifo_count_r <= stream_fifo_count_r - {{(STREAM_FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                default: stream_fifo_count_r <= stream_fifo_count_r;
            endcase

            if (vpu_raw_done)
                vpu_stream_done_count_r <= vpu_stream_done_count_r + 32'd1;

            if (stream_accum_entry_done && stream_accum_error)
                vpu_stream_error_count_r <= vpu_stream_error_count_r + 32'd1;

            if (stream_accum_out_valid) begin
                vpu_stream_out_count_r     <= vpu_stream_out_count_r + 32'd1;
                vpu_stream_last_accum_lo_r <= stream_accum_out_q16[31:0];
                vpu_stream_last_accum_hi_r <= stream_accum_out_q16[63:32];
            end

            case (stream_state_r)
                STREAM_IDLE: begin
                    if (stream_pop) begin
                        if (stream_fifo_scale_index_ok[stream_fifo_rd_ptr_r]) begin
                            stream_raw_r          <= stream_fifo_raw[stream_fifo_rd_ptr_r];
                            stream_row_r          <= stream_fifo_row[stream_fifo_rd_ptr_r];
                            stream_last_block_r   <= stream_fifo_last_block[stream_fifo_rd_ptr_r];
                            stream_clear_accum_r  <= stream_fifo_clear_accum[stream_fifo_rd_ptr_r];
                            stream_scale_word_index_r <=
                                stream_fifo_scale_word_index[stream_fifo_rd_ptr_r];
                            stream_scale_lane_r   <=
                                stream_fifo_scale_lane[stream_fifo_rd_ptr_r];
                            stream_state_r        <= STREAM_READ_SCALE;
                        end else begin
                            vpu_stream_error_count_r <= vpu_stream_error_count_r + 32'd1;
                            vpu_stream_drop_count_r  <= vpu_stream_drop_count_r + 32'd1;
                        end
                    end
                end

                STREAM_READ_SCALE: begin
                    stream_state_r      <= STREAM_CAPTURE_SCALE;
                end

                STREAM_CAPTURE_SCALE: begin
                    stream_scale_word_r <= core_mem_rdata[32*stream_scale_lane_r +: 32];
                    stream_state_r      <= STREAM_START;
                end

                STREAM_START: begin
                    if (!stream_accum_busy) begin
                        stream_accum_start_r <= 1'b1;
                        stream_state_r       <= STREAM_WAIT;
                    end
                end

                STREAM_WAIT: begin
                    if (stream_accum_entry_done)
                        stream_state_r <= STREAM_IDLE;
                end

                default: begin
                    stream_state_r <= STREAM_IDLE;
                end
            endcase
            end
        end
    end

    SPU_Q8_Scale_Accum #(
        .ROW_ID_WIDTH     (16),
        .MAX_ROWS         (SCALE_ACCUM_ROWS),
        .ACC_WIDTH        (64),
        .FIXED_FRAC_BITS  (16)
    ) u_vpu_stream_scale_accum (
        .clk              (clk),
        .resetn           (resetn),
        .start            (stream_accum_start_r),
        .raw_in           (stream_raw_r),
        .act_scale_fp16   (stream_scale_word_r[15:0]),
        .weight_scale_fp16(stream_scale_word_r[31:16]),
        .row_id           (stream_row_r),
        .clear_accum      (stream_clear_accum_r),
        .last_block       (stream_last_block_r),
        .busy             (stream_accum_busy),
        .entry_done       (stream_accum_entry_done),
        .out_valid        (stream_accum_out_valid),
        .out_row_id       (stream_accum_out_row_id),
        .out_accum_q16    (stream_accum_out_q16),
        .error            (stream_accum_error),
        .error_code       (stream_accum_error_code)
    );

    SPU_Controller #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH),
        .SCALE_ACCUM_ROWS (SCALE_ACCUM_ROWS)
    ) u_spu_controller (
        .clk          (clk),
        .resetn       (resetn),
        .start        (spu_start),
        .clear_done   (spu_clear_done),
        .soft_reset   (spu_soft_reset),
        .mode         (spu_mode),
        .len          (spu_len),
        .aux0         (spu_aux0),
        .aux1         (spu_aux1),
        .busy         (spu_busy),
        .done         (spu_done),
        .error        (spu_error),
        .error_code   (spu_error_code),
        .mem_en       (ctrl_mem_en),
        .mem_we       (ctrl_mem_we),
        .mem_region   (ctrl_mem_region),
        .mem_index    (ctrl_mem_index),
        .mem_wdata    (ctrl_mem_wdata),
        .mem_wstrb    (ctrl_mem_wstrb),
        .mem_rdata    (core_mem_rdata)
    );

    SPU_Local_Memory #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH)
    ) u_spu_local_memory (
        .clk            (clk),
        .resetn         (resetn),
        .mm_wr_en       (mm_wr_en),
        .mm_wr_region   (mm_wr_region),
        .mm_wr_index    (mm_wr_index),
        .mm_wr_data     (mm_wr_data),
        .mm_wr_strb     (mm_wr_strb),
        .mm_rd_en       (mm_rd_en),
        .mm_rd_region   (mm_rd_region),
        .mm_rd_index    (mm_rd_index),
        .mm_rd_data     (mm_rd_data),
        .mm_rd_valid    (mm_rd_valid),
        .mm_rd_error    (mm_rd_error),
        .core_en        (core_mem_en),
        .core_we        (core_mem_we),
        .core_region    (core_mem_region),
        .core_index     (core_mem_index),
        .core_wdata     (core_mem_wdata),
        .core_wstrb     (core_mem_wstrb),
        .core_rdata     (core_mem_rdata)
    );

endmodule
