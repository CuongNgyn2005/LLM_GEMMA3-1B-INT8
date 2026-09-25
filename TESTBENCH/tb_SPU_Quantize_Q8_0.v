`ifndef TB_SPU_QUANTIZE_Q8_0_V
`define TB_SPU_QUANTIZE_Q8_0_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_Quantize_Q8_0 #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam INPUT_WIDTH = 16;
    localparam OUTPUT_WIDTH = 8;
    localparam BLOCK_SIZE = 32;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = 0;
    reg start = 0;
    reg [INPUT_WIDTH*BLOCK_SIZE-1:0]     values_in = 0;
    wire busy;
    wire done;
    wire [OUTPUT_WIDTH*BLOCK_SIZE-1:0]   qs_out;
    wire [15:0]                          scale_amax;
    wire zero_block;
    integer checks = 0;
    SPU_Quantize_Q8_0 dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .values_in(values_in),
        .busy(busy),
        .done(done),
        .qs_out(qs_out),
        .scale_amax(scale_amax),
        .zero_block(zero_block)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_Quantize_Q8_0: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_Quantize_Q8_0: watchdog timeout");
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
    integer i,trial,v,a,q;
    initial begin
        reset_dut();
        for(trial=0;trial<3;trial=trial+1) begin
            a=trial==0 ? 0 : trial==1 ? 1024 : 32768;
            for(i=0;i<32;i=i+1) begin
                v=trial==0 ? 0 : trial==1 ? (i%2 ? -1024 : 512) : (i%2 ? -32768 : 32767);
                values_in[16*i+:16]=v;
            end
            run_op();
            check(scale_amax === a[15:0] && zero_block === (a==0),"maximum magnitude and zero block");
            for(i=0;i<32;i=i+1) begin
                v=$signed(values_in[16*i+:16]);
                q=a==0 ? 0 : (((v<0 ? -v : v)*127+a/2)/a);
                if(v<0) q=-q;
                check(qs_out[8*i+:8] === q[7:0],"rounded signed quantization");
            end
        end
        completed = 1;
        $display("[TB][PASS] tb_SPU_Quantize_Q8_0 checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
