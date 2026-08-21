/*
 * 8-lane VPU -> SPU Q8_0 scale/accumulate stream.
 * One accepted bundle carries up to eight row results for one Q8 block.
 * Scale RAM is read two rows/cycle through the existing two PARAM ports;
 * all valid rows then execute SPU_Q8_Scale_Accum in parallel.  On the P2
 * path, the next queued bundle is scale-prefetched while the current eight
 * accumulators are busy, hiding the existing four registered read/return pairs without
 * changing accumulation order or the external stream ABI.
 *
 * A four-entry input FIFO decouples the VPU result handshake from the SPU
 * scale/accumulate FSM.  Its depth matches the VPU raw burst scheduler's
 * maximum four-block issue burst while preserving the external stream ABI.
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

    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_READ    = 3'd1;
    localparam [2:0] S_CAPTURE = 3'd2;
    localparam [2:0] S_START   = 3'd3;
    localparam [2:0] S_WAIT    = 3'd4;
    localparam [2:0] S_WRITE   = 3'd5;
    localparam [2:0] S_RESPONSE = 3'd6;

    localparam [2:0] PF_IDLE     = 3'd0;
    localparam [2:0] PF_READ     = 3'd1;
    localparam [2:0] PF_CAPTURE  = 3'd2;
    localparam [2:0] PF_READY    = 3'd3;
    localparam [2:0] PF_RESPONSE = 3'd4;

    reg [2:0] state_r;
    reg [1:0] pair_idx_r;
    reg [7:0] lane_valid_r;
    reg signed [31:0] raw_r [0:7];
    reg [15:0] row_r [0:7];
    // Store decoded scale addresses in the FIFO and active bundle registers.
    // This keeps the variable shift / P3 bank addition away from the memory
    // control path while allowing the VPU handshake to run ahead of the FSM.
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

    // Register the complete PARAM/SCRATCH read command one cycle before it
    // reaches a memory port.  pair_idx_r advances bundle accounting, but it
    // does not select a live memory address or enable.
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

    // read_req_* is the registered request/command bundle.  The exported
    // mem0/mem1/mem3 signals are registered from it, and its tags are copied
    // into the response bundle at the RAM return boundary.

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

    // SPU_OUT commits use the same registered destination boundary.  This
    // leaves pair_idx_r as sequencing/accounting state only.
    reg write_req_valid_r;
    reg write_req_lane0_valid_r;
    reg write_req_lane1_valid_r;
    reg [2:0] write_req_lane0_dest_r;
    reg [2:0] write_req_lane1_dest_r;
    reg [15:0] write_req_lane0_row_r;
    reg [15:0] write_req_lane1_row_r;

    // One P2 look-ahead slot owns a bundle after it leaves the FIFO.  Raw
    // data/metadata and decoded scale addresses are copied immediately; the
    // four scale pairs are then fetched while the active accumulators run.
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

    // The prefetcher has the same registered read boundary as the active
    // reader so PF_READ never drives PARAM from prefetch_pair_idx_r.
    reg prefetch_req_valid_r;
    reg prefetch_req_lane0_valid_r;
    reg prefetch_req_lane1_valid_r;
    reg [2:0] prefetch_req_lane0_dest_r;
    reg [2:0] prefetch_req_lane1_dest_r;
    reg [31:0] prefetch_req_lane0_word_index_r;
    reg [31:0] prefetch_req_lane1_word_index_r;
    reg [2:0] prefetch_req_lane0_scale_lane_r;
    reg [2:0] prefetch_req_lane1_scale_lane_r;
    reg prefetch_req_p3_r;
    reg prefetch_req_scratch_valid_r;
    reg [31:0] prefetch_req_scratch_index_r;
    reg [2:0] prefetch_req_scratch_lane_r;

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
    reg prefetch_rsp_p3_r;
    reg prefetch_rsp_scratch_valid_r;
    reg [2:0] prefetch_rsp_scratch_lane_r;

    // Four-entry x8 bundle FIFO.  Wide buses are kept packed so this remains
    // plain Verilog-2001 compatible (one unpacked memory dimension only).
    reg [2:0] fifo_count_r;
    reg [1:0] fifo_wr_ptr_r;
    reg [1:0] fifo_rd_ptr_r;
    reg [7:0] fifo_lane_valid [0:3];
    reg [8*32-1:0] fifo_lane_data [0:3];
    reg [8*16-1:0] fifo_lane_row [0:3];
    reg [8*32-1:0] fifo_scale_word_index [0:3];
    reg [8*3-1:0] fifo_scale_lane [0:3];
    reg [15:0] fifo_block [0:3];
    reg [15:0] fifo_group_blocks [0:3];
    reg fifo_last_block [0:3];
    reg fifo_clear_accum [0:3];
    reg [31:0] fifo_job_id [0:3];
    reg fifo_bank [0:3];
    reg fifo_p3 [0:3];

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

    wire bank_mismatch = split_scale_enable && p3_bank_lock_valid &&
                         (vpu_bank != p3_bank_lock);
    wire fifo_empty = (fifo_count_r == 3'd0);
    wire fifo_full = (fifo_count_r == 3'd4);
    wire prefetch_empty = (prefetch_state_r == PF_IDLE);
    wire prefetch_ready = (prefetch_state_r == PF_READY);
    // The normal S_IDLE dequeue feeds the active bundle.  While a non-final
    // P2 block is accumulating, a second dequeue feeds the look-ahead slot.
    // Restrict prefetch to non-final blocks so SPU_OUT writes never contend
    // with the look-ahead PARAM reads.
    wire fifo_active_pop = !split_scale_enable && (state_r == S_IDLE) &&
                           prefetch_empty && !command_busy && !fifo_empty;
    wire fifo_prefetch_pop = !split_scale_enable && (state_r == S_WAIT) &&
                             !last_block_r && prefetch_empty &&
                             !command_busy && !fifo_empty;
    wire fifo_pop = fifo_active_pop || fifo_prefetch_pop;
    // Either dequeue may replace the head of a full FIFO in the same cycle.
    wire p2_fifo_ready = resetn && !command_busy && (!fifo_full || fifo_pop);
    wire p3_direct_ready = resetn && (state_r == S_IDLE) && !command_busy &&
                           !bank_mismatch;
    // P2 uses the four-entry FIFO plus one internal look-ahead slot. P3
    // deliberately keeps the original direct one-bundle handshake so the
    // existing bank-lock protocol is unchanged.
    assign vpu_ready = split_scale_enable ? p3_direct_ready : p2_fifo_ready;
    wire vpu_fire = vpu_valid && vpu_ready;
    wire fifo_push = !split_scale_enable && vpu_fire && bundle_index_ok;
    wire [3:0] accepted_lanes = popcount8(vpu_lane_valid);
    wire [2:0] tail_lane = highest_lane(vpu_lane_valid);

    wire all_accum_idle = ((accum_busy & lane_valid_r) == 8'd0);
    wire all_accum_done = ((accum_entry_done | ~lane_valid_r) == 8'hff);
    wire any_accum_error = |(accum_error & lane_valid_r);
    wire stream_engine_idle = split_scale_enable ?
                              (state_r == S_IDLE) :
                              ((state_r == S_IDLE) && fifo_empty && prefetch_empty);
    wire prefetch_mem_available = !split_scale_enable &&
                                  (state_r != S_READ) &&
                                  (state_r != S_CAPTURE) &&
                                  (state_r != S_RESPONSE) &&
                                  (state_r != S_WRITE);

    // mem0/mem1/mem3 commands are registered in the clocked FSM below.  The
    // response registers there form the tagged RAM return boundary.

    // Idle/ownership status includes queued bundles; otherwise the host could
    // observe S_IDLE during the one-cycle FIFO-to-FSM handoff and overwrite
    // PARAM/OUT before the queue has drained.
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
            // Keep an independent identity branch for each accumulator reset
            // load; reset polarity and the asynchronous assertion semantics of
            // SPU_Q8_Scale_Accum remain unchanged.
            (* keep = "true" *) wire resetn_local;
            assign resetn_local = resetn;
            SPU_Q8_Scale_Accum #(
                .ROW_ID_WIDTH(16), .MAX_ROWS(MAX_ROWS),
                .ACC_WIDTH(64), .FIXED_FRAC_BITS(16)
            ) u_accum (
                .clk(clk), .resetn(resetn_local), .start(accum_start_r[gi]),
                .raw_in(raw_r[gi]), .act_scale_fp16(act_scale_r[gi]),
                .weight_scale_fp16(weight_scale_r[gi]), .row_id(row_r[gi]),
                .clear_accum(clear_accum_r), .last_block(last_block_r),
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
            fifo_count_r <= 3'd0; fifo_wr_ptr_r <= 2'd0; fifo_rd_ptr_r <= 2'd0;
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
            prefetch_req_p3_r <= 1'b0; prefetch_req_scratch_valid_r <= 1'b0;
            prefetch_req_scratch_index_r <= 32'd0;
            prefetch_req_scratch_lane_r <= 3'd0;
            prefetch_rsp_mem0_data_r <= {AXI_DATA_WIDTH{1'b0}};
            prefetch_rsp_mem1_data_r <= {AXI_DATA_WIDTH{1'b0}};
            prefetch_rsp_scratch_data_r <= {AXI_DATA_WIDTH{1'b0}};
            prefetch_rsp_valid_r <= 1'b0;
            prefetch_rsp_lane0_valid_r <= 1'b0; prefetch_rsp_lane1_valid_r <= 1'b0;
            prefetch_rsp_lane0_dest_r <= 3'd0; prefetch_rsp_lane1_dest_r <= 3'd0;
            prefetch_rsp_lane0_scale_lane_r <= 3'd0;
            prefetch_rsp_lane1_scale_lane_r <= 3'd0;
            prefetch_rsp_p3_r <= 1'b0; prefetch_rsp_scratch_valid_r <= 1'b0;
            prefetch_rsp_scratch_lane_r <= 3'd0;
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
            end
            for (fi = 0; fi < 4; fi = fi + 1) begin
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
            // Commands are one-cycle registered ownership tokens.  Branches
            // below replace these defaults when a PARAM/SCRATCH read or an
            // SPU_OUT write is issued for the next memory clock.
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

            // Invalid input is consumed (as before) but counted as a
            // drop/error. Valid P2 bundles enter the decoupling FIFO; P3
            // keeps the original direct S_IDLE acceptance path below.
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
                fifo_wr_ptr_r <= fifo_wr_ptr_r + 2'd1;

                stream_count <= stream_count + accepted_lanes;
                stream_last_raw <= vpu_lane_data[32*tail_lane +: 32];
                stream_last_meta <= {vpu_clear_accum,vpu_last_block,
                                     vpu_block[13:0],vpu_lane_row[16*tail_lane +: 16]};
                stream_last_job <= vpu_job_id;
                stream_last_bank <= {31'd0,vpu_bank};

                if (!fifo_pop &&
                    (stream_fifo_high_water < {29'd0,(fifo_count_r + 3'd1)}))
                    stream_fifo_high_water <= {29'd0,(fifo_count_r + 3'd1)};
            end

            // Occupancy update handles simultaneous dequeue/enqueue.  The
            // input ready path deliberately accounts for fifo_pop, allowing a
            // full FIFO to replace its head and tail in one clock.
            case ({fifo_push, fifo_pop})
                2'b10: fifo_count_r <= fifo_count_r + 3'd1;
                2'b01: fifo_count_r <= fifo_count_r - 3'd1;
                default: fifo_count_r <= fifo_count_r;
            endcase
            if (fifo_pop)
                fifo_rd_ptr_r <= fifo_rd_ptr_r + 2'd1;

            // Pull the next non-final P2 bundle out of FIFO while the active
            // accumulators are busy.  It owns this look-ahead slot until all
            // four scale pairs have been captured.
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
                prefetch_req_valid_r <= 1'b1;
                prefetch_req_lane0_valid_r <= fifo_lane_valid[fifo_rd_ptr_r][0];
                prefetch_req_lane1_valid_r <= fifo_lane_valid[fifo_rd_ptr_r][1];
                prefetch_req_lane0_dest_r <= 3'd0;
                prefetch_req_lane1_dest_r <= 3'd1;
                prefetch_req_lane0_word_index_r <= fifo_scale_word_index[fifo_rd_ptr_r][31:0];
                prefetch_req_lane1_word_index_r <= fifo_scale_word_index[fifo_rd_ptr_r][63:32];
                prefetch_req_lane0_scale_lane_r <= fifo_scale_lane[fifo_rd_ptr_r][2:0];
                prefetch_req_lane1_scale_lane_r <= fifo_scale_lane[fifo_rd_ptr_r][5:3];
                prefetch_req_p3_r <= 1'b0;
                prefetch_req_scratch_valid_r <= 1'b0;
                prefetch_req_scratch_index_r <= 32'd0;
                prefetch_req_scratch_lane_r <= 3'd0;
                mem0_en <= fifo_lane_valid[fifo_rd_ptr_r][0];
                mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                mem0_index <= fifo_scale_word_index[fifo_rd_ptr_r][31:0];
                mem1_en <= fifo_lane_valid[fifo_rd_ptr_r][1];
                mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                mem1_index <= fifo_scale_word_index[fifo_rd_ptr_r][63:32];
                mem3_scratch_en <= 1'b0; mem3_scratch_index <= 32'd0;
                prefetch_state_r <= PF_READ;
            end

            // Look-ahead scale reader.  It uses PARAM ports only when the
            // active FSM is not reading/capturing/returning scales or writing
            // SPU_OUT.  PF_RESPONSE is an internal tagged-return phase; the
            // external FIFO and raw-stream cadence remain unchanged.
            if (!split_scale_enable) begin
                case (prefetch_state_r)
                    PF_READ: begin
                        if (prefetch_mem_available)
                            prefetch_state_r <= PF_CAPTURE;
                    end
                    PF_CAPTURE: begin
                        if (prefetch_mem_available) begin
                            prefetch_rsp_mem0_data_r <= mem0_rdata;
                            prefetch_rsp_mem1_data_r <= mem1_rdata;
                            prefetch_rsp_scratch_data_r <= mem3_scratch_rdata;
                            prefetch_rsp_valid_r <= prefetch_req_valid_r;
                            prefetch_rsp_lane0_valid_r <= prefetch_req_lane0_valid_r;
                            prefetch_rsp_lane1_valid_r <= prefetch_req_lane1_valid_r;
                            prefetch_rsp_lane0_dest_r <= prefetch_req_lane0_dest_r;
                            prefetch_rsp_lane1_dest_r <= prefetch_req_lane1_dest_r;
                            prefetch_rsp_lane0_scale_lane_r <= prefetch_req_lane0_scale_lane_r;
                            prefetch_rsp_lane1_scale_lane_r <= prefetch_req_lane1_scale_lane_r;
                            prefetch_rsp_p3_r <= prefetch_req_p3_r;
                            prefetch_rsp_scratch_valid_r <= prefetch_req_scratch_valid_r;
                            prefetch_rsp_scratch_lane_r <= prefetch_req_scratch_lane_r;
                            if (prefetch_pair_idx_r != 2'd3) begin
                                prefetch_req_valid_r <= 1'b1;
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
                                prefetch_req_p3_r <= 1'b0;
                                prefetch_req_scratch_valid_r <= 1'b0;
                                prefetch_req_scratch_index_r <= 32'd0;
                                prefetch_req_scratch_lane_r <= 3'd0;
                            end
                            prefetch_state_r <= PF_RESPONSE;
                        end
                    end
                    PF_RESPONSE: begin
                        if (prefetch_mem_available) begin
                            if (prefetch_rsp_valid_r && prefetch_rsp_lane0_valid_r) begin
                                if (prefetch_rsp_p3_r) begin
                                    prefetch_act_scale_r[prefetch_rsp_lane0_dest_r] <=
                                        prefetch_rsp_scratch_valid_r ?
                                        prefetch_rsp_scratch_data_r[16*prefetch_rsp_scratch_lane_r +: 16] : 16'd0;
                                    prefetch_weight_scale_r[prefetch_rsp_lane0_dest_r] <=
                                        prefetch_rsp_mem0_data_r[16*prefetch_rsp_lane0_scale_lane_r +: 16];
                                end else begin
                                    prefetch_act_scale_r[prefetch_rsp_lane0_dest_r] <=
                                        prefetch_rsp_mem0_data_r[32*prefetch_rsp_lane0_scale_lane_r +: 16];
                                    prefetch_weight_scale_r[prefetch_rsp_lane0_dest_r] <=
                                        prefetch_rsp_mem0_data_r[32*prefetch_rsp_lane0_scale_lane_r+16 +: 16];
                                end
                            end
                            if (prefetch_rsp_valid_r && prefetch_rsp_lane1_valid_r) begin
                                if (prefetch_rsp_p3_r) begin
                                    prefetch_act_scale_r[prefetch_rsp_lane1_dest_r] <=
                                        prefetch_rsp_scratch_valid_r ?
                                        prefetch_rsp_scratch_data_r[16*prefetch_rsp_scratch_lane_r +: 16] : 16'd0;
                                    prefetch_weight_scale_r[prefetch_rsp_lane1_dest_r] <=
                                        prefetch_rsp_mem1_data_r[16*prefetch_rsp_lane1_scale_lane_r +: 16];
                                end else begin
                                    prefetch_act_scale_r[prefetch_rsp_lane1_dest_r] <=
                                        prefetch_rsp_mem1_data_r[32*prefetch_rsp_lane1_scale_lane_r +: 16];
                                    prefetch_weight_scale_r[prefetch_rsp_lane1_dest_r] <=
                                        prefetch_rsp_mem1_data_r[32*prefetch_rsp_lane1_scale_lane_r+16 +: 16];
                                end
                            end
                            if (prefetch_pair_idx_r == 2'd3) begin
                                prefetch_pair_idx_r <= 2'd0;
                                prefetch_req_valid_r <= 1'b0;
                                prefetch_req_lane0_valid_r <= 1'b0;
                                prefetch_req_lane1_valid_r <= 1'b0;
                                prefetch_req_p3_r <= 1'b0;
                                prefetch_req_scratch_valid_r <= 1'b0;
                                prefetch_rsp_valid_r <= 1'b0;
                                prefetch_rsp_p3_r <= 1'b0;
                                prefetch_rsp_scratch_valid_r <= 1'b0;
                                prefetch_rsp_scratch_lane_r <= 3'd0;
                                prefetch_state_r <= PF_READY;
                            end else begin
                                mem0_en <= prefetch_req_valid_r && prefetch_req_lane0_valid_r;
                                mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                                mem0_index <= prefetch_req_lane0_word_index_r;
                                mem1_en <= prefetch_req_valid_r && prefetch_req_lane1_valid_r;
                                mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                                mem1_index <= prefetch_req_lane1_word_index_r;
                                mem3_scratch_en <= prefetch_req_valid_r && prefetch_req_scratch_valid_r;
                                mem3_scratch_index <= prefetch_req_scratch_index_r;
                                prefetch_pair_idx_r <= prefetch_pair_idx_r + 2'd1;
                                prefetch_state_r <= PF_READ;
                            end
                        end // PF_RESPONSE command issue complete
                    end // PF_RESPONSE ownership released
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
                        // Preserve the original P3 direct acceptance and bank
                        // locking behavior. No P3 token is buffered here.
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
                    end else if (prefetch_ready) begin
                        // Scales are already captured, so bypass the normal
                        // four READ/CAPTURE pairs and proceed directly to start.
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
                        prefetch_state_r <= PF_IDLE;
                        state_r <= S_START;
                    end else if (fifo_active_pop) begin
                        lane_valid_r <= fifo_lane_valid[fifo_rd_ptr_r];
                        for (i = 0; i < 8; i = i + 1) begin
                            raw_r[i] <= fifo_lane_data[fifo_rd_ptr_r][32*i +: 32];
                            row_r[i] <= fifo_lane_row[fifo_rd_ptr_r][16*i +: 16];
                            scale_word_index_r[i] <= fifo_scale_word_index[fifo_rd_ptr_r][32*i +: 32];
                            scale_lane_r[i] <= fifo_scale_lane[fifo_rd_ptr_r][3*i +: 3];
                        end
                        block_r <= fifo_block[fifo_rd_ptr_r];
                        group_blocks_r <= fifo_group_blocks[fifo_rd_ptr_r];
                        last_block_r <= fifo_last_block[fifo_rd_ptr_r];
                        clear_accum_r <= fifo_clear_accum[fifo_rd_ptr_r];
                        job_id_r <= fifo_job_id[fifo_rd_ptr_r];
                        bank_r <= fifo_bank[fifo_rd_ptr_r];
                        p3_r <= 1'b0;
                        pair_idx_r <= 2'd0;
                        read_req_valid_r <= 1'b1;
                        read_req_lane0_valid_r <= fifo_lane_valid[fifo_rd_ptr_r][0];
                        read_req_lane1_valid_r <= fifo_lane_valid[fifo_rd_ptr_r][1];
                        read_req_lane0_dest_r <= 3'd0;
                        read_req_lane1_dest_r <= 3'd1;
                        read_req_lane0_word_index_r <= fifo_scale_word_index[fifo_rd_ptr_r][31:0];
                        read_req_lane1_word_index_r <= fifo_scale_word_index[fifo_rd_ptr_r][63:32];
                        read_req_lane0_scale_lane_r <= fifo_scale_lane[fifo_rd_ptr_r][2:0];
                        read_req_lane1_scale_lane_r <= fifo_scale_lane[fifo_rd_ptr_r][5:3];
                        read_req_p3_r <= 1'b0;
                        read_req_scratch_valid_r <= 1'b0;
                        read_req_scratch_index_r <= 32'd0;
                        read_req_scratch_lane_r <= 3'd0;
                        mem0_en <= fifo_lane_valid[fifo_rd_ptr_r][0];
                        mem0_we <= 1'b0; mem0_region <= REGION_PARAM;
                        mem0_index <= fifo_scale_word_index[fifo_rd_ptr_r][31:0];
                        mem1_en <= fifo_lane_valid[fifo_rd_ptr_r][1];
                        mem1_we <= 1'b0; mem1_region <= REGION_PARAM;
                        mem1_index <= fifo_scale_word_index[fifo_rd_ptr_r][63:32];
                        mem3_scratch_en <= 1'b0; mem3_scratch_index <= 32'd0;
                        state_r <= S_READ;
                    end
                end

                S_READ: state_r <= S_CAPTURE;

                S_CAPTURE: begin
                    // Register the complete RAM return and its command tags.
                    // Dynamic lane extraction is deliberately deferred to
                    // S_RESPONSE, after this full-width boundary.
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
