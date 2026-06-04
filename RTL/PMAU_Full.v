/*
 *-----------------------------------------------------------------------------
 * Module      : PMAU_Full
 * Description : Internal parallel multiply-accumulate unit for the VPU.
 *
 * This block consumes one paired activation/weight beat per cycle when both
 * internal activation/weight valid signals are asserted.  The datapath is
 * fully pipelined:
 *
 *   Stage 0          : NUM_LANES signed INT8 x INT8 multiplies
 *   Stage 1..log2(N) : registered binary adder tree
 *   Commit stage     : row accumulator, fixed-point dequant, result FIFO
 *
 * Throughput is one input beat per clock while the result FIFO has enough
 * space for completed rows already in flight.  The result channel uses a
 * simple valid/ready handshake internal to the AXI4-Full VPU wrapper.
 *
 * Notes:
 * - NUM_LANES must be a power of two.  16/32/64/128 are the intended values.
 * - scale_factor is treated as a positive fixed-point scale with
 *   SCALE_FRAC_BITS fractional bits.  FP16 1.0 (16'h3c00) is bypassed for the
 *   existing raw-accumulator test flow; replace this with a real FP16 unit if
 *   you want to match the paper's FP16 VPU exactly.
 * - RESULT_FIFO_DEPTH must be a power of two.
 * - Reset is active-low and synchronous.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module PMAU_Full #(
    parameter NUM_LANES          = 16,
    parameter ACT_WIDTH          = 8,
    parameter WEIGHT_WIDTH       = 8,
    parameter MULT_WIDTH         = ACT_WIDTH + WEIGHT_WIDTH,
    parameter ACC_WIDTH          = 32,
    parameter SCALE_WIDTH        = 16,
    parameter SCALE_FRAC_BITS    = 15,
    parameter RESULT_FIFO_DEPTH  = 8
) (
    input  wire                              CLK,
    input  wire                              RST,

    // Control
    input  wire [1:0]                        compute_mode,

    // Activation input, internal valid/ready beat
    input  wire [ACT_WIDTH*NUM_LANES-1:0]    activation_data,
    input  wire                              activation_valid,
    output wire                              activation_ready,
    input  wire                              activation_last,

    // Weight input, internal valid/ready beat
    input  wire [WEIGHT_WIDTH*NUM_LANES-1:0] weight_data,
    input  wire [SCALE_WIDTH-1:0]            scale_factor,
    input  wire                              weight_valid,
    output wire                              weight_ready,
    input  wire                              weight_last,

    // Reserved for future AXPY mode
    input  wire [15:0]                       scalar_axpy,

    // Result output, internal valid/ready beat
    output wire [ACC_WIDTH-1:0]              result_data,
    output wire                              result_valid,
    input  wire                              result_ready,
    output wire                              result_last
);

    // -------------------------------------------------------------------------
    // Local helpers
    // -------------------------------------------------------------------------
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    localparam TREE_LEVELS      = clog2(NUM_LANES);
    localparam HALF_LANES       = NUM_LANES / 2;
    localparam FIFO_PTR_WIDTH   = clog2(RESULT_FIFO_DEPTH);
    localparam FIFO_COUNT_WIDTH = FIFO_PTR_WIDTH + 1;
    localparam SCALE_EXT_WIDTH  = SCALE_WIDTH + 1;
    localparam DEQUANT_WIDTH    = ACC_WIDTH + SCALE_EXT_WIDTH;
    localparam [FIFO_COUNT_WIDTH-1:0] FIFO_DEPTH_COUNT = RESULT_FIFO_DEPTH;
    localparam [SCALE_WIDTH-1:0] FP16_ONE = 16'h3c00;

    // valid_pipe[0] is the multiply stage.  valid_pipe[TREE_LEVELS] is the
    // final registered adder-tree result.
    reg valid_pipe [0:TREE_LEVELS];
    reg last_pipe  [0:TREE_LEVELS];
    reg [SCALE_WIDTH-1:0] scale_pipe [0:TREE_LEVELS];

    reg                         deq_s1_valid;
    reg                         deq_s1_last;
    reg signed [ACC_WIDTH-1:0]  deq_s1_raw;
    reg [SCALE_WIDTH-1:0]       deq_s1_scale;

    reg                         deq_s2_valid;
    reg                         deq_s2_last;
    reg signed [ACC_WIDTH-1:0]  deq_s2_value;

    // -------------------------------------------------------------------------
    // Result FIFO and input backpressure
    // -------------------------------------------------------------------------
    reg [ACC_WIDTH-1:0] result_fifo_data [0:RESULT_FIFO_DEPTH-1];
    reg                 result_fifo_last [0:RESULT_FIFO_DEPTH-1];
    reg [FIFO_PTR_WIDTH-1:0]   fifo_wr_ptr;
    reg [FIFO_PTR_WIDTH-1:0]   fifo_rd_ptr;
    reg [FIFO_COUNT_WIDTH-1:0] fifo_count;

    assign result_valid = (fifo_count != {FIFO_COUNT_WIDTH{1'b0}});
    assign result_data  = result_valid ? result_fifo_data[fifo_rd_ptr] :
                                       {ACC_WIDTH{1'b0}};
    assign result_last  = result_valid ? result_fifo_last[fifo_rd_ptr] : 1'b0;

    wire result_fire = result_valid && result_ready;

    reg [FIFO_COUNT_WIDTH-1:0] pending_result_count;
    integer pending_i;
    always @* begin
        pending_result_count = {FIFO_COUNT_WIDTH{1'b0}};
        for (pending_i = 0; pending_i <= TREE_LEVELS; pending_i = pending_i + 1) begin
            if (valid_pipe[pending_i] && last_pipe[pending_i])
                pending_result_count = pending_result_count + {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
        end
        if (deq_s1_valid)
            pending_result_count = pending_result_count + {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
        if (deq_s2_valid)
            pending_result_count = pending_result_count + {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
    end

    wire [FIFO_COUNT_WIDTH-1:0] fifo_count_after_pop =
        fifo_count - {{(FIFO_COUNT_WIDTH-1){1'b0}}, result_fire};

    wire [FIFO_COUNT_WIDTH-1:0] reserved_result_slots =
        fifo_count_after_pop + pending_result_count;

    wire both_inputs_valid = activation_valid && weight_valid;
    wire incoming_pair_last = both_inputs_valid && activation_last && weight_last;
    wire incoming_last_match = (!both_inputs_valid) || (activation_last == weight_last);
    wire can_accept_pair =
        incoming_last_match &&
        ((!incoming_pair_last) ||
         (reserved_result_slots < FIFO_DEPTH_COUNT));

    assign activation_ready = can_accept_pair && weight_valid;
    assign weight_ready     = can_accept_pair && activation_valid;

    wire input_fire = both_inputs_valid && can_accept_pair;

    // -------------------------------------------------------------------------
    // Stage 0: signed INT8 x INT8 multiplies
    // -------------------------------------------------------------------------
    wire signed [MULT_WIDTH-1:0] mult_comb [0:NUM_LANES-1];
    reg  signed [MULT_WIDTH-1:0] mult_pipe [0:NUM_LANES-1];

    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < NUM_LANES; lane_g = lane_g + 1) begin : GEN_MULT
            wire signed [ACT_WIDTH-1:0] act_lane;
            wire signed [WEIGHT_WIDTH-1:0] weight_lane;

            assign act_lane =
                activation_data[ACT_WIDTH*lane_g +: ACT_WIDTH];
            assign weight_lane =
                weight_data[WEIGHT_WIDTH*lane_g +: WEIGHT_WIDTH];
            assign mult_comb[lane_g] = act_lane * weight_lane;
        end
    endgenerate

    // Each level keeps its maximum possible width in the second dimension.
    wire signed [ACC_WIDTH-1:0] sum_comb [0:TREE_LEVELS-1][0:HALF_LANES-1];
    reg  signed [ACC_WIDTH-1:0] sum_pipe [0:TREE_LEVELS-1][0:HALF_LANES-1];

    genvar level_g;
    genvar node_g;
    generate
        for (level_g = 0; level_g < TREE_LEVELS; level_g = level_g + 1) begin : GEN_TREE_LEVEL
            localparam integer LEVEL_COUNT = NUM_LANES >> (level_g + 1);

            for (node_g = 0; node_g < LEVEL_COUNT; node_g = node_g + 1) begin : GEN_TREE_NODE
                if (level_g == 0) begin : GEN_FROM_MULT
                    wire signed [ACC_WIDTH-1:0] lhs;
                    wire signed [ACC_WIDTH-1:0] rhs;

                    assign lhs = {{(ACC_WIDTH-MULT_WIDTH){mult_pipe[2*node_g][MULT_WIDTH-1]}},
                                  mult_pipe[2*node_g]};
                    assign rhs = {{(ACC_WIDTH-MULT_WIDTH){mult_pipe[2*node_g+1][MULT_WIDTH-1]}},
                                  mult_pipe[2*node_g+1]};
                    assign sum_comb[level_g][node_g] = lhs + rhs;
                end else begin : GEN_FROM_PREV
                    assign sum_comb[level_g][node_g] =
                        sum_pipe[level_g-1][2*node_g] +
                        sum_pipe[level_g-1][2*node_g+1];
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Pipeline registers
    // -------------------------------------------------------------------------
    integer k;
    integer level_i;
    integer node_i;
    always @(posedge CLK) begin
        if (!RST) begin
            for (k = 0; k < NUM_LANES; k = k + 1)
                mult_pipe[k] <= {MULT_WIDTH{1'b0}};

            for (level_i = 0; level_i <= TREE_LEVELS; level_i = level_i + 1) begin
                valid_pipe[level_i] <= 1'b0;
                last_pipe[level_i]  <= 1'b0;
                scale_pipe[level_i] <= {SCALE_WIDTH{1'b0}};
            end

            for (level_i = 0; level_i < TREE_LEVELS; level_i = level_i + 1)
                for (node_i = 0; node_i < HALF_LANES; node_i = node_i + 1)
                    sum_pipe[level_i][node_i] <= {ACC_WIDTH{1'b0}};
        end else begin
            valid_pipe[0] <= input_fire;
            last_pipe[0]  <= input_fire && activation_last && weight_last;
            if (input_fire)
                scale_pipe[0] <= scale_factor;

            for (k = 0; k < NUM_LANES; k = k + 1)
                if (input_fire)
                    mult_pipe[k] <= mult_comb[k];

            for (level_i = 0; level_i < TREE_LEVELS; level_i = level_i + 1) begin
                valid_pipe[level_i+1] <= valid_pipe[level_i];
                last_pipe[level_i+1]  <= last_pipe[level_i];
                scale_pipe[level_i+1] <= scale_pipe[level_i];

                for (node_i = 0; node_i < (NUM_LANES >> (level_i + 1)); node_i = node_i + 1)
                    sum_pipe[level_i][node_i] <= sum_comb[level_i][node_i];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Accumulator and dequantization
    // -------------------------------------------------------------------------
    reg signed [ACC_WIDTH-1:0] accumulator;

    wire final_valid = valid_pipe[TREE_LEVELS];
    wire final_last  = last_pipe[TREE_LEVELS];
    wire signed [ACC_WIDTH-1:0] sum_final = sum_pipe[TREE_LEVELS-1][0];
    wire signed [ACC_WIDTH-1:0] result_commit = accumulator + sum_final;

    wire signed [SCALE_EXT_WIDTH-1:0] scale_ext =
        {1'b0, deq_s1_scale};
    wire signed [DEQUANT_WIDTH-1:0] dequant_mul =
        deq_s1_raw * scale_ext;
    wire signed [ACC_WIDTH-1:0] result_dequant =
        dequant_mul >>> SCALE_FRAC_BITS;

    wire bypass_dequant = (deq_s1_scale == FP16_ONE);
    wire signed [ACC_WIDTH-1:0] result_final_value =
        bypass_dequant ? deq_s1_raw : result_dequant;

    wire row_commit = final_valid && final_last;
    wire fifo_push  = deq_s2_valid;
    wire fifo_pop   = result_fire;

    always @(posedge CLK) begin
        if (!RST) begin
            accumulator <= {ACC_WIDTH{1'b0}};
            deq_s1_valid <= 1'b0;
            deq_s1_last  <= 1'b0;
            deq_s1_raw   <= {ACC_WIDTH{1'b0}};
            deq_s1_scale <= {SCALE_WIDTH{1'b0}};
            deq_s2_valid <= 1'b0;
            deq_s2_last  <= 1'b0;
            deq_s2_value <= {ACC_WIDTH{1'b0}};
            fifo_wr_ptr <= {FIFO_PTR_WIDTH{1'b0}};
            fifo_rd_ptr <= {FIFO_PTR_WIDTH{1'b0}};
            fifo_count  <= {FIFO_COUNT_WIDTH{1'b0}};

            for (k = 0; k < RESULT_FIFO_DEPTH; k = k + 1) begin
                result_fifo_data[k] <= {ACC_WIDTH{1'b0}};
                result_fifo_last[k] <= 1'b0;
            end
        end else begin
            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + {{(FIFO_PTR_WIDTH-1){1'b0}}, 1'b1};

            if (fifo_push) begin
                result_fifo_data[fifo_wr_ptr] <= deq_s2_value;
                result_fifo_last[fifo_wr_ptr] <= deq_s2_last;
                fifo_wr_ptr <= fifo_wr_ptr + {{(FIFO_PTR_WIDTH-1){1'b0}}, 1'b1};
            end

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                2'b01: fifo_count <= fifo_count - {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                default: fifo_count <= fifo_count;
            endcase

            if (final_valid) begin
                if (final_last)
                    accumulator <= {ACC_WIDTH{1'b0}};
                else
                    accumulator <= result_commit;
            end

            deq_s1_valid <= row_commit;
            deq_s1_last  <= row_commit;
            if (row_commit) begin
                deq_s1_raw   <= result_commit;
                deq_s1_scale <= scale_pipe[TREE_LEVELS];
            end

            deq_s2_valid <= deq_s1_valid;
            deq_s2_last  <= deq_s1_last;
            if (deq_s1_valid)
                deq_s2_value <= result_final_value;
        end
    end

endmodule
