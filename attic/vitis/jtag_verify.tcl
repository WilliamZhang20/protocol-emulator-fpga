# SPDX-License-Identifier: Apache-2.0
# XSCT script: drive the VIO probes and check responses post-bitstream.
# Usage (after programming the device):
#   xsct jtag_verify.tcl
# Requires the VIO core named "vio_debug" with probes:
#   probe_ui_in  (8-bit, output from VIO -> DUT ui_in)
#   probe_uo_out (8-bit, input to VIO <- DUT uo_out)

set expect_fail 0

proc fabric_wait {n} {
    # fabric runs at 25 MHz; VIO transactions are slow, so a small sleep
    # is plenty. Poll instead if you need cycle accuracy.
    after [expr {$n * 40}]; # microseconds
}

proc vio_set_ui {v} {
    set_property PROBE_OUT0 [format %02x $v] [get_hw_probes probe_ui_in -of_objects [get_hw_vios]]
    commit_hw_vio [get_hw_probes probe_ui_in -of_objects [get_hw_vios]]
}

proc vio_get_uo {} {
    refresh_hw_vio [get_hw_vios]
    return [expr 0x[get_property PROBE_IN0 [get_hw_probes probe_uo_out -of_objects [get_hw_vios]]]]
}

# ---- connect
connect
targets -set -filter {name =~ "ARM Cortex-A53 MPCore #0"} ;# PS up? not needed for VIO
after 500
refresh_hw_device [lindex [get_hw_devices] 0]

# Host-link bytes per docs/host-link.md: {cmd[3:0], payload[3:0]},
# each sent as low nibble then high nibble with a 0x00 gap.
# Load byte 0xA5 at SRAM 0x3F0, read it back, start the engine.
set stimulus {0x10 0x00 0x2F 0x00 0x33 0x00 0x45 0x00 0x5A 0x00 0xB0 0x00 0x81 0x00}
set names    {addr_3_0 addr_7_4 addr_9_8 data_low data_high sram_readback run}
set expects  {0 0 0 0 0 0xA5 0}
set errors 0

foreach cmd $stimulus nm $names ex $expects {
    vio_set_ui $cmd
    fabric_wait 3
    vio_set_ui 0x00
    fabric_wait 3
    set resp [vio_get_uo]
    if {$ex != 0 && $resp != $ex} {
        puts "$nm -> $resp (FAIL, expect [format %02x $ex])"
        incr errors
    } else {
        puts "$nm -> $resp"
    }
}

puts "done (errors=$errors)"
disconnect
