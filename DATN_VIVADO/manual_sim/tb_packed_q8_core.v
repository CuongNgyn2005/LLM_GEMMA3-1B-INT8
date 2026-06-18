`timescale 1ns/1ps

module tb_packed_q8_core #(
    parameter integer MAX_COL_BEATS = 32
);
    localparam integer AXI_DATA_WIDTH = 128;

    reg clk = 1'b0;
    reg resetn = 1'b0;

    reg ctrl_start = 1'b0;
    reg ctrl_clear_done = 1'b0;
    reg [15:0] cfg_rows = 16'd2;
    reg [15:0] cfg_cols = 16'd64;
    reg [15:0] cfg_col_beats = 16'd4;
    reg [15:0] cfg_scale = 16'h3c00;
    reg [1:0] compute_mode = 2'b01;

    wire busy;
    wire done;
    wire error;
    wire [15:0] active_row;
    wire [15:0] active_col_beat;

    reg mm_wr_en = 1'b0;
    reg [1:0] mm_wr_region = 2'd0;
    reg [31:0] mm_wr_index = 32'd0;
    reg [AXI_DATA_WIDTH-1:0] mm_wr_data = {AXI_DATA_WIDTH{1'b0}};
    reg [(AXI_DATA_WIDTH/8)-1:0] mm_wr_strb = {(AXI_DATA_WIDTH/8){1'b0}};

    reg mm_rd_en = 1'b0;
    reg [1:0] mm_rd_region = 2'd2;
    reg [31:0] mm_rd_index = 32'd0;
    wire [AXI_DATA_WIDTH-1:0] mm_rd_data;
    wire mm_rd_valid;
    wire mm_rd_error;

    integer lane;
    integer row;
    integer timeout;
    reg [127:0] result_word;

    always #1.6665 clk = ~clk;

    Matrix_Vector_Multiplication #(
        .MAX_ROWS(256),
        .MAX_COL_BEATS(MAX_COL_BEATS)
    ) dut (
        .CLK(clk),
        .RST(resetn),
        .ctrl_start(ctrl_start),
        .ctrl_clear_done(ctrl_clear_done),
        .cfg_rows(cfg_rows),
        .cfg_cols(cfg_cols),
        .cfg_col_beats(cfg_col_beats),
        .cfg_scale(cfg_scale),
        .compute_mode(compute_mode),
        .busy(busy),
        .done(done),
        .error(error),
        .active_row(active_row),
        .active_col_beat(active_col_beat),
        .mm_wr_en(mm_wr_en),
        .mm_wr_region(mm_wr_region),
        .mm_wr_index(mm_wr_index),
        .mm_wr_data(mm_wr_data),
        .mm_wr_strb(mm_wr_strb),
        .mm_rd_en(mm_rd_en),
        .mm_rd_region(mm_rd_region),
        .mm_rd_index(mm_rd_index),
        .mm_rd_data(mm_rd_data),
        .mm_rd_valid(mm_rd_valid),
        .mm_rd_error(mm_rd_error)
    );

    function [127:0] splat_i8;
        input signed [7:0] value;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                splat_i8[8*i +: 8] = value;
        end
    endfunction

    task write_beat;
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
            mm_wr_strb = 16'h0000;
        end
    endtask

    task read_result_word;
        input [31:0] index;
        output [127:0] data;
        begin
            @(negedge clk);
            mm_rd_en = 1'b1;
            mm_rd_region = 2'd2;
            mm_rd_index = index;
            @(negedge clk);
            mm_rd_en = 1'b0;
            while (!mm_rd_valid)
                @(negedge clk);
            if (mm_rd_error) begin
                $display("[PACKED_Q8] read error index=%0d", index);
                $fatal(1);
            end
            data = mm_rd_data;
        end
    endtask

    initial begin
        repeat (8) @(negedge clk);
        resetn = 1'b1;
        repeat (4) @(negedge clk);

        write_beat(2'd0, 32'd0, splat_i8(8'sd1));
        write_beat(2'd0, 32'd1, splat_i8(8'sd1));
        write_beat(2'd0, 32'd2, splat_i8(8'sd2));
        write_beat(2'd0, 32'd3, splat_i8(8'sd2));

        write_beat(2'd1, 32'd0, splat_i8(8'sd1));
        write_beat(2'd1, 32'd1, splat_i8(8'sd1));
        write_beat(2'd1, 32'd2, splat_i8(8'sd1));
        write_beat(2'd1, 32'd3, splat_i8(8'sd1));

        write_beat(2'd1, MAX_COL_BEATS + 32'd0, splat_i8(-8'sd1));
        write_beat(2'd1, MAX_COL_BEATS + 32'd1, splat_i8(-8'sd1));
        write_beat(2'd1, MAX_COL_BEATS + 32'd2, splat_i8(8'sd3));
        write_beat(2'd1, MAX_COL_BEATS + 32'd3, splat_i8(8'sd3));

        @(negedge clk);
        ctrl_start = 1'b1;
        @(negedge clk);
        ctrl_start = 1'b0;

        timeout = 0;
        while (!done && timeout < 10000) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!done || error) begin
            $display("[PACKED_Q8] core failed done=%0d error=%0d row=%0d beat=%0d",
                     done, error, active_row, active_col_beat);
            $fatal(1);
        end

        read_result_word(32'd0, result_word);
        $display("[PACKED_Q8] results=[%0d,%0d,%0d,%0d] expected=[32,64,-32,192]",
                 $signed(result_word[31:0]),
                 $signed(result_word[63:32]),
                 $signed(result_word[95:64]),
                 $signed(result_word[127:96]));

        if (($signed(result_word[31:0]) !== 32'sd32) ||
            ($signed(result_word[63:32]) !== 32'sd64) ||
            ($signed(result_word[95:64]) !== -32'sd32) ||
            ($signed(result_word[127:96]) !== 32'sd192)) begin
            $display("[PACKED_Q8] FAIL");
            $fatal(1);
        end

        if (MAX_COL_BEATS >= 256) begin
            // Row 64 starts at logical weight address 16384 when the stride is
            // 256 beats, so this run crosses the 16K depth-shard boundary.
            @(negedge clk);
            ctrl_clear_done = 1'b1;
            @(negedge clk);
            ctrl_clear_done = 1'b0;

            cfg_rows = 16'd66;
            cfg_cols = 16'd16;
            cfg_col_beats = 16'd1;
            compute_mode = 2'b00;
            write_beat(2'd0, 32'd0, splat_i8(8'sd1));
            for (row = 0; row < 66; row = row + 1) begin
                if (row == 64)
                    write_beat(2'd1, row*MAX_COL_BEATS, splat_i8(8'sd2));
                else if (row == 65)
                    write_beat(2'd1, row*MAX_COL_BEATS, splat_i8(-8'sd2));
                else
                    write_beat(2'd1, row*MAX_COL_BEATS, splat_i8(8'sd1));
            end

            repeat (2) @(negedge clk);
            @(negedge clk);
            ctrl_start = 1'b1;
            @(negedge clk);
            ctrl_start = 1'b0;

            timeout = 0;
            while (!done && timeout < 20000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!done || error) begin
                $display("[SHARD_BOUNDARY] core failed done=%0d error=%0d row=%0d beat=%0d",
                         done, error, active_row, active_col_beat);
                $fatal(1);
            end
            $display("[SHARD_BOUNDARY] compute cycles=%0d result_words[63]=%h [64]=%h [65]=%h",
                     timeout, dut.u_result_bram.mem[63], dut.u_result_bram.mem[64],
                     dut.u_result_bram.mem[65]);

            read_result_word(32'd63, result_word);
            if ($signed(result_word[31:0]) !== 32'sd16) begin
                $display("[SHARD_BOUNDARY] FAIL row=63 result=%0d expected=16",
                         $signed(result_word[31:0]));
                $fatal(1);
            end
            read_result_word(32'd64, result_word);
            if ($signed(result_word[31:0]) !== 32'sd32) begin
                $display("[SHARD_BOUNDARY] FAIL row=64 result=%0d expected=32",
                         $signed(result_word[31:0]));
                $fatal(1);
            end
            read_result_word(32'd65, result_word);
            $display("[SHARD_BOUNDARY] rows=[63,64,65] results=[16,32,%0d] expected=[16,32,-32]",
                     $signed(result_word[31:0]));
            if ($signed(result_word[31:0]) !== -32'sd32) begin
                $display("[SHARD_BOUNDARY] FAIL");
                $fatal(1);
            end
            $display("[SHARD_BOUNDARY] PASS");
        end

        $display("[PACKED_Q8] PASS");
        $finish;
    end
endmodule
