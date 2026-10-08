# SID 6581 / 8580 Replica — status report and operator's guide

Project: `~/project/SID_tinytapeout`
Target: Tiny Tapeout **SKY26d** shuttle (sky130A), tile size **4x2**
Date: 2026-10-08

---

## 1. Status

The design is complete, verified, and **hardens cleanly to GDS locally** with
zero DRC, zero LVS errors and no timing violations. It is ready to push to
GitHub, which is what triggers the official shuttle flow.

| Gate | Result |
|---|---|
| RTL simulation (cocotb 2.1.0, 20 cases) | **20/20 pass** |
| Gate-level simulation on the hardened netlist | **13/13 pass**, 7 skipped by design |
| Verilator lint (what `RUN_LINTER` runs) | **clean**, no output |
| `info.yaml` against Tiny Tapeout's own schema | **valid** |
| Yosys `check -assert` | **0 problems, 0 latches** |
| Local harden (OpenLane 2.0.11 + sky130A) | **Flow complete** |
| Magic DRC | **0 errors** |
| Netgen LVS | **0 errors, 0 device differences** |
| Detailed routing DRC | **0 errors** (converged after 6 iterations) |
| Setup timing | **+296.06 ns** worst slack, TNS 0 |
| Hold timing | **+0.110 ns** worst slack, TNS 0 |

Signoff numbers for the committed configuration:

| Metric | Value |
|---|---|
| Standard cell area | 83,982 µm² |
| Core utilisation | 56.3 % |
| Cell count | 12,203 |
| Die (4x2 tile) | 682.64 × 225.76 µm |
| Wirelength | 226,700 µm |
| Total power | 153 µW |
| GDS size | 24 MB |

### Tile size: 4x2 at density 75

The design does **not** place at the template's default
`PL_TARGET_DENSITY_PCT` of 60 — global placement fails with `GPL-0302`.
The committed `src/config.json` therefore sets **75**, which places and
routes cleanly. This matters: without it CI would fail exactly as the first
local attempt did.

A 6x2 run was tried as a fallback and is *worse* on nearly every measure —
13,317 cells, 240,901 µm of wire, 6 antenna-violating nets, slightly higher
power — for twice the tiles. 4x2 at density 75 is the better build.

### Residual warnings, and why they are acceptable

- **32–37 max-slew violations** in the slow corner (`nom_ss_100C_1v60`),
  worst 1.058 ns against a 0.750 ns limit, on high-fanout buffer inputs.
  These are electrical-quality advisories, not functional failures, and the
  design has **+296 ns** of setup slack — three orders of magnitude of
  margin. The fast and typical corners are clean.
- **53 max-fanout advisories** — same character.
- **1 antenna-violating net** (a high-fanout buffered net). Tiny Tapeout's
  precheck does not gate on antenna reports.
- **7 Verilator `-Wall` warnings** — `DECLFILENAME` (which the Tiny Tapeout
  template itself triggers) and unused-bit notes on genuinely unused bits:
  reserved config bits, truncated product LSBs, and the sync source's
  accumulator where only the MSB is read. Verilator's *default* lint, which
  is what the flow actually gates on, is silent.

---

## 2. What the design is

A digital replica of the MOS 6581/8580 SID, built as a **drop-in
replacement**: `clk` is φ2 and the whole design runs from it at the
original rate — 985,248 Hz on a PAL C64, 1,022,727 Hz on NTSC. There is no
second oscillator, PLL or clock division anywhere, so an adapter board
needs no crystal.

- Three voices: 24-bit phase accumulators, saw/triangle/pulse/noise
  (23-bit LFSR, taps 22 and 17, clocked from accumulator bit 19), ring
  modulation, oscillator sync, TEST.
- Three ADSR envelopes using the hardware rate-period table and the 5-bit
  exponential decay/release divider.
- The chip's two-integrator multimode filter as a digital state variable
  filter at φ2/8 = 123.156 kHz, with an 8-segment piecewise-linear model of
  the 6581 cutoff curve and the 8580 linear law on register 1F bit 0.
- Audio out as second-order sigma-delta (~59 dB) on `uo[0]`, plus I2S on
  `uo[1..3]`.

Full pinout, register map and the external-component discussion are in
[`docs/info.md`](docs/info.md).

---

## 3. Running simulations

Everything goes through `scripts/sim.sh`, which creates and uses a
virtualenv at `.venv` holding the **exact cocotb the shuttle pins**
(`cocotb==2.1.0`) — deliberately not the system/conda cocotb, which is
1.9.2 and uses the old `MODULE` convention.

```bash
cd ~/project/SID_tinytapeout

./scripts/sim.sh                              # whole suite (RTL)
./scripts/sim.sh --list                       # list the 20 test cases
./scripts/sim.sh test_lowpass_attenuates      # one case
./scripts/sim.sh --wave                       # run, then open gtkwave
./scripts/sim.sh --wave test_oscillator_sync  # one case, then gtkwave
./scripts/sim.sh --div2                       # build with -DSID_I2S_SCK_DIV2
./scripts/sim.sh --record 3000                # render 3 s to test/sid_demo.wav
./scripts/sim.sh --gl submission              # gate-level, against the netlist
```

Plain `make` in `test/` also works if `.venv/bin` is on PATH.

### Interacting with waveforms

The testbench writes **`test/tb.fst`** (FST, not VCD — far smaller and what
the shuttle template uses). `gtkwave` is installed at `/usr/bin/gtkwave`.

```bash
gtkwave test/tb.fst
```

Signals worth adding, by hierarchical path:

| Path | What it shows |
|---|---|
| `tb.clk` | φ2 itself |
| `tb.ui_in`, `tb.uio_in`, `tb.uio_out`, `tb.uio_oe` | the host bus; watch `uio_oe` go to `ff` only during reads |
| `tb.uo_out` | bit 0 sigma-delta audio, bits 1–3 I2S, bit 4 sample strobe |
| `tb.user_project.u_core.u_audio.audio_o` | **the 16-bit mixer output** — the signal to look at |
| `tb.user_project.u_core.u_audio.st` | the 8-cycle audio frame counter |
| `tb.user_project.u_core.u_audio.f_low` / `f_band` / `f_high` | filter state variables |
| `tb.user_project.u_core.u_v0.acc` | voice 1 phase accumulator |
| `tb.user_project.u_core.u_v0.wave_o` | voice 1 waveform output |
| `tb.user_project.u_core.u_e0.env_o` | voice 1 envelope |
| `tb.user_project.u_core.u_audio.w0_smooth` | smoothed filter coefficient |

For `audio_o`, `f_low`, `wave_o` and the accumulators, right-click the
trace and choose **Data Format → Analog → Step** (and **Signed Decimal**
for the signed ones) — they then render as waveforms rather than hex, which
is what you want for audio.

A useful starting view: `clk`, `st`, `u_v0.wave_o` (analog), `u_e0.env_o`,
`audio_o` (analog signed), `uo_out[0]`. Save it with **File → Write Save
File** so it reloads next time.

### Listening to it

```bash
./scripts/sim.sh --record 3000
# writes test/sid_demo.wav at 123.156 kHz (the filter rate)
```

The renderer drives the tile over the φ2 bus exactly as a C64 would —
every note is register writes — so what you hear is the design, not a
model of it. A Goertzel check on the output confirms the fundamental lands
on D5 at 587.33 Hz, i.e. pitches come out at the real SID's frequencies.

---

## 4. Viewing the hardened design

```bash
source scripts/eda_env.sh        # puts the toolchain on PATH, prints versions
```

### OpenROAD GUI — the placed-and-routed database

```bash
./scripts/view_layout.sh submission openroad
```

This is the one to use for P&R results: every layer, every net, timing
paths, congestion and power-density heatmaps. Needs a display.

Once open, useful things:
- **Heat Maps** in the Display Control panel → Placement Density, Routing
  Congestion, Power Density.
- **Timing → Report Timing** for path-by-path slack.
- The **Inspector** on a selected net shows its full route.
- Every step directory under `asic/work/submission/runs/wokwi/` has its own
  `.odb`, so you can open any earlier stage of the flow the same way:
  `openroad -gui` then `read_db <path>.odb`.

### KLayout — the GDS as the foundry sees it, plus 2.5D

```bash
./scripts/view_layout.sh submission klayout
```

Then **Tools → 2.5d View** for a rotatable, extruded view of the layer
stack. This is the quickest route to a real 3D look at the tile.

### Magic — interactive DRC and device probing

```bash
./scripts/view_layout.sh submission magic
```

### 3D model (glTF)

```bash
./scripts/gds_to_gltf.sh submission
# or: ./scripts/view_layout.sh submission gltf
```

Writes `asic/viewer/tt_um_sid6581.gltf` — already generated, **127 MB**.
Each sky130 layer becomes an extruded solid at its true height in the
stack, so this is the actual metal and via geometry. Open it in Blender,
the VS Code glTF extension, or any browser glTF viewer. It is large; expect
a pause while it loads.

### Tiny Tapeout's own 3D web viewer

This renders the GDS directly and wants a publicly reachable URL:

```
https://gds-viewer.tinytapeout.com/?process=SKY130&model=<url to the .gds>
```

Pushing to GitHub gets this for free — the `gds` workflow's `viewer` job
publishes the GDS to GitHub Pages and links the viewer at it. That is the
easiest way to get the rotatable 3D tile view you asked about.

---

## 5. Toolchain: do you need to install anything to match CI?

**Short answer: you do not need to install OpenROAD, and you do not need
root for the tools. Root buys exactly one thing — Docker group membership —
and that is only needed if you want to reproduce CI bit-for-bit.**

Here is the actual picture, read out of the shuttle's own action:

- CI does `pip install librelane==3.0.14` and then runs
  `python -m librelane --docker-no-tty --dockerized ...`.
- So **CI runs LibreLane inside Docker**. The pinned OpenROAD, Yosys, Magic
  and Netgen versions live in that container image — they are not installed
  on the runner.
- `pip install librelane==3.0.14` works here already (verified, no root). It
  brings `klayout` and `ciel` as wheels but **no** OpenROAD/Yosys/Magic
  binaries; it expects either Docker or a Nix environment to supply them.

What this machine has instead: OpenLane **2.0.11** with natively installed
OpenROAD 2.0-12381, Yosys 0.41, Magic 8.3.465, Netgen, Verilator 5.052 and
the sky130A PDK at `/home/van496/pdk`. That is what produced the clean
harden above. It is LibreLane's direct ancestor and the same flow, but not
the same build.

### What that means practically

The local harden is strong evidence, not a bit-exact preview. It proves
synthesis works, the design fits the tile, placement and routing converge,
DRC and LVS are clean and timing closes with vast margin. Version
differences between OpenROAD builds could in principle shift cell choices
or routing slightly, but not by enough to change any of those conclusions.

**If you want exact parity,** the cheapest path is Docker, and that is the
one place root helps:

```bash
sudo usermod -aG docker $USER     # then log out and back in
```

Docker is already installed (26.1.4) and the daemon is running — the
current failure is purely socket permissions, not a missing service. After
that:

```bash
python3 -m venv ~/ll3 && ~/ll3/bin/pip install librelane==3.0.14
cd ~/project/SID_tinytapeout
~/ll3/bin/python -m librelane --dockerized --pdk-root /home/van496/pdk \
    --run-tag wokwi --force-run-dir runs/wokwi src/config_merged.json
```

(`scripts/harden_local.sh` already generates `config_merged.json`; run it
once with `--to OpenROAD.STAPrePNR` if you just want the merged config.)

Note the LibreLane image is several GB and this filesystem is at 98 %
(~49 GB free) — enough, but worth watching.

**My recommendation:** don't install anything. Push to GitHub and let the
shuttle's own pipeline be the authority — it is free, it is the actual
acceptance gate, and it runs precheck and gate-level tests that no local
setup reproduces. Keep the local flow for fast iteration, which is what it
is good at. Add Docker only if CI throws something you cannot reproduce
locally.

---

## 6. Next steps for submission

1. **Create a public GitHub repo and push.** The repo must be public for
   the shuttle to read it.

   ```bash
   cd ~/project/SID_tinytapeout
   gh auth login
   gh repo create SID_tinytapeout --public --source=. --remote=origin --push
   ```

2. **Enable GitHub Pages** for the repo (Settings → Pages → Source: GitHub
   Actions). The `viewer` job needs it to publish the GDS and the 3D
   viewer link.

3. **Watch the workflows.** Four jobs run on push:

   ```bash
   gh run watch
   ```

   | Job | What it does |
   |---|---|
   | `gds` | hardens with LibreLane 3.0.14 in Docker |
   | `precheck` | the official Tiny Tapeout precheck |
   | `gl_test` | runs this suite against the hardened netlist |
   | `viewer` | publishes the GDS and the 3D viewer link to Pages |

   All four should pass. `test` runs separately and should be 20/20.

4. **Fill in your Discord handle** in `info.yaml` if you want the Tapeout
   role assigned automatically — it is currently empty, which is allowed.

5. **Submit the repo URL** at <https://tinytapeout.com> under your own
   account. This reserves and pays for the tiles; it needs your login and I
   cannot do it for you. The SKY26d shuttle was open with **44 days
   remaining** as of 2026-10-08.

6. **Check the tile count** when submitting — this is a **4x2** project, so
   it consumes 8 tiles, not 1.

### Before you push, consider

- `info.yaml` has `discord: ""`. Optional, but fill it if you use Discord.
- The licence is **CERN-OHL-S-2.0** (strongly reciprocal), chosen because
  the two reference implementations consulted for hardware constants —
  reDIP-SID and icesid — are under it. The RTL here was written from the
  datasheet rather than copied, so you could argue for a permissive
  licence, but that is your call to make deliberately.
- `asic/` and `.venv/` are gitignored, so the harden artefacts and the
  127 MB glTF do not go up.

---

## 7. Known limitations, stated plainly

- **POT X / POT Y** cannot work. They are analog RC-timing pins on the real
  chip. The registers are present and readable; a host loads them through
  the 1D/1E extension (unconnected on the original).
- **EXT IN** works but is a 1-bit sigma-delta input, not an analog summing
  node — nine levels per filter sample. Good enough to feed another source
  through the SID filter.
- **No analog character.** The 6581's non-linear wave DAC, filter input
  distortion and DC offset come from its +12 V analog section. This design
  is architecturally and timing-faithful but arithmetically clean, so it
  sounds closer to a well-behaved 8580 than a gritty 6581.
- **I2S bandwidth is 15.4 kHz** (φ2/32 frames). That is a consequence of
  having only a ~1 MHz clock. The sigma-delta output has full bandwidth at
  ~59 dB.
- **Filter Q is capped.** At φ2/8 the two-integrator loop needs
  `w0 < 2 − 1/Q`; maximum cutoff gives `w0 = 0.603`, so `1/Q` is limited to
  1.2 rather than Butterworth's 1.414. Q = 0.83 is within a decibel of
  Butterworth. Without this cap the filter oscillates at RES=0 with the
  cutoff wide open — there is a test that sweeps the corners.
- **The filter capacitors are gone and must not be fitted.** The 470 pF /
  22 nF parts on pins 1–4 of a real chip have no equivalent. You *do* need
  an RC reconstruction filter on `uo[0]`; see `docs/info.md`.
- `/CS` **must be φ2-qualified**, as it is on a C64. A microcontroller
  driving this tile must assert `/CS` only for the duration of an access.

---

## 8. Repository layout

```
src/            RTL: project.v (top), sid_core, sid_voice, sid_envelope,
                sid_audio, sid_dac, sid_fc_curve, sid_q_table
                config.json  — OpenLane config (note PL_TARGET_DENSITY_PCT 75)
test/           cocotb suite, bus driver (sid.py), WAV renderer (record.py)
docs/info.md    datasheet-style documentation, published by the docs workflow
scripts/        harden_local.sh, view_layout.sh, gds_to_gltf.sh, sim.sh,
                eda_env.sh
asic/           gitignored: harden work dirs, logs, glTF viewer output
info.yaml       Tiny Tapeout project metadata
```
