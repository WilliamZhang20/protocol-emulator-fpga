# KV260 prototype of the protocol-emulator ASIC — start to finish

This folder turns the tapeout RTL (`~/Documents/protocol-emulator`, branch
`arch/spatial8x4`) into a Kria KV260 bitstream and runs real protocol programs
on it over JTAG, checked the same way the RTL simulation checks them.

```
 Linux box (no Vivado)                      Windows box (Vivado 2024.2)            KV260
 ─────────────────────                      ──────────────────────────            ─────
 make check     RTL sync, lint, sims         Run Tcl Script: vivado_build.tcl
 make programs  compile tests -> programs/   ──► bitstream + .ltx
 make dist      zip  ─────── copy ────────►  Tcl Console: pe_connect -program ──USB──► FPGA
                                             pe_run_all                              Pmod J2 ◄─► devices
```

On the FPGA the chip runs at its ASIC clock (50 MHz). JTAG talks to it through
a small **host bridge** that plays host-link commands at full speed and buffers
everything the chip sends back, so programs behave on the board exactly as in
simulation. Details: [docs/fpga-notes.md](docs/fpga-notes.md).

---

## Part 1 — Linux side (this machine)

### 1.1 What it uses
| Thing | Where | Used for |
| --- | --- | --- |
| Tapeout RTL | `~/Documents/protocol-emulator` (git) | `make sync` copies `src/` from branch `arch/spatial8x4` |
| OSS CAD Suite | `~/Documents/protocol-emulator/.tools/oss-cad-suite` | Verilator, Icarus, Yosys |
| Compiler | `~/Documents/protocol-emulator-compiler` | `spatial` builds the `.spt` programs (built automatically) |
| Python 3, tclsh, cargo | system | generators, Tcl co-simulation, compiler build |

Override any path on the make line, e.g. `make sync UPSTREAM=/other/checkout UPSTREAM_REF=main`.

### 1.2 Check everything (no Vivado needed)
```sh
cd ~/Documents/protocol-emulator-fpga
make check
```
That runs, in order:

| Step | What it proves |
| --- | --- |
| `check-sync` | `rtl/upstream/` is byte-identical to `arch/spatial8x4` (commit in `rtl/upstream/UPSTREAM_COMMIT`) |
| `lint` | Verilator `-Wall` on the whole FPGA top (Xilinx IP stubbed) |
| `sim` | host-link smoke test, 71 checks (Icarus) |
| `hwsim` | every program's tests on the FPGA RTL (Verilator, JTAG delays modelled) |

Expected end: every line of `hwsim` shows `0 failed`.

There is also `make cosim`: it runs **the board's own Tcl runner**
(`jtag/pe_jtag.tcl`) in `tclsh` against the RTL, with the VIO modelled, so the
exact script you run in Vivado is tested here first. Ends with `COSIM PASS`.

### 1.3 Build the programs
```sh
make programs
```
For every program this runs the compiler's own RTL tests, then converts them
into `programs/<name>/`:

| File | For |
| --- | --- |
| `image.hex` | the SRAM image (for `pe_load_hex`) |
| `tests.hwtest` | the board (text, read by `pe_jtag.tcl`) |
| `tests.hwmem` | the simulation (`make hwsim`) |

Sources:
* `~/Documents/protocol-emulator-compiler/examples/*.spt` — the compiler's examples.
* `programs/spt/*.spt` — board versions on the standard Pmod pins (`spi_board`, `i2c_board`).
* `tools/cocotb_programs.py` — programs built with the tapeout repo's cocotb
  protocol library (`test/cocotb_tests/protocols.py`), named `cc_*`.

### 1.4 Package for the Vivado machine
```sh
make dist      # -> dist/protocol-emulator-fpga.zip
```
Copy the zip to the Windows machine and unzip it to a **short path without
spaces**, e.g. `C:\pe`, so you get `C:\pe\protocol-emulator-fpga\`. (Vivado's
IP generation fails on very long Windows paths.) The zip's `MANIFEST.txt` says
which RTL and compiler commits it was built from.

You only need to re-copy when something changed. If only `jtag/` or
`programs/` changed, copying those folders is enough — no rebuild. If
anything in `rtl/`, `constraints/` or `scripts/` changed, rebuild the bitstream (Part 2).

---

## Part 2 — Build the bitstream (Windows, Vivado 2024.2)

1. Start Vivado. Do **not** create or open a project.
2. **Tools → Run Tcl Script…** → choose `C:\pe\protocol-emulator-fpga\scripts\vivado_build.tcl`.
   (Or in the Tcl Console at the bottom:
   `source C:/pe/protocol-emulator-fpga/scripts/vivado_build.tcl` — forward slashes.)
3. Wait 15–40 min. `Waiting for impl_1 to finish` repeating is normal. Progress:
   the **Design Runs** tab, or `build_vivado/pe_kv260.runs/impl_1/runme.log`.
4. It ends with:
   ```
   TIMING: WNS=… ns  WHS=… ns  at 50 MHz
   BUILD DONE: …/build_vivado/out/kria_top.bit + kria_top.ltx
   ```
   Both numbers must be ≥ 0 (the script stops with an error otherwise). The
   first build gave WNS = +13.4 ns: the design could run ~3× faster.

The script creates the project itself (`build_vivado/pe_kv260.xpr`, open it
afterwards with **Open Project** if you want to look around) and recreates it
on every run — change files in the folder, never only inside the project.

---

## Part 3 — Board setup (once)

1. **SD card**: flash *Ubuntu 22.04 for AMD Kria KV260* (ubuntu.com/download/amd)
   with balenaEtcher, insert it.
2. **micro-USB (J4)** to the Vivado PC: one cable carries JTAG and the serial console.
3. **12 V power**. No switch: it boots at once. Wait 1–2 min.
4. Optional: watch the boot in PuTTY / Tera Term, 115200 baud, the second of
   the board's COM ports. Login `ubuntu` / `ubuntu` (you're asked to change it).

The PS (ARM side) must be running: it supplies the FPGA's clock. Linux being
up is enough; nothing needs to run on it.

---

## Part 4 — Every session (Vivado Tcl Console)

Type these in the **Tcl Console** at the bottom of the Vivado window (not
PowerShell, not cmd):
```tcl
cd C:/pe/protocol-emulator-fpga
source jtag/pe_jtag.tcl
pe_connect -program
```
Expected:
```
pe: setting pl_clk0 to 50 MHz with …xsdb.bat
IOPLL 1499.985 MHz; PL0_REF_CTRL … ; pl_clk0 = 49.999 MHz (target 50)
… program_hw_devices …
pe: connected to xck26_0, VIO+ILA
```
`pe_connect -program` does three things: sets the PS→FPGA clock to 50 MHz
(a JTAG-loaded bitstream can't), loads `build_vivado/out/kria_top.bit`, and
attaches to the debug cores. If the board was already programmed this
session, plain `pe_connect` just attaches.

**The fan** runs at a reduced speed with this bitstream (`pe_fan 15` = full,
`pe_fan 4` = slowest). The older bitstream forced it to full speed (loud).

### 4.1 Smoke test (raw host link)
```tcl
pe_run_stimulus jtag/stimulus.txt      ;# ~1–2 min, ends: 71 checks, 0 errors / PASS
```

### 4.2 Run the programs
```tcl
pe_list                       ;# programs, test counts, and devices they need
pe_run_program uart           ;# one program
pe_run_program cc_spi_loopback mode_2*   ;# one program, tests matching a pattern
pe_run_all                    ;# everything; ends PASS or FAIL (n failed tests)
```
Each test prints `pass`, `FAIL <why>` or `skip <why>`. A skip is never a
failure: it means the test needs something you haven't connected or declared:

| Skip message | Meaning / what to do |
| --- | --- |
| `needs <part> … (then: pe_devices <id>)` | wire the part (Part 5), then `pe_devices <id>` |
| `needs a USB-UART adapter: pe_serial COMn` | see 5.2 |
| `… baud is not a standard rate` | the program's UART runs at a rate no PC adapter has (the compiler examples use 781 250 baud); it is still tested in simulation |
| `needs device <kind> … (no board equivalent yet)` | the test needs a simulated device (SPI/I²C/USB/PS2/JTAG/SWD model); see the `*_board` / `cc_*` programs for board versions |

With nothing attached to the Pmod, these run and should pass (they use the
bridge's internal pin loopback — the compiler's `wire a -> b`):

| Program | What it exercises |
| --- | --- |
| `loopback`, `uart`, `cc_uart_loopback` | UART TX → RX, incl. 256 bytes through the 8-deep FIFOs |
| `cc_framed_burst` | multi-byte bursts with parity |
| `cc_spi_loopback`, `spi_board` | SPI master in all 4 modes, MOSI → MISO |
| `packets`, `byte_*`, `stored_bytes`, `protocol_control` | packet framing, checksums, stored data, protocol actors |
| `cc_i2c_nack`, `i2c_board` (first test) | real I²C on the real pins: nothing answers, so the address is NACKed (FPGA pull-ups) |

---

## Part 5 — Real devices on Pmod J2

### 5.1 Pins
The chip's 8 `uio` pins are on Pmod J2 (3.3 V only!). The order follows the
Tiny Tapeout / Digilent Pmod convention, so a standard 6-pin Digilent-style
module plugged into the **top row** lines up with `uio0..3`:

| uio | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pmod row/position | top 1 | top 2 | top 3 | top 4 | bottom 1 | bottom 2 | bottom 3 | bottom 4 |
| KV260 schematic J2 pin | 1 | 3 | 5 | 7 | 2 | 4 | 6 | 8 |
| FPGA ball | H12 | E10 | D10 | C11 | B10 | E12 | D11 | B11 |
| SPI (Type 2A) | CS | MOSI | MISO | SCK | | | | |
| UART | | TXD (chip out) | RXD (chip in) | | | | | |
| I²C (Type 6) | | | SCL | SDA | | | | |
| WS2812 | DIN | | | | | | | |

Each row ends with GND and 3.3 V. **Check the pin-1 marking on the board's
silkscreen before plugging a module in** — the FPGA balls are confirmed against
AMD's KV260 designs, but I could not see the physical connector.

`pe_pins` shows what every pad is doing (`uio_oe` = driven by the chip,
`pad_in` = the level on the wire).

### 5.2 USB-UART adapter (115200 baud) — `cc_uart_115200`
Any 3.3 V USB-serial adapter (FTDI, CP2102, CH340):
adapter **RX ← uio1** (top 2), adapter **TX → uio2** (top 3), **GND ↔ GND**.
Plug the adapter into the Vivado PC, find its COM number (Device Manager →
Ports), then:
```tcl
pe_serial COM7
pe_run_program cc_uart_115200
```
The chip sends `hello from the chip`, the adapter answers `ok!`. To play with
it by hand, close it (`pe_serial`) and open the COM port in PuTTY at 115200 8N1.

### 5.3 Jumper wire — `cc_uart_loopback`
A wire from uio1 (top 2) to uio2 (top 3): the same UART test as the internal
loopback, but through the real pads.
```tcl
pe_devices jumper_uio1_uio2
pe_run_program cc_uart_loopback
```

### 5.4 SPI flash — `spi_board`, `cc_spi_flash_id`
A SPI NOR flash module (e.g. Digilent Pmod SF3) on the top row. Reads the
JEDEC ID at 1 MHz. `spi_board` expects the Micron N25Q256 ID `20 BA 19`
(edit `programs/spt/spi_board.spt` for another part); `cc_spi_flash_id` just
prints what it reads.
```tcl
pe_devices spi_flash
pe_run_program cc_spi_flash_id
pe_run_program spi_board
```

### 5.5 I²C sensor — `i2c_board`, `cc_i2c_read_reg`
Default part: ADT7420 temperature sensor (Digilent Pmod TMP2, address 0x4B,
ID register 0x0B = 0xCB) on SCL uio2 / SDA uio3. Edit
`programs/spt/i2c_board.spt` (or `DEV`/`REG` in `tools/cocotb_programs.py`)
for another part.
```tcl
pe_devices i2c_adt7420 i2c_0x4b
pe_run_program i2c_board
pe_run_program cc_i2c_read_reg
```

### 5.6 WS2812 LED strip — `cc_ws2812`
Strip DIN on uio0 (top 1), strip GND to Pmod GND, strip power from its own
5 V supply (not the Pmod). Lights 8 LEDs green/red/blue.
```tcl
pe_devices ws2812
pe_run_program cc_ws2812
```

Several at once: `pe_devices spi_flash ws2812 jumper_uio1_uio2`.

---

## Part 6 — By hand, and with the logic analyzer

```tcl
pe_load_hex programs/uart/image.hex 0   ;# write an image into the chip's SRAM
pe_start                                ;# run   (pe_stop to stop)
pe_status                               ;# running/halted/FIFO flags
pe_push_tx 0x55                         ;# one byte into the TX FIFO (channel: pe_channel 0|1)
pe_pop_rx                               ;# one byte out of the RX FIFO
pe_pins                                 ;# pad levels
```
These go one command per JTAG access (~0.1 s each), fine for poking around.

**ILA** (on-chip logic analyzer, 8192 samples at 50 MHz = 164 µs):
```tcl
pe_ila_arm          ;# trigger when the chip drives any uio pin   (pe_ila_arm 1 = now)
pe_run_program cc_uart_loopback internal*
pe_ila_save C:/pe/cap   ;# -> cap.csv and cap.vcd (open the VCD in GTKWave)
```
The ILA window in Vivado's Hardware Manager shows the same capture.

---

## Part 7 — Your own program

1. Write `programs/spt/myproto.spt` (copy `spi_board.spt` as a template; pin
   placement is `pin name @ <uio>: …`). Tests that use `wire a -> b` run on
   the board with no hardware; a test that `attach`es a simulated device can
   run against a real part if you list it in `programs/spt/myproto.board`:
   ```
   peer <peer name in the test> <device id> <what to connect>
   ```
   Steps that read the device's side (`device.read`) are dropped on the
   board; host-side checks (call results, stream reads) stay.
2. `make programs` — the compiler tests it in simulation, then it's converted.
3. `make hwsim PROG=myproto` and `make cosim PROG=myproto`.
4. `make dist`, copy `programs/` (and `jtag/` if changed) to the Vivado
   machine, `pe_run_program myproto`.

For UART tests that should also run with a PC adapter, use a standard rate:
`const BIT = 434 cycles` is 115200 baud at 50 MHz.

---

## Part 8 — When the tapeout RTL changes

```sh
cd ~/Documents/protocol-emulator && git fetch
cd ~/Documents/protocol-emulator-fpga
make sync UPSTREAM_REF=origin/arch/spatial8x4   # newest pushed 8x4 RTL
make check programs UPSTREAM_REF=origin/arch/spatial8x4
make dist
```
(Plain `make sync` uses the local branch `arch/spatial8x4`, i.e. what you
last pulled.) `make sync` reads the branch from git, not the working tree, so
whatever is checked out upstream doesn't matter; the commit it used is written
to `rtl/upstream/UPSTREAM_COMMIT` and into the zip's `MANIFEST.txt`.
Then rebuild the bitstream (Part 2) — the RTL is inside it.

If the compiler moved to a new RTL revision too, `make programs` uses the
compiler's pinned revision for its own tests (`HARDWARE_REVISION` in its
`src/lib.rs`); `make hwsim` always uses `rtl/upstream/`.

---

## Part 9 — Teardown

1. Vivado: close it (or `close_hw_target; disconnect_hw_server; close_hw_manager`).
2. Board: on the serial console `sync` (no sudo needed), wait 5 s, unplug
   12 V, then the USB cable. (`sudo shutdown -h now` if you have sudo.)
3. Unplug anything on the Pmod.

Nothing on the FPGA survives power-off; next session starts at Part 4.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `The term '…' is not recognized` (PowerShell error) | You typed into PowerShell/cmd. Use Vivado's **Tcl Console**. |
| `no xck26 device on the JTAG chain` | Board off, or micro-USB not in J4. |
| `VIO not detected` / "no debug cores" | FPGA clock not running: `pe_set_clock`, then `pe_connect`. |
| `xsdb/xsct not found` | It lists where it looked; tell Claude the Vivado install path (`puts $::env(XILINX_VIVADO)`). |
| `no probe matching '*vio_…*'` | Bitstream older than the scripts: rebuild (Part 2). |
| `Designutils 20-1474 … value characters` | Old `pe_jtag.tcl`: copy the current `jtag/` folder. |
| A test `FAIL`s on the board but passes in `make hwsim` | Save the output; capture with `pe_ila_arm` + `pe_ila_save`; compare. |
| Fan loud | `pe_fan 6`. |
| `bridge overflow` | A test pushed > 4096 commands at once; split it. |

---

## Where things are

| Path | What |
| --- | --- |
| `rtl/upstream/` | tapeout RTL, verbatim (never edit; `make sync`) |
| `rtl/program_memory_bram.v` | the SRAM macro as block RAM, same timing |
| `rtl/pe_host_bridge.v` | full-speed host for the host link, fed over JTAG |
| `rtl/pe_harness.v` | reset, bridge, pin loopback, fan — everything simulation also runs |
| `rtl/kria_top.v` | PS clock, VIO, ILA, IOBUFs around the harness |
| `constraints/kv260.xdc` | Pmod J2 + fan pin |
| `scripts/vivado_build.tcl` | project, PS block design, VIO/ILA, bitstream |
| `jtag/pe_jtag.tcl` | everything you type in the Tcl Console |
| `jtag/set_pl_clk.tcl` | sets the 50 MHz PS→FPGA clock (run by `pe_connect -program`) |
| `programs/` | generated programs; `programs/spt/` board `.spt` sources |
| `tools/pe_hw.py` | test-format converter (`plan.json` → `.hwtest` / `.hwmem`) |
| `tools/cocotb_programs.py` | `cc_*` programs from the cocotb protocol library |
| `tools/cosim/` | Tcl-runner co-simulation |
| `testbench/` | `tb_hwtest.sv` (programs), `tb_host_link.sv` (smoke test) |
| `docs/fpga-notes.md` | design notes |
| `attic/` | the original pre-fix scaffold, for reference only |
