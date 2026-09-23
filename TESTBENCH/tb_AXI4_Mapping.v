`ifndef TB_AXI4_MAPPING_V
`define TB_AXI4_MAPPING_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_AXI4_Mapping #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    localparam AXI_ADDR_WIDTH = 40;
    localparam VPU_BASE_ADDR = 40'h00A0_0000_00;
    localparam ENABLE_BASE_TRANSLATION = 1;
    localparam NUM_LANES = 16;
    localparam ACT_WIDTH = 8;
    localparam WEIGHT_WIDTH = 8;
    localparam ACC_WIDTH = 32;
    localparam SCALE_WIDTH = 16;
    localparam SCALE_FRAC_BITS = 15;
    localparam RESULT_FIFO_DEPTH = 8;
    localparam MAX_ROWS = 256;
    localparam MAX_COL_BEATS = 128;
    localparam MAX_GROUP_Q8_BLOCKS = 64;
    localparam SPU_WORD_DEPTH = 4096;
    localparam SPU_STREAM_TEST_STALL_ENABLE = 0;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = '0;
    reg map_wr_en = '0;
    reg [AXI_ADDR_WIDTH-1:0]             map_wr_addr = '0;
    reg [AXI_DATA_WIDTH-1:0]             map_wr_data = '0;
    reg [(AXI_DATA_WIDTH/8)-1:0]         map_wr_strb = '0;
    reg map_rd_en = '0;
    reg [AXI_ADDR_WIDTH-1:0]             map_rd_addr = '0;
    wire map_rd_ready;
    wire [AXI_DATA_WIDTH-1:0]             map_rd_data;
    wire map_rd_valid;
    wire map_rd_error;
    integer checks = 0;
    AXI4_Mapping dut (
        .clk(clk),
        .resetn(resetn),
        .map_wr_en(map_wr_en),
        .map_wr_addr(map_wr_addr),
        .map_wr_data(map_wr_data),
        .map_wr_strb(map_wr_strb),
        .map_rd_en(map_rd_en),
        .map_rd_addr(map_rd_addr),
        .map_rd_ready(map_rd_ready),
        .map_rd_data(map_rd_data),
        .map_rd_valid(map_rd_valid),
        .map_rd_error(map_rd_error)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_AXI4_Mapping: %0s", message);
            checks = checks + 1;
        end
    endtask
    task reset_dut;
        begin
            @(negedge tb_clk);
            resetn = 0;
            repeat (4) @(negedge tb_clk);
            resetn = 1;
            repeat (2) @(negedge tb_clk);
        end
    endtask
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_AXI4_Mapping: watchdog timeout");
    end
    task wr;
        input [39:0] addr;
        input [127:0] data;
        input [15:0] strobe;
        begin
            @(negedge tb_clk); map_wr_en=1; map_wr_addr=addr; map_wr_data=data; map_wr_strb=strobe;
            @(negedge tb_clk); map_wr_en=0;
            repeat(3) @(negedge tb_clk);
        end
    endtask
    task rd;
        input [39:0] addr;
        input [127:0] expected;
        input expected_error;
        integer t;
        begin
            @(negedge tb_clk); map_rd_addr=addr;
            #1;
            t=0;
            while(!map_rd_ready && t<100) begin @(negedge tb_clk); t=t+1; end
            check(map_rd_ready,"read admission");
            map_rd_en=1;
            @(negedge tb_clk); map_rd_en=0;
            t=0;
            while(!map_rd_valid && t<100) begin @(negedge tb_clk); t=t+1; end
            check(map_rd_valid && map_rd_error===expected_error,"read response/error");
            if(!expected_error) check(map_rd_data===expected,"read data");
        end
    endtask
    initial begin
        reset_dut();
        rd(40'hf4,128'h00000000_00000000_00000002_00000000,0);
        wr(40'h20,128'd9,16'h000f); rd(40'h20,128'd9,0);
        wr(40'h20,128'd5,16'h0001); rd(40'h20,128'd5,0);
        wr(40'h340000,128'hfeedface_81234567_89abcdef_01234567,16'hffff);
        rd(40'ha0340000,128'hfeedface_81234567_89abcdef_01234567,0);
        rd(40'h350000,0,1);
        rd(40'h100000,0,1);
        rd(40'h400000,0,1);
        rd(40'h20,128'd5,0);
        completed = 1;
        $display("[TB][PASS] tb_AXI4_Mapping checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
