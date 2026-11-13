`ifndef TB_ATTENTION_FP32_V
`define TB_ATTENTION_FP32_V
`timescale 1ns/1ps

// Standalone by default; AUTO_FINISH=0 permits an enclosing regression owner.
// Arithmetic golden vectors are exact bit patterns, independent of DUT helpers.
// Exponential goldens use correctly rounded binary32 values of exp(binary32 x);
// the dense sweep uses simulator binary64 $exp and the declared error bounds.
module tb_Attention_FP32 #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    reg clk = 0;
    always #5 if (!completed) clk = ~clk;
    reg resetn = 0;
    reg start = 0;
    reg [2:0] op = 0;
    reg [31:0] a = 0, b = 0;
    wire busy, done, error;
    wire [31:0] result;
    integer checks = 0, commands = 0, exp_checks = 0;
    integer index;
    integer last_wait_cycles = 0, stage_checks = 0, stage_index;
    reg [31:0] saved_result;
    real worst_exp_relative = 0.0;
    real worst_exp_subnormal_ulp = 0.0;

    Attention_FP32 dut (.clk(clk), .resetn(resetn), .start(start), .op(op),
        .a(a), .b(b), .busy(busy), .done(done), .result(result), .error(error));

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "[TB][FAIL] tb_Attention_FP32 command=%0d: %0s", commands, message);
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk); resetn = 0; start = 0;
            repeat (2) @(negedge clk);
            check(!busy && !done && !error && result === 32'd0, "synchronous reset/abort");
            resetn = 1;
            @(negedge clk);
            check(!busy && !done, "reset must not leak completion");
        end
    endtask

    task launch;
        input [2:0] operation;
        input [31:0] operand_a, operand_b;
        begin
            @(negedge clk);
            check(!busy, "launch while idle");
            saved_result = result;
            op = operation; a = operand_a; b = operand_b; start = 1;
            @(negedge clk);
            start = 0;
            commands = commands + 1;
            check(busy && !done && !error, "accepted command asserts busy and clears prior error");
            // External pins may change after acceptance; the latched command owns execution.
            op = 7; a = 32'h7fc00000; b = 32'h7f800000;
        end
    endtask

    task await_result;
        integer cycles;
        begin
            cycles = 0;
            while (!done && cycles < 200) begin
                check(busy && result === saved_result, "result stable until publication");
                @(negedge clk);
                cycles = cycles + 1;
            end
            check(done && !busy, "bounded completion publishes with busy low");
            last_wait_cycles = cycles;
        end
    endtask

    task run_case;
        input [2:0] operation;
        input [31:0] operand_a, operand_b, expected;
        input expected_error;
        begin
            launch(operation, operand_a, operand_b);
            await_result();
            if (result !== expected || error !== expected_error)
                $fatal(1, "[TB][FAIL] op=%0d a=%08x b=%08x got=%08x/error%0b expected=%08x/error%0b",
                       operation, operand_a, operand_b, result, error, expected, expected_error);
            checks = checks + 1;
            @(negedge clk);
            check(!done && !busy && result === expected && error === expected_error,
                  "one-cycle done and stable result/error after completion");
        end
    endtask

    task run_timed_case;
        input [2:0] operation;
        input [31:0] operand_a, operand_b, expected;
        input expected_error;
        input integer expected_cycles;
        begin
            run_case(operation, operand_a, operand_b, expected, expected_error);
            if (last_wait_cycles != expected_cycles)
                $fatal(1, "[TB][FAIL] op=%0d latency=%0d expected=%0d", operation, last_wait_cycles, expected_cycles);
            checks = checks + 1;
        end
    endtask

    // Visit each new register boundary without forcing DUT state. A busy-time
    // start must be ignored, and synchronous reset must discard that boundary's
    // data before it can publish. Arithmetic expectations remain independent.
    task probe_stage;
        input [4:0] stage;
        input [2:0] operation;
        input [31:0] operand_a, operand_b, expected;
        integer timeout, pass;
        begin
            for (pass = 0; pass < 2; pass = pass + 1) begin
                launch(operation, operand_a, operand_b);
                timeout = 0;
                while (dut.state_r != stage && timeout < 180) begin
                    @(negedge clk); timeout = timeout + 1;
                end
                check(dut.state_r == stage && busy && !done, "requested pipeline boundary reached while busy");
                if (pass == 0) begin
                    start = 1; op = 7; a = 32'h7fc00000; b = 32'h7f800000;
                    @(negedge clk); start = 0;
                    await_result();
                    check(!error && result === expected, "start at pipeline boundary cannot replace captured command");
                    @(negedge clk);
                    check(!done && !busy && !error && result === expected, "pipeline completion is one pulse and holds result");
                end else begin
                    // Assert on this observed negative edge, before the stage
                    // executes; reset_dut() would first wait another full cycle.
                    resetn = 0; start = 0;
                    repeat (2) @(negedge clk);
                    check(!busy && !done && !error && result === 0, "reset clears an occupied pipeline stage");
                    resetn = 1;
                    repeat (12) begin
                        @(negedge clk);
                        check(!busy && !done && !error && result === 0, "aborted pipeline cannot leak a stale completion");
                    end
                    run_case(5, 32'h3fc00000, 0, 32'd2, 0);
                end
            end
            stage_checks = stage_checks + 1;
        end
    endtask

    // await_result returns on the negative edge with DONE high and IDLE
    // already active. Drive the next command now, so the very next positive
    // edge must accept it without an extra idle bubble.
    task probe_done_restart;
        input [2:0] first_op, next_op;
        input [31:0] first_a, first_b, first_expected;
        input first_error;
        input [31:0] next_a, next_b, next_expected;
        input integer next_cycles;
        begin
            launch(first_op, first_a, first_b);
            await_result();
            check(result === first_expected && error === first_error,
                  "restart predecessor publishes its exact result/error");
            saved_result = result;
            op = next_op; a = next_a; b = next_b; start = 1;
            @(negedge clk);
            commands = commands + 1;
            start = 0;
            check(busy && !done && !error && result === saved_result,
                  "first edge after DONE accepts next command and clears previous error");
            op = 7; a = 32'h7fc00000; b = 32'h7f800000;
            await_result();
            check(!error && result === next_expected && last_wait_cycles == next_cycles,
                  "immediate restart retains operands, exact result and normal latency");
            @(negedge clk);
            check(!done && !busy && !error && result === next_expected,
                  "restart publishes exactly one DONE pulse");
        end
    endtask

    function real fp32_real;
        input [31:0] bits;
        integer significand, exponent;
        real value;
        begin
            if (bits[30:23] == 0) begin
                significand = {9'd0, bits[22:0]};
                exponent = -149;
            end else begin
                significand = {8'd0, 1'b1, bits[22:0]};
                exponent = {24'd0, bits[30:23]} - 150;
            end
            value = $itor(significand) * (2.0 ** exponent);
            fp32_real = bits[31] ? -value : value;
        end
    endfunction

    function [31:0] negative_sixteenth;
        input integer numerator;
        integer top, j, encoded_exp;
        reg [31:0] normalized;
        begin
            top = 0;
            for (j = 0; j < 12; j = j + 1)
                if ((numerator >> j) != 0) top = j;
            normalized = numerator << (23-top);
            encoded_exp = top + 123;
            negative_sixteenth = (numerator == 0) ? 32'd0 :
                                 {1'b1, encoded_exp[7:0], normalized[22:0]};
        end
    endfunction

    task check_exp;
        input [31:0] operand;
        real reference_value, observed_value, difference, relative_error, ulp_error;
        begin
            launch(3, operand, 32'h7fc00000); // unused b must not cause an error
            await_result();
            check(!error && !result[31] && result[30:23] != 8'hff, "finite nonnegative exp");
            reference_value = $exp(fp32_real(operand));
            observed_value = fp32_real(result);
            difference = observed_value - reference_value;
            if (difference < 0) difference = -difference;
            if (reference_value >= (2.0 ** -126)) begin
                relative_error = difference / reference_value;
                if (relative_error > worst_exp_relative) worst_exp_relative = relative_error;
                if (!(relative_error <= 2.0e-6))
                    $fatal(1, "[TB][FAIL] exp normal a=%08x result=%08x relative_error=%e",
                           operand, result, relative_error);
            end else begin
                ulp_error = difference / (2.0 ** -149);
                if (ulp_error > worst_exp_subnormal_ulp) worst_exp_subnormal_ulp = ulp_error;
                if (!(ulp_error <= 2.0))
                    $fatal(1, "[TB][FAIL] exp subnormal a=%08x result=%08x minsub_ulp_error=%e",
                           operand, result, ulp_error);
            end
            exp_checks = exp_checks + 1;
        end
    endtask

    initial begin
        #20000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_Attention_FP32 watchdog");
    end

    initial begin
        reset_dut();

        // Exact addition, signed zero, cancellation, guard/sticky, and overflow.
        run_case(0, 32'h3f800000, 32'h40000000, 32'h40400000, 0);
        run_case(0, 32'h3f800000, 32'h33800000, 32'h3f800000, 0);
        run_case(0, 32'h3f800001, 32'h33800000, 32'h3f800002, 0);
        run_case(0, 32'h3f800000, 32'h33800001, 32'h3f800001, 0);
        run_case(0, 32'h3f800000, 32'hb3800000, 32'h3f7fffff, 0);
        run_case(0, 32'h00800000, 32'h807fffff, 32'h00000001, 0);
        run_case(0, 32'h007fffff, 32'h00000001, 32'h00800000, 0);
        run_case(0, 32'h00000001, 32'h00000001, 32'h00000002, 0);
        run_case(0, 32'hbf800000, 32'h3f800000, 32'h00000000, 0);
        run_case(0, 32'h80000000, 32'h80000000, 32'h80000000, 0);
        run_case(0, 32'h80000000, 32'h00000000, 32'h00000000, 0);
        run_case(0, 32'h7f7fffff, 32'h00000001, 32'h7f7fffff, 0);
        run_case(0, 32'h7f7fffff, 32'h7f7fffff, 32'h00000000, 1);

        run_case(1, 32'hbf800000, 32'h40000000, 32'hc0000000, 0);
        run_case(1, 32'h3f800001, 32'h3fc00000, 32'h3fc00002, 0);
        run_case(1, 32'h00000001, 32'h3fc00000, 32'h00000002, 0);
        run_case(1, 32'h00000001, 32'h40200000, 32'h00000002, 0);
        run_case(1, 32'h00000001, 32'h3f000000, 32'h00000000, 0);
        run_case(1, 32'h80000001, 32'h3f000000, 32'h80000000, 0);
        run_case(1, 32'h00800000, 32'h3f000000, 32'h00400000, 0);
        run_case(1, 32'h80000000, 32'hbf800000, 32'h00000000, 0);
        run_case(1, 32'h00000000, 32'hbf800000, 32'h80000000, 0);
        run_case(1, 32'h7f7fffff, 32'h3f800000, 32'h7f7fffff, 0);
        run_case(1, 32'h7f7fffff, 32'h40000000, 32'h00000000, 1);

        run_case(2, 32'h3f800000, 32'h40400000, 32'h3eaaaaab, 0);
        run_case(2, 32'hc0000000, 32'h40400000, 32'hbf2aaaab, 0);
        run_case(2, 32'h00000001, 32'h40000000, 32'h00000000, 0);
        run_case(2, 32'h00000003, 32'h40000000, 32'h00000002, 0);
        run_case(2, 32'h00000005, 32'h40000000, 32'h00000002, 0);
        run_case(2, 32'h00800000, 32'h40000000, 32'h00400000, 0);
        run_case(2, 32'h00000001, 32'h00000001, 32'h3f800000, 0);
        run_case(2, 32'h3f800000, 32'h7f7fffff, 32'h00200000, 0);
        run_case(2, 32'h80000000, 32'h3f800000, 32'h80000000, 0);
        run_case(2, 32'h00000000, 32'hbf800000, 32'h80000000, 0);
        run_case(2, 32'h3f800000, 32'h00000000, 32'h00000000, 1);
        run_case(2, 32'h00000000, 32'h80000000, 32'h00000000, 1);
        run_case(2, 32'h7f7fffff, 32'h00000001, 32'h00000000, 1);

        // Exact-rational residual-sensitive division vectors. Python Fraction,
        // seed 0x50495045, nearest finite encoding by binary search and exact
        // distance comparison (ties -> even). Omitting the final remainder
        // sticky bit rounds each positive result down by one ULP.
        run_case(2, 32'h3f9e945c, 32'h3f8c1816, 32'h3f90e3bf, 0);
        run_case(2, 32'h3f88a8e8, 32'h3fd547a9, 32'h3f240867, 0);
        run_case(2, 32'h3fd95d6e, 32'h3fdcdb80, 32'h3f7bf3ab, 0);
        run_case(2, 32'h3fcfadf5, 32'h3f88a613, 32'h3fc288ff, 0);
        run_case(2, 32'hbf9e945c, 32'h3f8c1816, 32'hbf90e3bf, 0);
        run_case(2, 32'h3f88a8e8, 32'hbfd547a9, 32'hbf240867, 0);
        run_case(2, 32'hbfd95d6e, 32'hbfdcdb80, 32'h3f7bf3ab, 0);
        run_case(2, 32'hbfcfadf5, 32'h3f88a613, 32'hbfc288ff, 0);

        // Binary16 exact/tie/overflow and gradual-underflow boundaries.
        run_case(4, 32'h3f800000, 0, 32'h00003c00, 0);
        run_case(4, 32'hbf800000, 0, 32'h0000bc00, 0);
        run_case(4, 32'h3f801000, 0, 32'h00003c00, 0);
        run_case(4, 32'h3f803000, 0, 32'h00003c02, 0);
        run_case(4, 32'h3f801001, 0, 32'h00003c01, 0);
        run_case(4, 32'h38800000, 0, 32'h00000400, 0);
        run_case(4, 32'h387fe000, 0, 32'h00000400, 0);
        run_case(4, 32'h387fc000, 0, 32'h000003ff, 0);
        run_case(4, 32'h33800000, 0, 32'h00000001, 0);
        run_case(4, 32'h33000000, 0, 32'h00000000, 0);
        run_case(4, 32'h33000001, 0, 32'h00000001, 0);
        run_case(4, 32'hb3000000, 0, 32'h00008000, 0);
        run_case(4, 32'h33c00000, 0, 32'h00000002, 0);
        run_case(4, 32'h34200000, 0, 32'h00000002, 0);
        run_case(4, 32'h477fe000, 0, 32'h00007bff, 0);
        run_case(4, 32'h477fefff, 0, 32'h00007bff, 0);
        run_case(4, 32'h477ff000, 0, 32'h00000000, 1);
        run_case(4, 32'hc77ff000, 0, 32'h00000000, 1);
        run_case(4, 32'h80000000, 32'h7fc00000, 32'h00008000, 0);
        run_case(4, 32'h00000001, 0, 32'h00000000, 0);

        // ARM NEON vcvtnq_s32_f32 semantics: signed nearest-even, not roundf.
        run_case(5, 32'h3f000000, 0, 32'd0, 0);
        run_case(5, 32'hbf000000, 0, 32'd0, 0);
        run_case(5, 32'h3fc00000, 0, 32'd2, 0);
        run_case(5, 32'hbfc00000, 0, -32'd2, 0);
        run_case(5, 32'h40200000, 0, 32'd2, 0);
        run_case(5, 32'hc0200000, 0, -32'd2, 0);
        run_case(5, 32'h3f000001, 0, 32'd1, 0);
        run_case(5, 32'hbeffffff, 0, 32'd0, 0);
        run_case(5, 32'h42ff0000, 0, 32'd128, 0);
        run_case(5, 32'hc2ff0000, 0, -32'd128, 0);
        run_case(5, 32'h43008000, 0, 32'd128, 0);
        run_case(5, 32'hc3008000, 0, -32'd128, 0);
        run_case(5, 32'h4effffff, 0, 32'h7fffff80, 0);
        run_case(5, 32'hcf000000, 0, 32'h80000000, 0);
        run_case(5, 32'h4f000000, 0, 32'd0, 1);
        run_case(5, 32'hcf000001, 0, 32'd0, 1);
        run_case(5, 32'h00000001, 0, 32'd0, 0);
        run_case(5, 32'h80000000, 32'h7f800000, 32'd0, 0);

        // Used nonfinite operands, invalid opcode, positive exp and error recovery.
        for (index = 0; index < 6; index = index + 1) begin
            run_case(index[2:0], 32'h7f800000, 32'h3f800000, 0, 1);
            run_case(index[2:0], 32'hff800000, 32'h3f800000, 0, 1);
            run_case(index[2:0], 32'h7fc12345, 32'h3f800000, 0, 1);
            run_case(index[2:0], 32'h7f800001, 32'h3f800000, 0, 1);
        end
        for (index = 0; index < 3; index = index + 1)
            run_case(index[2:0], 32'h3f800000, 32'h7fc00000, 0, 1);
        run_case(6, 0, 0, 0, 1);
        run_case(7, 0, 0, 0, 1);
        run_case(3, 32'h00000001, 0, 0, 1);
        run_case(3, 32'h3f800000, 0, 0, 1);
        run_case(0, 32'h3f800000, 32'h3f800000, 32'h40000000, 0);

        // Independent exact-rational vectors: Python Fraction, seed 0x46503332.
        // Oracle binary-searches ordered finite FP encodings for the two nearest
        // values and compares exact rational distances (tie -> even encoding).
        // This does not reuse DUT normalization, shifts, packing, or division.
run_case(0, 32'h64776947, 32'h4b7d0064, 32'h64776947, 0);
        run_case(0, 32'h643e4ab4, 32'hfea4db7e, 32'hfea4db7e, 0);
        run_case(0, 32'h001ef37c, 32'hcb4eadef, 32'hcb4eadef, 0);
        run_case(0, 32'hfeb57d56, 32'h3254e23a, 32'hfeb57d56, 0);
        run_case(0, 32'hfe9d8523, 32'hbfaba9d4, 32'hfe9d8523, 0);
        run_case(0, 32'h810134a9, 32'h00d63e65, 32'h802c2aed, 0);
        run_case(0, 32'h00ebff91, 32'h4b5b0cd6, 32'h4b5b0cd6, 0);
        run_case(0, 32'h327c9d5c, 32'h009fdc98, 32'h327c9d5c, 0);
        run_case(0, 32'hb25e7687, 32'h324d9928, 32'hb086eaf8, 0);
        run_case(0, 32'ha0002cb0, 32'h3f9771ab, 32'h3f9771ab, 0);
        run_case(0, 32'h6418ff4c, 32'hc015b6eb, 32'h6418ff4c, 0);
        run_case(0, 32'h40112ed9, 32'h003b630f, 32'h40112ed9, 0);
        run_case(0, 32'hbf0df270, 32'h80233255, 32'hbf0df270, 0);
        run_case(0, 32'hbf74e704, 32'hfeaae798, 32'hfeaae798, 0);
        run_case(0, 32'ha00c86de, 32'h00db07ad, 32'ha00c86de, 0);
        run_case(0, 32'h00d5413f, 32'h8135ee6a, 32'h80969b95, 0);
        run_case(0, 32'hcb7effe9, 32'hbf6c1808, 32'hcb7effea, 0);
        run_case(0, 32'he46ec5af, 32'hc01549ae, 32'he46ec5af, 0);
        run_case(0, 32'h7f410190, 32'hcb3aa1d6, 32'h7f410190, 0);
        run_case(0, 32'hcb445366, 32'hbfd87f83, 32'hcb445368, 0);
        run_case(0, 32'h407ef2da, 32'hbf69ce6c, 32'h40447f3f, 0);
        run_case(0, 32'h808a3f00, 32'h324e4edf, 32'h324e4edf, 0);
        run_case(0, 32'hcb59259d, 32'h402c4434, 32'hcb59259a, 0);
        run_case(0, 32'hb23358c5, 32'h646673cf, 32'h646673cf, 0);
        run_case(0, 32'h017900c2, 32'h4b0eae80, 32'h4b0eae80, 0);
        run_case(0, 32'h64205445, 32'h816105df, 32'h64205445, 0);
        run_case(0, 32'h8017ddcd, 32'h00ad2985, 32'h00954bb8, 0);
        run_case(0, 32'h402d283f, 32'h7f067627, 32'h7f067627, 0);
        run_case(0, 32'hff29d0bf, 32'hbf782fc8, 32'hff29d0bf, 0);
        run_case(0, 32'hb213c253, 32'h20794a5a, 32'hb213c253, 0);
        run_case(0, 32'he44b7236, 32'hb261cf54, 32'he44b7236, 0);
        run_case(0, 32'hcb2753c5, 32'h401351a3, 32'hcb2753c3, 0);
        run_case(0, 32'h325ad321, 32'h4b616760, 32'h4b616760, 0);
        run_case(0, 32'h3f7d620e, 32'hbf96fa02, 32'hbe4247d8, 0);
        run_case(0, 32'hff1e2765, 32'h3fb5c04b, 32'hff1e2765, 0);
        run_case(0, 32'h8048b95a, 32'h203fa970, 32'h203fa970, 0);
        run_case(0, 32'h202110d4, 32'h7f410627, 32'h7f410627, 0);
        run_case(0, 32'h810f824e, 32'h00dbcc17, 32'h80433885, 0);
        run_case(0, 32'ha04306ee, 32'hbf74855c, 32'hbf74855c, 0);
        run_case(0, 32'hcb211c5f, 32'h000bb60e, 32'hcb211c5f, 0);
        run_case(0, 32'h80529a70, 32'h2015ffab, 32'h2015ffab, 0);
        run_case(0, 32'h008ec18b, 32'h00c9a49b, 32'h012c3313, 0);
        run_case(0, 32'h3233fc07, 32'h8129fe90, 32'h3233fc07, 0);
        run_case(0, 32'h642946bb, 32'hff34c5ce, 32'hff34c5ce, 0);
        run_case(0, 32'hb20804f9, 32'h7f21dae1, 32'h7f21dae1, 0);
        run_case(0, 32'h7f0c71c9, 32'h323ec8ac, 32'h7f0c71c9, 0);
        run_case(0, 32'h815b9f09, 32'h816578cf, 32'h81e08bec, 0);
        run_case(0, 32'hbfdfc391, 32'h3f62f088, 32'hbf5c969a, 0);
        run_case(1, 32'h64507dbe, 32'hcb088b28, 32'hefde6844, 0);
        run_case(1, 32'h7f17ab22, 32'hb202cc43, 32'hf19afbd7, 0);
        run_case(1, 32'h2029468f, 32'h644aa1e6, 32'h4505fcba, 0);
        run_case(1, 32'h001a4e49, 32'ha00aa21d, 32'h80000000, 0);
        run_case(1, 32'hb2776f57, 32'he455f134, 32'h574ec8c5, 0);
        run_case(1, 32'hb25e24dd, 32'hbfae05e2, 32'h32970229, 0);
        run_case(1, 32'h325b139b, 32'hbf377add, 32'hb21d0428, 0);
        run_case(1, 32'h8098788f, 32'h7f14142f, 32'hc0306370, 0);
        run_case(1, 32'hb26ecb77, 32'hc0651d0c, 32'h3355b71a, 0);
        run_case(1, 32'h006f5c3b, 32'h3fefbefd, 32'h00d0945f, 0);
        run_case(1, 32'h80521869, 32'h401a0b03, 32'h80c598dd, 0);
        run_case(1, 32'h4b28f340, 32'hbfc72645, 32'hcb836e58, 0);
        run_case(1, 32'h803e4d47, 32'h644d64a0, 32'ha4c7f17c, 0);
        run_case(1, 32'h207acac5, 32'h327ecd56, 32'h13799e58, 0);
        run_case(1, 32'hff3cb2ab, 32'h3f13f317, 32'hfeda1b8d, 0);
        run_case(1, 32'h015833bf, 32'h801bb1e9, 32'h80000000, 0);
        run_case(1, 32'h81351b68, 32'hcb71bbc6, 32'h0d2b03a4, 0);
        run_case(1, 32'h4b308588, 32'h7f764bf4, 32'h00000000, 1);
        run_case(1, 32'h7e9fa75a, 32'h3f6807b7, 32'h7e90b479, 0);
        run_case(1, 32'h3f04d696, 32'h647468a6, 32'h63fda5a9, 0);
        run_case(1, 32'h8142a11d, 32'hcb718590, 32'h0d379f37, 0);
        run_case(1, 32'h3f0c0e73, 32'hb23352bb, 32'hb1c436bb, 0);
        run_case(1, 32'hb2783bb9, 32'h322a263a, 32'ha524fcba, 0);
        run_case(1, 32'ha0396679, 32'h81103c6c, 32'h00000000, 0);
        run_case(1, 32'h80849749, 32'h4b33385e, 32'h8c39a5f4, 0);
        run_case(1, 32'hbfba1dc8, 32'hfee8cda2, 32'h7f29407d, 0);
        run_case(1, 32'hbf7fa8b8, 32'hfef2a77e, 32'h7ef254c3, 0);
        run_case(1, 32'hbf7da643, 32'hff0fd2c8, 32'h7f0e80b8, 0);
        run_case(1, 32'hfeb163a7, 32'he40264c3, 32'h00000000, 1);
        run_case(1, 32'h7f428181, 32'hfe894980, 32'h00000000, 1);
        run_case(1, 32'h403db419, 32'he42bf95c, 32'he4fee02a, 0);
        run_case(1, 32'hbffdb0df, 32'h323104ac, 32'hb2af6beb, 0);
        run_case(1, 32'h014c1c9c, 32'hbfdc2abd, 32'h81af8aa9, 0);
        run_case(1, 32'h4020f0b0, 32'he428ea5a, 32'he4d46290, 0);
        run_case(1, 32'h3fdcc56a, 32'hfe956fd2, 32'hff00df55, 0);
        run_case(1, 32'h3f7d7a25, 32'ha0307f22, 32'ha02ec1db, 0);
        run_case(1, 32'hff721299, 32'h01414fcb, 32'hc136cb79, 0);
        run_case(1, 32'h00778154, 32'h3f6ae893, 32'h006da8c9, 0);
        run_case(1, 32'h3f311852, 32'hff09be4f, 32'hfebe9355, 0);
        run_case(1, 32'h004561e9, 32'hbf1dd784, 32'h802ac775, 0);
        run_case(1, 32'h3f22993a, 32'h4b5292f8, 32'h4b05bf0a, 0);
        run_case(1, 32'h7eb816b7, 32'hbfd4f48c, 32'hff1922aa, 0);
        run_case(1, 32'ha0569454, 32'h80eb02d6, 32'h00000000, 0);
        run_case(1, 32'hcb2b598e, 32'h642d216e, 32'hefe7c3ca, 0);
        run_case(1, 32'h016c8db2, 32'hb2407f36, 32'h80000000, 0);
        run_case(1, 32'h3f5148ea, 32'h0083032f, 32'h006b1aea, 0);
        run_case(1, 32'ha01fd95e, 32'h7efbff3c, 32'hdf9d597e, 0);
        run_case(1, 32'h0146a47f, 32'hff5ce4dd, 32'hc12b66f3, 0);
        run_case(2, 32'ha0646451, 32'h80ee2039, 32'h5ef5890c, 0);
        run_case(2, 32'h81452074, 32'h3f2d6d53, 32'h81917dec, 0);
        run_case(2, 32'h80864dcf, 32'h00da5498, 32'hbf1d79dc, 0);
        run_case(2, 32'h4b3aaf9d, 32'h8150c297, 32'h00000000, 1);
        run_case(2, 32'hc046cc90, 32'h80f325c4, 32'h7ed14eae, 0);
        run_case(2, 32'hcb47e49d, 32'h2076840b, 32'hea4f9561, 0);
        run_case(2, 32'h00dba304, 32'hbf83ad5e, 32'h80d580d2, 0);
        run_case(2, 32'hff0524f1, 32'hff642c58, 32'h3f1561c2, 0);
        run_case(2, 32'h8104836d, 32'h80a852a9, 32'h3fc989ad, 0);
        run_case(2, 32'h0016e9f0, 32'hb24dbecd, 32'h8c6415dc, 0);
        run_case(2, 32'h800a96c9, 32'hff300d18, 32'h00000000, 0);
        run_case(2, 32'h325d4280, 32'hff579af6, 32'h80000000, 0);
        run_case(2, 32'h7eb6b5ac, 32'h7f6adf70, 32'h3ec7250b, 0);
        run_case(2, 32'h80323cef, 32'h003f4039, 32'hbf4b5506, 0);
        run_case(2, 32'h207e0c4e, 32'h80b47492, 32'hdf343357, 0);
        run_case(2, 32'h7f2e029f, 32'h7f7958d1, 32'h3f32a736, 0);
        run_case(2, 32'h807afcb0, 32'h4007b74b, 32'h8039ff54, 0);
        run_case(2, 32'he45fa928, 32'h7f5d47da, 32'ha4816074, 0);
        run_case(2, 32'hfef3cde9, 32'hbf9c6dc9, 32'h7ec77f05, 0);
        run_case(2, 32'hcb33258c, 32'hb27d657c, 32'h5834fcc3, 0);
        run_case(2, 32'hc0405f4b, 32'h813e9dc8, 32'h7e812dda, 0);
        run_case(2, 32'h00fc20d6, 32'hcb255499, 32'h80000002, 0);
        run_case(2, 32'h016fc13a, 32'h7ee63b17, 32'h00000000, 0);
        run_case(2, 32'h80f5cbc5, 32'h2076945a, 32'h9fff2fc1, 0);
        run_case(2, 32'h3ff19566, 32'he439de7b, 32'h9b265e41, 0);
        run_case(2, 32'h32468a4f, 32'h80350e48, 32'hf1ef7ea2, 0);
        run_case(2, 32'hbf9e783f, 32'h3f4f4c82, 32'hbfc3b307, 0);
        run_case(2, 32'h6479b209, 32'h81550b4a, 32'h00000000, 1);
        run_case(2, 32'h200ca7b2, 32'hff491c92, 32'h80000000, 0);
        run_case(2, 32'h0031dfda, 32'hc0195636, 32'h8014d112, 0);
        run_case(2, 32'h8031e6ae, 32'hbf3cc025, 32'h0043ae23, 0);
        run_case(2, 32'h00635ec6, 32'hbfb19680, 32'h80479f80, 0);
        run_case(2, 32'h3fec391e, 32'h3f256950, 32'h4036cbcf, 0);
        run_case(2, 32'h7e80b559, 32'he4637cca, 32'hd990d71d, 0);
        run_case(2, 32'hc018a701, 32'hb21ae593, 32'h4d7c4a66, 0);
        run_case(2, 32'hcb7f08cd, 32'h32082c82, 32'hd8efb9d4, 0);
        run_case(2, 32'hbf6318f1, 32'h403aa8db, 32'hbe9bbad8, 0);
        run_case(2, 32'h00e6ec6f, 32'h3f582104, 32'h0108c30e, 0);
        run_case(2, 32'hfea09b8c, 32'h322e69cb, 32'h00000000, 1);
        run_case(2, 32'hb2328ed2, 32'hb2787623, 32'h3f37f9ba, 0);
        run_case(2, 32'h4b374328, 32'hff7c38d6, 32'h8b3a01e4, 0);
        run_case(2, 32'hbf50a783, 32'h01770ecd, 32'hfd5834df, 0);
        run_case(2, 32'hbf200212, 32'h4005fcc4, 32'hbe98dba3, 0);
        run_case(2, 32'h7ecdeef7, 32'h32094be0, 32'h00000000, 1);
        run_case(2, 32'h3f1f8190, 32'he40e59cc, 32'h9a8f6d05, 0);
        run_case(2, 32'hbf313f97, 32'h20613c8f, 32'hde49751e, 0);
        run_case(2, 32'hff2dfa59, 32'hfe9d29e5, 32'h400db1b5, 0);
        run_case(2, 32'h80ddbe50, 32'ha02daa43, 32'h20236fa9, 0);
        run_case(4, 32'he4075460, 0, 32'h00000000, 1);
        run_case(4, 32'h8082f839, 0, 32'h00008000, 0);
        run_case(4, 32'h207ec4d9, 0, 32'h00000000, 0);
        run_case(4, 32'h4b2a347b, 0, 32'h00000000, 1);
        run_case(4, 32'h8155a984, 0, 32'h00008000, 0);
        run_case(4, 32'h00534448, 0, 32'h00000000, 0);
        run_case(4, 32'h20110897, 0, 32'h00000000, 0);
        run_case(4, 32'h4069a347, 0, 32'h0000434d, 0);
        run_case(4, 32'hbf944f91, 0, 32'h0000bca2, 0);
        run_case(4, 32'h01032259, 0, 32'h00000000, 0);
        run_case(4, 32'h806612b8, 0, 32'h00008000, 0);
        run_case(4, 32'h015a83c1, 0, 32'h00000000, 0);
        run_case(4, 32'h7f67f050, 0, 32'h00000000, 1);
        run_case(4, 32'hff3c31ef, 0, 32'h00000000, 1);
        run_case(4, 32'hc0148b22, 0, 32'h0000c0a4, 0);
        run_case(4, 32'h32377837, 0, 32'h00000000, 0);
        run_case(4, 32'h644f9d49, 0, 32'h00000000, 1);
        run_case(4, 32'he4417283, 0, 32'h00000000, 1);
        run_case(4, 32'h40321d2d, 0, 32'h00004191, 0);
        run_case(4, 32'h640fc455, 0, 32'h00000000, 1);
        run_case(4, 32'hcb31ca27, 0, 32'h00000000, 1);
        run_case(4, 32'he45d4ea0, 0, 32'h00000000, 1);
        run_case(4, 32'h3f35670e, 0, 32'h000039ab, 0);
        run_case(4, 32'hcb1cf8ad, 0, 32'h00000000, 1);
        run_case(5, 32'h01168fe3, 0, 32'h00000000, 0);
        run_case(5, 32'h005338a6, 0, 32'h00000000, 0);
        run_case(5, 32'he417ef21, 0, 32'h00000000, 1);
        run_case(5, 32'h4041968c, 0, 32'h00000003, 0);
        run_case(5, 32'h7f559faf, 0, 32'h00000000, 1);
        run_case(5, 32'h8164f1d6, 0, 32'h00000000, 0);
        run_case(5, 32'h81412ce4, 0, 32'h00000000, 0);
        run_case(5, 32'h64739224, 0, 32'h00000000, 1);
        run_case(5, 32'h0041a229, 0, 32'h00000000, 0);
        run_case(5, 32'h003203f6, 0, 32'h00000000, 0);
        run_case(5, 32'h80c2bc2a, 0, 32'h00000000, 0);
        run_case(5, 32'h7edc7d12, 0, 32'h00000000, 1);
        run_case(5, 32'hff50b02b, 0, 32'h00000000, 1);
        run_case(5, 32'h803fa03c, 0, 32'h00000000, 0);
        run_case(5, 32'h0058fce5, 0, 32'h00000000, 0);
        run_case(5, 32'hb20e7b62, 0, 32'h00000000, 0);
        run_case(5, 32'he4622a79, 0, 32'h00000000, 1);
        run_case(5, 32'h32422c56, 0, 32'h00000000, 0);
        run_case(5, 32'h3f246b9c, 0, 32'h00000001, 0);
        run_case(5, 32'h00a7e47c, 0, 32'h00000000, 0);
        run_case(5, 32'h016f3608, 0, 32'h00000000, 0);
        run_case(5, 32'h017f95be, 0, 32'h00000000, 0);
        run_case(5, 32'he4697bed, 0, 32'h00000000, 1);
        run_case(5, 32'hbf71fc67, 0, 32'hffffffff, 0);

        // exp goldens from binary64 math.exp after decoding the exact FP32 input.
        run_case(3, 32'h00000000, 0, 32'h3f800000, 0);
        run_case(3, 32'h80000000, 0, 32'h3f800000, 0);
        run_case(3, 32'h80000001, 0, 32'h3f800000, 0);
        run_case(3, 32'hb8d1b717, 0, 32'h3f7ff972, 0);
        run_case(3, 32'hbdcccccd, 0, 32'h3f67a36d, 0);
        run_case(3, 32'hbf000000, 0, 32'h3f1b4598, 0);
        run_case(3, 32'hbf317218, 0, 32'h3f000000, 0);
        run_case(3, 32'hbf800000, 0, 32'h3ebc5ab2, 0);
        run_case(3, 32'hc0000000, 0, 32'h3e0a9555, 0);
        run_case(3, 32'hc0400000, 0, 32'h3d4bed86, 0);
        run_case(3, 32'hc1200000, 0, 32'h383e6bce, 0);
        run_case(3, 32'hc1a00000, 0, 32'h310da433, 0);
        run_case(3, 32'hc2480000, 0, 32'h1b692beb, 0);
        run_case(3, 32'hc2a00000, 0, 32'h05bfecba, 0);
        run_case(3, 32'hc2ae0000, 0, 32'h00b33687, 0);
        run_case(3, 32'hc2aeac4f, 0, 32'h00800026, 0);
        run_case(3, 32'hc2aeac50, 0, 32'h007fffe6, 0);
        run_case(3, 32'hc2aeac51, 0, 32'h007fffa6, 0);
        run_case(3, 32'hc2b00000, 0, 32'h0041edc4, 0);
        run_case(3, 32'hc2b40000, 0, 32'h0008ec28, 0);
        run_case(3, 32'hc2c80000, 0, 32'h0000001b, 0);
        run_case(3, 32'hc2cc0000, 0, 32'h00000004, 0);
        run_case(3, 32'hc2ce0000, 0, 32'h00000001, 0);
        run_case(3, 32'hc2ce8ed0, 0, 32'h00000001, 0);
        run_case(3, 32'hc2cff1b4, 0, 32'h00000001, 0);
        run_case(3, 32'hc2cff1b5, 0, 32'h00000000, 0);
        run_case(3, 32'hc2d00000, 0, 32'h00000000, 0);
        run_case(3, 32'hff7fffff, 0, 32'h00000000, 0);
        for (index = 0; index <= 1664; index = index + 1)
            check_exp(negative_sixteenth(index));
        for (index = -64; index <= 64; index = index + 1) begin
            check_exp(32'hc2aeac50 + index);
            check_exp(32'hc2cff1b5 + index);
            check_exp(32'hbf317218 + index);
            check_exp(32'hc2317218 + index);
            check_exp(32'hc2b17218 + index);
        end

        // Busy-time start must not replace an in-flight division.
        launch(2, 32'h3f800000, 32'h40400000);
        repeat (3) @(negedge clk);
        start = 1; op = 0; a = 32'h40000000; b = 32'h40000000;
        @(negedge clk); start = 0;
        await_result();
        check(!error && result === 32'h3eaaaaab, "busy-time command is ignored");

        // Reset at several stages, then prove no stale completion/operand survives.
        launch(2, 32'h3f800000, 32'h40400000);
        repeat (15) @(negedge clk);
        reset_dut();
        run_case(0, 32'h3f800000, 32'h40000000, 32'h40400000, 0);
        launch(3, 32'hc2b40000, 0);
        repeat (20) @(negedge clk);
        reset_dut();
        launch(3, 32'hbf000000, 0);
        repeat (7) @(negedge clk);
        reset_dut();
        run_case(3, 32'hbf800000, 0, 32'h3ebc5ab2, 0);

        // Exact acceptance-to-publication timing: finite integer conversion
        // takes 4 cycles; early exits stay at 2. Include the longest exp reduction.
        run_timed_case(0, 32'h3f800000, 32'h40000000, 32'h40400000, 0, 9);
        run_timed_case(0, 32'h80000000, 32'h80000000, 32'h80000000, 0, 9);
        run_timed_case(0, 32'hbf800000, 32'h3f800000, 0, 0, 9);
        run_timed_case(1, 32'h00000001, 32'h3fc00000, 2, 0, 7);
        run_timed_case(4, 32'h33000001, 0, 1, 0, 7);
        run_timed_case(2, 32'h3f800000, 32'h40400000, 32'h3eaaaaab, 0, 58);
        run_timed_case(2, 0, 32'hbf800000, 32'h80000000, 0, 2);
        run_timed_case(2, 32'h3f800000, 0, 0, 1, 2);
        run_timed_case(5, 32'h3fc00000, 0, 2, 0, 4);
        run_timed_case(0, 32'h7f800000, 0, 0, 1, 2);
        run_timed_case(3, 0, 0, 32'h3f800000, 0, 45);
        run_timed_case(3, 32'hc2cfffff, 0, 0, 0, 195);
        run_timed_case(3, 32'hc2d00000, 0, 0, 0, 2);
        probe_stage(dut.S_ADD_SELECT, 0, 32'h3f800001, 32'h33800000, 32'h3f800002);
        probe_stage(dut.S_ADD_SUM, 0, 32'h3f800001, 32'h33800000, 32'h3f800002);
        for (stage_index = 0; stage_index < 5; stage_index = stage_index + 1) begin
            // Include S_DONE: reset must also suppress a fully encoded result
            // that has not yet been published to the interface.
            probe_stage(stage_index == 4 ? dut.S_DONE : dut.S_PACK_META+stage_index,
                        0, 32'h3f800001, 32'h33800000, 32'h3f800002);
            probe_stage(stage_index == 4 ? dut.S_DONE : dut.S_PACK_META+stage_index,
                        1, 32'h00000001, 32'h3fc00000, 2);
            probe_stage(stage_index == 4 ? dut.S_DONE : dut.S_PACK_META+stage_index,
                        2, 32'h3f800000, 32'h40400000, 32'h3eaaaaab);
            probe_stage(stage_index == 4 ? dut.S_DONE : dut.S_PACK_META+stage_index,
                        3, 32'hbf800000, 0, 32'h3ebc5ab2);
            probe_stage(stage_index == 4 ? dut.S_DONE : dut.S_PACK_META+stage_index,
                        4, 32'h33000001, 0, 1);
        end
        probe_stage(dut.S_PACK_EXP_META, 0, 32'h3f800001, 32'h33800000, 32'h3f800002);
        probe_stage(dut.S_PACK_EXP_META, 1, 32'h00000001, 32'h3fc00000, 2);
        probe_stage(dut.S_PACK_EXP_META, 2, 32'h3f800000, 32'h40400000, 32'h3eaaaaab);
        probe_stage(dut.S_PACK_EXP_META, 3, 32'hbf800000, 0, 32'h3ebc5ab2);
        probe_stage(dut.S_PACK_EXP_META, 4, 32'h33000001, 0, 1);
        probe_stage(dut.S_INT_ROUND, 5, 32'h3fc00000, 0, 2);
        probe_stage(dut.S_INT_ENCODE, 5, 32'h3fc00000, 0, 2);
        probe_stage(dut.S_EXP_ROUND, 3, 32'hbf800000, 0, 32'h3ebc5ab2);
        probe_stage(dut.S_EXP_UPDATE, 3, 32'hbf800000, 0, 32'h3ebc5ab2);
        probe_done_restart(0, 1, 32'h3f800000, 32'h40000000, 32'h40400000, 0,
                           32'h40000000, 32'h40400000, 32'h40c00000, 7);
        probe_done_restart(2, 4, 32'h3f800000, 32'h40400000, 32'h3eaaaaab, 0,
                           32'h3f800000, 0, 32'h00003c00, 7);
        probe_done_restart(3, 0, 32'hbf800000, 0, 32'h3ebc5ab2, 0,
                           32'hbf800000, 32'h3f800000, 0, 9);
        probe_done_restart(2, 2, 32'h3f800000, 0, 0, 1,
                           32'h3f800000, 32'h40400000, 32'h3eaaaaab, 58);
        probe_done_restart(4, 5, 32'h33000001, 0, 1, 0,
                           32'h3fc00000, 0, 2, 4);
        probe_done_restart(5, 3, 32'h3fc00000, 0, 2, 0,
                           0, 0, 32'h3f800000, 45);
        $display("[TB] First-edge-after-DONE restart pairs=6 including error recovery PASS");
        $display("[TB] Pipeline control stage_probes=%0d ignored_start/reset=PASS latency add=9 mul/half=7 div=58 exp_max=195 integer=4 early=2", stage_checks);

        $display("[TB][PASS] tb_Attention_FP32 checks=%0d commands=%0d exp_sweep=%0d worst_normal_rel=%e worst_subnormal_ulp=%e",
                 checks, commands, exp_checks, worst_exp_relative, worst_exp_subnormal_ulp);
        completed = 1;
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
