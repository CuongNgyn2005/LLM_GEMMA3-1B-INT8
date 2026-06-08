`timescale 1ns/1ps

module tb_pmau_direct_xsim;
    localparam integer NUM_LANES      = 16;
    localparam integer AXI_DATA_WIDTH = 128;
    localparam integer MAX_ROWS       = 8;
    localparam integer MAX_COLS       = 128;

    reg CLK;
    reg RST;
    reg [AXI_DATA_WIDTH-1:0] activation_data;
    reg activation_valid;
    wire activation_ready;
    reg activation_last;
    reg [AXI_DATA_WIDTH-1:0] weight_data;
    reg [15:0] scale_factor;
    reg weight_valid;
    wire weight_ready;
    reg weight_last;
    wire [31:0] result_data;
    wire result_valid;
    reg result_ready;
    wire result_last;

    reg signed [7:0] x_mem [0:MAX_COLS-1];
    reg signed [7:0] a_mem [0:(MAX_ROWS*MAX_COLS)-1];

    integer rows;
    integer cols;
    integer pass_cases;
    integer fail_cases;
    integer result_file;

    PMAU_Full #(
        .NUM_LANES         (NUM_LANES),
        .ACT_WIDTH         (8),
        .WEIGHT_WIDTH      (8),
        .ACC_WIDTH         (32),
        .SCALE_WIDTH       (16),
        .SCALE_FRAC_BITS   (15),
        .RESULT_FIFO_DEPTH (8)
    ) dut (
        .CLK               (CLK),
        .RST               (RST),
        .compute_mode      (2'b00),
        .activation_data   (activation_data),
        .activation_valid  (activation_valid),
        .activation_ready  (activation_ready),
        .activation_last   (activation_last),
        .weight_data       (weight_data),
        .scale_factor      (scale_factor),
        .weight_valid      (weight_valid),
        .weight_ready      (weight_ready),
        .weight_last       (weight_last),
        .scalar_axpy       (16'd0),
        .result_data       (result_data),
        .result_valid      (result_valid),
        .result_ready      (result_ready),
        .result_last       (result_last)
    );

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    function signed [31:0] golden_row;
        input integer row;
        integer col;
        reg signed [31:0] acc;
        begin
            acc = 32'sd0;
            for (col = 0; col < cols; col = col + 1)
                acc = acc + a_mem[row * MAX_COLS + col] * x_mem[col];
            golden_row = acc;
        end
    endfunction

    function [AXI_DATA_WIDTH-1:0] pack_activation;
        input integer beat;
        integer lane;
        integer idx;
        begin
            pack_activation = {AXI_DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                idx = beat * NUM_LANES + lane;
                if (idx < cols)
                    pack_activation[8*lane +: 8] = x_mem[idx];
            end
        end
    endfunction

    function [AXI_DATA_WIDTH-1:0] pack_weight;
        input integer row;
        input integer beat;
        integer lane;
        integer col;
        begin
            pack_weight = {AXI_DATA_WIDTH{1'b0}};
            for (lane = 0; lane < NUM_LANES; lane = lane + 1) begin
                col = beat * NUM_LANES + lane;
                if (col < cols)
                    pack_weight[8*lane +: 8] = a_mem[row * MAX_COLS + col];
            end
        end
    endfunction

    task init_case;
        input integer case_id;
        input integer case_rows;
        input integer case_cols;
        integer row;
        integer col;
        integer value;
        begin
            rows = case_rows;
            cols = case_cols;
            for (col = 0; col < MAX_COLS; col = col + 1) begin
                case (case_id)
                1: value = ((col * 9 + 17) % 41) - 20;
                2: value = ((col * 7 + 5) % 63) - 31;
                default: value = (col & 1) ? 127 : -128;
                endcase
                x_mem[col] = value;
            end
            for (row = 0; row < MAX_ROWS; row = row + 1) begin
                for (col = 0; col < MAX_COLS; col = col + 1) begin
                    case (case_id)
                    1: value = ((row * 13 + col * 11 + 23) % 45) - 22;
                    2: value = ((row * 17 + col * 3 + 19) % 67) - 33;
                    default: begin
                        case ((row + col) % 4)
                        0: value = 127;
                        1: value = -128;
                        2: value = 13;
                        default: value = -11;
                        endcase
                    end
                    endcase
                    a_mem[row * MAX_COLS + col] = value;
                end
            end
        end
    endtask

    task send_beat;
        input [AXI_DATA_WIDTH-1:0] act_word;
        input [AXI_DATA_WIDTH-1:0] weight_word;
        input last_flag;
        begin
            @(posedge CLK);
            #1;
            activation_data  = act_word;
            weight_data      = weight_word;
            activation_last  = last_flag;
            weight_last      = last_flag;
            activation_valid = 1'b1;
            weight_valid     = 1'b1;

            wait (activation_ready && weight_ready);
            @(posedge CLK);
            #1;
            activation_valid = 1'b0;
            weight_valid     = 1'b0;
            activation_last  = 1'b0;
            weight_last      = 1'b0;
        end
    endtask

    task wait_result;
        output signed [31:0] value;
        integer timeout;
        begin
            timeout = 0;
            while (!result_valid && timeout < 200) begin
                @(posedge CLK);
                #1;
                timeout = timeout + 1;
            end
            if (!result_valid) begin
                value = 32'sd0;
                $display("[PMAU][FAIL] result timeout");
            end else begin
                value = result_data;
                @(posedge CLK);
                #1;
            end
        end
    endtask

    task run_case;
        input integer case_id;
        input integer case_rows;
        input integer case_cols;
        integer row;
        integer beat;
        integer col_beats;
        integer mismatches;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        begin
            init_case(case_id, case_rows, case_cols);
            col_beats = (cols + NUM_LANES - 1) / NUM_LANES;
            mismatches = 0;

            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < col_beats; beat = beat + 1)
                    send_beat(pack_activation(beat), pack_weight(row, beat),
                              (beat == (col_beats - 1)));

                wait_result(got);
                expected = golden_row(row);
                if (got !== expected) begin
                    mismatches = mismatches + 1;
                    $display("[PMAU][FAIL] case=%0d row=%0d got=%0d expected=%0d",
                             case_id, row, got, expected);
                end else begin
                    $display("[PMAU][PASS] case=%0d row=%0d result=%0d",
                             case_id, row, got);
                end
            end

            if (mismatches == 0) begin
                pass_cases = pass_cases + 1;
                $fwrite(result_file, "%0d,%0d,%0d,pass,0\n", case_id, rows, cols);
            end else begin
                fail_cases = fail_cases + 1;
                $fwrite(result_file, "%0d,%0d,%0d,fail,%0d\n", case_id, rows, cols, mismatches);
            end
        end
    endtask

    initial begin
        RST = 1'b0;
        activation_data = {AXI_DATA_WIDTH{1'b0}};
        activation_valid = 1'b0;
        activation_last = 1'b0;
        weight_data = {AXI_DATA_WIDTH{1'b0}};
        scale_factor = 16'h3c00;
        weight_valid = 1'b0;
        weight_last = 1'b0;
        result_ready = 1'b1;
        pass_cases = 0;
        fail_cases = 0;

        result_file = $fopen("pmau_direct_xsim_results.csv", "w");
        $fwrite(result_file, "case_id,rows,cols,status,mismatches\n");

        repeat (8) @(posedge CLK);
        #1;
        RST = 1'b1;
        repeat (4) @(posedge CLK);

        run_case(1, 4, 4);
        run_case(2, 3, 17);
        run_case(3, 4, 64);

        $display("[PMAU][SUMMARY] pass_cases=%0d fail_cases=%0d", pass_cases, fail_cases);
        $fclose(result_file);
        if (fail_cases == 0)
            $finish(0);
        else
            $finish(1);
    end
endmodule
