/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Co-simulation of the board's JTAG Tcl (jtag/pe_jtag.tcl) against the RTL:
 * this model plays the VIO. vio_mock.tcl sends one line per VIO access over
 * a named pipe:
 *   W <ui> <rst> <br_en> <drain> <loop> <wr_data> <wr_count> <wr_tog> <rd_count> <rd_tog> <fan> <hold>
 *        commit all output probes (hex), then LAT clocks pass  -> "OK"
 *   R    LAT clocks pass, then input probes                    -> "I <uo> <uio_in> <uio_out> <uio_oe>
 *                                                                  <rd_data> <rd_valid> <q_level> <r_level> <status> <pad_in>"
 *   T <n>  n clocks pass                                        -> "OK"
 *   Q    quit
 * Pads are pulled up, as on the board with nothing connected.
 *   +IN=<pipe> +OUT=<pipe> +LAT=<clocks per JTAG access, default 300>
 */
`timescale 1ns/1ps
`default_nettype none

module tb_vio_server;
  logic clk = 0;
  always #10 clk = ~clk;

  logic [7:0]   ui = 0;
  logic         rst = 0, br_en = 0, wr_tog = 0, rd_tog = 0, hold = 0;
  logic [1:0]   drain = 0;
  logic [31:0]  loop_cfg = 0;
  logic [127:0] wr_data = 0;
  logic [4:0]   wr_count = 0;
  logic [3:0]   rd_count = 0, fan = 9;
  wire  [127:0] rd_data;
  wire  [3:0]   rd_valid;
  wire  [12:0]  q_level, r_level;
  wire  [7:0]   status, uo, uio_in, uio_out, uio_oe, ui_mon;
  wire          fan_en_b, rst_n;
  wire  [7:0]   pad_in;

  genvar g;
  generate for (g = 0; g < 8; g++) begin : g_pad
    assign pad_in[g] = uio_oe[g] ? uio_out[g] : 1'b1;
  end endgenerate

  pe_harness dut (
      .clk(clk), .soft_reset(rst), .raw_ui(ui), .uo_out(uo),
      .br_en(br_en), .br_drain(drain), .br_hold(hold), .br_wr_data(wr_data), .br_wr_count(wr_count),
      .br_wr_tog(wr_tog), .br_rd_count(rd_count), .br_rd_tog(rd_tog),
      .br_rd_data(rd_data), .br_rd_valid(rd_valid), .br_q_level(q_level),
      .br_r_level(r_level), .br_status(status), .loop_cfg(loop_cfg), .pad_in(pad_in),
      .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe), .fan_duty(fan),
      .fan_en_b(fan_en_b), .rst_n_out(rst_n), .ui_in_out(ui_mon));

  initial begin
    string inp, outp, line;
    int fin, fout, lat, n;
    logic [127:0] v[12];
    lat = 300;
    void'($value$plusargs("LAT=%d", lat));
    if (!$value$plusargs("IN=%s", inp) || !$value$plusargs("OUT=%s", outp)) $fatal(1, "+IN= +OUT= required");
    fin = $fopen(inp, "r");
    fout = $fopen(outp, "w");
    forever begin
      if ($fgets(line, fin) == 0) break;
      case (line[0])
        "W": begin
          n = $sscanf(line, "W %h %h %h %h %h %h %h %h %h %h %h %h",
                      v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11]);
          if (n != 12) $fatal(1, "bad W line (%0d fields): %s", n, line);
          @(negedge clk);
          ui = v[0][7:0]; rst = v[1][0]; br_en = v[2][0]; drain = v[3][1:0]; loop_cfg = v[4][31:0];
          wr_data = v[5]; wr_count = v[6][4:0]; wr_tog = v[7][0]; rd_count = v[8][3:0];
          rd_tog = v[9][0]; fan = v[10][3:0]; hold = v[11][0];
          repeat (lat) @(posedge clk);
          $fwrite(fout, "OK\n"); $fflush(fout);
        end
        "R": begin
          repeat (lat) @(posedge clk);
          #1;
          $fwrite(fout, "I %h %h %h %h %h %h %h %h %h %h\n", uo, uio_in, uio_out, uio_oe,
                  rd_data, rd_valid, q_level, r_level, status, pad_in);
          $fflush(fout);
        end
        "T": begin
          void'($sscanf(line, "T %d", n));
          repeat (n) @(posedge clk);
          $fwrite(fout, "OK\n"); $fflush(fout);
        end
        "Q": break;
        default: $fatal(1, "bad line: %s", line);
      endcase
    end
    $finish;
  end
endmodule

`default_nettype wire
