/*
 * sid_fc_curve.v -- filter cutoff register to integrator coefficient
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * Maps the 11-bit FC register onto the state-variable filter coefficient
 *     w0 = 2*sin(pi*fc/fs) * 16384        (Q0.14)
 * where fs is the filter sample rate, phi2/8 -- 123.156 kHz on a PAL
 * machine.  Using 2*sin() rather than the small-angle approximation
 * keeps the cutoff on target at the top of the range, where phi2/8 is
 * only ten times the corner frequency.
 *
 * The 8580 cutoff law is linear in the register value.  The 6581's is
 * strongly non-linear -- a shallow region below the knee near FC=1024,
 * then a steep climb to about 12 kHz -- and that curve is what makes a
 * 6581 filter sweep sound the way it does.  It is approximated here with
 * eight linearly interpolated segments, which costs a small 14x8
 * multiplier instead of the 2048-entry lookup table a bit-exact model
 * would need.
 */

`default_nettype none

module sid_fc_curve (
    input  wire [10:0] fc,
    input  wire        is_6581,
    output wire [13:0] w0
);

  // Segment endpoints, Q0.14, for FC = 0, 256, 512, ... 2047
  // (approximately 220, 310, 450, 700, 1300, 3500, 6500, 9500, 12000 Hz)
  reg [13:0] base;
  reg [13:0] next;

  wire [2:0] seg  = fc[10:8];
  wire [7:0] frac = fc[7:0];

  always @(*) begin
    case (seg)
      3'd0: begin base = 14'd184;  next = 14'd259;  end
      3'd1: begin base = 14'd259;  next = 14'd376;  end
      3'd2: begin base = 14'd376;  next = 14'd585;  end
      3'd3: begin base = 14'd585;  next = 14'd1086; end
      3'd4: begin base = 14'd1086; next = 14'd2922; end
      3'd5: begin base = 14'd2922; next = 14'd5408; end
      3'd6: begin base = 14'd5408; next = 14'd7863; end
      3'd7: begin base = 14'd7863; next = 14'd9875; end
    endcase
  end

  wire [13:0] delta   = next - base;
  wire [21:0] interp  = delta * frac;          // 14x8 -> 22 bits
  wire [13:0] w0_6581 = base + interp[21:8];

  // 8580: fc ~= 12.5 kHz * FC/2047, which at this sample rate works out
  // at almost exactly 5.0 per register step.
  wire [13:0] w0_8580 = {fc, 2'b00} + {3'b000, fc};

  assign w0 = is_6581 ? w0_6581 : w0_8580;

endmodule
