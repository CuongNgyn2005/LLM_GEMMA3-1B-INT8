`timescale 1ns/1ps

module tb_pmau_known;
    localparam NUM_LANES = 16;
    localparam ACT_WIDTH = 8;
    localparam WEIGHT_WIDTH = 8;
    localparam ACC_WIDTH = 32;
    localparam SCALE_WIDTH = 16;
    localparam NUM_BEATS = 4;

    reg clk = 1'b0;
    reg rst = 1'b0;
    reg [ACT_WIDTH*NUM_LANES-1:0] act_data = 0;
    reg [WEIGHT_WIDTH*NUM_LANES-1:0] weight_data = 0;
    reg act_valid = 1'b0;
    reg weight_valid = 1'b0;
    reg act_last = 1'b0;
    reg weight_last = 1'b0;
    wire act_ready;
    wire weight_ready;
    wire [ACC_WIDTH-1:0] result_data;
    wire result_valid;
    wire result_last;

    integer beat;
    integer lane;

    always #5 clk = ~clk;

    PMAU_Streaming #(
        .NUM_LANES(NUM_LANES),
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .SCALE_WIDTH(SCALE_WIDTH)
    ) dut (
        .CLK(clk),
        .RST(rst),
        .compute_mode(2'b00),
        .activation_data(act_data),
        .activation_valid(act_valid),
        .activation_ready(act_ready),
        .activation_last(act_last),
        .weight_data(weight_data),
        .scale_factor(16'h3c00),
        .weight_valid(weight_valid),
        .weight_ready(weight_ready),
        .weight_last(weight_last),
        .scalar_axpy(16'b0),
        .result_data(result_data),
        .result_valid(result_valid),
        .result_ready(1'b1),
        .result_last(result_last)
    );

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);

        for (beat = 0; beat < NUM_BEATS; beat = beat + 1) begin
            @(negedge clk);
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                act_data[ACT_WIDTH*lane +: ACT_WIDTH] = 8'sd1;
                weight_data[WEIGHT_WIDTH*lane +: WEIGHT_WIDTH] = 8'sd1;
            end
            act_valid = 1'b1;
            weight_valid = 1'b1;
            act_last = (beat == NUM_BEATS - 1);
            weight_last = (beat == NUM_BEATS - 1);
        end

        @(negedge clk);
        act_valid = 1'b0;
        weight_valid = 1'b0;
        act_last = 1'b0;
        weight_last = 1'b0;

        while (!result_valid)
            @(posedge clk);

        $display("[KNOWN] result=%0d hex=0x%08h last=%0d expected=64",
                 $signed(result_data), result_data, result_last);
        if (result_data !== 32'd64)
            $display("[KNOWN] FAIL");
        else
            $display("[KNOWN] PASS");
        $finish;
    end
endmodule
