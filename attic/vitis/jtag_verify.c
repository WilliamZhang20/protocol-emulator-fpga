/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * JTAG-based post-bitstream verification for the protocol emulator on
 * Kria KV260. Runs on the host PC (not the PS) and talks to the ILA/VIO
 * cores in the bitstream through XSCT/hw_server — no Pmod wiring needed.
 *
 * Flow:
 *   1. In Vivado, add a VIO (8-bit probe_in on uo_out, 8-bit probe_out
 *      on ui_in, plus probe on uio_*) and an ILA on the same buses.
 *      Re-synthesize with these cores (see scripts/vivado_add_debug.tcl).
 *   2. Program the device, then run this app under XSCT:
 *        xsct jtag_verify.tcl
 *      or use the standalone Vitis app which links libhw_jtag (see
 *      Makefile). The app drives the same stimulus as tb_kria_top.sv
 *      and compares against expected responses.
 *
 * This file is the pure-C reference of the stimulus; jtag_verify.tcl is
 * the version you actually run from XSCT without building anything.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* Host-link command encoding, mirroring docs/host-link.md:
 * top nibble = command, bottom nibble = payload. */
enum {
    CMD_ADDR_0   = 0x10,   /* 1: SRAM address bits 3:0 */
    CMD_ADDR_1   = 0x20,   /* 2: SRAM address bits 7:4 */
    CMD_ADDR_2   = 0x30,   /* 3: SRAM address bits 9:8 */
    CMD_PROG_LO  = 0x40,   /* 4: write byte, low half */
    CMD_PROG_HI  = 0x50,   /* 5: write byte, high half */
    CMD_TX_LO    = 0x60,   /* 6: push TX byte, low half */
    CMD_TX_HI    = 0x70,   /* 7: push TX byte, high half */
    CMD_ENGINE   = 0x80,   /* 8: engine control (payload 1 = run) */
    CMD_RX_POP   = 0x90,   /* 9: pop RX byte */
    CMD_STATUS   = 0xA0,   /* A: FIFO status */
    CMD_SRAM_READ= 0xB0,   /* B: read SRAM byte at address */
    CMD_LEVELS   = 0xC0,   /* C: FIFO levels */
    CMD_RX_PEEK  = 0xD0,   /* D: peek RX byte */
    CMD_CHANNEL  = 0xE0,   /* E: select FIFO channel */
    CMD_TX_EOP   = 0xF0,   /* F: push TX byte tagged eop, high half */
};

typedef struct { uint8_t cmd; uint8_t expect; const char *name; } xfer_t;

/* Stimulus shared with testbench/tb_kria_top.sv — keep in sync.
 * Command encoding is {cmd[3:0], payload[3:0]} per docs/host-link.md:
 * 1/2/3 set SRAM address, 4/5 write a byte (low then high half),
 * 8 payload 1 starts the engine. Each byte is sent as two halves
 * (low nibble, then high nibble) with a 0x00 gap between bytes. */
static const xfer_t program[] = {
    /* load one byte 0xA5 at SRAM address 0x3F0 */
    {0x10, 0, "addr 3:0"},   /* 1, payload 0 */
    {0x2F, 0, "addr 7:4"},   /* 2, payload F */
    {0x33, 0, "addr 9:8"},   /* 3, payload 3 */
    {0x45, 0, "data low"},   /* 4, payload 5 */
    {0x5A, 0, "data high"},  /* 5, payload A */
    /* read it back through SRAM_READ (B) */
    {0xB0, 0xA5, "sram readback"},
    /* start the engine */
    {0x81, 0, "run"},
};

#define N_XFER (sizeof(program)/sizeof(program[0]))

/* These two hooks are provided by the XSCT TCL bridge (jtag_verify.tcl)
 * which wraps VIO read/write via `hw_vio` commands. In a standalone Vitis
 * app built against the XSCT libs, implement them with the JTAG-AXI or
 * VIO IP driver API. */
extern uint8_t vio_read_uo(void);
extern void    vio_write_ui(uint8_t v);
extern void    fabric_wait_cycles(unsigned n);

int jtag_verify(void)
{
    int errors = 0;
    printf("== JTAG post-bitstream verification ==\n");

    for (unsigned i = 0; i < N_XFER; i++) {
        vio_write_ui(program[i].cmd);
        fabric_wait_cycles(3);
        vio_write_ui(0x00);          /* idle gap */
        fabric_wait_cycles(3);
        uint8_t resp = vio_read_uo();
        if (resp != program[i].expect) {
            printf("[FAIL] %s: resp=%02x expect=%02x\n",
                   program[i].name, resp, program[i].expect);
            errors++;
        } else {
            printf("[PASS] %s -> %02x\n", program[i].name, resp);
        }
    }
    printf("== done: %d errors ==\n", errors);
    return errors;
}

#ifdef STANDALONE
/* Stub hooks for host-side unit test of the stimulus logic (no hardware).
 * Build: cc -DSTANDALONE -o jtag_verify_host jtag_verify.c && ./jtag_verify_host
 */
static uint8_t fake_ui;
uint8_t vio_read_uo(void)
{
    return fake_ui == CMD_SRAM_READ ? 0xA5 : 0x00;
}
void vio_write_ui(uint8_t v) { if (v != 0) fake_ui = v; }
void fabric_wait_cycles(unsigned n) { (void)n; }
int main(void) { return jtag_verify(); }
#endif
