`ifndef TB_SPU_VPU_STREAM8_V
`define TB_SPU_VPU_STREAM8_V
`timescale 1ns/1ps

module tb_SPU_VPU_Stream8 #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] SPU_VPU_Stream8 watchdog timeout");
    end
    reg clk = 1'b0;
    always #5 if (!completed) clk = ~clk;
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
    reg [15:0] vpu_group_blocks = 16'd1;
    reg vpu_last_block = 1'b1;
    reg vpu_clear_accum = 1'b1;
    reg [31:0] vpu_job_id = 32'h89abcdef;
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
                $display("FAIL MMIO write rejected region=%0d index=%0d", region, index);
                $fatal(1);
            end
            mm_wr_en = 1'b0; mm_wr_strb = 16'd0;
        end
    endtask

    task mm_read;
        input [1:0] region;
        input [31:0] index;
        output [127:0] data;
        integer read_timeout;
        begin
            @(negedge clk);
            mm_rd_en = 1'b1; mm_rd_region = region; mm_rd_index = index;
            @(negedge clk);
            mm_rd_en = 1'b0;
            read_timeout = 0;
            while (!mm_rd_valid && read_timeout < 100) begin
                @(posedge clk); read_timeout = read_timeout + 1;
            end
            if (!mm_rd_valid) $fatal(1, "FAIL bounded MMIO read timeout");
            #1;
            if (mm_rd_error) begin
                $display("FAIL MMIO read error region=%0d index=%0d", region, index);
                $fatal(1);
            end
            data = mm_rd_data;
        end
    endtask


    integer operand_cycle = 0;
    integer case_start_cycle = 0;
    integer mode_toggle_coverage = 0;
    integer error_retire_coverage = 0;
    reg mode_toggle_armed = 0;
    reg [31:0] errors_before;
    reg [31:0] writes_before;
    always @(posedge clk) begin
        operand_cycle <= operand_cycle + 1;
        if (resetn && !soft_reset) begin
            if (dut.accum_entry_done[0] && dut.accum_error[0])
                error_retire_coverage = error_retire_coverage + 1;
            if (mode_toggle_armed && dut.GEN_ACCUM8[0].u_accum.accepted_start_w) begin
                if (split_scale_enable !== 1'b0 || dut.prefetch_ready !== 1'b1 ||
                    dut.accum_start_r[0] !== 1'b1 || dut.p3_r !== 1'b1 ||
                    dut.p2_prefetch_launch !== 1'b0 || dut.prefetch_row_r[0] !== 16'd20 ||
                    dut.prefetch_raw_r[0] !== 32'sd7 ||
                    {dut.GEN_ACCUM8[0].u_accum.raw_in,
                     dut.GEN_ACCUM8[0].u_accum.act_scale_fp16,
                     dut.GEN_ACCUM8[0].u_accum.weight_scale_fp16,
                     dut.GEN_ACCUM8[0].u_accum.row_id,
                     dut.GEN_ACCUM8[0].u_accum.clear_accum,
                     dut.GEN_ACCUM8[0].u_accum.last_block} !==
                    {32'sd13,16'h3c00,16'h3c00,16'd40,1'b0,1'b1})
                    $fatal(1, "FAIL mode-toggle accepted P3 operands replaced by parked P2");
                mode_toggle_coverage = mode_toggle_coverage + 1;
            end
        end
    end

    task send_lane0;
        input signed [31:0] raw_value;
        input [15:0] row_value;
        input clear_value, last_value;
        input [15:0] block_value, group_value;
        input [31:0] scale_index, job_value;
        integer wait_cycles;
        begin
            @(negedge clk);
            vpu_lane_valid = 8'h01;
            vpu_lane_data = {224'd0,raw_value};
            vpu_lane_row = {112'd0,row_value};
            vpu_lane_scale_index = {224'd0,scale_index};
            vpu_clear_accum = clear_value; vpu_last_block = last_value;
            vpu_block = block_value; vpu_group_blocks = group_value;
            vpu_job_id = job_value; vpu_bank = 0;
            vpu_valid = 1;
            wait_cycles = 0;
            @(posedge clk);
            while (!vpu_ready && wait_cycles < 2000) begin
                @(posedge clk); wait_cycles = wait_cycles + 1;
            end
            if (!vpu_ready) $fatal(1, "FAIL lane0 ready timeout");
            @(negedge clk); vpu_valid = 0;
        end
    endtask

    task await_quiescence;
        input [31:0] expected_entries, expected_writes;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((!stream_status[4] || p3_bank_lock_valid ||
                    stream_entry_done_count != expected_entries ||
                    stream_final_write_count != expected_writes) && wait_cycles < 4000) begin
                @(negedge clk); wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles == 4000 || stream_status[4] !== 1'b1 || p3_bank_lock_valid !== 1'b0 ||
                stream_count !== expected_entries ||
                stream_out_count !== expected_writes || stream_drop_count !== 32'd0)
                $fatal(1, "FAIL quiescence entries=%0d/%0d writes=%0d/%0d status=%h lock=%b",
                    stream_entry_done_count,expected_entries,stream_final_write_count,expected_writes,
                    stream_status,p3_bank_lock_valid);
        end
    endtask

    task check_output;
        input [15:0] row_value;
        input signed [63:0] expected_value;
        reg [127:0] output_word;
        begin
            mm_read(2'd1,{16'd0,row_value},output_word);
            if (output_word[15:0] !== row_value || $signed(output_word[79:16]) !== expected_value)
                $fatal(1, "FAIL directed output row=%0d got=%0d expected=%0d",
                    row_value,$signed(output_word[79:16]),expected_value);
        end
    endtask

    task operand_case_metrics;
        input [255:0] name;
        begin
            $display("[METRICS] early_operands %s start=%0d end=%0d cycles=%0d accepted=%0d p2=%0d p3=%0d toggle=%0d error_retire=%0d writes=%0d errors=%0d",
                name,case_start_cycle,operand_cycle,operand_cycle-case_start_cycle,operand_total,
                operand_p2_total,operand_p3_total,mode_toggle_coverage,error_retire_coverage,
                stream_final_write_count,stream_error_count);
        end
    endtask

    integer i;
    integer timeout;
    reg [127:0] rd;
    reg signed [63:0] expected_q16;
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        // P2 PARAM: four packed {weight_fp16, act_fp16} entries per word.
        // Both scales are FP16 1.0, therefore final Q16.16 = raw << 16.
        mm_write(2'd2, 32'd0, {4{32'h3c003c00}});
        mm_write(2'd2, 32'd1, {4{32'h3c003c00}});

        for (i = 0; i < 8; i = i + 1) begin
            vpu_lane_data[32*i +: 32] = 32 * (i + 1);
            vpu_lane_row[16*i +: 16] = i;
            vpu_lane_scale_index[32*i +: 32] = i;
        end

        while (!vpu_ready) @(posedge clk);
        @(negedge clk); vpu_valid = 1'b1;
        @(negedge clk); vpu_valid = 1'b0;

        timeout = 0;
        while ((stream_out_count != 32'd8 || !stream_status[4]) && timeout < 2000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        if (timeout >= 2000) begin
            $display("FAIL SPU stream timeout count=%0d out=%0d entry=%0d status=%08x",
                     stream_count, stream_out_count, stream_entry_done_count, stream_status);
            $fatal(1);
        end
        if (stream_count !== 32'd8 || stream_drop_count !== 32'd0 ||
            stream_error_count !== 32'd0 || stream_entry_done_count !== 32'd8 ||
            stream_final_write_count !== 32'd8) begin
            $display("FAIL counters count=%0d drop=%0d err=%0d entry=%0d write=%0d",
                     stream_count, stream_drop_count, stream_error_count,
                     stream_entry_done_count, stream_final_write_count);
            $fatal(1);
        end

        repeat (2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            mm_read(2'd1, i, rd);
            expected_q16 = $signed(32 * (i + 1));
            expected_q16 = expected_q16 <<< 16;
            if (rd[15:0] !== i[15:0] || $signed(rd[79:16]) !== expected_q16) begin
                $display("FAIL OUT row=%0d stored_row=%0d q16=%0d expected=%0d",
                         i, rd[15:0], $signed(rd[79:16]), expected_q16);
                $fatal(1);
            end
        end


        case_start_cycle = operand_cycle;
        mm_write(2'd2,32'd0,{4{32'h3c003c00}});
        // Chuan bi PARAM/SCRATCH P3 truoc khi khoa bank; khong doi word cache P2.
        mm_write(2'd2,32'd5,{8{16'h3c00}});
        mm_write(2'd3,32'd0,{8{16'h3c00}});
        send_lane0(32'sd3,16'd20,1'b1,1'b1,0,1,0,32'hc4000010);
        await_quiescence(9,9);
        check_output(20,64'sd3 <<< 16);
        operand_case_metrics("initialize_row20");

        case_start_cycle = operand_cycle;
        send_lane0(32'sd11,16'd40,1'b1,1'b1,0,1,0,32'hc4000020);
        await_quiescence(10,10);
        check_output(40,64'sd11 <<< 16);
        operand_case_metrics("initialize_row40");

        case_start_cycle = operand_cycle;
        send_lane0(32'sd7,16'd20,1'b0,1'b1,0,1,0,32'hc4000010);
        timeout = 0;
        while (!dut.prefetch_ready && timeout < 2000) begin
            @(negedge clk); timeout = timeout + 1;
        end
        if (dut.prefetch_ready !== 1'b1 || dut.state_r !== dut.S_IDLE || operand_total != 10)
            $fatal(1, "FAIL parked P2 target not reached before launch");
        // Doi mode o negedge, truoc canh launch P2 ke tiep.
        split_scale_enable = 1;
        send_lane0(32'sd13,16'd40,1'b0,1'b1,0,1,40,32'hc4000030);
        timeout = 0;
        while (dut.accum_start_r[0] !== 1'b1 && timeout < 2000) begin
            @(negedge clk); timeout = timeout + 1;
        end
        if (dut.accum_start_r[0] !== 1'b1 || dut.prefetch_ready !== 1'b1 || p3_bank_lock_valid !== 1'b1)
            $fatal(1, "FAIL direct-start/parked-prefetch overlap not reached");
        split_scale_enable = 0;
        mode_toggle_armed = 1;
        // Done thuoc owner P3 da chot, khong phu thuoc mode vua doi.
        vpu_done = 1;
        @(negedge clk);
        vpu_done = 0; mode_toggle_armed = 0;
        if (mode_toggle_coverage != 1 || operand_p3_total != 1 ||
            dut.GEN_ACCUM8[0].u_accum.row_id_r !== 16'd40)
            $fatal(1, "FAIL P3 target edge not accepted exactly once");
        await_quiescence(12,12);
        check_output(40,64'sd24 <<< 16);
        check_output(20,64'sd10 <<< 16);
        if (stream_done_count !== 32'd1 || stream_error_count !== 32'd0 || stream_p3_reject_count !== 32'd0)
            $fatal(1, "FAIL mode-toggle ownership/error accounting");
        operand_case_metrics("parked_P2_direct_P3_toggle");

        case_start_cycle = operand_cycle;
        send_lane0(-32'sd2,16'd20,1'b1,1'b1,0,1,0,32'hc4000040);
        await_quiescence(13,13);
        check_output(20,-64'sd2 <<< 16);
        operand_case_metrics("clear_signed_row20");

        case_start_cycle = operand_cycle;
        mm_write(2'd2,32'd6,{4{32'hbc003c00}});
        errors_before = stream_error_count;
        writes_before = stream_final_write_count;
        // Loi nonfinal khong ghi OUT; final hop le phai cong tren RAM giu nguyen.
        send_lane0(32'sd5,16'd20,1'b0,1'b0,0,2,24,32'hc4000050);
        send_lane0(32'sd5,16'd20,1'b0,1'b1,1,2,0,32'hc4000050);
        await_quiescence(15,14);
        if (stream_error_count <= errors_before || error_retire_coverage == 0 ||
            stream_final_write_count !== writes_before + 32'd1)
            $fatal(1, "FAIL nonfinal bad-scale/recovery accounting");
        check_output(20,64'sd3 <<< 16);
        if (operand_total != 15 || operand_p2_total != 14 || operand_p3_total != 1 || mode_toggle_coverage != 1)
            $fatal(1, "FAIL directed operand coverage counts");
        operand_case_metrics("nonfinal_error_valid_recovery");

        if (operand_total == 0 || operand_p2_total == 0)
            $fatal(1, "FAIL accepted operand monitor not exercised");
        $display("[OPERAND_MONITOR] accepted=%0d p2=%0d p3=%0d",operand_total,operand_p2_total,operand_p3_total);
        $display("PASS tb_SPU_VPU_Stream8");
        completed = 1; if (AUTO_FINISH) $finish;
    end
endmodule

`endif
