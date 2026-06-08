library verilog;
use verilog.vl_types.all;
entity Dual_Port_BRAM is
    generic(
        AWIDTH          : integer := 8;
        DWIDTH          : integer := 128
    );
    port(
        clka            : in     vl_logic;
        ena             : in     vl_logic;
        wea             : in     vl_logic_vector;
        addra           : in     vl_logic_vector;
        dina            : in     vl_logic_vector;
        douta           : out    vl_logic_vector;
        clkb            : in     vl_logic;
        enb             : in     vl_logic;
        web             : in     vl_logic_vector;
        addrb           : in     vl_logic_vector;
        dinb            : in     vl_logic_vector;
        doutb           : out    vl_logic_vector
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of AWIDTH : constant is 2;
    attribute mti_svvh_generic_type of DWIDTH : constant is 2;
end Dual_Port_BRAM;
