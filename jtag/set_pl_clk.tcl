# SPDX-License-Identifier: Apache-2.0
# XSCT: set the PS -> PL clock pl_clk0 (PL0_REF_CTRL) to the ASIC frequency.
#
#   xsct jtag/set_pl_clk.tcl [hw_server host:port] [MHz]     (default localhost:3121 50)
#
# Why: a bitstream loaded over JTAG does not configure the PS. pl_clk0 keeps
# whatever the KV260 boot firmware set (or is off), and the core, the VIO and
# the ILA all run on it. This writes the clock divider directly through the
# debug port (CRL_APB registers, UG1087), so it works with Linux running and
# does not touch DDR or anything else. Run it before `make jtag`; re-run after
# a board power cycle.

set url [expr {[llength $argv] > 0 ? [lindex $argv 0] : "localhost:3121"}]
set mhz [expr {[llength $argv] > 1 ? [lindex $argv 1] : 50}]

set PS_REF_MHZ   33.333          ;# K26 SOM PS_REF_CLK
set IOPLL_CTRL   0xFF5E0020
set PL0_REF_CTRL 0xFF5E00C0

connect -url tcp:$url
targets -set -nocase -filter {name =~ "PSU"}

proc rd {a} { return [lindex [mrd -force -value $a] 0] }

set pll [rd $IOPLL_CTRL]
set fbdiv  [expr {($pll >> 8) & 0x7f}]
set div2   [expr {($pll >> 16) & 1}]
set bypass [expr {($pll >> 3) & 1}]
if {$bypass || $fbdiv == 0} { error "IOPLL is bypassed/unconfigured (IOPLL_CTRL=[format 0x%08x $pll]); is the PS booted?" }
set iopll [expr {$PS_REF_MHZ * $fbdiv / ($div2 ? 2.0 : 1.0)}]

# best divisor pair, each 1..63
set best {}; set besterr 1e9
for {set d0 1} {$d0 < 64} {incr d0} {
    for {set d1 1} {$d1 < 64} {incr d1} {
        set f [expr {$iopll / ($d0 * $d1)}]
        set e [expr {abs($f - $mhz)}]
        if {$e < $besterr - 1e-9} { set besterr $e; set best [list $d0 $d1 $f] }
    }
}
lassign $best d0 d1 f
set old [rd $PL0_REF_CTRL]
set val [expr {(1 << 24) | ($d1 << 16) | ($d0 << 8) | 0}]   ;# CLKACT, IOPLL source
mwr -force $PL0_REF_CTRL $val
set new [rd $PL0_REF_CTRL]

puts [format "IOPLL %.3f MHz; PL0_REF_CTRL 0x%08x -> 0x%08x; pl_clk0 = %.3f MHz (target %s)" \
      $iopll $old $new $f $mhz]
if {abs($f - $mhz) / $mhz > 0.01} { puts "WARNING: pl_clk0 is more than 1% off target" }
disconnect
