from pathlib import Path
import re


def rep(s, old, new, label):
    n = s.count(old)
    if n != 1:
        raise RuntimeError(f"{label}: expected 1 match, got {n}")
    return s.replace(old, new, 1)


def regex_rep(s, pat, new, label, flags=0):
    out, n = re.subn(pat, new, s, count=1, flags=flags)
    if n != 1:
        raise RuntimeError(f"{label}: expected 1 match, got {n}")
    return out

# ---------------------------------------------------------------------------
# Matrix_Vector_Multiplication: 4 rows -> 8 rows, one 8-row SPU bundle.
# ---------------------------------------------------------------------------
p = Path("RTL/Matrix_Vector_Multiplication.v")
s = p.read_text()

s = rep(s,
"""    output reg  [31:0]                       spu_raw_pair_scale_index,\n\n    input  wire                              mm_wr_en,""",
"""    output reg  [31:0]                       spu_raw_pair_scale_index,\n    // Native x8 VPU->SPU bundle. Lane 0 aliases spu_raw_*, lane 1 aliases\n    // spu_raw_pair_*. Shared block/job metadata remains on spu_raw_*.\n    output reg  [7:0]                        spu_raw_lane_valid,\n    output reg  [8*32-1:0]                   spu_raw_lane_data,\n    output reg  [8*16-1:0]                   spu_raw_lane_row,\n    output reg  [8*32-1:0]                   spu_raw_lane_scale_index,\n\n    input  wire                              mm_wr_en,""", "matrix ports")

s = s.replace("four logical row-slot leaves at 8K depth", "eight logical row-slot leaves at 4K depth")
s = s.replace("four SDP UltraRAM row-slot leaves", "eight SDP UltraRAM row-slot leaves")
s = s.replace("row[1:0] and (row >> 2)*col_beats + beat", "row[2:0] and (row >> 3)*col_beats + beat")
s = s.replace("Four 8K leaves replace\n    // two 16K parity leaves", "Eight 4K leaves replace\n    // the former four 8K row-slot leaves")
s = rep(s, "localparam WEIGHT_ROW_SLOT_LEAVES   = 4;", "localparam WEIGHT_ROW_SLOT_LEAVES   = 8;", "row slot leaves")

s = rep(s,
"""    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad3_compute_data;""",
"""    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad3_compute_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad4_compute_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad5_compute_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad6_compute_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0]  weight_quad7_compute_data;""", "weight compute regs")
s = rep(s,
"""    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad3_pmau_data;""",
"""    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad3_pmau_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad4_pmau_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad5_pmau_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad6_pmau_data;\n    reg [WEIGHT_BEAT_WIDTH-1:0] weight_quad7_pmau_data;""", "weight pmau regs")

s = rep(s,
"""    reg [12:0]                   weight_map_base_r;\n    reg [7:0]                    weight_map_base_rem_r;\n    reg                          weight_map_base_pair_odd_r;""",
"""    reg [WEIGHT_LOCAL_ADDR_WIDTH-1:0] weight_map_base_r;\n    reg [7:0]                    weight_map_base_rem_r;\n    reg [1:0]                    weight_map_base_pair_mod4_r;""", "weight base regs")
s = rep(s, "reg [1:0]                   weight_map_row_slot_r;", "reg [2:0]                   weight_map_row_slot_r;", "map row slot")
s = rep(s, "reg [1:0]                   weight_leaf_stage_row_slot_r [0:BANK_COUNT-1];", "reg [2:0]                   weight_leaf_stage_row_slot_r [0:BANK_COUNT-1];", "leaf row slot")

s = rep(s,
"""    reg signed [ACC_WIDTH-1:0] result_row3_data_r;\n    reg [RESULT_ADDR_WIDTH-1:0] result_row1_addr_r;""",
"""    reg signed [ACC_WIDTH-1:0] result_row3_data_r;\n    reg signed [ACC_WIDTH-1:0] result_row4_data_r;\n    reg signed [ACC_WIDTH-1:0] result_row5_data_r;\n    reg signed [ACC_WIDTH-1:0] result_row6_data_r;\n    reg signed [ACC_WIDTH-1:0] result_row7_data_r;\n    reg [RESULT_ADDR_WIDTH-1:0] result_row1_addr_r;""", "result data regs")
s = rep(s,
"""    reg [RESULT_ADDR_WIDTH-1:0] result_row3_addr_r;\n    reg [RESULT_I8_LANE_SHIFT-1:0] result_row1_lane_r;""",
"""    reg [RESULT_ADDR_WIDTH-1:0] result_row3_addr_r;\n    reg [RESULT_ADDR_WIDTH-1:0] result_row4_addr_r;\n    reg [RESULT_ADDR_WIDTH-1:0] result_row5_addr_r;\n    reg [RESULT_ADDR_WIDTH-1:0] result_row6_addr_r;\n    reg [RESULT_ADDR_WIDTH-1:0] result_row7_addr_r;\n    reg [RESULT_I8_LANE_SHIFT-1:0] result_row1_lane_r;""", "result addr regs")
s = rep(s,
"""    reg [RESULT_I8_LANE_SHIFT-1:0] result_row3_lane_r;\n    reg [1:0] result_write_slot_r;\n    reg result_writes_done_r;\n    reg raw_second_packet_r;\n    reg raw_first_packet_accepted_r;\n    reg raw_second_packet_accepted_r;""",
"""    reg [RESULT_I8_LANE_SHIFT-1:0] result_row3_lane_r;\n    reg [RESULT_I8_LANE_SHIFT-1:0] result_row4_lane_r;\n    reg [RESULT_I8_LANE_SHIFT-1:0] result_row5_lane_r;\n    reg [RESULT_I8_LANE_SHIFT-1:0] result_row6_lane_r;\n    reg [RESULT_I8_LANE_SHIFT-1:0] result_row7_lane_r;\n    reg [2:0] result_write_slot_r;\n    reg result_writes_done_r;\n    reg raw_bundle_accepted_r;""", "result control regs")

for name in ["read_req_row_slot_r","read_req_pair_row_slot_r","read_req_quad2_row_slot_r","read_req_quad3_row_slot_r",
             "read_row_slot_d_r","read_row_slot_q_r","read_row_slot_x_r","read_pair_row_slot_d_r","read_pair_row_slot_q_r","read_pair_row_slot_x_r",
             "read_quad2_row_slot_d_r","read_quad2_row_slot_q_r","read_quad2_row_slot_x_r","read_quad3_row_slot_d_r","read_quad3_row_slot_q_r","read_quad3_row_slot_x_r"]:
    s = regex_rep(s, rf"reg \[1:0\](\s+){name};", rf"reg [2:0]\1{name};", f"widen {name}")

s = rep(s,
"""    reg [1:0]                         read_req_quad3_row_slot_r;""",
"""    reg [2:0]                         read_req_quad3_row_slot_r;\n    reg [2:0]                         read_req_quad4_row_slot_r;\n    reg [2:0]                         read_req_quad5_row_slot_r;\n    reg [2:0]                         read_req_quad6_row_slot_r;\n    reg [2:0]                         read_req_quad7_row_slot_r;""", "req x8 slots") if "reg [1:0]                         read_req_quad3_row_slot_r;" in s else s
# Previous width loop may already have widened quad3. Insert x8 request slots after it.
s = rep(s, "reg [2:0]                         read_req_quad3_row_slot_r;", "reg [2:0]                         read_req_quad3_row_slot_r;\n    reg [2:0]                         read_req_quad4_row_slot_r;\n    reg [2:0]                         read_req_quad5_row_slot_r;\n    reg [2:0]                         read_req_quad6_row_slot_r;\n    reg [2:0]                         read_req_quad7_row_slot_r;", "insert req x8 slots")
s = rep(s, "reg [2:0] read_quad3_row_slot_x_r;", "reg [2:0] read_quad3_row_slot_x_r;\n    reg [2:0] read_quad4_row_slot_d_r, read_quad4_row_slot_q_r, read_quad4_row_slot_x_r;\n    reg [2:0] read_quad5_row_slot_d_r, read_quad5_row_slot_q_r, read_quad5_row_slot_x_r;\n    reg [2:0] read_quad6_row_slot_d_r, read_quad6_row_slot_q_r, read_quad6_row_slot_x_r;\n    reg [2:0] read_quad7_row_slot_d_r, read_quad7_row_slot_q_r, read_quad7_row_slot_x_r;", "insert pipe x8 slots")

s = rep(s,
"""    wire pair_lane3_valid = pair_mode_r && ((row_idx_r + 16'd3) < active_rows_r);""",
"""    wire pair_lane3_valid = pair_mode_r && ((row_idx_r + 16'd3) < active_rows_r);\n    wire pair_lane4_valid = pair_mode_r && ((row_idx_r + 16'd4) < active_rows_r);\n    wire pair_lane5_valid = pair_mode_r && ((row_idx_r + 16'd5) < active_rows_r);\n    wire pair_lane6_valid = pair_mode_r && ((row_idx_r + 16'd6) < active_rows_r);\n    wire pair_lane7_valid = pair_mode_r && ((row_idx_r + 16'd7) < active_rows_r);""", "lane valid x8")

s = rep(s,
"""    wire [ACC_WIDTH-1:0] pmau4_result_data;\n    wire signed [7:0] pmau_result_i8;""",
"""    wire [ACC_WIDTH-1:0] pmau4_result_data;\n    wire pmau5_activation_ready, pmau5_weight_ready, pmau5_input_ready, pmau5_result_valid;\n    wire [ACC_WIDTH-1:0] pmau5_result_data;\n    wire pmau6_activation_ready, pmau6_weight_ready, pmau6_input_ready, pmau6_result_valid;\n    wire [ACC_WIDTH-1:0] pmau6_result_data;\n    wire pmau7_activation_ready, pmau7_weight_ready, pmau7_input_ready, pmau7_result_valid;\n    wire [ACC_WIDTH-1:0] pmau7_result_data;\n    wire pmau8_activation_ready, pmau8_weight_ready, pmau8_input_ready, pmau8_result_valid;\n    wire [ACC_WIDTH-1:0] pmau8_result_data;\n    wire signed [7:0] pmau_result_i8;""", "pmau x8 wires")

s = rep(s,
"""    wire pmau_all_results_valid = pmau_result_valid &&\n                                  (!pair_lane1_valid || pmau2_result_valid) &&\n                                  (!pair_lane2_valid || pmau3_result_valid) &&\n                                  (!pair_lane3_valid || pmau4_result_valid);\n    wire pmau_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau2_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau3_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau4_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pair_issue_grant = pmau_input_ready &&\n                            (!pair_lane1_valid || pmau2_input_ready) &&\n                            (!pair_lane2_valid || pmau3_input_ready) &&\n                            (!pair_lane3_valid || pmau4_input_ready);\n    wire pmau_offer_valid = feed_valid_r && pair_issue_grant;\n    wire pmau_input_fire =\n        pmau_offer_valid && pmau_activation_ready && pmau_weight_ready &&\n        (!pair_lane1_valid || (pmau2_activation_ready && pmau2_weight_ready)) &&\n        (!pair_lane2_valid || (pmau3_activation_ready && pmau3_weight_ready)) &&\n        (!pair_lane3_valid || (pmau4_activation_ready && pmau4_weight_ready));""",
"""    wire pmau_all_results_valid = pmau_result_valid &&\n                                  (!pair_lane1_valid || pmau2_result_valid) &&\n                                  (!pair_lane2_valid || pmau3_result_valid) &&\n                                  (!pair_lane3_valid || pmau4_result_valid) &&\n                                  (!pair_lane4_valid || pmau5_result_valid) &&\n                                  (!pair_lane5_valid || pmau6_result_valid) &&\n                                  (!pair_lane6_valid || pmau7_result_valid) &&\n                                  (!pair_lane7_valid || pmau8_result_valid);\n    wire pmau_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau2_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau3_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau4_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau5_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau6_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau7_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pmau8_result_ready = (state_r == S_WAIT_RESULT) && pmau_all_results_valid;\n    wire pair_issue_grant = pmau_input_ready &&\n                            (!pair_lane1_valid || pmau2_input_ready) &&\n                            (!pair_lane2_valid || pmau3_input_ready) &&\n                            (!pair_lane3_valid || pmau4_input_ready) &&\n                            (!pair_lane4_valid || pmau5_input_ready) &&\n                            (!pair_lane5_valid || pmau6_input_ready) &&\n                            (!pair_lane6_valid || pmau7_input_ready) &&\n                            (!pair_lane7_valid || pmau8_input_ready);\n    wire pmau_offer_valid = feed_valid_r && pair_issue_grant;\n    wire pmau_input_fire =\n        pmau_offer_valid && pmau_activation_ready && pmau_weight_ready &&\n        (!pair_lane1_valid || (pmau2_activation_ready && pmau2_weight_ready)) &&\n        (!pair_lane2_valid || (pmau3_activation_ready && pmau3_weight_ready)) &&\n        (!pair_lane3_valid || (pmau4_activation_ready && pmau4_weight_ready)) &&\n        (!pair_lane4_valid || (pmau5_activation_ready && pmau5_weight_ready)) &&\n        (!pair_lane5_valid || (pmau6_activation_ready && pmau6_weight_ready)) &&\n        (!pair_lane6_valid || (pmau7_activation_ready && pmau7_weight_ready)) &&\n        (!pair_lane7_valid || (pmau8_activation_ready && pmau8_weight_ready));""", "pmau handshake x8")

s = rep(s,
"""    // Physical address = (row >> 2) * active_col_beats + beat.  The running\n    // base advances once per four-row group, and each logical row selects a\n    // distinct SDP leaf for atomic four-row P2 issue.\n    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] issue_weight_local_addr =\n        weight_row_base_r + read_abs_beat[WEIGHT_LOCAL_ADDR_WIDTH-1:0];\n    wire [1:0] issue_weight_row_slot = row_idx_r[1:0];\n    wire [1:0] issue_pair_weight_row_slot = row_idx_r[1:0] + 2'd1;\n    wire [1:0] issue_quad2_weight_row_slot = row_idx_r[1:0] + 2'd2;\n    wire [1:0] issue_quad3_weight_row_slot = row_idx_r[1:0] + 2'd3;""",
"""    // Physical address = (row >> 3) * active_col_beats + beat. Eight\n    // logical row slots allow one activation beat to feed eight PMAUs.\n    wire [WEIGHT_LOCAL_ADDR_WIDTH-1:0] issue_weight_local_addr =\n        weight_row_base_r + read_abs_beat[WEIGHT_LOCAL_ADDR_WIDTH-1:0];\n    wire [2:0] issue_weight_row_slot = row_idx_r[2:0];\n    wire [2:0] issue_pair_weight_row_slot = row_idx_r[2:0] + 3'd1;\n    wire [2:0] issue_quad2_weight_row_slot = row_idx_r[2:0] + 3'd2;\n    wire [2:0] issue_quad3_weight_row_slot = row_idx_r[2:0] + 3'd3;\n    wire [2:0] issue_quad4_weight_row_slot = row_idx_r[2:0] + 3'd4;\n    wire [2:0] issue_quad5_weight_row_slot = row_idx_r[2:0] + 3'd5;\n    wire [2:0] issue_quad6_weight_row_slot = row_idx_r[2:0] + 3'd6;\n    wire [2:0] issue_quad7_weight_row_slot = row_idx_r[2:0] + 3'd7;""", "issue slots x8")

s = rep(s,
"""    wire [31:0] quad3_result_value_index =\n        result_row_base_r + ({16'd0, group_blocks_r} * 3) + {16'd0, block_idx_r};""",
"""    wire [31:0] quad3_result_value_index =\n        result_row_base_r + ({16'd0, group_blocks_r} * 3) + {16'd0, block_idx_r};\n    wire [31:0] quad4_result_value_index =\n        result_row_base_r + ({16'd0, group_blocks_r} << 2) + {16'd0, block_idx_r};\n    wire [31:0] quad5_result_value_index =\n        result_row_base_r + ({16'd0, group_blocks_r} * 5) + {16'd0, block_idx_r};\n    wire [31:0] quad6_result_value_index =\n        result_row_base_r + ({16'd0, group_blocks_r} * 6) + {16'd0, block_idx_r};\n    wire [31:0] quad7_result_value_index =\n        result_row_base_r + ({16'd0, group_blocks_r} * 7) + {16'd0, block_idx_r};""", "result indices x8")
s = rep(s,
"""    wire [RESULT_LANE_SHIFT-1:0] quad3_result_wr_lane_i32 =\n        quad3_result_value_index[RESULT_LANE_SHIFT-1:0];""",
"""    wire [RESULT_LANE_SHIFT-1:0] quad3_result_wr_lane_i32 =\n        quad3_result_value_index[RESULT_LANE_SHIFT-1:0];\n    wire [RESULT_ADDR_WIDTH-1:0] quad4_result_wr_addr_i32 = quad4_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];\n    wire [RESULT_LANE_SHIFT-1:0] quad4_result_wr_lane_i32 = quad4_result_value_index[RESULT_LANE_SHIFT-1:0];\n    wire [RESULT_ADDR_WIDTH-1:0] quad5_result_wr_addr_i32 = quad5_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];\n    wire [RESULT_LANE_SHIFT-1:0] quad5_result_wr_lane_i32 = quad5_result_value_index[RESULT_LANE_SHIFT-1:0];\n    wire [RESULT_ADDR_WIDTH-1:0] quad6_result_wr_addr_i32 = quad6_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];\n    wire [RESULT_LANE_SHIFT-1:0] quad6_result_wr_lane_i32 = quad6_result_value_index[RESULT_LANE_SHIFT-1:0];\n    wire [RESULT_ADDR_WIDTH-1:0] quad7_result_wr_addr_i32 = quad7_result_value_index[RESULT_LANE_SHIFT +: RESULT_ADDR_WIDTH];\n    wire [RESULT_LANE_SHIFT-1:0] quad7_result_wr_lane_i32 = quad7_result_value_index[RESULT_LANE_SHIFT-1:0];""", "result addresses x8")

pmau_extra = r'''

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
'''
s = rep(s, "\n    VPU_Result_Requantizer #(\n", pmau_extra + "\n    VPU_Result_Requantizer #(\n", "insert PMAUs 5-8")

# 8-slot write remapper.
s = rep(s, "weight_map_base_r <= 13'd0;", "weight_map_base_r <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};", "base reset")
s = rep(s, "weight_map_base_pair_odd_r <= 1'b0;", "weight_map_base_pair_mod4_r <= 2'd0;", "base pair reset")
s = rep(s,
"""                weight_map_base_r <=\n                    (weight_map_delta_r -\n                     (weight_map_delta_pair_r[0] ?\n                      weight_map_delta_col_beats_r[13:0] : 14'd0)) >> 1;\n                weight_map_base_rem_r <= weight_map_delta_rem_r;\n                weight_map_base_pair_odd_r <= weight_map_delta_pair_r[0];""",
"""                weight_map_base_r <=\n                    (weight_map_delta_r -\n                     (weight_map_delta_pair_r[1] ? {weight_map_delta_col_beats_r[12:0],1'b0} : 14'd0) -\n                     (weight_map_delta_pair_r[0] ? weight_map_delta_col_beats_r[13:0] : 14'd0)) >> 2;\n                weight_map_base_rem_r <= weight_map_delta_rem_r;\n                weight_map_base_pair_mod4_r <= weight_map_delta_pair_r[1:0];""", "base mapping x8")
s = rep(s, "weight_map_row_slot_r <= 2'd0;", "weight_map_row_slot_r <= 3'd0;", "map row reset")
s = rep(s,
"""                weight_map_row_slot_r <= {weight_map_base_pair_odd_r,\n                                          weight_map_base_parity_r};""",
"""                weight_map_row_slot_r <= {weight_map_base_pair_mod4_r,\n                                          weight_map_base_parity_r};""", "map row x8")
s = s.replace("before driving the four row-slot leaves", "before driving the eight row-slot leaves")
s = rep(s, "weight_leaf_stage_row_slot_r[wr_top_bank_i] <= 2'd0;", "weight_leaf_stage_row_slot_r[wr_top_bank_i] <= 3'd0;", "leaf reset")
s = s.replace("four fixed logical-row leaves", "eight fixed logical-row leaves")
s = s.replace("four 8K SDP URAM leaves for logical row slots, allowing all four P2 rows", "eight 4K SDP URAM leaves for logical row slots, allowing all eight P2 rows")
s = s.replace("compute-read port for all modes; four-row P2 selects", "compute-read port for all modes; eight-row P2 selects")

# Weight read mux x8.
s = rep(s,
"""        weight_quad3_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};""",
"""        weight_quad3_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};\n        weight_quad4_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};\n        weight_quad5_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};\n        weight_quad6_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};\n        weight_quad7_compute_data = {WEIGHT_BEAT_WIDTH{1'b0}};""", "mux zero x8")
s = rep(s,
"""            weight_quad3_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =\n                weight_compute_data_leaf[\n                    WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT +\n                                        mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad3_row_slot_x_r)\n                    +: WEIGHT_BANK_WIDTH\n                ];""",
"""            weight_quad3_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =\n                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad3_row_slot_x_r) +: WEIGHT_BANK_WIDTH];\n            weight_quad4_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =\n                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad4_row_slot_x_r) +: WEIGHT_BANK_WIDTH];\n            weight_quad5_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =\n                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad5_row_slot_x_r) +: WEIGHT_BANK_WIDTH];\n            weight_quad6_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =\n                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad6_row_slot_x_r) +: WEIGHT_BANK_WIDTH];\n            weight_quad7_compute_data[WEIGHT_BANK_WIDTH*mux_bank_i +: WEIGHT_BANK_WIDTH] =\n                weight_compute_data_leaf[WEIGHT_BANK_WIDTH*(active_bank_r*WEIGHT_RAM_COUNT + mux_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_quad7_row_slot_x_r) +: WEIGHT_BANK_WIDTH];""", "mux x8")

# Reset additions.
s = rep(s, "result_row3_data_r <= {ACC_WIDTH{1'b0}};", "result_row3_data_r <= {ACC_WIDTH{1'b0}};\n            result_row4_data_r <= {ACC_WIDTH{1'b0}}; result_row5_data_r <= {ACC_WIDTH{1'b0}};\n            result_row6_data_r <= {ACC_WIDTH{1'b0}}; result_row7_data_r <= {ACC_WIDTH{1'b0}};", "reset result data")
s = rep(s, "result_row3_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};", "result_row3_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};\n            result_row4_addr_r <= {RESULT_ADDR_WIDTH{1'b0}}; result_row5_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};\n            result_row6_addr_r <= {RESULT_ADDR_WIDTH{1'b0}}; result_row7_addr_r <= {RESULT_ADDR_WIDTH{1'b0}};", "reset result addr")
s = rep(s, "result_row3_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};", "result_row3_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};\n            result_row4_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}}; result_row5_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};\n            result_row6_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}}; result_row7_lane_r <= {RESULT_I8_LANE_SHIFT{1'b0}};", "reset result lane")
s = rep(s,
"""            result_write_slot_r <= 2'd0;\n            result_writes_done_r <= 1'b0;\n            raw_second_packet_r <= 1'b0;\n            raw_first_packet_accepted_r <= 1'b0;\n            raw_second_packet_accepted_r <= 1'b0;""",
"""            result_write_slot_r <= 3'd0;\n            result_writes_done_r <= 1'b0;\n            raw_bundle_accepted_r <= 1'b0;""", "reset bundle ctl")
s = rep(s, "spu_raw_pair_scale_index <= 32'd0;", "spu_raw_pair_scale_index <= 32'd0;\n            spu_raw_lane_valid <= 8'd0;\n            spu_raw_lane_data <= 256'd0;\n            spu_raw_lane_row <= 128'd0;\n            spu_raw_lane_scale_index <= 256'd0;", "reset bundle outputs")

for name in ["read_req_row_slot_r","read_req_pair_row_slot_r","read_req_quad2_row_slot_r","read_req_quad3_row_slot_r",
             "read_row_slot_d_r","read_row_slot_q_r","read_row_slot_x_r","read_pair_row_slot_d_r","read_pair_row_slot_q_r","read_pair_row_slot_x_r",
             "read_quad2_row_slot_d_r","read_quad2_row_slot_q_r","read_quad2_row_slot_x_r","read_quad3_row_slot_d_r","read_quad3_row_slot_q_r","read_quad3_row_slot_x_r"]:
    s = s.replace(f"{name} <= 2'd0;", f"{name} <= 3'd0;")
s = rep(s, "read_req_quad3_row_slot_r <= 3'd0;", "read_req_quad3_row_slot_r <= 3'd0;\n            read_req_quad4_row_slot_r <= 3'd0; read_req_quad5_row_slot_r <= 3'd0;\n            read_req_quad6_row_slot_r <= 3'd0; read_req_quad7_row_slot_r <= 3'd0;", "reset req extra")
s = rep(s, "read_quad3_row_slot_x_r <= 3'd0;", "read_quad3_row_slot_x_r <= 3'd0;\n            read_quad4_row_slot_d_r <= 3'd0; read_quad4_row_slot_q_r <= 3'd0; read_quad4_row_slot_x_r <= 3'd0;\n            read_quad5_row_slot_d_r <= 3'd0; read_quad5_row_slot_q_r <= 3'd0; read_quad5_row_slot_x_r <= 3'd0;\n            read_quad6_row_slot_d_r <= 3'd0; read_quad6_row_slot_q_r <= 3'd0; read_quad6_row_slot_x_r <= 3'd0;\n            read_quad7_row_slot_d_r <= 3'd0; read_quad7_row_slot_q_r <= 3'd0; read_quad7_row_slot_x_r <= 3'd0;", "reset pipe extra")
s = rep(s, "weight_quad3_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};", "weight_quad3_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};\n            weight_quad4_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}}; weight_quad5_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};\n            weight_quad6_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}}; weight_quad7_pmau_data <= {WEIGHT_BEAT_WIDTH{1'b0}};", "reset pmau extra")

# Pipeline x8 additions.
s = rep(s, "weight_quad3_pmau_data <= weight_quad3_compute_data;", "weight_quad3_pmau_data <= weight_quad3_compute_data;\n                        weight_quad4_pmau_data <= weight_quad4_compute_data;\n                        weight_quad5_pmau_data <= weight_quad5_compute_data;\n                        weight_quad6_pmau_data <= weight_quad6_compute_data;\n                        weight_quad7_pmau_data <= weight_quad7_compute_data;", "capture weights x8")
s = rep(s, "read_quad3_row_slot_x_r <= read_quad3_row_slot_q_r;", "read_quad3_row_slot_x_r <= read_quad3_row_slot_q_r;\n                        read_quad4_row_slot_x_r <= read_quad4_row_slot_q_r;\n                        read_quad5_row_slot_x_r <= read_quad5_row_slot_q_r;\n                        read_quad6_row_slot_x_r <= read_quad6_row_slot_q_r;\n                        read_quad7_row_slot_x_r <= read_quad7_row_slot_q_r;", "q2x x8")
s = rep(s, "read_quad3_row_slot_q_r <= read_quad3_row_slot_d_r;", "read_quad3_row_slot_q_r <= read_quad3_row_slot_d_r;\n                        read_quad4_row_slot_q_r <= read_quad4_row_slot_d_r;\n                        read_quad5_row_slot_q_r <= read_quad5_row_slot_d_r;\n                        read_quad6_row_slot_q_r <= read_quad6_row_slot_d_r;\n                        read_quad7_row_slot_q_r <= read_quad7_row_slot_d_r;", "d2q x8")

# Add x8 leaf read enables after lane3 block.
needle = """                            if (pair_lane3_valid) begin\n                                weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT +\n                                                       fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad3_row_slot_r]\n                                    <= 1'b1;\n                                weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT +\n                                                         fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad3_row_slot_r]\n                                    <= read_req_weight_addr_r;\n                            end"""
extra = needle + """\n                            if (pair_lane4_valid) begin\n                                weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad4_row_slot_r] <= 1'b1;\n                                weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad4_row_slot_r] <= read_req_weight_addr_r;\n                            end\n                            if (pair_lane5_valid) begin\n                                weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad5_row_slot_r] <= 1'b1;\n                                weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad5_row_slot_r] <= read_req_weight_addr_r;\n                            end\n                            if (pair_lane6_valid) begin\n                                weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad6_row_slot_r] <= 1'b1;\n                                weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad6_row_slot_r] <= read_req_weight_addr_r;\n                            end\n                            if (pair_lane7_valid) begin\n                                weight_compute_en_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad7_row_slot_r] <= 1'b1;\n                                weight_compute_addr_leaf[active_bank_r*WEIGHT_RAM_COUNT + fsm_bank_i*WEIGHT_ROW_SLOT_LEAVES + read_req_quad7_row_slot_r] <= read_req_weight_addr_r;\n                            end"""
s = rep(s, needle, extra, "read enables x8")
s = rep(s, "read_quad3_row_slot_d_r <= read_req_quad3_row_slot_r;", "read_quad3_row_slot_d_r <= read_req_quad3_row_slot_r;\n                        read_quad4_row_slot_d_r <= read_req_quad4_row_slot_r;\n                        read_quad5_row_slot_d_r <= read_req_quad5_row_slot_r;\n                        read_quad6_row_slot_d_r <= read_req_quad6_row_slot_r;\n                        read_quad7_row_slot_d_r <= read_req_quad7_row_slot_r;", "req2d x8")
s = rep(s, "read_req_quad3_row_slot_r <= issue_quad3_weight_row_slot;", "read_req_quad3_row_slot_r <= issue_quad3_weight_row_slot;\n                        read_req_quad4_row_slot_r <= issue_quad4_weight_row_slot;\n                        read_req_quad5_row_slot_r <= issue_quad5_weight_row_slot;\n                        read_req_quad6_row_slot_r <= issue_quad6_weight_row_slot;\n                        read_req_quad7_row_slot_r <= issue_quad7_weight_row_slot;", "issue req x8")

# Replace raw result handling states. INT8 path remains single-row, x8 only applies to raw group mode.
new_states = r'''                S_WAIT_RESULT: begin
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
                            result_write_pending_r <= 1'b1;
                            result_write_addr_r <= result_wr_addr;
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
                            result_writes_done_r <= 1'b0;
                            raw_bundle_accepted_r <= 1'b0;

                            spu_raw_valid <= 1'b0;
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
                    feed_valid_r <= 1'b0;
                    if (result_writeback_fire) begin
                        case (result_write_slot_r)
                            3'd0: if (pair_lane1_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row1_addr_r; result_write_lane_r<=result_row1_lane_r; result_write_i32_r<=result_row1_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd1; end else result_writes_done_r<=1'b1;
                            3'd1: if (pair_lane2_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row2_addr_r; result_write_lane_r<=result_row2_lane_r; result_write_i32_r<=result_row2_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd2; end else result_writes_done_r<=1'b1;
                            3'd2: if (pair_lane3_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row3_addr_r; result_write_lane_r<=result_row3_lane_r; result_write_i32_r<=result_row3_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd3; end else result_writes_done_r<=1'b1;
                            3'd3: if (pair_lane4_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row4_addr_r; result_write_lane_r<=result_row4_lane_r; result_write_i32_r<=result_row4_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd4; end else result_writes_done_r<=1'b1;
                            3'd4: if (pair_lane5_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row5_addr_r; result_write_lane_r<=result_row5_lane_r; result_write_i32_r<=result_row5_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd5; end else result_writes_done_r<=1'b1;
                            3'd5: if (pair_lane6_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row6_addr_r; result_write_lane_r<=result_row6_lane_r; result_write_i32_r<=result_row6_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd6; end else result_writes_done_r<=1'b1;
                            3'd6: if (pair_lane7_valid) begin result_write_pending_r<=1'b1; result_write_addr_r<=result_row7_addr_r; result_write_lane_r<=result_row7_lane_r; result_write_i32_r<=result_row7_data_r; result_write_is_i8_r<=1'b0; result_write_slot_r<=3'd7; end else result_writes_done_r<=1'b1;
                            default: result_writes_done_r <= 1'b1;
                        endcase
                        spu_raw_valid <= 1'b1;
                    end
                    if (spu_raw_valid && spu_raw_ready) begin
                        spu_raw_valid <= 1'b0;
                        spu_raw_pair_valid <= 1'b0;
                        spu_raw_lane_valid <= 8'd0;
                        raw_bundle_accepted_r <= 1'b1;
                    end
                    if (result_writes_done_r && raw_bundle_accepted_r) begin
                        if ((block_idx_r + 16'd1) < group_blocks_r) begin
                            block_idx_r <= block_idx_r + 16'd1;
                            state_r <= S_RUN;
                        end else begin
                            block_idx_r <= 16'd0;
                            if ((row_idx_r + (pair_mode_r ? 16'd8 : 16'd1)) >= active_rows_r) begin
                                state_r <= S_DRAIN_RESULT;
                            end else begin
                                row_idx_r <= row_idx_r + (pair_mode_r ? 16'd8 : 16'd1);
                                read_beat_idx_r <= 16'd0;
                                result_row_base_r <= result_row_base_r +
                                    (pair_mode_r ? ({16'd0,group_blocks_r} << 3) : {16'd0,group_blocks_r});
                                if (pair_mode_r || (row_idx_r[2:0] == 3'd7))
                                    weight_row_base_r <= weight_row_base_r + active_col_beats_r;
                                state_r <= S_RUN;
                            end
                        end
                    end
                end

'''
s = regex_rep(s, r"                S_WAIT_RESULT: begin.*?                S_ACCUM_WAIT: begin", new_states + "                S_ACCUM_WAIT: begin", "replace raw states", re.S)

# Legacy single-row path shares groups of 8 slots now.
s = s.replace("if (row_idx_r[1:0] == 2'd3)\n                            weight_row_base_r", "if (row_idx_r[2:0] == 3'd7)\n                            weight_row_base_r")
s = s.replace("Four\n                        // logical row slots", "Eight\n                        // logical row slots")

p.write_text(s)

# ---------------------------------------------------------------------------
# SPU_Top: select new 8-lane engine for the production AXI-mapped instance.
# ---------------------------------------------------------------------------
p = Path("RTL/SPU_Top.v")
s = p.read_text()
s = rep(s, "parameter integer STREAM_TEST_STALL_ENABLE = 0", "parameter integer STREAM_TEST_STALL_ENABLE = 0,\n    parameter integer VPU_BUNDLE8_ENABLE = 0", "spu param")
s = rep(s,
"""    input  wire [31:0]                       vpu_raw_pair_scale_index,\n    output wire [31:0]                       vpu_stream_count,""",
"""    input  wire [31:0]                       vpu_raw_pair_scale_index,\n    input  wire [7:0]                        vpu_raw_lane_valid,\n    input  wire [8*32-1:0]                   vpu_raw_lane_data,\n    input  wire [8*16-1:0]                   vpu_raw_lane_row,\n    input  wire [8*32-1:0]                   vpu_raw_lane_scale_index,\n    output wire [31:0]                       vpu_stream_count,""", "spu bundle ports")

s = rep(s, "wire stream_push = vpu_raw_valid && vpu_raw_ready;", "wire stream_push = (VPU_BUNDLE8_ENABLE == 0) && vpu_raw_valid && legacy_vpu_raw_ready;", "legacy push")
s = rep(s,
"""    assign vpu_raw_ready = resetn && !stream_fifo_full && !stream_test_stall &&\n                           !stream_p3_bank_mismatch &&\n                           (!stream_split_scale_enable || !spu_busy);""",
"""    wire legacy_vpu_raw_ready = resetn && !stream_fifo_full && !stream_test_stall &&\n                           !stream_p3_bank_mismatch &&\n                           (!stream_split_scale_enable || !spu_busy);""", "legacy ready")

# Rename legacy memory arbitration nets; final nets are muxed below.
for name in ["core_mem_en","core_mem_we","core_mem_region","core_mem_index","core_mem_wdata","core_mem_wstrb",
             "core_mem2_en","core_mem2_we","core_mem2_region","core_mem2_index","core_mem2_wdata","core_mem2_wstrb",
             "core_mem3_scratch_en","core_mem3_scratch_index"]:
    s = regex_rep(s, rf"wire(\s+){name}(\s*=)", rf"wire\1legacy_{name}\2", f"rename {name}")

# Insert x8 stream instance before capability map.
anchor = "    // Capability map:\n"
bundle_block = r'''    wire bundle8_active = (VPU_BUNDLE8_ENABLE != 0);
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

'''
s = rep(s, anchor, bundle_block + anchor, "insert stream8")

# Counter/status mux. Keep legacy state unchanged for direct old testbenches.
assign_map = {
"vpu_stream_count":"vpu_stream_count_r","vpu_stream_done_count":"vpu_stream_done_count_r","vpu_stream_drop_count":"vpu_stream_drop_count_r",
"vpu_stream_out_count":"vpu_stream_out_count_r","vpu_stream_error_count":"vpu_stream_error_count_r","vpu_stream_last_raw":"vpu_stream_last_raw_r",
"vpu_stream_last_meta":"vpu_stream_last_meta_r","vpu_stream_last_accum_lo":"vpu_stream_last_accum_lo_r","vpu_stream_last_accum_hi":"vpu_stream_last_accum_hi_r",
"vpu_stream_last_job":"vpu_stream_last_job_r","vpu_stream_last_bank":"vpu_stream_last_bank_r","vpu_stream_fifo_high_water":"vpu_stream_fifo_high_water_r",
"vpu_stream_raw_stall_cycles":"vpu_stream_raw_stall_cycles_r","vpu_stream_entry_done_count":"vpu_stream_entry_done_count_r",
"vpu_stream_final_write_count":"vpu_stream_final_write_count_r","vpu_stream_p3_reject_count":"vpu_stream_p3_reject_count_r"}
b8_map = {"vpu_stream_count":"b8_count","vpu_stream_done_count":"b8_done_count","vpu_stream_drop_count":"b8_drop_count","vpu_stream_out_count":"b8_out_count",
"vpu_stream_error_count":"b8_error_count","vpu_stream_last_raw":"b8_last_raw","vpu_stream_last_meta":"b8_last_meta","vpu_stream_last_accum_lo":"b8_last_accum_lo",
"vpu_stream_last_accum_hi":"b8_last_accum_hi","vpu_stream_last_job":"b8_last_job","vpu_stream_last_bank":"b8_last_bank","vpu_stream_fifo_high_water":"b8_high_water",
"vpu_stream_raw_stall_cycles":"b8_stall_cycles","vpu_stream_entry_done_count":"b8_entry_done_count","vpu_stream_final_write_count":"b8_final_write_count","vpu_stream_p3_reject_count":"b8_p3_reject_count"}
for out, old in assign_map.items():
    s = regex_rep(s, rf"assign\s+{out}\s*=\s*{old};", f"assign {out} = bundle8_active ? {b8_map[out]} : {old};", f"mux {out}")
# Status bit block and p3 status are replaced with whole-word mux while preserving legacy internal status on a private wire.
s = rep(s, "assign vpu_stream_status[0]     = stream_idle;", "wire [31:0] legacy_stream_status;\n    assign legacy_stream_status[0] = stream_idle;", "legacy status0")
for bit in range(1,7):
    s = s.replace(f"assign vpu_stream_status[{bit}]", f"assign legacy_stream_status[{bit}]")
s = s.replace("assign vpu_stream_status[31:7]", "assign legacy_stream_status[31:7]")
s = rep(s,
"""    assign vpu_stream_p3_status = {24'd0,\n                                    stream_split_scale_enable,\n                                    stream_p3_done_seen_r,\n                                    stream_p3_bank_lock_r,\n                                    stream_p3_bank_lock_valid_r,\n                                    stream_p3_r,\n                                    stream_fifo_full,\n                                    stream_fifo_empty,\n                                    stream_idle};""",
"""    wire [31:0] legacy_stream_p3_status = {24'd0,\n                                    stream_split_scale_enable,\n                                    stream_p3_done_seen_r,\n                                    stream_p3_bank_lock_r,\n                                    stream_p3_bank_lock_valid_r,\n                                    stream_p3_r,\n                                    stream_fifo_full,\n                                    stream_fifo_empty,\n                                    stream_idle};\n    assign vpu_stream_status = bundle8_active ? b8_status : legacy_stream_status;\n    assign vpu_stream_p3_status = bundle8_active ? b8_p3_status : legacy_stream_p3_status;""", "mux status")

# Controller/lock ownership.
s = rep(s, ".start        (spu_start && !stream_p3_bank_lock_valid_r),", ".start        (spu_start && !effective_stream_lock_valid && (!bundle8_active || b8_status[4])),", "controller gate")
s = rep(s, ".stream_p3_bank_lock_valid(stream_p3_bank_lock_valid_r)", ".stream_p3_bank_lock_valid(effective_stream_lock_valid)", "lock valid mux")
s = rep(s, ".stream_p3_bank_lock(stream_p3_bank_lock_r)", ".stream_p3_bank_lock(effective_stream_lock_bank)", "lock bank mux")
p.write_text(s)

# ---------------------------------------------------------------------------
# AXI4_Mapping: carry the native 8-row bundle between VPU and SPU.
# ---------------------------------------------------------------------------
p = Path("RTL/AXI4_Mapping.v")
s = p.read_text()
s = rep(s,
"""    wire [31:0] core_spu_raw_pair_scale_index;\n    wire [31:0] spu_stream_count;""",
"""    wire [31:0] core_spu_raw_pair_scale_index;\n    wire [7:0] core_spu_raw_lane_valid;\n    wire [8*32-1:0] core_spu_raw_lane_data;\n    wire [8*16-1:0] core_spu_raw_lane_row;\n    wire [8*32-1:0] core_spu_raw_lane_scale_index;\n    wire [31:0] spu_stream_count;""", "axi bundle wires")
s = rep(s,
"""        .spu_raw_pair_scale_index(core_spu_raw_pair_scale_index),\n        .mm_wr_en""",
"""        .spu_raw_pair_scale_index(core_spu_raw_pair_scale_index),\n        .spu_raw_lane_valid(core_spu_raw_lane_valid),\n        .spu_raw_lane_data(core_spu_raw_lane_data),\n        .spu_raw_lane_row(core_spu_raw_lane_row),\n        .spu_raw_lane_scale_index(core_spu_raw_lane_scale_index),\n        .mm_wr_en""", "axi matrix bundle")
s = rep(s, ".STREAM_TEST_STALL_ENABLE (SPU_STREAM_TEST_STALL_ENABLE)\n    ) u_spu", ".STREAM_TEST_STALL_ENABLE (SPU_STREAM_TEST_STALL_ENABLE),\n        .VPU_BUNDLE8_ENABLE (1)\n    ) u_spu", "axi enable bundle")
s = rep(s,
"""        .vpu_raw_pair_scale_index(core_spu_raw_pair_scale_index),\n        .vpu_stream_count""",
"""        .vpu_raw_pair_scale_index(core_spu_raw_pair_scale_index),\n        .vpu_raw_lane_valid(core_spu_raw_lane_valid),\n        .vpu_raw_lane_data(core_spu_raw_lane_data),\n        .vpu_raw_lane_row(core_spu_raw_lane_row),\n        .vpu_raw_lane_scale_index(core_spu_raw_lane_scale_index),\n        .vpu_stream_count""", "axi spu bundle")
p.write_text(s)

print("Applied x8 VPU + 8-lane VPU/SPU stream RTL transformation")
