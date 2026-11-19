# SPDX-License-Identifier: Apache-2.0
# Vivado batch build for Kria KV260 (part xck26-sfvc784-2LVC).
# Usage: vivado -mode batch -source scripts/vivado_build.tcl
set part xck26-sfvc784-2LVC
set top  kria_top

create_project -force pe_kv260 build_vivado -part $part
add_files [glob rtl/*.v]
add_files constraints/kv260.xdc
add_files -norecurse [file normalize program.hex]
set_property top $top [current_fileset]
set_property file_type {Memory File} [get_files [file normalize program.hex]]

synth_design -top $top -flatten_hierarchy none
opt_design
place_design
route_design
report_timing_summary -file build_vivado/timing.rpt
report_utilization   -file build_vivado/util.rpt
write_bitstream -force build_vivado/kria_top.bit

# Optional: add ILA/VIO for JTAG verification (see vitis/)
# source scripts/vivado_add_debug.tcl  # before synth, adds VIO+ILA
puts "BUILD DONE"
