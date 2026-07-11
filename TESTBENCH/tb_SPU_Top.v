`timescale 1ns/1ps

module tb_SPU_Top;

    localparam integer DATA_WIDTH = 128;
    localparam integer WORD_DEPTH = 64;

    localparam [1:0] REGION_IN      = 2'd0;
    localparam [1:0] REGION_OUT     = 2'd1;
    localparam [1:0] REGION_PARAM   = 2'd2;
    localparam [1:0] REGION_SCRATCH = 2'd3;

    localparam [7:0] SPU_MODE_QUANT_Q8_0 = 8'd1;
    localparam [7:0] SPU_MODE_SILU_MUL   = 8'd2;
    localparam [7:0] SPU_MODE_RMSNORM    = 8'd3;
    localparam [7:0] SPU_MODE_ROPE       = 8'd4;
    localparam [7:0] SPU_MODE_SOFTMAX    = 8'd5;
    localparam [7:0] SPU_MODE_Q8_SCALE_ACCUM = 8'd6;
    localparam [7:0] SPU_MODE_COPY       = 8'h7f;

    reg clk;
    reg resetn;

    reg        spu_start;
    reg        spu_clear_done;
    reg        spu_soft_reset;
    reg [7:0]  spu_mode;
    reg [31:0] spu_len;
    reg [31:0] spu_aux0;
    reg [31:0] spu_aux1;

    wire        spu_busy;
    wire        spu_done;
    wire        spu_error;
    wire [7:0]  spu_error_code;
    wire [31:0] spu_caps;

    reg                              mm_wr_en;
    reg [1:0]                        mm_wr_region;
    reg [31:0]                       mm_wr_index;
    reg [DATA_WIDTH-1:0]             mm_wr_data;
    reg [(DATA_WIDTH/8)-1:0]         mm_wr_strb;

    reg                              mm_rd_en;
    reg [1:0]                        mm_rd_region;
    reg [31:0]                       mm_rd_index;
    wire [DATA_WIDTH-1:0]            mm_rd_data;
    wire                             mm_rd_valid;
    wire                             mm_rd_error;

    integer pass_count;
    integer fail_count;
    integer timeout;
    integer lane;
    integer sample_i;
    reg signed [15:0] samples [0:31];

    SPU_Top #(
        .AXI_DATA_WIDTH (DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH)
    ) dut (
        .clk             (clk),
        .resetn          (resetn),
        .spu_start       (spu_start),
        .spu_clear_done  (spu_clear_done),
        .spu_soft_reset  (spu_soft_reset),
        .spu_mode        (spu_mode),
        .spu_len         (spu_len),
        .spu_aux0        (spu_aux0),
        .spu_aux1        (spu_aux1),
        .spu_busy        (spu_busy),
        .spu_done        (spu_done),
        .spu_error       (spu_error),
        .spu_error_code  (spu_error_code),
        .spu_caps        (spu_caps),
        .mm_wr_en        (mm_wr_en),
        .mm_wr_region    (mm_wr_region),
        .mm_wr_index     (mm_wr_index),
        .mm_wr_data      (mm_wr_data),
        .mm_wr_strb      (mm_wr_strb),
        .mm_rd_en        (mm_rd_en),
        .mm_rd_region    (mm_rd_region),
        .mm_rd_index     (mm_rd_index),
        .mm_rd_data      (mm_rd_data),
        .mm_rd_valid     (mm_rd_valid),
        .mm_rd_error     (mm_rd_error)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task fail;
        input [255:0] message;
        begin
            fail_count = fail_count + 1;
            $display("[TB][FAIL] %0s", message);
        end
    endtask

    task mm_write;
        input [1:0] region;
        input [31:0] index;
        input [DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);
            mm_wr_region <= region;
            mm_wr_index  <= index;
            mm_wr_data   <= data;
            mm_wr_strb   <= 16'hffff;
            mm_wr_en     <= 1'b1;
            @(posedge clk);
            mm_wr_en     <= 1'b0;
            mm_wr_strb   <= 16'h0000;
            mm_wr_data   <= {DATA_WIDTH{1'b0}};
        end
    endtask

    task mm_read;
        input [1:0] region;
        input [31:0] index;
        output [DATA_WIDTH-1:0] data;
        begin
            @(posedge clk);
            mm_rd_region <= region;
            mm_rd_index  <= index;
            mm_rd_en     <= 1'b1;
            @(posedge clk);
            mm_rd_en     <= 1'b0;

            timeout = 0;
            while (!mm_rd_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 20) begin
                    fail("SPU memory read timeout");
                    timeout = 0;
                end
            end

            data = mm_rd_data;
            if (mm_rd_error)
                fail("SPU memory read returned error");
        end
    endtask

    task start_and_wait;
        input [7:0] mode;
        input [31:0] len;
        begin
            @(posedge clk);
            spu_mode  <= mode;
            spu_len   <= len;
            spu_start <= 1'b1;
            @(posedge clk);
            spu_start <= 1'b0;

            timeout = 0;
            while (!spu_done) begin
                @(posedge clk);
                timeout = timeout + 1;
                // Exact restoring division processes a q8 block serially.
                // Keep the test timeout above its expected 800-cycle latency.
                if (timeout > 5000) begin
                    fail("SPU command timeout");
                    timeout = 0;
                end
            end

            if (spu_error) begin
                $display("[TB][FAIL] SPU command error_code=%0d", spu_error_code);
                fail_count = fail_count + 1;
            end

            @(posedge clk);
            spu_clear_done <= 1'b1;
            @(posedge clk);
            spu_clear_done <= 1'b0;
        end
    endtask

    function [DATA_WIDTH-1:0] pack_i16_word;
        input integer base;
        integer i;
        begin
            pack_i16_word = {DATA_WIDTH{1'b0}};
            for (i = 0; i < 8; i = i + 1)
                pack_i16_word[16*i +: 16] = samples[base + i];
        end
    endfunction

    function [DATA_WIDTH-1:0] pack_scale_entry;
        input signed [31:0] raw;
        input [15:0] act_scale;
        input [15:0] weight_scale;
        input [15:0] row_id;
        input clear_accum;
        input last_block;
        begin
            pack_scale_entry = {DATA_WIDTH{1'b0}};
            pack_scale_entry[31:0] = raw;
            pack_scale_entry[47:32] = act_scale;
            pack_scale_entry[63:48] = weight_scale;
            pack_scale_entry[79:64] = row_id;
            pack_scale_entry[80] = last_block;
            pack_scale_entry[81] = clear_accum;
        end
    endfunction

    function [15:0] abs16;
        input signed [15:0] value;
        begin
            if (value == -16'sd32768)
                abs16 = 16'd32768;
            else if (value < 0)
                abs16 = 16'd0 - value[15:0];
            else
                abs16 = value[15:0];
        end
    endfunction

    function [7:0] expected_q;
        input signed [15:0] value;
        input integer max_abs;
        integer signed numerator;
        integer signed rounded;
        begin
            if (max_abs == 0) begin
                rounded = 0;
            end else begin
                numerator = value * 127;
                if (numerator >= 0)
                    rounded = (numerator + (max_abs / 2)) / max_abs;
                else
                    rounded = (numerator - (max_abs / 2)) / max_abs;
            end

            if (rounded > 127)
                expected_q = 8'sd127;
            else if (rounded < -128)
                expected_q = -8'sd128;
            else
                expected_q = rounded[7:0];
        end
    endfunction

    task run_copy_case;
        reg [DATA_WIDTH-1:0] got0;
        reg [DATA_WIDTH-1:0] got1;
        begin
            $display("[TB] COPY self-test");
            mm_write(REGION_IN, 0, 128'h0123_4567_89ab_cdef_1111_2222_3333_4444);
            mm_write(REGION_IN, 1, 128'hfeed_face_cafe_beef_5555_6666_7777_8888);
            start_and_wait(SPU_MODE_COPY, 32'd2);
            mm_read(REGION_OUT, 0, got0);
            mm_read(REGION_OUT, 1, got1);

            if (got0 !== 128'h0123_4567_89ab_cdef_1111_2222_3333_4444)
                fail("COPY output word 0 mismatch");
            else
                pass_count = pass_count + 1;

            if (got1 !== 128'hfeed_face_cafe_beef_5555_6666_7777_8888)
                fail("COPY output word 1 mismatch");
            else
                pass_count = pass_count + 1;
        end
    endtask

    task run_quant_case;
        reg [DATA_WIDTH-1:0] out0;
        reg [DATA_WIDTH-1:0] out1;
        reg [DATA_WIDTH-1:0] scratch0;
        integer max_abs;
        reg [7:0] got_q;
        reg [7:0] exp_q;
        begin
            $display("[TB] QUANT_Q8_0 fixed-point payload test");
            for (sample_i = 0; sample_i < 32; sample_i = sample_i + 1)
                samples[sample_i] = (sample_i - 16) * 4;

            for (sample_i = 0; sample_i < 4; sample_i = sample_i + 1)
                mm_write(REGION_IN, sample_i, pack_i16_word(sample_i * 8));

            start_and_wait(SPU_MODE_QUANT_Q8_0, 32'd32);
            mm_read(REGION_OUT, 0, out0);
            mm_read(REGION_OUT, 1, out1);
            mm_read(REGION_SCRATCH, 0, scratch0);

            max_abs = 0;
            for (sample_i = 0; sample_i < 32; sample_i = sample_i + 1)
                if (abs16(samples[sample_i]) > max_abs)
                    max_abs = abs16(samples[sample_i]);

            if (scratch0[15:0] !== max_abs[15:0])
                fail("QUANT amax scratch mismatch");
            else
                pass_count = pass_count + 1;

            for (lane = 0; lane < 32; lane = lane + 1) begin
                got_q = (lane < 16) ? out0[8*lane +: 8] :
                                      out1[8*(lane-16) +: 8];
                exp_q = expected_q(samples[lane], max_abs);
                if (got_q !== exp_q) begin
                    $display("[TB][FAIL] lane=%0d got=%0d expected=%0d",
                             lane, $signed(got_q), $signed(exp_q));
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    task run_scale_accum_case;
        reg [DATA_WIDTH-1:0] out0;
        reg [DATA_WIDTH-1:0] out1;
        reg [DATA_WIDTH-1:0] status0;
        reg signed [63:0] got_accum;
        begin
            $display("[TB] Q8 scale-accumulate mixed-scale test");
            mm_write(REGION_IN, 0, pack_scale_entry(32'sd32, 16'h3800, 16'h3400, 16'd0, 1'b1, 1'b0));
            mm_write(REGION_IN, 1, pack_scale_entry(32'sd32, 16'h3800, 16'h3800, 16'd0, 1'b0, 1'b1));
            mm_write(REGION_IN, 2, pack_scale_entry(-32'sd64, 16'h3c00, 16'h3000, 16'd1, 1'b1, 1'b1));

            start_and_wait(SPU_MODE_Q8_SCALE_ACCUM, 32'd3);
            mm_read(REGION_OUT, 0, out0);
            mm_read(REGION_OUT, 1, out1);
            mm_read(REGION_SCRATCH, 0, status0);

            if (status0[31:0] !== 32'd2)
                fail("Q8 scale-accumulate output count mismatch");
            else
                pass_count = pass_count + 1;

            if (out0[15:0] !== 16'd0)
                fail("Q8 scale-accumulate row 0 id mismatch");
            else
                pass_count = pass_count + 1;
            got_accum = out0[79:16];
            if (got_accum !== 64'sd786432) begin
                $display("[TB][FAIL] row0 accum_q16 got=%0d expected=%0d", got_accum, 64'sd786432);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end

            if (out1[15:0] !== 16'd1)
                fail("Q8 scale-accumulate row 1 id mismatch");
            else
                pass_count = pass_count + 1;
            got_accum = out1[79:16];
            if (got_accum !== -64'sd524288) begin
                $display("[TB][FAIL] row1 accum_q16 got=%0d expected=%0d", got_accum, -64'sd524288);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    task run_scale_accum_bad_scale_case;
        begin
            $display("[TB] Q8 scale-accumulate bad-scale rejection");
            mm_write(REGION_IN, 0, pack_scale_entry(32'sd1, 16'hbc00, 16'h3c00, 16'd0, 1'b1, 1'b1));

            @(posedge clk);
            spu_mode  <= SPU_MODE_Q8_SCALE_ACCUM;
            spu_len   <= 32'd1;
            spu_start <= 1'b1;
            @(posedge clk);
            spu_start <= 1'b0;

            timeout = 0;
            while (!spu_done) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("Q8 scale-accumulate bad-scale timeout");
                    timeout = 0;
                end
            end

            if (!spu_error || spu_error_code !== 8'd4)
                fail("Q8 scale-accumulate bad scale did not report ERR_BAD_SCALE");
            else
                pass_count = pass_count + 1;

            @(posedge clk);
            spu_clear_done <= 1'b1;
            @(posedge clk);
            spu_clear_done <= 1'b0;
        end
    endtask

    task run_scale_accum_row_range_case;
        begin
            $display("[TB] Q8 scale-accumulate row-range rejection");
            mm_write(REGION_IN, 0, pack_scale_entry(32'sd1, 16'h3c00, 16'h3c00, 16'd256, 1'b1, 1'b1));

            @(posedge clk);
            spu_mode  <= SPU_MODE_Q8_SCALE_ACCUM;
            spu_len   <= 32'd1;
            spu_start <= 1'b1;
            @(posedge clk);
            spu_start <= 1'b0;

            timeout = 0;
            while (!spu_done) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("Q8 scale-accumulate row-range timeout");
                    timeout = 0;
                end
            end

            if (!spu_error || spu_error_code !== 8'd3)
                fail("Q8 scale-accumulate row range did not report ERR_RANGE");
            else
                pass_count = pass_count + 1;

            @(posedge clk);
            spu_clear_done <= 1'b1;
            @(posedge clk);
            spu_clear_done <= 1'b0;
        end
    endtask

    task run_marker_mode;
        input [7:0] mode;
        input [127:0] label;
        begin
            $display("[TB] %0s reserved command rejection", label);
            @(posedge clk);
            spu_mode  <= mode;
            spu_len   <= 32'd1;
            spu_start <= 1'b1;
            @(posedge clk);
            spu_start <= 1'b0;

            timeout = 0;
            while (!spu_done) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 20) begin
                    fail("reserved SPU command timeout");
                    timeout = 0;
                end
            end

            if (!spu_error || spu_error_code !== 8'd1)
                fail("reserved SPU command did not report ERR_BAD_MODE");
            else
                pass_count = pass_count + 1;

            @(posedge clk);
            spu_clear_done <= 1'b1;
            @(posedge clk);
            spu_clear_done <= 1'b0;
        end
    endtask

    initial begin
        resetn = 1'b0;
        spu_start = 1'b0;
        spu_clear_done = 1'b0;
        spu_soft_reset = 1'b0;
        spu_mode = 8'd0;
        spu_len = 32'd0;
        spu_aux0 = 32'd0;
        spu_aux1 = 32'd0;
        mm_wr_en = 1'b0;
        mm_wr_region = REGION_IN;
        mm_wr_index = 32'd0;
        mm_wr_data = {DATA_WIDTH{1'b0}};
        mm_wr_strb = 16'h0000;
        mm_rd_en = 1'b0;
        mm_rd_region = REGION_OUT;
        mm_rd_index = 32'd0;
        pass_count = 0;
        fail_count = 0;

        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (3) @(posedge clk);

        if (spu_caps[0] !== 1'b1 || spu_caps[1] !== 1'b1 ||
            spu_caps[2] !== 1'b0 || spu_caps[3] !== 1'b0 ||
            spu_caps[4] !== 1'b0 || spu_caps[5] !== 1'b0 ||
            spu_caps[6] !== 1'b1 || spu_caps[7] !== 1'b1)
            fail("SPU capability bits are not set as expected");
        else
            pass_count = pass_count + 1;

        run_copy_case();
        run_quant_case();
        run_scale_accum_case();
        run_scale_accum_bad_scale_case();
        run_scale_accum_row_range_case();
        run_marker_mode(SPU_MODE_SILU_MUL, "SPU_SiLU_Mul");
        run_marker_mode(SPU_MODE_RMSNORM, "SPU_RMSNorm");
        run_marker_mode(SPU_MODE_ROPE, "SPU_RoPE");
        run_marker_mode(SPU_MODE_SOFTMAX, "SPU_Softmax");

        if (fail_count == 0) begin
            $display("[TB][PASS] SPU_Top tests passed pass_count=%0d", pass_count);
        end else begin
            $display("[TB][FAIL] SPU_Top tests failed pass_count=%0d fail_count=%0d",
                     pass_count, fail_count);
            $fatal(1, "SPU testbench observed %0d failures", fail_count);
        end
        $finish;
    end

endmodule
