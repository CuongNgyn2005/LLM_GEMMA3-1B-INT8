`timescale 1ns/1ps
// Shared, one-key-tile ONLINE attention engine, ABI 0x41540101.
// Q is pre-scaled FP32 [Hq,D]; K/V are FP16 [N,Hkv,D]; mask[N] is byte 0/1.
// Each visible key updates global (m,l,O), without tile-local normalization:
// first: (score,1,V); larger score: (score,l*exp(m-score)+1,O*exp(m-score)+V);
// otherwise: (m,l+exp(score-m),O+exp(score-m)*V). Normalize only after all N.
// One Attention_FP32 datapath is shared by dot, online update, normalize and Q8.
// Preload all Q, then iterate KV group -> increasing key -> grouped query head.
// For each visible key, load contiguous K then contiguous V into local vectors
// once; reuse them across that group's query heads. Per-head m/l/seen/O persist
// across every key. Normalize the complete group only after its final key.
// Local arrays: Q[1024], unnormalized O[1024], output[1024], K[256], V[256],
// all FP32; four per-head m/l/seen records. Storage is independent of N. A single
// aligned read-beat cache serves scalar fields and is invalidated on each
// accepted idle START, before any new descriptor reads can issue.
// No host/RTL fallback, repaired values, hidden clamping, or behavioral floating
// arithmetic. Output is invalid until all F32/Q8/scale writes have B responses.
// Busy config/control writes abort after AXI/FP drain, keeping original tag/gen.
// Error codes: 1 descriptor, 2 busy mutation, 3 AXI, 4 invalid data, 5 arithmetic,
// 6 all masked, 7 Q8 integer outside [-127,127]. System reset resets the AXI peer.
module Attention_Engine (
    input wire clk, resetn,
    input wire reg_wr_en,
    input wire [7:0] reg_wr_addr,
    input wire [31:0] reg_wr_data,
    input wire [3:0] reg_wr_strb,
    input wire [7:0] reg_rd_addr,
    output reg [31:0] reg_rd_data,
    output wire [0:0] m_att_axi_awid,
    output wire [39:0] m_att_axi_awaddr,
    output wire [7:0] m_att_axi_awlen,
    output wire [2:0] m_att_axi_awsize,
    output wire [1:0] m_att_axi_awburst,
    output wire m_att_axi_awlock,
    output wire [3:0] m_att_axi_awcache,
    output wire [2:0] m_att_axi_awprot,
    output wire [3:0] m_att_axi_awqos, m_att_axi_awregion,
    output wire m_att_axi_awvalid,
    input wire m_att_axi_awready,
    output wire [127:0] m_att_axi_wdata,
    output wire [15:0] m_att_axi_wstrb,
    output wire m_att_axi_wlast, m_att_axi_wvalid,
    input wire m_att_axi_wready,
    input wire [0:0] m_att_axi_bid,
    input wire [1:0] m_att_axi_bresp,
    input wire m_att_axi_bvalid,
    output wire m_att_axi_bready,
    output wire [0:0] m_att_axi_arid,
    output wire [39:0] m_att_axi_araddr,
    output wire [7:0] m_att_axi_arlen,
    output wire [2:0] m_att_axi_arsize,
    output wire [1:0] m_att_axi_arburst,
    output wire m_att_axi_arlock,
    output wire [3:0] m_att_axi_arcache,
    output wire [2:0] m_att_axi_arprot,
    output wire [3:0] m_att_axi_arqos, m_att_axi_arregion,
    output wire m_att_axi_arvalid,
    input wire m_att_axi_arready,
    input wire [0:0] m_att_axi_rid,
    input wire [127:0] m_att_axi_rdata,
    input wire [1:0] m_att_axi_rresp,
    input wire m_att_axi_rlast, m_att_axi_rvalid,
    output wire m_att_axi_rready
);
    localparam integer C_TAG=0, C_D=1, C_HQ=2, C_HKV=3, C_N=4,
        C_Q=5, C_K=6, C_V=7, C_MASK=8, C_OUT=9, C_Q8=10, C_SCALE=11, C_GEN=12;
    localparam [6:0] S_IDLE=0, S_VALIDATE=1, S_SPANS=2, S_Q_HEAD=3,
        S_Q_REQ=4, S_Q_GOT=5, S_MASK_REQ=6, S_MASK_GOT=7,
        S_K_REQ=8, S_K_GOT=9, S_DOT_MUL=10, S_DOT_ADD=11, S_SCORE=12,
        S_WEIGHT_EXP=13, S_WEIGHT_GOT=14, S_SUM_MUL=15, S_SUM_GOT=16,
        S_V_REQ=17, S_HEAD_SAVE=18, S_V_MUL=19, S_V_ADD=20, S_V_NEXT=21,
        S_KEY_NEXT=22, S_NORM_REQ=23, S_NORM_GOT=24, S_NORM_WROTE=25,
        S_QUANT_BLOCK=26, S_AMAX=27, S_SCALE_GOT=28, S_ID_GOT=29,
        S_HALF_GOT=30, S_SCALE_WROTE=31, S_QUANT_VALUE=32, S_QUANT_MUL=33,
        S_QUANT_INT=34, S_QUANT_WROTE=35, S_FINISH=36, S_DRAIN=37,
        S_MEM_CMD=38, S_MEM_WAIT=39, S_FP_CMD=40, S_FP_WAIT=41,
        S_GROUP_BEGIN=42, S_V_LOAD_REQ=43, S_V_LOAD_GOT=44,
        S_HEAD_RESTORE=45, S_DOT_REQ=46, S_NORM_HEAD=47,
        S_SPAN_SIZE=48, S_SPAN_END=49, S_KV_HEAD=50, S_KV_BASE=51;
    localparam [1:0] UPDATE_FIRST=0, UPDATE_RESCALE=1, UPDATE_ADD=2;
    reg [6:0] state_r, mem_return_r, fp_return_r;
    reg [31:0] cfg_r[0:12], desc_r[0:12];
    reg done_r, retained_valid_r;
    reg [31:0] error_code_r, active_error_r, done_tag_r, done_gen_r;
    wire busy = state_r != S_IDLE;
    reg [31:0] q_r[0:1023], accum_r[0:1023], output_r[0:1023];
    reg [31:0] k_vector_r[0:255], v_vector_r[0:255];
    reg [31:0] head_maximum_r[0:3], head_sum_r[0:3];
    reg head_seen_r[0:3];
    reg [31:0] head_r, key_r, dim_r, group_r, total_r;
    reg [31:0] head_base_r;
    reg [31:0] kv_group_r;
    reg [31:0] group_first_head_r, group_end_head_r, group_next_r;
    reg [31:0] kv_key_product_r, kv_head_index_r, kv_vector_base_r;
    reg [31:0] score_r, maximum_r, sum_r, weight_r, value_r;
    reg seen_r;
    reg [1:0] update_r;
    reg [31:0] block_r, quant_index_r, amax_r, scale_r, inverse_r;
    reg [31:0] amax_sample_r;
    reg mem_write_r;
    reg [31:0] mem_addr_r, mem_wdata_r, mem_value_r;
    reg [1:0] mem_size_r;
    wire mem_ready, mem_busy, mem_rsp_valid, mem_error;
    wire [31:0] mem_rdata;
    reg [2:0] fp_op_r;
    reg [31:0] fp_a_r, fp_b_r, fp_value_r;
    wire fp_busy, fp_done, fp_error;
    wire [31:0] fp_result;
    integer cfg_write_index, i, j;
    reg [63:0] span_base[0:6];
    reg [63:0] span_nkv_r, span_size_r[0:6], span_end_r[0:6];
    reg [63:0] span_nkv_early_r, span_product_lo_r;
    reg [31:0] span_product_hi_r;
    reg spans_invalid;
    reg [2:0] decoded_group;
    wire head_pair_invalid = decoded_group == 3'd0;
    wire ctrl_write = reg_wr_en && reg_wr_addr == 8'h04 && reg_wr_strb[0];
    wire cache_invalidate = !busy && ctrl_write && reg_wr_data[0];
    wire busy_mutation = busy && reg_wr_en &&
        ((cfg_write_index >= 0 && |reg_wr_strb) || (ctrl_write && |reg_wr_data[2:0]));
    // group_r is Hq/Hkv; head_r is an absolute query-head index. kv_group_r
    // changes only after the whole current group's output has been normalized.
    wire [31:0] kv_index = kv_vector_base_r + dim_r;
    // Head-entry states isolate the multiplier from the local array index.
    wire [31:0] output_index = head_base_r + dim_r;
    wire [31:0] quant_offset = block_r * 32 + quant_index_r;
    // Dùng chung một cổng đọc tổ hợp cho AMAX và lượng tử hóa.
    wire [31:0] output_read_addr = (state_r == S_QUANT_BLOCK) ? block_r * 32 :
        ((state_r == S_AMAX) && (quant_index_r != 31)) ? quant_offset + 32'd1 : quant_offset;
    wire [31:0] output_read_data = output_r[output_read_addr];

    function [31:0] merge_bytes;
        input [31:0] old_word, new_word;
        input [3:0] strobe;
        integer k;
        begin
            merge_bytes = old_word;
            for (k=0; k<4; k=k+1)
                if (strobe[k]) merge_bytes[8*k +: 8] = new_word[8*k +: 8];
        end
    endfunction
    function fp_greater;
        input [31:0] x,y;
        begin
            if (x[30:0]==0 && y[30:0]==0) fp_greater=0;
            else if (x[31]!=y[31]) fp_greater=!x[31];
            else fp_greater=x[31] ? x[30:0]<y[30:0] : x[30:0]>y[30:0];
        end
    endfunction
    function [31:0] half_to_float;
        input [15:0] h;
        reg [10:0] mantissa;
        integer exponent, k;
        begin
            mantissa={h[14:10]!=0,h[9:0]};
            exponent=(h[14:10]==0) ? -14 : {27'd0,h[14:10]}-15;
            for(k=0;k<10;k=k+1)
                if(!mantissa[10]) begin mantissa=mantissa<<1; exponent=exponent-1; end
            exponent=exponent+127;
            half_to_float=(h[14:0]==0) ? {h[15],31'd0} :
                          {h[15],exponent[7:0],mantissa[9:0],13'd0};
        end
    endfunction
    task memory_command;
        input write_enable;
        input [31:0] address, data;
        input [1:0] size;
        input [6:0] return_state;
        begin
            mem_write_r <= write_enable;
            mem_addr_r <= address;
            mem_wdata_r <= data;
            mem_size_r <= size;
            mem_return_r <= return_state;
            state_r <= S_MEM_CMD;
        end
    endtask
    task floating_command;
        input [2:0] operation;
        input [31:0] x,y;
        input [6:0] return_state;
        begin
            fp_op_r <= operation;
            fp_a_r <= x;
            fp_b_r <= y;
            fp_return_r <= return_state;
            state_r <= S_FP_CMD;
        end
    endtask
    task fail_command;
        input [31:0] code;
        begin active_error_r <= code; state_r <= S_DRAIN; end
    endtask

    // Only these eight full-width (Hq,Hkv) pairs are valid. Decode their
    // constant group sizes without a general divide/remainder validation cone.
    // Exact 64-bit matching also rejects high-bit aliases of small head counts.
    always @* begin
        decoded_group = 3'd0;
        case ({desc_r[C_HQ], desc_r[C_HKV]})
            {32'd1, 32'd1}: decoded_group = 3'd1;
            {32'd2, 32'd1}: decoded_group = 3'd2;
            {32'd2, 32'd2}: decoded_group = 3'd1;
            {32'd3, 32'd1}: decoded_group = 3'd3;
            {32'd3, 32'd3}: decoded_group = 3'd1;
            {32'd4, 32'd1}: decoded_group = 3'd4;
            {32'd4, 32'd2}: decoded_group = 3'd2;
            {32'd4, 32'd4}: decoded_group = 3'd1;
            default: decoded_group = 3'd0;
        endcase
    end

    always @* begin
        cfg_write_index=-1;
        case(reg_wr_addr)
            8'h10:cfg_write_index=C_TAG; 8'h18:cfg_write_index=C_D;
            8'h1c:cfg_write_index=C_HQ; 8'h20:cfg_write_index=C_HKV;
            8'h24:cfg_write_index=C_N; 8'h28:cfg_write_index=C_Q;
            8'h2c:cfg_write_index=C_K; 8'h30:cfg_write_index=C_V;
            8'h34:cfg_write_index=C_MASK; 8'h38:cfg_write_index=C_OUT;
            8'h3c:cfg_write_index=C_Q8; 8'h40:cfg_write_index=C_SCALE;
            8'h44:cfg_write_index=C_GEN;
            default:cfg_write_index=-1;
        endcase
        reg_rd_data=0;
        case(reg_rd_addr)
            8'h00:reg_rd_data=32'h41540101;
            8'h08:reg_rd_data={28'd0,retained_valid_r,(error_code_r!=0),done_r,busy};
            8'h0c:reg_rd_data=error_code_r;
            8'h10:reg_rd_data=cfg_r[C_TAG]; 8'h14:reg_rd_data=done_tag_r;
            8'h18:reg_rd_data=cfg_r[C_D]; 8'h1c:reg_rd_data=cfg_r[C_HQ];
            8'h20:reg_rd_data=cfg_r[C_HKV]; 8'h24:reg_rd_data=cfg_r[C_N];
            8'h28:reg_rd_data=cfg_r[C_Q]; 8'h2c:reg_rd_data=cfg_r[C_K];
            8'h30:reg_rd_data=cfg_r[C_V]; 8'h34:reg_rd_data=cfg_r[C_MASK];
            8'h38:reg_rd_data=cfg_r[C_OUT]; 8'h3c:reg_rd_data=cfg_r[C_Q8];
            8'h40:reg_rd_data=cfg_r[C_SCALE]; 8'h44:reg_rd_data=cfg_r[C_GEN];
            8'h48:reg_rd_data=done_gen_r; 8'h4c:reg_rd_data=1;
            default:reg_rd_data=0;
        endcase
        span_base[0]={32'd0,desc_r[C_Q]}; span_base[1]={32'd0,desc_r[C_K]};
        span_base[2]={32'd0,desc_r[C_V]}; span_base[3]={32'd0,desc_r[C_MASK]};
        span_base[4]={32'd0,desc_r[C_OUT]}; span_base[5]={32'd0,desc_r[C_Q8]};
        span_base[6]={32'd0,desc_r[C_SCALE]};
        spans_invalid=0;
        for(i=0;i<7;i=i+1) begin
            if(span_base[i]<64'h70000000 || span_end_r[i]>64'h80000000 ||
               span_end_r[i]<=span_base[i]) spans_invalid=1;
        end
        // Inputs may alias each other. No output may alias another output/input.
        for(i=4;i<7;i=i+1)
            for(j=0;j<7;j=j+1)
                if(i!=j && span_base[i]<span_end_r[j] && span_base[j]<span_end_r[i])
                    spans_invalid=1;
        if(|desc_r[C_Q][1:0] || |desc_r[C_OUT][1:0] ||
           desc_r[C_K][0] || desc_r[C_V][0] || desc_r[C_SCALE][0]) spans_invalid=1;
    end

    Attention_FP32 u_fp (.clk(clk),.resetn(resetn),.start(state_r==S_FP_CMD),
        .op(fp_op_r),.a(fp_a_r),.b(fp_b_r),.busy(fp_busy),.done(fp_done),
        .result(fp_result),.error(fp_error));
    Attention_AXI_Master u_master (.clk(clk),.resetn(resetn),
        .cache_invalidate(cache_invalidate),
        .cmd_valid(state_r==S_MEM_CMD),.cmd_ready(mem_ready),.cmd_write(mem_write_r),
        .cmd_addr(mem_addr_r),.cmd_wdata(mem_wdata_r),.cmd_size(mem_size_r),
        .busy(mem_busy),.rsp_valid(mem_rsp_valid),.rsp_ready(1'b1),
        .rsp_rdata(mem_rdata),.rsp_error(mem_error),
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

    integer reset_index;
    always @(posedge clk) begin
        if(!resetn) begin
            state_r<=S_IDLE; mem_return_r<=S_IDLE; fp_return_r<=S_IDLE;
            for(reset_index=0;reset_index<13;reset_index=reset_index+1) begin
                cfg_r[reset_index]<=0; desc_r[reset_index]<=0;
            end
            for(reset_index=0;reset_index<4;reset_index=reset_index+1) begin
                head_maximum_r[reset_index]<=0; head_sum_r[reset_index]<=0;
                head_seen_r[reset_index]<=0;
            end
            span_nkv_r<=64'd0;
            span_nkv_early_r<=64'd0;
            span_product_lo_r<=64'd0;
            span_product_hi_r<=32'd0;
            for(reset_index=0;reset_index<7;reset_index=reset_index+1) begin
                span_size_r[reset_index]<=64'd0;
                span_end_r[reset_index]<=64'd0;
            end
            done_r<=0; retained_valid_r<=0; error_code_r<=0; active_error_r<=0;
            done_tag_r<=0; done_gen_r<=0;
            head_r<=0; key_r<=0; dim_r<=0; group_r<=1; total_r<=0; kv_group_r<=0;
            group_first_head_r<=0; group_end_head_r<=0; group_next_r<=0;
            head_base_r<=0;
            kv_key_product_r<=0; kv_head_index_r<=0; kv_vector_base_r<=0;
            score_r<=0; maximum_r<=0; sum_r<=0; weight_r<=0; value_r<=0;
            seen_r<=0; update_r<=UPDATE_FIRST; block_r<=0; quant_index_r<=0;
            amax_r<=0; scale_r<=0; inverse_r<=0; amax_sample_r<=0;
            mem_write_r<=0; mem_addr_r<=0; mem_wdata_r<=0; mem_value_r<=0; mem_size_r<=0;
            fp_op_r<=0; fp_a_r<=0; fp_b_r<=0; fp_value_r<=0;
        end else begin
            if(!busy && reg_wr_en && cfg_write_index>=0)
                cfg_r[cfg_write_index]<=merge_bytes(cfg_r[cfg_write_index],reg_wr_data,reg_wr_strb);
            if(busy_mutation) begin
                active_error_r<=2;
                state_r<=S_DRAIN;
            end else case(state_r)
                S_IDLE: if(ctrl_write) begin
                    if(reg_wr_data[1]) begin done_r<=0; error_code_r<=0; end
                    if(reg_wr_data[2]) retained_valid_r<=0;
                    if(reg_wr_data[0]) begin
                        span_nkv_early_r<={32'd0,cfg_r[C_N]}*{32'd0,cfg_r[C_HKV]};
                        for(reset_index=0;reset_index<13;reset_index=reset_index+1)
                            desc_r[reset_index]<=cfg_r[reset_index];
                        for(reset_index=0;reset_index<4;reset_index=reset_index+1) begin
                            head_maximum_r[reset_index]<=0; head_sum_r[reset_index]<=0;
                            head_seen_r[reset_index]<=0;
                        end
                        done_r<=0; error_code_r<=0; active_error_r<=0;
                        retained_valid_r<=0;
                        state_r<=S_VALIDATE;
                    end
                end
                S_VALIDATE: begin
                    if(desc_r[C_D]==0 || desc_r[C_D]>256 || |desc_r[C_D][4:0] ||
                       head_pair_invalid ||
                       desc_r[C_N]==0 || desc_r[C_N]>32768) fail_command(1);
                    else begin
                        group_r<={29'd0,decoded_group};
                        total_r<=desc_r[C_HQ]*desc_r[C_D];
                        span_nkv_r<={32'd0,desc_r[C_N]}*{32'd0,desc_r[C_HKV]};
                        // Recombine low/high 32-bit products modulo 64 bits;
                        // high-product bits above bit 31 are discarded as before.
                        span_product_lo_r<={32'd0,span_nkv_early_r[31:0]}*{32'd0,desc_r[C_D]};
                        span_product_hi_r<=span_nkv_early_r[63:32]*desc_r[C_D];
                        state_r<=S_SPAN_SIZE;
                    end
                end
                S_SPAN_SIZE: begin
                    // S_VALIDATE has accepted the full-width shape. total_r
                    // is at most 1024; extend before every byte-size operation.
                    span_size_r[0]<={32'd0,total_r}*64'd4;
                    span_size_r[1]<=(span_product_lo_r+{span_product_hi_r,32'd0})<<1;
                    span_size_r[2]<=(span_product_lo_r+{span_product_hi_r,32'd0})<<1;
                    span_size_r[3]<={32'd0,desc_r[C_N]};
                    span_size_r[4]<={32'd0,total_r}*64'd4;
                    span_size_r[5]<={32'd0,total_r};
                    span_size_r[6]<=({32'd0,total_r}>>5)*64'd2;
                    state_r<=S_SPAN_END;
                end
                S_SPAN_END: begin
                    for(reset_index=0;reset_index<7;reset_index=reset_index+1)
                        span_end_r[reset_index]<=span_base[reset_index]+span_size_r[reset_index];
                    state_r<=S_SPANS;
                end
                S_SPANS: if(spans_invalid) fail_command(1);
                    else begin head_r<=0; state_r<=S_Q_HEAD; end
                S_Q_HEAD: begin
                    head_base_r<=head_r*desc_r[C_D];
                    dim_r<=0;
                    state_r<=S_Q_REQ;
                end
                S_Q_REQ: memory_command(0,desc_r[C_Q]+(output_index<<2),0,2,S_Q_GOT);
                S_Q_GOT: begin
                    if(mem_value_r[30:23]==8'hff) fail_command(4);
                    else begin
                        q_r[output_index]<=mem_value_r;
                        if(dim_r+1==desc_r[C_D]) begin
                            if(head_r+1==desc_r[C_HQ]) begin
                                kv_group_r<=0; state_r<=S_GROUP_BEGIN;
                            end else begin head_r<=head_r+1; state_r<=S_Q_HEAD; end
                        end
                        else begin dim_r<=dim_r+1; state_r<=S_Q_REQ; end
                    end
                end
                S_GROUP_BEGIN: begin
                    group_first_head_r<=kv_group_r*group_r;
                    group_next_r<=kv_group_r+1;
                    key_r<=0; dim_r<=0;
                    state_r<=S_MASK_REQ;
                end
                S_MASK_REQ: begin
                    group_end_head_r<=group_next_r*group_r;
                    memory_command(0,desc_r[C_MASK]+key_r,0,0,S_MASK_GOT);
                end
                S_MASK_GOT: begin
                    if(mem_value_r>1) fail_command(4);
                    else if(mem_value_r==0) state_r<=S_KEY_NEXT;
                    else begin
                        dim_r<=0;
                        kv_key_product_r<=key_r*desc_r[C_HKV];
                        state_r<=S_KV_HEAD;
                    end
                end
                // Register each operation once per visible key; K and V reuse
                // the vector base while only the dimension index advances.
                S_KV_HEAD: begin
                    head_r<=group_first_head_r;
                    kv_head_index_r<=kv_key_product_r+kv_group_r;
                    state_r<=S_KV_BASE;
                end
                S_KV_BASE: begin
                    kv_vector_base_r<=kv_head_index_r*desc_r[C_D];
                    state_r<=S_K_REQ;
                end
                S_K_REQ: memory_command(0,desc_r[C_K]+(kv_index<<1),0,1,S_K_GOT);
                S_K_GOT: begin
                    if(mem_value_r[14:10]==5'h1f) fail_command(4);
                    else begin
                        k_vector_r[dim_r]<=half_to_float(mem_value_r[15:0]);
                        if(dim_r+1==desc_r[C_D]) begin dim_r<=0; state_r<=S_V_LOAD_REQ; end
                        else begin dim_r<=dim_r+1; state_r<=S_K_REQ; end
                    end
                end
                S_V_LOAD_REQ: memory_command(0,desc_r[C_V]+(kv_index<<1),0,1,S_V_LOAD_GOT);
                S_V_LOAD_GOT: begin
                    if(mem_value_r[14:10]==5'h1f) fail_command(4);
                    else begin
                        v_vector_r[dim_r]<=half_to_float(mem_value_r[15:0]);
                        if(dim_r+1==desc_r[C_D]) begin
                            head_r<=group_first_head_r; state_r<=S_HEAD_RESTORE;
                        end else begin dim_r<=dim_r+1; state_r<=S_V_LOAD_REQ; end
                    end
                end
                S_HEAD_RESTORE: begin
                    head_base_r<=head_r*desc_r[C_D];
                    maximum_r<=head_maximum_r[head_r]; sum_r<=head_sum_r[head_r];
                    seen_r<=head_seen_r[head_r]; score_r<=0; dim_r<=0;
                    state_r<=S_DOT_REQ;
                end
                S_DOT_REQ: floating_command(1,q_r[output_index],k_vector_r[dim_r],S_DOT_MUL);
                S_DOT_MUL: floating_command(0,score_r,fp_value_r,S_DOT_ADD);
                S_DOT_ADD: begin
                    score_r<=fp_value_r;
                    if(dim_r+1==desc_r[C_D]) state_r<=S_SCORE;
                    else begin dim_r<=dim_r+1; state_r<=S_DOT_REQ; end
                end
                S_SCORE: begin
                    dim_r<=0;
                    if(!seen_r) begin
                        seen_r<=1; maximum_r<=score_r; sum_r<=32'h3f800000;
                        update_r<=UPDATE_FIRST; state_r<=S_V_REQ;
                    end else if(fp_greater(score_r,maximum_r)) begin
                        maximum_r<=score_r; update_r<=UPDATE_RESCALE;
                        floating_command(0,maximum_r,{!score_r[31],score_r[30:0]},S_WEIGHT_EXP);
                    end else begin
                        update_r<=UPDATE_ADD;
                        floating_command(0,score_r,{!maximum_r[31],maximum_r[30:0]},S_WEIGHT_EXP);
                    end
                end
                S_WEIGHT_EXP: floating_command(3,fp_value_r,0,S_WEIGHT_GOT);
                S_WEIGHT_GOT: begin
                    weight_r<=fp_value_r;
                    if(update_r==UPDATE_RESCALE)
                        floating_command(1,sum_r,fp_value_r,S_SUM_MUL);
                    else floating_command(0,sum_r,fp_value_r,S_SUM_GOT);
                end
                S_SUM_MUL: floating_command(0,fp_value_r,32'h3f800000,S_SUM_GOT);
                S_SUM_GOT: begin sum_r<=fp_value_r; state_r<=S_V_REQ; end
                S_V_REQ: begin
                    value_r<=v_vector_r[dim_r];
                    if(update_r==UPDATE_FIRST) begin
                        accum_r[output_index]<=v_vector_r[dim_r];
                        state_r<=S_V_NEXT;
                    end else if(update_r==UPDATE_RESCALE)
                        floating_command(1,accum_r[output_index],weight_r,S_V_MUL);
                    else floating_command(1,v_vector_r[dim_r],weight_r,S_V_MUL);
                end
                S_V_MUL: floating_command(0,fp_value_r,
                    update_r==UPDATE_RESCALE ? value_r : accum_r[output_index],S_V_ADD);
                S_V_ADD: begin accum_r[output_index]<=fp_value_r; state_r<=S_V_NEXT; end
                S_V_NEXT: begin
                    if(dim_r+1==desc_r[C_D]) state_r<=S_HEAD_SAVE;
                    else begin dim_r<=dim_r+1; state_r<=S_V_REQ; end
                end
                S_HEAD_SAVE: begin
                    head_maximum_r[head_r]<=maximum_r; head_sum_r[head_r]<=sum_r;
                    head_seen_r[head_r]<=seen_r;
                    if(head_r+1==group_end_head_r) state_r<=S_KEY_NEXT;
                    else begin head_r<=head_r+1; state_r<=S_HEAD_RESTORE; end
                end
                S_KEY_NEXT: begin
                    if(key_r+1==desc_r[C_N]) begin
                        // Every head shares this mask and completes each visible
                        // key before key_r advances, so the first record proves
                        // the whole group has a valid nonempty history.
                        if(!head_seen_r[group_first_head_r]) fail_command(6);
                        else begin head_r<=group_first_head_r; dim_r<=0; state_r<=S_NORM_HEAD; end
                    end else begin key_r<=key_r+1; state_r<=S_MASK_REQ; end
                end
                S_NORM_HEAD: begin
                    head_base_r<=head_r*desc_r[C_D];
                    sum_r<=head_sum_r[head_r];
                    state_r<=S_NORM_REQ;
                end
                S_NORM_REQ: floating_command(2,accum_r[output_index],sum_r,S_NORM_GOT);
                S_NORM_GOT: begin
                    output_r[output_index]<=fp_value_r;
                    memory_command(1,desc_r[C_OUT]+(output_index<<2),fp_value_r,2,S_NORM_WROTE);
                end
                S_NORM_WROTE: begin
                    if(dim_r+1==desc_r[C_D]) begin
                        dim_r<=0;
                        if(head_r+1==group_end_head_r) begin
                            if(kv_group_r+1==desc_r[C_HKV]) begin block_r<=0; state_r<=S_QUANT_BLOCK; end
                            else begin kv_group_r<=kv_group_r+1; state_r<=S_GROUP_BEGIN; end
                        end else begin head_r<=head_r+1; state_r<=S_NORM_HEAD; end
                    end else begin dim_r<=dim_r+1; state_r<=S_NORM_REQ; end
                end
                S_QUANT_BLOCK: begin
                    amax_r<=0; quant_index_r<=0;
                    // Đọc trước lane 0 để tách đường RAM khỏi so sánh AMAX.
                    amax_sample_r<=output_read_data;
                    state_r<=S_AMAX;
                end
                S_AMAX: begin
                    if(amax_sample_r[30:0]>amax_r[30:0])
                        amax_r<={1'b0,amax_sample_r[30:0]};
                    if(quant_index_r==31) begin
                        quant_index_r<=0;
                        // Include the final lane in the reduction before division.
                        if((amax_sample_r[30:0]==31'd0) && (amax_r[30:0]==31'd0)) begin
                            inverse_r<=0;
                            memory_command(1,desc_r[C_SCALE]+(block_r<<1),0,1,S_SCALE_WROTE);
                        end else floating_command(2,
                            amax_sample_r[30:0]>amax_r[30:0] ?
                            {1'b0,amax_sample_r[30:0]} : amax_r,
                            32'h42fe0000,S_SCALE_GOT);
                    end else begin
                        quant_index_r<=quant_index_r+1;
                        amax_sample_r<=output_read_data;
                    end
                end
                S_SCALE_GOT: begin
                    scale_r<=fp_value_r;
                    // ARM quantization branches on d, including finite underflow
                    // of a nonzero amax/127; its specified reciprocal is then 0.
                    if(fp_value_r[30:0]==0) begin
                        inverse_r<=0;
                        memory_command(1,desc_r[C_SCALE]+(block_r<<1),0,1,S_SCALE_WROTE);
                    end else floating_command(2,32'h3f800000,fp_value_r,S_ID_GOT);
                end
                S_ID_GOT: begin
                    inverse_r<=fp_value_r;
                    floating_command(4,scale_r,0,S_HALF_GOT);
                end
                S_HALF_GOT: begin
                    memory_command(1,desc_r[C_SCALE]+(block_r<<1),fp_value_r,1,S_SCALE_WROTE);
                end
                S_SCALE_WROTE: state_r<=S_QUANT_VALUE;
                S_QUANT_VALUE: begin
                    if(inverse_r==0) memory_command(1,desc_r[C_Q8]+quant_offset,0,0,S_QUANT_WROTE);
                    else floating_command(1,output_read_data,inverse_r,S_QUANT_MUL);
                end
                S_QUANT_MUL: floating_command(5,fp_value_r,0,S_QUANT_INT);
                S_QUANT_INT: begin
                    if($signed(fp_value_r)<-127 || $signed(fp_value_r)>127) fail_command(7);
                    else memory_command(1,desc_r[C_Q8]+quant_offset,fp_value_r,0,S_QUANT_WROTE);
                end
                S_QUANT_WROTE: begin
                    if(quant_index_r==31) begin
                        if((block_r+1)*32==total_r) state_r<=S_FINISH;
                        else begin block_r<=block_r+1; state_r<=S_QUANT_BLOCK; end
                    end else begin quant_index_r<=quant_index_r+1; state_r<=S_QUANT_VALUE; end
                end
                S_MEM_CMD: if(mem_ready) state_r<=S_MEM_WAIT;
                S_MEM_WAIT: if(mem_rsp_valid) begin
                    if(mem_error) fail_command(3);
                    else begin mem_value_r<=mem_rdata; state_r<=mem_return_r; end
                end
                S_FP_CMD: state_r<=S_FP_WAIT;
                S_FP_WAIT: if(fp_done) begin
                    if(fp_error) fail_command(5);
                    else begin fp_value_r<=fp_result; state_r<=fp_return_r; end
                end
                S_DRAIN: if(!mem_busy && !fp_busy) state_r<=S_FINISH;
                S_FINISH: begin
                    done_r<=1; error_code_r<=active_error_r;
                    done_tag_r<=desc_r[C_TAG]; done_gen_r<=desc_r[C_GEN];
                    retained_valid_r<=active_error_r==0;
                    state_r<=S_IDLE;
                end
                default: fail_command(1);
            endcase
        end
    end
endmodule

