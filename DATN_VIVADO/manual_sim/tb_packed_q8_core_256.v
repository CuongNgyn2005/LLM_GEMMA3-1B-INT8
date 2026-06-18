`timescale 1ns/1ps

module tb_packed_q8_core_256;
    tb_packed_q8_core #(
        .MAX_COL_BEATS(256)
    ) testbench ();
endmodule
