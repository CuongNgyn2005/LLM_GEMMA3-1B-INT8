`ifndef TB_MY_IP_V
`define TB_MY_IP_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_MY_IP #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam C_S00_AXI_ID_WIDTH = 1;
    localparam C_S00_AXI_DATA_WIDTH = 128;
    localparam C_S00_AXI_ADDR_WIDTH = 40;
    localparam C_S00_AXI_AWUSER_WIDTH = 1;
    localparam C_S00_AXI_ARUSER_WIDTH = 1;
    localparam C_S00_AXI_WUSER_WIDTH = 1;
    localparam C_S00_AXI_RUSER_WIDTH = 1;
    localparam C_S00_AXI_BUSER_WIDTH = 1;
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
    localparam SPU_STREAM_TEST_STALL_ENABLE = 0;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire s00_axi_aclk = tb_clk;
    reg s00_axi_aresetn = '0;
    reg [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_awid = '0;
    reg [C_S00_AXI_ADDR_WIDTH-1:0]       s00_axi_awaddr = '0;
    reg [7:0]                            s00_axi_awlen = '0;
    reg [2:0]                            s00_axi_awsize = '0;
    reg [1:0]                            s00_axi_awburst = '0;
    reg s00_axi_awlock = '0;
    reg [3:0]                            s00_axi_awcache = '0;
    reg [2:0]                            s00_axi_awprot = '0;
    reg [3:0]                            s00_axi_awqos = '0;
    reg [3:0]                            s00_axi_awregion = '0;
    reg [C_S00_AXI_AWUSER_WIDTH-1:0]     s00_axi_awuser = '0;
    reg s00_axi_awvalid = '0;
    wire s00_axi_awready;
    reg [C_S00_AXI_DATA_WIDTH-1:0]       s00_axi_wdata = '0;
    reg [(C_S00_AXI_DATA_WIDTH/8)-1:0]   s00_axi_wstrb = '0;
    reg s00_axi_wlast = '0;
    reg [C_S00_AXI_WUSER_WIDTH-1:0]      s00_axi_wuser = '0;
    reg s00_axi_wvalid = '0;
    wire s00_axi_wready;
    wire [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_bid;
    wire [1:0]                            s00_axi_bresp;
    wire [C_S00_AXI_BUSER_WIDTH-1:0]      s00_axi_buser;
    wire s00_axi_bvalid;
    reg s00_axi_bready = '0;
    reg [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_arid = '0;
    reg [C_S00_AXI_ADDR_WIDTH-1:0]       s00_axi_araddr = '0;
    reg [7:0]                            s00_axi_arlen = '0;
    reg [2:0]                            s00_axi_arsize = '0;
    reg [1:0]                            s00_axi_arburst = '0;
    reg s00_axi_arlock = '0;
    reg [3:0]                            s00_axi_arcache = '0;
    reg [2:0]                            s00_axi_arprot = '0;
    reg [3:0]                            s00_axi_arqos = '0;
    reg [3:0]                            s00_axi_arregion = '0;
    reg [C_S00_AXI_ARUSER_WIDTH-1:0]     s00_axi_aruser = '0;
    reg s00_axi_arvalid = '0;
    wire s00_axi_arready;
    wire [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_rid;
    wire [C_S00_AXI_DATA_WIDTH-1:0]       s00_axi_rdata;
    wire [1:0]                            s00_axi_rresp;
    wire s00_axi_rlast;
    wire [C_S00_AXI_RUSER_WIDTH-1:0]      s00_axi_ruser;
    wire s00_axi_rvalid;
    reg s00_axi_rready = '0;
    integer checks = 0;
    MY_IP dut (
        .s00_axi_aclk(s00_axi_aclk),
        .s00_axi_aresetn(s00_axi_aresetn),
        .s00_axi_awid(s00_axi_awid),
        .s00_axi_awaddr(s00_axi_awaddr),
        .s00_axi_awlen(s00_axi_awlen),
        .s00_axi_awsize(s00_axi_awsize),
        .s00_axi_awburst(s00_axi_awburst),
        .s00_axi_awlock(s00_axi_awlock),
        .s00_axi_awcache(s00_axi_awcache),
        .s00_axi_awprot(s00_axi_awprot),
        .s00_axi_awqos(s00_axi_awqos),
        .s00_axi_awregion(s00_axi_awregion),
        .s00_axi_awuser(s00_axi_awuser),
        .s00_axi_awvalid(s00_axi_awvalid),
        .s00_axi_awready(s00_axi_awready),
        .s00_axi_wdata(s00_axi_wdata),
        .s00_axi_wstrb(s00_axi_wstrb),
        .s00_axi_wlast(s00_axi_wlast),
        .s00_axi_wuser(s00_axi_wuser),
        .s00_axi_wvalid(s00_axi_wvalid),
        .s00_axi_wready(s00_axi_wready),
        .s00_axi_bid(s00_axi_bid),
        .s00_axi_bresp(s00_axi_bresp),
        .s00_axi_buser(s00_axi_buser),
        .s00_axi_bvalid(s00_axi_bvalid),
        .s00_axi_bready(s00_axi_bready),
        .s00_axi_arid(s00_axi_arid),
        .s00_axi_araddr(s00_axi_araddr),
        .s00_axi_arlen(s00_axi_arlen),
        .s00_axi_arsize(s00_axi_arsize),
        .s00_axi_arburst(s00_axi_arburst),
        .s00_axi_arlock(s00_axi_arlock),
        .s00_axi_arcache(s00_axi_arcache),
        .s00_axi_arprot(s00_axi_arprot),
        .s00_axi_arqos(s00_axi_arqos),
        .s00_axi_arregion(s00_axi_arregion),
        .s00_axi_aruser(s00_axi_aruser),
        .s00_axi_arvalid(s00_axi_arvalid),
        .s00_axi_arready(s00_axi_arready),
        .s00_axi_rid(s00_axi_rid),
        .s00_axi_rdata(s00_axi_rdata),
        .s00_axi_rresp(s00_axi_rresp),
        .s00_axi_rlast(s00_axi_rlast),
        .s00_axi_ruser(s00_axi_ruser),
        .s00_axi_rvalid(s00_axi_rvalid),
        .s00_axi_rready(s00_axi_rready)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_MY_IP: %0s", message);
            checks = checks + 1;
        end
    endtask
    task reset_dut;
        begin
            @(negedge tb_clk);
            s00_axi_aresetn = 0;
            repeat (4) @(negedge tb_clk);
            s00_axi_aresetn = 1;
            repeat (2) @(negedge tb_clk);
        end
    endtask
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_MY_IP: watchdog timeout");
    end
    integer i,t;
    reg [127:0] held;
    task write_word;
        input [39:0] addr;
        input [127:0] data;
        begin
            @(negedge tb_clk);
            s00_axi_awaddr=addr; s00_axi_awsize=4; s00_axi_awburst=1;
            s00_axi_awvalid=1; s00_axi_bready=0;
            t=0;
            @(posedge tb_clk);
            while(!s00_axi_awready && t<100) begin @(posedge tb_clk); t=t+1; end
            check(s00_axi_awready,"AW timeout");
            @(negedge tb_clk); s00_axi_awvalid=0;
            s00_axi_wvalid=1; s00_axi_wlast=1; s00_axi_wstrb='1; s00_axi_wdata=data;
            @(posedge tb_clk); check(s00_axi_wready,"W handshake");
            @(negedge tb_clk); s00_axi_wvalid=0;
            t=0;
            while(!s00_axi_bvalid && t<100) begin @(negedge tb_clk); t=t+1; end
            check(s00_axi_bvalid && s00_axi_bresp==0,"B response");
            repeat(3) begin @(negedge tb_clk); check(s00_axi_bvalid,"B stall"); end
            s00_axi_bready=1;
            @(negedge tb_clk);
        end
    endtask
    initial begin
        reset_dut();
        for(i=0;i<4;i=i+1) write_word(40'h340000+i*16,128'hfedcba98_76543210_80000000_00000000+i);
        @(negedge tb_clk); s00_axi_araddr=40'h340000; s00_axi_arlen=3;
        s00_axi_arsize=4; s00_axi_arburst=1; s00_axi_arid=1;
        s00_axi_arvalid=1; s00_axi_rready=0;
        @(posedge tb_clk); check(s00_axi_arready,"AR handshake");
        @(negedge tb_clk); s00_axi_arvalid=0;
        for(i=0;i<4;i=i+1) begin
            t=0;
            while(!s00_axi_rvalid && t<100) begin @(negedge tb_clk); t=t+1; end
            check(s00_axi_rvalid,"R timeout");
            held=s00_axi_rdata;
            repeat(20) begin
                @(negedge tb_clk);
                check(s00_axi_rvalid && s00_axi_rdata===held && s00_axi_rid==1 &&
                      s00_axi_rlast===(i==3) && s00_axi_rresp==0,"R stall stability/metadata");
            end
            check(held===128'hfedcba98_76543210_80000000_00000000+i,"burst payload/order");
            s00_axi_rready=1;
            @(negedge tb_clk); s00_axi_rready=0;
        end
        repeat(4) @(negedge tb_clk);
        check(!s00_axi_rvalid && s00_axi_arready,"burst drained exactly");
        completed = 1;
        $display("[TB][PASS] tb_MY_IP checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
