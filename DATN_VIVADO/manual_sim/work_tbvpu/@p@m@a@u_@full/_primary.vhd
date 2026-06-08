library verilog;
use verilog.vl_types.all;
entity PMAU_Full is
    generic(
        NUM_LANES       : integer := 16;
        ACT_WIDTH       : integer := 8;
        WEIGHT_WIDTH    : integer := 8;
        MULT_WIDTH      : vl_notype;
        ACC_WIDTH       : integer := 32;
        SCALE_WIDTH     : integer := 16;
        SCALE_FRAC_BITS : integer := 15;
        RESULT_FIFO_DEPTH: integer := 8
    );
    port(
        CLK             : in     vl_logic;
        RST             : in     vl_logic;
        compute_mode    : in     vl_logic_vector(1 downto 0);
        activation_data : in     vl_logic_vector;
        activation_valid: in     vl_logic;
        activation_ready: out    vl_logic;
        activation_last : in     vl_logic;
        weight_data     : in     vl_logic_vector;
        scale_factor    : in     vl_logic_vector;
        weight_valid    : in     vl_logic;
        weight_ready    : out    vl_logic;
        weight_last     : in     vl_logic;
        scalar_axpy     : in     vl_logic_vector(15 downto 0);
        result_data     : out    vl_logic_vector;
        result_valid    : out    vl_logic;
        result_ready    : in     vl_logic;
        result_last     : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of NUM_LANES : constant is 1;
    attribute mti_svvh_generic_type of ACT_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of WEIGHT_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of MULT_WIDTH : constant is 3;
    attribute mti_svvh_generic_type of ACC_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of SCALE_WIDTH : constant is 1;
    attribute mti_svvh_generic_type of SCALE_FRAC_BITS : constant is 1;
    attribute mti_svvh_generic_type of RESULT_FIFO_DEPTH : constant is 1;
end PMAU_Full;
