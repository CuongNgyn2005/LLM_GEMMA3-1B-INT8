`timescale 1ns/1ps

module tb_VPU8_burst;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg ctrl_start = 1'b0;
    reg ctrl_clear_done = 1'b0;
    reg [15:0] cfg_rows = 16'd8;
    reg [15:0] cfg_cols = 16'd320;
    reg [15:0] cfg_col_beats = 16'd20; // 10 Q8 blocks -> bursts 4 + 4 + 2
    reg [15:0] cfg_scale = 16'h3c00;
    reg [4:0] compute_mode = 5'b10001; // x8 P2 raw group mode
    reg cfg_wr_bank = 1'b0;
    reg cfg_rd_bank = 1'b0;
    reg [31:0] cfg_job_id = 32'hff0d0001;

    wire busy, done, error;
    wire [15:0] active_row, active_col_beat;
    wire active_bank, done_bank;
    wire [31:0] active_job_id, done_job_id;

    wire spu_raw_valid;
    reg  spu_raw_ready = 1'b0;
    wire signed [31:0] spu_raw_data;
    wire [15:0] spu_raw_row, spu_raw_block, spu_raw_group_blocks;
    wire spu_raw_last_block, spu_raw_clear_accum;
    wire [31:0] spu_raw_job_id;
    wire spu_raw_bank;
    wire [31:0] spu_raw_scale_index;
    wire spu_raw_done;
    wire spu_raw_pair_valid;
    wire signed [31:0] spu_raw_pair_data;
    wire [15:0] spu_raw_pair_row, spu_raw_pair_block, spu_raw_pair_group_blocks;
    wire spu_raw_pair_last_block, spu_raw_pair_clear_accum;
    wire [31:0] spu_raw_pair_job_id;
    wire spu_raw_pair_bank;
    wire [31:0] spu_raw_pair_scale_index;
    wire [7:0] spu_raw_lane_valid;
    wire [255:0] spu_raw_lane_data;
    wire [127:0] spu_raw_lane_row;
    wire [255:0] spu_raw_lane_scale_index;

    reg mm_wr_en = 1'b0;
    reg [1:0] mm_wr_region = 2'd0;
    reg [31:0] mm_wr_index = 32'd0;
    reg [127:0] mm_wr_data = 128'd0;
    reg [15:0] mm_wr_strb = 16'd0;
    reg mm_rd_en = 1'b0;
    reg [1:0] mm_rd_region = 2'd0;
    reg [31:0] mm_rd_index = 32'd0;
    wire [127:0] mm_rd_data;
    wire mm_rd_valid, mm_rd_error;

    Matrix_Vector_Multiplication dut (
        .CLK(clk), .RST(resetn),
        .ctrl_start(ctrl_start), .ctrl_clear_done(ctrl_clear_done),
        .cfg_rows(cfg_rows), .cfg_cols(cfg_cols), .cfg_col_beats(cfg_col_beats),
        .cfg_scale(cfg_scale), .compute_mode(compute_mode),
        .cfg_wr_bank(cfg_wr_bank), .cfg_rd_bank(cfg_rd_bank), .cfg_job_id(cfg_job_id),
        .busy(busy), .done(done), .error(error), .active_row(active_row),
        .active_col_beat(active_col_beat), .active_bank(active_bank), .done_bank(done_bank),
        .active_job_id(active_job_id), .done_job_id(done_job_id),
        .spu_raw_valid(spu_raw_valid), .spu_raw_ready(spu_raw_ready),
        .spu_raw_data(spu_raw_data), .spu_raw_row(spu_raw_row), .spu_raw_block(spu_raw_block),
        .spu_raw_group_blocks(spu_raw_group_blocks), .spu_raw_last_block(spu_raw_last_block),
        .spu_raw_clear_accum(spu_raw_clear_accum), .spu_raw_job_id(spu_raw_job_id),
        .spu_raw_bank(spu_raw_bank), .spu_raw_scale_index(spu_raw_scale_index),
        .spu_raw_done(spu_raw_done), .spu_raw_pair_valid(spu_raw_pair_valid),
        .spu_raw_pair_data(spu_raw_pair_data), .spu_raw_pair_row(spu_raw_pair_row),
        .spu_raw_pair_block(spu_raw_pair_block), .spu_raw_pair_group_blocks(spu_raw_pair_group_blocks),
        .spu_raw_pair_last_block(spu_raw_pair_last_block),
        .spu_raw_pair_clear_accum(spu_raw_pair_clear_accum),
        .spu_raw_pair_job_id(spu_raw_pair_job_id), .spu_raw_pair_bank(spu_raw_pair_bank),
        .spu_raw_pair_scale_index(spu_raw_pair_scale_index),
        .spu_raw_lane_valid(spu_raw_lane_valid), .spu_raw_lane_data(spu_raw_lane_data),
        .spu_raw_lane_row(spu_raw_lane_row), .spu_raw_lane_scale_index(spu_raw_lane_scale_index),
        .mm_wr_en(mm_wr_en), .mm_wr_region(mm_wr_region), .mm_wr_index(mm_wr_index),
        .mm_wr_data(mm_wr_data), .mm_wr_strb(mm_wr_strb),
        .mm_rd_en(mm_rd_en), .mm_rd_region(mm_rd_region), .mm_rd_index(mm_rd_index),
        .mm_rd_data(mm_rd_data), .mm_rd_valid(mm_rd_valid), .mm_rd_error(mm_rd_error)
    );

    task write_word;
        input [1:0] region;
        input [31:0] index;
        input [127:0] data;
        begin
            @(negedge clk);
            mm_wr_en = 1'b1;
            mm_wr_region = region;
            mm_wr_index = index;
            mm_wr_data = data;
            mm_wr_strb = 16'hffff;
            @(negedge clk);
            mm_wr_en = 1'b0;
            mm_wr_strb = 16'd0;
        end
    endtask

    function [127:0] repeat_byte;
        input [7:0] value;
        integer j;
        begin
            for (j = 0; j < 16; j = j + 1)
                repeat_byte[8*j +: 8] = value;
        end
    endfunction

    task load_inputs;
        integer beat;
        begin
            for (beat = 0; beat < 20; beat = beat + 1)
                write_word(2'd0, beat, repeat_byte(8'd1));
        end
    endtask

    task load_weights;
        integer r, beat;
        integer pair_id, parity, ext_index, block;
        reg [7:0] value;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                pair_id = r >> 1;
                parity = r & 1;
                for (beat = 0; beat < 20; beat = beat + 1) begin
                    block = beat >> 1;
                    value = r + 1 + block;
                    ext_index = 2 * (pair_id * 20 + beat) + parity;
                    write_word(2'd1, ext_index, repeat_byte(value));
                end
            end
        end
    endtask

    task start_run;
        begin
            @(negedge clk);
            ctrl_start = 1'b1;
            @(negedge clk);
            ctrl_start = 1'b0;
        end
    endtask

    task consume_bundle;
        input integer expected_block;
        integer i, hold_cycle;
        integer expected_raw;
        integer expected_scale_index;
        reg [255:0] held_data;
        reg [127:0] held_row;
        reg [255:0] held_index;
        begin
            while (!spu_raw_valid) @(posedge clk);
            #1;

            if (spu_raw_lane_valid !== 8'hff) begin
                $display("FAIL block=%0d lane_valid=%02x", expected_block, spu_raw_lane_valid);
                $fatal(1);
            end
            if (spu_raw_block !== expected_block[15:0] || spu_raw_group_blocks !== 16'd10) begin
                $display("FAIL metadata expected_block=%0d got_block=%0d groups=%0d",
                         expected_block, spu_raw_block, spu_raw_group_blocks);
                $fatal(1);
            end
            if (spu_raw_clear_accum !== (expected_block == 0)) begin
                $display("FAIL clear flag block=%0d clear=%b", expected_block, spu_raw_clear_accum);
                $fatal(1);
            end
            if (spu_raw_last_block !== (expected_block == 9)) begin
                $display("FAIL last flag block=%0d last=%b", expected_block, spu_raw_last_block);
                $fatal(1);
            end
            if (spu_raw_job_id !== cfg_job_id || spu_raw_bank !== 1'b0) begin
                $display("FAIL job/bank block=%0d job=%08x bank=%b", expected_block, spu_raw_job_id, spu_raw_bank);
                $fatal(1);
            end

            for (i = 0; i < 8; i = i + 1) begin
                expected_raw = 32 * (i + 1 + expected_block);
                expected_scale_index = i * 10 + expected_block;
                if ($signed(spu_raw_lane_data[32*i +: 32]) !== expected_raw) begin
                    $display("FAIL block=%0d lane=%0d raw=%0d expected=%0d",
                             expected_block, i, $signed(spu_raw_lane_data[32*i +: 32]), expected_raw);
                    $fatal(1);
                end
                if (spu_raw_lane_row[16*i +: 16] !== i[15:0]) begin
                    $display("FAIL block=%0d lane=%0d row=%0d", expected_block, i,
                             spu_raw_lane_row[16*i +: 16]);
                    $fatal(1);
                end
                if (spu_raw_lane_scale_index[32*i +: 32] !== expected_scale_index) begin
                    $display("FAIL block=%0d lane=%0d scale_index=%0d expected=%0d",
                             expected_block, i, spu_raw_lane_scale_index[32*i +: 32], expected_scale_index);
                    $fatal(1);
                end
            end

            // Exercise the raw ready/valid hold contract on every retired block.
            held_data = spu_raw_lane_data;
            held_row = spu_raw_lane_row;
            held_index = spu_raw_lane_scale_index;
            for (hold_cycle = 0; hold_cycle < 3; hold_cycle = hold_cycle + 1) begin
                @(posedge clk); #1;
                if (!spu_raw_valid || spu_raw_lane_data !== held_data ||
                    spu_raw_lane_row !== held_row || spu_raw_lane_scale_index !== held_index) begin
                    $display("FAIL block=%0d changed under raw backpressure", expected_block);
                    $fatal(1);
                end
            end
            @(negedge clk); spu_raw_ready = 1'b1;
            @(negedge clk); spu_raw_ready = 1'b0;
        end
    endtask

    integer block;
    integer timeout;
    reg saw_four_block_issue = 1'b0;

    always @(posedge clk) begin
        if (resetn && dut.issue_block_idx_r == 16'd3 &&
            dut.block_idx_r == 16'd0 && dut.raw_burst_blocks_r == 3'd4)
            saw_four_block_issue <= 1'b1;
    end

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        load_inputs();
        load_weights();
        // The write remapper is pipelined; leave ample time for its final word.
        repeat (128) @(posedge clk);

        start_run();
        for (block = 0; block < 10; block = block + 1)
            consume_bundle(block);

        timeout = 0;
        while (!done && timeout < 20000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!done || error) begin
            $display("FAIL burst run done=%b error=%b timeout=%0d", done, error, timeout);
            $fatal(1);
        end
        if (!saw_four_block_issue) begin
            $display("FAIL scheduler never accumulated a four-block issue burst");
            $fatal(1);
        end
        if (done_job_id !== cfg_job_id) begin
            $display("FAIL done_job_id=%08x expected=%08x", done_job_id, cfg_job_id);
            $fatal(1);
        end

        $display("PASS tb_VPU8_burst blocks=10 burst_pattern=4+4+2 ordered=1");
        $finish;
    end
endmodule
