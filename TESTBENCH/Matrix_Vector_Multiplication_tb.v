/*-----------------------------------------------------------------------------
 * File          : Matrix_Vector_Multiplication_tb.v
 * Description   : Minimal testbench matching the current interface in
 *                 RTL/Matrix_Vector_Multiplication.v
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module Matrix_Vector_Multiplication_tb;

    localparam AXI_DATA_WIDTH = 128;
    localparam SCALE_WIDTH    = 16;

    reg                            CLK;
    reg                            RST;
    reg                            ctrl_start;
    reg                            ctrl_clear_done;
    reg  [15:0]                    cfg_rows;
    reg  [15:0]                    cfg_cols;
    reg  [15:0]                    cfg_col_beats;
    reg  [SCALE_WIDTH-1:0]         cfg_scale;
    reg  [4:0]                     compute_mode;
    reg                            cfg_wr_bank;
    reg                            cfg_rd_bank;
    reg  [31:0]                    cfg_job_id;

    wire                           busy;
    wire                           done;
    wire                           error;
    wire [15:0]                    active_row;
    wire [15:0]                    active_col_beat;
    wire                           active_bank;
    wire                           done_bank;
    wire [31:0]                    active_job_id;
    wire [31:0]                    done_job_id;
    wire                           spu_raw_valid;
    reg                            spu_raw_ready;
    wire signed [31:0]             spu_raw_data;
    wire [15:0]                    spu_raw_row;
    wire [15:0]                    spu_raw_block;
    wire [15:0]                    spu_raw_group_blocks;
    wire                           spu_raw_last_block;
    wire                           spu_raw_clear_accum;
    wire [31:0]                    spu_raw_job_id;
    wire                           spu_raw_bank;
    wire [31:0]                    spu_raw_scale_index;
    wire                           spu_raw_done;
    wire                           spu_raw_pair_valid;
    wire signed [31:0]             spu_raw_pair_data;
    wire [15:0]                    spu_raw_pair_row;
    wire [15:0]                    spu_raw_pair_block;
    wire [15:0]                    spu_raw_pair_group_blocks;
    wire                           spu_raw_pair_last_block;
    wire                           spu_raw_pair_clear_accum;
    wire [31:0]                    spu_raw_pair_job_id;
    wire                           spu_raw_pair_bank;
    wire [31:0]                    spu_raw_pair_scale_index;

    reg                            mm_wr_en;
    reg  [1:0]                     mm_wr_region;
    reg  [31:0]                    mm_wr_index;
    reg  [AXI_DATA_WIDTH-1:0]      mm_wr_data;
    reg  [(AXI_DATA_WIDTH/8)-1:0]  mm_wr_strb;

    reg                            mm_rd_en;
    reg  [1:0]                     mm_rd_region;
    reg  [31:0]                    mm_rd_index;
    wire [AXI_DATA_WIDTH-1:0]      mm_rd_data;
    wire                           mm_rd_valid;
    wire                           mm_rd_error;

    // Instantiate the DUT using the current RTL interface.
    Matrix_Vector_Multiplication uut (
        .CLK(CLK),
        .RST(RST),
        .ctrl_start(ctrl_start),
        .ctrl_clear_done(ctrl_clear_done),
        .cfg_rows(cfg_rows),
        .cfg_cols(cfg_cols),
        .cfg_col_beats(cfg_col_beats),
        .cfg_scale(cfg_scale),
        .compute_mode(compute_mode),
        .cfg_wr_bank(cfg_wr_bank),
        .cfg_rd_bank(cfg_rd_bank),
        .cfg_job_id(cfg_job_id),
        .busy(busy),
        .done(done),
        .error(error),
        .active_row(active_row),
        .active_col_beat(active_col_beat),
        .active_bank(active_bank),
        .done_bank(done_bank),
        .active_job_id(active_job_id),
        .done_job_id(done_job_id),
        .spu_raw_valid(spu_raw_valid),
        .spu_raw_ready(spu_raw_ready),
        .spu_raw_data(spu_raw_data),
        .spu_raw_row(spu_raw_row),
        .spu_raw_block(spu_raw_block),
        .spu_raw_group_blocks(spu_raw_group_blocks),
        .spu_raw_last_block(spu_raw_last_block),
        .spu_raw_clear_accum(spu_raw_clear_accum),
        .spu_raw_job_id(spu_raw_job_id),
        .spu_raw_bank(spu_raw_bank),
        .spu_raw_scale_index(spu_raw_scale_index),
        .spu_raw_done(spu_raw_done),
        .spu_raw_pair_valid(spu_raw_pair_valid),
        .spu_raw_pair_data(spu_raw_pair_data),
        .spu_raw_pair_row(spu_raw_pair_row),
        .spu_raw_pair_block(spu_raw_pair_block),
        .spu_raw_pair_group_blocks(spu_raw_pair_group_blocks),
        .spu_raw_pair_last_block(spu_raw_pair_last_block),
        .spu_raw_pair_clear_accum(spu_raw_pair_clear_accum),
        .spu_raw_pair_job_id(spu_raw_pair_job_id),
        .spu_raw_pair_bank(spu_raw_pair_bank),
        .spu_raw_pair_scale_index(spu_raw_pair_scale_index),
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

    always #5 CLK = ~CLK;

    initial begin
        CLK = 0;
        RST = 0;
        ctrl_start = 0;
        ctrl_clear_done = 0;
        cfg_rows = 16'd1;
        cfg_cols = 16'd1;
        cfg_col_beats = 16'd1;
        cfg_scale = 16'd0;
        compute_mode = 5'd0;
        cfg_wr_bank = 0;
        cfg_rd_bank = 0;
        cfg_job_id = 32'd0;

        spu_raw_ready = 1'b1;

        mm_wr_en = 1'b0;
        mm_wr_region = 2'd0;
        mm_wr_index = 32'd0;
        mm_wr_data = {AXI_DATA_WIDTH{1'b0}};
        mm_wr_strb = {(AXI_DATA_WIDTH/8){1'b0}};

        mm_rd_en = 1'b0;
        mm_rd_region = 2'd0;
        mm_rd_index = 32'd0;

        #20 RST = 1'b1;
        #40 RST = 1'b0;

        #40;
        cfg_rows = 16'd1;
        cfg_cols = 16'd1;
        cfg_col_beats = 16'd1;
        cfg_scale = 16'd4096;
        compute_mode = 5'd0;
        ctrl_start = 1'b1;
        #10 ctrl_start = 1'b0;

        #200;
        $display("Matrix_Vector_Multiplication_tb: simulation finished.");
        $finish;
    end

endmodule
