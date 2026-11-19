# SPDX-License-Identifier: Apache-2.0
# Stand-ins for the Vivado hardware-manager commands jtag/pe_jtag.tcl uses,
# backed by tools/cosim/tb_vio_server.sv over named pipes. Lets plain tclsh
# run the board's test runner against the RTL:
#   tclsh tools/cosim/run.tcl <to_sim_pipe> <from_sim_pipe> [program ...]

namespace eval mock {
    variable to ""; variable from ""
    # role -> {probe name, width, direction}
    variable probes {
        vio_ui_in 8 out   vio_reset 1 out   vio_br_en 1 out   vio_drain 2 out   vio_loop 32 out
        vio_wr_data 128 out   vio_wr_count 5 out   vio_wr_tog 1 out   vio_rd_count 4 out
        vio_rd_tog 1 out   vio_fan 4 out   vio_hold 1 out
        uo_out 8 in   uio_in 8 in   uio_out 8 in   uio_oe 8 in   br_rd_data 128 in
        br_rd_valid 4 in   br_q_level 13 in   br_r_level 13 in   br_status 8 in   pad_in 8 in
    }
    variable outs {vio_ui_in vio_reset vio_br_en vio_drain vio_loop vio_wr_data vio_wr_count
                   vio_wr_tog vio_rd_count vio_rd_tog vio_fan vio_hold}
    variable ins  {uo_out uio_in uio_out uio_oe br_rd_data br_rd_valid br_q_level br_r_level
                   br_status pad_in}
    variable value; array set value {}
    variable width; array set width {}
    variable type;  array set type {}
    foreach {n w d} $probes {
        set width($n) $w; set type($n) vio_$d
        set value($n) [string repeat 0 [expr {($w + 3) / 4}]]
    }
    set value(vio_fan) 9
    variable commits 0; variable refreshes 0
}

proc mock::open_pipes {to from} {
    set mock::to [open $to w]
    fconfigure $mock::to -buffering line
    set mock::from [open $from r]
}
proc mock::xfer {line} {
    puts $mock::to $line
    return [gets $mock::from]
}

proc get_hw_probes {args} {
    set filter ""
    if {[set i [lsearch $args -filter]] >= 0} { set filter [lindex $args [expr {$i + 1}]] }
    set out {}
    foreach {n w d} $mock::probes {
        if {$filter eq "" || [string match "*vio_$d*" $filter]} { lappend out $n }
    }
    return $out
}
proc get_property {prop obj} {
    switch -- $prop {
        NAME         { return $obj }
        WIDTH        { return $mock::width($obj) }
        TYPE         { return $mock::type($obj) }
        OUTPUT_VALUE - INPUT_VALUE { return $mock::value($obj) }
        default      { error "mock get_property: $prop" }
    }
}
proc set_property {prop val obj} {
    switch -- $prop {
        OUTPUT_VALUE {
            set digits [expr {($mock::width($obj) + 3) / 4}]
            if {[string length $val] != $digits} {
                error "Designutils 20-1474: probe $obj value '$val' has [string length $val] digits, needs $digits"
            }
            set mock::value($obj) $val
        }
        OUTPUT_VALUE_RADIX - INPUT_VALUE_RADIX {}
        default { error "mock set_property: $prop" }
    }
}
proc commit_hw_vio {args} {
    incr mock::commits
    set line "W"
    foreach n $mock::outs { append line " $mock::value($n)" }
    set r [mock::xfer $line]
    if {$r ne "OK"} { error "sim: $r" }
}
proc refresh_hw_vio {args} {
    if {[lsearch $args -update_output_values] >= 0} return
    incr mock::refreshes
    set r [mock::xfer R]
    if {[lindex $r 0] ne "I"} { error "sim: $r" }
    foreach n $mock::ins v [lrange $r 1 end] {
        set mock::value($n) [string toupper $v]
    }
}

# Connect without Vivado: what pe_connect does after it finds the VIO.
proc pe_connect_cosim {} {
    set pe::vio mock_vio
    set pe::ila ""
    foreach {role pattern} {
        ui *vio_ui_in*  rst *vio_reset*  br_en *vio_br_en*  drain *vio_drain*  loop *vio_loop*
        wr_data *vio_wr_data*  wr_count *vio_wr_count*  wr_tog *vio_wr_tog*
        rd_count *vio_rd_count*  rd_tog *vio_rd_tog*  fan *vio_fan*  hold *vio_hold*
        uo *uo_out*  uio_in *uio_in*  uio_out *uio_out*  uio_oe *uio_oe*  pad_in *pad_in*
        rd_data *br_rd_data*  rd_valid *br_rd_valid*  q_level *br_q_level*  r_level *br_r_level*
        status *br_status*
    } {
        set pe::P($role) [pe::find_probe $pe::vio $pattern]
    }
    pe_reset
}

# Simulated time instead of wall time: 1 ms of host sleep = 2000 clocks
# (the real board sleeps far longer per JTAG access; this keeps sims short).
proc pe::sleep {ms} { mock::xfer "T [expr {$ms * 2000}]" }
proc pe::sleep_cycles {cycles} { mock::xfer "T $cycles" }
