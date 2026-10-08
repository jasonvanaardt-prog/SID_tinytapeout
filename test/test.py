"""
Functional tests for the tt_um_sid6581 Tiny Tapeout tile.

clk is phi2, driven here at the PAL C64 rate of 985248 Hz, so every
timing figure these tests assert is the figure the real chip produces.

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import sid
from sid import (CTRL, MODEVOL, RESFILT, OSC3, ENV3, POTX, POTY,
                 POTX_SET, POTY_SET, CFG, FCLO, FCHI,
                 NOISE, PULSE, SAW, TRI, TEST, SYNC, GATE,
                 FILTEX, FILT1, LP, HP, BP, VOICE3OFF,
                 PHI2_PAL, FRAME)

# One phi2 period in picoseconds, at the PAL rate.  Rounded to an even
# number of simulator steps, which is what cocotb's Clock requires when
# no explicit high time is given; the 0.9 ppm error is irrelevant.
PERIOD_PS = 2 * round(1e12 / PHI2_PAL / 2)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, PERIOD_PS, unit="ps").start())
    s = sid.Sid(dut)
    await s.reset()
    return s


@cocotb.test()
async def test_reset_state(dut):
    """After /RES the oscillators, envelopes and output are all cleared."""
    s = await start(dut)

    assert await s.read(OSC3) == 0x00, "OSC3 should be 0 after reset"
    assert await s.read(ENV3) == 0x00, "ENV3 should be 0 after reset"

    await s.idle(200)
    assert s.audio() == 0, "no voice is gated, so the output must be silent"


@cocotb.test()
async def test_write_only_registers_read_zero(dut):
    """Registers 00..18 are write-only on the real chip."""
    s = await start(dut)
    await s.write(CTRL[0], SAW | GATE)
    await s.write(MODEVOL, 0x0F)

    for addr in (0x00, 0x04, 0x15, 0x17, 0x18):
        assert await s.read(addr) == 0x00, f"{addr:#04x} must not read back"


@cocotb.test()
async def test_pot_registers(dut):
    """POT X/Y read back the values loaded through the 1D/1E extension."""
    s = await start(dut)

    assert await s.read(POTX) == 0x00
    assert await s.read(POTY) == 0x00

    await s.write(POTX_SET, 0x5A)
    await s.write(POTY_SET, 0xA5)

    assert await s.read(POTX) == 0x5A, "POTX should return the loaded value"
    assert await s.read(POTY) == 0xA5, "POTY should return the loaded value"


@cocotb.test()
async def test_single_cycle_write(dut):
    """A write must take effect from one phi2 period, as on the real chip."""
    s = await start(dut)
    await s.write(POTX_SET, 0x3C)
    # No idling in between: the very next cycle must already see it.
    assert await s.read(POTX) == 0x3C, "the write did not land in one period"


@cocotb.test()
async def test_sawtooth_ramps(dut):
    """OSC3 follows the top of voice 3's phase accumulator."""
    s = await start(dut)
    await s.set_freq(2, 0x1000)
    await s.write(CTRL[2], SAW)

    prev = await s.read(OSC3)
    rises = 0
    for _ in range(12):
        await s.idle(64)
        now = await s.read(OSC3)
        if now > prev or (prev > 0xE0 and now < 0x20):
            rises += 1
        prev = now

    assert rises >= 11, f"sawtooth should ramp monotonically, got {rises}/12"


@cocotb.test()
async def test_test_bit_holds_pulse_high(dut):
    """TEST zeroes the accumulator and forces the pulse output high."""
    s = await start(dut)
    await s.set_freq(2, 0xFFFF)          # accumulator wraps every 256 phi2
    await s.set_pw(2, 0x800)             # 50% duty
    await s.write(CTRL[2], PULSE | TEST)
    await s.idle(64)

    assert await s.read(OSC3) == 0xFF, "TEST must hold the pulse output high"

    await s.write(CTRL[2], PULSE)
    seen = set()
    for _ in range(32):
        await s.idle(23)
        seen.add(await s.read(OSC3))

    assert 0x00 in seen and 0xFF in seen, (
        f"a 50% pulse should swing between 0x00 and 0xFF, saw {sorted(seen)}")


@cocotb.test()
async def test_triangle_is_folded(dut):
    """The triangle output folds, so it never stays on a single ramp."""
    s = await start(dut)
    await s.set_freq(2, 0x4000)
    await s.write(CTRL[2], TRI)

    vals = []
    for _ in range(40):
        await s.idle(16)
        vals.append(await s.read(OSC3))

    assert max(vals) > 0xC0 and min(vals) < 0x40, (
        "triangle should cover most of the range")
    ups = sum(1 for a, b in zip(vals, vals[1:]) if b > a)
    downs = sum(1 for a, b in zip(vals, vals[1:]) if b < a)
    assert ups > 2 and downs > 2, f"triangle should rise and fall ({ups}/{downs})"


@cocotb.test()
async def test_noise_is_random(dut):
    """The 23-bit LFSR produces a spread of values, not a ramp."""
    s = await start(dut)
    await s.set_freq(2, 0xFFFF)
    await s.write(CTRL[2], NOISE)

    vals = []
    for _ in range(48):
        await s.idle(20)
        vals.append(await s.read(OSC3))

    assert len(set(vals)) > 20, f"noise should vary widely, got {len(set(vals))}"


@cocotb.test()
async def test_envelope_attack_decay_release(dut):
    """Gate drives the ADSR through attack, decay to sustain, then release."""
    s = await start(dut)
    await s.set_adsr(2, a=0, d=0, s=8, r=0)
    await s.write(CTRL[2], SAW | GATE)

    peak = 0
    for _ in range(60):
        await s.idle(100)
        peak = max(peak, await s.read(ENV3))
        if peak == 0xFF:
            break
    assert peak == 0xFF, f"attack should reach full scale, got {peak:#04x}"

    for _ in range(400):
        await s.idle(100)
        if await s.read(ENV3) <= 0x8A:
            break
    env = await s.read(ENV3)
    assert 0x86 <= env <= 0x8A, f"should settle at sustain 0x88, got {env:#04x}"

    await s.idle(3000)
    env = await s.read(ENV3)
    assert 0x86 <= env <= 0x8A, f"sustain should hold, got {env:#04x}"

    await s.write(CTRL[2], SAW)
    for _ in range(600):
        await s.idle(100)
        if await s.read(ENV3) == 0x00:
            break
    assert await s.read(ENV3) == 0x00, "release should reach zero"


@cocotb.test()
async def test_attack_timing_matches_hardware(dut):
    """The fastest attack takes 255 * 9 phi2 periods, as the hardware does."""
    s = await start(dut)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)

    await s.idle(2)
    await s.write(CTRL[0], SAW | GATE)

    cycles = 0
    while cycles < 6000:
        await s.idle(10)
        cycles += 10
        if s.dut.user_project.u_core.u_e0.env_o.value.to_unsigned() == 0xFF:
            break

    # 255 steps at 9+1 phi2 cycles per step is 2550; allow for the write
    # and the sampling granularity.
    assert 2300 <= cycles <= 2800, (
        f"attack took {cycles} phi2 periods, expected about 2550")


@cocotb.test()
async def test_audio_output_and_volume(dut):
    """A gated voice produces a moving output that scales with volume."""
    s = await start(dut)
    await s.write(MODEVOL, 0x0F)
    await s.set_freq(0, 0x4000)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)
    await s.idle(3000)

    loud = await s.collect(300)
    span_loud = max(loud) - min(loud)
    assert span_loud > 2000, f"expected a large swing, got {span_loud}"

    await s.write(MODEVOL, 0x00)
    await s.idle(100)
    quiet = await s.collect(100)
    assert all(v == 0 for v in quiet), "volume 0 must mute the output"


@cocotb.test()
async def test_pdm_output_toggles(dut):
    """The sigma-delta AUDIO OUT pin carries a varying duty cycle."""
    s = await start(dut)
    await s.write(MODEVOL, 0x0F)
    await s.set_freq(0, 0x1000)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)
    await s.idle(3000)

    ones = 0
    for _ in range(4000):
        await RisingEdge(dut.clk)
        ones += dut.uo_out.value.to_unsigned() & 1

    assert 200 < ones < 3800, f"PDM duty cycle looks stuck ({ones}/4000)"


@cocotb.test()
async def test_lowpass_attenuates(dut):
    """Routing a voice through a low cutoff low-pass reduces its level."""
    s = await start(dut)
    await s.write(MODEVOL, LP | 0x0F)
    await s.set_freq(0, 0x2000)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)
    await s.idle(3000)

    await s.write(RESFILT, 0x00)
    await s.idle(500)
    dry = await s.collect(250)
    span_dry = max(dry) - min(dry)

    await s.write(RESFILT, FILT1)
    await s.set_cutoff(0)
    await s.idle(4000)
    wet = await s.collect(250)
    span_wet = max(wet) - min(wet)

    dut._log.info(f"dry span {span_dry}, low-pass span {span_wet}")
    assert span_wet < span_dry / 2, (
        f"a low cutoff should attenuate strongly ({span_wet} vs {span_dry})")


@cocotb.test()
async def test_highpass_passes_high_cutoff(dut):
    """High-pass with the cutoff at the bottom passes the signal through."""
    s = await start(dut)
    await s.write(MODEVOL, HP | 0x0F)
    await s.set_freq(0, 0x2000)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)
    await s.write(RESFILT, FILT1)
    await s.set_cutoff(0)
    await s.idle(4000)

    wet = await s.collect(250)
    span = max(wet) - min(wet)
    assert span > 1000, f"high-pass should pass this voice, got {span}"


@cocotb.test()
async def test_filter_is_stable_across_the_range(dut):
    """No cutoff and resonance combination may let the loop run away.

    A two-integrator loop is only stable while w0 < 2 - 1/Q, and at this
    filter's phi2/8 sample rate the top of the cutoff range leaves little
    room.  This sweeps the corners with a voice driving the filter and
    checks the state variables stay well short of their clamps.
    """
    s = await start(dut)
    await s.write(MODEVOL, LP | BP | HP | 0x0F)
    await s.set_freq(0, 0x1000)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)
    await s.write(RESFILT, FILT1)
    await s.idle(2000)

    flt = s.dut.user_project.u_core.u_audio
    worst = 0
    worst_at = None

    for res in (0x0, 0x8, 0xF):
        for fc in (0, 0x400, 0x7FF):
            await s.write(RESFILT, (res << 4) | FILT1)
            await s.set_cutoff(fc)
            await s.idle(3000)           # let the smoother settle
            for _ in range(200):
                await s.idle(FRAME)
                for name in ("f_low", "f_band", "f_high"):
                    v = abs(getattr(flt, name).value.to_signed())
                    if v > worst:
                        worst, worst_at = v, (res, fc, name)

    dut._log.info(f"worst filter state magnitude {worst} at {worst_at}")
    # The clamp sits at 131071; anything approaching it means the loop is
    # diverging rather than tracking the input.
    assert worst < 60000, (
        f"filter state reached {worst} at res/fc/{worst_at}, which indicates "
        "an unstable loop")


@cocotb.test()
async def test_voice3_off(dut):
    """Bit 7 of MODE/VOL silences voice 3 only while it is unfiltered."""
    s = await start(dut)
    await s.write(MODEVOL, 0x0F)
    await s.set_freq(2, 0x4000)
    await s.set_adsr(2, a=0, d=0, s=15, r=0)
    await s.write(CTRL[2], SAW | GATE)
    await s.idle(3000)

    on = await s.collect(300)
    assert max(on) - min(on) > 1000, "voice 3 should be audible"

    await s.write(MODEVOL, VOICE3OFF | 0x0F)
    await s.idle(200)
    off = await s.collect(300)
    assert all(v == 0 for v in off), "3 OFF should silence an unfiltered voice 3"


@cocotb.test()
async def test_oscillator_sync(dut):
    """SYNC resets a voice's accumulator from the previous voice's MSB."""
    s = await start(dut)
    await s.set_freq(1, 0x8000)
    await s.write(CTRL[1], SAW)
    await s.set_freq(2, 0x0400)
    await s.write(CTRL[2], SAW | SYNC)

    await s.idle(2000)
    synced = []
    for _ in range(40):
        await s.idle(20)
        synced.append(await s.read(OSC3))

    assert max(synced) < 0x18, (
        f"a hard-synced ramp should stay near zero, peaked at {max(synced):#04x}")

    await s.write(CTRL[2], SAW)
    free = []
    for _ in range(40):
        await s.idle(150)
        free.append(await s.read(OSC3))

    assert max(free) > 0x30, (
        f"without sync the ramp should climb, peaked at {max(free):#04x}")


@cocotb.test()
async def test_ext_in_reaches_the_filter(dut):
    """EXT IN is summed into the filter when FILT EX is set."""
    s = await start(dut)
    await s.write(MODEVOL, LP | 0x0F)
    await s.set_cutoff(0x7FF)
    await s.write(RESFILT, FILTEX)       # EXT IN only, no voices
    await s.idle(2000)

    # Hold EXT IN low, then high; the mixer should follow.
    s.set_ext_in(0)
    await s.idle(2000)
    low = await s.collect(100)

    s.set_ext_in(1)
    await s.idle(2000)
    high = await s.collect(100)

    dut._log.info(f"EXT IN low mean {sum(low)//len(low)}, "
                  f"high mean {sum(high)//len(high)}")
    assert sum(high) // len(high) > sum(low) // len(low) + 500, (
        "driving EXT IN high should move the output")

    # With FILT EX cleared it must be ignored.
    await s.write(RESFILT, 0x00)
    await s.idle(2000)
    muted = await s.collect(100)
    assert max(muted) - min(muted) < 100, "EXT IN should be gated by FILT EX"


@cocotb.test()
async def test_model_select(dut):
    """The 1F extension switches between the 6581 and 8580 cutoff laws."""
    s = await start(dut)
    core = dut.user_project.u_core

    await s.set_cutoff(0x400)
    await s.write(CFG, 0x00)             # 6581
    await s.idle(4)
    w0_6581 = core.u_audio.u_fc.w0.value.to_unsigned()

    await s.write(CFG, 0x01)             # 8580
    await s.idle(4)
    w0_8580 = core.u_audio.u_fc.w0.value.to_unsigned()

    dut._log.info(f"w0 6581={w0_6581} 8580={w0_8580}")
    assert w0_6581 != w0_8580, "the two cutoff laws should differ"
    assert w0_8580 > w0_6581, "the 8580 law is linear and higher at mid scale"


@cocotb.test()
async def test_i2s_stream(dut):
    """The I2S output carries the mixer sample, MSB first, one bit after WS."""
    s = await start(dut)

    # TEST forces the pulse output high, so the sample does not move.
    await s.write(MODEVOL, 0x0F)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], PULSE | TEST | GATE)
    await s.idle(3000)

    expected = s.audio()
    assert expected != 0, "the test setup should produce a steady non-zero sample"
    want = (expected + 0x8000) & 0xFFFF
    dut._log.info(f"audio_o={expected}, expecting I2S word {want:#06x}")

    SD, WS = 1, 2

    prev_ws = None
    bits = []
    words = []

    # sck is phi2, and an I2S receiver samples on its rising edge.
    for _ in range(4000):
        await RisingEdge(dut.clk)
        o = dut.uo_out.value.to_unsigned()
        ws = (o >> WS) & 1
        if prev_ws is not None and ws != prev_ws:
            if len(bits) >= 17:
                w = 0
                for b in bits[1:17]:
                    w = (w << 1) | b
                words.append(w)
            bits = []
        prev_ws = ws
        bits.append((o >> SD) & 1)
        if len(words) >= 5:
            break

    # The first word is discarded: the decoder starts part-way through a
    # frame, so it has no complete slot to work with.
    words = words[1:]

    assert len(words) >= 3, f"expected several I2S words, decoded {len(words)}"
    assert all(w == want for w in words), (
        f"I2S words {[hex(w) for w in words]} should all be {want:#06x}")
