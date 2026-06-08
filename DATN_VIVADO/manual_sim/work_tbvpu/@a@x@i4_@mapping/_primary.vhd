library verilog;
use verilog.vl_types.all;
entity AXI4_Mapping is
    generic(
        AXI_DATA_WIDTH  : integer := 128;
        AXI_ADDR_WIDTH  : integer := 40;
        VPU_BASE_ADDR   : vl_logic_vector;
        ENABLE_BASE_TRANSLATION: integer := 1;
        NUM_LANES       : integer := 16;
        ACT_WIDTH       : integer := 8;
        WEIGHT_WIDTH    : integer := 8;
        ACC_WIDTH       : integer := 32;
        SCALE_WIDTH     : integer := 16;
        SCALE_FRAC_BITS : integer := 15;
        RESULT_FIFO_DEPTH: integer := 8;
        MAX_ROWS        : integer := 128;
        MAX_COL_BEATS   : integer := 256
    );
    port(
        clk             : in     vl_logic;
        resetn          : in     vl_logic;
        map_wr_en       : in     vl_logic;
        map_wr_addr     : in     vl_logic_vector;
        map_wr_data     : in     vl_logic_vector;
        map_wr_strb     : in     vl_logic_vector;
        map_rd_en       : in     vl_logic;
        map_rd_addr     : in     vl_logic_vector;
        map_rd_data     : out    vl_logic_vector;
        map_rd_valid    : out    vl_logic;
        map_rd_error    : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of AXI_DATA_WIDTH : constant is 2;
    attribute mti_svvh_generic_type of AXI_ADDR_WIDTH : constant is 2;
    attribute mti_svvh_generic_type of VPU_BASE_ADDR : constant is 4;
    attribute mti_svvh_generic_type of ENABLE_BASE_TRANSLATION : constant is 2;
    attribute mti_svvh_generic_type of NUM_LANES : constant is 2;
    attribute mti_svvh_generic_type of ACT_WIDTH : constant is 2;
    attribute mti_svvh_generic_type of WEIGHT_WIDTH : constant is 2;
    attribute mti_svvh_generic_type of ACC_WIDTH : constant is 2;
    attribute mti_svvh_generic_type of SCALE_WIDTH : constant is 2;
    attribute mti_svvh_generic_type of SCALE_FRAC_BITS : constant is 2;
    attribute mti_svvh_generic_type of RESULT_FIFO_DEPTH : constant is 2;
    attribute mti_svvh_generic_type of MAX_ROWS : constant is 2;
    attribute mti_svvh_generic_type of MAX_COL_BEATS : constant is 2;
end AXI4_Mapping;
