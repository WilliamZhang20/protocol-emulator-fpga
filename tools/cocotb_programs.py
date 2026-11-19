#!/usr/bin/env python3
"""Board programs built from the tapeout repo's cocotb protocol library.

The programs come from ../protocol-emulator/test/cocotb_tests/protocols.py
(the same Px8 builders the cocotb regression runs), so the image is
bit-identical to what the RTL tests load. The tests are rewritten for the
board: a pad loopback instead of a cocotb model where the protocol can talk
to itself, and a `needs` device line where it takes a real part.

Pmod J2 (uio = Tiny Tapeout pinout, see constraints/kv260.xdc):
    UART  TXD uio1, RXD uio2           SPI  CS uio0, MOSI uio1, MISO uio2, SCK uio3
    I2C   SCL uio2, SDA uio3           WS2812 DIN uio0

Usage: cocotb_programs.py [--upstream DIR] <programs dir>
"""
from __future__ import annotations

import argparse
import random
import sys
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pe_hw  # noqa: E402
from pe_hw import CLOCK_HZ, Program, loop_cfg  # noqa: E402


def import_protocols(upstream: Path):
    """protocols.py imports cocotb only for its async helpers; stub it so the
    pure program builders import without a cocotb install."""
    class _Any:
        def __init__(self, *a, **k): pass
        def __call__(self, *a, **k): return _Any()
        def __getattr__(self, name): return _Any()
    for name in ("cocotb", "cocotb.triggers", "cocotb.clock", "cocotb.utils", "cocotb.handle"):
        mod = types.ModuleType(name)
        mod.__getattr__ = lambda attr: _Any  # type: ignore[attr-defined]
        sys.modules.setdefault(name, mod)
    sys.modules["cocotb"].test = lambda *a, **k: (lambda f: f)  # type: ignore[attr-defined]
    sys.path.insert(0, str(upstream / "test"))
    import cocotb_tests.protocols as protocols  # noqa: E402
    return protocols


def us(n: float) -> int:
    return round(n * CLOCK_HZ / 1_000_000)


def build(P, out: Path, source: str):
    progs = []

    # ------------------------------------------------------------- UART loopback
    BIT = 24
    tx, rx = P.UART_TX_PIN, P.UART_RX_PIN
    prog = Program("cc_uart_loopback", P.uart_full_duplex(BIT), source + ":uart_full_duplex",
                   f"8N1 UART, {BIT} clocks/bit ({CLOCK_HZ // BIT} baud); TXD uio{tx} -> RXD uio{rx}")
    rng = random.Random(7)
    data = [rng.randrange(256) for _ in range(32)]
    t = prog.test("internal_loopback_32_bytes")
    t.setup(prog.image, drain=0b10, loop=loop_cfg([(tx, rx)]))
    t.write(0, data)
    t.rx(1, data)
    big = [rng.randrange(256) for _ in range(256)]
    t = prog.test("stream_256_bytes_through_8_deep_fifos")
    t.setup(prog.image, drain=0b10, loop=loop_cfg([(tx, rx)]))
    t.write(0, big)
    t.rx(1, big, timeout=us(20000))
    t = prog.test("jumper_wire_loopback")
    t.op("needs", f"jumper_uio{tx}_uio{rx}", f"a wire from Pmod TXD (uio{tx}) to RXD (uio{rx})")
    t.setup(prog.image, drain=0b10, loop=0)
    t.write(0, data[:8])
    t.rx(1, data[:8])
    progs.append(prog)

    # ------------------------------------------------------------- UART 115200 to a real adapter
    BIT = round(CLOCK_HZ / 115200)                       # 434 -> 115207 baud (+0.006 %)
    prog = Program("cc_uart_115200", P.uart_full_duplex(BIT), source + ":uart_full_duplex",
                   f"8N1 UART at 115200 baud ({BIT} clocks/bit).\n"
                   f"Board: USB-UART adapter (3.3 V): adapter RX <- uio{tx} (chip TXD),\n"
                   f"adapter TX -> uio{rx} (chip RXD), GND <-> Pmod GND; open its COM port with pe_serial.")
    t = prog.test("chip_to_terminal_and_back")
    t.setup(prog.image, drain=0b10)
    t.op("serial", BIT, tx, rx, "none")
    t.write(0, list(b"hello from the chip\r\n"))
    t.op("sread", 21, us(5000), list(b"hello from the chip\r\n"))
    t.op("swrite", list(b"ok!"))
    t.rx(1, list(b"ok!"), timeout=us(5000))
    progs.append(prog)

    # ------------------------------------------------------------- framed bursts (parity over a burst)
    BIT, WORDS = 24, 4
    prog = Program("cc_framed_burst", P.framed_burst_loop(BIT, WORDS), source + ":framed_burst_loop",
                   f"start bit, {WORDS} bytes back to back, even parity, stop; TXD uio{tx} -> RXD uio{rx}")
    t = prog.test("bursts_round_trip")
    t.setup(prog.image, drain=0b10, loop=loop_cfg([(tx, rx)]))
    for burst in ([0xA5, 0x3C, 0x00, 0xFF], [0x12, 0x34, 0x56, 0x78]):
        t.write(0, burst)
        t.rx(1, burst)
    progs.append(prog)

    # ------------------------------------------------------------- SPI master, all modes, MOSI -> MISO
    HALF, sent = 6, [0xA5, 0x3C, 0x81, 0x7E]
    prog = Program("cc_spi_loopback", P.spi_master(0, HALF, len(sent)), source + ":spi_master",
                   f"SPI master, {HALF}-clock half period; CS uio{P.SPI_CS} MOSI uio{P.SPI_MOSI} "
                   f"MISO uio{P.SPI_MISO} SCK uio{P.SPI_SCK}; MOSI looped to MISO, so every byte reads back")
    for mode in range(4):
        image = P.spi_master(mode, HALF, len(sent))
        t = prog.test(f"mode_{mode}_reads_back_what_it_sends")
        t.setup(image, drain=0b01, loop=loop_cfg([(P.SPI_MOSI, P.SPI_MISO)]), start=False)
        t.write(0, sent)
        t.op("cmds", pe_hw.START)
        t.rx(0, sent)
    progs.append(prog)

    # ------------------------------------------------------------- SPI flash JEDEC ID (real part)
    HALF = 25                                                     # 1 MHz SCK
    cmd = [0x9F, 0x00, 0x00, 0x00]
    prog = Program("cc_spi_flash_id", P.spi_master(0, HALF, len(cmd)), source + ":spi_master",
                   "Reads a SPI NOR flash's JEDEC ID (9F) at 1 MHz, mode 0. Prints the 3 ID bytes\n"
                   "(e.g. Digilent Pmod SF3 / Micron N25Q256: 20 BA 19). The first byte is don't-care.")
    t = prog.test("read_jedec_id")
    t.op("needs", "spi_flash", "SPI NOR flash on the Pmod top row (CS MOSI MISO SCK = uio0..3)")
    t.setup(prog.image, drain=0b01, start=False)
    t.write(0, cmd)
    t.op("cmds", pe_hw.START)
    t.rx(0, None, count=4)
    progs.append(prog)

    # ------------------------------------------------------------- I2C: an absent address NACKs
    HALF, ADDR = 250, 0x3A                                        # 100 kHz
    image = P.i2c_write_then_read(HALF, ADDR, [], reads=1)
    prog = Program("cc_i2c_nack", image, source + ":i2c_write_then_read",
                   f"I2C at 100 kHz, SCL uio{P.I2C_SCL} SDA uio{P.I2C_SDA}, open drain. Addresses 0x{ADDR:02X},\n"
                   "where nothing answers: the first RX entry (the address ACK bit) must be 1 = NACK.\n"
                   "On the board this needs only the pull-ups (internal ones suffice at 100 kHz).")
    t = prog.test("absent_address_is_nacked")
    t.setup(prog.image, drain=0b01)
    t.rx(0, [1], timeout=us(2000))
    progs.append(prog)

    # ------------------------------------------------------------- I2C register read (real part)
    DEV, REG = 0x4B, 0x0B                                         # e.g. ADT7420 (Pmod TMP2): ID reg 0x0B = 0xCB
    image = P.i2c_write_then_read(HALF, DEV, [REG], reads=1)
    prog = Program("cc_i2c_read_reg", image, source + ":i2c_write_then_read",
                   f"Write register 0x{REG:02X} to device 0x{DEV:02X}, repeated START, read 1 byte.\n"
                   "RX: address ACK, register ACK, read-address ACK, data (ACK 0 = acknowledged).\n"
                   "Default part: ADT7420 temperature sensor (Digilent Pmod TMP2), ID = 0xCB.\n"
                   "Edit DEV/REG in tools/cocotb_programs.py for another part.")
    t = prog.test("read_id_register")
    t.op("needs", f"i2c_0x{DEV:02x}", f"I2C device at 0x{DEV:02X} (SCL uio2, SDA uio3, with pull-ups)")
    t.setup(prog.image, drain=0b01)
    t.rx(0, [0, 0, 0, 0xCB], timeout=us(2000))
    progs.append(prog)

    # ------------------------------------------------------------- WS2812 LED strip (real part)
    bit, t0h, t1h = us(1.25), us(0.4), us(0.8)
    prog = Program("cc_ws2812", P.ws2812_transmit(bit, t0h, t1h), source + ":ws2812_transmit",
                   f"WS2812/NeoPixel on uio{P.WS2812_PIN} ({bit}/{t0h}/{t1h} clocks). 3.3 V data works\n"
                   "with most strips at short distance. Watch the LEDs, or capture uio0 with pe_ila_arm 1.")
    t = prog.test("eight_leds_red_green_blue")
    t.op("needs", "ws2812", "WS2812 strip DIN on uio0 (Pmod pin 1), strip GND to Pmod GND")
    t.setup(prog.image)
    grb = []
    for i in range(8):
        grb += [(0x00, 0x20, 0x00), (0x20, 0x00, 0x00), (0x00, 0x00, 0x20)][i % 3]
    t.write(0, grb)
    t.op("cmds", pe_hw.delay_cmds(us(100)))
    progs.append(prog)

    for p in progs:
        p.tests  # noqa: B018
        for test in p.tests:
            test.ops = pe_hw.merge_script(test.ops)
        p.write_dir(out / p.name)
        print(f"{out / p.name}: {len(p.image)} image bytes, {len(p.tests)} tests")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--upstream", default=str(Path.home() / "Documents/protocol-emulator"))
    a = ap.parse_args()
    P = import_protocols(Path(a.upstream).expanduser())
    build(P, Path(a.out), "~/Documents/protocol-emulator/test/cocotb_tests/protocols.py")


if __name__ == "__main__":
    main()
