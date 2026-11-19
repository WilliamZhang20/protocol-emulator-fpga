/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Kria KV260 top level. Wraps the Tiny Tapeout project for standalone
 * FPGA use. The fabric is fully synchronous and single-clock; we run it
 * on the 125 MHz input clock. The emulator core runs at 125 MHz; only the
 * registered output pins update at 25 MHz. Use a clocking IP block if the
 * entire core needs a separate 25 MHz clock domain.
 *
 * Debug/verification path: the Vitis app (vitis/) talks to the ILA/VIO
 * cores instantiated here via the hw_server JTAG connection, so you can
 * drive ui_in and sample uo_out/uio_* without touching the Pmod pins.
 */
`default_nettype none

module kria_top (
    input  wire        clk_125m,      // PL clock from PS (see XDC)
    input  wire        btn_reset,     // active-high button, synchronized
    input  wire [7:0]  pmod_in,       // ui_in  (host command byte)
    output wire [7:0]  pmod_out,      // uo_out (host response byte)
    input  wire [7:0]  gpio_in,       // uio_in (protocol pins)
    output wire [7:0]  gpio_out,      // uio_out
    output wire [7:0]  gpio_oe,       // uio_oe
    output wire [7:0]  led,
    output wire        clk_out
);

  // Output pins update once every five input clock cycles.
  reg [2:0] div = 3'd0;
  always @(posedge clk_125m) div <= (div == 3'd4) ? 3'd0 : div + 3'd1;
  wire ce_25m = (div == 3'd4);

  // reset synchronizer, release after 16 cycles
  reg [3:0] rst_sh = 4'h0;
  always @(posedge clk_125m) rst_sh <= {rst_sh[2:0], ~btn_reset};
  wire rst_n = rst_sh[3];

  wire [7:0] uo_out, uio_out, uio_oe;
  wire ena = 1'b1;

  ce_register #(.WIDTH(8)) uo_reg    (.clk(clk_125m), .ce(ce_25m), .d(uo_out),  .q(pmod_out));
  ce_register #(.WIDTH(8)) uio_reg   (.clk(clk_125m), .ce(ce_25m), .d(uio_out), .q(gpio_out));
  ce_register #(.WIDTH(8)) uiooe_reg (.clk(clk_125m), .ce(ce_25m), .d(uio_oe),  .q(gpio_oe));

  tt_um_protocol_emulator u_core (
      .ui_in  (pmod_in),
      .uo_out (uo_out),
      .uio_in (gpio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk_125m),
      .rst_n  (rst_n)
  );

  assign led[0]   = 1'b1;          // alive
  assign led[1]   = ~rst_n;        // in reset
  assign led[7:2] = uo_out[7:2];   // host response bits
  assign clk_out  = clk_125m;

endmodule

module ce_register #(parameter WIDTH = 8) (
    input  wire             clk,
    input  wire             ce,
    input  wire [WIDTH-1:0] d,
    output reg  [WIDTH-1:0] q
);
  always @(posedge clk) if (ce) q <= d;
endmodule

`default_nettype wire
