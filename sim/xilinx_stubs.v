// Lint-only port stubs for the Xilinx pieces of kria_top (Verilator/yosys
// can then check kria_top's connections). Vivado uses the real IP.
`default_nettype none
module ps_wrapper (output wire pl_clk0);
  assign pl_clk0 = 1'b0;
endmodule

module vio_host (
    input  wire         clk,
    input  wire [7:0]   probe_in0, probe_in1, probe_in2, probe_in3,
    input  wire [127:0] probe_in4,
    input  wire [3:0]   probe_in5,
    input  wire [12:0]  probe_in6, probe_in7,
    input  wire [7:0]   probe_in8, probe_in9,
    output wire [7:0]   probe_out0,
    output wire         probe_out1, probe_out2,
    output wire [1:0]   probe_out3,
    output wire [31:0]  probe_out4,
    output wire [127:0] probe_out5,
    output wire [4:0]   probe_out6,
    output wire         probe_out7,
    output wire [3:0]   probe_out8,
    output wire         probe_out9,
    output wire [3:0]   probe_out10,
    output wire         probe_out11
);
  assign probe_out0 = 8'h00;  assign probe_out1 = 1'b0;  assign probe_out2 = 1'b0;
  assign probe_out3 = 2'b00;  assign probe_out4 = 32'h0; assign probe_out5 = 128'h0;
  assign probe_out6 = 5'h0;   assign probe_out7 = 1'b0;  assign probe_out8 = 4'h0;
  assign probe_out9 = 1'b0;   assign probe_out10 = 4'h9; assign probe_out11 = 1'b0;
endmodule

module ila_host (
    input wire       clk,
    input wire [7:0] probe0, probe1, probe2, probe3, probe4,
    input wire       probe5
);
endmodule

module IOBUF (input wire I, input wire T, output wire O, inout wire IO);
  assign IO = T ? 1'bz : I;
  assign O  = IO;
endmodule
`default_nettype wire
