/*
 *-----------------------------------------------------------------------------
 * Module      : SPU_Top
 * Description : Top-level Scalar Processing Unit wrapper.
 *
 * SPU_Top is integrated below AXI4_Mapping, next to the existing VPU/GEMV
 * core.  It exposes a small command interface, local memory windows, status,
 * and capability bits.  The first SPU integration phase wires the command
 * boundaries for quantization, Q8 scale accumulation, SiLU/Mul, RMSNorm, RoPE,
 * Softmax, and copy self-test.  Quantization and scale accumulation perform
 * local-memory data movement; the other scalar functions remain reserved until
 * validated streaming datapaths replace their marker bodies.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module SPU_Top #(
    parameter integer AXI_DATA_WIDTH = 128,
    parameter integer WORD_DEPTH     = 4096,
    parameter integer SCALE_ACCUM_ROWS = 256
) (
    input  wire                              clk,
    input  wire                              resetn,

    input  wire                              spu_start,
    input  wire                              spu_clear_done,
    input  wire                              spu_soft_reset,
    input  wire [7:0]                        spu_mode,
    input  wire [31:0]                       spu_len,
    input  wire [31:0]                       spu_aux0,
    input  wire [31:0]                       spu_aux1,

    output wire                              spu_busy,
    output wire                              spu_done,
    output wire                              spu_error,
    output wire [7:0]                        spu_error_code,
    output wire [31:0]                       spu_caps,

    input  wire                              mm_wr_en,
    input  wire [1:0]                        mm_wr_region,
    input  wire [31:0]                       mm_wr_index,
    input  wire [AXI_DATA_WIDTH-1:0]         mm_wr_data,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     mm_wr_strb,

    input  wire                              mm_rd_en,
    input  wire [1:0]                        mm_rd_region,
    input  wire [31:0]                       mm_rd_index,
    output wire [AXI_DATA_WIDTH-1:0]         mm_rd_data,
    output wire                              mm_rd_valid,
    output wire                              mm_rd_error
);

    wire                              core_mem_en;
    wire                              core_mem_we;
    wire [1:0]                        core_mem_region;
    wire [31:0]                       core_mem_index;
    wire [AXI_DATA_WIDTH-1:0]         core_mem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]     core_mem_wstrb;
    wire [AXI_DATA_WIDTH-1:0]         core_mem_rdata;
    localparam [31:0] WORD_DEPTH_32 = WORD_DEPTH;
    localparam [15:0] WORD_DEPTH_16 = WORD_DEPTH_32[15:0];
    localparam [7:0] SPU_MODE_SILU_MUL = 8'd2;
    localparam [7:0] SPU_MODE_RMSNORM  = 8'd3;
    localparam [7:0] SPU_MODE_ROPE     = 8'd4;
    localparam [7:0] SPU_MODE_SOFTMAX  = 8'd5;

    wire silu_busy;
    wire silu_done;
    wire silu_supported;
    wire rmsnorm_busy;
    wire rmsnorm_done;
    wire rmsnorm_supported;
    wire rope_busy;
    wire rope_done;
    wire rope_supported;
    wire softmax_busy;
    wire softmax_done;
    wire softmax_supported;

    // Capability map:
    // bit 0  : SPU framework present
    // bit 1  : fixed-point quantize-to-INT8 payload supported
    // bit 2  : SPU_SiLU_Mul numerical datapath supported
    // bit 3  : SPU_RMSNorm numerical datapath supported
    // bit 4  : SPU_RoPE numerical datapath supported
    // bit 5  : SPU_Softmax numerical datapath supported
    // bit 6  : Q8 raw-block scale accumulation supported
    // bit 7  : COPY self-test command supported
    // bits 31:16 expose implemented words per SPU memory window.
    assign spu_caps = {WORD_DEPTH_16, 8'd0, 1'b1, 1'b1,
                       softmax_supported, rope_supported, rmsnorm_supported,
                       silu_supported, 1'b1, 1'b1};

    SPU_SiLU_Mul u_spu_silu_mul (
        .clk       (clk),
        .resetn    (resetn),
        .start     (spu_start && (spu_mode == SPU_MODE_SILU_MUL)),
        .busy      (silu_busy),
        .done      (silu_done),
        .supported (silu_supported)
    );

    SPU_RMSNorm u_spu_rmsnorm (
        .clk       (clk),
        .resetn    (resetn),
        .start     (spu_start && (spu_mode == SPU_MODE_RMSNORM)),
        .busy      (rmsnorm_busy),
        .done      (rmsnorm_done),
        .supported (rmsnorm_supported)
    );

    SPU_RoPE u_spu_rope (
        .clk       (clk),
        .resetn    (resetn),
        .start     (spu_start && (spu_mode == SPU_MODE_ROPE)),
        .busy      (rope_busy),
        .done      (rope_done),
        .supported (rope_supported)
    );

    SPU_Softmax u_spu_softmax (
        .clk       (clk),
        .resetn    (resetn),
        .start     (spu_start && (spu_mode == SPU_MODE_SOFTMAX)),
        .busy      (softmax_busy),
        .done      (softmax_done),
        .supported (softmax_supported)
    );

    SPU_Controller #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH),
        .SCALE_ACCUM_ROWS (SCALE_ACCUM_ROWS)
    ) u_spu_controller (
        .clk          (clk),
        .resetn       (resetn),
        .start        (spu_start),
        .clear_done   (spu_clear_done),
        .soft_reset   (spu_soft_reset),
        .mode         (spu_mode),
        .len          (spu_len),
        .aux0         (spu_aux0),
        .aux1         (spu_aux1),
        .busy         (spu_busy),
        .done         (spu_done),
        .error        (spu_error),
        .error_code   (spu_error_code),
        .mem_en       (core_mem_en),
        .mem_we       (core_mem_we),
        .mem_region   (core_mem_region),
        .mem_index    (core_mem_index),
        .mem_wdata    (core_mem_wdata),
        .mem_wstrb    (core_mem_wstrb),
        .mem_rdata    (core_mem_rdata)
    );

    SPU_Local_Memory #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .WORD_DEPTH     (WORD_DEPTH)
    ) u_spu_local_memory (
        .clk            (clk),
        .resetn         (resetn),
        .mm_wr_en       (mm_wr_en),
        .mm_wr_region   (mm_wr_region),
        .mm_wr_index    (mm_wr_index),
        .mm_wr_data     (mm_wr_data),
        .mm_wr_strb     (mm_wr_strb),
        .mm_rd_en       (mm_rd_en),
        .mm_rd_region   (mm_rd_region),
        .mm_rd_index    (mm_rd_index),
        .mm_rd_data     (mm_rd_data),
        .mm_rd_valid    (mm_rd_valid),
        .mm_rd_error    (mm_rd_error),
        .core_en        (core_mem_en),
        .core_we        (core_mem_we),
        .core_region    (core_mem_region),
        .core_index     (core_mem_index),
        .core_wdata     (core_mem_wdata),
        .core_wstrb     (core_mem_wstrb),
        .core_rdata     (core_mem_rdata)
    );

endmodule
