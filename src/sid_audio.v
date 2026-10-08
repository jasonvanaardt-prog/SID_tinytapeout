/*
 * sid_audio.v -- SID voice amplitude, filter and output mixer
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * The whole chip runs from phi2 alone, so there is exactly one clock
 * cycle per phi2 period and the audio pipeline is organised as a
 * repeating 8-cycle frame.  Two small multipliers run concurrently:
 *
 *   mulv (13x8)  voice amplitude, waveform x envelope.  One voice per
 *                cycle, round robin, twice per frame.  The two products
 *                for a voice are averaged, which both decimates from
 *                phi2/3 to phi2/8 and puts a null at phi2/4 -- cheap
 *                anti-aliasing for waveform harmonics that would
 *                otherwise fold into the audio band.
 *
 *   mulf (18x14) the filter's two integrators and resonance tap, plus
 *                the master volume.
 *
 * The filter is the original chip's two-integrator loop, so low-pass,
 * band-pass and high-pass are available at once and can be summed:
 *
 *   low  = low  + w0    * band
 *   high = in   - low   - (1/Q) * band
 *   band = band + w0    * high
 *
 * Multiplier latency is two cycles, not one: the operands are registered
 * on one edge and the product on the next, so operands issued in cycle N
 * give a product that is readable in cycle N+2.
 *
 *   cycle  mulv issue   mulv collect    mulf issue    mulf collect
 *   0      voice 1                      w0*band       latch mixer buses
 *   1      voice 2                                    audio = p>>4
 *   2      voice 3      voice 1 -> a    q*band        low  += p
 *   3      voice 1      voice 2 -> a
 *   4      voice 2      voice 3 -> a                  high  = in-low-p
 *   5      voice 3      voice 1 += b    w0*high
 *   6                   voice 2 += b
 *   7                   voice 3 += b    total*vol     band += p
 *
 * The voice sums therefore complete at the end of cycle 7 and are latched
 * into the mixer buses at cycle 0 of the next frame.
 */

`default_nettype none

module sid_audio (
    input  wire        clk,
    input  wire        rst_n,

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

    input  wire        ext_in,        // 1-bit sigma-delta EXT IN

    output reg signed [15:0] audio_o,
    output wire        frame_tick     // one pulse per filter sample
);

  // --------------------------------------------------- the 8-cycle frame
  reg [2:0] st;
  always @(posedge clk) begin
    if (!rst_n) st <= 3'd0;
    else        st <= st + 3'd1;
  end

  // audio_o is assigned in cycle 1, so flag the new sample in cycle 2.
  assign frame_tick = (st == 3'd2);

  // --------------------------------------------------- coefficients
  wire [13:0] w0;
  wire [13:0] q_inv;

  sid_fc_curve u_fc (.fc(fc), .is_6581(is_6581), .w0(w0));
  sid_q_table  u_q  (.res(res), .q_inv(q_inv));

  // Two cascaded one-pole smoothers on w0.  Without these, a program
  // stepping the cutoff register produces an audible click on every
  // write; the real filter's control voltage is smoothed the same way.
  //
  // These are exponential moving averages with a gain of 64, held in
  // Q13.6 so they settle on the target exactly rather than parking an
  // LSB short of it.  The time constant is 64 phi2 periods, about 65 us.
  reg [20:0] w0_lag0, w0_lag1;
  wire [13:0] w0_smooth = w0_lag1[19:6];

  always @(posedge clk) begin
    if (!rst_n) begin
      w0_lag0 <= 21'd0;
      w0_lag1 <= 21'd0;
    end else begin
      w0_lag0 <= w0_lag0 - (w0_lag0 >> 6) + {7'd0, w0};
      w0_lag1 <= w0_lag1 - (w0_lag1 >> 6) + {7'd0, w0_lag0[19:6]};
    end
  end

  // ------------------------------------------- voice amplitude multiplier
  // Centre the unsigned waveform on zero, then scale by the envelope.
  wire signed [12:0] wc1 = $signed({1'b0, wave1}) - 13'sd2048;
  wire signed [12:0] wc2 = $signed({1'b0, wave2}) - 13'sd2048;
  wire signed [12:0] wc3 = $signed({1'b0, wave3}) - 13'sd2048;

  reg  signed [12:0] mulv_a;
  reg         [7:0]  mulv_b;
  reg  signed [21:0] prodv;

  always @(posedge clk) begin
    if (!rst_n) prodv <= 22'sd0;
    else        prodv <= mulv_a * $signed({1'b0, mulv_b});
  end

  // Operand select: voices 1,2,3,1,2,3 on cycles 0..5.
  always @(posedge clk) begin
    if (!rst_n) begin
      mulv_a <= 13'sd0;
      mulv_b <= 8'd0;
    end else begin
      case (st)
        3'd0, 3'd3: begin mulv_a <= wc1; mulv_b <= env1; end
        3'd1, 3'd4: begin mulv_a <= wc2; mulv_b <= env2; end
        3'd2, 3'd5: begin mulv_a <= wc3; mulv_b <= env3; end
        default: ;
      endcase
    end
  end

  // Per-voice accumulators: set on the first product, add the second.
  reg signed [22:0] va1, va2, va3;

  always @(posedge clk) begin
    if (!rst_n) begin
      va1 <= 23'sd0;
      va2 <= 23'sd0;
      va3 <= 23'sd0;
    end else begin
      case (st)
        3'd2: va1 <= {prodv[21], prodv};
        3'd3: va2 <= {prodv[21], prodv};
        3'd4: va3 <= {prodv[21], prodv};
        3'd5: va1 <= va1 + {prodv[21], prodv};
        3'd6: va2 <= va2 + {prodv[21], prodv};
        3'd7: va3 <= va3 + {prodv[21], prodv};
        default: ;
      endcase
    end
  end

  // Mean of the two products (>>1), scaled down by 256, so about +/- 2040.
  wire signed [13:0] vs1 = va1[22:9];
  wire signed [13:0] vs2 = va2[22:9];
  wire signed [13:0] vs3 = va3[22:9];

  // ------------------------------------------------------------- EXT IN
  // A 1-bit sigma-delta input pin: count the ones over the frame and
  // centre the result, giving nine levels per filter sample.
  reg [3:0] ext_cnt;
  reg signed [13:0] ext_val;

  // Centre the count of ones (0..8 becomes -4..+4) and scale by 512, which
  // is exactly 14 bits -- hence the width of ext_val.
  wire signed [4:0] ext_c = $signed({1'b0, ext_cnt}) - 5'sd4;

  always @(posedge clk) begin
    if (!rst_n) begin
      ext_cnt <= 4'd0;
      ext_val <= 14'sd0;
    end else if (st == 3'd7) begin
      ext_val <= $signed({ext_c, 9'd0});
      ext_cnt <= {3'd0, ext_in};
    end else begin
      ext_cnt <= ext_cnt + {3'd0, ext_in};
    end
  end

  // -------------------------------------------------------- mixer buses
  // Routing: voice 3 can be silenced, but only when it is not filtered.
  wire mute3 = voice3_off & ~filt[2];

  wire signed [15:0] sum_unfilt = (filt[0] ? 16'sd0 : {{2{vs1[13]}}, vs1})
                                + (filt[1] ? 16'sd0 : {{2{vs2[13]}}, vs2})
                                + ((filt[2] | mute3) ? 16'sd0 : {{2{vs3[13]}}, vs3});

  wire signed [15:0] sum_filt = (filt[0] ? {{2{vs1[13]}}, vs1} : 16'sd0)
                              + (filt[1] ? {{2{vs2[13]}}, vs2} : 16'sd0)
                              + (filt[2] ? {{2{vs3[13]}}, vs3} : 16'sd0)
                              + (filt[3] ? {{2{ext_val[13]}}, ext_val} : 16'sd0);

  reg signed [15:0] r_unfilt, r_filt;

  // ------------------------------------------------------ filter section
  reg  signed [17:0] f_low, f_band, f_high;

  reg  signed [17:0] mulf_a;
  reg         [13:0] mulf_b;
  reg  signed [32:0] prodf;      // 18 + 15 bits, the exact product width

  always @(posedge clk) begin
    if (!rst_n) prodf <= 33'sd0;
    else        prodf <= mulf_a * $signed({1'b0, mulf_b});
  end

  // Arithmetic shifts, so the sign of the product survives.  24 bits is
  // wide enough for the worst case (a fully clamped state times the
  // largest 1/Q coefficient) and clamp18() brings it back in range.
  // Taken as explicit sign-extending slices rather than >>>, so the
  // narrowing is stated rather than implied.
  wire signed [23:0] p_w0 = {{5{prodf[32]}}, prodf[32:14]};   // Q0.14
  wire signed [23:0] p_q  = {{3{prodf[32]}}, prodf[32:12]};   // Q1.12

  function signed [17:0] clamp18(input signed [23:0] v);
    clamp18 = (v >  24'sd131071) ?  18'sd131071 :
              (v < -24'sd131072) ? -18'sd131072 : v[17:0];
  endfunction

  wire signed [23:0] x_low    = {{6{f_low[17]}},    f_low};
  wire signed [23:0] x_band   = {{6{f_band[17]}},   f_band};
  wire signed [23:0] x_high   = {{6{f_high[17]}},   f_high};
  wire signed [23:0] x_filt   = {{8{r_filt[15]}},   r_filt};
  wire signed [23:0] x_unfilt = {{8{r_unfilt[15]}}, r_unfilt};

  wire signed [23:0] f_out = (mode[0] ? x_low  : 24'sd0)
                           + (mode[1] ? x_band : 24'sd0)
                           + (mode[2] ? x_high : 24'sd0);

  wire signed [28:0] scaled = prodf[32:4];           // total * vol / 16

  always @(posedge clk) begin
    if (!rst_n) begin
      mulf_a   <= 18'sd0;
      mulf_b   <= 14'd0;
      f_low    <= 18'sd0;
      f_band   <= 18'sd0;
      f_high   <= 18'sd0;
      r_unfilt <= 16'sd0;
      r_filt   <= 16'sd0;
      audio_o  <= 16'sd0;
    end else begin
      case (st)
        3'd0: begin                       // latch the frame's mixer buses
          r_unfilt <= sum_unfilt;
          r_filt   <= sum_filt;
          mulf_a   <= f_band;             // -> w0 * band, read in cycle 2
          mulf_b   <= w0_smooth;
        end

        3'd1: begin                       // volume product from cycle 7
          audio_o <= (scaled >  29'sd32767) ?  16'sd32767 :
                     (scaled < -29'sd32768) ? -16'sd32768 :
                     scaled[15:0];
        end

        3'd2: begin                       // low += w0*band
          f_low  <= clamp18(x_low + p_w0);
          mulf_a <= f_band;               // -> (1/Q) * band, read in cycle 4
          mulf_b <= q_inv;
        end

        3'd4: begin                       // high = in - low - (1/Q)*band
          f_high <= clamp18(x_filt - x_low - p_q);
        end

        3'd5: begin                       // -> w0 * high, read in cycle 7
          mulf_a <= f_high;
          mulf_b <= w0_smooth;
        end

        3'd7: begin                       // band += w0*high, then volume
          f_band <= clamp18(x_band + p_w0);
          mulf_a <= clamp18(x_unfilt + f_out);
          mulf_b <= {10'd0, vol};
        end

        default: ;
      endcase
    end
  end

endmodule
