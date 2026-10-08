## How it works

This is a digital replica of the MOS Technology 6581/8580 SID, the sound
chip from the Commodore 64, built as a Tiny Tapeout tile.

The whole signal chain of the original is reproduced in RTL:

- **Three voices.** Each has a 24-bit phase accumulator advanced once per
  phi2 period by its 16-bit frequency register, feeding sawtooth,
  triangle, variable-width pulse and noise generators. The noise source is
  the original's 23-bit LFSR with taps at bits 22 and 17, clocked from
  accumulator bit 19. Ring modulation, oscillator sync and the TEST bit
  all behave as they do on the chip, including the 1 -> 3 -> 2 -> 1
  wrap-around of the sync/ring source chain. Selecting more than one
  waveform wire-ANDs them together, which is how the original's waveform
  DAC produces its combined waveforms.
- **Three ADSR envelope generators.** The 8-bit envelope counter is driven
  by a 15-bit rate prescaler using the hardware's actual period table (9,
  32, 63, ... 31251 phi2 cycles), and decay/release additionally pass
  through the chip's 5-bit "exponential" divider, which stretches the
  slope at six envelope breakpoints (0xFF, 0x5D, 0x36, 0x1A, 0x0E, 0x06).
  That divider is what gives the SID its recognisable envelope shape.
- **The multimode filter.** The original is a two-integrator loop, so
  low-pass, band-pass and high-pass are available simultaneously and can
  be summed. The same topology is implemented here as a digital state
  variable filter running at the phi2 rate:

      low  = low  + w0 * band
      high = in   - low - (1/Q) * band
      band = band + w0 * high

  The cutoff coefficient is derived from the 11-bit FC register through a
  piecewise-linear model of the 6581's famously non-linear cutoff curve
  (shallow below the knee near FC=1024, then a steep climb to about
  12 kHz). Register 1F bit 0 switches to the 8580's linear law instead.
- **Mixer and master volume**, with per-voice filter routing and the
  "3 OFF" bit, which -- as on the real chip -- only silences voice 3 while
  voice 3 is *not* routed through the filter.

One 18x13 signed multiplier is time-shared by a sequencer across
all seven multiplies needed per sample (three voice amplitudes, three
filter taps, one volume), which keeps the design small enough to fit the
tile. The sequence takes 15 cycles, which is why `clk` must be at least
about 16x phi2.

### Pinout

The host-facing interface is pin-for-pin the original chip's: the full
8-bit bidirectional data bus, five address lines, /CS, R//W, phi2 and
/RES, with the same cycle timing (writes latch on the falling edge of
phi2; the data bus is driven only while /CS is low, R//W is high and phi2
is high).

| 6581 pin | Signal | Tiny Tapeout |
|---|---|---|
| 15-22 | D0..D7 | `uio[0..7]` |
| 9-13 | A0..A4 | `ui[0..4]` |
| 8 | /CS | `ui[5]` |
| 7 | R//W | `ui[6]` |
| 6 | phi2 | `ui[7]` |
| 5 | /RES | `rst_n` |
| 27 | AUDIO OUT | `uo[0]` (sigma-delta) |
| 23, 24 | POT Y, POT X | no analog pin -- see below |
| 26 | EXT IN | no analog pin -- see below |
| 1-4 | CAP1A/B, CAP2A/B | **not needed** -- see below |
| 25, 28 | Vcc +5V, Vdd +12V | tile runs at 1.8V core / 3.3V I/O |

### Register map

Identical to the original. Registers 00-18 are write-only, 19-1C are
read-only.

| Addr | Register |
|---|---|
| 00/01, 07/08, 0E/0F | Voice 1/2/3 FREQ lo/hi |
| 02/03, 09/0A, 10/11 | Voice 1/2/3 PW lo/hi (12-bit) |
| 04, 0B, 12 | Voice 1/2/3 CONTROL: NOISE, PULSE, SAW, TRI, TEST, RING, SYNC, GATE |
| 05, 0C, 13 | Voice 1/2/3 ATTACK/DECAY |
| 06, 0D, 14 | Voice 1/2/3 SUSTAIN/RELEASE |
| 15/16 | FC lo (3 bits) / hi (8 bits) |
| 17 | RES (7:4), FILT EX, FILT3, FILT2, FILT1 |
| 18 | 3 OFF, HP, BP, LP, VOL (3:0) |
| 19 | POT X (read) |
| 1A | POT Y (read) |
| 1B | OSC3 / RANDOM (read) |
| 1C | ENV3 (read) |

Three addresses that are unconnected on the original are used as
extensions, so nothing that targets a real SID is affected:

| Addr | Extension |
|---|---|
| 1D | writes the value that register 19 (POT X) reads back |
| 1E | writes the value that register 1A (POT Y) reads back |
| 1F | bit 0: 0 = 6581 cutoff curve (default), 1 = 8580 |

## Do you still need external analog components?

Short answer: **the two filter capacitors are gone, but you do still need
a small passive output network.** They are different things, and it is
worth being precise about which.

### The filter capacitors are no longer required

On a real 6581, pins 1-4 (CAP1A/CAP1B, CAP2A/CAP2B) bring the two
integrating capacitors of the analog filter off-chip -- 470 pF on a 6581,
22 nF on an 8580. Those capacitors *are* the filter's integrators; the
on-chip part is a pair of transconductance amplifiers whose bias current
sets the cutoff.

In this replica the filter is arithmetic: two integrators built from
registers and an adder, with cutoff set by a coefficient rather than a
bias current. There is nothing for a capacitor to integrate. **Pins 1-4
and their capacitors do not exist in this design and must not be
fitted.** This is also why the cutoff frequency here is immune to the
part-to-part capacitor and process spread that makes two real 6581s sound
noticeably different.

### You do need a reconstruction filter on AUDIO OUT

A Tiny Tapeout tile has only digital I/O, so `uo[0]` is not an analog
output. It is a 1-bit sigma-delta (PDM) bitstream at the `clk` rate, and a
passive low-pass is needed to turn it back into audio. This is a DAC
smoothing network, not a replacement for the SID's filter -- the musical
filtering has already happened digitally upstream.

A two-pole RC is enough for line level:

```
uo[0] ──[ 1k ]──┬──[ 1k ]──┬──[ 10uF ]──> line out
                │          │
             [10nF]     [10nF]
                │          │
               GND        GND
```

That gives a corner near 16 kHz, which passes the audio band and pushes
the remaining 50 MHz-rate quantisation noise far enough down to be
inaudible. The 10 uF in series removes the ~1.65 V DC offset of the
3.3 V output. Add a buffer or op-amp stage if you are driving anything
low-impedance.

If you would rather not use sigma-delta, `uo[1]` is an 8-bit PWM output
(carrier at `clk`/256, so about 195 kHz at 50 MHz) that works with the
same RC network but has less dynamic range. For a clean path with no
analog work at all, `uo[2..4]` is a standard I2S stream you can feed
straight into an external DAC -- that is the recommended option if audio
quality matters.

### Three things genuinely cannot be reproduced on a digital tile

- **POT X and POT Y (pins 23, 24).** On the original these are analog
  pins: the chip discharges an external capacitor, releases it, and times
  how long a paddle potentiometer takes to charge it. That needs an analog
  comparator and a current path a digital tile does not have. The POT
  registers are still present and readable; a host loads them through the
  1D/1E extension, so software that polls paddles still works.
- **EXT IN (pin 26).** An analog audio input summed into the filter. With
  all 24 digital I/O already committed to the bus and the audio outputs
  there is no pin left for it, and it could only ever be a 1-bit digital
  input anyway. The FILT EX bit (register 17 bit 3) is decoded but its
  input is tied to zero. Mix external audio in after the output filter
  instead.
- **The 6581's analog character.** The original runs its analog section
  from +12 V, and a good part of what people recognise as "the 6581 sound"
  comes from imperfections there: the non-linear wave DAC, the input
  distortion of the filter, the leakage that makes voice mixing slightly
  non-linear, and the DC offset that makes the famous "digi" playback
  trick audible. This design reproduces the chip's *architecture and
  timing* faithfully but is arithmetically clean, so it sounds closer to a
  well-behaved 8580 than to a gritty 6581 even with the 6581 cutoff curve
  selected. Modelling those non-linearities would mean adding shaping
  tables, and those cost area that this tile does not have.

### Driving it from real hardware

The tile's I/O is 3.3 V. A Commodore 64 bus is 5 V, so level shifting is
required in both directions on D0-D7 and in the host-to-tile direction on
the address and control lines. For bench use, the Tiny Tapeout demo board
RP2040 can drive phi2, the address and control lines and the data bus
directly.

## How to test

With the Tiny Tapeout demo board, or any microcontroller wired to the
pins above:

1. Hold `/RES` (`rst_n`) low briefly, then release it.
2. Drive phi2 as a square wave at 1 MHz; `clk` must be running at least
   16x faster (50 MHz is the design point).
3. Write `0x0F` to register 18 to set master volume to maximum.
4. Write `0x00` to 05 and `0xF0` to 06 (instant attack and decay, full
   sustain).
5. Write `0x25` to 00 and `0x11` to 01 to set voice 1 to about 440 Hz.
6. Write `0x21` to 04 to select the sawtooth and raise GATE.

Audio should appear on `uo[0]` through the RC network. Writing `0x20` to
04 drops GATE and the voice releases. To hear the filter, write `0x01` to
17 to route voice 1 into it, `0x10` to 18 for low-pass, and sweep the
cutoff by writing 15/16.

The repository's `test/` directory has a cocotb suite that drives the phi2
bus and checks the oscillators, envelopes, filter and bus protocol; run it
with `make` in that directory.

## External hardware

- Two 1 kOhm resistors, two 10 nF capacitors and one 10 uF capacitor for
  the output reconstruction filter on `uo[0]`, or
- any I2S DAC module on `uo[2..4]` instead.
- A microcontroller or level-shifted 6502-family bus to drive phi2, the
  address/control lines and the data bus.
- **No filter capacitors.** The 470 pF / 22 nF parts a real 6581 or 8580
  needs on pins 1-4 have no equivalent here.

## Credits

Written from the 6581 datasheet and the published reverse-engineering of
the chip. The hardware constants (envelope rate periods, exponential
breakpoints, LFSR taps and output bits, filter topology) were cross-checked
against two existing open implementations, both of which are worth reading:

- [reDIP-SID](https://github.com/daglem/reDIP-SID) by Dag Lem, also the
  author of reSID
- [icesid](https://github.com/bit-hack/icesid) by Aidan Dodds

Both are CERN-OHL-S-2.0, and this project carries the same licence.
