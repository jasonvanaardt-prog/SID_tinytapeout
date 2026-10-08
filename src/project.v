/*
 * project.v -- Tiny Tapeout top level for a MOS 6581/8580 SID replica
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * The pinout follows the original 6581 as closely as a digital Tiny
 * Tapeout tile allows.  The entire host-facing interface -- the 8-bit
 * bidirectional data bus, five address lines, /CS, R//W, phi2 and /RES --
 * is reproduced exactly, so a C64 (or any 6502-style bus master) can
 * drive this tile with the same cycle timing it uses for a real SID.
 *
 *   6581 pin        Tiny Tapeout pin     note
 *   --------------  -------------------  ----------------------------------
 *   D0..D7   15-22  uio[0..7]            bidirectional, driven on reads
 *   A0..A4    9-13  ui_in[0..4]
 *   /CS          8  ui_in[5]
 *   R//W         7  ui_in[6]
 *   phi2         6  ui_in[7]             bus and oscillator timing
 *   /RES         5  rst_n
 *   AUDIO OUT   27  uo_out[0]            1-bit sigma-delta, needs an RC
 *   POT X       24  -- no analog pin, see docs/info.md
 *   POT Y       23  -- no analog pin, see docs/info.md
 *   EXT IN      26  -- no analog pin, see docs/info.md
 *   CAP1A/B    1-2  -- not needed: the filter is digital
 *   CAP2A/B    3-4  -- not needed: the filter is digital
 *
 * clk is the tile's system clock and must run at least ~16x phi2; the
 * audio pipeline time-shares one multiplier across 14 cycles per phi2
 * period.  50 MHz clk with a 1 MHz phi2 is the intended operating point.
 */

`default_nettype none

module tt_um_sid6581 (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidirectional: input path
    output wire [7:0] uio_out,  // bidirectional: output path
    output wire [7:0] uio_oe,   // bidirectional: 1 = drive out
    input  wire       ena,      // high when the design is selected
    input  wire       clk,      // system clock
    input  wire       rst_n     // /RES, active low
);

  // --------------------------------------------------------------- inputs
  // The host bus is asynchronous to clk, so everything is taken through
  // two flops before it is used.
  reg [7:0] ui_s1,   ui_s2;
  reg [7:0] uio_s1,  uio_s2;

  always @(posedge clk) begin
    if (!rst_n) begin
      ui_s1  <= 8'h20;   // /CS idle high
      ui_s2  <= 8'h20;
      uio_s1 <= 8'h00;
      uio_s2 <= 8'h00;
    end else begin
      ui_s1  <= ui_in;
      ui_s2  <= ui_s1;
      uio_s1 <= uio_in;
      uio_s2 <= uio_s1;
    end
  end

  wire [4:0] addr = ui_s2[4:0];
  wire       cs_n = ui_s2[5];
  wire       rw   = ui_s2[6];
  wire       phi2 = ui_s2[7];

  // ----------------------------------------------------------------- core
  wire [7:0]        data_o;
  wire              data_oe;
  wire              tick;
  wire signed [15:0] audio;
  wire              osc3_msb;
  wire              env3_active;

  sid_core u_core (
      .clk     (clk),
      .rst_n   (rst_n),
      .phi2    (phi2),
      .cs_n    (cs_n),
      .rw      (rw),
      .addr    (addr),
      .data_i  (uio_s2),
      .data_o  (data_o),
      .data_oe (data_oe),
      .tick    (tick),
      .audio_o (audio),
      .osc3_msb(osc3_msb),
      .env3_active(env3_active)
  );

  // The data bus is only driven during a read cycle: /CS low, R//W high
  // and phi2 high, exactly as on the original chip.
  assign uio_out = data_o;
  assign uio_oe  = {8{data_oe}};

  // ----------------------------------------------------------------- audio
  wire pdm, pwm, i2s_sck, i2s_ws, i2s_sd;

  sid_dac u_dac (
      .clk    (clk),
      .rst_n  (rst_n),
      .sample (audio),
      .pdm_o  (pdm),
      .pwm_o  (pwm),
      .i2s_sck(i2s_sck),
      .i2s_ws (i2s_ws),
      .i2s_sd (i2s_sd)
  );

  assign uo_out[0] = pdm;           // AUDIO OUT  (6581 pin 27)
  assign uo_out[1] = pwm;           // alternative audio output
  assign uo_out[2] = i2s_sd;        // lossless digital audio
  assign uo_out[3] = i2s_ws;
  assign uo_out[4] = i2s_sck;
  assign uo_out[5] = osc3_msb;      // voice 3 oscillator MSB
  assign uo_out[6] = env3_active;   // voice 3 envelope is non-zero
  assign uo_out[7] = tick;          // phi2-rate sample strobe

  // ena is driven by the Tiny Tapeout mux and is not needed here.
  wire _unused = &{ena, 1'b0};

endmodule
