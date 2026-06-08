library verilog;
use verilog.vl_types.all;
entity Matrix_Vector_Multiplication is
    generic(
        NUM_LANES       : integer := 16;
        ACT_WIDTH       : integer := 8;
        WEIGHT_WIDTH    : integer := 8;
        ACC_WIDTH       : integer := 32;
        SCALE_WIDTH     : integer := 16;
        SCALE_FRAC_BITS : integer := 15;
        RESULT_FIFO_DEPTH: integer := 8;
        AXI_DATA_WIDTH  : integer := 128;
        MAX_ROWS        : integer := 128;
        MAX_COL_BEATS   : integer := 256
    );
    port(
        CLK             : in     vl_logic;
        RST             : in     vl_logic;
        ctrl_start      : in     vl_logic;
        ctrl_clear_done : in     vl_logic;
        cfg_rows        : in     vl_logic_vector(15 downto 0);
        cfg_cols        : in     vl_logic_vector(15 downto 0);
        cfg_col_beats   : in     vl_logic_vector(15 downto 0);
        cfg_scale       : in     vl_logic_vector;
        compute_mode    : in     vl_logic_vector(1 downto 0);
        busy            : out    vl_logic;
        done            : out    vl_logic;
        error           : out    vl_logic;
        active_row      : out    vl_logic_vector(15 downto 0);
        active_col_beat : out    vl_logic_vector(15 downto 0);
        mm_wr_en        : in     vl_logic;
        mm_wr_region    : in     vl_logic_vector(1 downto 0);
        mm_wr_index     : in     vl_logic_vector(31 downto 0);
        mm_wr_data      : in     vl_logic_vector;
        mm_wr_strb      : in     vl_logic_vector;
        mm_rd_en        : in     vl_logic;
        mm_rd_region    : in     vl_logic_vector(1 downto 0);
        mm_rd_index     : in     vl_logic_vector(31 downto 0);
        mm_rd_data      : out    vl_logic_vector;
        mm_rd_valid     : out    vl_logic;
        mm_rd_error     : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of NUM_LANES : constant is 1;
    attribute mti_svvh_generic_type of ACT_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of WEIGHT_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of ACC_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of SCALE_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of SCALE_FRAC_BITS : constant is 1;
    attribute mti_svvh_generic_type of RESULT_FIFO_DEPTH : constant is 1;
    attribute mti_svvh_generic_type of AXI_DATA_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of MAX_ROWS : constant is 1;
    attribute mti_svvh_generic_type of MAX_COL_BEATS : constant is 1;
end Matrix_Vector_Multiplication;
