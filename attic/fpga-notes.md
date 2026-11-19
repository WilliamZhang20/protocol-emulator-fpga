# FPGA bring-up notes (Kria KV260)

## What changed vs. the tapeout RTL
- `program_memory` (foundry SRAM macro) → `rtl/program_memory_bram.v`
  (BRAM, same ports, same 1-cycle read latency, RMW for write-mask).
- New `kria_top.v` wraps the TT project: the core runs at 125 MHz; the
  registered output pins update every five clocks (25 MHz), with a
  synchronized reset and LED mapping.
- `program.hex` initializes the BRAM ($readmemh). A NOP-filled default
  is in `sim/program.hex`; replace with your assembled program.

## Build
```sh
make lint          # verilator lint
make synth-check   # yosys structural synth
make sim           # iverilog run of tb_kria_top
make vivado        # full build -> build_vivado/kria_top.bit
```
Vivado 2023.2+ recommended (KV260 support). Part: xck26-sfvc784-2LVC.

## Programming & JTAG verification
1. `vivado -mode batch -source scripts/vivado_build.tcl`
2. Program: open hardware manager, connect to hw_server on the KV260
   (or via `xsct`), program `kria_top.bit`.
3. For deep verification, rebuild with the debug cores:
   instantiate a VIO (probe_ui_in → ui_in, probe_uo_out ← uo_out,
   probes on uio_*) and an ILA on the same buses, then use
   `vitis/jtag_verify.tcl` from XSCT to drive the exact stimulus that
   `testbench/tb_kria_top.sv` uses in simulation. Compare responses
   byte-for-byte: sim vs. silicon.
4. `vitis/jtag_verify.c` is the C reference for the SRAM write/readback
   sequence; build its host-side stimulus check with `make -C vitis test`.

## Pinout caveat
`constraints/kv260.xdc` pin locations are a template — verify against
your carrier/Pmod wiring before programming. The clock pin assumes a
PL clock from the PS block design; if you use the boot clock instead,
update both the XDC and the create_clock period.

## Clocking note
The /5 divider does not slow the core: its flip-flops run at 125 MHz. It
only clocks the output-pin registers at 25 MHz. If the whole core needs a
25 MHz domain, use a clocking IP block and update the timing constraints.
