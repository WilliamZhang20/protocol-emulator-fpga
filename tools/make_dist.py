#!/usr/bin/env python3
"""Package what a Vivado machine needs into dist/protocol-emulator-fpga.zip.

Included: RTL (incl. rtl/upstream + UPSTREAM_COMMIT), constraints, the Vivado
build script, the JTAG Tcl, generated programs/ (so the Vivado machine needs
no Python), docs, tutorial. Excluded: build outputs, sim outputs, attic/.
A MANIFEST.txt inside records where everything came from.
"""
import hashlib
import subprocess
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = [
    "tutorial.md", "Makefile", "program.hex",
    "rtl", "constraints", "scripts", "jtag", "programs", "docs",
    "testbench", "sim/xilinx_stubs.v", "tools",
]
SKIP_PARTS = {"__pycache__"}
SKIP_SUFFIX = {".vvp", ".fst", ".log", ".pyc"}


def files():
    for item in INCLUDE:
        p = ROOT / item
        if p.is_file():
            yield p
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not (set(f.parts) & SKIP_PARTS) and f.suffix not in SKIP_SUFFIX:
                    yield f


def main():
    out = ROOT / "dist"
    out.mkdir(exist_ok=True)
    zpath = out / "protocol-emulator-fpga.zip"
    upstream = (ROOT / "rtl/upstream/UPSTREAM_COMMIT").read_text().strip()
    try:
        compiler = subprocess.run(
            ["git", "-C", str(Path.home() / "Documents/protocol-emulator-compiler"), "log", "-1",
             "--format=%H %cs %s"], capture_output=True, text=True).stdout.strip()
    except OSError:
        compiler = "?"
    lines = [f"protocol-emulator-fpga, packaged {time.strftime('%Y-%m-%d %H:%M')}",
             f"RTL:      protocol-emulator {upstream}",
             f"compiler: protocol-emulator-compiler {compiler}", ""]
    n = 0
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files():
            rel = f.relative_to(ROOT).as_posix()
            data = f.read_bytes()
            z.writestr(f"protocol-emulator-fpga/{rel}", data)
            lines.append(f"{hashlib.sha256(data).hexdigest()[:16]}  {rel}")
            n += 1
        z.writestr("protocol-emulator-fpga/MANIFEST.txt", "\n".join(lines) + "\n")
    print(f"{zpath}: {n} files, {zpath.stat().st_size // 1024} KiB")
    print("Copy it to the Vivado machine and unzip; the folder inside is protocol-emulator-fpga/.")


if __name__ == "__main__":
    main()
