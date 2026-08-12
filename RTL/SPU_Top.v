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
    parameter integer PRECOMPUTED_SCALE_INDEX = 0,
    parameter integer STREAM_TEST_STALL_ENABLE = 0,
    parameter integer VPU_BUNDLE8_ENABLE = 0
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

    // P3 is opt-in.  When clear, the P2 packed {weight,activation} scale
    // entry ABI is byte-for-byte and cycle-for-cycle unchanged.
    input  wire                              stream_split_scale_enable,

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
    // Retained P2-v2 companion lane.  It is sampled only with vpu_raw_valid
    // and vpu_raw_ready, so a pair never becomes two independently losable
    // stream entries.
    input  wire                              vpu_raw_pair_valid,
    input  wire signed [31:0]                vpu_raw_pair_data,
    input  wire [15:0]                       vpu_raw_pair_row,
    input  wire [15:0]                       vpu_raw_pair_block,
    input  wire [15:0]                       vpu_raw_pair_group_blocks,
    input  wire                              vpu_raw_pair_last_block,
    input  wire                              vpu_raw_pair_clear_accum,
    input  wire [31:0]                       vpu_raw_pair_job_id,
    input  wire                              vpu_raw_pair_bank,
    input  wire [31:0]                       vpu_raw_scale_index,
    input  wire [31:0]                       vpu_raw_pair_scale_index,
    input  wire [7:0]                        vpu_raw_lane_valid,
    input  wire [8*32-1:0]                   vpu_raw_lane_data,
    input  wire [8*16-1:0]                   vpu_raw_lane_row,
    input  wire [8*32-1:0]                   vpu_raw_lane_scale_index,
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
    output wire [31:0]                       vpu_stream_fifo_high_water,
    output wire [31:0]                       vpu_stream_raw_stall_cycles,
    output wire [31:0]                       vpu_stream_entry_done_count,
    output wire [31:0]                       vpu_stream_final_write_count,
    output wire [31:0]                       vpu_stream_p3_reject_count,
    output wire [31:0]                       vpu_stream_p3_status,

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
    localparam integer STREAM_P3_SCALE_LANES = AXI_DATA_WIDTH / 16;
    localparam integer STREAM_P3_BANK_WORD_DEPTH = WORD_DEPTH / 2;
    localparam [31:0] STREAM_P3_ENTRIES_PER_BANK =
        STREAM_P3_BANK_WORD_DEPTH * STREAM_P3_SCALE_LANES;
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
    reg stream_accum_pair_start_r;
    wire stream_accum_pair_busy;
    wire stream_accum_pair_entry_done;
    wire stream_accum_pair_out_valid;
    wire [15:0] stream_accum_pair_out_row_id;
    wire signed [63:0] stream_accum_pair_out_q16;
    wire stream_accum_pair_error;

    // P3 reuses the two PARAM ports for the two immutable weight scales and
    // the otherwise independent SCRATCH core port for the common activation
    // scale.  RAM reads are registered, hence the explicit READ/CAPTURE FSM
    // stages below; there is no combinational RAM-to-accumulator path.
    wire [AXI_DATA_WIDTH-1:0] core_mem3_rdata;
    wire mm_wr_rejected;

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
    reg [2:0] stream_scale_lane_r;
    reg [31:0] stream_scale_word_r;
    reg stream_pair_valid_r;
    reg signed [31:0] stream_pair_raw_r;
    reg [15:0] stream_pair_row_r;
    reg stream_pair_last_block_r;
    reg stream_pair_clear_accum_r;
    reg [31:0] stream_pair_scale_word_index_r;
    reg [2:0] stream_pair_scale_lane_r;
    reg [31:0] stream_pair_scale_word_r;
    reg stream_p3_r;
    reg [31:0] stream_act_scale_word_index_r;
    reg [2:0] stream_act_scale_lane_r;
    reg stream_p3_bank_lock_valid_r;
    reg stream_p3_bank_lock_r;
    reg stream_p3_done_seen_r;
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
    reg [31:0] vpu_stream_fifo_high_water_r;
    reg [31:0] vpu_stream_raw_stall_cycles_r;
    reg [31:0] vpu_stream_entry_done_count_r;
    reg [31:0] vpu_stream_final_write_count_r;
    reg [31:0] vpu_stream_p3_reject_count_r;
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
    reg [2:0] stream_fifo_scale_lane [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_scale_index_ok [0:STREAM_FIFO_DEPTH-1];
    reg [31:0] stream_fifo_job_id [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_bank [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_pair_valid [0:STREAM_FIFO_DEPTH-1];
    reg signed [31:0] stream_fifo_pair_raw [0:STREAM_FIFO_DEPTH-1];
    reg [15:0] stream_fifo_pair_row [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_pair_last_block [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_pair_clear_accum [0:STREAM_FIFO_DEPTH-1];
    reg [31:0] stream_fifo_pair_scale_word_index [0:STREAM_FIFO_DEPTH-1];
    reg [2:0] stream_fifo_pair_scale_lane [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_pair_scale_index_ok [0:STREAM_FIFO_DEPTH-1];
    reg stream_fifo_p3 [0:STREAM_FIFO_DEPTH-1];
    reg [31:0] stream_fifo_act_scale_word_index [0:STREAM_FIFO_DEPTH-1];
    reg [2:0] stream_fifo_act_scale_lane [0:STREAM_FIFO_DEPTH-1];
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

    // Production VPU tokens already carry the result/scale index formed by
    // the registered VPU result-address path.  This removes the wide
    // row*group_blocks arithmetic and its DSP input-enable cone from the
    // ready/valid boundary.  Standalone SPU tests retain the legacy local
    // calculation through the default parameter.
    wire [31:0] stream_enqueue_scale_index_w;
    wire [31:0] stream_enqueue_scale_word_index_w =
        stream_enqueue_scale_index_w >> 2;
    wire [31:0] stream_enqueue_pair_scale_index_w;
    wire [31:0] stream_enqueue_pair_scale_word_index_w =
        stream_enqueue_pair_scale_index_w >> 2;

    generate
        if (PRECOMPUTED_SCALE_INDEX != 0) begin : GEN_PRECOMPUTED_SCALE_INDEX
            assign stream_enqueue_scale_index_w = vpu_raw_scale_index;
            assign stream_enqueue_pair_scale_index_w = vpu_raw_pair_scale_index;
        end else begin : GEN_LEGACY_SCALE_INDEX
            assign stream_enqueue_scale_index_w =
                ({16'd0, vpu_raw_row} * {16'd0, vpu_raw_group_blocks}) +
                {16'd0, vpu_raw_block};
            assign stream_enqueue_pair_scale_index_w =
                ({16'd0, vpu_raw_pair_row} * {16'd0, vpu_raw_pair_group_blocks}) +
                {16'd0, vpu_raw_pair_block};
        end
    endgenerate
    wire stream_enqueue_scale_index_ok =
        (vpu_raw_group_blocks != 16'd0) &&
        (vpu_raw_block < vpu_raw_group_blocks) &&
        (stream_enqueue_scale_index_w < STREAM_SCALE_ENTRY_DEPTH_32);
    wire stream_enqueue_pair_scale_index_ok =
        !vpu_raw_pair_valid ||
        ((vpu_raw_pair_group_blocks != 16'd0) &&
         (vpu_raw_pair_block < vpu_raw_pair_group_blocks) &&
         (stream_enqueue_pair_scale_index_w < STREAM_SCALE_ENTRY_DEPTH_32));

    // P3 format: each 128-bit word contains eight dense FP16 scales.  PARAM
    // contains immutable weight scales indexed by row*group_blocks+block;
    // SCRATCH contains one activation scale per block.  Both windows are
    // explicitly split into bank0 [0, WORD_DEPTH/2) and bank1
    // [WORD_DEPTH/2, WORD_DEPTH), selected by the VPU job bank.
    wire [31:0] stream_enqueue_p3_weight_index_w = stream_enqueue_scale_index_w;
    wire [31:0] stream_enqueue_p3_pair_weight_index_w = stream_enqueue_pair_scale_index_w;
    wire [31:0] stream_enqueue_p3_bank_base_w =
        vpu_raw_bank ? STREAM_P3_BANK_WORD_DEPTH : 32'd0;
    wire [31:0] stream_enqueue_p3_weight_word_index_w =
        stream_enqueue_p3_bank_base_w + (stream_enqueue_p3_weight_index_w >> 3);
    wire [31:0] stream_enqueue_p3_pair_weight_word_index_w =
        stream_enqueue_p3_bank_base_w + (stream_enqueue_p3_pair_weight_index_w >> 3);
    wire [31:0] stream_enqueue_p3_act_word_index_w =
        stream_enqueue_p3_bank_base_w + ({16'd0, vpu_raw_block} >> 3);
    wire stream_enqueue_p3_index_ok =
        (WORD_DEPTH >= 2) && ((WORD_DEPTH % 2) == 0) &&
        (vpu_raw_group_blocks != 16'd0) &&
        (vpu_raw_block < vpu_raw_group_blocks) &&
        (vpu_raw_row < SCALE_ACCUM_ROWS) &&
        (stream_enqueue_p3_weight_index_w < STREAM_P3_ENTRIES_PER_BANK) &&
        (stream_enqueue_p3_weight_word_index_w < WORD_DEPTH) &&
        (stream_enqueue_p3_act_word_index_w < WORD_DEPTH);
    wire stream_enqueue_p3_pair_index_ok =
        !vpu_raw_pair_valid ||
        ((vpu_raw_pair_group_blocks != 16'd0) &&
         (vpu_raw_pair_block < vpu_raw_pair_group_blocks) &&
         (vpu_raw_pair_row < SCALE_ACCUM_ROWS) &&
         (vpu_raw_pair_bank == vpu_raw_bank) &&
         (vpu_raw_pair_block == vpu_raw_block) &&
         (vpu_raw_pair_group_blocks == vpu_raw_group_blocks) &&
         (stream_enqueue_p3_pair_weight_index_w < STREAM_P3_ENTRIES_PER_BANK) &&
         (stream_enqueue_p3_pair_weight_word_index_w < WORD_DEPTH));
    wire stream_idle = (stream_state_r == STREAM_IDLE);
    wire stream_fifo_empty = (stream_fifo_count_r == 0);
    wire stream_fifo_full = (stream_fifo_count_r == STREAM_FIFO_DEPTH);
    wire stream_test_stall = (STREAM_TEST_STALL_ENABLE != 0) &&
                            (stream_test_stall_count_r != 0);
    wire stream_push = (VPU_BUNDLE8_ENABLE == 0) && vpu_raw_valid && legacy_vpu_raw_ready;
    wire stream_pop = stream_idle && !stream_fifo_empty;
    wire stream_p3_bank_mismatch = stream_split_scale_enable &&
                                   stream_p3_bank_lock_valid_r &&
                                   (vpu_raw_bank != stream_p3_bank_lock_r);
    // Do not accept the first P3 raw token while a command-mode SPU operator
    // owns its core memory port.  Once a P3 lock exists, command starts are
    // blocked below, so controller traffic cannot write PARAM/SCRATCH behind
    // the stream's ownership protocol.
    wire legacy_vpu_raw_ready = resetn && !stream_fifo_full && !stream_test_stall &&
                           !stream_p3_bank_mismatch &&
                           (!stream_split_scale_enable || !spu_busy);
    wire stream_result_write = stream_accum_out_valid;
    wire stream_pair_result_write = stream_accum_pair_out_valid;
    wire stream_scale_read = (stream_state_r == STREAM_READ_SCALE);
    wire stream_scale_port =
        (stream_state_r == STREAM_READ_SCALE) ||
        (stream_state_r == STREAM_CAPTURE_SCALE);
    wire [AXI_DATA_WIDTH-1:0] stream_result_wdata =
        {{(AXI_DATA_WIDTH-80){1'b0}},
         stream_accum_out_q16,
         stream_accum_out_row_id};
    wire [AXI_DATA_WIDTH-1:0] stream_pair_result_wdata =
        {{(AXI_DATA_WIDTH-80){1'b0}},
         stream_accum_pair_out_q16,
         stream_accum_pair_out_row_id};
    wire                              legacy_core_mem_en =
        stream_result_write ? 1'b1 :
        stream_scale_read   ? 1'b1 : ctrl_mem_en;
    wire                              legacy_core_mem_we =
        stream_result_write ? 1'b1 :
        stream_scale_read   ? 1'b0 : ctrl_mem_we;
    wire [1:0]                        legacy_core_mem_region =
        stream_result_write ? REGION_OUT :
        stream_scale_port   ? REGION_PARAM : ctrl_mem_region;
    wire [31:0]                       legacy_core_mem_index =
        stream_result_write ? {16'd0, stream_accum_out_row_id} :
        stream_scale_port   ? stream_scale_word_index_r : ctrl_mem_index;
    wire [AXI_DATA_WIDTH-1:0]         legacy_core_mem_wdata =
        stream_result_write ? stream_result_wdata : ctrl_mem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]     legacy_core_mem_wstrb =
        stream_result_write ? 16'h03ff : ctrl_mem_wstrb;
    wire                              legacy_core_mem2_en =
        stream_pair_result_write ? 1'b1 :
        ((stream_state_r == STREAM_READ_SCALE) && stream_pair_valid_r);
    wire                              legacy_core_mem2_we = stream_pair_result_write;
    wire [1:0]                        legacy_core_mem2_region =
        stream_pair_result_write ? REGION_OUT : REGION_PARAM;
    wire [31:0]                       legacy_core_mem2_index =
        stream_pair_result_write ? {16'd0, stream_accum_pair_out_row_id} :
        stream_pair_scale_word_index_r;
    wire [AXI_DATA_WIDTH-1:0]         legacy_core_mem2_wdata = stream_pair_result_write ?
        stream_pair_result_wdata : {AXI_DATA_WIDTH{1'b0}};
    wire [(AXI_DATA_WIDTH/8)-1:0]     legacy_core_mem2_wstrb = stream_pair_result_write ?
        16'h03ff : {(AXI_DATA_WIDTH/8){1'b0}};
    wire [AXI_DATA_WIDTH-1:0]         core_mem2_rdata;
    wire                              legacy_core_mem3_scratch_en =
        stream_p3_r && (stream_state_r == STREAM_READ_SCALE);
    wire [31:0]                       legacy_core_mem3_scratch_index =
        stream_act_scale_word_index_r;

    wire bundle8_active = (VPU_BUNDLE8_ENABLE != 0);
    wire bundle8_ready;
    wire b8_mem0_en, b8_mem0_we, b8_mem1_en, b8_mem1_we, b8_mem3_en;
    wire [1:0] b8_mem0_region, b8_mem1_region;
    wire [31:0] b8_mem0_index, b8_mem1_index, b8_mem3_index;
    wire [AXI_DATA_WIDTH-1:0] b8_mem0_wdata, b8_mem1_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] b8_mem0_wstrb, b8_mem1_wstrb;
    wire b8_lock_valid, b8_lock_bank;
    wire [31:0] b8_count,b8_done_count,b8_drop_count,b8_out_count,b8_error_count;
    wire [31:0] b8_last_raw,b8_last_meta,b8_last_accum_lo,b8_last_accum_hi,b8_last_job,b8_last_bank;
    wire [31:0] b8_status,b8_high_water,b8_stall_cycles,b8_entry_done_count,b8_final_write_count,b8_p3_reject_count,b8_p3_status;

    SPU_VPU_Stream8 #(.AXI_DATA_WIDTH(AXI_DATA_WIDTH), .WORD_DEPTH(WORD_DEPTH), .MAX_ROWS(SCALE_ACCUM_ROWS)) u_vpu_stream8 (
        .clk(clk), .resetn(resetn), .soft_reset(spu_soft_reset), .command_busy(spu_busy),
        .split_scale_enable(stream_split_scale_enable),
        .vpu_valid(vpu_raw_valid), .vpu_ready(bundle8_ready), .vpu_lane_valid(vpu_raw_lane_valid),
        .vpu_lane_data(vpu_raw_lane_data), .vpu_lane_row(vpu_raw_lane_row), .vpu_lane_scale_index(vpu_raw_lane_scale_index),
        .vpu_block(vpu_raw_block), .vpu_group_blocks(vpu_raw_group_blocks), .vpu_last_block(vpu_raw_last_block),
        .vpu_clear_accum(vpu_raw_clear_accum), .vpu_job_id(vpu_raw_job_id), .vpu_bank(vpu_raw_bank), .vpu_done(vpu_raw_done),
        .mem0_en(b8_mem0_en), .mem0_we(b8_mem0_we), .mem0_region(b8_mem0_region), .mem0_index(b8_mem0_index), .mem0_wdata(b8_mem0_wdata), .mem0_wstrb(b8_mem0_wstrb), .mem0_rdata(core_mem_rdata),
        .mem1_en(b8_mem1_en), .mem1_we(b8_mem1_we), .mem1_region(b8_mem1_region), .mem1_index(b8_mem1_index), .mem1_wdata(b8_mem1_wdata), .mem1_wstrb(b8_mem1_wstrb), .mem1_rdata(core_mem2_rdata),
        .mem3_scratch_en(b8_mem3_en), .mem3_scratch_index(b8_mem3_index), .mem3_scratch_rdata(core_mem3_rdata),
        .p3_bank_lock_valid(b8_lock_valid), .p3_bank_lock(b8_lock_bank),
        .stream_count(b8_count), .stream_done_count(b8_done_count), .stream_drop_count(b8_drop_count), .stream_out_count(b8_out_count), .stream_error_count(b8_error_count),
        .stream_last_raw(b8_last_raw), .stream_last_meta(b8_last_meta), .stream_last_accum_lo(b8_last_accum_lo), .stream_last_accum_hi(b8_last_accum_hi), .stream_last_job(b8_last_job), .stream_last_bank(b8_last_bank),
        .stream_status(b8_status), .stream_fifo_high_water(b8_high_water), .stream_raw_stall_cycles(b8_stall_cycles), .stream_entry_done_count(b8_entry_done_count),
        .stream_final_write_count(b8_final_write_count), .stream_p3_reject_count(b8_p3_reject_count), .stream_p3_status(b8_p3_status));

    assign vpu_raw_ready = bundle8_active ? bundle8_ready : legacy_vpu_raw_ready;
    wire effective_stream_lock_valid = bundle8_active ? b8_lock_valid : stream_p3_bank_lock_valid_r;
    wire effective_stream_lock_bank = bundle8_active ? b8_lock_bank : stream_p3_bank_lock_r;

    wire core_mem_en = bundle8_active ? (b8_mem0_en ? 1'b1 : ctrl_mem_en) : legacy_core_mem_en;
    wire core_mem_we = bundle8_active ? (b8_mem0_en ? b8_mem0_we : ctrl_mem_we) : legacy_core_mem_we;
    wire [1:0] core_mem_region = bundle8_active ? (b8_mem0_en ? b8_mem0_region : ctrl_mem_region) : legacy_core_mem_region;
    wire [31:0] core_mem_index = bundle8_active ? (b8_mem0_en ? b8_mem0_index : ctrl_mem_index) : legacy_core_mem_index;
    wire [AXI_DATA_WIDTH-1:0] core_mem_wdata = bundle8_active ? (b8_mem0_en ? b8_mem0_wdata : ctrl_mem_wdata) : legacy_core_mem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] core_mem_wstrb = bundle8_active ? (b8_mem0_en ? b8_mem0_wstrb : ctrl_mem_wstrb) : legacy_core_mem_wstrb;
    wire core_mem2_en = bundle8_active ? b8_mem1_en : legacy_core_mem2_en;
    wire core_mem2_we = bundle8_active ? b8_mem1_we : legacy_core_mem2_we;
    wire [1:0] core_mem2_region = bundle8_active ? b8_mem1_region : legacy_core_mem2_region;
    wire [31:0] core_mem2_index = bundle8_active ? b8_mem1_index : legacy_core_mem2_index;
    wire [AXI_DATA_WIDTH-1:0] core_mem2_wdata = bundle8_active ? b8_mem1_wdata : legacy_core_mem2_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] core_mem2_wstrb = bundle8_active ? b8_mem1_wstrb : legacy_core_mem2_wstrb;
    wire core_mem3_scratch_en = bundle8_active ? b8_mem3_en : legacy_core_mem3_scratch_en;
    wire [31:0] core_mem3_scratch_index = bundle8_active ? b8_mem3_index : legacy_core_mem3_scratch_index;

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
    // bit 11 is P3 dense split-scale support.  Arithmetic capabilities for
    // SiLU/RMSNorm/RoPE/Softmax deliberately remain clear until graph routing
    // has its own end-to-end numerical contract.
    assign spu_caps = {WORD_DEPTH_16, 4'd0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1,
                       softmax_supported, rope_supported, rmsnorm_supported,
                       silu_supported, 1'b1, 1'b1};

    assign vpu_stream_count = bundle8_active ? b8_count : vpu_stream_count_r;
    assign vpu_stream_done_count = bundle8_active ? b8_done_count : vpu_stream_done_count_r;
    assign vpu_stream_drop_count = bundle8_active ? b8_drop_count : vpu_stream_drop_count_r;
    assign vpu_stream_out_count = bundle8_active ? b8_out_count : vpu_stream_out_count_r;
    assign vpu_stream_error_count = bundle8_active ? b8_error_count : vpu_stream_error_count_r;
    assign vpu_stream_last_raw = bundle8_active ? b8_last_raw : vpu_stream_last_raw_r;
    assign vpu_stream_last_meta = bundle8_active ? b8_last_meta : vpu_stream_last_meta_r;
    assign vpu_stream_last_accum_lo = bundle8_active ? b8_last_accum_lo : vpu_stream_last_accum_lo_r;
    assign vpu_stream_last_accum_hi = bundle8_active ? b8_last_accum_hi : vpu_stream_last_accum_hi_r;
    assign vpu_stream_last_job = bundle8_active ? b8_last_job : vpu_stream_last_job_r;
    assign vpu_stream_last_bank = bundle8_active ? b8_last_bank : vpu_stream_last_bank_r;
    assign vpu_stream_fifo_high_water = bundle8_active ? b8_high_water : vpu_stream_fifo_high_water_r;
    assign vpu_stream_raw_stall_cycles = bundle8_active ? b8_stall_cycles : vpu_stream_raw_stall_cycles_r;
    assign vpu_stream_entry_done_count = bundle8_active ? b8_entry_done_count : vpu_stream_entry_done_count_r;
    assign vpu_stream_final_write_count = bundle8_active ? b8_final_write_count : vpu_stream_final_write_count_r;
    assign vpu_stream_p3_reject_count = bundle8_active ? b8_p3_reject_count : vpu_stream_p3_reject_count_r;
    // bit 0: dequeue FSM idle, bit 1: FIFO empty, bit 2: scale accumulator
    // idle, bit 3: no SPU_OUT write in this cycle, bit 4: all of the above.
    // The host requires bit 4 before it may reuse SPU_PARAM/SPU_OUT.
    wire [31:0] legacy_stream_status;
    assign legacy_stream_status[0] = stream_idle;
    assign legacy_stream_status[1]     = stream_fifo_empty;
    assign legacy_stream_status[2]     = !stream_accum_busy && !stream_accum_pair_busy;
    assign legacy_stream_status[3]     = !stream_result_write && !stream_pair_result_write;
    assign legacy_stream_status[4]     = stream_idle && stream_fifo_empty &&
                                      !stream_accum_busy && !stream_accum_pair_busy &&
                                      !stream_result_write && !stream_pair_result_write;
    assign legacy_stream_status[5]     = stream_p3_bank_lock_valid_r;
    assign legacy_stream_status[6]     = stream_p3_bank_lock_r;
    assign legacy_stream_status[31:7]  = 25'd0;
    wire [31:0] legacy_stream_p3_status = {24'd0,
                                    stream_split_scale_enable,
                                    stream_p3_done_seen_r,
                                    stream_p3_bank_lock_r,
                                    stream_p3_bank_lock_valid_r,
                                    stream_p3_r,
                                    stream_fifo_full,
                                    stream_fifo_empty,
                                    stream_idle};
    assign vpu_stream_status = bundle8_active ? b8_status : legacy_stream_status;
    assign vpu_stream_p3_status = bundle8_active ? b8_p3_status : legacy_stream_p3_status;

    always @(posedge clk) begin
        if (!resetn) begin
            stream_accum_start_r      <= 1'b0;
            stream_accum_pair_start_r <= 1'b0;
            stream_state_r            <= STREAM_IDLE;
            stream_raw_r              <= 32'sd0;
            stream_row_r              <= 16'd0;
            stream_last_block_r       <= 1'b0;
            stream_clear_accum_r      <= 1'b0;
            stream_scale_word_index_r <= 32'd0;
            stream_scale_lane_r       <= 2'd0;
            stream_scale_word_r       <= 32'd0;
            stream_pair_valid_r       <= 1'b0;
            stream_pair_raw_r         <= 32'sd0;
            stream_pair_row_r         <= 16'd0;
            stream_pair_last_block_r  <= 1'b0;
            stream_pair_clear_accum_r <= 1'b0;
            stream_pair_scale_word_index_r <= 32'd0;
            stream_pair_scale_lane_r  <= 2'd0;
            stream_pair_scale_word_r  <= 32'd0;
            stream_p3_r               <= 1'b0;
            stream_act_scale_word_index_r <= 32'd0;
            stream_act_scale_lane_r   <= 3'd0;
            stream_p3_bank_lock_valid_r <= 1'b0;
            stream_p3_bank_lock_r     <= 1'b0;
            stream_p3_done_seen_r     <= 1'b0;
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
            vpu_stream_fifo_high_water_r <= 32'd0;
            vpu_stream_raw_stall_cycles_r <= 32'd0;
            vpu_stream_entry_done_count_r <= 32'd0;
            vpu_stream_final_write_count_r <= 32'd0;
            vpu_stream_p3_reject_count_r <= 32'd0;
            stream_fifo_wr_ptr_r       <= {STREAM_FIFO_PTR_WIDTH{1'b0}};
            stream_fifo_rd_ptr_r       <= {STREAM_FIFO_PTR_WIDTH{1'b0}};
            stream_fifo_count_r        <= {STREAM_FIFO_COUNT_WIDTH{1'b0}};
            stream_test_lfsr_r         <= 16'h1;
            stream_test_stall_count_r  <= 6'd0;
        end else begin
            stream_accum_start_r <= 1'b0;
            stream_accum_pair_start_r <= 1'b0;

            if (spu_soft_reset) begin
                stream_state_r            <= STREAM_IDLE;
                stream_raw_r              <= 32'sd0;
                stream_row_r              <= 16'd0;
                stream_last_block_r       <= 1'b0;
                stream_clear_accum_r      <= 1'b0;
                stream_scale_word_index_r <= 32'd0;
                stream_scale_lane_r       <= 2'd0;
                stream_scale_word_r       <= 32'd0;
                stream_pair_valid_r       <= 1'b0;
                stream_pair_raw_r         <= 32'sd0;
                stream_pair_row_r         <= 16'd0;
                stream_pair_last_block_r  <= 1'b0;
                stream_pair_clear_accum_r <= 1'b0;
                stream_pair_scale_word_index_r <= 32'd0;
                stream_pair_scale_lane_r  <= 2'd0;
                stream_pair_scale_word_r  <= 32'd0;
                stream_p3_r               <= 1'b0;
                stream_act_scale_word_index_r <= 32'd0;
                stream_act_scale_lane_r   <= 3'd0;
                stream_p3_bank_lock_valid_r <= 1'b0;
                stream_p3_bank_lock_r     <= 1'b0;
                stream_p3_done_seen_r     <= 1'b0;
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
                vpu_stream_fifo_high_water_r <= 32'd0;
                vpu_stream_raw_stall_cycles_r <= 32'd0;
                vpu_stream_entry_done_count_r <= 32'd0;
                vpu_stream_final_write_count_r <= 32'd0;
                vpu_stream_p3_reject_count_r <= 32'd0;
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

            // Count only producer-visible ready/valid pressure.  This counter
            // does not infer a drop: the VPU holds its raw token stable until
            // ready returns high.
            if (vpu_raw_valid && !vpu_raw_ready)
                vpu_stream_raw_stall_cycles_r <= vpu_stream_raw_stall_cycles_r + 32'd1;

            if (mm_wr_rejected)
                vpu_stream_p3_reject_count_r <= vpu_stream_p3_reject_count_r + 32'd1;

            if (stream_push) begin
                stream_fifo_raw[stream_fifo_wr_ptr_r]          <= vpu_raw_data;
                stream_fifo_row[stream_fifo_wr_ptr_r]          <= vpu_raw_row;
                stream_fifo_last_block[stream_fifo_wr_ptr_r]   <= vpu_raw_last_block;
                stream_fifo_clear_accum[stream_fifo_wr_ptr_r]  <= vpu_raw_clear_accum;
                stream_fifo_scale_word_index[stream_fifo_wr_ptr_r] <=
                    stream_split_scale_enable ? stream_enqueue_p3_weight_word_index_w :
                                                stream_enqueue_scale_word_index_w;
                stream_fifo_scale_lane[stream_fifo_wr_ptr_r] <=
                    stream_split_scale_enable ? stream_enqueue_p3_weight_index_w[2:0] :
                                                {1'b0, stream_enqueue_scale_index_w[1:0]};
                stream_fifo_scale_index_ok[stream_fifo_wr_ptr_r] <=
                    stream_split_scale_enable ? stream_enqueue_p3_index_ok :
                                                stream_enqueue_scale_index_ok;
                stream_fifo_job_id[stream_fifo_wr_ptr_r]       <= vpu_raw_job_id;
                stream_fifo_bank[stream_fifo_wr_ptr_r]         <= vpu_raw_bank;
                stream_fifo_pair_valid[stream_fifo_wr_ptr_r]   <= vpu_raw_pair_valid;
                stream_fifo_pair_raw[stream_fifo_wr_ptr_r]     <= vpu_raw_pair_data;
                stream_fifo_pair_row[stream_fifo_wr_ptr_r]     <= vpu_raw_pair_row;
                stream_fifo_pair_last_block[stream_fifo_wr_ptr_r] <= vpu_raw_pair_last_block;
                stream_fifo_pair_clear_accum[stream_fifo_wr_ptr_r] <= vpu_raw_pair_clear_accum;
                stream_fifo_pair_scale_word_index[stream_fifo_wr_ptr_r] <=
                    stream_split_scale_enable ? stream_enqueue_p3_pair_weight_word_index_w :
                                                stream_enqueue_pair_scale_word_index_w;
                stream_fifo_pair_scale_lane[stream_fifo_wr_ptr_r] <=
                    stream_split_scale_enable ? stream_enqueue_p3_pair_weight_index_w[2:0] :
                                                {1'b0, stream_enqueue_pair_scale_index_w[1:0]};
                stream_fifo_pair_scale_index_ok[stream_fifo_wr_ptr_r] <=
                    stream_split_scale_enable ? stream_enqueue_p3_pair_index_ok :
                                                stream_enqueue_pair_scale_index_ok;
                stream_fifo_p3[stream_fifo_wr_ptr_r] <= stream_split_scale_enable;
                stream_fifo_act_scale_word_index[stream_fifo_wr_ptr_r] <=
                    stream_enqueue_p3_act_word_index_w;
                stream_fifo_act_scale_lane[stream_fifo_wr_ptr_r] <= vpu_raw_block[2:0];
                stream_fifo_wr_ptr_r <= stream_fifo_next_ptr(stream_fifo_wr_ptr_r);
                vpu_stream_count_r <= vpu_stream_count_r + (vpu_raw_pair_valid ? 32'd2 : 32'd1);
                vpu_stream_last_raw_r <= vpu_raw_data;
                vpu_stream_last_meta_r <= {vpu_raw_clear_accum,
                                           vpu_raw_last_block,
                                           vpu_raw_block[13:0],
                                           vpu_raw_row};
                vpu_stream_last_job_r <= vpu_raw_job_id;
                vpu_stream_last_bank_r <= {31'd0, vpu_raw_bank};
                // Publish the highest row in a retained pair as the stream
                // tail. This makes finality/diagnostics match the completed
                // logical row sequence rather than only lane 0.
                if (vpu_raw_pair_valid) begin
                    vpu_stream_last_raw_r <= vpu_raw_pair_data;
                    vpu_stream_last_meta_r <= {vpu_raw_pair_clear_accum,
                                               vpu_raw_pair_last_block,
                                               vpu_raw_pair_block[13:0],
                                               vpu_raw_pair_row};
                    vpu_stream_last_job_r <= vpu_raw_pair_job_id;
                    vpu_stream_last_bank_r <= {31'd0, vpu_raw_pair_bank};
                end
                if (stream_split_scale_enable && !stream_p3_bank_lock_valid_r) begin
                    stream_p3_bank_lock_valid_r <= 1'b1;
                    stream_p3_bank_lock_r <= vpu_raw_bank;
                end
            end

            if (stream_pop)
                stream_fifo_rd_ptr_r <= stream_fifo_next_ptr(stream_fifo_rd_ptr_r);

            case ({stream_push, stream_pop})
                2'b10: stream_fifo_count_r <= stream_fifo_count_r + {{(STREAM_FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                2'b01: stream_fifo_count_r <= stream_fifo_count_r - {{(STREAM_FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                default: stream_fifo_count_r <= stream_fifo_count_r;
            endcase

            if (stream_push && !stream_pop &&
                (stream_fifo_count_r + {{(STREAM_FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1} >
                 vpu_stream_fifo_high_water_r))
                vpu_stream_fifo_high_water_r <=
                    stream_fifo_count_r + {{(STREAM_FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};

            if (vpu_raw_done)
                vpu_stream_done_count_r <= vpu_stream_done_count_r + 32'd1;
            // Completion is tied to the latched P3 bank owner, never to the
            // live mode register.  A mode-disable request during the drained
            // pre-done interval cannot strand the bank lock.
            if (vpu_raw_done && stream_p3_bank_lock_valid_r)
                stream_p3_done_seen_r <= 1'b1;

            if ((stream_accum_entry_done && stream_accum_error) ||
                (stream_accum_pair_entry_done && stream_accum_pair_error))
                vpu_stream_error_count_r <= vpu_stream_error_count_r +
                    ((stream_accum_entry_done && stream_accum_error ? 32'd1 : 32'd0) +
                     (stream_accum_pair_entry_done && stream_accum_pair_error ? 32'd1 : 32'd0));

            if (stream_accum_entry_done || stream_accum_pair_entry_done)
                vpu_stream_entry_done_count_r <= vpu_stream_entry_done_count_r +
                    (stream_accum_entry_done ? 32'd1 : 32'd0) +
                    (stream_accum_pair_entry_done ? 32'd1 : 32'd0);

            if (stream_accum_out_valid) begin
                vpu_stream_out_count_r     <= vpu_stream_out_count_r +
                                              (stream_accum_pair_out_valid ? 32'd2 : 32'd1);
                vpu_stream_last_accum_lo_r <= stream_accum_out_q16[31:0];
                vpu_stream_last_accum_hi_r <= stream_accum_out_q16[63:32];
            end
            if (stream_accum_pair_out_valid) begin
                vpu_stream_last_accum_lo_r <= stream_accum_pair_out_q16[31:0];
                vpu_stream_last_accum_hi_r <= stream_accum_pair_out_q16[63:32];
            end
            if (stream_accum_out_valid || stream_accum_pair_out_valid)
                vpu_stream_final_write_count_r <= vpu_stream_final_write_count_r +
                    (stream_accum_out_valid ? 32'd1 : 32'd0) +
                    (stream_accum_pair_out_valid ? 32'd1 : 32'd0);

            // Release a P3 bank only after VPU end-of-stream has arrived and
            // every queued/raw/accumulator/output stage is quiescent.  Payload
            // RAM itself is intentionally not reset or cleared.
            if (stream_p3_done_seen_r && stream_idle && stream_fifo_empty &&
                !stream_accum_busy && !stream_accum_pair_busy &&
                !stream_result_write && !stream_pair_result_write) begin
                stream_p3_bank_lock_valid_r <= 1'b0;
                stream_p3_done_seen_r <= 1'b0;
            end

            case (stream_state_r)
                STREAM_IDLE: begin
                    if (stream_pop) begin
                        if (stream_fifo_scale_index_ok[stream_fifo_rd_ptr_r] &&
                            (!stream_fifo_pair_valid[stream_fifo_rd_ptr_r] ||
                             stream_fifo_pair_scale_index_ok[stream_fifo_rd_ptr_r])) begin
                            stream_raw_r          <= stream_fifo_raw[stream_fifo_rd_ptr_r];
                            stream_row_r          <= stream_fifo_row[stream_fifo_rd_ptr_r];
                            stream_last_block_r   <= stream_fifo_last_block[stream_fifo_rd_ptr_r];
                            stream_clear_accum_r  <= stream_fifo_clear_accum[stream_fifo_rd_ptr_r];
                            stream_scale_word_index_r <=
                                stream_fifo_scale_word_index[stream_fifo_rd_ptr_r];
                            stream_scale_lane_r   <=
                                stream_fifo_scale_lane[stream_fifo_rd_ptr_r];
                            stream_p3_r           <= stream_fifo_p3[stream_fifo_rd_ptr_r];
                            stream_act_scale_word_index_r <=
                                stream_fifo_act_scale_word_index[stream_fifo_rd_ptr_r];
                            stream_act_scale_lane_r <=
                                stream_fifo_act_scale_lane[stream_fifo_rd_ptr_r];
                            stream_pair_valid_r   <= stream_fifo_pair_valid[stream_fifo_rd_ptr_r];
                            stream_pair_raw_r     <= stream_fifo_pair_raw[stream_fifo_rd_ptr_r];
                            stream_pair_row_r     <= stream_fifo_pair_row[stream_fifo_rd_ptr_r];
                            stream_pair_last_block_r <= stream_fifo_pair_last_block[stream_fifo_rd_ptr_r];
                            stream_pair_clear_accum_r <= stream_fifo_pair_clear_accum[stream_fifo_rd_ptr_r];
                            stream_pair_scale_word_index_r <=
                                stream_fifo_pair_scale_word_index[stream_fifo_rd_ptr_r];
                            stream_pair_scale_lane_r <=
                                stream_fifo_pair_scale_lane[stream_fifo_rd_ptr_r];
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
                    if (stream_p3_r) begin
                        stream_scale_word_r <= {
                            core_mem_rdata[16*stream_scale_lane_r +: 16],
                            core_mem3_rdata[16*stream_act_scale_lane_r +: 16]};
                        if (stream_pair_valid_r)
                            stream_pair_scale_word_r <= {
                                core_mem2_rdata[16*stream_pair_scale_lane_r +: 16],
                                core_mem3_rdata[16*stream_act_scale_lane_r +: 16]};
                    end else begin
                        stream_scale_word_r <= core_mem_rdata[32*stream_scale_lane_r +: 32];
                        if (stream_pair_valid_r)
                            stream_pair_scale_word_r <= core_mem2_rdata[32*stream_pair_scale_lane_r +: 32];
                    end
                    stream_state_r      <= STREAM_START;
                end

                STREAM_START: begin
                    if (!stream_accum_busy) begin
                        stream_accum_start_r <= 1'b1;
                        if (stream_pair_valid_r && !stream_accum_pair_busy)
                            stream_accum_pair_start_r <= 1'b1;
                        stream_state_r       <= STREAM_WAIT;
                    end
                end

                STREAM_WAIT: begin
                    if (stream_accum_entry_done &&
                        (!stream_pair_valid_r || stream_accum_pair_entry_done))
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

    SPU_Q8_Scale_Accum #(
        .ROW_ID_WIDTH (16), .MAX_ROWS (SCALE_ACCUM_ROWS),
        .ACC_WIDTH (64), .FIXED_FRAC_BITS (16)
    ) u_vpu_stream_pair_scale_accum (
        .clk              (clk), .resetn (resetn), .start (stream_accum_pair_start_r),
        .raw_in           (stream_pair_raw_r),
        .act_scale_fp16   (stream_pair_scale_word_r[15:0]),
        .weight_scale_fp16(stream_pair_scale_word_r[31:16]),
        .row_id           (stream_pair_row_r),
        .clear_accum      (stream_pair_clear_accum_r),
        .last_block       (stream_pair_last_block_r),
        .busy             (stream_accum_pair_busy),
        .entry_done       (stream_accum_pair_entry_done),
        .out_valid        (stream_accum_pair_out_valid),
        .out_row_id       (stream_accum_pair_out_row_id),
        .out_accum_q16    (stream_accum_pair_out_q16),
        .error            (stream_accum_pair_error), .error_code ()
    );

    SPU_Controller #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH),
        .SCALE_ACCUM_ROWS (SCALE_ACCUM_ROWS)
    ) u_spu_controller (
        .clk          (clk),
        .resetn       (resetn),
        .start        (spu_start && !effective_stream_lock_valid && (!bundle8_active || b8_status[4])),
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
        ,.core2_en       (core_mem2_en)
        ,.core2_we       (core_mem2_we)
        ,.core2_region   (core_mem2_region)
        ,.core2_index    (core_mem2_index)
        ,.core2_wdata    (core_mem2_wdata)
        ,.core2_wstrb    (core_mem2_wstrb)
        ,.core2_rdata    (core_mem2_rdata)
        ,.core3_scratch_en(core_mem3_scratch_en)
        ,.core3_scratch_index(core_mem3_scratch_index)
        ,.core3_scratch_rdata(core_mem3_rdata)
        ,.stream_p3_bank_lock_valid(effective_stream_lock_valid)
        ,.stream_p3_bank_lock(effective_stream_lock_bank)
        ,.mm_wr_rejected(mm_wr_rejected)
    );

endmodule
