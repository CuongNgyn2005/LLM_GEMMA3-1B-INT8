/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Local_Memory
 * Description : Four dual-port on-chip RAM windows for the Scalar Processing
 *               Unit.
 *
 * The previous implementation selected one of four Verilog arrays through a
 * task/function.  That dynamic array selection prevents Vivado from inferring
 * RAM and expands every 128-bit word into registers and muxes.  This version
 * instantiates one Dual_Port_BRAM per window, so each window has a static RAM
 * implementation with a synchronous MMIO port and a synchronous SPU port.
 *
 * Port A: AXI4_Mapping/MMIO (CPU or DMA visible).
 * Port B: SPU_Controller (on-chip operator dataflow).
 *
 * All four windows use BRAM in this bring-up revision.  The VPU continues to
 * use URAM for its streaming weight tile.  A future scratch-URAM revision must
 * adopt a simple-dual-port ownership protocol before changing USE_URAM, because
 * the current SPU contract permits either port to read or byte-write a window.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Local_Memory #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH     = 4096
) (
    input  wire                              clk,
    input  wire                              resetn,

    input  wire                              mm_wr_en,
    input  wire [1:0]                        mm_wr_region,
    input  wire [31:0]                       mm_wr_index,
    input  wire [AXI_DATA_WIDTH-1:0]         mm_wr_data,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     mm_wr_strb,

    input  wire                              mm_rd_en,
    input  wire [1:0]                        mm_rd_region,
    input  wire [31:0]                       mm_rd_index,
    output wire [AXI_DATA_WIDTH-1:0]         mm_rd_data,
    output reg                               mm_rd_valid,
    output reg                               mm_rd_error,

    input  wire                              core_en,
    input  wire                              core_we,
    input  wire [1:0]                        core_region,
    input  wire [31:0]                       core_index,
    input  wire [AXI_DATA_WIDTH-1:0]         core_wdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     core_wstrb,
    output wire [AXI_DATA_WIDTH-1:0]         core_rdata
);

    localparam [1:0] REGION_IN      = 2'd0;
    localparam [1:0] REGION_OUT     = 2'd1;
    localparam [1:0] REGION_PARAM   = 2'd2;
    localparam [1:0] REGION_SCRATCH = 2'd3;
    localparam integer ADDR_WIDTH = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH);

    wire mm_wr_index_ok = (mm_wr_index < WORD_DEPTH);
    wire mm_rd_index_ok = (mm_rd_index < WORD_DEPTH);
    wire core_index_ok  = (core_index < WORD_DEPTH);

    wire [ADDR_WIDTH-1:0] mm_wr_addr = mm_wr_index[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] mm_rd_addr = mm_rd_index[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] core_addr  = core_index[ADDR_WIDTH-1:0];

    wire mm_in_en      = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_IN);
    wire mm_out_en     = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_OUT);
    wire mm_param_en   = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_PARAM);
    wire mm_scratch_en = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_SCRATCH);

    wire core_in_en      = core_en && core_index_ok && (core_region == REGION_IN);
    wire core_out_en     = core_en && core_index_ok && (core_region == REGION_OUT);
    wire core_param_en   = core_en && core_index_ok && (core_region == REGION_PARAM);
    wire core_scratch_en = core_en && core_index_ok && (core_region == REGION_SCRATCH);

    wire [AXI_DATA_WIDTH-1:0] in_mm_rdata;
    wire [AXI_DATA_WIDTH-1:0] out_mm_rdata;
    wire [AXI_DATA_WIDTH-1:0] param_mm_rdata;
    wire [AXI_DATA_WIDTH-1:0] scratch_mm_rdata;
    wire [AXI_DATA_WIDTH-1:0] in_core_rdata;
    wire [AXI_DATA_WIDTH-1:0] out_core_rdata;
    wire [AXI_DATA_WIDTH-1:0] param_core_rdata;
    wire [AXI_DATA_WIDTH-1:0] scratch_core_rdata;

    // Dual_Port_BRAM registers each read.  These multiplexers intentionally
    // consume that registered RAM output directly; adding another register here
    // would shift the controller and AXI read protocol by an extra cycle.
    assign mm_rd_data =
        (mm_rd_region == REGION_IN)      ? in_mm_rdata :
        (mm_rd_region == REGION_OUT)     ? out_mm_rdata :
        (mm_rd_region == REGION_PARAM)   ? param_mm_rdata :
        (mm_rd_region == REGION_SCRATCH) ? scratch_mm_rdata :
                                          {AXI_DATA_WIDTH{1'b0}};

    assign core_rdata =
        (core_region == REGION_IN)      ? in_core_rdata :
        (core_region == REGION_OUT)     ? out_core_rdata :
        (core_region == REGION_PARAM)   ? param_core_rdata :
        (core_region == REGION_SCRATCH) ? scratch_core_rdata :
                                         {AXI_DATA_WIDTH{1'b0}};

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_in_ram (
        .clka  (clk), .ena (mm_in_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_IN))),
        .wea   (mm_in_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addra (mm_in_en ? mm_wr_addr : mm_rd_addr), .dina (mm_wr_data), .douta (in_mm_rdata),
        .clkb  (clk), .enb (core_in_en), .web (core_in_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (in_core_rdata)
    );

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_out_ram (
        .clka  (clk), .ena (mm_out_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_OUT))),
        .wea   (mm_out_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addra (mm_out_en ? mm_wr_addr : mm_rd_addr), .dina (mm_wr_data), .douta (out_mm_rdata),
        .clkb  (clk), .enb (core_out_en), .web (core_out_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (out_core_rdata)
    );

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_param_ram (
        .clka  (clk), .ena (mm_param_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_PARAM))),
        .wea   (mm_param_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addra (mm_param_en ? mm_wr_addr : mm_rd_addr), .dina (mm_wr_data), .douta (param_mm_rdata),
        .clkb  (clk), .enb (core_param_en), .web (core_param_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (param_core_rdata)
    );

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_scratch_ram (
        .clka  (clk), .ena (mm_scratch_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_SCRATCH))),
        .wea   (mm_scratch_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addra (mm_scratch_en ? mm_wr_addr : mm_rd_addr), .dina (mm_wr_data), .douta (scratch_mm_rdata),
        .clkb  (clk), .enb (core_scratch_en), .web (core_scratch_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (scratch_core_rdata)
    );

    always @(posedge clk) begin
        if (!resetn) begin
            mm_rd_valid <= 1'b0;
            mm_rd_error <= 1'b0;
        end else begin
            mm_rd_valid <= mm_rd_en;
            mm_rd_error <= mm_rd_en && !mm_rd_index_ok;

        end
    end

endmodule
