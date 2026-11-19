/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * FPGA stand-in for the foundry SRAM wrapper (src/program_memory.v, macro
 * RM_IHPSG13_1P_1024x8_c2_bm_bist). Same module name and ports, so the
 * upstream project.v uses it unchanged.
 *
 * Macro behaviour (test/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v):
 *   MEN & WEN        : write (bit mask), DOUT holds   (unless REN: write-through)
 *   MEN & REN & !WEN : DOUT <= mem[A] on the clock edge (1-cycle latency)
 *   otherwise        : DOUT holds
 *
 * In this design the memory is only ever used in two ways:
 *   - host: enable = write | read, never both, mask always 8'hff
 *   - engine: enable = read = instruction_read, never writes
 * so "enable && !write" is always a read, and the macro reduces to the
 * standard Xilinx NO_CHANGE block-RAM template below (no read-modify-write,
 * which would stop Vivado from mapping it to a RAMB18). The simulation-only
 * checks flag any future upstream change that breaks those assumptions.
 */
`default_nettype none

module program_memory (
    input  wire       clk,
    input  wire       enable,
    input  wire       write_enable,
    input  wire       read_enable,
    input  wire [9:0] address,
    input  wire [7:0] write_data,
    input  wire [7:0] write_mask,
    output reg  [7:0] read_data
);

  (* ram_style = "block" *) reg [7:0] mem [0:1023];

  // Optional preload (the ASIC SRAM powers up undefined; the host normally
  // loads the program over the host link). program.hex is 1024 hex bytes.
  initial $readmemh("program.hex", mem);

  always @(posedge clk) begin
    if (enable) begin
      if (write_enable)
        mem[address] <= write_data;
      else
        read_data <= mem[address];
    end
  end

`ifndef SYNTHESIS
  // synthesis translate_off
  always @(posedge clk) begin
    if (enable === 1'b1) begin
      if (write_enable === 1'b1 && write_mask !== 8'hff)
        $display("ERROR: program_memory: partial write mask %h not modelled on FPGA", write_mask);
      if (write_enable === 1'b1 && read_enable === 1'b1)
        $display("ERROR: program_memory: simultaneous read+write (macro write-through) not modelled");
      if (write_enable !== 1'b1 && read_enable !== 1'b1)
        $display("ERROR: program_memory: enable without read or write");
    end
  end
  // synthesis translate_on
`endif

endmodule

`default_nettype wire
