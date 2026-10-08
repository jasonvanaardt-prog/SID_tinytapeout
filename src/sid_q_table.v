/*
 * sid_q_table.v -- resonance register to 1/Q coefficient
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * 1/Q in Q1.12 fixed point (4096 = 1.0), geometric from 1.2 at RES=0 to
 * 0.25 at RES=15.
 *
 * The top of the range is deliberately 1.2 rather than the 1.414 of a
 * Butterworth response.  A two-integrator loop is only stable while
 * w0 < 2 - 1/Q, and at the filter's phi2/8 sample rate the maximum
 * cutoff gives w0 = 0.603; 1/Q = 1.414 would leave a stability bound of
 * 0.586 and the filter would oscillate at RES=0 with the cutoff wide
 * open.  1.2 puts the bound at 0.800, a third of margin, and Q = 0.83
 * is within a decibel of Butterworth -- inaudible either way.
 */

`default_nettype none

module sid_q_table (
    input  wire [3:0]  res,
    output reg  [13:0] q_inv
);

  always @(*) begin
    case (res)
      4'h0: q_inv = 14'd4915;   // 1.200
      4'h1: q_inv = 14'd4427;
      4'h2: q_inv = 14'd3988;
      4'h3: q_inv = 14'd3592;
      4'h4: q_inv = 14'd3235;
      4'h5: q_inv = 14'd2914;
      4'h6: q_inv = 14'd2624;
      4'h7: q_inv = 14'd2364;
      4'h8: q_inv = 14'd2129;
      4'h9: q_inv = 14'd1918;
      4'ha: q_inv = 14'd1727;
      4'hb: q_inv = 14'd1556;
      4'hc: q_inv = 14'd1401;
      4'hd: q_inv = 14'd1262;
      4'he: q_inv = 14'd1137;
      4'hf: q_inv = 14'd1024;   // 0.250
    endcase
  end

endmodule
