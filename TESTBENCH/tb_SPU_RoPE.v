`ifndef TB_SPU_ROPE_V
`define TB_SPU_ROPE_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_RoPE #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = '0;
    reg start = '0;
    reg [AXI_DATA_WIDTH-1:0]         input_word = '0;
    reg [AXI_DATA_WIDTH-1:0]         trig_word = '0;
    reg [7:0]                        lane_valid = '0;
    wire busy;
    wire done;
    wire [AXI_DATA_WIDTH-1:0]         result_word;
    wire supported;
    integer checks = 0;
    SPU_RoPE dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .input_word(input_word),
        .trig_word(trig_word),
        .lane_valid(lane_valid),
        .busy(busy),
        .done(done),
        .result_word(result_word),
        .supported(supported)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_RoPE: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_RoPE: watchdog timeout");
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
    reg signed [63:0] x0,x1,c,s,y0,y1;
    reg [127:0] expected;
    initial begin
        reset_dut();
        check(supported, "supported");
        for(trial=0;trial<3;trial=trial+1) begin
            lane_valid=trial==0 ? 8'hff : trial==1 ? 8'h55 : 0;
            expected=0;
            for(i=0;i<4;i=i+1) begin
                x0=(i+1)*1024; x1=-(i+1)*512;
                c=16384; s= -16384;
                input_word[32*i+:16]=x0; input_word[32*i+16+:16]=x1;
                trig_word[32*i+:16]=c; trig_word[32*i+16+:16]=s;
                y0=(x0*c-x1*s) >>> 15; y1=(x0*s+x1*c) >>> 15;
                if(lane_valid[2*i]) expected[32*i+:16]=y0;
                if(lane_valid[2*i+1]) expected[32*i+16+:16]=y1;
            end
            run_op(); check(result_word === expected,"signed rotation and inactive lanes");
        end
        completed = 1;
        $display("[TB][PASS] tb_SPU_RoPE checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
