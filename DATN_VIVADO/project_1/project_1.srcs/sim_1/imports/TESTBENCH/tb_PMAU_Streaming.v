/*
 *-----------------------------------------------------------------------------
 * Description   : Unit testbench for PMAU_Streaming module
 *                 - Tests parallel multiply-accumulate with pipelined adder tree
 *                 - Verifies DOT product computation for INT8 inputs
 *                 - Tests AXI-Stream interface compliance
 *                 - Tests accumulation across multiple data beats
 *                 - Golden model verification
 *
 * Test Scenario:
 *   - NUM_LANES = 16 (16 INT8 multipliers in parallel)
 *   - Vector size: 64 elements (4 beats of 16 elements each)
 *   - Expected result: DOT product of 64-element vectors
 *   - Includes pipeline latency verification
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module tb_PMAU_Streaming;

    //-------------------------------------//
    //        Test Parameters              //
    //-------------------------------------//
    
    parameter NUM_LANES    = 16;
    parameter ACT_WIDTH    = 8;
    parameter WEIGHT_WIDTH = 8;
    parameter MULT_WIDTH   = 16;
    parameter ACC_WIDTH    = 32;
    parameter SCALE_WIDTH  = 16;
    parameter CLOCK_PERIOD = 10;           // 100 MHz
    parameter VEC_SIZE     = 64;
    parameter NUM_BEATS    = VEC_SIZE / NUM_LANES;  // 4 beats
    
    //-------------------------------------//
    //       Test Data Storage             //
    //-------------------------------------//
    
    reg signed [ACT_WIDTH-1:0]    test_activation [0:VEC_SIZE-1];
    reg signed [WEIGHT_WIDTH-1:0] test_weight [0:VEC_SIZE-1];
    reg signed [ACC_WIDTH-1:0]    golden_dot_product;
    
    //-------------------------------------//
    //       DUT Signals                   //
    //-------------------------------------//
    
    reg                                   clk;
    reg                                   rst;
    reg [1:0]                             compute_mode;
    
    // Activation Input
    wire [ACT_WIDTH*NUM_LANES-1:0]       activation_data;
    wire                                 activation_valid;
    wire                                 activation_ready;
    wire                                 activation_last;
    
    // Weight Input
    wire [WEIGHT_WIDTH*NUM_LANES-1:0]   weight_data;
    wire [SCALE_WIDTH-1:0]               scale_factor;
    wire                                 weight_valid;
    wire                                 weight_ready;
    wire                                 weight_last;
    
    // Output
    wire [ACC_WIDTH-1:0]                 result_data;
    wire                                 result_valid;
    wire                                 result_ready;
    wire                                 result_last;
    
    //-------------------------------------//
    //       Testbench Internal Signals    //
    //-------------------------------------//
    
    reg [ACT_WIDTH*NUM_LANES-1:0]        act_tdata_r;
    reg                                  act_tvalid_r;
    reg                                  act_tlast_r;
    
    reg [WEIGHT_WIDTH*NUM_LANES-1:0]    weight_tdata_r;
    reg [SCALE_WIDTH-1:0]                scale_r;
    reg                                  weight_tvalid_r;
    reg                                  weight_tlast_r;
    
    reg                                  result_tready_r;
    
    reg [ACC_WIDTH-1:0]                 received_result;
    integer                             test_count;
    integer                             pass_count;
    integer                             fail_count;
    integer                             pipeline_latency;
    reg signed [ACC_WIDTH-1:0]          act_ext;
    reg signed [ACC_WIDTH-1:0]          weight_ext;
    
    //-------------------------------------//
    //   DUT Instantiation                 //
    //-------------------------------------//
    
    PMAU_Streaming #(
        .NUM_LANES(NUM_LANES),
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .MULT_WIDTH(MULT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .SCALE_WIDTH(SCALE_WIDTH)
    ) dut (
        .CLK(clk),
        .RST(rst),
        .compute_mode(compute_mode),
        
        .activation_data(act_tdata_r),
        .activation_valid(act_tvalid_r),
        .activation_ready(activation_ready),
        .activation_last(act_tlast_r),
        
        .weight_data(weight_tdata_r),
        .scale_factor(scale_r),
        .weight_valid(weight_tvalid_r),
        .weight_ready(weight_ready),
        .weight_last(weight_tlast_r),
        
        .scalar_axpy(16'b0),
        
        .result_data(result_data),
        .result_valid(result_valid),
        .result_ready(result_tready_r),
        .result_last(result_last)
    );
    
    //-------------------------------------//
    //       Clock Generation              //
    //-------------------------------------//
    
    initial begin
        clk = 0;
        forever #(CLOCK_PERIOD/2) clk = ~clk;
    end
    
    //-------------------------------------//
    //       Main Test Stimulus            //
    //-------------------------------------//
    
    initial begin
        // Initialize, active-low reset
        rst = 1'b0;
        compute_mode = 2'b00;  // DOT mode
        act_tvalid_r = 1'b0;
        weight_tvalid_r = 1'b0;
        result_tready_r = 1'b1;
        act_tlast_r = 1'b0;
        weight_tlast_r = 1'b0;
        scale_r = 16'h3C00;  // FP16 1.0
        
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
        pipeline_latency = 0;
        
        // Reset sequence
        repeat (5) @(posedge clk);
        rst = 1'b1;
        repeat (5) @(posedge clk);
        
        $display("[TB] ============================================================");
        $display("[TB] PMAU_Streaming Unit Test Started");
        $display("[TB] Configuration: NUM_LANES=%0d, VEC_SIZE=%0d, NUM_BEATS=%0d",
                 NUM_LANES, VEC_SIZE, NUM_BEATS);
        $display("[TB] Clock Period: %0d ns (%.1f MHz)", 
                 CLOCK_PERIOD, 1000.0/CLOCK_PERIOD);
        $display("[TB] ============================================================\n");
        
        // Generate and compute golden reference
        generate_test_data();
        
        // Test 1: Single DOT product
        $display("[TB] TEST 1: Single Vector DOT Product");
        $display("[TB] ============================================================");
        test_single_dot_product();
        
        repeat (10) @(posedge clk);
        
        // Test 2: Back-to-back DOT products
        $display("\n[TB] TEST 2: Multiple Back-to-Back DOT Products");
        $display("[TB] ============================================================");
        test_multiple_dot_products();
        
        repeat (10) @(posedge clk);
        
        // Test 3: Input stalling
        $display("\n[TB] TEST 3: Input Stalling & Flow Control");
        $display("[TB] ============================================================");
        test_input_stalling();
        
        repeat (10) @(posedge clk);
        
        // Final Results
        $display("\n[TB] ============================================================");
        $display("[TB] Final Results:");
        $display("[TB]   Total Tests: %0d", test_count);
        $display("[TB]   PASS: %0d", pass_count);
        $display("[TB]   FAIL: %0d", fail_count);
        $display("[TB] ============================================================");
        
        if (fail_count > 0) begin
            $display("[TB] [FAIL] Some tests failed!");
            $finish(1);
        end else begin
            $display("[TB] [PASS] All tests passed!");
            $finish(0);
        end
    end
    
    //-------------------------------------//
    //   Task: Generate Test Data          //
    //-------------------------------------//
    
    task generate_test_data;
        integer i;
        reg signed [31:0] dot_product;
        begin
            $display("[TB] Generating random test vectors...");
            
            // Generate random activation and weight vectors
            for (i = 0; i < VEC_SIZE; i = i + 1) begin
                test_activation[i] = (($random % 256) - 128);
                test_weight[i] = (($random % 256) - 128);
            end
            
            // Compute golden DOT product
            dot_product = 0;
            for (i = 0; i < VEC_SIZE; i = i + 1) begin
                act_ext = {{(ACC_WIDTH-ACT_WIDTH){test_activation[i][ACT_WIDTH-1]}},
                           test_activation[i]};
                weight_ext = {{(ACC_WIDTH-WEIGHT_WIDTH){test_weight[i][WEIGHT_WIDTH-1]}},
                              test_weight[i]};
                dot_product = dot_product + (act_ext * weight_ext);
            end
            golden_dot_product = dot_product[ACC_WIDTH-1:0];
            
            $display("[TB] Activation vector: [%0d, %0d, %0d, ..., %0d]", 
                     test_activation[0], test_activation[1], test_activation[2],
                     test_activation[VEC_SIZE-1]);
            $display("[TB] Weight vector:     [%0d, %0d, %0d, ..., %0d]", 
                     test_weight[0], test_weight[1], test_weight[2],
                     test_weight[VEC_SIZE-1]);
            $display("[TB] Golden DOT Product: %0d (0x%08h)\n", 
                     $signed(golden_dot_product), golden_dot_product);
        end
    endtask
    
    //-------------------------------------//
    //   Task: Single DOT Product Test     //
    //-------------------------------------//
    
    task test_single_dot_product;
        integer beat, elem_idx;
        integer start_cycle;
        begin
            $display("[TB] Starting single DOT product test...\n");
            
            // Send all beats
            for (beat = 0; beat < NUM_BEATS; beat = beat + 1) begin
                elem_idx = beat * NUM_LANES;
                
                // Pack data
                pack_activation_beat(elem_idx);
                pack_weight_beat(elem_idx);
                
                // Set tlast on last beat
                if (beat == NUM_BEATS - 1) begin
                    act_tlast_r = 1'b1;
                    weight_tlast_r = 1'b1;
                end else begin
                    act_tlast_r = 1'b0;
                    weight_tlast_r = 1'b0;
                end
                
                act_tvalid_r = 1'b1;
                weight_tvalid_r = 1'b1;
                
                $display("[TB] Sending beat %0d (elements %0d-%0d)...", 
                         beat, elem_idx, elem_idx + NUM_LANES - 1);
                
                @(posedge clk);
                #1;
                
                // Wait for ready
                while (~(activation_ready && weight_ready)) begin
                    @(posedge clk);
                    #1;
                end
            end
            
            act_tvalid_r = 1'b0;
            weight_tvalid_r = 1'b0;
            act_tlast_r = 1'b0;
            weight_tlast_r = 1'b0;
            
            // Wait for result
            $display("[TB] Waiting for DOT product result...");
            start_cycle = 0;
            while (~result_valid) begin
                @(posedge clk);
                #1;
                start_cycle = start_cycle + 1;
            end
            
            received_result = result_data;
            pipeline_latency = start_cycle;
            
            $display("[TB] Result received after %0d cycles latency", pipeline_latency);
            $display("[TB] Received: 0x%08h, Expected: 0x%08h", 
                     received_result, golden_dot_product);
            
            // Check result
            test_count = test_count + 1;
            if (received_result == golden_dot_product) begin
                $display("[PASS] DOT product correct!\n");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] DOT product mismatch! Got %0d, expected %0d\n",
                         $signed(received_result), $signed(golden_dot_product));
                fail_count = fail_count + 1;
            end
            
            @(posedge clk);
            #1;
        end
    endtask
    
    //-------------------------------------//
    //   Task: Multiple Back-to-Back Test  //
    //-------------------------------------//
    
    task test_multiple_dot_products;
        integer iteration, beat, elem_idx;
        integer num_iterations;
        begin
            num_iterations = 3;
            $display("[TB] Running %0d back-to-back DOT products...\n", num_iterations);
            
            for (iteration = 0; iteration < num_iterations; iteration = iteration + 1) begin
                $display("[TB] Iteration %0d:", iteration + 1);
                
                // Regenerate test data for each iteration
                generate_test_data();
                
                // Send beats
                for (beat = 0; beat < NUM_BEATS; beat = beat + 1) begin
                    elem_idx = beat * NUM_LANES;
                    pack_activation_beat(elem_idx);
                    pack_weight_beat(elem_idx);
                    
                    if (beat == NUM_BEATS - 1) begin
                        act_tlast_r = 1'b1;
                        weight_tlast_r = 1'b1;
                    end else begin
                        act_tlast_r = 1'b0;
                        weight_tlast_r = 1'b0;
                    end
                    
                    act_tvalid_r = 1'b1;
                    weight_tvalid_r = 1'b1;
                    @(posedge clk);
                    #1;
                    
                    while (~(activation_ready && weight_ready)) begin
                        @(posedge clk);
                        #1;
                    end
                end
                
                act_tvalid_r = 1'b0;
                weight_tvalid_r = 1'b0;
                
                // Wait for result
                while (~result_valid) begin
                    @(posedge clk);
                    #1;
                end
                
                received_result = result_data;
                
                // Check result
                test_count = test_count + 1;
                if (received_result == golden_dot_product) begin
                    $display("[PASS] Iteration %0d correct! (0x%08h)\n", 
                             iteration + 1, received_result);
                    pass_count = pass_count + 1;
                end else begin
                    $display("[FAIL] Iteration %0d mismatch! Got 0x%08h, expected 0x%08h\n",
                             iteration + 1, received_result, golden_dot_product);
                    fail_count = fail_count + 1;
                end
                
                @(posedge clk);
                #1;
            end
        end
    endtask
    
    //-------------------------------------//
    //   Task: Input Stalling Test         //
    //-------------------------------------//
    
    task test_input_stalling;
        integer beat, elem_idx;
        integer stall_beat;
        begin
            $display("[TB] Testing input stalling...\n");
            
            // Randomly select a beat to stall at
            stall_beat = ($random % NUM_BEATS);
            $display("[TB] Will stall at beat %0d\n", stall_beat);
            
            for (beat = 0; beat < NUM_BEATS; beat = beat + 1) begin
                elem_idx = beat * NUM_LANES;
                pack_activation_beat(elem_idx);
                pack_weight_beat(elem_idx);
                
                if (beat == NUM_BEATS - 1) begin
                    act_tlast_r = 1'b1;
                    weight_tlast_r = 1'b1;
                end else begin
                    act_tlast_r = 1'b0;
                    weight_tlast_r = 1'b0;
                end
                
                if (beat == stall_beat) begin
                    // Introduce source-side stall before this beat is accepted.
                    $display("[TB] Stalling before beat %0d...", beat);
                    act_tvalid_r = 1'b0;
                    weight_tvalid_r = 1'b0;
                    repeat (5) @(posedge clk);
                    #1;
                end

                act_tvalid_r = 1'b1;
                weight_tvalid_r = 1'b1;

                @(posedge clk);
                #1;

                if (beat == stall_beat) begin
                    act_tvalid_r = 1'b1;
                    weight_tvalid_r = 1'b1;
                    $display("[TB] Resuming...");
                end
                
                // Wait for handshake
                while (~(activation_ready && weight_ready && act_tvalid_r && weight_tvalid_r)) begin
                    if (beat == stall_beat && ~act_tvalid_r) begin
                        // Still stalling
                    end
                    @(posedge clk);
                    #1;
                end
            end
            
            act_tvalid_r = 1'b0;
            weight_tvalid_r = 1'b0;
            
            // Wait for result
            $display("[TB] Waiting for result after stall...");
            while (~result_valid) begin
                @(posedge clk);
                #1;
            end
            
            received_result = result_data;
            
            // Check result
            test_count = test_count + 1;
            if (received_result == golden_dot_product) begin
                $display("[PASS] Result correct even after stall! (0x%08h)\n", 
                         received_result);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Result mismatch after stall! Got 0x%08h, expected 0x%08h\n",
                         received_result, golden_dot_product);
                fail_count = fail_count + 1;
            end
            
            @(posedge clk);
            #1;
        end
    endtask
    
    //-------------------------------------//
    //   Helper: Pack Activation Beat      //
    //-------------------------------------//
    
    task pack_activation_beat(input integer start_idx);
        integer i;
        begin
            for (i = 0; i < NUM_LANES; i = i + 1) begin
                act_tdata_r[ACT_WIDTH*i +: ACT_WIDTH] = test_activation[start_idx + i];
            end
        end
    endtask
    
    //-------------------------------------//
    //   Helper: Pack Weight Beat          //
    //-------------------------------------//
    
    task pack_weight_beat(input integer start_idx);
        integer i;
        begin
            for (i = 0; i < NUM_LANES; i = i + 1) begin
                weight_tdata_r[WEIGHT_WIDTH*i +: WEIGHT_WIDTH] = test_weight[start_idx + i];
            end
        end
    endtask
    
endmodule
