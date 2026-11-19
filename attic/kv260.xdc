# Kria KV260 XDC — edit pin locations to match your Pmod/IO carrier.
# Base pinout follows the KV260 PL default (RPi-compatible header on HDA).
# Clock: PL0 via PS — if you use the PS-GTR/PL clock from a Vivado block
# design, delete clk_125m pin and let the BD drive it.

set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS18} [get_ports clk_125m]
create_clock -period 8.000 -name sys_clk [get_ports clk_125m]

# Example reset input pin. Verify it is connected on your carrier and does
# not conflict with the selected Pmod/header wiring.
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS18} [get_ports btn_reset]
set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS18} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS18} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS18} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS18} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS18} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS18} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS18} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS18} [get_ports {led[7]}]

# Pmod host link (ui_in / uo_out) — example on HDA header; remap to your Pmod
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS18} [get_ports {pmod_in[0]}]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS18} [get_ports {pmod_in[1]}]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS18} [get_ports {pmod_in[2]}]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS18} [get_ports {pmod_in[3]}]
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS18} [get_ports {pmod_in[4]}]
set_property -dict {PACKAGE_PIN B8  IOSTANDARD LVCMOS18} [get_ports {pmod_in[5]}]
set_property -dict {PACKAGE_PIN A7  IOSTANDARD LVCMOS18} [get_ports {pmod_in[6]}]
set_property -dict {PACKAGE_PIN B7  IOSTANDARD LVCMOS18} [get_ports {pmod_in[7]}]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS18} [get_ports {pmod_out[0]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS18} [get_ports {pmod_out[1]}]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS18} [get_ports {pmod_out[2]}]
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS18} [get_ports {pmod_out[3]}]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS18} [get_ports {pmod_out[4]}]
set_property -dict {PACKAGE_PIN E11 IOSTANDARD LVCMOS18} [get_ports {pmod_out[5]}]
set_property -dict {PACKAGE_PIN F9  IOSTANDARD LVCMOS18} [get_ports {pmod_out[6]}]
set_property -dict {PACKAGE_PIN F10 IOSTANDARD LVCMOS18} [get_ports {pmod_out[7]}]

# protocol GPIO (uio) — second Pmod or remaining header pins
set_property -dict {PACKAGE_PIN G9  IOSTANDARD LVCMOS18} [get_ports {gpio_in[0]}]
set_property -dict {PACKAGE_PIN G10 IOSTANDARD LVCMOS18} [get_ports {gpio_in[1]}]
set_property -dict {PACKAGE_PIN H9  IOSTANDARD LVCMOS18} [get_ports {gpio_in[2]}]
set_property -dict {PACKAGE_PIN H10 IOSTANDARD LVCMOS18} [get_ports {gpio_in[3]}]
set_property -dict {PACKAGE_PIN J9  IOSTANDARD LVCMOS18} [get_ports {gpio_in[4]}]
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS18} [get_ports {gpio_in[5]}]
set_property -dict {PACKAGE_PIN K9  IOSTANDARD LVCMOS18} [get_ports {gpio_in[6]}]
set_property -dict {PACKAGE_PIN K10 IOSTANDARD LVCMOS18} [get_ports {gpio_in[7]}]
set_property -dict {PACKAGE_PIN L9  IOSTANDARD LVCMOS18} [get_ports {gpio_out[0]}]
set_property -dict {PACKAGE_PIN L10 IOSTANDARD LVCMOS18} [get_ports {gpio_out[1]}]
set_property -dict {PACKAGE_PIN M9  IOSTANDARD LVCMOS18} [get_ports {gpio_out[2]}]
set_property -dict {PACKAGE_PIN M10 IOSTANDARD LVCMOS18} [get_ports {gpio_out[3]}]
set_property -dict {PACKAGE_PIN N9  IOSTANDARD LVCMOS18} [get_ports {gpio_out[4]}]
set_property -dict {PACKAGE_PIN N10 IOSTANDARD LVCMOS18} [get_ports {gpio_out[5]}]
set_property -dict {PACKAGE_PIN P9  IOSTANDARD LVCMOS18} [get_ports {gpio_out[6]}]
set_property -dict {PACKAGE_PIN P10 IOSTANDARD LVCMOS18} [get_ports {gpio_out[7]}]
set_property -dict {PACKAGE_PIN R9  IOSTANDARD LVCMOS18} [get_ports {gpio_oe[0]}]
set_property -dict {PACKAGE_PIN R10 IOSTANDARD LVCMOS18} [get_ports {gpio_oe[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS18} [get_ports {gpio_oe[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS18} [get_ports {gpio_oe[3]}]
set_property -dict {PACKAGE_PIN U9  IOSTANDARD LVCMOS18} [get_ports {gpio_oe[4]}]
set_property -dict {PACKAGE_PIN U10 IOSTANDARD LVCMOS18} [get_ports {gpio_oe[5]}]
set_property -dict {PACKAGE_PIN V9  IOSTANDARD LVCMOS18} [get_ports {gpio_oe[6]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS18} [get_ports {gpio_oe[7]}]

set_property -dict {PACKAGE_PIN W12 IOSTANDARD LVCMOS18} [get_ports clk_out]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
