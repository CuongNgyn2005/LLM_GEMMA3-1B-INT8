`timescale 1ns/1ps

module tb_SPU_Stream8_prefetch;
    // Global watchdog also bounds the retained original MMIO/ready waits.
    initial begin
        #2000000;
        $fatal(1,"FAIL prefetch global watchdog");
    end
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg soft_reset = 1'b0;
    reg command_busy = 1'b0;
    reg split_scale_enable = 1'b0;

    reg vpu_valid = 1'b0;
    wire vpu_ready;
    reg [7:0] vpu_lane_valid = 8'hff;
    reg [255:0] vpu_lane_data = 256'd0;
    reg [127:0] vpu_lane_row = 128'd0;
    reg [255:0] vpu_lane_scale_index = 256'd0;
    reg [15:0] vpu_block = 16'd0;
    reg [15:0] vpu_group_blocks = 16'd8;
    reg vpu_last_block = 1'b0;
    reg vpu_clear_accum = 1'b0;
    reg [31:0] vpu_job_id = 32'h13572468;
    reg vpu_bank = 1'b0;
    reg vpu_done = 1'b0;

    wire mem0_en, mem0_we, mem1_en, mem1_we, mem3_scratch_en;
    wire [1:0] mem0_region, mem1_region;
    wire [31:0] mem0_index, mem1_index, mem3_scratch_index;
    wire [127:0] mem0_wdata, mem1_wdata;
    wire [15:0] mem0_wstrb, mem1_wstrb;
    wire [127:0] mem0_rdata, mem1_rdata, mem3_scratch_rdata;
    wire p3_bank_lock_valid, p3_bank_lock;

    wire [31:0] stream_count, stream_done_count, stream_drop_count;
    wire [31:0] stream_out_count, stream_error_count;
    wire [31:0] stream_last_raw, stream_last_meta;
    wire [31:0] stream_last_accum_lo, stream_last_accum_hi;
    wire [31:0] stream_last_job, stream_last_bank, stream_status;
    wire [31:0] stream_fifo_high_water, stream_raw_stall_cycles;
    wire [31:0] stream_entry_done_count, stream_final_write_count;
    wire [31:0] stream_p3_reject_count, stream_p3_status;

    reg mm_wr_en = 1'b0;
    reg [1:0] mm_wr_region = 2'd0;
    reg [31:0] mm_wr_index = 32'd0;
    reg [127:0] mm_wr_data = 128'd0;
    reg [15:0] mm_wr_strb = 16'd0;
    reg mm_rd_en = 1'b0;
    reg [1:0] mm_rd_region = 2'd0;
    reg [31:0] mm_rd_index = 32'd0;
    wire [127:0] mm_rd_data;
    wire mm_rd_valid, mm_rd_error, mm_wr_rejected;

    SPU_VPU_Stream8 dut (
        .clk(clk), .resetn(resetn), .soft_reset(soft_reset), .command_busy(command_busy),
        .split_scale_enable(split_scale_enable),
        .vpu_valid(vpu_valid), .vpu_ready(vpu_ready), .vpu_lane_valid(vpu_lane_valid),
        .vpu_lane_data(vpu_lane_data), .vpu_lane_row(vpu_lane_row),
        .vpu_lane_scale_index(vpu_lane_scale_index), .vpu_block(vpu_block),
        .vpu_group_blocks(vpu_group_blocks), .vpu_last_block(vpu_last_block),
        .vpu_clear_accum(vpu_clear_accum), .vpu_job_id(vpu_job_id), .vpu_bank(vpu_bank),
        .vpu_done(vpu_done),
        .mem0_en(mem0_en), .mem0_we(mem0_we), .mem0_region(mem0_region),
        .mem0_index(mem0_index), .mem0_wdata(mem0_wdata), .mem0_wstrb(mem0_wstrb),
        .mem0_rdata(mem0_rdata), .mem1_en(mem1_en), .mem1_we(mem1_we),
        .mem1_region(mem1_region), .mem1_index(mem1_index), .mem1_wdata(mem1_wdata),
        .mem1_wstrb(mem1_wstrb), .mem1_rdata(mem1_rdata),
        .mem3_scratch_en(mem3_scratch_en), .mem3_scratch_index(mem3_scratch_index),
        .mem3_scratch_rdata(mem3_scratch_rdata), .p3_bank_lock_valid(p3_bank_lock_valid),
        .p3_bank_lock(p3_bank_lock), .stream_count(stream_count),
        .stream_done_count(stream_done_count), .stream_drop_count(stream_drop_count),
        .stream_out_count(stream_out_count), .stream_error_count(stream_error_count),
        .stream_last_raw(stream_last_raw), .stream_last_meta(stream_last_meta),
        .stream_last_accum_lo(stream_last_accum_lo), .stream_last_accum_hi(stream_last_accum_hi),
        .stream_last_job(stream_last_job), .stream_last_bank(stream_last_bank),
        .stream_status(stream_status), .stream_fifo_high_water(stream_fifo_high_water),
        .stream_raw_stall_cycles(stream_raw_stall_cycles),
        .stream_entry_done_count(stream_entry_done_count),
        .stream_final_write_count(stream_final_write_count),
        .stream_p3_reject_count(stream_p3_reject_count), .stream_p3_status(stream_p3_status)
    );

    SPU_Local_Memory #(.AXI_DATA_WIDTH(128), .WORD_DEPTH(4096)) mem (
        .clk(clk), .resetn(resetn),
        .mm_wr_en(mm_wr_en), .mm_wr_region(mm_wr_region), .mm_wr_index(mm_wr_index),
        .mm_wr_data(mm_wr_data), .mm_wr_strb(mm_wr_strb),
        .mm_rd_en(mm_rd_en), .mm_rd_region(mm_rd_region), .mm_rd_index(mm_rd_index),
        .mm_rd_data(mm_rd_data), .mm_rd_valid(mm_rd_valid), .mm_rd_error(mm_rd_error),
        .core_en(mem0_en), .core_we(mem0_we), .core_region(mem0_region), .core_index(mem0_index),
        .core_wdata(mem0_wdata), .core_wstrb(mem0_wstrb), .core_rdata(mem0_rdata),
        .core2_en(mem1_en), .core2_we(mem1_we), .core2_region(mem1_region), .core2_index(mem1_index),
        .core2_wdata(mem1_wdata), .core2_wstrb(mem1_wstrb), .core2_rdata(mem1_rdata),
        .core3_scratch_en(mem3_scratch_en), .core3_scratch_index(mem3_scratch_index),
        .core3_scratch_rdata(mem3_scratch_rdata),
        .stream_p3_bank_lock_valid(p3_bank_lock_valid), .stream_p3_bank_lock(p3_bank_lock),
        .mm_wr_rejected(mm_wr_rejected)
    );


    // So sanh tai canh nhan thuc, truoc NBA; khong rang buoc operand luc idle.
    integer operand_checks [0:7];
    integer operand_p2_checks [0:7];
    integer operand_p3_checks [0:7];
    integer operand_init_lane;
    initial begin
        for (operand_init_lane = 0; operand_init_lane < 8; operand_init_lane = operand_init_lane + 1) begin
            operand_checks[operand_init_lane] = 0;
            operand_p2_checks[operand_init_lane] = 0;
            operand_p3_checks[operand_init_lane] = 0;
        end
    end
    wire [31:0] operand_total = operand_checks[0] + operand_checks[1] + operand_checks[2] + operand_checks[3] +
                                operand_checks[4] + operand_checks[5] + operand_checks[6] + operand_checks[7];
    wire [31:0] operand_p2_total = operand_p2_checks[0] + operand_p2_checks[1] + operand_p2_checks[2] + operand_p2_checks[3] +
                                   operand_p2_checks[4] + operand_p2_checks[5] + operand_p2_checks[6] + operand_p2_checks[7];
    wire [31:0] operand_p3_total = operand_p3_checks[0] + operand_p3_checks[1] + operand_p3_checks[2] + operand_p3_checks[3] +
                                   operand_p3_checks[4] + operand_p3_checks[5] + operand_p3_checks[6] + operand_p3_checks[7];
    genvar operand_lane;
    generate
        for (operand_lane = 0; operand_lane < 8; operand_lane = operand_lane + 1) begin : CHECK_ACCEPTED_OPERANDS
            always @(posedge clk) begin
                if (resetn && !soft_reset && dut.GEN_ACCUM8[operand_lane].u_accum.accepted_start_w) begin
                    if ({dut.GEN_ACCUM8[operand_lane].u_accum.raw_in,
                         dut.GEN_ACCUM8[operand_lane].u_accum.act_scale_fp16,
                         dut.GEN_ACCUM8[operand_lane].u_accum.weight_scale_fp16,
                         dut.GEN_ACCUM8[operand_lane].u_accum.row_id,
                         dut.GEN_ACCUM8[operand_lane].u_accum.clear_accum,
                         dut.GEN_ACCUM8[operand_lane].u_accum.last_block} !==
                        (dut.p2_prefetch_launch ?
                         {dut.prefetch_raw_r[operand_lane], dut.prefetch_act_scale_r[operand_lane],
                          dut.prefetch_weight_scale_r[operand_lane], dut.prefetch_row_r[operand_lane],
                          dut.prefetch_clear_accum_r, dut.prefetch_last_block_r} :
                         {dut.raw_r[operand_lane], dut.act_scale_r[operand_lane],
                          dut.weight_scale_r[operand_lane], dut.row_r[operand_lane],
                          dut.clear_accum_r, dut.last_block_r}))
                        $fatal(1, "FAIL accepted operand mismatch lane=%0d", operand_lane);
                    operand_checks[operand_lane] = operand_checks[operand_lane] + 1;
                    if (dut.p2_prefetch_launch)
                        operand_p2_checks[operand_lane] = operand_p2_checks[operand_lane] + 1;
                    else
                        operand_p3_checks[operand_lane] = operand_p3_checks[operand_lane] + 1;
                end
            end
        end
    endgenerate
    always @(posedge clk) begin
        if (resetn && !soft_reset && (|dut.accum_start_r) && dut.p2_prefetch_launch)
            $fatal(1, "FAIL simultaneous direct and prefetch accumulator starts");
    end

    task mm_write;
        input [1:0] region;
        input [31:0] index;
        input [127:0] data;
        begin
            @(negedge clk);
            mm_wr_en = 1'b1; mm_wr_region = region; mm_wr_index = index;
            mm_wr_data = data; mm_wr_strb = 16'hffff;
            @(negedge clk);
            if (mm_wr_rejected) begin
                $display("FAIL prefetch MMIO write rejected region=%0d index=%0d", region, index);
                $fatal(1);
            end
            mm_wr_en = 1'b0; mm_wr_strb = 16'd0;
        end
    endtask

    task mm_read;
        input [1:0] region;
        input [31:0] index;
        output [127:0] data;
        begin
            @(negedge clk);
            mm_rd_en = 1'b1; mm_rd_region = region; mm_rd_index = index;
            @(negedge clk);
            mm_rd_en = 1'b0;
            while (!mm_rd_valid) @(posedge clk);
            #1;
            if (mm_rd_error) begin
                $display("FAIL prefetch MMIO read error region=%0d index=%0d", region, index);
                $fatal(1);
            end
            data = mm_rd_data;
        end
    endtask

    task send_block;
        input integer b;
        integer lane;
        begin
            @(negedge clk);
            vpu_block = b[15:0];
            vpu_last_block = (b == 7);
            vpu_clear_accum = (b == 0);
            for (lane = 0; lane < 8; lane = lane + 1) begin
                vpu_lane_data[32*lane +: 32] = (b + 1) * (lane + 1);
                vpu_lane_row[16*lane +: 16] = lane;
                vpu_lane_scale_index[32*lane +: 32] = lane * 8 + b;
            end
            vpu_valid = 1'b1;
            while (!vpu_ready) @(negedge clk);
            @(posedge clk);
        end
    endtask

    integer cycle_count = 0;
    integer start_count = 0;
    integer last_start_cycle = -1;
    integer min_start_gap = 9999;
    integer prefetch_pop_count = 0;
    integer prefetch_ready_count = 0;
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (resetn && dut.fifo_prefetch_pop)
            prefetch_pop_count <= prefetch_pop_count + 1;
        if (resetn && (dut.prefetch_state_r == 2'd3))
            prefetch_ready_count <= prefetch_ready_count + 1;
        if (resetn && !soft_reset && dut.p2_prefetch_launch) begin
            if (last_start_cycle >= 0 && (cycle_count - last_start_cycle) < min_start_gap)
                min_start_gap <= cycle_count - last_start_cycle;
            last_start_cycle <= cycle_count;
            start_count <= start_count + 1;
        end
    end


    // Reference queue is populated ONLY by external ready/valid handshakes.
    // PARAM shadow and cache tags are independent of DUT internal hit decisions.
    reg [127:0] param_ref [0:4095];
    reg [7:0] q_mask [0:255];
    reg [255:0] q_raw [0:255], q_index [0:255];
    reg [127:0] q_row [0:255];
    reg [15:0] q_block [0:255], q_group [0:255];
    reg q_last [0:255], q_clear [0:255], q_bank [0:255];
    reg [31:0] q_job [0:255];
    reg [31:0] q_scale [0:2047];
    integer q_reads [0:255];
    reg [7:0] ref_cache_valid = 0;
    reg [31:0] ref_cache_job [0:7], ref_cache_word [0:7];
    reg signed [63:0] ref_sum [0:255];
    reg [15:0] out_row [0:2047];
    reg signed [63:0] out_value [0:2047];
    integer accepted = 0, launched = 0, read_count = 0, reads_this = 0;
    integer expected_lanes = 0, rejected_lanes = 0;
    integer out_tail = 0, out_head = 0, read_lane = 0, last_read_cycle = -99;
    integer first_launch = -1, last_launch = -1;
    integer cov_empty = 0, cov_partial = 0, cov_full = 0, cov_stall = 0;
    integer cov_full_both = 0, cov_partial_both = 0, cov_refill = 0;
    integer cov_idle_change = 0, cov_read_blocked = 0, cov_reject = 0;
    integer cov_hit = 0, cov_miss = 0, cov_reset = 0;
    integer ml, mi, mr, pc, port_no;
    reg legal_input, model_hit;
    reg [31:0] cmd_index;
    reg [127:0] cmd_data;
    reg cmd_en, cmd_we;
    reg [1:0] cmd_region;
    reg stalled = 0;
    reg [714:0] held_payload;
    wire [714:0] input_payload = {vpu_lane_valid,vpu_lane_data,vpu_lane_row,
        vpu_lane_scale_index,vpu_block,vpu_group_blocks,vpu_last_block,
        vpu_clear_accum,vpu_job_id,vpu_bank};

    // All programmed factors are exact powers of two, represented in quarter units.
    function integer scale_quarters;
        input [15:0] h;
        begin
            case (h)
                16'h3800: scale_quarters = 2;
                16'h3c00: scale_quarters = 4;
                16'h4000: scale_quarters = 8;
                16'h4400: scale_quarters = 16;
                default: begin $display("FAIL unexpected reference FP16 %h",h); $fatal(1); end
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (mm_wr_en && mm_wr_region == 2 && resetn)
            param_ref[mm_wr_index] = mm_wr_data;
        if (!resetn || soft_reset) begin
            accepted = 0; launched = 0; read_count = 0; reads_this = 0;
            expected_lanes = 0; rejected_lanes = 0;
            out_tail = 0; out_head = 0; read_lane = 0; last_read_cycle = -99;
            first_launch = -1; last_launch = -1; ref_cache_valid = 0; stalled = 0;
            for (ml = 0; ml < 256; ml = ml + 1) ref_sum[ml] = 0;
        end else begin
            if (stalled && (!vpu_valid || input_payload !== held_payload))
                $fatal(1,"FAIL producer changed stalled payload");
            stalled = vpu_valid && !vpu_ready;
            held_payload = input_payload;
            if (dut.fifo_count_r == 0) cov_empty = cov_empty + 1;
            if (dut.fifo_count_r > 0 && dut.fifo_count_r < 8) cov_partial = cov_partial + 1;
            if (dut.fifo_count_r == 8) cov_full = cov_full + 1;
            if (dut.fifo_count_r == 8 && vpu_valid && !vpu_ready) cov_stall = cov_stall + 1;
            if (dut.fifo_push && dut.fifo_pop && dut.fifo_count_r == 8) cov_full_both = cov_full_both + 1;
            if (dut.fifo_push && dut.fifo_pop && dut.fifo_count_r > 0 && dut.fifo_count_r < 8)
                cov_partial_both = cov_partial_both + 1;
            if (dut.p2_prefetch_launch && dut.fifo_prefetch_pop) cov_refill = cov_refill + 1;
            if (dut.prefetch_state_r == 1 && !dut.prefetch_mem_available)
                cov_read_blocked = cov_read_blocked + 1;

            if (vpu_valid && vpu_ready) begin
                legal_input = vpu_lane_valid != 0 && vpu_group_blocks != 0 && vpu_block < vpu_group_blocks;
                pc = 0;
                for (ml = 0; ml < 8; ml = ml + 1) if (vpu_lane_valid[ml]) begin
                    pc = pc + 1;
                    if (vpu_lane_row[16*ml +: 16] >= 256 || vpu_lane_scale_index[32*ml +: 32] >= 16384)
                        legal_input = 0;
                end
                if (!legal_input) begin
                    rejected_lanes = rejected_lanes + pc;
                    cov_reject = cov_reject + 1;
                end else begin
                    if (accepted >= 256) $fatal(1,"FAIL reference queue bound");
                    q_mask[accepted] = vpu_lane_valid; q_raw[accepted] = vpu_lane_data;
                    q_index[accepted] = vpu_lane_scale_index; q_row[accepted] = vpu_lane_row;
                    q_block[accepted] = vpu_block; q_group[accepted] = vpu_group_blocks;
                    q_last[accepted] = vpu_last_block; q_clear[accepted] = vpu_clear_accum;
                    q_job[accepted] = vpu_job_id; q_bank[accepted] = vpu_bank;
                    model_hit = 1;
                    for (ml = 0; ml < 8; ml = ml + 1) if (vpu_lane_valid[ml]) begin
                        mi = vpu_lane_scale_index[32*ml +: 32];
                        q_scale[accepted*8+ml] = param_ref[mi/4][32*(mi%4) +: 32];
                        if (!ref_cache_valid[ml] || ref_cache_job[ml] != vpu_job_id || ref_cache_word[ml] != mi/4)
                            model_hit = 0;
                    end
                    q_reads[accepted] = model_hit ? 0 : pc;
                    if (model_hit) cov_hit = cov_hit + 1; else cov_miss = cov_miss + 1;
                    if (!model_hit) for (ml = 0; ml < 8; ml = ml + 1) if (vpu_lane_valid[ml]) begin
                        ref_cache_valid[ml] = 1; ref_cache_job[ml] = vpu_job_id;
                        ref_cache_word[ml] = vpu_lane_scale_index[32*ml +: 32] >> 2;
                    end
                    accepted = accepted + 1; expected_lanes = expected_lanes + pc;
                end
            end

            // Observe commands on the same edge as the fixed-latency RAM.
            for (port_no = 0; port_no < 2; port_no = port_no + 1) begin
                cmd_en = port_no == 0 ? mem0_en : mem1_en;
                cmd_we = port_no == 0 ? mem0_we : mem1_we;
                cmd_region = port_no == 0 ? mem0_region : mem1_region;
                cmd_index = port_no == 0 ? mem0_index : mem1_index;
                cmd_data = port_no == 0 ? mem0_wdata : mem1_wdata;
                if (cmd_en && !cmd_we && cmd_region == 2) begin
                    if (launched >= accepted || q_reads[launched] == 0) $fatal(1,"FAIL unexpected PARAM read");
                    while (read_lane < 8 && !q_mask[launched][read_lane]) read_lane = read_lane + 1;
                    if (read_lane >= 8) $fatal(1,"FAIL excess PARAM command");
                    if (cmd_index !== (q_index[launched][32*read_lane +: 32] >> 2) || port_no != read_lane%2)
                        $fatal(1,"FAIL PARAM order bundle=%0d lane=%0d index=%0d",launched,read_lane,cmd_index);
                    read_lane = read_lane + 1; reads_this = reads_this + 1;
                    read_count = read_count + 1; last_read_cycle = cycle_count;
                end
                if (cmd_en && cmd_we && cmd_region == 1) begin
                    if (out_head >= out_tail || cmd_index !== out_row[out_head] ||
                        cmd_data[15:0] !== out_row[out_head] || $signed(cmd_data[79:16]) !== out_value[out_head])
                        $fatal(1,"FAIL exact OUT slot=%0d row=%0d q16=%0d expected=%0d",out_head,cmd_index,$signed(cmd_data[79:16]),out_value[out_head]);
                    out_head = out_head + 1;
                end
            end
            if (dut.p2_prefetch_launch) begin
                if (launched >= accepted) $fatal(1,"FAIL stale/duplicate launch");
                if (reads_this != q_reads[launched] || (reads_this != 0 && cycle_count-last_read_cycle < 2))
                    $fatal(1,"FAIL PARAM completion bundle=%0d reads=%0d expected=%0d age=%0d",launched,reads_this,q_reads[launched],cycle_count-last_read_cycle);
                if (dut.prefetch_lane_valid_r !== q_mask[launched] || dut.prefetch_block_r !== q_block[launched] ||
                    dut.prefetch_group_blocks_r !== q_group[launched] || dut.prefetch_last_block_r !== q_last[launched] ||
                    dut.prefetch_clear_accum_r !== q_clear[launched] || dut.prefetch_job_id_r !== q_job[launched] ||
                    dut.prefetch_bank_r !== q_bank[launched]) $fatal(1,"FAIL launch metadata bundle=%0d",launched);
                for (ml = 0; ml < 8; ml = ml + 1) if (q_mask[launched][ml]) begin
                    mi = q_index[launched][32*ml +: 32]; mr = q_row[launched][16*ml +: 16];
                    if (dut.prefetch_raw_r[ml] !== q_raw[launched][32*ml +: 32] || dut.prefetch_row_r[ml] !== mr ||
                        dut.prefetch_scale_word_index_r[ml] !== (mi >> 2) || dut.prefetch_scale_lane_r[ml] !== (mi%4) ||
                        {dut.prefetch_weight_scale_r[ml],dut.prefetch_act_scale_r[ml]} !== q_scale[launched*8+ml])
                        $fatal(1,"FAIL launch payload/scales bundle=%0d lane=%0d got=%h expected=%h",launched,ml,
                            {dut.prefetch_weight_scale_r[ml],dut.prefetch_act_scale_r[ml]},q_scale[launched*8+ml]);
                    if (q_clear[launched]) ref_sum[mr] = 0;
                    ref_sum[mr] = ref_sum[mr] + $signed(q_raw[launched][32*ml +: 32]) *
                        (64'sd4096 * scale_quarters(q_scale[launched*8+ml][15:0]) * scale_quarters(q_scale[launched*8+ml][31:16]));
                    if (q_last[launched]) begin
                        if (out_tail >= 2048) $fatal(1,"FAIL output reference bound");
                        out_row[out_tail] = mr; out_value[out_tail] = ref_sum[mr]; out_tail = out_tail + 1;
                    end
                end
                if (first_launch < 0) first_launch = cycle_count;
                last_launch = cycle_count;
                launched = launched + 1; reads_this = 0; read_lane = 0;
            end
        end
    end

    task drain;
        input [255:0] name;
        integer n;
        begin
            @(negedge clk); vpu_valid = 0;
            n = 0;
            while ((!stream_status[4] || launched != accepted || out_head != out_tail) && n < 12000) begin
                @(negedge clk); n = n + 1;
            end
            if (n == 12000) $fatal(1,"FAIL drain timeout %s",name);
            if (stream_count !== expected_lanes || stream_drop_count !== rejected_lanes || stream_error_count !== rejected_lanes)
                $fatal(1,"FAIL accounting %s count=%0d expected=%0d drop=%0d err=%0d reject=%0d",name,
                    stream_count,expected_lanes,stream_drop_count,stream_error_count,rejected_lanes);
            if (stream_entry_done_count !== expected_lanes || stream_final_write_count !== out_tail || stream_out_count !== out_tail)
                $fatal(1,"FAIL retirement accounting %s entry=%0d expected=%0d write=%0d out=%0d expected_out=%0d",
                    name,stream_entry_done_count,expected_lanes,stream_final_write_count,stream_out_count,out_tail);
            $display("[METRICS] %s accepted=%0d launch=%0d reads=%0d first=%0d last=%0d drain=%0d blocked_read=%0d",
                name,accepted,launched,read_count,first_launch,last_launch,n,cov_read_blocked);
        end
    endtask

    task reset_stream;
        input integer hard;
        begin
            @(negedge clk); vpu_valid = 0;
            if (hard) resetn = 0; else soft_reset = 1;
            repeat (3) @(negedge clk);
            resetn = 1; soft_reset = 0;
            repeat (3) @(negedge clk);
            if (!stream_status[4] || accepted != 0 || launched != 0 || stream_count != 0)
                $fatal(1,"FAIL reset not quiescent");
        end
    endtask

    // Distinct act/weight combinations, including different entries in one word.
    task program_scales;
        input integer variant;
        integer w;
        begin
            for (w = 0; w < 32; w = w + 1)
                if (variant == 0) mm_write(2, w, {32'h44004400,32'h40004000,32'h3c003c00,32'h38003800});
                else mm_write(2, w, {32'h38003c00,32'h38004000,32'h40004400,32'h3c004000});
        end
    endtask

    task send_case;
        input integer seq, block_no, blocks, base_row, entry, changed_lane;
        input [7:0] mask;
        input [31:0] job;
        input integer clear_flag, last_flag;
        integer lane, n;
        begin
            @(negedge clk);
            vpu_lane_valid = mask; vpu_block = block_no; vpu_group_blocks = blocks;
            vpu_clear_accum = clear_flag; vpu_last_block = last_flag; vpu_job_id = job; vpu_bank = seq%2;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                vpu_lane_data[32*lane +: 32] = (lane%2 == 0) ? -(seq+1)*(lane+1) : (seq+1)*(lane+1);
                vpu_lane_row[16*lane +: 16] = base_row+lane;
                vpu_lane_scale_index[32*lane +: 32] = mask[lane] ? lane*8+entry+(lane==changed_lane ? 4 : 0) : 16000+seq;
            end
            vpu_valid = 1; n = 0;
            // Evaluate ready at sampling edges; never advance a stalled payload.
            @(posedge clk);
            while (!vpu_ready && n < 12000) begin @(posedge clk); n = n + 1; end
            if (n == 12000) $fatal(1,"FAIL input timeout");
        end
    endtask

    task reset_inflight;
        input integer hard, phase;
        integer n;
        begin
            reset_stream(0);
            // Four accepted bundles ensure queued work remains when the second
            // look-ahead transfer reaches CHECK/READ. Distinct words force misses.
            send_case(0,0,4,64,0,-1,8'hff,32'h9000,1,0);
            send_case(1,1,4,64,4,-1,8'hff,32'h9000,0,0);
            send_case(2,2,4,64,0,-1,8'hff,32'h9000,0,0);
            send_case(3,3,4,64,4,-1,8'hff,32'h9000,0,1);
            @(negedge clk); vpu_valid = 0; n = 0;
            while (!((phase == 0 && dut.fifo_count_r >= 2) ||
                     (phase == 1 && dut.prefetch_state_r == 5 && dut.fifo_count_r != 0) ||
                     (phase == 2 && dut.prefetch_state_r == 1 && dut.fifo_count_r != 0)) && n < 4000) begin
                @(negedge clk); n = n + 1;
            end
            if (n == 4000) $fatal(1,"FAIL reset target hard=%0d phase=%0d",hard,phase);
            // Assert now, while the observed target state is still present.
            if (hard) resetn = 0; else soft_reset = 1;
            repeat (3) @(negedge clk); resetn = 1; soft_reset = 0;
            repeat (30) @(negedge clk);
            if (launched != 0 || accepted != 0 || !stream_status[4] || stream_out_count != 0)
                $fatal(1,"FAIL stale work after reset");
            cov_reset = cov_reset + 1;
            send_case(7,0,1,96,2,-1,8'hff,32'ha000+hard*4+phase,1,1);
            drain("reset_recovery");
            $display("[METRICS] reset hard=%0d phase=%0d recovery_reads=%0d",hard,phase,read_count);
        end
    endtask
    integer abc_refill_start;
    integer i;
    integer b;
    integer timeout;
    reg [127:0] rd;
    reg signed [63:0] expected_q16;
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        // 64 P2 scale entries (8 rows x 8 blocks), all act/weight scales = FP16 1.0.
        for (i = 0; i < 16; i = i + 1)
            mm_write(2'd2, i, {4{32'h3c003c00}});

        // Keep valid asserted across adjacent accepted blocks. The FIFO may apply
        // backpressure, but every block must be accepted exactly once and in order.
        for (b = 0; b < 8; b = b + 1)
            send_block(b);
        @(negedge clk);
        vpu_valid = 1'b0;

        timeout = 0;
        while ((stream_out_count != 32'd8 || !stream_status[4]) && timeout < 4000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 4000) begin
            $display("FAIL prefetch timeout count=%0d out=%0d entry=%0d status=%08x pf=%0d fifo=%0d",
                     stream_count, stream_out_count, stream_entry_done_count,
                     stream_status, dut.prefetch_state_r, dut.fifo_count_r);
            $fatal(1);
        end

        if (stream_count !== 32'd64 || stream_drop_count !== 32'd0 ||
            stream_error_count !== 32'd0 || stream_entry_done_count !== 32'd64 ||
            stream_final_write_count !== 32'd8 || start_count !== 8) begin
            $display("FAIL prefetch counters count=%0d drop=%0d err=%0d entry=%0d write=%0d starts=%0d",
                     stream_count, stream_drop_count, stream_error_count,
                     stream_entry_done_count, stream_final_write_count, start_count);
            $fatal(1);
        end

        // This is the architectural assertion for the optimization: multiple FIFO
        // heads must be consumed by the look-ahead path, and at least one subsequent
        // accumulator launch must arrive much sooner than the old ~20-cycle
        // READ/CAPTURE + compute cadence.
        if (prefetch_pop_count < 4 || prefetch_ready_count == 0 || min_start_gap > 14) begin
            $display("FAIL prefetch not exercised pops=%0d ready_cycles=%0d min_start_gap=%0d hwm=%0d stalls=%0d",
                     prefetch_pop_count, prefetch_ready_count, min_start_gap,
                     stream_fifo_high_water, stream_raw_stall_cycles);
            $fatal(1);
        end

        repeat (2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            mm_read(2'd1, i, rd);
            expected_q16 = 36 * (i + 1);
            expected_q16 = expected_q16 <<< 16;
            if (rd[15:0] !== i[15:0] || $signed(rd[79:16]) !== expected_q16) begin
                $display("FAIL prefetch OUT row=%0d stored_row=%0d q16=%0d expected=%0d",
                         i, rd[15:0], $signed(rd[79:16]), expected_q16);
                $fatal(1);
            end
        end

        drain("original_eight");

        reset_stream(0);
        program_scales(0);
        // 24 bundles exceed twice the physical FIFO depth; sustained valid
        // exercises pointer wrapping and full-FIFO simultaneous push/pop.
        for (b = 0; b < 24; b = b + 1)
            send_case(b,b,24,48,b%4,-1,8'hff,32'h3000,(b==0),(b==23));
        drain("stress_24");
        if (accepted != 24 || launched != 24 || read_count != 8 ||
            cov_full == 0 || cov_stall == 0 || cov_full_both == 0 || cov_partial_both == 0)
            $fatal(1,"FAIL stress coverage full=%0d stall=%0d both_full=%0d both_partial=%0d",
                cov_full,cov_stall,cov_full_both,cov_partial_both);

        reset_stream(0);
        send_case(0,0,1,80,0,-1,8'hff,32'h4000,1,1); drain("cold_miss");
        if (read_count != 8) $fatal(1,"FAIL cold read count");
        send_case(1,0,1,80,1,-1,8'hff,32'h4000,1,1); drain("same_word_entry_hit");
        if (read_count != 8) $fatal(1,"FAIL hit issued reads");
        send_case(2,0,1,80,2,3,8'hff,32'h4000,1,1); drain("one_lane_word_miss");
        if (read_count != 16) $fatal(1,"FAIL one lane miss read count");
        send_case(3,0,1,80,3,-1,8'h05,32'h4000,1,1); drain("sparse_inactive_tags");
        if (read_count != 16) $fatal(1,"FAIL inactive tags prevented cache hit");
        program_scales(1);
        send_case(4,0,1,80,3,-1,8'h05,32'h4001,1,1); drain("new_job_new_values");
        if (read_count != 18) $fatal(1,"FAIL changed job miss read count");

        // Invalid metadata is handshaken but must never enter the launch queue.
        send_case(0,1,1,80,0,-1,8'hff,32'h5000,1,1);
        drain("reject_block");
        send_case(0,0,1,256,0,-1,8'hff,32'h5000,1,1);
        drain("reject_row");
        send_case(0,0,1,80,16384,-1,8'hff,32'h5000,1,1);
        drain("reject_index");
        if (rejected_lanes != 24) $fatal(1,"FAIL rejection coverage");
        // Payload noise while valid is low must have no architectural effect.
        for (b = 0; b < 12; b = b + 1) begin
            @(negedge clk); vpu_valid = 0; vpu_lane_data = b;
            vpu_job_id = b; vpu_lane_valid = b; vpu_lane_scale_index = ~b;
            cov_idle_change = cov_idle_change + 1;
        end
        drain("valid_low_noise");
        if (accepted != 5 || launched != 5) $fatal(1,"FAIL valid-low accepted input");

        for (b = 0; b < 2; b = b + 1)
            for (i = 0; i < 3; i = i + 1) reset_inflight(b,i);
        reset_stream(0);
        program_scales(0);
        // Legal A(nonfinal)/B(final)/C(new group) overlap; C is already queued
        // on B's launch/refill edge. The scoreboard checks every PARAM command.
        abc_refill_start = cov_refill;
        send_case(0,0,2,16,0,-1,8'hff,32'h2000,1,0);
        send_case(1,1,2,16,1,-1,8'hff,32'h2000,0,1);
        send_case(2,0,1,32,3,-1,8'hff,32'h2001,1,1);
        drain("ABC_overlap");
        if (accepted != 3 || launched != 3 || read_count != 16 || cov_refill-abc_refill_start != 2)
            $fatal(1,"FAIL ABC counts");

        if (cov_empty == 0 || cov_partial == 0 || cov_refill == 0 || cov_idle_change == 0 ||
            cov_reject < 3 || cov_hit == 0 || cov_miss == 0 || cov_reset != 6)
            $fatal(1,"FAIL missing mandatory coverage");
        $display("[METRICS] coverage empty=%0d partial=%0d full=%0d stall=%0d full_both=%0d partial_both=%0d refill=%0d hit=%0d miss=%0d reject=%0d reset=%0d blocked_read=%0d",
            cov_empty,cov_partial,cov_full,cov_stall,cov_full_both,cov_partial_both,cov_refill,cov_hit,cov_miss,cov_reject,cov_reset,cov_read_blocked);

        if (operand_total == 0 || operand_p2_total == 0)
            $fatal(1, "FAIL accepted operand monitor not exercised");
        $display("[OPERAND_MONITOR] accepted=%0d p2=%0d p3=%0d",operand_total,operand_p2_total,operand_p3_total);
        $display("PASS tb_SPU_Stream8_prefetch pops=%0d ready_cycles=%0d min_start_gap=%0d hwm=%0d stalls=%0d",
                 prefetch_pop_count, prefetch_ready_count, min_start_gap,
                 stream_fifo_high_water, stream_raw_stall_cycles);
        $finish;
    end
endmodule
