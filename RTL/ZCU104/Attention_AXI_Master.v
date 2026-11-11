`timescale 1ns/1ps
// One scalar command at a time. Every external transfer is an aligned 128-bit
// single beat (ID=0, LEN=0, SIZE=4, INCR); WSTRB selects the scalar bytes.
// AW and W progress independently. A malformed read lacking RLAST is drained
// through RLAST before reporting failure. There is deliberately no cancellation
// timeout: a nonresponding interconnect requires the shared system reset.
// One read-beat cache reuses scalar fields of an aligned 16-byte beat. Only a
// successful ID0/OKAY/RLAST read fills it. Reset, explicit invalidation, writes,
// and errors invalidate it. Invalidating an outstanding read also discards its
// eventual cache fill; it does not cancel or modify that command's response.
module Attention_AXI_Master (
    input wire clk, resetn,
    input wire cache_invalidate,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire cmd_write,
    input wire [31:0] cmd_addr, cmd_wdata,
    input wire [1:0] cmd_size,
    output wire busy,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg [31:0] rsp_rdata,
    output reg rsp_error,
    output wire [0:0] m_att_axi_awid,
    output wire [39:0] m_att_axi_awaddr,
    output wire [7:0] m_att_axi_awlen,
    output wire [2:0] m_att_axi_awsize,
    output wire [1:0] m_att_axi_awburst,
    output wire m_att_axi_awlock,
    output wire [3:0] m_att_axi_awcache,
    output wire [2:0] m_att_axi_awprot,
    output wire [3:0] m_att_axi_awqos, m_att_axi_awregion,
    output wire m_att_axi_awvalid,
    input wire m_att_axi_awready,
    output wire [127:0] m_att_axi_wdata,
    output wire [15:0] m_att_axi_wstrb,
    output wire m_att_axi_wlast, m_att_axi_wvalid,
    input wire m_att_axi_wready,
    input wire [0:0] m_att_axi_bid,
    input wire [1:0] m_att_axi_bresp,
    input wire m_att_axi_bvalid,
    output wire m_att_axi_bready,
    output wire [0:0] m_att_axi_arid,
    output wire [39:0] m_att_axi_araddr,
    output wire [7:0] m_att_axi_arlen,
    output wire [2:0] m_att_axi_arsize,
    output wire [1:0] m_att_axi_arburst,
    output wire m_att_axi_arlock,
    output wire [3:0] m_att_axi_arcache,
    output wire [2:0] m_att_axi_arprot,
    output wire [3:0] m_att_axi_arqos, m_att_axi_arregion,
    output wire m_att_axi_arvalid,
    input wire m_att_axi_arready,
    input wire [0:0] m_att_axi_rid,
    input wire [127:0] m_att_axi_rdata,
    input wire [1:0] m_att_axi_rresp,
    input wire m_att_axi_rlast, m_att_axi_rvalid,
    output wire m_att_axi_rready
);
    localparam [2:0] IDLE=0, READ_ADDR=1, READ_DATA=2, READ_DRAIN=3,
                     WRITE_SEND=4, WRITE_RESP=5, RESPONSE=6;
    reg [2:0] state_r;
    reg [31:0] address_r;
    reg [1:0] size_r;
    reg [127:0] write_data_r;
    reg [15:0] write_strobe_r;
    reg aw_accepted_r, w_accepted_r;
    reg cache_valid_r, discard_read_r;
    reg [27:0] cache_tag_r;
    reg [127:0] cache_data_r;
    wire [127:0] shifted_read = m_att_axi_rdata >> (8*address_r[3:0]);
    wire [127:0] shifted_cache = cache_data_r >> (8*cmd_addr[3:0]);
    assign busy = state_r != IDLE;
    assign cmd_ready = resetn && state_r == IDLE;
    assign rsp_valid = resetn && state_r == RESPONSE;
    assign m_att_axi_awid = 0;
    assign m_att_axi_awaddr = {8'd0, address_r[31:4], 4'd0};
    assign m_att_axi_awlen = 0;
    assign m_att_axi_awsize = 3'd4;
    assign m_att_axi_awburst = 2'b01;
    assign m_att_axi_awlock = 0;
    assign m_att_axi_awcache = 0;
    assign m_att_axi_awprot = 0;
    assign m_att_axi_awqos = 0;
    assign m_att_axi_awregion = 0;
    assign m_att_axi_awvalid = resetn && state_r == WRITE_SEND && !aw_accepted_r;
    assign m_att_axi_wdata = write_data_r;
    assign m_att_axi_wstrb = write_strobe_r;
    assign m_att_axi_wlast = 1;
    assign m_att_axi_wvalid = resetn && state_r == WRITE_SEND && !w_accepted_r;
    assign m_att_axi_bready = resetn && state_r == WRITE_RESP;
    assign m_att_axi_arid = 0;
    assign m_att_axi_araddr = {8'd0, address_r[31:4], 4'd0};
    assign m_att_axi_arlen = 0;
    assign m_att_axi_arsize = 3'd4;
    assign m_att_axi_arburst = 2'b01;
    assign m_att_axi_arlock = 0;
    assign m_att_axi_arcache = 0;
    assign m_att_axi_arprot = 0;
    assign m_att_axi_arqos = 0;
    assign m_att_axi_arregion = 0;
    assign m_att_axi_arvalid = resetn && state_r == READ_ADDR;
    assign m_att_axi_rready = resetn && (state_r == READ_DATA || state_r == READ_DRAIN);
    always @(posedge clk) begin
        if (!resetn) begin
            state_r <= IDLE;
            address_r <= 0;
            size_r <= 0;
            write_data_r <= 0;
            write_strobe_r <= 0;
            aw_accepted_r <= 0;
            w_accepted_r <= 0;
            rsp_rdata <= 0;
            rsp_error <= 0;
            cache_valid_r <= 0;
            discard_read_r <= 0;
            cache_tag_r <= 0;
            cache_data_r <= 0;
        end else begin
            if (cache_invalidate) begin
                cache_valid_r <= 0;
                if (state_r == READ_ADDR || state_r == READ_DATA || state_r == READ_DRAIN)
                    discard_read_r <= 1;
            end
            case (state_r)
            IDLE: if (cmd_valid) begin
                address_r <= cmd_addr;
                size_r <= cmd_size;
                write_data_r <= {96'd0, cmd_wdata} << (8*cmd_addr[3:0]);
                case (cmd_size)
                    0: write_strobe_r <= 16'h0001 << cmd_addr[3:0];
                    1: write_strobe_r <= 16'h0003 << cmd_addr[3:0];
                    default: write_strobe_r <= 16'h000f << cmd_addr[3:0];
                endcase
                aw_accepted_r <= 0;
                w_accepted_r <= 0;
                rsp_rdata <= 0;
                rsp_error <= 0;
                discard_read_r <= cache_invalidate;
                if (cmd_size == 3 || (cmd_size == 1 && cmd_addr[0]) ||
                    (cmd_size == 2 && |cmd_addr[1:0])) begin
                    cache_valid_r <= 0;
                    rsp_error <= 1;
                    state_r <= RESPONSE;
                end else if (cmd_write) begin
                    cache_valid_r <= 0;
                    state_r <= WRITE_SEND;
                end else if (cache_valid_r && !cache_invalidate && cache_tag_r == cmd_addr[31:4]) begin
                    case (cmd_size)
                        0: rsp_rdata <= {24'd0, shifted_cache[7:0]};
                        1: rsp_rdata <= {16'd0, shifted_cache[15:0]};
                        default: rsp_rdata <= shifted_cache[31:0];
                    endcase
                    state_r <= RESPONSE;
                end else state_r <= READ_ADDR;
            end
            READ_ADDR: if (m_att_axi_arready) state_r <= READ_DATA;
            READ_DATA: if (m_att_axi_rvalid) begin
                case (size_r)
                    0: rsp_rdata <= {24'd0, shifted_read[7:0]};
                    1: rsp_rdata <= {16'd0, shifted_read[15:0]};
                    default: rsp_rdata <= shifted_read[31:0];
                endcase
                rsp_error <= m_att_axi_rresp != 0 || m_att_axi_rid != 0 || !m_att_axi_rlast;
                if (m_att_axi_rresp != 0 || m_att_axi_rid != 0 || !m_att_axi_rlast)
                    cache_valid_r <= 0;
                else if (!discard_read_r && !cache_invalidate) begin
                    cache_valid_r <= 1;
                    cache_tag_r <= address_r[31:4];
                    cache_data_r <= m_att_axi_rdata;
                end
                state_r <= m_att_axi_rlast ? RESPONSE : READ_DRAIN;
            end
            READ_DRAIN: if (m_att_axi_rvalid && m_att_axi_rlast) state_r <= RESPONSE;
            WRITE_SEND: begin
                if (m_att_axi_awvalid && m_att_axi_awready) aw_accepted_r <= 1;
                if (m_att_axi_wvalid && m_att_axi_wready) w_accepted_r <= 1;
                if ((aw_accepted_r || m_att_axi_awready) &&
                    (w_accepted_r || m_att_axi_wready)) state_r <= WRITE_RESP;
            end
            WRITE_RESP: if (m_att_axi_bvalid) begin
                rsp_error <= m_att_axi_bresp != 0 || m_att_axi_bid != 0;
                if (m_att_axi_bresp != 0 || m_att_axi_bid != 0) cache_valid_r <= 0;
                state_r <= RESPONSE;
            end
            RESPONSE: if (rsp_ready) state_r <= IDLE;
            default: begin state_r <= IDLE; cache_valid_r <= 0; end
            endcase
        end
    end
endmodule
