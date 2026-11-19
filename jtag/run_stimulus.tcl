# SPDX-License-Identifier: Apache-2.0
# Batch runner: program the KV260 and replay jtag/stimulus.txt over JTAG.
#   vivado -mode batch -source jtag/run_stimulus.tcl -tclargs \
#       [-url host:port] [-program] [-stim file | -no-stim]
source [file dirname [info script]]/pe_jtag.tcl

set url localhost:3121; set program 0
set stim $pe::root/jtag/stimulus.txt
set a $argv
while {[llength $a]} {
    set a [lassign $a o]
    switch -- $o {
        -url     { set a [lassign $a url] }
        -program { set program 1 }
        -stim    { set a [lassign $a stim] }
        -no-stim { set stim "" }
        default  { error "unknown option $o" }
    }
}

if {$program} { pe_connect -url $url -program } else { pe_connect -url $url }
if {$stim eq ""} { exit 0 }
set errs [pe_run_stimulus $stim]
# Only exit in batch mode; in the GUI Tcl console `exit` would close Vivado.
if {[info exists ::rdi::mode] && $::rdi::mode eq "batch"} { exit [expr {$errs ? 1 : 0}] }
