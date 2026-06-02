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

    localparam integer ADDR_LSB = clog2(C_S00_AXI_DATA_WIDTH / 8);
    localparam [2:0] ADDR_LSB_3 = ADDR_LSB;
    localparam [15:0] MAX_ROWS_16 = MAX_ROWS;
    localparam [15:0] MAX_COL_BEATS_16 = MAX_COL_BEATS;
    localparam integer WEIGHT_DEPTH = MAX_ROWS * MAX_COL_BEATS;
    localparam [31:0] MAX_ROWS_32 = MAX_ROWS;
    localparam [31:0] MAX_COL_BEATS_32 = MAX_COL_BEATS;
    localparam [31:0] WEIGHT_DEPTH_32 = WEIGHT_DEPTH;
    localparam [31:0] ACT_BASE_ADDR = 32'h0001_0000;
    localparam [31:0] ACT_END_ADDR = 32'h0002_0000;
    localparam [31:0] WEIGHT_BASE_ADDR = 32'h0010_0000;
    localparam [31:0] WEIGHT_END_ADDR = 32'h0020_0000;
    localparam [31:0] RESULT_BASE_ADDR = 32'h0020_0000;
    localparam [31:0] RESULT_END_ADDR = 32'h0021_0000;

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
                mem_region = 2'd0;
            else if ((addr >= WEIGHT_BASE_ADDR) && (addr < WEIGHT_END_ADDR))
                mem_region = 2'd1;
            else
                mem_region = 2'd2;
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
                2'd0: mem_index_in_range = (index < MAX_COL_BEATS_32);
                2'd1: mem_index_in_range = (index < WEIGHT_DEPTH_32);
                2'd2: mem_index_in_range = (index < MAX_ROWS_32);
                default: mem_index_in_range = 1'b0;
            endcase
        end
    endfunction

    function [C_S00_AXI_DATA_WIDTH-1:0] reg_read_data;
        input [31:0] addr;
        begin
            reg_read_data = {C_S00_AXI_DATA_WIDTH{1'b0}};
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
                default: reg_read_data = {C_S00_AXI_DATA_WIDTH{1'b0}};
            endcase
        end
    endfunction

    reg wr_active_r;
    reg [C_S00_AXI_ADDR_WIDTH-1:0] wr_addr_r;
    reg [7:0] wr_len_r;
    reg [7:0] wr_beat_r;
    reg [2:0] wr_size_r;
    reg [1:0] wr_burst_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] wr_id_r;
    reg bvalid_r;
    reg wr_done_pending_r;
    reg core_wr_en_r;
    reg [1:0] core_wr_region_r;
    reg [31:0] core_wr_index_r;
    reg [C_S00_AXI_DATA_WIDTH-1:0] core_wr_data_r;
    reg [(C_S00_AXI_DATA_WIDTH/8)-1:0] core_wr_strb_r;

    assign s00_axi_awready = (!wr_active_r) && (!bvalid_r) && (!wr_done_pending_r);
    assign s00_axi_wready  = wr_active_r;
    assign s00_axi_bvalid  = bvalid_r;
    assign s00_axi_bresp   = 2'b00;
    assign s00_axi_bid     = wr_id_r;
    assign s00_axi_buser   = {C_S00_AXI_BUSER_WIDTH{1'b0}};

    wire aw_fire = s00_axi_awvalid && s00_axi_awready;
    wire w_fire  = s00_axi_wvalid && s00_axi_wready;
    wire w_done  = w_fire && (s00_axi_wlast || (wr_beat_r == wr_len_r));

    wire core_start_pulse =
        w_fire && is_reg_addr(wr_addr_r[31:0]) &&
        (wr_addr_r[15:0] == 16'h0000) &&
        s00_axi_wstrb[0] && s00_axi_wdata[0];
    wire core_clear_done_pulse =
        w_fire && is_reg_addr(wr_addr_r[31:0]) &&
        (wr_addr_r[15:0] == 16'h0000) &&
        s00_axi_wstrb[0] && s00_axi_wdata[1];

    wire core_wr_hit =
        w_fire && is_mem_addr(wr_addr_r[31:0]) &&
        mem_index_in_range(wr_addr_r[31:0]);
    wire [1:0] core_wr_region_next = mem_region(wr_addr_r[31:0]);
    wire [31:0] core_wr_index_next = mem_index(wr_addr_r[31:0]);

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
            core_wr_en_r      <= 1'b0;
            core_wr_region_r  <= 2'd0;
            core_wr_index_r   <= 32'd0;
            core_wr_data_r    <= {C_S00_AXI_DATA_WIDTH{1'b0}};
            core_wr_strb_r    <= {(C_S00_AXI_DATA_WIDTH/8){1'b0}};
            cfg_rows_reg      <= 32'd0;
            cfg_cols_reg      <= 32'd0;
            cfg_col_beats_reg <= 32'd0;
            cfg_scale_reg     <= 32'h0000_3c00;
            cfg_mode_reg      <= 32'd0;
        end else begin
            core_wr_en_r <= core_wr_hit;
            if (core_wr_hit) begin
                core_wr_region_r <= core_wr_region_next;
                core_wr_index_r  <= core_wr_index_next;
                core_wr_data_r   <= s00_axi_wdata;
                core_wr_strb_r   <= s00_axi_wstrb;
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
                if (is_reg_addr(wr_addr_r[31:0])) begin
                    case (wr_addr_r[15:0])
                        16'h0020: cfg_rows_reg      <= apply_wstrb32(cfg_rows_reg, s00_axi_wdata[31:0], s00_axi_wstrb[3:0]);
                        16'h0030: cfg_cols_reg      <= apply_wstrb32(cfg_cols_reg, s00_axi_wdata[31:0], s00_axi_wstrb[3:0]);
                        16'h0040: cfg_col_beats_reg <= apply_wstrb32(cfg_col_beats_reg, s00_axi_wdata[31:0], s00_axi_wstrb[3:0]);
                        16'h0050: cfg_scale_reg     <= apply_wstrb32(cfg_scale_reg, s00_axi_wdata[31:0], s00_axi_wstrb[3:0]);
                        16'h0060: cfg_mode_reg      <= apply_wstrb32(cfg_mode_reg, s00_axi_wdata[31:0], s00_axi_wstrb[3:0]);
                        default: begin
                        end
                    endcase
                end

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
    reg rd_pending_is_mem_r;
    reg rd_pending_last_r;
    reg rd_pending_error_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] rd_pending_id_r;
    reg [C_S00_AXI_DATA_WIDTH-1:0] rd_pending_reg_data_r;

    reg rvalid_r;
    reg rlast_r;
    reg [1:0] rresp_r;
    reg [C_S00_AXI_ID_WIDTH-1:0] rid_r;
    reg [C_S00_AXI_DATA_WIDTH-1:0] rdata_r;

    assign s00_axi_arready =
        (!read_active_r) && (!rd_pending_r) && (!rvalid_r) &&
        (!wr_active_r) && (!bvalid_r);
    assign s00_axi_rvalid  = rvalid_r;
    assign s00_axi_rlast   = rlast_r;
    assign s00_axi_rresp   = rresp_r;
    assign s00_axi_rid     = rid_r;
    assign s00_axi_rdata   = rdata_r;
    assign s00_axi_ruser   = {C_S00_AXI_RUSER_WIDTH{1'b0}};

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

    wire core_rd_en =
        issue_read_r &&
        is_result_addr(issue_addr_r[31:0]) &&
        mem_index_in_range(issue_addr_r[31:0]);
    wire [1:0] core_rd_region = mem_region(issue_addr_r[31:0]);
    wire [31:0] core_rd_index = mem_index(issue_addr_r[31:0]);
    wire [C_S00_AXI_DATA_WIDTH-1:0] core_rd_data;
    wire core_rd_valid;
    wire core_rd_error;

    always @(posedge s00_axi_aclk) begin
        if (!s00_axi_aresetn) begin
            read_active_r        <= 1'b0;
            rd_addr_r            <= {C_S00_AXI_ADDR_WIDTH{1'b0}};
            rd_len_r             <= 8'd0;
            rd_beat_r            <= 8'd0;
            rd_size_r            <= ADDR_LSB_3;
            rd_burst_r           <= 2'b01;
            rd_id_r              <= {C_S00_AXI_ID_WIDTH{1'b0}};
            rd_pending_r         <= 1'b0;
            rd_pending_is_mem_r  <= 1'b0;
            rd_pending_last_r    <= 1'b0;
            rd_pending_error_r   <= 1'b0;
            rd_pending_id_r      <= {C_S00_AXI_ID_WIDTH{1'b0}};
            rd_pending_reg_data_r <= {C_S00_AXI_DATA_WIDTH{1'b0}};
            rvalid_r             <= 1'b0;
            rlast_r              <= 1'b0;
            rresp_r              <= 2'b00;
            rid_r                <= {C_S00_AXI_ID_WIDTH{1'b0}};
            rdata_r              <= {C_S00_AXI_DATA_WIDTH{1'b0}};
        end else begin
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
                rd_pending_r          <= 1'b1;
                rd_pending_is_mem_r   <= is_result_addr(issue_addr_r[31:0]) &&
                                         mem_index_in_range(issue_addr_r[31:0]);
                rd_pending_last_r     <= issue_last_r;
                rd_pending_error_r    <= (!is_reg_addr(issue_addr_r[31:0])) &&
                                         (!(is_result_addr(issue_addr_r[31:0]) &&
                                            mem_index_in_range(issue_addr_r[31:0])));
                rd_pending_id_r       <= issue_id_r;
                rd_pending_reg_data_r <= reg_read_data(issue_addr_r[31:0]);
            end else if (rd_pending_r && (!rvalid_r) &&
                         ((!rd_pending_is_mem_r) || core_rd_valid)) begin
                rd_pending_r <= 1'b0;
            end

            if ((!rvalid_r) && rd_pending_r &&
                ((!rd_pending_is_mem_r) || core_rd_valid)) begin
                rvalid_r <= 1'b1;
                rlast_r  <= rd_pending_last_r;
                rid_r    <= rd_pending_id_r;
                if (rd_pending_is_mem_r) begin
                    rdata_r <= core_rd_data;
                    rresp_r <= (core_rd_error || (!core_rd_valid)) ? 2'b10 : 2'b00;
                end else begin
                    rdata_r <= rd_pending_reg_data_r;
                    rresp_r <= rd_pending_error_r ? 2'b10 : 2'b00;
                end
            end else if (r_fire) begin
                rvalid_r <= 1'b0;
                if (rlast_r)
                    read_active_r <= 1'b0;
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
        .AXI_DATA_WIDTH    (C_S00_AXI_DATA_WIDTH),
        .MAX_ROWS          (MAX_ROWS),
        .MAX_COL_BEATS     (MAX_COL_BEATS)
    ) u_gemv (
        .CLK               (s00_axi_aclk),
        .RST               (s00_axi_aresetn),
        .ctrl_start        (core_start_pulse),
        .ctrl_clear_done   (core_clear_done_pulse),
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
