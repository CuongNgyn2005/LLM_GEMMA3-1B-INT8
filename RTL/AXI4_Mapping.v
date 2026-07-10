/*
 *-----------------------------------------------------------------------------
 * Module      : AXI4_Mapping
 * Description : Local register map, memory-window decoder, and GEMV connector.
 *
 * AXI4_Mapping is the boundary between the AXI protocol adapter and the compute
 * core.  MY_IP has already serialized AXI traffic into map_wr_* and map_rd_*
 * requests; this module interprets the local address, applies optional
 * VPU_BASE_ADDR translation, classifies the access, and drives the correct
 * internal control or memory path.
 *
 * Address responsibilities:
 * - register space below 0x0001_0000 stores ROWS, COLS, COL_BEATS, SCALE, and
 *   MODE; exposes STATUS, LIMITS, PROGRESS, and CAPABILITY registers; and
 *   generates one-cycle ctrl_start/ctrl_clear_done pulses;
 * - ACT_BASE_ADDR..ACT_END_ADDR writes activation beats into the GEMV local
 *   Activation BRAM;
 * - WEIGHT_BASE_ADDR..WEIGHT_END_ADDR writes flattened row-major weight beats
 *   into the GEMV Weight BRAM banks;
 * - RESULT_BASE_ADDR..RESULT_END_ADDR reads 128-bit result words from GEMV;
 * - SPU_IN/OUT/PARAM/SCRATCH windows expose the Scalar Processing Unit local
 *   memory used by helper operators around GEMV.
 *
 * This module also checks implemented BRAM depths before forwarding memory
 * writes or accepting Result-window reads.  PMAU is not visible at this level;
 * configuration and tensor data reach PMAU only after GEMV reads local BRAM
 * and schedules valid/ready beats.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module AXI4_Mapping #(
    parameter integer AXI_DATA_WIDTH           = 128,
    parameter integer AXI_ADDR_WIDTH           = 40,
    parameter [AXI_ADDR_WIDTH-1:0] VPU_BASE_ADDR = 40'h00A0_0000_00,
    parameter integer ENABLE_BASE_TRANSLATION  = 1,

    parameter integer NUM_LANES                = 16,
    parameter integer ACT_WIDTH                = 8,
    parameter integer WEIGHT_WIDTH             = 8,
    parameter integer ACC_WIDTH                = 32,
    parameter integer SCALE_WIDTH              = 16,
    parameter integer SCALE_FRAC_BITS          = 15,
    parameter integer RESULT_FIFO_DEPTH        = 8,
    parameter integer MAX_ROWS                 = 256,
    parameter integer MAX_COL_BEATS            = 128,
    parameter integer MAX_GROUP_Q8_BLOCKS      = 64,
    parameter integer SPU_WORD_DEPTH           = 4096
) (
    input  wire                                  clk,
    input  wire                                  resetn,

    input  wire                                  map_wr_en,
    input  wire [AXI_ADDR_WIDTH-1:0]             map_wr_addr,
    input  wire [AXI_DATA_WIDTH-1:0]             map_wr_data,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]         map_wr_strb,

    input  wire                                  map_rd_en,
    input  wire [AXI_ADDR_WIDTH-1:0]             map_rd_addr,
    output reg  [AXI_DATA_WIDTH-1:0]             map_rd_data,
    output reg                                   map_rd_valid,
    output reg                                   map_rd_error
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

    localparam integer ADDR_LSB = clog2(AXI_DATA_WIDTH / 8);
    localparam integer WEIGHT_DEPTH = MAX_ROWS * MAX_COL_BEATS;
    localparam integer RESULT_PACK_LANES = AXI_DATA_WIDTH / ACC_WIDTH;
    localparam integer MAX_RESULT_VALUES = MAX_ROWS * MAX_GROUP_Q8_BLOCKS;
    localparam integer RESULT_WORD_DEPTH =
        (MAX_RESULT_VALUES + RESULT_PACK_LANES - 1) / RESULT_PACK_LANES;

    localparam [15:0] MAX_ROWS_16 = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16 = MAX_COL_BEATS;
    localparam [15:0] MAX_GROUP_Q8_BLOCKS_16 = MAX_GROUP_Q8_BLOCKS;
    localparam [31:0] MAX_COL_BEATS_32 = MAX_COL_BEATS;
    localparam [31:0] WEIGHT_DEPTH_32 = WEIGHT_DEPTH;
    localparam [31:0] RESULT_WORD_DEPTH_32 = RESULT_WORD_DEPTH;

    // Memory-mapped data windows.  Ranges are interpreted as [base, end):
    // ACT/WEIGHT are CPU/DMA input-loading paths, and RESULT is the CPU/DMA
    // output-readback path.
    localparam [31:0] ACT_BASE_ADDR    = 32'h0001_0000;
    localparam [31:0] ACT_END_ADDR     = 32'h0002_0000;
    localparam [31:0] WEIGHT_BASE_ADDR = 32'h0010_0000;
    localparam [31:0] WEIGHT_END_ADDR  = 32'h0020_0000;
    localparam [31:0] RESULT_BASE_ADDR = 32'h0020_0000;
    localparam [31:0] RESULT_END_ADDR  = 32'h0021_0000;
    localparam [31:0] SPU_IN_BASE_ADDR      = 32'h0030_0000;
    localparam [31:0] SPU_IN_END_ADDR       = 32'h0034_0000;
    localparam [31:0] SPU_OUT_BASE_ADDR     = 32'h0034_0000;
    localparam [31:0] SPU_OUT_END_ADDR      = 32'h0038_0000;
    localparam [31:0] SPU_PARAM_BASE_ADDR   = 32'h0038_0000;
    localparam [31:0] SPU_PARAM_END_ADDR    = 32'h003C_0000;
    localparam [31:0] SPU_SCRATCH_BASE_ADDR = 32'h003C_0000;
    localparam [31:0] SPU_SCRATCH_END_ADDR  = 32'h0040_0000;

    localparam [1:0] REGION_ACT    = 2'd0;
    localparam [1:0] REGION_WEIGHT = 2'd1;
    localparam [1:0] REGION_RESULT = 2'd2;
    localparam [1:0] SPU_REGION_IN      = 2'd0;
    localparam [1:0] SPU_REGION_OUT     = 2'd1;
    localparam [1:0] SPU_REGION_PARAM   = 2'd2;
    localparam [1:0] SPU_REGION_SCRATCH = 2'd3;

    localparam [1:0] RD_KIND_REG   = 2'd0;
    localparam [1:0] RD_KIND_CORE  = 2'd1;
    localparam [1:0] RD_KIND_SPU   = 2'd2;
    localparam [1:0] RD_KIND_ERROR = 2'd3;

    // Support two interconnect addressing styles:
    // 1. Full physical addresses including VPU_BASE_ADDR.
    // 2. Base-stripped addresses that are already local offsets.
    function [AXI_ADDR_WIDTH-1:0] to_local_addr;
        input [AXI_ADDR_WIDTH-1:0] addr;
        begin
            if ((ENABLE_BASE_TRANSLATION != 0) && (addr >= VPU_BASE_ADDR))
                to_local_addr = addr - VPU_BASE_ADDR;
            else
                to_local_addr = addr;
        end
    endfunction

    function [31:0] local32;
        input [AXI_ADDR_WIDTH-1:0] addr;
        reg [AXI_ADDR_WIDTH-1:0] local_addr;
        begin
            local_addr = to_local_addr(addr);
            local32 = local_addr[31:0];
        end
    endfunction

    // 32-bit register writes honor AXI WSTRB.  Only bytes with an asserted
    // strobe are updated; all other bytes keep their previous value.
    function [31:0] apply_wstrb32;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  strobe;
        integer i;
        begin
            apply_wstrb32 = old_value;
            for (i = 0; i < 4; i = i + 1)
                if (strobe[i])
                    apply_wstrb32[8*i +: 8] = new_value[8*i +: 8];
        end
    endfunction

    function is_reg_addr;
        input [31:0] addr;
        begin
            is_reg_addr = (addr < 32'h0001_0000);
        end
    endfunction

    function is_vpu_mem_addr;
        input [31:0] addr;
        begin
            is_vpu_mem_addr =
                ((addr >= ACT_BASE_ADDR) && (addr < ACT_END_ADDR)) ||
                ((addr >= WEIGHT_BASE_ADDR) && (addr < WEIGHT_END_ADDR)) ||
                ((addr >= RESULT_BASE_ADDR) && (addr < RESULT_END_ADDR));
        end
    endfunction

    function is_spu_mem_addr;
        input [31:0] addr;
        begin
            is_spu_mem_addr =
                ((addr >= SPU_IN_BASE_ADDR) && (addr < SPU_IN_END_ADDR)) ||
                ((addr >= SPU_OUT_BASE_ADDR) && (addr < SPU_OUT_END_ADDR)) ||
                ((addr >= SPU_PARAM_BASE_ADDR) && (addr < SPU_PARAM_END_ADDR)) ||
                ((addr >= SPU_SCRATCH_BASE_ADDR) && (addr < SPU_SCRATCH_END_ADDR));
        end
    endfunction

    function is_result_addr;
        input [31:0] addr;
        begin
            is_result_addr =
                (addr >= RESULT_BASE_ADDR) && (addr < RESULT_END_ADDR);
        end
    endfunction

    // Convert a local address into an internal region so GEMV does not need to
    // decode AXI address windows.  The region code is used for both write and
    // read requests.
    function [1:0] mem_region;
        input [31:0] addr;
        begin
            if ((addr >= ACT_BASE_ADDR) && (addr < ACT_END_ADDR))
                mem_region = REGION_ACT;
            else if ((addr >= WEIGHT_BASE_ADDR) && (addr < WEIGHT_END_ADDR))
                mem_region = REGION_WEIGHT;
            else
                mem_region = REGION_RESULT;
        end
    endfunction

    // Each AXI word is AXI_DATA_WIDTH bits.  ADDR_LSB converts a byte offset
    // into a 128-bit local BRAM word index.
    function [31:0] mem_index;
        input [31:0] addr;
        begin
            if ((addr >= ACT_BASE_ADDR) && (addr < ACT_END_ADDR))
                mem_index = (addr - ACT_BASE_ADDR) >> ADDR_LSB;
            else if ((addr >= WEIGHT_BASE_ADDR) && (addr < WEIGHT_END_ADDR))
                mem_index = (addr - WEIGHT_BASE_ADDR) >> ADDR_LSB;
            else
                mem_index = (addr - RESULT_BASE_ADDR) >> ADDR_LSB;
        end
    endfunction

    function [1:0] spu_mem_region;
        input [31:0] addr;
        begin
            if ((addr >= SPU_IN_BASE_ADDR) && (addr < SPU_IN_END_ADDR))
                spu_mem_region = SPU_REGION_IN;
            else if ((addr >= SPU_OUT_BASE_ADDR) && (addr < SPU_OUT_END_ADDR))
                spu_mem_region = SPU_REGION_OUT;
            else if ((addr >= SPU_PARAM_BASE_ADDR) && (addr < SPU_PARAM_END_ADDR))
                spu_mem_region = SPU_REGION_PARAM;
            else
                spu_mem_region = SPU_REGION_SCRATCH;
        end
    endfunction

    function [31:0] spu_mem_index;
        input [31:0] addr;
        begin
            if ((addr >= SPU_IN_BASE_ADDR) && (addr < SPU_IN_END_ADDR))
                spu_mem_index = (addr - SPU_IN_BASE_ADDR) >> ADDR_LSB;
            else if ((addr >= SPU_OUT_BASE_ADDR) && (addr < SPU_OUT_END_ADDR))
                spu_mem_index = (addr - SPU_OUT_BASE_ADDR) >> ADDR_LSB;
            else if ((addr >= SPU_PARAM_BASE_ADDR) && (addr < SPU_PARAM_END_ADDR))
                spu_mem_index = (addr - SPU_PARAM_BASE_ADDR) >> ADDR_LSB;
            else
                spu_mem_index = (addr - SPU_SCRATCH_BASE_ADDR) >> ADDR_LSB;
        end
    endfunction

    // Address windows can be wider than the actual parameterized BRAM depth.
    // This function blocks accesses that decode into a valid window but exceed
    // the implemented memory depth.
    function mem_index_in_range;
        input [31:0] addr;
        reg [1:0] region;
        reg [31:0] index;
        begin
            region = mem_region(addr);
            index = mem_index(addr);
            case (region)
                REGION_ACT:    mem_index_in_range = (index < MAX_COL_BEATS_32);
                REGION_WEIGHT: mem_index_in_range = (index < WEIGHT_DEPTH_32);
                REGION_RESULT: mem_index_in_range = (index < RESULT_WORD_DEPTH_32);
                default:       mem_index_in_range = 1'b0;
            endcase
        end
    endfunction

    function spu_mem_index_in_range;
        input [31:0] addr;
        begin
            spu_mem_index_in_range = is_spu_mem_addr(addr) &&
                                     (spu_mem_index(addr) < SPU_WORD_DEPTH);
        end
    endfunction

    reg [31:0] cfg_rows_reg;
    reg [31:0] cfg_cols_reg;
    reg [31:0] cfg_col_beats_reg;
    reg [31:0] cfg_scale_reg;
    reg [31:0] cfg_mode_reg;
    reg [31:0] cfg_spu_mode_reg;
    reg [31:0] cfg_spu_len_reg;
    reg [31:0] cfg_spu_aux0_reg;
    reg [31:0] cfg_spu_aux1_reg;

    wire core_busy;
    wire core_done;
    wire core_error;
    wire [15:0] core_active_row;
    wire [15:0] core_active_col_beat;
    wire spu_busy;
    wire spu_done;
    wire spu_error;
    wire [7:0] spu_error_code;
    wire [31:0] spu_caps;
    wire status_error = core_error;

    // Register read map.  The low 32 bits carry the useful information; the
    // remaining bits of the 128-bit AXI data bus are returned as zero.  Offset
    // 0x0000 acts as a control register on writes and as a status alias on
    // reads.
    function [AXI_DATA_WIDTH-1:0] reg_read_data;
        input [31:0] addr;
        begin
            reg_read_data = {AXI_DATA_WIDTH{1'b0}};
            case (addr[15:0])
                16'h0000: reg_read_data[2:0]   = {status_error, core_busy, core_done};
                16'h0010: reg_read_data[2:0]   = {status_error, core_busy, core_done};
                16'h0020: reg_read_data[31:0]  = cfg_rows_reg;
                16'h0030: reg_read_data[31:0]  = cfg_cols_reg;
                16'h0040: reg_read_data[31:0]  = cfg_col_beats_reg;
                16'h0050: reg_read_data[31:0]  = cfg_scale_reg;
                16'h0060: reg_read_data[31:0]  = cfg_mode_reg;
                16'h0070: begin
                    reg_read_data[15:0]  = MAX_ROWS_16;
                    reg_read_data[31:16] = MAX_COL_BEATS_16;
                end
                16'h0080: begin
                    reg_read_data[15:0]  = core_active_row;
                    reg_read_data[31:16] = core_active_col_beat;
                end
                16'h0090: begin
                    reg_read_data[0]      = 1'b1; // packed q8_0 mode is available
                    reg_read_data[1]      = 1'b1; // compact active-stride weight layout is available
                    reg_read_data[2]      = 1'b1; // production result is PL-side INT8 requantized output
                    reg_read_data[15:8]   = MAX_GROUP_Q8_BLOCKS_16[7:0];
                    reg_read_data[31:16]  = RESULT_WORD_DEPTH_32[15:0];
                end
                16'h00A0: begin
                    reg_read_data[2:0]    = {spu_error, spu_done, spu_busy};
                    reg_read_data[15:8]   = spu_error_code;
                end
                16'h00B0: begin
                    reg_read_data[2:0]    = {spu_error, spu_done, spu_busy};
                    reg_read_data[15:8]   = spu_error_code;
                end
                16'h00C0: reg_read_data[31:0] = cfg_spu_mode_reg;
                16'h00D0: reg_read_data[31:0] = cfg_spu_len_reg;
                16'h00E0: reg_read_data[31:0] = cfg_spu_aux0_reg;
                16'h00E4: reg_read_data[31:0] = cfg_spu_aux1_reg;
                16'h00F0: reg_read_data[31:0] = spu_caps;
                default: reg_read_data = {AXI_DATA_WIDTH{1'b0}};
            endcase
        end
    endfunction

    wire [31:0] wr_addr_local = local32(map_wr_addr);
    wire [31:0] rd_addr_local = local32(map_rd_addr);

    // Writing bits 0/1 at register 0x0000 does not store a persistent value.
    // These bits generate one-cycle pulses that start GEMV or clear done/error.
    wire ctrl_start_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h0000) &&
        map_wr_strb[0] && map_wr_data[0];
    wire ctrl_clear_done_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h0000) &&
        map_wr_strb[0] && map_wr_data[1];
    wire spu_start_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h00A0) &&
        map_wr_strb[0] && map_wr_data[0];
    wire spu_clear_done_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h00A0) &&
        map_wr_strb[0] && map_wr_data[1];
    wire spu_soft_reset_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h00A0) &&
        map_wr_strb[0] && map_wr_data[2];
    wire core_wr_hit =
        map_wr_en && is_vpu_mem_addr(wr_addr_local) &&
        mem_index_in_range(wr_addr_local);
    wire spu_wr_hit =
        map_wr_en && is_spu_mem_addr(wr_addr_local) &&
        spu_mem_index_in_range(wr_addr_local);

    reg core_start_r;
    reg core_clear_done_r;
    reg spu_start_r;
    reg spu_clear_done_r;
    reg spu_soft_reset_r;
    reg core_wr_en_r;
    reg [1:0] core_wr_region_r;
    reg [31:0] core_wr_index_r;
    reg [AXI_DATA_WIDTH-1:0] core_wr_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] core_wr_strb_r;
    reg spu_wr_en_r;
    reg [1:0] spu_wr_region_r;
    reg [31:0] spu_wr_index_r;
    reg [AXI_DATA_WIDTH-1:0] spu_wr_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] spu_wr_strb_r;

    // Mapping write path:
    // - register writes update cfg_* registers or generate control pulses;
    // - memory writes are latched into core_wr_* so GEMV can update local BRAM.
    // Invalid writes do not generate an AXI BRESP error at this layer; software
    // should read LIMITS and avoid out-of-range writes.
    always @(posedge clk) begin
        if (!resetn) begin
            cfg_rows_reg      <= 32'd0;
            cfg_cols_reg      <= 32'd0;
            cfg_col_beats_reg <= 32'd0;
            cfg_scale_reg     <= 32'h0000_3c00;
            cfg_mode_reg      <= 32'd0;
            cfg_spu_mode_reg  <= 32'd0;
            cfg_spu_len_reg   <= 32'd0;
            cfg_spu_aux0_reg  <= 32'd0;
            cfg_spu_aux1_reg  <= 32'd0;
            core_start_r      <= 1'b0;
            core_clear_done_r <= 1'b0;
            spu_start_r       <= 1'b0;
            spu_clear_done_r  <= 1'b0;
            spu_soft_reset_r  <= 1'b0;
            core_wr_en_r      <= 1'b0;
            core_wr_region_r  <= REGION_ACT;
            core_wr_index_r   <= 32'd0;
            core_wr_data_r    <= {AXI_DATA_WIDTH{1'b0}};
            core_wr_strb_r    <= {(AXI_DATA_WIDTH/8){1'b0}};
            spu_wr_en_r       <= 1'b0;
            spu_wr_region_r   <= SPU_REGION_IN;
            spu_wr_index_r    <= 32'd0;
            spu_wr_data_r     <= {AXI_DATA_WIDTH{1'b0}};
            spu_wr_strb_r     <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            core_start_r      <= ctrl_start_hit;
            core_clear_done_r <= ctrl_clear_done_hit;
            spu_start_r       <= spu_start_hit;
            spu_clear_done_r  <= spu_clear_done_hit;
            spu_soft_reset_r  <= spu_soft_reset_hit;
            core_wr_en_r      <= core_wr_hit;
            spu_wr_en_r       <= spu_wr_hit;

            if (core_wr_hit) begin
                core_wr_region_r <= mem_region(wr_addr_local);
                core_wr_index_r  <= mem_index(wr_addr_local);
                core_wr_data_r   <= map_wr_data;
                core_wr_strb_r   <= map_wr_strb;
            end

            if (spu_wr_hit) begin
                spu_wr_region_r <= spu_mem_region(wr_addr_local);
                spu_wr_index_r  <= spu_mem_index(wr_addr_local);
                spu_wr_data_r   <= map_wr_data;
                spu_wr_strb_r   <= map_wr_strb;
            end

            if (map_wr_en && is_reg_addr(wr_addr_local)) begin
                case (wr_addr_local[15:0])
                    16'h0020: cfg_rows_reg      <= apply_wstrb32(cfg_rows_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0030: cfg_cols_reg      <= apply_wstrb32(cfg_cols_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0040: cfg_col_beats_reg <= apply_wstrb32(cfg_col_beats_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0050: cfg_scale_reg     <= apply_wstrb32(cfg_scale_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0060: cfg_mode_reg      <= apply_wstrb32(cfg_mode_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h00C0: cfg_spu_mode_reg  <= apply_wstrb32(cfg_spu_mode_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h00D0: cfg_spu_len_reg   <= apply_wstrb32(cfg_spu_len_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h00E0: cfg_spu_aux0_reg  <= apply_wstrb32(cfg_spu_aux0_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h00E4: cfg_spu_aux1_reg  <= apply_wstrb32(cfg_spu_aux1_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    default: begin
                    end
                endcase
            end
        end
    end

    // The read path only forwards Result-window reads to GEMV.  Activation and
    // Weight windows are input-loading paths, so reading them back reports an
    // error through map_rd_error.
    wire mmio_core_rd_en =
        map_rd_en && is_result_addr(rd_addr_local) &&
        mem_index_in_range(rd_addr_local);
    wire [1:0] mmio_core_rd_region = mem_region(rd_addr_local);
    wire [31:0] mmio_core_rd_index = mem_index(rd_addr_local);
    wire core_rd_en = mmio_core_rd_en;
    wire [1:0] core_rd_region = mmio_core_rd_region;
    wire [31:0] core_rd_index = mmio_core_rd_index;
    wire [AXI_DATA_WIDTH-1:0] core_rd_data;
    wire core_rd_valid;
    wire core_rd_error;

    wire mmio_spu_rd_en =
        map_rd_en && is_spu_mem_addr(rd_addr_local) &&
        spu_mem_index_in_range(rd_addr_local);
    wire [1:0] spu_rd_region = spu_mem_region(rd_addr_local);
    wire [31:0] spu_rd_index = spu_mem_index(rd_addr_local);
    wire [AXI_DATA_WIDTH-1:0] spu_rd_data;
    wire spu_rd_valid;
    wire spu_rd_error;

    reg rd_pending_r;
    reg [1:0] rd_pending_kind_r;
    reg rd_pending_error_r;
    reg [AXI_DATA_WIDTH-1:0] rd_pending_reg_data_r;
    wire rd_pending_ready =
        rd_pending_r &&
        ((rd_pending_kind_r == RD_KIND_REG) ||
         (rd_pending_kind_r == RD_KIND_ERROR) ||
         ((rd_pending_kind_r == RD_KIND_CORE) && core_rd_valid) ||
         ((rd_pending_kind_r == RD_KIND_SPU) && spu_rd_valid));

    // Read response pipeline.  Register reads can return after one cycle using
    // rd_pending_reg_data_r; Result reads must wait for GEMV/Result BRAM to
    // assert core_rd_valid before map_rd_valid is returned to MY_IP.
    always @(posedge clk) begin
        if (!resetn) begin
            map_rd_data <= {AXI_DATA_WIDTH{1'b0}};
            map_rd_valid <= 1'b0;
            map_rd_error <= 1'b0;
            rd_pending_r <= 1'b0;
            rd_pending_kind_r <= RD_KIND_REG;
            rd_pending_error_r <= 1'b0;
            rd_pending_reg_data_r <= {AXI_DATA_WIDTH{1'b0}};
        end else begin
            map_rd_valid <= 1'b0;
            map_rd_error <= 1'b0;
            map_rd_data  <= {AXI_DATA_WIDTH{1'b0}};

            if (map_rd_en) begin
                rd_pending_r <= 1'b1;
                if (is_result_addr(rd_addr_local) && mem_index_in_range(rd_addr_local))
                    rd_pending_kind_r <= RD_KIND_CORE;
                else if (is_spu_mem_addr(rd_addr_local) && spu_mem_index_in_range(rd_addr_local))
                    rd_pending_kind_r <= RD_KIND_SPU;
                else if (is_reg_addr(rd_addr_local))
                    rd_pending_kind_r <= RD_KIND_REG;
                else
                    rd_pending_kind_r <= RD_KIND_ERROR;
                rd_pending_error_r <= (!is_reg_addr(rd_addr_local)) &&
                                      (!(is_result_addr(rd_addr_local) &&
                                         mem_index_in_range(rd_addr_local))) &&
                                      (!(is_spu_mem_addr(rd_addr_local) &&
                                         spu_mem_index_in_range(rd_addr_local)));
                rd_pending_reg_data_r <= reg_read_data(rd_addr_local);
            end else if (rd_pending_ready) begin
                rd_pending_r <= 1'b0;
            end

            if (rd_pending_ready) begin
                map_rd_valid <= 1'b1;
                if (rd_pending_kind_r == RD_KIND_CORE) begin
                    map_rd_data  <= core_rd_data;
                    map_rd_error <= core_rd_error || (!core_rd_valid);
                end else if (rd_pending_kind_r == RD_KIND_SPU) begin
                    map_rd_data  <= spu_rd_data;
                    map_rd_error <= spu_rd_error || (!spu_rd_valid);
                end else begin
                    map_rd_data  <= rd_pending_reg_data_r;
                    map_rd_error <= rd_pending_error_r;
                end
            end
        end
    end

    // GEMV contains the local BRAMs, compute FSM, and PMAU_Full instance. The
    // mapping layer only forwards configuration, memory-window requests, and
    // receives status/result data.
    Matrix_Vector_Multiplication #(
        .NUM_LANES         (NUM_LANES),
        .ACT_WIDTH         (ACT_WIDTH),
        .WEIGHT_WIDTH      (WEIGHT_WIDTH),
        .ACC_WIDTH         (ACC_WIDTH),
        .SCALE_WIDTH       (SCALE_WIDTH),
        .SCALE_FRAC_BITS   (SCALE_FRAC_BITS),
        .RESULT_FIFO_DEPTH (RESULT_FIFO_DEPTH),
        .AXI_DATA_WIDTH    (AXI_DATA_WIDTH),
        .MAX_ROWS          (MAX_ROWS),
        .MAX_COL_BEATS     (MAX_COL_BEATS),
        .MAX_GROUP_Q8_BLOCKS (MAX_GROUP_Q8_BLOCKS)
    ) u_gemv (
        .CLK               (clk),
        .RST               (resetn),
        .ctrl_start        (core_start_r),
        .ctrl_clear_done   (core_clear_done_r),
        .cfg_rows          (cfg_rows_reg[15:0]),
        .cfg_cols          (cfg_cols_reg[15:0]),
        .cfg_col_beats     (cfg_col_beats_reg[15:0]),
        .cfg_scale         (cfg_scale_reg[SCALE_WIDTH-1:0]),
        .compute_mode      (cfg_mode_reg[3:0]),
        .busy              (core_busy),
        .done              (core_done),
        .error             (core_error),
        .active_row        (core_active_row),
        .active_col_beat   (core_active_col_beat),
        .mm_wr_en          (core_wr_en_r),
        .mm_wr_region      (core_wr_region_r),
        .mm_wr_index       (core_wr_index_r),
        .mm_wr_data        (core_wr_data_r),
        .mm_wr_strb        (core_wr_strb_r),
        .mm_rd_en          (core_rd_en),
        .mm_rd_region      (core_rd_region),
        .mm_rd_index       (core_rd_index),
        .mm_rd_data        (core_rd_data),
        .mm_rd_valid       (core_rd_valid),
        .mm_rd_error       (core_rd_error)
    );

    SPU_Top #(
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .WORD_DEPTH     (SPU_WORD_DEPTH)
    ) u_spu (
        .clk             (clk),
        .resetn          (resetn),
        .spu_start       (spu_start_r),
        .spu_clear_done  (spu_clear_done_r),
        .spu_soft_reset  (spu_soft_reset_r),
        .spu_mode        (cfg_spu_mode_reg[7:0]),
        .spu_len         (cfg_spu_len_reg),
        .spu_aux0        (cfg_spu_aux0_reg),
        .spu_aux1        (cfg_spu_aux1_reg),
        .spu_busy        (spu_busy),
        .spu_done        (spu_done),
        .spu_error       (spu_error),
        .spu_error_code  (spu_error_code),
        .spu_caps        (spu_caps),
        .mm_wr_en        (spu_wr_en_r),
        .mm_wr_region    (spu_wr_region_r),
        .mm_wr_index     (spu_wr_index_r),
        .mm_wr_data      (spu_wr_data_r),
        .mm_wr_strb      (spu_wr_strb_r),
        .mm_rd_en        (mmio_spu_rd_en),
        .mm_rd_region    (spu_rd_region),
        .mm_rd_index     (spu_rd_index),
        .mm_rd_data      (spu_rd_data),
        .mm_rd_valid     (spu_rd_valid),
        .mm_rd_error     (spu_rd_error)
    );
endmodule
