# Design notes — KV260 prototype

How-to is in [../tutorial.md](../tutorial.md). This file explains why things
are the way they are.

## Architecture

```
 kria_top (Xilinx-specific)
 ├── ps_wrapper        Zynq MPSoC PS, only for pl_clk0 = 50 MHz (= ASIC clock_hz)
 ├── vio_host          JTAG: 12 output probes, 10 input probes
 ├── ila_host          JTAG: ui_in, uo_out, uio_in/out/oe, rst_n; 8192 deep
 ├── IOBUF ×8          uio <-> Pmod J2, T = ~uio_oe (true tristate, as the ASIC pads)
 └── pe_harness (portable; simulation runs exactly this)
     ├── reset         power-on + JTAG soft reset, 16 clocks
     ├── pe_host_bridge   full-speed host link player + RX drain
     ├── loopback      per pad: uio_in[i] = pad src (the compiler's `wire src -> i`)
     ├── fan PWM       25 kHz on fan_en_b
     └── tt_um_protocol_emulator   = rtl/upstream (tapeout RTL) + program_memory_bram
```

* **Why JTAG for the host link.** The KV260 has one Pmod (8 pins) and the TT
  host link needs 16. JTAG needs no wiring (the carrier's FTDI does it), so
  `ui_in`/`uo_out` go over JTAG and the Pmod carries the 8 protocol pins.
* **Why a bridge.** A VIO access costs ~0.1 s; a UART byte at 781 kbaud
  arrives every 13 µs and the chip's RX FIFOs are 8 deep. The bridge
  (rtl/pe_host_bridge.v) does in hardware what the compiler's simulated host
  (`sim/harness.py`, class Host) does: play queued commands (held 4 clocks,
  8'h00 for 6), hold back a TX push while that FIFO is full, and keep draining
  the RX FIFOs into a 4096-entry buffer. JTAG reads 8 entries per access.
* **Hold.** The host uploads a whole script with playback paused, then
  releases it, so sequences like "push, wait 2 µs, cancel" keep chip-speed
  spacing regardless of JTAG latency. Script delays are `00 nn` (nn×16
  clocks; 8'h00 is never a host-link command).
* **Clock.** The KV260 has no PL oscillator; pl_clk0 comes from the PS. A
  JTAG-loaded bitstream does not configure the PS, so `jtag/set_pl_clk.tcl`
  writes PL0_REF_CTRL through the debug port (IOPLL 1500 MHz / 30 = 50 MHz).
* **SRAM.** `program_memory_bram.v` is the macro as used (NO_CHANGE block RAM,
  1-cycle read latency); simulation asserts on partial write masks or
  simultaneous read/write, which the macro supports but this design never uses.

## One test format, three runners

```
 .spt ──spatial run --test──► plan.json ──tools/pe_hw.py──► tests.hwtest ──► jtag/pe_jtag.tcl (board)
 protocols.py ──tools/cocotb_programs.py──────────────────► tests.hwtest ──► tools/cosim (tclsh + RTL)
                                                           tests.hwmem  ──► testbench/tb_hwtest.sv
```
The op list is documented at the top of `tools/pe_hw.py`. Compiler peers map
as follows: `wire` → harness loopback; `uart_device` → a model in simulation,
a USB-UART adapter (COM port) on the board; peers named in a `.board` sidecar
→ real parts (`needs <device>`); other peers → skipped on the board.

Verification layers, cheapest first: `make lint` → `make sim` (host link) →
`make hwsim` (programs on the RTL with the bridge) → `make cosim` (the board's
Tcl on the RTL) → board.

## Known limits

* `always` invariants from `.spt` tests are checked in RTL simulation only.
* Pad timing: the FPGA's IO path is faster than the ASIC pads; inputs are
  synchronized either way, so behaviour matches, but not analog edges.
* The SRAM is preloaded from `program.hex` on the FPGA; the ASIC's powers up
  undefined. Tests always load their program first.
* Gate-level effects are not modelled: use the upstream GL simulation.
* Pmod connector orientation is inferred from AMD's KV260 pin lists and the
  Digilent convention; check the silkscreen before plugging modules in.
