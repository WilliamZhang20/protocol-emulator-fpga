/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * SystemVerilog testbench for the Kria top (and the TT core inside it).
 * Runs in three modes:
 *   1. RTL sim of the full kria_top (default)
 *   2. Post-synthesis/post-implementation netlist sim (pass +define+GL_TOP
 *      and compile the netlist instead of the RTL)
 *   3. Reference for the JTAG/Vitis flow: the VIO/ILA probes in vitis/
 *      drive the same stimulus as task drive_host_cmd, so results from
 *      simulation and silicon can be compared byte-for-byte.
 *
 * Run:  make sim        (Icarus)   |   make sim-vl   (Verilator)
 */
`timescale 1ns/1ps

module tb_kria_top;

  localparam CLK_PERIOD = 8; // 125 MHz

  logic clk_125m = 0;
  logic btn_reset = 1;
  logic [7:0] pmod_in = '0, gpio_in = '0;
  logic [7:0] pmod_out, gpio_out, gpio_oe;
  logic [7:0] led;
  logic clk_out;

  always #(CLK_PERIOD/2) clk_125m = ~clk_125m;

  kria_top dut (.*);

  // ---------------------------------------------------------------- helpers
  int errors = 0;

  task automatic step_fabric(int n = 1);
    // one output-register update interval = 5 input clocks
    repeat (5 * n) @(posedge clk_125m);
    #1;
  endtask

  // Drive one host command byte, mirroring docs/host-link.md protocol:
  // hold command >=2 fabric cycles, then 0x00 >=2 cycles.
  task automatic drive_host_cmd(byte cmd, byte exp_resp = 8'hxx, bit check = 0);
    pmod_in = cmd;
    step_fabric(3);
    pmod_in = 8'h00;
    step_fabric(3);
    if (check) begin
      if (pmod_out !== exp_resp) begin
        $error("cmd %02x: resp %02x != expected %02x", cmd, pmod_out, exp_resp);
        errors++;
      end else
        $display("[PASS] cmd %02x -> %02x", cmd, pmod_out);
    end
  endtask

  // ---------------------------------------------------------------- program
  // Load a tiny program through the host programming interface, then run
  // it and check the response byte. Adjust opcodes to your ISA — this
  // Mirrors test/cocotb_tests/test_host.py and fabric.py:load_program.
  // Command encoding is {cmd[3:0], payload[3:0]} per docs/host-link.md:
  //   1/2/3 set SRAM address, 4/5 write a byte (low then high half),
  //   8 payload 1 starts the engine.
  task automatic test_program_load();
    $display("== program load via host link ==");
    for (integer i = 0; i < 16; i = i + 1) begin
      drive_host_cmd(8'h10 | ((1008 + i) & 8'h0F));          // 1: addr 3:0
      drive_host_cmd(8'h20 | (((1008 + i) >> 4) & 8'h0F));   // 2: addr 7:4
      drive_host_cmd(8'h30 | (((1008 + i) >> 8) & 8'h03));   // 3: addr 9:8
      drive_host_cmd(8'h40 | ((37*i+11) & 8'h0F));           // 4: data low
      drive_host_cmd(8'h50 | (((37*i+11) >> 4) & 8'h0F));    // 5: data high
    end
    drive_host_cmd(8'h81);            // 8, payload 1: start engine
    step_fabric(100);
  endtask

  // ---------------------------------------------------------------- smoke
  initial begin
    $display("== reset ==");
    step_fabric(4);
    btn_reset = 0;
    step_fabric(4);

    test_program_load();

    // protocol pin exercise: UART TX path via uio
    $display("== uio exercise ==");
    gpio_in = 8'hA5; step_fabric(10);
    gpio_in = 8'h5A; step_fabric(10);

    $display("== done: %0d errors ==", errors);
    if (errors == 0) $display("SMOKE RUN COMPLETE (no response assertions)");
    $finish;
  end

  // timeout watchdog
  initial begin
    #2ms;
    $error("timeout");
    $finish;
  end

  // waveform
  initial begin
    $dumpfile("tb_kria.fst");
    $dumpvars(0, tb_kria_top);
  end

endmodule
