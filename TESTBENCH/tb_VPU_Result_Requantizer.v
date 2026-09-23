`ifndef TB_VPU_RESULT_REQUANTIZER_V
`define TB_VPU_RESULT_REQUANTIZER_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_VPU_Result_Requantizer #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam ACC_WIDTH = 32;
    localparam SHIFT_WIDTH = 5;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    reg signed [ACC_WIDTH-1:0]        value_in = '0;
    reg [SHIFT_WIDTH-1:0]             requant_shift = '0;
    wire signed [7:0]                  value_out;
    integer checks = 0;
    VPU_Result_Requantizer dut (
        .value_in(value_in),
        .requant_shift(requant_shift),
        .value_out(value_out)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_VPU_Result_Requantizer: %0s", message);
            checks = checks + 1;
        end
    endtask
    task reset_dut;
        begin
            @(negedge tb_clk);

            repeat (4) @(negedge tb_clk);

            repeat (2) @(negedge tb_clk);
        end
    endtask
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_VPU_Result_Requantizer: watchdog timeout");
    end
    integer v, sh;
    reg signed [63:0] expected;
    initial begin
        reset_dut();
        for (sh=0; sh<32; sh=sh+1) begin
            requant_shift = sh;
            for (v=-1024; v<=1024; v=v+1) begin
                value_in = v;
                expected = v;
                expected = expected >>> sh;
                if (expected > 127) expected = 127;
                if (expected < -128) expected = -128;
                #1; check(value_out === expected[7:0], "signed shift/saturation");
            end
        end
        value_in = 32'h80000000; requant_shift = 0;
        #1; check(value_out === -8'sd128, "INT32 minimum");
        value_in = 32'h7fffffff;
        #1; check(value_out === 8'sd127, "INT32 maximum");
        completed = 1;
        $display("[TB][PASS] tb_VPU_Result_Requantizer checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
