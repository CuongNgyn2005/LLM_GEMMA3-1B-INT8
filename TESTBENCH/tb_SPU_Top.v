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
    reg         stream_split_scale_enable;
    wire        vpu_raw_ready;
    wire [31:0] vpu_stream_count;
    wire [31:0] vpu_stream_done_count;
    wire [31:0] vpu_stream_drop_count;
    wire [31:0] vpu_stream_out_count;
    wire [31:0] vpu_stream_error_count;
    wire [31:0] vpu_stream_last_raw;
    wire [31:0] vpu_stream_last_meta;
    wire [31:0] vpu_stream_last_accum_lo;
    wire [31:0] vpu_stream_last_accum_hi;
    wire [31:0] vpu_stream_last_job;
    wire [31:0] vpu_stream_last_bank;
    wire [31:0] vpu_stream_status;
    wire [31:0] vpu_stream_fifo_high_water;
    wire [31:0] vpu_stream_raw_stall_cycles;
    wire [31:0] vpu_stream_entry_done_count;
    wire [31:0] vpu_stream_final_write_count;
    wire [31:0] vpu_stream_p3_reject_count;
    wire [31:0] vpu_stream_p3_status;
    reg vpu_raw_valid;
    reg signed [31:0] vpu_raw_data;
    reg [15:0] vpu_raw_row;
    reg [15:0] vpu_raw_block;
    reg [15:0] vpu_raw_group_blocks;
    reg vpu_raw_last_block;
    reg vpu_raw_clear_accum;
    reg [31:0] vpu_raw_job_id;
    reg vpu_raw_bank;
    reg vpu_raw_done;
    reg vpu_raw_pair_valid;
    reg signed [31:0] vpu_raw_pair_data;
    reg [15:0] vpu_raw_pair_row, vpu_raw_pair_block, vpu_raw_pair_group_blocks;
    reg vpu_raw_pair_last_block, vpu_raw_pair_clear_accum;
    reg [31:0] vpu_raw_pair_job_id;
    reg vpu_raw_pair_bank;

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
    reg signed [15:0] params [0:31];

    SPU_Top #(
        .AXI_DATA_WIDTH (DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH),
        .STREAM_TEST_STALL_ENABLE (1)
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
        .stream_split_scale_enable(stream_split_scale_enable),
        .vpu_raw_valid   (vpu_raw_valid),
        .vpu_raw_ready   (vpu_raw_ready),
        .vpu_raw_data    (vpu_raw_data),
        .vpu_raw_row     (vpu_raw_row),
        .vpu_raw_block   (vpu_raw_block),
        .vpu_raw_group_blocks(vpu_raw_group_blocks),
        .vpu_raw_last_block(vpu_raw_last_block),
        .vpu_raw_clear_accum(vpu_raw_clear_accum),
        .vpu_raw_job_id  (vpu_raw_job_id),
        .vpu_raw_bank    (vpu_raw_bank),
        .vpu_raw_done    (vpu_raw_done),
        .vpu_raw_pair_valid(vpu_raw_pair_valid), .vpu_raw_pair_data(vpu_raw_pair_data),
        .vpu_raw_pair_row(vpu_raw_pair_row), .vpu_raw_pair_block(vpu_raw_pair_block),
        .vpu_raw_pair_group_blocks(vpu_raw_pair_group_blocks), .vpu_raw_pair_last_block(vpu_raw_pair_last_block),
        .vpu_raw_pair_clear_accum(vpu_raw_pair_clear_accum), .vpu_raw_pair_job_id(vpu_raw_pair_job_id),
        .vpu_raw_pair_bank(vpu_raw_pair_bank),
        .vpu_stream_count(vpu_stream_count),
        .vpu_stream_done_count(vpu_stream_done_count),
        .vpu_stream_drop_count(vpu_stream_drop_count),
        .vpu_stream_out_count(vpu_stream_out_count),
        .vpu_stream_error_count(vpu_stream_error_count),
        .vpu_stream_last_raw(vpu_stream_last_raw),
        .vpu_stream_last_meta(vpu_stream_last_meta),
        .vpu_stream_last_accum_lo(vpu_stream_last_accum_lo),
        .vpu_stream_last_accum_hi(vpu_stream_last_accum_hi),
        .vpu_stream_last_job(vpu_stream_last_job),
        .vpu_stream_last_bank(vpu_stream_last_bank),
        .vpu_stream_status(vpu_stream_status),
        .vpu_stream_fifo_high_water(vpu_stream_fifo_high_water),
        .vpu_stream_raw_stall_cycles(vpu_stream_raw_stall_cycles),
        .vpu_stream_entry_done_count(vpu_stream_entry_done_count),
        .vpu_stream_final_write_count(vpu_stream_final_write_count),
        .vpu_stream_p3_reject_count(vpu_stream_p3_reject_count),
        .vpu_stream_p3_status(vpu_stream_p3_status),
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

    function [DATA_WIDTH-1:0] pack_param_word;
        input integer base;
        integer i;
        begin
            pack_param_word = {DATA_WIDTH{1'b0}};
            for (i = 0; i < 8; i = i + 1)
                pack_param_word[16*i +: 16] = params[base + i];
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

    function signed [15:0] sat16_tb;
        input signed [63:0] value;
        begin
            if (value > 64'sd32767)
                sat16_tb = 16'sd32767;
            else if (value < -64'sd32768)
                sat16_tb = -16'sd32768;
            else
                sat16_tb = value[15:0];
        end
    endfunction

    function signed [15:0] expected_silu_mul;
        input signed [15:0] gate_q8;
        input signed [15:0] up_q8;
        reg signed [31:0] sigmoid_q15;
        reg signed [63:0] silu_q8;
        reg signed [63:0] result_q8;
        begin
            if (gate_q8 >= 16'sd1024)
                sigmoid_q15 = 32'sd32768;
            else if (gate_q8 <= -16'sd1024)
                sigmoid_q15 = 32'sd0;
            else
                sigmoid_q15 = 32'sd16384 + ($signed(gate_q8) <<< 4);

            silu_q8 = ($signed(gate_q8) * sigmoid_q15) >>> 15;
            result_q8 = (silu_q8 * $signed(up_q8)) >>> 8;
            expected_silu_mul = sat16_tb(result_q8);
        end
    endfunction

    function signed [15:0] expected_rope_lane;
        input signed [15:0] x0_q8;
        input signed [15:0] x1_q8;
        input signed [15:0] cos_q15;
        input signed [15:0] sin_q15;
        input integer lane_sel;
        reg signed [63:0] y0_q8;
        reg signed [63:0] y1_q8;
        reg signed [31:0] x0_ext;
        reg signed [31:0] x1_ext;
        reg signed [31:0] cos_ext;
        reg signed [31:0] sin_ext;
        begin
            x0_ext = {{16{x0_q8[15]}}, x0_q8};
            x1_ext = {{16{x1_q8[15]}}, x1_q8};
            cos_ext = {{16{cos_q15[15]}}, cos_q15};
            sin_ext = {{16{sin_q15[15]}}, sin_q15};
            y0_q8 = ((x0_ext * cos_ext) - (x1_ext * sin_ext)) >>> 15;
            y1_q8 = ((x0_ext * sin_ext) + (x1_ext * cos_ext)) >>> 15;
            expected_rope_lane = lane_sel ? sat16_tb(y1_q8) : sat16_tb(y0_q8);
        end
    endfunction

    function [31:0] isqrt64_tb;
        input [63:0] value;
        reg [31:0] result;
        reg [31:0] trial;
        integer bit_i;
        begin
            result = 32'd0;
            for (bit_i = 31; bit_i >= 0; bit_i = bit_i - 1) begin
                trial = result | (32'd1 << bit_i);
                if ({32'd0, trial} * {32'd0, trial} <= value)
                    result = trial;
            end
            isqrt64_tb = result;
        end
    endfunction

    function [31:0] expected_rms_inv;
        input [63:0] sumsq_q16;
        input [31:0] element_count;
        reg [63:0] mean_q16;
        reg [31:0] sqrt_q8;
        begin
            mean_q16 = (sumsq_q16 / element_count) + 64'd1;
            sqrt_q8 = isqrt64_tb(mean_q16);
            if (sqrt_q8 == 32'd0)
                expected_rms_inv = 32'h7fff_ffff;
            else
                expected_rms_inv = 64'd8388608 / sqrt_q8;
        end
    endfunction

    function signed [15:0] expected_rms_lane;
        input signed [15:0] value_q8;
        input signed [15:0] weight_q8;
        input [31:0] inv_q15;
        reg signed [63:0] prod;
        reg signed [31:0] value_ext;
        reg signed [31:0] weight_ext;
        begin
            value_ext = {{16{value_q8[15]}}, value_q8};
            weight_ext = {{16{weight_q8[15]}}, weight_q8};
            prod = value_ext * weight_ext;
            prod = (prod * $signed({1'b0, inv_q15[30:0]})) >>> 23;
            expected_rms_lane = sat16_tb(prod);
        end
    endfunction

    function [15:0] expected_soft_score;
        input signed [15:0] delta_q8;
        begin
            if (delta_q8 >= 16'sd0)
                expected_soft_score = 16'd32768;
            else if (delta_q8 >= -16'sd128)
                expected_soft_score = 16'd19872;
            else if (delta_q8 >= -16'sd256)
                expected_soft_score = 16'd12055;
            else if (delta_q8 >= -16'sd384)
                expected_soft_score = 16'd7310;
            else if (delta_q8 >= -16'sd512)
                expected_soft_score = 16'd4435;
            else if (delta_q8 >= -16'sd640)
                expected_soft_score = 16'd2690;
            else if (delta_q8 >= -16'sd768)
                expected_soft_score = 16'd1631;
            else if (delta_q8 >= -16'sd896)
                expected_soft_score = 16'd989;
            else if (delta_q8 >= -16'sd1024)
                expected_soft_score = 16'd600;
            else if (delta_q8 >= -16'sd1280)
                expected_soft_score = 16'd221;
            else if (delta_q8 >= -16'sd1536)
                expected_soft_score = 16'd81;
            else if (delta_q8 >= -16'sd1792)
                expected_soft_score = 16'd30;
            else if (delta_q8 >= -16'sd2048)
                expected_soft_score = 16'd11;
            else
                expected_soft_score = 16'd0;
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

    // Drive one true ready/valid VPU raw-stream transfer.  The payload stays
    // stable from the falling edge before acceptance through the following
    // rising edge, matching the upstream VPU contract.
    task stream_push_entry;
        input signed [31:0] raw;
        input [15:0] row;
        input [15:0] block;
        input [15:0] group_blocks;
        input last_block;
        input clear_accum;
        input [31:0] job_id;
        input bank;
        reg accepted;
        begin
            while (!vpu_raw_ready)
                @(posedge clk);
            @(negedge clk);
            vpu_raw_data         = raw;
            vpu_raw_row          = row;
            vpu_raw_block        = block;
            vpu_raw_group_blocks = group_blocks;
            vpu_raw_last_block   = last_block;
            vpu_raw_clear_accum  = clear_accum;
            vpu_raw_job_id       = job_id;
            vpu_raw_bank         = bank;
            vpu_raw_valid        = 1'b1;
            // ready is allowed to change after a prior queue operation.  Hold
            // the full payload until the real ready/valid handshake instead
            // of assuming the next edge will accept it.
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (vpu_raw_ready)
                    accepted = 1'b1;
            end
            @(negedge clk);
            vpu_raw_valid = 1'b0;
        end
    endtask

    task wait_for_stream_error_count;
        input [31:0] expected;
        begin
            timeout = 0;
            while (vpu_stream_error_count != expected) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 300) begin
                    fail("VPU raw stream error-count timeout");
                    timeout = 0;
                end
            end
        end
    endtask

    task run_stream_soft_reset_abort_case;
        begin
            $display("[TB] VPU stream soft-reset aborts in-flight Q8 accumulator");
            mm_write(REGION_PARAM, 0,
                     {96'd0, 16'h3c00, 16'h3c00});
            stream_push_entry(32'sd17, 16'd0, 16'd0, 16'd2,
                              1'b0, 1'b1, 32'h0000_aa01, 1'b0);
            timeout = 0;
            while (!dut.stream_accum_busy) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    fail("soft-reset test did not observe accumulator busy");
                    timeout = 0;
                end
            end

            @(negedge clk);
            spu_soft_reset = 1'b1;
            @(posedge clk);
            @(negedge clk);
            spu_soft_reset = 1'b0;
            #1;

            if (dut.stream_accum_busy || dut.stream_accum_pair_busy)
                fail("SPU soft reset left a Q8 stream accumulator in flight");
            else
                pass_count = pass_count + 1;
            if (vpu_stream_status[4] !== 1'b1)
                fail("SPU soft reset did not restore true stream quiescence");
            else
                pass_count = pass_count + 1;
        end
    endtask

    task run_vpu_stream_pair_case;
        reg [DATA_WIDTH-1:0] out0, out1;
        reg [31:0] count_before, out_before, err_before;
        begin
            $display("[TB] P2-v2 paired raw-stream dual-scale/output test");
            // rows 0/1, one block each, distinct scales: 1.0 and 0.5.
            mm_write(REGION_PARAM, 0,
                     {32'h3c00_3c00, 32'h3c00_3c00, 32'h3c00_3800, 32'h3c00_3c00});
            count_before = vpu_stream_count;
            out_before = vpu_stream_out_count;
            err_before = vpu_stream_error_count;
            while (!vpu_raw_ready) @(posedge clk);
            @(negedge clk);
            vpu_raw_data = 32'sd3; vpu_raw_row = 16'd0; vpu_raw_block = 16'd0;
            vpu_raw_group_blocks = 16'd1; vpu_raw_last_block = 1'b1;
            vpu_raw_clear_accum = 1'b1; vpu_raw_job_id = 32'h55; vpu_raw_bank = 1'b1;
            vpu_raw_pair_valid = 1'b1; vpu_raw_pair_data = -32'sd4;
            vpu_raw_pair_row = 16'd1; vpu_raw_pair_block = 16'd0;
            vpu_raw_pair_group_blocks = 16'd1; vpu_raw_pair_last_block = 1'b1;
            vpu_raw_pair_clear_accum = 1'b1; vpu_raw_pair_job_id = 32'h55;
            vpu_raw_pair_bank = 1'b1; vpu_raw_valid = 1'b1;
            @(posedge clk);
            if (!vpu_raw_ready) fail("P2-v2 pair was not atomically accepted");
            @(negedge clk); vpu_raw_valid = 1'b0; vpu_raw_pair_valid = 1'b0;
            wait_for_stream_out_count(out_before + 32'd2);
            if (vpu_stream_count != count_before + 32'd2 ||
                vpu_stream_error_count != err_before)
                fail("P2-v2 pair count/error contract mismatch");
            else pass_count = pass_count + 1;
            mm_read(REGION_OUT, 0, out0); mm_read(REGION_OUT, 1, out1);
            if (out0[15:0] !== 16'd0 || out0[79:16] !== 64'sd196608 ||
                out1[15:0] !== 16'd1 || out1[79:16] !== -64'sd131072)
                fail("P2-v2 pair dual-scale SPU_OUT mismatch");
            else pass_count = pass_count + 1;
        end
    endtask

    task run_vpu_stream_p3_split_scale_case;
        reg [DATA_WIDTH-1:0] out_word;
        reg [DATA_WIDTH-1:0] param_before;
        reg [DATA_WIDTH-1:0] inactive_param_before;
        reg [31:0] out_before;
        reg [31:0] reject_before;
        reg [31:0] done_before;
        reg [31:0] stall_before;
        reg        p3_pair_accepted;
        begin
            $display("[TB] P3 dense split-scale bank/ownership test");
            // Bank 0, PARAM: row0=1.0, row1=0.5, row2=1.0.  SCRATCH
            // block0=1.0, block1=min-subnormal.  Eight FP16 values occupy
            // each 128-bit word; this is intentionally different from P2's
            // four packed {weight,activation} 32-bit entries.
            mm_write(REGION_PARAM, 0,
                     {16'h0000,16'h0000,16'h0000,16'h0000,
                      16'h0000,16'h0000,16'h3800,16'h3c00});
            mm_write(REGION_PARAM, 1,
                     {16'h0000,16'h0000,16'h0000,16'h0000,
                      16'h0000,16'h0000,16'h3c00,16'h0000});
            // Inactive bank sentinel for the explicit port-A arbitration
            // regression below.  This must survive a colliding P3 pair read.
            mm_write(REGION_PARAM, 32, 128'h1111_2222_3333_4444_5555_6666_7777_8888);
            mm_write(REGION_SCRATCH, 0,
                     {16'h0000,16'h0000,16'h0000,16'h0000,
                      16'h0000,16'h0000,16'h0000,16'h0001});
            // Correct lane order for the test vectors is written explicitly
            // below: lane0=1.0 and lane1=min-subnormal.
            mm_write(REGION_SCRATCH, 0,
                     {16'h0000,16'h0000,16'h0000,16'h0000,
                      16'h0000,16'h0000,16'h0001,16'h3c00});

            stream_split_scale_enable = 1'b1;
            repeat (2) @(posedge clk);
            out_before = vpu_stream_out_count;
            reject_before = vpu_stream_p3_reject_count;
            done_before = vpu_stream_entry_done_count;
            stall_before = vpu_stream_raw_stall_cycles;

            // Atomic primary/companion pair, normal scales.
            while (!vpu_raw_ready) @(posedge clk);
            @(negedge clk);
            vpu_raw_data = 32'sd3; vpu_raw_row = 16'd0; vpu_raw_block = 16'd0;
            vpu_raw_group_blocks = 16'd1; vpu_raw_last_block = 1'b1;
            vpu_raw_clear_accum = 1'b1; vpu_raw_job_id = 32'h5033_0001; vpu_raw_bank = 1'b0;
            vpu_raw_pair_valid = 1'b1; vpu_raw_pair_data = -32'sd4;
            vpu_raw_pair_row = 16'd1; vpu_raw_pair_block = 16'd0;
            vpu_raw_pair_group_blocks = 16'd1; vpu_raw_pair_last_block = 1'b1;
            vpu_raw_pair_clear_accum = 1'b1; vpu_raw_pair_job_id = 32'h5033_0001;
            vpu_raw_pair_bank = 1'b0; vpu_raw_valid = 1'b1;
            @(posedge clk);
            @(negedge clk); vpu_raw_valid = 1'b0; vpu_raw_pair_valid = 1'b0;

            // While the paired P3 PARAM reads own both PARAM ports, an MMIO
            // write to otherwise-inactive PARAM bank1 is serialized/rejected.
            // It must never reuse the core2 read address with MMIO strobes.
            timeout = 0;
            // Sample on the falling edge.  Sampling immediately after a
            // rising edge observes pre-NBA state and can miss READ_SCALE.
            while (dut.stream_state_r != 3'd1) begin
                @(negedge clk); timeout = timeout + 1;
                if (timeout > 50) begin
                    fail("P3 paired PARAM read state was not reached");
                    timeout = 0;
                end
            end
            inactive_param_before = 128'h1111_2222_3333_4444_5555_6666_7777_8888;
            mm_wr_region = REGION_PARAM;
            mm_wr_index = 32'd32;
            mm_wr_data = {DATA_WIDTH{1'b0}};
            mm_wr_strb = 16'hffff;
            mm_wr_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mm_wr_en = 1'b0;
            mm_wr_strb = 16'h0000;
            if (vpu_stream_p3_reject_count != reject_before + 32'd1)
                fail("P3 concurrent inactive PARAM write was not visibly serialized");
            else
                pass_count = pass_count + 1;
            mm_read(REGION_PARAM, 32, out_word);
            if (out_word !== inactive_param_before)
                fail("P3 concurrent inactive PARAM write corrupted a core2 read address");
            else
                pass_count = pass_count + 1;
            // The next check is an independent ownership violation, so use
            // the counter value after the port-arbitration rejection above.
            reject_before = vpu_stream_p3_reject_count;

            // The bank is locked before completion.  A host PARAM write to
            // that same bank must be rejected and must not alter the scale.
            mm_read(REGION_PARAM, 0, param_before);
            mm_write(REGION_PARAM, 0, {DATA_WIDTH{1'b1}});
            @(posedge clk);
            if (vpu_stream_p3_reject_count != reject_before + 32'd1)
            begin
                $display("[TB][DBG] P3 reject got=%0d expected=%0d lock=%b status=%h",
                         vpu_stream_p3_reject_count, reject_before + 32'd1,
                         vpu_stream_status[5], vpu_stream_p3_status);
                fail("P3 active-bank PARAM write was not visibly rejected");
            end
            else
                pass_count = pass_count + 1;
            mm_read(REGION_PARAM, 0, out_word);
            if (out_word !== param_before)
                fail("P3 active-bank PARAM write corrupted immutable scale");
            else
                pass_count = pass_count + 1;

            // Zero and subnormal activation scales are finite legal Q8_0
            // scales.  Their small Q16.16 contribution rounds to zero, but
            // they must not raise a scale-format error or lose final writes.
            // Force producer backpressure in P3 mode and prove both members
            // of the offered pair remain stable until the atomic handshake.
            force dut.stream_test_stall_count_r = 6'd4;
            @(negedge clk);
            vpu_raw_data = 32'sd17; vpu_raw_row = 16'd2; vpu_raw_block = 16'd0;
            vpu_raw_group_blocks = 16'd1; vpu_raw_last_block = 1'b1;
            vpu_raw_clear_accum = 1'b1; vpu_raw_job_id = 32'h5033_0002; vpu_raw_bank = 1'b0;
            vpu_raw_pair_valid = 1'b1; vpu_raw_pair_data = -32'sd9;
            vpu_raw_pair_row = 16'd3; vpu_raw_pair_block = 16'd0;
            vpu_raw_pair_group_blocks = 16'd1; vpu_raw_pair_last_block = 1'b1;
            vpu_raw_pair_clear_accum = 1'b1; vpu_raw_pair_job_id = 32'h5033_0002;
            vpu_raw_pair_bank = 1'b0; vpu_raw_valid = 1'b1;
            repeat (3) begin
                @(posedge clk);
                if (vpu_raw_ready || vpu_raw_data !== 32'sd17 ||
                    vpu_raw_row !== 16'd2 || vpu_raw_pair_data !== -32'sd9 ||
                    vpu_raw_pair_row !== 16'd3 || !vpu_raw_pair_valid)
                    fail("P3 raw pair changed or was accepted during forced backpressure");
            end
            release dut.stream_test_stall_count_r;
            // Observe the actual handshake edge exactly once.  The producer
            // remains valid during backpressure, so an extra clock here would
            // enqueue the same pair twice.
            p3_pair_accepted = 1'b0;
            while (!p3_pair_accepted) begin
                @(posedge clk);
                if (vpu_raw_ready)
                    p3_pair_accepted = 1'b1;
            end
            @(negedge clk); vpu_raw_valid = 1'b0; vpu_raw_pair_valid = 1'b0;
            stream_push_entry(32'sd1, 16'd4, 16'd1, 16'd2,
                              1'b1, 1'b1, 32'h5033_0003, 1'b0);
            wait_for_stream_out_count(out_before + 32'd5);
            if (vpu_stream_entry_done_count != done_before + 32'd5 ||
                vpu_stream_final_write_count < out_before + 32'd5 ||
                vpu_stream_raw_stall_cycles <= stall_before)
            begin
                $display("[TB][DBG] P3 done got=%0d before=%0d final=%0d out_before=%0d out=%0d err=%0d drop=%0d",
                         vpu_stream_entry_done_count, done_before,
                         vpu_stream_final_write_count, out_before,
                         vpu_stream_out_count, vpu_stream_error_count,
                         vpu_stream_drop_count);
                fail("P3 entry/final-write counters did not retire every entry");
            end
            else
                pass_count = pass_count + 1;
            mm_read(REGION_OUT, 0, out_word);
            if (out_word[79:16] !== 64'sd196608)
                fail("P3 normal primary split-scale result mismatch");
            else
                pass_count = pass_count + 1;
            mm_read(REGION_OUT, 1, out_word);
            if (out_word[79:16] !== -64'sd131072)
                fail("P3 normal companion split-scale result mismatch");
            else
                pass_count = pass_count + 1;

            // Command-mode engines are blocked while P3 owns a scale bank.
            @(negedge clk); spu_mode = SPU_MODE_COPY; spu_len = 32'd1; spu_start = 1'b1;
            @(posedge clk); @(negedge clk); spu_start = 1'b0;
            repeat (2) @(posedge clk);
            if (spu_busy)
                fail("P3 lock did not block SPU_Controller command start");
            else
                pass_count = pass_count + 1;

            // The unit-level mode signal intentionally changes here to prove
            // completion uses the latched P3 owner, not the live mode input.
            // AXI-level mode-write rejection is covered in tb_VPU_Top.
            stream_split_scale_enable = 1'b0;
            if (!vpu_stream_status[5])
                fail("P3 lock changed with live mode before raw done");
            else
                pass_count = pass_count + 1;

            // Publish end-of-stream, then confirm the protected bank releases
            // only after the pipeline has drained even though live mode is off.
            @(negedge clk); vpu_raw_done = 1'b1;
            @(posedge clk); @(negedge clk); vpu_raw_done = 1'b0;
            timeout = 0;
            while (vpu_stream_status[5]) begin
                @(posedge clk); timeout = timeout + 1;
                if (timeout > 200) begin
                    fail("P3 bank lock did not release after final retirement");
                    timeout = 0;
                end
            end

            stream_split_scale_enable = 1'b1;
            // Bank 1 dense-index boundary: entry row63*4+3=255 maps to
            // PARAM word 32+31=63 lane7; activation block3 maps to SCRATCH
            // word 32 lane3.  This is the maximum geometry practical for the
            // reduced WORD_DEPTH=64 unit test.
            mm_write(REGION_PARAM, 63,
                     {16'h3c00,16'h0000,16'h0000,16'h0000,
                      16'h0000,16'h0000,16'h0000,16'h0000});
            mm_write(REGION_SCRATCH, 32,
                     {16'h0000,16'h0000,16'h0000,16'h0000,
                      16'h3c00,16'h0000,16'h0000,16'h0000});
            stream_push_entry(-32'sd2, 16'd63, 16'd3, 16'd4,
                              1'b1, 1'b1, 32'h5033_0004, 1'b1);
            wait_for_stream_out_count(out_before + 32'd6);
            mm_read(REGION_OUT, 63, out_word);
            if (out_word[15:0] !== 16'd63 || out_word[79:16] !== -64'sd131072) begin
                $display("[TB][DBG] P3 bank1 got_row=%0d got_q16=%0d word=%h",
                         out_word[15:0], $signed(out_word[79:16]), out_word);
                fail("P3 bank1 dense boundary result mismatch");
            end else
                pass_count = pass_count + 1;
            @(negedge clk); vpu_raw_done = 1'b1;
            @(posedge clk); @(negedge clk); vpu_raw_done = 1'b0;
            timeout = 0;
            while (vpu_stream_status[5]) begin
                @(posedge clk); timeout = timeout + 1;
                if (timeout > 200) begin
                    fail("P3 bank1 lock did not release after final retirement");
                    timeout = 0;
                end
            end

            // P3 counters/ownership reset without clearing payload RAM.  This
            // is the abort/reset contract used before a host can reuse either
            // scale bank for a new descriptor.
            @(negedge clk); spu_soft_reset = 1'b1;
            @(posedge clk); @(negedge clk); spu_soft_reset = 1'b0;
            @(posedge clk);
            if (vpu_stream_count != 0 || vpu_stream_entry_done_count != 0 ||
                vpu_stream_final_write_count != 0 ||
                vpu_stream_p3_reject_count != 0 || vpu_stream_status[5])
                fail("P3 counter/ownership reset did not clear stream state");
            else
                pass_count = pass_count + 1;
            stream_split_scale_enable = 1'b0;
        end
    endtask

    task wait_for_stream_out_count;
        input [31:0] expected;
        begin
            timeout = 0;
            while ((vpu_stream_out_count != expected) && (timeout <= 500)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (vpu_stream_out_count != expected)
                fail("VPU raw stream output-count timeout");
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

    task run_vpu_stream_scale_metadata_case;
        reg [DATA_WIDTH-1:0] out_word;
        reg signed [63:0] got_accum;
        reg [31:0] stream_count_before;
        reg [31:0] stream_out_before;
        reg [31:0] stream_error_before;
        reg [31:0] stream_drop_before;
        begin
            $display("[TB] VPU raw-stream precomputed scale metadata test");

            // Linear scale indices 4..7 are in SPU_PARAM word 1.  The first
            // two entries exercise FIFO back-to-back push/pop and accumulation
            // for row=2/group_blocks=2; index 7 specifically covers lane 3.
            mm_write(REGION_PARAM, 32'd1,
                     {32'h3c00_3c00, 32'h3c00_3c00,
                      32'h3c00_3c00, 32'h3c00_3c00});
            // Linear index 63 is the final lane of word 15 for this 64-word
            // SPU_PARAM test instance: row=63/group_blocks=1/block=0.
            mm_write(REGION_PARAM, 32'd15,
                     {32'h3c00_3c00, 32'h3c00_3c00,
                      32'h3c00_3c00, 32'h3c00_3c00});

            stream_count_before = vpu_stream_count;
            stream_out_before   = vpu_stream_out_count;
            stream_error_before = vpu_stream_error_count;
            stream_drop_before  = vpu_stream_drop_count;

            stream_push_entry(32'sd1, 16'd2, 16'd0, 16'd2,
                              1'b0, 1'b1, 32'h0000_0101, 1'b0);
            stream_push_entry(32'sd2, 16'd2, 16'd1, 16'd2,
                              1'b1, 1'b0, 32'h0000_0101, 1'b0);
            stream_push_entry(32'sd3, 16'd63, 16'd0, 16'd1,
                              1'b1, 1'b1, 32'h0000_0102, 1'b1);

            wait_for_stream_out_count(stream_out_before + 32'd2);

            if (vpu_stream_count != stream_count_before + 32'd3)
                fail("VPU raw stream accepted-count mismatch for FIFO push test");
            else
                pass_count = pass_count + 1;

            if (vpu_stream_error_count != stream_error_before ||
                vpu_stream_drop_count != stream_drop_before)
                fail("valid VPU raw stream entry was reported as an error/drop");
            else
                pass_count = pass_count + 1;

            mm_read(REGION_OUT, 32'd2, out_word);
            got_accum = out_word[79:16];
            if (out_word[15:0] !== 16'd2 || got_accum !== 64'sd196608)
                fail("FIFO ordered row=2 scale accumulation mismatch");
            else
                pass_count = pass_count + 1;

            mm_read(REGION_OUT, 32'd63, out_word);
            got_accum = out_word[79:16];
            if (out_word[15:0] !== 16'd63 || got_accum !== 64'sd196608)
                fail("boundary scale-word/lane row=63 accumulation mismatch");
            else
                pass_count = pass_count + 1;

            // Preserve the old invalid-entry semantics: entries are accepted
            // into the FIFO, then rejected once dequeued, incrementing both
            // error and drop counters without publishing an output row.
            stream_push_entry(32'sd9, 16'd0, 16'd0, 16'd0,
                              1'b1, 1'b1, 32'h0000_0103, 1'b0);
            stream_push_entry(32'sd9, 16'd0, 16'd2, 16'd2,
                              1'b1, 1'b1, 32'h0000_0104, 1'b0);
            wait_for_stream_error_count(stream_error_before + 32'd2);

            if (vpu_stream_drop_count != stream_drop_before + 32'd2)
                fail("invalid VPU group/block entries did not increment drop count");
            else
                pass_count = pass_count + 1;
            if (vpu_stream_out_count != stream_out_before + 32'd2)
                fail("invalid VPU group/block entries unexpectedly published output");
            else
                pass_count = pass_count + 1;
        end
    endtask

    task run_silu_mul_case;
        reg [DATA_WIDTH-1:0] out0;
        reg signed [15:0] got;
        reg signed [15:0] exp;
        begin
            $display("[TB] SPU_SiLU_Mul functional Q8.8 test");
            samples[0] = 16'sd0;
            samples[1] = 16'sd256;
            samples[2] = -16'sd256;
            samples[3] = 16'sd1024;
            samples[4] = -16'sd1024;
            samples[5] = 16'sd512;
            samples[6] = -16'sd512;
            samples[7] = 16'sd128;

            params[0] = 16'sd512;
            params[1] = 16'sd512;
            params[2] = 16'sd512;
            params[3] = 16'sd256;
            params[4] = 16'sd256;
            params[5] = -16'sd256;
            params[6] = 16'sd256;
            params[7] = 16'sd384;

            mm_write(REGION_IN, 0, pack_i16_word(0));
            mm_write(REGION_PARAM, 0, pack_param_word(0));
            start_and_wait(SPU_MODE_SILU_MUL, 32'd8);
            mm_read(REGION_OUT, 0, out0);

            for (lane = 0; lane < 8; lane = lane + 1) begin
                got = out0[16*lane +: 16];
                exp = expected_silu_mul(samples[lane], params[lane]);
                if (got !== exp) begin
                    $display("[TB][FAIL] SiLU lane=%0d got=%0d expected=%0d", lane, got, exp);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    task run_rmsnorm_case;
        reg [DATA_WIDTH-1:0] out0;
        reg signed [15:0] got;
        reg signed [15:0] exp;
        reg [63:0] sumsq;
        reg [31:0] inv;
        reg signed [31:0] sample_ext;
        reg signed [63:0] sample_square;
        integer i;
        begin
            $display("[TB] SPU_RMSNorm functional Q8.8 test");
            samples[0] = 16'sd256;
            samples[1] = 16'sd512;
            samples[2] = -16'sd256;
            samples[3] = 16'sd0;
            samples[4] = 16'sd128;
            samples[5] = -16'sd128;
            samples[6] = 16'sd64;
            samples[7] = -16'sd64;
            for (i = 0; i < 8; i = i + 1)
                params[i] = 16'sd256;

            mm_write(REGION_IN, 0, pack_i16_word(0));
            mm_write(REGION_PARAM, 0, pack_param_word(0));
            start_and_wait(SPU_MODE_RMSNORM, 32'd8);
            mm_read(REGION_OUT, 0, out0);

            sumsq = 64'd0;
            for (i = 0; i < 8; i = i + 1) begin
                sample_ext = {{16{samples[i][15]}}, samples[i]};
                sample_square = $signed({{32{sample_ext[31]}}, sample_ext}) *
                                $signed({{32{sample_ext[31]}}, sample_ext});
                sumsq = sumsq + sample_square[63:0];
            end
            inv = expected_rms_inv(sumsq, 32'd8);

            for (lane = 0; lane < 8; lane = lane + 1) begin
                got = out0[16*lane +: 16];
                exp = expected_rms_lane(samples[lane], params[lane], inv);
                if (got !== exp) begin
                    $display("[TB][FAIL] RMS lane=%0d got=%0d expected=%0d", lane, got, exp);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    task check_rmsnorm_saturation;
        input signed [63:0] product_q38;
        input signed [15:0] expected;
        begin
            force dut.u_spu_controller.u_rmsnorm.state_r = 2'd3;
            force dut.u_spu_controller.u_rmsnorm.lane_active_r = 1'b1;
            force dut.u_spu_controller.u_rmsnorm.lane_idx_r = 3'd0;
            force dut.u_spu_controller.u_rmsnorm.norm_product_r = product_q38;
            @(posedge clk);
            #1;
            if ($signed(dut.u_spu_controller.u_rmsnorm.result_word[15:0]) !== expected) begin
                $display("[TB][FAIL] RMS saturation product=%0d got=%0d expected=%0d",
                         product_q38,
                         $signed(dut.u_spu_controller.u_rmsnorm.result_word[15:0]),
                         expected);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
            release dut.u_spu_controller.u_rmsnorm.norm_product_r;
            release dut.u_spu_controller.u_rmsnorm.lane_idx_r;
            release dut.u_spu_controller.u_rmsnorm.lane_active_r;
            release dut.u_spu_controller.u_rmsnorm.state_r;
        end
    endtask

    task run_rmsnorm_saturation_case;
        begin
            $display("[TB] SPU_RMSNorm saturation-boundary test");
            check_rmsnorm_saturation(64'sd274869518848,  16'sd32767); //  32767 <<< 23
            check_rmsnorm_saturation(64'sd274877906944,  16'sd32767); //  32768 <<< 23
            check_rmsnorm_saturation(-64'sd274877906944, -16'sd32768); // -32768 <<< 23
            check_rmsnorm_saturation(-64'sd274886295552, -16'sd32768); // -32769 <<< 23
        end
    endtask

    task run_rope_case;
        reg [DATA_WIDTH-1:0] out0;
        reg signed [15:0] got;
        reg signed [15:0] exp;
        begin
            $display("[TB] SPU_RoPE functional Q8.8/Q1.15 test");
            samples[0] = 16'sd256; samples[1] = 16'sd0;
            samples[2] = 16'sd0;   samples[3] = 16'sd256;
            samples[4] = 16'sd256; samples[5] = 16'sd256;
            samples[6] = -16'sd256; samples[7] = 16'sd256;

            params[0] = 16'sd32767; params[1] = 16'sd0;
            params[2] = 16'sd0;     params[3] = 16'sd32767;
            params[4] = 16'sd0;     params[5] = 16'sd32767;
            params[6] = 16'sd32767; params[7] = 16'sd0;

            mm_write(REGION_IN, 0, pack_i16_word(0));
            mm_write(REGION_PARAM, 0, pack_param_word(0));
            start_and_wait(SPU_MODE_ROPE, 32'd8);
            mm_read(REGION_OUT, 0, out0);

            for (lane = 0; lane < 8; lane = lane + 1) begin
                got = out0[16*lane +: 16];
                exp = expected_rope_lane(samples[(lane/2)*2],
                                         samples[(lane/2)*2 + 1],
                                         params[(lane/2)*2],
                                         params[(lane/2)*2 + 1],
                                         lane % 2);
                if (got !== exp) begin
                    $display("[TB][FAIL] RoPE lane=%0d got=%0d expected=%0d", lane, got, exp);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
        end
    endtask

    task run_softmax_case;
        reg [DATA_WIDTH-1:0] out0;
        reg [15:0] got;
        reg [15:0] exp;
        reg signed [15:0] max_val;
        reg [63:0] score_sum;
        reg [15:0] scores [0:7];
        reg [79:0] prob_tmp;
        integer i;
        begin
            $display("[TB] SPU_Softmax functional Q8.8/Q0.15 test");
            samples[0] = 16'sd0;
            samples[1] = -16'sd256;
            samples[2] = -16'sd512;
            samples[3] = -16'sd1024;
            samples[4] = -16'sd2048;
            samples[5] = -16'sd128;
            samples[6] = -16'sd384;
            samples[7] = -16'sd768;

            mm_write(REGION_IN, 0, pack_i16_word(0));
            start_and_wait(SPU_MODE_SOFTMAX, 32'd8);
            mm_read(REGION_OUT, 0, out0);

            max_val = samples[0];
            for (i = 1; i < 8; i = i + 1)
                if (samples[i] > max_val)
                    max_val = samples[i];
            score_sum = 64'd0;
            for (i = 0; i < 8; i = i + 1) begin
                scores[i] = expected_soft_score(samples[i] - max_val);
                score_sum = score_sum + scores[i];
            end

            for (lane = 0; lane < 8; lane = lane + 1) begin
                got = out0[16*lane +: 16];
                prob_tmp = ({64'd0, scores[lane]} << 15) / score_sum;
                exp = prob_tmp[15:0];
                if (got !== exp) begin
                    $display("[TB][FAIL] Softmax lane=%0d got=%0d expected=%0d", lane, got, exp);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
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
        stream_split_scale_enable = 1'b0;
        mm_wr_en = 1'b0;
        mm_wr_region = REGION_IN;
        mm_wr_index = 32'd0;
        mm_wr_data = {DATA_WIDTH{1'b0}};
        mm_wr_strb = 16'h0000;
        mm_rd_en = 1'b0;
        mm_rd_region = REGION_OUT;
        mm_rd_index = 32'd0;
        vpu_raw_valid = 1'b0;
        vpu_raw_data = 32'sd0;
        vpu_raw_row = 16'd0;
        vpu_raw_block = 16'd0;
        vpu_raw_group_blocks = 16'd1;
        vpu_raw_last_block = 1'b0;
        vpu_raw_clear_accum = 1'b0;
        vpu_raw_job_id = 32'd0;
        vpu_raw_bank = 1'b0;
        vpu_raw_done = 1'b0;
        vpu_raw_pair_valid = 1'b0;
        vpu_raw_pair_data = 32'sd0;
        vpu_raw_pair_row = 16'd0;
        vpu_raw_pair_block = 16'd0;
        vpu_raw_pair_group_blocks = 16'd1;
        vpu_raw_pair_last_block = 1'b0;
        vpu_raw_pair_clear_accum = 1'b0;
        vpu_raw_pair_job_id = 32'd0;
        vpu_raw_pair_bank = 1'b0;
        pass_count = 0;
        fail_count = 0;

        repeat (5) @(posedge clk);
        resetn = 1'b1;
        repeat (3) @(posedge clk);

        if (spu_caps[0] !== 1'b1 || spu_caps[1] !== 1'b1 ||
            spu_caps[2] !== 1'b0 || spu_caps[3] !== 1'b0 ||
            spu_caps[4] !== 1'b0 || spu_caps[5] !== 1'b0 ||
            spu_caps[6] !== 1'b1 || spu_caps[7] !== 1'b1 ||
            spu_caps[8] !== 1'b1 || spu_caps[9] !== 1'b1 ||
            spu_caps[10] !== 1'b1 || spu_caps[11] !== 1'b1)
            fail("SPU capability bits do not match the integration-safe policy");
        else
            pass_count = pass_count + 1;

        run_copy_case();
        run_quant_case();
        run_scale_accum_case();
        run_scale_accum_bad_scale_case();
        run_scale_accum_row_range_case();
        run_stream_soft_reset_abort_case();
        run_vpu_stream_scale_metadata_case();
        run_vpu_stream_pair_case();
        run_vpu_stream_p3_split_scale_case();
        run_silu_mul_case();
        run_rmsnorm_case();
        run_rmsnorm_saturation_case();
        run_rope_case();
        run_softmax_case();

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
