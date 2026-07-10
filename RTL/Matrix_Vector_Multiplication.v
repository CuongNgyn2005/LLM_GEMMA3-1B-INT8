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
 * - REGION_WEIGHT writes store flattened row-major weight beats.  New
 *   bitstreams use compact active-stride layout:
 *   row * active_col_beats + col_beat.
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
 * Production mode is INT8-result only.  PMAU still computes raw INT32 sums,
 * because INT8 dot products require a wide accumulator, but those sums never
 * leave the IP as the normal software-visible result.  Across split K-group
 * launches, compute_mode[2] clears the on-chip row accumulator for the first
 * group and compute_mode[3] emits the final requantized INT8 result for the
 * last group.  Sixteen INT8 results are packed into each 128-bit Result BRAM
 * word.
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
    input  wire [3:0]                        compute_mode,

    output wire                              busy,
    output wire                              done,
    output wire                              error,
    output wire [15:0]                       active_row,
    output wire [15:0]                       active_col_beat,

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
    // Split each 32-bit weight bank into 16K-word depth shards when the
    // configured matrix capacity grows beyond a single BRAM address range.
    // With the Phase 1A MAX_ROWS=256 and MAX_COL_BEATS=128 configuration, each
    // bank uses multiple shards.  Sharding keeps the logical MMIO address map
    // stable while allowing deeper weight storage.
    localparam WEIGHT_LOCAL_ADDR_WIDTH =
        (WEIGHT_ADDR_WIDTH > 14) ? 14 : WEIGHT_ADDR_WIDTH;
    localparam WEIGHT_SHARD_DEPTH      = (1 << WEIGHT_LOCAL_ADDR_WIDTH);
    localparam WEIGHT_DEPTH_SHARDS     =
        (WEIGHT_DEPTH + WEIGHT_SHARD_DEPTH - 1) / WEIGHT_SHARD_DEPTH;
    localparam WEIGHT_SHARD_SEL_WIDTH  =
        (WEIGHT_DEPTH_SHARDS > 1) ? clog2(WEIGHT_DEPTH_SHARDS) : 1;
    localparam WEIGHT_RAM_COUNT        = WEIGHT_BANKS * WEIGHT_DEPTH_SHARDS;
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

    localparam [2:0] S_IDLE         = 3'd0;
    localparam [2:0] S_RUN          = 3'd1;
    localparam [2:0] S_WAIT_RESULT  = 3'd2;
    localparam [2:0] S_DONE         = 3'd3;
    localparam [2:0] S_ERROR        = 3'd4;
    localparam [2:0] S_VALIDATE     = 3'd5;
    // Final-result handling is deliberately three stages: capture the INT32
    // accumulated value, requantize it to INT8, then commit Result BRAM.
    // This prevents the accumulator mux, saturation logic and BRAM routing
    // from forming one long routed path at 187.5 MHz.
    localparam [2:0] S_REQUANT_RESULT = 3'd6;
    localparam [2:0] S_DRAIN_RESULT   = 3'd7;

    // The GEMV core has two independent traffic classes:
    // - memory-window traffic from AXI4_Mapping, used to fill Activation/Weight
    //   BRAMs and read Result BRAM;
    // - compute traffic generated by the FSM, used to read activation/weight
    //   beats and feed PMAU_Full.

    wire [ACT_BEAT_WIDTH-1:0]   act_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_compute_data;
    wire [WEIGHT_BANK_WIDTH*WEIGHT_RAM_COUNT-1:0] weight_compute_data_leaf;
    reg [ACT_BEAT_WIDTH-1:0]    act_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pmau_data;
    wire [AXI_DATA_WIDTH-1:0]   result_cpu_rd_data;
    reg [ACT_ADDR_WIDTH-1:0]    act_compute_addr;
    reg                         compute_rd_en;
    (* keep = "true" *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_compute_addr_leaf [0:WEIGHT_RAM_COUNT-1];
    (* keep = "true" *)
    reg                         weight_compute_en_leaf [0:WEIGHT_RAM_COUNT-1];
    reg                         mm_rd_pending_r;
    reg [1:0]                   mm_rd_region_d_r;
    reg                         mm_rd_error_d_r;
    reg                         rd_pipe_en_r;
    reg [1:0]                   rd_pipe_region_r;
    reg [31:0]                  rd_pipe_index_r;

    // Local write pipeline.  AXI4_Mapping already registers its request, but
    // that register can be placed far from the banked weight BRAMs.  Capturing
    // the complete request again inside the GEMV hierarchy keeps address, data,
    // and byte enables aligned while cutting the long inter-module route.
    reg                         wr_pipe_en_r;
    reg [1:0]                   wr_pipe_region_r;
    reg [31:0]                  wr_pipe_index_r;
    (* keep = "true" *)
    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_wr_addr_leaf [0:WEIGHT_RAM_COUNT-1];
    (* keep = "true" *)
    reg                         weight_wr_en_leaf [0:WEIGHT_RAM_COUNT-1];
    (* keep = "true" *)
    reg [WEIGHT_BANK_WIDTH-1:0] weight_wr_data_leaf [0:WEIGHT_RAM_COUNT-1];
    (* keep = "true" *)
    reg [WEIGHT_BANK_BYTES-1:0] weight_wr_strb_leaf [0:WEIGHT_RAM_COUNT-1];
    reg [AXI_DATA_WIDTH-1:0]    wr_pipe_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] wr_pipe_strb_r;

    reg [2:0]  state_r;
    reg        done_r;
    reg        error_r;
    reg [15:0] active_rows_r;
    reg [15:0] active_col_beats_r;
    reg [15:0] row_idx_r;
    reg [15:0] read_beat_idx_r;
    reg [15:0] block_idx_r;
    reg [15:0] group_blocks_r;
    reg [31:0] result_row_base_r;
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_row_base_r;
    reg group_mode_r;
    reg result_i8_mode_r;
    reg result_accum_clear_r;
    reg result_emit_r;
    reg signed [ACC_WIDTH-1:0] result_accum_mem [0:MAX_ROWS-1];

    // The accumulator/requantizer result is captured before it drives Result
    // BRAM.  This separates the variable-row accumulator mux from the BRAM
    // write data path and gives the physical implementation one full cycle to
    // place each side locally.
    reg result_write_pending_r;
    reg [RESULT_ADDR_WIDTH-1:0] result_write_addr_r;
    reg [RESULT_I8_LANE_SHIFT-1:0] result_write_lane_r;
    reg signed [7:0] result_write_i8_r;

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
    reg [WEIGHT_SHARD_SEL_WIDTH-1:0] read_req_shard_r;
    reg read_req_last_r;
    reg read_req_group_last_r;
    reg read_valid_q_r;
    reg read_last_q_r;
    reg read_group_last_q_r;
    reg read_valid_x_r;
    reg read_last_x_r;
    reg read_group_last_x_r;
    reg [WEIGHT_SHARD_SEL_WIDTH-1:0] read_shard_d_r;
    reg [WEIGHT_SHARD_SEL_WIDTH-1:0] read_shard_q_r;
    reg [WEIGHT_SHARD_SEL_WIDTH-1:0] read_shard_x_r;

    wire [15:0] auto_col_beats =
        (cfg_cols + NUM_LANES_16 - 16'd1) >> LANE_SHIFT;
    wire [15:0] requested_col_beats =
        (cfg_col_beats != 16'd0) ? cfg_col_beats : auto_col_beats;
    wire        requested_group_mode = compute_mode[0];
    wire        requested_result_i8_mode = 1'b1;
    wire        requested_result_accum_clear = compute_mode[2];
    wire        requested_result_emit = compute_mode[3];
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

    // Runtime configuration is latched on ctrl_start, then validated before
    // any BRAM read is issued.  Packed q8 mode groups every two 128-bit beats
    // into one partial-result block, so an odd beat count is rejected.

    wire pmau_activation_ready;
    wire pmau_weight_ready;
    wire pmau_result_valid;
    wire [ACC_WIDTH-1:0] pmau_result_data;
    wire pmau_result_last;
    wire signed [7:0] pmau_result_i8;
    wire [4:0] result_requant_shift = cfg_scale[4:0];
    wire pmau_result_ready =
        (state_r == S_RUN) || (state_r == S_WAIT_RESULT);
    wire pmau_input_fire =
        feed_valid_r && pmau_activation_ready && pmau_weight_ready;
    wire pmau_result_fire = pmau_result_valid && pmau_result_ready;

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
    wire [WEIGHT_ADDR_WIDTH-1:0] issue_weight_addr =
        weight_row_base_r + read_abs_beat[WEIGHT_ADDR_WIDTH-1:0];
    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] issue_weight_local_addr =
        issue_weight_addr[WEIGHT_LOCAL_ADDR_WIDTH-1:0];
    wire [WEIGHT_SHARD_SEL_WIDTH-1:0] issue_weight_shard =
        issue_weight_addr >> WEIGHT_LOCAL_ADDR_WIDTH;
    wire can_issue_read =
        (state_r == S_RUN) &&
        read_req_slot_open &&
        (read_beat_idx_r < active_col_beats_r);
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
    wire signed [ACC_WIDTH-1:0] result_accum_prev =
        result_accum_clear_r ? {ACC_WIDTH{1'b0}} : result_accum_mem[row_idx_r];
    wire signed [ACC_WIDTH-1:0] result_accum_next =
        result_accum_prev + $signed(pmau_result_data);
    wire result_requant_capture =
        pmau_result_fire && result_wr_index_ok && result_i8_mode_r && result_emit_r;
    wire result_writeback_fire = result_write_pending_r;

    // Result placement is INT8-only for production.  Intermediate K-group
    // launches update the on-chip accumulator but do not write Result BRAM.
    // The final group writes one saturated INT8 byte per row.

    assign busy            = (state_r == S_RUN) ||
                             (state_r == S_WAIT_RESULT) ||
                             (state_r == S_REQUANT_RESULT) ||
                             (state_r == S_DRAIN_RESULT);
    assign done            = done_r;
    assign error           = error_r;
    assign active_row      = row_idx_r;
    assign active_col_beat = read_abs_beat;

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
        .activation_valid  ((state_r == S_RUN) && feed_valid_r),
        .activation_ready  (pmau_activation_ready),
        .activation_last   (feed_last_r),
        .weight_data       (weight_pmau_data),
        .scale_factor      (result_i8_mode_r ? FP16_ONE : cfg_scale),
        .weight_valid      ((state_r == S_RUN) && feed_valid_r),
        .weight_ready      (pmau_weight_ready),
        .weight_last       (feed_last_r),
        .scalar_axpy       (16'd0),
        .result_data       (pmau_result_data),
        .result_valid      (pmau_result_valid),
        .result_ready      (pmau_result_ready),
        .result_last       (pmau_result_last)
    );

    VPU_Result_Requantizer #(
        .ACC_WIDTH   (ACC_WIDTH),
        .SHIFT_WIDTH (5)
    ) u_result_requantizer (
        .value_in       (result_requant_value_r),
        .requant_shift  (result_requant_shift),
        .value_out      (pmau_result_i8)
    );

    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] wr_pipe_weight_local_addr =
        wr_pipe_index_r[WEIGHT_LOCAL_ADDR_WIDTH-1:0];
    wire [WEIGHT_SHARD_SEL_WIDTH-1:0] wr_pipe_weight_shard =
        wr_pipe_index_r >> WEIGHT_LOCAL_ADDR_WIDTH;

    integer wr_bank_i;
    integer wr_shard_i;
    integer wr_ram_i;
    integer fsm_bank_i;
    integer fsm_shard_i;
    integer fsm_ram_i;
    integer accum_i;
    integer mux_bank_i;
    always @(posedge CLK) begin
        if (!RST) begin
            wr_pipe_en_r     <= 1'b0;
            wr_pipe_region_r <= REGION_ACT;
            wr_pipe_index_r  <= 32'd0;
            wr_pipe_data_r   <= {AXI_DATA_WIDTH{1'b0}};
            wr_pipe_strb_r   <= {(AXI_DATA_WIDTH/8){1'b0}};
            for (wr_ram_i = 0; wr_ram_i < WEIGHT_RAM_COUNT; wr_ram_i = wr_ram_i + 1) begin
                weight_wr_addr_leaf[wr_ram_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                weight_wr_en_leaf[wr_ram_i]   <= 1'b0;
                weight_wr_data_leaf[wr_ram_i] <= {WEIGHT_BANK_WIDTH{1'b0}};
                weight_wr_strb_leaf[wr_ram_i] <= {WEIGHT_BANK_BYTES{1'b0}};
            end
        end else begin
            // Capture memory-window writes from AXI4_Mapping.  Activation is a
            // direct 128-bit BRAM word path, while Weight memory is split into
            // four 32-bit banks and optional depth shards.  Result BRAM is
            // written only by the PMAU result path below.
            wr_pipe_en_r <= mm_wr_en;
            if (mm_wr_en) begin
                wr_pipe_region_r <= mm_wr_region;
                wr_pipe_index_r  <= mm_wr_index;
                wr_pipe_data_r   <= mm_wr_data;
                wr_pipe_strb_r   <= mm_wr_strb;
            end

            for (wr_bank_i = 0; wr_bank_i < WEIGHT_BANKS; wr_bank_i = wr_bank_i + 1) begin
                for (wr_shard_i = 0; wr_shard_i < WEIGHT_DEPTH_SHARDS;
                     wr_shard_i = wr_shard_i + 1) begin
                    weight_wr_en_leaf[wr_bank_i*WEIGHT_DEPTH_SHARDS + wr_shard_i]
                        <= 1'b0;
                    if (wr_pipe_en_r &&
                        (wr_pipe_region_r == REGION_WEIGHT) &&
                        (wr_pipe_weight_shard == wr_shard_i)) begin
                        weight_wr_addr_leaf[wr_bank_i*WEIGHT_DEPTH_SHARDS + wr_shard_i]
                            <= wr_pipe_weight_local_addr;
                        weight_wr_en_leaf[wr_bank_i*WEIGHT_DEPTH_SHARDS + wr_shard_i]
                            <= 1'b1;
                        weight_wr_data_leaf[wr_bank_i*WEIGHT_DEPTH_SHARDS + wr_shard_i]
                            <= wr_pipe_data_r[WEIGHT_BANK_WIDTH*wr_bank_i +: WEIGHT_BANK_WIDTH];
                        weight_wr_strb_leaf[wr_bank_i*WEIGHT_DEPTH_SHARDS + wr_shard_i]
                            <= wr_pipe_strb_r[WEIGHT_BANK_BYTES*wr_bank_i +: WEIGHT_BANK_BYTES];
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
        end else begin
            // Delay the read request metadata so the Result BRAM data and the
            // region/error information are returned to AXI4_Mapping together.
            rd_pipe_en_r <= mm_rd_en;
            if (mm_rd_en) begin
                rd_pipe_region_r <= mm_rd_region;
                rd_pipe_index_r  <= mm_rd_index;
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
            // Final-result mode: PL returns one signed INT8 value per row.
            // Sixteen values share one 128-bit Result BRAM word.
            result_wr_data[8*result_write_lane_r +: 8] = result_write_i8_r;
            result_wr_strobe[result_write_lane_r] = 1'b1;
        end
    end

    wire [ACT_BEAT_WIDTH-1:0]    act_cpu_rd_unused;
    wire [WEIGHT_BANK_WIDTH*WEIGHT_RAM_COUNT-1:0] weight_cpu_rd_unused;
    wire [AXI_DATA_WIDTH-1:0]    result_compute_rd_unused;

    Dual_Port_BRAM #(
        .AWIDTH (ACT_ADDR_WIDTH),
        .DWIDTH (ACT_BEAT_WIDTH),
        .OUTPUT_REG (1),
        .USE_URAM (0)
    ) u_act_bram (
        .clka  (CLK),
        .ena   (act_wr_hit),
        .wea   (act_wr_strobe),
        .addra (wr_pipe_index_r[ACT_ADDR_WIDTH-1:0]),
        .dina  (wr_pipe_data_r[ACT_BEAT_WIDTH-1:0]),
        .douta (act_cpu_rd_unused),
        .clkb  (CLK),
        .enb   (compute_rd_en),
        .web   ({ACT_BYTE_COUNT{1'b0}}),
        .addrb (act_compute_addr),
        .dinb  ({ACT_BEAT_WIDTH{1'b0}}),
        .doutb (act_compute_data)
    );

    // Four 32-bit lane banks preserve the packed-Q8 interface.  Splitting each
    // lane bank by depth bounds the physical BRAM address fanout without
    // changing the logical MMIO address map.
    genvar weight_bank_g;
    genvar weight_shard_g;
    generate
        for (weight_bank_g = 0; weight_bank_g < WEIGHT_BANKS;
             weight_bank_g = weight_bank_g + 1) begin : GEN_WEIGHT_BANK
            for (weight_shard_g = 0; weight_shard_g < WEIGHT_DEPTH_SHARDS;
                 weight_shard_g = weight_shard_g + 1) begin : GEN_WEIGHT_SHARD
                localparam integer WEIGHT_RAM_INDEX =
                    weight_bank_g * WEIGHT_DEPTH_SHARDS + weight_shard_g;
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
                    .douta (weight_cpu_rd_unused[WEIGHT_BANK_WIDTH*WEIGHT_RAM_INDEX +: WEIGHT_BANK_WIDTH]),
                    .clkb  (CLK),
                    .enb   (weight_compute_en_leaf[WEIGHT_RAM_INDEX]),
                    .web   ({WEIGHT_BANK_BYTES{1'b0}}),
                    .addrb (weight_compute_addr_leaf[WEIGHT_RAM_INDEX]),
                    .dinb  ({WEIGHT_BANK_WIDTH{1'b0}}),
                    .doutb (weight_compute_data_leaf[WEIGHT_BANK_WIDTH*WEIGHT_RAM_INDEX +: WEIGHT_BANK_WIDTH])
                );
            end
        end
    endgenerate

    always @* begin
        weight_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};
        for (mux_bank_i = 0; mux_bank_i < WEIGHT_BANKS; mux_bank_i = mux_bank_i + 1) begin
            weight_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =
                weight_compute_data_leaf[
                    WEIGHT_BANK_WIDTH*(mux_bank_i*WEIGHT_DEPTH_SHARDS + read_shard_x_r)
                    +: WEIGHT_BANK_WIDTH
                ];
        end
    end

    Dual_Port_BRAM #(
        .AWIDTH (RESULT_ADDR_WIDTH),
        .DWIDTH (AXI_DATA_WIDTH),
        .USE_URAM (0)
    ) u_result_bram (
        .clka  (CLK),
        .ena   (result_rd_hit),
        .wea   ({(AXI_DATA_WIDTH/8){1'b0}}),
        .addra (rd_pipe_index_r[RESULT_ADDR_WIDTH-1:0]),
        .dina  ({AXI_DATA_WIDTH{1'b0}}),
        .douta (result_cpu_rd_data),
        .clkb  (CLK),
        .enb   (result_writeback_fire),
        .web   (result_wr_strobe),
        .addrb (result_write_addr_r),
        .dinb  (result_wr_data),
        .doutb (result_compute_rd_unused)
    );

    always @(posedge CLK) begin
        if (!RST) begin
            mm_rd_data  <= {AXI_DATA_WIDTH{1'b0}};
            mm_rd_valid <= 1'b0;
            mm_rd_error <= 1'b0;
            mm_rd_pending_r  <= 1'b0;
            mm_rd_region_d_r <= REGION_ACT;
            mm_rd_error_d_r  <= 1'b0;
        end else begin
            // Result-window reads are synchronous.  The request is accepted in
            // one cycle, and the data/error response is returned on the next
            // cycle when Result BRAM output is valid.
            mm_rd_pending_r <= mm_rd_accept;
            if (mm_rd_accept) begin
                mm_rd_region_d_r <= rd_pipe_region_r;
                mm_rd_error_d_r  <= (!rd_region_known) || (!rd_index_ok);
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
            active_rows_r       <= 16'd0;
            active_col_beats_r  <= 16'd0;
            row_idx_r           <= 16'd0;
            read_beat_idx_r     <= 16'd0;
            block_idx_r          <= 16'd0;
            group_blocks_r       <= 16'd1;
            result_row_base_r    <= 32'd0;
            weight_row_base_r   <= {WEIGHT_ADDR_WIDTH{1'b0}};
            group_mode_r         <= 1'b0;
            result_i8_mode_r     <= 1'b1;
            result_accum_clear_r <= 1'b0;
            result_emit_r        <= 1'b0;
            result_write_pending_r <= 1'b0;
            result_write_addr_r  <= {RESULT_ADDR_WIDTH{1'b0}};
            result_write_lane_r  <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_write_i8_r    <= 8'sd0;
            result_requant_pending_r <= 1'b0;
            result_requant_value_r <= {ACC_WIDTH{1'b0}};
            result_requant_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};
            result_requant_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};
            result_requant_final_r <= 1'b0;
            feed_valid_r        <= 1'b0;
            feed_last_r         <= 1'b0;
            feed_group_last_r   <= 1'b0;
            read_req_valid_r    <= 1'b0;
            read_req_act_addr_r <= {ACT_ADDR_WIDTH{1'b0}};
            read_req_weight_addr_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
            read_req_shard_r    <= {WEIGHT_SHARD_SEL_WIDTH{1'b0}};
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
            read_shard_d_r      <= {WEIGHT_SHARD_SEL_WIDTH{1'b0}};
            read_shard_q_r      <= {WEIGHT_SHARD_SEL_WIDTH{1'b0}};
            read_shard_x_r      <= {WEIGHT_SHARD_SEL_WIDTH{1'b0}};
            compute_rd_en       <= 1'b0;
            act_compute_addr    <= {ACT_ADDR_WIDTH{1'b0}};
            for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_COUNT; fsm_ram_i = fsm_ram_i + 1) begin
                weight_compute_addr_leaf[fsm_ram_i] <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                weight_compute_en_leaf[fsm_ram_i]   <= 1'b0;
            end
            for (accum_i = 0; accum_i < MAX_ROWS; accum_i = accum_i + 1)
                result_accum_mem[accum_i] <= {ACC_WIDTH{1'b0}};
            act_pmau_data       <= {ACT_BEAT_WIDTH{1'b0}};
            weight_pmau_data    <= {WEIGHT_BEAT_WIDTH{1'b0}};
        end else begin
            compute_rd_en  <= 1'b0;
            result_write_pending_r <= 1'b0;
            result_requant_pending_r <= 1'b0;
            for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_COUNT; fsm_ram_i = fsm_ram_i + 1)
                weight_compute_en_leaf[fsm_ram_i] <= 1'b0;
            if (shift_req_to_d)
                read_req_valid_r <= 1'b0;
            read_valid_d_r <= 1'b0;
            read_group_last_d_r <= 1'b0;

            if (ctrl_clear_done) begin
                done_r  <= 1'b0;
                error_r <= 1'b0;
            end

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
                    weight_row_base_r  <= {WEIGHT_ADDR_WIDTH{1'b0}};

                    if (ctrl_start) begin
                        done_r <= 1'b0;
                        error_r            <= 1'b0;
                        active_rows_r      <= cfg_rows;
                        active_col_beats_r <= requested_col_beats;
                        group_mode_r       <= requested_group_mode;
                        result_i8_mode_r   <= requested_result_i8_mode;
                        result_accum_clear_r <= requested_result_accum_clear;
                        result_emit_r      <= requested_result_emit;
                        group_blocks_r     <= requested_group_blocks;
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
                        read_valid_x_r <= 1'b0;
                    end

                    if (shift_q_to_x) begin
                        read_valid_x_r <= 1'b1;
                        read_last_x_r  <= read_last_q_r;
                        read_group_last_x_r <= read_group_last_q_r;
                        read_shard_x_r <= read_shard_q_r;
                        read_valid_q_r <= 1'b0;
                    end

                    if (shift_d_to_q) begin
                        read_valid_q_r <= 1'b1;
                        read_last_q_r  <= read_last_d_r;
                        read_group_last_q_r <= read_group_last_d_r;
                        read_shard_q_r <= read_shard_d_r;
                    end

                    if (shift_req_to_d) begin
                        compute_rd_en       <= 1'b1;
                        act_compute_addr    <= read_req_act_addr_r;
                        for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1) begin
                            for (fsm_shard_i = 0; fsm_shard_i < WEIGHT_DEPTH_SHARDS;
                                 fsm_shard_i = fsm_shard_i + 1) begin
                                weight_compute_en_leaf[fsm_bank_i*WEIGHT_DEPTH_SHARDS + fsm_shard_i]
                                    <= (read_req_shard_r == fsm_shard_i);
                                weight_compute_addr_leaf[fsm_bank_i*WEIGHT_DEPTH_SHARDS + fsm_shard_i]
                                    <= read_req_weight_addr_r;
                            end
                        end
                        read_valid_d_r      <= 1'b1;
                        read_last_d_r       <= read_req_last_r;
                        read_group_last_d_r <= read_req_group_last_r;
                        read_shard_d_r      <= read_req_shard_r;
                    end

                    if (can_issue_read) begin
                        read_req_valid_r      <= 1'b1;
                        read_req_act_addr_r   <= read_abs_beat[ACT_ADDR_WIDTH-1:0];
                        read_req_weight_addr_r <= issue_weight_local_addr;
                        read_req_shard_r      <= issue_weight_shard;
                        read_req_last_r       <= issue_read_last;
                        read_req_group_last_r <= issue_read_group_last;
                        read_beat_idx_r       <= read_beat_idx_r + 16'd1;
                    end

                    if (group_mode_r && pmau_result_fire)
                        block_idx_r <= block_idx_r + 16'd1;

                    if (pmau_input_fire && feed_group_last_r) begin
                        // The last beat of the current row/block has entered
                        // PMAU.  Stop issuing input and wait for the pipeline
                        // to produce the corresponding result.
                        feed_valid_r    <= 1'b0;
                        compute_rd_en   <= 1'b0;
                        for (fsm_ram_i = 0; fsm_ram_i < WEIGHT_RAM_COUNT; fsm_ram_i = fsm_ram_i + 1)
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
                            result_accum_mem[row_idx_r] <= result_accum_next;
                            block_idx_r <= 16'd0;

                            if (result_requant_capture) begin
                                result_requant_pending_r <= 1'b1;
                                result_requant_value_r   <= result_accum_next;
                                result_requant_addr_r    <= result_wr_addr;
                                result_requant_lane_r    <= result_wr_lane;
                                result_requant_final_r   <=
                                    ((row_idx_r + 16'd1) >= active_rows_r);
                            end

                            if ((row_idx_r + 16'd1) >= active_rows_r) begin
                                // The final INT32 value is first registered,
                                // then requantized and committed to Result
                                // BRAM in the two following cycles.
                                if (result_requant_capture)
                                    state_r <= S_REQUANT_RESULT;
                                else begin
                                    done_r  <= 1'b1;
                                    state_r <= S_DONE;
                                end
                            end else begin
                                row_idx_r         <= row_idx_r + 16'd1;
                                read_beat_idx_r   <= 16'd0;
                                result_row_base_r <= result_row_base_r + 32'd1;
                                weight_row_base_r <= weight_row_base_r +
                                                     active_col_beats_r;
                                state_r           <= result_requant_capture ?
                                                     S_REQUANT_RESULT : S_RUN;
                            end
                        end else if ((block_idx_r + 16'd1) < group_blocks_r) begin
                            block_idx_r       <= block_idx_r + 16'd1;
                        end else begin
                            block_idx_r       <= 16'd0;

                            if ((row_idx_r + 16'd1) >= active_rows_r) begin
                                done_r  <= 1'b1;
                                state_r <= S_DONE;
                            end else begin
                                row_idx_r         <= row_idx_r + 16'd1;
                                read_beat_idx_r   <= 16'd0;
                                result_row_base_r <= result_row_base_r + {16'd0, group_blocks_r};
                                weight_row_base_r <= weight_row_base_r +
                                                     active_col_beats_r;
                                state_r           <= S_RUN;
                            end
                        end
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
                    // On entry, result_write_pending_r was set by
                    // S_REQUANT_RESULT.  Result BRAM consumes it on this edge;
                    // asserting done here guarantees software observes the
                    // completed INT8 payload after the write is committed.
                    feed_valid_r <= 1'b0;
                    done_r       <= 1'b1;
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
                        group_blocks_r      <= requested_group_blocks;
                        row_idx_r           <= 16'd0;
                        read_beat_idx_r     <= 16'd0;
                        read_req_valid_r    <= 1'b0;
                        block_idx_r         <= 16'd0;
                        result_row_base_r   <= 32'd0;
                        weight_row_base_r   <= {WEIGHT_ADDR_WIDTH{1'b0}};
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
                        group_blocks_r     <= requested_group_blocks;
                        row_idx_r          <= 16'd0;
                        read_beat_idx_r    <= 16'd0;
                        read_req_valid_r   <= 1'b0;
                        block_idx_r        <= 16'd0;
                        result_row_base_r  <= 32'd0;
                        weight_row_base_r  <= {WEIGHT_ADDR_WIDTH{1'b0}};
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
