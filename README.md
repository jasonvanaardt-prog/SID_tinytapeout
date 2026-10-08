# SID 6581 / 8580 Replica -- Tiny Tapeout

A digital replica of the MOS Technology 6581/8580 SID, the Commodore 64
sound chip, as a Tiny Tapeout tile.

The host interface is the original chip's: an 8-bit bidirectional data
bus, five address lines, `/CS`, `R//W`, `phi2` and `/RES`, with the same
cycle timing and the same 29-register map. Software written for a real SID
drives this tile unchanged.

- `src/` -- the RTL
- `test/` -- cocotb test suite driving the phi2 bus
- `docs/info.md` -- full documentation, pinout, register map and the
  external-component discussion
- `info.yaml` -- Tiny Tapeout project metadata

## What is implemented

| Block | Status |
|---|---|
| 3 x 24-bit phase accumulator oscillator | yes |
| Sawtooth, triangle, pulse, noise (23-bit LFSR) | yes |
| Combined waveforms (wire-AND) | approximated |
| Ring modulation, oscillator sync, TEST bit | yes |
| 3 x ADSR envelope with the hardware rate table | yes |
| Exponential decay/release divider | yes |
| Multimode filter (LP / BP / HP, simultaneous) | yes, digital SVF |
| 6581 non-linear cutoff curve | 8-segment piecewise-linear |
| 8580 linear cutoff curve | yes (register 1F bit 0) |
| Per-voice filter routing, 3 OFF, master volume | yes |
| OSC3 / ENV3 read-back | yes |
| POT X / POT Y | register-level only (no analog pin) |
| EXT IN | not available (no analog pin) |
| 6581 analog non-linearities and distortion | not modelled |

## Pinout

| 6581 pin | Signal | Tiny Tapeout |
|---|---|---|
| 15-22 | D0..D7 | `uio[0..7]` |
| 9-13 | A0..A4 | `ui[0..4]` |
| 8 | `/CS` | `ui[5]` |
| 7 | `R//W` | `ui[6]` |
| 6 | `phi2` | `ui[7]` |
| 5 | `/RES` | `rst_n` |
| 27 | AUDIO OUT | `uo[0]` (sigma-delta; `uo[1]` PWM, `uo[2..4]` I2S) |
| 1-4 | CAP1A/B, CAP2A/B | not needed, the filter is digital |
| 23, 24, 26 | POT Y, POT X, EXT IN | no analog pins available |

`clk` is the tile's system clock and must run at least ~16x `phi2`; the
audio pipeline time-shares one multiplier over 15 cycles per `phi2`
period. The design point is 50 MHz `clk` with a 1 MHz `phi2`.

## External components

The two filter capacitors a real SID needs (470 pF on a 6581, 22 nF on an
8580, across pins 1-4) are **not** required -- the filter is arithmetic
here, so there is nothing for them to integrate.

You do need a passive reconstruction filter on `uo[0]`, because it carries
a 1-bit sigma-delta bitstream rather than an analog signal:

```
uo[0] ──[ 1k ]──┬──[ 1k ]──┬──[ 10uF ]──> line out
                │          │
             [10nF]     [10nF]
                │          │
               GND        GND
```

Or skip the analog work entirely and feed `uo[2..4]` into an I2S DAC.
See `docs/info.md` for the full discussion.

## Running the tests

```bash
cd test && make
```

Needs `iverilog` and `cocotb`. The 16 cases drive the phi2 bus the way a
6502 would and check the bus protocol, the oscillators and their sync and
ring-modulation chain, the ADSR envelope through all its phases, the
filter responses, voice routing, master volume and the I2S stream.

To hear it, render a short demo to a WAV file:

```bash
cd test && make record          # or DURATION_MS=500 make record
```

That plays a four-note figure with a filter sweep by writing registers
over the phi2 bus, then captures the mixer output to `test/sid_demo.wav`.
It takes a few minutes -- the simulation runs the full 1 MHz phi2 clock.

## Licence

CERN-OHL-S-2.0. The hardware constants were cross-checked against
[reDIP-SID](https://github.com/daglem/reDIP-SID) and
[icesid](https://github.com/bit-hack/icesid), which are under the same
licence; see `docs/info.md` for credits.
