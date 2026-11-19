#!/usr/bin/env python3
"""Hardware test format for the KV260 prototype, shared by simulation and silicon.

A *program* is an SRAM image plus tests. Each test is a list of ops that both
runners execute the same way:

  testbench/tb_hwtest.sv   reads  <prog>/tests.hwmem  (byte encoding, $readmemh)
  jtag/pe_jtag.tcl         reads  <prog>/tests.hwtest (text, one op per line)

Ops (text form; <hex> is a byte string like 55a300, '-' means "don't check"):

  test <name>
  skip <reason>                       test cannot run on this platform
  needs <device> <description>        board-only test: the board runs it when
                                      <device> is listed as connected; sim skips it
  reset                               chip + bridge reset, bridge on
  drain <mask>                        RX channels the bridge drains (bit k = channel k)
  loop <hex32>                        pad loopback config (pe_harness loop_cfg)
  cmds <hex>                          host-link command bytes for the bridge script queue;
                                      00 nn is a script delay of nn*16 clocks
  idle <timeout>                      wait until the script queue has been played
  wait <cycles>                       let the chip run
  rx <ch> <count> <timeout> <hex|->   collect count bytes drained from channel ch
  packet <ch> <timeout> <hex|-> <err> collect up to an eop byte; err 0/1/- (any)
  reply <ch> <timeout> <hex|-> <status>
                                      a call's answer: bytes up to the eop entry;
                                      status 'ok' or a failure code (decimal)
  flush <ch> <settle> <hex|->         everything channel ch holds after settle cycles
  serial <bit_cycles> <chip_tx_pad> <chip_rx_pad> <none|even|odd>
                                      a UART device (8 data bits, 1 stop) on those pads
                                      (sim: model; board: a USB-UART adapter on a COM port)
  swrite <hex>                        the UART device sends bytes to the chip
  sread <count> <timeout> <hex|->     the UART device must receive these bytes
  end

Timeouts are in chip clocks (50 MHz); the board converts them to wall time
with a floor, since JTAG itself is slow.

Usage:
  pe_hw.py plan <plan.json> <out_dir> [--name N]   convert a `spatial run --test` plan
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

CLOCK_HZ = 50_000_000
DEFAULT_TIMEOUT = 200_000

OPS = {"end": 0x00, "test": 0x01, "reset": 0x02, "loop": 0x03, "drain": 0x04,
       "cmds": 0x05, "wait": 0x06, "rx": 0x07, "packet": 0x08, "reply": 0x09,
       "flush": 0x0A, "serial": 0x0B, "swrite": 0x0C, "sread": 0x0D,
       "skip": 0x0E, "idle": 0x0F, "needs": 0x10}


# ------------------------------------------------------------------ host-link encoding
def hl(cmd: int, payload: int = 0) -> int:
    return ((cmd & 0xF) << 4) | (payload & 0xF)


def load_cmds(image: list[int], address: int = 0) -> list[int]:
    out = [hl(1, address), hl(2, address >> 4), hl(3, address >> 8)]
    for b in image:
        out += [hl(4, b), hl(5, b >> 4)]
    return out


def push_cmds(channel: int, data: list[int], eop_last: bool = False) -> list[int]:
    out = [hl(0xE, channel)]
    for i, b in enumerate(data):
        last = eop_last and i == len(data) - 1
        out += [hl(6, b), hl(0xF if last else 7, b >> 4)]
    return out


def delay_cmds(cycles: int) -> list[int]:
    """Bridge script delay: 0x00, n pauses n*16 clocks (rounded up)."""
    out, units = [], (cycles + 15) // 16
    while units > 0:
        n = min(units, 255)
        out += [0x00, n]
        units -= n
    return out


START = [hl(8, 1)]
STOP = [hl(8, 2)]


def hexs(data) -> str:
    return "-" if data is None else ("".join(f"{b & 0xFF:02x}" for b in data) or "-")


# ------------------------------------------------------------------ builder
class Test:
    def __init__(self, name: str):
        self.name = name
        self.ops: list[tuple] = []
        self.skipped: str | None = None

    def op(self, *args):
        self.ops.append(args)
        return self

    def skip(self, reason: str):
        self.skipped = reason
        return self

    # conveniences
    def setup(self, image: list[int], drain: int = 0, loop: int = 0, start: bool = True):
        self.op("reset")
        self.op("drain", drain)
        self.op("loop", loop)
        self.op("cmds", load_cmds(image))
        if start:
            self.op("cmds", START)
        return self

    def write(self, ch, data, eop_last=False):
        return self.op("cmds", push_cmds(ch, list(data), eop_last))

    def rx(self, ch, data=None, count=None, timeout=DEFAULT_TIMEOUT):
        count = len(data) if count is None else count
        return self.op("rx", ch, count, timeout, data)


def loop_cfg(wires) -> int:
    """wires: iterable of (src_pad, dst_pad), the compiler's `wire src -> dst`."""
    cfg = 0
    for src, dst in wires:
        cfg |= (0x8 | (src & 7)) << (4 * dst)
    return cfg


class Program:
    def __init__(self, name: str, image: list[int], source: str = "", notes: str = ""):
        self.name, self.image, self.source, self.notes = name, list(image), source, notes
        self.tests: list[Test] = []

    def test(self, name: str) -> Test:
        t = Test(name)
        self.tests.append(t)
        return t

    # ---------------- text
    def text(self) -> str:
        lines = [f"# program {self.name}  ({len(self.image)} image bytes)"]
        if self.source:
            lines.append(f"# source: {self.source}")
        for n in self.notes.splitlines():
            lines.append(f"# {n}")
        for t in self.tests:
            lines.append("")
            lines.append(f"test {t.name.replace(' ', '_')}")
            if t.skipped:
                lines.append(f"skip {t.skipped}")
                continue
            for op in t.ops:
                lines.append(_op_text(op))
        lines.append("end")
        return "\n".join(lines) + "\n"

    # ---------------- bytes for the testbench
    def mem(self) -> list[int]:
        out: list[int] = []
        for i, t in enumerate(self.tests):
            out += [OPS["test"], *_u16(i)]
            if t.skipped:
                out.append(OPS["skip"])
                continue
            for op in t.ops:
                out += _op_mem(op)
        out.append(OPS["end"])
        return out

    def write_dir(self, out: Path):
        out.mkdir(parents=True, exist_ok=True)
        (out / "image.hex").write_text("".join(f"{b:02x}\n" for b in self.image))
        (out / "tests.hwtest").write_text(self.text())
        (out / "tests.hwmem").write_text("".join(f"{b:02x}\n" for b in self.mem()))
        (out / "tests.names").write_text("".join(t.name.replace(" ", "_") + "\n" for t in self.tests))


def _u16(v): return [v & 0xFF, (v >> 8) & 0xFF]
def _u32(v): return [(v >> s) & 0xFF for s in (0, 8, 16, 24)]


def _op_text(op) -> str:
    k, *a = op
    if k in ("reset",):
        return k
    if k == "needs":
        return f"needs {a[0]} {a[1]}"
    if k == "loop":
        return f"loop {a[0]:08x}"
    if k == "drain":
        return f"drain {a[0]}"
    if k in ("cmds", "swrite"):
        return f"{k} {hexs(a[0])}"
    if k in ("wait", "idle"):
        return f"{k} {a[0]}"
    if k == "rx":
        ch, count, timeout, data = a
        return f"rx {ch} {count} {timeout} {hexs(data)}"
    if k == "packet":
        ch, timeout, data, err = a
        return f"packet {ch} {timeout} {hexs(data)} {'-' if err is None else int(err)}"
    if k == "reply":
        ch, timeout, data, status = a
        return f"reply {ch} {timeout} {hexs(data)} {status}"
    if k == "flush":
        ch, settle, data = a
        return f"flush {ch} {settle} {hexs(data)}"
    if k == "serial":
        return "serial {} {} {} {}".format(*a)
    if k == "sread":
        count, timeout, data = a
        return f"sread {count} {timeout} {hexs(data)}"
    raise ValueError(k)


def _bytes_field(data):
    """has_expect, len16, bytes"""
    if data is None:
        return [0, 0, 0]
    return [1, *_u16(len(data)), *data]


def _op_mem(op) -> list[int]:
    k, *a = op
    c = OPS[k]
    if k == "reset":
        return [c]
    if k == "needs":
        return [c]
    if k == "loop":
        return [c, *_u32(a[0])]
    if k == "drain":
        return [c, a[0]]
    if k in ("cmds", "swrite"):
        return [c, *_u16(len(a[0])), *a[0]]
    if k in ("wait", "idle"):
        return [c, *_u32(a[0])]
    if k == "rx":
        ch, count, timeout, data = a
        return [c, ch, *_u16(count), *_u32(timeout), *_bytes_field(data)]
    if k == "packet":
        ch, timeout, data, err = a
        return [c, ch, *_u32(timeout), *_bytes_field(data), 2 if err is None else int(err)]
    if k == "reply":
        ch, timeout, data, status = a
        return [c, ch, *_u32(timeout), *_bytes_field(data), 0 if status == "ok" else 1,
                0 if status == "ok" else int(status)]
    if k == "flush":
        ch, settle, data = a
        return [c, ch, *_u32(settle), *_bytes_field(data)]
    if k == "serial":
        bit, txp, rxp, parity = a
        return [c, *_u16(bit), txp, rxp, ("none", "even", "odd").index(parity)]
    if k == "sread":
        count, timeout, data = a
        return [c, *_u16(count), *_u32(timeout), *_bytes_field(data)]
    raise ValueError(k)


# ------------------------------------------------------------------ compiler plans
def _host_value(expr, args, elements):
    if isinstance(expr, int):
        return expr
    if "param" in expr:
        return args[expr["param"]]
    if "len" in expr:
        return len(args[expr["len"]])
    if "element" in expr:
        return elements[expr["element"]]
    a, b = _host_value(expr["a"], args, elements), _host_value(expr["b"], args, elements)
    return {"+": a + b, "-": a - b, "<<": a << b, ">>": a >> b, "|": a | b,
            "&": a & b, "^": a ^ b}[expr["op"]]


def _call_bytes(sends, args, elements=None):
    """Mirror of protocol-emulator-compiler/sim/harness.py call_bytes."""
    elements = elements or {}
    out = []
    for item in sends:
        if "value" in item:
            out.append(_host_value(item["value"], args, elements))
        elif "for" in item:
            items = args[item["in"]]
            out.append(len(items))
            for element in items:
                out += _call_bytes(item["body"], args, {**elements, item["for"]: element})
        else:
            count = _host_value(item["repeat"], args, elements)
            out.append(count)
            for _ in range(max(count, 0)):
                out += _call_bytes(item["body"], args, elements)
    return out


def _as_bytes(v):
    if isinstance(v, str):
        return list(v.encode())
    return list(v)


def read_board(path) -> dict:
    """A .board sidecar: `peer <name> <device id> <what to connect>` lines name
    the test peers that are real parts on the board."""
    real = {}
    if path and Path(path).exists():
        for line in Path(path).read_text().splitlines():
            parts = line.split(None, 3)
            if len(parts) >= 3 and parts[0] == "peer":
                real[parts[1]] = (parts[2], parts[3] if len(parts) > 3 else parts[2])
    return real


def from_plan(plan: dict, name: str, source: str = "", real_peers: dict | None = None) -> Program:
    real_peers = real_peers or {}
    if plan.get("clock_hz", CLOCK_HZ) != CLOCK_HZ:
        raise SystemExit(f"{name}: plan clock {plan['clock_hz']} Hz != {CLOCK_HZ} Hz (`clock 50 MHz` in the .spt)")
    streams = plan["streams"]
    calls = plan["calls"]
    drain = 0
    for s in streams.values():
        if s["direction"] == "from_chip":
            drain |= 1 << s["channel"]
    if calls.get("channel") is not None:
        drain |= 1 << calls["channel"]
        for f in calls["functions"].values():
            if isinstance(f["result"], dict):
                drain |= 1 << f["result"]["channel"]
    pins = plan.get("pins", {})
    notes = "pins: " + ", ".join(f"{n}=uio{p}" for n, p in sorted(pins.items(), key=lambda x: x[1]))
    if plan.get("invariants"):
        notes += "\n`always` invariants are checked in RTL simulation only, not on the board"
    prog = Program(name, plan["image"], source, notes)

    for t in plan["tests"]:
        test = prog.test(t["name"])
        timeout = t.get("step_timeout_cycles") or DEFAULT_TIMEOUT
        uart = None
        unsupported = []
        real = {}
        for p in t["peers"]:
            if p["name"] in real_peers:
                real[p["name"]] = real_peers[p["name"]]
            elif p["kind"] == "uart_device" and uart is None:
                a = p["args"]
                parity = a.get("parity", "none")
                if isinstance(parity, list):
                    parity = bytes(parity).decode()
                uart = (p["name"], a["bit"], a["from_chip"]["pin"], a["to_chip"]["pin"], parity)
            else:
                unsupported.append(f"{p['kind']} `{p['name']}`")
        if unsupported:
            test.skip("needs device " + ", ".join(unsupported) + " (no board equivalent yet)")
            continue
        if any(s.get("target", {}).get("peer") in real and s["op"].startswith("write") for s in t["steps"]):
            test.skip("writes through a real-part peer, which the board cannot do")
            continue
        for device, what in real.values():
            test.op("needs", device, what)
        test.setup(prog.image, drain=drain, loop=loop_cfg(t["wires"]))
        if uart:
            test.op("serial", uart[1], uart[2], uart[3], uart[4])
        for step in t["steps"]:
            target = step.get("target", {})
            peer = target.get("peer")
            op = step["op"]
            if peer in real:
                continue        # observing a real part's side is not possible
            expect = step.get("expect")
            if op in ("write", "write_packet") and peer:
                test.op("idle", timeout)       # earlier script waits come first
                test.op("swrite", _as_bytes(step["bytes"]))
            elif op == "write":
                test.write(streams[target["stream"]]["channel"], _as_bytes(step["bytes"]))
            elif op == "write_packet":
                test.write(streams[target["stream"]]["channel"], _as_bytes(step["bytes"]), eop_last=True)
            elif op == "read" and peer:
                test.op("sread", step["count"], timeout, None if expect is None else _as_bytes(expect))
            elif op == "read":
                test.op("rx", streams[target["stream"]]["channel"], step["count"], timeout,
                        None if expect is None else _as_bytes(expect))
            elif op == "read_packet":
                ch = streams[target["stream"]]["channel"]
                if expect is None:
                    test.op("packet", ch, timeout, None, None)
                else:
                    test.op("packet", ch, timeout, _as_bytes(expect["data"]), bool(expect["error"]))
            elif op == "call":
                fn = calls["functions"][step["function"]]
                payload = [fn["id"], *_call_bytes(fn["sends"], step["args"]), 0]
                if any(not 0 <= v <= 255 for v in payload):
                    raise SystemExit(f"{name}/{t['name']}: call payload {payload} does not fit in bytes")
                test.write(calls["channel"], payload, eop_last=True)
                for param in fn["params"]:
                    if param["type"] == "bytes" and param["via"] is not None:
                        test.write(param["via"], _as_bytes(step["args"][param["name"]]))
                result_ch = fn["result"]["channel"] if isinstance(fn["result"], dict) else None
                if "fails" in step:
                    status = str(calls["fails"].index(step["fails"]) + 1)
                    data = None
                else:
                    status = "ok"
                    data = None if (expect is None or result_ch is not None) else _as_bytes(expect)
                test.op("reply", calls["channel"], timeout, data, status)
                if result_ch is not None:
                    test.op("flush", result_ch, 2000,
                            None if (expect is None or "fails" in step) else _as_bytes(expect))
            elif op == "wait":
                # Played by the bridge, so it is timed relative to the
                # surrounding host commands as in the compiler's simulation.
                test.op("cmds", delay_cmds(step["cycles"]))
            else:
                raise SystemExit(f"{name}/{t['name']}: unknown step op {op}")
        test.ops = merge_script(test.ops)
    return prog


def merge_script(ops):
    """Merge runs of `cmds` into one queue write, moving the `reply` checks
    in between to after the run. Over JTAG every op costs ~0.1 s, so only
    commands that sit in the bridge queue together keep their chip-speed
    spacing (e.g. a write, a 2 us script delay, then a cancel call)."""
    out, run, replies = [], None, []
    for op in ops:
        if op[0] == "cmds":
            if run is None:
                run = list(op[1])
            else:
                run += op[1]
        elif op[0] == "reply" and run is not None:
            replies.append(op)
        else:
            if run is not None:
                out.append(("cmds", run))
                out += replies
                run, replies = None, []
            out.append(op)
    if run is not None:
        out.append(("cmds", run))
        out += replies
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("plan")
    p.add_argument("out")
    p.add_argument("--name")
    p.add_argument("--source", default="")
    p.add_argument("--board", help=".board sidecar naming real-part peers")
    a = ap.parse_args(argv)
    if a.cmd == "plan":
        plan = json.loads(Path(a.plan).read_text())
        out = Path(a.out)
        prog = from_plan(plan, a.name or out.name, a.source, read_board(a.board))
        prog.write_dir(out)
        skipped = sum(1 for t in prog.tests if t.skipped)
        print(f"{out}: {len(prog.image)} image bytes, {len(prog.tests)} tests ({skipped} skipped)")


if __name__ == "__main__":
    sys.exit(main())
