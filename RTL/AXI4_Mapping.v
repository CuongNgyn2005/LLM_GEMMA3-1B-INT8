/*
 *-----------------------------------------------------------------------------
 * Module      : AXI4_Mapping
 * Description : Board-facing AXI4-Full wrapper for the INT8 VPU.
 *
 * This wrapper keeps the AXI4 signal names used by the course/reference design
 * while reusing the verified VPU_Top AXI4-Full slave.  It also optionally
 * translates a physical AXI address window into the local address map expected
 * by MY_IP/VPU_Top.
 *
 * Default physical map when C_ENABLE_BASE_TRANSLATION = 1:
 *   0x00A0_0000_00 + 0x0000_0000 : CTRL/STATUS/config registers
 *   0x00A0_0000_00 + 0x0001_0000 : activation BRAM window
 *   0x00A0_0000_00 + 0x0010_0000 : weight BRAM window
 *   0x00A0_0000_00 + 0x0020_0000 : result BRAM window
 *
 * If the Vivado AXI interconnect already strips the base address and presents
 * local offsets to the IP, the address is below C_VPU_BASE_ADDR and is passed
 * through unchanged.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module AXI4_Mapping #(
    parameter integer C_S_AXI_ID_WIDTH      = 1,
    parameter integer C_S_AXI_DATA_WIDTH    = 128,
    parameter integer C_S_AXI_ADDR_WIDTH    = 40,
    parameter integer C_S_AXI_AWUSER_WIDTH  = 1,
    parameter integer C_S_AXI_ARUSER_WIDTH  = 1,
    parameter integer C_S_AXI_WUSER_WIDTH   = 1,
    parameter integer C_S_AXI_RUSER_WIDTH   = 1,
    parameter integer C_S_AXI_BUSER_WIDTH   = 1,

    parameter [C_S_AXI_ADDR_WIDTH-1:0] C_VPU_BASE_ADDR = 40'h00A0_0000_00,
    parameter integer C_ENABLE_BASE_TRANSLATION = 1,

    parameter integer NUM_LANES               = 16,
    parameter integer ACT_WIDTH               = 8,
    parameter integer WEIGHT_WIDTH            = 8,
    parameter integer ACC_WIDTH               = 32,
    parameter integer SCALE_WIDTH             = 16,
    parameter integer SCALE_FRAC_BITS         = 15,
    parameter integer RESULT_FIFO_DEPTH       = 8,
    parameter integer MAX_ROWS                = 128,
    parameter integer MAX_COL_BEATS           = 256
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN" *)
    input  wire                                  S_AXI_ACLK,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                                  S_AXI_ARESETN,

    input  wire [C_S_AXI_ID_WIDTH-1:0]           S_AXI_AWID,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_AWADDR,
    input  wire [7:0]                            S_AXI_AWLEN,
    input  wire [2:0]                            S_AXI_AWSIZE,
    input  wire [1:0]                            S_AXI_AWBURST,
    input  wire                                  S_AXI_AWLOCK,
    input  wire [3:0]                            S_AXI_AWCACHE,
    input  wire [2:0]                            S_AXI_AWPROT,
    input  wire [3:0]                            S_AXI_AWQOS,
    input  wire [3:0]                            S_AXI_AWREGION,
    input  wire [C_S_AXI_AWUSER_WIDTH-1:0]       S_AXI_AWUSER,
    input  wire                                  S_AXI_AWVALID,
    output wire                                  S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]     S_AXI_WSTRB,
    input  wire                                  S_AXI_WLAST,
    input  wire [C_S_AXI_WUSER_WIDTH-1:0]        S_AXI_WUSER,
    input  wire                                  S_AXI_WVALID,
    output wire                                  S_AXI_WREADY,

    output wire [C_S_AXI_ID_WIDTH-1:0]           S_AXI_BID,
    output wire [1:0]                            S_AXI_BRESP,
    output wire [C_S_AXI_BUSER_WIDTH-1:0]        S_AXI_BUSER,
    output wire                                  S_AXI_BVALID,
    input  wire                                  S_AXI_BREADY,

    input  wire [C_S_AXI_ID_WIDTH-1:0]           S_AXI_ARID,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]         S_AXI_ARADDR,
    input  wire [7:0]                            S_AXI_ARLEN,
    input  wire [2:0]                            S_AXI_ARSIZE,
    input  wire [1:0]                            S_AXI_ARBURST,
    input  wire                                  S_AXI_ARLOCK,
    input  wire [3:0]                            S_AXI_ARCACHE,
    input  wire [2:0]                            S_AXI_ARPROT,
    input  wire [3:0]                            S_AXI_ARQOS,
    input  wire [3:0]                            S_AXI_ARREGION,
    input  wire [C_S_AXI_ARUSER_WIDTH-1:0]       S_AXI_ARUSER,
    input  wire                                  S_AXI_ARVALID,
    output wire                                  S_AXI_ARREADY,

    output wire [C_S_AXI_ID_WIDTH-1:0]           S_AXI_RID,
    output wire [C_S_AXI_DATA_WIDTH-1:0]         S_AXI_RDATA,
    output wire [1:0]                            S_AXI_RRESP,
    output wire                                  S_AXI_RLAST,
    output wire [C_S_AXI_RUSER_WIDTH-1:0]        S_AXI_RUSER,
    output wire                                  S_AXI_RVALID,
    input  wire                                  S_AXI_RREADY
);

    function [C_S_AXI_ADDR_WIDTH-1:0] to_local_addr;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        begin
            if ((C_ENABLE_BASE_TRANSLATION != 0) && (addr >= C_VPU_BASE_ADDR))
                to_local_addr = addr - C_VPU_BASE_ADDR;
            else
                to_local_addr = addr;
        end
    endfunction

    wire [C_S_AXI_ADDR_WIDTH-1:0] vpu_awaddr;
    wire [C_S_AXI_ADDR_WIDTH-1:0] vpu_araddr;

    assign vpu_awaddr = to_local_addr(S_AXI_AWADDR);
    assign vpu_araddr = to_local_addr(S_AXI_ARADDR);

    VPU_Top #(
        .C_S00_AXI_ID_WIDTH     (C_S_AXI_ID_WIDTH),
        .C_S00_AXI_DATA_WIDTH   (C_S_AXI_DATA_WIDTH),
        .C_S00_AXI_ADDR_WIDTH   (C_S_AXI_ADDR_WIDTH),
        .C_S00_AXI_AWUSER_WIDTH (C_S_AXI_AWUSER_WIDTH),
        .C_S00_AXI_ARUSER_WIDTH (C_S_AXI_ARUSER_WIDTH),
        .C_S00_AXI_WUSER_WIDTH  (C_S_AXI_WUSER_WIDTH),
        .C_S00_AXI_RUSER_WIDTH  (C_S_AXI_RUSER_WIDTH),
        .C_S00_AXI_BUSER_WIDTH  (C_S_AXI_BUSER_WIDTH),
        .NUM_LANES              (NUM_LANES),
        .ACT_WIDTH              (ACT_WIDTH),
        .WEIGHT_WIDTH           (WEIGHT_WIDTH),
        .ACC_WIDTH              (ACC_WIDTH),
        .SCALE_WIDTH            (SCALE_WIDTH),
        .SCALE_FRAC_BITS        (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH      (RESULT_FIFO_DEPTH),
        .MAX_ROWS               (MAX_ROWS),
        .MAX_COL_BEATS          (MAX_COL_BEATS)
    ) u_vpu_top (
        .s00_axi_aclk       (S_AXI_ACLK),
        .s00_axi_aresetn    (S_AXI_ARESETN),

        .s00_axi_awid       (S_AXI_AWID),
        .s00_axi_awaddr     (vpu_awaddr),
        .s00_axi_awlen      (S_AXI_AWLEN),
        .s00_axi_awsize     (S_AXI_AWSIZE),
        .s00_axi_awburst    (S_AXI_AWBURST),
        .s00_axi_awlock     (S_AXI_AWLOCK),
        .s00_axi_awcache    (S_AXI_AWCACHE),
        .s00_axi_awprot     (S_AXI_AWPROT),
        .s00_axi_awqos      (S_AXI_AWQOS),
        .s00_axi_awregion   (S_AXI_AWREGION),
        .s00_axi_awuser     (S_AXI_AWUSER),
        .s00_axi_awvalid    (S_AXI_AWVALID),
        .s00_axi_awready    (S_AXI_AWREADY),

        .s00_axi_wdata      (S_AXI_WDATA),
        .s00_axi_wstrb      (S_AXI_WSTRB),
        .s00_axi_wlast      (S_AXI_WLAST),
        .s00_axi_wuser      (S_AXI_WUSER),
        .s00_axi_wvalid     (S_AXI_WVALID),
        .s00_axi_wready     (S_AXI_WREADY),

        .s00_axi_bid        (S_AXI_BID),
        .s00_axi_bresp      (S_AXI_BRESP),
        .s00_axi_buser      (S_AXI_BUSER),
        .s00_axi_bvalid     (S_AXI_BVALID),
        .s00_axi_bready     (S_AXI_BREADY),

        .s00_axi_arid       (S_AXI_ARID),
        .s00_axi_araddr     (vpu_araddr),
        .s00_axi_arlen      (S_AXI_ARLEN),
        .s00_axi_arsize     (S_AXI_ARSIZE),
        .s00_axi_arburst    (S_AXI_ARBURST),
        .s00_axi_arlock     (S_AXI_ARLOCK),
        .s00_axi_arcache    (S_AXI_ARCACHE),
        .s00_axi_arprot     (S_AXI_ARPROT),
        .s00_axi_arqos      (S_AXI_ARQOS),
        .s00_axi_arregion   (S_AXI_ARREGION),
        .s00_axi_aruser     (S_AXI_ARUSER),
        .s00_axi_arvalid    (S_AXI_ARVALID),
        .s00_axi_arready    (S_AXI_ARREADY),

        .s00_axi_rid        (S_AXI_RID),
        .s00_axi_rdata      (S_AXI_RDATA),
        .s00_axi_rresp      (S_AXI_RRESP),
        .s00_axi_rlast      (S_AXI_RLAST),
        .s00_axi_ruser      (S_AXI_RUSER),
        .s00_axi_rvalid     (S_AXI_RVALID),
        .s00_axi_rready     (S_AXI_RREADY)
    );

endmodule
