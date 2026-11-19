# Kria KV260 constraints for kria_top.
#
# Clock: pl_clk0 comes from the PS block design, which also creates its
# timing constraint (50 MHz), so there is no clock pin or create_clock here.
# The KV260 has no PL oscillator, no PL user LEDs and no PL user buttons;
# reset and the host link are over JTAG (VIO).
#
# Pmod J2 (bank 45 / HDA, 3.3 V), same balls and order as AMD's Kria-PYNQ
# base.xdc: uio[3:0] on the top row (pins 1,3,5,7), uio[7:4] on the bottom
# row (pins 2,4,6,8). Pins 5,6,11,12 are GND/VCC.
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33} [get_ports {pmod[0]}]   ;# Pmod J2 pin 1
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33} [get_ports {pmod[1]}]   ;# Pmod J2 pin 3
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports {pmod[2]}]   ;# Pmod J2 pin 5
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports {pmod[3]}]   ;# Pmod J2 pin 7
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports {pmod[4]}]   ;# Pmod J2 pin 2
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports {pmod[5]}]   ;# Pmod J2 pin 4
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33} [get_ports {pmod[6]}]   ;# Pmod J2 pin 6
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {pmod[7]}]   ;# Pmod J2 pin 8
set_property PULLUP true [get_ports {pmod[*]}]
set_property DRIVE 8 [get_ports {pmod[*]}]
set_property SLEW SLOW [get_ports {pmod[*]}]

# Fan enable (active low). Driving it low keeps the fan running at full speed
# while a custom bitstream is loaded.
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports fan_en_b]

# Pmod pins are asynchronous to pl_clk0 (external devices); the core
# synchronizes pin inputs internally like the ASIC pads, so IO timing is
# not analysed.
set_false_path -from [get_ports {pmod[*]}]
set_false_path -to   [get_ports {pmod[*]}]
set_false_path -to   [get_ports fan_en_b]
