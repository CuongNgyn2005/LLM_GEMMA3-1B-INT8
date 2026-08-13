`timescale 1ns/1ps

module tb_VPU_SPU8_integration;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;

    reg ctrl_start = 1'b0;
    reg [15:0] cfg_rows = 16'd8;
    reg [15:0] cfg_cols = 16'd32;
    reg [15:0] cfg_col_beats = 16'd2;
    reg [15:0] cfg_scale = 16'h3c00;
    reg [4:0] compute_mode = 5'b10001;
    reg cfg_wr_bank = 1'b0, cfg_rd_bank = 1'b0;
    reg [31:0] cfg_job_id = 32'h55aa0001;
    wire vpu_done, vpu_error;

    wire raw_valid, raw_ready, raw_done;
    wire signed [31:0] raw_data;
    wire [15:0] raw_row, raw_block, raw_group_blocks;
    wire raw_last_block, raw_clear_accum;
    wire [31:0] raw_job_id, raw_scale_index;
    wire raw_bank;
    wire [7:0] raw_lane_valid;
    wire [255:0] raw_lane_data;
    wire [127:0] raw_lane_row;
    wire [255:0] raw_lane_scale_index;

    reg vpu_mm_wr_en = 1'b0;
    reg [1:0] vpu_mm_wr_region = 2'd0;
    reg [31:0] vpu_mm_wr_index = 32'd0;
    reg [127:0] vpu_mm_wr_data = 128'd0;
    reg [15:0] vpu_mm_wr_strb = 16'd0;

    Matrix_Vector_Multiplication vpu (
        .CLK(clk), .RST(resetn), .ctrl_start(ctrl_start), .ctrl_clear_done(1'b0),
        .cfg_rows(cfg_rows), .cfg_cols(cfg_cols), .cfg_col_beats(cfg_col_beats),
        .cfg_scale(cfg_scale), .compute_mode(compute_mode), .cfg_wr_bank(cfg_wr_bank),
        .cfg_rd_bank(cfg_rd_bank), .cfg_job_id(cfg_job_id), .done(vpu_done), .error(vpu_error),
        .spu_raw_valid(raw_valid), .spu_raw_ready(raw_ready), .spu_raw_data(raw_data),
        .spu_raw_row(raw_row), .spu_raw_block(raw_block), .spu_raw_group_blocks(raw_group_blocks),
        .spu_raw_last_block(raw_last_block), .spu_raw_clear_accum(raw_clear_accum),
        .spu_raw_job_id(raw_job_id), .spu_raw_bank(raw_bank), .spu_raw_scale_index(raw_scale_index),
        .spu_raw_done(raw_done), .spu_raw_lane_valid(raw_lane_valid),
        .spu_raw_lane_data(raw_lane_data), .spu_raw_lane_row(raw_lane_row),
        .spu_raw_lane_scale_index(raw_lane_scale_index),
        .mm_wr_en(vpu_mm_wr_en), .mm_wr_region(vpu_mm_wr_region), .mm_wr_index(vpu_mm_wr_index),
        .mm_wr_data(vpu_mm_wr_data), .mm_wr_strb(vpu_mm_wr_strb),
        .mm_rd_en(1'b0), .mm_rd_region(2'd0), .mm_rd_index(32'd0)
    );

    wire sm0_en, sm0_we, sm1_en, sm1_we, sm3_en;
    wire [1:0] sm0_region, sm1_region;
    wire [31:0] sm0_index, sm1_index, sm3_index;
    wire [127:0] sm0_wdata, sm1_wdata;
    wire [15:0] sm0_wstrb, sm1_wstrb;
    wire [127:0] sm0_rdata, sm1_rdata, sm3_rdata;
    wire p3_lock_valid, p3_lock;
    wire [31:0] stream_count, stream_out_count, stream_error_count;
    wire [31:0] stream_entry_done_count, stream_final_write_count, stream_status;

    SPU_VPU_Stream8 spu_stream (
        .clk(clk), .resetn(resetn), .soft_reset(1'b0), .command_busy(1'b0),
        .split_scale_enable(1'b0), .vpu_valid(raw_valid), .vpu_ready(raw_ready),
        .vpu_lane_valid(raw_lane_valid), .vpu_lane_data(raw_lane_data),
        .vpu_lane_row(raw_lane_row), .vpu_lane_scale_index(raw_lane_scale_index),
        .vpu_block(raw_block), .vpu_group_blocks(raw_group_blocks),
        .vpu_last_block(raw_last_block), .vpu_clear_accum(raw_clear_accum),
        .vpu_job_id(raw_job_id), .vpu_bank(raw_bank), .vpu_done(raw_done),
        .mem0_en(sm0_en), .mem0_we(sm0_we), .mem0_region(sm0_region), .mem0_index(sm0_index),
        .mem0_wdata(sm0_wdata), .mem0_wstrb(sm0_wstrb), .mem0_rdata(sm0_rdata),
        .mem1_en(sm1_en), .mem1_we(sm1_we), .mem1_region(sm1_region), .mem1_index(sm1_index),
        .mem1_wdata(sm1_wdata), .mem1_wstrb(sm1_wstrb), .mem1_rdata(sm1_rdata),
        .mem3_scratch_en(sm3_en), .mem3_scratch_index(sm3_index), .mem3_scratch_rdata(sm3_rdata),
        .p3_bank_lock_valid(p3_lock_valid), .p3_bank_lock(p3_lock),
        .stream_count(stream_count), .stream_out_count(stream_out_count),
        .stream_error_count(stream_error_count), .stream_entry_done_count(stream_entry_done_count),
        .stream_final_write_count(stream_final_write_count), .stream_status(stream_status)
    );

    reg spu_mm_wr_en = 1'b0;
    reg [1:0] spu_mm_wr_region = 2'd0;
    reg [31:0] spu_mm_wr_index = 32'd0;
    reg [127:0] spu_mm_wr_data = 128'd0;
    reg [15:0] spu_mm_wr_strb = 16'd0;
    reg spu_mm_rd_en = 1'b0;
    reg [1:0] spu_mm_rd_region = 2'd0;
    reg [31:0] spu_mm_rd_index = 32'd0;
    wire [127:0] spu_mm_rd_data;
    wire spu_mm_rd_valid, spu_mm_rd_error;

    SPU_Local_Memory spu_mem (
        .clk(clk), .resetn(resetn),
        .mm_wr_en(spu_mm_wr_en), .mm_wr_region(spu_mm_wr_region), .mm_wr_index(spu_mm_wr_index),
        .mm_wr_data(spu_mm_wr_data), .mm_wr_strb(spu_mm_wr_strb),
        .mm_rd_en(spu_mm_rd_en), .mm_rd_region(spu_mm_rd_region), .mm_rd_index(spu_mm_rd_index),
        .mm_rd_data(spu_mm_rd_data), .mm_rd_valid(spu_mm_rd_valid), .mm_rd_error(spu_mm_rd_error),
        .core_en(sm0_en), .core_we(sm0_we), .core_region(sm0_region), .core_index(sm0_index),
        .core_wdata(sm0_wdata), .core_wstrb(sm0_wstrb), .core_rdata(sm0_rdata),
        .core2_en(sm1_en), .core2_we(sm1_we), .core2_region(sm1_region), .core2_index(sm1_index),
        .core2_wdata(sm1_wdata), .core2_wstrb(sm1_wstrb), .core2_rdata(sm1_rdata),
        .core3_scratch_en(sm3_en), .core3_scratch_index(sm3_index), .core3_scratch_rdata(sm3_rdata),
        .stream_p3_bank_lock_valid(p3_lock_valid), .stream_p3_bank_lock(p3_lock)
    );

    function [127:0] repeat_byte;
        input [7:0] value;
        integer j;
        begin
            for (j=0; j<16; j=j+1) repeat_byte[8*j +: 8] = value;
        end
    endfunction

    task vpu_write;
        input [1:0] region; input [31:0] index; input [127:0] data;
        begin
            @(negedge clk); vpu_mm_wr_en=1'b1; vpu_mm_wr_region=region;
            vpu_mm_wr_index=index; vpu_mm_wr_data=data; vpu_mm_wr_strb=16'hffff;
            @(negedge clk); vpu_mm_wr_en=1'b0; vpu_mm_wr_strb=16'd0;
        end
    endtask

    task spu_write;
        input [1:0] region; input [31:0] index; input [127:0] data;
        begin
            @(negedge clk); spu_mm_wr_en=1'b1; spu_mm_wr_region=region;
            spu_mm_wr_index=index; spu_mm_wr_data=data; spu_mm_wr_strb=16'hffff;
            @(negedge clk); spu_mm_wr_en=1'b0; spu_mm_wr_strb=16'd0;
        end
    endtask

    task spu_read;
        input [1:0] region; input [31:0] index; output [127:0] data;
        begin
            @(negedge clk); spu_mm_rd_en=1'b1; spu_mm_rd_region=region; spu_mm_rd_index=index;
            @(negedge clk); spu_mm_rd_en=1'b0;
            while (!spu_mm_rd_valid) @(posedge clk);
            #1 data = spu_mm_rd_data;
            if (spu_mm_rd_error) $fatal(1, "SPU MMIO read error");
        end
    endtask

    integer r, beat, pair_id, parity, ext_index, timeout;
    reg [127:0] rd;
    reg signed [63:0] expected_q16;
    initial begin
        repeat (5) @(posedge clk); resetn = 1'b1; repeat (2) @(posedge clk);

        // VPU activation = 1, row r weights = r+1, two 16-byte beats.
        vpu_write(2'd0, 0, repeat_byte(8'd1));
        vpu_write(2'd0, 1, repeat_byte(8'd1));
        for (r=0; r<8; r=r+1) begin
            pair_id = r >> 1; parity = r & 1;
            for (beat=0; beat<2; beat=beat+1) begin
                ext_index = 2*(pair_id*2 + beat) + parity;
                vpu_write(2'd1, ext_index, repeat_byte(r+1));
            end
        end
        // P2 scales = 1.0 * 1.0 for rows 0..7.
        spu_write(2'd2, 0, {4{32'h3c003c00}});
        spu_write(2'd2, 1, {4{32'h3c003c00}});
        repeat (64) @(posedge clk);

        @(negedge clk); ctrl_start = 1'b1;
        @(negedge clk); ctrl_start = 1'b0;

        timeout = 0;
        while ((stream_out_count != 8 || !vpu_done) && timeout < 5000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        if (timeout >= 5000 || vpu_error || stream_error_count != 0 ||
            stream_count != 8 || stream_entry_done_count != 8 || stream_final_write_count != 8) begin
            $display("FAIL integration timeout=%0d vpu_done=%b vpu_err=%b count=%0d entry=%0d out=%0d write=%0d err=%0d",
                     timeout, vpu_done, vpu_error, stream_count, stream_entry_done_count,
                     stream_out_count, stream_final_write_count, stream_error_count);
            $fatal(1);
        end

        repeat (2) @(posedge clk);
        for (r=0; r<8; r=r+1) begin
            spu_read(2'd1, r, rd);
            expected_q16 = $signed(32*(r+1)); expected_q16 = expected_q16 <<< 16;
            if (rd[15:0] !== r[15:0] || $signed(rd[79:16]) !== expected_q16) begin
                $display("FAIL integration row=%0d stored_row=%0d q16=%0d expected=%0d",
                         r, rd[15:0], $signed(rd[79:16]), expected_q16);
                $fatal(1);
            end
        end

        $display("PASS tb_VPU_SPU8_integration");
        $finish;
    end
endmodule
