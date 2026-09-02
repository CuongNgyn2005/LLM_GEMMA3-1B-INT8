/*
 * 8-lane VPU -> SPU Q8_0 scale/accumulate stream.
 * One accepted bundle carries up to eight row results for one Q8 block.
 * Scale RAM is read two rows/cycle through the existing two PARAM ports;
 * all valid rows then execute SPU_Q8_Scale_Accum in parallel.
 *
 * P2 bundles first enter a four-entry FIFO, then one look-ahead slot pipelines
 * the four PARAM read pairs. The synchronous BRAM return tags advance while
 * the next pair is issued, so after fill one scale pair is launched per clock.
 * Each P2 lane also keeps the last full 128-bit PARAM word it fetched. Because
 * four consecutive P2 scale entries share one PARAM word, a following bundle
 * from the same job can select another 32-bit entry from that registered word
 * without issuing another BRAM read. A bundle takes the fast path only when
 * every valid lane hits both job_id and word index; otherwise the original
 * registered two-port read pipeline is used unchanged. The cache is cleared on
 * reset/soft-reset and never participates in P3, so it cannot change P3 memory
 * ownership or turn a P2 miss into speculative scale data.
 *
 * A ready look-ahead bundle can start the eight accumulators on the same edge
 * that it becomes the active bundle. If another FIFO entry exists, the
 * look-ahead slot is replaced on that handoff edge. P3 retains its original
 * direct registered read protocol and memory ownership rules.
 */
`timescale 1ns/1ps

module SPU_VPU_Stream8 #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH = 4096,
    parameter integer MAX_ROWS = 256
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         soft_reset,
    input  wire                         command_busy,
    input  wire                         split_scale_enable,

    input  wire                         vpu_valid,
    output wire                         vpu_ready,
    input  wire [7:0]                   vpu_lane_valid,
    input  wire [8*32-1:0]              vpu_lane_data,
    input  wire [8*16-1:0]              vpu_lane_row,
    input  wire [8*32-1:0]              vpu_lane_scale_index,
    input  wire [15:0]                  vpu_block,
    input  wire [15:0]                  vpu_group_blocks,
    input  wire                         vpu_last_block,
    input  wire                         vpu_clear_accum,
    input  wire [31:0]                  vpu_job_id,
    input  wire                         vpu_bank,
    input  wire                         vpu_done,

    output reg                          mem0_en,
    output reg                          mem0_we,
    output reg  [1:0]                   mem0_region,
    output reg  [31:0]                  mem0_index,
    output reg  [AXI_DATA_WIDTH-1:0]    mem0_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0] mem0_wstrb,
    input  wire [AXI_DATA_WIDTH-1:0]    mem0_rdata,

    output reg                          mem1_en,
    output reg                          mem1_we,
    output reg  [1:0]                   mem1_region,
    output reg  [31:0]                  mem1_index,
    output reg  [AXI_DATA_WIDTH-1:0]    mem1_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0] mem1_wstrb,
    input  wire [AXI_DATA_WIDTH-1:0]    mem1_rdata,

    output reg                          mem3_scratch_en,
    output reg  [31:0]                  mem3_scratch_index,
    input  wire [AXI_DATA_WIDTH-1:0]    mem3_scratch_rdata,

    output reg                          p3_bank_lock_valid,
    output reg                          p3_bank_lock,

    output reg  [31:0]                  stream_count,
    output reg  [31:0]                  stream_done_count,
    output reg  [31:0]                  stream_drop_count,
    output reg  [31:0]                  stream_out_count,
    output reg  [31:0]                  stream_error_count,
    output reg  [31:0]                  stream_last_raw,
    output reg  [31:0]                  stream_last_meta,
    output reg  [31:0]                  stream_last_accum_lo,
    output reg  [31:0]                  stream_last_accum_hi,
    output reg  [31:0]                  stream_last_job,
    output reg  [31:0]                  stream_last_bank,
    output wire [31:0]                  stream_status,
    output reg  [31:0]                  stream_fifo_high_water,
    output reg  [31:0]                  stream_raw_stall_cycles,
    output reg  [31:0]                  stream_entry_done_count,
    output reg  [31:0]                  stream_final_write_count,
    output reg  [31:0]                  stream_p3_reject_count,
    output wire [31:0]                  stream_p3_status
);
    localparam [1:0] REGION_OUT = 2'd1;
    localparam [1:0] REGION_PARAM = 2'd2;
    localparam integer SCALE32_PER_WORD = AXI_DATA_WIDTH/32;
    localparam integer SCALE16_PER_WORD = AXI_DATA_WIDTH/16;
    localparam integer P3_BANK_WORD_DEPTH = WORD_DEPTH/2;
    localparam [31:0] P2_ENTRY_DEPTH = WORD_DEPTH*SCALE32_PER_WORD;
    localparam [31:0] P3_ENTRY_DEPTH = P3_BANK_WORD_DEPTH*SCALE16_PER_WORD;

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_READ     = 3'd1;
    localparam [2:0] S_CAPTURE  = 3'd2;
    localparam [2:0] S_START    = 3'd3;
    localparam [2:0] S_WAIT     = 3'd4;
    localparam [2:0] S_WRITE    = 3'd5;
    localparam [2:0] S_RESPONSE = 3'd6;

    localparam [2:0] PF_IDLE     = 3'd0;
    localparam [2:0] PF_READ     = 3'd1;
    localparam [2:0] PF_CAPTURE  = 3'd2;
    localparam [2:0] PF_READY    = 3'd3;
    localparam [2:0] PF_RESPONSE = 3'd4;
    localparam [2:0] PF_CHECK    = 3'd5;

    reg [2:0] state_r;
    reg [1:0] pair_idx_r;
    reg [7:0] lane_valid_r;
    reg signed [31:0] raw_r [0:7];
    reg [15:0] row_r [0:7];
    reg [31:0] scale_word_index_r [0:7];
    reg [2:0] scale_lane_r [0:7];
    reg [15:0] act_scale_r [0:7];
    reg [15:0] weight_scale_r [0:7];
    reg signed [63:0] final_q16_r [0:7];
    reg [15:0] block_r;
    reg [15:0] group_blocks_r;
    reg last_block_r;
    reg clear_accum_r;
    reg [31:0] job_id_r;
    reg bank_r;
    reg p3_r;
    reg p3_done_seen_r;
    reg [15:0] p3_act_scale_r;
    reg [7:0] accum_start_r;

    reg read_req_valid_r;
    reg read_req_lane0_valid_r;
    reg read_req_lane1_valid_r;
    reg [2:0] read_req_lane0_dest_r;
    reg [2:0] read_req_lane1_dest_r;
    reg [31:0] read_req_lane0_word_index_r;
    reg [31:0] read_req_lane1_word_index_r;
    reg [2:0] read_req_lane0_scale_lane_r;
    reg [2:0] read_req_lane1_scale_lane_r;
    reg read_req_p3_r;
    reg read_req_scratch_valid_r;
    reg [31:0] read_req_scratch_index_r;
    reg [2:0] read_req_scratch_lane_r;

    reg [AXI_DATA_WIDTH-1:0] read_rsp_mem0_data_r;
    reg [AXI_DATA_WIDTH-1:0] read_rsp_mem1_data_r;
    reg [AXI_DATA_WIDTH-1:0] read_rsp_scratch_data_r;
    reg read_rsp_valid_r;
    reg read_rsp_lane0_valid_r;
    reg read_rsp_lane1_valid_r;
    reg [2:0] read_rsp_lane0_dest_r;
    reg [2:0] read_rsp_lane1_dest_r;
    reg [2:0] read_rsp_lane0_scale_lane_r;
    reg [2:0] read_rsp_lane1_scale_lane_r;
    reg read_rsp_p3_r;
    reg read_rsp_scratch_valid_r;
    reg [2:0] read_rsp_scratch_lane_r;

    reg write_req_valid_r;
    reg write_req_lane0_valid_r;
    reg write_req_lane1_valid_r;
    reg [2:0] write_req_lane0_dest_r;
    reg [2:0] write_req_lane1_dest_r;
    reg [15:0] write_req_lane0_row_r;
    reg [15:0] write_req_lane1_row_r;

    reg [2:0] prefetch_state_r;
    reg [1:0] prefetch_pair_idx_r;
    reg [7:0] prefetch_lane_valid_r;
    reg signed [31:0] prefetch_raw_r [0:7];
    reg [15:0] prefetch_row_r [0:7];
    reg [31:0] prefetch_scale_word_index_r [0:7];
    reg [2:0] prefetch_scale_lane_r [0:7];
    reg [15:0] prefetch_act_scale_r [0:7];
    reg [15:0] prefetch_weight_scale_r [0:7];
    reg [15:0] prefetch_block_r;
    reg [15:0] prefetch_group_blocks_r;
    reg prefetch_last_block_r;
    reg prefetch_clear_accum_r;
    reg [31:0] prefetch_job_id_r;
    reg prefetch_bank_r;

    reg prefetch_req_valid_r;
    reg prefetch_req_lane0_valid_r;
    reg prefetch_req_lane1_valid_r;
    reg [2:0] prefetch_req_lane0_dest_r;
    reg [2:0] prefetch_req_lane1_dest_r;
    reg [31:0] prefetch_req_lane0_word_index_r;
    reg [31:0] prefetch_req_lane1_word_index_r;
    reg [2:0] prefetch_req_lane0_scale_lane_r;
    reg [2:0] prefetch_req_lane1_scale_lane_r;
    reg read_unused_prefetch_req_p3_r;
    reg read_unused_prefetch_req_scratch_valid_r;
    reg [31:0] read_unused_prefetch_req_scratch_index_r;
    reg [2:0] read_unused_prefetch_req_scratch_lane_r;
    reg prefetch_req_last_r;

    // Kept as registered fields so the structure remains friendly to the
    // existing Vivado hierarchy; P2 only needs the tag subset below.
    reg [AXI_DATA_WIDTH-1:0] prefetch_rsp_mem0_data_r;
    reg [AXI_DATA_WIDTH-1:0] prefetch_rsp_mem1_data_r;
    reg [AXI_DATA_WIDTH-1:0] prefetch_rsp_scratch_data_r;
    reg prefetch_rsp_valid_r;
    reg prefetch_rsp_lane0_valid_r;
    reg prefetch_rsp_lane1_valid_r;
    reg [2:0] prefetch_rsp_lane0_dest_r;
    reg [2:0] prefetch_rsp_lane1_dest_r;
    reg [2:0] prefetch_rsp_lane0_scale_lane_r;
    reg [2:0] prefetch_rsp_lane1_scale_lane_r;
    reg read_unused_prefetch_rsp_p3_r;
    reg read_unused_prefetch_rsp_scratch_valid_r;
    reg [2:0] read_unused_prefetch_rsp_scratch_lane_r;
    reg prefetch_rsp_last_r;

    // Per-lane P2 scale-word cache.  Tagging with job_id as well as the word
    // index prevents a later job that rewrites SPU_PARAM from consuming a word
    // retained by an earlier job.
    reg [7:0] p2_scale_cache_valid_r;
    reg [31:0] p2_scale_cache_job_r [0:7];
    reg [31:0] p2_scale_cache_word_index_r [0:7];
    reg [AXI_DATA_WIDTH-1:0] p2_scale_cache_word_r [0:7];

    // Match the P2 VPU retirement burst so one complete eight-result burst can
    // be absorbed while the scale accumulators continue draining older work.
    reg [3:0] fifo_count_r;
    reg [2:0] fifo_wr_ptr_r;
    reg [2:0] fifo_rd_ptr_r;
    reg [7:0] fifo_lane_valid [0:7];
    reg [8*32-1:0] fifo_lane_data [0:7];
    reg [8*16-1:0] fifo_lane_row [0:7];
    reg [8*32-1:0] fifo_scale_word_index [0:7];
    reg [8*3-1:0] fifo_scale_lane [0:7];
    reg [15:0] fifo_block [0:7];
    reg [15:0] fifo_group_blocks [0:7];
    reg fifo_last_block [0:7];
    reg fifo_clear_accum [0:7];
    reg [31:0] fifo_job_id [0:7];
    reg fifo_bank [0:7];
    reg fifo_p3 [0:7];

    wire [7:0] accum_busy;
    wire [7:0] accum_entry_done;
    wire [7:0] accum_out_valid;
    wire [8*16-1:0] accum_out_row_bus;
    wire [8*64-1:0] accum_out_q16_bus;
    wire [7:0] accum_error;
    wire [8*4-1:0] accum_error_code_bus;

    function [3:0] popcount8;
        input [7:0] v;
        integer k;
        begin
            popcount8 = 4'd0;
            for (k = 0; k < 8; k = k + 1)
                popcount8 = popcount8 + v[k];
        end
    endfunction

    function [2:0] highest_lane;
        input [7:0] v;
        integer k;
        begin
            highest_lane = 3'd0;
            for (k = 0; k < 8; k = k + 1)
                if (v[k]) highest_lane = k[2:0];
        end
    endfunction

    integer vi;
    reg bundle_index_ok;
    reg [31:0] idx_tmp;
    always @* begin
        bundle_index_ok = (vpu_lane_valid != 8'd0) &&
                          (vpu_group_blocks != 16'd0) &&
                          (vpu_block < vpu_group_blocks);
        for (vi = 0; vi < 8; vi = vi + 1) begin
            idx_tmp = vpu_lane_scale_index[32*vi +: 32];
            if (vpu_lane_valid[vi]) begin
                if (vpu_lane_row[16*vi +: 16] >= MAX_ROWS)
                    bundle_index_ok = 1'b0;
                if (!split_scale_enable && (idx_tmp >= P2_ENTRY_DEPTH))
                    bundle_index_ok = 1'b0;
                if (split_scale_enable && (idx_tmp >= P3_ENTRY_DEPTH))
                    bundle_index_ok = 1'b0;
            end
        end
        if (split_scale_enable &&
            ((WORD_DEPTH < 2) || ((WORD_DEPTH & 1) != 0) ||
             ((vpu_block >> 3) >= P3_BANK_WORD_DEPTH)))
            bundle_index_ok = 1'b0;
    end

    // Fast-path qualification is all-or-nothing for the FIFO head.  This keeps
    // the miss path exactly the old four-pair protocol and avoids mixing cached
    // and live BRAM data inside one x8 atomic bundle.
    integer ci;
    reg prefetch_scale_cache_hit;
    always @* begin
        // Cache qualification uses the registered prefetch payload.  This
        // removes the circular-FIFO read pointer and its wide metadata muxes
        // from the tag-compare and accumulator clock-enable path.
        prefetch_scale_cache_hit = (prefetch_lane_valid_r != 8'd0);
        for (ci = 0; ci < 8; ci = ci + 1) begin
            if (prefetch_lane_valid_r[ci] &&
                (!p2_scale_cache_valid_r[ci] ||
                 (p2_scale_cache_job_r[ci] != prefetch_job_id_r) ||
                 (p2_scale_cache_word_index_r[ci] !=
                  prefetch_scale_word_index_r[ci])))
                prefetch_scale_cache_hit = 1'b0;
        end
    end

    wire bank_mismatch = split_scale_enable && p3_bank_lock_valid &&
                         (vpu_bank != p3_bank_lock);
    wire fifo_empty = (fifo_count_r == 4'd0);
    wire fifo_full = (fifo_count_r == 4'd8);
    wire prefetch_empty = (prefetch_state_r == PF_IDLE);
    wire prefetch_ready = (prefetch_state_r == PF_READY);

    wire all_accum_idle = ((accum_busy & lane_valid_r) == 8'd0);
    wire all_accum_done = ((accum_entry_done | ~lane_valid_r) == 8'hff);
    wire any_accum_error = |(accum_error & lane_valid_r);

    // P2 can consume a completed look-ahead bundle directly into the eight
    // accumulator inputs.  The accumulator captures those prefetch registers
    // on this edge while the active metadata registers are updated in parallel.
    wire p2_prefetch_launch = !split_scale_enable && prefetch_ready &&
                              (((state_r == S_IDLE) && all_accum_idle) ||
                               ((state_r == S_WAIT) && all_accum_done &&
                                !last_block_r));
    wire prefetch_slot_open = prefetch_empty || p2_prefetch_launch;

    wire fifo_prefetch_pop = !split_scale_enable && prefetch_slot_open &&
                             !command_busy && !fifo_empty &&
                             ((state_r == S_IDLE) ||
                              ((state_r == S_WAIT) && !last_block_r) ||
                              ((state_r == S_WRITE) && (pair_idx_r == 2'd3)));
    wire fifo_pop = fifo_prefetch_pop;

    wire p2_fifo_ready = resetn && !command_busy && (!fifo_full || fifo_pop);
    wire p3_direct_ready = resetn && (state_r == S_IDLE) && !command_busy &&
                           !bank_mismatch;
    assign vpu_ready = split_scale_enable ? p3_direct_ready : p2_fifo_ready;
    wire vpu_fire = vpu_valid && vpu_ready;
    wire fifo_push = !split_scale_enable && vpu_fire && bundle_index_ok;
    wire [3:0] accepted_lanes = popcount8(vpu_lane_valid);
    wire [2:0] tail_lane = highest_lane(vpu_lane_valid);

    wire stream_engine_idle = split_scale_enable ?
                              (state_r == S_IDLE) :
                              ((state_r == S_IDLE) && fifo_empty && prefetch_empty);
    wire prefetch_mem_available = !split_scale_enable &&
                                  (state_r != S_READ) &&
                                  (state_r != S_CAPTURE) &&
                                  (state_r != S_RESPONSE) &&
                                  (state_r != S_WRITE);

    assign stream_status[0] = stream_engine_idle;
    assign stream_status[1] = stream_engine_idle;
    assign stream_status[2] = all_accum_idle;
    assign stream_status[3] = (state_r != S_WRITE);
    assign stream_status[4] = stream_engine_idle && all_accum_idle;
    assign stream_status[5] = p3_bank_lock_valid;
    assign stream_status[6] = p3_bank_lock;
    assign stream_status[31:7] = 25'd0;
    assign stream_p3_status = {24'd0,split_scale_enable,p3_done_seen_r,
                               p3_bank_lock,p3_bank_lock_valid,p3_r,
                               1'b0,stream_engine_idle,stream_engine_idle};

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : GEN_ACCUM8
            (* keep = "true" *) wire resetn_local;
            wire launch_prefetch_lane = p2_prefetch_launch &&
                                        prefetch_lane_valid_r[gi];
            // A stream soft reset aborts the complete transaction, including
            // arithmetic already accepted by a lane accumulator.  Resetting
            // only the FIFO/FSM clears lane_valid_r and can otherwise expose a
            // false-quiescent status while the accumulator is still busy.
            assign resetn_local = resetn && !soft_reset;
            SPU_Q8_Scale_Accum #(
                .ROW_ID_WIDTH(16), .MAX_ROWS(MAX_ROWS),
                .ACC_WIDTH(64), .FIXED_FRAC_BITS(16)
            ) u_accum (
                .clk(clk),
                .resetn(resetn_local),
                .start(accum_start_r[gi] || launch_prefetch_lane),
                .raw_in(p2_prefetch_launch ? prefetch_raw_r[gi] : raw_r[gi]),
                .act_scale_fp16(p2_prefetch_launch ? prefetch_act_scale_r[gi] : act_scale_r[gi]),
                .weight_scale_fp16(p2_prefetch_launch ? prefetch_weight_scale_r[gi] : weight_scale_r[gi]),
                .row_id(p2_prefetch_launch ? prefetch_row_r[gi] : row_r[gi]),
                .clear_accum(p2_prefetch_launch ? prefetch_clear_accum_r : clear_accum_r),
                .last_block(p2_prefetch_launch ? prefetch_last_block_r : last_block_r),
                .busy(accum_busy[gi]), .entry_done(accum_entry_done[gi]),
                .out_valid(accum_out_valid[gi]),
                .out_row_id(accum_out_row_bus[16*gi +: 16]),
                .out_accum_q16(accum_out_q16_bus[64*gi +: 64]),
                .error(accum_error[gi]),
                .error_code(accum_error_code_bus[4*gi +: 4])
            );
        end
    endgenerate

    integer i;
    integer fi;
    reg [3:0] write_count;
    always @(posedge clk) begin
        if (!resetn || soft_reset) begin
            state_r <= S_IDLE;
            pair_idx_r <= 2'd0;
            lane_valid_r <= 8'd0;
            block_r <= 16'd0; group_blocks_r <= 16'd0;
            last_block_r <= 1'b0; clear_accum_r <= 1'b0;
            job_id_r <= 32'd0; bank_r <= 1'b0; p3_r <= 1'b0;
            p3_done_seen_r <= 1'b0; p3_act_scale_r <= 16'd0;
            accum_start_r <= 8'd0;
            read_req_valid_r <= 1'b0;
            read_req_lane0_valid_r <= 1'b0; read_req_lane1_valid_r <= 1'b0;
            read_req_lane0_dest_r <= 3'd0; read_req_lane1_dest_r <= 3'd0;
            read_req_lane0_word_index_r <= 32'd0; read_req_lane1_word_index_r <= 32'd0;
            read_req_lane0_scale_lane_r <= 3'd0; read_req_lane1_scale_lane_r <= 3'd0;
            read_req_p3_r <= 1'b0; read_req_scratch_valid_r <= 1'b0;
            read_req_scratch_index_r <= 32'd0; read_req_scratch_lane_r <= 3'd0;
            read_rsp_mem0_data_r <= {AXI_DATA_WIDTH{1'b0}};
            read_rsp_mem1_data_r <= {AXI_DATA_WIDTH{1'b0}};
            read_rsp_scratch_data_r <= {AXI_DATA_WIDTH{1'b0}};
            read_rsp_valid_r <= 1'b0;
            read_rsp_lane0_valid_r <= 1'b0; read_rsp_lane1_valid_r <= 1'b0;
            read_rsp_lane0_dest_r <= 3'd0; read_rsp_lane1_dest_r <= 3'd0;
            read_rsp_lane0_scale_lane_r <= 3'd0; read_rsp_lane1_scale_lane_r <= 3'd0;
            read_rsp_p3_r <= 1'b0; read_rsp_scratch_valid_r <= 1'b0;
            read_rsp_scratch_lane_r <= 3'd0;
            write_req_valid_r <= 1'b0;
            write_req_lane0_valid_r <= 1'b0; write_req_lane1_valid_r <= 1'b0;
            write_req_lane0_dest_r <= 3'd0; write_req_lane1_dest_r <= 3'd0;
            write_req_lane0_row_r <= 16'd0; write_req_lane1_row_r <= 16'd0;
            p3_bank_lock_valid <= 1'b0; p3_bank_lock <= 1'b0;
            stream_count <= 32'd0; stream_done_count <= 32'd0;
            stream_drop_count <= 32'd0; stream_out_count <= 32'd0;
            stream_error_count <= 32'd0; stream_last_raw <= 32'd0;
            stream_last_meta <= 32'd0; stream_last_accum_lo <= 32'd0;
            stream_last_accum_hi <= 32'd0; stream_last_job <= 32'd0;
            stream_last_bank <= 32'd0; stream_fifo_high_water <= 32'd0;
            stream_raw_stall_cycles <= 32'd0;
            stream_entry_done_count <= 32'd0;
            stream_final_write_count <= 32'd0;
            stream_p3_reject_count <= 32'd0;
            fifo_count_r <= 4'd0; fifo_wr_ptr_r <= 3'd0; fifo_rd_ptr_r <= 3'd0;
            prefetch_state_r <= PF_IDLE; prefetch_pair_idx_r <= 2'd0;
            prefetch_lane_valid_r <= 8'd0;
            prefetch_block_r <= 16'd0; prefetch_group_blocks_r <= 16'd0;
            prefetch_last_block_r <= 1'b0; prefetch_clear_accum_r <= 1'b0;
            prefetch_job_id_r <= 32'd0; prefetch_bank_r <= 1'b0;
            prefetch_req_valid_r <= 1'b0;
            prefetch_req_lane0_valid_r <= 1'b0; prefetch_req_lane1_valid_r <= 1'b0;
            prefetch_req_lane0_dest_r <= 3'd0; prefetch_req_lane1_dest_r <= 3'd0;
            prefetch_req_lane0_word_index_r <= 32'd0;
            prefetch_req_lane1_word_index_r <= 32'd0;
            prefetch_req_lane0_scale_lane_r <= 3'd0;
            prefetch_req_lane1_scale_lane_r <= 3'd0;
            read_unused_prefetch_req_p3_r <= 1'b0;
            read_unused_prefetch_req_scratch_valid_r <= 1'b0;
            read_unused_prefetch_req_scratch_index_r <= 32'd0;
            read_unused_prefetch_req_scratch_lane_r <= 3'd0;
            prefetch_req_last_r <= 1'b0;
            prefetch_rsp_mem0_data_r <= {AXI_DATA_WIDTH{1'b0}};
            prefetch_rsp_mem1_data_r <= {AXI_DATA_WIDTH{1'b0}};
            prefetch_rsp_scratch_data_r <= {AXI_DATA_WIDTH{1'b0}};
            prefetch_rsp_valid_r <= 1'b0;
            prefetch_rsp_lane0_valid_r <= 1'b0; prefetch_rsp_lane1_valid_r <= 1'b0;
            prefetch_rsp_lane0_dest_r <= 3'd0; prefetch_rsp_lane1_dest_r <= 3'd0;
            prefetch_rsp_lane0_scale_lane_r <= 3'd0;
            prefetch_rsp_lane1_scale_lane_r <= 3'd0;
            read_unused_prefetch_rsp_p3_r <= 1'b0;
            read_unused_prefetch_rsp_scratch_valid_r <= 1'b0;
            read_unused_prefetch_rsp_scratch_lane_r <= 3'd0;
            prefetch_rsp_last_r <= 1'b0;
            p2_scale_cache_valid_r <= 8'd0;
            mem0_en <= 1'b0; mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
            mem0_index <= 32'd0; mem0_wdata <= {AXI_DATA_WIDTH{1'b0}};
            mem0_wstrb <= {(AXI_DATA_WIDTH/8){1'b0}};
            mem1_en <= 1'b0; mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
            mem1_index <= 32'd0; mem1_wdata <= {AXI_DATA_WIDTH{1'b0}};
            mem1_wstrb <= {(AXI_DATA_WIDTH/8){1'b0}};
            mem3_scratch_en <= 1'b0; mem3_scratch_index <= 32'd0;
            write_count <= 4'd0;
            for (i = 0; i < 8; i = i + 1) begin
                raw_r[i] <= 32'sd0; row_r[i] <= 16'd0;
                scale_word_index_r[i] <= 32'd0; scale_lane_r[i] <= 3'd0;
                act_scale_r[i] <= 16'd0; weight_scale_r[i] <= 16'd0;
                final_q16_r[i] <= 64'sd0;
                prefetch_raw_r[i] <= 32'sd0; prefetch_row_r[i] <= 16'd0;
                prefetch_scale_word_index_r[i] <= 32'd0;
                prefetch_scale_lane_r[i] <= 3'd0;
                prefetch_act_scale_r[i] <= 16'd0;
                prefetch_weight_scale_r[i] <= 16'd0;
                p2_scale_cache_job_r[i] <= 32'd0;
                p2_scale_cache_word_index_r[i] <= 32'd0;
                p2_scale_cache_word_r[i] <= {AXI_DATA_WIDTH{1'b0}};
            end
            for (fi = 0; fi < 8; fi = fi + 1) begin
                fifo_lane_valid[fi] <= 8'd0;
                fifo_lane_data[fi] <= {8*32{1'b0}};
                fifo_lane_row[fi] <= {8*16{1'b0}};
                fifo_scale_word_index[fi] <= {8*32{1'b0}};
                fifo_scale_lane[fi] <= {8*3{1'b0}};
                fifo_block[fi] <= 16'd0; fifo_group_blocks[fi] <= 16'd0;
                fifo_last_block[fi] <= 1'b0; fifo_clear_accum[fi] <= 1'b0;
                fifo_job_id[fi] <= 32'd0; fifo_bank[fi] <= 1'b0; fifo_p3[fi] <= 1'b0;
            end
        end else begin
            accum_start_r <= 8'd0;
            mem0_en <= 1'b0; mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
            mem0_index <= 32'd0; mem0_wdata <= {AXI_DATA_WIDTH{1'b0}};
            mem0_wstrb <= {(AXI_DATA_WIDTH/8){1'b0}};
            mem1_en <= 1'b0; mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
            mem1_index <= 32'd0; mem1_wdata <= {AXI_DATA_WIDTH{1'b0}};
            mem1_wstrb <= {(AXI_DATA_WIDTH/8){1'b0}};
            mem3_scratch_en <= 1'b0; mem3_scratch_index <= 32'd0;

            if (vpu_valid && !vpu_ready)
                stream_raw_stall_cycles <= stream_raw_stall_cycles + 32'd1;
            if (vpu_done) begin
                stream_done_count <= stream_done_count + 32'd1;
                if (p3_bank_lock_valid) p3_done_seen_r <= 1'b1;
            end

            if (vpu_fire && !bundle_index_ok) begin
                stream_drop_count <= stream_drop_count + accepted_lanes;
                stream_error_count <= stream_error_count + accepted_lanes;
                if (split_scale_enable)
                    stream_p3_reject_count <= stream_p3_reject_count + accepted_lanes;
            end else if (fifo_push) begin
                fifo_lane_valid[fifo_wr_ptr_r] <= vpu_lane_valid;
                fifo_lane_data[fifo_wr_ptr_r] <= vpu_lane_data;
                fifo_lane_row[fifo_wr_ptr_r] <= vpu_lane_row;
                for (i = 0; i < 8; i = i + 1) begin
                    fifo_scale_word_index[fifo_wr_ptr_r][32*i +: 32] <=
                        (vpu_lane_scale_index[32*i +: 32] >> 2);
                    fifo_scale_lane[fifo_wr_ptr_r][3*i +: 3] <=
                        {1'b0, vpu_lane_scale_index[32*i + 1 -: 2]};
                end
                fifo_block[fifo_wr_ptr_r] <= vpu_block;
                fifo_group_blocks[fifo_wr_ptr_r] <= vpu_group_blocks;
                fifo_last_block[fifo_wr_ptr_r] <= vpu_last_block;
                fifo_clear_accum[fifo_wr_ptr_r] <= vpu_clear_accum;
                fifo_job_id[fifo_wr_ptr_r] <= vpu_job_id;
                fifo_bank[fifo_wr_ptr_r] <= vpu_bank;
                fifo_p3[fifo_wr_ptr_r] <= 1'b0;
                fifo_wr_ptr_r <= fifo_wr_ptr_r + 3'd1;
                stream_count <= stream_count + accepted_lanes;
                stream_last_raw <= vpu_lane_data[32*tail_lane +: 32];
                stream_last_meta <= {vpu_clear_accum,vpu_last_block,
                                     vpu_block[13:0],vpu_lane_row[16*tail_lane +: 16]};
                stream_last_job <= vpu_job_id;
                stream_last_bank <= {31'd0,vpu_bank};
                if (!fifo_pop &&
                    (stream_fifo_high_water < {28'd0,(fifo_count_r + 4'd1)}))
                    stream_fifo_high_water <= {28'd0,(fifo_count_r + 4'd1)};
            end

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count_r <= fifo_count_r + 4'd1;
                2'b01: fifo_count_r <= fifo_count_r - 4'd1;
                default: fifo_count_r <= fifo_count_r;
            endcase
            if (fifo_pop)
                fifo_rd_ptr_r <= fifo_rd_ptr_r + 3'd1;

            // A pop may fill an empty prefetch slot or replace a slot that is
            // being launched this cycle. RHS values still refer to the old
            // prefetch bundle, so simultaneous launch/refill preserves FIFO order.
            if (fifo_prefetch_pop) begin
                prefetch_lane_valid_r <= fifo_lane_valid[fifo_rd_ptr_r];
                for (i = 0; i < 8; i = i + 1) begin
                    prefetch_raw_r[i] <= fifo_lane_data[fifo_rd_ptr_r][32*i +: 32];
                    prefetch_row_r[i] <= fifo_lane_row[fifo_rd_ptr_r][16*i +: 16];
                    prefetch_scale_word_index_r[i] <=
                        fifo_scale_word_index[fifo_rd_ptr_r][32*i +: 32];
                    prefetch_scale_lane_r[i] <= fifo_scale_lane[fifo_rd_ptr_r][3*i +: 3];
                end
                prefetch_block_r <= fifo_block[fifo_rd_ptr_r];
                prefetch_group_blocks_r <= fifo_group_blocks[fifo_rd_ptr_r];
                prefetch_last_block_r <= fifo_last_block[fifo_rd_ptr_r];
                prefetch_clear_accum_r <= fifo_clear_accum[fifo_rd_ptr_r];
                prefetch_job_id_r <= fifo_job_id[fifo_rd_ptr_r];
                prefetch_bank_r <= fifo_bank[fifo_rd_ptr_r];
                prefetch_pair_idx_r <= 2'd0;

                prefetch_req_valid_r <= 1'b0;
                prefetch_req_lane0_valid_r <= 1'b0;
                prefetch_req_lane1_valid_r <= 1'b0;
                prefetch_req_last_r <= 1'b0;
                prefetch_rsp_valid_r <= 1'b0;
                prefetch_rsp_lane0_valid_r <= 1'b0;
                prefetch_rsp_lane1_valid_r <= 1'b0;
                prefetch_rsp_last_r <= 1'b0;
                prefetch_state_r <= PF_CHECK;
            end

            if (!split_scale_enable) begin
                case (prefetch_state_r)
                    PF_CHECK: begin
                        if (prefetch_scale_cache_hit) begin
                            // Registered-word hit: select the requested scale
                            // entry without issuing a PARAM RAM command.
                            for (i = 0; i < 8; i = i + 1) begin
                                if (prefetch_lane_valid_r[i]) begin
                                    prefetch_act_scale_r[i] <=
                                        p2_scale_cache_word_r[i]
                                            [32*prefetch_scale_lane_r[i] +: 16];
                                    prefetch_weight_scale_r[i] <=
                                        p2_scale_cache_word_r[i]
                                            [32*prefetch_scale_lane_r[i]+16 +: 16];
                                end
                            end
                            prefetch_state_r <= PF_READY;
                        end else begin
                            // Cache miss: begin the retained registered
                            // two-port PARAM RAM prefetch sequence.
                            prefetch_req_valid_r <= 1'b1;
                            prefetch_req_lane0_valid_r <= prefetch_lane_valid_r[0];
                            prefetch_req_lane1_valid_r <= prefetch_lane_valid_r[1];
                            prefetch_req_lane0_dest_r <= 3'd0;
                            prefetch_req_lane1_dest_r <= 3'd1;
                            prefetch_req_lane0_word_index_r <= prefetch_scale_word_index_r[0];
                            prefetch_req_lane1_word_index_r <= prefetch_scale_word_index_r[1];
                            prefetch_req_lane0_scale_lane_r <= prefetch_scale_lane_r[0];
                            prefetch_req_lane1_scale_lane_r <= prefetch_scale_lane_r[1];
                            prefetch_req_last_r <= 1'b0;
                            mem0_en <= prefetch_lane_valid_r[0];
                            mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                            mem0_index <= prefetch_scale_word_index_r[0];
                            mem1_en <= prefetch_lane_valid_r[1];
                            mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                            mem1_index <= prefetch_scale_word_index_r[1];
                            prefetch_state_r <= PF_READ;
                        end
                    end

                    PF_READ: begin
                        if (prefetch_mem_available) begin
                            if (prefetch_rsp_valid_r && prefetch_rsp_lane0_valid_r) begin
                                prefetch_act_scale_r[prefetch_rsp_lane0_dest_r] <=
                                    mem0_rdata[32*prefetch_rsp_lane0_scale_lane_r +: 16];
                                prefetch_weight_scale_r[prefetch_rsp_lane0_dest_r] <=
                                    mem0_rdata[32*prefetch_rsp_lane0_scale_lane_r+16 +: 16];
                                p2_scale_cache_valid_r[prefetch_rsp_lane0_dest_r] <= 1'b1;
                                p2_scale_cache_job_r[prefetch_rsp_lane0_dest_r] <=
                                    prefetch_job_id_r;
                                p2_scale_cache_word_index_r[prefetch_rsp_lane0_dest_r] <=
                                    prefetch_scale_word_index_r[prefetch_rsp_lane0_dest_r];
                                p2_scale_cache_word_r[prefetch_rsp_lane0_dest_r] <= mem0_rdata;
                            end
                            if (prefetch_rsp_valid_r && prefetch_rsp_lane1_valid_r) begin
                                prefetch_act_scale_r[prefetch_rsp_lane1_dest_r] <=
                                    mem1_rdata[32*prefetch_rsp_lane1_scale_lane_r +: 16];
                                prefetch_weight_scale_r[prefetch_rsp_lane1_dest_r] <=
                                    mem1_rdata[32*prefetch_rsp_lane1_scale_lane_r+16 +: 16];
                                p2_scale_cache_valid_r[prefetch_rsp_lane1_dest_r] <= 1'b1;
                                p2_scale_cache_job_r[prefetch_rsp_lane1_dest_r] <=
                                    prefetch_job_id_r;
                                p2_scale_cache_word_index_r[prefetch_rsp_lane1_dest_r] <=
                                    prefetch_scale_word_index_r[prefetch_rsp_lane1_dest_r];
                                p2_scale_cache_word_r[prefetch_rsp_lane1_dest_r] <= mem1_rdata;
                            end

                            if (prefetch_rsp_valid_r && prefetch_rsp_last_r) begin
                                prefetch_req_valid_r <= 1'b0;
                                prefetch_req_lane0_valid_r <= 1'b0;
                                prefetch_req_lane1_valid_r <= 1'b0;
                                prefetch_req_last_r <= 1'b0;
                                prefetch_rsp_valid_r <= 1'b0;
                                prefetch_rsp_lane0_valid_r <= 1'b0;
                                prefetch_rsp_lane1_valid_r <= 1'b0;
                                prefetch_rsp_last_r <= 1'b0;
                                prefetch_pair_idx_r <= 2'd0;
                                prefetch_state_r <= PF_READY;
                            end else begin
                                prefetch_rsp_valid_r <= prefetch_req_valid_r;
                                prefetch_rsp_lane0_valid_r <= prefetch_req_lane0_valid_r;
                                prefetch_rsp_lane1_valid_r <= prefetch_req_lane1_valid_r;
                                prefetch_rsp_lane0_dest_r <= prefetch_req_lane0_dest_r;
                                prefetch_rsp_lane1_dest_r <= prefetch_req_lane1_dest_r;
                                prefetch_rsp_lane0_scale_lane_r <= prefetch_req_lane0_scale_lane_r;
                                prefetch_rsp_lane1_scale_lane_r <= prefetch_req_lane1_scale_lane_r;
                                prefetch_rsp_last_r <= prefetch_req_last_r;

                                if (prefetch_req_valid_r && !prefetch_req_last_r) begin
                                    prefetch_req_lane0_valid_r <=
                                        prefetch_lane_valid_r[{(prefetch_pair_idx_r + 2'd1),1'b0}];
                                    prefetch_req_lane1_valid_r <=
                                        prefetch_lane_valid_r[{(prefetch_pair_idx_r + 2'd1),1'b1}];
                                    prefetch_req_lane0_dest_r <=
                                        {(prefetch_pair_idx_r + 2'd1),1'b0};
                                    prefetch_req_lane1_dest_r <=
                                        {(prefetch_pair_idx_r + 2'd1),1'b1};
                                    prefetch_req_lane0_word_index_r <=
                                        prefetch_scale_word_index_r[{(prefetch_pair_idx_r + 2'd1),1'b0}];
                                    prefetch_req_lane1_word_index_r <=
                                        prefetch_scale_word_index_r[{(prefetch_pair_idx_r + 2'd1),1'b1}];
                                    prefetch_req_lane0_scale_lane_r <=
                                        prefetch_scale_lane_r[{(prefetch_pair_idx_r + 2'd1),1'b0}];
                                    prefetch_req_lane1_scale_lane_r <=
                                        prefetch_scale_lane_r[{(prefetch_pair_idx_r + 2'd1),1'b1}];
                                    prefetch_req_last_r <=
                                        ((prefetch_pair_idx_r + 2'd1) == 2'd3);
                                    mem0_en <=
                                        prefetch_lane_valid_r[{(prefetch_pair_idx_r + 2'd1),1'b0}];
                                    mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                                    mem0_index <=
                                        prefetch_scale_word_index_r[{(prefetch_pair_idx_r + 2'd1),1'b0}];
                                    mem1_en <=
                                        prefetch_lane_valid_r[{(prefetch_pair_idx_r + 2'd1),1'b1}];
                                    mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                                    mem1_index <=
                                        prefetch_scale_word_index_r[{(prefetch_pair_idx_r + 2'd1),1'b1}];
                                    prefetch_pair_idx_r <= prefetch_pair_idx_r + 2'd1;
                                end else begin
                                    prefetch_req_valid_r <= 1'b0;
                                    prefetch_req_lane0_valid_r <= 1'b0;
                                    prefetch_req_lane1_valid_r <= 1'b0;
                                    prefetch_req_last_r <= 1'b0;
                                end
                            end
                        end
                    end
                    default: begin end
                endcase
            end

            case (state_r)
                S_IDLE: begin
                    if (p3_done_seen_r && p3_bank_lock_valid) begin
                        p3_bank_lock_valid <= 1'b0;
                        p3_done_seen_r <= 1'b0;
                    end

                    if (split_scale_enable) begin
                        if (vpu_fire && bundle_index_ok) begin
                            lane_valid_r <= vpu_lane_valid;
                            for (i = 0; i < 8; i = i + 1) begin
                                raw_r[i] <= vpu_lane_data[32*i +: 32];
                                row_r[i] <= vpu_lane_row[16*i +: 16];
                                scale_word_index_r[i] <=
                                    ((vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                     (vpu_lane_scale_index[32*i +: 32] >> 3));
                                scale_lane_r[i] <= vpu_lane_scale_index[32*i + 2 -: 3];
                            end
                            block_r <= vpu_block;
                            group_blocks_r <= vpu_group_blocks;
                            last_block_r <= vpu_last_block;
                            clear_accum_r <= vpu_clear_accum;
                            job_id_r <= vpu_job_id;
                            bank_r <= vpu_bank;
                            p3_r <= 1'b1;
                            pair_idx_r <= 2'd0;
                            read_req_valid_r <= 1'b1;
                            read_req_lane0_valid_r <= vpu_lane_valid[0];
                            read_req_lane1_valid_r <= vpu_lane_valid[1];
                            read_req_lane0_dest_r <= 3'd0;
                            read_req_lane1_dest_r <= 3'd1;
                            read_req_lane0_word_index_r <=
                                (vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                (vpu_lane_scale_index[31:0] >> 3);
                            read_req_lane1_word_index_r <=
                                (vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                (vpu_lane_scale_index[63:32] >> 3);
                            read_req_lane0_scale_lane_r <= vpu_lane_scale_index[2:0];
                            read_req_lane1_scale_lane_r <= vpu_lane_scale_index[34:32];
                            read_req_p3_r <= 1'b1;
                            read_req_scratch_valid_r <= 1'b1;
                            read_req_scratch_index_r <=
                                (vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                ({16'd0,vpu_block} >> 3);
                            read_req_scratch_lane_r <= vpu_block[2:0];
                            mem0_en <= vpu_lane_valid[0];
                            mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                            mem0_index <=
                                (vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                (vpu_lane_scale_index[31:0] >> 3);
                            mem1_en <= vpu_lane_valid[1];
                            mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                            mem1_index <=
                                (vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                (vpu_lane_scale_index[63:32] >> 3);
                            mem3_scratch_en <= 1'b1;
                            mem3_scratch_index <=
                                (vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                ({16'd0,vpu_block} >> 3);
                            stream_count <= stream_count + accepted_lanes;
                            stream_fifo_high_water <= 32'd1;
                            stream_last_raw <= vpu_lane_data[32*tail_lane +: 32];
                            stream_last_meta <= {vpu_clear_accum,vpu_last_block,
                                                 vpu_block[13:0],vpu_lane_row[16*tail_lane +: 16]};
                            stream_last_job <= vpu_job_id;
                            stream_last_bank <= {31'd0,vpu_bank};
                            if (!p3_bank_lock_valid) begin
                                p3_bank_lock_valid <= 1'b1;
                                p3_bank_lock <= vpu_bank;
                            end
                            state_r <= S_READ;
                        end
                    end else if (p2_prefetch_launch) begin
                        lane_valid_r <= prefetch_lane_valid_r;
                        for (i = 0; i < 8; i = i + 1) begin
                            raw_r[i] <= prefetch_raw_r[i];
                            row_r[i] <= prefetch_row_r[i];
                            scale_word_index_r[i] <= prefetch_scale_word_index_r[i];
                            scale_lane_r[i] <= prefetch_scale_lane_r[i];
                            act_scale_r[i] <= prefetch_act_scale_r[i];
                            weight_scale_r[i] <= prefetch_weight_scale_r[i];
                        end
                        block_r <= prefetch_block_r;
                        group_blocks_r <= prefetch_group_blocks_r;
                        last_block_r <= prefetch_last_block_r;
                        clear_accum_r <= prefetch_clear_accum_r;
                        job_id_r <= prefetch_job_id_r;
                        bank_r <= prefetch_bank_r;
                        p3_r <= 1'b0;
                        pair_idx_r <= 2'd0;
                        if (!fifo_prefetch_pop)
                            prefetch_state_r <= PF_IDLE;
                        state_r <= S_WAIT;
                    end
                end

                S_READ: state_r <= S_CAPTURE;

                S_CAPTURE: begin
                    read_rsp_mem0_data_r <= mem0_rdata;
                    read_rsp_mem1_data_r <= mem1_rdata;
                    read_rsp_scratch_data_r <= mem3_scratch_rdata;
                    read_rsp_valid_r <= read_req_valid_r;
                    read_rsp_lane0_valid_r <= read_req_lane0_valid_r;
                    read_rsp_lane1_valid_r <= read_req_lane1_valid_r;
                    read_rsp_lane0_dest_r <= read_req_lane0_dest_r;
                    read_rsp_lane1_dest_r <= read_req_lane1_dest_r;
                    read_rsp_lane0_scale_lane_r <= read_req_lane0_scale_lane_r;
                    read_rsp_lane1_scale_lane_r <= read_req_lane1_scale_lane_r;
                    read_rsp_p3_r <= read_req_p3_r;
                    read_rsp_scratch_valid_r <= read_req_scratch_valid_r;
                    read_rsp_scratch_lane_r <= read_req_scratch_lane_r;
                    if (pair_idx_r != 2'd3) begin
                        read_req_valid_r <= 1'b1;
                        read_req_lane0_valid_r <=
                            lane_valid_r[{(pair_idx_r + 2'd1),1'b0}];
                        read_req_lane1_valid_r <=
                            lane_valid_r[{(pair_idx_r + 2'd1),1'b1}];
                        read_req_lane0_dest_r <= {(pair_idx_r + 2'd1),1'b0};
                        read_req_lane1_dest_r <= {(pair_idx_r + 2'd1),1'b1};
                        read_req_lane0_word_index_r <=
                            scale_word_index_r[{(pair_idx_r + 2'd1),1'b0}];
                        read_req_lane1_word_index_r <=
                            scale_word_index_r[{(pair_idx_r + 2'd1),1'b1}];
                        read_req_lane0_scale_lane_r <=
                            scale_lane_r[{(pair_idx_r + 2'd1),1'b0}];
                        read_req_lane1_scale_lane_r <=
                            scale_lane_r[{(pair_idx_r + 2'd1),1'b1}];
                        read_req_p3_r <= p3_r;
                        read_req_scratch_valid_r <= 1'b0;
                        read_req_scratch_index_r <= 32'd0;
                        read_req_scratch_lane_r <= 3'd0;
                    end
                    state_r <= S_RESPONSE;
                end

                S_RESPONSE: begin
                    if (read_rsp_valid_r && read_rsp_scratch_valid_r)
                        p3_act_scale_r <=
                            read_rsp_scratch_data_r[16*read_rsp_scratch_lane_r +: 16];
                    if (read_rsp_valid_r && read_rsp_lane0_valid_r) begin
                        if (read_rsp_p3_r) begin
                            weight_scale_r[read_rsp_lane0_dest_r] <=
                                read_rsp_mem0_data_r[16*read_rsp_lane0_scale_lane_r +: 16];
                            act_scale_r[read_rsp_lane0_dest_r] <= read_rsp_scratch_valid_r ?
                                read_rsp_scratch_data_r[16*read_rsp_scratch_lane_r +: 16] :
                                p3_act_scale_r;
                        end else begin
                            act_scale_r[read_rsp_lane0_dest_r] <=
                                read_rsp_mem0_data_r[32*read_rsp_lane0_scale_lane_r +: 16];
                            weight_scale_r[read_rsp_lane0_dest_r] <=
                                read_rsp_mem0_data_r[32*read_rsp_lane0_scale_lane_r+16 +: 16];
                        end
                    end
                    if (read_rsp_valid_r && read_rsp_lane1_valid_r) begin
                        if (read_rsp_p3_r) begin
                            weight_scale_r[read_rsp_lane1_dest_r] <=
                                read_rsp_mem1_data_r[16*read_rsp_lane1_scale_lane_r +: 16];
                            act_scale_r[read_rsp_lane1_dest_r] <= read_rsp_scratch_valid_r ?
                                read_rsp_scratch_data_r[16*read_rsp_scratch_lane_r +: 16] :
                                p3_act_scale_r;
                        end else begin
                            act_scale_r[read_rsp_lane1_dest_r] <=
                                read_rsp_mem1_data_r[32*read_rsp_lane1_scale_lane_r +: 16];
                            weight_scale_r[read_rsp_lane1_dest_r] <=
                                read_rsp_mem1_data_r[32*read_rsp_lane1_scale_lane_r+16 +: 16];
                        end
                    end
                    read_rsp_valid_r <= 1'b0;
                    read_rsp_lane0_valid_r <= 1'b0;
                    read_rsp_lane1_valid_r <= 1'b0;
                    read_rsp_p3_r <= 1'b0;
                    read_rsp_scratch_valid_r <= 1'b0;
                    read_rsp_scratch_lane_r <= 3'd0;
                    if (pair_idx_r == 2'd3) begin
                        pair_idx_r <= 2'd0;
                        read_req_valid_r <= 1'b0;
                        read_req_lane0_valid_r <= 1'b0;
                        read_req_lane1_valid_r <= 1'b0;
                        read_req_p3_r <= 1'b0;
                        read_req_scratch_valid_r <= 1'b0;
                        state_r <= S_START;
                    end else begin
                        mem0_en <= read_req_valid_r && read_req_lane0_valid_r;
                        mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                        mem0_index <= read_req_lane0_word_index_r;
                        mem1_en <= read_req_valid_r && read_req_lane1_valid_r;
                        mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                        mem1_index <= read_req_lane1_word_index_r;
                        mem3_scratch_en <= read_req_valid_r && read_req_scratch_valid_r;
                        mem3_scratch_index <= read_req_scratch_index_r;
                        pair_idx_r <= pair_idx_r + 2'd1;
                        state_r <= S_READ;
                    end
                end

                // S_START is now only needed by the retained P3 active-reader path.
                S_START: begin
                    if (all_accum_idle) begin
                        accum_start_r <= lane_valid_r;
                        state_r <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (all_accum_done) begin
                        stream_entry_done_count <= stream_entry_done_count + popcount8(lane_valid_r);
                        if (any_accum_error)
                            stream_error_count <= stream_error_count + popcount8(accum_error & lane_valid_r);
                        if (last_block_r) begin
                            for (i = 0; i < 8; i = i + 1)
                                if (lane_valid_r[i]) final_q16_r[i] <= accum_out_q16_bus[64*i +: 64];
                            pair_idx_r <= 2'd0;
                            write_req_valid_r <= 1'b1;
                            write_req_lane0_valid_r <= lane_valid_r[0];
                            write_req_lane1_valid_r <= lane_valid_r[1];
                            write_req_lane0_dest_r <= 3'd0;
                            write_req_lane1_dest_r <= 3'd1;
                            write_req_lane0_row_r <= row_r[0];
                            write_req_lane1_row_r <= row_r[1];
                            mem0_en <= lane_valid_r[0];
                            mem0_we <= lane_valid_r[0]; mem0_region <= REGION_OUT;
                            mem0_index <= {16'd0,row_r[0]};
                            mem0_wdata <= {{(AXI_DATA_WIDTH-80){1'b0}},
                                           accum_out_q16_bus[63:0],row_r[0]};
                            mem0_wstrb <= 16'h03ff;
                            mem1_en <= lane_valid_r[1];
                            mem1_we <= lane_valid_r[1]; mem1_region <= REGION_OUT;
                            mem1_index <= {16'd0,row_r[1]};
                            mem1_wdata <= {{(AXI_DATA_WIDTH-80){1'b0}},
                                           accum_out_q16_bus[127:64],row_r[1]};
                            mem1_wstrb <= 16'h03ff;
                            state_r <= S_WRITE;
                        end else if (p2_prefetch_launch) begin
                            lane_valid_r <= prefetch_lane_valid_r;
                            for (i = 0; i < 8; i = i + 1) begin
                                raw_r[i] <= prefetch_raw_r[i];
                                row_r[i] <= prefetch_row_r[i];
                                scale_word_index_r[i] <= prefetch_scale_word_index_r[i];
                                scale_lane_r[i] <= prefetch_scale_lane_r[i];
                                act_scale_r[i] <= prefetch_act_scale_r[i];
                                weight_scale_r[i] <= prefetch_weight_scale_r[i];
                            end
                            block_r <= prefetch_block_r;
                            group_blocks_r <= prefetch_group_blocks_r;
                            last_block_r <= prefetch_last_block_r;
                            clear_accum_r <= prefetch_clear_accum_r;
                            job_id_r <= prefetch_job_id_r;
                            bank_r <= prefetch_bank_r;
                            p3_r <= 1'b0;
                            pair_idx_r <= 2'd0;
                            if (!fifo_prefetch_pop)
                                prefetch_state_r <= PF_IDLE;
                            state_r <= S_WAIT;
                        end else begin
                            state_r <= S_IDLE;
                        end
                    end
                end

                S_WRITE: begin
                    write_count = write_req_valid_r ?
                                  ({3'd0,write_req_lane0_valid_r} +
                                   {3'd0,write_req_lane1_valid_r}) : 4'd0;
                    if (write_count != 0) begin
                        stream_out_count <= stream_out_count + write_count;
                        stream_final_write_count <= stream_final_write_count + write_count;
                        if (write_req_lane1_valid_r) begin
                            stream_last_accum_lo <= final_q16_r[write_req_lane1_dest_r][31:0];
                            stream_last_accum_hi <= final_q16_r[write_req_lane1_dest_r][63:32];
                        end else if (write_req_lane0_valid_r) begin
                            stream_last_accum_lo <= final_q16_r[write_req_lane0_dest_r][31:0];
                            stream_last_accum_hi <= final_q16_r[write_req_lane0_dest_r][63:32];
                        end
                    end
                    if (pair_idx_r == 2'd3) begin
                        pair_idx_r <= 2'd0;
                        write_req_valid_r <= 1'b0;
                        write_req_lane0_valid_r <= 1'b0;
                        write_req_lane1_valid_r <= 1'b0;
                        state_r <= S_IDLE;
                    end else begin
                        write_req_valid_r <= 1'b1;
                        write_req_lane0_valid_r <=
                            lane_valid_r[{(pair_idx_r + 2'd1),1'b0}];
                        write_req_lane1_valid_r <=
                            lane_valid_r[{(pair_idx_r + 2'd1),1'b1}];
                        write_req_lane0_dest_r <= {(pair_idx_r + 2'd1),1'b0};
                        write_req_lane1_dest_r <= {(pair_idx_r + 2'd1),1'b1};
                        write_req_lane0_row_r <= row_r[{(pair_idx_r + 2'd1),1'b0}];
                        write_req_lane1_row_r <= row_r[{(pair_idx_r + 2'd1),1'b1}];
                        mem0_en <= lane_valid_r[{(pair_idx_r + 2'd1),1'b0}];
                        mem0_we <= lane_valid_r[{(pair_idx_r + 2'd1),1'b0}];
                        mem0_region <= REGION_OUT;
                        mem0_index <= {16'd0,row_r[{(pair_idx_r + 2'd1),1'b0}]};
                        mem0_wdata <= {{(AXI_DATA_WIDTH-80){1'b0}},
                                       final_q16_r[{(pair_idx_r + 2'd1),1'b0}],
                                       row_r[{(pair_idx_r + 2'd1),1'b0}]};
                        mem0_wstrb <= 16'h03ff;
                        mem1_en <= lane_valid_r[{(pair_idx_r + 2'd1),1'b1}];
                        mem1_we <= lane_valid_r[{(pair_idx_r + 2'd1),1'b1}];
                        mem1_region <= REGION_OUT;
                        mem1_index <= {16'd0,row_r[{(pair_idx_r + 2'd1),1'b1}]};
                        mem1_wdata <= {{(AXI_DATA_WIDTH-80){1'b0}},
                                       final_q16_r[{(pair_idx_r + 2'd1),1'b1}],
                                       row_r[{(pair_idx_r + 2'd1),1'b1}]};
                        mem1_wstrb <= 16'h03ff;
                        pair_idx_r <= pair_idx_r + 2'd1;
                    end
                end

                default: state_r <= S_IDLE;
            endcase
        end
    end
endmodule
