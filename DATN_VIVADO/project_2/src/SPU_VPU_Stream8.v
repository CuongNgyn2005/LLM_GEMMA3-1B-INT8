/*
 * 8-lane VPU -> SPU Q8_0 scale/accumulate stream.
 * One accepted bundle carries up to eight row results for one Q8 block.
 * Scale RAM is read two rows/cycle through the existing two PARAM ports;
 * all valid rows then execute SPU_Q8_Scale_Accum in parallel.
 */
`timescale 1ns/1ps

module SPU_VPU_Stream8 #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH = 4096,
    parameter integer MAX_ROWS = 256
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         soft_reset,
    input  wire                         command_busy,
    input  wire                         split_scale_enable,

    input  wire                         vpu_valid,
    output wire                         vpu_ready,
    input  wire [7:0]                   vpu_lane_valid,
    input  wire [8*32-1:0]              vpu_lane_data,
    input  wire [8*16-1:0]              vpu_lane_row,
    input  wire [8*32-1:0]              vpu_lane_scale_index,
    input  wire [15:0]                  vpu_block,
    input  wire [15:0]                  vpu_group_blocks,
    input  wire                         vpu_last_block,
    input  wire                         vpu_clear_accum,
    input  wire [31:0]                  vpu_job_id,
    input  wire                         vpu_bank,
    input  wire                         vpu_done,

    output reg                          mem0_en,
    output reg                          mem0_we,
    output reg  [1:0]                   mem0_region,
    output reg  [31:0]                  mem0_index,
    output reg  [AXI_DATA_WIDTH-1:0]    mem0_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0] mem0_wstrb,
    input  wire [AXI_DATA_WIDTH-1:0]    mem0_rdata,

    output reg                          mem1_en,
    output reg                          mem1_we,
    output reg  [1:0]                   mem1_region,
    output reg  [31:0]                  mem1_index,
    output reg  [AXI_DATA_WIDTH-1:0]    mem1_wdata,
    output reg  [(AXI_DATA_WIDTH/8)-1:0] mem1_wstrb,
    input  wire [AXI_DATA_WIDTH-1:0]    mem1_rdata,

    output reg                          mem3_scratch_en,
    output reg  [31:0]                  mem3_scratch_index,
    input  wire [AXI_DATA_WIDTH-1:0]    mem3_scratch_rdata,

    output reg                          p3_bank_lock_valid,
    output reg                          p3_bank_lock,

    output reg  [31:0]                  stream_count,
    output reg  [31:0]                  stream_done_count,
    output reg  [31:0]                  stream_drop_count,
    output reg  [31:0]                  stream_out_count,
    output reg  [31:0]                  stream_error_count,
    output reg  [31:0]                  stream_last_raw,
    output reg  [31:0]                  stream_last_meta,
    output reg  [31:0]                  stream_last_accum_lo,
    output reg  [31:0]                  stream_last_accum_hi,
    output reg  [31:0]                  stream_last_job,
    output reg  [31:0]                  stream_last_bank,
    output wire [31:0]                  stream_status,
    output reg  [31:0]                  stream_fifo_high_water,
    output reg  [31:0]                  stream_raw_stall_cycles,
    output reg  [31:0]                  stream_entry_done_count,
    output reg  [31:0]                  stream_final_write_count,
    output reg  [31:0]                  stream_p3_reject_count,
    output wire [31:0]                  stream_p3_status
);
    localparam [1:0] REGION_OUT = 2'd1;
    localparam [1:0] REGION_PARAM = 2'd2;
    localparam integer SCALE32_PER_WORD = AXI_DATA_WIDTH/32;
    localparam integer SCALE16_PER_WORD = AXI_DATA_WIDTH/16;
    localparam integer P3_BANK_WORD_DEPTH = WORD_DEPTH/2;
    localparam [31:0] P2_ENTRY_DEPTH = WORD_DEPTH*SCALE32_PER_WORD;
    localparam [31:0] P3_ENTRY_DEPTH = P3_BANK_WORD_DEPTH*SCALE16_PER_WORD;

    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_READ    = 3'd1;
    localparam [2:0] S_CAPTURE = 3'd2;
    localparam [2:0] S_START   = 3'd3;
    localparam [2:0] S_WAIT    = 3'd4;
    localparam [2:0] S_WRITE   = 3'd5;

    reg [2:0] state_r;
    reg [1:0] pair_idx_r;
    reg [7:0] lane_valid_r;
    reg signed [31:0] raw_r [0:7];
    reg [15:0] row_r [0:7];
    // Store the decoded scale address at bundle acceptance.  Keeping the
    // word address and lane selector registered removes the variable shift
    // and P3 bank-offset adder from the memory-control timing cone.
    reg [31:0] scale_word_index_r [0:7];
    reg [2:0] scale_lane_r [0:7];
    reg [15:0] act_scale_r [0:7];
    reg [15:0] weight_scale_r [0:7];
    reg signed [63:0] final_q16_r [0:7];
    reg [15:0] block_r;
    reg [15:0] group_blocks_r;
    reg last_block_r;
    reg clear_accum_r;
    reg [31:0] job_id_r;
    reg bank_r;
    reg p3_r;
    reg p3_done_seen_r;
    reg [15:0] p3_act_scale_r;
    reg [7:0] accum_start_r;

    wire [7:0] accum_busy;
    wire [7:0] accum_entry_done;
    wire [7:0] accum_out_valid;
    wire [8*16-1:0] accum_out_row_bus;
    wire [8*64-1:0] accum_out_q16_bus;
    wire [7:0] accum_error;
    wire [8*4-1:0] accum_error_code_bus;

    function [3:0] popcount8;
        input [7:0] v;
        integer k;
        begin
            popcount8 = 4'd0;
            for (k = 0; k < 8; k = k + 1)
                popcount8 = popcount8 + v[k];
        end
    endfunction

    function [2:0] highest_lane;
        input [7:0] v;
        integer k;
        begin
            highest_lane = 3'd0;
            for (k = 0; k < 8; k = k + 1)
                if (v[k]) highest_lane = k[2:0];
        end
    endfunction

    wire bank_mismatch = split_scale_enable && p3_bank_lock_valid &&
                         (vpu_bank != p3_bank_lock);
    assign vpu_ready = resetn && (state_r == S_IDLE) && !command_busy &&
                       !bank_mismatch;
    wire vpu_fire = vpu_valid && vpu_ready;
    wire [3:0] accepted_lanes = popcount8(vpu_lane_valid);
    wire [2:0] tail_lane = highest_lane(vpu_lane_valid);

    integer vi;
    reg bundle_index_ok;
    reg [31:0] idx_tmp;
    always @* begin
        bundle_index_ok = (vpu_lane_valid != 8'd0) &&
                          (vpu_group_blocks != 16'd0) &&
                          (vpu_block < vpu_group_blocks);
        for (vi = 0; vi < 8; vi = vi + 1) begin
            idx_tmp = vpu_lane_scale_index[32*vi +: 32];
            if (vpu_lane_valid[vi]) begin
                if (vpu_lane_row[16*vi +: 16] >= MAX_ROWS)
                    bundle_index_ok = 1'b0;
                if (!split_scale_enable && (idx_tmp >= P2_ENTRY_DEPTH))
                    bundle_index_ok = 1'b0;
                if (split_scale_enable && (idx_tmp >= P3_ENTRY_DEPTH))
                    bundle_index_ok = 1'b0;
            end
        end
        if (split_scale_enable &&
            ((WORD_DEPTH < 2) || ((WORD_DEPTH & 1) != 0) ||
             ((vpu_block >> 3) >= P3_BANK_WORD_DEPTH)))
            bundle_index_ok = 1'b0;
    end

    wire [2:0] lane0_sel = {pair_idx_r, 1'b0};
    wire [2:0] lane1_sel = {pair_idx_r, 1'b1};
    wire [31:0] p3_bank_base = bank_r ? P3_BANK_WORD_DEPTH : 32'd0;
    wire [31:0] lane0_word_index = scale_word_index_r[lane0_sel];
    wire [31:0] lane1_word_index = scale_word_index_r[lane1_sel];
    wire [2:0] lane0_scale_lane = scale_lane_r[lane0_sel];
    wire [2:0] lane1_scale_lane = scale_lane_r[lane1_sel];
    wire [31:0] p3_act_word_index = p3_bank_base + ({16'd0,block_r} >> 3);
    wire [2:0] p3_act_lane = block_r[2:0];

    wire all_accum_idle = ((accum_busy & lane_valid_r) == 8'd0);
    wire all_accum_done = ((accum_entry_done | ~lane_valid_r) == 8'hff);
    wire any_accum_error = |(accum_error & lane_valid_r);

    always @* begin
        mem0_en = 1'b0; mem0_we = 1'b0; mem0_region = REGION_PARAM;
        mem0_index = 32'd0; mem0_wdata = {AXI_DATA_WIDTH{1'b0}};
        mem0_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};
        mem1_en = 1'b0; mem1_we = 1'b0; mem1_region = REGION_PARAM;
        mem1_index = 32'd0; mem1_wdata = {AXI_DATA_WIDTH{1'b0}};
        mem1_wstrb = {(AXI_DATA_WIDTH/8){1'b0}};
        mem3_scratch_en = 1'b0; mem3_scratch_index = 32'd0;

        if (state_r == S_READ) begin
            if (lane_valid_r[lane0_sel]) begin
                mem0_en = 1'b1;
                mem0_index = lane0_word_index;
            end
            if (lane_valid_r[lane1_sel]) begin
                mem1_en = 1'b1;
                mem1_index = lane1_word_index;
            end
            if (p3_r && (pair_idx_r == 2'd0)) begin
                mem3_scratch_en = 1'b1;
                mem3_scratch_index = p3_act_word_index;
            end
        end else if (state_r == S_WRITE) begin
            if (lane_valid_r[lane0_sel]) begin
                mem0_en = 1'b1; mem0_we = 1'b1; mem0_region = REGION_OUT;
                mem0_index = {16'd0,row_r[lane0_sel]};
                mem0_wdata = {{(AXI_DATA_WIDTH-80){1'b0}},final_q16_r[lane0_sel],row_r[lane0_sel]};
                mem0_wstrb = 16'h03ff;
            end
            if (lane_valid_r[lane1_sel]) begin
                mem1_en = 1'b1; mem1_we = 1'b1; mem1_region = REGION_OUT;
                mem1_index = {16'd0,row_r[lane1_sel]};
                mem1_wdata = {{(AXI_DATA_WIDTH-80){1'b0}},final_q16_r[lane1_sel],row_r[lane1_sel]};
                mem1_wstrb = 16'h03ff;
            end
        end
    end

    assign stream_status[0] = (state_r == S_IDLE);
    assign stream_status[1] = (state_r == S_IDLE);
    assign stream_status[2] = all_accum_idle;
    assign stream_status[3] = (state_r != S_WRITE);
    assign stream_status[4] = (state_r == S_IDLE) && all_accum_idle;
    assign stream_status[5] = p3_bank_lock_valid;
    assign stream_status[6] = p3_bank_lock;
    assign stream_status[31:7] = 25'd0;
    assign stream_p3_status = {24'd0,split_scale_enable,p3_done_seen_r,
                               p3_bank_lock,p3_bank_lock_valid,p3_r,
                               1'b0,(state_r==S_IDLE),(state_r==S_IDLE)};

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : GEN_ACCUM8
            SPU_Q8_Scale_Accum #(
                .ROW_ID_WIDTH(16), .MAX_ROWS(MAX_ROWS),
                .ACC_WIDTH(64), .FIXED_FRAC_BITS(16)
            ) u_accum (
                .clk(clk), .resetn(resetn), .start(accum_start_r[gi]),
                .raw_in(raw_r[gi]), .act_scale_fp16(act_scale_r[gi]),
                .weight_scale_fp16(weight_scale_r[gi]), .row_id(row_r[gi]),
                .clear_accum(clear_accum_r), .last_block(last_block_r),
                .busy(accum_busy[gi]), .entry_done(accum_entry_done[gi]),
                .out_valid(accum_out_valid[gi]),
                .out_row_id(accum_out_row_bus[16*gi +: 16]),
                .out_accum_q16(accum_out_q16_bus[64*gi +: 64]),
                .error(accum_error[gi]),
                .error_code(accum_error_code_bus[4*gi +: 4])
            );
        end
    endgenerate

    integer i;
    reg [3:0] write_count;
    always @(posedge clk) begin
        if (!resetn || soft_reset) begin
            state_r <= S_IDLE;
            pair_idx_r <= 2'd0;
            lane_valid_r <= 8'd0;
            block_r <= 16'd0; group_blocks_r <= 16'd0;
            last_block_r <= 1'b0; clear_accum_r <= 1'b0;
            job_id_r <= 32'd0; bank_r <= 1'b0; p3_r <= 1'b0;
            p3_done_seen_r <= 1'b0; p3_act_scale_r <= 16'd0;
            accum_start_r <= 8'd0;
            p3_bank_lock_valid <= 1'b0; p3_bank_lock <= 1'b0;
            stream_count <= 32'd0; stream_done_count <= 32'd0;
            stream_drop_count <= 32'd0; stream_out_count <= 32'd0;
            stream_error_count <= 32'd0; stream_last_raw <= 32'd0;
            stream_last_meta <= 32'd0; stream_last_accum_lo <= 32'd0;
            stream_last_accum_hi <= 32'd0; stream_last_job <= 32'd0;
            stream_last_bank <= 32'd0; stream_fifo_high_water <= 32'd0;
            stream_raw_stall_cycles <= 32'd0;
            stream_entry_done_count <= 32'd0;
            stream_final_write_count <= 32'd0;
            stream_p3_reject_count <= 32'd0;
            write_count <= 4'd0;
            for (i = 0; i < 8; i = i + 1) begin
                raw_r[i] <= 32'sd0; row_r[i] <= 16'd0;
                scale_word_index_r[i] <= 32'd0; scale_lane_r[i] <= 3'd0;
                act_scale_r[i] <= 16'd0; weight_scale_r[i] <= 16'd0;
                final_q16_r[i] <= 64'sd0;
            end
        end else begin
            accum_start_r <= 8'd0;
            if (vpu_valid && !vpu_ready)
                stream_raw_stall_cycles <= stream_raw_stall_cycles + 32'd1;
            if (vpu_done) begin
                stream_done_count <= stream_done_count + 32'd1;
                if (p3_bank_lock_valid) p3_done_seen_r <= 1'b1;
            end

            case (state_r)
                S_IDLE: begin
                    if (p3_done_seen_r && p3_bank_lock_valid) begin
                        p3_bank_lock_valid <= 1'b0;
                        p3_done_seen_r <= 1'b0;
                    end
                    if (vpu_fire) begin
                        if (!bundle_index_ok) begin
                            stream_drop_count <= stream_drop_count + accepted_lanes;
                            stream_error_count <= stream_error_count + accepted_lanes;
                            if (split_scale_enable)
                                stream_p3_reject_count <= stream_p3_reject_count + accepted_lanes;
                        end else begin
                            lane_valid_r <= vpu_lane_valid;
                            for (i = 0; i < 8; i = i + 1) begin
                                raw_r[i] <= vpu_lane_data[32*i +: 32];
                                row_r[i] <= vpu_lane_row[16*i +: 16];
                                scale_word_index_r[i] <= split_scale_enable ?
                                    ((vpu_bank ? P3_BANK_WORD_DEPTH : 32'd0) +
                                     (vpu_lane_scale_index[32*i +: 32] >> 3)) :
                                    (vpu_lane_scale_index[32*i +: 32] >> 2);
                                scale_lane_r[i] <= split_scale_enable ?
                                    vpu_lane_scale_index[32*i + 2 -: 3] :
                                    {1'b0, vpu_lane_scale_index[32*i + 1 -: 2]};
                            end
                            block_r <= vpu_block; group_blocks_r <= vpu_group_blocks;
                            last_block_r <= vpu_last_block; clear_accum_r <= vpu_clear_accum;
                            job_id_r <= vpu_job_id; bank_r <= vpu_bank;
                            p3_r <= split_scale_enable; pair_idx_r <= 2'd0;
                            stream_count <= stream_count + accepted_lanes;
                            stream_fifo_high_water <= 32'd1;
                            stream_last_raw <= vpu_lane_data[32*tail_lane +: 32];
                            stream_last_meta <= {vpu_clear_accum,vpu_last_block,
                                                 vpu_block[13:0],vpu_lane_row[16*tail_lane +: 16]};
                            stream_last_job <= vpu_job_id;
                            stream_last_bank <= {31'd0,vpu_bank};
                            if (split_scale_enable && !p3_bank_lock_valid) begin
                                p3_bank_lock_valid <= 1'b1;
                                p3_bank_lock <= vpu_bank;
                            end
                            state_r <= S_READ;
                        end
                    end
                end

                S_READ: state_r <= S_CAPTURE;

                S_CAPTURE: begin
                    if (p3_r && (pair_idx_r == 2'd0))
                        p3_act_scale_r <= mem3_scratch_rdata[16*p3_act_lane +: 16];
                    if (lane_valid_r[lane0_sel]) begin
                        if (p3_r) begin
                            weight_scale_r[lane0_sel] <= mem0_rdata[16*lane0_scale_lane +: 16];
                            act_scale_r[lane0_sel] <= (pair_idx_r == 2'd0) ?
                                mem3_scratch_rdata[16*p3_act_lane +: 16] : p3_act_scale_r;
                        end else begin
                            act_scale_r[lane0_sel] <= mem0_rdata[32*lane0_scale_lane +: 16];
                            weight_scale_r[lane0_sel] <= mem0_rdata[32*lane0_scale_lane+16 +: 16];
                        end
                    end
                    if (lane_valid_r[lane1_sel]) begin
                        if (p3_r) begin
                            weight_scale_r[lane1_sel] <= mem1_rdata[16*lane1_scale_lane +: 16];
                            act_scale_r[lane1_sel] <= (pair_idx_r == 2'd0) ?
                                mem3_scratch_rdata[16*p3_act_lane +: 16] : p3_act_scale_r;
                        end else begin
                            act_scale_r[lane1_sel] <= mem1_rdata[32*lane1_scale_lane +: 16];
                            weight_scale_r[lane1_sel] <= mem1_rdata[32*lane1_scale_lane+16 +: 16];
                        end
                    end
                    if (pair_idx_r == 2'd3) begin
                        pair_idx_r <= 2'd0;
                        state_r <= S_START;
                    end else begin
                        pair_idx_r <= pair_idx_r + 2'd1;
                        state_r <= S_READ;
                    end
                end

                S_START: begin
                    if (all_accum_idle) begin
                        accum_start_r <= lane_valid_r;
                        state_r <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (all_accum_done) begin
                        stream_entry_done_count <= stream_entry_done_count + popcount8(lane_valid_r);
                        if (any_accum_error)
                            stream_error_count <= stream_error_count + popcount8(accum_error & lane_valid_r);
                        if (last_block_r) begin
                            for (i = 0; i < 8; i = i + 1)
                                if (lane_valid_r[i]) final_q16_r[i] <= accum_out_q16_bus[64*i +: 64];
                            pair_idx_r <= 2'd0;
                            state_r <= S_WRITE;
                        end else begin
                            state_r <= S_IDLE;
                        end
                    end
                end

                S_WRITE: begin
                    write_count = lane_valid_r[lane0_sel] + lane_valid_r[lane1_sel];
                    if (write_count != 0) begin
                        stream_out_count <= stream_out_count + write_count;
                        stream_final_write_count <= stream_final_write_count + write_count;
                        if (lane_valid_r[lane1_sel]) begin
                            stream_last_accum_lo <= final_q16_r[lane1_sel][31:0];
                            stream_last_accum_hi <= final_q16_r[lane1_sel][63:32];
                        end else if (lane_valid_r[lane0_sel]) begin
                            stream_last_accum_lo <= final_q16_r[lane0_sel][31:0];
                            stream_last_accum_hi <= final_q16_r[lane0_sel][63:32];
                        end
                    end
                    if (pair_idx_r == 2'd3) begin
                        pair_idx_r <= 2'd0;
                        state_r <= S_IDLE;
                    end else begin
                        pair_idx_r <= pair_idx_r + 2'd1;
                    end
                end

                default: state_r <= S_IDLE;
            endcase
        end
    end
endmodule
