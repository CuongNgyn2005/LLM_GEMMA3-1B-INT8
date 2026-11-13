`ifndef TB_SPU_CONTROLLER_V
`define TB_SPU_CONTROLLER_V
`timescale 1ns/1ps
// Standalone by default; AUTO_FINISH=0 lets tb_AI_IP_top own completion.
module tb_SPU_Controller #(parameter AUTO_FINISH = 1)(output reg completed = 0);
    localparam AXI_DATA_WIDTH = 128;
    localparam WORD_DEPTH = 4096;
    localparam SCALE_ACCUM_ROWS = 256;
    reg tb_clk = 0;
    always #5 if (!completed) tb_clk = ~tb_clk;
    wire clk = tb_clk;
    reg resetn = 0;
    reg start = 0;
    reg clear_done = 0;
    reg soft_reset = 0;
    reg [7:0]                        mode = 0;
    reg [31:0]                       len = 0;
    reg [31:0]                       aux0 = 0;
    reg [31:0]                       aux1 = 0;
    wire busy;
    wire done;
    wire error;
    wire [7:0]                        error_code;
    wire mem_en;
    wire mem_we;
    wire [1:0]                        mem_region;
    wire [31:0]                       mem_index;
    wire [AXI_DATA_WIDTH-1:0]         mem_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0]     mem_wstrb;
    reg [AXI_DATA_WIDTH-1:0]         mem_rdata = 0;
    integer checks = 0;
    SPU_Controller dut (
        .clk(clk),
        .resetn(resetn),
        .start(start),
        .clear_done(clear_done),
        .soft_reset(soft_reset),
        .mode(mode),
        .len(len),
        .aux0(aux0),
        .aux1(aux1),
        .busy(busy),
        .done(done),
        .error(error),
        .error_code(error_code),
        .mem_en(mem_en),
        .mem_we(mem_we),
        .mem_region(mem_region),
        .mem_index(mem_index),
        .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata)
    );
    integer busy_state_checks = 0;
    // Kiem tra sau NBA de so sanh cung trang thai moi tren moi canh clock.
    always @(posedge tb_clk) begin
        #1;
        if ((^dut.state_r) === 1'bx ||
            busy !== ((dut.state_r != dut.S_IDLE) &&
                      (dut.state_r != dut.S_DONE) && (dut.state_r != dut.S_ERROR)))
            $fatal(1, "[TB][FAIL] controller busy/state mismatch state=%0d busy=%b", dut.state_r, busy);
        if ((!resetn || soft_reset) && busy !== 1'b0)
            $fatal(1, "[TB][FAIL] controller busy during reset");
        busy_state_checks = busy_state_checks + 1;
    end
    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            if (condition !== 1'b1) $fatal(1, "[TB][FAIL] tb_SPU_Controller: %0s", message);
            checks = checks + 1;
        end
    endtask
    task reset_dut;
        begin
            @(negedge tb_clk);
            resetn = 0;
            repeat (4) @(negedge tb_clk);
            resetn = 1;
            repeat (2) @(negedge tb_clk);
        end
    endtask
    initial begin
        #100000000;
        if (!completed) $fatal(1, "[TB][FAIL] tb_SPU_Controller: watchdog timeout");
    end
    reg [127:0] input_mem [0:7];
    reg [127:0] output_mem [0:7];
    integer i, writes=0;
    always @(posedge tb_clk) begin
        if(resetn && mem_en) begin
            if(mem_we) begin
                check(mem_region==1 && mem_index<8 && mem_wstrb===16'hffff,"copy write address/strobes");
                output_mem[mem_index]=mem_wdata;
                writes=writes+1;
            end else begin
                check(mem_region==0 && mem_index<8,"copy read address");
                mem_rdata <= input_mem[mem_index];
            end
        end
    end
    task command;
        input [7:0] cmd;
        input [31:0] count;
        integer t;
        begin
            @(negedge tb_clk); clear_done=1;
            @(negedge tb_clk); clear_done=0; mode=cmd; len=count; start=1;
            @(negedge tb_clk); start=0;
            check(busy && !done && !error && dut.state_r == dut.S_DECODE,"busy asserted on command start");
            t=0;
            while(!done && t<200) begin @(negedge tb_clk); t=t+1; end
            check(done,"command completion");
            check(!busy,"busy cleared on success/decode error");
            repeat(2) @(negedge tb_clk);
        end
    endtask
    task restart_terminal;
        input expect_error;
        integer t, writes_before;
        begin
            check(done && !busy && error == expect_error,"terminal state before restart");
            writes_before = writes;
            @(negedge tb_clk);
            clear_done = 1; start = 1; mode = 8'h7f; len = 1;
            @(negedge tb_clk);
            check(busy && !done && !error && error_code == 0 && dut.state_r == dut.S_DECODE,
                  "simultaneous clear_done/start restart wins");
            clear_done = 0; start = 0;
            t = 0;
            while (!done && t < 200) begin @(negedge tb_clk); t = t + 1; end
            check(done && !busy && !error,"restarted command completes");
            repeat (2) @(negedge tb_clk);
            check(writes == writes_before+1 && output_mem[0] === input_mem[0],"restart copy result");
        end
    endtask
    task clear_terminal;
        begin
            check(done && !busy,"terminal state before clear only");
            @(negedge tb_clk); clear_done = 1;
            @(negedge tb_clk); clear_done = 0;
            check(!busy && !done && !error && error_code == 0 && dut.state_r == dut.S_IDLE,
                  "clear_done only returns idle");
        end
    endtask
    task abort_active_copy;
        integer t, writes_before;
        begin
            @(negedge tb_clk); mode = 8'h7f; len = 8; start = 1;
            @(negedge tb_clk); start = 0;
            check(busy && !done,"busy before active abort");
            t = 0;
            while (dut.state_r != dut.S_COPY_WAIT && t < 200) begin
                @(negedge tb_clk); t = t + 1;
            end
            check(t < 200 && busy,"active copy state reached before abort");
            writes_before = writes;
            soft_reset = 1;
            @(negedge tb_clk); soft_reset = 0;
            check(!busy && !done && !error && dut.state_r == dut.S_IDLE,"active soft reset returns idle");
            repeat (40) begin
                @(negedge tb_clk);
                check(!busy && !done && !error && !mem_en && !mem_we && writes == writes_before,
                      "no stale completion or memory command after abort");
            end
        end
    endtask
    initial begin
        reset_dut();
        for(i=0;i<8;i=i+1) input_mem[i]=128'hffff0000_12345678_80000000_00000000+i;
        command(8'h7f,8);
        check(!error && writes==8,"copy completion and write count");
        for(i=0;i<8;i=i+1) check(output_mem[i]===input_mem[i],"copy data");
        command(8'h7f,0); check(error && error_code==2,"zero length");
        command(8'h7f,4097); check(error && error_code==3,"length boundary");
        command(8'hff,1); check(error && error_code==1,"invalid command");
        @(negedge tb_clk); soft_reset=1;
        @(negedge tb_clk); soft_reset=0;
        check(!busy && !done && !error,"soft reset clears status");
        command(8'h7f,1);
        restart_terminal(0);
        clear_terminal();
        command(8'hff,1);
        restart_terminal(1);
        command(8'hff,1);
        clear_terminal();
        abort_active_copy();
        check(busy_state_checks > 0,"busy invariant monitor exercised");
        $display("[METRICS] controller_busy_state_checks=%0d",busy_state_checks);
        completed = 1;
        $display("[TB][PASS] tb_SPU_Controller checks=%0d", checks);
        if (AUTO_FINISH) $finish;
    end
endmodule
`endif
