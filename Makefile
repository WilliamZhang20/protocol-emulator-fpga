# Protocol emulator ASIC prototype on Kria KV260.  Start here: tutorial.md
#
#   make sync        copy the tapeout RTL (UPSTREAM_REF) into rtl/upstream
#   make check-sync  fail if rtl/upstream differs from UPSTREAM_REF
#   make lint        verilator lint of kria_top (Xilinx IP stubbed)
#   make sim         host-link smoke test (jtag/stimulus.txt) in iverilog
#   make programs    compile + convert all programs into programs/<name>/
#   make hwsim       run every programs/<name> test in simulation (PROG=name for one)
#   make vivado      bitstream + debug probes -> build_vivado/out/
#   make dist        zip of everything the Vivado machine needs -> dist/
#   make jtag        (Linux + Vivado only) program the board, replay jtag/stimulus.txt

UPSTREAM     ?= $(HOME)/Documents/protocol-emulator
UPSTREAM_REF ?= arch/spatial8x4
COMPILER     ?= $(HOME)/Documents/protocol-emulator-compiler
OSSCAD       ?= $(UPSTREAM)/.tools/oss-cad-suite/bin
VIVADO       ?= vivado
# xsdb ships with Vivado; xsct with Vitis. Either runs jtag/set_pl_clk.tcl.
XSCT         ?= $(or $(shell command -v xsdb),$(shell command -v xsct),xsdb)
HW_SERVER    ?= localhost:3121
SHELL := /bin/bash

# Same list as upstream info.yaml, minus program_memory.v (replaced by BRAM).
UPSTREAM_FILES = project.v protocol_emulator_core.v controller.v \
  fabric_control_actor.v fabric_timer.v fabric_shifter.v fabric_counter.v \
  fabric_crc.v fabric_edge.v fabric_logic.v byte_tile.v config_bank.v \
  byte_fifo.v host_interface.v

CORE_RTL    = $(addprefix rtl/upstream/,$(UPSTREAM_FILES)) rtl/program_memory_bram.v
HARNESS_RTL = $(CORE_RTL) rtl/pe_host_bridge.v rtl/pe_harness.v
TOP_RTL     = $(HARNESS_RTL) rtl/kria_top.v sim/xilinx_stubs.v

.PHONY: sync check-sync lint sim stimulus vivado clock program jtag clean \
        programs convert hwsim cosim dist check

# ---------------------------------------------------------------- upstream RTL
sync:
	@git -C $(UPSTREAM) rev-parse --verify -q $(UPSTREAM_REF) >/dev/null \
	   || { echo "no ref $(UPSTREAM_REF) in $(UPSTREAM) (git fetch?)"; exit 1; }
	@for f in $(UPSTREAM_FILES); do \
	   git -C $(UPSTREAM) show $(UPSTREAM_REF):src/$$f > rtl/upstream/$$f || exit 1; done
	@git -C $(UPSTREAM) log -1 --format='%H %cs %s' $(UPSTREAM_REF) > rtl/upstream/UPSTREAM_COMMIT
	@echo "synced $(UPSTREAM_REF): $$(cat rtl/upstream/UPSTREAM_COMMIT)"
	@diff <(echo $(UPSTREAM_FILES) program_memory.v | tr ' ' '\n' | sort) \
	      <(git -C $(UPSTREAM) show $(UPSTREAM_REF):info.yaml | grep -o '"[a-z_]*\.v"' | tr -d '"' | sort) \
	   && echo "file list matches info.yaml" \
	   || echo "WARNING: upstream info.yaml file list changed; update UPSTREAM_FILES"

check-sync:
	@for f in $(UPSTREAM_FILES); do \
	   git -C $(UPSTREAM) show $(UPSTREAM_REF):src/$$f | cmp -s - rtl/upstream/$$f \
	   || { echo "OUT OF SYNC with $(UPSTREAM_REF): $$f (run make sync)"; exit 1; }; done
	@echo "rtl/upstream == $(UPSTREAM_REF) ($$(git -C $(UPSTREAM) rev-parse --short $(UPSTREAM_REF)))"

# ---------------------------------------------------------------- checks
lint:
	env -u VERILATOR_ROOT $(OSSCAD)/verilator --lint-only -Wall -Wno-DECLFILENAME \
	  -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-MULTITOP -Wno-PROCASSINIT \
	  $(TOP_RTL) --top-module kria_top

stimulus:
	python3 jtag/gen_stimulus.py > jtag/stimulus.txt

sim:
	$(OSSCAD)/iverilog -g2012 -o sim/tb_host_link.vvp $(CORE_RTL) testbench/tb_host_link.sv
	set -o pipefail; $(OSSCAD)/vvp -n sim/tb_host_link.vvp $(SIMARGS) | tee sim/tb_host_link.log | tail -5
	@grep -q '^PASS' sim/tb_host_link.log
	@! grep -q '^ERROR' sim/tb_host_link.log || { echo 'BRAM model assertion fired'; exit 1; }

# everything that can be checked without Vivado
check: check-sync lint sim hwsim

# ---------------------------------------------------------------- real programs
# programs/<name>/ = image.hex + tests (.hwtest for the board, .hwmem for sim)
programs:
	COMPILER=$(COMPILER) UPSTREAM=$(UPSTREAM) tools/build_programs.sh
	python3 tools/cocotb_programs.py --upstream $(UPSTREAM) programs

# re-convert already-compiled plans after a tools/pe_hw.py change
convert:
	@for d in build/spt/*/; do n=$$(basename $$d); \
	  python3 tools/pe_hw.py plan $$d/target/plan.json programs/$$n --source "$$(cat $$d/source.txt)" \
	    --board $$d/main.board; done
	python3 tools/cocotb_programs.py --upstream $(UPSTREAM) programs

VL_DIR = build/vl_hwtest
$(VL_DIR)/Vtb_hwtest: $(HARNESS_RTL) testbench/tb_hwtest.sv
	@mkdir -p build
	env -u VERILATOR_ROOT $(OSSCAD)/verilator --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint \
	  -Wno-style -Wno-TIMESCALEMOD --top-module tb_hwtest -Mdir $(VL_DIR) \
	  $(HARNESS_RTL) testbench/tb_hwtest.sv > $(VL_DIR).log 2>&1 || { tail -30 $(VL_DIR).log; exit 1; }

#   make hwsim            all programs
#   make hwsim PROG=uart  one program
PROG ?= $(sort $(notdir $(patsubst %/,%,$(dir $(wildcard programs/*/tests.hwmem)))))
hwsim: $(VL_DIR)/Vtb_hwtest
	@fail=0; for p in $(PROG); do \
	  $(VL_DIR)/Vtb_hwtest +PROG=programs/$$p > sim/hwsim_$$p.log 2>&1; \
	  r=$$(grep -E '^== [0-9]+ passed' sim/hwsim_$$p.log); \
	  printf '%-24s %s\n' $$p "$$r"; grep -E ' FAIL ' sim/hwsim_$$p.log; \
	  grep -q '^PASS' sim/hwsim_$$p.log || grep -q ' 0 passed, 0 failed' sim/hwsim_$$p.log || fail=1; \
	done; exit $$fail

# the board's Tcl runner (jtag/pe_jtag.tcl) against the RTL, VIO modelled
#   make cosim            all programs     make cosim PROG=uart   some
cosim:
	tools/cosim/cosim.sh $(if $(filter command line,$(origin PROG)),$(PROG))

# ---------------------------------------------------------------- Vivado / board
vivado:
	$(VIVADO) -mode batch -nojournal -log build_vivado/vivado.log -source scripts/vivado_build.tcl

clock:
	$(XSCT) jtag/set_pl_clk.tcl $(HW_SERVER) 50

program:
	$(VIVADO) -mode batch -nojournal -nolog -source jtag/run_stimulus.tcl \
	  -tclargs -url $(HW_SERVER) -program -no-stim

jtag:
	$(VIVADO) -mode batch -nojournal -nolog -source jtag/run_stimulus.tcl \
	  -tclargs -url $(HW_SERVER) -program -stim jtag/stimulus.txt

dist:
	python3 tools/make_dist.py

clean:
	rm -rf sim/*.vvp sim/*.fst sim/*.log build/vl_hwtest*
