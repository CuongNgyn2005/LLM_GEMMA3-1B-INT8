/*
 *-----------------------------------------------------------------------------
 * Module      : Matrix_Vector_Multiplication
 * Description : Runtime-sized INT8 GEMV engine with BRAM-backed activation,
 *               weight, and result storage.
 *
 * The AXI wrapper writes tensor data into these memory windows, configures the
 * active matrix size, then pulses ctrl_start.  The compute path feeds one
 * NUM_LANES-wide INT8 activation/weight beat per clock into PMAU_Full
 * after the pipelined BRAM read latency.  Results are stored one row per
 * 128-bit result word, using the low ACC_WIDTH bits.
 *
 * Addressing contract used by the AXI wrapper:
 * - activation index = column beat
 * - weight index     = row * MAX_COL_BEATS + column beat
 * - result index     = row
 *
 * Runtime sizes are bounded by MAX_ROWS and MAX_COL_BEATS.  If cfg_col_beats is
 * zero, the engine derives it from cfg_cols assuming NUM_LANES is a power of 2.
 * The last beat must be zero-padded by software when cfg_cols is not an exact
 * multiple of NUM_LANES.
 *
 * compute_mode[0] enables packed q8_0 partial mode.  In this mode the core
 * treats every two 128-bit beats as one q8_0 block, emits one raw INT32 partial
 * per row per q8_0 block, and packs four partials into each 128-bit result word.
 * This reduces host start/poll cycles while keeping q8_0 scaling in software.
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
    parameter MAX_COL_BEATS      = 32
) (
    input  wire                              CLK,
    input  wire                              RST,

    input  wire                              ctrl_start,
    input  wire                              ctrl_clear_done,
    input  wire [15:0]                       cfg_rows,
    input  wire [15:0]                       cfg_cols,
    input  wire [15:0]                       cfg_col_beats,
    input  wire [SCALE_WIDTH-1:0]            cfg_scale,
    input  wire [1:0]                        compute_mode,

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
    localparam WEIGHT_BYTE_COUNT    = WEIGHT_BEAT_WIDTH / 8;
    localparam WEIGHT_BANKS         = 4;
    localparam WEIGHT_BANK_WIDTH    = WEIGHT_BEAT_WIDTH / WEIGHT_BANKS;
    localparam WEIGHT_BANK_BYTES    = WEIGHT_BANK_WIDTH / 8;
    localparam RESULT_BYTE_COUNT    = ACC_WIDTH / 8;
    localparam ACT_ADDR_WIDTH       = clog2(MAX_COL_BEATS);
    localparam RESULT_PACK_LANES    = AXI_DATA_WIDTH / ACC_WIDTH;
    localparam RESULT_LANE_SHIFT    = clog2(RESULT_PACK_LANES);
    localparam MAX_GROUP_Q8_BLOCKS  = 16;
    localparam MAX_RESULT_VALUES    = MAX_ROWS * MAX_GROUP_Q8_BLOCKS;
    localparam RESULT_WORD_DEPTH    = (MAX_RESULT_VALUES + RESULT_PACK_LANES - 1) / RESULT_PACK_LANES;
    localparam RESULT_ADDR_WIDTH    = clog2(RESULT_WORD_DEPTH);
    localparam WEIGHT_DEPTH         = MAX_ROWS * MAX_COL_BEATS;
    localparam WEIGHT_ADDR_WIDTH    = clog2(WEIGHT_DEPTH);
    localparam LANE_SHIFT           = clog2(NUM_LANES);
    localparam [15:0] NUM_LANES_16          = NUM_LANES;
    localparam [15:0] MAX_ROWS_16           = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16      = MAX_COL_BEATS;
    localparam [15:0] Q8_BLOCK_BEATS_16     = 16'd2;
    localparam [31:0] MAX_ROWS_32           = MAX_ROWS;
    localparam [31:0] MAX_COL_BEATS_32      = MAX_COL_BEATS;
    localparam [31:0] WEIGHT_DEPTH_32       = WEIGHT_DEPTH;
    localparam [31:0] MAX_RESULT_VALUES_32  = MAX_RESULT_VALUES;
    localparam [31:0] RESULT_WORD_DEPTH_32  = RESULT_WORD_DEPTH;
    localparam [WEIGHT_ADDR_WIDTH-1:0] MAX_COL_BEATS_WADDR = MAX_COL_BEATS;

    localparam [1:0] REGION_ACT     = 2'd0;
    localparam [1:0] REGION_WEIGHT  = 2'd1;
    localparam [1:0] REGION_RESULT  = 2'd2;

    localparam [2:0] S_IDLE         = 3'd0;
    localparam [2:0] S_RUN          = 3'd1;
    localparam [2:0] S_WAIT_RESULT  = 3'd2;
    localparam [2:0] S_DONE         = 3'd3;
    localparam [2:0] S_ERROR        = 3'd4;
    localparam [2:0] S_VALIDATE     = 3'd5;

    wire [ACT_BEAT_WIDTH-1:0]   act_compute_data;
    wire [WEIGHT_BEAT_WIDTH-1:0] weight_compute_data;
    reg [ACT_BEAT_WIDTH-1:0]    act_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pmau_data;
    wire [AXI_DATA_WIDTH-1:0]   result_cpu_rd_data;
    reg [ACT_ADDR_WIDTH-1:0]    act_compute_addr;
    reg                         compute_rd_en;
    (* keep = "true", dont_touch = "true" *)
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_compute_addr_bank [0:WEIGHT_BANKS-1];
    (* keep = "true", dont_touch = "true" *)
    reg                         weight_compute_en_bank [0:WEIGHT_BANKS-1];
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
    (* keep = "true", dont_touch = "true" *)
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_wr_addr_bank [0:WEIGHT_BANKS-1];
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

    reg feed_valid_r;
    reg feed_last_r;
    reg feed_group_last_r;
    reg read_valid_d_r;
    reg read_last_d_r;
    reg read_group_last_d_r;
    reg read_valid_q_r;
    reg read_last_q_r;
    reg read_group_last_q_r;
    reg read_valid_x_r;
    reg read_last_x_r;
    reg read_group_last_x_r;

    wire [15:0] auto_col_beats =
        (cfg_cols + NUM_LANES_16 - 16'd1) >> LANE_SHIFT;
    wire [15:0] requested_col_beats =
        (cfg_col_beats != 16'd0) ? cfg_col_beats : auto_col_beats;
    wire        requested_group_mode = compute_mode[0];
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

    wire pmau_activation_ready;
    wire pmau_weight_ready;
    wire pmau_result_valid;
    wire [ACC_WIDTH-1:0] pmau_result_data;
    wire pmau_result_last;
    wire pmau_result_ready =
        (state_r == S_RUN) || (state_r == S_WAIT_RESULT);
    wire pmau_input_fire =
        feed_valid_r && pmau_activation_ready && pmau_weight_ready;
    wire pmau_result_fire = pmau_result_valid && pmau_result_ready;

    wire feed_slot_open = (!feed_valid_r) || pmau_input_fire;
    wire consume_read_x = read_valid_x_r && feed_slot_open;
    wire read_x_slot_open = (!read_valid_x_r) || consume_read_x;
    wire shift_q_to_x = read_valid_q_r && read_x_slot_open;
    wire read_q_slot_open = (!read_valid_q_r) || shift_q_to_x;
    wire shift_d_to_q = read_valid_d_r && read_q_slot_open;
    wire read_d_slot_open = (!read_valid_d_r) || shift_d_to_q;
    wire [15:0] read_abs_beat = read_beat_idx_r;
    wire can_issue_read =
        (state_r == S_RUN) &&
        read_d_slot_open &&
        (read_beat_idx_r < active_col_beats_r);
    wire issue_read_last =
        group_mode_r ? (read_beat_idx_r[0] == 1'b1) :
                       (read_beat_idx_r == (active_col_beats_r - 16'd1));
    wire issue_read_group_last =
        (read_beat_idx_r == (active_col_beats_r - 16'd1));

    wire [31:0] result_value_index =
        group_mode_r ? (result_row_base_r + {16'd0, block_idx_r}) :
                       {16'd0, row_idx_r};
    wire [RESULT_ADDR_WIDTH-1:0] result_wr_addr =
        group_mode_r ? result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH] :
                       row_idx_r[RESULT_ADDR_WIDTH-1:0];
    wire [RESULT_LANE_SHIFT-1:0] result_wr_lane =
        group_mode_r ? result_value_index[RESULT_LANE_SHIFT-1:0] :
                       {RESULT_LANE_SHIFT{1'b0}};
    wire result_wr_index_ok =
        group_mode_r ? (result_value_index < MAX_RESULT_VALUES_32) :
                       (row_idx_r < MAX_ROWS_16);

    assign busy            = (state_r == S_RUN) || (state_r == S_WAIT_RESULT);
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
        .compute_mode      (compute_mode),
        .activation_data   (act_pmau_data),
        .activation_valid  ((state_r == S_RUN) && feed_valid_r),
        .activation_ready  (pmau_activation_ready),
        .activation_last   (feed_last_r),
        .weight_data       (weight_pmau_data),
        .scale_factor      (cfg_scale),
        .weight_valid      ((state_r == S_RUN) && feed_valid_r),
        .weight_ready      (pmau_weight_ready),
        .weight_last       (feed_last_r),
        .scalar_axpy       (16'd0),
        .result_data       (pmau_result_data),
        .result_valid      (pmau_result_valid),
        .result_ready      (pmau_result_ready),
        .result_last       (pmau_result_last)
    );

    integer wr_bank_i;
    integer fsm_bank_i;
    always @(posedge CLK) begin
        if (!RST) begin
            wr_pipe_en_r     <= 1'b0;
            wr_pipe_region_r <= REGION_ACT;
            wr_pipe_index_r  <= 32'd0;
            wr_pipe_data_r   <= {AXI_DATA_WIDTH{1'b0}};
            wr_pipe_strb_r   <= {(AXI_DATA_WIDTH/8){1'b0}};
            for (wr_bank_i = 0; wr_bank_i < WEIGHT_BANKS; wr_bank_i = wr_bank_i + 1)
                weight_wr_addr_bank[wr_bank_i] <= {WEIGHT_ADDR_WIDTH{1'b0}};
        end else begin
            wr_pipe_en_r <= mm_wr_en;
            if (mm_wr_en) begin
                wr_pipe_region_r <= mm_wr_region;
                wr_pipe_index_r  <= mm_wr_index;
                wr_pipe_data_r   <= mm_wr_data;
                wr_pipe_strb_r   <= mm_wr_strb;
                for (wr_bank_i = 0; wr_bank_i < WEIGHT_BANKS; wr_bank_i = wr_bank_i + 1)
                    weight_wr_addr_bank[wr_bank_i] <= mm_wr_index[WEIGHT_ADDR_WIDTH-1:0];
            end
        end
    end

    always @(posedge CLK) begin
        if (!RST) begin
            rd_pipe_en_r     <= 1'b0;
            rd_pipe_region_r <= REGION_RESULT;
            rd_pipe_index_r  <= 32'd0;
        end else begin
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
    wire weight_wr_hit =
        wr_pipe_en_r && (wr_pipe_region_r == REGION_WEIGHT);
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
    wire [WEIGHT_BYTE_COUNT-1:0] weight_wr_strobe =
        wr_pipe_strb_r[WEIGHT_BYTE_COUNT-1:0];
    reg [AXI_DATA_WIDTH-1:0] result_wr_data;
    reg [(AXI_DATA_WIDTH/8)-1:0] result_wr_strobe;
    integer result_lane_i;
    always @* begin
        result_wr_data   = {AXI_DATA_WIDTH{1'b0}};
        result_wr_strobe = {(AXI_DATA_WIDTH/8){1'b0}};
        if (pmau_result_fire && result_wr_index_ok) begin
            result_wr_data[ACC_WIDTH*result_wr_lane +: ACC_WIDTH] = pmau_result_data;
            for (result_lane_i = 0; result_lane_i < RESULT_BYTE_COUNT; result_lane_i = result_lane_i + 1)
                result_wr_strobe[RESULT_BYTE_COUNT*result_wr_lane + result_lane_i] = 1'b1;
        end
    end

    wire [ACT_BEAT_WIDTH-1:0]    act_cpu_rd_unused;
    wire [WEIGHT_BEAT_WIDTH-1:0] weight_cpu_rd_unused;
    wire [AXI_DATA_WIDTH-1:0]    result_compute_rd_unused;

    Dual_Port_BRAM #(
        .AWIDTH (ACT_ADDR_WIDTH),
        .DWIDTH (ACT_BEAT_WIDTH),
        .OUTPUT_REG (1)
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

    // Four 32-bit banks keep each BRAM address/enable route local while the
    // concatenated interface remains one 128-bit weight beat.
    genvar weight_bank_g;
    generate
        for (weight_bank_g = 0; weight_bank_g < WEIGHT_BANKS;
             weight_bank_g = weight_bank_g + 1) begin : GEN_WEIGHT_BANK
            Dual_Port_BRAM #(
                .AWIDTH (WEIGHT_ADDR_WIDTH),
                .DWIDTH (WEIGHT_BANK_WIDTH),
                .OUTPUT_REG (1)
            ) u_weight_bram_bank (
                .clka  (CLK),
                .ena   (weight_wr_hit),
                .wea   (weight_wr_strobe[WEIGHT_BANK_BYTES*weight_bank_g +: WEIGHT_BANK_BYTES]),
                .addra (weight_wr_addr_bank[weight_bank_g]),
                .dina  (wr_pipe_data_r[WEIGHT_BANK_WIDTH*weight_bank_g +: WEIGHT_BANK_WIDTH]),
                .douta (weight_cpu_rd_unused[WEIGHT_BANK_WIDTH*weight_bank_g +: WEIGHT_BANK_WIDTH]),
                .clkb  (CLK),
                .enb   (weight_compute_en_bank[weight_bank_g]),
                .web   ({WEIGHT_BANK_BYTES{1'b0}}),
                .addrb (weight_compute_addr_bank[weight_bank_g]),
                .dinb  ({WEIGHT_BANK_WIDTH{1'b0}}),
                .doutb (weight_compute_data[WEIGHT_BANK_WIDTH*weight_bank_g +: WEIGHT_BANK_WIDTH])
            );
        end
    endgenerate

    Dual_Port_BRAM #(
        .AWIDTH (RESULT_ADDR_WIDTH),
        .DWIDTH (AXI_DATA_WIDTH)
    ) u_result_bram (
        .clka  (CLK),
        .ena   (result_rd_hit),
        .wea   ({(AXI_DATA_WIDTH/8){1'b0}}),
        .addra (rd_pipe_index_r[RESULT_ADDR_WIDTH-1:0]),
        .dina  ({AXI_DATA_WIDTH{1'b0}}),
        .douta (result_cpu_rd_data),
        .clkb  (CLK),
        .enb   (pmau_result_fire && result_wr_index_ok),
        .web   (result_wr_strobe),
        .addrb (result_wr_addr),
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
            feed_valid_r        <= 1'b0;
            feed_last_r         <= 1'b0;
            feed_group_last_r   <= 1'b0;
            read_valid_d_r      <= 1'b0;
            read_last_d_r       <= 1'b0;
            read_group_last_d_r <= 1'b0;
            read_valid_q_r      <= 1'b0;
            read_last_q_r       <= 1'b0;
            read_group_last_q_r <= 1'b0;
            read_valid_x_r      <= 1'b0;
            read_last_x_r       <= 1'b0;
            read_group_last_x_r <= 1'b0;
            compute_rd_en       <= 1'b0;
            act_compute_addr    <= {ACT_ADDR_WIDTH{1'b0}};
            for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1) begin
                weight_compute_addr_bank[fsm_bank_i] <= {WEIGHT_ADDR_WIDTH{1'b0}};
                weight_compute_en_bank[fsm_bank_i]   <= 1'b0;
            end
            act_pmau_data       <= {ACT_BEAT_WIDTH{1'b0}};
            weight_pmau_data    <= {WEIGHT_BEAT_WIDTH{1'b0}};
        end else begin
            compute_rd_en  <= 1'b0;
            for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1)
                weight_compute_en_bank[fsm_bank_i] <= 1'b0;
            read_valid_d_r <= 1'b0;
            read_group_last_d_r <= 1'b0;

            if (ctrl_clear_done) begin
                done_r  <= 1'b0;
                error_r <= 1'b0;
            end

            case (state_r)
                S_IDLE: begin
                    feed_valid_r       <= 1'b0;
                    feed_last_r        <= 1'b0;
                    feed_group_last_r  <= 1'b0;
                    read_valid_d_r     <= 1'b0;
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
                        group_blocks_r     <= requested_group_blocks;
                        state_r            <= S_VALIDATE;
                    end
                end

                S_VALIDATE: begin
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
                        read_valid_q_r <= 1'b0;
                    end

                    if (shift_d_to_q) begin
                        read_valid_q_r <= 1'b1;
                        read_last_q_r  <= read_last_d_r;
                        read_group_last_q_r <= read_group_last_d_r;
                    end

                    if (can_issue_read) begin
                        compute_rd_en       <= 1'b1;
                        act_compute_addr    <= read_abs_beat[ACT_ADDR_WIDTH-1:0];
                        for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1) begin
                            weight_compute_en_bank[fsm_bank_i] <= 1'b1;
                            weight_compute_addr_bank[fsm_bank_i] <= weight_row_base_r +
                                read_abs_beat[WEIGHT_ADDR_WIDTH-1:0];
                        end
                        read_valid_d_r      <= 1'b1;
                        read_last_d_r       <= issue_read_last;
                        read_group_last_d_r <= issue_read_group_last;
                        read_beat_idx_r     <= read_beat_idx_r + 16'd1;
                    end

                    if (group_mode_r && pmau_result_fire)
                        block_idx_r <= block_idx_r + 16'd1;

                    if (pmau_input_fire && feed_group_last_r) begin
                        feed_valid_r    <= 1'b0;
                        compute_rd_en   <= 1'b0;
                        for (fsm_bank_i = 0; fsm_bank_i < WEIGHT_BANKS; fsm_bank_i = fsm_bank_i + 1)
                            weight_compute_en_bank[fsm_bank_i] <= 1'b0;
                        read_valid_d_r  <= 1'b0;
                        read_valid_q_r  <= 1'b0;
                        read_valid_x_r  <= 1'b0;
                        state_r         <= S_WAIT_RESULT;
                    end
                end

                S_WAIT_RESULT: begin
                    feed_valid_r <= 1'b0;

                    if (pmau_result_fire) begin
                        if ((block_idx_r + 16'd1) < group_blocks_r) begin
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
                                                     MAX_COL_BEATS_WADDR;
                                state_r           <= S_RUN;
                            end
                        end
                    end
                end

                S_DONE: begin
                    feed_valid_r <= 1'b0;
                    if (ctrl_start) begin
                        done_r              <= 1'b0;
                        error_r             <= 1'b0;
                        active_rows_r       <= cfg_rows;
                        active_col_beats_r  <= requested_col_beats;
                        group_mode_r        <= requested_group_mode;
                        group_blocks_r      <= requested_group_blocks;
                        row_idx_r           <= 16'd0;
                        read_beat_idx_r     <= 16'd0;
                        block_idx_r         <= 16'd0;
                        result_row_base_r   <= 32'd0;
                        weight_row_base_r   <= {WEIGHT_ADDR_WIDTH{1'b0}};
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
                        group_blocks_r     <= requested_group_blocks;
                        row_idx_r          <= 16'd0;
                        read_beat_idx_r    <= 16'd0;
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
