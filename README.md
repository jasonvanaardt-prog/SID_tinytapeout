# SID 6581 / 8580 Replica -- Tiny Tapeout

A digital replica of the MOS Technology 6581/8580 SID, the Commodore 64
sound chip, as a Tiny Tapeout tile -- built as a drop-in replacement.

**One clock, and it is phi2.** The host's phi2 is the tile's `clk`, so the
whole design runs at the original SID rate (985248 Hz PAL, 1022727 Hz
NTSC) with no second oscillator, PLL or clock division anywhere. Pitches
and envelope times therefore come out at exactly the real chip's
frequencies, and PAL/NTSC is tracked automatically. An adapter board needs
no crystal.

The rest of the interface is the original's too: an 8-bit bidirectional
data bus, five address lines, `/CS`, `R//W` and `/RES`, the same 29-register
map, and writes latched on the falling edge of phi2. Software written for
a real SID drives this tile unchanged.

- `src/` -- the RTL
- `test/` -- cocotb test suite driving the phi2 bus
- `docs/info.md` -- full documentation, pinout, register map and the
  external-component discussion
- `info.yaml`, `src/config.json` -- Tiny Tapeout and OpenLane configuration

## What is implemented

| Block | Status |
|---|---|
| 3 x 24-bit phase accumulator oscillator | yes, advanced every phi2 period |
| Sawtooth, triangle, pulse, noise (23-bit LFSR) | yes |
| Combined waveforms (wire-AND) | approximated |
| Ring modulation, oscillator sync, TEST bit | yes |
| 3 x ADSR envelope with the hardware rate table | yes |
| Exponential decay/release divider | yes |
| Multimode filter (LP / BP / HP, simultaneous) | yes, digital SVF at phi2/8 |
| 6581 non-linear cutoff curve | 8-segment piecewise-linear |
| 8580 linear cutoff curve | yes (register 1F bit 0) |
| Per-voice filter routing, 3 OFF, master volume | yes |
| OSC3 / ENV3 read-back | yes |
| EXT IN | yes, as a 1-bit sigma-delta input |
| POT X / POT Y | register-level only (no analog pin) |
| 6581 analog non-linearities and distortion | not modelled |

## Pinout

| 6581 pin | Signal | Tiny Tapeout |
|---|---|---|
| 15-22 | D0..D7 | `uio[0..7]` |
| 9-13 | A0..A4 | `ui[0..4]` |
| 8 | `/CS` | `ui[5]` (must be phi2-qualified) |
| 7 | `R//W` | `ui[6]` |
| 6 | `phi2` | `clk` |
| 5 | `/RES` | `rst_n` |
| 26 | EXT IN | `ui[7]` (1-bit stream) |
| 27 | AUDIO OUT | `uo[0]` sigma-delta; `uo[1..3]` I2S |
| 1-4 | CAP1A/B, CAP2A/B | not needed, the filter is digital |
| 23, 24 | POT Y, POT X | no analog pins available |

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

At the phi2 clock rate that output is good for about 59 dB in the audio
band, which is in the same territory as a real 6581 in a C64. For better
than that, feed `uo[1..3]` into an I2S DAC at phi2/32 (30.8 kHz).
`docs/info.md` has the full discussion, including why there is no PWM
output.

### Build options

| Define | Effect |
|---|---|
| *(none)* | I2S `sck` is phi2 directly: 30.8 kHz frames, 15.4 kHz bandwidth |
| `SID_I2S_SCK_DIV2` | `sck` is a registered divide-by-two, so no clock reaches an output pin; 15.4 kHz frames, 7.7 kHz bandwidth |

Add it to `VERILOG_DEFINES` in `src/config.json` to change the hardened
build. The sigma-delta output on `uo[0]` is unaffected either way.

## Implementation notes

Running from phi2 alone means one clock cycle per phi2 period, so the
audio arithmetic is an 8-cycle frame driving two small multipliers: one
doing voice amplitudes (round robin, two samples per voice per frame,
averaged for cheap anti-aliasing) and one doing the filter and master
volume. Oscillators and envelopes update every phi2 period; the filter and
mixer produce a sample every eighth, at 123.156 kHz on PAL.

With a 1015 ns clock period there is no timing pressure anywhere in the
design. `scripts/harden_local.sh` reproduces the CI hardening flow
locally; see the area and timing figures it reports.

## Running the tests

```bash
cd test && make
```

Needs `iverilog` and the pinned `cocotb` from `test/requirements.txt`. The
20 cases drive the phi2 bus the way a 6502 would and check the bus
protocol and single-cycle writes, all four waveforms, sync and ring
modulation, TEST, the ADSR through every phase *and* against the
hardware's attack timing, filter responses, filter stability across the
cutoff and resonance ranges, EXT IN routing, voice routing, master volume
and the decoded I2S stream.

`GATES=yes make` runs the same suite against the hardened netlist, which
is what the shuttle's `gl_test` job does. Thirteen of the cases work
purely through the pins and run there unchanged; the seven that reach into
the mixer and filter state are skipped, because a flat netlist has no such
hierarchy.

To hear it, render a demo to a WAV file:

```bash
cd test && make record          # or DURATION_MS=3000 make record
```

That plays a four-note figure with a filter sweep by writing registers
over the phi2 bus, then captures the mixer output to `test/sid_demo.wav`
at the 123.156 kHz filter rate.

## Licence

CERN-OHL-S-2.0. The hardware constants were cross-checked against
[reDIP-SID](https://github.com/daglem/reDIP-SID) and
[icesid](https://github.com/bit-hack/icesid), which are under the same
licence; see `docs/info.md` for credits.
