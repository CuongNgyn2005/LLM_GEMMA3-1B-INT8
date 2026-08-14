`timescale 1ns/1ps

module tb_SPU_Stream8_prefetch;
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
        if (resetn && (|dut.accum_start_r)) begin
            if (last_start_cycle >= 0 && (cycle_count - last_start_cycle) < min_start_gap)
                min_start_gap <= cycle_count - last_start_cycle;
            last_start_cycle <= cycle_count;
            start_count <= start_count + 1;
        end
    end

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

        $display("PASS tb_SPU_Stream8_prefetch pops=%0d ready_cycles=%0d min_start_gap=%0d hwm=%0d stalls=%0d",
                 prefetch_pop_count, prefetch_ready_count, min_start_gap,
                 stream_fifo_high_water, stream_raw_stall_cycles);
        $finish;
    end
endmodule
