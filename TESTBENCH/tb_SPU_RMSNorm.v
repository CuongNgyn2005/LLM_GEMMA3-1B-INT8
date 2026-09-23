`ifndef TB_SPU_RMSNORM_V
`define TB_SPU_RMSNORM_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_RMSNorm #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = '0;
    reg start = '0;
    reg [AXI_DATA_WIDTH-1:0]         input_word = '0;
    reg [AXI_DATA_WIDTH-1:0]         weight_word = '0;
    reg [31:0]                       inv_rms_q15 = '0;
    reg [7:0]                        lane_valid = '0;
    wire busy;
    wire done;
    wire [AXI_DATA_WIDTH-1:0]         result_word;
    wire [63:0]                       word_sumsq_q16;
    wire supported;
    integer checks = 0;
    SPU_RMSNorm dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .input_word(input_word),
        .weight_word(weight_word),
        .inv_rms_q15(inv_rms_q15),
        .lane_valid(lane_valid),
        .busy(busy),
        .done(done),
        .result_word(result_word),
        .word_sumsq_q16(word_sumsq_q16),
        .supported(supported)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_RMSNorm: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_RMSNorm: watchdog timeout");
    end
    task run_op;
        integer t;
        begin
            @(negedge tb_clk); start = 1;
            @(negedge tb_clk); start = 0;
            t = 0;
            while (!done && t < 2000) begin @(negedge tb_clk); t=t+1; end
            check(done && !busy, "bounded completion");
        end
    endtask
    integer i, trial;
    reg signed [63:0] v, w, ref_value;
    reg [63:0] ref_sum;
    reg [127:0] ref_word;
    initial begin
        reset_dut();
        check(supported, "supported");
        for (trial=0; trial<4; trial=trial+1) begin
            lane_valid = (trial == 0) ? 8'hff : (trial == 1) ? 8'h55 : (trial == 2) ? 8'h80 : 0;
            inv_rms_q15 = trial == 2 ? 32'h7fffffff : 32768;
            ref_sum=0; ref_word=0;
            for(i=0;i<8;i=i+1) begin
                v = (i%2) ? -(i+1)*256 : (i+1)*256;
                w = (i%3) ? 256 : -512;
                input_word[16*i+:16]=v; weight_word[16*i+:16]=w;
                if(lane_valid[i]) begin
                    ref_sum=ref_sum+v*v;
                    ref_value=(v*w*$signed({1'b0,inv_rms_q15})) >>> 23;
                    if(ref_value>32767) ref_value=32767;
                    if(ref_value< -32768) ref_value=-32768;
                    ref_word[16*i+:16]=ref_value;
                end
            end
            run_op();
            check(result_word === ref_word, "signed normalization, masks, saturation");
            check(word_sumsq_q16 === ref_sum, "sum of squares");
        end
        completed = 1;
        $display("[TB][PASS] tb_SPU_RMSNorm checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
