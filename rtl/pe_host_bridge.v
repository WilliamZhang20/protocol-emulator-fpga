/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Full-speed host for the protocol emulator's host link, fed from slow JTAG.
 *
 * JTAG (VIO) is ~0.1 s per access; a UART byte arrives every few µs. This
 * bridge does at clock speed what the compiler's simulated host
 * (protocol-emulator-compiler/sim/harness.py, class Host) does:
 *
 *   - Script queue (4096 host-link command bytes). JTAG appends up to 16
 *     bytes per toggle of wr_tog. Each byte is played as one host-link
 *     command: held HOLD clocks, then 8'h00 for GAP clocks.
 *     Response commands (9 A B C D) record their uo_out answer (src 0).
 *     A TX commit (7 / F) is held back while the selected channel's TX FIFO
 *     is full (checked with an A status command first), like Host.write.
 *     E updates the bridge's notion of the selected channel.
 *     While `hold` is set the script is not played (drains continue), so
 *     the host can upload a whole timing-critical script first.
 *     8'h00 is never a host-link command, so it escapes a script delay:
 *     8'h00, n pauses the script for n*16 clocks (drains keep running).
 *   - Background drain. For each channel in drain_mask the bridge selects
 *     it, reads status, and pops every byte it holds into the result buffer
 *     as (src = channel+1, eop, err, byte), then reselects the script's
 *     channel. Drains run whenever the script is idle or waiting for TX
 *     space, and at least every 8 script commands.
 *   - Result buffer (4096 entries of {src[1:0], eop, err, 4'b0, byte}).
 *     JTAG sees the oldest 8 entries in rd_data (entry 0 in [15:0]) and
 *     their count in rd_valid; toggling rd_tog drops rd_count of them.
 *     When the buffer is nearly full the drain stops popping, so the chip's
 *     own RX FIFO applies backpressure instead of bytes being lost.
 *
 * Timing per command: HOLD + GAP clocks (default 4 + 6), comfortably above
 * the host link's 2-clock stability rule plus the 2-flop synchronizer and
 * the 2-clock SRAM-read answer latency.
 */
`default_nettype none

module pe_host_bridge #(
    parameter HOLD = 4,
    parameter GAP  = 6
) (
    input  wire         clk,
    input  wire         rst,            // synchronous, active high
    input  wire [1:0]   drain_mask,
    input  wire         hold,           // pause script playback
    // JTAG write side (toggle handshake; data must be stable before the toggle)
    input  wire [127:0] wr_data,        // byte i in [8i+7:8i]
    input  wire [4:0]   wr_count,       // 0..16
    input  wire         wr_tog,
    // JTAG read side
    input  wire [3:0]   rd_count,       // entries to drop, 0..8
    input  wire         rd_tog,
    output wire [127:0] rd_data,
    output reg  [3:0]   rd_valid,
    // status
    output wire [12:0]  q_level,        // script bytes not yet played
    output wire [12:0]  r_level,        // result entries not yet read (incl. window)
    output wire [7:0]   status,         // {q_ovf, r_ovf, tx_wait, idle, sel_ch, 3'b0}
    // host link
    output reg  [7:0]   ui,
    input  wire [7:0]   uo
);
  localparam QAW = 12, RAW = 12;

  // ------------------------------------------------------------------ script queue
  reg [7:0]     qmem [0:(1<<QAW)-1];
  reg [QAW:0]   q_wp, q_rp;
  wire [QAW:0]  q_cnt = q_wp - q_rp;
  wire          q_empty = q_cnt == 0;
  reg           q_ovf;

  reg           wr_tog_q;
  reg [127:0]   st_data;
  reg [4:0]     st_n, st_i;
  wire          st_busy = st_i != st_n;
  wire          q_we = st_busy && q_cnt != (1 << QAW);

  always @(posedge clk) if (q_we) qmem[q_wp[QAW-1:0]] <= st_data[{st_i[3:0], 3'b000} +: 8];

  always @(posedge clk) begin
    if (rst) begin
      wr_tog_q <= wr_tog; st_n <= 0; st_i <= 0; q_wp <= 0; q_ovf <= 1'b0;
    end else begin
      wr_tog_q <= wr_tog;
      if (wr_tog != wr_tog_q) begin
        st_data <= wr_data;
        st_n <= (wr_count > 5'd16) ? 5'd16 : wr_count;
        st_i <= 0;
        if (st_busy) q_ovf <= 1'b1;           // previous chunk not finished
      end else if (st_busy) begin
        st_i <= st_i + 1'b1;
        if (q_we) q_wp <= q_wp + 1'b1;
        else      q_ovf <= 1'b1;              // queue full: byte dropped
      end
    end
  end

  // ------------------------------------------------------------------ result buffer
  reg [15:0]    rmem [0:(1<<RAW)-1];
  reg [RAW:0]   r_wp, r_rp;
  wire [RAW:0]  r_cnt = r_wp - r_rp;           // in memory, not yet in the window
  reg           r_ovf;
  reg           rec_en;
  reg [15:0]    rec_entry;
  wire          r_full = r_cnt == (1 << RAW);
  wire          r_room = r_cnt < (1 << RAW) - 2;   // drain only with room to spare

  always @(posedge clk) if (rec_en && !r_full) rmem[r_wp[RAW-1:0]] <= rec_entry;

  // read window: 8 entries visible to JTAG
  reg [15:0]    win [0:7];
  reg           rd_tog_q;
  reg           fetch_pending;      // fetch_q lands in the window this cycle
  reg [15:0]    fetch_q;

  genvar gi;
  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_rd
      assign rd_data[16*gi +: 16] = (gi < rd_valid) ? win[gi] : 16'h0000;
    end
  endgenerate

  wire       rd_pop      = rd_tog != rd_tog_q;
  wire [3:0] pop_k       = !rd_pop ? 4'd0 : (rd_count > rd_valid) ? rd_valid : rd_count;
  wire [3:0] n_kept      = rd_valid - pop_k;
  wire [3:0] n_next      = n_kept + {3'b000, fetch_pending};
  wire       fetch_issue = r_cnt != 0 && n_next < 4'd8;

  // fetch_q captures rmem[r_rp] on the edge that issues the fetch and lands
  // in the window on the next edge.
  always @(posedge clk) fetch_q <= rmem[r_rp[RAW-1:0]];

  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_win
      wire [4:0] from = gi + pop_k;
      always @(posedge clk)
        if (fetch_pending && gi == n_kept) win[gi] <= fetch_q;
        else if (from < 5'd8)             win[gi] <= win[from[2:0]];
    end
  endgenerate

  always @(posedge clk) begin
    if (rst) begin
      r_wp <= 0; r_rp <= 0; r_ovf <= 1'b0; rd_valid <= 0; rd_tog_q <= rd_tog;
      fetch_pending <= 1'b0;
    end else begin
      if (rec_en) begin
        if (r_full) r_ovf <= 1'b1;
        else r_wp <= r_wp + 1'b1;
      end
      rd_tog_q      <= rd_tog;
      rd_valid      <= n_next;
      fetch_pending <= fetch_issue;
      if (fetch_issue) r_rp <= r_rp + 1'b1;
    end
  end

  assign r_level = r_cnt + {9'd0, rd_valid} + {12'd0, fetch_pending};

  // ------------------------------------------------------------------ host-link sequencer
  localparam S_IDLE = 4'd0, S_FETCH = 4'd1, S_DISPATCH = 4'd2, S_HOLD = 4'd3,
             S_GAP = 4'd4, S_TXCHK = 4'd5, S_SDONE = 4'd6, S_DSEL = 4'd7,
             S_DSTAT = 4'd8, S_DCHK = 4'd9, S_DPOP = 4'd10, S_DNEXT = 4'd11,
             S_DREST = 4'd12;

  reg [3:0]  state, ret;
  reg [3:0]  cnt;
  reg [7:0]  cur;                // script command being played
  reg        cur_valid;          // fetched but not yet issued (TX may be waiting)
  reg        sel_ch;             // channel the script has selected
  reg        dch;                // channel being drained
  reg [1:0]  dleft;              // channels still to drain this round
  reg [3:0]  pops;
  reg        hd_eop, hd_err;
  reg        tx_wait;
  reg [3:0]  since;              // script commands since the last drain
  reg [7:0]  qbyte;
  reg        delay_arg;          // next script byte is a delay count
  reg        just_drained;       // let script work through between drain rounds
  reg [11:0] delay_cnt;          // script paused while nonzero

  always @(posedge clk) qbyte <= qmem[q_rp[QAW-1:0]];

  wire [3:0] cmd = cur[7:4];
  wire is_resp = cmd == 4'h9 || cmd == 4'hA || cmd == 4'hB || cmd == 4'hC || cmd == 4'hD;
  wire is_txhi = cmd == 4'h7 || cmd == 4'hF;
  wire want_drain = drain_mask != 2'b00 && r_room &&
                    (q_empty || hold || tx_wait || delay_cnt != 0 || since >= 4'd8);

  assign q_level = q_cnt + cur_valid;
  assign status  = {q_ovf, r_ovf, tx_wait,
                    (state == S_IDLE && q_empty && !cur_valid && !st_busy && delay_cnt == 0),
                    sel_ch, 3'b000};

  task issue(input [7:0] b, input [3:0] next);
    begin
      ui <= b; cnt <= HOLD - 1; ret <= next; state <= S_HOLD;
    end
  endtask

  always @(posedge clk) begin
    rec_en <= 1'b0;
    if (rst) begin
      state <= S_IDLE; ui <= 8'h00; q_rp <= 0; cur_valid <= 1'b0; sel_ch <= 1'b0;
      tx_wait <= 1'b0; since <= 0; cnt <= 0; ret <= S_IDLE; dleft <= 0;
      delay_arg <= 1'b0; delay_cnt <= 0; just_drained <= 1'b0;
    end else begin
      if (delay_cnt != 0) delay_cnt <= delay_cnt - 1'b1;
      case (state)
        S_IDLE: begin
          // After a drain round, script work (a waiting TX commit or the
          // next command) goes first, so a full TX FIFO cannot starve it.
          if (want_drain && !(just_drained && (cur_valid || (!q_empty && delay_cnt == 0 && !hold)))) begin
            dleft <= drain_mask;
            since <= 0;
            state <= S_DNEXT;
          end else if (cur_valid) begin
            just_drained <= 1'b0;
            state <= S_DISPATCH;            // retry a TX commit that waited
          end else if (!q_empty && delay_cnt == 0 && !hold) begin
            just_drained <= 1'b0;
            state <= S_FETCH;               // qbyte valid next cycle
          end
        end
        S_FETCH: begin
          q_rp <= q_rp + 1'b1;
          if (delay_arg) begin              // delay count
            delay_arg <= 1'b0;
            delay_cnt <= {qbyte, 4'h0};
            state <= S_IDLE;
          end else if (qbyte == 8'h00) begin
            delay_arg <= 1'b1;
            state <= S_IDLE;
          end else begin
            cur <= qbyte; cur_valid <= 1'b1; state <= S_DISPATCH;
          end
        end
        S_DISPATCH: begin
          if (is_txhi) issue({4'hA, 4'h0}, S_TXCHK);
          else         issue(cur, S_SDONE);
        end
        S_TXCHK: begin
          if (uo[5]) begin                  // tx_full: let the program drain it
            tx_wait <= 1'b1; state <= S_IDLE;
          end else begin
            tx_wait <= 1'b0; issue(cur, S_SDONE);
          end
        end
        S_SDONE: begin
          if (is_resp) begin
            rec_en <= 1'b1; rec_entry <= {2'b00, 2'b00, 4'h0, uo};
          end
          if (cmd == 4'hE) sel_ch <= cur[0];
          cur_valid <= 1'b0;
          if (since != 4'hF) since <= since + 1'b1;
          state <= S_IDLE;
        end
        // ---- drain round
        S_DNEXT: begin
          if (dleft[0]) begin dch <= 1'b0; dleft[0] <= 1'b0; pops <= 0; state <= S_DSEL; end
          else if (dleft[1]) begin dch <= 1'b1; dleft[1] <= 1'b0; pops <= 0; state <= S_DSEL; end
          else state <= S_DREST;
        end
        S_DSEL:  issue({4'hE, 3'b000, dch}, S_DSTAT);
        S_DSTAT: issue({4'hA, 4'h0}, S_DCHK);
        S_DCHK: begin
          if (uo[4] || !r_room) state <= S_DNEXT;      // rx_empty, or no room
          else begin
            hd_eop <= uo[1]; hd_err <= uo[0];
            issue({4'h9, 4'h0}, S_DPOP);
          end
        end
        S_DPOP: begin
          rec_en <= 1'b1; rec_entry <= {(dch ? 2'd2 : 2'd1), hd_eop, hd_err, 4'h0, uo};
          pops <= pops + 1'b1;
          if (pops == 4'd15) state <= S_DNEXT;
          else state <= S_DSTAT;
        end
        S_DREST: begin just_drained <= 1'b1; issue({4'hE, 3'b000, sel_ch}, S_IDLE); end
        // ---- one host-link command
        S_HOLD: begin
          if (cnt == 0) begin ui <= 8'h00; cnt <= GAP - 1; state <= S_GAP; end
          else cnt <= cnt - 1'b1;
        end
        S_GAP: begin
          if (cnt == 0) state <= ret;
          else cnt <= cnt - 1'b1;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
