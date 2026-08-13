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
,
    // P2-v2 claims the MMIO-side port only while the paired stream performs
    // its second scale read or second SPU_OUT write.  Host software must wait
    // for stream quiescence before reuse; this arbitration also prevents an
    // unsafe host access from colliding with the live paired lane.
    input  wire                              core2_en,
    input  wire                              core2_we,
    input  wire [1:0]                        core2_region,
    input  wire [31:0]                       core2_index,
    input  wire [AXI_DATA_WIDTH-1:0]         core2_wdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     core2_wstrb,
    output wire [AXI_DATA_WIDTH-1:0]         core2_rdata,

    // P3 split-scale path.  The existing core port reads the primary
    // immutable scale from PARAM while this independent scratch-port read
    // fetches the dynamic activation scale.  This is deliberately restricted
    // to SCRATCH so it cannot steal a PARAM/OUT port from the retained P2
    // companion lane.
    input  wire                              core3_scratch_en,
    input  wire [31:0]                       core3_scratch_index,
    output wire [AXI_DATA_WIDTH-1:0]         core3_scratch_rdata,

    // A split-scale stream owns one half (bank) of both PARAM and SCRATCH
    // until its final result has retired.  MMIO writes into that bank are
    // rejected, not arbitrated against a live scale read.
    input  wire                              stream_p3_bank_lock_valid,
    input  wire                              stream_p3_bank_lock,
    output wire                              mm_wr_rejected
);

    localparam [1:0] REGION_IN      = 2'd0;
    localparam [1:0] REGION_OUT     = 2'd1;
    localparam [1:0] REGION_PARAM   = 2'd2;
    localparam [1:0] REGION_SCRATCH = 2'd3;
    localparam integer ADDR_WIDTH = (WORD_DEPTH <= 1) ? 1 : $clog2(WORD_DEPTH);
    localparam integer BANK_WORD_DEPTH = WORD_DEPTH / 2;

    reg [1:0] core_region_r;
    reg [1:0] core2_region_r;

    wire mm_wr_index_ok = (mm_wr_index < WORD_DEPTH);
    wire mm_rd_index_ok = (mm_rd_index < WORD_DEPTH);
    wire core_index_ok  = (core_index < WORD_DEPTH);

    wire [ADDR_WIDTH-1:0] mm_wr_addr = mm_wr_index[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] mm_rd_addr = mm_rd_index[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] core_addr  = core_index[ADDR_WIDTH-1:0];

    wire core_in_en      = core_en && core_index_ok && (core_region == REGION_IN);
    wire core_out_en     = core_en && core_index_ok && (core_region == REGION_OUT);
    wire core_param_en   = core_en && core_index_ok && (core_region == REGION_PARAM);
    wire core_scratch_en = core_en && core_index_ok && (core_region == REGION_SCRATCH);
    wire core2_index_ok = (core2_index < WORD_DEPTH);
    wire core2_in_en      = core2_en && core2_index_ok && (core2_region == REGION_IN);
    wire core2_out_en     = core2_en && core2_index_ok && (core2_region == REGION_OUT);
    wire core2_param_en   = core2_en && core2_index_ok && (core2_region == REGION_PARAM);
    wire core2_scratch_en = core2_en && core2_index_ok && (core2_region == REGION_SCRATCH);
    wire [ADDR_WIDTH-1:0] core2_addr = core2_index[ADDR_WIDTH-1:0];
    wire core3_scratch_index_ok = (core3_scratch_index < WORD_DEPTH);
    wire [ADDR_WIDTH-1:0] core3_scratch_addr = core3_scratch_index[ADDR_WIDTH-1:0];

    // Port A is shared by MMIO and the retained paired-stream lane.  A
    // selected owner supplies enable, write-enable, address and data as one
    // indivisible bundle.  In particular, an MMIO write must never borrow a
    // core2 read address with MMIO write strobes/data.  The policy is safe
    // serialization: reject and count a colliding MMIO write; do not pretend
    // inactive-bank PARAM staging overlaps the two live P3 PARAM reads.
    wire mm_wr_bank = (mm_wr_index >= BANK_WORD_DEPTH);
    wire mm_wr_active_bank_conflict = mm_wr_en && mm_wr_index_ok &&
        ((mm_wr_region == REGION_PARAM) || (mm_wr_region == REGION_SCRATCH)) &&
        stream_p3_bank_lock_valid && (mm_wr_bank == stream_p3_bank_lock);
    wire mm_wr_port_a_conflict = mm_wr_en && mm_wr_index_ok &&
        (((mm_wr_region == REGION_IN)      && core2_in_en) ||
         ((mm_wr_region == REGION_OUT)     && core2_out_en) ||
         ((mm_wr_region == REGION_PARAM)   && core2_param_en) ||
         ((mm_wr_region == REGION_SCRATCH) && core2_scratch_en));
    assign mm_wr_rejected = mm_wr_active_bank_conflict || mm_wr_port_a_conflict;
    wire mm_in_en      = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_IN) && !mm_wr_rejected;
    wire mm_out_en     = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_OUT) && !mm_wr_rejected;
    wire mm_param_en   = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_PARAM) && !mm_wr_rejected;
    wire mm_scratch_en = mm_wr_en && mm_wr_index_ok && (mm_wr_region == REGION_SCRATCH) && !mm_wr_rejected;

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
        (core_region_r == REGION_IN)      ? in_core_rdata :
        (core_region_r == REGION_OUT)     ? out_core_rdata :
        (core_region_r == REGION_PARAM)   ? param_core_rdata :
        (core_region_r == REGION_SCRATCH) ? scratch_core_rdata :
                                         {AXI_DATA_WIDTH{1'b0}};
    assign core2_rdata =
        (core2_region_r == REGION_IN)      ? in_mm_rdata :
        (core2_region_r == REGION_OUT)     ? out_mm_rdata :
        (core2_region_r == REGION_PARAM)   ? param_mm_rdata :
        (core2_region_r == REGION_SCRATCH) ? scratch_mm_rdata :
                                          {AXI_DATA_WIDTH{1'b0}};
    assign core3_scratch_rdata = scratch_core_rdata;

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_in_ram (
        .clka  (clk), .ena (core2_in_en || mm_in_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_IN))),
        .wea   (core2_in_en ? (core2_we ? core2_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}) : (mm_in_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}})),
        .addra (core2_in_en ? core2_addr : (mm_in_en ? mm_wr_addr : mm_rd_addr)), .dina (core2_in_en ? core2_wdata : mm_wr_data), .douta (in_mm_rdata),
        .clkb  (clk), .enb (core_in_en), .web (core_in_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (in_core_rdata)
    );

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_out_ram (
        .clka  (clk), .ena (core2_out_en || mm_out_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_OUT))),
        .wea   (core2_out_en ? (core2_we ? core2_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}) : (mm_out_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}})),
        .addra (core2_out_en ? core2_addr : (mm_out_en ? mm_wr_addr : mm_rd_addr)), .dina (core2_out_en ? core2_wdata : mm_wr_data), .douta (out_mm_rdata),
        .clkb  (clk), .enb (core_out_en), .web (core_out_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (out_core_rdata)
    );

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_param_ram (
        .clka  (clk), .ena (core2_param_en || mm_param_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_PARAM))),
        .wea   (core2_param_en ? (core2_we ? core2_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}) : (mm_param_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}})),
        .addra (core2_param_en ? core2_addr : (mm_param_en ? mm_wr_addr : mm_rd_addr)), .dina (core2_param_en ? core2_wdata : mm_wr_data), .douta (param_mm_rdata),
        .clkb  (clk), .enb (core_param_en), .web (core_param_en && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb (core_addr), .dinb (core_wdata), .doutb (param_core_rdata)
    );

    Dual_Port_BRAM #(
        .AWIDTH     (ADDR_WIDTH),
        .DWIDTH     (AXI_DATA_WIDTH),
        .OUTPUT_REG (0),
        .USE_URAM   (0)
    ) u_spu_scratch_ram (
        .clka  (clk), .ena (core2_scratch_en || mm_scratch_en || (mm_rd_en && mm_rd_index_ok && (mm_rd_region == REGION_SCRATCH))),
        .wea   (core2_scratch_en ? (core2_we ? core2_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}) : (mm_scratch_en ? mm_wr_strb : {(AXI_DATA_WIDTH/8){1'b0}})),
        .addra (core2_scratch_en ? core2_addr : (mm_scratch_en ? mm_wr_addr : mm_rd_addr)), .dina (core2_scratch_en ? core2_wdata : mm_wr_data), .douta (scratch_mm_rdata),
        .clkb  (clk), .enb ((core3_scratch_en && core3_scratch_index_ok) || core_scratch_en),
        .web (core_scratch_en && !(core3_scratch_en && core3_scratch_index_ok) && core_we ? core_wstrb : {(AXI_DATA_WIDTH/8){1'b0}}),
        .addrb ((core3_scratch_en && core3_scratch_index_ok) ? core3_scratch_addr : core_addr),
        .dinb (core_wdata), .doutb (scratch_core_rdata)
    );

    always @(posedge clk) begin
        if (!resetn) begin
            mm_rd_valid <= 1'b0;
            mm_rd_error <= 1'b0;
            core_region_r <= REGION_PARAM;
            core2_region_r <= 2'b00;
        end else begin
            mm_rd_valid <= mm_rd_en;
            mm_rd_error <= mm_rd_en && !mm_rd_index_ok;
            if (core_en)
                core_region_r <= core_region;
            if (core2_en)
                core2_region_r <= core2_region;

        end
    end

endmodule
