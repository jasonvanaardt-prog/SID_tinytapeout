# Hardware targets: reDIP-SID FPGA, codec-free audio, and the ASIC pinout

Answers three questions, with the evidence behind each:

1. Can the current top level run on the reDIP-SID board's FPGA?
2. Can it run without the external codec — audio on a pin, filtered by an RC?
3. Can the ASIC top level be as close to the real SID as possible, with no
   supporting hardware beyond level shifters?

Evidence comes from `submodules/reDIP-SID/gateware/redip_sid.pcf`,
`gateware/sid_io.sv`, `gateware/Makefile`,
`hardware/documentation/reDIP-SID-sch.pdf`, and a trial `synth_ice40` run
of this project's RTL.

---

## 1. Running the current top level on reDIP-SID — yes

### It fits, with room to spare

`yosys synth_ice40 -top tt_um_sid6581 -dsp` against the iCE40UP5K:

| Resource | Used | Available | Share |
|---|---|---|---|
| SB_LUT4 | 2,009 | 5,280 | **38 %** |
| Flip-flops | 925 | 5,280 | 18 % |
| SB_MAC16 (DSP) | 4 | 8 | 50 % |
| SB_CARRY | 762 | — | — |

Both multipliers inferred into DSP blocks. Critically, the **262 negative-edge
flip-flops map natively** (`SB_DFFN`, `SB_DFFNESR`, `SB_DFFNSR`, `SB_DFFNSS`) —
the iCE40 logic tile has a per-tile clock-polarity bit, so the negedge register
file and I2S shifter are not a problem. Yosys reports 0 problems.

That leaves over half the fabric for the board's own support logic if we reuse
any of it.

### Every signal it needs is on a pin

From `redip_sid.pcf`:

| My top-level port | Board signal | FPGA pin |
|---|---|---|
| `clk` (φ2) | `phi2` | 44 |
| `rst_n` (/RES) | `res_n` | 21 |
| `ui_in[6]` (R/W̄) | `r_w_n` | 36 |
| `ui_in[5]` (/CS) | `cs_n` | **28** |
| `ui_in[4:0]` (A0–A4) | `a0..a4` | 27, 26, 34, 31, 32 |
| `uio[7:0]` (D0–D7) | `d0..d7` | 45, 46, 47, 3, 2, 4, 43, 48 |

`/CS` exists as a real pin, so the bus maps straight across. Spare,
level-shifted I/O also exists: `cs_io1_n` (41), `a5` (42), `a8` (38), brought
out on header J2 — the schematic marks these "do NOT connect to SID socket!",
i.e. they are free for our use.

**Bonus the ASIC cannot have:** `pot_x` (39) and `pot_y` (40) are real FPGA pins
wired to the socket's POT pins. On the FPGA, paddles can genuinely work.
`gateware/sid_pot.sv` plus the pad handling in `sid_io.sv` already does it, and
the technique is worth knowing: the pin is shared between an `SB_RGBA_DRV`
instance — used not for an LED but as a **2 mA current-limited sink** for the
discharge phase, because the 6581 datasheet specifies a minimum 500 µA POT sink
current — and an `SB_IO` instance that reads the pin back while
`pot_o.discharge` is low. (There is no RGB LED on this board; the single LED is
on pin 6, shared with I2C SCL.)

### The one real design decision: how to clock it

This is where my design and the board disagree, and it is worth being explicit.

**reDIP-SID deliberately does not clock from φ2.** It runs from the 24 MHz
oscillator through a PLL (`ice40_init.sv`, `SB_PLL40_2F_CORE`) and treats φ2 as
an oversampled *data* input (`sid_io.sv`: `phi2_x <= phi2_io; phi2 <= phi2_x;`).
The reason is quoted in `sid_io.sv`:

> The 6510 phi2 clock driver only weakly drives the clock line high. This makes
> the clock signal susceptible to noise at the rising edge, which could in
> theory cause a false detection of the falling edge. Tests show that the
> iCE40UP5K has input hysteresis of approximately 250mV, which should hopefully
> be sufficient to remedy this issue. In an attempt to further aid in the
> avoidance of any glitches, we configure the I/O with a 100k pullup.

Our design, by contrast, *is* clocked from φ2 — that was the point of the
drop-in rework. Two options:

**Option A — clock from φ2 (recommended).** This is the configuration that
actually validates the ASIC, because it exercises the same single-clock
architecture, the same negedge write capture and the same φ2-qualified `/CS`
assumption that the silicon will use.

- Configure the φ2 input `SB_IO` with `PULLUP(1'b1)`, copying `io_phi2` in
  `sid_io.sv`.
- Pin 44 may not be a global-buffer input. nextpnr-ice40 normally promotes a
  high-fanout clock to a global network automatically; if it does not,
  instantiate `SB_GB` explicitly. At ~1 MHz, timing closure is trivial either
  way — the concern is skew across 925 flops, not speed.
- **Risk to watch:** a noisy or slow φ2 edge could double-clock the whole
  design. On the bench with a clean 1 MHz generator this is a non-issue. In a
  real C64 it is the thing most likely to bite. If it does, add a Schmitt
  buffer (74LVC1G17) between the socket and the FPGA, or fall back to Option B.

**Option B — board-native.** Keep `sys_clk`/PLL and re-introduce an oversampled
φ2 bus front end. This is the architecture the project had *before* the drop-in
rework, so it would test something the ASIC no longer does. Only worth it if
Option A proves unreliable in a real machine.

### Work required

1. `fpga/redip_sid_tt.sv` — a wrapper instantiating `tt_um_sid6581`, with
   `SB_IO` tristate primitives for D0–D7 (copy the pattern from `sid_io.sv`) and
   plain inputs for the rest. Map `uio_oe[0]` to the bus `OUTPUT_ENABLE`.
2. `fpga/redip_sid_tt.pcf` — derived from `redip_sid.pcf`, keeping only the pins
   we use.
3. Audio routing — see section 2.
4. Optional: instantiate `sid_pot.sv` alongside and feed the results into
   registers 1D/1E through the existing extension, giving working paddles.

### Toolchain gap

`yosys` is installed; **`nextpnr-ice40`, `icepack` and `dfu-util` are not.**
The board's flow is:

```
yosys -p 'synth_ice40 -abc9 -device u -dff -top ... -json ...'
nextpnr-ice40 --up5k --package sg48 --freq 24 --json ... --pcf ... --asc ...
icepack ... .bin
dfu-util -d 1d50:6159,:6156 -a 0 -D redip_sid.bin -R
```

The missing pieces come from the OSS CAD Suite tarball — a user-space unpack,
**no root needed**.

---

## 2. Running without the codec — possible, but it needs one wire on this board

### What the codec is actually doing

From the schematic, the SGTL5000 (U6) sits in the middle of both analog paths:

- **AUDIO OUT (socket pin 27)** is driven by opamp U8 (MCP6D01) from the codec's
  `HP_L`/`HP_R`. **No FPGA pin reaches AUDIO OUT.**
- **EXT IN (pin 26) and EXT_IN_R** go to the codec's `LINEIN_L`/`LINEIN_R` — the
  codec is also the ADC for the SID's analog external input. It reaches the
  FPGA only as I2S: `sid_api.sv` takes `ext_in` from `audio_i`, which comes
  from `i2s_dsp_mode`.
- `LINEOUT_L/R` go to `AOUT_L`/`AOUT_R` on J2 through 10 µF caps.

The FPGA talks to it over I2S (pins 10–13) and configures it over I2C (pins 6, 9).
`AUDIO_OUT`, `EXT_IN`, `EXT_IN_R`, `AOUT_L` and `AOUT_R` exist in the schematic
only as analog nets on the codec — none has an `ICE_` counterpart and none
appears in the PCF.

**So dropping the codec costs EXT IN as well as AUDIO OUT.** That is consistent
with our ASIC, where EXT IN is already a 1-bit input rather than an analog
summing node, but it does mean the FPGA build loses the better of the two.

### Consequence

On reDIP-SID as built, **a PDM-pin-plus-RC path requires a hardware
modification.** There is no trace from any FPGA pin to AUDIO OUT.

**No RTL change is needed, though** — `uo_out[0]` is already a second-order
sigma-delta output designed for precisely this, and `docs/info.md` already
specifies the RC network. This is purely a routing question.

### Minimum modification

1. Pick a spare level-shifted pin on J2: `cs_io1_n` (41), `a5` (42) or `a8` (38).
   These are only used when the gateware is built for a second SID at D420 /
   D500 / DE00; in the default `SID2=0` build they are ignored entirely, so
   they are genuinely free. (The `spi_*` pins are also declared but never
   connected to anything inside `redip_sid.sv` — however they are wired to the
   flash and PSRAM chips, so they are a worse choice than the J2 pins.)
2. Assign the PDM output to it in the PCF.
3. From that J2 pin, an RC to the AUDIO OUT net:

```
J2 pin ──[ 1k ]──┬──[ 1k ]──┬──[ 10uF ]──> AUDIO OUT (socket pin 27)
                 │          │
              [10nF]     [10nF]
                 │          │
                GND        GND
```

4. **Stop U8 driving the same net** — lift its output pin or leave it
   unpopulated — or the opamp and the RC will fight.

### Two caveats worth stating plainly

- **Quality goes down, not up.** The SGTL5000 is a ~95 dB codec. Our
  sigma-delta at the φ2 rate is ~59 dB, because a 1-bit stream at 985 kHz only
  oversamples a 20 kHz band by about 25. On a board that already has the codec
  fitted, the PDM route is a downgrade.
- **Drive impedance.** The RC above presents roughly 2 kΩ. A C64's audio input
  wants to see less. Lowering R is limited by pad drive current — at 3.3 V, 1 kΩ
  already draws 3.3 mA peak — so getting below ~1 kΩ per section means adding a
  unity-gain buffer, which is the supporting hardware we were trying to avoid.

### Recommendation

- **On reDIP-SID: keep the codec.** It is already there and it is better. Reuse
  `i2s_dsp_mode.sv` + `sgtl5000_init.v` and feed them `sid_core`'s 16-bit
  `audio_o` directly. That means instantiating **`sid_core` rather than
  `tt_um_sid6581`** in the FPGA wrapper.

  This is not merely a convenience — **our I2S output cannot drive this codec
  at all.** On reDIP-SID the SGTL5000 is the I2S *master*: in
  `i2s_dsp_mode.sv`, `pad_lrclk` and `pad_sclk` are configured as registered
  *inputs* (`PIN_TYPE 6'b0000_00`) and only `i2s_din` is an output
  (`6'b0110_00`). Our `sid_dac` generates `sck` and `ws` as a master at
  φ2/32 ≈ 30.8 kHz, whereas the codec supplies them at 6.144 MHz for 96 kHz
  DSP mode. Two masters on one clock line is a direct conflict. Feeding
  `audio_o` into their I2S slave block side-steps this entirely.
- **Codec-free PDM + RC is the right answer for the ASIC and for any new
  minimal board** — which is exactly what the ASIC already does.

---

## 3. The ASIC top level versus the real SID — it is already 1:1

Every *digital* pin of the 6581 is already reproduced exactly. Nothing is
missing that could be added, because what is left is inherently analog.

| 6581 pin | Signal | Status in the tile |
|---|---|---|
| 1–4 | CAP1A/B, CAP2A/B | **Not needed** — filter is digital. Must not be fitted. |
| 5 | /RES | `rst_n` ✅ |
| 6 | φ2 | `clk` ✅ |
| 7 | R/W̄ | `ui_in[6]` ✅ |
| 8 | /CS | `ui_in[5]` ✅ |
| 9–13 | A0–A4 | `ui_in[4:0]` ✅ |
| 14 | GND | ✅ |
| 15–22 | D0–D7 | `uio[7:0]`, true bidirectional ✅ |
| 23, 24 | POT Y, POT X | ❌ needs two bidirectional pins; all 8 `uio` are the data bus |
| 25 | VCC +5 V | supply |
| 26 | EXT IN | `ui_in[7]`, 1-bit sigma-delta rather than analog |
| 27 | AUDIO OUT | `uo_out[0]`, sigma-delta + RC |
| 28 | VDD +12 V | not needed |

### One assumption worth re-examining: the φ2-qualified `/CS`

Our ASIC drives the data bus on `~cs_n & rw` alone, relying on the C64's PLA
having already gated `/CS` with φ2. reDIP-SID does the same job belt-and-braces
(`sid_io.sv`):

```systemverilog
oe_io <= phi2_io & phi2 & bus_i.r_w_n & ~cs.cs_n;
```

— raw φ2 **and** synchronised φ2 **and** read **and** `/CS`, with the comment
that the extra φ2 term is "to avoid any output glitches". They can do that
because φ2 is a data input to them. We cannot, because φ2 is our clock and the
tile has no spare input to bring it in a second time.

In a real C64 this is fine: `/CS` is PLA-generated from φ2 and the address
decode, so it is already qualified. The exposure is a non-C64 host — a
microcontroller test rig, say — that asserts `/CS` outside a φ2 window. That is
already documented in `docs/info.md` as an interface requirement, and it is the
right trade for a drop-in part, but it is worth knowing that the FPGA reference
design chose to be stricter.

Note also their read/write asymmetry, which matches ours: reads are qualified on
φ2 **high**, writes are captured on φ2 **low** (they use a φ1-enabled input
latch; we use a negative-edge flop).

### Minimum external bill of materials

**Required:**

1. **Level shifters.** Bidirectional on D0–D7; 5 V → 3.3 V on A0–A4, /CS, R/W̄,
   φ2 and /RES. A CBT-style bus switch is what reDIP-SID uses
   (SN74CBT16211) and is the cheapest route.
2. **RC reconstruction network** on AUDIO OUT — two 1 kΩ, two 10 nF, one 10 µF.

**Strongly recommended, and this is new information from reading the board:**

3. **A Schmitt-trigger buffer on φ2** (one 74LVC1G17). The 6510 only weakly
   drives φ2 high, and the ASIC is clocked directly from it. reDIP-SID gets away
   with no buffer because the iCE40 has ~250 mV of input hysteresis and it
   oversamples rather than clocking from φ2; we have neither of those
   protections. This is one gate, and it is cheap insurance against
   double-clocking 900-odd flip-flops.

**Optional:**

4. **A unity-gain buffer** on audio if driving a C64's audio input directly
   rather than a high-impedance amplifier input.
5. **POT X/Y**: one small-signal transistor each. A `uo_out` pin drives the gate
   to discharge the paddle capacitor, and a `ui_in` pin senses the recharge
   through the tile's own input threshold. This costs one output pin and one
   input pin per paddle. `ui_in[7]` could be freed by giving up EXT IN, which
   would buy one paddle; a second would need another input, and there is none
   spare.

### Why POT X/Y cannot be done pin-only

Tiny Tapeout provides exactly eight bidirectional pins and the data bus needs
all eight. The paddle measurement needs a pin that can both drive low and go
high-impedance, and `uo_out` cannot tri-state. Time-multiplexing a paddle onto a
data-bus pin is not possible either — they are physically different nets on the
C64. Hence the transistor, or nothing.

---

## Suggested order of work

1. **Install the FPGA toolchain** (OSS CAD Suite, user-space): `nextpnr-ice40`,
   `icepack`, `dfu-util`.
2. **Write `fpga/redip_sid_tt.sv` + `.pcf`**, clocking from φ2 (Option A), with
   audio going to the codec via `sid_core.audio_o` and the board's existing I2S
   and codec-init blocks.
3. **Build and program**, then test in a real C64. The thing to watch is φ2 edge
   quality; if the design misbehaves, scope φ2 at the socket before suspecting
   the RTL.
4. **Optionally add `sid_pot.sv`** for working paddles on the FPGA build.
5. **Only if a codec-free path is actually wanted**, do the J2 bodge in
   section 2 — but on this board the codec is the better audio.
6. **Feed anything learned back into the ASIC docs** — particularly the φ2
   buffering question, which affects the adapter design.
