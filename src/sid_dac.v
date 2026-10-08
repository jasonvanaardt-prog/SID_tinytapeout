/*
 * sid_dac.v -- digital audio output stages
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * The original 6581 drives AUDIO OUT from an on-chip analog output
 * amplifier.  A digital tile has no such pin, so the sample stream is
 * offered two ways: a 1-bit sigma-delta pin that needs only an RC, and an
 * I2S stream for an external DAC.
 *
 * Running from phi2 alone costs real output resolution and it is worth
 * being honest about the arithmetic.  A 1-bit output at 985 kHz gives an
 * oversampling ratio of only about 25 for a 20 kHz audio band, where a
 * 50 MHz clock would give 1250.  A first-order modulator at that ratio
 * would manage about 37 dB, which is not good enough, so the modulator
 * here is second order: roughly
 *
 *     1.76 - 12.9 + 50*log10(25)  ~=  59 dB
 *
 * in the audio band, comparable to what a real 6581 achieves in a C64
 * once its own noise and hum are counted.  For better than that, take the
 * I2S output into an external DAC.
 *
 * PWM is not offered: at phi2 rates an 8-bit carrier would land near
 * 3.8 kHz, right in the middle of the audio band.
 */

`default_nettype none

module sid_dac #(
    // I2S bit clock source.
    //
    //   0 (default)  sck is phi2 itself, so a 32-bit frame takes 32 phi2
    //                periods: phi2/32, 30.8 kHz on PAL, 15.4 kHz of audio
    //                bandwidth.  This routes the clock net to an output
    //                pin, which the Tiny Tapeout flow expects -- its
    //                config sets DESIGN_REPAIR_BUFFER_OUTPUT_PORTS to 0
    //                precisely so output ports do not get clock buffers.
    //
    //   1            sck is a registered divide-by-two, so nothing but
    //                flop outputs leave the module and there is no
    //                clock-as-data path at all.  The frame then takes 64
    //                phi2 periods: phi2/64, 15.4 kHz, halving the audio
    //                bandwidth to 7.7 kHz.  Select it with
    //                -DSID_I2S_SCK_DIV2 if the flow objects to the direct
    //                version; the sigma-delta output is unaffected either
    //                way.
    parameter SCK_DIV2 = 0
) (
    input  wire               clk,        // phi2
    input  wire               rst_n,
    input  wire signed [15:0] sample,
    input  wire               frame_tick, // one pulse per filter sample

    output reg                pdm_o,
    output wire               i2s_sck,
    output reg                i2s_ws,
    output reg                i2s_sd
);

  // Offset-binary: 0x8000 is silence.
  wire [15:0] usample = {~sample[15], sample[14:0]};

  // ------------------------------------------- second-order sigma-delta
  // Error-feedback form with clamped integrators.  The clamps are what
  // keep a second-order 1-bit modulator from running away on loud input;
  // without them the loop can latch into a limit cycle.
  localparam signed [20:0] SD_LIM = 21'sd262143;

  reg signed [20:0] i1, i2;

  wire signed [20:0] x  = {5'b00000, usample} - 21'sd32768;   // centre
  wire signed [20:0] fb = pdm_o ? 21'sd32768 : -21'sd32768;

  wire signed [21:0] i1_n = i1 + (x - fb);
  wire signed [21:0] i2_n = i2 + (i1 - fb);

  // The bounds are written as signed literals on purpose: concatenating
  // SD_LIM into a wider vector would make it unsigned and turn both
  // comparisons unsigned, which clamps every negative value to +full
  // scale and wedges the modulator's output high.
  function signed [20:0] clamp21(input signed [21:0] v);
    clamp21 = (v >  22'sd262143) ?  SD_LIM :
              (v < -22'sd262143) ? -SD_LIM : v[20:0];
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      i1    <= 21'sd0;
      i2    <= 21'sd0;
      pdm_o <= 1'b0;
    end else begin
      i1    <= clamp21(i1_n);
      i2    <= clamp21(i2_n);
      pdm_o <= ~i2[20];          // sign of the second integrator
    end
  end

  // ------------------------------------------------------------------- I2S
  // The filter produces a sample every 8 phi2 periods, so a whole number
  // of filter samples falls in each I2S frame: four in the direct-sck
  // case, eight when sck is divided.  They are summed and shifted down,
  // which both decimates and puts a null right at the frame rate --
  // without it, content between the frame rate and the 123 kHz filter
  // rate would alias into the I2S band.
  localparam [2:0] DEC_LAST  = (SCK_DIV2 != 0) ? 3'd7 : 3'd3;
  localparam       DEC_SHIFT = (SCK_DIV2 != 0) ? 3 : 2;

  reg signed [18:0] dec_acc;
  reg        [15:0] dec_out;
  reg        [2:0]  dec_cnt;

  wire signed [18:0] sample_x = {{3{sample[15]}}, sample};

  always @(posedge clk) begin
    if (!rst_n) begin
      dec_acc <= 19'sd0;
      dec_out <= 16'd0;
      dec_cnt <= 3'd0;
    end else if (frame_tick) begin
      if (dec_cnt == DEC_LAST) begin
        // Mean of DEC_LAST+1 samples, converted to offset binary.
        dec_out <= {~dec_acc[DEC_SHIFT+15], dec_acc[DEC_SHIFT+14:DEC_SHIFT]};
        dec_acc <= sample_x;
        dec_cnt <= 3'd0;
      end else begin
        dec_acc <= dec_acc + sample_x;
        dec_cnt <= dec_cnt + 3'd1;
      end
    end
  end

  // One shift per bit clock, MSB first, with the one-bit delay after the
  // word-select edge that I2S requires.  Data changes on the falling edge
  // of sck so it is stable for the receiver's rising edge.
  reg [4:0] bit_cnt;
  reg [15:0] shifter;

  wire advance;                       // high for the cycle before sck falls

  generate
    if (SCK_DIV2 != 0) begin : g_div2
      reg sck_r;
      always @(posedge clk) begin
        if (!rst_n) sck_r <= 1'b0;
        else        sck_r <= ~sck_r;
      end
      assign i2s_sck = sck_r;
      assign advance = sck_r;         // sck_r is 1 now, so it falls next edge
    end else begin : g_direct
      assign i2s_sck = clk;
      assign advance = 1'b1;          // every negative edge of clk is a fall
    end
  endgenerate

  // In the divided case the shifter runs on the positive edge, gated by
  // `advance`; in the direct case sck falls with clk, so it runs on the
  // negative edge.  Either way the update coincides with sck falling.
  generate
    if (SCK_DIV2 != 0) begin : g_shift_pos
      always @(posedge clk) begin
        if (!rst_n) begin
          bit_cnt <= 5'd0;
          shifter <= 16'd0;
          i2s_ws  <= 1'b0;
          i2s_sd  <= 1'b0;
        end else if (advance) begin
          bit_cnt <= bit_cnt + 5'd1;
          if (bit_cnt == 5'd15) i2s_ws <= ~i2s_ws;
          shifter <= (bit_cnt == 5'd15) ? dec_out : {shifter[14:0], 1'b0};
          i2s_sd  <= shifter[15];
        end
      end
    end else begin : g_shift_neg
      always @(negedge clk) begin
        if (!rst_n) begin
          bit_cnt <= 5'd0;
          shifter <= 16'd0;
          i2s_ws  <= 1'b0;
          i2s_sd  <= 1'b0;
        end else begin
          bit_cnt <= bit_cnt + 5'd1;
          if (bit_cnt == 5'd15) i2s_ws <= ~i2s_ws;
          shifter <= (bit_cnt == 5'd15) ? dec_out : {shifter[14:0], 1'b0};
          i2s_sd  <= shifter[15];
        end
      end
    end
  endgenerate

endmodule
