/*
 *-----------------------------------------------------------------------------
 * Module      : Matrix_Vector_Multiplication
 * Description : Runtime-sized INT8 GEMV engine with BRAM-backed activation,
 *               weight, and result storage.
 *
 * The AXI wrapper writes tensor data into these memory windows, configures the
 * active matrix size, then pulses ctrl_start.  The compute path feeds one
 * NUM_LANES-wide INT8 activation/weight beat per clock into PMAU_Streaming
 * after the first BRAM read latency cycle.  Results are stored one row per
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
    parameter MAX_ROWS           = 128,
    parameter MAX_COL_BEATS      = 256
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
    localparam ACT_ADDR_WIDTH       = clog2(MAX_COL_BEATS);
    localparam RESULT_ADDR_WIDTH    = clog2(MAX_ROWS);
    localparam WEIGHT_DEPTH         = MAX_ROWS * MAX_COL_BEATS;
    localparam WEIGHT_ADDR_WIDTH    = clog2(WEIGHT_DEPTH);
    localparam LANE_SHIFT           = clog2(NUM_LANES);
    localparam [15:0] NUM_LANES_16          = NUM_LANES;
    localparam [15:0] MAX_ROWS_16           = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16      = MAX_COL_BEATS;
    localparam [31:0] MAX_ROWS_32           = MAX_ROWS;
    localparam [31:0] MAX_COL_BEATS_32      = MAX_COL_BEATS;
    localparam [31:0] WEIGHT_DEPTH_32       = WEIGHT_DEPTH;
    localparam [WEIGHT_ADDR_WIDTH-1:0] MAX_COL_BEATS_WADDR = MAX_COL_BEATS;

    localparam [1:0] REGION_ACT     = 2'd0;
    localparam [1:0] REGION_WEIGHT  = 2'd1;
    localparam [1:0] REGION_RESULT  = 2'd2;

    localparam [2:0] S_IDLE         = 3'd0;
    localparam [2:0] S_RUN          = 3'd1;
    localparam [2:0] S_WAIT_RESULT  = 3'd2;
    localparam [2:0] S_DONE         = 3'd3;
    localparam [2:0] S_ERROR        = 3'd4;

    (* ram_style = "block" *) reg [ACT_BEAT_WIDTH-1:0]    act_mem    [0:MAX_COL_BEATS-1];
    (* ram_style = "block" *) reg [WEIGHT_BEAT_WIDTH-1:0] weight_mem [0:WEIGHT_DEPTH-1];
    (* ram_style = "block" *) reg [ACC_WIDTH-1:0]         result_mem [0:MAX_ROWS-1];

    reg [ACT_BEAT_WIDTH-1:0]    act_compute_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_compute_data;
    reg [ACT_BEAT_WIDTH-1:0]    act_pmau_data;
    reg [WEIGHT_BEAT_WIDTH-1:0] weight_pmau_data;
    reg [ACC_WIDTH-1:0]         result_cpu_rd_data;
    reg [ACT_ADDR_WIDTH-1:0]    act_compute_addr;
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_compute_addr;
    reg                         compute_rd_en;
    reg                         mm_rd_pending_r;
    reg [1:0]                   mm_rd_region_d_r;
    reg                         mm_rd_error_d_r;

    reg [2:0]  state_r;
    reg        done_r;
    reg        error_r;
    reg [15:0] active_rows_r;
    reg [15:0] active_col_beats_r;
    reg [15:0] row_idx_r;
    reg [15:0] read_beat_idx_r;
    reg [WEIGHT_ADDR_WIDTH-1:0] weight_row_base_r;

    reg feed_valid_r;
    reg feed_last_r;
    reg read_valid_d_r;
    reg read_last_d_r;
    reg read_valid_q_r;
    reg read_last_q_r;

    wire [15:0] auto_col_beats =
        (cfg_cols + NUM_LANES_16 - 16'd1) >> LANE_SHIFT;
    wire [15:0] requested_col_beats =
        (cfg_col_beats != 16'd0) ? cfg_col_beats : auto_col_beats;

    wire config_invalid =
        (cfg_rows == 16'd0) ||
        (requested_col_beats == 16'd0) ||
        (cfg_rows > MAX_ROWS_16) ||
        (requested_col_beats > MAX_COL_BEATS_16);

    wire pmau_activation_ready;
    wire pmau_weight_ready;
    wire pmau_result_valid;
    wire [ACC_WIDTH-1:0] pmau_result_data;
    wire pmau_result_last;
    wire pmau_result_ready = (state_r == S_WAIT_RESULT);
    wire pmau_input_fire =
        feed_valid_r && pmau_activation_ready && pmau_weight_ready;
    wire pmau_result_fire = pmau_result_valid && pmau_result_ready;

    wire feed_slot_open = (!feed_valid_r) || pmau_input_fire;
    wire can_issue_read =
        (state_r == S_RUN) &&
        feed_slot_open &&
        (read_beat_idx_r < active_col_beats_r);
    wire issue_read_last = (read_beat_idx_r == (active_col_beats_r - 16'd1));

    assign busy            = (state_r == S_RUN) || (state_r == S_WAIT_RESULT);
    assign done            = done_r;
    assign error           = error_r;
    assign active_row      = row_idx_r;
    assign active_col_beat = read_beat_idx_r;

    PMAU_Streaming #(
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

    wire mm_rd_accept = mm_rd_en && !mm_wr_en;
    wire act_wr_hit =
        mm_wr_en && (mm_wr_region == REGION_ACT);
    wire weight_wr_hit =
        mm_wr_en && (mm_wr_region == REGION_WEIGHT);
    wire act_rd_hit = 1'b0;
    wire weight_rd_hit = 1'b0;
    wire result_rd_hit =
        mm_rd_accept && (mm_rd_region == REGION_RESULT) &&
        (mm_rd_index < MAX_ROWS_32);
    wire rd_region_known =
        (mm_rd_region == REGION_ACT) ||
        (mm_rd_region == REGION_WEIGHT) ||
        (mm_rd_region == REGION_RESULT);
    wire rd_index_ok = result_rd_hit;

    integer act_byte_i;
    always @(posedge CLK) begin
        if (act_wr_hit) begin
            for (act_byte_i = 0; act_byte_i < AXI_BYTE_COUNT; act_byte_i = act_byte_i + 1)
                if (mm_wr_strb[act_byte_i] && (act_byte_i < (ACT_BEAT_WIDTH/8)))
                    act_mem[mm_wr_index[ACT_ADDR_WIDTH-1:0]][8*act_byte_i +: 8]
                        <= mm_wr_data[8*act_byte_i +: 8];
        end

        if (compute_rd_en)
            act_compute_data <= act_mem[act_compute_addr];
    end

    integer weight_byte_i;
    always @(posedge CLK) begin
        if (weight_wr_hit) begin
            for (weight_byte_i = 0; weight_byte_i < AXI_BYTE_COUNT; weight_byte_i = weight_byte_i + 1)
                if (mm_wr_strb[weight_byte_i] && (weight_byte_i < (WEIGHT_BEAT_WIDTH/8)))
                    weight_mem[mm_wr_index[WEIGHT_ADDR_WIDTH-1:0]][8*weight_byte_i +: 8]
                        <= mm_wr_data[8*weight_byte_i +: 8];
        end

        if (compute_rd_en)
            weight_compute_data <= weight_mem[weight_compute_addr];
    end

    always @(posedge CLK) begin
        if (pmau_result_fire && (row_idx_r < MAX_ROWS_16))
            result_mem[row_idx_r[RESULT_ADDR_WIDTH-1:0]] <= pmau_result_data;

        if (result_rd_hit)
            result_cpu_rd_data <= result_mem[mm_rd_index[RESULT_ADDR_WIDTH-1:0]];
    end

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
                mm_rd_region_d_r <= mm_rd_region;
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
                        mm_rd_data[ACC_WIDTH-1:0] <= result_cpu_rd_data;
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
            weight_row_base_r   <= {WEIGHT_ADDR_WIDTH{1'b0}};
            feed_valid_r        <= 1'b0;
            feed_last_r         <= 1'b0;
            read_valid_d_r      <= 1'b0;
            read_last_d_r       <= 1'b0;
            read_valid_q_r      <= 1'b0;
            read_last_q_r       <= 1'b0;
            compute_rd_en       <= 1'b0;
            act_compute_addr    <= {ACT_ADDR_WIDTH{1'b0}};
            weight_compute_addr <= {WEIGHT_ADDR_WIDTH{1'b0}};
            act_pmau_data       <= {ACT_BEAT_WIDTH{1'b0}};
            weight_pmau_data    <= {WEIGHT_BEAT_WIDTH{1'b0}};
        end else begin
            compute_rd_en  <= 1'b0;
            read_valid_d_r <= 1'b0;

            if (ctrl_clear_done) begin
                done_r  <= 1'b0;
                error_r <= 1'b0;
            end

            case (state_r)
                S_IDLE: begin
                    feed_valid_r       <= 1'b0;
                    feed_last_r        <= 1'b0;
                    read_valid_d_r     <= 1'b0;
                    read_valid_q_r     <= 1'b0;
                    read_beat_idx_r    <= 16'd0;
                    row_idx_r          <= 16'd0;
                    weight_row_base_r  <= {WEIGHT_ADDR_WIDTH{1'b0}};

                    if (ctrl_start) begin
                        done_r <= 1'b0;
                        if (config_invalid) begin
                            error_r <= 1'b1;
                            done_r  <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            error_r            <= 1'b0;
                            active_rows_r      <= cfg_rows;
                            active_col_beats_r <= requested_col_beats;
                            state_r            <= S_RUN;
                        end
                    end
                end

                S_RUN: begin
                    if (pmau_input_fire)
                        feed_valid_r <= 1'b0;

                    if (read_valid_q_r && feed_slot_open) begin
                        feed_valid_r <= 1'b1;
                        feed_last_r  <= read_last_q_r;
                        act_pmau_data    <= act_compute_data;
                        weight_pmau_data <= weight_compute_data;
                        read_valid_q_r <= 1'b0;
                    end

                    if (read_valid_d_r) begin
                        read_valid_q_r <= 1'b1;
                        read_last_q_r  <= read_last_d_r;
                    end

                    if (can_issue_read) begin
                        compute_rd_en       <= 1'b1;
                        act_compute_addr    <= read_beat_idx_r[ACT_ADDR_WIDTH-1:0];
                        weight_compute_addr <= weight_row_base_r +
                                               read_beat_idx_r[WEIGHT_ADDR_WIDTH-1:0];
                        read_valid_d_r      <= 1'b1;
                        read_last_d_r       <= issue_read_last;
                        read_beat_idx_r     <= read_beat_idx_r + 16'd1;
                    end

                    if (pmau_input_fire && feed_last_r) begin
                        feed_valid_r    <= 1'b0;
                        compute_rd_en   <= 1'b0;
                        read_valid_d_r  <= 1'b0;
                        read_valid_q_r  <= 1'b0;
                        state_r         <= S_WAIT_RESULT;
                    end
                end

                S_WAIT_RESULT: begin
                    feed_valid_r <= 1'b0;

                    if (pmau_result_fire) begin
                        if ((row_idx_r + 16'd1) >= active_rows_r) begin
                            done_r  <= 1'b1;
                            state_r <= S_DONE;
                        end else begin
                            row_idx_r         <= row_idx_r + 16'd1;
                            read_beat_idx_r   <= 16'd0;
                            weight_row_base_r <= weight_row_base_r +
                                                 MAX_COL_BEATS_WADDR;
                            state_r           <= S_RUN;
                        end
                    end
                end

                S_DONE: begin
                    feed_valid_r <= 1'b0;
                    if (ctrl_start) begin
                        done_r <= 1'b0;
                        if (config_invalid) begin
                            error_r <= 1'b1;
                            done_r  <= 1'b1;
                            state_r <= S_ERROR;
                        end else begin
                            error_r            <= 1'b0;
                            active_rows_r      <= cfg_rows;
                            active_col_beats_r <= requested_col_beats;
                            row_idx_r          <= 16'd0;
                            read_beat_idx_r    <= 16'd0;
                            weight_row_base_r  <= {WEIGHT_ADDR_WIDTH{1'b0}};
                            state_r            <= S_RUN;
                        end
                    end
                end

                S_ERROR: begin
                    feed_valid_r <= 1'b0;
                    if (ctrl_clear_done) begin
                        done_r  <= 1'b0;
                        error_r <= 1'b0;
                        state_r <= S_IDLE;
                    end else if (ctrl_start && !config_invalid) begin
                        done_r             <= 1'b0;
                        error_r            <= 1'b0;
                        active_rows_r      <= cfg_rows;
                        active_col_beats_r <= requested_col_beats;
                        row_idx_r          <= 16'd0;
                        read_beat_idx_r    <= 16'd0;
                        weight_row_base_r  <= {WEIGHT_ADDR_WIDTH{1'b0}};
                        state_r            <= S_RUN;
                    end
                end

                default: begin
                    state_r <= S_IDLE;
                end
            endcase
        end
    end

endmodule
