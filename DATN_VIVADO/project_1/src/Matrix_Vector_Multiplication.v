/*
 *-----------------------------------------------------------------------------
 * Module      : Matrix_Vector_Multiplication
 * Description : GEMV scheduler, local-memory subsystem, and PMAU controller.
 *
 * Matrix_Vector_Multiplication is the compute core behind AXI4_Mapping.  It
 * owns the local Activation BRAM, banked and optionally sharded Weight BRAM,
 * Result BRAM, active runtime configuration latched from AXI4_Mapping, the
 * compute FSM, the synchronous BRAM read-alignment pipeline, and the PMAU_Full
 * instance.
 *
 * External memory-window behavior:
 * - REGION_ACT writes store activation beats indexed by col_beat.
 * - REGION_WEIGHT writes store pair-interleaved weight beats.  For every row
 *   pair and beat, the even-row word is followed by the odd-row word; an odd
 *   final row still supplies a zero companion word.  Bit 0 of the flat payload
 *   index selects the row-parity leaf and bits [14:1] select its 16K address.
 * - REGION_RESULT reads return packed INT8 result bytes for CPU/DMA readback.
 *   CPU/DMA writes to REGION_RESULT are not part of the normal compute flow;
 *   Result BRAM is written only after PMAU results have been accumulated and
 *   requantized inside PL.
 *
 * Compute behavior:
 * - ctrl_start snapshots cfg_rows, cfg_cols/cfg_col_beats, cfg_scale, and
 *   compute_mode, then S_VALIDATE rejects out-of-range or invalid packed-mode
 *   settings before any BRAM read is issued.
 * - S_RUN issues synchronous reads to Activation and Weight BRAM, delays valid
 *   and last metadata through the d/q/x pipeline, and presents aligned beats
 *   to PMAU_Full through valid/ready handshakes.
 * - S_WAIT_RESULT waits for PMAU result_valid after the final beat of a row,
 *   accumulates the INT32 raw result in the PL row accumulator, and writes the
 *   requantized INT8 byte only when compute_mode[3] requests final emission.
 * - S_DONE holds completion status for host polling, while S_ERROR holds
 *   invalid-configuration status until cleared or restarted.
 *
 * Default packed mode returns raw INT32 sums for each Q8 block so the current
 * host path can apply per-block Q8_0 scales.  INT8 result mode is only selected
 * when compute_mode[1] is set; across split K-group launches, compute_mode[2]
 * clears the on-chip row accumulator for the first group and compute_mode[3]
 * emits the final requantized INT8 result for the last group.  Sixteen INT8
 * results are packed into each 128-bit Result BRAM word.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module Matrix_Vector_Multiplication #(
    parameter NUM_LANES          = 16,
    parameter ACT_WIDTH          = 8,
    parameter WEIGHT_WIDTH       = 8,
    parameter ACC_WIDTH          = 32,
    parameter SCALE_WIDTH        = 16,
    parameter SCALE_FRAC_BITS    = 15,
    parameter RESULT_FIFO_DEPTH  = 8,
    parameter AXI_DATA_WIDTH     = 128,
    parameter MAX_ROWS           = 256,
    parameter MAX_COL_BEATS      = 128,
    parameter MAX_GROUP_Q8_BLOCKS = 64
) (
    input  wire                              CLK,
    input  wire                              RST,

    input  wire                              ctrl_start,
    input  wire                              ctrl_clear_done,
    input  wire [15:0]                       cfg_rows,
    input  wire [15:0]                       cfg_cols,
    input  wire [15:0]                       cfg_col_beats,
    input  wire [SCALE_WIDTH-1:0]            cfg_scale,
    // bit 4 is reserved for the P2-v2 retained two-row transport.  Keep the
    // full field here even while legacy PMAU controls consume bits [1:0].
    input  wire [4:0]                        compute_mode,
    input  wire                              cfg_wr_bank,
    input  wire                              cfg_rd_bank,
    input  wire [31:0]                       cfg_job_id,

    output wire                              busy,
    output wire                              done,
    output wire                              error,
    output wire [15:0]                       active_row,
    output wire [15:0]                       active_col_beat,
    output wire                              active_bank,
    output wire                              done_bank,
    output wire [31:0]                       active_job_id,
    output wire [31:0]                       done_job_id,
    output reg                               spu_raw_valid,
    input  wire                              spu_raw_ready,
    output reg  signed [31:0]                spu_raw_data,
    output reg  [15:0]                       spu_raw_row,
    output reg  [15:0]                       spu_raw_block,
    output reg  [15:0]                       spu_raw_group_blocks,
    output reg                               spu_raw_last_block,
    output reg                               spu_raw_clear_accum,
    output reg  [31:0]                       spu_raw_job_id,
    output reg                               spu_raw_bank,
    output reg                               spu_raw_done,
    // In P2-v2 this is the retained companion lane of spu_raw_*.  Both
    // lanes are accepted atomically through spu_raw_ready.
    output reg                               spu_raw_pair_valid,
    output reg  signed [31:0]                spu_raw_pair_data,
    output reg  [15:0]                       spu_raw_pair_row,
    output reg  [15:0]                       spu_raw_pair_block,
    output reg  [15:0]                       spu_raw_pair_group_blocks,
    output reg                               spu_raw_pair_last_block,
    output reg                               spu_raw_pair_clear_accum,
    output reg  [31:0]                       spu_raw_pair_job_id,
    output reg                               spu_raw_pair_bank,

    input  wire                              mm_wr_en,
    input  wire [1:0]                        mm_wr_region,
    input  wire [31:0]                       mm_wr_index,
    input  wire [AXI_DATA_WIDTH-1:0]         mm_wr_data,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     mm_wr_strb,

    input  wire                              mm_rd_en,
    input  wire [1:0]                        mm_rd_region,
    input  wire [31:0]                       mm_rd_index,
    output reg  [AXI_DATA_WIDTH-1:0]         mm_rd_data,
    output reg                               mm_rd_valid,
    output reg                               mm_rd_error
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

    localparam ACT_BEAT_WIDTH       = NUM_LANES * ACT_WIDTH;
    localparam WEIGHT_BEAT_WIDTH    = NUM_LANES * WEIGHT_WIDTH;
    localparam AXI_BYTE_COUNT       = AXI_DATA_WIDTH / 8;
    localparam BANK_COUNT           = 2;
    localparam ACT_BYTE_COUNT       = ACT_BEAT_WIDTH / 8;
    localparam WEIGHT_BANKS         = 4;
    localparam WEIGHT_BANK_WIDTH    = WEIGHT_BEAT_WIDTH / WEIGHT_BANKS;
    localparam WEIGHT_BANK_BYTES    = WEIGHT_BANK_WIDTH / 8;
    localparam RESULT_BYTE_COUNT    = ACC_WIDTH / 8;
    localparam ACT_ADDR_WIDTH       = clog2(MAX_COL_BEATS);
    localparam RESULT_PACK_LANES    = AXI_DATA_WIDTH / ACC_WIDTH;
    localparam RESULT_LANE_SHIFT    = clog2(RESULT_PACK_LANES);
    localparam RESULT_I8_PACK_LANES = AXI_DATA_WIDTH / 8;
    localparam RESULT_I8_LANE_SHIFT = clog2(RESULT_I8_PACK_LANES);
    localparam MAX_RESULT_VALUES    = MAX_ROWS * MAX_GROUP_Q8_BLOCKS;
    localparam RESULT_WORD_DEPTH    = (MAX_RESULT_VALUES + RESULT_PACK_LANES - 1) / RESULT_PACK_LANES;
    localparam RESULT_ADDR_WIDTH    = clog2(RESULT_WORD_DEPTH);
    localparam WEIGHT_DEPTH         = MAX_ROWS * MAX_COL_BEATS;
    localparam WEIGHT_ADDR_WIDTH    = clog2(WEIGHT_DEPTH);
    // Each 32-bit lane has one SDP UltraRAM leaf per row parity.  The external
    // payload remains 32K beats, but every leaf stores half of those beats at
    // a fixed 16K depth.  P2 reads its even/odd pair from different leaves.
    localparam WEIGHT_PARITY_LEAVES     = 2;
    localparam WEIGHT_LOCAL_ADDR_WIDTH  = clog2(WEIGHT_DEPTH / WEIGHT_PARITY_LEAVES);
    localparam WEIGHT_RAM_COUNT         = WEIGHT_BANKS * WEIGHT_PARITY_LEAVES;
    localparam WEIGHT_RAM_TOTAL        = BANK_COUNT * WEIGHT_RAM_COUNT;
    localparam LANE_SHIFT           = clog2(NUM_LANES);
    localparam [15:0] NUM_LANES_16          = NUM_LANES;
    localparam [15:0] MAX_ROWS_16           = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16      = MAX_COL_BEATS;
    localparam [15:0] Q8_BLOCK_BEATS_16     = 16'd2;
    localparam [SCALE_WIDTH-1:0] FP16_ONE    = 16'h3c00;
    localparam [31:0] MAX_ROWS_32           = MAX_ROWS;
    localparam [31:0] MAX_COL_BEATS_32      = MAX_COL_BEATS;
    localparam [31:0] WEIGHT_DEPTH_32       = WEIGHT_DEPTH;
    localparam [31:0] MAX_RESULT_VALUES_32  = MAX_RESULT_VALUES;
    localparam [31:0] RESULT_WORD_DEPTH_32  = RESULT_WORD_DEPTH;

    localparam [1:0] REGION_ACT     = 2'd0;
    localparam [1:0] REGION_WEIGHT  = 2'd1;
    localparam [1:0] REGION_RESULT  = 2'd2;

    localparam [3:0] S_IDLE         = 4'd0;
    localparam [3:0] S_RUN          = 4'd1;
    localparam [3:0] S_WAIT_RESULT  = 4'd2;
    localparam [3:0] S_DONE         = 4'd3;
    localparam [3:0] S_ERROR        = 4'd4;
    localparam [3:0] S_VALIDATE     = 4'd5;
    // Final-result handling is deliberately three stages: capture the INT32
    // accumulated value, requantize it to INT8, then commit Result BRAM.
    // This prevents the accumulator mux, saturation logic and BRAM routing
    // from forming one long routed path at 187.5 MHz.
    localparam [3:0] S_REQUANT_RESULT = 4'd6;
    localparam [3:0] S_DRAIN_RESULT   = 4'd7;
    localparam [3:0] S_ACCUM_WAIT     = 4'd8;
    localparam [3:0] S_ACCUM_ADD      = 4'd9;
    localparam [3:0] S_ACCUM_WRITE    = 4'd10;
    localparam [3:0] S_RAW_STREAM_HOLD = 4'd11;

    // The GEMV core has two independent traffic classes:
    // - memory-window traffic from AXI4_Mapping, used to fill Activation/Weight
    //   BRAMs and read Result BRAM;
    // - compute traffic generated by the FSM, used to read activation/weight
    //   beats and feed PMAU_Full.

    wire [ACT_BEAT_WIDTH-1:0]   act_compute_data;
    wire [ACT_BEAT_WIDTH*BANK_COUNT-1:0] act_compute_data_bank;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_pair_compute_data;
    wire [WEIGHT_BANK_WIDTH*WEIGHT_RAM_TOTAL-1:0] weight_compute_data_leaf;
    reg [ACT_BEAT_WIDTH-1:0]    act_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pair_pmau_data;
    wire [AXI_DATA_WIDTH-1:0]   result_cpu_rd_data;
    reg [ACT_ADDR_WIDTH-1:0]    act_compute_addr;
    reg                         compute_rd_en;
    (* keep = "true" *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_compute_addr_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg                         weight_compute_en_leaf [0:WEIGHT_RAM_TOTAL-1];
    reg                         mm_rd_pending_r;
    reg [1:0]                   mm_rd_region_d_r;
    reg                         mm_rd_error_d_r;
    reg                         rd_pipe_en_r;
    reg [1:0]                   rd_pipe_region_r;
    reg [31:0]                  rd_pipe_index_r;
    reg                         rd_pipe_bank_r;
    reg                         mm_rd_bank_d_r;

    // Local write pipeline.  AXI4_Mapping already registers its request, but
    // that register can be placed far from the banked weight BRAMs.  Capturing
    // the complete request again inside the GEMV hierarchy keeps address, data,
    // and byte enables aligned while cutting the long inter-module route.
    reg                         wr_pipe_en_r;
    reg [1:0]                   wr_pipe_region_r;
    reg [31:0]                  wr_pipe_index_r;
    reg                         wr_pipe_bank_r;
    (* keep = "true" *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_wr_addr_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg                         weight_wr_en_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg [WEIGHT_BANK_WIDTH-1:0] weight_wr_data_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg [WEIGHT_BANK_BYTES-1:0] weight_wr_strb_leaf [0:WEIGHT_RAM_TOTAL-1];
    reg [AXI_DATA_WIDTH-1:0]    wr_pipe_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] wr_pipe_strb_r;

    reg [3:0]  state_r;
    reg        done_r;
    reg        error_r;
    reg        active_bank_r;
    reg        done_bank_r;
    reg [31:0] active_job_id_r;
    reg [31:0] done_job_id_r;
    reg [15:0] active_rows_r;
    reg [15:0] active_col_beats_r;
    reg [15:0] row_idx_r;
    reg [15:0] read_beat_idx_r;
    reg [15:0] block_idx_r;
    reg [15:0] group_blocks_r;
    reg [31:0] result_row_base_r;
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_row_base_r;
    reg group_mode_r;
    reg result_i8_mode_r;
    reg result_accum_clear_r;
    reg result_emit_r;
    (* ram_style = "block" *)
    reg signed [ACC_WIDTH-1:0] result_accum_mem [0:MAX_ROWS-1];
    reg                         result_accum_rd_en_r;
    reg [15:0]                  result_accum_rd_addr_r;
    reg signed [ACC_WIDTH-1:0]  result_accum_rd_data_r;
    reg signed [ACC_WIDTH-1:0]  result_accum_pmau_r;
    reg signed [ACC_WIDTH-1:0]  result_accum_next_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_accum_result_addr_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_accum_result_lane_r;
    reg                         result_accum_emit_r;
    reg                         result_accum_final_row_r;

    // The accumulator/requantizer result is captured before it drives Result
    // BRAM.  This separates the variable-row accumulator mux from the BRAM
    // write data path and gives the physical implementation one full cycle to
    // place each side locally.
    reg result_write_pending_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_write_addr_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_write_lane_r;
    reg signed [7:0] result_write_i8_r;
    reg signed [ACC_WIDTH-1:0] result_write_i32_r;
    reg result_write_is_i8_r;
    reg result_pair_write_pending_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_pair_write_addr_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_pair_write_lane_r;
    reg signed [ACC_WIDTH-1:0] result_pair_write_i32_r;
    reg result_pair_write_issued_r;
    reg pair_mode_r;

    // The raw PL accumulator is captured before the saturating INT8
    // requantizer.  Besides shortening the routed critical path, this makes
    // the INT32-to-INT8 handoff explicit in the VPU/SPU boundary.
    reg result_requant_pending_r;
    reg signed [ACC_WIDTH-1:0] result_requant_value_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_requant_addr_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_requant_lane_r;
    reg result_requant_final_r;

    reg feed_valid_r;
    reg feed_last_r;
    reg feed_group_last_r;
    reg read_valid_d_r;
    reg read_last_d_r;
    reg read_group_last_d_r;
    reg read_req_valid_r;
    reg [ACT_ADDR_WIDTH-1:0] read_req_act_addr_r;
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] read_req_weight_addr_r;
    reg                               read_req_parity_r;
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] read_req_pair_weight_addr_r;
    reg                               read_req_pair_parity_r;
    reg read_req_last_r;
    reg read_req_group_last_r;
    reg read_valid_q_r;
    reg read_last_q_r;
    reg read_group_last_q_r;
    reg read_valid_x_r;
    reg read_last_x_r;
    reg read_group_last_x_r;
    // Row parity follows the same d/q/x memory-latency pipeline as valid.
    reg read_parity_d_r;
    reg read_parity_q_r;
    reg read_parity_x_r;
    reg read_pair_parity_d_r;
    reg read_pair_parity_q_r;
    reg read_pair_parity_x_r;

    wire [15:0] auto_col_beats =
        (cfg_cols + NUM_LANES_16 - 16'd1) >> LANE_SHIFT;
    wire [15:0] requested_col_beats =
        (cfg_col_beats != 16'd0) ? cfg_col_beats : auto_col_beats;
    wire        requested_group_mode = compute_mode[0];
    wire        requested_result_i8_mode = compute_mode[1];
    wire        requested_result_accum_clear = compute_mode[2];
    wire        requested_result_emit = compute_mode[3];
    wire        requested_pair_mode = compute_mode[4] && compute_mode[0] && !compute_mode[1];
    wire [15:0] requested_group_blocks =
        requested_group_mode ? (requested_col_beats >> 1) : 16'd1;
    wire active_group_invalid =
        group_mode_r &&
        ((active_col_beats_r[0] != 1'b0) ||
         (group_blocks_r == 16'd0) ||
         (group_blocks_r > MAX_GROUP_Q8_BLOCKS));
    wire active_config_invalid =
        (active_rows_r == 16'd0) ||
        (active_col_beats_r == 16'd0) ||
        (active_rows_r > MAX_ROWS_16) ||
        (active_col_beats_r > MAX_COL_BEATS_16) ||
        active_group_invalid;
    wire pair_lane1_valid = pair_mode_r && ((row_idx_r + 16'd1) < active_rows_r);
    // A paired active bank owns both weight-memory ports.  Active ACT writes
    // are blocked while compute is live, and active WEIGHT writes are rejected
    // visibly through error_r rather than being silently dropped.  The
    // inactive bank remains available for staging.
    wire pair_compute_ownership = pair_mode_r &&
        ((state_r == S_RUN) || (state_r == S_WAIT_RESULT) ||
         (state_r == S_RAW_STREAM_HOLD) || (state_r == S_DRAIN_RESULT)) &&
        (cfg_wr_bank == active_bank_r);
    wire pair_active_input_write_reject =
        mm_wr_en && pair_compute_ownership &&
        ((mm_wr_region == REGION_ACT) || (mm_wr_region == REGION_WEIGHT));
    wire pair_active_write_block = pair_compute_ownership &&
        ((mm_wr_region == REGION_ACT) || (mm_wr_region == REGION_WEIGHT));

    // Runtime configuration is latched on ctrl_start, then validated before
    // any BRAM read is issued.  Packed q8 mode groups every two 128-bit beats
    // into one partial-result block, so an odd beat count is rejected.

    wire pmau_activation_ready;
    wire pmau_weight_ready;
    wire pmau_input_ready;
    wire pmau_result_valid;
    wire [ACC_WIDTH-1:0] pmau_result_data;
    wire pmau_result_last;
    wire pmau2_activation_ready;
    wire pmau2_weight_ready;
    wire pmau2_input_ready;
    wire pmau2_result_valid;
    wire [ACC_WIDTH-1:0] pmau2_result_data;
    wire signed [7:0] pmau_result_i8;
    wire [4:0] result_requant_shift = cfg_scale[4:0];
    wire pmau_result_ready = ((state_r == S_RUN) || (state_r == S_WAIT_RESULT)) &&
                             (!pair_lane1_valid || pmau2_result_valid);
    wire pmau2_result_ready = ((state_r == S_RUN) || (state_r == S_WAIT_RESULT)) &&
                              pmau_result_valid;
    wire pair_issue_grant = !pair_lane1_valid ||
                            (pmau_input_ready && pmau2_input_ready);
    wire pmau_offer_valid = feed_valid_r && pair_issue_grant;
    wire pmau_input_fire =
        pmau_offer_valid && pmau_activation_ready && pmau_weight_ready &&
        (!pair_lane1_valid || (pmau2_activation_ready && pmau2_weight_ready));
    wire pmau_result_fire = pmau_result_valid && pmau_result_ready;
    wire wait_after_feed =
        result_i8_mode_r ? feed_group_last_r : feed_last_r;

    // BRAM output data is delayed relative to the address request.  The d/q/x
    // valid pipeline keeps activation data, selected weight shard data, and
    // sideband last flags aligned before a beat is presented to PMAU.
    wire feed_slot_open = (!feed_valid_r) || pmau_input_fire;
    wire consume_read_x = read_valid_x_r && feed_slot_open;
    wire read_x_slot_open = (!read_valid_x_r) || consume_read_x;
    wire shift_q_to_x = read_valid_q_r && read_x_slot_open;
    wire read_q_slot_open = (!read_valid_q_r) || shift_q_to_x;
    wire shift_d_to_q = read_valid_d_r && read_q_slot_open;
    wire read_d_slot_open = (!read_valid_d_r) || shift_d_to_q;
    wire shift_req_to_d = read_req_valid_r && read_d_slot_open;
    wire read_req_slot_open = (!read_req_valid_r) || shift_req_to_d;
    wire [15:0] read_abs_beat = read_beat_idx_r;
    // Physical address = (row >> 1) * active_col_beats + beat.  The running
    // base advances once per row pair, and parity chooses the matching SDP
    // leaf; no divider or variable-stride address logic is inferred.
    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] issue_weight_local_addr =
        weight_row_base_r + read_abs_beat[WEIGHT_LOCAL_ADDR_WIDTH-1:0];
    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] issue_pair_weight_local_addr =
        weight_row_base_r + read_abs_beat[WEIGHT_LOCAL_ADDR_WIDTH-1:0];
    wire issue_weight_parity = row_idx_r[0];
    wire issue_pair_weight_parity = ~row_idx_r[0];
    wire [15:0] raw_group_issue_limit =
        {block_idx_r[14:0], 1'b0} + Q8_BLOCK_BEATS_16;
    wire [15:0] issue_read_limit =
        (!result_i8_mode_r && group_mode_r) ? raw_group_issue_limit :
                                              active_col_beats_r;
    wire can_issue_read =
        (state_r == S_RUN) &&
        read_req_slot_open &&
        (read_beat_idx_r < issue_read_limit);
    wire issue_read_last =
        result_i8_mode_r ? (read_beat_idx_r == (active_col_beats_r - 16'd1)) :
        group_mode_r ? (read_beat_idx_r[0] == 1'b1) :
                       (read_beat_idx_r == (active_col_beats_r - 16'd1));
    wire issue_read_group_last =
        (read_beat_idx_r == (active_col_beats_r - 16'd1));

    wire [31:0] result_value_index =
        result_i8_mode_r ? {16'd0, row_idx_r} :
        group_mode_r ? (result_row_base_r + {16'd0, block_idx_r}) :
                       {16'd0, row_idx_r};
    wire [31:0] pair_result_value_index =
        result_row_base_r + {16'd0, group_blocks_r} + {16'd0, block_idx_r};
    wire [RESULT_ADDR_WIDTH-1:0] pair_result_wr_addr_i32 =
        pair_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] pair_result_wr_lane_i32 =
        pair_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] result_wr_addr_i32 =
        group_mode_r ? result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH] :
                       row_idx_r[RESULT_ADDR_WIDTH-1:0];
    wire [RESULT_LANE_SHIFT-1:0] result_wr_lane_i32 =
        group_mode_r ? result_value_index[RESULT_LANE_SHIFT-1:0] :
                       {RESULT_LANE_SHIFT{1'b0}};
    wire [RESULT_ADDR_WIDTH-1:0] result_wr_addr_i8 =
        result_value_index[RESULT_I8_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_I8_LANE_SHIFT-1:0] result_wr_lane_i8 =
        result_value_index[RESULT_I8_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] result_wr_addr =
        result_i8_mode_r ? result_wr_addr_i8 : result_wr_addr_i32;
    wire [RESULT_I8_LANE_SHIFT-1:0] result_wr_lane =
        result_i8_mode_r ? result_wr_lane_i8 :
                           {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},
                            result_wr_lane_i32};
    wire result_wr_index_ok =
        result_i8_mode_r ? (row_idx_r < MAX_ROWS_16) :
        group_mode_r ? (result_value_index < MAX_RESULT_VALUES_32) :
                       (row_idx_r < MAX_ROWS_16);
    wire result_requant_capture =
        result_i8_mode_r && result_emit_r;
    wire result_writeback_fire = result_write_pending_r;

    // Result placement has two explicit contracts:
    // - raw mode writes one INT32 value per row/block for host scale handling;
    // - INT8 mode accumulates raw groups on chip and writes one saturated byte
    //   per row only when compute_mode[3] requests final emission.

    assign busy            = (state_r == S_RUN) ||
                             (state_r == S_WAIT_RESULT) ||
                             (state_r == S_ACCUM_WAIT) ||
                             (state_r == S_ACCUM_ADD) ||
                             (state_r == S_ACCUM_WRITE) ||
                             (state_r == S_REQUANT_RESULT) ||
                             (state_r == S_DRAIN_RESULT) ||
                             (state_r == S_RAW_STREAM_HOLD);
    assign done            = done_r;
    assign error           = error_r;
    assign active_row      = row_idx_r;
    assign active_col_beat = read_abs_beat;
    assign active_bank     = active_bank_r;
    assign done_bank       = done_bank_r;
    assign active_job_id   = active_job_id_r;
    assign done_job_id     = done_job_id_r;

    PMAU_Full #(
        .NUM_LANES         (NUM_LANES),
        .ACT_WIDTH         (ACT_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH),
        .ACC_WIDTH         (ACC_WIDTH),
        .SCALE_WIDTH       (SCALE_WIDTH),
        .SCALE_FRAC_BITS   (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH (RESULT_FIFO_DEPTH)
    ) u_pmau (
        .CLK               (CLK),
        .RST               (RST),
        .compute_mode      (compute_mode[1:0]),
        .activation_data   (act_pmau_data),
        .activation_valid  ((state_r == S_RUN) && pmau_offer_valid),
        .activation_ready  (pmau_activation_ready),
        .input_ready       (pmau_input_ready),
        .activation_last   (feed_last_r),
        .weight_data       (weight_pmau_data),
        .scale_factor      (result_i8_mode_r ? FP16_ONE : cfg_scale),
        .weight_valid      ((state_r == S_RUN) && pmau_offer_valid),
        .weight_ready      (pmau_weight_ready),
        .weight_last       (feed_last_r),
        .scalar_axpy       (16'd0),
        .result_data       (pmau_result_data),
        .result_valid      (pmau_result_valid),
        .result_ready      (pmau_result_ready),
        .result_last       (pmau_result_last)
    );

    PMAU_Full #(
        .NUM_LANES         (NUM_LANES), .ACT_WIDTH (ACT_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH), .ACC_WIDTH (ACC_WIDTH),
        .SCALE_WIDTH       (SCALE_WIDTH), .SCALE_FRAC_BITS (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH (RESULT_FIFO_DEPTH)
    ) u_pmau_pair (
        .CLK               (CLK), .RST (RST), .compute_mode (compute_mode[1:0]),
        .activation_data   (act_pmau_data),
        .activation_valid  ((state_r == S_RUN) && pmau_offer_valid && pair_lane1_valid),
        .activation_ready  (pmau2_activation_ready), .input_ready (pmau2_input_ready), .activation_last (feed_last_r),
        .weight_data       (weight_pair_pmau_data), .scale_factor (cfg_scale),
        .weight_valid      ((state_r == S_RUN) && pmau_offer_valid && pair_lane1_valid),
        .weight_ready      (pmau2_weight_ready), .weight_last (feed_last_r),
        .scalar_axpy       (16'd0), .result_data (pmau2_result_data),
        .result_valid      (pmau2_result_valid), .result_ready (pmau2_result_ready),
        .result_last       ()
    );

    VPU_Result_Requantizer #(
        .ACC_WIDTH   (ACC_WIDTH),
        .SHIFT_WIDTH (5)
    ) u_result_requantizer (
        .value_in       (result_requant_value_r),
        .requant_shift  (result_requant_shift),
        .value_out      (pmau_result_i8)
    );

    // Flat payload index is pair-interleaved: low bit chooses even/odd leaf,
    // remaining bits are the physical 16K-word leaf address.
    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] wr_pipe_weight_local_addr =
        wr_pipe_index_r[WEIGHT_LOCAL_ADDR_WIDTH:1];
    wire wr_pipe_weight_parity = wr_pipe_index_r[0];

    integer wr_bank_i;
    integer wr_ram_i;
    integer fsm_bank_i;
    integer fsm_ram_i;
    integer accum_i;
    integer mux_bank_i;
    always @(posedge CLK) begin
        if (!RST) begin
            wr_pipe_en_r     <= 1'b0;
            wr_pipe_region_r <= REGION_ACT;
            wr_pipe_index_r  <= 32'd0;
            wr_pipe_bank_r   <= 1'b0;
            wr_pipe_data_r   <= {AXI_DATA_WIDTH{1'b0}};
            wr_pipe_strb_r   <= {(AXI_DATA_WIDTH/8){1'b0}};
            for (wr_ram_i = 0; wr_ram_i < WEIGHT_RAM_TOTAL; wr_ram_i = wr_ram_i + 1) begin
                weight_wr_addr_leaf[wr_ram_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                weight_wr_en_leaf[wr_ram_i]   <= 1'b0;
                weight_wr_data_leaf[wr_ram_i] <= {WEIGHT_BANK_WIDTH{1'b0}};
                weight_wr_strb_leaf[wr_ram_i] <= {WEIGHT_BANK_BYTES{1'b0}};
            end
        end else begin
            // Capture memory-window writes from AXI4_Mapping.  Activation is a
            // direct 128-bit BRAM word path, while Weight memory is split into
            // four 32-bit banks and two fixed row-parity leaves.  Result BRAM is
            // written only by the PMAU result path below.
            wr_pipe_en_r <= mm_wr_en && !pair_active_write_block;
            if (mm_wr_en && !pair_active_write_block) begin
                wr_pipe_region_r <= mm_wr_region;
                wr_pipe_index_r  <= mm_wr_index;
                wr_pipe_bank_r   <= cfg_wr_bank;
                wr_pipe_data_r   <= mm_wr_data;
                wr_pipe_strb_r   <= mm_wr_strb;
            end

            for (wr_ram_i = 0; wr_ram_i < WEIGHT_RAM_TOTAL; wr_ram_i = wr_ram_i + 1)
                weight_wr_en_leaf[wr_ram_i] <= 1'b0;

            for (wr_bank_i = 0; wr_bank_i < WEIGHT_BANKS; wr_bank_i = wr_bank_i + 1) begin
                if (wr_pipe_en_r && (wr_pipe_region_r == REGION_WEIGHT)) begin
                    weight_wr_addr_leaf[wr_pipe_bank_r*WEIGHT_RAM_COUNT +
                                        wr_bank_i*WEIGHT_PARITY_LEAVES + wr_pipe_weight_parity]
                        <= wr_pipe_weight_local_addr;
                    weight_wr_en_leaf[wr_pipe_bank_r*WEIGHT_RAM_COUNT +
                                      wr_bank_i*WEIGHT_PARITY_LEAVES + wr_pipe_weight_parity]
                        <= 1'b1;
                    weight_wr_data_leaf[wr_pipe_bank_r*WEIGHT_RAM_COUNT +
                                        wr_bank_i*WEIGHT_PARITY_LEAVES + wr_pipe_weight_parity]
                        <= wr_pipe_data_r[WEIGHT_BANK_WIDTH*wr_bank_i +: WEIGHT_BANK_WIDTH];
                    weight_wr_strb_leaf[wr_pipe_bank_r*WEIGHT_RAM_COUNT +
                                        wr_bank_i*WEIGHT_PARITY_LEAVES + wr_pipe_weight_parity]
                        <= wr_pipe_strb_r[WEIGHT_BANK_BYTES*wr_bank_i +: WEIGHT_BANK_BYTES];
                end
            end
        end
    end

    always @(posedge CLK) begin
        if (!RST) begin
            rd_pipe_en_r     <= 1'b0;
            rd_pipe_region_r <= REGION_RESULT;
            rd_pipe_index_r  <= 32'd0;
            rd_pipe_bank_r   <= 1'b0;
        end else begin
            // Delay the read request metadata so the Result BRAM data and the
            // region/error information are returned to AXI4_Mapping together.
            rd_pipe_en_r <= mm_rd_en;
            if (mm_rd_en) begin
                rd_pipe_region_r <= mm_rd_region;
                rd_pipe_index_r  <= mm_rd_index;
                rd_pipe_bank_r   <= cfg_rd_bank;
            end
        end
    end

    wire mm_rd_accept = rd_pipe_en_r;
    wire act_wr_hit =
        wr_pipe_en_r && (wr_pipe_region_r == REGION_ACT);
    wire act_rd_hit = 1'b0;
    wire weight_rd_hit = 1'b0;
    wire result_rd_hit =
        mm_rd_accept && (rd_pipe_region_r == REGION_RESULT) &&
        (rd_pipe_index_r < RESULT_WORD_DEPTH_32);
    wire rd_region_known =
        (rd_pipe_region_r == REGION_ACT) ||
        (rd_pipe_region_r == REGION_WEIGHT) ||
        (rd_pipe_region_r == REGION_RESULT);
    wire rd_index_ok = result_rd_hit;

    wire [ACT_BYTE_COUNT-1:0]    act_wr_strobe =
        wr_pipe_strb_r[ACT_BYTE_COUNT-1:0];
    reg [AXI_DATA_WIDTH-1:0] result_wr_data;
    reg [(AXI_DATA_WIDTH/8)-1:0] result_wr_strobe;
    reg [AXI_DATA_WIDTH-1:0] result_pair_wr_data;
    reg [(AXI_DATA_WIDTH/8)-1:0] result_pair_wr_strobe;
    integer result_lane_i;
    always @* begin
        result_wr_data   = {AXI_DATA_WIDTH{1'b0}};
        result_wr_strobe = {(AXI_DATA_WIDTH/8){1'b0}};
        result_pair_wr_data = {AXI_DATA_WIDTH{1'b0}};
        result_pair_wr_strobe = {(AXI_DATA_WIDTH/8){1'b0}};
        if (result_writeback_fire) begin
            if (result_write_is_i8_r) begin
                // Final-result mode: PL returns one signed INT8 value per row.
                // Sixteen values share one 128-bit Result BRAM word.
                result_wr_data[8*result_write_lane_r +: 8] = result_write_i8_r;
                result_wr_strobe[result_write_lane_r] = 1'b1;
            end else begin
                // Raw packed mode: PL returns one INT32 dot-product per
                // row/block. Four values share one 128-bit Result BRAM word.
                result_wr_data[ACC_WIDTH*result_write_lane_r[RESULT_LANE_SHIFT-1:0] +: ACC_WIDTH] =
                    result_write_i32_r;
                result_wr_strobe[RESULT_BYTE_COUNT*result_write_lane_r[RESULT_LANE_SHIFT-1:0] +: RESULT_BYTE_COUNT] =
                    {RESULT_BYTE_COUNT{1'b1}};
            end
        end
        if (result_pair_write_pending_r) begin
            result_pair_wr_data[ACC_WIDTH*result_pair_write_lane_r[RESULT_LANE_SHIFT-1:0] +: ACC_WIDTH] =
                result_pair_write_i32_r;
            result_pair_wr_strobe[RESULT_BYTE_COUNT*result_pair_write_lane_r[RESULT_LANE_SHIFT-1:0] +: RESULT_BYTE_COUNT] =
                {RESULT_BYTE_COUNT{1'b1}};
        end
    end

    wire [ACT_BEAT_WIDTH*BANK_COUNT-1:0] act_cpu_rd_unused_bank;
    wire [WEIGHT_BANK_WIDTH*WEIGHT_RAM_TOTAL-1:0] weight_cpu_rd_unused;
    wire [AXI_DATA_WIDTH*BANK_COUNT-1:0] result_cpu_rd_data_bank;
    wire [AXI_DATA_WIDTH*BANK_COUNT-1:0] result_compute_rd_unused_bank;

    assign act_compute_data =
        act_compute_data_bank[ACT_BEAT_WIDTH*active_bank_r +: ACT_BEAT_WIDTH];

    genvar act_bank_g;
    generate
        for (act_bank_g = 0; act_bank_g < BANK_COUNT; act_bank_g = act_bank_g + 1) begin : GEN_ACT_BANK
            Dual_Port_BRAM #(
                .AWIDTH (ACT_ADDR_WIDTH),
                .DWIDTH (ACT_BEAT_WIDTH),
                .OUTPUT_REG (1),
                .USE_URAM (0)
            ) u_act_bram (
                .clka  (CLK),
                .ena   (act_wr_hit && (wr_pipe_bank_r == act_bank_g)),
                .wea   (act_wr_strobe),
                .addra (wr_pipe_index_r[ACT_ADDR_WIDTH-1:0]),
                .dina  (wr_pipe_data_r[ACT_BEAT_WIDTH-1:0]),
                .douta (act_cpu_rd_unused_bank[ACT_BEAT_WIDTH*act_bank_g +: ACT_BEAT_WIDTH]),
                .clkb  (CLK),
                .enb   (compute_rd_en && (active_bank_r == act_bank_g)),
                .web   ({ACT_BYTE_COUNT{1'b0}}),
                .addrb (act_compute_addr),
                .dinb  ({ACT_BEAT_WIDTH{1'b0}}),
                .doutb (act_compute_data_bank[ACT_BEAT_WIDTH*act_bank_g +: ACT_BEAT_WIDTH])
            );
        end
    endgenerate

    // Four 32-bit lane banks preserve the packed-Q8 interface.  Each bank has
    // separate 16K SDP URAM leaves for even and odd rows, allowing both P2 rows
    // to read concurrently without a true-dual-port memory primitive.
    genvar weight_top_bank_g;
    genvar weight_bank_g;
    genvar weight_parity_g;
    generate
        for (weight_top_bank_g = 0; weight_top_bank_g < BANK_COUNT;
             weight_top_bank_g = weight_top_bank_g + 1) begin : GEN_WEIGHT_TOP_BANK
            for (weight_bank_g = 0; weight_bank_g < WEIGHT_BANKS;
                 weight_bank_g = weight_bank_g + 1) begin : GEN_WEIGHT_BANK
                for (weight_parity_g = 0; weight_parity_g < WEIGHT_PARITY_LEAVES;
                     weight_parity_g = weight_parity_g + 1) begin : GEN_WEIGHT_PARITY
                    localparam integer WEIGHT_RAM_INDEX =
                        weight_top_bank_g * WEIGHT_RAM_COUNT +
                        weight_bank_g * WEIGHT_PARITY_LEAVES + weight_parity_g;
                    Dual_Port_BRAM #(
                        .AWIDTH (WEIGHT_LOCAL_ADDR_WIDTH),
                        .DWIDTH (WEIGHT_BANK_WIDTH),
                        .OUTPUT_REG (1),
                        .USE_URAM (1)
                    ) u_weight_bram_bank (
                        .clka  (CLK),
                        // A is the only staging-write port.  B is the only
                        // compute-read port for all modes; paired rows select
                        // distinct parity leaves and therefore never contend.
                        .ena   (weight_wr_en_leaf[WEIGHT_RAM_INDEX]),
                        .wea   (weight_wr_strb_leaf[WEIGHT_RAM_INDEX]),
                        .addra (weight_wr_addr_leaf[WEIGHT_RAM_INDEX]),
                        .dina  (weight_wr_data_leaf[WEIGHT_RAM_INDEX]),
                        .douta (),
                        .clkb  (CLK),
                        .enb   (weight_compute_en_leaf[WEIGHT_RAM_INDEX]),
                        .web   ({WEIGHT_BANK_BYTES{1'b0}}),
                        .addrb (weight_compute_addr_leaf[WEIGHT_RAM_INDEX]),
                        .dinb  ({WEIGHT_BANK_WIDTH{1'b0}}),
                        .doutb (weight_compute_data_leaf[WEIGHT_BANK_WIDTH*WEIGHT_RAM_INDEX +: WEIGHT_BANK_WIDTH])
                    );
                end
            end
        end
    endgenerate

    always @* begin
        weight_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        weight_pair_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        for (mux_bank_i = 0; mux_bank_i < WEIGHT_BANKS; mux_bank_i = mux_bank_i + 1) begin
            weight_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[
                    WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT +
                                       mux_bank_i*WEIGHT_PARITY_LEAVES + read_parity_x_r)
                    +: WEIGHT_BANK_WIDTH
                ];
            weight_pair_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[
                    WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT +
                                       mux_bank_i*WEIGHT_PARITY_LEAVES + read_pair_parity_x_r)
                    +: WEIGHT_BANK_WIDTH
                ];
        end
    end

    assign result_cpu_rd_data =
        result_cpu_rd_data_bank[AXI_DATA_WIDTH*mm_rd_bank_d_r +: AXI_DATA_WIDTH];

    genvar result_bank_g;
    generate
        for (result_bank_g = 0; result_bank_g < BANK_COUNT; result_bank_g = result_bank_g + 1) begin : GEN_RESULT_BANK
            Dual_Port_BRAM #(
                .AWIDTH (RESULT_ADDR_WIDTH),
                .DWIDTH (AXI_DATA_WIDTH),
                .USE_URAM (0)
            ) u_result_bram (
                .clka  (CLK),
                .ena   ((result_rd_hit && (rd_pipe_bank_r == result_bank_g)) ||
                         (result_pair_write_pending_r && (active_bank_r == result_bank_g))),
                .wea   (result_pair_write_pending_r && (active_bank_r == result_bank_g) ?
                        result_pair_wr_strobe : {(AXI_DATA_WIDTH/8){1'b0}}),
                .addra (result_pair_write_pending_r && (active_bank_r == result_bank_g) ?
                        result_pair_write_addr_r : rd_pipe_index_r[RESULT_ADDR_WIDTH-1:0]),
                .dina  (result_pair_wr_data),
                .douta (result_cpu_rd_data_bank[AXI_DATA_WIDTH*result_bank_g +: AXI_DATA_WIDTH]),
                .clkb  (CLK),
                .enb   (result_writeback_fire && (active_bank_r == result_bank_g)),
                .web   (result_wr_strobe),
                .addrb (result_write_addr_r),
                .dinb  (result_wr_data),
                .doutb (result_compute_rd_unused_bank[AXI_DATA_WIDTH*result_bank_g +: AXI_DATA_WIDTH])
            );
        end
    endgenerate

    always @(posedge CLK) begin
        if (!RST) begin
            mm_rd_data  <= {AXI_DATA_WIDTH{1'b0}};
            mm_rd_valid <= 1'b0;
            mm_rd_error <= 1'b0;
            mm_rd_pending_r  <= 1'b0;
            mm_rd_region_d_r <= REGION_ACT;
            mm_rd_error_d_r  <= 1'b0;
            mm_rd_bank_d_r   <= 1'b0;
        end else begin
            // Result-window reads are synchronous.  The request is accepted in
            // one cycle, and the data/error response is returned on the next
            // cycle when Result BRAM output is valid.
            mm_rd_pending_r <= mm_rd_accept;
            if (mm_rd_accept) begin
                mm_rd_region_d_r <= rd_pipe_region_r;
                mm_rd_error_d_r  <= (!rd_region_known) || (!rd_index_ok);
                mm_rd_bank_d_r   <= rd_pipe_bank_r;
            end

            mm_rd_valid <= mm_rd_pending_r;
            mm_rd_error <= 1'b0;
            mm_rd_data  <= {AXI_DATA_WIDTH{1'b0}};

            if (mm_rd_pending_r) begin
                mm_rd_error <= mm_rd_error_d_r;
                case (mm_rd_region_d_r)
                    REGION_ACT: begin
                        mm_rd_error <= 1'b1;
                    end

                    REGION_WEIGHT: begin
                        mm_rd_error <= 1'b1;
                    end

                    REGION_RESULT: begin
                        mm_rd_data <= result_cpu_rd_data;
                    end

                    default: begin
                        mm_rd_error <= 1'b1;
                    end
                endcase
            end
        end
    end

    always @(posedge CLK) begin
        if (!RST) begin
            state_r             <= S_IDLE;
            done_r              <= 1'b0;
            error_r             <= 1'b0;
            active_bank_r        <= 1'b0;
            done_bank_r          <= 1'b0;
            active_job_id_r      <= 32'd0;
            done_job_id_r        <= 32'd0;
            active_rows_r       <= 16'd0;
            active_col_beats_r  <= 16'd0;
            row_idx_r           <= 16'd0;
            read_beat_idx_r     <= 16'd0;
            block_idx_r          <= 16'd0;
            group_blocks_r       <= 16'd1;
            result_row_base_r    <= 32'd0;
            weight_row_base_r   <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            group_mode_r         <= 1'b0;
            result_i8_mode_r     <= 1'b0;
            result_accum_clear_r <= 1'b0;
            result_emit_r        <= 1'b0;
            result_accum_rd_en_r <= 1'b0;
            result_accum_rd_addr_r <= 16'd0;
            result_accum_rd_data_r <= {ACC_WIDTH{1'b0}};
            result_accum_pmau_r <= {ACC_WIDTH{1'b0}};
            result_accum_next_r <= {ACC_WIDTH{1'b0}};
            result_accum_result_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_accum_result_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_accum_emit_r <= 1'b0;
            result_accum_final_row_r <= 1'b0;
            result_write_pending_r <= 1'b0;
            result_write_addr_r  <= {RESULT_ADDR_WIDTH{1'b0}};
            result_write_lane_r  <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_write_i8_r    <= 8'sd0;
            result_write_i32_r   <= {ACC_WIDTH{1'b0}};
            result_write_is_i8_r <= 1'b0;
            result_pair_write_pending_r <= 1'b0;
            result_pair_write_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_pair_write_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_pair_write_i32_r <= {ACC_WIDTH{1'b0}};
            result_pair_write_issued_r <= 1'b0;
            pair_mode_r <= 1'b0;
            result_requant_pending_r <= 1'b0;
            result_requant_value_r <= {ACC_WIDTH{1'b0}};
            result_requant_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_requant_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_requant_final_r <= 1'b0;
            spu_raw_valid       <= 1'b0;
            spu_raw_data        <= 32'sd0;
            spu_raw_row         <= 16'd0;
            spu_raw_block       <= 16'd0;
            spu_raw_group_blocks <= 16'd1;
            spu_raw_last_block  <= 1'b0;
            spu_raw_clear_accum <= 1'b0;
            spu_raw_job_id      <= 32'd0;
            spu_raw_bank        <= 1'b0;
            spu_raw_done        <= 1'b0;
            spu_raw_pair_valid  <= 1'b0;
            spu_raw_pair_data   <= 32'sd0;
            spu_raw_pair_row    <= 16'd0;
            spu_raw_pair_block  <= 16'd0;
            spu_raw_pair_group_blocks <= 16'd1;
            spu_raw_pair_last_block <= 1'b0;
            spu_raw_pair_clear_accum <= 1'b0;
            spu_raw_pair_job_id <= 32'd0;
            spu_raw_pair_bank <= 1'b0;
            feed_valid_r        <= 1'b0;
            feed_last_r         <= 1'b0;
            feed_group_last_r   <= 1'b0;
            read_req_valid_r    <= 1'b0;
            read_req_act_addr_r <= {ACT_ADDR_WIDTH{1'b0}};
            read_req_weight_addr_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            read_req_parity_r   <= 1'b0;
            read_req_pair_weight_addr_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            read_req_pair_parity_r <= 1'b0;
            read_req_last_r     <= 1'b0;
            read_req_group_last_r <= 1'b0;
            read_valid_d_r      <= 1'b0;
            read_last_d_r       <= 1'b0;
            read_group_last_d_r <= 1'b0;
            read_valid_q_r      <= 1'b0;
            read_last_q_r       <= 1'b0;
            read_group_last_q_r <= 1'b0;
            read_valid_x_r      <= 1'b0;
            read_last_x_r       <= 1'b0;
            read_group_last_x_r <= 1'b0;
            read_parity_d_r      <= 1'b0;
            read_parity_q_r      <= 1'b0;
            read_parity_x_r      <= 1'b0;
            read_pair_parity_d_r <= 1'b0;
            read_pair_parity_q_r <= 1'b0;
            read_pair_parity_x_r <= 1'b0;
            compute_rd_en       <= 1'b0;
            act_compute_addr    <= {ACT_ADDR_WIDTH{1'b0}};
            for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_TOTAL; fsm_ram_i = fsm_ram_i + 1) begin
                weight_compute_addr_leaf[fsm_ram_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                weight_compute_en_leaf[fsm_ram_i]   <= 1'b0;
            end
            act_pmau_data       <= {ACT_BEAT_WIDTH{1'b0}};
            weight_pmau_data    <= {WEIGHT_BEAT_WIDTH{1'b0}};
            weight_pair_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};
        end else begin
            compute_rd_en  <= 1'b0;
            result_accum_rd_en_r <= 1'b0;
            result_write_pending_r <= 1'b0;
            result_pair_write_pending_r <= 1'b0;
            result_requant_pending_r <= 1'b0;
            spu_raw_done  <= 1'b0;
            if (result_accum_rd_en_r)
                result_accum_rd_data_r <= result_accum_mem[result_accum_rd_addr_r];
            for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_TOTAL; fsm_ram_i = fsm_ram_i + 1) begin
                weight_compute_en_leaf[fsm_ram_i] <= 1'b0;
            end
            if (shift_req_to_d)
                read_req_valid_r <= 1'b0;
            read_valid_d_r <= 1'b0;
            read_group_last_d_r <= 1'b0;

            if (ctrl_clear_done) begin
                done_r  <= 1'b0;
                error_r <= 1'b0;
            end
            // Never acknowledge an active-bank ACT/WEIGHT handoff only to
            // discard it silently.  AXI remains protocol-compatible, while
            // the sticky core error makes the ownership violation visible.
            if (pair_active_input_write_reject)
                error_r <= 1'b1;

            case (state_r)
                S_IDLE: begin
                    // Wait for a new run.  ctrl_start snapshots all runtime
                    // configuration and resets row/block/read progress.
                    feed_valid_r       <= 1'b0;
                    feed_last_r        <= 1'b0;
                    feed_group_last_r  <= 1'b0;
                    read_valid_d_r     <= 1'b0;
                    read_req_valid_r   <= 1'b0;
                    read_valid_q_r     <= 1'b0;
                    read_valid_x_r     <= 1'b0;
                    read_beat_idx_r    <= 16'd0;
                    row_idx_r          <= 16'd0;
                    block_idx_r        <= 16'd0;
                    result_row_base_r  <= 32'd0;
                    weight_row_base_r  <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};

                    if (ctrl_start) begin
                        done_r <= 1'b0;
                        error_r            <= 1'b0;
                        active_rows_r      <= cfg_rows;
                        active_col_beats_r <= requested_col_beats;
                        group_mode_r       <= requested_group_mode;
                        result_i8_mode_r   <= requested_result_i8_mode;
                        result_accum_clear_r <= requested_result_accum_clear;
                        result_emit_r      <= requested_result_emit;
                        pair_mode_r        <= requested_pair_mode;
                        group_blocks_r     <= requested_group_blocks;
                        active_bank_r      <= cfg_wr_bank;
                        active_job_id_r    <= cfg_job_id;
                        state_r            <= S_VALIDATE;
                    end
                end

                S_VALIDATE: begin
                    // Reject illegal runtime dimensions before any memory read
                    // can be issued.  This prevents out-of-range BRAM access.
                    feed_valid_r <= 1'b0;
                    if (active_config_invalid) begin
                        error_r <= 1'b1;
                        done_r  <= 1'b1;
                        done_bank_r <= active_bank_r;
                        done_job_id_r <= active_job_id_r;
                        state_r <= S_ERROR;
                    end else begin
                        state_r <= S_RUN;
                    end
                end

                S_RUN: begin
                    // Main compute state.  Issue BRAM read requests, shift the
                    // synchronous-read pipeline, and feed aligned beats into
                    // PMAU when its input ready signals allow it.
                    if (pmau_input_fire)
                        feed_valid_r <= 1'b0;

                    if (consume_read_x) begin
                        feed_valid_r <= 1'b1;
                        feed_last_r  <= read_last_x_r;
                        feed_group_last_r <= read_group_last_x_r;
                        act_pmau_data    <= act_compute_data;
                        weight_pmau_data <= weight_compute_data;
                        weight_pair_pmau_data <= weight_pair_compute_data;
                        read_valid_x_r <= 1'b0;
                    end

                    if (shift_q_to_x) begin
                        read_valid_x_r <= 1'b1;
                        read_last_x_r  <= read_last_q_r;
                        read_group_last_x_r <= read_group_last_q_r;
                        read_parity_x_r <= read_parity_q_r;
                        read_pair_parity_x_r <= read_pair_parity_q_r;
                        read_valid_q_r <= 1'b0;
                    end

                    if (shift_d_to_q) begin
                        read_valid_q_r <= 1'b1;
                        read_last_q_r  <= read_last_d_r;
                        read_group_last_q_r <= read_group_last_d_r;
                        read_parity_q_r <= read_parity_d_r;
                        read_pair_parity_q_r <= read_pair_parity_d_r;
                    end

                    if (shift_req_to_d) begin
                        compute_rd_en       <= 1'b1;
                        act_compute_addr    <= read_req_act_addr_r;
                        for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1) begin
                            weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                                   fsm_bank_i*WEIGHT_PARITY_LEAVES + read_req_parity_r]
                                <= 1'b1;
                            weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                                     fsm_bank_i*WEIGHT_PARITY_LEAVES + read_req_parity_r]
                                <= read_req_weight_addr_r;
                            if (pair_lane1_valid) begin
                                // Primary and companion parities are opposite,
                                // so both independent SDP B ports can be
                                // enabled on this cycle without a leaf conflict.
                                weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                                       fsm_bank_i*WEIGHT_PARITY_LEAVES + read_req_pair_parity_r]
                                    <= 1'b1;
                                weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                                         fsm_bank_i*WEIGHT_PARITY_LEAVES + read_req_pair_parity_r]
                                    <= read_req_pair_weight_addr_r;
                            end
                        end
                        read_valid_d_r      <= 1'b1;
                        read_last_d_r       <= read_req_last_r;
                        read_group_last_d_r <= read_req_group_last_r;
                        read_parity_d_r      <= read_req_parity_r;
                        read_pair_parity_d_r <= read_req_pair_parity_r;
                    end

                    if (can_issue_read) begin
                        read_req_valid_r      <= 1'b1;
                        read_req_act_addr_r   <= read_abs_beat[ACT_ADDR_WIDTH-1:0];
                        read_req_weight_addr_r <= issue_weight_local_addr;
                        read_req_parity_r     <= issue_weight_parity;
                        read_req_pair_weight_addr_r <= issue_pair_weight_local_addr;
                        read_req_pair_parity_r <= issue_pair_weight_parity;
                        read_req_last_r       <= issue_read_last;
                        read_req_group_last_r <= issue_read_group_last;
                        read_beat_idx_r       <= read_beat_idx_r + 16'd1;
                    end

                    if (pmau_input_fire && wait_after_feed) begin
                        // The last beat of the current row/block has entered
                        // PMAU.  Stop issuing input and wait for the pipeline
                        // to produce the corresponding result.
                        feed_valid_r    <= 1'b0;
                        compute_rd_en   <= 1'b0;
                        for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_TOTAL; fsm_ram_i = fsm_ram_i + 1)
                            weight_compute_en_leaf[fsm_ram_i] <= 1'b0;
                        read_req_valid_r <= 1'b0;
                        read_valid_d_r  <= 1'b0;
                        read_valid_q_r  <= 1'b0;
                        read_valid_x_r  <= 1'b0;
                        state_r         <= S_WAIT_RESULT;
                    end
                end

                S_WAIT_RESULT: begin
                    // PMAU may still be processing the last accepted beat.
                    // Hold the FSM here until the completed INT32 result is
                    // returned and written into Result BRAM.
                    feed_valid_r <= 1'b0;

                    if (pmau_result_fire) begin
                        if (result_i8_mode_r) begin
                            result_accum_rd_en_r <= 1'b1;
                            result_accum_rd_addr_r <= row_idx_r;
                            result_accum_pmau_r <= $signed(pmau_result_data);
                            result_accum_result_addr_r <= result_wr_addr;
                            result_accum_result_lane_r <= result_wr_lane;
                            result_accum_emit_r <=
                                result_wr_index_ok && result_requant_capture;
                            result_accum_final_row_r <=
                                ((row_idx_r + 16'd1) >= active_rows_r);
                            block_idx_r <= 16'd0;
                            state_r <= result_wr_index_ok ? S_ACCUM_WAIT :
                                                         S_ERROR;
                        end else begin
                            if (result_wr_index_ok) begin
                                result_write_pending_r <= 1'b1;
                                result_write_addr_r    <= result_wr_addr;
                                result_write_lane_r    <= result_wr_lane;
                                result_write_i32_r     <= pmau_result_data;
                                result_write_is_i8_r   <= 1'b0;
                                // Commit lane 0 now; lane 1 is committed on
                                // the following retained-stream cycle. This
                                // avoids a same-word TDP collision when two
                                // adjacent raw INT32 values share a Result
                                // BRAM word.
                                result_pair_write_pending_r <= 1'b0;
                                result_pair_write_issued_r <= 1'b0;
                                result_pair_write_addr_r <= pair_result_wr_addr_i32;
                                result_pair_write_lane_r <=
                                    {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},
                                     pair_result_wr_lane_i32};
                                result_pair_write_i32_r <= pmau2_result_data;
                                spu_raw_valid          <= 1'b1;
                                spu_raw_data           <= $signed(pmau_result_data);
                                spu_raw_row            <= row_idx_r;
                                spu_raw_block          <= block_idx_r;
                                spu_raw_group_blocks   <= group_blocks_r;
                                spu_raw_last_block     <=
                                    ((block_idx_r + 16'd1) >= group_blocks_r);
                                spu_raw_clear_accum    <= (block_idx_r == 16'd0);
                                spu_raw_job_id         <= active_job_id_r;
                                spu_raw_bank           <= active_bank_r;
                                spu_raw_pair_valid     <= pair_lane1_valid;
                                spu_raw_pair_data      <= $signed(pmau2_result_data);
                                spu_raw_pair_row       <= row_idx_r + 16'd1;
                                spu_raw_pair_block     <= block_idx_r;
                                spu_raw_pair_group_blocks <= group_blocks_r;
                                spu_raw_pair_last_block <= ((block_idx_r + 16'd1) >= group_blocks_r);
                                spu_raw_pair_clear_accum <= (block_idx_r == 16'd0);
                                spu_raw_pair_job_id    <= active_job_id_r;
                                spu_raw_pair_bank      <= active_bank_r;
                                state_r                <= S_RAW_STREAM_HOLD;
                            end else begin
                                error_r <= 1'b1;
                                state_r <= S_ERROR;
                            end
                        end
                    end
                end

                S_RAW_STREAM_HOLD: begin
                    // Keep the complete raw token stable until SPU/FIFO
                    // accepts it.  Row/block progress is deliberately held
                    // here, so no partial result can be lost under backpressure.
                    feed_valid_r <= 1'b0;
                    if (pair_lane1_valid && !result_pair_write_issued_r) begin
                        result_pair_write_pending_r <= 1'b1;
                        result_pair_write_issued_r <= 1'b1;
                    end
                    if (spu_raw_valid && spu_raw_ready) begin
                        spu_raw_valid <= 1'b0;
                        spu_raw_pair_valid <= 1'b0;
                        if ((block_idx_r + 16'd1) < group_blocks_r) begin
                            block_idx_r <= block_idx_r + 16'd1;
                            state_r <= S_RUN;
                        end else begin
                            block_idx_r <= 16'd0;
                            if ((row_idx_r + (pair_lane1_valid ? 16'd2 : 16'd1)) >= active_rows_r) begin
                                state_r <= S_DRAIN_RESULT;
                            end else begin
                                row_idx_r         <= row_idx_r + (pair_lane1_valid ? 16'd2 : 16'd1);
                                read_beat_idx_r   <= 16'd0;
                                result_row_base_r <= result_row_base_r +
                                                     (pair_lane1_valid ? ({16'd0, group_blocks_r} << 1) :
                                                                         {16'd0, group_blocks_r});
                                // Parity leaves share one physical row-pair
                                // base.  A paired issue advances by a whole
                                // pair; legacy one-row mode advances only
                                // after consuming the odd member.
                                if (pair_lane1_valid || row_idx_r[0])
                                    weight_row_base_r <= weight_row_base_r + active_col_beats_r;
                                state_r           <= S_RUN;
                            end
                        end
                    end
                end

                S_ACCUM_WAIT: begin
                    // One cycle for the synchronous accumulator RAM read.
                    feed_valid_r <= 1'b0;
                    state_r <= S_ACCUM_ADD;
                end

                S_ACCUM_ADD: begin
                    // The BRAM output is registered before the add stage.  A
                    // clear launch treats the previous row value as zero
                    // without resetting every accumulator entry.
                    feed_valid_r <= 1'b0;
                    result_accum_next_r <=
                        (result_accum_clear_r ? {ACC_WIDTH{1'b0}} :
                                                result_accum_rd_data_r) +
                        result_accum_pmau_r;
                    state_r <= S_ACCUM_WRITE;
                end

                S_ACCUM_WRITE: begin
                    feed_valid_r <= 1'b0;
                    result_accum_mem[row_idx_r] <= result_accum_next_r;

                    if (result_accum_emit_r) begin
                        result_requant_pending_r <= 1'b1;
                        result_requant_value_r   <= result_accum_next_r;
                        result_requant_addr_r    <= result_accum_result_addr_r;
                        result_requant_lane_r    <= result_accum_result_lane_r;
                        result_requant_final_r   <= result_accum_final_row_r;
                    end

                    if (result_accum_final_row_r) begin
                        if (result_accum_emit_r)
                            state_r <= S_REQUANT_RESULT;
                        else begin
                            done_r  <= 1'b1;
                            state_r <= S_DONE;
                        end
                    end else begin
                        row_idx_r         <= row_idx_r + 16'd1;
                        read_beat_idx_r   <= 16'd0;
                        result_row_base_r <= result_row_base_r + 32'd1;
                        // INT8/legacy mode walks one row at a time.  Even and
                        // odd rows select different leaves at the same base;
                        // advance the pair base only after the odd row.
                        if (row_idx_r[0])
                            weight_row_base_r <= weight_row_base_r +
                                                 active_col_beats_r;
                        state_r           <= result_accum_emit_r ?
                                             S_REQUANT_RESULT : S_RUN;
                    end
                end

                S_REQUANT_RESULT: begin
                    // result_requant_value_r was captured with the PMAU
                    // response.  Requantize one cycle later so the INT32
                    // accumulator read and INT8 saturation/packing are never
                    // on the same timing path.
                    feed_valid_r <= 1'b0;
                    if (result_requant_pending_r) begin
                        result_write_pending_r <= 1'b1;
                        result_write_addr_r    <= result_requant_addr_r;
                        result_write_lane_r    <= result_requant_lane_r;
                        result_write_i8_r      <= pmau_result_i8;
                        result_write_is_i8_r   <= 1'b1;

                        if (result_requant_final_r)
                            state_r <= S_DRAIN_RESULT;
                        else
                            state_r <= S_RUN;
                    end else begin
                        // Defensive fallback: this state is entered only for
                        // a final-result capture, but never hang on a bad
                        // handshake.
                        error_r <= 1'b1;
                        state_r <= S_ERROR;
                    end
                end

                S_DRAIN_RESULT: begin
                    // On entry, result_write_pending_r was set by either raw
                    // result capture or S_REQUANT_RESULT. Result BRAM consumes
                    // it on this edge; asserting done here guarantees software
                    // observes the completed payload after the write commits.
                    feed_valid_r <= 1'b0;
                    done_r       <= 1'b1;
                    done_bank_r  <= active_bank_r;
                    done_job_id_r <= active_job_id_r;
                    spu_raw_done <= !result_i8_mode_r;
                    state_r      <= S_DONE;
                end

                S_DONE: begin
                    // Keep done asserted for software polling.  A new start
                    // command immediately snapshots new configuration and
                    // launches another validation/run sequence.
                    feed_valid_r <= 1'b0;
                    if (ctrl_start) begin
                        done_r              <= 1'b0;
                        error_r             <= 1'b0;
                        active_rows_r       <= cfg_rows;
                        active_col_beats_r  <= requested_col_beats;
                        group_mode_r        <= requested_group_mode;
                        result_i8_mode_r    <= requested_result_i8_mode;
                        result_accum_clear_r <= requested_result_accum_clear;
                        result_emit_r        <= requested_result_emit;
                        pair_mode_r          <= requested_pair_mode;
                        group_blocks_r      <= requested_group_blocks;
                        active_bank_r        <= cfg_wr_bank;
                        active_job_id_r      <= cfg_job_id;
                        row_idx_r           <= 16'd0;
                        read_beat_idx_r     <= 16'd0;
                        read_req_valid_r    <= 1'b0;
                        block_idx_r         <= 16'd0;
                        result_row_base_r   <= 32'd0;
                        weight_row_base_r   <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                        state_r             <= S_VALIDATE;
                    end
                end

                S_ERROR: begin
                    // Configuration errors are sticky until software clears
                    // them or starts a new run with corrected parameters.
                    feed_valid_r <= 1'b0;
                    if (ctrl_clear_done) begin
                        done_r  <= 1'b0;
                        error_r <= 1'b0;
                        state_r <= S_IDLE;
                    end else if (ctrl_start) begin
                        done_r             <= 1'b0;
                        error_r            <= 1'b0;
                        active_rows_r      <= cfg_rows;
                        active_col_beats_r <= requested_col_beats;
                        group_mode_r       <= requested_group_mode;
                        result_i8_mode_r   <= requested_result_i8_mode;
                        result_accum_clear_r <= requested_result_accum_clear;
                        result_emit_r      <= requested_result_emit;
                        pair_mode_r        <= requested_pair_mode;
                        group_blocks_r     <= requested_group_blocks;
                        active_bank_r      <= cfg_wr_bank;
                        active_job_id_r    <= cfg_job_id;
                        row_idx_r          <= 16'd0;
                        read_beat_idx_r    <= 16'd0;
                        read_req_valid_r   <= 1'b0;
                        block_idx_r        <= 16'd0;
                        result_row_base_r  <= 32'd0;
                        weight_row_base_r  <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                        state_r            <= S_VALIDATE;
                    end
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
        end
    end

endmodule
