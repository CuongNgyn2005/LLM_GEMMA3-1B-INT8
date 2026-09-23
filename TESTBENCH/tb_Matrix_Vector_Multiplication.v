`ifndef TB_MATRIX_VECTOR_MULTIPLICATION_V
`define TB_MATRIX_VECTOR_MULTIPLICATION_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_Matrix_Vector_Multiplication #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam NUM_LANES = 16;
    localparam ACT_WIDTH = 8;
    localparam WEIGHT_WIDTH = 8;
    localparam ACC_WIDTH = 32;
    localparam SCALE_WIDTH = 16;
    localparam SCALE_FRAC_BITS = 15;
    localparam RESULT_FIFO_DEPTH = 8;
    localparam AXI_DATA_WIDTH = 128;
    localparam MAX_ROWS = 256;
    localparam MAX_COL_BEATS = 128;
    localparam MAX_GROUP_Q8_BLOCKS = 64;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire CLK = tb_clk;
    reg RST = '0;
    reg ctrl_start = '0;
    reg ctrl_clear_done = '0;
    reg [15:0]                       cfg_rows = '0;
    reg [15:0]                       cfg_cols = '0;
    reg [15:0]                       cfg_col_beats = '0;
    reg [SCALE_WIDTH-1:0]            cfg_scale = '0;
    reg [4:0]                        compute_mode = '0;
    reg cfg_wr_bank = '0;
    reg cfg_rd_bank = '0;
    reg [31:0]                       cfg_job_id = '0;
    wire busy;
    wire done;
    wire error;
    wire [15:0]                       active_row;
    wire [15:0]                       active_col_beat;
    wire active_bank;
    wire done_bank;
    wire [31:0]                       active_job_id;
    wire [31:0]                       done_job_id;
    wire spu_raw_valid;
    reg spu_raw_ready = '0;
    wire signed [31:0]                spu_raw_data;
    wire [15:0]                       spu_raw_row;
    wire [15:0]                       spu_raw_block;
    wire [15:0]                       spu_raw_group_blocks;
    wire spu_raw_last_block;
    wire spu_raw_clear_accum;
    wire [31:0]                       spu_raw_job_id;
    wire spu_raw_bank;
    wire [31:0]                       spu_raw_scale_index;
    wire spu_raw_done;
    wire spu_raw_pair_valid;
    wire signed [31:0]                spu_raw_pair_data;
    wire [15:0]                       spu_raw_pair_row;
    wire [15:0]                       spu_raw_pair_block;
    wire [15:0]                       spu_raw_pair_group_blocks;
    wire spu_raw_pair_last_block;
    wire spu_raw_pair_clear_accum;
    wire [31:0]                       spu_raw_pair_job_id;
    wire spu_raw_pair_bank;
    wire [31:0]                       spu_raw_pair_scale_index;
    wire [7:0]                        spu_raw_lane_valid;
    wire [8*32-1:0]                   spu_raw_lane_data;
    wire [8*16-1:0]                   spu_raw_lane_row;
    wire [8*32-1:0]                   spu_raw_lane_scale_index;
    reg mm_wr_en = '0;
    reg [1:0]                        mm_wr_region = '0;
    reg [31:0]                       mm_wr_index = '0;
    reg [AXI_DATA_WIDTH-1:0]         mm_wr_data = '0;
    reg [(AXI_DATA_WIDTH/8)-1:0]     mm_wr_strb = '0;
    reg mm_rd_en = '0;
    reg [1:0]                        mm_rd_region = '0;
    reg [31:0]                       mm_rd_index = '0;
    wire [AXI_DATA_WIDTH-1:0]         mm_rd_data;
    wire mm_rd_valid;
    wire mm_rd_error;
    integer checks = 0;
    Matrix_Vector_Multiplication dut (
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
        .spu_raw_lane_valid(spu_raw_lane_valid),
        .spu_raw_lane_data(spu_raw_lane_data),
        .spu_raw_lane_row(spu_raw_lane_row),
        .spu_raw_lane_scale_index(spu_raw_lane_scale_index),
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
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_Matrix_Vector_Multiplication: %0s", message);
            checks = checks + 1;
        end
    endtask
    task reset_dut;
        begin
            @(negedge tb_clk);
            RST = 0;
            repeat (4) @(negedge tb_clk);
            RST = 1;
            repeat (2) @(negedge tb_clk);
        end
    endtask
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_Matrix_Vector_Multiplication: watchdog timeout");
    end
    integer t;
    task wr;
        input [1:0] region;
        input [31:0] idx;
        input [127:0] data;
        begin
            @(negedge tb_clk); mm_wr_en=1; mm_wr_region=region; mm_wr_index=idx;
            mm_wr_data=data; mm_wr_strb=16'hffff;
            @(negedge tb_clk); mm_wr_en=0;
        end
    endtask
    task start_job;
        begin
            @(negedge tb_clk); ctrl_start=1;
            @(negedge tb_clk); ctrl_start=0;
        end
    endtask
    initial begin
        reset_dut();
        cfg_rows=1; cfg_cols=16; cfg_col_beats=1; cfg_scale=16'h3c00;
        cfg_job_id=32'h12345678; compute_mode=0; spu_raw_ready=1;
        wr(0,0,{16{8'd2}});
        wr(1,0,{16{8'hfd}});
        repeat(4) @(negedge tb_clk);
        start_job();
        t=0;
        while(!done && t<1000) begin @(negedge tb_clk); t=t+1; end
        check(done && !error && done_job_id===32'h12345678,"signed GEMV completion/job identity");
        @(negedge tb_clk); mm_rd_en=1; mm_rd_region=2; mm_rd_index=0;
        @(negedge tb_clk); mm_rd_en=0;
        t=0;
        while(!mm_rd_valid && t<32) begin @(negedge tb_clk); t=t+1; end
        check(mm_rd_valid && !mm_rd_error && $signed(mm_rd_data[31:0])=== -32'sd96,"16-lane signed dot product");
        @(negedge tb_clk); ctrl_clear_done=1;
        @(negedge tb_clk); ctrl_clear_done=0; cfg_rows=0;
        start_job(); t=0;
        while(!done && t<100) begin @(negedge tb_clk); t=t+1; end
        check(done && error,"zero rows rejected");
        completed = 1;
        $display("[TB][PASS] tb_Matrix_Vector_Multiplication checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
