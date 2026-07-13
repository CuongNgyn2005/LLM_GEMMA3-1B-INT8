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
    localparam [ADDR_WIDTH-1:0] REG_CAPS      = 40'h0000_0090;
    localparam [ADDR_WIDTH-1:0] REG_BANK      = 40'h0000_0100;
    localparam [ADDR_WIDTH-1:0] REG_JOB_ID    = 40'h0000_0110;
    localparam [ADDR_WIDTH-1:0] REG_BANK_STAT = 40'h0000_0120;
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
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_ACCUM_LO = 40'h0000_01F0;
    localparam [ADDR_WIDTH-1:0] REG_SPU_STREAM_ACCUM_HI = 40'h0000_01F4;
    localparam [ADDR_WIDTH-1:0] ACT_BASE      = 40'h0001_0000;
    localparam [ADDR_WIDTH-1:0] WEIGHT_BASE   = 40'h0010_0000;
    localparam [ADDR_WIDTH-1:0] RESULT_BASE   = 40'h0020_0000;
    localparam [ADDR_WIDTH-1:0] SPU_OUT_BASE   = 40'h0034_0000;
    localparam [ADDR_WIDTH-1:0] SPU_PARAM_BASE = 40'h0038_0000;
    localparam [31:0] VPU_MODE_PACKED_Q8      = 32'h0000_0001;
    localparam [31:0] VPU_MODE_RESULT_INT8    = 32'h0000_0002;
    localparam [31:0] VPU_MODE_ACCUM_CLEAR    = 32'h0000_0004;
    localparam [31:0] VPU_MODE_RESULT_EMIT    = 32'h0000_0008;
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
    reg [DATA_WIDTH-1:0] init_rd_word;

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
        .MAX_GROUP_Q8_BLOCKS    (MAX_GROUP_Q8_BLOCKS)
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

    function [DATA_WIDTH-1:0] word32;
        input [31:0] value;
        begin
            word32 = {DATA_WIDTH{1'b0}};
            word32[31:0] = value;
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

            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < current_col_beats; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * current_col_beats) + beat) * 16,
                              pack_weight(row, beat), 16'hffff);
            end

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
            if (rd_word[15:8] !== 8'd64)
                fail("REG_CAPS max_group_q8_blocks was not 64");

            axi_write(REG_CTRL, word32(32'h0000_0002), 16'h000f);
            axi_write(REG_BANK, word32(32'h0000_0000), 16'h000f);
            axi_write(REG_JOB_ID, word32(32'h1000 + case_id), 16'h000f);
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(group_blocks * 32), 16'h000f);
            axi_write(REG_COL_BEATS, word32(group_blocks * 2), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);
            axi_write(REG_MODE, word32(VPU_MODE_PACKED_Q8), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);

            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < current_col_beats; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * current_col_beats) + beat) * 16,
                              pack_weight(row, beat), 16'hffff);
            end

            for (scale_word_idx = 0;
                 scale_word_idx < ((rows * group_blocks + 3) / 4);
                 scale_word_idx = scale_word_idx + 1)
                axi_write(SPU_PARAM_BASE + scale_word_idx * 16,
                          pack_stream_scale_word(rows, group_blocks, scale_word_idx),
                          16'hffff);

            axi_read(REG_SPU_STREAM_COUNT, rd_word);
            stream_count_before = rd_word[31:0];
            axi_read(REG_SPU_STREAM_DONE, rd_word);
            stream_done_before = rd_word[31:0];
            axi_read(REG_SPU_STREAM_DROP, rd_word);
            stream_drop_before = rd_word[31:0];
            axi_read(REG_SPU_STREAM_OUT, rd_word);
            stream_out_before = rd_word[31:0];
            axi_read(REG_SPU_STREAM_ERROR, rd_word);
            stream_error_before = rd_word[31:0];

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
                if (timeout > 1000) begin
                    fail("Packed q8 core did not finish");
                    rd_word[0] = 1'b1;
                end
            end
            done_cycle = cycle_count;

            timeout = 0;
            stream_out_after = stream_out_before;
            while (stream_out_after < (stream_out_before + rows)) begin
                axi_read(REG_SPU_STREAM_OUT, rd_word);
                stream_out_after = rd_word[31:0];
                timeout = timeout + 1;
                if (timeout > 1000) begin
                    fail("SPU raw stream accumulator did not emit all rows");
                    stream_out_after = stream_out_before + rows;
                end
            end

            axi_read(REG_SPU_STREAM_COUNT, rd_word);
            stream_count_after = rd_word[31:0];
            axi_read(REG_SPU_STREAM_DONE, rd_word);
            stream_done_after = rd_word[31:0];
            axi_read(REG_SPU_STREAM_DROP, rd_word);
            stream_drop_after = rd_word[31:0];
            axi_read(REG_SPU_STREAM_OUT, rd_word);
            stream_out_after = rd_word[31:0];
            axi_read(REG_SPU_STREAM_ERROR, rd_word);
            stream_error_after = rd_word[31:0];

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

            axi_read(REG_SPU_STREAM_LAST_META, rd_word);
            if ((rd_word[30] !== 1'b1) ||
                (rd_word[31] !== (group_blocks == 1)) ||
                (rd_word[29:16] != (group_blocks - 1)) ||
                (rd_word[15:0] != (rows - 1)))
                fail("SPU raw stream last metadata mismatch");
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

            axi_read(REG_SPU_STREAM_ACCUM_HI, rd_word);
            if (rd_word[31:0] !== expected_accum[63:32])
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

            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < current_col_beats; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * current_col_beats) + beat) * 16,
                              pack_weight(row, beat), 16'hffff);
            end

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
            for (row = 0; row < rows; row = row + 1)
                for (beat = 0; beat < first_blocks * 2; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * (first_blocks * 2)) + beat) * 16,
                              pack_weight_from(row, 0, beat), 16'hffff);

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
            for (row = 0; row < rows; row = row + 1)
                for (beat = 0; beat < second_blocks * 2; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * (second_blocks * 2)) + beat) * 16,
                              pack_weight_from(row, first_blocks * 2, beat), 16'hffff);

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
            for (row = 0; row < 2; row = row + 1)
                for (beat = 0; beat < current_col_beats; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * current_col_beats) + beat) * 16,
                              pack_weight(row, beat), 16'hffff);

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
                if (timeout > 1000) begin
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
            for (row = 0; row < 2; row = row + 1)
                for (beat = 0; beat < current_col_beats; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * current_col_beats) + beat) * 16,
                              pack_weight(row, beat), 16'hffff);

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
        init_rd_word = 0;

        repeat (8) @(posedge clk);
        resetn = 1'b1;
        repeat (4) @(posedge clk);

        axi_read(REG_LIMITS, init_rd_word);
        if (init_rd_word[15:0] !== 16'd256)
            fail("REG_LIMITS max rows mismatch");
        if (init_rd_word[31:16] !== 16'd128)
            fail("REG_LIMITS max col beats mismatch");

        run_case(1, 3, 64, 4);
        run_case(2, 2, 17, 0);
        run_group_case(3, 5, 3);
        run_group_case(4, 2, MAX_GROUP_Q8_BLOCKS);
        run_int8_result_case(5, 5, 3, 3);
        run_int8_accum_groups_case(6, 4, 2, 3, 4);
        run_pingpong_case();

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
