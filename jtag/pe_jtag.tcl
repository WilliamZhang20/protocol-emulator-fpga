# SPDX-License-Identifier: Apache-2.0
# JTAG driver for the protocol-emulator prototype on the KV260.
# Runs in the Vivado Tcl Console (or vivado -mode tcl / vivado_lab): the
# hw_vio / hw_ila commands only exist there.
#
# Every session:
#   cd C:/path/to/protocol-emulator-fpga
#   source jtag/pe_jtag.tcl
#   pe_connect -program            ;# sets pl_clk0 to 50 MHz, loads the bitstream
#
# Running programs (programs/<name>/tests.hwtest, built by `make programs`):
#   pe_list                        ;# what is there
#   pe_run_program uart            ;# one program's tests
#   pe_run_all                     ;# every program
#   pe_devices spi_flash ws2812    ;# real parts you have wired up (enables `needs` tests)
#   pe_serial COM5                 ;# a USB-UART adapter for tests with a UART device
#
# By hand (raw host link, one command per JTAG access; see docs/host-link.md upstream):
#   pe_status   pe_load_hex f.hex   pe_start   pe_stop   pe_push_tx b   pe_pop_rx
#   pe_ila_arm ?1?  pe_ila_save cap   pe_fan 15
#
# Raw commands use the VIO byte directly. Programs use pe_host_bridge, which
# plays queued host-link commands at clock speed and drains the RX FIFOs
# into a 4096-entry buffer (rtl/pe_host_bridge.v).

namespace eval pe {
    variable root [file normalize [file dirname [info script]]/..]
    variable dev ""; variable vio ""; variable ila ""
    variable P;                  ;# probe handles by role
    array set P {}
    variable bridge 0            ;# bridge currently enabled
    variable wr_tog 0; variable rd_tog 0
    variable devices {}          ;# real parts declared with pe_devices
    variable serial ""           ;# open COM channel
    variable serial_port ""
    variable verbose 0
    variable Q                   ;# received entries: Q(src) = list of {byte eop err}
    array set Q {0 {} 1 {} 2 {}}
    variable clock_hz 50000000
}

# ====================================================================== setup
proc pe::find_probe {core pattern} {
    foreach p [get_hw_probes -quiet -of_objects $core] {
        if {[string match $pattern [get_property NAME $p]]} { return $p }
    }
    set names [lmap p [get_hw_probes -quiet -of_objects $core] {get_property NAME $p}]
    error "no probe matching '$pattern' on $core (have: $names) -- bitstream and .ltx out of date? rebuild with scripts/vivado_build.tcl"
}

# Find xsdb (ships with Vivado) or xsct (ships with Vitis).
proc pe::find_xsdb {} {
    set tried {}
    foreach var {XILINX_VIVADO XILINX_VITIS XILINX_SDK} {
        if {![info exists ::env($var)]} continue
        foreach name {xsdb.bat xsdb xsct.bat xsct} {
            set f [file join $::env($var) bin $name]
            lappend tried $f
            if {[file exists $f]} { return $f }
        }
    }
    foreach name {xsdb xsct} {
        set f [auto_execok $name]
        if {$f ne ""} { return [lindex $f 0] }
    }
    error "xsdb/xsct not found (tried: $tried and PATH)"
}

# Set the PS -> PL clock (pl_clk0) by running jtag/set_pl_clk.tcl in xsdb.
# A JTAG-loaded bitstream cannot configure the PS clocks; without this the
# core and the VIO/ILA have no clock.
proc pe_set_clock {{mhz 50} {url localhost:3121}} {
    set tool [pe::find_xsdb]
    set script [file join $pe::root jtag set_pl_clk.tcl]
    puts "pe: setting pl_clk0 to $mhz MHz with $tool"
    if {[catch {exec {*}[auto_execok $tool] $script $url $mhz 2>@1} out]} {
        puts $out
        error "pe_set_clock failed (output above)"
    }
    puts $out
}

# pe_connect ?-url host:port? ?-program? ?-no-clock? ?-bit file? ?-ltx file?
# With -program the PL clock is set first (skip with -no-clock).
proc pe_connect {args} {
    set url localhost:3121
    set bit $pe::root/build_vivado/out/kria_top.bit
    set ltx $pe::root/build_vivado/out/kria_top.ltx
    set program 0; set clock 1
    while {[llength $args]} {
        set args [lassign $args a]
        switch -- $a {
            -url      { set args [lassign $args url] }
            -bit      { set args [lassign $args bit] }
            -ltx      { set args [lassign $args ltx] }
            -program  { set program 1 }
            -no-clock { set clock 0 }
            default   { error "pe_connect: unknown option $a" }
        }
    }
    if {$program && $clock} { pe_set_clock 50 $url }
    if {[catch {current_hw_server}]} { open_hw_manager }
    if {[catch {current_hw_server}] || [get_property NAME [current_hw_server]] ne $url} {
        connect_hw_server -url $url -allow_non_jtag
    }
    if {[catch {current_hw_target}]} { open_hw_target }
    set pe::dev [lindex [get_hw_devices -quiet xck26*] 0]
    if {$pe::dev eq ""} { error "no xck26 device on the JTAG chain ([get_hw_devices]); is the KV260 micro-USB connected?" }
    current_hw_device $pe::dev
    if {![file exists $ltx]} { error "missing $ltx (build first: scripts/vivado_build.tcl)" }
    set_property PROBES.FILE      $ltx $pe::dev
    set_property FULL_PROBES.FILE $ltx $pe::dev
    if {$program} {
        if {![file exists $bit]} { error "missing $bit (build first: scripts/vivado_build.tcl)" }
        set_property PROGRAM.FILE $bit $pe::dev
        program_hw_devices $pe::dev
    }
    refresh_hw_device $pe::dev
    set pe::vio [lindex [get_hw_vios -quiet -of_objects $pe::dev] 0]
    set pe::ila [lindex [get_hw_ilas -quiet -of_objects $pe::dev] 0]
    if {$pe::vio eq ""} {
        error "VIO not detected. The debug cores run on pl_clk0: run pe_set_clock, then pe_connect again."
    }
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
    foreach p [get_hw_probes -of_objects $pe::vio -filter {TYPE == vio_output}] {
        set_property OUTPUT_VALUE_RADIX HEX $p
    }
    foreach p [get_hw_probes -of_objects $pe::vio -filter {TYPE == vio_input}] {
        set_property INPUT_VALUE_RADIX HEX $p
    }
    refresh_hw_vio -update_output_values $pe::vio
    set pe::wr_tog [pe::get_out wr_tog]
    set pe::rd_tog [pe::get_out rd_tog]
    pe_reset
    puts "pe: connected to [get_property NAME $pe::dev], VIO+[expr {$pe::ila ne "" ? "ILA" : "no ILA"}]"
}

# Sleeps (the co-simulation in tools/cosim redefines these to advance sim time).
proc pe::sleep {ms} { after $ms }
proc pe::sleep_cycles {cycles} { after [expr {max(1, $cycles * 1000 / $pe::clock_hz)}] }

# ====================================================================== VIO access
# HEX radix needs exactly ceil(width/4) digits.
proc pe::fmt {role v} {
    set digits [expr {([get_property WIDTH $pe::P($role)] + 3) / 4}]
    return [format %0*llX $digits $v]
}
proc pe::put {role v} { set_property OUTPUT_VALUE [pe::fmt $role $v] $pe::P($role) }
proc pe::put_hex {role hex} { set_property OUTPUT_VALUE $hex $pe::P($role) }
proc pe::commit {} { commit_hw_vio $pe::vio }
proc pe::set_out {role v} { pe::put $role $v; pe::commit }
proc pe::get_out {role} { return [expr {"0x[get_property OUTPUT_VALUE $pe::P($role)]"}] }
proc pe::refresh {} { refresh_hw_vio $pe::vio }
proc pe::in {role} { return [expr {"0x[get_property INPUT_VALUE $pe::P($role)]"}] }
proc pe::in_hex {role} { return [get_property INPUT_VALUE $pe::P($role)] }

proc pe_reset {} {
    pe::put ui 0; pe::put br_en 0; pe::put drain 0; pe::put loop 0; pe::put hold 0
    pe::put rst 1; pe::commit
    pe::set_out rst 0
    set pe::bridge 0
    array set pe::Q {0 {} 1 {} 2 {}}
}

proc pe_fan {duty} {
    # 4..15 = 27..100 % (25 kHz PWM on the fan enable). Default 9.
    pe::set_out fan [expr {max(4, min(15, $duty))}]
}

# ====================================================================== raw host link
# One host-link command (byte = {cmd, payload}); returns uo_out afterwards.
proc pe_cmd {byte} {
    if {$pe::bridge} { pe::set_out br_en 0; set pe::bridge 0 }
    pe::set_out ui [expr {$byte & 0xff}]
    pe::set_out ui 0
    pe::refresh
    return [pe::in uo]
}
proc pe::c {cmd {payload 0}} { return [pe_cmd [expr {(($cmd & 0xf) << 4) | ($payload & 0xf)}]] }

proc pe_set_addr {addr}  { pe::c 1 $addr; pe::c 2 [expr {$addr >> 4}]; pe::c 3 [expr {$addr >> 8}] }
proc pe_write_bytes {addr bytes} {
    pe_set_addr $addr
    foreach b $bytes { pe::c 4 $b; pe::c 5 [expr {$b >> 4}] }
}
proc pe_sram_read {addr} { pe_set_addr $addr; return [pe::c 0xB] }
proc pe_start {} { pe::c 8 1 }
proc pe_stop  {} { pe::c 8 2 }
proc pe_channel {ch} { pe::c 0xE $ch }
proc pe_push_tx {b {eop 0}} { pe::c 6 $b; pe::c [expr {$eop ? 0xF : 7}] [expr {$b >> 4}] }
proc pe_pop_rx  {} { return [pe::c 9] }
proc pe_peek_rx {} { return [pe::c 0xD] }
proc pe_levels  {} { return [pe::c 0xC] }
proc pe_status  {} {
    set s [pe::c 0xA]
    return [dict create raw [format 0x%02x $s] running [expr {($s>>7)&1}] halted [expr {($s>>6)&1}] \
            tx_full [expr {($s>>5)&1}] rx_empty [expr {($s>>4)&1}] eop [expr {($s>>1)&1}] err [expr {$s&1}]]
}
proc pe_pins {} {
    pe::refresh
    return [dict create uio_in 0x[pe::in_hex uio_in] uio_out 0x[pe::in_hex uio_out] \
            uio_oe 0x[pe::in_hex uio_oe] pad_in 0x[pe::in_hex pad_in]]
}

# Load a $readmemh-style image (one hex byte per line, // or # comments).
proc pe::read_hex {file} {
    set fh [open $file]; set bytes {}
    foreach line [split [read $fh] \n] {
        regsub {(//|#).*} $line {} line
        foreach tok $line { lappend bytes [expr {"0x$tok"}] }
    }
    close $fh
    return $bytes
}
proc pe_load_hex {file {addr 0}} {
    set bytes [pe::read_hex $file]
    pe_write_bytes $addr $bytes
    puts "pe: wrote [llength $bytes] bytes at [format 0x%03x $addr]"
}

# ====================================================================== bridge
proc pe::bridge_on {} {
    if {!$pe::bridge} { pe::set_out br_en 1; set pe::bridge 1 }
}

# Queue host-link command bytes (a list of ints) into the bridge script.
# The bridge holds playback until the whole script is uploaded, so the
# commands keep their chip-speed spacing (JTAG takes ~0.1 s per access).
proc pe::enqueue {bytes} {
    pe::bridge_on
    pe::set_out hold 1
    set n [llength $bytes]
    for {set i 0} {$i < $n} {incr i 16} {
        set chunk [lrange $bytes $i [expr {$i + 15}]]
        # room in the 4096-byte queue?
        while 1 {
            pe::refresh
            if {[pe::in q_level] <= 4096 - 32} break
            pe::sleep 20
        }
        # 128-bit value, byte j at bits [8j+7:8j]: hex string is MSB first
        set hex ""
        for {set j 15} {$j >= 0} {incr j -1} {
            append hex [format %02X [expr {$j < [llength $chunk] ? [lindex $chunk $j] : 0}]]
        }
        pe::put_hex wr_data $hex
        pe::put wr_count [llength $chunk]
        pe::commit
        set pe::wr_tog [expr {!$pe::wr_tog}]
        pe::set_out wr_tog $pe::wr_tog
        if {$i + 16 < $n && [pe::in q_level] > 4096 - 64} { pe::set_out hold 0 }   ;# too big: stream
    }
    pe::set_out hold 0
}

# Move everything visible in the bridge's read window into pe::Q.
# Returns the number of entries moved.
proc pe::pull {} {
    pe::refresh
    set n [pe::in rd_valid]
    if {$n == 0} { return 0 }
    set hex [pe::in_hex rd_data]
    set hex [string range [string repeat 0 32]$hex end-31 end]
    for {set k 0} {$k < $n} {incr k} {
        set e [expr {"0x[string range $hex [expr {28 - 4*$k}] [expr {31 - 4*$k}]]"}]
        set src [expr {($e >> 14) & 3}]
        lappend pe::Q($src) [list [expr {$e & 0xff}] [expr {($e >> 13) & 1}] [expr {($e >> 12) & 1}]]
    }
    pe::put rd_count $n
    pe::commit
    set pe::rd_tog [expr {!$pe::rd_tog}]
    pe::set_out rd_tog $pe::rd_tog
    return $n
}

proc pe::bridge_status {} {
    pe::refresh
    set s [pe::in status]
    return [dict create q_ovf [expr {($s>>7)&1}] r_ovf [expr {($s>>6)&1}] tx_wait [expr {($s>>5)&1}] \
            idle [expr {($s>>4)&1}] q_level [pe::in q_level] r_level [pe::in r_level]]
}

# ====================================================================== UART adapter (COM port)
# pe_serial COM5            open a USB-UART adapter (Windows: COMn, Linux: /dev/ttyUSB0)
# pe_serial                 close it
proc pe_serial {{port ""}} {
    if {$pe::serial ne ""} { catch {close $pe::serial}; set pe::serial "" }
    set pe::serial_port $port
    if {$port eq ""} { return }
    set path $port
    if {[regexp {^COM[0-9]+$} $port]} { set path "\\\\.\\$port" }
    set pe::serial [open $path r+]
    fconfigure $pe::serial -mode 115200,n,8,1 -translation binary -buffering none \
        -blocking 0 -handshake none
    puts "pe: serial $port open"
}

proc pe::serial_setup {bit parity} {
    set baud [expr {double($pe::clock_hz) / $bit}]
    set std 0
    foreach b {9600 19200 38400 57600 115200 230400 460800 921600 1000000 2000000 3000000} {
        if {abs($baud - $b) / $b < 0.02} { set std $b }
    }
    if {$std == 0} { return "UART device at [format %.0f $baud] baud is not a standard rate (change the program's bit time)" }
    if {$pe::serial eq ""} { return "needs a USB-UART adapter: pe_serial COMn (adapter RX <- chip TX pad, TX -> chip RX pad, GND)" }
    set p [string index $parity 0]
    fconfigure $pe::serial -mode $std,$p,8,1
    read $pe::serial        ;# discard anything stale
    return ""
}

# ====================================================================== test runner
proc pe::hex2list {hex} {
    if {$hex eq "-"} { return {} }
    set out {}
    for {set i 0} {$i < [string length $hex]} {incr i 2} {
        lappend out [expr {"0x[string range $hex $i [expr {$i + 1}]]"}]
    }
    return $out
}
proc pe::list2hex {l} {
    set s ""
    foreach b $l { append s [format %02x $b] }
    return [expr {$s eq "" ? "(none)" : $s}]
}
# JTAG is slow: a step gets its chip-time budget plus 3 s.
proc pe::deadline {cycles} {
    return [expr {[clock milliseconds] + 3000 + $cycles * 1000 / $pe::clock_hz}]
}

# Wait for `count` entries from src (count < 0: until an eop entry). 1 = ok.
proc pe::collect {src count cycles} {
    set until [pe::deadline $cycles]
    while 1 {
        if {$count >= 0 && [llength $pe::Q($src)] >= $count} { return 1 }
        if {$count < 0} {
            foreach e $pe::Q($src) { if {[lindex $e 1]} { return 1 } }
        }
        if {[clock milliseconds] > $until} { return 0 }
        if {[pe::pull] == 0} { pe::sleep 10 }
    }
}
proc pe::take {src n} {
    set got [lrange $pe::Q($src) 0 [expr {$n - 1}]]
    set pe::Q($src) [lrange $pe::Q($src) $n end]
    return $got
}
proc pe::eop_index {src} {
    set i 0
    foreach e $pe::Q($src) { if {[lindex $e 1]} { return $i }; incr i }
    return -1
}
proc pe::bytes_of {entries} { return [lmap e $entries {lindex $e 0}] }

# Run one op line; returns "" or a failure message.
proc pe::op {line} {
    set a [split [string trim $line]]
    set k [lindex $a 0]
    switch -- $k {
        reset { pe_reset; pe::bridge_on; return "" }
        drain { pe::set_out drain [lindex $a 1]; return "" }
        loop  { pe::set_out loop [expr {"0x[lindex $a 1]"}]; return "" }
        cmds  { pe::enqueue [pe::hex2list [lindex $a 1]]; return "" }
        wait  { pe::sleep_cycles [lindex $a 1]; return "" }
        idle  {
            set until [pe::deadline [lindex $a 1]]
            while 1 {
                set s [pe::bridge_status]
                if {[dict get $s idle] && [dict get $s q_level] == 0} { return "" }
                if {[clock milliseconds] > $until} { return "script queue never drained (TX stalled?)" }
                pe::sleep 20
            }
        }
        rx {
            lassign [lrange $a 1 end] ch count cycles exp
            set src [expr {$ch + 1}]
            if {![pe::collect $src $count $cycles]} {
                return "channel $ch: got [pe::list2hex [pe::bytes_of $pe::Q($src)]], then nothing (wanted $count bytes)"
            }
            set got [pe::take $src $count]
            foreach e $got { if {[lindex $e 2]} { return "channel $ch: byte marked as error (bad stop/parity)" } }
            set bytes [pe::bytes_of $got]
            if {$exp eq "-"} { puts "      channel $ch received [pe::list2hex $bytes]"; return "" }
            if {$bytes ne [pe::hex2list $exp]} { return "channel $ch: expected $exp, got [pe::list2hex $bytes]" }
            return ""
        }
        packet - reply {
            lassign [lrange $a 1 end] ch cycles exp last
            set src [expr {$ch + 1}]
            if {![pe::collect $src -1 $cycles]} {
                return "channel $ch: no packet end (have [pe::list2hex [pe::bytes_of $pe::Q($src)]])"
            }
            set idx [pe::eop_index $src]
            if {$k eq "packet"} {
                set got [pe::take $src [expr {$idx + 1}]]
                set err 0
                foreach e $got { if {[lindex $e 2]} { set err 1 } }
                set bytes [pe::bytes_of $got]
                if {$last ne "-" && $err != $last} { return "channel $ch: packet error flag $err, expected $last" }
                if {$exp ne "-" && $bytes ne [pe::hex2list $exp]} { return "channel $ch: packet [pe::list2hex $bytes], expected $exp" }
                if {$exp eq "-"} { puts "      channel $ch packet [pe::list2hex $bytes] err=$err" }
            } else {
                set bytes [pe::bytes_of [pe::take $src $idx]]
                lassign [lindex [pe::take $src 1] 0] status - err
                if {$last eq "ok" && $err} { return "call failed with status $status" }
                if {$last ne "ok" && !$err} { return "call succeeded, expected failure $last" }
                if {$last ne "ok" && $status != $last} { return "call failed with $status, expected $last" }
                if {$exp ne "-" && $bytes ne [pe::hex2list $exp]} { return "call answered [pe::list2hex $bytes], expected $exp" }
            }
            return ""
        }
        flush {
            lassign [lrange $a 1 end] ch cycles exp
            set src [expr {$ch + 1}]
            pe::sleep 200; pe::sleep_cycles $cycles
            while {[pe::pull] > 0} {}
            set bytes [pe::bytes_of [pe::take $src [llength $pe::Q($src)]]]
            if {$exp eq "-"} { puts "      channel $ch held [pe::list2hex $bytes]"; return "" }
            if {$bytes ne [pe::hex2list $exp]} { return "channel $ch held [pe::list2hex $bytes], expected $exp" }
            return ""
        }
        serial {
            lassign [lrange $a 1 end] bit txp rxp parity
            set why [pe::serial_setup $bit $parity]
            if {$why ne ""} { return "SKIP $why" }
            return ""
        }
        swrite {
            puts -nonewline $pe::serial [binary format c* [pe::hex2list [lindex $a 1]]]
            flush $pe::serial
            return ""
        }
        sread {
            lassign [lrange $a 1 end] count cycles exp
            set until [pe::deadline $cycles]
            set buf ""
            while {[string length $buf] < $count && [clock milliseconds] <= $until} {
                append buf [read $pe::serial]
                pe::sleep 5
            }
            binary scan $buf cu* got
            if {[llength $got] < $count} { return "UART adapter got [pe::list2hex $got], wanted $count bytes" }
            set got [lrange $got 0 [expr {$count - 1}]]
            if {$exp ne "-" && $got ne [pe::hex2list $exp]} { return "UART adapter got [pe::list2hex $got], expected $exp" }
            return ""
        }
        default { return "unknown op '$k'" }
    }
}

# pe_run_program <name or path> ?test-name-pattern?   -> number of failures
proc pe_run_program {prog {only *}} {
    set file $prog
    if {![file exists $file]} { set file [file join $pe::root programs $prog tests.hwtest] }
    if {[file isdirectory $file]} { set file [file join $file tests.hwtest] }
    if {![file exists $file]} { error "no such program: $prog (see pe_list)" }
    set name [file tail [file dirname $file]]
    puts "== $name =="
    set fh [open $file]; set lines [split [read $fh] \n]; close $fh

    set tests {}; set cur ""
    foreach line $lines {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        if {[lindex $line 0] eq "test"} { set cur [lindex $line 1]; lappend tests $cur; set body($cur) {}; continue }
        if {[lindex $line 0] eq "end"} break
        lappend body($cur) $line
    }
    set pass 0; set fail 0; set skip 0
    foreach t $tests {
        if {![string match $only $t]} continue
        set result ""; set start [clock milliseconds]
        foreach line $body($t) {
            set k [lindex $line 0]
            if {$k eq "skip"} { set result "SKIP [lrange $line 1 end]"; break }
            if {$k eq "needs"} {
                if {[lindex $line 1] ni $pe::devices} {
                    set result "SKIP needs [lrange $line 2 end] (then: pe_devices [lindex $line 1])"; break
                }
                continue
            }
            if {$pe::verbose} { puts "    [string range $line 0 100]" }
            if {[catch {pe::op $line} r]} { set r "error: $r" }
            if {$r ne ""} { set result $r; break }
        }
        if {$result eq ""} {
            set s [pe::bridge_status]
            if {[dict get $s q_ovf] || [dict get $s r_ovf]} { set result "bridge overflow ($s)" }
        }
        set secs [format %.1f [expr {([clock milliseconds] - $start) / 1000.0}]]
        if {$result eq ""} {
            incr pass; puts [format "  %-48s pass  (%s s)" $t $secs]
        } elseif {[string match "SKIP*" $result]} {
            incr skip; puts [format "  %-48s skip  %s" $t [string range $result 5 end]]
        } else {
            incr fail; puts [format "  %-48s FAIL  %s" $t $result]
        }
    }
    puts "== $name: $pass passed, $fail failed, $skip skipped =="
    pe_reset
    return $fail
}

proc pe_list {} {
    foreach f [lsort [glob -nocomplain [file join $pe::root programs * tests.hwtest]]] {
        set fh [open $f]; set text [read $fh]; close $fh
        set n [regexp -all -line {^test } $text]
        set needs [lsort -unique [regexp -all -inline -line {^needs (\S+)} $text]]
        set needs [lmap {m d} $needs {set d}]
        puts [format "  %-22s %2d tests  %s" [file tail [file dirname $f]] $n \
              [expr {[llength $needs] ? "needs: [join $needs {, }]" : ""}]]
    }
}

proc pe_run_all {} {
    set total 0
    foreach f [lsort [glob -nocomplain [file join $pe::root programs * tests.hwtest]]] {
        incr total [pe_run_program $f]
    }
    puts [expr {$total ? "FAIL ($total failed tests)" : "PASS"}]
    return $total
}

# pe_devices spi_flash ws2812 ...   declare real parts wired to the Pmod
proc pe_devices {args} {
    set pe::devices $args
    puts "pe: devices = [expr {[llength $args] ? $args : {(none)}}]"
}

# ====================================================================== ILA
# Arm on "any uio pin driven" (or immediately with pe_ila_arm 1), then save.
proc pe_ila_arm {{immediate 0}} {
    if {$pe::ila eq ""} { error "no ILA in this bitstream" }
    reset_hw_ila $pe::ila
    if {!$immediate} {
        set p [pe::find_probe $pe::ila *uio_oe*]
        set_property TRIGGER_COMPARE_VALUE neq8'h00 $p
    }
    set_property CONTROL.TRIGGER_POSITION 512 $pe::ila
    run_hw_ila $pe::ila {*}[expr {$immediate ? "-trigger_now" : ""}]
}
# Saves <base>.csv and <base>.vcd (open the VCD in GTKWave next to the sim FST).
proc pe_ila_save {base} {
    wait_on_hw_ila -timeout 1 $pe::ila
    set d [upload_hw_ila_data $pe::ila]
    write_hw_ila_data -force -csv_file $base.csv $d
    write_hw_ila_data -force -vcd_file $base.vcd $d
    puts "pe: ILA capture -> $base.csv, $base.vcd"
}

# ====================================================================== legacy smoke test
# Replay a jtag/stimulus.txt file through the raw host link; returns mismatches.
proc pe_run_stimulus {file} {
    set fh [open $file]; set errors 0; set checks 0; set n 0
    foreach line [split [read $fh] \n] {
        regsub {#.*} $line {} line
        if {[llength $line] == 0} continue
        incr n
        set got [pe_cmd [expr {"0x[lindex $line 0]"}]]
        if {[llength $line] > 1} {
            incr checks
            set exp [expr {"0x[lindex $line 1]"}]
            if {$got != $exp} {
                incr errors
                puts [format "\[FAIL\] cmd %s: uo_out %02x expected %02x" [lindex $line 0] $got $exp]
            }
        }
        if {$n % 50 == 0} { puts "pe: $n commands..." }
    }
    close $fh
    puts "== $n commands, $checks checks, $errors errors =="
    puts [expr {$errors == 0 && $checks > 0 ? "PASS" : "FAIL"}]
    return $errors
}
