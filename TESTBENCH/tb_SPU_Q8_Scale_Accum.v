`ifndef TB_SPU_Q8_SCALE_ACCUM_V
`define TB_SPU_Q8_SCALE_ACCUM_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_Q8_Scale_Accum #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam ROW_ID_WIDTH = 16;
    localparam MAX_ROWS = 256;
    localparam ACC_WIDTH = 64;
    localparam FIXED_FRAC_BITS = 16;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = '0;
    reg start = '0;
    reg signed [31:0]                raw_in = '0;
    reg [15:0]                       act_scale_fp16 = '0;
    reg [15:0]                       weight_scale_fp16 = '0;
    reg [ROW_ID_WIDTH-1:0]           row_id = '0;
    reg clear_accum = '0;
    reg last_block = '0;
    wire busy;
    wire entry_done;
    wire out_valid;
    wire [ROW_ID_WIDTH-1:0]           out_row_id;
    wire signed [ACC_WIDTH-1:0]       out_accum_q16;
    wire error;
    wire [3:0]                        error_code;
    integer checks = 0;
    SPU_Q8_Scale_Accum dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .raw_in(raw_in),
        .act_scale_fp16(act_scale_fp16),
        .weight_scale_fp16(weight_scale_fp16),
        .row_id(row_id),
        .clear_accum(clear_accum),
        .last_block(last_block),
        .busy(busy),
        .entry_done(entry_done),
        .out_valid(out_valid),
        .out_row_id(out_row_id),
        .out_accum_q16(out_accum_q16),
        .error(error),
        .error_code(error_code)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_Q8_Scale_Accum: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_Q8_Scale_Accum: watchdog timeout");
    end
    task entry;
        integer t;
        begin
            @(negedge tb_clk); start=1;
            @(negedge tb_clk); start=0;
            t=0;
            while(!entry_done && t<32) begin @(negedge tb_clk); t=t+1; end
            check(entry_done,"entry completion");
        end
    endtask
    initial begin
        reset_dut();
        row_id=3; act_scale_fp16=16'h3800; weight_scale_fp16=16'h3400;
        raw_in=-16; clear_accum=1; last_block=0; entry();
        while(busy) @(negedge tb_clk);
        raw_in=8; clear_accum=0; last_block=1; entry();
        check(out_valid && out_row_id===16'd3 && out_accum_q16=== -64'sd65536 && !error,"multi-block signed Q16 sum");
        while(busy) @(negedge tb_clk);
        clear_accum=1; act_scale_fp16=0; entry();
        check(out_valid && out_accum_q16===0 && !error,"zero scale");
        while(busy) @(negedge tb_clk);
        act_scale_fp16=16'h7c00; entry();
        check(error && error_code===4'd1 && !out_valid,"infinite scale rejected");
        while(busy) @(negedge tb_clk);
        act_scale_fp16=16'h3c00; row_id=256; entry();
        check(error && error_code===4'd2 && !out_valid,"row bound");
        completed = 1;
        $display("[TB][PASS] tb_SPU_Q8_Scale_Accum checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
