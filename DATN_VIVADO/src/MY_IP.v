`timescale 1ns/1ps

module MY_IP #(
    parameter integer C_S00_AXI_ID_WIDTH     = 1,
    parameter integer C_S00_AXI_DATA_WIDTH   = 128,
    parameter integer C_S00_AXI_ADDR_WIDTH   = 40,
    parameter integer C_S00_AXI_AWUSER_WIDTH = 1,
    parameter integer C_S00_AXI_ARUSER_WIDTH = 1,
    parameter integer C_S00_AXI_WUSER_WIDTH  = 1,
    parameter integer C_S00_AXI_RUSER_WIDTH  = 1,
    parameter integer C_S00_AXI_BUSER_WIDTH  = 1,

    parameter integer NUM_LANES              = 16,
    parameter integer ACT_WIDTH              = 8,
    parameter integer WEIGHT_WIDTH           = 8,
    parameter integer ACC_WIDTH              = 32,
    parameter integer SCALE_WIDTH            = 16,
    parameter integer SCALE_FRAC_BITS        = 15,
    parameter integer RESULT_FIFO_DEPTH      = 8,
    parameter integer MAX_ROWS               = 128,
    parameter integer MAX_COL_BEATS          = 256
) (
    input  wire                                  s00_axi_aclk,
    input  wire                                  s00_axi_aresetn,

    input  wire [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_awid,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]       s00_axi_awaddr,
    input  wire [7:0]                            s00_axi_awlen,
    input  wire [2:0]                            s00_axi_awsize,
    input  wire [1:0]                            s00_axi_awburst,
    input  wire                                  s00_axi_awlock,
    input  wire [3:0]                            s00_axi_awcache,
    input  wire [2:0]                            s00_axi_awprot,
    input  wire [3:0]                            s00_axi_awqos,
    input  wire [3:0]                            s00_axi_awregion,
    input  wire [C_S00_AXI_AWUSER_WIDTH-1:0]     s00_axi_awuser,
    input  wire                                  s00_axi_awvalid,
    output wire                                  s00_axi_awready,

    input  wire [C_S00_AXI_DATA_WIDTH-1:0]       s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1:0]   s00_axi_wstrb,
    input  wire                                  s00_axi_wlast,
    input  wire [C_S00_AXI_WUSER_WIDTH-1:0]      s00_axi_wuser,
    input  wire                                  s00_axi_wvalid,
    output wire                                  s00_axi_wready,

    output wire [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_bid,
    output wire [1:0]                            s00_axi_bresp,
    output wire [C_S00_AXI_BUSER_WIDTH-1:0]      s00_axi_buser,
    output wire                                  s00_axi_bvalid,
    input  wire                                  s00_axi_bready,

    input  wire [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_arid,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]       s00_axi_araddr,
    input  wire [7:0]                            s00_axi_arlen,
    input  wire [2:0]                            s00_axi_arsize,
    input  wire [1:0]                            s00_axi_arburst,
    input  wire                                  s00_axi_arlock,
    input  wire [3:0]                            s00_axi_arcache,
    input  wire [2:0]                            s00_axi_arprot,
    input  wire [3:0]                            s00_axi_arqos,
    input  wire [3:0]                            s00_axi_arregion,
    input  wire [C_S00_AXI_ARUSER_WIDTH-1:0]     s00_axi_aruser,
    input  wire                                  s00_axi_arvalid,
    output wire                                  s00_axi_arready,

    output wire [C_S00_AXI_ID_WIDTH-1:0]         s00_axi_rid,
    output wire [C_S00_AXI_DATA_WIDTH-1:0]       s00_axi_rdata,
    output wire [1:0]                            s00_axi_rresp,
    output wire                                  s00_axi_rlast,
    output wire [C_S00_AXI_RUSER_WIDTH-1:0]      s00_axi_ruser,
    output wire                                  s00_axi_rvalid,
    input  wire                                  s00_axi_rready
);

    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction

    function [C_S00_AXI_ADDR_WIDTH-1:0] axi_next_addr;
        input [C_S00_AXI_ADDR_WIDTH-1:0] addr;
        input [2:0] size;
        input [1:0] burst;
        reg [C_S00_AXI_ADDR_WIDTH-1:0] step;
        begin
            step = {{(C_S00_AXI_ADDR_WIDTH-1){1'b0}}, 1'b1} << size;
            if (burst == 2'b01)
                axi_next_addr = addr + step;
            else
                axi_next_addr = addr;
        end
    endfunction

    localparam integer ADDR_LSB = clog2(C_S00_AXI_DATA_WIDTH / 8);
    localparam [2:0] ADDR_LSB_3 = ADDR_LSB;

    reg wr_active_r;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] wr_addr_r;
    reg [7:0] wr_len_r;
    reg [7:0] wr_beat_r;
    reg [2:0] wr_size_r;
    reg [1:0] wr_burst_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] wr_id_r;
    reg bvalid_r;
    reg wr_done_pending_r;

    reg map_wr_en_r;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] map_wr_addr_r;
    reg [C_S00_AXI_DATA_WIDTH-1:0] map_wr_data_r;
    reg [(C_S00_AXI_DATA_WIDTH/8)-1:0] map_wr_strb_r;

    assign s00_axi_awready = (!wr_active_r) && (!bvalid_r) && (!wr_done_pending_r);
    assign s00_axi_wready  = wr_active_r;
    assign s00_axi_bvalid  = bvalid_r;
    assign s00_axi_bresp   = 2'b00;
    assign s00_axi_bid     = wr_id_r;
    assign s00_axi_buser   = {C_S00_AXI_BUSER_WIDTH{1'b0}};

    wire aw_fire = s00_axi_awvalid && s00_axi_awready;
    wire w_fire  = s00_axi_wvalid && s00_axi_wready;
    wire w_done  = w_fire && (s00_axi_wlast || (wr_beat_r == wr_len_r));

    always @(posedge s00_axi_aclk) begin
        if (!s00_axi_aresetn) begin
            wr_active_r       <= 1'b0;
            wr_addr_r         <= {C_S00_AXI_ADDR_WIDTH{1'b0}};
            wr_len_r          <= 8'd0;
            wr_beat_r         <= 8'd0;
            wr_size_r         <= ADDR_LSB_3;
            wr_burst_r        <= 2'b01;
            wr_id_r           <= {C_S00_AXI_ID_WIDTH{1'b0}};
            bvalid_r          <= 1'b0;
            wr_done_pending_r <= 1'b0;
            map_wr_en_r       <= 1'b0;
            map_wr_addr_r     <= {C_S00_AXI_ADDR_WIDTH{1'b0}};
            map_wr_data_r     <= {C_S00_AXI_DATA_WIDTH{1'b0}};
            map_wr_strb_r     <= {(C_S00_AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            map_wr_en_r <= w_fire;
            if (w_fire) begin
                map_wr_addr_r <= wr_addr_r;
                map_wr_data_r <= s00_axi_wdata;
                map_wr_strb_r <= s00_axi_wstrb;
            end

            if (aw_fire) begin
                wr_active_r <= 1'b1;
                wr_addr_r   <= s00_axi_awaddr;
                wr_len_r    <= s00_axi_awlen;
                wr_beat_r   <= 8'd0;
                wr_size_r   <= s00_axi_awsize;
                wr_burst_r  <= s00_axi_awburst;
                wr_id_r     <= s00_axi_awid;
            end

            if (w_fire) begin
                wr_addr_r <= axi_next_addr(wr_addr_r, wr_size_r, wr_burst_r);
                wr_beat_r <= wr_beat_r + 8'd1;

                if (w_done) begin
                    wr_active_r <= 1'b0;
                    wr_done_pending_r <= 1'b1;
                end
            end

            if (wr_done_pending_r) begin
                bvalid_r <= 1'b1;
                wr_done_pending_r <= 1'b0;
            end

            if (bvalid_r && s00_axi_bready)
                bvalid_r <= 1'b0;
        end
    end

    reg read_active_r;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] rd_addr_r;
    reg [7:0] rd_len_r;
    reg [7:0] rd_beat_r;
    reg [2:0] rd_size_r;
    reg [1:0] rd_burst_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] rd_id_r;

    reg rd_pending_r;
    reg rd_pending_last_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] rd_pending_id_r;

    reg rvalid_r;
    reg rlast_r;
    reg [1:0] rresp_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] rid_r;
    reg [C_S00_AXI_DATA_WIDTH-1:0] rdata_r;

    reg map_rd_en_r;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] map_rd_addr_r;
    wire [C_S00_AXI_DATA_WIDTH-1:0] map_rd_data;
    wire map_rd_valid;
    wire map_rd_error;

    assign s00_axi_arready =
        (!read_active_r) && (!rd_pending_r) && (!rvalid_r) &&
        (!wr_active_r) && (!bvalid_r);
    assign s00_axi_rvalid = rvalid_r;
    assign s00_axi_rlast  = rlast_r;
    assign s00_axi_rresp  = rresp_r;
    assign s00_axi_rid    = rid_r;
    assign s00_axi_rdata  = rdata_r;
    assign s00_axi_ruser  = {C_S00_AXI_RUSER_WIDTH{1'b0}};

    wire ar_fire = s00_axi_arvalid && s00_axi_arready;
    wire r_fire  = s00_axi_rvalid && s00_axi_rready;

    reg issue_read_r;
    reg issue_last_r;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] issue_addr_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] issue_id_r;
    reg [7:0] issue_beat_r;
    reg [7:0] issue_len_r;

    always @* begin
        issue_read_r = 1'b0;
        issue_last_r = 1'b0;
        issue_addr_r = rd_addr_r;
        issue_id_r   = rd_id_r;
        issue_beat_r = rd_beat_r;
        issue_len_r  = rd_len_r;

        if (ar_fire) begin
            issue_read_r = 1'b1;
            issue_addr_r = s00_axi_araddr;
            issue_id_r   = s00_axi_arid;
            issue_beat_r = 8'd0;
            issue_len_r  = s00_axi_arlen;
            issue_last_r = (s00_axi_arlen == 8'd0);
        end else if (read_active_r && (!rd_pending_r) && (!rvalid_r) && (rd_beat_r <= rd_len_r)) begin
            issue_read_r = 1'b1;
            issue_addr_r = rd_addr_r;
            issue_id_r   = rd_id_r;
            issue_beat_r = rd_beat_r;
            issue_len_r  = rd_len_r;
            issue_last_r = (rd_beat_r == rd_len_r);
        end
    end

    always @(posedge s00_axi_aclk) begin
        if (!s00_axi_aresetn) begin
            read_active_r     <= 1'b0;
            rd_addr_r         <= {C_S00_AXI_ADDR_WIDTH{1'b0}};
            rd_len_r          <= 8'd0;
            rd_beat_r         <= 8'd0;
            rd_size_r         <= ADDR_LSB_3;
            rd_burst_r        <= 2'b01;
            rd_id_r           <= {C_S00_AXI_ID_WIDTH{1'b0}};
            rd_pending_r      <= 1'b0;
            rd_pending_last_r <= 1'b0;
            rd_pending_id_r   <= {C_S00_AXI_ID_WIDTH{1'b0}};
            rvalid_r          <= 1'b0;
            rlast_r           <= 1'b0;
            rresp_r           <= 2'b00;
            rid_r             <= {C_S00_AXI_ID_WIDTH{1'b0}};
            rdata_r           <= {C_S00_AXI_DATA_WIDTH{1'b0}};
            map_rd_en_r       <= 1'b0;
            map_rd_addr_r     <= {C_S00_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            map_rd_en_r <= issue_read_r;
            if (issue_read_r)
                map_rd_addr_r <= issue_addr_r;

            if (ar_fire) begin
                read_active_r <= 1'b1;
                rd_addr_r     <= axi_next_addr(s00_axi_araddr, s00_axi_arsize, s00_axi_arburst);
                rd_len_r      <= s00_axi_arlen;
                rd_beat_r     <= 8'd1;
                rd_size_r     <= s00_axi_arsize;
                rd_burst_r    <= s00_axi_arburst;
                rd_id_r       <= s00_axi_arid;
            end else if (issue_read_r) begin
                rd_addr_r <= axi_next_addr(rd_addr_r, rd_size_r, rd_burst_r);
                rd_beat_r <= rd_beat_r + 8'd1;
            end

            if (issue_read_r) begin
                rd_pending_r      <= 1'b1;
                rd_pending_last_r <= issue_last_r;
                rd_pending_id_r   <= issue_id_r;
            end else if (rd_pending_r && map_rd_valid && (!rvalid_r)) begin
                rd_pending_r <= 1'b0;
            end

            if ((!rvalid_r) && rd_pending_r && map_rd_valid) begin
                rvalid_r <= 1'b1;
                rlast_r  <= rd_pending_last_r;
                rid_r    <= rd_pending_id_r;
                rdata_r  <= map_rd_data;
                rresp_r  <= map_rd_error ? 2'b10 : 2'b00;
            end else if (r_fire) begin
                rvalid_r <= 1'b0;
                if (rlast_r)
                    read_active_r <= 1'b0;
            end
        end
    end

    AXI4_Mapping #(
        .AXI_DATA_WIDTH          (C_S00_AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH          (C_S00_AXI_ADDR_WIDTH),
        .NUM_LANES               (NUM_LANES),
        .ACT_WIDTH               (ACT_WIDTH),
        .WEIGHT_WIDTH            (WEIGHT_WIDTH),
        .ACC_WIDTH               (ACC_WIDTH),
        .SCALE_WIDTH             (SCALE_WIDTH),
        .SCALE_FRAC_BITS         (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH       (RESULT_FIFO_DEPTH),
        .MAX_ROWS                (MAX_ROWS),
        .MAX_COL_BEATS           (MAX_COL_BEATS)
    ) u_axi4_mapping (
        .clk            (s00_axi_aclk),
        .resetn         (s00_axi_aresetn),
        .map_wr_en      (map_wr_en_r),
        .map_wr_addr    (map_wr_addr_r),
        .map_wr_data    (map_wr_data_r),
        .map_wr_strb    (map_wr_strb_r),
        .map_rd_en      (map_rd_en_r),
        .map_rd_addr    (map_rd_addr_r),
        .map_rd_data    (map_rd_data),
        .map_rd_valid   (map_rd_valid),
        .map_rd_error   (map_rd_error)
    );

endmodule
