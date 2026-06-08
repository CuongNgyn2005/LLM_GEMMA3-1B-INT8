`timescale 1ns/1ps

module mult_gen_0 (
    input  wire              CLK,
    input  wire signed [7:0] A,
    input  wire signed [7:0] B,
    output reg  signed [15:0] P
);
    reg signed [15:0] p0;
    reg signed [15:0] p1;

    always @(posedge CLK) begin
        p0 <= A * B;
        p1 <= p0;
        P  <= p1;
    end
endmodule
