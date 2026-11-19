/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Portable (vendor-free) shell around the ASIC: everything the FPGA adds
 * that simulation must see too. kria_top.v only adds the PS clock, the
 * JTAG VIO/ILA and the IOBUFs.
 *
 *   reset      power-on + soft reset (JTAG), 16 clocks, synchronous release
 *   ui_in      raw JTAG byte (bridge off) or pe_host_bridge (bridge on)
 *   loopback   per pad i, loop_cfg[4i+3:4i] = {en, src[2:0]}: when en, the
 *              core's uio_in[i] sees pad src as the outside world would
 *              (the core's own drive if uio_oe[src], else the pad). This is
 *              the compiler's `wire src -> i`, without a physical jumper.
 *   fan        25 kHz PWM on the KV260 fan enable (active low), duty
 *              fan_duty/15 (0 = off is not allowed: minimum 4/15)
 */
`default_nettype none

module pe_harness (
    input  wire         clk,
    input  wire         soft_reset,
    // raw host link (JTAG)
    input  wire [7:0]   raw_ui,
    output wire [7:0]   uo_out,
    // bridge
    input  wire         br_en,
    input  wire [1:0]   br_drain,
    input  wire         br_hold,
    input  wire [127:0] br_wr_data,
    input  wire [4:0]   br_wr_count,
    input  wire         br_wr_tog,
    input  wire [3:0]   br_rd_count,
    input  wire         br_rd_tog,
    output wire [127:0] br_rd_data,
    output wire [3:0]   br_rd_valid,
    output wire [12:0]  br_q_level,
    output wire [12:0]  br_r_level,
    output wire [7:0]   br_status,
    // pins
    input  wire [31:0]  loop_cfg,
    input  wire [7:0]   pad_in,
    output wire [7:0]   uio_in,         // what the core sees (for debug)
    output wire [7:0]   uio_out,
    output wire [7:0]   uio_oe,
    // misc
    input  wire [3:0]   fan_duty,
    output reg          fan_en_b,
    output wire         rst_n_out,
    output wire [7:0]   ui_in_out
);

  // ------------------------------------------------------------ reset
  reg [4:0] por = 5'd0;
  always @(posedge clk)
    if (soft_reset) por <= 5'd0;
    else if (!por[4]) por <= por + 5'd1;
  reg rst_n = 1'b0;
  always @(posedge clk) rst_n <= por[4];
  assign rst_n_out = rst_n;

  // ------------------------------------------------------------ host link
  wire [7:0] br_ui;
  pe_host_bridge u_bridge (
      .clk(clk), .rst(!rst_n || !br_en), .drain_mask(br_drain), .hold(br_hold),
      .wr_data(br_wr_data), .wr_count(br_wr_count), .wr_tog(br_wr_tog),
      .rd_count(br_rd_count), .rd_tog(br_rd_tog),
      .rd_data(br_rd_data), .rd_valid(br_rd_valid),
      .q_level(br_q_level), .r_level(br_r_level), .status(br_status),
      .ui(br_ui), .uo(uo_out));

  wire [7:0] ui_in = br_en ? br_ui : raw_ui;
  assign ui_in_out = ui_in;

  // ------------------------------------------------------------ pins
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_loop
      wire       en  = loop_cfg[4*i + 3];
      wire [2:0] src = loop_cfg[4*i +: 3];
      assign uio_in[i] = en ? (uio_oe[src] ? uio_out[src] : pad_in[src]) : pad_in[i];
    end
  endgenerate

  tt_um_protocol_emulator u_core (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // ------------------------------------------------------------ fan
  // 50 MHz / 2000 = 25 kHz, 15 duty steps.
  reg [10:0] fan_cnt = 0;
  always @(posedge clk) fan_cnt <= (fan_cnt == 11'd1999) ? 11'd0 : fan_cnt + 1'b1;
  wire [3:0] duty = (fan_duty < 4'd4) ? 4'd4 : fan_duty;
  // on (low) for duty/15 of the period
  always @(posedge clk) fan_en_b <= !(fan_cnt < duty * 11'd133);

endmodule

`default_nettype wire
