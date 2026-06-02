# ============================================================================
# Vivado Tcl Script for VPU Testbench Simulation
# ============================================================================
# 
# Usage in Vivado:
#   1. Open Vivado 2023.2
#   2. File → Create Project
#   3. Set project directory to: TESTBENCH/vivado_proj
#   4. Add sources:
#        - RTL: ../RTL/PMAU_Streaming.v, ../RTL/VPU_Top.v
#        - Testbench: tb_VPU_Top.v (or tb_PMAU_Streaming.v)
#   5. Tools → Run Tcl Script
#   6. Select this file: run_sim.tcl
#
# Or run from command line:
#   vivado -mode batch -source run_sim.tcl -tclargs <testbench_name>
#
# ============================================================================

# Parse command line arguments
set tb_name "tb_VPU_Top"
if {$argc > 0} {
    set tb_name [lindex $argv 0]
}

puts "============================================================================"
puts "VPU RTL Testbench Automation Script"
puts "============================================================================"
puts "Testbench: $tb_name"
puts ""

# ============================================================================
# Create project if it doesn't exist
# ============================================================================

set proj_dir "./vivado_proj"
set proj_name "VPU_TB"

if {![file exists "$proj_dir/$proj_name.xpr"]} {
    puts "\[CREATE\] Creating Vivado project: $proj_name"
    create_project $proj_name $proj_dir -force -part xc7z020clg400-1
    set_property target_language Verilog [current_project]
} else {
    puts "\[OPEN\] Opening existing Vivado project"
    open_project "$proj_dir/$proj_name.xpr"
}

# ============================================================================
# Add source files
# ============================================================================

puts "\[SOURCES\] Adding RTL files..."
add_files -norecurse -force {
    ../RTL/PMAU_Streaming.v
    ../RTL/VPU_Top.v
}

puts "\[SOURCES\] Adding testbench file..."
add_files -norecurse -force -fileset sim_1 "$tb_name.v"

set_property file_type {Verilog} [get_files *.v]
update_compile_order -fileset sim_1

# ============================================================================
# Set simulation options
# ============================================================================

puts "\[CONFIG\] Configuring simulation..."

# Set top module for simulation
set_property top $tb_name [get_filesets sim_1]
set_property top_lib xsim [get_filesets sim_1]

# Simulation time (adjust as needed)
set_property -name {xsim.simulate.runtime} -value {10ms} -objects [get_filesets sim_1]

# Waveform configuration
set_property -name {xsim.elaborate.xvlog.more_options} -value {-m64} -objects [get_filesets sim_1]

puts "\[CONFIG\] Launching behavioral simulation..."

# ============================================================================
# Run simulation
# ============================================================================

# Launch behavioral simulation
launch_simulation -simset sim_1 -mode behavioral

puts ""
puts "============================================================================"
puts "Simulation launched successfully!"
puts "============================================================================"
puts ""
puts "In the Vivado GUI:"
puts "  1. View → Waveform to open Wave window"
puts "  2. Add signals: CLK, RST, FSM states, input/output valid/ready signals"
puts "  3. Run → Run All to execute testbench"
puts "  4. Check console for [PASS]/[FAIL] results"
puts ""
puts "Keyboard shortcuts:"
puts "  Ctrl+F5  - Run All"
puts "  Ctrl+K   - Run Selected"
puts ""
puts "============================================================================"

# Return to normal Tcl prompt
flush stdout
