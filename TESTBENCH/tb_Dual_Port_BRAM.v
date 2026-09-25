`ifndef TB_DUAL_PORT_BRAM_V
`define TB_DUAL_PORT_BRAM_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_Dual_Port_BRAM #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AWIDTH = 8;
    localparam DWIDTH = 128;
    localparam OUTPUT_REG = 0;
    localparam USE_URAM = 0;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clka = tb_clk;
    reg ena = 0;
    reg [(DWIDTH/8)-1:0]        wea = 0;
    reg [AWIDTH-1:0]            addra = 0;
    reg [DWIDTH-1:0]            dina = 0;
    wire [DWIDTH-1:0]            douta;
    wire clkb = tb_clk;
    reg enb = 0;
    reg [(DWIDTH/8)-1:0]        web = 0;
    reg [AWIDTH-1:0]            addrb = 0;
    reg [DWIDTH-1:0]            dinb = 0;
    wire [DWIDTH-1:0]            doutb;
    integer checks = 0;
    Dual_Port_BRAM dut (
        .clka(clka),
        .ena(ena),
        .wea(wea),
        .addra(addra),
        .dina(dina),
        .douta(douta),
        .clkb(clkb),
        .enb(enb),
        .web(web),
        .addrb(addrb),
        .dinb(dinb),
        .doutb(doutb)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_Dual_Port_BRAM: %0s", message);
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
        if (!completed) $fatal(1, "[TB][FAIL] tb_Dual_Port_BRAM: watchdog timeout");
    end
    integer i;
    reg [127:0] saved;
    initial begin
        reset_dut();
        ena=1; wea={(DWIDTH/8){1'b1}}; addra=0; dina=128'h0123456789abcdef_fedcba9876543210;
        @(negedge tb_clk); wea=0; enb=1; addrb=0;
        @(negedge tb_clk);
        check(doutb===dina,"cross-port full write/read");
        saved=doutb;
        wea=16'h0003; dina=128'hbeef;
        @(negedge tb_clk); wea=0;
        @(negedge tb_clk); check(doutb==={saved[127:16],16'hbeef},"byte strobes");
        ena=0; enb=1; web={(DWIDTH/8){1'b1}}; addrb=255; dinb=128'h8000000000000000_7fffffffffffffff;
        @(negedge tb_clk); web=0; ena=1; addra=255;
        @(negedge tb_clk); check(douta===dinb,"port B write / A read at boundary");
        saved=douta; ena=0; addra=17;
        repeat(3) @(negedge tb_clk);
        check(douta===saved,"disabled port holds output");
        completed = 1;
        $display("[TB][PASS] tb_Dual_Port_BRAM checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
