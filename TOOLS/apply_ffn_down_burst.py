#!/usr/bin/env python3
from pathlib import Path

FILES = [
    Path("RTL/Matrix_Vector_Multiplication.v"),
    Path("DATN_VIVADO/project_2/src/Matrix_Vector_Multiplication.v"),
]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def patch(text: str) -> str:
    text = replace_once(
        text,
        "    localparam [15:0] Q8_BLOCK_BEATS_16     = 16'd2;\n",
        "    localparam [15:0] Q8_BLOCK_BEATS_16     = 16'd2;\n"
        "    // Raw P2 x8 mode may issue several Q8 blocks before retiring\n"
        "    // results. Four is deliberately below PMAU_Full's 8-entry result\n"
        "    // FIFO depth so every PMAU has deterministic reservation headroom.\n"
        "    localparam [2:0]  RAW_BURST_MAX          = 3'd4;\n",
        "RAW_BURST_MAX",
    )

    text = replace_once(
        text,
        "    reg [15:0] block_idx_r;\n    reg [15:0] group_blocks_r;\n",
        "    // block_idx_r is the oldest block awaiting retirement.\n"
        "    // issue_block_idx_r is the newest block currently being issued.\n"
        "    // Keeping them separate lets the PMAU result FIFOs absorb a short\n"
        "    // burst without changing result/scale ordering at the SPU boundary.\n"
        "    reg [15:0] block_idx_r;\n"
        "    reg [15:0] issue_block_idx_r;\n"
        "    reg [2:0]  raw_burst_blocks_r;\n"
        "    reg [2:0]  raw_burst_retired_r;\n"
        "    reg [15:0] group_blocks_r;\n",
        "burst declarations",
    )

    text = replace_once(
        text,
        "    wire pair_lane7_valid = pair_mode_r && ((row_idx_r + 16'd7) < active_rows_r);\n",
        "    wire pair_lane7_valid = pair_mode_r && ((row_idx_r + 16'd7) < active_rows_r);\n"
        "    // Restrict burst issue to the deployed P2 raw x8 path. Legacy/raw\n"
        "    // single-row and INT8 accumulation modes keep their original FSM.\n"
        "    wire raw_burst_mode = pair_mode_r && group_mode_r && !result_i8_mode_r;\n",
        "raw_burst_mode",
    )

    text = replace_once(
        text,
        "    wire [15:0] raw_group_issue_limit =\n"
        "        {block_idx_r[14:0], 1'b0} + Q8_BLOCK_BEATS_16;\n",
        "    wire [15:0] raw_issue_block_idx =\n"
        "        raw_burst_mode ? issue_block_idx_r : block_idx_r;\n"
        "    wire [15:0] raw_group_issue_limit =\n"
        "        {raw_issue_block_idx[14:0], 1'b0} + Q8_BLOCK_BEATS_16;\n",
        "issue block selector",
    )

    text = replace_once(
        text,
        "            block_idx_r          <= 16'd0;\n            group_blocks_r       <= 16'd1;\n",
        "            block_idx_r          <= 16'd0;\n"
        "            issue_block_idx_r    <= 16'd0;\n"
        "            raw_burst_blocks_r   <= 3'd0;\n"
        "            raw_burst_retired_r  <= 3'd0;\n"
        "            group_blocks_r       <= 16'd1;\n",
        "reset burst state",
    )

    text = replace_once(
        text,
        "                    block_idx_r        <= 16'd0;\n                    result_row_base_r  <= 32'd0;\n",
        "                    block_idx_r        <= 16'd0;\n"
        "                    issue_block_idx_r  <= 16'd0;\n"
        "                    raw_burst_blocks_r <= 3'd0;\n"
        "                    raw_burst_retired_r <= 3'd0;\n"
        "                    result_row_base_r  <= 32'd0;\n",
        "S_IDLE burst reset",
    )

    old_run_end = """                    if (pmau_input_fire && wait_after_feed) begin
                        // The last beat of the current row/block has entered
                        // PMAU.  Stop issuing input and wait for the pipeline
                        // to produce the corresponding result.
                        feed_valid_r    <= 1'b0;
                        compute_rd_en   <= 1'b0;
                        read_req_valid_r <= 1'b0;
                        read_valid_d_r  <= 1'b0;
                        read_valid_q_r  <= 1'b0;
                        read_valid_x_r  <= 1'b0;
                        state_r         <= S_WAIT_RESULT;
                    end
"""
    new_run_end = """                    if (pmau_input_fire && wait_after_feed) begin
                        // A raw P2 x8 block is two 128-bit beats. PMAU_Full has
                        // an 8-entry result FIFO, so keep up to four completed
                        // blocks in flight before switching to ordered retire.
                        // The read pipeline is flushed at each block boundary;
                        // this changes block-level scheduling only and leaves the
                        // existing BRAM/feed timing contract untouched.
                        feed_valid_r     <= 1'b0;
                        compute_rd_en    <= 1'b0;
                        read_req_valid_r <= 1'b0;
                        read_valid_d_r   <= 1'b0;
                        read_valid_q_r   <= 1'b0;
                        read_valid_x_r   <= 1'b0;

                        if (raw_burst_mode) begin
                            if (((issue_block_idx_r + 16'd1) < group_blocks_r) &&
                                (raw_burst_blocks_r < (RAW_BURST_MAX - 3'd1))) begin
                                // Continue issuing the next Q8 block. No PMAU
                                // result is popped until this burst is complete.
                                issue_block_idx_r   <= issue_block_idx_r + 16'd1;
                                raw_burst_blocks_r  <= raw_burst_blocks_r + 3'd1;
                                state_r             <= S_RUN;
                            end else begin
                                // Current block completes the burst (or group).
                                // Count it, then retire FIFO results in order.
                                raw_burst_blocks_r  <= raw_burst_blocks_r + 3'd1;
                                raw_burst_retired_r <= 3'd0;
                                state_r             <= S_WAIT_RESULT;
                            end
                        end else begin
                            state_r <= S_WAIT_RESULT;
                        end
                    end
"""
    text = replace_once(text, old_run_end, new_run_end, "S_RUN burst issue")

    old_raw_done = """                    if (result_writes_done_r && raw_bundle_accepted_r) begin
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
"""
    new_raw_done = """                    if (result_writes_done_r && raw_bundle_accepted_r) begin
                        if (raw_burst_mode) begin
                            if ((raw_burst_retired_r + 3'd1) < raw_burst_blocks_r) begin
                                // More results from this issued burst are already
                                // queued inside all active PMAUs. Advance only
                                // the retire-side block index and pop the next one.
                                raw_burst_retired_r <= raw_burst_retired_r + 3'd1;
                                block_idx_r         <= block_idx_r + 16'd1;
                                state_r             <= S_WAIT_RESULT;
                            end else begin
                                // Burst fully retired. Either issue the next
                                // burst in this row group or advance rows/job.
                                raw_burst_blocks_r  <= 3'd0;
                                raw_burst_retired_r <= 3'd0;
                                if ((issue_block_idx_r + 16'd1) < group_blocks_r) begin
                                    issue_block_idx_r <= issue_block_idx_r + 16'd1;
                                    block_idx_r       <= block_idx_r + 16'd1;
                                    state_r           <= S_RUN;
                                end else begin
                                    issue_block_idx_r <= 16'd0;
                                    block_idx_r       <= 16'd0;
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
                        end else begin
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
"""
    text = replace_once(text, old_raw_done, new_raw_done, "S_RAW_STREAM_HOLD ordered retire")

    # New launches from S_DONE and S_ERROR must reset both issue and retire
    # progress. There are exactly two matching launch snippets.
    old_restart = """                        block_idx_r         <= 16'd0;
                        result_row_base_r   <= 32'd0;
                        weight_row_base_r   <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                        state_r             <= S_VALIDATE;
"""
    new_restart = """                        block_idx_r         <= 16'd0;
                        issue_block_idx_r   <= 16'd0;
                        raw_burst_blocks_r  <= 3'd0;
                        raw_burst_retired_r <= 3'd0;
                        result_row_base_r   <= 32'd0;
                        weight_row_base_r   <= {WEIGHT_LOCAL_ADDR_WIDTH{1'b0}};
                        state_r             <= S_VALIDATE;
"""
    count = text.count(old_restart)
    if count != 2:
        raise RuntimeError(f"restart burst reset: expected two matches, found {count}")
    text = text.replace(old_restart, new_restart)

    return text


originals = [path.read_text() for path in FILES]
if originals[0] != originals[1]:
    raise RuntimeError("RTL and Vivado mirror differ before patch")

patched = [patch(text) for text in originals]
if patched[0] != patched[1]:
    raise RuntimeError("RTL and Vivado mirror differ after patch")

for path, text in zip(FILES, patched):
    path.write_text(text)
    print(f"patched {path}")
