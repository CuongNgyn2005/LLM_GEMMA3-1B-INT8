`ifndef TB_SPU_SILU_MUL_V
`define TB_SPU_SILU_MUL_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_SiLU_Mul #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = 0;
    reg start = 0;
    reg [AXI_DATA_WIDTH-1:0]         gate_word = 0;
    reg [AXI_DATA_WIDTH-1:0]         up_word = 0;
    reg [7:0]                        lane_valid = 0;
    wire busy;
    wire done;
    wire [AXI_DATA_WIDTH-1:0]         result_word;
    wire supported;
    integer checks = 0;
    SPU_SiLU_Mul dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .gate_word(gate_word),
        .up_word(up_word),
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
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_SiLU_Mul: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_SiLU_Mul: watchdog timeout");
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
    integer i,trial;
    reg signed [63:0] g,u,sig,y;
    reg [127:0] expected;
    initial begin
        reset_dut();
        check(supported,"supported");
        for(trial=0;trial<3;trial=trial+1) begin
            lane_valid=trial==0 ? 8'hff : trial==1 ? 8'ha5 : 0;
            expected=0;
            for(i=0;i<8;i=i+1) begin
                g=(i-3)*512; u=(i%2) ? -16384 : 16384;
                gate_word[16*i+:16]=g; up_word[16*i+:16]=u;
                sig=(g>=1024) ? 32768 : (g<= -1024) ? 0 : 16384+g*16;
                y=((g*sig) >>> 15)*u; y=y >>> 8;
                if(y>32767) y=32767;
                if(y< -32768) y=-32768;
                if(lane_valid[i]) expected[16*i+:16]=y;
            end
            run_op(); check(result_word === expected,"clipped sigmoid, signed product, saturation and mask");
        end
        completed = 1;
        $display("[TB][PASS] tb_SPU_SiLU_Mul checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
