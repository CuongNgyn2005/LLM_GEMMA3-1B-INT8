/*
 *-----------------------------------------------------------------------------
 * Module      : AXI4_Mapping
 * Description : Internal address/register mapping layer for the INT8 VPU.
 *
 * Hierarchy:
 *   VPU_Top -> MY_IP -> AXI4_Mapping -> Matrix_Vector_Multiplication
 *
 * MY_IP owns the AXI4-Full protocol channels.  This module owns the VPU local
 * register map, memory-window decode, optional physical-base translation, and
 * the GEMV core instance.
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
    parameter integer MAX_ROWS                 = 128,
    parameter integer MAX_COL_BEATS            = 256
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

    localparam [15:0] MAX_ROWS_16 = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16 = MAX_COL_BEATS;
    localparam [31:0] MAX_ROWS_32 = MAX_ROWS;
    localparam [31:0] MAX_COL_BEATS_32 = MAX_COL_BEATS;
    localparam [31:0] WEIGHT_DEPTH_32 = WEIGHT_DEPTH;

    localparam [31:0] ACT_BASE_ADDR    = 32'h0001_0000;
    localparam [31:0] ACT_END_ADDR     = 32'h0002_0000;
    localparam [31:0] WEIGHT_BASE_ADDR = 32'h0010_0000;
    localparam [31:0] WEIGHT_END_ADDR  = 32'h0020_0000;
    localparam [31:0] RESULT_BASE_ADDR = 32'h0020_0000;
    localparam [31:0] RESULT_END_ADDR  = 32'h0021_0000;

    localparam [1:0] REGION_ACT    = 2'd0;
    localparam [1:0] REGION_WEIGHT = 2'd1;
    localparam [1:0] REGION_RESULT = 2'd2;

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

    function is_mem_addr;
        input [31:0] addr;
        begin
            is_mem_addr =
                ((addr >= ACT_BASE_ADDR) && (addr < ACT_END_ADDR)) ||
                ((addr >= WEIGHT_BASE_ADDR) && (addr < WEIGHT_END_ADDR)) ||
                ((addr >= RESULT_BASE_ADDR) && (addr < RESULT_END_ADDR));
        end
    endfunction

    function is_result_addr;
        input [31:0] addr;
        begin
            is_result_addr =
                (addr >= RESULT_BASE_ADDR) && (addr < RESULT_END_ADDR);
        end
    endfunction

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
                REGION_RESULT: mem_index_in_range = (index < MAX_ROWS_32);
                default:       mem_index_in_range = 1'b0;
            endcase
        end
    endfunction

    reg [31:0] cfg_rows_reg;
    reg [31:0] cfg_cols_reg;
    reg [31:0] cfg_col_beats_reg;
    reg [31:0] cfg_scale_reg;
    reg [31:0] cfg_mode_reg;

    wire core_busy;
    wire core_done;
    wire core_error;
    wire [15:0] core_active_row;
    wire [15:0] core_active_col_beat;

    function [AXI_DATA_WIDTH-1:0] reg_read_data;
        input [31:0] addr;
        begin
            reg_read_data = {AXI_DATA_WIDTH{1'b0}};
            case (addr[15:0])
                16'h0000: reg_read_data[2:0]   = {core_error, core_busy, core_done};
                16'h0010: reg_read_data[2:0]   = {core_error, core_busy, core_done};
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
                default: reg_read_data = {AXI_DATA_WIDTH{1'b0}};
            endcase
        end
    endfunction

    wire [31:0] wr_addr_local = local32(map_wr_addr);
    wire [31:0] rd_addr_local = local32(map_rd_addr);

    wire ctrl_start_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h0000) &&
        map_wr_strb[0] && map_wr_data[0];
    wire ctrl_clear_done_hit =
        map_wr_en && is_reg_addr(wr_addr_local) &&
        (wr_addr_local[15:0] == 16'h0000) &&
        map_wr_strb[0] && map_wr_data[1];
    wire core_wr_hit =
        map_wr_en && is_mem_addr(wr_addr_local) &&
        mem_index_in_range(wr_addr_local);

    reg core_start_r;
    reg core_clear_done_r;
    reg core_wr_en_r;
    reg [1:0] core_wr_region_r;
    reg [31:0] core_wr_index_r;
    reg [AXI_DATA_WIDTH-1:0] core_wr_data_r;
    reg [(AXI_DATA_WIDTH/8)-1:0] core_wr_strb_r;

    always @(posedge clk) begin
        if (!resetn) begin
            cfg_rows_reg      <= 32'd0;
            cfg_cols_reg      <= 32'd0;
            cfg_col_beats_reg <= 32'd0;
            cfg_scale_reg     <= 32'h0000_3c00;
            cfg_mode_reg      <= 32'd0;
            core_start_r      <= 1'b0;
            core_clear_done_r <= 1'b0;
            core_wr_en_r      <= 1'b0;
            core_wr_region_r  <= REGION_ACT;
            core_wr_index_r   <= 32'd0;
            core_wr_data_r    <= {AXI_DATA_WIDTH{1'b0}};
            core_wr_strb_r    <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            core_start_r      <= ctrl_start_hit;
            core_clear_done_r <= ctrl_clear_done_hit;
            core_wr_en_r      <= core_wr_hit;

            if (core_wr_hit) begin
                core_wr_region_r <= mem_region(wr_addr_local);
                core_wr_index_r  <= mem_index(wr_addr_local);
                core_wr_data_r   <= map_wr_data;
                core_wr_strb_r   <= map_wr_strb;
            end

            if (map_wr_en && is_reg_addr(wr_addr_local)) begin
                case (wr_addr_local[15:0])
                    16'h0020: cfg_rows_reg      <= apply_wstrb32(cfg_rows_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0030: cfg_cols_reg      <= apply_wstrb32(cfg_cols_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0040: cfg_col_beats_reg <= apply_wstrb32(cfg_col_beats_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0050: cfg_scale_reg     <= apply_wstrb32(cfg_scale_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    16'h0060: cfg_mode_reg      <= apply_wstrb32(cfg_mode_reg, map_wr_data[31:0], map_wr_strb[3:0]);
                    default: begin
                    end
                endcase
            end
        end
    end

    wire core_rd_en =
        map_rd_en && is_result_addr(rd_addr_local) &&
        mem_index_in_range(rd_addr_local);
    wire [1:0] core_rd_region = mem_region(rd_addr_local);
    wire [31:0] core_rd_index = mem_index(rd_addr_local);
    wire [AXI_DATA_WIDTH-1:0] core_rd_data;
    wire core_rd_valid;
    wire core_rd_error;

    reg rd_pending_r;
    reg rd_pending_is_core_r;
    reg rd_pending_error_r;
    reg [AXI_DATA_WIDTH-1:0] rd_pending_reg_data_r;

    always @(posedge clk) begin
        if (!resetn) begin
            map_rd_data <= {AXI_DATA_WIDTH{1'b0}};
            map_rd_valid <= 1'b0;
            map_rd_error <= 1'b0;
            rd_pending_r <= 1'b0;
            rd_pending_is_core_r <= 1'b0;
            rd_pending_error_r <= 1'b0;
            rd_pending_reg_data_r <= {AXI_DATA_WIDTH{1'b0}};
        end else begin
            map_rd_valid <= 1'b0;
            map_rd_error <= 1'b0;
            map_rd_data  <= {AXI_DATA_WIDTH{1'b0}};

            if (map_rd_en) begin
                rd_pending_r <= 1'b1;
                rd_pending_is_core_r <= is_result_addr(rd_addr_local) &&
                                        mem_index_in_range(rd_addr_local);
                rd_pending_error_r <= (!is_reg_addr(rd_addr_local)) &&
                                      (!(is_result_addr(rd_addr_local) &&
                                         mem_index_in_range(rd_addr_local)));
                rd_pending_reg_data_r <= reg_read_data(rd_addr_local);
            end else if (rd_pending_r && ((!rd_pending_is_core_r) || core_rd_valid)) begin
                rd_pending_r <= 1'b0;
            end

            if (rd_pending_r && ((!rd_pending_is_core_r) || core_rd_valid)) begin
                map_rd_valid <= 1'b1;
                if (rd_pending_is_core_r) begin
                    map_rd_data  <= core_rd_data;
                    map_rd_error <= core_rd_error || (!core_rd_valid);
                end else begin
                    map_rd_data  <= rd_pending_reg_data_r;
                    map_rd_error <= rd_pending_error_r;
                end
            end
        end
    end

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
        .MAX_COL_BEATS     (MAX_COL_BEATS)
    ) u_gemv (
        .CLK               (clk),
        .RST               (resetn),
        .ctrl_start        (core_start_r),
        .ctrl_clear_done   (core_clear_done_r),
        .cfg_rows          (cfg_rows_reg[15:0]),
        .cfg_cols          (cfg_cols_reg[15:0]),
        .cfg_col_beats     (cfg_col_beats_reg[15:0]),
        .cfg_scale         (cfg_scale_reg[SCALE_WIDTH-1:0]),
        .compute_mode      (cfg_mode_reg[1:0]),
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

endmodule
