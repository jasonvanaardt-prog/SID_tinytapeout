/*
 * sid_dac.v -- digital audio output stages
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * The original 6581 drives AUDIO OUT from an on-chip analog output
 * amplifier.  A digital tile has no such pin, so the sample stream is
 * offered three ways.
 *
 * Running from phi2 alone costs real output resolution and it is worth
 * being honest about the arithmetic.  A 1-bit output at 985 kHz gives an
 * oversampling ratio of only about 25 for a 20 kHz audio band, where the
 * 50 MHz clock this design previously assumed gave 1250.  A first-order
 * modulator at that ratio would manage about 37 dB, which is not good
 * enough, so the modulator here is second order: roughly
 *
 *     1.76 - 12.9 + 50*log10(25)  ~=  59 dB
 *
 * in the audio band, which is comparable to what a real 6581 achieves in
 * a C64 once its own noise and hum are counted.  If you want better than
 * that, take the I2S output into an external DAC.
 *
 * PWM is not offered any more: at phi2 rates an 8-bit carrier would land
 * near 3.8 kHz, right in the middle of the audio band.
 */

`default_nettype none

module sid_dac (
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
  localparam signed [20:0] SD_LIM =  21'sd262143;

  reg signed [20:0] i1, i2;

  wire signed [20:0] x  = {{5{1'b0}}, usample} - 21'sd32768;   // centre
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
  // sck = clk, 32 bits per frame (two 16-bit channel slots carrying the
  // same sample), so the frame rate is phi2/32 -- 30.8 kHz on PAL.
  //
  // The filter produces a sample every 8 phi2 cycles, so exactly four
  // filter samples fall in each I2S frame.  They are summed and shifted
  // down by two, which both decimates 4:1 and puts a null right at the
  // frame rate -- without it, content between 15 kHz and the 123 kHz
  // filter rate would alias into the I2S band.
  reg signed [17:0] dec_acc;
  reg        [15:0] dec_out;
  reg        [1:0]  dec_cnt;

  always @(posedge clk) begin
    if (!rst_n) begin
      dec_acc <= 18'sd0;
      dec_out <= 16'd0;
      dec_cnt <= 2'd0;
    end else if (frame_tick) begin
      if (dec_cnt == 2'd3) begin
        dec_out <= {~dec_acc[17], dec_acc[16:2]};  // average, to offset binary
        dec_acc <= {{2{sample[15]}}, sample};
        dec_cnt <= 2'd0;
      end else begin
        dec_acc <= dec_acc + {{2{sample[15]}}, sample};
        dec_cnt <= dec_cnt + 2'd1;
      end
    end
  end

  // sck is phi2 itself, so one bit clock per phi2 period and 32 bits per
  // frame gives phi2/32 -- 30.8 kHz on PAL, with the 15.4 kHz audio
  // bandwidth that implies.  Taking sck from clk/2 instead would halve
  // that, which is why the shifter runs on the negative edge: data
  // changes on the falling edge of sck and is stable for the receiver's
  // rising edge, as I2S requires.
  reg [4:0]  bit_cnt;
  reg [15:0] shifter;

  always @(negedge clk) begin
    if (!rst_n) begin
      bit_cnt <= 5'd0;
      shifter <= 16'd0;
      i2s_ws  <= 1'b0;
      i2s_sd  <= 1'b0;
    end else begin
      bit_cnt <= bit_cnt + 5'd1;

      // I2S is delayed by one bit clock from the word-select edge.
      if (bit_cnt == 5'd15) i2s_ws <= ~i2s_ws;

      if (bit_cnt == 5'd15)
        shifter <= dec_out;             // reload at each channel boundary
      else
        shifter <= {shifter[14:0], 1'b0};

      i2s_sd <= shifter[15];
    end
  end

  assign i2s_sck = clk;

endmodule
