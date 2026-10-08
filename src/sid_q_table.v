/*
 * sid_q_table.v -- resonance register to 1/Q coefficient
 *
 * SPDX-FileCopyrightText: 2026 Jason van Aardt
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 *
 * 1/Q in Q1.12 fixed point (4096 = 1.0).  RES=0 gives a well damped
 * filter, RES=15 the sharp peak the chip is known for.
 */

`default_nettype none

module sid_q_table (
    input  wire [3:0]  res,
    output reg  [12:0] q_inv
);

  always @(*) begin
    case (res)
      4'h0: q_inv = 13'd5793;   // 1.414
      4'h1: q_inv = 13'd5225;
      4'h2: q_inv = 13'd4710;
      4'h3: q_inv = 13'd4245;
      4'h4: q_inv = 13'd3826;
      4'h5: q_inv = 13'd3449;
      4'h6: q_inv = 13'd3109;
      4'h7: q_inv = 13'd2802;
      4'h8: q_inv = 13'd2526;
      4'h9: q_inv = 13'd2277;
      4'ha: q_inv = 13'd2053;
      4'hb: q_inv = 13'd1851;
      4'hc: q_inv = 13'd1668;
      4'hd: q_inv = 13'd1504;
      4'he: q_inv = 13'd1356;
      4'hf: q_inv = 13'd1222;   // 0.298
    endcase
  end

endmodule
