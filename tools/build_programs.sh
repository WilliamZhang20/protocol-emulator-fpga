#!/usr/bin/env bash
# Build programs/<name>/ for every Spatial source listed below:
#   1. `spatial run --test` (compiler's own RTL simulation, writes plan.json)
#   2. tools/pe_hw.py plan -> programs/<name>/{image.hex,tests.hwtest,tests.hwmem}
# Sources: the compiler's examples plus this repo's board-oriented programs in
# programs/spt/. Work happens in build/spt/ so the compiler repo is untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

COMPILER=${COMPILER:-$HOME/Documents/protocol-emulator-compiler}
UPSTREAM=${UPSTREAM:-$HOME/Documents/protocol-emulator}
SPATIAL=${SPATIAL:-$COMPILER/target/release/spatial}
export SPATIAL_RTL_DIR=${SPATIAL_RTL_DIR:-$UPSTREAM}

if [ ! -x "$SPATIAL" ]; then
    (cd "$COMPILER" && cargo build --release --offline)
fi

sources=()
for name in ${EXAMPLES:-loopback uart spi i2c usb packets packet_errors byte_framing byte_filter byte_xor stored_bytes jtag swd ps2 protocol_control}; do
    sources+=("$COMPILER/examples/$name.spt")
done
for f in programs/spt/*.spt; do [ -e "$f" ] && sources+=("$f"); done

fail=0
for src in "${sources[@]}"; do
    name=$(basename "$src" .spt)
    work=build/spt/$name
    rm -rf "$work"; mkdir -p "$work"
    cp "$src" "$work/main.spt"
    echo "${src/#$HOME/~}" > "$work/source.txt"
    printf '%-24s ' "$name"
    if ! (cd "$work" && "$SPATIAL" run --test > run.log 2>&1); then
        echo "COMPILER TESTS FAILED (see $work/run.log)"; fail=1; continue
    fi
    summary=$(grep -E '^\s+[0-9]+ passed' "$work/run.log" | head -1 | xargs)
    board=${src%.spt}.board
    if [ -f "$board" ]; then cp "$board" "$work/main.board"; fi
    python3 tools/pe_hw.py plan "$work/target/plan.json" "programs/$name" \
        --source "${src/#$HOME/~}" --board "$work/main.board" | sed 's/^/  /' | tr -d '\n'
    echo "   [compiler sim: $summary]"
done
exit $fail
