/*
 *-----------------------------------------------------------------------------
 * Module      : AI_IP_top
 * Description : AXI4-Full top-level wrapper for the programmable-logic AI IP.
 *
 * AI_IP_top is the integration boundary that Vivado Block Design sees as the
 * custom accelerator IP. It exposes the existing AXI4-Full slave plus the
 * independent attention DDR master (128-bit data, 40-bit address), the shared
 * clock/reset, slave-side AXI metadata, and datapath sizing parameters. Both
 * interfaces are forwarded into MY_IP without extra wrapper behavior.
 *
 * This module intentionally contains no register map, BRAM instance, compute
 * FSM, or arithmetic datapath. Existing slave semantics remain unchanged while
 * the new master exposes attention DDR transactions. AXI handling, address
 * decoding, local memory storage, GEMV scheduling, and PMAU arithmetic remain
 * implemented in the lower modules.
 *
 * Parameter groups:
 * - C_S00_AXI_* define the external AXI ID, address, data, and USER widths.
 * - NUM_LANES and data-width parameters define the INT8 MAC datapath shape.
 * - MAX_ROWS, MAX_COL_BEATS, and MAX_GROUP_Q8_BLOCKS define the maximum local
 *   tile capacity passed down to the GEMV implementation.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module AI_IP_top #(
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
    parameter integer MAX_ROWS               = 256,
    parameter integer MAX_COL_BEATS          = 128,
    parameter integer MAX_GROUP_Q8_BLOCKS    = 64,
    parameter integer SPU_STREAM_TEST_STALL_ENABLE = 0
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s00_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s00_axi:m_att_axi, ASSOCIATED_RESET s00_axi_aresetn" *)
    input  wire                                  s00_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s00_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
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
    input  wire                                  s00_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWID" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_att_axi, PROTOCOL AXI4, DATA_WIDTH 128, ADDR_WIDTH 40, ID_WIDTH 1, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *)
    output wire [0:0] m_att_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWADDR" *)
    output wire [39:0] m_att_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWLEN" *)
    output wire [7:0] m_att_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWSIZE" *)
    output wire [2:0] m_att_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWBURST" *)
    output wire [1:0] m_att_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWLOCK" *)
    output wire m_att_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWCACHE" *)
    output wire [3:0] m_att_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWPROT" *)
    output wire [2:0] m_att_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWQOS" *)
    output wire [3:0] m_att_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWREGION" *)
    output wire [3:0] m_att_axi_awregion,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWVALID" *)
    output wire m_att_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi AWREADY" *)
    input wire m_att_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi WDATA" *)
    output wire [127:0] m_att_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi WSTRB" *)
    output wire [15:0] m_att_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi WLAST" *)
    output wire m_att_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi WVALID" *)
    output wire m_att_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi WREADY" *)
    input wire m_att_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi BID" *)
    input wire [0:0] m_att_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi BRESP" *)
    input wire [1:0] m_att_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi BVALID" *)
    input wire m_att_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi BREADY" *)
    output wire m_att_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARID" *)
    output wire [0:0] m_att_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARADDR" *)
    output wire [39:0] m_att_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARLEN" *)
    output wire [7:0] m_att_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARSIZE" *)
    output wire [2:0] m_att_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARBURST" *)
    output wire [1:0] m_att_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARLOCK" *)
    output wire m_att_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARCACHE" *)
    output wire [3:0] m_att_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARPROT" *)
    output wire [2:0] m_att_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARQOS" *)
    output wire [3:0] m_att_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARREGION" *)
    output wire [3:0] m_att_axi_arregion,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARVALID" *)
    output wire m_att_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi ARREADY" *)
    input wire m_att_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi RID" *)
    input wire [0:0] m_att_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi RDATA" *)
    input wire [127:0] m_att_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi RRESP" *)
    input wire [1:0] m_att_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi RLAST" *)
    input wire m_att_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi RVALID" *)
    input wire m_att_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_att_axi RREADY" *)
    output wire m_att_axi_rready
);

    // Both independent AXI interfaces and the system parameters pass through.
    // Slave protocol handling remains in MY_IP; the attention master lives in
    // Attention_AXI_Master below AXI4_Mapping/Attention_Engine.
    MY_IP #(
        .C_S00_AXI_ID_WIDTH     (C_S00_AXI_ID_WIDTH),
        .C_S00_AXI_DATA_WIDTH   (C_S00_AXI_DATA_WIDTH),
        .C_S00_AXI_ADDR_WIDTH   (C_S00_AXI_ADDR_WIDTH),
        .C_S00_AXI_AWUSER_WIDTH (C_S00_AXI_AWUSER_WIDTH),
        .C_S00_AXI_ARUSER_WIDTH (C_S00_AXI_ARUSER_WIDTH),
        .C_S00_AXI_WUSER_WIDTH  (C_S00_AXI_WUSER_WIDTH),
        .C_S00_AXI_RUSER_WIDTH  (C_S00_AXI_RUSER_WIDTH),
        .C_S00_AXI_BUSER_WIDTH  (C_S00_AXI_BUSER_WIDTH),
        .NUM_LANES              (NUM_LANES),
        .ACT_WIDTH              (ACT_WIDTH),
        .WEIGHT_WIDTH           (WEIGHT_WIDTH),
        .ACC_WIDTH              (ACC_WIDTH),
        .SCALE_WIDTH            (SCALE_WIDTH),
        .SCALE_FRAC_BITS        (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH      (RESULT_FIFO_DEPTH),
        .MAX_ROWS               (MAX_ROWS),
        .MAX_COL_BEATS          (MAX_COL_BEATS),
        .MAX_GROUP_Q8_BLOCKS    (MAX_GROUP_Q8_BLOCKS),
        .SPU_STREAM_TEST_STALL_ENABLE (SPU_STREAM_TEST_STALL_ENABLE)
    ) u_my_ip (
        .s00_axi_aclk       (s00_axi_aclk),
        .s00_axi_aresetn    (s00_axi_aresetn),
        .s00_axi_awid       (s00_axi_awid),
        .s00_axi_awaddr     (s00_axi_awaddr),
        .s00_axi_awlen      (s00_axi_awlen),
        .s00_axi_awsize     (s00_axi_awsize),
        .s00_axi_awburst    (s00_axi_awburst),
        .s00_axi_awlock     (s00_axi_awlock),
        .s00_axi_awcache    (s00_axi_awcache),
        .s00_axi_awprot     (s00_axi_awprot),
        .s00_axi_awqos      (s00_axi_awqos),
        .s00_axi_awregion   (s00_axi_awregion),
        .s00_axi_awuser     (s00_axi_awuser),
        .s00_axi_awvalid    (s00_axi_awvalid),
        .s00_axi_awready    (s00_axi_awready),
        .s00_axi_wdata      (s00_axi_wdata),
        .s00_axi_wstrb      (s00_axi_wstrb),
        .s00_axi_wlast      (s00_axi_wlast),
        .s00_axi_wuser      (s00_axi_wuser),
        .s00_axi_wvalid     (s00_axi_wvalid),
        .s00_axi_wready     (s00_axi_wready),
        .s00_axi_bid        (s00_axi_bid),
        .s00_axi_bresp      (s00_axi_bresp),
        .s00_axi_buser      (s00_axi_buser),
        .s00_axi_bvalid     (s00_axi_bvalid),
        .s00_axi_bready     (s00_axi_bready),
        .s00_axi_arid       (s00_axi_arid),
        .s00_axi_araddr     (s00_axi_araddr),
        .s00_axi_arlen      (s00_axi_arlen),
        .s00_axi_arsize     (s00_axi_arsize),
        .s00_axi_arburst    (s00_axi_arburst),
        .s00_axi_arlock     (s00_axi_arlock),
        .s00_axi_arcache    (s00_axi_arcache),
        .s00_axi_arprot     (s00_axi_arprot),
        .s00_axi_arqos      (s00_axi_arqos),
        .s00_axi_arregion   (s00_axi_arregion),
        .s00_axi_aruser     (s00_axi_aruser),
        .s00_axi_arvalid    (s00_axi_arvalid),
        .s00_axi_arready    (s00_axi_arready),
        .s00_axi_rid        (s00_axi_rid),
        .s00_axi_rdata      (s00_axi_rdata),
        .s00_axi_rresp      (s00_axi_rresp),
        .s00_axi_rlast      (s00_axi_rlast),
        .s00_axi_ruser      (s00_axi_ruser),
        .s00_axi_rvalid     (s00_axi_rvalid),
        .s00_axi_rready     (s00_axi_rready),
        .m_att_axi_awid(m_att_axi_awid),
        .m_att_axi_awaddr(m_att_axi_awaddr),
        .m_att_axi_awlen(m_att_axi_awlen),
        .m_att_axi_awsize(m_att_axi_awsize),
        .m_att_axi_awburst(m_att_axi_awburst),
        .m_att_axi_awlock(m_att_axi_awlock),
        .m_att_axi_awcache(m_att_axi_awcache),
        .m_att_axi_awprot(m_att_axi_awprot),
        .m_att_axi_awqos(m_att_axi_awqos),
        .m_att_axi_awregion(m_att_axi_awregion),
        .m_att_axi_awvalid(m_att_axi_awvalid),
        .m_att_axi_awready(m_att_axi_awready),
        .m_att_axi_wdata(m_att_axi_wdata),
        .m_att_axi_wstrb(m_att_axi_wstrb),
        .m_att_axi_wlast(m_att_axi_wlast),
        .m_att_axi_wvalid(m_att_axi_wvalid),
        .m_att_axi_wready(m_att_axi_wready),
        .m_att_axi_bid(m_att_axi_bid),
        .m_att_axi_bresp(m_att_axi_bresp),
        .m_att_axi_bvalid(m_att_axi_bvalid),
        .m_att_axi_bready(m_att_axi_bready),
        .m_att_axi_arid(m_att_axi_arid),
        .m_att_axi_araddr(m_att_axi_araddr),
        .m_att_axi_arlen(m_att_axi_arlen),
        .m_att_axi_arsize(m_att_axi_arsize),
        .m_att_axi_arburst(m_att_axi_arburst),
        .m_att_axi_arlock(m_att_axi_arlock),
        .m_att_axi_arcache(m_att_axi_arcache),
        .m_att_axi_arprot(m_att_axi_arprot),
        .m_att_axi_arqos(m_att_axi_arqos),
        .m_att_axi_arregion(m_att_axi_arregion),
        .m_att_axi_arvalid(m_att_axi_arvalid),
        .m_att_axi_arready(m_att_axi_arready),
        .m_att_axi_rid(m_att_axi_rid),
        .m_att_axi_rdata(m_att_axi_rdata),
        .m_att_axi_rresp(m_att_axi_rresp),
        .m_att_axi_rlast(m_att_axi_rlast),
        .m_att_axi_rvalid(m_att_axi_rvalid),
        .m_att_axi_rready(m_att_axi_rready)
    );

endmodule
