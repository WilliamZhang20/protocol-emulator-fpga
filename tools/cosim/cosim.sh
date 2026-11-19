#!/usr/bin/env bash
# Run jtag/pe_jtag.tcl (the board's runner) against the RTL: see tb_vio_server.sv.
# Usage: tools/cosim/cosim.sh [program ...]     (no args: every program)
set -euo pipefail
cd "$(dirname "$0")/../.."
OSSCAD=${OSSCAD:-$HOME/Documents/protocol-emulator/.tools/oss-cad-suite/bin}
RTL="$(ls rtl/upstream/*.v) rtl/program_memory_bram.v rtl/pe_host_bridge.v rtl/pe_harness.v"
OUT=build/cosim
mkdir -p $OUT
if [ ! -x $OUT/Vtb_vio_server ] || [ -n "$(find $RTL tools/cosim/tb_vio_server.sv -newer $OUT/Vtb_vio_server)" ]; then
    env -u VERILATOR_ROOT "$OSSCAD/verilator" --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint \
        -Wno-style -Wno-TIMESCALEMOD --top-module tb_vio_server -Mdir $OUT \
        $RTL tools/cosim/tb_vio_server.sv > $OUT/build.log 2>&1 || { tail -30 $OUT/build.log; exit 1; }
fi
to=$OUT/to_sim.$$; from=$OUT/from_sim.$$
mkfifo "$to" "$from"
trap 'unlink "$to"; unlink "$from"' EXIT
$OUT/Vtb_vio_server +IN="$to" +OUT="$from" +LAT=${COSIM_LAT:-300} > $OUT/server.log 2>&1 &
tclsh tools/cosim/run.tcl "$to" "$from" "$@"
