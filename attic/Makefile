# FPGA package for Kria KV260 — sim + lint + (optionally) Vivado.
# RTL is copied from ../protocol-emulator/src with the SRAM swapped for BRAM.

OSSCAD ?= $(HOME)/Documents/protocol-emulator/.tools/oss-cad-suite/bin
VIVADO ?= vivado
SHELL := /bin/bash

RTL = rtl/project.v rtl/program_memory_bram.v rtl/host_interface.v \
      rtl/protocol_emulator_core.v rtl/px8_controller.v rtl/byte_fifo.v \
      rtl/byte_tile.v rtl/config_bank.v rtl/fabric_counter.v rtl/fabric_crc.v \
      rtl/fabric_logic.v rtl/fabric_shifter.v rtl/fabric_timer.v \
      rtl/kria_top.v

.PHONY: lint sim synth-check clean vivado

lint:
	env -u VERILATOR_ROOT $(OSSCAD)/verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-PROCASSINIT -Wno-BLKSEQ -Wno-PINCONNECTEMPTY $(RTL) --top-module kria_top

sim: sim/program.hex
	$(OSSCAD)/iverilog -g2012 -o sim/tb_kria.vvp $(RTL) testbench/tb_kria_top.sv
	set -o pipefail; $(OSSCAD)/vvp sim/tb_kria.vvp 2>&1 | tail -20

# synthesis check with yosys (quick structural sanity before Vivado)
synth-check:
	$(OSSCAD)/yosys -p "read_verilog $(RTL); synth -top kria_top; stat"

vivado:
	$(VIVADO) -mode batch -source scripts/vivado_build.tcl

clean:
	rm -rf sim/*.vvp sim/*.fst sim/*.vcd
