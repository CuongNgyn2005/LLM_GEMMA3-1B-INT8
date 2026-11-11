`ifndef TB_ATTENTION_ENGINE_V
`define TB_ATTENTION_ENGINE_V
`timescale 1ns/1ps

// Actual top-level MMIO -> mapping -> attention -> external AXI integration.
// The DDR peer generates input bytes from deterministic fixtures and stores raw
// writes. Golden arithmetic uses binary64 mathematical softmax plus explicit RNE
// conversion, never hierarchical DUT arithmetic or repaired output.
module tb_Attention_Engine #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    wire validation_completed;
    tb_Attention_Validation validation_tests(.completed(validation_completed));
    localparam [39:0] MMIO = 40'h00a0000000;
    localparam [31:0] Q_BASE = 32'h70000000, K_BASE = 32'h70100000,
        V_BASE = 32'h72100000, MASK_BASE = 32'h74100000, OUT_BASE = 32'h74200000;
    reg clk = 0, resetn = 0;
    always #5 if (!completed) clk = ~clk;
    reg [39:0] s_awaddr = 0, s_araddr = 0;
    reg [2:0] s_awsize = 2, s_arsize = 2;
    reg [127:0] s_wdata = 0;
    reg [15:0] s_wstrb = 0;
    reg s_awvalid = 0, s_wvalid = 0, s_bready = 0, s_arvalid = 0, s_rready = 0;
    wire s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
    wire [1:0] s_bresp, s_rresp;
    wire [127:0] s_rdata;
    wire [0:0] s_bid, s_rid;
    wire [0:0] m_awid, m_arid;
    wire [39:0] m_awaddr, m_araddr;
    wire [7:0] m_awlen, m_arlen;
    wire [2:0] m_awsize, m_arsize, m_awprot, m_arprot;
    wire [1:0] m_awburst, m_arburst;
    wire m_awlock, m_arlock;
    wire [3:0] m_awcache, m_arcache, m_awqos, m_arqos, m_awregion, m_arregion;
    wire m_awvalid, m_wvalid, m_wlast, m_bready, m_arvalid, m_rready;
    wire [127:0] m_wdata;
    wire [15:0] m_wstrb;
    wire m_awready, m_wready, m_arready;
    reg m_bvalid = 0, m_rvalid = 0, m_rlast = 1;
    reg [0:0] m_bid = 0, m_rid = 0;
    reg [1:0] m_bresp = 0, m_rresp = 0;
    reg [127:0] m_rdata = 0;

    integer checks = 0, cases = 0, cycle_count = 0;
    integer fixture = 0, fixture_d = 32, fixture_hq = 1, fixture_hkv = 1, fixture_n = 1;
    integer bank_offset = 0, generation = 1, tag = 1;
    integer read_count = 0, write_count = 0, b_count = 0, mask_reads = 0, kv_reads = 0;
    integer q_reads = 0, k_reads = 0, v_reads = 0;
    integer final_b_stall_cycles = 0, aw_first_count = 0, w_first_count = 0;
    integer injection = 0;
    reg injected = 0, freeze_read = 0, freeze_b = 0;
    reg ar_pending = 0, aw_pending = 0, w_pending = 0, b_pending = 0, extra_read = 0;
    reg [39:0] saved_awaddr = 0, saved_araddr = 0;
    reg [127:0] saved_wdata = 0;
    reg [15:0] saved_wstrb = 0;
    integer read_delay = 0, b_delay = 0, byte_index, output_offset, token_index;
    reg final_write_pending = 0;
    reg [7:0] output_memory [0:32767];
    // Immutable files generated before simulation by the independent host
    // oracle. These arrays contain no DUT-derived or repaired expectations.
    reg [31:0] vector_input [0:65535];
    reg [31:0] vector_expected [0:8191];
    reg vector_mode = 0;
    integer vector_q_offset = 0, vector_k_offset = 0, vector_v_offset = 0, vector_mask_offset = 0;
    integer vector_online_offset = 0, vector_scale_offset = 0, vector_q8_offset = 0, vector_math_offset = 0;
    reg [8*1024-1:0] vector_directory, vector_input_path, vector_expected_path;
    wire engine_busy = dut.u_my_ip.u_axi4_mapping.u_attention.busy;
    wire engine_done = dut.u_my_ip.u_axi4_mapping.u_attention.done_r;
    wire engine_retained = dut.u_my_ip.u_axi4_mapping.u_attention.retained_valid_r;
    reg [31:0] status_word, value_word;
    integer i, j, count_before, writes_before, errors_index;

    AI_IP_top dut (
        .s00_axi_aclk(clk), .s00_axi_aresetn(resetn),
        .s00_axi_awid(1'b0), .s00_axi_awaddr(s_awaddr), .s00_axi_awlen(8'd0),
        .s00_axi_awsize(s_awsize), .s00_axi_awburst(2'b01), .s00_axi_awlock(1'b0),
        .s00_axi_awcache(4'd0), .s00_axi_awprot(3'd0), .s00_axi_awqos(4'd0),
        .s00_axi_awregion(4'd0), .s00_axi_awuser(1'b0), .s00_axi_awvalid(s_awvalid), .s00_axi_awready(s_awready),
        .s00_axi_wdata(s_wdata), .s00_axi_wstrb(s_wstrb), .s00_axi_wlast(1'b1),
        .s00_axi_wuser(1'b0), .s00_axi_wvalid(s_wvalid), .s00_axi_wready(s_wready),
        .s00_axi_bid(s_bid), .s00_axi_bresp(s_bresp), .s00_axi_buser(), .s00_axi_bvalid(s_bvalid), .s00_axi_bready(s_bready),
        .s00_axi_arid(1'b0), .s00_axi_araddr(s_araddr), .s00_axi_arlen(8'd0),
        .s00_axi_arsize(s_arsize), .s00_axi_arburst(2'b01), .s00_axi_arlock(1'b0),
        .s00_axi_arcache(4'd0), .s00_axi_arprot(3'd0), .s00_axi_arqos(4'd0),
        .s00_axi_arregion(4'd0), .s00_axi_aruser(1'b0), .s00_axi_arvalid(s_arvalid), .s00_axi_arready(s_arready),
        .s00_axi_rid(s_rid), .s00_axi_rdata(s_rdata), .s00_axi_rresp(s_rresp), .s00_axi_rlast(s_rlast),
        .s00_axi_ruser(), .s00_axi_rvalid(s_rvalid), .s00_axi_rready(s_rready),
        .m_att_axi_awid(m_awid),
        .m_att_axi_awaddr(m_awaddr),
        .m_att_axi_awlen(m_awlen),
        .m_att_axi_awsize(m_awsize),
        .m_att_axi_awburst(m_awburst),
        .m_att_axi_awlock(m_awlock),
        .m_att_axi_awcache(m_awcache),
        .m_att_axi_awprot(m_awprot),
        .m_att_axi_awqos(m_awqos),
        .m_att_axi_awregion(m_awregion),
        .m_att_axi_awvalid(m_awvalid),
        .m_att_axi_awready(m_awready),
        .m_att_axi_wdata(m_wdata),
        .m_att_axi_wstrb(m_wstrb),
        .m_att_axi_wlast(m_wlast),
        .m_att_axi_wvalid(m_wvalid),
        .m_att_axi_wready(m_wready),
        .m_att_axi_bid(m_bid),
        .m_att_axi_bresp(m_bresp),
        .m_att_axi_bvalid(m_bvalid),
        .m_att_axi_bready(m_bready),
        .m_att_axi_arid(m_arid),
        .m_att_axi_araddr(m_araddr),
        .m_att_axi_arlen(m_arlen),
        .m_att_axi_arsize(m_arsize),
        .m_att_axi_arburst(m_arburst),
        .m_att_axi_arlock(m_arlock),
        .m_att_axi_arcache(m_arcache),
        .m_att_axi_arprot(m_arprot),
        .m_att_axi_arqos(m_arqos),
        .m_att_axi_arregion(m_arregion),
        .m_att_axi_arvalid(m_arvalid),
        .m_att_axi_arready(m_arready),
        .m_att_axi_rid(m_rid),
        .m_att_axi_rdata(m_rdata),
        .m_att_axi_rresp(m_rresp),
        .m_att_axi_rlast(m_rlast),
        .m_att_axi_rvalid(m_rvalid),
        .m_att_axi_rready(m_rready)
    );

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "[TB][FAIL] tb_Attention_Engine case=%0d fixture=%0d cycle=%0d: %0s",
                       cases, fixture, cycle_count, message);
        end
    endtask
    function real absolute;
        input real x;
        begin absolute = x < 0.0 ? -x : x; end
    endfunction
    function integer nearest_even;
        input real x;
        real magnitude, fraction;
        integer whole;
        begin
            magnitude = absolute(x);
            whole = $rtoi(magnitude);
            fraction = magnitude - whole;
            if (fraction > 0.5 || (fraction == 0.5 && whole%2 != 0)) whole = whole + 1;
            nearest_even = x < 0.0 ? -whole : whole;
        end
    endfunction
    function [31:0] real_fp32;
        input real x;
        real magnitude, normalized;
        integer exponent, significand;
        reg sign_bit;
        begin
            sign_bit = x < 0.0;
            magnitude = absolute(x);
            if (magnitude == 0.0) real_fp32 = 0;
            else begin
                exponent = 0; normalized = magnitude;
                while (normalized >= 2.0) begin normalized = normalized / 2.0; exponent = exponent + 1; end
                while (normalized < 1.0) begin normalized = normalized * 2.0; exponent = exponent - 1; end
                if (exponent < -126) begin
                    significand = nearest_even(magnitude * (2.0 ** 149));
                    real_fp32 = {sign_bit, 31'd0} | significand;
                end else begin
                    significand = nearest_even(normalized * 8388608.0);
                    if (significand == 16777216) begin significand = 8388608; exponent = exponent + 1; end
                    real_fp32 = {sign_bit, 31'd0} | ((exponent+127) << 23) | (significand-8388608);
                end
            end
        end
    endfunction
    function real fp32_real;
        input [31:0] bits;
        real magnitude;
        integer exponent;
        begin
            exponent = bits[30:23];
            if (bits[30:23] == 0) magnitude = bits[22:0] * (2.0 ** -149);
            else magnitude = (8388608.0 + bits[22:0]) * (2.0 ** (exponent-150));
            fp32_real = bits[31] ? -magnitude : magnitude;
        end
    endfunction
    function [15:0] real_half;
        input real x;
        real normalized;
        integer exponent, significand;
        reg sign_bit;
        begin
            sign_bit = x < 0.0; normalized = absolute(x); exponent = 0;
            if (normalized == 0.0) real_half = 0;
            else begin
                while (normalized >= 2.0) begin normalized = normalized / 2.0; exponent = exponent + 1; end
                while (normalized < 1.0) begin normalized = normalized * 2.0; exponent = exponent - 1; end
                if (exponent < -14) real_half = (sign_bit ? 16'h8000 : 0) | nearest_even(absolute(x)*16777216.0);
                else begin
                    significand = nearest_even(normalized*1024.0);
                    if (significand == 2048) begin significand = 1024; exponent = exponent + 1; end
                    real_half = (sign_bit ? 16'h8000 : 0) | ((exponent+15)<<10) | (significand-1024);
                end
            end
        end
    endfunction
    function visible;
        input integer token;
        begin
            if (vector_mode) visible = vector_input[vector_mask_offset+token] == 1;
            else case (fixture)
                4: visible = token == 0 || token == fixture_n-1;
                5: visible = token >= fixture_n-17 && token%3 != 1;
                6: visible = 0;
                default: visible = 1;
            endcase
        end
    endfunction
    function real query_value;
        input integer head, dimension;
        begin
            if (dimension != 0) query_value = 0.0;
            else if (fixture == 14 || fixture == 15) query_value = fp32_real(32'h7f7fffff);
            else if (fixture == 1 || fixture == 2 || fixture == 4) query_value = (head+1)/2.0;
            else query_value = 1.0;
        end
    endfunction
    function real key_value;
        input integer token, group_id, dimension;
        begin
            if (dimension != 0) key_value = 0.0;
            else if (fixture == 14) key_value = 1.0/16777216.0;
            else if (fixture == 15) key_value = 2.0;
            else if (fixture == 1 || fixture == 4) key_value = token == fixture_n-1 ? 8.0 : 0.0;
            else if (fixture == 2) key_value = (token%3-1)/256.0;
            else key_value = 0.25;
        end
    endfunction
    function real value_value;
        input integer token, group_id, dimension;
        integer temporal, block_offset;
        begin
            temporal = token%5-2;
            if ((fixture == 1 || fixture == 4) && token == fixture_n-1) temporal = 5;
            block_offset = fixture == 3 ? dimension/32 : 0;
            value_value = fixture == 8 ? 0.0 : ((group_id+1)*(dimension%8-4)+temporal+block_offset)/32.0;
            if (fixture == 13) begin
                // Anchor amax=127 makes d=id=1 exactly. All neighbors are
                // adjacent representable FP16 values around the named ties.
                case (dimension)
                    0: value_value = 127.0;
                    1: value_value = -127.0;
                    2: value_value = 1.5;
                    3: value_value = -1.5;
                    4: value_value = 2.5;
                    5: value_value = -2.5;
                    6: value_value = 3.5;
                    7: value_value = -3.5;
                    8: value_value = 1.5-1.0/1024.0;
                    9: value_value = 1.5+1.0/1024.0;
                    10: value_value = -1.5+1.0/1024.0;
                    11: value_value = -1.5-1.0/1024.0;
                    12: value_value = 2.5-1.0/512.0;
                    13: value_value = 2.5+1.0/512.0;
                    14: value_value = -2.5+1.0/512.0;
                    15: value_value = -2.5-1.0/512.0;
                    16: value_value = 3.5-1.0/512.0;
                    17: value_value = 3.5+1.0/512.0;
                    18: value_value = -3.5+1.0/512.0;
                    19: value_value = -3.5-1.0/512.0;
                    20: value_value = 0.5;
                    21: value_value = -0.5;
                    22: value_value = 0.5-1.0/4096.0;
                    23: value_value = 0.5+1.0/2048.0;
                    24: value_value = -0.5+1.0/4096.0;
                    25: value_value = -0.5-1.0/2048.0;
                    26: value_value = 126.5;
                    27: value_value = -126.5;
                    28: value_value = 126.5-1.0/16.0;
                    29: value_value = 126.5+1.0/16.0;
                    30: value_value = -126.5+1.0/16.0;
                    31: value_value = -126.5-1.0/16.0;
                endcase
            end else if (fixture == 14) begin
                case (dimension)
                    0: value_value = 65504.0;
                    1: value_value = -65504.0;
                    2: value_value = 1.0/16777216.0;
                    3: value_value = -1.0/16777216.0;
                    4: value_value = 32752.0;
                    5: value_value = -32752.0;
                    6: value_value = 1.0;
                    7: value_value = -1.0;
                    default: value_value = (dimension%2 == 0 ? 1.0 : -1.0)*(dimension+1)/32.0;
                endcase
            end
        end
    endfunction
    function [7:0] memory_byte;
        input [31:0] address;
        integer relative, scalar, head, dimension, token, group_id;
        reg [31:0] word_value;
        reg [15:0] half_value;
        begin
            memory_byte = 8'ha5;
            if (address >= Q_BASE && address < Q_BASE+fixture_hq*fixture_d*4) begin
                relative = address-Q_BASE; scalar = relative/4;
                word_value = real_fp32(query_value(scalar/fixture_d,scalar%fixture_d));
                if (vector_mode) word_value = vector_input[vector_q_offset+scalar];
                if (fixture == 9 && scalar == 0) word_value = 32'h7fc00000;
                if ((fixture == 14 || fixture == 15) && scalar == 0) word_value = 32'h7f7fffff;
                memory_byte = word_value >> (8*(relative%4));
            end else if ((address >= K_BASE && address < K_BASE+fixture_n*fixture_hkv*fixture_d*2) ||
                         (address >= V_BASE && address < V_BASE+fixture_n*fixture_hkv*fixture_d*2)) begin
                relative = address < V_BASE ? address-K_BASE : address-V_BASE;
                scalar = relative/2; dimension = scalar%fixture_d;
                group_id = (scalar/fixture_d)%fixture_hkv; token = scalar/(fixture_d*fixture_hkv);
                if (address < V_BASE) half_value = real_half(key_value(token,group_id,dimension));
                else half_value = real_half(value_value(token,group_id,dimension));
                if (vector_mode) begin
                    if (address < V_BASE) half_value = vector_input[vector_k_offset+scalar];
                    else half_value = vector_input[vector_v_offset+scalar];
                end
                if (fixture == 10 && address < V_BASE && scalar == 0) half_value = 16'h7c00;
                if (fixture == 11 && address >= V_BASE && scalar == 0) half_value = 16'h7e00;
                if (fixture == 14 && address < V_BASE && scalar == 0) half_value = 16'h0001;
                if (fixture == 15 && address < V_BASE && scalar == 0) half_value = 16'h4000;
                memory_byte = half_value >> (8*(relative%2));
            end else if (address >= MASK_BASE && address < MASK_BASE+fixture_n) begin
                memory_byte = visible(address-MASK_BASE);
                if (vector_mode) memory_byte = vector_input[vector_mask_offset+address-MASK_BASE];
                if (fixture == 12 && address == MASK_BASE) memory_byte = 2;
            end
        end
    endfunction
    function [31:0] output_word;
        input integer offset;
        begin output_word = {output_memory[offset+3],output_memory[offset+2],output_memory[offset+1],output_memory[offset]}; end
    endfunction
    function output_address_valid;
        input [31:0] address;
        begin
            output_address_valid =
                (address >= OUT_BASE+bank_offset && address < OUT_BASE+bank_offset+fixture_hq*fixture_d*4) ||
                (address >= OUT_BASE+bank_offset+4096 && address < OUT_BASE+bank_offset+4096+fixture_hq*fixture_d) ||
                (address >= OUT_BASE+bank_offset+6144 && address < OUT_BASE+bank_offset+6144+fixture_hq*fixture_d/16);
        end
    endfunction

    // Alternating AW-first / W-first transactions exercise independent channels.
    assign m_awready = resetn && !aw_pending && !b_pending && !m_bvalid &&
        (write_count%2 == 0 || w_pending) && cycle_count%5 != 1;
    assign m_wready = resetn && !w_pending && !b_pending && !m_bvalid &&
        (write_count%2 != 0 || aw_pending) && cycle_count%7 != 2;
    assign m_arready = resetn && !ar_pending && !m_rvalid && cycle_count%4 != 1;
    always @(posedge clk) begin
        if (!resetn) begin
            cycle_count <= 0; ar_pending <= 0; aw_pending <= 0; w_pending <= 0; b_pending <= 0;
            m_bvalid <= 0; m_rvalid <= 0; m_rlast <= 1; m_rresp <= 0; m_bresp <= 0;
            m_bid <= 0; m_rid <= 0; read_delay <= 0; b_delay <= 0; extra_read <= 0;
            final_write_pending <= 0; injected <= 0;
            read_count <= 0; write_count <= 0; b_count <= 0; mask_reads <= 0; kv_reads <= 0;
            q_reads <= 0; k_reads <= 0; v_reads <= 0;
            final_b_stall_cycles <= 0; aw_first_count <= 0; w_first_count <= 0;
        end else begin
            cycle_count <= cycle_count+1;
            if (m_arvalid && m_arready) begin
                check(m_araddr[3:0] == 0 && m_araddr[39:32] == 0 && m_arid == 0 && m_arlen == 0 &&
                      m_arsize == 4 && m_arburst == 1, "external read is aligned 128-bit single beat");
                saved_araddr <= m_araddr; ar_pending <= 1; read_delay <= 2+read_count%4;
                read_count <= read_count+1;
                if (m_araddr >= Q_BASE && m_araddr < Q_BASE+fixture_hq*fixture_d*4) q_reads <= q_reads+1;
                if (m_araddr >= K_BASE && m_araddr < K_BASE+fixture_n*fixture_hkv*fixture_d*2) k_reads <= k_reads+1;
                if (m_araddr >= V_BASE && m_araddr < V_BASE+fixture_n*fixture_hkv*fixture_d*2) v_reads <= v_reads+1;
                if (m_araddr >= MASK_BASE && m_araddr < MASK_BASE+fixture_n) mask_reads <= mask_reads+1;
                if ((m_araddr >= K_BASE && m_araddr < K_BASE+fixture_n*fixture_hkv*fixture_d*2) ||
                    (m_araddr >= V_BASE && m_araddr < V_BASE+fixture_n*fixture_hkv*fixture_d*2)) begin
                    token_index = m_araddr < V_BASE ? (m_araddr-K_BASE)/(fixture_hkv*fixture_d*2) :
                                                                     (m_araddr-V_BASE)/(fixture_hkv*fixture_d*2);
                    check(visible(token_index), "masked K/V are never read");
                    kv_reads <= kv_reads+1;
                end
            end
            if (ar_pending && !m_rvalid && !freeze_read) begin
                if (read_delay != 0) read_delay <= read_delay-1;
                else begin
                    for (byte_index=0;byte_index<16;byte_index=byte_index+1)
                        m_rdata[8*byte_index +: 8] <= memory_byte(saved_araddr[31:0]+byte_index);
                    m_rvalid <= 1; m_rlast <= 1; m_rresp <= 0; m_rid <= 0; ar_pending <= 0;
                    if (!injected && injection >= 1 && injection <= 3) begin
                        injected <= 1;
                        if (injection == 1) m_rresp <= 2;
                        if (injection == 2) m_rid <= 1;
                        if (injection == 3) begin m_rlast <= 0; extra_read <= 1; end
                    end
                end
            end
            if (m_rvalid && m_rready) begin
                m_rvalid <= 0;
                if (extra_read) begin ar_pending <= 1; read_delay <= 11; extra_read <= 0; end
            end
            if (m_awvalid && m_awready) begin
                check(m_awaddr[3:0] == 0 && m_awaddr[39:32] == 0 && m_awid == 0 && m_awlen == 0 &&
                      m_awsize == 4 && m_awburst == 1, "external write is aligned 128-bit single beat");
                saved_awaddr <= m_awaddr; aw_pending <= 1;
                if (!w_pending) aw_first_count <= aw_first_count+1;
            end
            if (m_wvalid && m_wready) begin
                check(m_wlast && m_wstrb != 0, "single-beat write last and nonzero strobe");
                saved_wdata <= m_wdata; saved_wstrb <= m_wstrb; w_pending <= 1;
                if (!aw_pending) w_first_count <= w_first_count+1;
            end
            if (aw_pending && w_pending && !b_pending && !m_bvalid) begin
                for (byte_index=0;byte_index<16;byte_index=byte_index+1) if (saved_wstrb[byte_index]) begin
                    check(output_address_valid(saved_awaddr[31:0]+byte_index), "all strobed bytes belong to current descriptor outputs");
                    output_offset = saved_awaddr[31:0]+byte_index-OUT_BASE;
                    output_memory[output_offset] <= saved_wdata[8*byte_index +: 8];
                end
                final_write_pending <= (saved_awaddr[31:0]+15 >= OUT_BASE+bank_offset+4096+fixture_hq*fixture_d-1) &&
                    (saved_awaddr[31:0] <= OUT_BASE+bank_offset+4096+fixture_hq*fixture_d-1) &&
                    saved_wstrb[(OUT_BASE+bank_offset+4096+fixture_hq*fixture_d-1)%16];
                b_delay <= 47;
                b_pending <= 1; aw_pending <= 0; w_pending <= 0; write_count <= write_count+1;
            end
            if (b_pending && !m_bvalid && !freeze_b) begin
                if (b_delay != 0) b_delay <= b_delay-1;
                else begin
                    m_bvalid <= 1; m_bresp <= 0; m_bid <= 0; b_pending <= 0;
                    if (!injected && injection >= 4) begin
                        injected <= 1;
                        if (injection == 4) m_bresp <= 2;
                        if (injection == 5) m_bid <= 1;
                    end
                end
            end
            if (m_bvalid && m_bready) begin m_bvalid <= 0; b_count <= b_count+1; final_write_pending <= 0; end
            if (final_write_pending) begin
                check(engine_busy && !engine_done && !engine_retained, "completion waits for final output B response");
                final_b_stall_cycles <= final_b_stall_cycles+1;
            end
        end
    end

    task reset_dut;
        begin
            @(negedge clk); resetn = 0; s_awvalid = 0; s_wvalid = 0; s_bready = 0; s_arvalid = 0; s_rready = 0;
            freeze_read = 0; freeze_b = 0; injection = 0;
            repeat (5) @(negedge clk);
            resetn = 1;
            repeat (4) @(negedge clk);
            check(!engine_busy && !engine_done && !engine_retained, "reset invalidates command and retained result");
        end
    endtask
    task mmio_write;
        input [31:0] offset;
        input [31:0] data;
        input [3:0] strobe;
        integer timeout;
        begin
            @(negedge clk); s_awaddr = MMIO+offset; s_awsize = 2; s_awvalid = 1;
            s_wdata = {96'd0,data} << (8*offset[3:0]); s_wstrb = {12'd0,strobe} << offset[3:0];
            timeout = 0;
            @(posedge clk);
            while (!s_awready && timeout < 300) begin @(posedge clk); timeout = timeout+1; end
            check(s_awready, "MMIO AW bounded acceptance");
            @(negedge clk); s_awvalid = 0; s_wvalid = 1;
            timeout = 0;
            @(posedge clk);
            while (!s_wready && timeout < 300) begin @(posedge clk); timeout = timeout+1; end
            check(s_wready, "MMIO W bounded acceptance");
            @(negedge clk); s_wvalid = 0;
            timeout = 0;
            while (!s_bvalid && timeout < 300) begin @(negedge clk); timeout = timeout+1; end
            check(s_bvalid && s_bresp == 0 && s_bid == 0, "MMIO write response");
            repeat (2) @(negedge clk);
            s_bready = 1; @(negedge clk); s_bready = 0;
        end
    endtask
    task mmio_read;
        input [31:0] offset;
        output [31:0] data;
        integer timeout;
        reg [127:0] captured;
        begin
            @(negedge clk); s_araddr = MMIO+offset; s_arsize = 2; s_arvalid = 1;
            timeout = 0; @(posedge clk);
            while (!s_arready && timeout < 300) begin @(posedge clk); timeout = timeout+1; end
            check(s_arready, "MMIO AR bounded acceptance");
            @(negedge clk); s_arvalid = 0;
            timeout = 0;
            while (!s_rvalid && timeout < 300) begin @(negedge clk); timeout = timeout+1; end
            check(s_rvalid && s_rresp == 0 && s_rlast && s_rid == 0, "MMIO read response");
            captured = s_rdata; data = captured >> (8*offset[3:0]);
            repeat (2) begin @(negedge clk); check(s_rvalid && s_rdata === captured, "MMIO read backpressure stability"); end
            s_rready = 1; @(negedge clk); s_rready = 0;
        end
    endtask
    task configure;
        input integer kind, dimension, heads, kvheads, tokens;
        integer clear_index;
        begin
            fixture = kind; fixture_d = dimension; fixture_hq = heads; fixture_hkv = kvheads; fixture_n = tokens;
            vector_mode = 0;
            cases = cases+1; tag = 32'h12340000+cases; generation = cases%3+1; bank_offset = (cases%2)*16384;
            injection = 0; injected = 0;
            for (clear_index=bank_offset;clear_index<bank_offset+8192;clear_index=clear_index+1) output_memory[clear_index] = 8'hcd;
            mmio_write(16'h4004,2,15);
            mmio_write(16'h4010,tag,15); mmio_write(16'h4018,dimension,15);
            mmio_write(16'h401c,heads,15); mmio_write(16'h4020,kvheads,15); mmio_write(16'h4024,tokens,15);
            mmio_write(16'h4028,Q_BASE,15); mmio_write(16'h402c,K_BASE,15);
            mmio_write(16'h4030,V_BASE,15); mmio_write(16'h4034,MASK_BASE,15);
            mmio_write(16'h4038,OUT_BASE+bank_offset,15); mmio_write(16'h403c,OUT_BASE+bank_offset+4096,15);
            mmio_write(16'h4040,OUT_BASE+bank_offset+6144,15); mmio_write(16'h4044,generation,15);
        end
    endtask
    task launch;
        begin
            mmio_write(16'h4004,1,15);
            check(!engine_retained, "START immediately invalidates old retained output");
        end
    endtask
    task await_done;
        input integer expected_error;
        integer timeout;
        reg [31:0] status, error_code, done_tag, done_gen;
        begin
            timeout = 0;
            // Sample status through the real slave after completion; waiting on
            // the monitor avoids millions of redundant MMIO polls in long runs.
            while (!engine_done && timeout < 100000000) begin @(negedge clk); timeout = timeout+1; end
            check(engine_done, "bounded completion");
            mmio_read(16'h4008,status); mmio_read(16'h400c,error_code);
            mmio_read(16'h4014,done_tag); mmio_read(16'h4048,done_gen);
            if (error_code !== expected_error)
                $fatal(1,"[TB][FAIL] case=%0d expected error=%0d got=%0d status=%08x",cases,expected_error,error_code,status);
            check(!status[0] && status[1] && status[2] == (expected_error != 0) &&
                  status[3] == (expected_error == 0), "DONE/error/retained public status");
            check(done_tag === tag && done_gen === generation, "completion preserves accepted tag and generation");
            check(!ar_pending && !aw_pending && !w_pending && !b_pending && !m_rvalid && !m_bvalid,
                  "completion owns no outstanding AXI response");
        end
    endtask

    function integer pinned_quant;
        input integer head, dimension;
        reg [63:0] table_value;
        integer byte_value;
        begin
            table_value = 0;
            if (fixture == 1) begin
                case (head)
                    0: table_value = 64'h7f6a55412c1702ee;
                    1: table_value = 64'h7f6f5f4f3f2f1f0f;
                    default: table_value = 64'h7f68513a230cf4dd;
                endcase
            end else if (fixture == 2) begin
                case (head)
                    0: table_value = 64'h5e3f1f00e0c0a181;
                    1: table_value = 64'h5f3f1f00e0c0a181;
                    default: table_value = 64'h5f3f2000e0c0a181;
                endcase
            end
            byte_value = (table_value >> (8*(dimension%8))) & 255;
            pinned_quant = byte_value >= 128 ? byte_value-256 : byte_value;
        end
    endfunction
    function integer tie_quant;
        input integer dimension;
        begin
            // Independent integer pins: scale and reciprocal are exactly one.
            case (dimension)
                0,29: tie_quant = 127;
                1,31: tie_quant = -127;
                2,4,9,12: tie_quant = 2;
                3,5,11,14: tie_quant = -2;
                6,17: tie_quant = 4;
                7,19: tie_quant = -4;
                8,23: tie_quant = 1;
                10,25: tie_quant = -1;
                13,16: tie_quant = 3;
                15,18: tie_quant = -3;
                26,28: tie_quant = 126;
                27,30: tie_quant = -126;
                default: tie_quant = 0;
            endcase
        end
    endfunction
    task verify_outputs;
        integer head, group_id, dimension, token, block_id, element, offset, quantized, raw_byte;
        real max_score, weight, denominator, numerator, expected, actual, amax, scale, reciprocal, rounded;
        real expected_values [0:1023];
        reg [31:0] bits;
        reg [15:0] scale_bits, observed_scale;
        reg [63:0] scale_table;
        reg [127:0] block_scale_table;
        begin
            for (head=0;head<fixture_hq;head=head+1) begin
                group_id = head/(fixture_hq/fixture_hkv);
                max_score = -1.0e30;
                for (token=0;token<fixture_n;token=token+1) if (visible(token)) begin
                    expected = query_value(head,0)*key_value(token,group_id,0);
                    if (expected > max_score) max_score = expected;
                end
                denominator = 0.0; numerator = 0.0;
                // V = constant(d,head) + temporal(token); one weighted sum
                // suffices for every dimension, independent of online DUT order.
                for (token=0;token<fixture_n;token=token+1) if (visible(token)) begin
                    weight = $exp(query_value(head,0)*key_value(token,group_id,0)-max_score);
                    denominator = denominator+weight;
                    numerator = numerator+weight*value_value(token,group_id,0);
                end
                for (dimension=0;dimension<fixture_d;dimension=dimension+1) begin
                    expected = numerator/denominator +
                        (fixture == 8 ? 0.0 : ((group_id+1)*(dimension%8)+(fixture == 3 ? dimension/32 : 0))/32.0);
                    if (fixture == 13 || fixture == 14)
                        expected = half_real(real_half(value_value(0,group_id,dimension)));
                    element = head*fixture_d+dimension;
                    expected_values[element] = fp32_real(real_fp32(expected));
                    bits = output_word(bank_offset+4*element); actual = fp32_real(bits);
                    check(bits[30:23] != 255 && (^bits !== 1'bx), "raw context contains finite initialized FP32");
                    if (fixture == 13 || fixture == 14)
                        check(bits === real_fp32(expected), "N=1 context exactly preserves original decoded FP16 V");
                    if (absolute(actual-expected) > 2.0e-6+2.0e-6*absolute(expected))
                        $fatal(1,"[TB][FAIL] context case=%0d h=%0d d=%0d got=%08x/%e expected=%e",
                               cases,head,dimension,bits,actual,expected);
                    checks = checks+1;
                end
            end
            for (block_id=0;block_id<fixture_hq*fixture_d/32;block_id=block_id+1) begin
                amax = 0.0;
                for (element=0;element<32;element=element+1)
                    if (absolute(expected_values[block_id*32+element]) > amax)
                        amax = absolute(expected_values[block_id*32+element]);
                scale = fp32_real(real_fp32(amax/127.0));
                reciprocal = scale == 0.0 ? 0.0 : fp32_real(real_fp32(1.0/scale));
                scale_bits = real_half(scale);
                head = block_id/(fixture_d/32); group_id = head/(fixture_hq/fixture_hkv);
                // Independent exact fixtures supplied by the reference model.
                if (fixture == 0 && fixture_d == 32) begin
                    scale_table = 0;
                    case (fixture_n)
                        31: scale_table = 64'h1c0c1a1418101419;
                        32,33: scale_table = 64'h1c0e1a1818141420;
                        129: scale_table = 64'h1c091a0e180a140c;
                    endcase
                    if (scale_table != 0) scale_bits = scale_table >> (16*group_id);
                end
                if (fixture == 1) begin scale_table = 64'h198b198b1801162a; scale_bits = scale_table >> (16*head); end
                if (fixture == 2) begin scale_table = 64'h1c091a0e180a140c; scale_bits = scale_table >> (16*head); end
                if (fixture == 3) begin
                    block_scale_table = group_id == 0 ? 128'h18891808170e160c150a14081408150a :
                                                               128'h1a0c198b190a18891808170e18081889;
                    scale_bits = block_scale_table >> (16*(block_id%8));
                end
                if (fixture == 13) begin
                    check(scale == 1.0 && reciprocal == 1.0, "tie fixture has exact unit scale and reciprocal");
                    scale_bits = 16'h3c00;
                end
                offset = bank_offset+6144+2*block_id;
                observed_scale = {output_memory[offset+1],output_memory[offset]};
                if (observed_scale !== scale_bits)
                    $fatal(1,"[TB][FAIL] scale case=%0d block=%0d got=%04x expected=%04x",cases,block_id,observed_scale,scale_bits);
                checks = checks+1;
                for (element=0;element<32;element=element+1) begin
                    rounded = fp32_real(real_fp32(expected_values[block_id*32+element]*reciprocal));
                    quantized = nearest_even(rounded);
                    if (fixture == 1 || fixture == 2) quantized = pinned_quant(head,element);
                    if (fixture == 13) quantized = tie_quant(element);
                    raw_byte = output_memory[bank_offset+4096+block_id*32+element];
                    if (raw_byte >= 128) raw_byte = raw_byte-256;
                    if (raw_byte !== quantized)
                        $fatal(1,"[TB][FAIL] Q8 case=%0d block=%0d lane=%0d got=%0d expected=%0d",
                               cases,block_id,element,raw_byte,quantized);
                    checks = checks+1;
                end
            end
            check((fixture_hq*fixture_d*4 == 4096 || output_memory[bank_offset+fixture_hq*fixture_d*4] === 8'hcd) &&
                  output_memory[bank_offset+4096+fixture_hq*fixture_d] === 8'hcd &&
                  output_memory[bank_offset+6144+fixture_hq*fixture_d/16] === 8'hcd,
                  "all output tails retain poison guards");
        end
    endtask
    task run_success;
        input integer kind, dimension, heads, kvheads, tokens;
        integer reads_start, writes_start, responses_start, mask_start, kv_start, visible_count, token;
        integer q_start, k_start, v_start, expected_masks, expected_kv;
        begin
            configure(kind,dimension,heads,kvheads,tokens);
            $display("[TB] Attention numeric case=%0d fixture=%0d D=%0d Hq=%0d Hkv=%0d N=%0d",cases,kind,dimension,heads,kvheads,tokens);
            reads_start = read_count; writes_start = write_count; responses_start = b_count;
            mask_start = mask_reads; kv_start = kv_reads;
            q_start = q_reads; k_start = k_reads; v_start = v_reads;
            launch(); await_done(0); verify_outputs();
            if (kind == 0 && dimension == 32 && heads == 4 && kvheads == 4 && tokens == 33)
                retained_projection();
            visible_count = 0; expected_masks = 0;
            for (token=0;token<tokens;token=token+1) begin
                if (visible(token)) visible_count = visible_count+1;
                // Visible K/V evicts the mask beat; consecutive hidden keys
                // share their mask beat until its 16-byte boundary.
                if (token == 0 || token%16 == 0) expected_masks = expected_masks+1;
                else if (visible(token-1)) expected_masks = expected_masks+1;
            end
            expected_masks = expected_masks*kvheads;
            expected_kv = kvheads*visible_count*(dimension/8);
            check(q_reads-q_start == heads*dimension/4,"Q preload uses one AR per four FP32 values");
            check(k_reads-k_start == expected_kv && v_reads-v_start == expected_kv,
                  "each KV group/key vector uses D/8 beats shared across its query heads");
            check(kv_reads-kv_start == 2*expected_kv,"exact combined cached K/V beat count");
            check(mask_reads-mask_start == expected_masks,"exact mask beat count with K/V eviction and hidden-key hits");
            check(read_count-reads_start == heads*dimension/4+expected_masks+2*expected_kv,
                  "exact external Q/mask/K/V beat count");
            $display("[TB] AXI reuse D=%0d Hq=%0d Hkv=%0d N=%0d Q=%0d K=%0d V=%0d mask=%0d",
                     dimension,heads,kvheads,tokens,q_reads-q_start,k_reads-k_start,v_reads-v_start,mask_reads-mask_start);
            check(write_count-writes_start == heads*dimension*2+heads*dimension/32 &&
                  b_count-responses_start == write_count-writes_start, "each context/Q8/scale write acknowledged once");
            mmio_write(16'h4004,2,15);
            mmio_read(16'h4008,status_word);
            check(status_word == 8, "idle ACK clears status but preserves retained output");
            mmio_write(16'h4004,4,15);
            mmio_read(16'h4008,status_word);
            check(status_word == 0, "RELEASE invalidates retained output");
        end
    endtask


    task probe_register_read;
        input [39:0] address;
        input [31:0] expected_word;
        input [1:0] expected_response;
        input concurrent_update;
        input [31:0] update_offset, update_word;
        reg [127:0] expected_beat;
        integer timeout;
        begin
            expected_beat = {96'd0,expected_word} << (32*address[3:2]);
            @(negedge clk);
            check(s_arready && (!concurrent_update || s_awready),"focused MMIO probe starts on idle channels");
            s_araddr = address; s_arsize = 2; s_arvalid = 1; s_rready = 0;
            if (concurrent_update) begin
                s_awaddr = MMIO+update_offset; s_awsize = 2; s_awvalid = 1;
                s_wdata = {96'd0,update_word} << (8*update_offset[3:0]);
                s_wstrb = 16'h000f << update_offset[3:0];
            end
            @(posedge clk);
            check(s_arready && (!concurrent_update || s_awready),"focused MMIO AR and optional AW accepted together");
            @(negedge clk);
            s_arvalid = 0; s_araddr = 40'h00004080;
            if (concurrent_update) begin s_awvalid = 0; s_wvalid = 1; end
            @(posedge clk);
            check(dut.u_my_ip.map_rd_en_r && dut.u_my_ip.map_rd_addr_r === address,
                  "accepted AXI address reaches mapping request unchanged");
            if (concurrent_update) check(s_wready,"concurrent write data accepted one edge after read address");
            // The mapping request is accepted above. Its existing contract is
            // pending capture at +1, response at +2, then MY_IP queues the beat.
            @(negedge clk); if (concurrent_update) s_wvalid = 0;
            check(!dut.u_my_ip.map_rd_valid,"no mapping response at request acceptance");
            @(negedge clk);
            check(!dut.u_my_ip.map_rd_valid,"no mapping response at pending-capture edge");
            @(negedge clk);
            check(dut.u_my_ip.map_rd_valid && dut.u_my_ip.map_rd_data === expected_beat &&
                  dut.u_my_ip.map_rd_error === (expected_response != 0),
                  "register/ERROR response preserves request+2 timing, snapshot and lane zero-fill");
            @(negedge clk);
            if (!(s_rvalid && s_rdata === expected_beat && s_rresp === expected_response && s_rlast && s_rid == 0))
                $fatal(1,"[TB][FAIL] focused MMIO address=%010x got=%032x/resp%0d expected=%032x/resp%0d",
                       address,s_rdata,s_rresp,expected_beat,expected_response);
            checks = checks+1;
            if (concurrent_update) begin
                // W was accepted at map request acceptance. Its configuration
                // update follows the read's pending-capture edge, so this held
                // response must retain the old value despite the later write.
                timeout = 0;
                while (!s_bvalid && timeout < 300) begin
                    @(negedge clk); timeout = timeout+1;
                    check(s_rvalid && s_rdata === expected_beat && s_rresp === expected_response,
                          "snapshot stable while concurrent write completes");
                end
                check(s_bvalid && s_bresp == 0,"concurrent descriptor update completes");
                s_bready = 1; @(negedge clk); s_bready = 0;
            end
            repeat (5) begin
                @(negedge clk);
                check(s_rvalid && s_rdata === expected_beat && s_rresp === expected_response && s_rlast && s_rid == 0,
                      "full response remains stable under RREADY stall");
            end
            s_rready = 1; @(negedge clk); s_rready = 0;
            check(!s_rvalid,"focused MMIO response consumed exactly once");
        end
    endtask
    task run_mapping_read_coverage;
        integer address_mode, lane;
        reg [39:0] address_base;
        reg [31:0] legacy_offset, legacy_value, attention_value;
        begin
            mmio_write(32'h0020,32'h10203040,15);
            mmio_write(32'h0020,32'ha1b2c3d4,5);
            mmio_write(32'h00e4,32'h50607080,15);
            mmio_write(32'h00e4,32'hd1c2b3a4,10);
            mmio_write(32'h4020,32'h11223344,15); mmio_write(32'h4020,32'ha1b2c3d4,5);
            mmio_write(32'h4024,32'h55667788,15); mmio_write(32'h4024,32'ha1b2c3d4,10);
            mmio_write(32'h4028,32'h99aabbcc,15); mmio_write(32'h4028,32'ha1b2c3d4,3);
            mmio_write(32'h402c,32'hddeeff00,15); mmio_write(32'h402c,32'ha1b2c3d4,12);
            for (address_mode=0;address_mode<2;address_mode=address_mode+1) begin
                address_base = address_mode == 0 ? MMIO : 0;
                for (lane=0;lane<4;lane=lane+1) begin
                    case (lane)
                        0: begin legacy_offset=32'h0020; legacy_value=32'h10b230d4; attention_value=32'h11b233d4; end
                        1: begin legacy_offset=32'h00e4; legacy_value=32'hd160b380; attention_value=32'ha166c388; end
                        2: begin legacy_offset=32'h00f8; legacy_value=32'h56505532; attention_value=32'h99aac3d4; end
                        3: begin legacy_offset=32'h00fc; legacy_value=32'h50320003; attention_value=32'ha1b2ff00; end
                    endcase
                    probe_register_read(address_base+legacy_offset,legacy_value,0,0,0,0);
                    probe_register_read(address_base+32'h4020+4*lane,attention_value,0,0,0,0);
                    probe_register_read(address_base+32'h4080+4*lane,0,0,0,0,0);
                    // ERROR responses retain the historical low-16 legacy
                    // payload alias, while attention uses its full window.
                    probe_register_read(address_base+32'h00400000+legacy_offset,legacy_value,2,0,0,0);
                end
                probe_register_read(address_base+32'h3ffc,0,0,0,0,0);
                probe_register_read(address_base+32'h4000,32'h41540101,0,0,0,0);
                probe_register_read(address_base+32'h404c,1,0,0,0,0);
                probe_register_read(address_base+32'h4050,0,0,0,0,0);
                probe_register_read(address_base+32'h4001,0,0,0,0,0);
                probe_register_read(address_base+32'h00404018,0,2,0,0,0);
            end
            probe_register_read(MMIO+32'h0020,32'h10b230d4,0,1,32'h0020,32'h43218765);
            probe_register_read(40'h00004028,32'h99aac3d4,0,1,32'h4028,32'hfeed5678);
            probe_register_read(40'h00000020,32'h43218765,0,0,0,0);
            probe_register_read(MMIO+32'h4028,32'hfeed5678,0,0,0,0);
            // Restore probe-only configuration before the unchanged numeric
            // and P2 suites (in particular the legacy SPU auxiliary register).
            mmio_write(32'h0020,0,15); mmio_write(32'h00e4,0,15);
            mmio_write(32'h4020,0,15); mmio_write(32'h4024,0,15);
            mmio_write(32'h4028,0,15); mmio_write(32'h402c,0,15);
            $display("[TB] Mapping read coverage lanes=4 address_modes=2 snapshots=2 map_response_cycles=2 legacy_ERROR_alias=PASS attention_window=PASS");
        end
    endtask

    task full_write;
        input [31:0] offset;
        input [127:0] data;
        integer timeout;
        begin
            @(negedge clk); s_awaddr = MMIO+offset; s_awsize = 4; s_awvalid = 1;
            s_wdata = data; s_wstrb = 16'hffff;
            timeout = 0; @(posedge clk);
            while (!s_awready && timeout < 300) begin @(posedge clk); timeout = timeout+1; end
            check(s_awready,"full AXI AW accepted");
            @(negedge clk); s_awvalid = 0; s_wvalid = 1;
            timeout = 0; @(posedge clk);
            while (!s_wready && timeout < 300) begin @(posedge clk); timeout = timeout+1; end
            check(s_wready,"full AXI W accepted");
            @(negedge clk); s_wvalid = 0;
            timeout = 0;
            while (!s_bvalid && timeout < 300) begin @(negedge clk); timeout = timeout+1; end
            check(s_bvalid && s_bresp == 0,"full AXI B accepted");
            s_bready = 1; @(negedge clk); s_bready = 0;
        end
    endtask
    task full_read;
        input [31:0] offset;
        output [127:0] data;
        integer timeout;
        begin
            @(negedge clk); s_araddr = MMIO+offset; s_arsize = 4; s_arvalid = 1;
            timeout = 0; @(posedge clk);
            while (!s_arready && timeout < 300) begin @(posedge clk); timeout = timeout+1; end
            check(s_arready,"full AXI AR accepted");
            @(negedge clk); s_arvalid = 0;
            timeout = 0;
            while (!s_rvalid && timeout < 300) begin @(negedge clk); timeout = timeout+1; end
            check(s_rvalid && s_rresp == 0 && s_rlast,"full AXI R accepted");
            data = s_rdata; s_rready = 1; @(negedge clk); s_rready = 0;
        end
    endtask
    task probe_spu_response_stall;
        input reset_held_response;
        integer timeout, stall;
        reg [127:0] expected;
        begin
            expected=128'hfedcba98_76543210_01234567_89abcdef;
            @(negedge clk); s_araddr=MMIO+32'h340040; s_arsize=4; s_arvalid=1; s_rready=0;
            timeout=0; @(posedge clk);
            while (!s_arready && timeout<300) begin @(posedge clk); timeout=timeout+1; end
            check(s_arready,"SPU stall probe AR accepted");
            @(negedge clk); s_arvalid=0;
            timeout=0;
            while (!s_rvalid && timeout<300) begin @(negedge clk); timeout=timeout+1; end
            check(s_rvalid,"SPU stall probe response arrives");
            for (stall=0;stall<8;stall=stall+1) begin
                s_araddr=stall[0] ? MMIO+32'h4028 : MMIO+32'h400020;
                @(negedge clk);
                check(s_rvalid && s_rdata===expected && s_rresp==0 && s_rlast && s_rid==0,
                      "SPU queued response stays exact while RREADY low and idle address changes");
                check(!s_arready,"held SPU response prevents a new AXI transaction");
            end
            if (reset_held_response) begin
                reset_dut();
                repeat (8) begin
                    @(negedge clk);
                    check(!s_rvalid && !dut.u_my_ip.map_rd_valid,
                          "reset discards held AXI response without stale publication");
                end
            end else begin
                s_rready=1; @(negedge clk); s_rready=0;
                check(!s_rvalid,"SPU held response consumed once");
            end
        end
    endtask
    task run_mapping_transition_stalls;
        begin
            full_write(32'h340040,128'hfedcba98_76543210_01234567_89abcdef);
            mmio_write(32'h20,32'h12345678,15);
            mmio_write(32'h4028,32'h89abcdef,15);
            probe_spu_response_stall(0);
            probe_register_read(MMIO+32'h4028,32'h89abcdef,0,0,0,0);
            probe_spu_response_stall(0);
            probe_register_read(MMIO+32'h20,32'h12345678,0,0,0,0);
            probe_spu_response_stall(0);
            probe_register_read(MMIO+32'h400020,32'h12345678,2,0,0,0);
            probe_spu_response_stall(1);
            $display("[TB] Mapping AXI transitions SPU-to-attention/legacy/error RREADY stalls and held-response reset PASS");
        end
    endtask
    function real half_real;
        input [15:0] bits;
        integer exponent;
        real magnitude;
        begin
            exponent = bits[14:10];
            if (exponent == 0) magnitude = bits[9:0]*(2.0**-24);
            else magnitude = (1024.0+bits[9:0])*(2.0**(exponent-25));
            half_real = bits[15] ? -magnitude : magnitude;
        end
    endfunction
    function integer projection_weight;
        input integer tile, row, element;
        begin projection_weight = ((tile*3+row*5+element*2)%7)-3; end
    endfunction
    task retained_projection;
        integer tile, row, beat, lane, element, block_id, blocks, col_beats, entries;
        integer word_index, linear, timeout, raw_dot, q_value, offset;
        reg [127:0] packed_word, read_word;
        reg [15:0] act_scale;
        reg [31:0] legacy_status;
        reg signed [63:0] expected_accum, scale_q32, contribution;
        begin
            blocks = fixture_hq*fixture_d/32; col_beats = blocks*2;
            check(engine_retained,"projection starts with valid retained attention output");
            for (tile=0;tile<2;tile=tile+1) begin
                mmio_write(32'h0000,2,15); mmio_write(32'h0100,0,15);
                mmio_write(32'h0110,32'he200+tile,15); mmio_write(32'h0020,2,15);
                mmio_write(32'h0030,fixture_hq*fixture_d,15); mmio_write(32'h0040,col_beats,15);
                mmio_write(32'h0050,32'h3c00,15); mmio_write(32'h0060,32'h11,15);
                // Transport only: ACT receives exact attention-produced bytes.
                for (beat=0;beat<col_beats;beat=beat+1) begin
                    packed_word = 0;
                    for (lane=0;lane<16;lane=lane+1)
                        packed_word[8*lane +: 8] = output_memory[bank_offset+4096+beat*16+lane];
                    full_write(32'h10000+beat*16,packed_word);
                    // Index 128 is outside ACT's implemented 128-word depth.
                    // Its rejected write must not wrap onto ACT word zero.
                    if (tile == 0 && beat == 0)
                        full_write(32'h10800,128'hdeadbeefcafef00d1122334455667788);
                    for (row=0;row<2;row=row+1) begin
                        packed_word = 0;
                        for (lane=0;lane<16;lane=lane+1)
                            packed_word[8*lane +: 8] = projection_weight(tile,row,beat*16+lane);
                        full_write(32'h100000+(beat*2+row)*16,packed_word);
                        // Unknown MMIO must not reuse the preceding memory
                        // write enable with its newly captured data/index.
                        if (tile == 0 && beat == 0 && row == 0)
                            full_write(32'h4080,128'h8899aabbccddeeff0123456789abcdef);
                    end
                end
                // Each P2 row/block entry is {weight FP16, activation FP16}.
                entries = 2*blocks;
                for (word_index=0;word_index<(entries+3)/4;word_index=word_index+1) begin
                    packed_word = 0;
                    for (lane=0;lane<4;lane=lane+1) begin
                        linear = word_index*4+lane;
                        if (linear < entries) begin
                            offset = bank_offset+6144+2*(linear%blocks);
                            act_scale = {output_memory[offset+1],output_memory[offset]};
                            packed_word[32*lane +: 32] = {16'h3c00,act_scale};
                        end
                    end
                    full_write(32'h380000+word_index*16,packed_word);
                end
                mmio_write(32'h0000,1,15);
                legacy_status = 0; timeout = 0;
                while (!legacy_status[0] && timeout < 10000) begin
                    mmio_read(32'h0010,legacy_status); timeout = timeout+1;
                    check(!legacy_status[2],"P2 projection accepts descriptor");
                end
                check(legacy_status[0],"P2 projection bounded completion");
                for (row=0;row<2;row=row+1) begin
                    expected_accum = 0;
                    for (block_id=0;block_id<blocks;block_id=block_id+1) begin
                        raw_dot = 0;
                        for (element=0;element<32;element=element+1) begin
                            q_value = output_memory[bank_offset+4096+block_id*32+element];
                            if (q_value >= 128) q_value = q_value-256;
                            raw_dot = raw_dot+q_value*projection_weight(tile,row,block_id*32+element);
                        end
                        offset = bank_offset+6144+2*block_id;
                        act_scale = {output_memory[offset+1],output_memory[offset]};
                        scale_q32 = $rtoi(half_real(act_scale)*4294967296.0);
                        contribution = raw_dot*scale_q32;
                        expected_accum = expected_accum+(contribution >>> 16);
                    end
                    full_read(32'h340000+row*16,read_word);
                    if (read_word[15:0] !== row || $signed(read_word[79:16]) !== expected_accum)
                        $fatal(1,"[TB][FAIL] retained P2 projection tile=%0d row=%0d got=%0d expected=%0d",
                               tile,row,$signed(read_word[79:16]),expected_accum);
                    checks = checks+1;
                end
                mmio_read(32'h01d8,legacy_status); check(legacy_status == 0,"P2 stream reports no error");
                mmio_read(32'h4008,legacy_status); check(legacy_status == 10,"attention remains retained across Wo row tiles");
            end
            $display("[TB] Attention raw Q8/FP16 transport -> P2 projection: two Wo row tiles checked");
        end
    endtask


    task load_dense_vectors;
        integer handle, descriptor, field, vector_case;
        begin
            if (!$value$plusargs("ATTENTION_VECTOR_DIR=%s",vector_directory))
                vector_directory = ".";
            $sformat(vector_input_path,"%0s/attention_dense_vectors.mem",vector_directory);
            $sformat(vector_expected_path,"%0s/attention_dense_expected.mem",vector_directory);
            handle = $fopen(vector_input_path,"r");
            check(handle != 0,"input vector file exists; set +ATTENTION_VECTOR_DIR to its directory");
            $fclose(handle);
            handle = $fopen(vector_expected_path,"r");
            check(handle != 0,"expected vector file exists; set +ATTENTION_VECTOR_DIR to its directory");
            $fclose(handle);
            $readmemh(vector_input_path,vector_input);
            $readmemh(vector_expected_path,vector_expected);
            check(vector_input[0] == 3 && vector_input[1] == 16 &&
                  vector_input[2] <= 65536 && vector_input[3] <= 8192,
                  "dense vector header count, stride and capacity");
            for (field=0;field<4;field=field+1)
                check(vector_input[field] === vector_expected[field],"input and expected vector headers agree");
            for (vector_case=0;vector_case<vector_input[0];vector_case=vector_case+1) begin
                descriptor = 4+16*vector_case;
                for (field=0;field<16;field=field+1)
                    check(vector_input[descriptor+field] === vector_expected[descriptor+field],
                          "input and expected descriptors agree");
                check(vector_input[descriptor+4]+vector_input[descriptor]*vector_input[descriptor+1] <= vector_input[2] &&
                      vector_input[descriptor+5]+vector_input[descriptor]*vector_input[descriptor+2]*vector_input[descriptor+3] <= vector_input[2] &&
                      vector_input[descriptor+6]+vector_input[descriptor]*vector_input[descriptor+2]*vector_input[descriptor+3] <= vector_input[2] &&
                      vector_input[descriptor+7]+vector_input[descriptor+3] <= vector_input[2],
                      "input descriptor spans fit immutable vector payload");
                check(vector_input[descriptor+8]+vector_input[descriptor]*vector_input[descriptor+1] <= vector_input[3] &&
                      vector_input[descriptor+9]+vector_input[descriptor]*vector_input[descriptor+1]/32 <= vector_input[3] &&
                      vector_input[descriptor+10]+vector_input[descriptor]*vector_input[descriptor+1] <= vector_input[3] &&
                      vector_input[descriptor+11]+vector_input[descriptor]*vector_input[descriptor+1] <= vector_input[3],
                      "expected descriptor spans fit immutable vector payload");
            end
            $display("[TB] Loaded independent dense vectors: cases=%0d input_words=%0d expected_words=%0d",
                     vector_input[0],vector_input[2],vector_input[3]);
        end
    endtask
    task verify_dense_reference;
        input integer reference_offset, oracle;
        integer element;
        reg [31:0] actual_bits, expected_bits;
        real actual, expected, difference, vscale, magnitude;
        real error_energy, reference_energy, max_abs, max_relative, ratio, max_ratio, nmse;
        begin
            vscale = 0.0;
            for (element=0;element<fixture_n*fixture_hkv*fixture_d;element=element+1) begin
                magnitude = absolute(half_real(vector_input[vector_v_offset+element]));
                if (magnitude > vscale) vscale = magnitude;
            end
            check(vscale > 0.0,"dense vector V has a nonzero comparison scale");
            error_energy = 0.0; reference_energy = 0.0;
            max_abs = 0.0; max_relative = 0.0; max_ratio = 0.0;
            for (element=0;element<fixture_hq*fixture_d;element=element+1) begin
                actual_bits = output_word(bank_offset+4*element);
                expected_bits = vector_expected[reference_offset+element];
                check((^actual_bits !== 1'bx) && actual_bits[30:23] != 255 &&
                      (^expected_bits !== 1'bx) && expected_bits[30:23] != 255,
                      "raw dense context and independent reference are finite");
                actual = fp32_real(actual_bits); expected = fp32_real(expected_bits);
                difference = absolute(actual-expected);
                error_energy = error_energy+difference*difference;
                reference_energy = reference_energy+expected*expected;
                if (difference > max_abs) max_abs = difference;
                if (absolute(expected) >= 0.01*vscale) begin
                    ratio = difference/absolute(expected);
                    if (ratio > max_relative) max_relative = ratio;
                end
                ratio = difference/(2.0e-6+2.0e-6*absolute(expected));
                if (ratio > max_ratio) max_ratio = ratio;
                if (ratio > 1.0)
                    $fatal(1,"[TB][FAIL] dense context case=%0d oracle=%0d element=%0d got=%08x expected=%08x abs_error=%e gate_ratio=%e",
                           cases,oracle,element,actual_bits,expected_bits,difference,ratio);
                checks = checks+1;
            end
            check(reference_energy > 0.0,"dense context reference has nonzero energy");
            nmse = error_energy/reference_energy;
            $display("[TB] Dense context case=%0d oracle=%0d elements=%0d max_abs=%e max_abs_over_vscale=%e gated_relative=%e NMSE=%e tight_gate_ratio=%e",
                     cases,oracle,fixture_hq*fixture_d,max_abs,max_abs/vscale,max_relative,nmse,max_ratio);
            check(nmse <= 1.0e-6 && max_abs/vscale <= 1.0e-3 && max_relative <= 5.0e-3,
                  "unchanged NMSE, scaled absolute and gated relative context acceptance");
        end
    endtask
    task run_dense_vectors;
        integer vector_case, descriptor, element, offset, token, visible_count, expected_masks, expected_kv;
        integer old_q, old_k, old_v, old_mask, old_reads, old_writes, old_b;
        reg [15:0] actual_scale;
        begin
            for (vector_case=0;vector_case<vector_input[0];vector_case=vector_case+1) begin
                descriptor = 4+16*vector_case;
                configure(20,vector_input[descriptor],vector_input[descriptor+1],
                          vector_input[descriptor+2],vector_input[descriptor+3]);
                vector_mode = 1;
                vector_q_offset = vector_input[descriptor+4]; vector_k_offset = vector_input[descriptor+5];
                vector_v_offset = vector_input[descriptor+6]; vector_mask_offset = vector_input[descriptor+7];
                vector_online_offset = vector_input[descriptor+8]; vector_scale_offset = vector_input[descriptor+9];
                vector_q8_offset = vector_input[descriptor+10]; vector_math_offset = vector_input[descriptor+11];
                $display("[TB] Dense fixture index=%0d D=%0d Hq=%0d Hkv=%0d N=%0d flags=%08x seed=%08x",
                         vector_case,fixture_d,fixture_hq,fixture_hkv,fixture_n,
                         vector_input[descriptor+12],vector_input[descriptor+13]);
                old_q = q_reads; old_k = k_reads; old_v = v_reads; old_mask = mask_reads;
                old_reads = read_count; old_writes = write_count; old_b = b_count;
                launch(); await_done(0);
                // oracle=0: ordered binary32 recurrence; oracle=1: separately
                // generated high-precision two-pass mathematical softmax.
                verify_dense_reference(vector_online_offset,0);
                verify_dense_reference(vector_math_offset,1);
                for (element=0;element<fixture_hq*fixture_d/32;element=element+1) begin
                    offset = bank_offset+6144+2*element;
                    actual_scale = {output_memory[offset+1],output_memory[offset]};
                    if (actual_scale !== vector_expected[vector_scale_offset+element][15:0])
                        $fatal(1,"[TB][FAIL] dense scale case=%0d block=%0d got=%04x expected=%04x",
                               cases,element,actual_scale,vector_expected[vector_scale_offset+element][15:0]);
                    checks = checks+1;
                end
                for (element=0;element<fixture_hq*fixture_d;element=element+1) begin
                    if (output_memory[bank_offset+4096+element] !== vector_expected[vector_q8_offset+element][7:0])
                        $fatal(1,"[TB][FAIL] dense Q8 case=%0d element=%0d got=%02x expected=%02x",
                               cases,element,output_memory[bank_offset+4096+element],vector_expected[vector_q8_offset+element][7:0]);
                    checks = checks+1;
                end
                visible_count = 0; expected_masks = 0;
                for (token=0;token<fixture_n;token=token+1) begin
                    if (visible(token)) visible_count = visible_count+1;
                    if (token == 0 || token%16 == 0) expected_masks = expected_masks+1;
                    else if (visible(token-1)) expected_masks = expected_masks+1;
                end
                expected_masks = expected_masks*fixture_hkv;
                expected_kv = fixture_hkv*visible_count*fixture_d/8;
                check(q_reads-old_q == fixture_hq*fixture_d/4 && k_reads-old_k == expected_kv &&
                      v_reads-old_v == expected_kv && mask_reads-old_mask == expected_masks,
                      "dense Q/K/V/mask external AR counts prove beat reuse and grouped-head sharing");
                check(read_count-old_reads == fixture_hq*fixture_d/4+2*expected_kv+expected_masks,
                      "dense external reads contain no extra head or dimension reload");
                check(write_count-old_writes == fixture_hq*fixture_d*2+fixture_hq*fixture_d/32 &&
                      b_count-old_b == write_count-old_writes,"dense outputs each acknowledged once");
                check((fixture_hq*fixture_d*4 == 4096 || output_memory[bank_offset+fixture_hq*fixture_d*4] === 8'hcd) &&
                      output_memory[bank_offset+4096+fixture_hq*fixture_d] === 8'hcd &&
                      output_memory[bank_offset+6144+fixture_hq*fixture_d/16] === 8'hcd,"dense output tail guards intact");
                $display("[TB] Dense AXI reuse index=%0d Q=%0d K=%0d V=%0d mask=%0d exact_Q8_and_scale=PASS",
                         vector_case,q_reads-old_q,k_reads-old_k,v_reads-old_v,mask_reads-old_mask);
                mmio_write(16'h4004,2,15); mmio_read(16'h4008,status_word);
                check(status_word == 8,"dense ACK preserves retained output");
                mmio_write(16'h4004,4,15); mmio_read(16'h4008,status_word);
                check(status_word == 0,"dense RELEASE invalidates retained output");
            end
            vector_mode = 0;
        end
    endtask

    task descriptor_reject;
        input [15:0] offset;
        input [31:0] replacement;
        integer old_reads, old_writes;
        begin
            configure(0,32,1,1,3); mmio_write(offset,replacement,15);
            old_reads = read_count; old_writes = write_count;
            launch(); await_done(1);
            check(read_count == old_reads && write_count == old_writes, "bad descriptor rejected before any DDR transfer");
        end
    endtask
    task head_pair_reject;
        input [31:0] raw_heads, raw_kvheads;
        integer old_reads, old_writes, timeout;
        reg was_retained;
        reg [31:0] read_heads, read_kvheads;
        begin
            $display("[TB] Head-pair reject raw_Hq=%08x raw_Hkv=%08x",raw_heads,raw_kvheads);
            was_retained = engine_retained;
            // Keep the memory fixture benign; only the actual MMIO descriptor
            // receives the raw invalid values, without truncation or division.
            configure(0,32,1,1,1);
            mmio_write(16'h401c,raw_heads,15);
            mmio_write(16'h4020,raw_kvheads,15);
            mmio_read(16'h401c,read_heads); mmio_read(16'h4020,read_kvheads);
            check(read_heads === raw_heads && read_kvheads === raw_kvheads,
                  "head-pair rejection receives both full-width MMIO fields");
            if (was_retained) check(engine_retained,"idle descriptor edits preserve prior retained result until START");
            old_reads = read_count; old_writes = write_count;
            launch();
            timeout = 0;
            while (!engine_done && timeout < 300) begin @(negedge clk); timeout = timeout+1; end
            if (!engine_done || engine_busy)
                $fatal(1,"[TB][FAIL] head-pair reject raw_Hq=%08x raw_Hkv=%08x did not complete validation within 300 cycles",
                       raw_heads,raw_kvheads);
            check(engine_done && !engine_busy,"invalid head pair rejected before compute begins");
            await_done(1);
            check(read_count == old_reads && write_count == old_writes && !engine_retained,
                  "invalid full-width head pair issues no DDR traffic or retained output");
            if (was_retained) $display("[TB] Head-pair rejection invalidated prior retained output");
        end
    endtask
    task run_head_pair_coverage;
        integer heads, kvheads, alias_index, matrix_invalid, high_bit_cases;
        reg legal_pair;
        reg [31:0] alias_value, compatible_heads;
        begin
            // The public contract has eight legal pairs. The unchanged numeric
            // oracle also checks group size three and distinct V for KV head 2.
            run_success(0,32,1,1,3);
            run_success(0,32,2,1,3);
            run_success(0,32,2,2,3);
            run_success(0,32,3,1,3);
            run_success(0,32,3,3,3);
            run_success(0,32,4,1,3);
            run_success(0,32,4,2,3);
            run_success(0,32,4,4,3);
            // Leave a valid output retained for the first invalid pair. Its
            // START must invalidate the previous result even though it fails.
            configure(0,32,1,1,1); launch(); await_done(0); verify_outputs();
            check(engine_retained,"head-pair rejection fixture has prior retained output");
            matrix_invalid = 0;
            for (heads=0;heads<=5;heads=heads+1)
                for (kvheads=0;kvheads<=5;kvheads=kvheads+1) begin
                    legal_pair = 0;
                    // Independent specification arithmetic, not DUT internals
                    // or a copy of its pair-decode table. Never divide by zero.
                    if (heads >= 1 && heads <= 4 && kvheads >= 1 && kvheads <= 4)
                        legal_pair = heads%kvheads == 0;
                    if (!legal_pair) begin
                        head_pair_reject(heads,kvheads);
                        matrix_invalid = matrix_invalid+1;
                    end
                end
            high_bit_cases = 0;
            for (alias_index=0;alias_index<5;alias_index=alias_index+1) begin
                case (alias_index)
                    0: begin alias_value = 32'h00040001; compatible_heads = 1; end
                    1: begin alias_value = 32'h80000003; compatible_heads = 3; end
                    2: begin alias_value = 32'hffffffff; compatible_heads = 3; end
                    3: begin alias_value = 32'h00000009; compatible_heads = 1; end
                    4: begin alias_value = 32'h00000104; compatible_heads = 4; end
                endcase
                head_pair_reject(alias_value,32'd1);
                head_pair_reject(compatible_heads,alias_value);
                high_bit_cases = high_bit_cases+2;
            end
            check(matrix_invalid == 28 && high_bit_cases == 10,"complete invalid head-pair and full-width alias coverage");
            $display("[TB] Head-pair coverage valid_pairs=8 matrix_invalid_pairs=%0d high_bit_cases=%0d retained_reject_cases=1",
                     matrix_invalid,high_bit_cases);
        end
    endtask
    task busy_abort;
        input [15:0] offset;
        input [31:0] replacement;
        integer timeout, original_writes;
        begin
            configure(0,32,1,1,3); freeze_read = 1; original_writes = write_count;
            launch(); timeout = 0;
            while (!ar_pending && timeout < 300) begin @(negedge clk); timeout = timeout+1; end
            check(ar_pending, "busy-abort fixture owns an outstanding read");
            mmio_write(16'h4010,32'hffffffff,0);
            mmio_write(16'h4004,7,2);
            check(engine_busy && !engine_done, "zero descriptor strobe and upper CTRL byte do not abort");
            mmio_write(offset,replacement,15);
            repeat (30) @(negedge clk);
            mmio_read(16'h4008,status_word);
            check(status_word == 1, "busy mutation cannot publish before outstanding R drains");
            freeze_read = 0; await_done(2);
            check(write_count == original_writes, "busy read abort never writes output");
        end
    endtask
    task response_error;
        input integer kind;
        integer writes_start;
        begin
            configure(0,32,1,1,1); injection = kind; writes_start = write_count;
            launch(); await_done(3);
            check(injected, "requested AXI fault was injected");
            if (kind < 4) check(write_count == writes_start, "read protocol error stops before output");
        end
    endtask

    initial begin
        #(64'd20000000000);
        if (!completed) $fatal(1,"[TB][FAIL] tb_Attention_Engine watchdog");
    end
    initial begin
        for (i=0;i<32768;i=i+1) output_memory[i] = 8'hcd;
        wait(validation_completed);
        load_dense_vectors();
        reset_dut();
        mmio_read(16'h4000,value_word); check(value_word === 32'h41540101, "attention ABI through actual AI_IP_top slave");
        mmio_read(16'h404c,value_word); check(value_word === 1, "attention capability through actual top slave");
        run_mapping_read_coverage();
        run_mapping_transition_stalls();
        // All four 32-bit lanes and all four byte enables; no-op strobes and
        // upper CTRL bytes must neither start nor clear state.
        for (i=0;i<4;i=i+1) begin
            mmio_write(16'h4028+4*i,32'h11223344,15);
            for (j=0;j<4;j=j+1) mmio_write(16'h4028+4*i,32'ha1b2c3d4,1<<j);
            mmio_read(16'h4028+4*i,value_word); check(value_word === 32'ha1b2c3d4, "lane-steered byte-strobe descriptor merge");
            mmio_write(16'h4028+4*i,32'hffffffff,0);
            mmio_read(16'h4028+4*i,value_word); check(value_word === 32'ha1b2c3d4, "zero strobe preserves descriptor");
        end
        mmio_write(16'h4004,1,2);
        mmio_read(16'h4008,status_word); check(status_word == 0, "CTRL low-byte strobe is required");
        run_success(0,32,4,1,31);
        run_success(0,32,4,2,32);
        run_success(0,32,4,4,33);
        run_success(0,32,4,4,129);
        run_success(1,32,4,2,33);
        run_success(2,32,4,4,129);
        run_success(3,256,4,2,3);
        run_success(5,32,4,2,33);
        run_success(8,32,1,1,3);
        run_success(13,32,1,1,1);
        run_success(14,32,1,1,1);
        configure(15,32,1,1,1); writes_before = write_count;
        launch(); await_done(5);
        check(write_count == writes_before && !engine_retained,
              "finite-input FP32 product overflow drains with error and no output writes/publication");
        run_dense_vectors();
        run_head_pair_coverage();
        run_success(4,32,1,1,32768);
        run_success(0,32,1,1,4096);
        configure(6,32,1,1,33); count_before = kv_reads; writes_before = write_count;
        launch(); await_done(6);
        check(kv_reads == count_before && write_count == writes_before, "all-masked command reads no K/V and publishes no output");
        for (errors_index=9;errors_index<=12;errors_index=errors_index+1) begin
            configure(errors_index,32,1,1,3); launch(); await_done(4);
        end
        descriptor_reject(16'h4018,31); descriptor_reject(16'h4018,288);
        descriptor_reject(16'h401c,0); descriptor_reject(16'h4020,3);
        descriptor_reject(16'h4024,0); descriptor_reject(16'h4024,32769);
        descriptor_reject(16'h4028,32'h6ffffffc); descriptor_reject(16'h4028,Q_BASE+2);
        descriptor_reject(16'h402c,K_BASE+1); descriptor_reject(16'h4030,V_BASE+1);
        descriptor_reject(16'h4040,OUT_BASE+6145);
        descriptor_reject(16'h4038,32'h7ffffffc);
        descriptor_reject(16'h4038,Q_BASE);
        descriptor_reject(16'h403c,Q_BASE);
        for (errors_index=1;errors_index<=5;errors_index=errors_index+1) response_error(errors_index);
        busy_abort(16'h4004,1); busy_abort(16'h4004,2); busy_abort(16'h4004,4);
        busy_abort(16'h4010,32'hdeadbeef); busy_abort(16'h4044,32'hbadc0ffe);
        // Mutation after W acceptance, while its B response is held, must
        // drain the original write before publishing the original identity.
        configure(0,32,1,1,1); freeze_b = 1; launch();
        count_before = 0;
        while (!b_pending && count_before < 100000) begin @(negedge clk); count_before = count_before+1; end
        check(b_pending, "late-B abort fixture owns write response");
        mmio_write(16'h4044,32'hffffffff,15);
        repeat (30) @(negedge clk);
        check(engine_busy && !engine_done && !engine_retained, "busy abort waits for late B");
        freeze_b = 0; await_done(2);
        // Shared reset is permitted to discard the outstanding peer response.
        configure(0,32,1,1,1); freeze_read = 1; launch();
        count_before = 0;
        while (!ar_pending && count_before < 300) begin @(negedge clk); count_before = count_before+1; end
        check(ar_pending, "reset fixture owns read"); reset_dut();
        mmio_read(16'h4008,status_word); check(status_word == 0, "reset has no stale DONE/retained result");
        run_success(0,32,1,1,3);
        check(final_b_stall_cycles > 20 && aw_first_count > 0 && w_first_count > 0,
              "observed final-B stall and both independent write-channel orders");
        $display("[TB][PASS] tb_Attention_Engine checks=%0d cases=%0d cycles_since_reset=%0d",checks,cases,cycle_count);
        completed = 1;
        if (AUTO_FINISH) $finish;
    end
endmodule

// Independent RTL register-interface checks reach each validation stage on an
// exact edge. AXI readiness is held low: accepted descriptors are stopped at
// their first Q request, while rejected/aborted descriptors must issue none.
// Full arithmetic and AXI integration still run in tb_Attention_Engine above.
module tb_Attention_Validation(output reg completed = 0);
    reg clk=0, resetn=0, reg_wr_en=0;
    always #5 if (!completed) clk=~clk;
    reg [7:0] reg_wr_addr=0, reg_rd_addr=0;
    reg [31:0] reg_wr_data=0;
    reg [3:0] reg_wr_strb=0;
    wire [31:0] reg_rd_data;
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
    integer checks=0, descriptors=0, valid_cases=0, rejected_cases=0;
    integer region, output_region, peer, direction, which_state, mutation;
    reg [31:0] command [0:12];
    reg [63:0] expected_size [0:6];
    reg [31:0] aligned_step;
    reg [6:0] target_state;
    Attention_Engine dut (
        .clk(clk),.resetn(resetn),.reg_wr_en(reg_wr_en),.reg_wr_addr(reg_wr_addr),
        .reg_wr_data(reg_wr_data),.reg_wr_strb(reg_wr_strb),
        .reg_rd_addr(reg_rd_addr),.reg_rd_data(reg_rd_data),
        .m_att_axi_awid(awid),.m_att_axi_awaddr(awaddr),.m_att_axi_awlen(awlen),
        .m_att_axi_awsize(awsize),.m_att_axi_awburst(awburst),.m_att_axi_awlock(awlock),
        .m_att_axi_awcache(awcache),.m_att_axi_awprot(awprot),.m_att_axi_awqos(awqos),
        .m_att_axi_awregion(awregion),.m_att_axi_awvalid(awvalid),.m_att_axi_awready(1'b0),
        .m_att_axi_wdata(wdata),.m_att_axi_wstrb(wstrb),.m_att_axi_wlast(wlast),
        .m_att_axi_wvalid(wvalid),.m_att_axi_wready(1'b0),
        .m_att_axi_bid(1'b0),.m_att_axi_bresp(2'd0),.m_att_axi_bvalid(1'b0),.m_att_axi_bready(bready),
        .m_att_axi_arid(arid),.m_att_axi_araddr(araddr),.m_att_axi_arlen(arlen),
        .m_att_axi_arsize(arsize),.m_att_axi_arburst(arburst),.m_att_axi_arlock(arlock),
        .m_att_axi_arcache(arcache),.m_att_axi_arprot(arprot),.m_att_axi_arqos(arqos),
        .m_att_axi_arregion(arregion),.m_att_axi_arvalid(arvalid),.m_att_axi_arready(1'b0),
        .m_att_axi_rid(1'b0),.m_att_axi_rdata(128'd0),.m_att_axi_rresp(2'd0),
        .m_att_axi_rlast(1'b1),.m_att_axi_rvalid(1'b0),.m_att_axi_rready(rready)
    );
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1)
                $fatal(1,"[TB][FAIL] validation descriptor=%0d state=%0d: %0s",descriptors,dut.state_r,message);
            checks=checks+1;
        end
    endtask
    task no_ddr;
        begin
            check(!arvalid && !awvalid && !wvalid && !dut.mem_busy && dut.state_r!=dut.S_MEM_CMD,
                  "validation/rejection cannot issue an internal or external DDR request");
        end
    endtask
    task reset_engine;
        integer n;
        begin
            resetn=0; reg_wr_en=0;
            repeat (2) @(negedge clk);
            check(!dut.busy && !dut.done_r && !dut.retained_valid_r && dut.span_nkv_r===64'd0,
                  "reset clears validation product and command controls");
            for (n=0;n<7;n=n+1)
                check(dut.span_size_r[n]===64'd0 && dut.span_end_r[n]===64'd0,
                      "reset clears every staged size and endpoint");
            resetn=1;
            repeat (8) begin @(negedge clk); no_ddr(); check(!dut.done_r,"reset cannot leak completion"); end
        end
    endtask
    task defaults;
        begin
            descriptors=descriptors+1;
            command[0]=32'hca000000+descriptors;
            command[1]=32; command[2]=1; command[3]=1; command[4]=4;
            command[5]=32'h70010000; command[6]=32'h71000000;
            command[7]=32'h72000000; command[8]=32'h76000000;
            command[9]=32'h77000000; command[10]=32'h77010000;
            command[11]=32'h77020002; command[12]=32'h51000000+descriptors;
        end
    endtask
    task size_oracle;
        begin
            // Descriptor ABI byte counts, evaluated independently from DUT
            // registers and helpers using explicitly unsigned 64-bit operands.
            expected_size[0]={32'd0,command[1]}*{32'd0,command[2]}*64'd4;
            expected_size[1]={32'd0,command[4]}*{32'd0,command[3]}*{32'd0,command[1]}*64'd2;
            expected_size[2]=expected_size[1]; expected_size[3]={32'd0,command[4]};
            expected_size[4]=expected_size[0];
            expected_size[5]={32'd0,command[1]}*{32'd0,command[2]};
            expected_size[6]=(expected_size[5]>>5)*64'd2;
        end
    endtask
    task write_register;
        input [7:0] address;
        input [31:0] value;
        begin
            @(negedge clk); reg_wr_en=1; reg_wr_addr=address; reg_wr_data=value; reg_wr_strb=15;
            @(negedge clk); reg_wr_en=0;
        end
    endtask
    task load_and_start;
        integer n;
        begin
            size_oracle();
            check(!dut.busy,"load descriptor only while idle");
            for (n=0;n<13;n=n+1)
                write_register(n==0 ? 8'h10 : 8'h14+4*n,command[n]);
            write_register(8'h04,1);
            check(dut.state_r==dut.S_VALIDATE && dut.busy && !dut.done_r,"start captures descriptor and enters validation");
            no_ddr();
        end
    endtask
    task expect_error;
        input [31:0] code;
        integer timeout;
        begin
            timeout=0;
            while (!dut.done_r && timeout<16) begin no_ddr(); @(negedge clk); timeout=timeout+1; end
            no_ddr();
            check(dut.done_r && !dut.busy && !dut.retained_valid_r && dut.error_code_r===code,
                  "invalid or mutated descriptor publishes only its expected error");
            check(dut.done_tag_r===command[0] && dut.done_gen_r===command[12],
                  "validation error preserves captured tag and generation");
            rejected_cases=rejected_cases+1;
        end
    endtask
    task run_validation;
        input accepted, bad_shape;
        integer n;
        begin
            load_and_start();
            @(negedge clk);
            if (bad_shape) begin
                check(dut.state_r==dut.S_DRAIN,"full-width shape rejection precedes span preparation");
                expect_error(1);
            end else begin
                check(dut.state_r==dut.S_SPAN_SIZE && dut.span_nkv_r===({32'd0,command[4]}*{32'd0,command[3]}),
                      "validated N times Hkv is captured before size preparation");
                no_ddr(); @(negedge clk);
                check(dut.state_r==dut.S_SPAN_END,"one size preparation cycle");
                for (n=0;n<7;n=n+1)
                    check(dut.span_size_r[n]===expected_size[n],"all seven registered byte sizes match descriptor ABI");
                no_ddr(); @(negedge clk);
                check(dut.state_r==dut.S_SPANS,"one endpoint preparation cycle");
                for (n=0;n<7;n=n+1)
                    check(dut.span_end_r[n]===({32'd0,command[5+n]}+expected_size[n]),
                          "all seven registered endpoints preserve full-width addition");
                no_ddr(); @(negedge clk);
                if (accepted) begin
                    check(dut.state_r==dut.S_Q_HEAD,"valid spans enter Q loading at acceptance plus four cycles");
                    no_ddr(); @(negedge clk);
                    check(dut.state_r==dut.S_Q_REQ,"existing Q preparation cycle remains");
                    no_ddr(); @(negedge clk);
                    check(dut.state_r==dut.S_MEM_CMD && dut.mem_addr_r===command[5] && !dut.mem_write_r,
                          "first DDR command at acceptance plus six cycles uses captured Q address");
                    @(negedge clk);
                    check(arvalid && araddr==={8'd0,command[5]} && !awvalid && !wvalid,
                          "validated descriptor reaches the actual AXI read channel");
                    valid_cases=valid_cases+1;
                    reset_engine();
                end else begin
                    check(dut.state_r==dut.S_DRAIN,"bad span drains instead of loading Q");
                    expect_error(1);
                end
            end
        end
    endtask
    task reach_stage;
        input [6:0] stage;
        integer timeout;
        begin
            load_and_start(); timeout=0;
            while (dut.state_r!=stage && timeout<4) begin no_ddr(); @(negedge clk); timeout=timeout+1; end
            check(dut.state_r==stage && dut.busy,"requested new validation stage reached");
            no_ddr();
        end
    endtask
    initial begin
        reset_engine();
        // Maximum supported shape: each of the seven spans may end exactly
        // at DDR's upper bound; one aligned address step beyond must reject.
        for (region=0;region<7;region=region+1) begin
            defaults(); command[1]=256; command[2]=4; command[3]=4; command[4]=32768;
            size_oracle(); command[5+region]=64'h80000000-expected_size[region];
            run_validation(1,0);
            defaults(); command[1]=256; command[2]=4; command[3]=4; command[4]=32768;
            size_oracle();
            aligned_step=(region==0 || region==4) ? 4 : (region==1 || region==2 || region==6) ? 2 : 1;
            command[5+region]=64'h80000000-expected_size[region]+aligned_step;
            run_validation(0,0);
        end
        // Every output versus every other input/output, on both sides of the
        // half-open boundary. Nonoverlapping adjacency is valid; the smallest
        // aligned step into its neighbor is invalid. No expectation is relaxed.
        for (output_region=4;output_region<7;output_region=output_region+1)
            for (peer=0;peer<7;peer=peer+1)
                if (peer!=output_region)
                    for (direction=0;direction<2;direction=direction+1) begin
                        defaults();
                        // A two-byte scale span needs a different aligned base
                        // on each side of a four-byte-aligned OUT adjacency.
                        if (peer==6 && direction==0) command[11]=32'h77020000;
                        size_oracle();
                        command[5+output_region]=direction ? command[5+peer]+expected_size[peer] :
                                                                          command[5+peer]-expected_size[output_region];
                        run_validation(1,0);
                        defaults();
                        if (peer==6 && direction==0) command[11]=32'h77020000;
                        size_oracle();
                        aligned_step=output_region==4 ? 4 : output_region==6 ? 2 : 1;
                        command[5+output_region]=direction ? command[5+peer]+expected_size[peer]-aligned_step :
                                                                          command[5+peer]-expected_size[output_region]+aligned_step;
                        run_validation(0,0);
                    end
        defaults(); command[6]=command[5]; command[7]=command[5]; command[8]=command[5];
        run_validation(1,0);
        defaults(); command[5]=32'h70000000; run_validation(1,0);
        defaults(); command[5]=32'h6ffffffc; run_validation(0,0);
        // This endpoint exceeds 32 bits; compare the raw registered 64-bit
        // result before checking rejection, so truncation cannot go unnoticed.
        defaults(); command[5]=32'hfffffffc; run_validation(0,0);
        // Invalid high bits must not be truncated into a supported shape.
        for (region=1;region<=4;region=region+1) begin
            defaults(); command[region]=command[region] | 32'h80000000; run_validation(0,1);
        end
        defaults(); command[1]=32'hffffffff; run_validation(0,1);
        defaults(); command[4]=32'hffffffff; run_validation(0,1);
        for (which_state=0;which_state<2;which_state=which_state+1) begin
            target_state=which_state==0 ? dut.S_SPAN_SIZE : dut.S_SPAN_END;
            defaults(); reach_stage(target_state); reset_engine();
            for (mutation=0;mutation<3;mutation=mutation+1) begin
                defaults(); reach_stage(target_state);
                // Drive now, at the observed negative edge, so the mutation
                // wins over this exact stage's normal sequential assignments.
                reg_wr_en=1; reg_wr_strb=15;
                reg_wr_addr=mutation==0 ? 8'h10 : mutation==1 ? 8'h44 : 8'h04;
                reg_wr_data=mutation==2 ? 1 : 32'hffffffff;
                @(negedge clk); reg_wr_en=0;
                check(dut.state_r==dut.S_DRAIN,"busy mutation has priority in each new stage");
                expect_error(2);
                check(dut.cfg_r[0]===command[0] && dut.cfg_r[12]===command[12],
                      "busy mutation cannot alter configuration identity");
            end
        end
        reset_engine();
        $display("[TB][PASS] tb_Attention_Validation checks=%0d descriptors=%0d accepted=%0d rejected_or_mutated=%0d reset_stages=2 preparation_cycles=2",
                 checks,descriptors,valid_cases,rejected_cases);
        completed=1;
    end
endmodule
`endif

