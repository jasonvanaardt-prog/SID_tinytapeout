/*
 * project.v -- Tiny Tapeout top level for a MOS 6581/8580 SID replica
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * A drop-in replacement for the original chip: clk is phi2 and the whole
 * design runs from it at the original SID rate -- 985248 Hz on a PAL C64,
 * 1022727 Hz on NTSC -- so there is no second oscillator anywhere and
 * every pitch, envelope time and filter sweep comes out at exactly the
 * rate the real chip produces.
 *
 *   6581 pin        Tiny Tapeout pin     note
 *   --------------  -------------------  ----------------------------------
 *   D0..D7   15-22  uio[0..7]            bidirectional, driven on reads
 *   A0..A4    9-13  ui_in[0..4]
 *   /CS          8  ui_in[5]             must be phi2-qualified
 *   R//W         7  ui_in[6]
 *   phi2         6  clk                  the design's only clock
 *   /RES         5  rst_n
 *   EXT IN      26  ui_in[7]             1-bit sigma-delta, not analog
 *   AUDIO OUT   27  uo_out[0]            1-bit sigma-delta, needs an RC
 *   POT X       24  -- no analog pin, see docs/info.md
 *   POT Y       23  -- no analog pin, see docs/info.md
 *   CAP1A/B    1-2  -- not needed: the filter is digital
 *   CAP2A/B    3-4  -- not needed: the filter is digital
 *
 * Because phi2 is the clock, the bus signals are already synchronous to
 * it and are used directly, with no synchroniser: that is what lets a
 * write complete in a single phi2 period the way the original does.
 */

`default_nettype none

module tt_um_sid6581 (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidirectional: input path
    output wire [7:0] uio_out,  // bidirectional: output path
    output wire [7:0] uio_oe,   // bidirectional: 1 = drive out
    input  wire       ena,      // high when the design is selected
    input  wire       clk,      // phi2
    input  wire       rst_n     // /RES, active low
);

  wire [4:0] addr   = ui_in[4:0];
  wire       cs_n   = ui_in[5];
  wire       rw     = ui_in[6];
  wire       ext_in = ui_in[7];

  // ----------------------------------------------------------------- core
  wire [7:0]         data_o;
  wire               data_oe;
  wire signed [15:0] audio;
  wire               frame_tick;
  wire               osc3_msb;
  wire               env3_active;

  sid_core u_core (
      .clk        (clk),
      .rst_n      (rst_n),
      .cs_n       (cs_n),
      .rw         (rw),
      .addr       (addr),
      .data_i     (uio_in),
      .data_o     (data_o),
      .data_oe    (data_oe),
      .ext_in     (ext_in),
      .audio_o    (audio),
      .frame_tick (frame_tick),
      .osc3_msb   (osc3_msb),
      .env3_active(env3_active)
  );

  // The data bus is driven only during a read cycle: /CS low and R//W
  // high.  On a C64 /CS is already phi2-qualified by the PLA, so this
  // confines bus driving to phi2 high exactly as on the original chip.
  assign uio_out = data_o;
  assign uio_oe  = {8{data_oe}};

  // ----------------------------------------------------------------- audio
  // I2S bit clock source: phi2 directly by default, or a registered
  // divide-by-two if built with -DSID_I2S_SCK_DIV2.  See sid_dac.v for the
  // trade-off (bandwidth against having no clock-as-data path).
`ifdef SID_I2S_SCK_DIV2
  localparam I2S_SCK_DIV2 = 1;
`else
  localparam I2S_SCK_DIV2 = 0;
`endif

  wire pdm, i2s_sck, i2s_ws, i2s_sd;

  sid_dac #(.SCK_DIV2(I2S_SCK_DIV2)) u_dac (
      .clk       (clk),
      .rst_n     (rst_n),
      .sample    (audio),
      .frame_tick(frame_tick),
      .pdm_o     (pdm),
      .i2s_sck   (i2s_sck),
      .i2s_ws    (i2s_ws),
      .i2s_sd    (i2s_sd)
  );

  assign uo_out[0] = pdm;           // AUDIO OUT  (6581 pin 27)
  assign uo_out[1] = i2s_sd;        // lossless digital audio
  assign uo_out[2] = i2s_ws;
  assign uo_out[3] = i2s_sck;
  assign uo_out[4] = frame_tick;    // phi2/8 sample strobe
  assign uo_out[5] = osc3_msb;      // voice 3 oscillator MSB
  assign uo_out[6] = env3_active;   // voice 3 envelope is non-zero
  assign uo_out[7] = 1'b0;          // reserved

  // ena is driven by the Tiny Tapeout mux and is not needed here.
  wire _unused = &{ena, 1'b0};

endmodule
