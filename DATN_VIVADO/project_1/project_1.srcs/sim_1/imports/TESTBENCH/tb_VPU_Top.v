`timescale 1ns/1ps

module tb_VPU_Top;

    localparam integer ID_WIDTH      = 1;
    localparam integer DATA_WIDTH    = 128;
    localparam integer ADDR_WIDTH    = 40;
    localparam integer NUM_LANES     = 16;
    localparam integer MAX_ROWS      = 8;
    localparam integer MAX_COL_BEATS = 8;
    localparam integer MAX_TEST_COLS = NUM_LANES * MAX_COL_BEATS;

    localparam [ADDR_WIDTH-1:0] REG_CTRL      = 40'h0000_0000;
    localparam [ADDR_WIDTH-1:0] REG_STATUS    = 40'h0000_0010;
    localparam [ADDR_WIDTH-1:0] REG_ROWS      = 40'h0000_0020;
    localparam [ADDR_WIDTH-1:0] REG_COLS      = 40'h0000_0030;
    localparam [ADDR_WIDTH-1:0] REG_COL_BEATS = 40'h0000_0040;
    localparam [ADDR_WIDTH-1:0] REG_SCALE     = 40'h0000_0050;
    localparam [ADDR_WIDTH-1:0] ACT_BASE      = 40'h0001_0000;
    localparam [ADDR_WIDTH-1:0] WEIGHT_BASE   = 40'h0010_0000;
    localparam [ADDR_WIDTH-1:0] RESULT_BASE   = 40'h0020_0000;

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
        .MAX_COL_BEATS          (MAX_COL_BEATS)
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
            wdata    <= data;
            wstrb    <= strb;
            wlast    <= 1'b1;
            wuser    <= 1'b0;
            wvalid   <= 1'b1;
            bready   <= 1'b1;

            timeout = 0;
            while (awvalid || wvalid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("AXI write handshake timeout");
                    awvalid <= 1'b0;
                    wvalid  <= 1'b0;
                end
                if (awvalid && awready)
                    awvalid <= 1'b0;
                if (wvalid && wready)
                    wvalid <= 1'b0;
            end

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
            bready <= 1'b0;
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
            axi_write(REG_ROWS, word32(rows), 16'h000f);
            axi_write(REG_COLS, word32(cols), 16'h000f);
            axi_write(REG_COL_BEATS, word32(explicit_col_beats), 16'h000f);
            axi_write(REG_SCALE, word32(32'h0000_3c00), 16'h000f);

            for (beat = 0; beat < current_col_beats; beat = beat + 1)
                axi_write(ACT_BASE + beat * 16, pack_activation(beat), 16'hffff);

            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < current_col_beats; beat = beat + 1)
                    axi_write(WEIGHT_BASE + ((row * MAX_COL_BEATS) + beat) * 16,
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

    initial begin
        resetn = 1'b0;
        awid = 0; awaddr = 0; awlen = 0; awsize = 0; awburst = 0; awlock = 0;
        awcache = 0; awprot = 0; awqos = 0; awregion = 0; awuser = 0; awvalid = 0;
        wdata = 0; wstrb = 0; wlast = 0; wuser = 0; wvalid = 0; bready = 0;
        arid = 0; araddr = 0; arlen = 0; arsize = 0; arburst = 0; arlock = 0;
        arcache = 0; arprot = 0; arqos = 0; arregion = 0; aruser = 0; arvalid = 0;
        rready = 0;
        pass_count = 0;
        fail_count = 0;
        cycle_count = 0;

        repeat (8) @(posedge clk);
        resetn = 1'b1;
        repeat (4) @(posedge clk);

        run_case(1, 3, 64, 4);
        run_case(2, 2, 17, 0);

        $display("[TB] pass_count=%0d fail_count=%0d", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("[TB] AXI4-Full VPU TEST PASSED");
            $finish;
        end else begin
            $display("[TB] AXI4-Full VPU TEST FAILED");
            $finish;
        end
    end

endmodule
