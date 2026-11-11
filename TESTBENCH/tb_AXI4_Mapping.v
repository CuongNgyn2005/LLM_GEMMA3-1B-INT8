`ifndef TB_AXI4_MAPPING_V
`define TB_AXI4_MAPPING_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_AXI4_Mapping #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    localparam AXI_ADDR_WIDTH = 40;
    localparam VPU_BASE_ADDR = 40'h00A0_0000_00;
    localparam ENABLE_BASE_TRANSLATION = 1;
    localparam NUM_LANES = 16;
    localparam ACT_WIDTH = 8;
    localparam WEIGHT_WIDTH = 8;
    localparam ACC_WIDTH = 32;
    localparam SCALE_WIDTH = 16;
    localparam SCALE_FRAC_BITS = 15;
    localparam RESULT_FIFO_DEPTH = 8;
    localparam MAX_ROWS = 256;
    localparam MAX_COL_BEATS = 128;
    localparam MAX_GROUP_Q8_BLOCKS = 64;
    localparam SPU_WORD_DEPTH = 4096;
    localparam SPU_STREAM_TEST_STALL_ENABLE = 0;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = 0;
    reg map_wr_en = 0;
    reg [AXI_ADDR_WIDTH-1:0]             map_wr_addr = 0;
    reg [AXI_DATA_WIDTH-1:0]             map_wr_data = 0;
    reg [(AXI_DATA_WIDTH/8)-1:0]         map_wr_strb = 0;
    reg map_rd_en = 0;
    reg [AXI_ADDR_WIDTH-1:0]             map_rd_addr = 0;
    wire map_rd_ready;
    wire [AXI_DATA_WIDTH-1:0]             map_rd_data;
    wire map_rd_valid;
    wire map_rd_error;
    integer checks = 0;
    reg [127:0] spu_expected [0:3];
    AXI4_Mapping dut (
        .clk(clk),
        .resetn(resetn),
        .map_wr_en(map_wr_en),
        .map_wr_addr(map_wr_addr),
        .map_wr_data(map_wr_data),
        .map_wr_strb(map_wr_strb),
        .map_rd_en(map_rd_en),
        .map_rd_addr(map_rd_addr),
        .map_rd_ready(map_rd_ready),
        .map_rd_data(map_rd_data),
        .map_rd_valid(map_rd_valid),
        .map_rd_error(map_rd_error)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_AXI4_Mapping: %0s", message);
            checks = checks + 1;
        end
    endtask
    task reset_dut;
        begin
            @(negedge tb_clk);
            resetn = 0;
            repeat (4) @(negedge tb_clk);
            resetn = 1;
            repeat (2) @(negedge tb_clk);
        end
    endtask
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_AXI4_Mapping: watchdog timeout");
    end
    task wr;
        input [39:0] addr;
        input [127:0] data;
        input [15:0] strobe;
        begin
            @(negedge tb_clk); map_wr_en=1; map_wr_addr=addr; map_wr_data=data; map_wr_strb=strobe;
            @(negedge tb_clk); map_wr_en=0;
            repeat(3) @(negedge tb_clk);
        end
    endtask
    task rd;
        input [39:0] addr;
        input [127:0] expected;
        input expected_error;
        integer t;
        begin
            @(negedge tb_clk); map_rd_addr=addr;
            #1;
            t=0;
            while(!map_rd_ready && t<100) begin @(negedge tb_clk); t=t+1; end
            check(map_rd_ready,"read admission");
            map_rd_en=1;
            @(negedge tb_clk); map_rd_en=0;
            t=0;
            while(!map_rd_valid && t<100) begin @(negedge tb_clk); t=t+1; end
            check(map_rd_valid && map_rd_error===expected_error,"read response/error");
            if(!expected_error) begin
                if (map_rd_data !== expected)
                    $fatal(1,"[TB][FAIL] mapping read address=%010x got=%032x expected=%032x",addr,map_rd_data,expected);
                checks=checks+1;
            end
        end
    endtask
    function [39:0] spu_address;
        input integer region;
        begin spu_address = 40'h300040 + region*40'h40000; end
    endfunction
    function [127:0] write_pattern;
        input integer seed;
        integer byte_no;
        begin
            for (byte_no=0;byte_no<16;byte_no=byte_no+1)
                write_pattern[8*byte_no +: 8] = seed*29 + byte_no*17;
        end
    endfunction
    task alternating_writes;
        integer n, region, byte_no;
        reg [127:0] data;
        reg [15:0] strobe;
        begin
            for (region=0;region<4;region=region+1) begin
                spu_expected[region] = write_pattern(region);
                wr(spu_address(region),spu_expected[region],16'hffff);
            end
            // Adjacent accepted writes alternate SPU and other targets. The
            // rejected scratch address deliberately aliases index 4 if the
            // valid/range gate is lost when the payload register changes.
            @(negedge tb_clk);
            for (n=0;n<32;n=n+1) begin
                region = n%4; data = write_pattern(n+7);
                case (n/4)
                    0: strobe=16'h0000; 1: strobe=16'hffff;
                    2: strobe=16'haaaa; 3: strobe=16'h5555;
                    4: strobe=16'h8001; 5: strobe=16'h7ffe;
                    6: strobe=16'h00ff; default: strobe=16'hff00;
                endcase
                map_wr_en=1; map_wr_addr=spu_address(region);
                map_wr_data=data; map_wr_strb=strobe;
                for (byte_no=0;byte_no<16;byte_no=byte_no+1)
                    if (strobe[byte_no])
                        spu_expected[region][8*byte_no +: 8] = data[8*byte_no +: 8];
                @(negedge tb_clk);
                case (n%4)
                    0: map_wr_addr=40'h40;
                    1: map_wr_addr=40'h4028;
                    2: map_wr_addr=40'h10040;
                    default: map_wr_addr=40'h3d0040;
                endcase
                map_wr_data=~data; map_wr_strb=~strobe;
                @(negedge tb_clk);
            end
            map_wr_en=0;
            repeat (5) @(negedge tb_clk);
            for (region=0;region<4;region=region+1)
                rd(spu_address(region),spu_expected[region],0);
            $display("[TB] Mapping alternating writes SPU=32 non-SPU=32 regions=4 strobe_patterns=8 PASS");
        end
    endtask
    task idle_address_changes;
        integer n;
        begin
            map_rd_en=0; map_wr_en=0;
            repeat (5) @(negedge tb_clk);
            for (n=0;n<24;n=n+1) begin
                case (n%6)
                    0: map_rd_addr=40'h340040;
                    1: map_rd_addr=40'h200000;
                    2: map_rd_addr=40'h4028;
                    3: map_rd_addr=40'h20;
                    4: map_rd_addr=40'h400020;
                    default: map_rd_addr=40'h80a000404c;
                endcase
                map_wr_addr=map_rd_addr; map_wr_data=write_pattern(n); map_wr_strb=16'hffff;
                @(negedge tb_clk);
                check(!map_rd_valid && !map_rd_error && !dut.rd_pending_r &&
                      !dut.core_rd_en_r && !dut.mmio_spu_rd_en_r && !dut.spu_wr_en_r &&
                      !dut.core_wr_en_r && dut.rd_outstanding_r == 0,
                      "idle address/data changes cannot issue requests or responses");
            end
        end
    endtask
    task prepare_zero_result;
        integer timeout, beat;
        begin
            reset_dut();
            // Packed-Q8 group mode stores four INT32 rows in one word.
            // Legacy mode instead leaves unused lanes uninitialized in four
            // separate words. Exercise a fully initialized real RESULT beat.
            wr(40'h20,128'd4,16'h000f); wr(40'h30,128'd32,16'h000f);
            wr(40'h40,128'd2,16'h000f); wr(40'h60,128'd1,16'h000f);
            wr(40'h10000,0,16'hffff); wr(40'h10010,0,16'hffff);
            for (beat=0;beat<8;beat=beat+1)
                wr(40'h100000+beat*16,0,16'hffff);
            wr(0,128'd1,16'h000f);
            timeout=0;
            while (!dut.core_done && timeout<5000) begin @(negedge tb_clk); timeout=timeout+1; end
            check(dut.core_done && !dut.core_error,"zero GEMV produces a real initialized RESULT word");
            rd(40'h200000,0,0);
        end
    endtask
    task spu_read_transition;
        input [39:0] target;
        input [127:0] expected;
        input expected_error;
        integer n, received, stalled, timeout;
        begin
            received=0; stalled=0;
            @(negedge tb_clk);
            map_rd_addr=40'h340040; #1;
            check(map_rd_ready,"SPU stream starts admitted");
            for (n=0;n<8;n=n+1) begin
                check(map_rd_ready,"consecutive SPU reads stay admitted");
                map_rd_en=1;
                @(negedge tb_clk);
                if (map_rd_valid) begin
                    check(!map_rd_error && map_rd_data===spu_expected[1],"streamed SPU response data");
                    received=received+1;
                end
            end
            map_rd_en=0; map_rd_addr=target; #1;
            check(!map_rd_ready,"SPU-to-non-SPU transition waits for outstanding responses");
            while (!map_rd_ready && stalled<100) begin
                @(negedge tb_clk); stalled=stalled+1;
                if (map_rd_valid) begin
                    check(!map_rd_error && map_rd_data===spu_expected[1],"draining SPU response retains its data");
                    received=received+1;
                end
            end
            check(map_rd_ready && received==8 && stalled>0,"all eight SPU reads drain before path switch");
            map_rd_en=1;
            @(negedge tb_clk); map_rd_en=0;
            timeout=0;
            while (!map_rd_valid && timeout<100) begin
                // These invalid-cycle addresses must never replace the request
                // being decoded, including while RESULT waits for memory.
                map_rd_addr = timeout[0] ? 40'h34004c : 40'h4044;
                @(negedge tb_clk); timeout=timeout+1;
            end
            check(map_rd_valid && map_rd_error===expected_error && map_rd_data===expected,
                  "SPU transition preserves target payload, lane and error");
            if (target != 40'h200000)
                check(timeout==2,"register/error mapping response remains request+2");
            rd(40'h340040,spu_expected[1],0);
            idle_address_changes();
        end
    endtask
    task reset_pending_requests;
        integer kind, delay_cycles, n;
        reg [39:0] address;
        begin
            for (kind=0;kind<4;kind=kind+1) begin
                case (kind)
                    0: address=40'h340040; 1: address=40'h4028;
                    2: address=40'h400020; default: address=40'h200000;
                endcase
                for (delay_cycles=0;delay_cycles<3;delay_cycles=delay_cycles+1) begin
                    @(negedge tb_clk); map_rd_addr=address; map_rd_en=1;
                    @(negedge tb_clk); map_rd_en=0;
                    repeat (delay_cycles) @(negedge tb_clk);
                    resetn=0;
                    repeat (2) @(negedge tb_clk);
                    check(!map_rd_valid && !map_rd_error && !dut.rd_req_en_r &&
                          !dut.rd_pending_r && dut.rd_outstanding_r==0,"reset clears pending read controls");
                    resetn=1;
                    for (n=0;n<12;n=n+1) begin
                        map_rd_addr=write_pattern(n);
                        @(negedge tb_clk);
                        check(!map_rd_valid && !dut.core_rd_en_r && !dut.mmio_spu_rd_en_r,
                              "reset read cannot leak a stale response or memory request");
                    end
                end
            end
            for (delay_cycles=0;delay_cycles<2;delay_cycles=delay_cycles+1) begin
                @(negedge tb_clk); map_wr_en=1; map_wr_addr=40'h340040;
                map_wr_data=~spu_expected[1]; map_wr_strb=16'hffff;
                @(negedge tb_clk); map_wr_en=0;
                repeat (delay_cycles) @(negedge tb_clk);
                // BRAM has no reset input. A write already issued by the
                // decode stage still commits on the reset edge; a request
                // reset before decode never reaches memory. Preserve both.
                if (delay_cycles == 1) spu_expected[1]=~spu_expected[1];
                resetn=0; repeat (2) @(negedge tb_clk); resetn=1;
                repeat (4) @(negedge tb_clk);
                rd(40'h340040,spu_expected[1],0);
            end
            $display("[TB] Mapping reset coverage read_stages=12 write_stages=2 PASS");
        end
    endtask
    initial begin
        reset_dut();
        rd(40'hf4,128'h00000000_00000000_00000002_00000000,0);
        wr(40'h20,128'd9,16'h000f); rd(40'h20,128'd9,0);
        wr(40'h20,128'd5,16'h0001); rd(40'h20,128'd5,0);
        wr(40'h340000,128'hfeedface_81234567_89abcdef_01234567,16'hffff);
        rd(40'ha0340000,128'hfeedface_81234567_89abcdef_01234567,0);
        rd(40'h350000,0,1);
        rd(40'h100000,0,1);
        rd(40'h400000,0,1);
        rd(40'h20,128'd5,0);
        alternating_writes();
        idle_address_changes();
        prepare_zero_result();
        wr(40'h20,128'h12345678,16'h000f);
        wr(40'h4028,128'h00000000_89abcdef_00000000_00000000,16'h0f00);
        spu_read_transition(40'h4028,128'h00000000_89abcdef_00000000_00000000,0);
        spu_read_transition(40'h20,128'h12345678,0);
        spu_read_transition(40'h400020,128'h12345678,1);
        spu_read_transition(40'h200000,0,0);
        reset_pending_requests();
        rd(40'h4000,128'h41540101,0);
        $display("[TB] Mapping transitions SPU-to-attention/legacy/error/RESULT and return PASS");
        completed = 1;
        $display("[TB][PASS] tb_AXI4_Mapping checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
