/*
 * sid_core.v -- MOS 6581/8580 SID register file and voice assembly
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * Implements the 29-register map of the original chip, the phi2 bus
 * protocol, the three voices with their sync/ring-modulation chain, and
 * the OSC3 / ENV3 read-back registers.
 */

`default_nettype none

module sid_core (
    input  wire       clk,
    input  wire       rst_n,        // /RES

    // phi2 bus, already synchronised to clk
    input  wire       phi2,
    input  wire       cs_n,         // /CS
    input  wire       rw,           // R//W  (1 = read)
    input  wire [4:0] addr,         // A0..A4
    input  wire [7:0] data_i,       // D0..D7 in
    output wire [7:0] data_o,       // D0..D7 out
    output wire       data_oe,      // drive the data bus

    output wire       tick,         // one clk pulse per phi2 period
    output wire signed [15:0] audio_o,
    output wire       osc3_msb,
    output wire       env3_active
);

  // ------------------------------------------------------- phi2 edges
  reg phi2_d;
  always @(posedge clk) begin
    if (!rst_n) phi2_d <= 1'b0;
    else        phi2_d <= phi2;
  end

  wire phi2_rise = phi2 & ~phi2_d;
  wire phi2_fall = ~phi2 & phi2_d;

  // The oscillators and envelopes advance once per phi2 period.
  assign tick = phi2_rise;

  // --------------------------------------------------------- registers
  reg [15:0] r_freq [0:2];
  reg [11:0] r_pw   [0:2];
  reg [7:0]  r_ctrl [0:2];
  reg [7:0]  r_ad   [0:2];
  reg [7:0]  r_sr   [0:2];

  reg [10:0] r_fc;          // 15 (low 3 bits) / 16 (high 8 bits)
  reg [7:0]  r_resfilt;     // 17
  reg [7:0]  r_modevol;     // 18

  // Paddle values.  POT X/Y are analog RC-sense pins on the real chip and
  // cannot be reproduced on a digital tile, so 1D/1E -- unconnected on the
  // original -- let a host load the values that 19/1A read back.
  reg [7:0]  r_potx;
  reg [7:0]  r_poty;
  reg [7:0]  r_cfg;         // 1F: bit 0 selects 8580 cutoff law

  wire is_6581 = ~r_cfg[0];

  // Address decode: three 7-register voice blocks, then the common block.
  wire [1:0] vsel = (addr <= 5'h06) ? 2'd0 :
                    (addr <= 5'h0d) ? 2'd1 : 2'd2;
  wire [4:0] vbase = (vsel == 2'd0) ? 5'h00 :
                     (vsel == 2'd1) ? 5'h07 : 5'h0e;
  wire [4:0] roff = addr - vbase;
  wire [2:0] rsel = roff[2:0];

  wire wr = phi2_fall & ~cs_n & ~rw;

  integer i;
  always @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < 3; i = i + 1) begin
        r_freq[i] <= 16'd0;
        r_pw[i]   <= 12'd0;
        r_ctrl[i] <= 8'd0;
        r_ad[i]   <= 8'd0;
        r_sr[i]   <= 8'd0;
      end
      r_fc      <= 11'd0;
      r_resfilt <= 8'd0;
      r_modevol <= 8'd0;
      r_potx    <= 8'd0;
      r_poty    <= 8'd0;
      r_cfg     <= 8'd0;
    end else if (wr) begin
      if (addr <= 5'h14) begin
        case (rsel)
          3'd0: r_freq[vsel] <= {r_freq[vsel][15:8], data_i};
          3'd1: r_freq[vsel] <= {data_i, r_freq[vsel][7:0]};
          3'd2: r_pw[vsel]   <= {r_pw[vsel][11:8], data_i};
          3'd3: r_pw[vsel]   <= {data_i[3:0], r_pw[vsel][7:0]};
          3'd4: r_ctrl[vsel] <= data_i;
          3'd5: r_ad[vsel]   <= data_i;
          3'd6: r_sr[vsel]   <= data_i;
        endcase
      end else begin
        case (addr)
          5'h15: r_fc      <= {r_fc[10:3], data_i[2:0]};
          5'h16: r_fc      <= {data_i, r_fc[2:0]};
          5'h17: r_resfilt <= data_i;
          5'h18: r_modevol <= data_i;
          5'h1d: r_potx    <= data_i;   // extension, see above
          5'h1e: r_poty    <= data_i;   // extension, see above
          5'h1f: r_cfg     <= data_i;   // extension, see above
          default: ;
        endcase
      end
    end
  end

  // ------------------------------------------------------------ voices
  wire [23:0] acc  [0:2];
  wire [11:0] wave [0:2];
  wire [7:0]  env  [0:2];

  // Sync and ring modulation take their source from the previous voice,
  // wrapping around: 1<-3, 2<-1, 3<-2.
  wire [23:0] src0 = acc[2];
  wire [23:0] src1 = acc[0];
  wire [23:0] src2 = acc[1];

  sid_voice u_v0 (
      .clk(clk), .rst_n(rst_n), .tick(tick),
      .freq(r_freq[0]), .pw(r_pw[0]), .ctrl(r_ctrl[0]),
      .src_acc(src0), .acc_o(acc[0]), .wave_o(wave[0]));

  sid_voice u_v1 (
      .clk(clk), .rst_n(rst_n), .tick(tick),
      .freq(r_freq[1]), .pw(r_pw[1]), .ctrl(r_ctrl[1]),
      .src_acc(src1), .acc_o(acc[1]), .wave_o(wave[1]));

  sid_voice u_v2 (
      .clk(clk), .rst_n(rst_n), .tick(tick),
      .freq(r_freq[2]), .pw(r_pw[2]), .ctrl(r_ctrl[2]),
      .src_acc(src2), .acc_o(acc[2]), .wave_o(wave[2]));

  sid_envelope u_e0 (
      .clk(clk), .rst_n(rst_n), .tick(tick), .gate(r_ctrl[0][0]),
      .attack(r_ad[0][7:4]), .decay(r_ad[0][3:0]),
      .sustain(r_sr[0][7:4]), .release_(r_sr[0][3:0]), .env_o(env[0]));

  sid_envelope u_e1 (
      .clk(clk), .rst_n(rst_n), .tick(tick), .gate(r_ctrl[1][0]),
      .attack(r_ad[1][7:4]), .decay(r_ad[1][3:0]),
      .sustain(r_sr[1][7:4]), .release_(r_sr[1][3:0]), .env_o(env[1]));

  sid_envelope u_e2 (
      .clk(clk), .rst_n(rst_n), .tick(tick), .gate(r_ctrl[2][0]),
      .attack(r_ad[2][7:4]), .decay(r_ad[2][3:0]),
      .sustain(r_sr[2][7:4]), .release_(r_sr[2][3:0]), .env_o(env[2]));

  // ------------------------------------------------------------- audio
  sid_audio u_audio (
      .clk(clk), .rst_n(rst_n), .tick(tick),
      .wave1(wave[0]), .wave2(wave[1]), .wave3(wave[2]),
      .env1(env[0]),   .env2(env[1]),   .env3(env[2]),
      .fc(r_fc),
      .res(r_resfilt[7:4]),
      .filt(r_resfilt[3:0]),
      .voice3_off(r_modevol[7]),
      .mode(r_modevol[6:4]),
      .vol(r_modevol[3:0]),
      .is_6581(is_6581),
      .audio_o(audio_o));

  assign osc3_msb    = acc[2][23];
  assign env3_active = |env[2];

  // -------------------------------------------------------- bus read-back
  // Only 19..1C are readable.  Write-only registers read as zero here; on
  // the real chip they return whatever the bus capacitance still holds.
  reg [7:0] rdata;
  always @(*) begin
    case (addr)
      5'h19:   rdata = r_potx;
      5'h1a:   rdata = r_poty;
      5'h1b:   rdata = wave[2][11:4];   // OSC3 / RANDOM
      5'h1c:   rdata = env[2];          // ENV3
      default: rdata = 8'h00;
    endcase
  end

  assign data_o  = rdata;
  assign data_oe = phi2 & ~cs_n & rw;

endmodule
