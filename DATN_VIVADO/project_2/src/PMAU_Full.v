/*
 *-----------------------------------------------------------------------------
 * Module      : PMAU_Full
 * Description : Pipelined parallel multiply-accumulate datapath for GEMV.
 *
 * PMAU_Full is the arithmetic core used by Matrix_Vector_Multiplication.  It
 * receives one activation beat and one weight beat through an internal
 * valid/ready interface, where each beat contains NUM_LANES signed INT8
 * elements.  On every accepted beat, lane i of activation is multiplied by
 * lane i of weight using one mult_gen_0 instance, so the default 16-lane
 * configuration performs 16 signed INT8xINT8 multiplications in parallel.
 *
 * Datapath flow:
 * - input handshake accepts a paired activation/weight beat only when both
 *   sides are valid, their last flags match, and enough result FIFO capacity
 *   remains for rows already in flight;
 * - NUM_LANES DSP-backed multiplier IP instances produce signed products after
 *   the configured mult_gen_0 pipeline delay;
 * - a registered binary adder tree reduces all lane products into one INT32
 *   partial sum for the accepted beat;
 * - the accumulator adds partial sums across all beats belonging to the
 *   current row or packed q8 block, then commits raw_result when last is
 *   asserted;
 * - dequant/post-scale either bypasses raw_result for 16'h3c00 or applies the
 *   fixed-point scale_factor and right shift;
 * - the result FIFO decouples the arithmetic pipeline from GEMV result writes.
 *
 * PMAU_Full does not know BRAM addresses, row numbers, DMA transfers, or AXI
 * transactions.  GEMV provides correctly aligned data and last flags, then
 * consumes result_data/result_valid through result_ready.
 * compute_mode and scalar_axpy are kept at the interface for mode expansion,
 * but the current MAC/accumulate/dequant datapath is controlled by the input
 * valid/ready handshake, last flags, and scale_factor.
 *
 * Constraints and assumptions:
 * - NUM_LANES and RESULT_FIFO_DEPTH must be powers of two.
 * - scale_factor is treated as a positive fixed-point value with
 *   SCALE_FRAC_BITS fractional bits.
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
    // Valid-independent admission predicate for a multi-PMAU producer.  The
    // existing ready signals intentionally depend on the opposite valid;
    // paired scheduling must inspect this predicate before offering either
    // lane so one PMAU can never consume alone on a readiness skew.
    output wire                              input_ready,
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
    localparam FIFO_PTR_WIDTH    = clog2(RESULT_FIFO_DEPTH);
    localparam FIFO_COUNT_WIDTH  = FIFO_PTR_WIDTH + 1;
    localparam SCALE_EXT_WIDTH   = SCALE_WIDTH + 1;
    localparam DEQUANT_WIDTH     = ACC_WIDTH + SCALE_EXT_WIDTH;
    // Must match mult_gen_0.xci C_LATENCY/PipeStages.  The current IP is
    // intentionally configured for three stages to meet the timing target.
    localparam MULT_IP_LATENCY   = 3;
    localparam [FIFO_COUNT_WIDTH-1:0] FIFO_DEPTH_COUNT = RESULT_FIFO_DEPTH;
    localparam [SCALE_WIDTH-1:0] FP16_ONE = 16'h3c00;

    // valid_pipe[0] is the multiply stage.  valid_pipe[TREE_LEVELS] is the
    // final registered adder-tree result.
    reg valid_pipe [0:TREE_LEVELS];
    reg last_pipe  [0:TREE_LEVELS];
    reg [SCALE_WIDTH-1:0] scale_pipe [0:TREE_LEVELS];
    reg mult_valid_pipe [0:MULT_IP_LATENCY];
    reg mult_last_pipe  [0:MULT_IP_LATENCY];
    reg [SCALE_WIDTH-1:0] mult_scale_pipe [0:MULT_IP_LATENCY];

    reg                         deq_s1_valid;
    reg                         deq_s1_last;
    reg signed [ACC_WIDTH-1:0]  deq_s1_raw;
    reg [SCALE_WIDTH-1:0]       deq_s1_scale;

    reg                         deq_s2_valid;
    reg                         deq_s2_last;
    reg                         deq_s2_bypass;
    reg signed [ACC_WIDTH-1:0]  deq_s2_raw;
    reg signed [DEQUANT_WIDTH-1:0] deq_s2_mul;

    reg                         deq_s3_valid;
    reg                         deq_s3_last;
    reg signed [ACC_WIDTH-1:0]  deq_s3_value;

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

    // Track completed rows that have entered the arithmetic pipeline but have
    // not reached the result FIFO yet.  The previous implementation rebuilt
    // this value every cycle with two procedural for-loops.  A sequential
    // occupancy counter removes that popcount/adder network from the input
    // ready path while preserving the same reservation semantics.
    reg [FIFO_COUNT_WIDTH-1:0] inflight_result_count;

    // GEMV accepts PMAU input beats only in S_RUN and consumes PMAU results
    // only in S_WAIT_RESULT, so result_fire and input_fire cannot occur in
    // the same cycle.  Keep admission conservative when the FIFO is full;
    // excluding the same-cycle pop removes a result-ready-to-input-ready
    // combinational feedback path that otherwise stretches the timing cone.
    wire [FIFO_COUNT_WIDTH-1:0] reserved_result_slots =
        fifo_count + inflight_result_count;

    wire both_inputs_valid = activation_valid && weight_valid;
    wire incoming_last_match = (activation_last == weight_last);

    assign input_ready = (!activation_last) ||
                         (reserved_result_slots < FIFO_DEPTH_COUNT);

    // Ready is deliberately independent of the opposite valid.  GEMV presents
    // activation/weight together, while input_fire below still requires both
    // valids and matching last flags.  This removes the row-lane valid mask
    // from the PMAU-ready feedback path without changing beat acceptance.
    assign activation_ready = input_ready && incoming_last_match;
    assign weight_ready     = input_ready && incoming_last_match;

    wire input_fire = both_inputs_valid && input_ready && incoming_last_match;
    wire accepted_row_end = input_fire && activation_last && weight_last;

    // A beat is accepted only when activation and weight arrive together and
    // their last flags agree.  If the beat completes a row/block, PMAU also
    // reserves one future FIFO slot before accepting it.

    // -------------------------------------------------------------------------
    // Stage 0: signed INT8 x INT8 Vivado multiplier IP instances
    // -------------------------------------------------------------------------
    wire signed [MULT_WIDTH-1:0] mult_ip_product [0:NUM_LANES-1];
    reg  signed [ACT_WIDTH-1:0]  mult_act_reg    [0:NUM_LANES-1];
    reg  signed [WEIGHT_WIDTH-1:0] mult_weight_reg [0:NUM_LANES-1];
    reg  signed [MULT_WIDTH-1:0] mult_pipe [0:NUM_LANES-1];

    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < NUM_LANES; lane_g = lane_g + 1) begin : GEN_MULT
            mult_gen_0 u_mult_gen_0 (
                .CLK (CLK),
                .A   (mult_act_reg[lane_g]),
                .B   (mult_weight_reg[lane_g]),
                .P   (mult_ip_product[lane_g])
            );
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
    integer mult_lat_i;
    always @(posedge CLK) begin
        if (!RST) begin
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                mult_act_reg[k]    <= {ACT_WIDTH{1'b0}};
                mult_weight_reg[k] <= {WEIGHT_WIDTH{1'b0}};
                mult_pipe[k] <= {MULT_WIDTH{1'b0}};
            end

            for (mult_lat_i = 0; mult_lat_i <= MULT_IP_LATENCY; mult_lat_i = mult_lat_i + 1) begin
                mult_valid_pipe[mult_lat_i] <= 1'b0;
                mult_last_pipe[mult_lat_i]  <= 1'b0;
                mult_scale_pipe[mult_lat_i] <= {SCALE_WIDTH{1'b0}};
            end

            for (level_i = 0; level_i <= TREE_LEVELS; level_i = level_i + 1) begin
                valid_pipe[level_i] <= 1'b0;
                last_pipe[level_i]  <= 1'b0;
                scale_pipe[level_i] <= {SCALE_WIDTH{1'b0}};
            end

            for (level_i = 0; level_i < TREE_LEVELS; level_i = level_i + 1)
                for (node_i = 0; node_i < HALF_LANES; node_i = node_i + 1)
                    sum_pipe[level_i][node_i] <= {ACC_WIDTH{1'b0}};
        end else begin
            // Stage 0 captures signed INT8 lane operands for the Vivado
            // multiplier IPs.  When no beat is accepted, operands are driven to
            // zero so stale values cannot create a false product with valid=0.
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                if (input_fire) begin
                    mult_act_reg[k] <=
                        activation_data[ACT_WIDTH*k +: ACT_WIDTH];
                    mult_weight_reg[k] <=
                        weight_data[WEIGHT_WIDTH*k +: WEIGHT_WIDTH];
                end else begin
                    mult_act_reg[k]    <= {ACT_WIDTH{1'b0}};
                    mult_weight_reg[k] <= {WEIGHT_WIDTH{1'b0}};
                end
            end

            mult_valid_pipe[0] <= input_fire;
            mult_last_pipe[0]  <= input_fire && activation_last && weight_last;
            if (input_fire)
                mult_scale_pipe[0] <= scale_factor;

            for (mult_lat_i = 1; mult_lat_i <= MULT_IP_LATENCY; mult_lat_i = mult_lat_i + 1) begin
                // Delay valid/last/scale through the same number of cycles as
                // mult_gen_0 so metadata stays aligned with the products.
                mult_valid_pipe[mult_lat_i] <= mult_valid_pipe[mult_lat_i-1];
                mult_last_pipe[mult_lat_i]  <= mult_last_pipe[mult_lat_i-1];
                mult_scale_pipe[mult_lat_i] <= mult_scale_pipe[mult_lat_i-1];
            end

            valid_pipe[0] <= mult_valid_pipe[MULT_IP_LATENCY];
            last_pipe[0]  <= mult_last_pipe[MULT_IP_LATENCY];
            scale_pipe[0] <= mult_scale_pipe[MULT_IP_LATENCY];

            for (k = 0; k < NUM_LANES; k = k + 1)
                if (mult_valid_pipe[MULT_IP_LATENCY])
                    mult_pipe[k] <= mult_ip_product[k];

            for (level_i = 0; level_i < TREE_LEVELS; level_i = level_i + 1) begin
                // Each adder-tree level is registered.  This shortens the
                // combinational add path and lets one partial sum advance per
                // cycle once the pipeline is filled.
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

    wire row_commit = final_valid && final_last;
    wire fifo_push  = deq_s3_valid;
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
            deq_s2_bypass <= 1'b0;
            deq_s2_raw <= {ACC_WIDTH{1'b0}};
            deq_s2_mul <= {DEQUANT_WIDTH{1'b0}};
            deq_s3_valid <= 1'b0;
            deq_s3_last  <= 1'b0;
            deq_s3_value <= {ACC_WIDTH{1'b0}};
            fifo_wr_ptr <= {FIFO_PTR_WIDTH{1'b0}};
            fifo_rd_ptr <= {FIFO_PTR_WIDTH{1'b0}};
            fifo_count  <= {FIFO_COUNT_WIDTH{1'b0}};
            inflight_result_count <= {FIFO_COUNT_WIDTH{1'b0}};

            for (k = 0; k < RESULT_FIFO_DEPTH; k = k + 1) begin
                result_fifo_data[k] <= {ACC_WIDTH{1'b0}};
                result_fifo_last[k] <= 1'b0;
            end
        end else begin
            // FIFO pop is controlled by GEMV's result_ready.  FIFO push happens
            // after dequant stage 2.  Simultaneous push/pop keeps occupancy
            // unchanged while still advancing both pointers.
            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + {{(FIFO_PTR_WIDTH-1){1'b0}}, 1'b1};

            if (fifo_push) begin
                result_fifo_data[fifo_wr_ptr] <= deq_s3_value;
                result_fifo_last[fifo_wr_ptr] <= deq_s3_last;
                fifo_wr_ptr <= fifo_wr_ptr + {{(FIFO_PTR_WIDTH-1){1'b0}}, 1'b1};
            end

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                2'b01: fifo_count <= fifo_count - {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                default: fifo_count <= fifo_count;
            endcase

            case ({accepted_row_end, fifo_push})
                // accepted_row_end reserves capacity for a result that has
                // entered the arithmetic pipeline but has not reached FIFO yet.
                // fifo_push releases that reservation because the result is now
                // accounted for in fifo_count.
                2'b10: inflight_result_count <= inflight_result_count +
                                                     {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                2'b01: inflight_result_count <= inflight_result_count -
                                                     {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1};
                default: inflight_result_count <= inflight_result_count;
            endcase

            if (final_valid) begin
                // Accumulate one adder-tree partial sum per beat.  On the beat
                // marked last, commit accumulator + current partial as the raw
                // row/block result and clear the accumulator for the next one.
                if (final_last)
                    accumulator <= {ACC_WIDTH{1'b0}};
                else
                    accumulator <= result_commit;
            end

            deq_s1_valid <= row_commit;
            deq_s1_last  <= row_commit;
            if (row_commit) begin
                // Dequant stage 1 captures the raw INT32 result and the scale
                // value that was pipelined alongside this row/block.
                deq_s1_raw   <= result_commit;
                deq_s1_scale <= scale_pipe[TREE_LEVELS];
            end

            deq_s2_valid <= deq_s1_valid;
            deq_s2_last  <= deq_s1_last;
            if (deq_s1_valid) begin
                // Dequant stage 2 is the DSP multiply stage.
                deq_s2_bypass <= (deq_s1_scale == FP16_ONE);
                deq_s2_raw    <= deq_s1_raw;
                deq_s2_mul    <= deq_s1_raw *
                                  $signed({1'b0, deq_s1_scale});
            end

            deq_s3_valid <= deq_s2_valid;
            deq_s3_last  <= deq_s2_last;
            if (deq_s2_valid) begin
                // Dequant stage 3 performs the shift/output selection after
                // the multiplier result has crossed a register boundary.
                deq_s3_value <= deq_s2_bypass ?
                                deq_s2_raw :
                                (deq_s2_mul >>> SCALE_FRAC_BITS);
            end
        end
    end

endmodule
