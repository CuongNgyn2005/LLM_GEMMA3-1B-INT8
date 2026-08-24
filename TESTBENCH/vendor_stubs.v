`timescale 1ns/1ps

// Behavioral stand-ins used only by Icarus regression. Vivado synthesis uses
// the real multiplier IP and XPM memory primitive.
module mult_gen_0(
    input  wire clk,
    input  wire CLK,
    input  wire signed [7:0] A,
    input  wire signed [7:0] B,
    output wire signed [15:0] P
);
    wire c = CLK;
    reg signed [15:0] p0, p1, p2;
    always @(posedge c) begin
        p0 <= $signed(A) * $signed(B);
        p1 <= p0;
        p2 <= p1;
    end
    assign P = p2;
endmodule

module xpm_memory_sdpram #(
    parameter integer MEMORY_SIZE = 2048,
    parameter MEMORY_PRIMITIVE = "auto",
    parameter CLOCKING_MODE = "common_clock",
    parameter ECC_MODE = "no_ecc",
    parameter MEMORY_INIT_FILE = "none",
    parameter MEMORY_INIT_PARAM = "0",
    parameter integer USE_MEM_INIT = 0,
    parameter WAKEUP_TIME = "disable_sleep",
    parameter integer AUTO_SLEEP_TIME = 0,
    parameter integer MESSAGE_CONTROL = 0,
    parameter integer USE_EMBEDDED_CONSTRAINT = 0,
    parameter MEMORY_OPTIMIZATION = "true",
    parameter integer CASCADE_HEIGHT = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer WRITE_PROTECT = 0,
    parameter integer WRITE_DATA_WIDTH_A = 32,
    parameter integer BYTE_WRITE_WIDTH_A = 32,
    parameter integer ADDR_WIDTH_A = 8,
    parameter integer ADDR_WIDTH_B = 8,
    parameter RST_MODE_A = "SYNC",
    parameter integer READ_DATA_WIDTH_B = 32,
    parameter READ_RESET_VALUE_B = "0",
    parameter integer READ_LATENCY_B = 1,
    parameter WRITE_MODE_B = "read_first",
    parameter RST_MODE_B = "SYNC"
) (
    input  wire sleep,
    input  wire clka,
    input  wire ena,
    input  wire wea,
    input  wire [ADDR_WIDTH_A-1:0] addra,
    input  wire [WRITE_DATA_WIDTH_A-1:0] dina,
    input  wire injectsbiterra,
    input  wire injectdbiterra,
    input  wire clkb,
    input  wire rstb,
    input  wire enb,
    input  wire regceb,
    input  wire [ADDR_WIDTH_B-1:0] addrb,
    output wire [READ_DATA_WIDTH_B-1:0] doutb,
    output wire sbiterrb,
    output wire dbiterrb
);
    localparam integer DEPTH = (1 << ADDR_WIDTH_A);
    reg [WRITE_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];
    reg [READ_DATA_WIDTH_B-1:0] q0, q1;
    always @(posedge clka)
        if (ena && wea) mem[addra] <= dina;
    always @(posedge clkb) begin
        if (rstb) begin q0 <= 0; q1 <= 0; end
        else if (enb) begin q0 <= mem[addrb]; q1 <= q0; end
    end
    assign doutb = (READ_LATENCY_B > 1) ? q1 : q0;
    assign sbiterrb = 1'b0;
    assign dbiterrb = 1'b0;
endmodule
