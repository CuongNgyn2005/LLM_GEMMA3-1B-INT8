`timescale 1ns/1ps

module tb_mult_gen_latency;
    reg CLK;
    reg signed [7:0] A;
    reg signed [7:0] B;
    wire signed [15:0] P;

    mult_gen_0 dut (
        .CLK (CLK),
        .A   (A),
        .B   (B),
        .P   (P)
    );

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    integer cycle;
    initial begin
        cycle = 0;
        A = 0;
        B = 0;
        repeat (2) @(posedge CLK);
        drive(-8'sd3,  8'sd5);
        drive( 8'sd7, -8'sd4);
        drive(-8'sd2, -8'sd6);
        drive( 8'sd9,  8'sd3);
        drive( 8'sd0,  8'sd0);
        drive( 8'sd0,  8'sd0);
        drive( 8'sd0,  8'sd0);
        drive( 8'sd0,  8'sd0);
        $finish;
    end

    task drive;
        input signed [7:0] a_in;
        input signed [7:0] b_in;
        begin
            @(posedge CLK);
            #1;
            A = a_in;
            B = b_in;
        end
    endtask

    always @(posedge CLK) begin
        $display("[MULT_GEN] cycle=%0d A=%0d B=%0d P=%0d raw=0x%04h",
                 cycle, A, B, P, P);
        cycle <= cycle + 1;
    end
endmodule
