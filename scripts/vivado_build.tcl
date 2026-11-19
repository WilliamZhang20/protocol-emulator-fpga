# SPDX-License-Identifier: Apache-2.0
# Vivado build for Kria KV260 (K26 SOM, part xck26-sfvc784-2LV-c).
# Run from the repo root:  vivado -mode batch -source scripts/vivado_build.tcl
# Outputs in build_vivado/out/: kria_top.bit, kria_top.ltx (debug probes,
# needed by the JTAG scripts), kria_top.xsa, timing/utilization reports.
#
# Written for Vivado 2024.2 (K26 parts built in). KV260 board files are
# optional (only used to apply the PS preset).

set part     xck26-sfvc784-2LV-c
set top      kria_top
set pl_mhz   50          ;# = info.yaml clock_hz of the ASIC
set jobs     [expr {[info exists ::env(JOBS)] ? $::env(JOBS) : 8}]
set root     [file normalize [file dirname [info script]]/..]
set out      $root/build_vivado/out

cd $root
create_project -force pe_kv260 build_vivado -part $part

# Board preset if the KV260 board files are installed (Tools > XHub Stores).
set bp [lindex [lsort [get_board_parts -quiet -latest_file_version *kv260_som*]] end]
if {$bp ne ""} {
    puts "INFO: using board part $bp"
    set_property board_part $bp [current_project]
} else {
    puts "WARNING: KV260 board files not found; PS left at defaults (fine for JTAG-loaded bitstreams)"
}

# ---------------------------------------------------------------- sources
add_files [glob rtl/upstream/*.v]
add_files rtl/program_memory_bram.v rtl/pe_host_bridge.v rtl/pe_harness.v rtl/kria_top.v
add_files -norecurse [file normalize program.hex]
set_property file_type {Memory Initialization Files} [get_files [file normalize program.hex]]
add_files -fileset constrs_1 constraints/kv260.xdc
set_property top $top [current_fileset]

# ---------------------------------------------------------------- PS block design (clock only)
create_bd_design ps
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps_e]
if {$bp ne ""} {
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
}
set_property -dict [list \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl_mhz \
    CONFIG.PSU__USE__M_AXI_GP0 {0} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
] $ps
# make_bd_pins_external copies the pin's FREQ_HZ (actual ~49.9995 MHz), so the
# port and pin cannot disagree at validation.
make_bd_pins_external [get_bd_pins ps_e/pl_clk0]
set_property name pl_clk0 [get_bd_ports -of_objects [get_bd_nets -of_objects [get_bd_pins ps_e/pl_clk0]]]
validate_bd_design
save_bd_design
set bd_file [get_files ps.bd]
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]

# ---------------------------------------------------------------- JTAG debug IP
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_host
# Inputs: uo_out uio_in uio_out uio_oe | bridge rd_data rd_valid q_level r_level status | pad_in
# Outputs: ui_in reset | bridge en drain loop wr_data wr_count wr_tog rd_count rd_tog | fan duty | bridge hold
set vio_in  {8 8 8 8 128 4 13 13 8 8}
set vio_out {8 1 1 2 32 128 5 1 4 1 4 1}
set vio_init {0x00 0x0 0x0 0x0 0x00000000 0x0 0x00 0x0 0x0 0x0 0x9 0x0}
set cfg [list CONFIG.C_NUM_PROBE_IN [llength $vio_in] CONFIG.C_NUM_PROBE_OUT [llength $vio_out] \
             CONFIG.C_EN_PROBE_IN_ACTIVITY {0}]
for {set i 0} {$i < [llength $vio_in]} {incr i} {
    lappend cfg CONFIG.C_PROBE_IN${i}_WIDTH [lindex $vio_in $i]
}
for {set i 0} {$i < [llength $vio_out]} {incr i} {
    lappend cfg CONFIG.C_PROBE_OUT${i}_WIDTH [lindex $vio_out $i] \
                CONFIG.C_PROBE_OUT${i}_INIT_VAL [lindex $vio_init $i]
}
set_property -dict $cfg [get_ips vio_host]

create_ip -name ila -vendor xilinx.com -library ip -module_name ila_host
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {6} \
    CONFIG.C_PROBE0_WIDTH {8} CONFIG.C_PROBE1_WIDTH {8} CONFIG.C_PROBE2_WIDTH {8} \
    CONFIG.C_PROBE3_WIDTH {8} CONFIG.C_PROBE4_WIDTH {8} CONFIG.C_PROBE5_WIDTH {1} \
    CONFIG.C_DATA_DEPTH {8192} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.ALL_PROBE_SAME_MU {true} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
] [get_ips ila_host]
generate_target all [get_ips {vio_host ila_host}]

# ---------------------------------------------------------------- build
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed, see build_vivado/pe_kv260.runs/impl_1/runme.log"
}

open_run impl_1
file mkdir $out
report_timing_summary -file $out/timing.rpt
report_utilization    -file $out/util.rpt
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force $impl_dir/$top.bit $out/$top.bit
write_debug_probes -force $out/$top.ltx
write_hw_platform -fixed -include_bit -force $out/$top.xsa

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "TIMING: WNS=$wns ns  WHS=$whs ns  at $pl_mhz MHz"
if {$wns < 0 || $whs < 0} {
    error "timing NOT met at $pl_mhz MHz -- the FPGA would not behave like the ASIC; see $out/timing.rpt"
}
puts "BUILD DONE: $out/$top.bit + $top.ltx"
