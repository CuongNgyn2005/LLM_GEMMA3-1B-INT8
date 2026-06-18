`timescale 1ns/1ps

module tb_vpu_dma_axis;
    localparam integer ID_WIDTH      = 1;
    localparam integer DATA_WIDTH    = 128;
    localparam integer ADDR_WIDTH    = 40;
    localparam integer NUM_LANES     = 16;
    localparam integer MAX_ROWS      = 256;
    localparam integer MAX_COL_BEATS = 8;
    localparam integer Q8_BLOCK_BEATS = 2;

    localparam [31:0] DMA_FRAME_MAGIC  = 32'h3341_4d44;
    localparam [7:0]  DMA_FRAME_CONFIG = 8'd1;
    localparam [7:0]  DMA_FRAME_ACT    = 8'd2;
    localparam [7:0]  DMA_FRAME_WEIGHT = 8'd3;
    localparam [7:0]  DMA_FRAME_START  = 8'd4;
    localparam [7:0]  DMA_FRAME_RESULT = 8'd5;
    localparam [7:0]  MODE_SCALAR      = 8'd0;
    localparam [7:0]  MODE_PACKED_Q8   = 8'd1;

    reg clk;
    reg resetn;

    wire [ID_WIDTH-1:0]       s00_axi_awid    = {ID_WIDTH{1'b0}};
    wire [ADDR_WIDTH-1:0]     s00_axi_awaddr  = {ADDR_WIDTH{1'b0}};
    wire [7:0]                s00_axi_awlen   = 8'd0;
    wire [2:0]                s00_axi_awsize  = 3'd4;
    wire [1:0]                s00_axi_awburst = 2'b01;
    wire                      s00_axi_awlock  = 1'b0;
    wire [3:0]                s00_axi_awcache = 4'd0;
    wire [2:0]                s00_axi_awprot  = 3'd0;
    wire [3:0]                s00_axi_awqos   = 4'd0;
    wire [3:0]                s00_axi_awregion = 4'd0;
    wire                      s00_axi_awuser  = 1'b0;
    wire                      s00_axi_awvalid = 1'b0;
    wire                      s00_axi_awready;

    wire [DATA_WIDTH-1:0]     s00_axi_wdata   = {DATA_WIDTH{1'b0}};
    wire [(DATA_WIDTH/8)-1:0] s00_axi_wstrb   = {(DATA_WIDTH/8){1'b0}};
    wire                      s00_axi_wlast   = 1'b0;
    wire                      s00_axi_wuser   = 1'b0;
    wire                      s00_axi_wvalid  = 1'b0;
    wire                      s00_axi_wready;

    wire [ID_WIDTH-1:0]       s00_axi_bid;
    wire [1:0]                s00_axi_bresp;
    wire                      s00_axi_buser;
    wire                      s00_axi_bvalid;
    wire                      s00_axi_bready  = 1'b1;

    wire [ID_WIDTH-1:0]       s00_axi_arid    = {ID_WIDTH{1'b0}};
    wire [ADDR_WIDTH-1:0]     s00_axi_araddr  = {ADDR_WIDTH{1'b0}};
    wire [7:0]                s00_axi_arlen   = 8'd0;
    wire [2:0]                s00_axi_arsize  = 3'd4;
    wire [1:0]                s00_axi_arburst = 2'b01;
    wire                      s00_axi_arlock  = 1'b0;
    wire [3:0]                s00_axi_arcache = 4'd0;
    wire [2:0]                s00_axi_arprot  = 3'd0;
    wire [3:0]                s00_axi_arqos   = 4'd0;
    wire [3:0]                s00_axi_arregion = 4'd0;
    wire                      s00_axi_aruser  = 1'b0;
    wire                      s00_axi_arvalid = 1'b0;
    wire                      s00_axi_arready;

    wire [ID_WIDTH-1:0]       s00_axi_rid;
    wire [DATA_WIDTH-1:0]     s00_axi_rdata;
    wire [1:0]                s00_axi_rresp;
    wire                      s00_axi_rlast;
    wire                      s00_axi_ruser;
    wire                      s00_axi_rvalid;
    wire                      s00_axi_rready  = 1'b1;

    reg  [DATA_WIDTH-1:0]     s_axis_dma_tdata;
    reg  [(DATA_WIDTH/8)-1:0] s_axis_dma_tkeep;
    reg                       s_axis_dma_tvalid;
    wire                      s_axis_dma_tready;
    reg                       s_axis_dma_tlast;

    wire [DATA_WIDTH-1:0]     m_axis_dma_tdata;
    wire [(DATA_WIDTH/8)-1:0] m_axis_dma_tkeep;
    wire                      m_axis_dma_tvalid;
    reg                       m_axis_dma_tready;
    wire                      m_axis_dma_tlast;

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
        .DMA_AXIS_DATA_WIDTH    (DATA_WIDTH)
    ) dut (
        .s00_axi_aclk       (clk),
        .s00_axi_aresetn    (resetn),
        .s00_axi_awid       (s00_axi_awid),
        .s00_axi_awaddr     (s00_axi_awaddr),
        .s00_axi_awlen      (s00_axi_awlen),
        .s00_axi_awsize     (s00_axi_awsize),
        .s00_axi_awburst    (s00_axi_awburst),
        .s00_axi_awlock     (s00_axi_awlock),
        .s00_axi_awcache    (s00_axi_awcache),
        .s00_axi_awprot     (s00_axi_awprot),
        .s00_axi_awqos      (s00_axi_awqos),
        .s00_axi_awregion   (s00_axi_awregion),
        .s00_axi_awuser     (s00_axi_awuser),
        .s00_axi_awvalid    (s00_axi_awvalid),
        .s00_axi_awready    (s00_axi_awready),
        .s00_axi_wdata      (s00_axi_wdata),
        .s00_axi_wstrb      (s00_axi_wstrb),
        .s00_axi_wlast      (s00_axi_wlast),
        .s00_axi_wuser      (s00_axi_wuser),
        .s00_axi_wvalid     (s00_axi_wvalid),
        .s00_axi_wready     (s00_axi_wready),
        .s00_axi_bid        (s00_axi_bid),
        .s00_axi_bresp      (s00_axi_bresp),
        .s00_axi_buser      (s00_axi_buser),
        .s00_axi_bvalid     (s00_axi_bvalid),
        .s00_axi_bready     (s00_axi_bready),
        .s00_axi_arid       (s00_axi_arid),
        .s00_axi_araddr     (s00_axi_araddr),
        .s00_axi_arlen      (s00_axi_arlen),
        .s00_axi_arsize     (s00_axi_arsize),
        .s00_axi_arburst    (s00_axi_arburst),
        .s00_axi_arlock     (s00_axi_arlock),
        .s00_axi_arcache    (s00_axi_arcache),
        .s00_axi_arprot     (s00_axi_arprot),
        .s00_axi_arqos      (s00_axi_arqos),
        .s00_axi_arregion   (s00_axi_arregion),
        .s00_axi_aruser     (s00_axi_aruser),
        .s00_axi_arvalid    (s00_axi_arvalid),
        .s00_axi_arready    (s00_axi_arready),
        .s00_axi_rid        (s00_axi_rid),
        .s00_axi_rdata      (s00_axi_rdata),
        .s00_axi_rresp      (s00_axi_rresp),
        .s00_axi_rlast      (s00_axi_rlast),
        .s00_axi_ruser      (s00_axi_ruser),
        .s00_axi_rvalid     (s00_axi_rvalid),
        .s00_axi_rready     (s00_axi_rready),
        .s_axis_dma_tdata   (s_axis_dma_tdata),
        .s_axis_dma_tkeep   (s_axis_dma_tkeep),
        .s_axis_dma_tvalid  (s_axis_dma_tvalid),
        .s_axis_dma_tready  (s_axis_dma_tready),
        .s_axis_dma_tlast   (s_axis_dma_tlast),
        .m_axis_dma_tdata   (m_axis_dma_tdata),
        .m_axis_dma_tkeep   (m_axis_dma_tkeep),
        .m_axis_dma_tvalid  (m_axis_dma_tvalid),
        .m_axis_dma_tready  (m_axis_dma_tready),
        .m_axis_dma_tlast   (m_axis_dma_tlast)
    );

    reg signed [7:0] act_elem [0:MAX_COL_BEATS*NUM_LANES-1];
    reg signed [7:0] weight_elem [0:MAX_ROWS*MAX_COL_BEATS*NUM_LANES-1];
    reg signed [31:0] expected [0:255];
    reg signed [31:0] received [0:255];

    integer pass_count;
    integer fail_count;
    integer i;
    integer j;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function [DATA_WIDTH-1:0] dma_header;
        input [7:0] typ;
        input [7:0] mode;
        input [15:0] rows;
        input [15:0] col_beats;
        input [15:0] tile_id;
        input [31:0] payload_words;
        begin
            dma_header = {
                payload_words,
                tile_id,
                col_beats,
                rows,
                mode,
                typ,
                DMA_FRAME_MAGIC
            };
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_act_word;
        input integer beat;
        integer lane;
        begin
            pack_act_word = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                pack_act_word[8*lane +: 8] = act_elem[beat*NUM_LANES + lane];
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_weight_word;
        input integer row;
        input integer beat;
        integer lane;
        integer idx;
        begin
            pack_weight_word = {DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                idx = (row*MAX_COL_BEATS + beat)*NUM_LANES + lane;
                pack_weight_word[8*lane +: 8] = weight_elem[idx];
            end
        end
    endfunction

    function signed [31:0] golden_scalar;
        input integer row;
        input integer col_beats;
        integer beat;
        integer lane;
        integer aidx;
        integer widx;
        reg signed [31:0] acc;
        begin
            acc = 32'sd0;
            for (beat = 0; beat < col_beats; beat = beat + 1) begin
                for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                    aidx = beat*NUM_LANES + lane;
                    widx = (row*MAX_COL_BEATS + beat)*NUM_LANES + lane;
                    acc = acc + act_elem[aidx] * weight_elem[widx];
                end
            end
            golden_scalar = acc;
        end
    endfunction

    function signed [31:0] golden_q8_block;
        input integer row;
        input integer block_id;
        integer beat;
        integer lane;
        integer aidx;
        integer widx;
        reg signed [31:0] acc;
        begin
            acc = 32'sd0;
            for (beat = 0; beat < Q8_BLOCK_BEATS; beat = beat + 1) begin
                for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                    aidx = (block_id*Q8_BLOCK_BEATS + beat)*NUM_LANES + lane;
                    widx = (row*MAX_COL_BEATS + block_id*Q8_BLOCK_BEATS + beat)*NUM_LANES + lane;
                    acc = acc + act_elem[aidx] * weight_elem[widx];
                end
            end
            golden_q8_block = acc;
        end
    endfunction

    task record_fail;
        input [1023:0] message;
        begin
            fail_count = fail_count + 1;
            $display("[TB][FAIL] %0s", message);
        end
    endtask

    task record_pass;
        input [1023:0] message;
        begin
            pass_count = pass_count + 1;
            $display("[TB][PASS] %0s", message);
        end
    endtask

    task axis_send_word;
        input [DATA_WIDTH-1:0] data;
        input last;
        input integer gap_cycles;
        integer g;
        integer timeout;
        begin
            for (g = 0; g < gap_cycles; g = g + 1) begin
                s_axis_dma_tvalid <= 1'b0;
                s_axis_dma_tlast  <= 1'b0;
                @(posedge clk);
            end
            s_axis_dma_tdata  <= data;
            s_axis_dma_tkeep  <= {(DATA_WIDTH/8){1'b1}};
            s_axis_dma_tlast  <= last;
            s_axis_dma_tvalid <= 1'b1;
            timeout = 0;
            while (!s_axis_dma_tready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 1000) begin
                    record_fail("AXIS input ready timeout");
                    timeout = 0;
                end
            end
            @(posedge clk);
            s_axis_dma_tvalid <= 1'b0;
            s_axis_dma_tlast  <= 1'b0;
            s_axis_dma_tdata  <= {DATA_WIDTH{1'b0}};
        end
    endtask

    task axis_recv_word;
        output [DATA_WIDTH-1:0] data;
        output last;
        input integer stall_cycles;
        integer g;
        integer timeout;
        begin
            for (g = 0; g < stall_cycles; g = g + 1) begin
                m_axis_dma_tready <= 1'b0;
                @(posedge clk);
            end
            m_axis_dma_tready <= 1'b1;
            timeout = 0;
            while (!m_axis_dma_tvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 5000) begin
                    record_fail("AXIS output valid timeout");
                    timeout = 0;
                end
            end
            data = m_axis_dma_tdata;
            last = m_axis_dma_tlast;
            @(posedge clk);
            m_axis_dma_tready <= 1'b0;
        end
    endtask

    task clear_arrays;
        integer idx;
        begin
            for (idx = 0; idx < MAX_COL_BEATS*NUM_LANES; idx = idx + 1)
                act_elem[idx] = 0;
            for (idx = 0; idx < MAX_ROWS*MAX_COL_BEATS*NUM_LANES; idx = idx + 1)
                weight_elem[idx] = 0;
            for (idx = 0; idx < 256; idx = idx + 1) begin
                expected[idx] = 0;
                received[idx] = 0;
            end
        end
    endtask

    task run_dma_case;
        input [1023:0] name;
        input integer rows;
        input integer group_blocks;
        input [7:0] mode;
        input integer tile_id;
        input integer input_gap;
        input integer output_stall;
        integer col_beats;
        integer payload_values;
        integer result_words;
        integer row;
        integer beat;
        integer word;
        integer lane;
        reg [DATA_WIDTH-1:0] rx;
        reg rx_last;
        begin
            col_beats = (mode == MODE_PACKED_Q8) ? group_blocks*Q8_BLOCK_BEATS : group_blocks*Q8_BLOCK_BEATS;
            payload_values = (mode == MODE_PACKED_Q8) ? rows*group_blocks : rows;
            result_words = (payload_values + 3) / 4;

            for (row = 0; row < rows; row = row + 1) begin
                if (mode == MODE_PACKED_Q8) begin
                    for (beat = 0; beat < group_blocks; beat = beat + 1)
                        expected[row*group_blocks + beat] = golden_q8_block(row, beat);
                end else begin
                    expected[row] = golden_scalar(row, col_beats);
                end
            end

            axis_send_word(dma_header(DMA_FRAME_CONFIG, mode, rows[15:0], col_beats[15:0], tile_id[15:0], 32'd0), 1'b0, input_gap);
            axis_send_word(dma_header(DMA_FRAME_WEIGHT, mode, rows[15:0], col_beats[15:0], tile_id[15:0], rows*col_beats), 1'b0, input_gap);
            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < col_beats; beat = beat + 1)
                    axis_send_word(pack_weight_word(row, beat), 1'b0, input_gap);
            end
            axis_send_word(dma_header(DMA_FRAME_ACT, mode, rows[15:0], col_beats[15:0], tile_id[15:0], col_beats), 1'b0, input_gap);
            for (beat = 0; beat < col_beats; beat = beat + 1)
                axis_send_word(pack_act_word(beat), 1'b0, input_gap);
            axis_send_word(dma_header(DMA_FRAME_START, mode, rows[15:0], col_beats[15:0], tile_id[15:0], 32'd0), 1'b1, input_gap);

            axis_recv_word(rx, rx_last, output_stall);
            if (rx[31:0] != DMA_FRAME_MAGIC ||
                rx[39:32] != DMA_FRAME_RESULT ||
                rx[47:40] != mode ||
                rx[63:48] != rows[15:0] ||
                rx[79:64] != col_beats[15:0] ||
                rx[95:80] != tile_id[15:0] ||
                rx[127:96] != result_words[31:0]) begin
                record_fail("RESULT header mismatch");
            end
            if (rx_last && result_words != 0)
                record_fail("RESULT header asserted tlast too early");

            for (word = 0; word < result_words; word = word + 1) begin
                axis_recv_word(rx, rx_last, (word == 0) ? output_stall : 0);
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (word*4 + lane < payload_values)
                        received[word*4 + lane] = rx[32*lane +: 32];
                end
                if ((word == result_words - 1) && !rx_last)
                    record_fail("RESULT payload missing final tlast");
                if ((word != result_words - 1) && rx_last)
                    record_fail("RESULT payload asserted early tlast");
            end

            for (i = 0; i < payload_values; i = i + 1) begin
                if (received[i] !== expected[i]) begin
                    $display("[TB][DETAIL] %0s idx=%0d got=%0d expected=%0d", name, i, received[i], expected[i]);
                    record_fail("result value mismatch");
                end
            end
            if (fail_count == 0)
                record_pass(name);
        end
    endtask

    task setup_basic_ones;
        begin
            clear_arrays();
            for (i = 0; i < 32; i = i + 1) begin
                act_elem[i] = 1;
                weight_elem[i] = 1;
            end
        end
    endtask

    task setup_packed_self_test;
        begin
            clear_arrays();
            for (i = 0; i < 32; i = i + 1) begin
                act_elem[i]      = 1;
                act_elem[32+i]   = 2;
                weight_elem[i]   = 1;
                weight_elem[32+i] = 1;
                weight_elem[(MAX_COL_BEATS*NUM_LANES)+i] = -1;
                weight_elem[(MAX_COL_BEATS*NUM_LANES)+32+i] = 3;
            end
        end
    endtask

    task setup_pattern;
        input integer rows;
        input integer col_beats;
        integer row;
        integer beat;
        integer lane;
        integer idx;
        begin
            clear_arrays();
            for (beat = 0; beat < col_beats; beat = beat + 1) begin
                for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                    idx = beat*NUM_LANES + lane;
                    act_elem[idx] = ((idx % 7) - 3);
                end
            end
            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < col_beats; beat = beat + 1) begin
                    for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                        idx = (row*MAX_COL_BEATS + beat)*NUM_LANES + lane;
                        weight_elem[idx] = (((row + 2*beat + lane) % 9) - 4);
                    end
                end
            end
        end
    endtask

    task run_large_tiling_case;
        integer rows;
        integer total_blocks;
        integer tile_blocks;
        integer block0;
        integer row;
        integer gb;
        reg signed [31:0] accum [0:7];
        begin
            rows = 2;
            total_blocks = 6;
            clear_arrays();
            for (i = 0; i < 8; i = i + 1)
                accum[i] = 0;

            block0 = 0;
            while (block0 < total_blocks) begin
                tile_blocks = (total_blocks - block0 > 4) ? 4 : (total_blocks - block0);
                setup_pattern(rows, tile_blocks*Q8_BLOCK_BEATS);
                run_dma_case("large tiling sub-tile", rows, tile_blocks, MODE_PACKED_Q8, 16 + block0, 1, 2);
                for (row = 0; row < rows; row = row + 1) begin
                    for (gb = 0; gb < tile_blocks; gb = gb + 1)
                        accum[row] = accum[row] + received[row*tile_blocks + gb];
                end
                block0 = block0 + tile_blocks;
            end

            if (accum[0] === 32'sdx || accum[1] === 32'sdx)
                record_fail("large tiling accumulation produced X");
            else
                record_pass("large matrix tiling behavioral accumulation");
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;
        s_axis_dma_tdata = {DATA_WIDTH{1'b0}};
        s_axis_dma_tkeep = {(DATA_WIDTH/8){1'b0}};
        s_axis_dma_tvalid = 1'b0;
        s_axis_dma_tlast = 1'b0;
        m_axis_dma_tready = 1'b0;
        resetn = 1'b0;
        repeat (12) @(posedge clk);
        resetn = 1'b1;
        repeat (8) @(posedge clk);

        $display("[TB] DMA AXIS VPU behavioral test started");

        setup_basic_ones();
        run_dma_case("DMA basic CONFIG/ACT/WEIGHT/START/RESULT", 1, 1, MODE_SCALAR, 0, 0, 0);

        setup_packed_self_test();
        run_dma_case("packed Q8 self-test [32,64,-32,192]", 2, 2, MODE_PACKED_Q8, 1, 0, 0);

        setup_pattern(3, 4);
        run_dma_case("multi-row packed mode", 3, 2, MODE_PACKED_Q8, 2, 0, 0);

        setup_pattern(2, 8);
        run_dma_case("multi-group-block packed mode", 2, 4, MODE_PACKED_Q8, 3, 0, 0);

        setup_pattern(2, 4);
        run_dma_case("AXIS input/output backpressure", 2, 2, MODE_PACKED_Q8, 4, 2, 4);

        run_large_tiling_case();

        $display("[TB] Final pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("[TB][PASS] tb_vpu_dma_axis completed successfully");
            $finish;
        end else begin
            $display("[TB][FAIL] tb_vpu_dma_axis detected failures");
            $fatal;
        end
    end
endmodule
