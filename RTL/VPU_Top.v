/*
 *-----------------------------------------------------------------------------
 * Module      : VPU_Top
 * Description : Project-facing AXI4-Full wrapper for the INT8 VPU.
 *
 * VPU_Top is intentionally a thin alias around MY_IP so the Vivado block design
 * can keep using the familiar VPU top name while the implementation underneath
 * is a memory-mapped AXI4-Full slave.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module VPU_Top #(
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
    parameter integer MAX_COL_BEATS          = 32
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
        .MAX_COL_BEATS          (MAX_COL_BEATS)
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
        .s00_axi_rready     (s00_axi_rready)
    );

endmodule
