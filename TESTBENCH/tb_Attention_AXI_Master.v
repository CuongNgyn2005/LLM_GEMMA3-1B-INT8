`ifndef TB_ATTENTION_AXI_MASTER_V
`define TB_ATTENTION_AXI_MASTER_V
`timescale 1ns/1ps

// Standalone scalar-to-AXI contract test. No behavioral DUT substitutes.
module tb_Attention_AXI_Master #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    reg clk = 0;
    always #5 if (!completed) clk = ~clk;
    reg resetn = 0, cmd_valid = 0, cmd_write = 0, rsp_ready = 0;
    reg cache_invalidate = 0;
    reg [31:0] cmd_addr = 0, cmd_wdata = 0;
    reg [1:0] cmd_size = 0;
    wire cmd_ready, busy, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;
    wire [0:0] awid, arid;
    wire [39:0] awaddr, araddr;
    wire [7:0] awlen, arlen;
    wire [2:0] awsize, arsize, awprot, arprot;
    wire [1:0] awburst, arburst;
    wire awlock, arlock;
    wire [3:0] awcache, arcache, awqos, arqos, awregion, arregion;
    wire awvalid, wvalid, wlast, bready, arvalid, rready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0, rlast = 1;
    reg [0:0] bid = 0, rid = 0;
    reg [1:0] bresp = 0, rresp = 0;
    reg [127:0] rdata = 128'h0f0e0d0c0b0a09080706050403020100;
    integer checks = 0, commands = 0, lane, size_index;
    integer accepted_ar = 0;
    always @(posedge clk) begin
        if (!resetn) accepted_ar <= 0;
        else if (arvalid && arready) accepted_ar <= accepted_ar+1;
    end

    Attention_AXI_Master dut (
        .clk(clk), .resetn(resetn), .cache_invalidate(cache_invalidate), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_write(cmd_write), .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata), .cmd_size(cmd_size),
        .busy(busy), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
        .m_att_axi_awid(awid), .m_att_axi_awaddr(awaddr), .m_att_axi_awlen(awlen),
        .m_att_axi_awsize(awsize), .m_att_axi_awburst(awburst), .m_att_axi_awlock(awlock),
        .m_att_axi_awcache(awcache), .m_att_axi_awprot(awprot), .m_att_axi_awqos(awqos),
        .m_att_axi_awregion(awregion), .m_att_axi_awvalid(awvalid), .m_att_axi_awready(awready),
        .m_att_axi_wdata(wdata), .m_att_axi_wstrb(wstrb), .m_att_axi_wlast(wlast),
        .m_att_axi_wvalid(wvalid), .m_att_axi_wready(wready), .m_att_axi_bid(bid),
        .m_att_axi_bresp(bresp), .m_att_axi_bvalid(bvalid), .m_att_axi_bready(bready),
        .m_att_axi_arid(arid), .m_att_axi_araddr(araddr), .m_att_axi_arlen(arlen),
        .m_att_axi_arsize(arsize), .m_att_axi_arburst(arburst), .m_att_axi_arlock(arlock),
        .m_att_axi_arcache(arcache), .m_att_axi_arprot(arprot), .m_att_axi_arqos(arqos),
        .m_att_axi_arregion(arregion), .m_att_axi_arvalid(arvalid), .m_att_axi_arready(arready),
        .m_att_axi_rid(rid), .m_att_axi_rdata(rdata), .m_att_axi_rresp(rresp),
        .m_att_axi_rlast(rlast), .m_att_axi_rvalid(rvalid), .m_att_axi_rready(rready)
    );

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "[TB][FAIL] tb_Attention_AXI_Master command=%0d: %0s", commands, message);
        end
    endtask
    task reset_dut;
        begin
            @(negedge clk); resetn = 0; cmd_valid = 0; rsp_ready = 0; cache_invalidate = 0;
            awready = 0; wready = 0; bvalid = 0; arready = 0; rvalid = 0;
            bid = 0; rid = 0; bresp = 0; rresp = 0; rlast = 1;
            repeat (3) @(negedge clk);
            check(!busy && !rsp_valid && !awvalid && !wvalid && !arvalid, "reset drains local state and AXI valids");
            resetn = 1;
            @(negedge clk); check(cmd_ready && !rsp_valid, "idle after reset");
        end
    endtask
    task launch;
        input wr;
        input [31:0] addr;
        input [1:0] sz;
        begin
            @(negedge clk); check(cmd_ready && !busy, "command accepted only when idle");
            cmd_write = wr; cmd_addr = addr; cmd_size = sz; cmd_wdata = 32'h89abcdef; cmd_valid = 1;
            @(negedge clk); cmd_valid = 0; commands = commands + 1;
            check(busy && !cmd_ready, "single outstanding command");
            cmd_addr = 32'h7fffffff; cmd_size = 3; cmd_wdata = 0; cmd_write = !wr;
        end
    endtask
    task response;
        input expected_error;
        input [31:0] expected_data;
        integer timeout;
        begin
            timeout = 0;
            while (!rsp_valid && timeout < 30) begin @(negedge clk); timeout = timeout + 1; end
            check(rsp_valid && rsp_error === expected_error && rsp_rdata === expected_data, "response data/error");
            repeat (4) begin
                @(negedge clk);
                check(rsp_valid && busy && !cmd_ready && rsp_error === expected_error && rsp_rdata === expected_data,
                      "response remains stable under consumer backpressure");
            end
            rsp_ready = 1;
            @(negedge clk); rsp_ready = 0;
            check(!rsp_valid && !busy && cmd_ready, "response accepted exactly once");
        end
    endtask
    task write_case;
        input integer byte_lane, sz, order;
        input [1:0] response_code;
        input response_id;
        reg [127:0] expected_data;
        reg [15:0] expected_strobe;
        begin
            launch(1, 32'h70000100 + byte_lane, sz);
            expected_data = {96'd0, 32'h89abcdef} << (8*byte_lane);
            expected_strobe = ((16'h1 << (1 << sz))-1) << byte_lane;
            repeat (3) begin
                check(awvalid && wvalid && awaddr === 40'h0070000100 && awid === 0 && awlen === 0 &&
                      awsize === 4 && awburst === 1 && !awlock && awcache === 0 && awprot === 0 &&
                      awqos === 0 && awregion === 0 && wdata === expected_data && wstrb === expected_strobe && wlast,
                      "write address, metadata, scalar lanes stable while stalled");
                @(negedge clk);
            end
            if (order == 0) begin
                awready = 1;
                @(negedge clk); awready = 0;
                repeat (3) begin check(!awvalid && wvalid && !bready, "AW before W"); @(negedge clk); end
                wready = 1;
                @(negedge clk); wready = 0;
            end else if (order == 1) begin
                wready = 1;
                @(negedge clk); wready = 0;
                repeat (3) begin check(awvalid && !wvalid && !bready, "W before AW"); @(negedge clk); end
                awready = 1;
                @(negedge clk); awready = 0;
            end else begin
                awready = 1; wready = 1;
                @(negedge clk); awready = 0; wready = 0;
            end
            repeat (11) begin
                check(bready && !rsp_valid && !awvalid && !wvalid, "late B prevents early completion and duplicate writes");
                @(negedge clk);
            end
            bid = response_id; bresp = response_code; bvalid = 1;
            @(negedge clk); bvalid = 0; bid = 0; bresp = 0;
            response(response_code != 0 || response_id, 0);
        end
    endtask
    task read_case;
        input integer byte_lane, sz;
        input [1:0] response_code;
        input response_id, missing_last;
        reg [127:0] shifted;
        reg [31:0] expected;
        begin
            launch(0, 32'h70000200 + byte_lane, sz);
            repeat (5) begin
                check(arvalid && araddr === 40'h0070000200 && arid === 0 && arlen === 0 && arsize === 4 &&
                      arburst === 1 && !arlock && arcache === 0 && arprot === 0 && arqos === 0 && arregion === 0,
                      "read address and metadata stable under AR backpressure");
                @(negedge clk);
            end
            arready = 1;
            @(negedge clk); arready = 0;
            repeat (7) begin check(rready && !rsp_valid && !arvalid, "R delay preserves outstanding read"); @(negedge clk); end
            rdata = 128'h0f0e0d0c0b0a09080706050403020100;
            shifted = rdata >> (8*byte_lane);
            case (sz)
                0: expected = {24'd0, shifted[7:0]};
                1: expected = {16'd0, shifted[15:0]};
                default: expected = shifted[31:0];
            endcase
            rid = response_id; rresp = response_code; rlast = !missing_last; rvalid = 1;
            @(negedge clk); rvalid = 0;
            if (missing_last) begin
                repeat (9) begin check(rready && !rsp_valid && busy, "missing RLAST drains before response"); @(negedge clk); end
                rdata = 128'hdeadbeef; rid = 0; rresp = 0; rlast = 1; rvalid = 1;
                @(negedge clk); rvalid = 0;
            end
            rid = 0; rresp = 0; rlast = 1;
            response(response_code != 0 || response_id || missing_last, expected);
        end
    endtask

    task invalidate_cache;
        begin
            @(negedge clk); cache_invalidate = 1;
            @(negedge clk); cache_invalidate = 0;
        end
    endtask
    task cache_miss;
        input [31:0] address;
        input [127:0] beat;
        input invalidate_outstanding;
        integer old_ar;
        begin
            old_ar = accepted_ar;
            launch(0,address,2);
            check(arvalid && !rsp_valid && araddr == {8'd0,address[31:4],4'd0}, "cache miss issues one aligned AR");
            arready = 1; @(negedge clk); arready = 0;
            if (invalidate_outstanding) invalidate_cache();
            repeat (5) begin check(rready && !rsp_valid,"cache miss waits for R"); @(negedge clk); end
            rdata = beat; rresp = 0; rid = 0; rlast = 1; rvalid = 1;
            @(negedge clk); rvalid = 0;
            response(0,beat >> (8*address[3:0]));
            check(accepted_ar == old_ar+1,"cache miss has exactly one external AR");
        end
    endtask
    task cache_hit;
        input integer byte_lane, sz;
        input [127:0] beat;
        reg [127:0] shifted;
        reg [31:0] expected;
        integer old_ar;
        begin
            old_ar = accepted_ar;
            launch(0,32'h70000300+byte_lane,sz);
            shifted = beat >> (8*byte_lane);
            case (sz)
                0: expected = {24'd0,shifted[7:0]};
                1: expected = {16'd0,shifted[15:0]};
                default: expected = shifted[31:0];
            endcase
            check(rsp_valid && !arvalid && !rready,"cache hit returns without an AXI request");
            rdata = ~beat;
            response(0,expected);
            check(accepted_ar == old_ar && !arvalid,"cache hit remains external-AR free under response stalls");
        end
    endtask
    task cache_cases;
        integer sz, byte_lane;
        reg [127:0] old_beat, new_beat;
        begin
            old_beat = 128'h0f0e0d0c0b0a09080706050403020100;
            new_beat = 128'h90817263544536271809faebdccdbeaf;
            invalidate_cache();
            cache_miss(32'h70000300,old_beat,0);
            for (sz=0;sz<3;sz=sz+1)
                for (byte_lane=0;byte_lane<16;byte_lane=byte_lane+(1<<sz))
                    cache_hit(byte_lane,sz,old_beat);
            cache_miss(32'h70000310,new_beat,0);
            cache_miss(32'h70000300,old_beat,0);
            invalidate_cache();
            cache_miss(32'h70000300,new_beat,0);
            cache_hit(12,2,new_beat);
            // Invalidate simultaneously with accepting a would-be hit.
            cache_invalidate = 1;
            cache_miss(32'h70000300,old_beat,0);
            cache_invalidate = 0;
            // Holding invalidation through R also forbids refilling the beat.
            cache_miss(32'h70000300,new_beat,0);
            invalidate_cache();
            cache_miss(32'h70000300,old_beat,1);
            cache_miss(32'h70000300,new_beat,0);
            write_case(0,2,0,0,0);
            cache_miss(32'h70000300,old_beat,0);
            // Error responses must not install a usable cache entry.
            invalidate_cache(); read_case(0,2,2,0,0);
            cache_miss(32'h70000200,new_beat,0);
            invalidate_cache(); read_case(0,2,0,1,0);
            cache_miss(32'h70000200,new_beat,0);
            invalidate_cache(); read_case(0,2,0,0,1);
            cache_miss(32'h70000200,new_beat,0);
            reset_dut();
            cache_miss(32'h70000200,old_beat,0);
        end
    endtask

    initial begin
        #(64'd20000000000);
        if (!completed) $fatal(1, "[TB][FAIL] tb_Attention_AXI_Master watchdog");
    end
    initial begin
        reset_dut();
        cache_cases();
        for (size_index = 0; size_index < 3; size_index = size_index + 1)
            for (lane = 0; lane < 16; lane = lane + (1 << size_index)) begin
                write_case(lane, size_index, lane%3, 0, 0);
                read_case(lane, size_index, 0, 0, 0);
            end
        write_case(12, 2, 0, 2, 0);
        write_case(14, 1, 1, 0, 1);
        read_case(12, 2, 2, 0, 0);
        read_case(14, 1, 0, 1, 0);
        read_case(15, 0, 0, 0, 1);
        launch(0, 32'h70000001, 1);
        check(!arvalid && !awvalid && !wvalid, "misaligned half rejected without AXI"); response(1, 0);
        launch(1, 32'h70000002, 2);
        check(!arvalid && !awvalid && !wvalid, "misaligned word rejected without AXI"); response(1, 0);
        launch(1, 32'h70000000, 3);
        check(!arvalid && !awvalid && !wvalid, "reserved size rejected without AXI"); response(1, 0);
        launch(0, 32'h70000200, 2);
        arready = 1; @(negedge clk); arready = 0;
        check(rready, "reset fixture has outstanding read"); reset_dut();
        launch(1, 32'h70000100, 2);
        wready = 1; @(negedge clk); wready = 0;
        check(awvalid && !wvalid, "reset fixture has W accepted before AW"); reset_dut();
        write_case(0, 2, 2, 0, 0);
        read_case(0, 2, 0, 0, 0);
        $display("[TB][PASS] tb_Attention_AXI_Master checks=%0d commands=%0d", checks, commands);
        completed = 1;
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
