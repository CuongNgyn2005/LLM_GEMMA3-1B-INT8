from pathlib import Path

CANON = Path("RTL/SPU_VPU_Stream8.v")
MIRROR = Path("DATN_VIVADO/project_2/src/SPU_VPU_Stream8.v")


def replace_once(text: str, old: str, new: str, name: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{name}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def patch(text: str) -> str:
    text = replace_once(
        text,
        " * Scale RAM is read two rows/cycle through the existing two PARAM ports;\n"
        " * all valid rows then execute SPU_Q8_Scale_Accum in parallel.\n"
        " *\n"
        " * A four-entry input FIFO decouples the VPU result handshake from the SPU\n"
        " * scale/accumulate FSM.  Its depth matches the VPU raw burst scheduler's\n"
        " * maximum four-block issue burst while preserving the external stream ABI.\n",
        " * Scale RAM is read two rows/cycle through the existing two PARAM ports;\n"
        " * all valid rows then execute SPU_Q8_Scale_Accum in parallel.  On the P2\n"
        " * path, the next queued bundle is scale-prefetched while the current eight\n"
        " * accumulators are busy, hiding the existing four READ/CAPTURE pairs without\n"
        " * changing accumulation order or the external stream ABI.\n"
        " *\n"
        " * A four-entry input FIFO decouples the VPU result handshake from the SPU\n"
        " * scale/accumulate FSM.  Its depth matches the VPU raw burst scheduler's\n"
        " * maximum four-block issue burst while preserving the external stream ABI.\n",
        "header",
    )

    text = replace_once(
        text,
        "    localparam [2:0] S_WAIT    = 3'd4;\n"
        "    localparam [2:0] S_WRITE   = 3'd5;\n\n"
        "    reg [2:0] state_r;\n",
        "    localparam [2:0] S_WAIT    = 3'd4;\n"
        "    localparam [2:0] S_WRITE   = 3'd5;\n\n"
        "    localparam [1:0] PF_IDLE    = 2'd0;\n"
        "    localparam [1:0] PF_READ    = 2'd1;\n"
        "    localparam [1:0] PF_CAPTURE = 2'd2;\n"
        "    localparam [1:0] PF_READY   = 2'd3;\n\n"
        "    reg [2:0] state_r;\n",
        "prefetch states",
    )

    text = replace_once(
        text,
        "    reg [15:0] p3_act_scale_r;\n"
        "    reg [7:0] accum_start_r;\n\n"
        "    // Four-entry x8 bundle FIFO.  Wide buses are kept packed so this remains\n",
        "    reg [15:0] p3_act_scale_r;\n"
        "    reg [7:0] accum_start_r;\n\n"
        "    // One P2 look-ahead slot owns a bundle after it leaves the FIFO.  Raw\n"
        "    // data/metadata and decoded scale addresses are copied immediately; the\n"
        "    // four scale pairs are then fetched while the active accumulators run.\n"
        "    reg [1:0] prefetch_state_r;\n"
        "    reg [1:0] prefetch_pair_idx_r;\n"
        "    reg [7:0] prefetch_lane_valid_r;\n"
        "    reg signed [31:0] prefetch_raw_r [0:7];\n"
        "    reg [15:0] prefetch_row_r [0:7];\n"
        "    reg [31:0] prefetch_scale_word_index_r [0:7];\n"
        "    reg [2:0] prefetch_scale_lane_r [0:7];\n"
        "    reg [15:0] prefetch_act_scale_r [0:7];\n"
        "    reg [15:0] prefetch_weight_scale_r [0:7];\n"
        "    reg [15:0] prefetch_block_r;\n"
        "    reg [15:0] prefetch_group_blocks_r;\n"
        "    reg prefetch_last_block_r;\n"
        "    reg prefetch_clear_accum_r;\n"
        "    reg [31:0] prefetch_job_id_r;\n"
        "    reg prefetch_bank_r;\n\n"
        "    // Four-entry x8 bundle FIFO.  Wide buses are kept packed so this remains\n",
        "prefetch registers",
    )

    text = replace_once(
        text,
        "    wire bank_mismatch = split_scale_enable && p3_bank_lock_valid &&\n"
        "                         (vpu_bank != p3_bank_lock);\n"
        "    wire fifo_empty = (fifo_count_r == 3'd0);\n"
        "    wire fifo_full = (fifo_count_r == 3'd4);\n"
        "    // The head can be removed in the same cycle that a new tail is accepted,\n"
        "    // so a full FIFO need not insert an avoidable bubble when the FSM is idle.\n"
        "    wire fifo_pop = !split_scale_enable && (state_r == S_IDLE) &&\n"
        "                    !command_busy && !fifo_empty;\n"
        "    wire p2_fifo_ready = resetn && !command_busy && (!fifo_full || fifo_pop);\n"
        "    wire p3_direct_ready = resetn && (state_r == S_IDLE) && !command_busy &&\n"
        "                           !bank_mismatch;\n"
        "    // P2 uses the four-entry FIFO. P3 deliberately keeps the original\n"
        "    // direct one-bundle handshake so the existing bank-lock protocol is not\n"
        "    // changed by this performance experiment.\n"
        "    assign vpu_ready = split_scale_enable ? p3_direct_ready : p2_fifo_ready;\n"
        "    wire vpu_fire = vpu_valid && vpu_ready;\n"
        "    wire fifo_push = !split_scale_enable && vpu_fire && bundle_index_ok;\n",
        "    wire bank_mismatch = split_scale_enable && p3_bank_lock_valid &&\n"
        "                         (vpu_bank != p3_bank_lock);\n"
        "    wire fifo_empty = (fifo_count_r == 3'd0);\n"
        "    wire fifo_full = (fifo_count_r == 3'd4);\n"
        "    wire prefetch_empty = (prefetch_state_r == PF_IDLE);\n"
        "    wire prefetch_ready = (prefetch_state_r == PF_READY);\n"
        "    // The normal S_IDLE dequeue feeds the active bundle.  While a non-final\n"
        "    // P2 block is accumulating, a second dequeue feeds the look-ahead slot.\n"
        "    // Restrict prefetch to non-final blocks so SPU_OUT writes never contend\n"
        "    // with the look-ahead PARAM reads.\n"
        "    wire fifo_active_pop = !split_scale_enable && (state_r == S_IDLE) &&\n"
        "                           prefetch_empty && !command_busy && !fifo_empty;\n"
        "    wire fifo_prefetch_pop = !split_scale_enable && (state_r == S_WAIT) &&\n"
        "                             !last_block_r && prefetch_empty &&\n"
        "                             !command_busy && !fifo_empty;\n"
        "    wire fifo_pop = fifo_active_pop || fifo_prefetch_pop;\n"
        "    // Either dequeue may replace the head of a full FIFO in the same cycle.\n"
        "    wire p2_fifo_ready = resetn && !command_busy && (!fifo_full || fifo_pop);\n"
        "    wire p3_direct_ready = resetn && (state_r == S_IDLE) && !command_busy &&\n"
        "                           !bank_mismatch;\n"
        "    // P2 uses the four-entry FIFO plus one internal look-ahead slot. P3\n"
        "    // deliberately keeps the original direct one-bundle handshake so the\n"
        "    // existing bank-lock protocol is unchanged.\n"
        "    assign vpu_ready = split_scale_enable ? p3_direct_ready : p2_fifo_ready;\n"
        "    wire vpu_fire = vpu_valid && vpu_ready;\n"
        "    wire fifo_push = !split_scale_enable && vpu_fire && bundle_index_ok;\n",
        "fifo dequeue policy",
    )

    text = replace_once(
        text,
        "    wire [2:0] lane0_sel = {pair_idx_r, 1'b0};\n"
        "    wire [2:0] lane1_sel = {pair_idx_r, 1'b1};\n"
        "    wire [31:0] p3_bank_base = bank_r ? P3_BANK_WORD_DEPTH : 32'd0;\n",
        "    wire [2:0] lane0_sel = {pair_idx_r, 1'b0};\n"
        "    wire [2:0] lane1_sel = {pair_idx_r, 1'b1};\n"
        "    wire [2:0] prefetch_lane0_sel = {prefetch_pair_idx_r, 1'b0};\n"
        "    wire [2:0] prefetch_lane1_sel = {prefetch_pair_idx_r, 1'b1};\n"
        "    wire [31:0] prefetch_lane0_word_index =\n"
        "        prefetch_scale_word_index_r[prefetch_lane0_sel];\n"
        "    wire [31:0] prefetch_lane1_word_index =\n"
        "        prefetch_scale_word_index_r[prefetch_lane1_sel];\n"
        "    wire [2:0] prefetch_lane0_scale_lane =\n"
        "        prefetch_scale_lane_r[prefetch_lane0_sel];\n"
        "    wire [2:0] prefetch_lane1_scale_lane =\n"
        "        prefetch_scale_lane_r[prefetch_lane1_sel];\n"
        "    wire [31:0] p3_bank_base = bank_r ? P3_BANK_WORD_DEPTH : 32'd0;\n",
        "prefetch selectors",
    )

    text = replace_once(
        text,
        "    wire any_accum_error = |(accum_error & lane_valid_r);\n"
        "    wire stream_engine_idle = split_scale_enable ?\n"
        "                              (state_r == S_IDLE) :\n"
        "                              ((state_r == S_IDLE) && fifo_empty);\n\n"
        "    always @* begin\n"
        "        mem0_en = 1'b0; mem0_we = 1'b0; mem0_region = REGION_PARAM;\n"
        "        mem0_index = 32'd0; mem0_wdata = {AXI_DATA_WIDTH{1'b0}};\n"
        "        mem0_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};\n"
        "        mem1_en = 1'b0; mem1_we = 1'b0; mem1_region = REGION_PARAM;\n"
        "        mem1_index = 32'd0; mem1_wdata = {AXI_DATA_WIDTH{1'b0}};\n"
        "        mem1_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};\n"
        "        mem3_scratch_en = 1'b0; mem3_scratch_index = 32'd0;\n\n"
        "        if (state_r == S_READ) begin\n"
        "            if (lane_valid_r[lane0_sel]) begin\n"
        "                mem0_en = 1'b1;\n"
        "                mem0_index = lane0_word_index;\n"
        "            end\n"
        "            if (lane_valid_r[lane1_sel]) begin\n"
        "                mem1_en = 1'b1;\n"
        "                mem1_index = lane1_word_index;\n"
        "            end\n"
        "            if (p3_r && (pair_idx_r == 2'd0)) begin\n"
        "                mem3_scratch_en = 1'b1;\n"
        "                mem3_scratch_index = p3_act_word_index;\n"
        "            end\n"
        "        end else if (state_r == S_WRITE) begin\n"
        "            if (lane_valid_r[lane0_sel]) begin\n"
        "                mem0_en = 1'b1; mem0_we = 1'b1; mem0_region = REGION_OUT;\n"
        "                mem0_index = {16'd0,row_r[lane0_sel]};\n"
        "                mem0_wdata = {{(AXI_DATA_WIDTH-80){1'b0}},final_q16_r[lane0_sel],row_r[lane0_sel]};\n"
        "                mem0_wstrb = 16'h03ff;\n"
        "            end\n"
        "            if (lane_valid_r[lane1_sel]) begin\n"
        "                mem1_en = 1'b1; mem1_we = 1'b1; mem1_region = REGION_OUT;\n"
        "                mem1_index = {16'd0,row_r[lane1_sel]};\n"
        "                mem1_wdata = {{(AXI_DATA_WIDTH-80){1'b0}},final_q16_r[lane1_sel],row_r[lane1_sel]};\n"
        "                mem1_wstrb = 16'h03ff;\n"
        "            end\n"
        "        end\n"
        "    end\n",
        "    wire any_accum_error = |(accum_error & lane_valid_r);\n"
        "    wire stream_engine_idle = split_scale_enable ?\n"
        "                              (state_r == S_IDLE) :\n"
        "                              ((state_r == S_IDLE) && fifo_empty && prefetch_empty);\n"
        "    wire prefetch_mem_available = !split_scale_enable &&\n"
        "                                  (state_r != S_READ) &&\n"
        "                                  (state_r != S_CAPTURE) &&\n"
        "                                  (state_r != S_WRITE);\n\n"
        "    always @* begin\n"
        "        mem0_en = 1'b0; mem0_we = 1'b0; mem0_region = REGION_PARAM;\n"
        "        mem0_index = 32'd0; mem0_wdata = {AXI_DATA_WIDTH{1'b0}};\n"
        "        mem0_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};\n"
        "        mem1_en = 1'b0; mem1_we = 1'b0; mem1_region = REGION_PARAM;\n"
        "        mem1_index = 32'd0; mem1_wdata = {AXI_DATA_WIDTH{1'b0}};\n"
        "        mem1_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};\n"
        "        mem3_scratch_en = 1'b0; mem3_scratch_index = 32'd0;\n\n"
        "        if (state_r == S_READ) begin\n"
        "            if (lane_valid_r[lane0_sel]) begin\n"
        "                mem0_en = 1'b1;\n"
        "                mem0_index = lane0_word_index;\n"
        "            end\n"
        "            if (lane_valid_r[lane1_sel]) begin\n"
        "                mem1_en = 1'b1;\n"
        "                mem1_index = lane1_word_index;\n"
        "            end\n"
        "            if (p3_r && (pair_idx_r == 2'd0)) begin\n"
        "                mem3_scratch_en = 1'b1;\n"
        "                mem3_scratch_index = p3_act_word_index;\n"
        "            end\n"
        "        end else if (state_r == S_WRITE) begin\n"
        "            if (lane_valid_r[lane0_sel]) begin\n"
        "                mem0_en = 1'b1; mem0_we = 1'b1; mem0_region = REGION_OUT;\n"
        "                mem0_index = {16'd0,row_r[lane0_sel]};\n"
        "                mem0_wdata = {{(AXI_DATA_WIDTH-80){1'b0}},final_q16_r[lane0_sel],row_r[lane0_sel]};\n"
        "                mem0_wstrb = 16'h03ff;\n"
        "            end\n"
        "            if (lane_valid_r[lane1_sel]) begin\n"
        "                mem1_en = 1'b1; mem1_we = 1'b1; mem1_region = REGION_OUT;\n"
        "                mem1_index = {16'd0,row_r[lane1_sel]};\n"
        "                mem1_wdata = {{(AXI_DATA_WIDTH-80){1'b0}},final_q16_r[lane1_sel],row_r[lane1_sel]};\n"
        "                mem1_wstrb = 16'h03ff;\n"
        "            end\n"
        "        end else if ((prefetch_state_r == PF_READ) && prefetch_mem_available) begin\n"
        "            if (prefetch_lane_valid_r[prefetch_lane0_sel]) begin\n"
        "                mem0_en = 1'b1;\n"
        "                mem0_index = prefetch_lane0_word_index;\n"
        "            end\n"
        "            if (prefetch_lane_valid_r[prefetch_lane1_sel]) begin\n"
        "                mem1_en = 1'b1;\n"
        "                mem1_index = prefetch_lane1_word_index;\n"
        "            end\n"
        "        end\n"
        "    end\n",
        "memory arbitration",
    )

    text = replace_once(
        text,
        "            fifo_count_r <= 3'd0; fifo_wr_ptr_r <= 2'd0; fifo_rd_ptr_r <= 2'd0;\n"
        "            write_count <= 4'd0;\n"
        "            for (i = 0; i < 8; i = i + 1) begin\n"
        "                raw_r[i] <= 32'sd0; row_r[i] <= 16'd0;\n"
        "                scale_word_index_r[i] <= 32'd0; scale_lane_r[i] <= 3'd0;\n"
        "                act_scale_r[i] <= 16'd0; weight_scale_r[i] <= 16'd0;\n"
        "                final_q16_r[i] <= 64'sd0;\n"
        "            end\n",
        "            fifo_count_r <= 3'd0; fifo_wr_ptr_r <= 2'd0; fifo_rd_ptr_r <= 2'd0;\n"
        "            prefetch_state_r <= PF_IDLE; prefetch_pair_idx_r <= 2'd0;\n"
        "            prefetch_lane_valid_r <= 8'd0;\n"
        "            prefetch_block_r <= 16'd0; prefetch_group_blocks_r <= 16'd0;\n"
        "            prefetch_last_block_r <= 1'b0; prefetch_clear_accum_r <= 1'b0;\n"
        "            prefetch_job_id_r <= 32'd0; prefetch_bank_r <= 1'b0;\n"
        "            write_count <= 4'd0;\n"
        "            for (i = 0; i < 8; i = i + 1) begin\n"
        "                raw_r[i] <= 32'sd0; row_r[i] <= 16'd0;\n"
        "                scale_word_index_r[i] <= 32'd0; scale_lane_r[i] <= 3'd0;\n"
        "                act_scale_r[i] <= 16'd0; weight_scale_r[i] <= 16'd0;\n"
        "                final_q16_r[i] <= 64'sd0;\n"
        "                prefetch_raw_r[i] <= 32'sd0; prefetch_row_r[i] <= 16'd0;\n"
        "                prefetch_scale_word_index_r[i] <= 32'd0;\n"
        "                prefetch_scale_lane_r[i] <= 3'd0;\n"
        "                prefetch_act_scale_r[i] <= 16'd0;\n"
        "                prefetch_weight_scale_r[i] <= 16'd0;\n"
        "            end\n",
        "prefetch reset",
    )

    text = replace_once(
        text,
        "            if (fifo_pop)\n"
        "                fifo_rd_ptr_r <= fifo_rd_ptr_r + 2'd1;\n\n"
        "            case (state_r)\n",
        "            if (fifo_pop)\n"
        "                fifo_rd_ptr_r <= fifo_rd_ptr_r + 2'd1;\n\n"
        "            // Pull the next non-final P2 bundle out of FIFO while the active\n"
        "            // accumulators are busy.  It owns this look-ahead slot until all\n"
        "            // four scale pairs have been captured.\n"
        "            if (fifo_prefetch_pop) begin\n"
        "                prefetch_lane_valid_r <= fifo_lane_valid[fifo_rd_ptr_r];\n"
        "                for (i = 0; i < 8; i = i + 1) begin\n"
        "                    prefetch_raw_r[i] <= fifo_lane_data[fifo_rd_ptr_r][32*i +: 32];\n"
        "                    prefetch_row_r[i] <= fifo_lane_row[fifo_rd_ptr_r][16*i +: 16];\n"
        "                    prefetch_scale_word_index_r[i] <=\n"
        "                        fifo_scale_word_index[fifo_rd_ptr_r][32*i +: 32];\n"
        "                    prefetch_scale_lane_r[i] <= fifo_scale_lane[fifo_rd_ptr_r][3*i +: 3];\n"
        "                end\n"
        "                prefetch_block_r <= fifo_block[fifo_rd_ptr_r];\n"
        "                prefetch_group_blocks_r <= fifo_group_blocks[fifo_rd_ptr_r];\n"
        "                prefetch_last_block_r <= fifo_last_block[fifo_rd_ptr_r];\n"
        "                prefetch_clear_accum_r <= fifo_clear_accum[fifo_rd_ptr_r];\n"
        "                prefetch_job_id_r <= fifo_job_id[fifo_rd_ptr_r];\n"
        "                prefetch_bank_r <= fifo_bank[fifo_rd_ptr_r];\n"
        "                prefetch_pair_idx_r <= 2'd0;\n"
        "                prefetch_state_r <= PF_READ;\n"
        "            end\n\n"
        "            // Look-ahead scale reader.  It uses PARAM ports only when the\n"
        "            // active FSM is not reading/capturing scales or writing SPU_OUT.\n"
        "            // Keeping the same READ/CAPTURE cadence preserves the synchronous\n"
        "            // BRAM timing contract; the latency is hidden under S_WAIT.\n"
        "            if (!split_scale_enable) begin\n"
        "                case (prefetch_state_r)\n"
        "                    PF_READ: begin\n"
        "                        if (prefetch_mem_available)\n"
        "                            prefetch_state_r <= PF_CAPTURE;\n"
        "                    end\n"
        "                    PF_CAPTURE: begin\n"
        "                        if (prefetch_mem_available) begin\n"
        "                            if (prefetch_lane_valid_r[prefetch_lane0_sel]) begin\n"
        "                                prefetch_act_scale_r[prefetch_lane0_sel] <=\n"
        "                                    mem0_rdata[32*prefetch_lane0_scale_lane +: 16];\n"
        "                                prefetch_weight_scale_r[prefetch_lane0_sel] <=\n"
        "                                    mem0_rdata[32*prefetch_lane0_scale_lane+16 +: 16];\n"
        "                            end\n"
        "                            if (prefetch_lane_valid_r[prefetch_lane1_sel]) begin\n"
        "                                prefetch_act_scale_r[prefetch_lane1_sel] <=\n"
        "                                    mem1_rdata[32*prefetch_lane1_scale_lane +: 16];\n"
        "                                prefetch_weight_scale_r[prefetch_lane1_sel] <=\n"
        "                                    mem1_rdata[32*prefetch_lane1_scale_lane+16 +: 16];\n"
        "                            end\n"
        "                            if (prefetch_pair_idx_r == 2'd3) begin\n"
        "                                prefetch_pair_idx_r <= 2'd0;\n"
        "                                prefetch_state_r <= PF_READY;\n"
        "                            end else begin\n"
        "                                prefetch_pair_idx_r <= prefetch_pair_idx_r + 2'd1;\n"
        "                                prefetch_state_r <= PF_READ;\n"
        "                            end\n"
        "                        end\n"
        "                    end\n"
        "                    default: begin end\n"
        "                endcase\n"
        "            end\n\n"
        "            case (state_r)\n",
        "prefetch engine",
    )

    text = replace_once(
        text,
        "                    end else if (fifo_pop) begin\n"
        "                        lane_valid_r <= fifo_lane_valid[fifo_rd_ptr_r];\n"
        "                        for (i = 0; i < 8; i = i + 1) begin\n"
        "                            raw_r[i] <= fifo_lane_data[fifo_rd_ptr_r][32*i +: 32];\n"
        "                            row_r[i] <= fifo_lane_row[fifo_rd_ptr_r][16*i +: 16];\n"
        "                            scale_word_index_r[i] <= fifo_scale_word_index[fifo_rd_ptr_r][32*i +: 32];\n"
        "                            scale_lane_r[i] <= fifo_scale_lane[fifo_rd_ptr_r][3*i +: 3];\n"
        "                        end\n"
        "                        block_r <= fifo_block[fifo_rd_ptr_r];\n"
        "                        group_blocks_r <= fifo_group_blocks[fifo_rd_ptr_r];\n"
        "                        last_block_r <= fifo_last_block[fifo_rd_ptr_r];\n"
        "                        clear_accum_r <= fifo_clear_accum[fifo_rd_ptr_r];\n"
        "                        job_id_r <= fifo_job_id[fifo_rd_ptr_r];\n"
        "                        bank_r <= fifo_bank[fifo_rd_ptr_r];\n"
        "                        p3_r <= 1'b0;\n"
        "                        pair_idx_r <= 2'd0;\n"
        "                        state_r <= S_READ;\n"
        "                    end\n",
        "                    end else if (prefetch_ready) begin\n"
        "                        // Scales are already captured, so bypass the normal\n"
        "                        // four READ/CAPTURE pairs and proceed directly to start.\n"
        "                        lane_valid_r <= prefetch_lane_valid_r;\n"
        "                        for (i = 0; i < 8; i = i + 1) begin\n"
        "                            raw_r[i] <= prefetch_raw_r[i];\n"
        "                            row_r[i] <= prefetch_row_r[i];\n"
        "                            scale_word_index_r[i] <= prefetch_scale_word_index_r[i];\n"
        "                            scale_lane_r[i] <= prefetch_scale_lane_r[i];\n"
        "                            act_scale_r[i] <= prefetch_act_scale_r[i];\n"
        "                            weight_scale_r[i] <= prefetch_weight_scale_r[i];\n"
        "                        end\n"
        "                        block_r <= prefetch_block_r;\n"
        "                        group_blocks_r <= prefetch_group_blocks_r;\n"
        "                        last_block_r <= prefetch_last_block_r;\n"
        "                        clear_accum_r <= prefetch_clear_accum_r;\n"
        "                        job_id_r <= prefetch_job_id_r;\n"
        "                        bank_r <= prefetch_bank_r;\n"
        "                        p3_r <= 1'b0;\n"
        "                        pair_idx_r <= 2'd0;\n"
        "                        prefetch_state_r <= PF_IDLE;\n"
        "                        state_r <= S_START;\n"
        "                    end else if (fifo_active_pop) begin\n"
        "                        lane_valid_r <= fifo_lane_valid[fifo_rd_ptr_r];\n"
        "                        for (i = 0; i < 8; i = i + 1) begin\n"
        "                            raw_r[i] <= fifo_lane_data[fifo_rd_ptr_r][32*i +: 32];\n"
        "                            row_r[i] <= fifo_lane_row[fifo_rd_ptr_r][16*i +: 16];\n"
        "                            scale_word_index_r[i] <= fifo_scale_word_index[fifo_rd_ptr_r][32*i +: 32];\n"
        "                            scale_lane_r[i] <= fifo_scale_lane[fifo_rd_ptr_r][3*i +: 3];\n"
        "                        end\n"
        "                        block_r <= fifo_block[fifo_rd_ptr_r];\n"
        "                        group_blocks_r <= fifo_group_blocks[fifo_rd_ptr_r];\n"
        "                        last_block_r <= fifo_last_block[fifo_rd_ptr_r];\n"
        "                        clear_accum_r <= fifo_clear_accum[fifo_rd_ptr_r];\n"
        "                        job_id_r <= fifo_job_id[fifo_rd_ptr_r];\n"
        "                        bank_r <= fifo_bank[fifo_rd_ptr_r];\n"
        "                        p3_r <= 1'b0;\n"
        "                        pair_idx_r <= 2'd0;\n"
        "                        state_r <= S_READ;\n"
        "                    end\n",
        "prefetched active handoff",
    )

    return text


before = CANON.read_text()
mirror_before = MIRROR.read_text()
if before != mirror_before:
    raise SystemExit("canonical/mirror mismatch before patch")

after = patch(before)
if after == before:
    raise SystemExit("patch made no changes")
CANON.write_text(after)
MIRROR.write_text(after)
print("SPU_VPU_Stream8 P2 look-ahead scale prefetch applied to canonical and Vivado mirror")
