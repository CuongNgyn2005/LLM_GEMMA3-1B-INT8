/*
 *-----------------------------------------------------------------------------
 * Module      : Dual_Port_BRAM
 * Description : Parameterized true dual-port local RAM wrapper.
 *
 * Dual_Port_BRAM is the reusable local memory primitive for activation,
 * weight-bank, and result storage inside the VPU.  It is not an AXI slave; the
 * upstream AXI and mapping logic has already converted bus transactions into
 * BRAM enable, address, write-data, and byte-enable signals.
 *
 * Functional behavior:
 * - Port A and Port B are independent synchronous ports.  The VPU connects all
 *   instances to the same PL clock.
 * - The BRAM branch keeps byte-granular writes, which preserves AXI WSTRB
 *   behavior and allows GEMV to update a single INT32 result lane inside a
 *   128-bit result word.
 * - The URAM branch is for weight storage.  It uses XPM UltraRAM as simple
 *   dual-port memory: Port A writes full 32-bit weight lanes from AXI, and
 *   Port B is the compute read port.  This matches the real access pattern and
 *   avoids the true-dual-port write-mode template that Vivado maps back to
 *   BRAM.
 * - Reads are synchronous.
 * - OUTPUT_REG optionally adds one registered output stage for timing closure
 *   when a BRAM output drives the GEMV/PMAU pipeline.
 *
 * In the full RTL system, instances of this wrapper hold CPU/DMA-loaded
 * activation and weight data before compute, and store GEMV/PMAU results for
 * CPU/DMA readback.  USE_URAM selects the intended FPGA memory primitive:
 * 0 uses BRAM-style read-first memory, 1 uses URAM-style simple-dual-port
 * UltraRAM for weight storage.
 *-----------------------------------------------------------------------------
 */

`timescale 1ns/1ps

module Dual_Port_BRAM #(
    parameter integer AWIDTH = 8,
    parameter integer DWIDTH = 128,
    parameter integer OUTPUT_REG = 0,
    parameter integer USE_URAM = 0
) (
    input  wire                         clka,
    input  wire                         ena,
    input  wire [(DWIDTH/8)-1:0]        wea,
    input  wire [AWIDTH-1:0]            addra,
    input  wire [DWIDTH-1:0]            dina,
    output wire [DWIDTH-1:0]            douta,

    input  wire                         clkb,
    input  wire                         enb,
    input  wire [(DWIDTH/8)-1:0]        web,
    input  wire [AWIDTH-1:0]            addrb,
    input  wire [DWIDTH-1:0]            dinb,
    output wire [DWIDTH-1:0]            doutb
);

    localparam integer BYTE_COUNT = DWIDTH / 8;
    localparam integer DEPTH      = (1 << AWIDTH);

    generate
        if (USE_URAM != 0) begin : GEN_ULTRA_RAM
            localparam integer URAM_READ_LATENCY = (OUTPUT_REG != 0) ? 2 : 1;

            // Weight writes are generated as complete AXI beats.  Use a single
            // full-word write enable and a simple-dual-port XPM, matching the
            // actual access pattern: AXI writes on Port A, compute reads on
            // Port B.
            wire uram_wea = ena && (&wea);
            assign douta = {DWIDTH{1'b0}};

            xpm_memory_sdpram #(
                .MEMORY_SIZE        (DEPTH * DWIDTH),
                .MEMORY_PRIMITIVE   ("ultra"),
                .CLOCKING_MODE      ("common_clock"),
                .ECC_MODE           ("no_ecc"),
                .MEMORY_INIT_FILE   ("none"),
                .MEMORY_INIT_PARAM  ("0"),
                .USE_MEM_INIT       (0),
                .WAKEUP_TIME        ("disable_sleep"),
                .AUTO_SLEEP_TIME    (0),
                .MESSAGE_CONTROL    (0),
                .USE_EMBEDDED_CONSTRAINT (0),
                .MEMORY_OPTIMIZATION     ("true"),
                .CASCADE_HEIGHT          (0),
                .SIM_ASSERT_CHK          (0),
                .WRITE_PROTECT           (0),
                .WRITE_DATA_WIDTH_A (DWIDTH),
                .BYTE_WRITE_WIDTH_A (DWIDTH),
                .ADDR_WIDTH_A       (AWIDTH),
                .RST_MODE_A         ("SYNC"),
                .READ_DATA_WIDTH_B  (DWIDTH),
                .ADDR_WIDTH_B       (AWIDTH),
                .READ_RESET_VALUE_B ("0"),
                .READ_LATENCY_B     (URAM_READ_LATENCY),
                .WRITE_MODE_B       ("read_first"),
                .RST_MODE_B         ("SYNC")
            ) u_xpm_ultra_ram (
                .sleep          (1'b0),
                .clka           (clka),
                .ena            (ena),
                .wea            (uram_wea),
                .addra          (addra),
                .dina           (dina),
                .injectsbiterra (1'b0),
                .injectdbiterra (1'b0),
                .clkb           (clkb),
                .rstb           (1'b0),
                .enb            (enb),
                .regceb         (1'b1),
                .addrb          (addrb),
                .doutb          (doutb),
                .sbiterrb       (),
                .dbiterrb       ()
            );
        end else begin : GEN_BLOCK_RAM
            (* ram_style = "block" *) reg [DWIDTH-1:0] mem [0:DEPTH-1];
            reg [DWIDTH-1:0] douta_mem;
            reg [DWIDTH-1:0] doutb_mem;

            // BRAM instances keep read-first behavior.  Activation and Result
            // memories rely on ordinary byte-enable BRAM semantics.
            integer byte_i_a;
            always @(posedge clka) begin
                if (ena) begin
                    douta_mem <= mem[addra];
                    for (byte_i_a = 0; byte_i_a < BYTE_COUNT; byte_i_a = byte_i_a + 1) begin
                        if (wea[byte_i_a])
                            mem[addra][8*byte_i_a +: 8] <= dina[8*byte_i_a +: 8];
                    end
                end
            end

            integer byte_i_b;
            always @(posedge clkb) begin
                if (enb) begin
                    doutb_mem <= mem[addrb];
                    for (byte_i_b = 0; byte_i_b < BYTE_COUNT; byte_i_b = byte_i_b + 1) begin
                        if (web[byte_i_b])
                            mem[addrb][8*byte_i_b +: 8] <= dinb[8*byte_i_b +: 8];
                    end
                end
            end

            if (OUTPUT_REG != 0) begin : GEN_OUTPUT_REG
                reg [DWIDTH-1:0] douta_reg;
                reg [DWIDTH-1:0] doutb_reg;

                always @(posedge clka)
                    douta_reg <= douta_mem;

                always @(posedge clkb)
                    doutb_reg <= doutb_mem;

                assign douta = douta_reg;
                assign doutb = doutb_reg;
            end else begin : GEN_NO_OUTPUT_REG
                assign douta = douta_mem;
                assign doutb = doutb_mem;
            end
        end
    endgenerate

endmodule
