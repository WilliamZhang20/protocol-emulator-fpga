/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Runs a program's tests (programs/<name>/tests.hwmem, from tools/pe_hw.py)
 * against pe_harness: the same RTL the KV260 runs, minus PS/VIO/ILA/IOBUF.
 * It drives the harness exactly as jtag/pe_jtag.tcl drives the VIO, with a
 * random 20-200 clock "JTAG" delay between accesses, so a pass here means
 * the same test file should pass on the board.
 *
 *   +PROG=programs/<name>   (required)   +ONLY=<test index>   +WAVES
 */
`timescale 1ns/1ps
`default_nettype none

module tb_hwtest;
  localparam real CLK_NS = 20.0;

  logic clk = 0;
  always #(CLK_NS/2) clk = ~clk;

  // ---------------------------------------------------------------- harness
  logic         soft_reset = 1, br_en = 0;
  logic [1:0]   br_drain = 0;
  logic         br_hold = 0;
  logic [127:0] br_wr_data = 0;
  logic [4:0]   br_wr_count = 0;
  logic         br_wr_tog = 0, br_rd_tog = 0;
  logic [3:0]   br_rd_count = 0;
  logic [31:0]  loop_cfg = 0;
  wire  [127:0] br_rd_data;
  wire  [3:0]   br_rd_valid;
  wire  [12:0]  br_q_level, br_r_level;
  wire  [7:0]   br_status;
  wire  [7:0]   uo_out, uio_in, uio_out, uio_oe, ui_in_mon;
  wire          fan_en_b, rst_n;
  logic [7:0]   peer_drive = 8'hFF;   // 0 = the device pulls the pad low
  wire  [7:0]   pad_in;

  // Pads: pulled up; the chip drives when uio_oe; the device can pull low.
  genvar gp;
  generate
    for (gp = 0; gp < 8; gp++) begin : g_pad
      assign pad_in[gp] = (uio_oe[gp] ? uio_out[gp] : 1'b1) & peer_drive[gp];
    end
  endgenerate

  pe_harness dut (
      .clk(clk), .soft_reset(soft_reset), .raw_ui(8'h00), .uo_out(uo_out),
      .br_en(br_en), .br_drain(br_drain), .br_hold(br_hold),
      .br_wr_data(br_wr_data), .br_wr_count(br_wr_count), .br_wr_tog(br_wr_tog),
      .br_rd_count(br_rd_count), .br_rd_tog(br_rd_tog),
      .br_rd_data(br_rd_data), .br_rd_valid(br_rd_valid),
      .br_q_level(br_q_level), .br_r_level(br_r_level), .br_status(br_status),
      .loop_cfg(loop_cfg), .pad_in(pad_in), .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
      .fan_duty(4'd9), .fan_en_b(fan_en_b), .rst_n_out(rst_n), .ui_in_out(ui_in_mon));

  // ---------------------------------------------------------------- JTAG-like access
  int unsigned seed = 1;
  task automatic jtag_delay();
    int n;
    n = 20 + ($urandom(seed) % 181);
    seed = seed + 1;
    repeat (n) @(posedge clk);
  endtask

  // received entries per source: 0 = script responses, 1/2 = channel 0/1
  int  q_byte[3][$];
  bit  q_eop[3][$];
  bit  q_err[3][$];

  task automatic pull();
    int n;
    n = br_rd_valid;
    for (int i = 0; i < n; i++) begin
      int src;
      src = br_rd_data[16*i + 14 +: 2];
      q_byte[src].push_back(br_rd_data[16*i +: 8]);
      q_eop[src].push_back(br_rd_data[16*i + 13]);
      q_err[src].push_back(br_rd_data[16*i + 12]);
    end
    if (n > 0) begin
      br_rd_count = n;
      jtag_delay();
      br_rd_tog = ~br_rd_tog;
    end
    jtag_delay();
  endtask

  task automatic enqueue(input int bytes[$]);
    int i, k;
    i = 0;
    br_hold = 1;               // upload the whole script, then play it at clock speed
    jtag_delay();
    while (i < bytes.size()) begin
      while (br_q_level > 4096 - 32) jtag_delay();
      k = bytes.size() - i;
      if (k > 16) k = 16;
      br_wr_data = 0;
      for (int j = 0; j < k; j++) br_wr_data[8*j +: 8] = bytes[i + j];
      br_wr_count = k;
      jtag_delay();
      br_wr_tog = ~br_wr_tog;
      jtag_delay();
      i += k;
      if (br_q_level > 4096 - 64) begin br_hold = 0; jtag_delay(); end   // too big: stream
    end
    br_hold = 0;
    jtag_delay();
  endtask

  // ---------------------------------------------------------------- UART device model
  // Mirrors protocol-emulator-compiler/sim/peers/uart.py, including its
  // referee checks (bit steady over its middle half, parity, stop bit).
  int  s_bit = 0, s_txpad = 0, s_rxpad = 0, s_parity = 0;  // parity 0 none, 1 even, 2 odd
  bit  s_on = 0;
  int  s_rx[$];          // bytes the device received from the chip
  int  s_tx[$];          // bytes queued for the device to send
  string s_problem = "";

  function automatic bit chip_level(int pad);
    return pad_in[pad];
  endfunction

  function automatic bit par_bit(int v);
    return ^v[7:0] ^ (s_parity == 2);
  endfunction

  task automatic sample_bit(input string label, output bit v);
    bit s[3];
    for (int i = 0; i < 3; i++) begin
      repeat (s_bit / 4) @(posedge clk);
      s[i] = chip_level(s_txpad);
    end
    repeat (s_bit - 3 * (s_bit / 4)) @(posedge clk);
    if ((s[0] != s[1] || s[1] != s[2]) && s_problem == "")
      s_problem = {label, " bit changed in the middle of its bit time"};
    v = s[1];
  endtask

  initial forever begin : uart_rx_model
    int v; bit b;
    @(posedge clk);
    if (s_on && chip_level(s_txpad) == 0) begin
      sample_bit("start", b);
      if (b == 0) begin
        v = 0;
        for (int i = 0; i < 8; i++) begin sample_bit("data", b); v |= int'(b) << i; end
        if (s_parity != 0) begin
          sample_bit("parity", b);
          if (b != par_bit(v) && s_problem == "") s_problem = $sformatf("wrong parity after %02x", v);
        end
        sample_bit("stop", b);
        if (b != 1 && s_problem == "") s_problem = $sformatf("stop bit after %02x was 0", v);
        s_rx.push_back(v);
      end
    end
  end

  initial forever begin : uart_tx_model
    int v;
    @(posedge clk);
    if (s_on && s_tx.size() > 0) begin
      v = s_tx.pop_front();
      peer_drive[s_rxpad] = 0; repeat (s_bit) @(posedge clk);
      for (int i = 0; i < 8; i++) begin
        peer_drive[s_rxpad] = (v >> i) & 1; repeat (s_bit) @(posedge clk);
      end
      if (s_parity != 0) begin peer_drive[s_rxpad] = par_bit(v); repeat (s_bit) @(posedge clk); end
      peer_drive[s_rxpad] = 1; repeat (s_bit) @(posedge clk);
    end
  end

  // ---------------------------------------------------------------- test file
  logic [7:0] mem [0:262143];
  int pc;
  string names[$];
  int n_pass = 0, n_fail = 0, n_skip = 0;
  int cur = -1;
  bit active = 0;          // executing ops of the current test
  bit cur_failed = 0, cur_skipped = 0;
  string why;

  function automatic int u8();  u8 = mem[pc]; pc++; endfunction
  function automatic int u16(); u16 = mem[pc] | (mem[pc+1] << 8); pc += 2; endfunction
  function automatic int u32(); u32 = mem[pc] | (mem[pc+1] << 8) | (mem[pc+2] << 16) | (mem[pc+3] << 24); pc += 4; endfunction

  // has_expect, len16, bytes  -> returns has_expect
  function automatic bit read_expect(ref int data[$]);
    bit has; int n;
    has = u8(); n = u16();
    data = {};
    for (int i = 0; i < n; i++) data.push_back(u8());
    return has;
  endfunction

  function automatic string hexq(input int d[$]);
    string s = "";
    foreach (d[i]) s = {s, $sformatf("%02x", d[i])};
    if (s == "") s = "(none)";
    return s;
  endfunction

  task automatic fail(input string msg);
    if (!cur_failed) why = msg;
    cur_failed = 1;
    active = 0;
  endtask

  task automatic finish_test();
    if (cur < 0) return;
    if (active && !cur_failed && !cur_skipped && s_on && s_problem != "")
      fail({"UART device: ", s_problem});
    if (active && !cur_failed && !cur_skipped && (br_status[7] || br_status[6]))
      fail($sformatf("bridge overflow (status %02x)", br_status));
    if (cur_skipped)     begin n_skip++; $display("  %-40s SKIP", names[cur]); end
    else if (cur_failed) begin n_fail++; $display("  %-40s FAIL  %s", names[cur], why); end
    else                 begin n_pass++; $display("  %-40s pass", names[cur]); end
  endtask

  // wait until src has `count` entries (or an eop entry if count < 0)
  task automatic collect(input int src, input int count, input int timeout, output bit ok);
    longint t0;
    t0 = $time;
    ok = 0;
    forever begin
      if (count >= 0 && q_byte[src].size() >= count) begin ok = 1; return; end
      if (count < 0) for (int i = 0; i < q_eop[src].size(); i++) if (q_eop[src][i]) begin ok = 1; return; end
      if (($time - t0) / CLK_NS > timeout) return;
      pull();
    end
  endtask

  task automatic take(input int src, input int n, output int d[$], output bit any_err, output bit last_eop, output bit last_err);
    d = {}; any_err = 0; last_eop = 0; last_err = 0;
    for (int i = 0; i < n; i++) begin
      d.push_back(q_byte[src].pop_front());
      last_eop = q_eop[src].pop_front();
      last_err = q_err[src].pop_front();
      any_err |= last_err;
    end
  endtask

  function automatic int eop_index(int src);
    for (int i = 0; i < q_eop[src].size(); i++) if (q_eop[src][i]) return i;
    return -1;
  endfunction

  task automatic run();
    int op, only;
    only = -1;
    void'($value$plusargs("ONLY=%d", only));
    pc = 0;
    forever begin
      op = u8();
      case (op)
        8'h00: begin finish_test(); return; end
        8'h01: begin
          finish_test();
          cur = u16();
          cur_failed = 0; cur_skipped = 0; why = "";
          active = (only < 0 || only == cur);
          if (!active) cur_skipped = 1;
        end
        8'h0E: begin cur_skipped = 1; active = 0; end
        8'h10: begin cur_skipped = 1; active = 0; end   // needs a real device
        8'h02: if (active) begin
          br_en = 0; s_on = 0; peer_drive = 8'hFF; s_tx = {}; s_rx = {}; s_problem = "";
          soft_reset = 1; repeat (4) @(posedge clk); soft_reset = 0;
          br_en = 1;
          for (int s = 0; s < 3; s++) begin q_byte[s] = {}; q_eop[s] = {}; q_err[s] = {}; end
          repeat (40) @(posedge clk);
        end
        8'h03: begin int v; v = u32(); if (active) begin loop_cfg = v; jtag_delay(); end end
        8'h04: begin int v; v = u8(); if (active) begin br_drain = v; jtag_delay(); end end
        8'h05: begin
          int n; int b[$];
          n = u16(); b = {};
          for (int i = 0; i < n; i++) b.push_back(u8());
          if (active) enqueue(b);
        end
        8'h06: begin int n; n = u32(); if (active) repeat (n) @(posedge clk); end
        8'h0F: begin
          int t; longint t0; t = u32();
          if (active) begin
            t0 = $time;
            while (!(br_status[4] && br_q_level == 0)) begin
              if (($time - t0) / CLK_NS > t) begin fail("script queue never drained (TX stalled?)"); break; end
              jtag_delay();
            end
          end
        end
        8'h07: begin // rx ch count timeout expect
          int ch, count, t; bit has, ok, aerr, le, lr; int exp[$], got[$];
          ch = u8(); count = u16(); t = u32(); has = read_expect(exp);
          if (active) begin
            collect(ch + 1, count, t, ok);
            if (!ok) fail($sformatf("channel %0d: got %s, then nothing (wanted %0d bytes)", ch, hexq(q_byte[ch+1]), count));
            else begin
              take(ch + 1, count, got, aerr, le, lr);
              if (aerr) fail($sformatf("channel %0d: byte marked as error (bad stop/parity)", ch));
              else if (has && got != exp) fail($sformatf("channel %0d: expected %s, got %s", ch, hexq(exp), hexq(got)));
            end
          end
        end
        8'h08, 8'h09: begin // packet / reply
          int ch, t, errk, stk, stv, idx; bit has, ok, aerr, le, lr; int exp[$], got[$];
          ch = u8(); t = u32(); has = read_expect(exp);
          if (op == 8'h08) errk = u8(); else begin stk = u8(); stv = u8(); end
          if (active) begin
            collect(ch + 1, -1, t, ok);
            if (!ok) fail($sformatf("channel %0d: no packet end (have %s)", ch, hexq(q_byte[ch+1])));
            else begin
              idx = eop_index(ch + 1);
              if (op == 8'h08) begin
                take(ch + 1, idx + 1, got, aerr, le, lr);
                if (errk != 2 && aerr != errk) fail($sformatf("channel %0d: packet error flag %0d, expected %0d", ch, aerr, errk));
                else if (has && got != exp) fail($sformatf("channel %0d: packet %s, expected %s", ch, hexq(got), hexq(exp)));
              end else begin
                int status;
                take(ch + 1, idx, got, aerr, le, lr);
                status = q_byte[ch+1].pop_front(); void'(q_eop[ch+1].pop_front()); lr = q_err[ch+1].pop_front();
                if (stk == 0 && lr) fail($sformatf("call failed with status %0d", status));
                else if (stk == 1 && !lr) fail($sformatf("call succeeded, expected failure %0d", stv));
                else if (stk == 1 && status != stv) fail($sformatf("call failed with %0d, expected %0d", status, stv));
                else if (has && got != exp) fail($sformatf("call answered %s, expected %s", hexq(got), hexq(exp)));
              end
            end
          end
        end
        8'h0A: begin // flush ch settle expect
          int ch, t; bit has, aerr, le, lr; int exp[$], got[$];
          ch = u8(); t = u32(); has = read_expect(exp);
          if (active) begin
            repeat (t) @(posedge clk);
            pull(); pull();
            take(ch + 1, q_byte[ch+1].size(), got, aerr, le, lr);
            if (has && got != exp) fail($sformatf("channel %0d held %s, expected %s", ch, hexq(got), hexq(exp)));
          end
        end
        8'h0B: begin int b, tp, rp, pa; b = u16(); tp = u8(); rp = u8(); pa = u8();
          if (active) begin s_bit = b; s_txpad = tp; s_rxpad = rp; s_parity = pa; s_problem = ""; s_on = 1; end end
        8'h0C: begin int n; n = u16(); for (int i = 0; i < n; i++) begin int v; v = u8(); if (active) s_tx.push_back(v); end end
        8'h0D: begin
          int count, t; bit has; int exp[$], got[$]; longint t0;
          count = u16(); t = u32(); has = read_expect(exp);
          if (active) begin
            t0 = $time;
            while (s_rx.size() < count && ($time - t0) / CLK_NS <= t) @(posedge clk);
            if (s_rx.size() < count) fail($sformatf("UART device got %s, wanted %0d bytes", hexq(s_rx), count));
            else begin
              got = {}; for (int i = 0; i < count; i++) got.push_back(s_rx.pop_front());
              if (has && got != exp) fail($sformatf("UART device got %s, expected %s", hexq(got), hexq(exp)));
            end
          end
        end
        default: begin $display("bad op %02x at %0d", op, pc - 1); $fatal(1); end
      endcase
    end
  endtask

  initial begin
    string prog, line, fn;
    int fd;
    if (!$value$plusargs("PROG=%s", prog)) $fatal(1, "+PROG=programs/<name> required");
    fn = {prog, "/tests.hwmem"};
    for (int i = 0; i < $size(mem); i++) mem[i] = 8'h00;
    $readmemh(fn, mem);
    fd = $fopen({prog, "/tests.names"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/tests.names", prog);
    while ($fgets(line, fd)) begin
      if (line.len() > 0 && line[line.len()-1] == "\n") line = line.substr(0, line.len()-2);
      names.push_back(line);
    end
    $fclose(fd);
    $display("== %s (sim) ==", prog);
    run();
    $display("== %0d passed, %0d failed, %0d skipped ==", n_pass, n_fail, n_skip);
    if (n_fail == 0 && n_pass > 0) $display("PASS"); else $display("FAIL");
    $finish;
  end

  initial if ($test$plusargs("WAVES")) begin
    $dumpfile("sim/tb_hwtest.fst");
    $dumpvars(0, tb_hwtest);
  end
endmodule

`default_nettype wire
