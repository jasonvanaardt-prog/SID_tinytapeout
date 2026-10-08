/*
 * sid_envelope.v -- MOS 6581/8580 SID ADSR envelope generator
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * 8-bit envelope counter driven by a 15-bit rate prescaler and, for the
 * decay and release phases, the chip's 5-bit "exponential" divider that
 * stretches the slope at six breakpoints.  Rate periods and breakpoints
 * are the values of the original hardware.
 */

`default_nettype none

module sid_envelope (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,       // one phi2 period

    input  wire       gate,       // control register bit 0
    input  wire [3:0] attack,
    input  wire [3:0] decay,
    input  wire [3:0] sustain,
    input  wire [3:0] release_,

    output reg  [7:0] env_o
);

  localparam ST_ATTACK  = 2'd0;
  localparam ST_DECSUS  = 2'd1;
  localparam ST_RELEASE = 2'd2;

  reg [1:0] state;

  // --------------------------------------------------- rate prescaler
  // Periods in phi2 cycles for rate values 0..15.
  reg [14:0] rate_period;
  reg [3:0]  rate_sel;

  always @(*) begin
    case (state)
      ST_ATTACK: rate_sel = attack;
      ST_DECSUS: rate_sel = decay;
      default:   rate_sel = release_;
    endcase
  end

  always @(*) begin
    case (rate_sel)
      4'h0: rate_period = 15'd9;
      4'h1: rate_period = 15'd32;
      4'h2: rate_period = 15'd63;
      4'h3: rate_period = 15'd95;
      4'h4: rate_period = 15'd149;
      4'h5: rate_period = 15'd220;
      4'h6: rate_period = 15'd267;
      4'h7: rate_period = 15'd313;
      4'h8: rate_period = 15'd392;
      4'h9: rate_period = 15'd977;
      4'ha: rate_period = 15'd1954;
      4'hb: rate_period = 15'd3126;
      4'hc: rate_period = 15'd3907;
      4'hd: rate_period = 15'd11719;
      4'he: rate_period = 15'd19531;
      4'hf: rate_period = 15'd31251;
    endcase
  end

  reg [14:0] rate_counter;
  wire       rate_hit = tick && (rate_counter >= rate_period);

  always @(posedge clk) begin
    if (!rst_n)
      rate_counter <= 15'd0;
    else if (tick)
      rate_counter <= rate_hit ? 15'd0 : (rate_counter + 15'd1);
  end

  // ----------------------------------------- exponential (decay/release)
  // The decay/release slope is divided down further at six envelope
  // breakpoints, which is what gives the SID its characteristic curve.
  // The divider is latched when a breakpoint is crossed and held until
  // the next one.
  reg [4:0] exp_period;

  always @(posedge clk) begin
    if (!rst_n)
      exp_period <= 5'd1;
    else begin
      case (env_o)
        8'hff: exp_period <= 5'd1;
        8'h5d: exp_period <= 5'd2;
        8'h36: exp_period <= 5'd4;
        8'h1a: exp_period <= 5'd8;
        8'h0e: exp_period <= 5'd16;
        8'h06: exp_period <= 5'd30;
        default: ;
      endcase
    end
  end

  reg [4:0] exp_counter;
  wire      exp_hit = rate_hit && (exp_counter + 5'd1 >= exp_period);

  always @(posedge clk) begin
    if (!rst_n)
      exp_counter <= 5'd0;
    else if (rate_hit)
      exp_counter <= exp_hit ? 5'd0 : (exp_counter + 5'd1);
  end

  // ------------------------------------------------------ state machine
  wire [7:0] sustain_level = {sustain, sustain};

  always @(posedge clk) begin
    if (!rst_n) begin
      env_o <= 8'h00;
      state <= ST_RELEASE;
    end else begin
      case (state)
        ST_ATTACK: begin
          if (!gate)
            state <= ST_RELEASE;
          else if (rate_hit) begin
            // Attack is linear: the exponential divider is bypassed.
            if (env_o == 8'hff)
              state <= ST_DECSUS;
            else
              env_o <= env_o + 8'd1;
          end
        end

        ST_DECSUS: begin
          if (!gate)
            state <= ST_RELEASE;
          else if (exp_hit) begin
            if (env_o != sustain_level && env_o != 8'h00)
              env_o <= env_o - 8'd1;
          end
        end

        default: begin // ST_RELEASE
          if (gate)
            state <= ST_ATTACK;
          else if (exp_hit) begin
            if (env_o != 8'h00)
              env_o <= env_o - 8'd1;
          end
        end
      endcase
    end
  end

endmodule
