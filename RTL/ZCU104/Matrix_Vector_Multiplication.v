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
 * - REGION_WEIGHT writes retain pair-interleaved weight beats.  For every row
 *   pair and beat, the even-row word is followed by the odd-row word; an odd
 *   final row still supplies a zero companion word.  The write-side stride
 *   decoder maps this ABI into eight logical row-slot leaves at 4K depth.
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
 * results are packed into each 128-bit Result BRAM word.  The deployed P2 x8
 * raw path is stream-only: raw sums are delivered directly to SPU and do not
 * need a duplicate Result-BRAM retirement before the scheduler advances.
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
    // The result/scale index is already formed by the VPU result-address
    // path.  Registering it with the raw token avoids recomputing
    // row*group_blocks in SPU_Top's ready/valid timing cone.
    output reg  [31:0]                       spu_raw_scale_index,
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
    output reg  [31:0]                       spu_raw_pair_scale_index,
    // Native x8 VPU->SPU bundle. Lane 0 aliases spu_raw_*, lane 1 aliases
    // spu_raw_pair_*. Shared block/job metadata remains on spu_raw_*.
    output reg  [7:0]                        spu_raw_lane_valid,
    output reg  [8*32-1:0]                   spu_raw_lane_data,
    output reg  [8*16-1:0]                   spu_raw_lane_row,
    output reg  [8*32-1:0]                   spu_raw_lane_scale_index,

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
    // Each 32-bit lane has eight SDP UltraRAM row-slot leaves.  The external
    // P2 payload remains pair-interleaved, while the write path maps each word
    // into row[2:0] and (row >> 3)*col_beats + beat.  Eight 4K leaves replace
    // the former four 8K row-slot leaves, retaining the same total weight capacity.
    localparam WEIGHT_ROW_SLOT_LEAVES   = 8;
    localparam WEIGHT_LOCAL_ADDR_WIDTH  = clog2(WEIGHT_DEPTH / WEIGHT_ROW_SLOT_LEAVES);
    localparam WEIGHT_RAM_COUNT         = WEIGHT_BANKS * WEIGHT_ROW_SLOT_LEAVES;
    localparam WEIGHT_COMPUTE_ADDR_COUNT = BANK_COUNT * WEIGHT_BANKS;
    localparam WEIGHT_RAM_TOTAL        = BANK_COUNT * WEIGHT_RAM_COUNT;
    localparam LANE_SHIFT           = clog2(NUM_LANES);
    localparam [15:0] NUM_LANES_16          = NUM_LANES;
    localparam [15:0] MAX_ROWS_16           = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16      = MAX_COL_BEATS;
    localparam [15:0] Q8_BLOCK_BEATS_16     = 16'd2;
    // Raw P2 x8 mode may fill the complete PMAU result reservation window
    // before retiring results. PMAU_Full accounts for both FIFO-resident and
    // in-flight row ends, so eight accepted blocks exactly consume (but never
    // exceed) the default eight-entry result FIFO capacity.
    localparam [3:0]  RAW_BURST_MAX          = 4'd8;
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

    wire [ACT_BEAT_WIDTH-1:0]   act_compute_data;
    wire [ACT_BEAT_WIDTH*BANK_COUNT-1:0] act_compute_data_bank;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_pair_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad2_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad3_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad4_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad5_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad6_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad7_compute_data;
    wire [WEIGHT_BANK_WIDTH*WEIGHT_RAM_TOTAL-1:0] weight_compute_data_leaf;
    reg [ACT_BEAT_WIDTH-1:0]    act_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pair_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad2_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad3_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad4_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad5_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad6_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad7_pmau_data;
    wire [AXI_DATA_WIDTH-1:0]   result_cpu_rd_data;
    reg [ACT_ADDR_WIDTH-1:0]    act_compute_addr;
    reg                         compute_rd_en;
    (* keep = "true" *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_compute_addr_shared [0:WEIGHT_COMPUTE_ADDR_COUNT-1];
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

    reg                         wr_pipe_en_r;
    reg [1:0]                   wr_pipe_region_r;
    reg [31:0]                  wr_pipe_index_r;
    reg                         wr_pipe_bank_r;
    reg [15:0]                  wr_pipe_col_beats_r;
    localparam WEIGHT_DIV_STAGES = 14;
    reg [WEIGHT_DIV_STAGES-1:0]  weight_div_valid_r;
    reg [7:0]                    weight_div_rem_r [0:WEIGHT_DIV_STAGES-1];
    reg [13:0]                   weight_div_pair_r [0:WEIGHT_DIV_STAGES-1];
    reg [13:0]                   weight_div_q_r [0:WEIGHT_DIV_STAGES-1];
    reg [15:0]                   weight_div_col_beats_r [0:WEIGHT_DIV_STAGES-1];
    reg                          weight_div_parity_r [0:WEIGHT_DIV_STAGES-1];
    reg                          weight_div_bank_r [0:WEIGHT_DIV_STAGES-1];
    reg [AXI_DATA_WIDTH-1:0]     weight_div_data_r [0:WEIGHT_DIV_STAGES-1];
    reg [(AXI_DATA_WIDTH/8)-1:0] weight_div_strb_r [0:WEIGHT_DIV_STAGES-1];
    reg                          weight_map_delta_valid_r;
    reg [13:0]                   weight_map_delta_r;
    reg [13:0]                   weight_map_delta_pair_r;
    reg [7:0]                    weight_map_delta_rem_r;
    reg [15:0]                   weight_map_delta_col_beats_r;
    reg                          weight_map_delta_parity_r;
    reg                          weight_map_delta_bank_r;
    reg [AXI_DATA_WIDTH-1:0]     weight_map_delta_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] weight_map_delta_strb_r;
    reg                          weight_map_base_valid_r;
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_map_base_r;
    reg [7:0]                    weight_map_base_rem_r;
    reg [1:0]                    weight_map_base_pair_mod4_r;
    reg                          weight_map_base_parity_r;
    reg                          weight_map_base_bank_r;
    reg [AXI_DATA_WIDTH-1:0]     weight_map_base_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] weight_map_base_strb_r;
    reg                         weight_map_valid_r;
    reg [2:0]                   weight_map_row_slot_r;
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_map_local_addr_r;
    reg                         weight_map_bank_r;
    reg [AXI_DATA_WIDTH-1:0]    weight_map_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] weight_map_strb_r;
    (* keep = "true" *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_wr_addr_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg                         weight_wr_en_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg [WEIGHT_BANK_WIDTH-1:0] weight_wr_data_leaf [0:WEIGHT_RAM_TOTAL-1];
    (* keep = "true" *)
    reg [WEIGHT_BANK_BYTES-1:0] weight_wr_strb_leaf [0:WEIGHT_RAM_TOTAL-1];
    reg [BANK_COUNT-1:0]        weight_leaf_stage_valid_r;
    reg [2:0]                   weight_leaf_stage_row_slot_r [0:BANK_COUNT-1];
    (* max_fanout = 8 *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_leaf_stage_addr_r [0:BANK_COUNT-1];
    reg [AXI_DATA_WIDTH-1:0]    weight_leaf_stage_data_r [0:BANK_COUNT-1];
    reg [(AXI_DATA_WIDTH/8)-1:0] weight_leaf_stage_strb_r [0:BANK_COUNT-1];
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
    reg [7:0]  row_lane_valid_r;
    reg [15:0] read_beat_idx_r;
    reg [15:0] block_idx_r;
    reg [15:0] issue_block_idx_r;
    reg [3:0]  raw_burst_blocks_r;
    reg [3:0]  raw_burst_retired_r;
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

    reg result_write_pending_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_write_addr_r;
    (* keep = "true" *)
    reg [RESULT_ADDR_WIDTH-1:0] result_write_addr_bank_r [0:BANK_COUNT-1];
    reg [RESULT_I8_LANE_SHIFT-1:0] result_write_lane_r;
    reg signed [7:0] result_write_i8_r;
    reg signed [ACC_WIDTH-1:0] result_write_i32_r;
    reg result_write_is_i8_r;
    reg pair_mode_r;
    reg signed [ACC_WIDTH-1:0] result_row1_data_r;
    reg signed [ACC_WIDTH-1:0] result_row2_data_r;
    reg signed [ACC_WIDTH-1:0] result_row3_data_r;
    reg signed [ACC_WIDTH-1:0] result_row4_data_r;
    reg signed [ACC_WIDTH-1:0] result_row5_data_r;
    reg signed [ACC_WIDTH-1:0] result_row6_data_r;
    reg signed [ACC_WIDTH-1:0] result_row7_data_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row1_addr_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row2_addr_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row3_addr_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row4_addr_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row5_addr_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row6_addr_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_row7_addr_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row1_lane_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row2_lane_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row3_lane_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row4_lane_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row5_lane_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row6_lane_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_row7_lane_r;
    reg [2:0] result_write_slot_r;
    reg result_writes_done_r;
    reg raw_bundle_accepted_r;

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
    reg read_bank_d_r;
    reg read_req_valid_r;
    reg [ACT_ADDR_WIDTH-1:0] read_req_act_addr_r;
    (* max_fanout = 8 *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] read_req_weight_addr_r;
    reg [2:0]                         read_req_row_slot_r;
    reg [2:0]                         read_req_pair_row_slot_r;
    reg [2:0]                         read_req_quad2_row_slot_r;
    reg [2:0]                         read_req_quad3_row_slot_r;
    reg [2:0]                         read_req_quad4_row_slot_r;
    reg [2:0]                         read_req_quad5_row_slot_r;
    reg [2:0]                         read_req_quad6_row_slot_r;
    reg [2:0]                         read_req_quad7_row_slot_r;
    reg read_req_last_r;
    reg read_req_group_last_r;
    reg read_valid_q_r;
    reg read_last_q_r;
    reg read_group_last_q_r;
    reg read_bank_q_r;
    reg read_valid_x_r;
    reg read_last_x_r;
    reg read_group_last_x_r;
    reg read_bank_x_r;
    reg [2:0] read_row_slot_d_r;
    reg [2:0] read_row_slot_q_r;
    reg [2:0] read_row_slot_x_r;
    reg [2:0] read_pair_row_slot_d_r;
    reg [2:0] read_pair_row_slot_q_r;
    reg [2:0] read_pair_row_slot_x_r;
    reg [2:0] read_quad2_row_slot_d_r;
    reg [2:0] read_quad2_row_slot_q_r;
    reg [2:0] read_quad2_row_slot_x_r;
    reg [2:0] read_quad3_row_slot_d_r;
    reg [2:0] read_quad3_row_slot_q_r;
    reg [2:0] read_quad3_row_slot_x_r;
    reg [2:0] read_quad4_row_slot_d_r, read_quad4_row_slot_q_r;
    reg [2:0] read_quad4_row_slot_x_r;
    reg [2:0] read_quad5_row_slot_d_r, read_quad5_row_slot_q_r;
    reg [2:0] read_quad5_row_slot_x_r;
    reg [2:0] read_quad6_row_slot_d_r, read_quad6_row_slot_q_r;
    reg [2:0] read_quad6_row_slot_x_r;
    reg [2:0] read_quad7_row_slot_d_r, read_quad7_row_slot_q_r;
    reg [2:0] read_quad7_row_slot_x_r;
    (* keep = "true" *)
    reg [2:0] read_quad7_row_slot_local_r [0:WEIGHT_COMPUTE_ADDR_COUNT-1];

    reg [31:0] raw_group_offset_r [0:7];
    reg [31:0] raw_row_base_advance_r;
    (* keep = "true" *)
    reg [31:0] raw_lane_result_index_r [0:7];

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
    function [7:0] make_row_lane_valid;
        input [15:0] base_row;
        input [15:0] total_rows;
        input        pair_mode;
        begin
            make_row_lane_valid[0] = 1'b1;
            make_row_lane_valid[1] = pair_mode && ((base_row + 16'd1) < total_rows);
            make_row_lane_valid[2] = pair_mode && ((base_row + 16'd2) < total_rows);
            make_row_lane_valid[3] = pair_mode && ((base_row + 16'd3) < total_rows);
            make_row_lane_valid[4] = pair_mode && ((base_row + 16'd4) < total_rows);
            make_row_lane_valid[5] = pair_mode && ((base_row + 16'd5) < total_rows);
            make_row_lane_valid[6] = pair_mode && ((base_row + 16'd6) < total_rows);
            make_row_lane_valid[7] = pair_mode && ((base_row + 16'd7) < total_rows);
        end
    endfunction

    wire pair_lane1_valid = row_lane_valid_r[1];
    wire pair_lane2_valid = row_lane_valid_r[2];
    wire pair_lane3_valid = row_lane_valid_r[3];
    wire pair_lane4_valid = row_lane_valid_r[4];
    wire pair_lane5_valid = row_lane_valid_r[5];
    wire pair_lane6_valid = row_lane_valid_r[6];
    wire pair_lane7_valid = row_lane_valid_r[7];
    wire raw_burst_mode = pair_mode_r && group_mode_r && !result_i8_mode_r;
    wire pair_compute_ownership = pair_mode_r &&
        ((state_r == S_RUN) || (state_r == S_WAIT_RESULT) ||
         (state_r == S_RAW_STREAM_HOLD) || (state_r == S_DRAIN_RESULT)) &&
        (cfg_wr_bank == active_bank_r);
    wire pair_active_input_write_reject =
        mm_wr_en && pair_compute_ownership &&
        ((mm_wr_region == REGION_ACT) || (mm_wr_region == REGION_WEIGHT));
    wire pair_active_write_block = pair_compute_ownership &&
        ((mm_wr_region == REGION_ACT) || (mm_wr_region == REGION_WEIGHT));
    wire [WEIGHT_DIV_STAGES-1:0] active_bank_weight_div_valid;
    genvar active_bank_div_stage;
    generate
        for (active_bank_div_stage = 0;
             active_bank_div_stage < WEIGHT_DIV_STAGES;
             active_bank_div_stage = active_bank_div_stage + 1) begin : GEN_ACTIVE_BANK_WEIGHT_DIV_VALID
            assign active_bank_weight_div_valid[active_bank_div_stage] =
                weight_div_valid_r[active_bank_div_stage] &&
                (weight_div_bank_r[active_bank_div_stage] == active_bank_r);
        end
    endgenerate

    wire active_bank_weight_write_pipeline_busy =
        (mm_wr_en && (mm_wr_region == REGION_WEIGHT) &&
         (cfg_wr_bank == active_bank_r)) ||
        (wr_pipe_en_r && (wr_pipe_region_r == REGION_WEIGHT) &&
         (wr_pipe_bank_r == active_bank_r)) ||
        (|active_bank_weight_div_valid) ||
        (weight_map_delta_valid_r &&
         (weight_map_delta_bank_r == active_bank_r)) ||
        (weight_map_base_valid_r &&
         (weight_map_base_bank_r == active_bank_r)) ||
        (weight_map_valid_r && (weight_map_bank_r == active_bank_r)) ||
        weight_leaf_stage_valid_r[active_bank_r];

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
    wire pmau3_activation_ready;
    wire pmau3_weight_ready;
    wire pmau3_input_ready;
    wire pmau3_result_valid;
    wire [ACC_WIDTH-1:0] pmau3_result_data;
    wire pmau4_activation_ready;
    wire pmau4_weight_ready;
    wire pmau4_input_ready;
    wire pmau4_result_valid;
    wire [ACC_WIDTH-1:0] pmau4_result_data;
    wire pmau5_activation_ready, pmau5_weight_ready, pmau5_input_ready, pmau5_result_valid;
    wire [ACC_WIDTH-1:0] pmau5_result_data;
    wire pmau6_activation_ready, pmau6_weight_ready, pmau6_input_ready, pmau6_result_valid;
    wire [ACC_WIDTH-1:0] pmau6_result_data;
    wire pmau7_activation_ready, pmau7_weight_ready, pmau7_input_ready, pmau7_result_valid;
    wire [ACC_WIDTH-1:0] pmau7_result_data;
    wire pmau8_activation_ready, pmau8_weight_ready, pmau8_input_ready, pmau8_result_valid;
    wire [ACC_WIDTH-1:0] pmau8_result_data;
    wire signed [7:0] pmau_result_i8;
    wire [4:0] result_requant_shift = cfg_scale[4:0];
    wire pmau_all_results_valid = pmau_result_valid &&
                                  (!pair_lane1_valid || pmau2_result_valid) &&
                                  (!pair_lane2_valid || pmau3_result_valid) &&
                                  (!pair_lane3_valid || pmau4_result_valid) &&
                                  (!pair_lane4_valid || pmau5_result_valid) &&
                                  (!pair_lane5_valid || pmau6_result_valid) &&
                                  (!pair_lane6_valid || pmau7_result_valid) &&
                                  (!pair_lane7_valid || pmau8_result_valid);
    wire raw_stream_fire = spu_raw_valid && spu_raw_ready;
    wire raw_burst_more_results =
        (raw_burst_retired_r + 4'd1) < raw_burst_blocks_r;
    // When the current raw bundle is accepted, pop the next already-complete
    // PMAU result directly into the same output register. This preserves the
    // registered ready/valid boundary under backpressure while removing the
    // otherwise idle return through S_WAIT_RESULT between burst results.
    wire raw_burst_chain_request =
        (state_r == S_RAW_STREAM_HOLD) && raw_burst_mode &&
        result_writes_done_r && raw_stream_fire && raw_burst_more_results;
    wire pmau_result_accept =
        ((state_r == S_WAIT_RESULT) || raw_burst_chain_request) &&
        pmau_all_results_valid;
    wire raw_burst_chain_pop = raw_burst_chain_request &&
                               pmau_all_results_valid;
    wire pmau_result_ready = pmau_result_accept;
    wire pmau2_result_ready = pmau_result_accept;
    wire pmau3_result_ready = pmau_result_accept;
    wire pmau4_result_ready = pmau_result_accept;
    wire pmau5_result_ready = pmau_result_accept;
    wire pmau6_result_ready = pmau_result_accept;
    wire pmau7_result_ready = pmau_result_accept;
    wire pmau8_result_ready = pmau_result_accept;
    wire pair_issue_grant = pmau_input_ready &&
                            (!pair_lane1_valid || pmau2_input_ready) &&
                            (!pair_lane2_valid || pmau3_input_ready) &&
                            (!pair_lane3_valid || pmau4_input_ready) &&
                            (!pair_lane4_valid || pmau5_input_ready) &&
                            (!pair_lane5_valid || pmau6_input_ready) &&
                            (!pair_lane6_valid || pmau7_input_ready) &&
                            (!pair_lane7_valid || pmau8_input_ready);
    // One next-burst beat may remain buffered while the current bounded P2
    // result reservation retires.  Keep it out of the PMAUs until S_RUN.
    wire pmau_offer_valid = (state_r == S_RUN) && feed_valid_r &&
                            pair_issue_grant;
    wire pmau_input_fire =
        pmau_offer_valid && pmau_activation_ready && pmau_weight_ready &&
        (!pair_lane1_valid || (pmau2_activation_ready && pmau2_weight_ready)) &&
        (!pair_lane2_valid || (pmau3_activation_ready && pmau3_weight_ready)) &&
        (!pair_lane3_valid || (pmau4_activation_ready && pmau4_weight_ready)) &&
        (!pair_lane4_valid || (pmau5_activation_ready && pmau5_weight_ready)) &&
        (!pair_lane5_valid || (pmau6_activation_ready && pmau6_weight_ready)) &&
        (!pair_lane6_valid || (pmau7_activation_ready && pmau7_weight_ready)) &&
        (!pair_lane7_valid || (pmau8_activation_ready && pmau8_weight_ready));
    wire pmau_result_fire = pmau_result_valid && pmau_result_ready;
    wire wait_after_feed =
        result_i8_mode_r ? feed_group_last_r : feed_last_r;
    // In P2 raw x8 mode a block boundary is not necessarily a scheduler
    // boundary. Keep the local-memory stream alive until the bounded eight-block
    // reservation is complete, then clear the read enables once before retire.
    wire p2_block_end_fire = raw_burst_mode && pmau_input_fire && feed_last_r;
    wire p2_burst_continue =
        p2_block_end_fire &&
        ((issue_block_idx_r + 16'd1) < group_blocks_r) &&
        (raw_burst_blocks_r < (RAW_BURST_MAX - 4'd1));
    wire p2_burst_end_fire = p2_block_end_fire && !p2_burst_continue;
    wire legacy_compute_final_clear =
        (!raw_burst_mode) && pmau_input_fire && wait_after_feed;
    wire weight_compute_final_clear =
        legacy_compute_final_clear || p2_burst_end_fire;

    wire p2_read_fast_safe = raw_burst_mode &&
                             (RESULT_FIFO_DEPTH >= RAW_BURST_MAX);
    wire feed_slot_open = !feed_valid_r ||
                          (p2_read_fast_safe && pmau_input_fire);
    wire consume_read_x = read_valid_x_r && feed_slot_open;
    wire read_x_slot_open = (!read_valid_x_r) || consume_read_x;
    wire shift_q_to_x = read_valid_q_r && read_x_slot_open;
    wire read_q_slot_open = (!read_valid_q_r) || shift_q_to_x;
    wire shift_d_to_q = read_valid_d_r && read_q_slot_open;
    wire read_d_slot_open = (!read_valid_d_r) || shift_d_to_q;
    wire shift_req_to_d = read_req_valid_r && read_d_slot_open;
    wire read_req_slot_open = (!read_req_valid_r) || shift_req_to_d;
    wire read_shift_addr_fire = shift_req_to_d;
    wire [15:0] read_abs_beat = read_beat_idx_r;
    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] issue_weight_local_addr =
        weight_row_base_r + read_abs_beat[WEIGHT_LOCAL_ADDR_WIDTH-1:0];
    wire [2:0] issue_weight_row_slot = row_idx_r[2:0];
    wire [2:0] issue_pair_weight_row_slot = row_idx_r[2:0] + 3'd1;
    wire [2:0] issue_quad2_weight_row_slot = row_idx_r[2:0] + 3'd2;
    wire [2:0] issue_quad3_weight_row_slot = row_idx_r[2:0] + 3'd3;
    wire [2:0] issue_quad4_weight_row_slot = row_idx_r[2:0] + 3'd4;
    wire [2:0] issue_quad5_weight_row_slot = row_idx_r[2:0] + 3'd5;
    wire [2:0] issue_quad6_weight_row_slot = row_idx_r[2:0] + 3'd6;
    wire [2:0] issue_quad7_weight_row_slot = row_idx_r[2:0] + 3'd7;
    wire [15:0] raw_issue_block_idx =
        raw_burst_mode ? issue_block_idx_r : block_idx_r;
    wire [15:0] raw_group_issue_limit =
        {raw_issue_block_idx[14:0], 1'b0} + Q8_BLOCK_BEATS_16;
    // During a P2 burst block_idx_r is the oldest unretired block and remains
    // stable while reads issue. One limit therefore covers the complete
    // <=RAW_BURST_MAX reservation window without exceeding FIFO capacity.
    wire [15:0] raw_p2_candidate_end_block =
        block_idx_r + {12'd0, RAW_BURST_MAX};
    wire [15:0] raw_p2_end_block =
        (raw_p2_candidate_end_block < group_blocks_r) ?
            raw_p2_candidate_end_block : group_blocks_r;
    wire [15:0] raw_p2_burst_issue_limit =
        {raw_p2_end_block[14:0], 1'b0};
    // Fetch the first beat of the next reservation before retiring the current
    // one.  The existing feed register owns the complete BRAM payload, so only
    // one beat crosses the S_WAIT_RESULT/S_RAW_STREAM_HOLD boundary.
    wire [15:0] raw_p2_lookahead_issue_limit =
        raw_p2_burst_issue_limit +
        ((raw_p2_end_block < group_blocks_r) ? 16'd1 : 16'd0);
    wire [15:0] issue_read_limit =
        raw_burst_mode ? raw_p2_lookahead_issue_limit :
        (!result_i8_mode_r && group_mode_r) ? raw_group_issue_limit :
                                              active_col_beats_r;
    wire p2_can_issue_read =
        (state_r == S_RUN) &&
        read_req_slot_open && read_d_slot_open && read_q_slot_open &&
        read_x_slot_open && feed_slot_open &&
        (read_beat_idx_r < issue_read_limit);
    wire legacy_can_issue_read =
        (state_r == S_RUN) &&
        read_req_slot_open &&
        !read_req_valid_r && !read_valid_d_r && !read_valid_q_r &&
        !read_valid_x_r && !feed_valid_r &&
        (read_beat_idx_r < issue_read_limit);
    wire can_issue_read = p2_read_fast_safe ? p2_can_issue_read :
                                               legacy_can_issue_read;
    wire issue_read_last =
        result_i8_mode_r ? (read_beat_idx_r == (active_col_beats_r - 16'd1)) :
        group_mode_r ? (read_beat_idx_r[0] == 1'b1) :
                       (read_beat_idx_r == (active_col_beats_r - 16'd1));
    wire issue_read_group_last =
        (read_beat_idx_r == (active_col_beats_r - 16'd1));

    wire [31:0] raw_result_value_index = raw_lane_result_index_r[0];
    wire [31:0] result_value_index =
        result_i8_mode_r ? {16'd0, row_idx_r} :
        group_mode_r ? raw_result_value_index :
                        {16'd0, row_idx_r};
    wire [31:0] pair_result_value_index = raw_lane_result_index_r[1];
    wire [31:0] quad2_result_value_index = raw_lane_result_index_r[2];
    wire [31:0] quad3_result_value_index = raw_lane_result_index_r[3];
    wire [31:0] quad4_result_value_index = raw_lane_result_index_r[4];
    wire [31:0] quad5_result_value_index = raw_lane_result_index_r[5];
    wire [31:0] quad6_result_value_index = raw_lane_result_index_r[6];
    wire [31:0] quad7_result_value_index = raw_lane_result_index_r[7];
    wire [RESULT_ADDR_WIDTH-1:0] pair_result_wr_addr_i32 =
        pair_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] pair_result_wr_lane_i32 =
        pair_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] quad2_result_wr_addr_i32 =
        quad2_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] quad2_result_wr_lane_i32 =
        quad2_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] quad3_result_wr_addr_i32 =
        quad3_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] quad3_result_wr_lane_i32 =
        quad3_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] quad4_result_wr_addr_i32 = quad4_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] quad4_result_wr_lane_i32 = quad4_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] quad5_result_wr_addr_i32 = quad5_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] quad5_result_wr_lane_i32 = quad5_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] quad6_result_wr_addr_i32 = quad6_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] quad6_result_wr_lane_i32 = quad6_result_value_index[RESULT_LANE_SHIFT-1:0];
    wire [RESULT_ADDR_WIDTH-1:0] quad7_result_wr_addr_i32 = quad7_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];
    wire [RESULT_LANE_SHIFT-1:0] quad7_result_wr_lane_i32 = quad7_result_value_index[RESULT_LANE_SHIFT-1:0];
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

    PMAU_Full #(
        .NUM_LANES         (NUM_LANES), .ACT_WIDTH (ACT_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH), .ACC_WIDTH (ACC_WIDTH),
        .SCALE_WIDTH       (SCALE_WIDTH), .SCALE_FRAC_BITS (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH (RESULT_FIFO_DEPTH)
    ) u_pmau_quad2 (
        .CLK               (CLK), .RST (RST), .compute_mode (compute_mode[1:0]),
        .activation_data   (act_pmau_data),
        .activation_valid  ((state_r == S_RUN) && pmau_offer_valid && pair_lane2_valid),
        .activation_ready  (pmau3_activation_ready), .input_ready (pmau3_input_ready), .activation_last (feed_last_r),
        .weight_data       (weight_quad2_pmau_data), .scale_factor (cfg_scale),
        .weight_valid      ((state_r == S_RUN) && pmau_offer_valid && pair_lane2_valid),
        .weight_ready      (pmau3_weight_ready), .weight_last (feed_last_r),
        .scalar_axpy       (16'd0), .result_data (pmau3_result_data),
        .result_valid      (pmau3_result_valid), .result_ready (pmau3_result_ready),
        .result_last       ()
    );

    PMAU_Full #(
        .NUM_LANES         (NUM_LANES), .ACT_WIDTH (ACT_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH), .ACC_WIDTH (ACC_WIDTH),
        .SCALE_WIDTH       (SCALE_WIDTH), .SCALE_FRAC_BITS (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH (RESULT_FIFO_DEPTH)
    ) u_pmau_quad3 (
        .CLK               (CLK), .RST (RST), .compute_mode (compute_mode[1:0]),
        .activation_data   (act_pmau_data),
        .activation_valid  ((state_r == S_RUN) && pmau_offer_valid && pair_lane3_valid),
        .activation_ready  (pmau4_activation_ready), .input_ready (pmau4_input_ready), .activation_last (feed_last_r),
        .weight_data       (weight_quad3_pmau_data), .scale_factor (cfg_scale),
        .weight_valid      ((state_r == S_RUN) && pmau_offer_valid && pair_lane3_valid),
        .weight_ready      (pmau4_weight_ready), .weight_last (feed_last_r),
        .scalar_axpy       (16'd0), .result_data (pmau4_result_data),
        .result_valid      (pmau4_result_valid), .result_ready (pmau4_result_ready),
        .result_last       ()
    );

    PMAU_Full #(.NUM_LANES(NUM_LANES), .ACT_WIDTH(ACT_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH), .SCALE_WIDTH(SCALE_WIDTH), .SCALE_FRAC_BITS(SCALE_FRAC_BITS), .RESULT_FIFO_DEPTH(RESULT_FIFO_DEPTH)) u_pmau_quad4 (
        .CLK(CLK), .RST(RST), .compute_mode(compute_mode[1:0]), .activation_data(act_pmau_data),
        .activation_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane4_valid), .activation_ready(pmau5_activation_ready), .input_ready(pmau5_input_ready), .activation_last(feed_last_r),
        .weight_data(weight_quad4_pmau_data), .scale_factor(cfg_scale), .weight_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane4_valid), .weight_ready(pmau5_weight_ready), .weight_last(feed_last_r),
        .scalar_axpy(16'd0), .result_data(pmau5_result_data), .result_valid(pmau5_result_valid), .result_ready(pmau5_result_ready), .result_last());
    PMAU_Full #(.NUM_LANES(NUM_LANES), .ACT_WIDTH(ACT_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH), .SCALE_WIDTH(SCALE_WIDTH), .SCALE_FRAC_BITS(SCALE_FRAC_BITS), .RESULT_FIFO_DEPTH(RESULT_FIFO_DEPTH)) u_pmau_quad5 (
        .CLK(CLK), .RST(RST), .compute_mode(compute_mode[1:0]), .activation_data(act_pmau_data),
        .activation_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane5_valid), .activation_ready(pmau6_activation_ready), .input_ready(pmau6_input_ready), .activation_last(feed_last_r),
        .weight_data(weight_quad5_pmau_data), .scale_factor(cfg_scale), .weight_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane5_valid), .weight_ready(pmau6_weight_ready), .weight_last(feed_last_r),
        .scalar_axpy(16'd0), .result_data(pmau6_result_data), .result_valid(pmau6_result_valid), .result_ready(pmau6_result_ready), .result_last());
    PMAU_Full #(.NUM_LANES(NUM_LANES), .ACT_WIDTH(ACT_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH), .SCALE_WIDTH(SCALE_WIDTH), .SCALE_FRAC_BITS(SCALE_FRAC_BITS), .RESULT_FIFO_DEPTH(RESULT_FIFO_DEPTH)) u_pmau_quad6 (
        .CLK(CLK), .RST(RST), .compute_mode(compute_mode[1:0]), .activation_data(act_pmau_data),
        .activation_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane6_valid), .activation_ready(pmau7_activation_ready), .input_ready(pmau7_input_ready), .activation_last(feed_last_r),
        .weight_data(weight_quad6_pmau_data), .scale_factor(cfg_scale), .weight_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane6_valid), .weight_ready(pmau7_weight_ready), .weight_last(feed_last_r),
        .scalar_axpy(16'd0), .result_data(pmau7_result_data), .result_valid(pmau7_result_valid), .result_ready(pmau7_result_ready), .result_last());
    PMAU_Full #(.NUM_LANES(NUM_LANES), .ACT_WIDTH(ACT_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH), .SCALE_WIDTH(SCALE_WIDTH), .SCALE_FRAC_BITS(SCALE_FRAC_BITS), .RESULT_FIFO_DEPTH(RESULT_FIFO_DEPTH)) u_pmau_quad7 (
        .CLK(CLK), .RST(RST), .compute_mode(compute_mode[1:0]), .activation_data(act_pmau_data),
        .activation_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane7_valid), .activation_ready(pmau8_activation_ready), .input_ready(pmau8_input_ready), .activation_last(feed_last_r),
        .weight_data(weight_quad7_pmau_data), .scale_factor(cfg_scale), .weight_valid((state_r == S_RUN) && pmau_offer_valid && pair_lane7_valid), .weight_ready(pmau8_weight_ready), .weight_last(feed_last_r),
        .scalar_axpy(16'd0), .result_data(pmau8_result_data), .result_valid(pmau8_result_valid), .result_ready(pmau8_result_ready), .result_last());

    VPU_Result_Requantizer #(
        .ACC_WIDTH   (ACC_WIDTH),
        .SHIFT_WIDTH (5)
    ) u_result_requantizer (
        .value_in       (result_requant_value_r),
        .requant_shift  (result_requant_shift),
        .value_out      (pmau_result_i8)
    );

    wire [15:0] wr_cfg_col_beats =
        (cfg_col_beats != 16'd0) ? cfg_col_beats : auto_col_beats;

    wire weight_div_input_valid =
        wr_pipe_en_r && (wr_pipe_region_r == REGION_WEIGHT) &&
        (wr_pipe_col_beats_r != 16'd0) &&
        (wr_pipe_col_beats_r <= MAX_COL_BEATS_16);
    wire [7:0] weight_div_s0_trial = {7'd0, wr_pipe_index_r[14]};
    wire weight_div_s0_ge =
        (weight_div_s0_trial >= wr_pipe_col_beats_r[7:0]);

    always @(posedge CLK) begin
        if (!RST) begin
            weight_div_valid_r[0] <= 1'b0;
            weight_div_rem_r[0] <= 8'd0;
            weight_div_pair_r[0] <= 14'd0;
            weight_div_q_r[0] <= 14'd0;
            weight_div_col_beats_r[0] <= 16'd0;
            weight_div_parity_r[0] <= 1'b0;
            weight_div_bank_r[0] <= 1'b0;
            weight_div_data_r[0] <= {AXI_DATA_WIDTH{1'b0}};
            weight_div_strb_r[0] <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            weight_div_valid_r[0] <= weight_div_input_valid;
            weight_div_rem_r[0] <= weight_div_s0_ge ?
                (weight_div_s0_trial - wr_pipe_col_beats_r[7:0]) :
                weight_div_s0_trial;
            weight_div_pair_r[0] <= weight_div_s0_ge ? 14'h2000 : 14'd0;
            weight_div_q_r[0] <= wr_pipe_index_r[14:1];
            weight_div_col_beats_r[0] <= wr_pipe_col_beats_r;
            weight_div_parity_r[0] <= wr_pipe_index_r[0];
            weight_div_bank_r[0] <= wr_pipe_bank_r;
            weight_div_data_r[0] <= wr_pipe_data_r;
            weight_div_strb_r[0] <= wr_pipe_strb_r;
        end
    end

    genvar weight_div_stage_g;
    generate
        for (weight_div_stage_g = 1; weight_div_stage_g < WEIGHT_DIV_STAGES;
             weight_div_stage_g = weight_div_stage_g + 1) begin : GEN_WEIGHT_DIV
            localparam integer DIV_Q_BIT = WEIGHT_DIV_STAGES - 1 - weight_div_stage_g;
            localparam [13:0] DIV_QUOT_BIT = (14'd1 << DIV_Q_BIT);
            wire [7:0] div_trial =
                {weight_div_rem_r[weight_div_stage_g-1][6:0],
                 weight_div_q_r[weight_div_stage_g-1][DIV_Q_BIT]};
            wire div_ge =
                (div_trial >= weight_div_col_beats_r[weight_div_stage_g-1][7:0]);

            always @(posedge CLK) begin
                if (!RST) begin
                    weight_div_valid_r[weight_div_stage_g] <= 1'b0;
                    weight_div_rem_r[weight_div_stage_g] <= 8'd0;
                    weight_div_pair_r[weight_div_stage_g] <= 14'd0;
                    weight_div_q_r[weight_div_stage_g] <= 14'd0;
                    weight_div_col_beats_r[weight_div_stage_g] <= 16'd0;
                    weight_div_parity_r[weight_div_stage_g] <= 1'b0;
                    weight_div_bank_r[weight_div_stage_g] <= 1'b0;
                    weight_div_data_r[weight_div_stage_g] <= {AXI_DATA_WIDTH{1'b0}};
                    weight_div_strb_r[weight_div_stage_g] <=
                        {(AXI_DATA_WIDTH/8){1'b0}};
                end else begin
                    weight_div_valid_r[weight_div_stage_g] <=
                        weight_div_valid_r[weight_div_stage_g-1];
                    weight_div_rem_r[weight_div_stage_g] <= div_ge ?
                        (div_trial -
                         weight_div_col_beats_r[weight_div_stage_g-1][7:0]) :
                        div_trial;
                    weight_div_pair_r[weight_div_stage_g] <= div_ge ?
                        (weight_div_pair_r[weight_div_stage_g-1] | DIV_QUOT_BIT) :
                        weight_div_pair_r[weight_div_stage_g-1];
                    weight_div_q_r[weight_div_stage_g] <=
                        weight_div_q_r[weight_div_stage_g-1];
                    weight_div_col_beats_r[weight_div_stage_g] <=
                        weight_div_col_beats_r[weight_div_stage_g-1];
                    weight_div_parity_r[weight_div_stage_g] <=
                        weight_div_parity_r[weight_div_stage_g-1];
                    weight_div_bank_r[weight_div_stage_g] <=
                        weight_div_bank_r[weight_div_stage_g-1];
                    weight_div_data_r[weight_div_stage_g] <=
                        weight_div_data_r[weight_div_stage_g-1];
                    weight_div_strb_r[weight_div_stage_g] <=
                        weight_div_strb_r[weight_div_stage_g-1];
                end
            end
        end
    endgenerate

    always @(posedge CLK) begin
        if (!RST) begin
            weight_map_delta_valid_r <= 1'b0;
            weight_map_delta_r <= 14'd0;
            weight_map_delta_pair_r <= 14'd0;
            weight_map_delta_rem_r <= 8'd0;
            weight_map_delta_col_beats_r <= 16'd0;
            weight_map_delta_parity_r <= 1'b0;
            weight_map_delta_bank_r <= 1'b0;
            weight_map_delta_data_r <= {AXI_DATA_WIDTH{1'b0}};
            weight_map_delta_strb_r <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            weight_map_delta_valid_r <= weight_div_valid_r[WEIGHT_DIV_STAGES-1];
            if (weight_div_valid_r[WEIGHT_DIV_STAGES-1]) begin
                weight_map_delta_r <=
                    weight_div_q_r[WEIGHT_DIV_STAGES-1] -
                    weight_div_rem_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_pair_r <= weight_div_pair_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_rem_r <= weight_div_rem_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_col_beats_r <=
                    weight_div_col_beats_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_parity_r <= weight_div_parity_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_bank_r <= weight_div_bank_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_data_r <= weight_div_data_r[WEIGHT_DIV_STAGES-1];
                weight_map_delta_strb_r <= weight_div_strb_r[WEIGHT_DIV_STAGES-1];
            end
        end
    end

    always @(posedge CLK) begin
        if (!RST) begin
            weight_map_base_valid_r <= 1'b0;
            weight_map_base_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            weight_map_base_rem_r <= 8'd0;
            weight_map_base_pair_mod4_r <= 2'd0;
            weight_map_base_parity_r <= 1'b0;
            weight_map_base_bank_r <= 1'b0;
            weight_map_base_data_r <= {AXI_DATA_WIDTH{1'b0}};
            weight_map_base_strb_r <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            weight_map_base_valid_r <= weight_map_delta_valid_r;
            if (weight_map_delta_valid_r) begin
                weight_map_base_r <=
                    (weight_map_delta_r -
                     (weight_map_delta_pair_r[1] ? {weight_map_delta_col_beats_r[12:0],1'b0} : 14'd0) -
                     (weight_map_delta_pair_r[0] ? weight_map_delta_col_beats_r[13:0] : 14'd0)) >> 2;
                weight_map_base_rem_r <= weight_map_delta_rem_r;
                weight_map_base_pair_mod4_r <= weight_map_delta_pair_r[1:0];
                weight_map_base_parity_r <= weight_map_delta_parity_r;
                weight_map_base_bank_r <= weight_map_delta_bank_r;
                weight_map_base_data_r <= weight_map_delta_data_r;
                weight_map_base_strb_r <= weight_map_delta_strb_r;
            end
        end
    end

    always @(posedge CLK) begin
        if (!RST) begin
            weight_map_valid_r <= 1'b0;
            weight_map_row_slot_r <= 3'd0;
            weight_map_local_addr_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            weight_map_bank_r <= 1'b0;
            weight_map_data_r <= {AXI_DATA_WIDTH{1'b0}};
            weight_map_strb_r <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            weight_map_valid_r <= weight_map_base_valid_r;
            if (weight_map_base_valid_r) begin
                weight_map_row_slot_r <= {weight_map_base_pair_mod4_r,
                                          weight_map_base_parity_r};
                weight_map_local_addr_r <= weight_map_base_r +
                                           weight_map_base_rem_r;
                weight_map_bank_r <= weight_map_base_bank_r;
                weight_map_data_r <= weight_map_base_data_r;
                weight_map_strb_r <= weight_map_base_strb_r;
            end
        end
    end

    integer wr_bank_i;
    integer wr_top_bank_i;
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
            wr_pipe_col_beats_r <= 16'd0;
            wr_pipe_data_r   <= {AXI_DATA_WIDTH{1'b0}};
            wr_pipe_strb_r   <= {(AXI_DATA_WIDTH/8){1'b0}};
            for (wr_top_bank_i = 0; wr_top_bank_i < BANK_COUNT; wr_top_bank_i = wr_top_bank_i + 1) begin
                weight_leaf_stage_valid_r[wr_top_bank_i] <= 1'b0;
                weight_leaf_stage_row_slot_r[wr_top_bank_i] <= 3'd0;
                weight_leaf_stage_addr_r[wr_top_bank_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                weight_leaf_stage_data_r[wr_top_bank_i] <= {AXI_DATA_WIDTH{1'b0}};
                weight_leaf_stage_strb_r[wr_top_bank_i] <= {(AXI_DATA_WIDTH/8){1'b0}};
            end
            for (wr_ram_i = 0; wr_ram_i < WEIGHT_RAM_TOTAL; wr_ram_i = wr_ram_i + 1) begin
                weight_wr_addr_leaf[wr_ram_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                weight_wr_en_leaf[wr_ram_i]   <= 1'b0;
                weight_wr_data_leaf[wr_ram_i] <= {WEIGHT_BANK_WIDTH{1'b0}};
                weight_wr_strb_leaf[wr_ram_i] <= {WEIGHT_BANK_BYTES{1'b0}};
            end
        end else begin
            wr_pipe_en_r <= mm_wr_en && !pair_active_write_block;
            if (mm_wr_en && !pair_active_write_block) begin
                wr_pipe_region_r <= mm_wr_region;
                wr_pipe_index_r  <= mm_wr_index;
                wr_pipe_bank_r   <= cfg_wr_bank;
                wr_pipe_col_beats_r <= wr_cfg_col_beats;
                wr_pipe_data_r   <= mm_wr_data;
                wr_pipe_strb_r   <= mm_wr_strb;
            end

            for (wr_top_bank_i = 0; wr_top_bank_i < BANK_COUNT; wr_top_bank_i = wr_top_bank_i + 1)
                weight_leaf_stage_valid_r[wr_top_bank_i] <= 1'b0;
            if (weight_map_valid_r) begin
                weight_leaf_stage_valid_r[weight_map_bank_r] <= 1'b1;
                weight_leaf_stage_row_slot_r[weight_map_bank_r] <= weight_map_row_slot_r;
                weight_leaf_stage_addr_r[weight_map_bank_r] <= weight_map_local_addr_r;
                weight_leaf_stage_data_r[weight_map_bank_r] <= weight_map_data_r;
                weight_leaf_stage_strb_r[weight_map_bank_r] <= weight_map_strb_r;
            end

            for (wr_ram_i = 0; wr_ram_i < WEIGHT_RAM_TOTAL; wr_ram_i = wr_ram_i + 1)
                weight_wr_en_leaf[wr_ram_i] <= 1'b0;

            for (wr_top_bank_i = 0; wr_top_bank_i < BANK_COUNT; wr_top_bank_i = wr_top_bank_i + 1) begin
                for (wr_bank_i = 0; wr_bank_i < WEIGHT_BANKS; wr_bank_i = wr_bank_i + 1) begin
                    if (weight_leaf_stage_valid_r[wr_top_bank_i]) begin
                        weight_wr_addr_leaf[wr_top_bank_i*WEIGHT_RAM_COUNT +
                                             wr_bank_i*WEIGHT_ROW_SLOT_LEAVES +
                                             weight_leaf_stage_row_slot_r[wr_top_bank_i]]
                            <= weight_leaf_stage_addr_r[wr_top_bank_i];
                        weight_wr_en_leaf[wr_top_bank_i*WEIGHT_RAM_COUNT +
                                           wr_bank_i*WEIGHT_ROW_SLOT_LEAVES +
                                           weight_leaf_stage_row_slot_r[wr_top_bank_i]]
                            <= 1'b1;
                        weight_wr_data_leaf[wr_top_bank_i*WEIGHT_RAM_COUNT +
                                             wr_bank_i*WEIGHT_ROW_SLOT_LEAVES +
                                             weight_leaf_stage_row_slot_r[wr_top_bank_i]]
                            <= weight_leaf_stage_data_r[wr_top_bank_i][WEIGHT_BANK_WIDTH*wr_bank_i +: WEIGHT_BANK_WIDTH];
                        weight_wr_strb_leaf[wr_top_bank_i*WEIGHT_RAM_COUNT +
                                             wr_bank_i*WEIGHT_ROW_SLOT_LEAVES +
                                             weight_leaf_stage_row_slot_r[wr_top_bank_i]]
                            <= weight_leaf_stage_strb_r[wr_top_bank_i][WEIGHT_BANK_BYTES*wr_bank_i +: WEIGHT_BANK_BYTES];
                    end
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
    integer result_lane_i;
    always @* begin
        result_wr_data   = {AXI_DATA_WIDTH{1'b0}};
        result_wr_strobe = {(AXI_DATA_WIDTH/8){1'b0}};
        if (result_writeback_fire) begin
            if (result_write_is_i8_r) begin
                result_wr_data[8*result_write_lane_r +: 8] = result_write_i8_r;
                result_wr_strobe[result_write_lane_r] = 1'b1;
            end else begin
                result_wr_data[ACC_WIDTH*result_write_lane_r[RESULT_LANE_SHIFT-1:0] +: ACC_WIDTH] =
                    result_write_i32_r;
                result_wr_strobe[RESULT_BYTE_COUNT*result_write_lane_r[RESULT_LANE_SHIFT-1:0] +: RESULT_BYTE_COUNT] =
                    {RESULT_BYTE_COUNT{1'b1}};
            end
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

    genvar weight_top_bank_g;
    genvar weight_bank_g;
    genvar weight_row_slot_g;
    generate
        for (weight_top_bank_g = 0; weight_top_bank_g < BANK_COUNT;
             weight_top_bank_g = weight_top_bank_g + 1) begin : GEN_WEIGHT_TOP_BANK
            for (weight_bank_g = 0; weight_bank_g < WEIGHT_BANKS;
                 weight_bank_g = weight_bank_g + 1) begin : GEN_WEIGHT_BANK
                 for (weight_row_slot_g = 0; weight_row_slot_g < WEIGHT_ROW_SLOT_LEAVES;
                      weight_row_slot_g = weight_row_slot_g + 1) begin : GEN_WEIGHT_ROW_SLOT
                     localparam integer WEIGHT_RAM_INDEX =
                         weight_top_bank_g * WEIGHT_RAM_COUNT +
                         weight_bank_g * WEIGHT_ROW_SLOT_LEAVES + weight_row_slot_g;
                     localparam integer WEIGHT_COMPUTE_ADDR_INDEX =
                         weight_top_bank_g * WEIGHT_BANKS + weight_bank_g;
                    Dual_Port_BRAM #(
                        .AWIDTH (WEIGHT_LOCAL_ADDR_WIDTH),
                        .DWIDTH (WEIGHT_BANK_WIDTH),
                        .OUTPUT_REG (1),
                        .USE_URAM (1)
                    ) u_weight_bram_bank (
                        .clka  (CLK),
                        .ena   (weight_wr_en_leaf[WEIGHT_RAM_INDEX]),
                        .wea   (weight_wr_strb_leaf[WEIGHT_RAM_INDEX]),
                        .addra (weight_wr_addr_leaf[WEIGHT_RAM_INDEX]),
                        .dina  (weight_wr_data_leaf[WEIGHT_RAM_INDEX]),
                        .douta (),
                        .clkb  (CLK),
                        .enb   (weight_compute_en_leaf[WEIGHT_RAM_INDEX]),
                        .web   ({WEIGHT_BANK_BYTES{1'b0}}),
                        .addrb (weight_compute_addr_shared[WEIGHT_COMPUTE_ADDR_INDEX]),
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
        weight_quad2_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        weight_quad3_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        weight_quad4_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        weight_quad5_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        weight_quad6_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        weight_quad7_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        for (mux_bank_i = 0; mux_bank_i < WEIGHT_BANKS; mux_bank_i = mux_bank_i + 1) begin
            weight_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[
                    WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT +
                                        mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_row_slot_x_r)
                    +: WEIGHT_BANK_WIDTH
                ];
            weight_pair_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[
                    WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT +
                                        mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_pair_row_slot_x_r)
                    +: WEIGHT_BANK_WIDTH
                ];
            weight_quad2_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[
                    WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT +
                                        mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad2_row_slot_x_r)
                    +: WEIGHT_BANK_WIDTH
                ];
            weight_quad3_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad3_row_slot_x_r) +: WEIGHT_BANK_WIDTH];
            weight_quad4_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad4_row_slot_x_r) +: WEIGHT_BANK_WIDTH];
            weight_quad5_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad5_row_slot_x_r) +: WEIGHT_BANK_WIDTH];
            weight_quad6_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad6_row_slot_x_r) +: WEIGHT_BANK_WIDTH];
        end
        case (active_bank_r)
            1'b0: begin
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*0 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(0*WEIGHT_RAM_COUNT + 0*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[0]) +: WEIGHT_BANK_WIDTH];
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*1 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(0*WEIGHT_RAM_COUNT + 1*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[1]) +: WEIGHT_BANK_WIDTH];
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*2 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(0*WEIGHT_RAM_COUNT + 2*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[2]) +: WEIGHT_BANK_WIDTH];
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*3 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(0*WEIGHT_RAM_COUNT + 3*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[3]) +: WEIGHT_BANK_WIDTH];
            end
            default: begin
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*0 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(1*WEIGHT_RAM_COUNT + 0*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[4]) +: WEIGHT_BANK_WIDTH];
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*1 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(1*WEIGHT_RAM_COUNT + 1*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[5]) +: WEIGHT_BANK_WIDTH];
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*2 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(1*WEIGHT_RAM_COUNT + 2*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[6]) +: WEIGHT_BANK_WIDTH];
                weight_quad7_compute_data[WEIGHT_BANK_WIDTH*3 +: WEIGHT_BANK_WIDTH] = weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(1*WEIGHT_RAM_COUNT + 3*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_local_r[7]) +: WEIGHT_BANK_WIDTH];
            end
        endcase
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
                .ena   (result_rd_hit && (rd_pipe_bank_r == result_bank_g)),
                .wea   ({(AXI_DATA_WIDTH/8){1'b0}}),
                .addra (rd_pipe_index_r[RESULT_ADDR_WIDTH-1:0]),
                .dina  ({AXI_DATA_WIDTH{1'b0}}),
                .douta (result_cpu_rd_data_bank[AXI_DATA_WIDTH*result_bank_g +: AXI_DATA_WIDTH]),
                .clkb  (CLK),
                .enb   (result_writeback_fire && (active_bank_r == result_bank_g)),
                .web   (result_wr_strobe),
                .addrb (result_write_addr_bank_r[result_bank_g]),
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
            row_lane_valid_r    <= 8'b00000001;
            read_beat_idx_r     <= 16'd0;
            block_idx_r          <= 16'd0;
            issue_block_idx_r    <= 16'd0;
            raw_burst_blocks_r   <= 4'd0;
            raw_burst_retired_r  <= 4'd0;
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
            pair_mode_r <= 1'b0;
            result_row1_data_r <= {ACC_WIDTH{1'b0}};
            result_row2_data_r <= {ACC_WIDTH{1'b0}};
            result_row3_data_r <= {ACC_WIDTH{1'b0}};
            result_row4_data_r <= {ACC_WIDTH{1'b0}}; result_row5_data_r <= {ACC_WIDTH{1'b0}};
            result_row6_data_r <= {ACC_WIDTH{1'b0}}; result_row7_data_r <= {ACC_WIDTH{1'b0}};
            result_row1_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_row2_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_row3_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_row4_addr_r <= {RESULT_ADDR_WIDTH{1'b0}}; result_row5_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_row6_addr_r <= {RESULT_ADDR_WIDTH{1'b0}}; result_row7_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_row1_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_row2_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_row3_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_row4_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}}; result_row5_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_row6_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}}; result_row7_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_write_slot_r <= 3'd0;
            result_writes_done_r <= 1'b0;
            raw_bundle_accepted_r <= 1'b0;
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
            spu_raw_scale_index <= 32'd0;
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
            spu_raw_pair_scale_index <= 32'd0;
            spu_raw_lane_valid <= 8'd0;
            spu_raw_lane_data <= 256'd0;
            spu_raw_lane_row <= 128'd0;
            spu_raw_lane_scale_index <= 256'd0;
            feed_valid_r        <= 1'b0;
            feed_last_r         <= 1'b0;
            feed_group_last_r   <= 1'b0;
            read_req_valid_r    <= 1'b0;
            read_req_act_addr_r <= {ACT_ADDR_WIDTH{1'b0}};
            read_req_weight_addr_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            read_req_row_slot_r <= 3'd0;
            read_req_pair_row_slot_r <= 3'd0;
            read_req_quad2_row_slot_r <= 3'd0;
            read_req_quad3_row_slot_r <= 3'd0;
            read_req_quad4_row_slot_r <= 3'd0; read_req_quad5_row_slot_r <= 3'd0;
            read_req_quad6_row_slot_r <= 3'd0; read_req_quad7_row_slot_r <= 3'd0;
            read_req_last_r     <= 1'b0;
            read_req_group_last_r <= 1'b0;
            read_valid_d_r      <= 1'b0;
            read_last_d_r       <= 1'b0;
            read_group_last_d_r <= 1'b0;
            read_bank_d_r       <= 1'b0;
            read_valid_q_r      <= 1'b0;
            read_last_q_r       <= 1'b0;
            read_group_last_q_r <= 1'b0;
            read_bank_q_r       <= 1'b0;
            read_valid_x_r      <= 1'b0;
            read_last_x_r       <= 1'b0;
            read_group_last_x_r <= 1'b0;
            read_bank_x_r       <= 1'b0;
            read_row_slot_d_r      <= 2'd0;
            read_row_slot_q_r      <= 2'd0;
            read_row_slot_x_r      <= 2'd0;
            read_pair_row_slot_d_r <= 3'd0;
            read_pair_row_slot_q_r <= 3'd0;
            read_pair_row_slot_x_r <= 3'd0;
            read_quad2_row_slot_d_r <= 3'd0;
            read_quad2_row_slot_q_r <= 3'd0;
            read_quad2_row_slot_x_r <= 3'd0;
            read_quad3_row_slot_d_r <= 3'd0;
            read_quad3_row_slot_q_r <= 3'd0;
            read_quad3_row_slot_x_r <= 3'd0;
            read_quad4_row_slot_d_r <= 3'd0; read_quad4_row_slot_q_r <= 3'd0; read_quad4_row_slot_x_r <= 3'd0;
            read_quad5_row_slot_d_r <= 3'd0; read_quad5_row_slot_q_r <= 3'd0; read_quad5_row_slot_x_r <= 3'd0;
            read_quad6_row_slot_d_r <= 3'd0; read_quad6_row_slot_q_r <= 3'd0; read_quad6_row_slot_x_r <= 3'd0;
            read_quad7_row_slot_d_r <= 3'd0; read_quad7_row_slot_q_r <= 3'd0; read_quad7_row_slot_x_r <= 3'd0;
            compute_rd_en       <= 1'b0;
            act_compute_addr    <= {ACT_ADDR_WIDTH{1'b0}};
            for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_COMPUTE_ADDR_COUNT; fsm_bank_i = fsm_bank_i + 1)
                weight_compute_addr_shared[fsm_bank_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            for (fsm_bank_i = 0; fsm_bank_i < BANK_COUNT; fsm_bank_i = fsm_bank_i + 1)
                result_write_addr_bank_r[fsm_bank_i] <= {RESULT_ADDR_WIDTH{1'b0}};
            for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_COMPUTE_ADDR_COUNT; fsm_bank_i = fsm_bank_i + 1)
                read_quad7_row_slot_local_r[fsm_bank_i] <= 3'd0;
            for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                raw_group_offset_r[fsm_bank_i] <= 32'd0;
            for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                raw_lane_result_index_r[fsm_bank_i] <= 32'd0;
            raw_row_base_advance_r <= 32'd0;
            for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_TOTAL; fsm_ram_i = fsm_ram_i + 1) begin
                weight_compute_en_leaf[fsm_ram_i]   <= 1'b0;
            end
            act_pmau_data       <= {ACT_BEAT_WIDTH{1'b0}};
            weight_pmau_data    <= {WEIGHT_BEAT_WIDTH{1'b0}};
            weight_pair_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};
            weight_quad2_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};
            weight_quad3_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};
            weight_quad4_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}}; weight_quad5_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};
            weight_quad6_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}}; weight_quad7_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};
        end else begin
            compute_rd_en  <= 1'b0;
            result_accum_rd_en_r <= 1'b0;
            result_write_pending_r <= 1'b0;
            result_requant_pending_r <= 1'b0;
            spu_raw_done  <= 1'b0;
            if (result_accum_rd_en_r)
                result_accum_rd_data_r <= result_accum_mem[result_accum_rd_addr_r];
            for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_TOTAL; fsm_ram_i = fsm_ram_i + 1) begin
                weight_compute_en_leaf[fsm_ram_i] <= 1'b0;
            end
            if (shift_req_to_d)
                read_req_valid_r <= 1'b0;
            if (shift_d_to_q) begin
                read_valid_d_r <= 1'b0;
                read_group_last_d_r <= 1'b0;
            end

            if (read_shift_addr_fire) begin
                for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1) begin
                    weight_compute_addr_shared[active_bank_r*WEIGHT_BANKS + fsm_bank_i]
                        <= read_req_weight_addr_r;
                end
                for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1) begin
                    weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                           fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_row_slot_r]
                        <= 1'b1;
                    if (pair_lane1_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                               fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_pair_row_slot_r]
                            <= 1'b1;
                    end
                    if (pair_lane2_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                               fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad2_row_slot_r]
                            <= 1'b1;
                    end
                    if (pair_lane3_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +
                                               fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad3_row_slot_r]
                            <= 1'b1;
                    end
                    if (pair_lane4_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad4_row_slot_r] <= 1'b1;
                    end
                    if (pair_lane5_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad5_row_slot_r] <= 1'b1;
                    end
                    if (pair_lane6_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad6_row_slot_r] <= 1'b1;
                    end
                    if (pair_lane7_valid) begin
                        weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad7_row_slot_r] <= 1'b1;
                    end
                end
            end

            if (weight_compute_final_clear) begin
                for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_TOTAL; fsm_ram_i = fsm_ram_i + 1)
                    weight_compute_en_leaf[fsm_ram_i] <= 1'b0;
            end

            if (ctrl_clear_done) begin
                done_r  <= 1'b0;
                error_r <= 1'b0;
            end
            if (pair_active_input_write_reject)
                error_r <= 1'b1;

            case (state_r)
                S_IDLE: begin
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
                    issue_block_idx_r  <= 16'd0;
                    raw_burst_blocks_r <= 4'd0;
                    raw_burst_retired_r <= 4'd0;
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
                    feed_valid_r <= 1'b0;
                    if (active_config_invalid) begin
                        error_r <= 1'b1;
                        done_r  <= 1'b1;
                        done_bank_r <= active_bank_r;
                        done_job_id_r <= active_job_id_r;
                        state_r <= S_ERROR;
                    end else if (!active_bank_weight_write_pipeline_busy) begin
                        row_lane_valid_r <= make_row_lane_valid(
                            16'd0, active_rows_r, pair_mode_r);
                        raw_group_offset_r[0] <= 32'd0;
                        raw_group_offset_r[1] <= {16'd0,group_blocks_r};
                        raw_group_offset_r[2] <= ({16'd0,group_blocks_r} << 1);
                        raw_group_offset_r[3] <= ({16'd0,group_blocks_r} * 3);
                        raw_group_offset_r[4] <= ({16'd0,group_blocks_r} << 2);
                        raw_group_offset_r[5] <= ({16'd0,group_blocks_r} * 5);
                        raw_group_offset_r[6] <= ({16'd0,group_blocks_r} * 6);
                        raw_group_offset_r[7] <= ({16'd0,group_blocks_r} * 7);
                        raw_lane_result_index_r[0] <= 32'd0;
                        raw_lane_result_index_r[1] <= {16'd0,group_blocks_r};
                        raw_lane_result_index_r[2] <= ({16'd0,group_blocks_r} << 1);
                        raw_lane_result_index_r[3] <= ({16'd0,group_blocks_r} * 3);
                        raw_lane_result_index_r[4] <= ({16'd0,group_blocks_r} << 2);
                        raw_lane_result_index_r[5] <= ({16'd0,group_blocks_r} * 5);
                        raw_lane_result_index_r[6] <= ({16'd0,group_blocks_r} * 6);
                        raw_lane_result_index_r[7] <= ({16'd0,group_blocks_r} * 7);
                        raw_row_base_advance_r <= pair_mode_r ?
                                                  ({16'd0,group_blocks_r} << 3) :
                                                  {16'd0,group_blocks_r};
                        state_r <= S_RUN;
                    end
                end

                S_RUN: begin
                    if (pmau_input_fire)
                        feed_valid_r <= 1'b0;

                    if (consume_read_x) begin
                        feed_valid_r <= 1'b1;
                        feed_last_r  <= read_last_x_r;
                        feed_group_last_r <= read_group_last_x_r;
                        act_pmau_data    <= act_compute_data;
                        weight_pmau_data <= weight_compute_data;
                        weight_pair_pmau_data <= weight_pair_compute_data;
                        weight_quad2_pmau_data <= weight_quad2_compute_data;
                        weight_quad3_pmau_data <= weight_quad3_compute_data;
                        weight_quad4_pmau_data <= weight_quad4_compute_data;
                        weight_quad5_pmau_data <= weight_quad5_compute_data;
                        weight_quad6_pmau_data <= weight_quad6_compute_data;
                        weight_quad7_pmau_data <= weight_quad7_compute_data;
                        read_valid_x_r <= 1'b0;
                    end

                    if (shift_q_to_x) begin
                        read_valid_x_r <= 1'b1;
                        read_last_x_r  <= read_last_q_r;
                        read_group_last_x_r <= read_group_last_q_r;
                        read_bank_x_r <= read_bank_q_r;
                        read_row_slot_x_r <= read_row_slot_q_r;
                        read_pair_row_slot_x_r <= read_pair_row_slot_q_r;
                        read_quad2_row_slot_x_r <= read_quad2_row_slot_q_r;
                        read_quad3_row_slot_x_r <= read_quad3_row_slot_q_r;
                        read_quad4_row_slot_x_r <= read_quad4_row_slot_q_r;
                        read_quad5_row_slot_x_r <= read_quad5_row_slot_q_r;
                        read_quad6_row_slot_x_r <= read_quad6_row_slot_q_r;
                        read_quad7_row_slot_x_r <= read_quad7_row_slot_q_r;
                        for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_COMPUTE_ADDR_COUNT; fsm_bank_i = fsm_bank_i + 1)
                            read_quad7_row_slot_local_r[fsm_bank_i] <= read_quad7_row_slot_q_r;
                        read_valid_q_r <= 1'b0;
                    end

                    if (shift_d_to_q) begin
                        read_valid_q_r <= 1'b1;
                        read_last_q_r  <= read_last_d_r;
                        read_group_last_q_r <= read_group_last_d_r;
                        read_bank_q_r <= read_bank_d_r;
                        read_row_slot_q_r <= read_row_slot_d_r;
                        read_pair_row_slot_q_r <= read_pair_row_slot_d_r;
                        read_quad2_row_slot_q_r <= read_quad2_row_slot_d_r;
                        read_quad3_row_slot_q_r <= read_quad3_row_slot_d_r;
                        read_quad4_row_slot_q_r <= read_quad4_row_slot_d_r;
                        read_quad5_row_slot_q_r <= read_quad5_row_slot_d_r;
                        read_quad6_row_slot_q_r <= read_quad6_row_slot_d_r;
                        read_quad7_row_slot_q_r <= read_quad7_row_slot_d_r;
                    end

                    if (shift_req_to_d) begin
                        compute_rd_en       <= 1'b1;
                        act_compute_addr    <= read_req_act_addr_r;
                        read_bank_d_r       <= active_bank_r;
                        read_valid_d_r      <= 1'b1;
                        read_last_d_r       <= read_req_last_r;
                        read_group_last_d_r <= read_req_group_last_r;
                        read_row_slot_d_r      <= read_req_row_slot_r;
                        read_pair_row_slot_d_r <= read_req_pair_row_slot_r;
                        read_quad2_row_slot_d_r <= read_req_quad2_row_slot_r;
                        read_quad3_row_slot_d_r <= read_req_quad3_row_slot_r;
                        read_quad4_row_slot_d_r <= read_req_quad4_row_slot_r;
                        read_quad5_row_slot_d_r <= read_req_quad5_row_slot_r;
                        read_quad6_row_slot_d_r <= read_req_quad6_row_slot_r;
                        read_quad7_row_slot_d_r <= read_req_quad7_row_slot_r;
                    end

                    if (can_issue_read) begin
                        read_req_valid_r      <= 1'b1;
                        read_req_act_addr_r   <= read_abs_beat[ACT_ADDR_WIDTH-1:0];
                        read_req_weight_addr_r <= issue_weight_local_addr;
                        read_req_row_slot_r    <= issue_weight_row_slot;
                        read_req_pair_row_slot_r <= issue_pair_weight_row_slot;
                        read_req_quad2_row_slot_r <= issue_quad2_weight_row_slot;
                        read_req_quad3_row_slot_r <= issue_quad3_weight_row_slot;
                        read_req_quad4_row_slot_r <= issue_quad4_weight_row_slot;
                        read_req_quad5_row_slot_r <= issue_quad5_weight_row_slot;
                        read_req_quad6_row_slot_r <= issue_quad6_weight_row_slot;
                        read_req_quad7_row_slot_r <= issue_quad7_weight_row_slot;
                        read_req_last_r       <= issue_read_last;
                        read_req_group_last_r <= issue_read_group_last;
                        read_beat_idx_r       <= read_beat_idx_r + 16'd1;
                    end

                    if (pmau_input_fire && wait_after_feed) begin
                        if (raw_burst_mode) begin
                            if (p2_burst_continue) begin
                                // Preserve req/d/q/x/feed at intermediate Q8
                                // boundaries so the next block arrives without
                                // a local-memory refill bubble.
                                issue_block_idx_r  <= issue_block_idx_r + 16'd1;
                                raw_burst_blocks_r <= raw_burst_blocks_r + 4'd1;
                                state_r            <= S_RUN;
                            end else begin
                                // The eighth (or final short-burst) block is the
                                // only P2 boundary that flushes before retire.
                                // A simultaneously consumed read_x beat is the
                                // first beat of the next reservation.  Preserve
                                // it while clearing every upstream read stage.
                                compute_rd_en    <= 1'b0;
                                read_req_valid_r <= 1'b0;
                                read_valid_d_r   <= 1'b0;
                                read_valid_q_r   <= 1'b0;
                                read_valid_x_r   <= 1'b0;
                                raw_burst_blocks_r  <= raw_burst_blocks_r + 4'd1;
                                raw_burst_retired_r <= 4'd0;
                                state_r             <= S_WAIT_RESULT;
                            end
                        end else begin
                            feed_valid_r     <= 1'b0;
                            compute_rd_en    <= 1'b0;
                            read_req_valid_r <= 1'b0;
                            read_valid_d_r   <= 1'b0;
                            read_valid_q_r   <= 1'b0;
                            read_valid_x_r   <= 1'b0;
                            state_r           <= S_WAIT_RESULT;
                        end
                    end
                end

                S_WAIT_RESULT: begin
                    if (!raw_burst_mode)
                        feed_valid_r <= 1'b0;
                    if (pmau_result_fire) begin
                        if (result_i8_mode_r) begin
                            result_accum_rd_en_r <= 1'b1;
                            result_accum_rd_addr_r <= row_idx_r;
                            result_accum_pmau_r <= $signed(pmau_result_data);
                            result_accum_result_addr_r <= result_wr_addr;
                            result_accum_result_lane_r <= result_wr_lane;
                            result_accum_emit_r <= result_wr_index_ok && result_requant_capture;
                            result_accum_final_row_r <= ((row_idx_r + 16'd1) >= active_rows_r);
                            block_idx_r <= 16'd0;
                            state_r <= result_wr_index_ok ? S_ACCUM_WAIT : S_ERROR;
                        end else if (result_wr_index_ok &&
                                     (!pair_lane1_valid || (pair_result_value_index < MAX_RESULT_VALUES_32)) &&
                                     (!pair_lane2_valid || (quad2_result_value_index < MAX_RESULT_VALUES_32)) &&
                                     (!pair_lane3_valid || (quad3_result_value_index < MAX_RESULT_VALUES_32)) &&
                                     (!pair_lane4_valid || (quad4_result_value_index < MAX_RESULT_VALUES_32)) &&
                                     (!pair_lane5_valid || (quad5_result_value_index < MAX_RESULT_VALUES_32)) &&
                                     (!pair_lane6_valid || (quad6_result_value_index < MAX_RESULT_VALUES_32)) &&
                                     (!pair_lane7_valid || (quad7_result_value_index < MAX_RESULT_VALUES_32))) begin
                            if (raw_burst_mode) begin
                                result_write_pending_r <= 1'b0;
                                result_writes_done_r    <= 1'b1;
                                spu_raw_valid           <= 1'b1;
                            end else begin
                                result_write_pending_r <= 1'b1;
                                result_writes_done_r    <= 1'b0;
                                spu_raw_valid           <= 1'b0;
                            end
                            result_write_addr_r <= result_wr_addr;
                            result_write_addr_bank_r[active_bank_r] <= result_wr_addr;
                            result_write_lane_r <= result_wr_lane;
                            result_write_i32_r <= pmau_result_data;
                            result_write_is_i8_r <= 1'b0;
                            result_row1_data_r <= pmau2_result_data; result_row2_data_r <= pmau3_result_data;
                            result_row3_data_r <= pmau4_result_data; result_row4_data_r <= pmau5_result_data;
                            result_row5_data_r <= pmau6_result_data; result_row6_data_r <= pmau7_result_data;
                            result_row7_data_r <= pmau8_result_data;
                            result_row1_addr_r <= pair_result_wr_addr_i32; result_row2_addr_r <= quad2_result_wr_addr_i32;
                            result_row3_addr_r <= quad3_result_wr_addr_i32; result_row4_addr_r <= quad4_result_wr_addr_i32;
                            result_row5_addr_r <= quad5_result_wr_addr_i32; result_row6_addr_r <= quad6_result_wr_addr_i32;
                            result_row7_addr_r <= quad7_result_wr_addr_i32;
                            result_row1_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},pair_result_wr_lane_i32};
                            result_row2_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},quad2_result_wr_lane_i32};
                            result_row3_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},quad3_result_wr_lane_i32};
                            result_row4_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},quad4_result_wr_lane_i32};
                            result_row5_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},quad5_result_wr_lane_i32};
                            result_row6_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},quad6_result_wr_lane_i32};
                            result_row7_lane_r <= {{(RESULT_I8_LANE_SHIFT-RESULT_LANE_SHIFT){1'b0}},quad7_result_wr_lane_i32};
                            result_write_slot_r <= 3'd0;
                            raw_bundle_accepted_r <= 1'b0;

                            spu_raw_data <= $signed(pmau_result_data);
                            spu_raw_row <= row_idx_r;
                            spu_raw_block <= block_idx_r;
                            spu_raw_group_blocks <= group_blocks_r;
                            spu_raw_last_block <= ((block_idx_r + 16'd1) >= group_blocks_r);
                            spu_raw_clear_accum <= (block_idx_r == 16'd0);
                            spu_raw_job_id <= active_job_id_r;
                            spu_raw_bank <= active_bank_r;
                            spu_raw_scale_index <= result_value_index;
                            spu_raw_pair_valid <= pair_lane1_valid;
                            spu_raw_pair_data <= $signed(pmau2_result_data);
                            spu_raw_pair_row <= row_idx_r + 16'd1;
                            spu_raw_pair_block <= block_idx_r;
                            spu_raw_pair_group_blocks <= group_blocks_r;
                            spu_raw_pair_last_block <= ((block_idx_r + 16'd1) >= group_blocks_r);
                            spu_raw_pair_clear_accum <= (block_idx_r == 16'd0);
                            spu_raw_pair_job_id <= active_job_id_r;
                            spu_raw_pair_bank <= active_bank_r;
                            spu_raw_pair_scale_index <= pair_result_value_index;
                            spu_raw_lane_valid <= {pair_lane7_valid,pair_lane6_valid,pair_lane5_valid,pair_lane4_valid,
                                                   pair_lane3_valid,pair_lane2_valid,pair_lane1_valid,1'b1};
                            spu_raw_lane_data <= {pmau8_result_data,pmau7_result_data,pmau6_result_data,pmau5_result_data,
                                                  pmau4_result_data,pmau3_result_data,pmau2_result_data,pmau_result_data};
                            spu_raw_lane_row <= {row_idx_r+16'd7,row_idx_r+16'd6,row_idx_r+16'd5,row_idx_r+16'd4,
                                                 row_idx_r+16'd3,row_idx_r+16'd2,row_idx_r+16'd1,row_idx_r};
                            spu_raw_lane_scale_index <= {quad7_result_value_index,quad6_result_value_index,quad5_result_value_index,
                                                         quad4_result_value_index,quad3_result_value_index,quad2_result_value_index,
                                                         pair_result_value_index,result_value_index};
                            state_r <= S_RAW_STREAM_HOLD;
                        end else begin
                            error_r <= 1'b1;
                            state_r <= S_ERROR;
                        end
                    end
                end

                S_RAW_STREAM_HOLD: begin
                    if (!raw_burst_mode)
                        feed_valid_r <= 1'b0;
                    if (raw_burst_chain_pop) begin
                        // The current stream bundle and the next PMAU result
                        // retire on the same edge. Replace the output payload
                        // with block N+1 and keep valid asserted continuously.
                        raw_burst_retired_r <= raw_burst_retired_r + 4'd1;
                        block_idx_r <= block_idx_r + 16'd1;
                        for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                            raw_lane_result_index_r[fsm_bank_i] <=
                                raw_lane_result_index_r[fsm_bank_i] + 32'd1;

                        spu_raw_valid <= 1'b1;
                        spu_raw_data <= $signed(pmau_result_data);
                        spu_raw_block <= block_idx_r + 16'd1;
                        spu_raw_last_block <=
                            ((block_idx_r + 16'd2) >= group_blocks_r);
                        spu_raw_clear_accum <= 1'b0;
                        spu_raw_scale_index <= result_value_index + 32'd1;

                        spu_raw_pair_valid <= pair_lane1_valid;
                        spu_raw_pair_data <= $signed(pmau2_result_data);
                        spu_raw_pair_block <= block_idx_r + 16'd1;
                        spu_raw_pair_last_block <=
                            ((block_idx_r + 16'd2) >= group_blocks_r);
                        spu_raw_pair_clear_accum <= 1'b0;
                        spu_raw_pair_scale_index <= pair_result_value_index + 32'd1;

                        spu_raw_lane_valid <=
                            {pair_lane7_valid,pair_lane6_valid,pair_lane5_valid,pair_lane4_valid,
                             pair_lane3_valid,pair_lane2_valid,pair_lane1_valid,1'b1};
                        spu_raw_lane_data <=
                            {pmau8_result_data,pmau7_result_data,pmau6_result_data,pmau5_result_data,
                             pmau4_result_data,pmau3_result_data,pmau2_result_data,pmau_result_data};
                        spu_raw_lane_scale_index <=
                            {quad7_result_value_index + 32'd1,
                             quad6_result_value_index + 32'd1,
                             quad5_result_value_index + 32'd1,
                             quad4_result_value_index + 32'd1,
                             quad3_result_value_index + 32'd1,
                             quad2_result_value_index + 32'd1,
                             pair_result_value_index + 32'd1,
                             result_value_index + 32'd1};
                        raw_bundle_accepted_r <= 1'b0;
                    end else begin
                    if (result_writeback_fire) begin
                        case (result_write_slot_r)
                            3'd0: if (pair_lane1_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row1_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row1_addr_r; result_write_lane_r<=result_row1_lane_r; result_write_i32_r<=result_row1_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd1; end else result_writes_done_r<=1'b1;
                            3'd1: if (pair_lane2_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row2_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row2_addr_r; result_write_lane_r<=result_row2_lane_r; result_write_i32_r<=result_row2_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd2; end else result_writes_done_r<=1'b1;
                            3'd2: if (pair_lane3_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row3_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row3_addr_r; result_write_lane_r<=result_row3_lane_r; result_write_i32_r<=result_row3_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd3; end else result_writes_done_r<=1'b1;
                            3'd3: if (pair_lane4_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row4_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row4_addr_r; result_write_lane_r<=result_row4_lane_r; result_write_i32_r<=result_row4_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd4; end else result_writes_done_r<=1'b1;
                            3'd4: if (pair_lane5_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row5_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row5_addr_r; result_write_lane_r<=result_row5_lane_r; result_write_i32_r<=result_row5_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd5; end else result_writes_done_r<=1'b1;
                            3'd5: if (pair_lane6_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row6_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row6_addr_r; result_write_lane_r<=result_row6_lane_r; result_write_i32_r<=result_row6_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd6; end else result_writes_done_r<=1'b1;
                            3'd6: if (pair_lane7_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row7_addr_r; result_write_addr_bank_r[active_bank_r]<=result_row7_addr_r; result_write_lane_r<=result_row7_lane_r; result_write_i32_r<=result_row7_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd7; end else result_writes_done_r<=1'b1;
                            default: result_writes_done_r <= 1'b1;
                        endcase
                        spu_raw_valid <= 1'b1;
                    end
                    if (raw_stream_fire) begin
                        spu_raw_valid <= 1'b0;
                        spu_raw_pair_valid <= 1'b0;
                        spu_raw_lane_valid <= 8'd0;
                        raw_bundle_accepted_r <= 1'b1;
                    end
                    if (result_writes_done_r &&
                        (raw_bundle_accepted_r || raw_stream_fire)) begin
                        if (raw_burst_mode) begin
                            if ((raw_burst_retired_r + 4'd1) < raw_burst_blocks_r) begin
                                raw_burst_retired_r <= raw_burst_retired_r + 4'd1;
                                block_idx_r         <= block_idx_r + 16'd1;
                                for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                                    raw_lane_result_index_r[fsm_bank_i] <= raw_lane_result_index_r[fsm_bank_i] + 32'd1;
                                state_r             <= S_WAIT_RESULT;
                            end else begin
                                raw_burst_blocks_r  <= 4'd0;
                                raw_burst_retired_r <= 4'd0;
                                if ((issue_block_idx_r + 16'd1) < group_blocks_r) begin
                                    issue_block_idx_r <= issue_block_idx_r + 16'd1;
                                    block_idx_r       <= block_idx_r + 16'd1;
                                    for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                                        raw_lane_result_index_r[fsm_bank_i] <= raw_lane_result_index_r[fsm_bank_i] + 32'd1;
                                    state_r           <= S_RUN;
                                end else begin
                                    issue_block_idx_r <= 16'd0;
                                    block_idx_r       <= 16'd0;
                                    if ((row_idx_r + (pair_mode_r ? 16'd8 : 16'd1)) >= active_rows_r) begin
                                        state_r <= S_DRAIN_RESULT;
                                    end else begin
                                        row_idx_r <= row_idx_r + (pair_mode_r ? 16'd8 : 16'd1);
                                        row_lane_valid_r <= make_row_lane_valid(
                                            row_idx_r + (pair_mode_r ? 16'd8 : 16'd1),
                                            active_rows_r, pair_mode_r);
                                        read_beat_idx_r <= 16'd0;
                                        result_row_base_r <= result_row_base_r + raw_row_base_advance_r;
                                        for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                                            raw_lane_result_index_r[fsm_bank_i] <=
                                                result_row_base_r + raw_row_base_advance_r + raw_group_offset_r[fsm_bank_i];
                                        if (pair_mode_r || (row_idx_r[2:0] == 3'd7))
                                            weight_row_base_r <= weight_row_base_r + active_col_beats_r;
                                        state_r <= S_RUN;
                                    end
                                end
                            end
                        end else begin
                            if ((block_idx_r + 16'd1) < group_blocks_r) begin
                                block_idx_r <= block_idx_r + 16'd1;
                                for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                                    raw_lane_result_index_r[fsm_bank_i] <= raw_lane_result_index_r[fsm_bank_i] + 32'd1;
                                state_r <= S_RUN;
                            end else begin
                                block_idx_r <= 16'd0;
                                if ((row_idx_r + (pair_mode_r ? 16'd8 : 16'd1)) >= active_rows_r) begin
                                    state_r <= S_DRAIN_RESULT;
                                end else begin
                                    row_idx_r <= row_idx_r + (pair_mode_r ? 16'd8 : 16'd1);
                                    row_lane_valid_r <= make_row_lane_valid(
                                        row_idx_r + (pair_mode_r ? 16'd8 : 16'd1),
                                        active_rows_r, pair_mode_r);
                                    read_beat_idx_r <= 16'd0;
                                    result_row_base_r <= result_row_base_r + raw_row_base_advance_r;
                                    for (fsm_bank_i = 0; fsm_bank_i < 8; fsm_bank_i = fsm_bank_i + 1)
                                        raw_lane_result_index_r[fsm_bank_i] <=
                                            result_row_base_r + raw_row_base_advance_r + raw_group_offset_r[fsm_bank_i];
                                    if (pair_mode_r || (row_idx_r[2:0] == 3'd7))
                                        weight_row_base_r <= weight_row_base_r + active_col_beats_r;
                                    state_r <= S_RUN;
                                end
                            end
                        end
                    end
                    end
                end

                S_ACCUM_WAIT: begin
                    feed_valid_r <= 1'b0;
                    state_r <= S_ACCUM_ADD;
                end

                S_ACCUM_ADD: begin
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
                        if (row_idx_r[2:0] == 3'd7)
                            weight_row_base_r <= weight_row_base_r +
                                                 active_col_beats_r;
                        state_r           <= result_accum_emit_r ?
                                             S_REQUANT_RESULT : S_RUN;
                    end
                end

                S_REQUANT_RESULT: begin
                    feed_valid_r <= 1'b0;
                    if (result_requant_pending_r) begin
                        result_write_pending_r <= 1'b1;
                        result_write_addr_r    <= result_requant_addr_r;
                        result_write_addr_bank_r[active_bank_r] <= result_requant_addr_r;
                        result_write_lane_r    <= result_requant_lane_r;
                        result_write_i8_r      <= pmau_result_i8;
                        result_write_is_i8_r   <= 1'b1;

                        if (result_requant_final_r)
                            state_r <= S_DRAIN_RESULT;
                        else
                            state_r <= S_RUN;
                    end else begin
                        error_r <= 1'b1;
                        state_r <= S_ERROR;
                    end
                end

                S_DRAIN_RESULT: begin
                    feed_valid_r <= 1'b0;
                    done_r       <= 1'b1;
                    done_bank_r  <= active_bank_r;
                    done_job_id_r <= active_job_id_r;
                    spu_raw_done <= !result_i8_mode_r;
                    state_r      <= S_DONE;
                end

                S_DONE: begin
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
                        issue_block_idx_r   <= 16'd0;
                    raw_burst_blocks_r  <= 4'd0;
                    raw_burst_retired_r <= 4'd0;
                        result_row_base_r   <= 32'd0;
                        weight_row_base_r   <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                        state_r             <= S_VALIDATE;
                    end
                end

                S_ERROR: begin
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
                        issue_block_idx_r  <= 16'd0;
                    raw_burst_blocks_r <= 4'd0;
                    raw_burst_retired_r <= 4'd0;
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
