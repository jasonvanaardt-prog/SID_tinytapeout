/*
 * sid_dac.v -- digital audio output stages
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * The original 6581 drives AUDIO OUT from an on-chip analog output
 * amplifier.  A digital ASIC tile has no such pin, so the 16-bit sample
 * stream is offered three ways:
 *
 *   1. First-order sigma-delta (PDM) on the main AUDIO OUT pin.  One RC
 *      network recovers the audio.  This is the primary output: the
 *      quantisation noise is pushed well above the audio band, so at a
 *      50 MHz clk the in-band SNR is far better than PWM can manage.
 *   2. 8-bit PWM, as a fallback for anyone who would rather use a simple
 *      low-pass and does not need the dynamic range.
 *   3. I2S (philips standard, 16-bit, stereo frame with both channels
 *      carrying the same sample) for a lossless digital path to an
 *      external DAC.
 */

`default_nettype none

module sid_dac (
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] sample,

    output reg                pdm_o,
    output reg                pwm_o,
    output reg                i2s_sck,
    output reg                i2s_ws,
    output reg                i2s_sd
);

  // Offset-binary: 0x8000 is silence.
  wire [15:0] usample = {~sample[15], sample[14:0]};

  // ----------------------------------------------- first-order sigma-delta
  reg [16:0] sd_acc;
  always @(posedge clk) begin
    if (!rst_n) begin
      sd_acc <= 17'h08000;
      pdm_o  <= 1'b0;
    end else begin
      sd_acc <= {1'b0, sd_acc[15:0]} + {1'b0, usample};
      pdm_o  <= sd_acc[16];
    end
  end

  // -------------------------------------------------------------- 8-bit PWM
  reg [7:0] pwm_cnt;
  always @(posedge clk) begin
    if (!rst_n) begin
      pwm_cnt <= 8'd0;
      pwm_o   <= 1'b0;
    end else begin
      pwm_cnt <= pwm_cnt + 8'd1;
      pwm_o   <= (pwm_cnt < usample[15:8]);
    end
  end

  // ------------------------------------------------------------------- I2S
  // clk/4 bit clock, 32 bits per channel slot.
  reg [1:0]  sck_div;
  reg [5:0]  bit_cnt;
  reg [15:0] shifter;

  always @(posedge clk) begin
    if (!rst_n) begin
      sck_div <= 2'd0;
      bit_cnt <= 6'd0;
      shifter <= 16'd0;
      i2s_sck <= 1'b0;
      i2s_ws  <= 1'b0;
      i2s_sd  <= 1'b0;
    end else begin
      sck_div <= sck_div + 2'd1;

      if (sck_div == 2'd0) begin
        i2s_sck <= 1'b0;                  // falling edge: shift data out
        bit_cnt <= bit_cnt + 6'd1;

        // I2S is delayed by one bit clock from the word-select edge.
        if (bit_cnt == 6'd63)       i2s_ws <= 1'b0;
        else if (bit_cnt == 6'd31)  i2s_ws <= 1'b1;

        if (bit_cnt == 6'd63 || bit_cnt == 6'd31)
          shifter <= usample;             // reload at each channel boundary
        else
          shifter <= {shifter[14:0], 1'b0};

        i2s_sd <= shifter[15];
      end else if (sck_div == 2'd2) begin
        i2s_sck <= 1'b1;                  // rising edge: receiver samples
      end
    end
  end

endmodule
