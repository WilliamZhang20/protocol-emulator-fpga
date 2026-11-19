# SPDX-License-Identifier: Apache-2.0
# tclsh tools/cosim/run.tcl <to_sim_pipe> <from_sim_pipe> [program ...]
# Runs the board's own runner (jtag/pe_jtag.tcl) against tb_vio_server.
set here [file dirname [info script]]
source [file join $here .. .. jtag pe_jtag.tcl]
source [file join $here vio_mock.tcl]
lassign $argv to from
set progs [lrange $argv 2 end]
mock::open_pipes $to $from
pe_connect_cosim

# raw host link first: the original smoke stimulus
set fails [pe_run_stimulus [file join $pe::root jtag stimulus.txt]]

if {[llength $progs] == 0} {
    incr fails [pe_run_all]
} else {
    foreach p $progs { incr fails [pe_run_program $p] }
}
puts "cosim: $mock::commits VIO commits, $mock::refreshes refreshes"
puts [expr {$fails ? "COSIM FAIL" : "COSIM PASS"}]
mock::xfer Q
exit [expr {$fails ? 1 : 0}]
