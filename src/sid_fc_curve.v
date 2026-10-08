/*
 * sid_fc_curve.v -- filter cutoff register to integrator coefficient
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * Maps the 11-bit FC register onto the state-variable filter coefficient
 *     w0 = 2*sin(pi*fc/phi2) * 65536
 * i.e. Q0.16 fixed point at a 1 MHz sample rate.
 *
 * The 8580 cutoff law is linear in the register value.  The 6581's is
 * strongly non-linear -- a shallow region below the knee near FC=1024,
 * then a steep climb to about 12 kHz -- and that curve is what makes a
 * 6581 filter sweep sound the way it does.  It is approximated here with
 * eight linearly interpolated segments, which costs a small 10x8
 * multiplier instead of the 2048-entry lookup table a bit-exact model
 * would need.
 */

`default_nettype none

module sid_fc_curve (
    input  wire [10:0] fc,
    input  wire        is_6581,
    output wire [12:0] w0
);

  // Segment base values, Q0.16, for FC = 0, 256, 512, ... 1792
  // (approximately 220, 310, 450, 700, 1300, 3500, 6500, 9500 Hz)
  reg [12:0] base;
  reg [12:0] next;

  wire [2:0] seg  = fc[10:8];
  wire [7:0] frac = fc[7:0];

  always @(*) begin
    case (seg)
      3'd0: begin base = 13'd91;   next = 13'd128;  end
      3'd1: begin base = 13'd128;  next = 13'd185;  end
      3'd2: begin base = 13'd185;  next = 13'd288;  end
      3'd3: begin base = 13'd288;  next = 13'd535;  end
      3'd4: begin base = 13'd535;  next = 13'd1441; end
      3'd5: begin base = 13'd1441; next = 13'd2676; end
      3'd6: begin base = 13'd2676; next = 13'd3911; end
      3'd7: begin base = 13'd3911; next = 13'd4941; end
    endcase
  end

  wire [12:0] delta  = next - base;
  wire [20:0] interp = delta * frac;          // 13x8 -> 21 bits
  wire [12:0] w0_6581 = base + interp[20:8];

  // 8580: fc ~= 12.5 kHz * FC/2047, so w0 ~= 2.5 * FC
  wire [12:0] w0_8580 = {fc, 1'b0} + {2'b00, fc[10:1]};

  assign w0 = is_6581 ? w0_6581 : w0_8580;

endmodule
