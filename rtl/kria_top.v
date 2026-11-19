/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Kria KV260 top level for the protocol-emulator ASIC prototype.
 *
 *   PS pl_clk0 (50 MHz, = ASIC clock_hz) ──► clk for the whole design
 *
 *   PC ──USB-JTAG──► VIO ──► pe_harness ──► tt_um_protocol_emulator (the ASIC RTL)
 *                    ILA ◄── host link + uio, cycle accurate
 *   uio[7:0] ◄──► Pmod J2 (3.3 V), true bidirectional (IOBUF, T = ~uio_oe)
 *
 * The host link (ui_in/uo_out) is driven over JTAG, either one byte at a
 * time (raw VIO) or through pe_host_bridge, which plays queued commands at
 * clock speed and drains the RX FIFOs (see rtl/pe_host_bridge.v).
 * Everything except the PS, VIO, ILA and IOBUFs is in pe_harness.v, which
 * the simulation runs unchanged.
 */
`default_nettype none

module kria_top (
    inout  wire [7:0] pmod,       // uio[7:0]
    output wire       fan_en_b    // KV260 fan enable, active low (PWM)
);

  wire clk;
  ps_wrapper u_ps (.pl_clk0(clk));

  // ------------------------------------------------------------ JTAG VIO
  wire [7:0]   vio_ui_in;
  wire         vio_reset;
  wire         vio_br_en;
  wire [1:0]   vio_drain;
  wire [31:0]  vio_loop;
  wire [127:0] vio_wr_data;
  wire [4:0]   vio_wr_count;
  wire         vio_wr_tog;
  wire [3:0]   vio_rd_count;
  wire         vio_rd_tog;
  wire [3:0]   vio_fan;
  wire         vio_hold;

  wire [7:0]   uo_out, uio_in, uio_out, uio_oe, pad_in, ui_in;
  wire [127:0] br_rd_data;
  wire [3:0]   br_rd_valid;
  wire [12:0]  br_q_level, br_r_level;
  wire [7:0]   br_status;
  wire         rst_n;

  vio_host u_vio (
      .clk        (clk),
      .probe_in0  (uo_out),
      .probe_in1  (uio_in),
      .probe_in2  (uio_out),
      .probe_in3  (uio_oe),
      .probe_in4  (br_rd_data),
      .probe_in5  (br_rd_valid),
      .probe_in6  (br_q_level),
      .probe_in7  (br_r_level),
      .probe_in8  (br_status),
      .probe_in9  (pad_in),
      .probe_out0 (vio_ui_in),
      .probe_out1 (vio_reset),
      .probe_out2 (vio_br_en),
      .probe_out3 (vio_drain),
      .probe_out4 (vio_loop),
      .probe_out5 (vio_wr_data),
      .probe_out6 (vio_wr_count),
      .probe_out7 (vio_wr_tog),
      .probe_out8 (vio_rd_count),
      .probe_out9 (vio_rd_tog),
      .probe_out10(vio_fan),
      .probe_out11(vio_hold)
  );

  // ------------------------------------------------------------ pins
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : g_uio
      IOBUF u_iobuf (
          .I (uio_out[i]),
          .T (~uio_oe[i]),     // T = 1 tristates the pin
          .O (pad_in[i]),
          .IO(pmod[i])
      );
    end
  endgenerate

  // ------------------------------------------------------------ the ASIC + FPGA shell
  pe_harness u_harness (
      .clk(clk), .soft_reset(vio_reset),
      .raw_ui(vio_ui_in), .uo_out(uo_out),
      .br_en(vio_br_en), .br_drain(vio_drain), .br_hold(vio_hold),
      .br_wr_data(vio_wr_data), .br_wr_count(vio_wr_count), .br_wr_tog(vio_wr_tog),
      .br_rd_count(vio_rd_count), .br_rd_tog(vio_rd_tog),
      .br_rd_data(br_rd_data), .br_rd_valid(br_rd_valid),
      .br_q_level(br_q_level), .br_r_level(br_r_level), .br_status(br_status),
      .loop_cfg(vio_loop), .pad_in(pad_in),
      .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
      .fan_duty(vio_fan), .fan_en_b(fan_en_b),
      .rst_n_out(rst_n), .ui_in_out(ui_in)
  );

  // ------------------------------------------------------------ JTAG ILA
  ila_host u_ila (
      .clk   (clk),
      .probe0(ui_in),
      .probe1(uo_out),
      .probe2(uio_in),
      .probe3(uio_out),
      .probe4(uio_oe),
      .probe5(rst_n)
  );

endmodule

`default_nettype wire
