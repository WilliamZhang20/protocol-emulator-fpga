/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Replays jtag/stimulus.txt against tt_um_protocol_emulator (upstream RTL +
 * FPGA BRAM) at the ASIC clock, the same way jtag/run_stimulus.tcl replays it
 * on the KV260 through the VIO: hold the command, hold 8'h00, then compare
 * uo_out. A pass here and a pass on hardware mean silicon == simulation.
 *
 * Plusargs: +STIM=<file> (default jtag/stimulus.txt)  +HOLD=<clocks> (default 4)
 */
`timescale 1ns/1ps
`default_nettype none

module tb_host_link;
  localparam real CLK_NS = 20.0;  // 50 MHz, info.yaml clock_hz

  logic       clk = 0;
  logic       rst_n = 0;
  logic [7:0] ui_in = 8'h00, uio_in = 8'h00;
  wire  [7:0] uo_out, uio_out, uio_oe;

  always #(CLK_NS/2) clk = ~clk;

  tt_um_protocol_emulator dut (
      .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
      .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));

  int errors = 0, checks = 0, cmds = 0, hold = 4;
  string stim = "jtag/stimulus.txt";

  initial begin
    int fd, n, cmd, exp;
    string line;
    void'($value$plusargs("STIM=%s", stim));
    void'($value$plusargs("HOLD=%d", hold));

    repeat (16) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    fd = $fopen(stim, "r");
    if (fd == 0) $fatal(1, "cannot open %s", stim);
    while (!$feof(fd)) begin
      if ($fgets(line, fd) == 0) break;
      if (line.len() == 0 || line[0] == "#" || line[0] == "\n") continue;
      n = $sscanf(line, "%h %h", cmd, exp);
      if (n < 1) continue;
      cmds++;
      ui_in = cmd[7:0];
      repeat (hold) @(posedge clk);
      ui_in = 8'h00;
      repeat (hold) @(posedge clk);
      #1;
      if (n == 2) begin
        checks++;
        if (uo_out !== exp[7:0]) begin
          errors++;
          $display("[FAIL] line cmd %02x: uo_out %02x expected %02x", cmd, uo_out, exp);
        end
      end
    end
    $fclose(fd);
    $display("== %0d commands, %0d checks, %0d errors ==", cmds, checks, errors);
    if (errors == 0 && checks > 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end

  initial begin
    #50ms;
    $fatal(1, "timeout");
  end

  initial if ($test$plusargs("WAVES")) begin
    $dumpfile("sim/tb_host_link.fst");
    $dumpvars(0, tb_host_link);
  end
endmodule

`default_nettype wire
