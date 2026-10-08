/*
 * sid_audio.v -- SID voice amplitude, filter and output mixer
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * One 18x13 signed multiplier is time-shared across the whole audio
 * pipeline by a sequencer that runs once per phi2 period:
 *
 *   3 voice amplitude multiplies   (waveform x envelope)
 *   3 filter multiplies            (two integrators + resonance tap)
 *   1 master volume multiply
 *
 * The filter is the original chip's two-integrator loop (a state
 * variable filter), which is why low-pass, band-pass and high-pass are
 * available at once and can be summed:
 *
 *   low  = low  + w0    * band
 *   high = in   - low   - (1/Q) * band
 *   band = band + w0    * high
 *
 * The sequence takes 15 clk cycles, so clk must be at least ~16x phi2.
 * At the Tiny Tapeout default of 50 MHz with a 1 MHz phi2 there are 50
 * cycles available.
 *
 * Multiplier timing: operands written during state S are registered at
 * the S -> S+1 edge, so the product is readable during state S+2.
 */

`default_nettype none

module sid_audio (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,          // one phi2 period

    // Per-voice oscillator and envelope values
    input  wire [11:0] wave1,
    input  wire [11:0] wave2,
    input  wire [11:0] wave3,
    input  wire [7:0]  env1,
    input  wire [7:0]  env2,
    input  wire [7:0]  env3,

    // Filter and mixer registers
    input  wire [10:0] fc,            // 15/16  cutoff
    input  wire [3:0]  res,           // 17[7:4] resonance
    input  wire [3:0]  filt,          // 17[3:0] filt ext, v3, v2, v1
    input  wire        voice3_off,    // 18[7]
    input  wire [2:0]  mode,          // 18[6:4] HP, BP, LP
    input  wire [3:0]  vol,           // 18[3:0]
    input  wire        is_6581,

    output reg signed [15:0] audio_o
);

  // ------------------------------------------------- shared multiplier
  reg  signed [17:0] mul_a;
  reg         [12:0] mul_b;
  reg  signed [30:0] prod;

  always @(posedge clk) begin
    if (!rst_n) prod <= 31'sd0;
    else        prod <= mul_a * $signed({1'b0, mul_b});
  end

  // Arithmetic shifts, so the sign of the product survives.  24 bits is
  // wide enough for the worst case (a fully clamped state times the
  // largest 1/Q coefficient) and clamp18() brings it back in range.
  wire signed [23:0] p_w0 = prod >>> 16;   // Q0.16 coefficient
  wire signed [23:0] p_q  = prod >>> 12;   // Q1.12 coefficient

  // --------------------------------------------------- coefficients
  wire [12:0] w0;
  wire [12:0] q_inv;

  sid_fc_curve u_fc (.fc(fc), .is_6581(is_6581), .w0(w0));
  sid_q_table  u_q  (.res(res), .q_inv(q_inv));

  // Two cascaded one-pole smoothers on w0.  Without these, a program
  // stepping the cutoff register produces an audible click on every
  // write; the real filter's control voltage is smoothed the same way.
  reg [12:0] w0_lag0, w0_lag1;
  always @(posedge clk) begin
    if (!rst_n) begin
      w0_lag0 <= 13'd0;
      w0_lag1 <= 13'd0;
    end else if (tick) begin
      w0_lag0 <= (w0_lag0 + w0) >> 1;
      w0_lag1 <= (w0_lag1 + w0_lag0) >> 1;
    end
  end

  // ------------------------------------------------------ voice values
  // Centre the unsigned waveform on zero, then scale by the envelope.
  wire signed [12:0] wc1 = $signed({1'b0, wave1}) - 13'sd2048;
  wire signed [12:0] wc2 = $signed({1'b0, wave2}) - 13'sd2048;
  wire signed [12:0] wc3 = $signed({1'b0, wave3}) - 13'sd2048;

  reg signed [13:0] vs1, vs2, vs3;    // +/- 4080

  // Routing: voice 3 can be silenced, but only when it is not filtered.
  wire mute3 = voice3_off & ~filt[2];

  wire signed [15:0] sum_unfilt = (filt[0] ? 16'sd0 : {{2{vs1[13]}}, vs1})
                                + (filt[1] ? 16'sd0 : {{2{vs2[13]}}, vs2})
                                + ((filt[2] | mute3) ? 16'sd0 : {{2{vs3[13]}}, vs3});

  // EXT IN (filt[3]) has no pin on Tiny Tapeout -- see docs/info.md.
  wire signed [15:0] sum_filt = (filt[0] ? {{2{vs1[13]}}, vs1} : 16'sd0)
                              + (filt[1] ? {{2{vs2[13]}}, vs2} : 16'sd0)
                              + (filt[2] ? {{2{vs3[13]}}, vs3} : 16'sd0);

  reg signed [15:0] r_unfilt, r_filt;

  // ------------------------------------------------------ filter state
  reg signed [17:0] f_low, f_band, f_high;

  function signed [17:0] clamp18(input signed [23:0] v);
    clamp18 = (v >  24'sd131071) ?  18'sd131071 :
              (v < -24'sd131072) ? -18'sd131072 : v[17:0];
  endfunction

  // Sign-extended views, for use in the 24-bit accumulations below.
  wire signed [23:0] x_low    = {{6{f_low[17]}},     f_low};
  wire signed [23:0] x_band   = {{6{f_band[17]}},    f_band};
  wire signed [23:0] x_filt   = {{8{r_filt[15]}},    r_filt};
  wire signed [23:0] x_unfilt = {{8{r_unfilt[15]}},  r_unfilt};

  wire signed [23:0] f_out = (mode[0] ? x_low  : 24'sd0)
                           + (mode[1] ? x_band : 24'sd0)
                           + (mode[2] ? {{6{f_high[17]}}, f_high} : 24'sd0);

  // Volume scaling: total * vol / 16, then clipped to 16 bits.
  wire signed [30:0] scaled = prod >>> 4;

  // ----------------------------------------------------- the sequencer
  localparam ST_IDLE = 4'd15;

  reg [3:0] st;

  always @(posedge clk) begin
    if (!rst_n) begin
      st       <= ST_IDLE;
      vs1      <= 14'sd0;
      vs2      <= 14'sd0;
      vs3      <= 14'sd0;
      r_unfilt <= 16'sd0;
      r_filt   <= 16'sd0;
      f_low    <= 18'sd0;
      f_band   <= 18'sd0;
      f_high   <= 18'sd0;
      mul_a    <= 18'sd0;
      mul_b    <= 13'd0;
      audio_o  <= 16'sd0;
    end else begin
      case (st)
        ST_IDLE: begin                     // wait for phi2
          if (tick) begin
            mul_a <= {{5{wc1[12]}}, wc1};
            mul_b <= {5'd0, env1};
            st    <= 4'd0;
          end
        end

        4'd0: begin                        // set up voice 2
          mul_a <= {{5{wc2[12]}}, wc2};
          mul_b <= {5'd0, env2};
          st    <= 4'd1;
        end

        4'd1: begin                        // collect voice 1, set up voice 3
          vs1   <= prod[21:8];
          mul_a <= {{5{wc3[12]}}, wc3};
          mul_b <= {5'd0, env3};
          st    <= 4'd2;
        end

        4'd2: begin                        // collect voice 2
          vs2 <= prod[21:8];
          st  <= 4'd3;
        end

        4'd3: begin                        // collect voice 3
          vs3 <= prod[21:8];
          st  <= 4'd4;
        end

        4'd4: begin                        // latch mixer buses, start w0*band
          r_unfilt <= sum_unfilt;
          r_filt   <= sum_filt;
          mul_a    <= f_band;
          mul_b    <= w0_lag1;
          st       <= 4'd5;
        end

        4'd5: begin                        // (1/Q) * band
          mul_a <= f_band;
          mul_b <= q_inv;
          st    <= 4'd6;
        end

        4'd6: begin                        // low += w0*band
          f_low <= clamp18(x_low + p_w0);
          st    <= 4'd7;
        end

        4'd7: begin                        // high = in - low - (1/Q)*band
          f_high <= clamp18(x_filt - x_low - p_q);
          st     <= 4'd8;
        end

        4'd8: begin                        // w0 * high
          mul_a <= f_high;
          mul_b <= w0_lag1;
          st    <= 4'd9;
        end

        4'd9:  st <= 4'd10;                // multiplier latency

        4'd10: begin                       // band += w0*high
          f_band <= clamp18(x_band + p_w0);
          st     <= 4'd11;
        end

        4'd11: begin                       // total * volume
          mul_a <= clamp18(x_unfilt + f_out);
          mul_b <= {9'd0, vol};
          st    <= 4'd12;
        end

        4'd12: st <= 4'd13;                // multiplier latency

        4'd13: begin                       // scale and clip the sample
          audio_o <= (scaled >  31'sd32767) ?  16'sd32767 :
                     (scaled < -31'sd32768) ? -16'sd32768 :
                     scaled[15:0];
          st      <= ST_IDLE;
        end

        default: st <= ST_IDLE;
      endcase
    end
  end

endmodule
