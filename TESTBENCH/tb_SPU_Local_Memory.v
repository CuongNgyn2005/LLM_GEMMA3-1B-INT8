`ifndef TB_SPU_LOCAL_MEMORY_V
`define TB_SPU_LOCAL_MEMORY_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_Local_Memory #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    localparam WORD_DEPTH = 4096;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = 0;
    reg mm_wr_en = 0;
    reg [1:0]                        mm_wr_region = 0;
    reg [31:0]                       mm_wr_index = 0;
    reg [AXI_DATA_WIDTH-1:0]         mm_wr_data = 0;
    reg [(AXI_DATA_WIDTH/8)-1:0]     mm_wr_strb = 0;
    reg mm_rd_en = 0;
    reg [1:0]                        mm_rd_region = 0;
    reg [31:0]                       mm_rd_index = 0;
    wire [AXI_DATA_WIDTH-1:0]         mm_rd_data;
    wire mm_rd_valid;
    wire mm_rd_error;
    reg core_en = 0;
    reg core_we = 0;
    reg [1:0]                        core_region = 0;
    reg [31:0]                       core_index = 0;
    reg [AXI_DATA_WIDTH-1:0]         core_wdata = 0;
    reg [(AXI_DATA_WIDTH/8)-1:0]     core_wstrb = 0;
    wire [AXI_DATA_WIDTH-1:0]         core_rdata;
    wire [AXI_DATA_WIDTH-1:0]         param_core_rdata;
    reg core2_en = 0;
    reg core2_we = 0;
    reg [1:0]                        core2_region = 0;
    reg [31:0]                       core2_index = 0;
    reg [AXI_DATA_WIDTH-1:0]         core2_wdata = 0;
    reg [(AXI_DATA_WIDTH/8)-1:0]     core2_wstrb = 0;
    wire [AXI_DATA_WIDTH-1:0]         core2_rdata;
    wire [AXI_DATA_WIDTH-1:0]         param_mm_rdata;
    reg core3_scratch_en = 0;
    reg [31:0]                       core3_scratch_index = 0;
    wire [AXI_DATA_WIDTH-1:0]         core3_scratch_rdata;
    reg stream_p3_bank_lock_valid = 0;
    reg stream_p3_bank_lock = 0;
    wire mm_wr_rejected;
    integer checks = 0;
    SPU_Local_Memory dut (
        .clk(clk),
        .resetn(resetn),
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
        .mm_rd_error(mm_rd_error),
        .core_en(core_en),
        .core_we(core_we),
        .core_region(core_region),
        .core_index(core_index),
        .core_wdata(core_wdata),
        .core_wstrb(core_wstrb),
        .core_rdata(core_rdata),
        .param_core_rdata(param_core_rdata),
        .core2_en(core2_en),
        .core2_we(core2_we),
        .core2_region(core2_region),
        .core2_index(core2_index),
        .core2_wdata(core2_wdata),
        .core2_wstrb(core2_wstrb),
        .core2_rdata(core2_rdata),
        .param_mm_rdata(param_mm_rdata),
        .core3_scratch_en(core3_scratch_en),
        .core3_scratch_index(core3_scratch_index),
        .core3_scratch_rdata(core3_scratch_rdata),
        .stream_p3_bank_lock_valid(stream_p3_bank_lock_valid),
        .stream_p3_bank_lock(stream_p3_bank_lock),
        .mm_wr_rejected(mm_wr_rejected)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_Local_Memory: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_Local_Memory: watchdog timeout");
    end
    integer r;
    task read_check;
        input [1:0] region;
        input [31:0] index;
        input [127:0] expected;
        begin
            @(negedge tb_clk); mm_rd_region=region; mm_rd_index=index; mm_rd_en=1;
            @(negedge tb_clk);
            check(mm_rd_valid && !mm_rd_error && mm_rd_data===expected,"region/boundary read");
            mm_rd_en=0;
        end
    endtask
    initial begin
        reset_dut();
        for(r=0;r<4;r=r+1) begin
            @(negedge tb_clk); mm_wr_en=1; mm_wr_region=r; mm_wr_index=4095;
            mm_wr_data=128'h8765432101234567_fedcba9800000000+r; mm_wr_strb=16'hffff;
            @(negedge tb_clk); mm_wr_en=0;
            read_check(r,4095,128'h8765432101234567_fedcba9800000000+r);
        end
        @(negedge tb_clk); mm_rd_en=1; mm_rd_index=4096;
        @(negedge tb_clk); check(mm_rd_valid && mm_rd_error,"out of range");
        mm_rd_en=0;
        stream_p3_bank_lock_valid=1; stream_p3_bank_lock=1;
        mm_wr_en=1; mm_wr_region=2; mm_wr_index=4095; mm_wr_data=0;
        #1; check(mm_wr_rejected,"locked scale-bank write rejected");
        @(negedge tb_clk); mm_wr_en=0; stream_p3_bank_lock_valid=0;
        read_check(2,4095,128'h8765432101234567_fedcba9800000002);
        core2_en=1; core2_region=1; core2_index=0; mm_wr_en=1; mm_wr_region=1; mm_wr_index=0;
        #1; check(mm_wr_rejected,"second core port collision rejected");
        @(negedge tb_clk); core2_en=0; mm_wr_en=0;
        completed = 1;
        $display("[TB][PASS] tb_SPU_Local_Memory checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
