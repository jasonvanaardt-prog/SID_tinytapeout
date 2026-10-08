/*
 * sid_voice.v -- MOS 6581/8580 SID oscillator + waveform generator
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * One voice: 24-bit phase accumulator, saw/triangle/pulse/noise waveform
 * generators, ring modulation, oscillator sync and the TEST bit.
 *
 * clk is phi2, so the accumulator advances once per phi2 period and the
 * oscillator is cycle-accurate with the original chip.
 */

`default_nettype none

module sid_voice (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] freq,        // frequency
    input  wire [11:0] pw,          // pulse width
    input  wire [7:0]  ctrl,        // control register

    input  wire [23:0] src_acc,     // accumulator of the sync/ring source voice

    output wire [23:0] acc_o,       // this voice's accumulator (to next voice)
    output wire [11:0] wave_o       // 12-bit waveform output
);

  // Control register bit assignments (6581 datasheet, register 04/0B/12)
  wire noise_en = ctrl[7];
  wire pulse_en = ctrl[6];
  wire saw_en   = ctrl[5];
  wire tri_en   = ctrl[4];
  wire test     = ctrl[3];
  wire ringmod  = ctrl[2];
  wire sync_en  = ctrl[1];

  // ---------------------------------------------------------------- phase
  reg [23:0] acc;
  assign acc_o = acc;

  // Sync resets this accumulator on the rising edge of the source MSB.
  reg  src_msb_d;
  wire src_msb_rise = src_acc[23] & ~src_msb_d;

  always @(posedge clk) begin
    if (!rst_n) begin
      acc       <= 24'd0;
      src_msb_d <= 1'b0;
    end else begin
      src_msb_d <= src_acc[23];
      if (test || (sync_en && src_msb_rise))
        acc <= 24'd0;
      else
        acc <= acc + {8'd0, freq};
    end
  end

  // ---------------------------------------------------------------- noise
  // 23-bit LFSR, taps 22 and 17, clocked from accumulator bit 19.
  reg [22:0] lfsr;
  reg        acc19_d;

  always @(posedge clk) begin
    if (!rst_n) begin
      lfsr    <= 23'h7fffff;
      acc19_d <= 1'b0;
    end else begin
      acc19_d <= acc[19];
      // TEST forces ones into the shift register, as on the real chip.
      if ((acc[19] & ~acc19_d) || test)
        lfsr <= {lfsr[21:0], (test | lfsr[22]) ^ lfsr[17]};
    end
  end

  wire [11:0] w_noise = {lfsr[20], lfsr[18], lfsr[14], lfsr[11],
                         lfsr[9],  lfsr[5],  lfsr[2],  lfsr[0], 4'b0000};

  // ------------------------------------------------------------ waveforms
  wire [11:0] w_saw = acc[23:12];

  // Ring modulation replaces the triangle's sign bit with acc^src MSB.
  wire        tri_msb = acc[23] ^ (ringmod & src_acc[23]);
  wire [11:0] w_tri   = tri_msb ? ~acc[22:11] : acc[22:11];

  // TEST holds the pulse output high.
  wire [11:0] w_pulse = (test || (acc[23:12] >= pw)) ? 12'hfff : 12'h000;

  // Selected waveforms are wire-ANDed in the original chip's waveform DAC;
  // unselected ones contribute all ones.
  wire [11:0] m_tri   = tri_en   ? w_tri   : 12'hfff;
  wire [11:0] m_saw   = saw_en   ? w_saw   : 12'hfff;
  wire [11:0] m_pulse = pulse_en ? w_pulse : 12'hfff;
  wire [11:0] m_noise = noise_en ? w_noise : 12'hfff;

  wire any_sel = tri_en | saw_en | pulse_en | noise_en;

  assign wave_o = any_sel ? (m_tri & m_saw & m_pulse & m_noise) : 12'h000;

endmodule
