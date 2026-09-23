`ifndef TB_SPU_SOFTMAX_V
`define TB_SPU_SOFTMAX_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_Softmax #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = '0;
    reg start = '0;
    reg [1:0]                        op = '0;
    reg [AXI_DATA_WIDTH-1:0]         input_word = '0;
    reg signed [15:0]                max_value_q8 = '0;
    reg [63:0]                       sum_value = '0;
    reg [7:0]                        lane_valid = '0;
    wire busy;
    wire done;
    wire [AXI_DATA_WIDTH-1:0]         output_word;
    wire signed [15:0]                word_max_q8;
    wire [63:0]                       word_sum;
    wire supported;
    integer checks = 0;
    SPU_Softmax dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .op(op),
        .input_word(input_word),
        .max_value_q8(max_value_q8),
        .sum_value(sum_value),
        .lane_valid(lane_valid),
        .busy(busy),
        .done(done),
        .output_word(output_word),
        .word_max_q8(word_max_q8),
        .word_sum(word_sum),
        .supported(supported)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_Softmax: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_Softmax: watchdog timeout");
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
    integer i;
    reg [127:0] scores;
    initial begin
        reset_dut();
        check(supported,"supported");
        lane_valid=8'h0f;
        for(i=0;i<8;i=i+1) input_word[16*i+:16]=(i<4)?16'sd256:16'sd32767;
        op=0; run_op();
        check(word_max_q8 === 16'sd256,"masked maximum");
        op=1; max_value_q8=256; run_op();
        scores=output_word;
        check(word_sum === 64'd131072,"equal-logit score sum");
        check(scores === {64'd0,{4{16'd32768}}},"score values and masked lanes");
        input_word=scores; sum_value=131072; op=2; run_op();
        check(output_word === {64'd0,{4{16'd8192}}},"equal probabilities");
        sum_value=0; run_op(); check(output_word === 0,"zero denominator");
        input_word=0; input_word[15:0]=-16'sd4096; lane_valid=1;
        op=1; max_value_q8=0; run_op();
        check(output_word === 0 && word_sum === 0,"far-negative score");
        completed = 1;
        $display("[TB][PASS] tb_SPU_Softmax checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
