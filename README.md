# Protocol Emulator FPGA

FPGA prototype of the Protocol Emulator ASIC design for the AMD Kria KV260. It packages the upstream RTL with a BRAM-backed program memory, a JTAG host bridge, simulation and build scripts, and example protocol programs.

The project supports RTL checks and simulation on Linux, bitstream generation with Vivado 2024.2, and running programs on a KV260 over JTAG. See the full [build and board tutorial](tutorial.md) and [FPGA design notes](docs/fpga-notes.md).

## Quick start

The default Makefile paths expect local checkouts of the upstream RTL and compiler, plus OSS CAD Suite. Override `UPSTREAM`, `UPSTREAM_REF`, `COMPILER`, and `OSSCAD` as needed.

```sh
make check       # RTL sync check, lint, smoke simulation, and program simulations
make programs    # compile and convert the protocol programs
make dist        # package files for the Vivado machine
```

Building the bitstream requires Vivado 2024.2. Board programming requires a KV260 connected to the host over JTAG. See [tutorial.md](tutorial.md) for setup, detailed commands, and the Windows/Vivado workflow.

## Repository layout

- `rtl/` — FPGA top level, host bridge, BRAM wrapper, and pinned upstream RTL
- `programs/` — program images and test vectors for simulation and hardware
- `sim/`, `testbench/` — simulation support and testbenches
- `jtag/`, `scripts/` — board control and Vivado scripts
- `constraints/` — KV260 pin and timing constraints
- `tools/` — program conversion, packaging, and co-simulation tools
- `docs/` — FPGA implementation notes

The upstream RTL revision is recorded in `rtl/upstream/UPSTREAM_COMMIT`.
