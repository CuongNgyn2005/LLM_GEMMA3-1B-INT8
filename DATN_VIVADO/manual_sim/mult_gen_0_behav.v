`timescale 1ns/1ps

module mult_gen_0 (
    input  wire              CLK,
    input  wire signed [7:0] A,
    input  wire signed [7:0] B,
    output wire signed [15:0] P
);
    reg signed [15:0] pipe0;
    reg signed [15:0] pipe1;
    reg signed [15:0] pipe2;

    always @(posedge CLK) begin
        pipe0 <= A * B;
        pipe1 <= pipe0;
        pipe2 <= pipe1;
    end

    assign P = pipe2;
endmodule
