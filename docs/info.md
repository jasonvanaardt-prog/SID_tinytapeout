## How it works

This is a digital replica of the MOS Technology 6581/8580 SID, the sound
chip from the Commodore 64, built as a Tiny Tapeout tile and intended as a
drop-in replacement for the real part.

**It has one clock, and that clock is phi2.** The host's phi2 is the
tile's `clk`, so the whole design runs at the original SID rate --
985248 Hz on a PAL C64, 1022727 Hz on NTSC -- and there is no second
oscillator, no PLL and no clock division anywhere in the signal path.
Every pitch, envelope time and filter sweep therefore comes out at exactly
the rate the real chip produces, and it tracks PAL or NTSC automatically
because it simply counts phi2 periods the way the original does.

The whole signal chain is reproduced in RTL:

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
  That divider is what gives the SID its recognisable envelope shape. The
  test suite checks the fastest attack takes the 2550 phi2 periods the
  hardware takes.
- **The multimode filter.** The original is a two-integrator loop, so
  low-pass, band-pass and high-pass are available simultaneously and can
  be summed. The same topology is implemented here as a digital state
  variable filter:

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

### How it fits in one clock cycle per phi2 period

Running from phi2 alone means there is exactly one clock cycle per phi2
period, so the audio arithmetic is organised as a repeating 8-cycle frame
driving two small multipliers concurrently:

- **mulv (13x8)** does one voice amplitude -- waveform times envelope --
  per cycle, round robin, twice per frame. The two products for a voice
  are averaged, which decimates to the frame rate *and* puts a null at
  phi2/4. That is cheap anti-aliasing for waveform harmonics that would
  otherwise fold down into the audio band.
- **mulf (18x14)** does the filter's two integrators and resonance tap,
  then the master volume.

So the oscillators and envelopes update every phi2 period, exactly like
the original, while the filter and mixer produce a sample every eighth
period: phi2/8, or 123.156 kHz on PAL. Note that a multiplier here has two
cycles of latency, because both the operands and the product are
registered, so the frame is laid out around products being readable two
cycles after they are issued.

That filter rate has one consequence worth stating. A two-integrator loop
is only stable while `w0 < 2 - 1/Q`, and at 123 kHz the maximum cutoff
gives `w0 = 0.603`. A Butterworth `1/Q` of 1.414 would put the bound at
0.586 -- the filter would oscillate at RES=0 with the cutoff wide open --
so `1/Q` is capped at 1.2, which moves the bound to 0.800. That is a third
of margin, and Q = 0.83 is within a decibel of Butterworth. There is a
test that sweeps the corners of the cutoff and resonance ranges and checks
the filter states stay well short of their clamps.

### Pinout

The host-facing interface is the original chip's, with phi2 as the clock:

| 6581 pin | Signal | Tiny Tapeout |
|---|---|---|
| 15-22 | D0..D7 | `uio[0..7]` |
| 9-13 | A0..A4 | `ui[0..4]` |
| 8 | /CS | `ui[5]` |
| 7 | R//W | `ui[6]` |
| 6 | phi2 | `clk` |
| 5 | /RES | `rst_n` |
| 26 | EXT IN | `ui[7]`, as a 1-bit stream |
| 27 | AUDIO OUT | `uo[0]`, sigma-delta |
| 23, 24 | POT Y, POT X | no analog pin -- see below |
| 1-4 | CAP1A/B, CAP2A/B | **not needed** -- see below |
| 25, 28 | Vcc +5V, Vdd +12V | tile runs at 1.8V core / 3.3V I/O |

Bus timing matches the original: a write is latched on the **falling edge
of phi2**, so the register file is clocked on the negative edge of `clk`,
and a write takes effect within a single phi2 period.

Reads need one thing spelled out. The data bus is driven whenever `/CS` is
low and `R//W` is high, with no phi2 qualification of its own, because
**`/CS` is expected to already be phi2-qualified** -- which it is on a
C64, where the PLA only asserts the SID's `/CS` during phi2 high for an
address in $D400-$D7FF. A microcontroller driving this tile must do the
same and assert `/CS` only for the duration of an access, or it will find
the tile driving the data bus outside the intended window.

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
output. It is a 1-bit sigma-delta bitstream at the phi2 rate, and a
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

That gives a corner near 16 kHz. The 10 uF in series removes the ~1.65 V
DC offset of the 3.3 V output. Add a buffer or op-amp stage if you are
driving anything low-impedance.

**Being clocked at phi2 costs real output resolution, and it is worth
being honest about the arithmetic.** A 1-bit output at 985 kHz gives an
oversampling ratio of only about 25 for a 20 kHz audio band. A
first-order modulator at that ratio would manage roughly 37 dB, which is
not good enough, so the modulator here is second order:

    1.76 - 12.9 + 50*log10(25)  ~=  59 dB

in the audio band, which is in the same territory as a real 6581 in a C64
once its own noise and hum are counted. There is no PWM output any more:
at phi2 rates an 8-bit PWM carrier would land near 3.8 kHz, right in the
middle of the audio band.

If you want better than 59 dB, take `uo[1..3]` as I2S into an external
DAC. `sck` is phi2 itself and a frame is 32 bits, so the frame rate is
phi2/32 -- 30.8 kHz, with the 15.4 kHz audio bandwidth that implies.
Exactly four filter samples fall in each I2S frame, and they are summed
and shifted down by two, which both decimates 4:1 and puts a null right at
the frame rate; without that, content between 15 kHz and the 123 kHz
filter rate would alias into the I2S band.

### What can and cannot be reproduced on a digital tile

- **EXT IN (pin 26) is available, but not as an analog input.** With phi2
  moved onto `clk`, `ui[7]` came free and now carries EXT IN as a 1-bit
  sigma-delta stream, summed into the filter when the FILT EX bit
  (register 17 bit 3) is set. The ones are counted over each 8-cycle
  frame, which gives nine levels per filter sample -- crude compared with
  the original's analog summing node, but genuinely functional, and good
  enough to feed another sound source through the SID filter.
- **POT X and POT Y (pins 23, 24) cannot.** On the original these are
  analog pins: the chip discharges an external capacitor, releases it, and
  times how long a paddle potentiometer takes to charge it. That needs an
  analog comparator and a current path a digital tile does not have. The
  POT registers are still present and readable; a host loads them through
  the 1D/1E extension, so software that polls paddles still works.
- **The 6581's analog character cannot.** The original runs its analog
  section from +12 V, and a good part of what people recognise as "the
  6581 sound" comes from imperfections there: the non-linear wave DAC, the
  input distortion of the filter, the leakage that makes voice mixing
  slightly non-linear, and the DC offset that makes the famous "digi"
  playback trick audible. This design reproduces the chip's *architecture
  and timing* faithfully but is arithmetically clean, so it sounds closer
  to a well-behaved 8580 than to a gritty 6581 even with the 6581 cutoff
  curve selected. Modelling those non-linearities would mean adding
  shaping tables, and those cost area.

### Fitting it in a SID socket

The tile's I/O is 3.3 V and a C64 bus is 5 V, so an adapter board needs
level shifting: bidirectional on D0-D7, and host-to-tile on the address
and control lines and on phi2. The socket supplies +5 V on pin 25 and
+12 V on pin 28, which is ample to derive the 3.3 V and 1.8 V rails the
tile needs; nothing in this design uses the +12 V rail itself.

Unlike SwinSID or ARMSID, the adapter needs **no crystal or oscillator**,
because phi2 from the socket is the only clock.

## How to test

With the Tiny Tapeout demo board, or any microcontroller wired to the
pins above:

1. Drive `clk` with a ~1 MHz square wave (phi2). Hold `rst_n` low for a
   few cycles, then release it.
2. Write `0x0F` to register 18 to set master volume to maximum.
3. Write `0x00` to 05 and `0xF0` to 06 (instant attack and decay, full
   sustain).
4. Write `0x25` to 00 and `0x11` to 01 to set voice 1 to about 440 Hz.
5. Write `0x21` to 04 to select the sawtooth and raise GATE.

Remember to assert `/CS` only for the single phi2 period of each access.

Audio should appear on `uo[0]` through the RC network. Writing `0x20` to
04 drops GATE and the voice releases. To hear the filter, write `0x01` to
17 to route voice 1 into it, `0x10` to 18 for low-pass, and sweep the
cutoff by writing 15/16.

The repository's `test/` directory has a cocotb suite that drives the phi2
bus and checks the bus protocol, the oscillators, the envelopes against
hardware timing, filter stability across the cutoff and resonance ranges,
and the I2S stream. Run it with `make` in that directory, or `make record`
to render a demo to a WAV file.

## External hardware

- Two 1 kOhm resistors, two 10 nF capacitors and one 10 uF capacitor for
  the output reconstruction filter on `uo[0]`, or any I2S DAC module on
  `uo[1..3]` instead.
- Level shifters between the 5 V host bus and the 3.3 V tile.
- A C64 phi2 clock, or a microcontroller generating ~1 MHz phi2 plus the
  address and control lines. **No crystal or oscillator is needed.**
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
