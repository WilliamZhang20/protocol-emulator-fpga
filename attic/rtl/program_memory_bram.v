/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * FPGA replacement for the foundry SRAM macro (RM_IHPSG13_1P_1024x8).
 * Drop-in for program_memory: same ports, same 1-cycle read latency.
 * Maps to block RAM on Kria KV260 (Zynq UltraScale+).
 *
 * Write masking: the foundry macro masks per-bit; BRAM writes whole
 * words, so we emulate the mask with a read-modify-write. The host
 * interface only issues full-byte writes (mask 8'hFF) or no-ops, so
 * the RMW is functionally identical.
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

  initial begin
    $readmemh("program.hex", mem); // place program.hex next to the sim or in the bitstream data dir
  end

  reg [7:0] masked;
  always @(posedge clk) begin
    if (enable) begin
      if (write_enable) begin
        masked = mem[address];          // blocking read for RMW
        masked = (masked & ~write_mask) | (write_data & write_mask);
        mem[address] <= masked;
      end
      if (read_enable)
        read_data <= mem[address];      // registered: 1-cycle latency, same as macro
    end
  end

endmodule

`default_nettype wire
