`timescale 1ns/1ps

module tb_matmul_dsp_core;
    localparam integer NUM_LANES      = 16;
    localparam integer AXI_DATA_WIDTH = 128;
    localparam integer MAX_ROWS       = 8;
    localparam integer MAX_COL_BEATS  = 8;
    localparam integer MAX_COLS       = NUM_LANES * MAX_COL_BEATS;

    localparam [1:0] REGION_ACT    = 2'd0;
    localparam [1:0] REGION_WEIGHT = 2'd1;
    localparam [1:0] REGION_RESULT = 2'd2;

    reg CLK;
    reg RST;
    reg ctrl_start;
    reg ctrl_clear_done;
    reg [15:0] cfg_rows;
    reg [15:0] cfg_cols;
    reg [15:0] cfg_col_beats;
    reg [15:0] cfg_scale;
    reg [1:0] compute_mode;
    wire busy;
    wire done;
    wire error;
    wire [15:0] active_row;
    wire [15:0] active_col_beat;
    reg mm_wr_en;
    reg [1:0] mm_wr_region;
    reg [31:0] mm_wr_index;
    reg [AXI_DATA_WIDTH-1:0] mm_wr_data;
    reg [(AXI_DATA_WIDTH/8)-1:0] mm_wr_strb;
    reg mm_rd_en;
    reg [1:0] mm_rd_region;
    reg [31:0] mm_rd_index;
    wire [AXI_DATA_WIDTH-1:0] mm_rd_data;
    wire mm_rd_valid;
    wire mm_rd_error;

    reg signed [7:0] x_mem [0:MAX_COLS-1];
    reg signed [7:0] a_mem [0:(MAX_ROWS*MAX_COLS)-1];

    integer rows;
    integer cols;
    integer col_beats;
    integer pass_cases;
    integer fail_cases;
    integer result_file;

    Matrix_Vector_Multiplication #(
        .NUM_LANES         (NUM_LANES),
        .MAX_ROWS          (MAX_ROWS),
        .MAX_COL_BEATS     (MAX_COL_BEATS),
        .AXI_DATA_WIDTH    (AXI_DATA_WIDTH)
    ) dut (
        .CLK               (CLK),
        .RST               (RST),
        .ctrl_start        (ctrl_start),
        .ctrl_clear_done   (ctrl_clear_done),
        .cfg_rows          (cfg_rows),
        .cfg_cols          (cfg_cols),
        .cfg_col_beats     (cfg_col_beats),
        .cfg_scale         (cfg_scale),
        .compute_mode      (compute_mode),
        .busy              (busy),
        .done              (done),
        .error             (error),
        .active_row        (active_row),
        .active_col_beat   (active_col_beat),
        .mm_wr_en          (mm_wr_en),
        .mm_wr_region      (mm_wr_region),
        .mm_wr_index       (mm_wr_index),
        .mm_wr_data        (mm_wr_data),
        .mm_wr_strb        (mm_wr_strb),
        .mm_rd_en          (mm_rd_en),
        .mm_rd_region      (mm_rd_region),
        .mm_rd_index       (mm_rd_index),
        .mm_rd_data        (mm_rd_data),
        .mm_rd_valid       (mm_rd_valid),
        .mm_rd_error       (mm_rd_error)
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

    task write_word;
        input [1:0] region;
        input [31:0] index;
        input [AXI_DATA_WIDTH-1:0] data;
        begin
            @(posedge CLK);
            #1;
            mm_wr_region <= region;
            mm_wr_index  <= index;
            mm_wr_data   <= data;
            mm_wr_strb   <= 16'hffff;
            mm_wr_en     <= 1'b1;
            @(posedge CLK);
            #1;
            mm_wr_en     <= 1'b0;
            mm_wr_strb   <= 16'h0000;
        end
    endtask

    task read_result;
        input integer row;
        output signed [31:0] value;
        integer timeout;
        begin
            @(posedge CLK);
            #1;
            mm_rd_region <= REGION_RESULT;
            mm_rd_index  <= row;
            mm_rd_en     <= 1'b1;
            @(posedge CLK);
            #1;
            mm_rd_en     <= 1'b0;
            timeout = 0;
            while (!mm_rd_valid && timeout < 20) begin
                @(posedge CLK);
                #1;
                timeout = timeout + 1;
            end
            if (!mm_rd_valid || mm_rd_error) begin
                $display("[FAIL] read_result row=%0d valid=%0d error=%0d", row, mm_rd_valid, mm_rd_error);
                value = 32'sd0;
            end else begin
                value = mm_rd_data[31:0];
            end
        end
    endtask

    task clear_done;
        begin
            @(posedge CLK);
            #1;
            ctrl_clear_done <= 1'b1;
            @(posedge CLK);
            #1;
            ctrl_clear_done <= 1'b0;
        end
    endtask

    task pulse_start;
        begin
            @(posedge CLK);
            #1;
            ctrl_start <= 1'b1;
            @(posedge CLK);
            #1;
            ctrl_start <= 1'b0;
        end
    endtask

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
            col_beats = (cols + NUM_LANES - 1) / NUM_LANES;
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

    task run_case;
        input integer case_id;
        input integer case_rows;
        input integer case_cols;
        integer row;
        integer beat;
        integer timeout;
        integer mismatches;
        reg signed [31:0] got;
        reg signed [31:0] expected;
        begin
            init_case(case_id, case_rows, case_cols);
            clear_done();
            cfg_rows      <= rows[15:0];
            cfg_cols      <= cols[15:0];
            cfg_col_beats <= col_beats[15:0];
            cfg_scale     <= 16'h3c00;
            compute_mode  <= 2'b00;

            for (beat = 0; beat < col_beats; beat = beat + 1)
                write_word(REGION_ACT, beat[31:0], pack_activation(beat));

            for (row = 0; row < rows; row = row + 1) begin
                for (beat = 0; beat < col_beats; beat = beat + 1)
                    write_word(REGION_WEIGHT, row * MAX_COL_BEATS + beat, pack_weight(row, beat));
            end

            pulse_start();
            timeout = 0;
            while (!done && !error && timeout < 100000) begin
                @(posedge CLK);
                #1;
                timeout = timeout + 1;
            end

            mismatches = 0;
            if (timeout >= 100000 || error) begin
                mismatches = rows;
                $display("[FAIL] case=%0d timeout=%0d error=%0d active_row=%0d active_col_beat=%0d",
                         case_id, timeout, error, active_row, active_col_beat);
            end else begin
                for (row = 0; row < rows; row = row + 1) begin
                    read_result(row, got);
                    expected = golden_row(row);
                    if (got !== expected) begin
                        mismatches = mismatches + 1;
                        $display("[FAIL] case=%0d row=%0d got=%0d expected=%0d",
                                 case_id, row, got, expected);
                    end
                end
            end

            if (mismatches == 0) begin
                pass_cases = pass_cases + 1;
                $display("[PASS] case=%0d rows=%0d cols=%0d", case_id, rows, cols);
                $fwrite(result_file, "%0d,%0d,%0d,pass,0\n", case_id, rows, cols);
            end else begin
                fail_cases = fail_cases + 1;
                $fwrite(result_file, "%0d,%0d,%0d,fail,%0d\n", case_id, rows, cols, mismatches);
            end
        end
    endtask

    initial begin
        RST = 1'b0;
        ctrl_start = 1'b0;
        ctrl_clear_done = 1'b0;
        cfg_rows = 16'd0;
        cfg_cols = 16'd0;
        cfg_col_beats = 16'd0;
        cfg_scale = 16'h3c00;
        compute_mode = 2'b00;
        mm_wr_en = 1'b0;
        mm_wr_region = REGION_ACT;
        mm_wr_index = 32'd0;
        mm_wr_data = {AXI_DATA_WIDTH{1'b0}};
        mm_wr_strb = 16'h0000;
        mm_rd_en = 1'b0;
        mm_rd_region = REGION_RESULT;
        mm_rd_index = 32'd0;
        pass_cases = 0;
        fail_cases = 0;

        result_file = $fopen("dsp_matmul_sim_results.csv", "w");
        $fwrite(result_file, "case_id,rows,cols,status,mismatches\n");

        repeat (8) @(posedge CLK);
        #1;
        RST = 1'b1;
        repeat (4) @(posedge CLK);

        if ($test$plusargs("ONLY_CASE17")) begin
            run_case(2, 3, 17);
        end else begin
            run_case(1, 4, 4);
            run_case(2, 3, 17);
            run_case(3, 4, 64);
        end

        $display("[SUMMARY] pass_cases=%0d fail_cases=%0d", pass_cases, fail_cases);
        $fclose(result_file);
        if (fail_cases == 0)
            $finish(0);
        else
            $finish(1);
    end
endmodule
