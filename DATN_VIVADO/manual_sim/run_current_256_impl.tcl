set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ".." ".."]]
set project_dir [file join $script_dir "current_256_impl_project"]
set part_name "xczu7ev-ffvc1156-2-e"

proc report_weight_address_fanout {path label} {
    set fp [open $path "w"]
    puts $fp "Weight address fanout report: $label"
    set source_pins [get_pins -hier -quiet -filter {
        DIRECTION == OUT &&
        (NAME =~ *weight_compute_addr_leaf_reg*/Q ||
         NAME =~ *weight_wr_addr_leaf_reg*/Q ||
         NAME =~ *weight_compute_addr_bank_reg*/Q ||
         NAME =~ *weight_wr_addr_bank_reg*/Q)
    }]
    if {[llength $source_pins] == 0} {
        puts $fp "No weight address source registers matched."
        close $fp
        return
    }
    foreach driver [lsort $source_pins] {
        foreach net [get_nets -quiet -of_objects $driver] {
            set loads [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]
            puts $fp [format "fanout=%4d driver=%s net=%s" \
                [llength $loads] $driver $net]
        }
    }
    close $fp
}

proc report_weight_address_paths {path} {
    set source_pins [get_pins -hier -quiet -filter {
        DIRECTION == OUT &&
        (NAME =~ *weight_compute_addr_leaf_reg*/Q ||
         NAME =~ *weight_wr_addr_leaf_reg*/Q ||
         NAME =~ *weight_compute_addr_bank_reg*/Q ||
         NAME =~ *weight_wr_addr_bank_reg*/Q)
    }]
    set ram_addr_pins [get_pins -hier -quiet -filter {
        REF_NAME == RAMB36E2 &&
        (REF_PIN_NAME =~ ADDRARDADDR* || REF_PIN_NAME =~ ADDRBWRADDR*)
    }]
    if {([llength $source_pins] == 0) || ([llength $ram_addr_pins] == 0)} {
        set fp [open $path "w"]
        puts $fp "No valid weight address timing endpoints matched."
        puts $fp [format "source_pins=%d ram_addr_pins=%d" \
            [llength $source_pins] [llength $ram_addr_pins]]
        close $fp
        return
    }
    report_timing -from $source_pins -to $ram_addr_pins -max_paths 50 \
        -path_type full -file $path
}

create_project current_256_impl $project_dir -part $part_name -force

add_files [file join $repo_root "RTL" "Dual_Port_BRAM.v"]
add_files [file join $repo_root "RTL" "PMAU_Full.v"]
add_files [file join $repo_root "RTL" "Matrix_Vector_Multiplication.v"]
add_files [file join $repo_root "RTL" "AXI4_Mapping.v"]
add_files [file join $repo_root "RTL" "MY_IP.v"]
add_files [file join $repo_root "RTL" "VPU_Top.v"]
add_files [file join $repo_root "DATN_VIVADO" "project_1" "project_1.srcs" "sources_1" "ip" "mult_gen_0" "mult_gen_0.xci"]

generate_target all [get_ips mult_gen_0]
update_compile_order -fileset sources_1

synth_design -top VPU_Top -part $part_name -mode out_of_context -generic {MAX_COL_BEATS=256}
create_clock -period 5.000 -name s00_axi_aclk [get_ports s00_axi_aclk]

report_utilization -file [file join $script_dir "current_256_synth_utilization.rpt"]
report_timing_summary -delay_type min_max -max_paths 50 \
    -file [file join $script_dir "current_256_synth_timing_200mhz.rpt"]
report_weight_address_fanout \
    [file join $script_dir "current_256_synth_weight_address_fanout.rpt"] "post-synthesis"

opt_design
place_design
phys_opt_design
route_design
phys_opt_design

report_utilization -file [file join $script_dir "current_256_impl_utilization.rpt"]
report_timing_summary -delay_type min_max -max_paths 50 \
    -file [file join $script_dir "current_256_impl_timing_200mhz.rpt"]
report_weight_address_fanout \
    [file join $script_dir "current_256_impl_weight_address_fanout.rpt"] "post-route"
report_weight_address_paths \
    [file join $script_dir "current_256_impl_weight_address_paths.rpt"]
write_checkpoint -force [file join $script_dir "current_256_impl_route.dcp"]

close_project
