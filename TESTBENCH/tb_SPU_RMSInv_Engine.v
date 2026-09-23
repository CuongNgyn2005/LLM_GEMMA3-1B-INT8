`ifndef TB_SPU_RMSINV_ENGINE_V
`define TB_SPU_RMSINV_ENGINE_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_RMSInv_Engine #(parameter AUTO_FINISH = 1)(output reg completed = 0);

    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = '0;
    reg start = '0;
    reg [63:0] sumsq_q16 = '0;
    reg [31:0] element_count = '0;
    reg [31:0] epsilon_q16 = '0;
    wire busy;
    wire done;
    wire error;
    wire [31:0] inv_rms_q15;
    integer checks = 0;
    SPU_RMSInv_Engine dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .sumsq_q16(sumsq_q16),
        .element_count(element_count),
        .epsilon_q16(epsilon_q16),
        .busy(busy),
        .done(done),
        .error(error),
        .inv_rms_q15(inv_rms_q15)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_RMSInv_Engine: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_RMSInv_Engine: watchdog timeout");
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

    initial begin
        reset_dut();
        element_count=8; epsilon_q16=0; sumsq_q16=8*65536;
        run_op(); check(!error && inv_rms_q15 === 32768,"unit RMS");
        sumsq_q16=8*4*65536;
        run_op(); check(!error && inv_rms_q15 === 16384,"RMS two");
        sumsq_q16=0; epsilon_q16=65536;
        run_op(); check(!error && inv_rms_q15 === 32768,"epsilon");
        element_count=0;
        run_op(); check(error && inv_rms_q15 === 0,"zero count rejection");
        completed = 1;
        $display("[TB][PASS] tb_SPU_RMSInv_Engine checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
