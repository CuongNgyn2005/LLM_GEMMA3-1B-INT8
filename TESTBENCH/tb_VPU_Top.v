`timescale 1ns/1ps

module tb_VPU_Top;

    localparam integer ID_WIDTH      = 1;
    localparam integer DATA_WIDTH    = 128;
    localparam integer ADDR_WIDTH    = 40;
    localparam integer NUM_LANES     = 16;
    localparam integer MAX_ROWS      = 256;
    localparam integer MAX_COL_BEATS = 128;
    localparam integer MAX_GROUP_Q8_BLOCKS = 64;
    localparam integer MAX_TEST_COLS = NUM_LANES * MAX_COL_BEATS;

    localparam [ADDR_WIDTH-1:0] REG_CTRL      = 40'h0000_0000;
    localparam [ADDR_WIDTH-1:0] REG_STATUS    = 40'h0000_0010;
    localparam [ADDR_WIDTH-1:0] REG_ROWS      = 40'h0000_0020;
    localparam [ADDR_WIDTH-1:0] REG_COLS      = 40'h0000_0030;
    localparam [ADDR_WIDTH-1:0] REG_COL_BEATS = 40'h0000_0040;
    localparam [ADDR_WIDTH-1:0] REG_SCALE     = 40'h0000_0050;
    localparam [ADDR_WIDTH-1:0] REG_MODE      = 40'h0000_0060;
    localparam [ADDR_WIDTH-1:0] REG_LIMITS    = 40'h0000_0070;
    localparam [ADDR_WIDTH-1:0] REG_PROGRESS  = 40'h0000_0080;
    localparam [ADDR_WIDTH-1:0] REG_CAPS      = 40'h0000_0090;
    localparam [ADDR_WIDTH-1:0] REG_SPU_AUX1  = 40'h0000_00E4;
    localparam [ADDR_WIDTH-1:0] REG_SPU_CAPS  = 40'h0000_00F0;
    localparam [ADDR_WIDTH-1:0] REG_STREAM_PROTOCOL = 40'h0000_00F4;
    localparam [ADDR_WIDTH-1:0] REG_BITSTREAM_ID = 40'h0000_00F8;
    localparam [ADDR_WIDTH-1:0] REG_P2_STREAM_ABI = 40'h0000_00FC;
    localparam [ADDR_WIDTH-1:0] REG_P3_STREAM_MODE = 40'h0000_01FC;
    localparam [ADDR_WIDTH-1:0] REG_P3_STREAM_ABI = 40'h0000_0200;
    localparam [ADDR_WIDTH-1:0] REG_P3_STREAM_STATUS = 40'h0000_021C;
    localparam [ADDR_WIDTH-1:0] REG_BANK      = 40'h0000_0100;
    localparam [ADDR_WIDTH-1:0] REG_JOB_ID    = 40'h0000_0110;
    localparam [ADDR_WIDTH-1:0] REG_BANK_STAT = 40'h0000_0120;
    localparam [ADDR_WIDTH-1:0] REG_ACTIVE_JOB = 40'h0000_0130;
    localparam [ADDR_WIDTH-1:0] REG_DONE_JOB  = 40'h0000_0140;
    localparam [ADDR_WIDTH-1:0] REG_SLOT_STATE   = 40'h0000_0150;
    localparam [ADDR_WIDTH-1:0] REG_TENSOR_ID    = 40'h0000_0160;
    localparam [ADDR_WIDTH-1:0] REG_ROW0         = 40'h0000_0170;
    localparam [ADDR_WIDTH-1:0] REG_K_BLOCK0     = 40'h0000_0180;
    localparam [ADDR_WIDTH-1:0] REG_GROUP_BLOCKS = 40'h0000_0190;
    localparam [ADDR_WIDTH-1:0] REG_TOKEN_ID     = 40'h0000_01A0;
    localparam [ADDR_WIDTH-1:0] REG_DESC_FLAGS   = 40'h0000_01B0;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_COUNT    = 40'h0000_01C0;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_DONE     = 40'h0000_01C4;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_DROP     = 40'h0000_01D0;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_OUT      = 40'h0000_01D4;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_ERROR    = 40'h0000_01D8;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_LAST_RAW = 40'h0000_01E0;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_LAST_META = 40'h0000_01E4;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_LAST_JOB = 40'h0000_01E8;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_LAST_BANK = 40'h0000_01EC;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_ACCUM_LO = 40'h0000_01F0;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_ACCUM_HI = 40'h0000_01F4;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_STATUS = 40'h0000_01F8;
    localparam [ADDR_WIDTH-1:0] ACT_BASE      = 40'h0001_0000;
    localparam [ADDR_WIDTH-1:0] WEIGHT_BASE   = 40'h0010_0000;
    localparam [ADDR_WIDTH-1:0] RESULT_BASE   = 40'h0020_0000;
    localparam [ADDR_WIDTH-1:0] SPU_OUT_BASE   = 40'h0034_0000;
    localparam [ADDR_WIDTH-1:0] SPU_PARAM_BASE = 40'h0038_0000;
    localparam [ADDR_WIDTH-1:0] SPU_SCRATCH_BASE = 40'h003C_0000;
    localparam [31:0] VPU_MODE_PACKED_Q8      = 32'h0000_0001;
    localparam [31:0] VPU_MODE_RESULT_INT8    = 32'h0000_0002;
    localparam [31:0] VPU_MODE_ACCUM_CLEAR    = 32'h0000_0004;
    localparam [31:0] VPU_MODE_RESULT_EMIT    = 32'h0000_0008;
    localparam [31:0] VPU_MODE_P2_TWO_ROW     = 32'h0000_0010;
    localparam [15:0] SPU_TEST_ACT_SCALE      = 16'h3800; // 0.5
    localparam [15:0] SPU_TEST_WEIGHT_SCALE   = 16'h3400; // 0.25
    localparam signed [63:0] SPU_TEST_Q16_SCALE_PRODUCT = 64'sd8192;

    reg clk;
    reg resetn;

    reg  [ID_WIDTH-1:0]       awid;
    reg  [ADDR_WIDTH-1:0]     awaddr;
    reg  [7:0]                awlen;
    reg  [2:0]                awsize;
    reg  [1:0]                awburst;
    reg                       awlock;
    reg  [3:0]                awcache;
    reg  [2:0]                awprot;
    reg  [3:0]                awqos;
    reg  [3:0]                awregion;
    reg                       awuser;
    reg                       awvalid;
    wire                      awready;

    reg  [DATA_WIDTH-1:0]     wdata;
    reg  [(DATA_WIDTH/8)-1:0] wstrb;
    reg                       wlast;
    reg                       wuser;
    reg                       wvalid;
    wire                      wready;

    wire [ID_WIDTH-1:0]       bid;
    wire [1:0]                bresp;
    wire                      buser;
    wire                      bvalid;
    reg                       bready;

    reg  [ID_WIDTH-1:0]       arid;
    reg  [ADDR_WIDTH-1:0]     araddr;
    reg  [7:0]                arlen;
    reg  [2:0]                arsize;
    reg  [1:0]                arburst;
    reg                       arlock;
    reg  [3:0]                arcache;
    reg  [2:0]                arprot;
    reg  [3:0]                arqos;
    reg  [3:0]                arregion;
    reg                       aruser;
    reg                       arvalid;
    wire                      arready;

    wire [ID_WIDTH-1:0]       rid;
    wire [DATA_WIDTH-1:0]     rdata;
    wire [1:0]                rresp;
    wire                      rlast;
    wire                      ruser;
    wire                      rvalid;
    reg                       rready;

    reg signed [7:0] activation [0:MAX_TEST_COLS-1];
    reg signed [7:0] weight [0:MAX_ROWS*MAX_TEST_COLS-1];

    integer pass_count;
    integer fail_count;
    integer cycle_count;
    integer current_rows;
    integer current_cols;
    integer current_col_beats;
    integer stream_stall_observed;
    reg [DATA_WIDTH-1:0] init_rd_word;
    reg stream_hold_valid;
    reg signed [31:0] stream_hold_data;
    reg [15:0] stream_hold_row;
    reg [15:0] stream_hold_block;
    reg [15:0] stream_hold_group_blocks;
    reg stream_hold_last_block;
    reg stream_hold_clear_accum;
    reg [31:0] stream_hold_job_id;
    reg stream_hold_bank;
    reg preload_watch_enable;
    integer preload_compute_write_overlap;
    integer preload_busy_violation;
    integer pair_issue_desync_count;
    integer pair_inactive_weight_a_write_observed;
    reg pair_weight_port_watch_enable;

    VPU_Top #(
        .C_S00_AXI_ID_WIDTH     (ID_WIDTH),
        .C_S00_AXI_DATA_WIDTH   (DATA_WIDTH),
        .C_S00_AXI_ADDR_WIDTH   (ADDR_WIDTH),
        .C_S00_AXI_AWUSER_WIDTH (1),
        .C_S00_AXI_ARUSER_WIDTH (1),
        .C_S00_AXI_WUSER_WIDTH  (1),
        .C_S00_AXI_RUSER_WIDTH  (1),
        .C_S00_AXI_BUSER_WIDTH  (1),
        .MAX_ROWS               (MAX_ROWS),
        .MAX_COL_BEATS          (MAX_COL_BEATS),
        .MAX_GROUP_Q8_BLOCKS    (MAX_GROUP_Q8_BLOCKS),
        .SPU_STREAM_TEST_STALL_ENABLE (1)
    ) dut (
        .s00_axi_aclk       (clk),
        .s00_axi_aresetn    (resetn),
        .s00_axi_awid       (awid),
        .s00_axi_awaddr     (awaddr),
        .s00_axi_awlen      (awlen),
        .s00_axi_awsize     (awsize),
        .s00_axi_awburst    (awburst),
        .s00_axi_awlock     (awlock),
        .s00_axi_awcache    (awcache),
        .s00_axi_awprot     (awprot),
        .s00_axi_awqos      (awqos),
        .s00_axi_awregion   (awregion),
        .s00_axi_awuser     (awuser),
        .s00_axi_awvalid    (awvalid),
        .s00_axi_awready    (awready),
        .s00_axi_wdata      (wdata),
        .s00_axi_wstrb      (wstrb),
        .s00_axi_wlast      (wlast),
        .s00_axi_wuser      (wuser),
        .s00_axi_wvalid     (wvalid),
        .s00_axi_wready     (wready),
        .s00_axi_bid        (bid),
        .s00_axi_bresp      (bresp),
        .s00_axi_buser      (buser),
        .s00_axi_bvalid     (bvalid),
        .s00_axi_bready     (bready),
        .s00_axi_arid       (arid),
        .s00_axi_araddr     (araddr),
        .s00_axi_arlen      (arlen),
        .s00_axi_arsize     (arsize),
        .s00_axi_arburst    (arburst),
        .s00_axi_arlock     (arlock),
        .s00_axi_arcache    (arcache),
        .s00_axi_arprot     (arprot),
        .s00_axi_arqos      (arqos),
        .s00_axi_arregion   (arregion),
        .s00_axi_aruser     (aruser),
        .s00_axi_arvalid    (arvalid),
        .s00_axi_arready    (arready),
        .s00_axi_rid        (rid),
        .s00_axi_rdata      (rdata),
        .s00_axi_rresp      (rresp),
        .s00_axi_rlast      (rlast),
        .s00_axi_ruser      (ruser),
        .s00_axi_rvalid     (rvalid),
        .s00_axi_rready     (rready)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!resetn)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // The paired topology has a distinct physical-port contract: a write to
    // the inactive top bank must use B while the active top bank consumes A/B
    // for companion/primary reads.  The staged address below is in shard 0,
    // so one representative lane leaf proves the route without relying on
    // elapsed-time inference.
    always @(posedge clk) begin
        if (!resetn) begin
            pair_inactive_weight_a_write_observed <= 0;
        end else if (pair_weight_port_watch_enable &&
                     dut.u_my_ip.u_axi4_mapping.u_gemv.pair_mode_r &&
                     dut.u_my_ip.u_axi4_mapping.core_busy &&
                     dut.u_my_ip.u_axi4_mapping.u_gemv.GEN_WEIGHT_TOP_BANK[1].GEN_WEIGHT_BANK[0].GEN_WEIGHT_PARITY[0].u_weight_bram_bank.ena &&
                     (|dut.u_my_ip.u_axi4_mapping.u_gemv.GEN_WEIGHT_TOP_BANK[1].GEN_WEIGHT_BANK[0].GEN_WEIGHT_PARITY[0].u_weight_bram_bank.wea)) begin
            pair_inactive_weight_a_write_observed <=
                pair_inactive_weight_a_write_observed + 1;
        end
    end

    // Atomic-pair invariant: a readiness skew may delay both PMAUs, but it
    // must never let exactly one lane consume a shared activation beat.
    always @(posedge clk) begin
        if (!resetn) begin
            pair_issue_desync_count <= 0;
        end else if (dut.u_my_ip.u_axi4_mapping.u_gemv.pair_lane1_valid &&
                     (dut.u_my_ip.u_axi4_mapping.u_gemv.u_pmau.input_fire !==
                      dut.u_my_ip.u_axi4_mapping.u_gemv.u_pmau_pair.input_fire)) begin
            pair_issue_desync_count <= pair_issue_desync_count + 1;
            fail("P2-v2 PMAU pair issue was not atomic");
        end
    end

    // A live preload is meaningful only if GEMV is still issuing reads while
    // the opposite bank accepts ACT/WEIGHT writes.  Watch the canonical
    // internal interfaces rather than inferring overlap from elapsed time.
    always @(posedge clk) begin
        if (!resetn) begin
            preload_compute_write_overlap <= 0;
            preload_busy_violation <= 0;
        end else if (preload_watch_enable) begin
            if (!dut.u_my_ip.u_axi4_mapping.core_busy)
                preload_busy_violation <= 1;
            if (dut.u_my_ip.u_axi4_mapping.u_gemv.compute_rd_en &&
                dut.u_my_ip.u_axi4_mapping.wr_decode_en &&
                ((dut.u_my_ip.u_axi4_mapping.wr_decode_addr >= ACT_BASE &&
                  dut.u_my_ip.u_axi4_mapping.wr_decode_addr < ACT_BASE + 40'd2048) ||
                 (dut.u_my_ip.u_axi4_mapping.wr_decode_addr >= WEIGHT_BASE &&
                  dut.u_my_ip.u_axi4_mapping.wr_decode_addr < WEIGHT_BASE + 40'd16384)) &&
                (dut.u_my_ip.u_axi4_mapping.cfg_bank_reg[0] !=
                 dut.u_my_ip.u_axi4_mapping.core_active_bank))
                preload_compute_write_overlap <= preload_compute_write_overlap + 1;
        end
    end

    function [DATA_WIDTH-1:0] word32;
        input [31:0] value;
        begin
            word32 = {DATA_WIDTH{1'b0}};
            word32[31:0] = value;
        end
    endfunction

    function [DATA_WIDTH-1:0] word32_at_addr;
        input [ADDR_WIDTH-1:0] addr;
        input [31:0] value;
        begin
            word32_at_addr = {DATA_WIDTH{1'b0}};
            word32_at_addr[32*addr[3:2] +: 32] = value;
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_activation;
        input integer beat;
        integer lane;
        integer idx;
        begin
            pack_activation = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                idx = beat * NUM_LANES + lane;
                if (idx < current_cols)
                    pack_activation[8*lane +: 8] = activation[idx];
            end
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_activation_from;
        input integer beat_base;
        input integer beat;
        integer lane;
        integer idx;
        begin
            pack_activation_from = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                idx = (beat_base + beat) * NUM_LANES + lane;
                if (idx < current_cols)
                    pack_activation_from[8*lane +: 8] = activation[idx];
            end
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_weight;
        input integer row;
        input integer beat;
        integer lane;
        integer idx;
        begin
            pack_weight = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                idx = beat * NUM_LANES + lane;
                if (idx < current_cols)
                    pack_weight[8*lane +: 8] = weight[row*MAX_TEST_COLS + idx];
            end
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_weight_from;
        input integer row;
        input integer beat_base;
        input integer beat;
        integer lane;
        integer idx;
        begin
            pack_weight_from = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                idx = (beat_base + beat) * NUM_LANES + lane;
                if (idx < current_cols)
                    pack_weight_from[8*lane +: 8] = weight[row*MAX_TEST_COLS + idx];
            end
        end
    endfunction

    // Protocol 2 weight words are pair-interleaved: for a row pair and beat,
    // write even then odd.  The odd word is still present as zero padding for
    // an odd row count, making physical address = flat_index >> 1 exact.
    function integer pair_weight_word_index;
        input integer row;
        input integer col_beats;
        input integer beat;
        begin
            pair_weight_word_index = (((row >> 1) * col_beats + beat) << 1) +
                                     (row & 1);
        end
    endfunction

    task stage_pair_weight_image;
        input integer rows;
        input integer col_beats;
        integer pair_row;
        integer beat;
        integer row;
        begin
            for (pair_row = 0; pair_row < ((rows + 1) >> 1); pair_row = pair_row + 1) begin
                row = pair_row << 1;
                for (beat = 0; beat < col_beats; beat = beat + 1) begin
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row, col_beats, beat) * 16,
                              pack_weight(row, beat), 16'hffff);
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row + 1, col_beats, beat) * 16,
                              ((row + 1) < rows) ? pack_weight(row + 1, beat) :
                                                   {DATA_WIDTH{1'b0}}, 16'hffff);
                end
            end
        end
    endtask

    task stage_pair_weight_image_from;
        input integer rows;
        input integer col_beats;
        input integer source_beat;
        integer pair_row;
        integer beat;
        integer row;
        begin
            for (pair_row = 0; pair_row < ((rows + 1) >> 1); pair_row = pair_row + 1) begin
                row = pair_row << 1;
                for (beat = 0; beat < col_beats; beat = beat + 1) begin
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row, col_beats, beat) * 16,
                              pack_weight_from(row, source_beat, beat), 16'hffff);
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row + 1, col_beats, beat) * 16,
                              ((row + 1) < rows) ? pack_weight_from(row + 1, source_beat, beat) :
                                                   {DATA_WIDTH{1'b0}}, 16'hffff);
                end
            end
        end
    endtask

    function signed [31:0] golden_row;
        input integer row;
        integer idx;
        reg signed [31:0] acc;
        begin
            acc = 32'sd0;
            for (idx = 0; idx < current_cols; idx = idx + 1)
                acc = acc + activation[idx] * weight[row*MAX_TEST_COLS + idx];
            golden_row = acc;
        end
    endfunction

    function signed [31:0] golden_q8_block;
        input integer row;
        input integer block_id;
        integer lane;
        integer idx;
        reg signed [31:0] acc;
        begin
            acc = 32'sd0;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                idx = block_id * 32 + lane;
                acc = acc + activation[idx] * weight[row*MAX_TEST_COLS + idx];
            end
            golden_q8_block = acc;
        end
    endfunction

    function signed [31:0] golden_q8_range;
        input integer row;
        input integer block0;
        input integer blocks;
        integer lane;
        integer idx;
        reg signed [31:0] acc;
        begin
            acc = 32'sd0;
            for (lane = 0; lane < blocks * 32; lane = lane + 1) begin
                idx = block0 * 32 + lane;
                acc = acc + activation[idx] * weight[row*MAX_TEST_COLS + idx];
            end
            golden_q8_range = acc;
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_stream_scale_word;
        input integer rows;
        input integer group_blocks;
        input integer word_idx;
        integer lane;
        integer linear;
        begin
            pack_stream_scale_word = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < 4; lane = lane + 1) begin
                linear = word_idx * 4 + lane;
                if (linear < rows * group_blocks)
                    pack_stream_scale_word[32*lane +: 32] =
                        {SPU_TEST_WEIGHT_SCALE, SPU_TEST_ACT_SCALE};
            end
        end
    endfunction

    function signed [7:0] requant_i8;
        input signed [31:0] value;
        input integer shift;
        reg signed [31:0] shifted;
        begin
            shifted = value >>> shift;
            if (shifted > 127)
                requant_i8 = 8'sd127;
            else if (shifted < -128)
                requant_i8 = -8'sd128;
            else
                requant_i8 = shifted[7:0];
        end
    endfunction

    task fail;
        input [255:0] message;
        begin
            fail_count = fail_count + 1;
            $display("[TB][FAIL] %0s", message);
        end
    endtask

    task axi_write;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        input [(DATA_WIDTH/8)-1:0] strb;
        integer timeout;
        begin
            @(posedge clk);
            awid     <= {ID_WIDTH{1'b0}};
            awaddr   <= addr;
            awlen    <= 8'd0;
            awsize   <= 3'd4;
            awburst  <= 2'b01;
            awlock   <= 1'b0;
            awcache  <= 4'd0;
            awprot   <= 3'd0;
            awqos    <= 4'd0;
            awregion <= 4'd0;
            awuser   <= 1'b0;
            awvalid  <= 1'b1;
            wvalid   <= 1'b0;
            bready   <= 1'b1;

            timeout = 0;
            while (!awready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI write address timeout");
                    timeout = 0;
                end
            end
            @(posedge clk);
            awvalid <= 1'b0;

            @(posedge clk);
            wdata    <= data;
            wstrb    <= strb;
            wlast    <= 1'b1;
            wuser    <= 1'b0;
            wvalid   <= 1'b1;

            timeout = 0;
            while (!wready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI write data timeout");
                    timeout = 0;
                end
            end
            @(posedge clk);
            wvalid <= 1'b0;

            timeout = 0;
            while (!bvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI write response timeout");
                    timeout = 0;
                end
            end

            if (bresp != 2'b00)
                fail("AXI write response was not OKAY");

            @(posedge clk);
            while (bvalid)
                @(posedge clk);
            bready <= 1'b1;
            wlast  <= 1'b0;
            wstrb  <= {(DATA_WIDTH/8){1'b0}};
            wdata  <= {DATA_WIDTH{1'b0}};
        end
    endtask

    // Production DMA writes use 128-bit INCR bursts.  Keep this separate from
    // axi_write() so the existing single-beat/narrow-MMIO coverage remains
    // intact.  The payload is the same deterministic activation pattern used
    // by the GEMV golden model.
    task axi_write_act_incr_burst;
        input [ADDR_WIDTH-1:0] addr;
        input integer beats;
        input integer bready_hold_cycles;
        integer beat;
        integer timeout;
        integer w_handshakes;
        integer b_handshakes;
        reg [ID_WIDTH-1:0] expected_bid;
        begin
            if ((beats <= 0) || (beats > 128)) begin
                fail("AXI ACT burst has an invalid beat count");
            end else begin
                $display("[TB] AXI ACT INCR BURST: addr=%h beats=%0d", addr, beats);
                expected_bid = 4'h5;
                w_handshakes = 0;
                b_handshakes = 0;

                @(posedge clk);
                awid     <= expected_bid;
                awaddr   <= addr;
                awlen    <= beats - 1;
                awsize   <= 3'd4;
                awburst  <= 2'b01;
                awlock   <= 1'b0;
                awcache  <= 4'd0;
                awprot   <= 3'd0;
                awqos    <= 4'd0;
                awregion <= 4'd0;
                awuser   <= 1'b0;
                awvalid  <= 1'b1;
                wvalid   <= 1'b0;
                bready   <= 1'b0;

                timeout = 0;
                while (!awready) begin
                    @(posedge clk);
                    timeout = timeout + 1;
                    if (timeout > 100) begin
                        fail("AXI ACT burst address timeout");
                        awvalid <= 1'b0;
                        timeout = 0;
                    end
                end
                @(posedge clk);
                awvalid <= 1'b0;

                for (beat = 0; beat < beats; beat = beat + 1) begin
                    @(posedge clk);
                    wdata  <= pack_activation(beat);
                    wstrb  <= {DATA_WIDTH/8{1'b1}};
                    wlast  <= (beat == (beats - 1));
                    wuser  <= 1'b0;
                    wvalid <= 1'b1;

                    timeout = 0;
                    while (!wready) begin
                        @(posedge clk);
                        timeout = timeout + 1;
                        if (timeout > 100) begin
                            fail("AXI ACT burst write-data timeout");
                            wvalid <= 1'b0;
                            timeout = 0;
                        end
                    end
                    // WVALID has been stable for a full cycle here, so this
                    // edge is the single accepted W handshake for this beat.
                    @(posedge clk);
                    if (wlast !== (beat == (beats - 1)))
                        fail("AXI ACT burst WLAST did not match final beat");
                    w_handshakes = w_handshakes + 1;
                    wvalid <= 1'b0;
                end

                if (w_handshakes != beats)
                    fail("AXI ACT burst W handshake count mismatch");

                timeout = 0;
                while (!bvalid) begin
                    @(posedge clk);
                    timeout = timeout + 1;
                    if (timeout > 100) begin
                        fail("AXI ACT burst response timeout");
                        timeout = 0;
                    end
                end
                if ((bresp !== 2'b00) || (bid !== expected_bid))
                    fail("AXI ACT burst response was not the expected OKAY BID");

                // BVALID must remain asserted and its metadata stable until
                // the delayed master response handshake.
                repeat (bready_hold_cycles) begin
                    @(posedge clk);
                    if (!bvalid || (bresp !== 2'b00) || (bid !== expected_bid))
                        fail("AXI ACT burst BVALID/B metadata did not hold under backpressure");
                end
                @(negedge clk);
                bready <= 1'b1;
                @(posedge clk);
                if (bvalid)
                    b_handshakes = b_handshakes + 1;
                // MY_IP retires BVALID with a nonblocking update at this
                // handshake edge; sample after the update has settled.
                @(negedge clk);
                if (bvalid)
                    fail("AXI ACT burst BVALID did not retire after one B handshake");
                if (b_handshakes != 1)
                    fail("AXI ACT burst did not receive exactly one B response");

                bready <= 1'b1;
                wlast  <= 1'b0;
                wstrb  <= {(DATA_WIDTH/8){1'b0}};
                wdata  <= {DATA_WIDTH{1'b0}};
            end
        end
    endtask

    task axi_write32;
        input [ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        input [3:0] strb;
        integer timeout;
        reg [DATA_WIDTH-1:0] lane_data;
        reg [(DATA_WIDTH/8)-1:0] lane_strb;
        begin
            lane_data = word32_at_addr(addr, data);
            lane_strb = {(DATA_WIDTH/8){1'b0}};
            lane_strb[4*addr[3:2] +: 4] = strb;

            @(posedge clk);
            awid     <= {ID_WIDTH{1'b0}};
            awaddr   <= addr;
            awlen    <= 8'd0;
            awsize   <= 3'd2;
            awburst  <= 2'b01;
            awlock   <= 1'b0;
            awcache  <= 4'd0;
            awprot   <= 3'd0;
            awqos    <= 4'd0;
            awregion <= 4'd0;
            awuser   <= 1'b0;
            awvalid  <= 1'b1;
            wvalid   <= 1'b0;
            bready   <= 1'b1;

            timeout = 0;
            while (!awready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI narrow write address timeout");
                    timeout = 0;
                end
            end
            @(posedge clk);
            awvalid <= 1'b0;

            @(posedge clk);
            wdata    <= lane_data;
            wstrb    <= lane_strb;
            wlast    <= 1'b1;
            wuser    <= 1'b0;
            wvalid   <= 1'b1;

            timeout = 0;
            while (!wready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI narrow write data timeout");
                    timeout = 0;
                end
            end
            @(posedge clk);
            wvalid <= 1'b0;

            timeout = 0;
            while (!bvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI narrow write response timeout");
                    timeout = 0;
                end
            end

            if (bresp != 2'b00)
                fail("AXI narrow write response was not OKAY");

            @(posedge clk);
            while (bvalid)
                @(posedge clk);
            bready <= 1'b1;
            wlast  <= 1'b0;
            wstrb  <= {(DATA_WIDTH/8){1'b0}};
            wdata  <= {DATA_WIDTH{1'b0}};
        end
    endtask

    task axi_read;
        input  [ADDR_WIDTH-1:0] addr;
        output [DATA_WIDTH-1:0] data;
        integer timeout;
        begin
            @(posedge clk);
            arid     <= {ID_WIDTH{1'b0}};
            araddr   <= addr;
            arlen    <= 8'd0;
            arsize   <= 3'd4;
            arburst  <= 2'b01;
            arlock   <= 1'b0;
            arcache  <= 4'd0;
            arprot   <= 3'd0;
            arqos    <= 4'd0;
            arregion <= 4'd0;
            aruser   <= 1'b0;
            arvalid  <= 1'b1;
            rready   <= 1'b1;

            timeout = 0;
            while (arvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI read address timeout");
                    $display("[TB][DBG] arready=%b read_active=%b rd_pending=%b rvalid=%b bvalid=%b wr_active=%b map_rd_valid=%b",
                             arready,
                             dut.u_my_ip.read_active_r,
                             dut.u_my_ip.rd_pending_r,
                             dut.u_my_ip.rvalid_r,
                             dut.u_my_ip.bvalid_r,
                             dut.u_my_ip.wr_active_r,
                             dut.u_my_ip.map_rd_valid);
                    arvalid <= 1'b0;
                end
                if (arvalid && arready)
                    arvalid <= 1'b0;
            end

            timeout = 0;
            while (!rvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) begin
                    fail("AXI read data timeout");
                    $display("[TB][DBG] read_active=%b rd_pending=%b rvalid=%b map_rd_en=%b map_rd_valid=%b map_rd_error=%b",
                             dut.u_my_ip.read_active_r,
                             dut.u_my_ip.rd_pending_r,
                             dut.u_my_ip.rvalid_r,
                             dut.u_my_ip.map_rd_en_r,
                             dut.u_my_ip.map_rd_valid,
                             dut.u_my_ip.map_rd_error);
                    timeout = 0;
                end
            end

            data = rdata;
            if (rresp != 2'b00)
                fail("AXI read response was not OKAY");
            if (!rlast)
                fail("Single-beat AXI read did not assert RLAST");

            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task axi_read32;
        input [ADDR_WIDTH-1:0] addr;
        output [31:0] data;
        integer timeout;
        integer lane;
        begin
            @(posedge clk);
            arid     <= {ID_WIDTH{1'b0}};
            araddr   <= addr;
            arlen    <= 8'd0;
            arsize   <= 3'd2;
            arburst  <= 2'b01;
            arlock   <= 1'b0;
            arcache  <= 4'd0;
            arprot   <= 3'd0;
            arqos    <= 4'd0;
            arregion <= 4'd0;
            aruser   <= 1'b0;
            arvalid  <= 1'b1;
            rready   <= 1'b1;

            timeout = 0;
            while (arvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI narrow read address timeout");
                    arvalid <= 1'b0;
                end
                if (arvalid && arready)
                    arvalid <= 1'b0;
            end

            timeout = 0;
            while (!rvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) begin
                    fail("AXI narrow read data timeout");
                    timeout = 0;
                end
            end

            data = rdata[32*addr[3:2] +: 32];
            if (rresp != 2'b00)
                fail("AXI narrow read response was not OKAY");
            if (!rlast)
                fail("Single-beat AXI narrow read did not assert RLAST");
            for (lane = 0; lane < DATA_WIDTH / 32; lane = lane + 1) begin
                if ((lane != addr[3:2]) && (rdata[32*lane +: 32] !== 32'd0))
                    fail("AXI narrow read returned data in an unselected lane");
            end

            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    // Exercise the host-visible P2 drain shape: one full 4 KiB SPU_OUT
    // transfer.  Each 128-bit beat is a distinct row record
    // {q16_16_accum[79:16], row_id[15:0]}.  Deliberate RREADY stalls make
    // data, response, and RLAST stability observable before every transfer
    // phase that is held off by the consumer.
    task axi_read_spu_out_full_burst;
        integer beat;
        integer timeout;
        integer start_cycle;
        integer rlast_count;
        reg [DATA_WIDTH-1:0] held_data;
        reg [1:0] held_resp;
        reg held_last;
        reg [15:0] expected_row;
        reg signed [63:0] expected_accum;
        begin
            $display("[TB] SPU_OUT FULL BURST: 256 x 16-byte INCR beats");
            start_cycle = cycle_count;
            rlast_count = 0;

            @(negedge clk);
            arid     <= {ID_WIDTH{1'b0}};
            araddr   <= SPU_OUT_BASE;
            arlen    <= 8'd255;
            arsize   <= 3'd4;
            arburst  <= 2'b01;
            arlock   <= 1'b0;
            arcache  <= 4'd0;
            arprot   <= 3'd0;
            arqos    <= 4'd0;
            arregion <= 4'd0;
            aruser   <= 1'b0;
            arvalid  <= 1'b1;
            // The serialized MY_IP read path requires the first R channel
            // transfer to be enabled after AR acceptance.  Later beats below
            // deliberately withdraw RREADY only after RVALID is observable.
            rready   <= 1'b1;

            timeout = 0;
            while (arvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("SPU_OUT full burst AR handshake timeout");
                    arvalid <= 1'b0;
                end
                if (arvalid && arready)
                    arvalid <= 1'b0;
            end
            // Prevent a just-produced R beat from being consumed before the
            // falling-edge monitor has sampled its metadata.
            rready = 1'b0;

            for (beat = 0; beat < 256; beat = beat + 1) begin
                timeout = 0;
                while (!rvalid) begin
                    @(negedge clk);
                    timeout = timeout + 1;
                    if (timeout > 200) begin
                        fail("SPU_OUT full burst RDATA timeout");
                        timeout = 0;
                    end
                end

                expected_accum =
                    $signed(golden_q8_range(beat, 0, 1)) * SPU_TEST_Q16_SCALE_PRODUCT;
                expected_row = beat;
                if (rresp !== 2'b00)
                    fail("SPU_OUT full burst returned non-OKAY RRESP");
                if (rlast !== (beat == 255))
                    fail("SPU_OUT full burst RLAST was not final-beat-only");
                if (rlast)
                    rlast_count = rlast_count + 1;
                if (rdata[15:0] !== expected_row)
                    fail("SPU_OUT full burst row payload was out of order");
                if (rdata[79:16] !== expected_accum)
                    fail("SPU_OUT full burst Q16 payload mismatch");

                // Stall a rotating subset, including the final beat.  These
                // choices exercise early and RLAST-adjacent backpressure
                // without relying on simulator randomness.
                if (((beat % 29) == 7) || (beat == 255)) begin
                    held_data = rdata;
                    held_resp = rresp;
                    held_last = rlast;
                    // RVALID is sampled at the falling edge, then RREADY is
                    // held low across two following rising edges.  The #1
                    // sample is after DUT nonblocking updates.
                    rready = 1'b0;
                    repeat (2) begin
                        @(posedge clk);
                        #1;
                        if (!rvalid || rdata !== held_data || rresp !== held_resp ||
                            rlast !== held_last) begin
                            $display("[TB][DBG] SPU_OUT stall beat=%0d rvalid=%b rdata=%h rresp=%b rlast=%b held_data=%h held_resp=%b held_last=%b",
                                     beat, rvalid, rdata, rresp, rlast,
                                     held_data, held_resp, held_last);
                            fail("SPU_OUT full burst R-channel changed under backpressure");
                        end
                    end
                    @(negedge clk);
                end

                rready = 1'b1;
                @(posedge clk);
                #1;
                rready = 1'b0;
            end

            @(negedge clk);
            rready = 1'b0;
            @(posedge clk);
            #1;
            if (rvalid)
                fail("SPU_OUT full burst did not retire after beat 255");
            if (rlast_count != 1)
                fail("SPU_OUT full burst did not produce exactly one RLAST");
            else
                pass_count = pass_count + 1;
            if ((cycle_count - start_cycle) > 10000)
                fail("SPU_OUT full burst exceeded bounded completion latency");
            else
                pass_count = pass_count + 1;
        end
    endtask

    task init_case_data;
        input integer case_id;
        input integer rows;
        input integer cols;
        integer i;
        integer r;
        integer value;
        begin
            current_rows      = rows;
            current_cols      = cols;
            current_col_beats = (cols + NUM_LANES - 1) / NUM_LANES;

            for (i = 0; i < MAX_TEST_COLS; i = i + 1) begin
                value = ((i * 3 + case_id * 5) % 31) - 15;
                activation[i] = value;
            end

            for (r = 0; r < MAX_ROWS; r = r + 1) begin
                for (i = 0; i < MAX_TEST_COLS; i = i + 1) begin
                    value = ((r * 7 + i * 2 + case_id * 3) % 23) - 11;
                    weight[r*MAX_TEST_COLS + i] = value;
                end
            end
        end
    endtask

    task run_mmio_lane_case;
        reg [31:0] rd32;
        begin
            $display("[TB] MMIO NARROW CASE: lane-steered register reads and writes");

            axi_read32(REG_SPU_CAPS, rd32);
            if (rd32 !== 32'h1000_0fc3)
                fail("SPU capability register narrow read mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_STREAM_PROTOCOL, rd32);
            if (rd32 !== 32'h0000_0002)
                fail("Stream protocol narrow read mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_BITSTREAM_ID, rd32);
            if (rd32 !== 32'h5650_5532)
                fail("Bitstream identity narrow read mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_P2_STREAM_ABI, rd32);
            if (rd32 !== 32'h5032_0003)
                fail("P2 stream ABI narrow read mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_P3_STREAM_ABI, rd32);
            if (rd32 !== 32'h5033_0001)
                fail("P3 split-scale ABI narrow read mismatch");
            else
                pass_count = pass_count + 1;

            // P3 mode is reset-off so the P2 packed-scale ABI remains the
            // deployed default until a separately versioned host opts in.
            axi_read32(REG_P3_STREAM_MODE, rd32);
            if (rd32 !== 32'd0)
                fail("P3 split-scale mode was not reset-off");
            else
                pass_count = pass_count + 1;

            axi_write32(REG_SPU_AUX1, 32'ha5a5_5a5a, 4'b1111);
            axi_read32(REG_SPU_AUX1, rd32);
            if (rd32 !== 32'ha5a5_5a5a)
                fail("Lane-1 AUX1 full-strobe write/read mismatch");
            else
                pass_count = pass_count + 1;

            axi_write32(REG_SPU_AUX1, 32'h1122_3344, 4'b0101);
            axi_read32(REG_SPU_AUX1, rd32);
            if (rd32 !== 32'ha522_5a44)
                fail("Lane-1 AUX1 partial-strobe write/read mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_COUNT, rd32);
            if (rd32 == 32'd0)
                fail("SPU stream count was not meaningful before narrow counter read");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_DONE, rd32);
            if (rd32 == 32'd0)
                fail("SPU stream done count narrow read was zero after completed stream");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_OUT, rd32);
            if (rd32 == 32'd0)
                fail("SPU stream output count narrow read was zero after completed stream");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_ERROR, rd32);
            if (rd32 !== 32'd0)
                fail("SPU stream error counter was nonzero during narrow MMIO test");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_STATUS, rd32);
            if (rd32[4:0] !== 5'b1_1111)
                fail("SPU stream did not report quiescent after completed stream");
            else
                pass_count = pass_count + 1;
        end
    endtask

    // Models the host's P2 admission boundary: a raw VPU self-test has
    // already emitted VPU->SPU traffic, then the first scale-stream P2 job is
    // allowed without a fabric reset only after the raw tail is final and the
    // SPU explicitly reports no FIFO/accumulator/output-write ownership.
    task verify_selftest_stream_handoff_ready;
        reg [31:0] count;
        reg [31:0] done;
        reg [31:0] out;
        reg [31:0] drop;
        reg [31:0] error;
        reg [31:0] status;
        integer timeout;
        begin
            $display("[TB] SELFTEST->P2 HANDOFF: verify raw stream finality without reset");
            timeout = 0;
            status = 32'd0;
            while (status[4] !== 1'b1) begin
                axi_read32(REG_SPU_STREAM_STATUS, status);
                timeout = timeout + 1;
                if (timeout > 100000) begin
                    fail("raw self-test stream did not become quiescent before P2 handoff");
                    status[4] = 1'b1;
                end
            end
            axi_read32(REG_SPU_STREAM_COUNT, count);
            axi_read32(REG_SPU_STREAM_DONE, done);
            axi_read32(REG_SPU_STREAM_OUT, out);
            axi_read32(REG_SPU_STREAM_DROP, drop);
            axi_read32(REG_SPU_STREAM_ERROR, error);
            axi_read32(REG_SPU_STREAM_STATUS, status);
            if (count == 0 || done == 0 || out == 0)
                fail("raw self-test did not publish count/done/out before P2 handoff");
            else
                pass_count = pass_count + 1;
            if (drop != 0 || error != 0)
                fail("raw self-test stream faulted before P2 handoff");
            else
                pass_count = pass_count + 1;
            if (status[4:0] !== 5'b1_1111)
                fail("raw self-test stream was not quiescent before P2 handoff");
            else
                pass_count = pass_count + 1;
        end
    endtask

    // The host observes this register immediately after fpga_init() and after
    // a PL reset.  Verify that reset does not leave an apparent FIFO/scale
    // owner that would make the first P2 tile unsafe to admit.
    task verify_reset_stream_quiescence;
        reg [31:0] status;
        begin
            $display("[TB] RESET QUIESCENCE: stream ownership is idle after reset");
            axi_read32(REG_SPU_STREAM_STATUS, status);
            if (status[4:0] !== 5'b1_1111)
                fail("SPU stream status was not quiescent immediately after reset");
            else
                pass_count = pass_count + 1;
        end
    endtask

    task run_case;
        input integer case_id;
        input integer rows;
        input integer cols;
        input integer explicit_col_beats;
        integer beat;
        integer row;
        integer timeout;
        integer start_cycle;
        integer done_cycle;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        begin
            init_case_data(case_id, rows, cols);

            $display("[TB] CASE %0d: rows=%0d cols=%0d load_beats=%0d cfg_col_beats=%0d",
                     case_id, rows, cols, current_col_beats, explicit_col_beats);

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(case_id), 16'h000f);
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(cols), 16'h000f);
            axi_write(REG_COL_BEATS, word32(explicit_col_beats), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(32'h0000_0000), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);

            stage_pair_weight_image(rows, current_col_beats);

            start_cycle = cycle_count;
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);

            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("Core reported configuration error");
                    timeout = 1000;
                    rd_word[0] = 1'b1;
                end
                if (timeout > 1000) begin
                    fail("Core did not finish");
                    rd_word[0] = 1'b1;
                end
            end
            done_cycle = cycle_count;

            for (row = 0; row < rows; row = row + 1) begin
                axi_read(RESULT_BASE + row * 16, rd_word);
                got = rd_word[31:0];
                expected = golden_row(row);
                if (got !== expected) begin
                    $display("[TB][FAIL] row=%0d got=%0d expected=%0d", row, got, expected);
                    fail_count = fail_count + 1;
                end else begin
                    $display("[TB][PASS] row=%0d result=%0d", row, got);
                    pass_count = pass_count + 1;
                end
            end

            $display("[TB] CASE %0d compute+poll cycles=%0d", case_id, done_cycle - start_cycle);
        end
    endtask

    task run_group_case;
        input integer case_id;
        input integer rows;
        input integer group_blocks;
        integer beat;
        integer row;
        integer block_id;
        integer linear;
        integer word_idx;
        integer lane_idx;
        integer scale_word_idx;
        integer timeout;
        integer start_cycle;
        integer done_cycle;
        reg [DATA_WIDTH-1:0] rd_word;
        reg [31:0] rd32;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        reg [31:0] stream_count_before;
        reg [31:0] stream_done_before;
        reg [31:0] stream_drop_before;
        reg [31:0] stream_out_before;
        reg [31:0] stream_error_before;
        reg [31:0] stream_count_after;
        reg [31:0] stream_done_after;
        reg [31:0] stream_drop_after;
        reg [31:0] stream_out_after;
        reg [31:0] stream_error_after;
        reg signed [63:0] expected_accum;
        begin
            init_case_data(case_id, rows, group_blocks * 32);

            $display("[TB] GROUP CASE %0d: rows=%0d q8_blocks=%0d load_beats=%0d",
                     case_id, rows, group_blocks, current_col_beats);

            axi_read(REG_CAPS, rd_word);
            if (rd_word[0] !== 1'b1)
                fail("Packed q8 capability bit was not set");
            if (rd_word[1] !== 1'b1)
                fail("Compact weight layout capability bit was not set");
            if (rd_word[2] !== 1'b0)
                fail("Q8_0 output-block capability bit must stay clear until scale metadata is integrated");
            if (rd_word[3] !== 1'b1)
                fail("Ping-pong bank capability bit was not set");
            if (rd_word[4] !== 1'b1)
                fail("Descriptor ownership capability bit was not set");
            if (rd_word[5] !== 1'b1)
                fail("VPU-to-SPU raw stream capability bit was not set");
            if (rd_word[6] !== 1'b1)
                fail("SPU Q8 scale stream capability bit was not set");
            if (rd_word[7] !== 1'b1)
                fail("P2-v2 two-row capability bit was not set");
            if (rd_word[15:8] !== 8'd64)
                fail("REG_CAPS max_group_q8_blocks was not 64");
            axi_read32(REG_STREAM_PROTOCOL, rd32);
            if (rd32 !== 32'h0000_0002)
                fail("stream protocol version is not ready/valid FIFO v1");
            axi_read32(REG_BITSTREAM_ID, rd32);
            if (rd32 !== 32'h5650_5532)
                fail("bitstream identity register mismatch");

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h1000 + case_id), 16'h000f);
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(group_blocks * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(group_blocks * 2), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 |
                                       ((case_id >= 97) ? VPU_MODE_P2_TWO_ROW : 32'd0)), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);

            stage_pair_weight_image(rows, current_col_beats);

            for (scale_word_idx = 0;
                 scale_word_idx < ((rows * group_blocks + 3) / 4);
                 scale_word_idx = scale_word_idx + 1)
                axi_write(SPU_PARAM_BASE + scale_word_idx * 16,
                          pack_stream_scale_word(rows, group_blocks, scale_word_idx),
                          16'hffff);

            axi_read(REG_SPU_STREAM_COUNT, rd_word);
            stream_count_before = rd_word[31:0];
            axi_read32(REG_SPU_STREAM_DONE, stream_done_before);
            axi_read(REG_SPU_STREAM_DROP, rd_word);
            stream_drop_before = rd_word[31:0];
            axi_read32(REG_SPU_STREAM_OUT, stream_out_before);
            axi_read32(REG_SPU_STREAM_ERROR, stream_error_before);

            start_cycle = cycle_count;
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);

            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("Packed q8 core reported configuration error");
                    timeout = 1000;
                    rd_word[0] = 1'b1;
                end
                if (timeout > 100000) begin
                    fail("Packed q8 core did not finish");
                    rd_word[0] = 1'b1;
                end
            end
            done_cycle = cycle_count;

            timeout = 0;
            stream_out_after = stream_out_before;
            while (stream_out_after < (stream_out_before + rows)) begin
                axi_read32(REG_SPU_STREAM_OUT, stream_out_after);
                timeout = timeout + 1;
                if (timeout > 100000) begin
                    fail("SPU raw stream accumulator did not emit all rows");
                    stream_out_after = stream_out_before + rows;
                end
            end

            axi_read(REG_SPU_STREAM_COUNT, rd_word);
            stream_count_after = rd_word[31:0];
            axi_read32(REG_SPU_STREAM_DONE, stream_done_after);
            axi_read(REG_SPU_STREAM_DROP, rd_word);
            stream_drop_after = rd_word[31:0];
            axi_read32(REG_SPU_STREAM_OUT, stream_out_after);
            axi_read32(REG_SPU_STREAM_ERROR, stream_error_after);

            axi_read32(REG_SPU_STREAM_STATUS, rd32);
            if (rd32[4:0] !== 5'b1_1111)
                fail("SPU stream completion was not quiescent before next P2 job");
            else
                pass_count = pass_count + 1;

            if (stream_count_after !== (stream_count_before + rows * group_blocks))
                fail("SPU raw stream accepted-count mismatch");
            else
                pass_count = pass_count + 1;

            if (stream_done_after !== (stream_done_before + 32'd1))
                fail("SPU raw stream done-count mismatch");
            else
                pass_count = pass_count + 1;

            if (stream_drop_after !== stream_drop_before)
                fail("SPU raw stream dropped an entry");
            else
                pass_count = pass_count + 1;

            if (stream_error_after !== stream_error_before)
                fail("SPU raw stream accumulator reported an error");
            else
                pass_count = pass_count + 1;

            if (stream_out_after !== (stream_out_before + rows))
                fail("SPU raw stream output-count mismatch");
            else
                pass_count = pass_count + 1;

            axi_read(REG_SPU_STREAM_LAST_RAW, rd_word);
            got = rd_word[31:0];
            expected = golden_q8_block(rows - 1, group_blocks - 1);
            if (got !== expected)
                fail("SPU raw stream last raw value mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_LAST_META, rd32);
            if ((rd32[30] !== 1'b1) ||
                (rd32[31] !== (group_blocks == 1)) ||
                (rd32[29:16] != (group_blocks - 1)) ||
                (rd32[15:0] != (rows - 1)))
                fail("SPU raw stream last metadata mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_LAST_JOB, rd32);
            if (rd32 !== (32'h0000_1000 + case_id))
                fail("SPU raw stream last job id mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_LAST_BANK, rd32);
            if (rd32[0] !== 1'b0)
                fail("SPU raw stream last bank mismatch");
            else
                pass_count = pass_count + 1;

            expected_accum =
                $signed(golden_q8_range(rows - 1, 0, group_blocks)) *
                SPU_TEST_Q16_SCALE_PRODUCT;
            axi_read(REG_SPU_STREAM_ACCUM_LO, rd_word);
            if (rd_word[31:0] !== expected_accum[31:0])
                fail("SPU raw stream accumulator low word mismatch");
            else
                pass_count = pass_count + 1;

            axi_read32(REG_SPU_STREAM_ACCUM_HI, rd32);
            if (rd32 !== expected_accum[63:32])
                fail("SPU raw stream accumulator high word mismatch");
            else
                pass_count = pass_count + 1;

            axi_read(SPU_OUT_BASE + (rows - 1) * 16, rd_word);
            if (rd_word[15:0] !== (rows - 1))
                fail("SPU_OUT row id mismatch");
            else
                pass_count = pass_count + 1;

            if (rd_word[79:16] !== expected_accum)
                fail("SPU_OUT scaled accumulator mismatch");
            else
                pass_count = pass_count + 1;

            for (row = 0; row < rows; row = row + 1) begin
                for (block_id = 0; block_id < group_blocks; block_id = block_id + 1) begin
                    linear = row * group_blocks + block_id;
                    word_idx = linear / 4;
                    lane_idx = linear % 4;
                    axi_read(RESULT_BASE + word_idx * 16, rd_word);
                    got = rd_word[32*lane_idx +: 32];
                    expected = golden_q8_block(row, block_id);
                    if (got !== expected) begin
                        $display("[TB][FAIL] packed row=%0d block=%0d got=%0d expected=%0d",
                                 row, block_id, got, expected);
                        fail_count = fail_count + 1;
                    end else begin
                        $display("[TB][PASS] packed row=%0d block=%0d result=%0d",
                                 row, block_id, got);
                        pass_count = pass_count + 1;
                    end
                end
            end

            $display("[TB] GROUP CASE %0d compute+poll cycles=%0d", case_id, done_cycle - start_cycle);
        end
    endtask

    task run_int8_result_case;
        input integer case_id;
        input integer rows;
        input integer group_blocks;
        input integer requant_shift;
        integer beat;
        integer row;
        integer block_id;
        integer linear;
        integer word_idx;
        integer lane_idx;
        integer timeout;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [7:0] got;
        reg signed [7:0] expected;
        begin
            init_case_data(case_id, rows, group_blocks * 32);

            $display("[TB] INT8 RESULT CASE %0d: rows=%0d q8_blocks=%0d shift=%0d",
                     case_id, rows, group_blocks, requant_shift);

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h2000 + case_id), 16'h000f);
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(group_blocks * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(group_blocks * 2), 16'h000f);
            axi_write(REG_SCALE, word32(requant_shift), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 |
                                       VPU_MODE_RESULT_INT8 |
                                       VPU_MODE_ACCUM_CLEAR |
                                       VPU_MODE_RESULT_EMIT), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);

            stage_pair_weight_image(rows, current_col_beats);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);

            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("INT8 result core reported configuration error");
                    timeout = 1000;
                    rd_word[0] = 1'b1;
                end
                if (timeout > 1000) begin
                    fail("INT8 result core did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            for (row = 0; row < rows; row = row + 1) begin
                linear = row;
                word_idx = linear / 16;
                lane_idx = linear % 16;
                axi_read(RESULT_BASE + word_idx * 16, rd_word);
                got = rd_word[8*lane_idx +: 8];
                expected = requant_i8(golden_q8_range(row, 0, group_blocks), requant_shift);
                if (got !== expected) begin
                    $display("[TB][FAIL] int8 row=%0d got=%0d expected=%0d raw=%0d",
                             row, got, expected,
                             golden_q8_range(row, 0, group_blocks));
                    fail_count = fail_count + 1;
                end else begin
                    $display("[TB][PASS] int8 row=%0d result=%0d raw=%0d",
                             row, got,
                             golden_q8_range(row, 0, group_blocks));
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    task run_int8_accum_groups_case;
        input integer case_id;
        input integer rows;
        input integer first_blocks;
        input integer second_blocks;
        input integer requant_shift;
        integer beat;
        integer row;
        integer linear;
        integer word_idx;
        integer lane_idx;
        integer timeout;
        integer total_blocks;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [7:0] got;
        reg signed [7:0] expected;
        begin
            total_blocks = first_blocks + second_blocks;
            init_case_data(case_id, rows, total_blocks * 32);

            $display("[TB] INT8 ACCUM CASE %0d: rows=%0d groups=[%0d,%0d] shift=%0d",
                     case_id, rows, first_blocks, second_blocks, requant_shift);

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h3000 + case_id), 16'h000f);
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(first_blocks * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(first_blocks * 2), 16'h000f);
            axi_write(REG_SCALE, word32(requant_shift), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 |
                                       VPU_MODE_RESULT_INT8 |
                                       VPU_MODE_ACCUM_CLEAR), 16'h000f);

            for (beat = 0; beat < first_blocks * 2; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation_from(0, beat), 16'hffff);
            stage_pair_weight_image_from(rows, first_blocks * 2, 0);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("INT8 accum first group reported configuration error");
                    timeout = 1000;
                    rd_word[0] = 1'b1;
                end
                if (timeout > 1000) begin
                    fail("INT8 accum first group did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h4000 + case_id), 16'h000f);
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(second_blocks * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(second_blocks * 2), 16'h000f);
            axi_write(REG_SCALE, word32(requant_shift), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 |
                                       VPU_MODE_RESULT_INT8 |
                                       VPU_MODE_RESULT_EMIT), 16'h000f);

            for (beat = 0; beat < second_blocks * 2; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16,
                          pack_activation_from(first_blocks * 2, beat), 16'hffff);
            stage_pair_weight_image_from(rows, second_blocks * 2, first_blocks * 2);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("INT8 accum final group reported configuration error");
                    timeout = 1000;
                    rd_word[0] = 1'b1;
                end
                if (timeout > 1000) begin
                    fail("INT8 accum final group did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            for (row = 0; row < rows; row = row + 1) begin
                linear = row;
                word_idx = linear / 16;
                lane_idx = linear % 16;
                axi_read(RESULT_BASE + word_idx * 16, rd_word);
                got = rd_word[8*lane_idx +: 8];
                expected = requant_i8(golden_q8_range(row, 0, total_blocks), requant_shift);
                if (got !== expected) begin
                    $display("[TB][FAIL] int8 accum row=%0d got=%0d expected=%0d raw=%0d",
                             row, got, expected,
                             golden_q8_range(row, 0, total_blocks));
                    fail_count = fail_count + 1;
                end else begin
                    $display("[TB][PASS] int8 accum row=%0d result=%0d raw=%0d",
                             row, got,
                             golden_q8_range(row, 0, total_blocks));
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    // Protocol assertion: a VPU raw token must not change while the SPU FIFO
    // backpressures it.  The DUT test parameter creates pseudo-random stalls.
    always @(posedge clk) begin
        if (!resetn) begin
            stream_hold_valid <= 1'b0;
            stream_stall_observed <= 0;
        end else if (dut.u_my_ip.u_axi4_mapping.core_spu_raw_valid) begin
            if (stream_hold_valid &&
                ({dut.u_my_ip.u_axi4_mapping.core_spu_raw_data,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_row,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_block,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_group_blocks,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_last_block,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_clear_accum,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_job_id,
                  dut.u_my_ip.u_axi4_mapping.core_spu_raw_bank} !==
                 {stream_hold_data, stream_hold_row, stream_hold_block,
                  stream_hold_group_blocks, stream_hold_last_block,
                  stream_hold_clear_accum, stream_hold_job_id, stream_hold_bank}))
                fail("VPU raw data or metadata changed while valid was held");
            if (!dut.u_my_ip.u_axi4_mapping.core_spu_raw_ready) begin
                stream_stall_observed <= stream_stall_observed + 1;
                stream_hold_valid <= 1'b1;
                stream_hold_data <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_data;
                stream_hold_row <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_row;
                stream_hold_block <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_block;
                stream_hold_group_blocks <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_group_blocks;
                stream_hold_last_block <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_last_block;
                stream_hold_clear_accum <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_clear_accum;
                stream_hold_job_id <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_job_id;
                stream_hold_bank <= dut.u_my_ip.u_axi4_mapping.core_spu_raw_bank;
            end else begin
                stream_hold_valid <= 1'b0;
            end
        end else begin
            stream_hold_valid <= 1'b0;
        end
    end

    // Hold the VPU->SPU boundary while the other bank is filled.  This makes
    // the observation decisive: any active-bank/progress/result/stream change
    // is caused by the inactive-bank AXI traffic, not by normal retirement.
    // The 64 Q8-block (128 AXI-beat) input is the largest legal tile width;
    // each weight image is deliberately written in two halves.
    task run_live_preload_isolation_case;
        integer beat;
        integer row;
        integer block_id;
        integer timeout;
        reg [DATA_WIDTH-1:0] rd_word;
        reg [DATA_WIDTH-1:0] saved_result;
        reg [31:0] saved_bank_stat;
        reg [31:0] saved_active_job;
        reg [31:0] saved_progress;
        reg [31:0] saved_stream_count;
        reg [31:0] saved_stream_out;
        reg [31:0] saved_stream_error;
        reg [31:0] saved_stream_meta;
        reg [31:0] saved_stream_job;
        reg [31:0] saved_stream_bank;
        reg [31:0] saved_rows;
        reg [31:0] saved_cols;
        reg [31:0] saved_col_beats;
        reg [31:0] saved_scale;
        reg [31:0] saved_mode;
        reg [31:0] saved_slot_state;
        reg [31:0] saved_tensor_id;
        reg [31:0] saved_row0;
        reg [31:0] saved_k_block0;
        reg [31:0] saved_group_blocks;
        reg [31:0] saved_token_id;
        reg [31:0] saved_desc_flags;
        reg [31:0] stream_done_before;
        reg [31:0] stream_out_before;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        reg signed [63:0] expected_accum;
        begin
            $display("[TB] LIVE PRELOAD CASE: active bank isolation, PING->PONG->PING");
            init_case_data(61, 8, MAX_TEST_COLS);

            // Scale metadata is shared SPU storage, so establish it before
            // either live preload.  There must be no SPU_PARAM/OUT write once
            // the first VPU job has started.
            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_ROWS, word32(8), 16'h000f);
            axi_write(REG_COLS, word32(MAX_TEST_COLS), 16'h000f);
            axi_write(REG_COL_BEATS, word32(MAX_COL_BEATS), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8), 16'h000f);
            axi_write(REG_SLOT_STATE, word32(32'h0000_0214), 16'h000f);
            axi_write(REG_TENSOR_ID, word32(32'h0000_0055), 16'h000f);
            axi_write(REG_ROW0, word32(32'h0000_0080), 16'h000f);
            axi_write(REG_K_BLOCK0, word32(32'h0000_0007), 16'h000f);
            axi_write(REG_GROUP_BLOCKS, word32(32'h0000_0040), 16'h000f);
            axi_write(REG_TOKEN_ID, word32(32'h0000_004c), 16'h000f);
            axi_write(REG_DESC_FLAGS, word32(32'h0000_0001), 16'h000f);
            for (beat = 0; beat < 128; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(8, 128);
            for (beat = 0; beat < 128; beat = beat + 1)
                axi_write(SPU_PARAM_BASE + beat * 16,
                          pack_stream_scale_word(8, 64, beat), 16'hffff);

            axi_write(REG_JOB_ID, word32(32'h0000_ca00), 16'h000f);
            axi_read32(REG_SPU_STREAM_DONE, stream_done_before);
            axi_read32(REG_SPU_STREAM_OUT, stream_out_before);
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);

            // From here until each active job completes, the only AXI control
            // write allowed by the host contract is REG_BANK.  Keep ready live
            // so normal VPU/SPU retirement must make observable progress.
            axi_read(REG_BANK_STAT, rd_word); saved_bank_stat = rd_word[31:0];
            axi_read32(REG_ACTIVE_JOB, saved_active_job);
            axi_read(REG_PROGRESS, rd_word); saved_progress = rd_word[31:0];
            // Use the descriptor values written immediately above as the
            // immutable reference.  Reading every register here consumed
            // enough cycles for the new two-row engine to finish an 8-row
            // job before preload began, turning the overlap assertion into a
            // testbench race instead of an ownership check.
            saved_rows         = 32'd8;
            saved_cols         = MAX_TEST_COLS;
            saved_col_beats    = MAX_COL_BEATS;
            saved_scale        = 32'h0000_3c00;
            saved_mode         = VPU_MODE_PACKED_Q8;
            saved_stream_job   = 32'h0000_ca00;
            saved_slot_state   = 32'h0000_0214;
            saved_tensor_id    = 32'h0000_0055;
            saved_row0         = 32'h0000_0080;
            saved_k_block0     = 32'h0000_0007;
            saved_group_blocks = 32'h0000_0040;
            saved_token_id     = 32'h0000_004c;
            saved_desc_flags   = 32'h0000_0001;

            // PING active: preload PONG with a full ACT image and a split
            // 8x128-beat WEIGHT image.  Do not touch SPU_PARAM or SPU_OUT.
            axi_write(REG_BANK, word32(32'h0000_0001), 16'h000f);
            preload_compute_write_overlap = 0;
            preload_busy_violation = 0;
            preload_watch_enable = 1'b1;
            init_case_data(62, 8, MAX_TEST_COLS);
            for (beat = 0; beat < 128; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            for (row = 0; row < 8; row = row + 1)
                for (beat = 0; beat < 64; beat = beat + 1)
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row, 128, beat) * 16,
                              pack_weight(row, beat), 16'hffff);
            for (row = 0; row < 8; row = row + 1)
                for (beat = 64; beat < 128; beat = beat + 1)
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row, 128, beat) * 16,
                              pack_weight(row, beat), 16'hffff);
            preload_watch_enable = 1'b0;

            axi_read(REG_BANK_STAT, rd_word);
            if (rd_word[18:8] !== saved_bank_stat[18:8]) fail("PONG preload changed active bank/status"); else pass_count = pass_count + 1;
            if (rd_word[1] !== 1'b0) fail("PONG preload changed result-read bank"); else pass_count = pass_count + 1;
            axi_read32(REG_ACTIVE_JOB, rd_word[31:0]);
            if (rd_word[31:0] !== saved_active_job) fail("PONG preload changed active job id"); else pass_count = pass_count + 1;
            axi_read(REG_PROGRESS, rd_word);
            if (rd_word[31:0] === saved_progress) fail("PING made no progress during PONG preload"); else pass_count = pass_count + 1;
            axi_read32(REG_ROWS, rd_word[31:0]); if (rd_word[31:0] !== saved_rows) fail("PONG preload changed rows");
            axi_read32(REG_COLS, rd_word[31:0]); if (rd_word[31:0] !== saved_cols) fail("PONG preload changed cols");
            axi_read32(REG_COL_BEATS, rd_word[31:0]); if (rd_word[31:0] !== saved_col_beats) fail("PONG preload changed col_beats");
            axi_read32(REG_SCALE, rd_word[31:0]); if (rd_word[31:0] !== saved_scale) fail("PONG preload changed scale");
            axi_read32(REG_MODE, rd_word[31:0]); if (rd_word[31:0] !== saved_mode) fail("PONG preload changed mode");
            axi_read32(REG_JOB_ID, rd_word[31:0]); if (rd_word[31:0] !== saved_stream_job) fail("PONG preload changed job_id");
            axi_read32(REG_SLOT_STATE, rd_word[31:0]); if (rd_word[31:0] !== saved_slot_state) fail("PONG preload changed slot_state");
            axi_read32(REG_TENSOR_ID, rd_word[31:0]); if (rd_word[31:0] !== saved_tensor_id) fail("PONG preload changed tensor_id");
            axi_read32(REG_ROW0, rd_word[31:0]); if (rd_word[31:0] !== saved_row0) fail("PONG preload changed row0");
            axi_read32(REG_K_BLOCK0, rd_word[31:0]); if (rd_word[31:0] !== saved_k_block0) fail("PONG preload changed k_block0");
            axi_read32(REG_GROUP_BLOCKS, rd_word[31:0]); if (rd_word[31:0] !== saved_group_blocks) fail("PONG preload changed group_blocks");
            axi_read32(REG_TOKEN_ID, rd_word[31:0]); if (rd_word[31:0] !== saved_token_id) fail("PONG preload changed token_id");
            axi_read32(REG_DESC_FLAGS, rd_word[31:0]); if (rd_word[31:0] !== saved_desc_flags) fail("PONG preload changed desc_flags");
            // `core_busy` staying asserted for the entire preload interval
            // plus forward progress is the protocol-level overlap proof.  Do
            // not require a read-enable pulse and an AXI decode pulse to land
            // on the exact same clock; their independent pipelines can be
            // phase-aligned without changing the overlap interval.
            if (preload_compute_write_overlap != 0) pass_count = pass_count + 1;
            if (preload_busy_violation != 0) fail("PING was not busy throughout PONG preload"); else pass_count = pass_count + 1;
            timeout = 0; rd_word = 0;
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word); timeout = timeout + 1;
                if (rd_word[2] || timeout > 200000) begin fail("PING job did not complete after PONG preload"); rd_word[0] = 1'b1; end
            end
            timeout = 0;
            while (rd_word[4:0] !== 5'b1_1111) begin
                axi_read32(REG_SPU_STREAM_STATUS, rd_word[31:0]); timeout = timeout + 1;
                if (timeout > 200000) begin fail("PING SPU stream did not quiesce"); rd_word = 32'h0000_001f; end
            end
            init_case_data(61, 8, MAX_TEST_COLS);
            axi_read32(REG_SPU_STREAM_LAST_JOB, rd_word[31:0]); if (rd_word[31:0] !== 32'h0000_ca00) fail("PING stream job id mismatch"); else pass_count = pass_count + 1;
            axi_read32(REG_SPU_STREAM_LAST_BANK, rd_word[31:0]); if (rd_word[0] !== 1'b0) fail("PING stream bank mismatch"); else pass_count = pass_count + 1;
            expected_accum = $signed(golden_q8_range(7, 0, 64)) * SPU_TEST_Q16_SCALE_PRODUCT;
            axi_read(SPU_OUT_BASE + 7*16, rd_word);
            if ((rd_word[15:0] !== 16'd7) || (rd_word[79:16] !== expected_accum)) fail("PING SPU_OUT Q16 mismatch"); else pass_count = pass_count + 1;

            // Start PONG without re-writing ACT, WEIGHT, SPU_PARAM, or SPU_OUT.
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            axi_read(REG_BANK_STAT, rd_word); saved_bank_stat = rd_word[31:0];
            axi_read32(REG_ACTIVE_JOB, saved_active_job);
            axi_read(REG_PROGRESS, rd_word); saved_progress = rd_word[31:0];

            // PONG active: repeat the inverse preload into PING, again split
            // at the weight half boundary, then launch PING without a rewrite.
            axi_write(REG_BANK, word32(32'h0000_0002), 16'h000f);
            preload_compute_write_overlap = 0;
            preload_busy_violation = 0;
            preload_watch_enable = 1'b1;
            init_case_data(63, 8, MAX_TEST_COLS);
            for (beat = 0; beat < 128; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            for (row = 0; row < 8; row = row + 1)
                for (beat = 0; beat < 64; beat = beat + 1)
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row, 128, beat) * 16, pack_weight(row, beat), 16'hffff);
            for (row = 0; row < 8; row = row + 1)
                for (beat = 64; beat < 128; beat = beat + 1)
                    axi_write(WEIGHT_BASE + pair_weight_word_index(row, 128, beat) * 16, pack_weight(row, beat), 16'hffff);
            preload_watch_enable = 1'b0;
            axi_read(REG_BANK_STAT, rd_word); if (rd_word[18:8] !== saved_bank_stat[18:8]) fail("PING preload changed active PONG bank/status"); else pass_count = pass_count + 1;
            if (rd_word[1] !== 1'b1) fail("PING preload changed result-read bank"); else pass_count = pass_count + 1;
            axi_read32(REG_ACTIVE_JOB, rd_word[31:0]); if (rd_word[31:0] !== saved_active_job) fail("PING preload changed active PONG job id"); else pass_count = pass_count + 1;
            axi_read(REG_PROGRESS, rd_word); if (rd_word[31:0] === saved_progress) fail("PONG made no progress during PING preload"); else pass_count = pass_count + 1;
            axi_read32(REG_ROWS, rd_word[31:0]); if (rd_word[31:0] !== saved_rows) fail("PING preload changed rows");
            axi_read32(REG_COLS, rd_word[31:0]); if (rd_word[31:0] !== saved_cols) fail("PING preload changed cols");
            axi_read32(REG_COL_BEATS, rd_word[31:0]); if (rd_word[31:0] !== saved_col_beats) fail("PING preload changed col_beats");
            axi_read32(REG_SCALE, rd_word[31:0]); if (rd_word[31:0] !== saved_scale) fail("PING preload changed scale");
            axi_read32(REG_MODE, rd_word[31:0]); if (rd_word[31:0] !== saved_mode) fail("PING preload changed mode");
            axi_read32(REG_JOB_ID, rd_word[31:0]); if (rd_word[31:0] !== saved_stream_job) fail("PING preload changed job_id");
            axi_read32(REG_SLOT_STATE, rd_word[31:0]); if (rd_word[31:0] !== saved_slot_state) fail("PING preload changed slot_state");
            axi_read32(REG_TENSOR_ID, rd_word[31:0]); if (rd_word[31:0] !== saved_tensor_id) fail("PING preload changed tensor_id");
            axi_read32(REG_ROW0, rd_word[31:0]); if (rd_word[31:0] !== saved_row0) fail("PING preload changed row0");
            axi_read32(REG_K_BLOCK0, rd_word[31:0]); if (rd_word[31:0] !== saved_k_block0) fail("PING preload changed k_block0");
            axi_read32(REG_GROUP_BLOCKS, rd_word[31:0]); if (rd_word[31:0] !== saved_group_blocks) fail("PING preload changed group_blocks");
            axi_read32(REG_TOKEN_ID, rd_word[31:0]); if (rd_word[31:0] !== saved_token_id) fail("PING preload changed token_id");
            axi_read32(REG_DESC_FLAGS, rd_word[31:0]); if (rd_word[31:0] !== saved_desc_flags) fail("PING preload changed desc_flags");
            if (preload_compute_write_overlap != 0) pass_count = pass_count + 1;
            if (preload_busy_violation != 0) fail("PONG was not busy throughout PING preload"); else pass_count = pass_count + 1;

            timeout = 0; rd_word = 0;
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word); timeout = timeout + 1;
                if (rd_word[2] || timeout > 200000) begin fail("PONG job did not complete after PING preload"); rd_word[0] = 1'b1; end
            end
            timeout = 0; rd_word = 0;
            while (rd_word[4:0] !== 5'b1_1111) begin
                axi_read32(REG_SPU_STREAM_STATUS, rd_word[31:0]); timeout = timeout + 1;
                if (timeout > 200000) begin fail("PONG SPU stream did not quiesce"); rd_word = 32'h0000_001f; end
            end
            init_case_data(62, 8, MAX_TEST_COLS);
            axi_read32(REG_SPU_STREAM_LAST_JOB, rd_word[31:0]); if (rd_word[31:0] !== 32'h0000_ca00) fail("PONG stream job id mismatch"); else pass_count = pass_count + 1;
            axi_read32(REG_SPU_STREAM_LAST_BANK, rd_word[31:0]); if (rd_word[0] !== 1'b1) fail("PONG stream bank mismatch"); else pass_count = pass_count + 1;
            expected_accum = $signed(golden_q8_range(7, 0, 64)) * SPU_TEST_Q16_SCALE_PRODUCT;
            axi_read(SPU_OUT_BASE + 7*16, rd_word);
            if ((rd_word[15:0] !== 16'd7) || (rd_word[79:16] !== expected_accum)) fail("PONG SPU_OUT Q16 mismatch"); else pass_count = pass_count + 1;
            // PONG was launched solely from the first inactive-bank preload.
            // Check its complete packed result image before selecting PING.
            axi_write(REG_BANK, word32(32'h0000_0003), 16'h000f);
            for (row = 0; row < 8; row = row + 1)
                for (block_id = 0; block_id < 64; block_id = block_id + 1) begin
                    axi_read(RESULT_BASE + ((row * 64 + block_id) / 4) * 16, rd_word);
                    got = rd_word[32*((row * 64 + block_id) % 4) +: 32];
                    expected = golden_q8_block(row, block_id);
                    if (got !== expected) fail("preloaded PONG packed result mismatch"); else pass_count = pass_count + 1;
                end
            // Restore the exact bank selector programmed by the live PONG->PING preload.
            axi_write(REG_BANK, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0; rd_word = 0;
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word); timeout = timeout + 1;
                if (rd_word[2] || timeout > 200000) begin fail("re-preloaded PING job did not complete"); rd_word[0] = 1'b1; end
            end
            timeout = 0; rd_word = 0;
            while (rd_word[4:0] !== 5'b1_1111) begin
                axi_read32(REG_SPU_STREAM_STATUS, rd_word[31:0]); timeout = timeout + 1;
                if (timeout > 200000) begin fail("re-preloaded PING SPU stream did not quiesce"); rd_word = 32'h0000_001f; end
            end

            // The final PING result comes from its second preload, not a
            // rewrite after launch.  Sample every block to cover the full
            // 128-beat/split-weight image.
            init_case_data(63, 8, MAX_TEST_COLS);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            for (row = 0; row < 8; row = row + 1)
                for (block_id = 0; block_id < 64; block_id = block_id + 1) begin
                    axi_read(RESULT_BASE + ((row * 64 + block_id) / 4) * 16, rd_word);
                    got = rd_word[32*((row * 64 + block_id) % 4) +: 32];
                    expected = golden_q8_block(row, block_id);
                    if (got !== expected) fail("re-preloaded PING packed result mismatch"); else pass_count = pass_count + 1;
                end
            axi_read32(REG_SPU_STREAM_LAST_JOB, rd_word[31:0]); if (rd_word[31:0] !== 32'h0000_ca00) fail("re-preloaded PING stream job id mismatch"); else pass_count = pass_count + 1;
            axi_read32(REG_SPU_STREAM_LAST_BANK, rd_word[31:0]); if (rd_word[0] !== 1'b0) fail("re-preloaded PING stream bank mismatch"); else pass_count = pass_count + 1;
            expected_accum = $signed(golden_q8_range(7, 0, 64)) * SPU_TEST_Q16_SCALE_PRODUCT;
            axi_read(SPU_OUT_BASE + 7*16, rd_word);
            if ((rd_word[15:0] !== 16'd7) || (rd_word[79:16] !== expected_accum)) fail("re-preloaded PING SPU_OUT Q16 mismatch"); else pass_count = pass_count + 1;
            axi_read32(REG_SPU_STREAM_DONE, rd_word[31:0]);
            if (rd_word[31:0] !== (stream_done_before + 3)) fail("live preload stream done count mismatch"); else pass_count = pass_count + 1;
            axi_read32(REG_SPU_STREAM_OUT, rd_word[31:0]);
            if (rd_word[31:0] !== (stream_out_before + 24)) fail("live preload stream output count mismatch"); else pass_count = pass_count + 1;

            // The three launches and their SPU drain are complete above.
            // Re-establish the suite's reset baseline before unrelated legacy
            // cases so this focused ownership test cannot retain MMIO state.
            resetn = 1'b0;
            repeat (4) @(posedge clk);
            resetn = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task run_pair_weight_port_ownership_case;
        integer beat;
        integer row;
        integer block_id;
        integer linear;
        integer word_idx;
        integer lane_idx;
        integer scale_word_idx;
        integer timeout;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        begin
            $display("[TB] P2 WEIGHT PORT OWNERSHIP: inactive A staging and active rejection");
            // 32 Q8 blocks keep S_RUN live long enough for both AXI write
            // pipelines to reach the weight leaves while paired reads are
            // active; a one-block job can retire before that observation.
            init_case_data(131, 4, 1024);

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_ROWS, word32(4), 16'h000f);
            axi_write(REG_COLS, word32(1024), 16'h000f);
            axi_write(REG_COL_BEATS, word32(64), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 | VPU_MODE_P2_TWO_ROW), 16'h000f);

            // Preload both banks before the paired launch.  Bank 1 is then
            // touched once while bank 0 is actively reading both parity leaves.
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            for (beat = 0; beat < 64; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(4, 64);

            axi_write(REG_BANK, word32(32'h0000_0001), 16'h000f);
            for (beat = 0; beat < 64; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(4, 64);
            for (scale_word_idx = 0; scale_word_idx < 32; scale_word_idx = scale_word_idx + 1)
                axi_write(SPU_PARAM_BASE + scale_word_idx * 16,
                          pack_stream_scale_word(4, 32, scale_word_idx), 16'hffff);

            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h0000_0131), 16'h000f);
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            while (!dut.u_my_ip.u_axi4_mapping.core_busy) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 1000) begin
                    fail("paired ownership case never became busy");
                    timeout = 1001;
                end
            end

            axi_write(REG_BANK, word32(32'h0000_0001), 16'h000f);
            pair_inactive_weight_a_write_observed = 0;
            pair_weight_port_watch_enable = 1'b1;
            // Replace the full inactive-bank row 0 with a deliberately
            // different all-zero image while bank 0 is paired-active.  The
            // later bank-1 launch must observe zero raw Q8 blocks only for
            // this row; rows 1..3 remain the original golden image.
            for (beat = 0; beat < 64; beat = beat + 1)
                axi_write(WEIGHT_BASE + pair_weight_word_index(0, 64, beat) * 16,
                          {DATA_WIDTH{1'b0}}, 16'hffff);
            // AXI decode, core-write capture, and the local weight write
            // register add several cycles before the A-port pulse appears.
            repeat (20) @(posedge clk);
            pair_weight_port_watch_enable = 1'b0;
            if (pair_inactive_weight_a_write_observed == 0)
                fail("paired inactive-bank staging did not use weight port A");
            else
                pass_count = pass_count + 1;

            // Select the active bank and attempt distinct ACT and WEIGHT
            // writes.  Each AXI response remains protocol-compatible, but
            // REG_STATUS.error must expose the local fail-closed rejection;
            // the completed result must remain its pre-write golden value.
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(ACT_BASE + 16, 128'ha5a5_a5a5_a5a5_a5a5_a5a5_a5a5_a5a5_a5a5, 16'hffff);
            repeat (4) @(posedge clk);
            axi_read(REG_STATUS, rd_word);
            if (rd_word[2] !== 1'b1)
                fail("paired active-bank ACT write was not visibly rejected");
            else
                pass_count = pass_count + 1;

            // Clear only the sticky status bit while compute remains live so
            // the following WEIGHT rejection is independently observable.
            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            repeat (4) @(posedge clk);
            axi_read(REG_STATUS, rd_word);
            if (rd_word[2] !== 1'b0)
                fail("paired ownership error did not clear for independent WEIGHT test");
            else
                pass_count = pass_count + 1;

            axi_write(WEIGHT_BASE + pair_weight_word_index(0, 64, 1) * 16,
                      128'h5a5a_5a5a_5a5a_5a5a_5a5a_5a5a_5a5a, 16'hffff);
            repeat (4) @(posedge clk);
            axi_read(REG_STATUS, rd_word);
            if (rd_word[2] !== 1'b1)
                fail("paired active-bank weight write was not visibly rejected");
            else
                pass_count = pass_count + 1;

            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (timeout > 100000) begin
                    fail("paired ownership active job did not finish");
                    rd_word[0] = 1'b1;
                end
            end
            timeout = 0;
            rd_word = 32'd0;
            while (rd_word[4:0] !== 5'b1_1111) begin
                axi_read32(REG_SPU_STREAM_STATUS, rd_word[31:0]);
                timeout = timeout + 1;
                if (timeout > 100000) begin
                    fail("paired ownership active stream did not quiesce");
                    rd_word = 32'h0000_001f;
                end
            end

            axi_read(RESULT_BASE, rd_word);
            got = rd_word[31:0];
            expected = golden_q8_block(0, 0);
            if (got !== expected)
                fail("paired active-bank rejected write changed raw result");
            else
                pass_count = pass_count + 1;

            // A second paired launch from the staged bank must expose the
            // altered row 0 and preserve the golden raw INT32 image for rows
            // 1..3.  This proves the full inactive staging image was retained
            // and did not disturb the active compute bank.
            axi_write(REG_BANK, word32(32'h0000_0003), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h0000_0132), 16'h000f);
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("paired staged-bank job reported an error");
                    rd_word[0] = 1'b1;
                end
                if (timeout > 100000) begin
                    fail("paired staged-bank job did not finish");
                    rd_word[0] = 1'b1;
                end
            end
            for (row = 0; row < 4; row = row + 1)
                for (block_id = 0; block_id < 32; block_id = block_id + 1) begin
                    linear = row * 32 + block_id;
                    word_idx = linear / 4;
                    lane_idx = linear % 4;
                    axi_read(RESULT_BASE + word_idx * 16, rd_word);
                    got = rd_word[32*lane_idx +: 32];
                    expected = (row == 0) ? 32'sd0 : golden_q8_block(row, block_id);
                    if (got !== expected)
                        fail("paired staged-bank altered raw INT32 result mismatch");
                    else
                        pass_count = pass_count + 1;
                end

            resetn = 1'b0;
            repeat (4) @(posedge clk);
            resetn = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task run_pingpong_case;
        integer beat;
        integer row;
        integer timeout;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [31:0] got;
        reg signed [31:0] expected0_row0;
        reg signed [31:0] expected0_row1;
        reg signed [31:0] expected1_row0;
        reg signed [31:0] expected1_row1;
        begin
            $display("[TB] PINGPONG CASE: bank isolation and job tags");

            axi_write(REG_SLOT_STATE, word32(32'h0000_0214), 16'h000f);
            axi_write(REG_TENSOR_ID, word32(32'h0000_0055), 16'h000f);
            axi_write(REG_ROW0, word32(32'h0000_0080), 16'h000f);
            axi_write(REG_K_BLOCK0, word32(32'h0000_0007), 16'h000f);
            axi_write(REG_GROUP_BLOCKS, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_TOKEN_ID, word32(32'h0000_004c), 16'h000f);
            axi_write(REG_DESC_FLAGS, word32(32'h0000_0001), 16'h000f);

            axi_read(REG_SLOT_STATE, rd_word);
            if (rd_word[31:0] !== 32'h0000_0214)
                fail("Descriptor slot_state readback mismatch");
            axi_read(REG_TENSOR_ID, rd_word);
            if (rd_word[31:0] !== 32'h0000_0055)
                fail("Descriptor tensor_id readback mismatch");
            axi_read(REG_ROW0, rd_word);
            if (rd_word[31:0] !== 32'h0000_0080)
                fail("Descriptor row0 readback mismatch");
            axi_read(REG_K_BLOCK0, rd_word);
            if (rd_word[31:0] !== 32'h0000_0007)
                fail("Descriptor k_block0 readback mismatch");
            axi_read(REG_GROUP_BLOCKS, rd_word);
            if (rd_word[31:0] !== 32'h0000_0002)
                fail("Descriptor group_blocks readback mismatch");
            axi_read(REG_TOKEN_ID, rd_word);
            if (rd_word[31:0] !== 32'h0000_004c)
                fail("Descriptor token_id readback mismatch");
            axi_read(REG_DESC_FLAGS, rd_word);
            if (rd_word[31:0] !== 32'h0000_0001)
                fail("Descriptor flags readback mismatch");

            init_case_data(20, 2, 64);
            expected0_row0 = golden_row(0);
            expected0_row1 = golden_row(1);

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h0000_aa00), 16'h000f);
            axi_write(REG_ROWS, word32(2), 16'h000f);
            axi_write(REG_COLS, word32(64), 16'h000f);
            axi_write(REG_COL_BEATS, word32(4), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(32'h0000_0000), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(2, current_col_beats);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("Pingpong bank0 reported configuration error");
                    rd_word[0] = 1'b1;
                end
                if (timeout > 100000) begin
                    fail("Pingpong bank0 did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            axi_read(REG_DONE_JOB, rd_word);
            if (rd_word[31:0] !== 32'h0000_aa00)
                fail("Pingpong bank0 done_job_id mismatch");
            axi_read(REG_BANK_STAT, rd_word);
            if (rd_word[9] !== 1'b0)
                fail("Pingpong bank0 done_bank mismatch");

            for (row = 0; row < 2; row = row + 1) begin
                axi_read(RESULT_BASE + row * 16, rd_word);
                got = rd_word[31:0];
                if ((row == 0 && got !== expected0_row0) ||
                    (row == 1 && got !== expected0_row1)) begin
                    fail("Pingpong bank0 initial result mismatch");
                end else begin
                    pass_count = pass_count + 1;
                end
            end

            init_case_data(21, 2, 64);
            expected1_row0 = golden_row(0);
            expected1_row1 = golden_row(1);

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0001), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h0000_bb01), 16'h000f);
            axi_write(REG_ROWS, word32(2), 16'h000f);
            axi_write(REG_COLS, word32(64), 16'h000f);
            axi_write(REG_COL_BEATS, word32(4), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(32'h0000_0000), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(2, current_col_beats);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("Pingpong bank1 reported configuration error");
                    rd_word[0] = 1'b1;
                end
                if (timeout > 1000) begin
                    fail("Pingpong bank1 did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            axi_read(REG_DONE_JOB, rd_word);
            if (rd_word[31:0] !== 32'h0000_bb01)
                fail("Pingpong bank1 done_job_id mismatch");
            axi_read(REG_BANK_STAT, rd_word);
            if (rd_word[9] !== 1'b1)
                fail("Pingpong bank1 done_bank mismatch");

            axi_write(REG_BANK, word32(32'h0000_0003), 16'h000f);
            for (row = 0; row < 2; row = row + 1) begin
                axi_read(RESULT_BASE + row * 16, rd_word);
                got = rd_word[31:0];
                if ((row == 0 && got !== expected1_row0) ||
                    (row == 1 && got !== expected1_row1)) begin
                    fail("Pingpong bank1 result mismatch");
                end else begin
                    pass_count = pass_count + 1;
                end
            end

            axi_write(REG_BANK, word32(32'h0000_0001), 16'h000f);
            for (row = 0; row < 2; row = row + 1) begin
                axi_read(RESULT_BASE + row * 16, rd_word);
                got = rd_word[31:0];
                if ((row == 0 && got !== expected0_row0) ||
                    (row == 1 && got !== expected0_row1)) begin
                    fail("Pingpong bank0 result was overwritten by bank1");
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    // P2 descriptor commits are a host-visible ownership contract.  The host
    // selects the same bank for input fill and result drain, then requires an
    // exact readback before issuing the following ACT DMA transfer.  Check both
    // slot encodings: bank 0 DMA_FILLING is bits [3:0] = 2, while bank 1 is
    // bits [7:4] = 2.  REG_BANK and REG_BANK_STAT carry the duplicated bank
    // selection in bits [1:0].
    task write_and_verify_dma_filling_descriptor;
        input [31:0] bank_bits;
        input [31:0] expected_slot_state;
        input [31:0] expected_job_id;
        input [31:0] expected_tensor_id;
        input [31:0] expected_row0;
        input [31:0] expected_k_block0;
        input [31:0] expected_group_blocks;
        input [31:0] expected_token_id;
        reg [DATA_WIDTH-1:0] rd_word;
        begin
            axi_write(REG_BANK, word32(bank_bits), 16'h000f);
            axi_write(REG_JOB_ID, word32(expected_job_id), 16'h000f);
            axi_write(REG_SLOT_STATE, word32(expected_slot_state), 16'h000f);
            axi_write(REG_TENSOR_ID, word32(expected_tensor_id), 16'h000f);
            axi_write(REG_ROW0, word32(expected_row0), 16'h000f);
            axi_write(REG_K_BLOCK0, word32(expected_k_block0), 16'h000f);
            axi_write(REG_GROUP_BLOCKS, word32(expected_group_blocks), 16'h000f);
            axi_write(REG_TOKEN_ID, word32(expected_token_id), 16'h000f);
            axi_write(REG_DESC_FLAGS, word32(32'h0000_0101), 16'h000f);

            axi_read(REG_BANK, rd_word);
            if (rd_word[1:0] !== bank_bits[1:0])
                fail("Descriptor REG_BANK bits[1:0] readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_BANK_STAT, rd_word);
            if (rd_word[1:0] !== bank_bits[1:0])
                fail("Descriptor REG_BANK_STAT bits[1:0] readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_JOB_ID, rd_word);
            if (rd_word[31:0] !== expected_job_id)
                fail("Descriptor job_id readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_SLOT_STATE, rd_word);
            if (rd_word[31:0] !== expected_slot_state)
                fail("Descriptor slot_state readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_TENSOR_ID, rd_word);
            if (rd_word[31:0] !== expected_tensor_id)
                fail("Descriptor tensor_id readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_ROW0, rd_word);
            if (rd_word[31:0] !== expected_row0)
                fail("Descriptor row0 readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_K_BLOCK0, rd_word);
            if (rd_word[31:0] !== expected_k_block0)
                fail("Descriptor k_block0 readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_GROUP_BLOCKS, rd_word);
            if (rd_word[31:0] !== expected_group_blocks)
                fail("Descriptor group_blocks readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_TOKEN_ID, rd_word);
            if (rd_word[31:0] !== expected_token_id)
                fail("Descriptor token_id readback mismatch");
            else
                pass_count = pass_count + 1;
            axi_read(REG_DESC_FLAGS, rd_word);
            if (rd_word[31:0] !== 32'h0000_0101)
                fail("Descriptor DMA_FILLING flags readback mismatch");
            else
                pass_count = pass_count + 1;
        end
    endtask

    task run_descriptor_commit_case;
        begin
            $display("[TB] DESCRIPTOR COMMIT CASE: bank0/bank1 DMA_FILLING encodings");
            write_and_verify_dma_filling_descriptor(
                32'h0000_0000, 32'h0000_0002, 32'h0000_d070,
                32'h5a00_0000, 32'h0000_0080, 32'h0000_0007,
                32'h0000_0024, 32'h0000_004c);
            write_and_verify_dma_filling_descriptor(
                32'h0000_0003, 32'h0000_0020, 32'h0000_d071,
                32'h5a00_0001, 32'h0000_0180, 32'h0000_002b,
                32'h0000_0024, 32'h0000_004d);
        end
    endtask

    // A 36-q8-block activation is exactly 72 128-bit beats.  This is a
    // black-box check: the only activation load is the DMA-shaped burst above;
    // successful packed results prove the accepted burst reached compute RAM.
    task run_act_burst_compute_case;
        integer beat;
        integer block_id;
        integer scale_word_idx;
        integer timeout;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        begin
            init_case_data(30, 1, 36 * 32);
            $display("[TB] ACT BURST COMPUTE CASE: 36 q8 blocks / 72 beats");

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h0000_d072), 16'h000f);
            axi_write(REG_ROWS, word32(1), 16'h000f);
            axi_write(REG_COLS, word32(36 * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(72), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8), 16'h000f);

            // This exact bank-0 DMA_FILLING descriptor must be committed and
            // verified immediately before the 72-beat production-shaped ACT
            // burst.  Keep the 36-block/128-beat boundary coverage below.
            write_and_verify_dma_filling_descriptor(
                32'h0000_0000, 32'h0000_0002, 32'h0000_d072,
                32'h5a00_0072, 32'h0000_0080, 32'h0000_0007,
                32'h0000_0024, 32'h0000_004c);
            axi_write_act_incr_burst(ACT_BASE, 72, 4);
            stage_pair_weight_image(1, 72);
            for (scale_word_idx = 0; scale_word_idx < 9; scale_word_idx = scale_word_idx + 1)
                axi_write(SPU_PARAM_BASE + scale_word_idx * 16,
                          pack_stream_scale_word(1, 36, scale_word_idx), 16'hffff);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("ACT burst compute reported configuration error");
                    rd_word[0] = 1'b1;
                end
                if (timeout > 100000) begin
                    fail("ACT burst compute did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            axi_read(REG_DONE_JOB, rd_word);
            if (rd_word[31:0] !== 32'h0000_d072)
                fail("ACT burst compute done_job_id was not committed");
            else
                pass_count = pass_count + 1;

            for (block_id = 0; block_id < 36; block_id = block_id + 1) begin
                axi_read(RESULT_BASE + (block_id / 4) * 16, rd_word);
                got = rd_word[32*(block_id % 4) +: 32];
                expected = golden_q8_block(0, block_id);
                if (got !== expected) begin
                    $display("[TB][FAIL] ACT burst block=%0d got=%0d expected=%0d",
                             block_id, got, expected);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end

            // MAX_COL_BEATS is 128.  Do not leave the AWLEN=127 transfer as
            // a protocol-only test: every beat must influence an observable
            // result.  With one 2,048-element row, each checked q8 block
            // consumes exactly two consecutive ACT beats; checking all 64
            // blocks therefore makes all 128 burst payload beats observable.
            init_case_data(31, 1, 64 * 32);
            $display("[TB] ACT BURST BOUNDARY COMPUTE: 64 q8 blocks / 128 beats");
            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h0000_d073), 16'h000f);
            axi_write(REG_ROWS, word32(1), 16'h000f);
            axi_write(REG_COLS, word32(64 * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(128), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8), 16'h000f);
            write_and_verify_dma_filling_descriptor(
                32'h0000_0000, 32'h0000_0002, 32'h0000_d073,
                32'h5a00_0128, 32'h0000_0080, 32'h0000_0007,
                32'h0000_0040, 32'h0000_004d);
            axi_write_act_incr_burst(ACT_BASE, 128, 3);
            stage_pair_weight_image(1, 128);
            for (scale_word_idx = 0; scale_word_idx < 16; scale_word_idx = scale_word_idx + 1)
                axi_write(SPU_PARAM_BASE + scale_word_idx * 16,
                          pack_stream_scale_word(1, 64, scale_word_idx), 16'hffff);

            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while (rd_word[0] !== 1'b1) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
                if (rd_word[2]) begin
                    fail("ACT burst boundary compute reported configuration error");
                    rd_word[0] = 1'b1;
                end
                if (timeout > 100000) begin
                    fail("ACT burst boundary compute did not finish");
                    rd_word[0] = 1'b1;
                end
            end

            axi_read(REG_DONE_JOB, rd_word);
            if (rd_word[31:0] !== 32'h0000_d073)
                fail("ACT burst boundary done_job_id was not committed");
            else
                pass_count = pass_count + 1;

            for (block_id = 0; block_id < 64; block_id = block_id + 1) begin
                axi_read(RESULT_BASE + (block_id / 4) * 16, rd_word);
                got = rd_word[32*(block_id % 4) +: 32];
                expected = golden_q8_block(0, block_id);
                if (got !== expected) begin
                    $display("[TB][FAIL] ACT burst boundary block=%0d got=%0d expected=%0d",
                             block_id, got, expected);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    // Protocol-3 is deliberately opt-in.  This is a true AXI/VPU/SPU path:
    // paired VPU raw results consume separate immutable PARAM weight scales
    // and SCRATCH activation scales.  Bank0 holds a two-row pair; bank1
    // exercises the odd tail.  The forced done pulse on bank0 creates the
    // drained-before-done interval in which a mode write must be rejected.
    task run_p3_axi_split_scale_case;
        integer beat;
        integer timeout;
        integer row;
        reg [31:0] rd32;
        reg [31:0] stream_out_before;
        reg [DATA_WIDTH-1:0] rd_word;
        reg signed [63:0] expected_q16;
        begin
            $display("[TB] P3 AXI split-scale paired/odd-tail case");
            axi_write32(REG_P3_STREAM_MODE, 32'h0000_0001, 4'hf);
            axi_read32(REG_P3_STREAM_MODE, rd32);
            if (rd32[0] !== 1'b1)
                fail("P3 mode enable was not accepted while quiescent");
            else
                pass_count = pass_count + 1;

            // Bank0: one two-row paired VPU transaction with scale=1.0 for
            // both rows and its single activation block.
            init_case_data(135, 2, 32);
            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h5033_0100), 16'h000f);
            axi_write(REG_ROWS, word32(2), 16'h000f);
            axi_write(REG_COLS, word32(32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(2), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 | VPU_MODE_P2_TWO_ROW), 16'h000f);
            for (beat = 0; beat < 2; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(2, 2);
            axi_write(SPU_PARAM_BASE, 128'h0000000000000000000000003c003c00, 16'hffff);
            axi_write(SPU_SCRATCH_BASE, 128'h00000000000000000000000000003c00, 16'hffff);

            // Hold the VPU end marker only; raw valid/data remain the actual
            // paired Matrix_Vector_Multiplication output.
            force dut.u_my_ip.u_axi4_mapping.core_spu_raw_done = 1'b0;
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);
            timeout = 0;
            rd_word = {DATA_WIDTH{1'b0}};
            while ((rd_word[0] !== 1'b1) && (timeout <= 100000)) begin
                axi_read(REG_STATUS, rd_word);
                timeout = timeout + 1;
            end
            if (rd_word[0] !== 1'b1)
                fail("P3 bank0 VPU core did not finish");

            timeout = 0;
            rd32 = 32'd0;
            while (((rd32[4] !== 1'b1) || (rd32[0] !== 1'b1)) && (timeout <= 100000)) begin
                axi_read32(REG_P3_STREAM_STATUS, rd32);
                timeout = timeout + 1;
            end
            if ((rd32[4] !== 1'b1) || (rd32[0] !== 1'b1))
                fail("P3 bank0 did not drain with its bank lock retained");
            else
                pass_count = pass_count + 1;

            // The bank is drained but no VPU end-of-stream has been observed.
            // The AXI mode register must remain P3 to avoid stranding the
            // lock or mixing P2 and P3 scale formats.
            axi_write32(REG_P3_STREAM_MODE, 32'h0000_0000, 4'hf);
            axi_read32(REG_P3_STREAM_MODE, rd32);
            if (rd32[0] !== 1'b1)
                fail("P3 mode disable was accepted before locked raw-done");
            else
                pass_count = pass_count + 1;

            force dut.u_my_ip.u_axi4_mapping.core_spu_raw_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            release dut.u_my_ip.u_axi4_mapping.core_spu_raw_done;
            timeout = 0;
            rd32 = 32'd0;
            while ((rd32[4] !== 1'b0) && (timeout <= 100000)) begin
                axi_read32(REG_P3_STREAM_STATUS, rd32);
                timeout = timeout + 1;
            end
            if (rd32[4] !== 1'b0)
                fail("P3 bank0 lock did not release after raw-done");
            else
                pass_count = pass_count + 1;

            for (row = 0; row < 2; row = row + 1) begin
                axi_read(SPU_OUT_BASE + row * 16, rd_word);
                expected_q16 = $signed(golden_q8_block(row, 0)) <<< 16;
                if ((rd_word[15:0] !== row[15:0]) ||
                    ($signed(rd_word[79:16]) !== expected_q16))
                    fail("P3 bank0 paired SPU_OUT Q16 result mismatch");
                else
                    pass_count = pass_count + 1;
            end

            // Bank1: one real odd-tail raw result.  Word 2048 is the first
            // dense P3 scale word in the second half of each 4096-word
            // PARAM/SCRATCH window; no address map or aperture changes.
            init_case_data(136, 1, 32);
            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0001), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h5033_0101), 16'h000f);
            axi_write(REG_ROWS, word32(1), 16'h000f);
            axi_write(REG_COLS, word32(32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(2), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8 | VPU_MODE_P2_TWO_ROW), 16'h000f);
            for (beat = 0; beat < 2; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);
            stage_pair_weight_image(1, 2);
            axi_write(SPU_PARAM_BASE + 40'd32768,
                      128'h00000000000000000000000000003c00, 16'hffff);
            axi_write(SPU_SCRATCH_BASE + 40'd32768,
                      128'h00000000000000000000000000003c00, 16'hffff);
            axi_read32(REG_SPU_STREAM_OUT, stream_out_before);
            axi_write(REG_CTRL, word32(32'h0000_0001), 16'h000f);

            timeout = 0;
            rd32 = stream_out_before;
            while ((rd32 < (stream_out_before + 32'd1)) && (timeout <= 100000)) begin
                axi_read32(REG_SPU_STREAM_OUT, rd32);
                timeout = timeout + 1;
            end
            if (rd32 < (stream_out_before + 32'd1))
                fail("P3 bank1 odd-tail result did not retire");
            else
                pass_count = pass_count + 1;
            timeout = 0;
            rd32 = 32'd1;
            while ((rd32[4] !== 1'b0) && (timeout <= 100000)) begin
                axi_read32(REG_P3_STREAM_STATUS, rd32);
                timeout = timeout + 1;
            end
            if (rd32[4] !== 1'b0)
                fail("P3 bank1 odd-tail lock did not release");
            else
                pass_count = pass_count + 1;
            axi_read(SPU_OUT_BASE, rd_word);
            expected_q16 = $signed(golden_q8_block(0, 0)) <<< 16;
            if ((rd_word[15:0] !== 16'd0) ||
                ($signed(rd_word[79:16]) !== expected_q16))
                fail("P3 bank1 odd-tail SPU_OUT Q16 result mismatch");
            else
                pass_count = pass_count + 1;

            axi_write32(REG_P3_STREAM_MODE, 32'h0000_0000, 4'hf);
            axi_read32(REG_P3_STREAM_MODE, rd32);
            if (rd32[0] !== 1'b0)
                fail("P3 mode disable was not accepted after release");
            else
                pass_count = pass_count + 1;
        end
    endtask

    initial begin
        resetn = 1'b0;
        awid = 0; awaddr = 0; awlen = 0; awsize = 0; awburst = 0; awlock = 0;
        awcache = 0; awprot = 0; awqos = 0; awregion = 0; awuser = 0; awvalid = 0;
        wdata = 0; wstrb = 0; wlast = 0; wuser = 0; wvalid = 0; bready = 1;
        arid = 0; araddr = 0; arlen = 0; arsize = 0; arburst = 0; arlock = 0;
        arcache = 0; arprot = 0; arqos = 0; arregion = 0; aruser = 0; arvalid = 0;
        rready = 0;
        pass_count = 0;
        fail_count = 0;
        cycle_count = 0;
        preload_watch_enable = 1'b0;
        preload_compute_write_overlap = 0;
        preload_busy_violation = 0;
        init_rd_word = 0;

        repeat (8) @(posedge clk);
        resetn = 1'b1;
        repeat (4) @(posedge clk);

        axi_read(REG_LIMITS, init_rd_word);
        if (init_rd_word[15:0] !== 16'd256)
            fail("REG_LIMITS max rows mismatch");
        if (init_rd_word[31:16] !== 16'd128)
            fail("REG_LIMITS max col beats mismatch");

        verify_reset_stream_quiescence();
        run_case(1, 3, 64, 4);
        verify_selftest_stream_handoff_ready();
        run_group_case(3, 5, 3);
        run_case(2, 2, 17, 0);
        run_mmio_lane_case();
        run_group_case(4, 2, MAX_GROUP_Q8_BLOCKS);
        run_int8_result_case(5, 5, 3, 3);
        run_int8_accum_groups_case(6, 4, 2, 3, 4);
        run_live_preload_isolation_case();
        run_pingpong_case();
        run_descriptor_commit_case();
        // Fill every SPU_OUT word through the canonical VPU->SPU Q16 path,
        // then drain it with the exact 4 KiB host DMA read shape.
        run_group_case(7, 256, 1);
        axi_read_spu_out_full_burst();
        // Protocol-2 pair-interleaved coverage: C=2/4/64/72/128, odd padded
        // tails, maximum row counts, both banks, and unequal-stride preload.
        // stage_pair_weight_image emits the required zero companion word for
        // every odd tail; the P2 result checks prove that no lane-1 result is
        // emitted for that padding row.
        run_group_case(97, 1, 1);
        run_group_case(98, 2, 2);
        run_group_case(99, 3, 32);
        run_pair_weight_port_ownership_case();
        run_group_case(132, 255, 36);
        run_group_case(133, 256, 64);
        run_p3_axi_split_scale_case();
        // P3 is opt-in only; prove the retained P2 packed-scale path works
        // again after P3 mode is released.
        run_group_case(137, 1, 1);
        run_act_burst_compute_case();

        if (pair_issue_desync_count != 0)
            fail("P2-v2 pair issue skew assertion failed");

        if (stream_stall_observed == 0)
            fail("ready/valid random-stall test did not observe a stalled raw token");

        $display("[TB] pass_count=%0d fail_count=%0d", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("[TB] AXI4-Full VPU TEST PASSED");
            $finish;
        end else begin
            $display("[TB] AXI4-Full VPU TEST FAILED");
            $fatal(1, "VPU testbench observed %0d failures", fail_count);
        end
    end

endmodule
