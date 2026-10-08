"""
Functional tests for the tt_um_sid6581 Tiny Tapeout tile.

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import sid
from sid import (CTRL, MODEVOL, RESFILT, OSC3, ENV3, POTX, POTY,
                 POTX_SET, POTY_SET, CFG,
                 NOISE, PULSE, SAW, TRI, TEST, SYNC, GATE,
                 LP, HP, VOICE3OFF)

CLK_NS = 20          # 50 MHz system clock
CLK_PER_PHI2 = 50    # 1 MHz phi2


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    s = sid.Sid(dut, CLK_PER_PHI2)
    await s.reset()
    return s


async def collect(s, periods, every=1):
    """Run phi2 and return the audio samples produced."""
    out = []
    for i in range(periods):
        await s.idle(1)
        if i % every == 0:
            out.append(s.audio())
    return out


@cocotb.test()
async def test_reset_state(dut):
    """After /RES the oscillators, envelopes and output are all cleared."""
    s = await start(dut)
    dut._log.info("checking reset state")

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
        # Each step should advance; allow the single 8-bit wrap.
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

    # Releasing TEST lets the accumulator run again, so the duty cycle
    # makes OSC3 leave 0xFF.
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
    # A fold means the direction reverses at least once.
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

    # Attack: fastest rate is 9 phi2 cycles per step, 255 steps.
    peak = 0
    for _ in range(60):
        await s.idle(100)
        peak = max(peak, await s.read(ENV3))
        if peak == 0xFF:
            break
    assert peak == 0xFF, f"attack should reach full scale, got {peak:#04x}"

    # Decay towards the sustain level of 0x88.
    for _ in range(400):
        await s.idle(100)
        if await s.read(ENV3) <= 0x8A:
            break
    env = await s.read(ENV3)
    assert 0x86 <= env <= 0x8A, f"should settle at sustain 0x88, got {env:#04x}"

    # Sustain holds.
    await s.idle(3000)
    env = await s.read(ENV3)
    assert 0x86 <= env <= 0x8A, f"sustain should hold, got {env:#04x}"

    # Release falls back to zero.
    await s.write(CTRL[2], SAW)
    for _ in range(600):
        await s.idle(100)
        if await s.read(ENV3) == 0x00:
            break
    assert await s.read(ENV3) == 0x00, "release should reach zero"


@cocotb.test()
async def test_audio_output_and_volume(dut):
    """A gated voice produces a moving output that scales with volume."""
    s = await start(dut)
    await s.write(MODEVOL, 0x0F)
    await s.set_freq(0, 0x4000)          # wraps every 1024 phi2 periods
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)

    # Let the envelope reach full scale.
    await s.idle(3000)

    loud = await collect(s, 1500)
    span_loud = max(loud) - min(loud)
    assert span_loud > 2000, f"expected a large swing, got {span_loud}"

    await s.write(MODEVOL, 0x00)
    await s.idle(100)
    quiet = await collect(s, 500)
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
        ones += dut.uo_out.value.integer & 1

    assert 200 < ones < 3800, f"PDM duty cycle looks stuck ({ones}/4000)"


@cocotb.test()
async def test_lowpass_attenuates(dut):
    """Routing a voice through a low cutoff low-pass reduces its level."""
    s = await start(dut)
    await s.write(MODEVOL, LP | 0x0F)
    await s.set_freq(0, 0x2000)          # a few kHz, well above the cutoff
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], SAW | GATE)
    await s.idle(3000)

    # Unfiltered reference.
    await s.write(RESFILT, 0x00)
    await s.idle(500)
    dry = await collect(s, 1200)
    span_dry = max(dry) - min(dry)

    # Route voice 1 into the filter with the cutoff at the bottom.
    await s.write(RESFILT, 0x01)
    await s.set_cutoff(0)
    await s.idle(4000)
    wet = await collect(s, 1200)
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
    await s.write(RESFILT, 0x01)
    await s.set_cutoff(0)
    await s.idle(4000)

    wet = await collect(s, 1200)
    span = max(wet) - min(wet)
    assert span > 1000, f"high-pass should pass this voice, got {span}"


@cocotb.test()
async def test_voice3_off(dut):
    """Bit 7 of MODE/VOL silences voice 3 only while it is unfiltered."""
    s = await start(dut)
    await s.write(MODEVOL, 0x0F)
    await s.set_freq(2, 0x4000)          # wraps every 1024 phi2 periods
    await s.set_adsr(2, a=0, d=0, s=15, r=0)
    await s.write(CTRL[2], SAW | GATE)
    await s.idle(3000)

    on = await collect(s, 1500)
    assert max(on) - min(on) > 1000, "voice 3 should be audible"

    await s.write(MODEVOL, VOICE3OFF | 0x0F)
    await s.idle(200)
    off = await collect(s, 1500)
    assert all(v == 0 for v in off), "3 OFF should silence an unfiltered voice 3"


@cocotb.test()
async def test_oscillator_sync(dut):
    """SYNC resets a voice's accumulator from the previous voice's MSB."""
    s = await start(dut)
    # Voice 3 takes its sync source from voice 2.  The source wraps every
    # 512 phi2 periods; the slave would need 16384 to complete one ramp of
    # its own, so being hard-synced pins its output near zero.
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

    # With SYNC cleared the same voice is free to run all the way up.
    # Its own ramp takes 16384 phi2 periods, so give it time to climb.
    await s.write(CTRL[2], SAW)
    free = []
    for _ in range(40):
        await s.idle(150)
        free.append(await s.read(OSC3))

    assert max(free) > 0x30, (
        f"without sync the ramp should climb, peaked at {max(free):#04x}")


@cocotb.test()
async def test_model_select(dut):
    """The 1F extension switches between the 6581 and 8580 cutoff laws."""
    s = await start(dut)
    core = dut.user_project.u_core

    await s.set_cutoff(0x400)
    await s.write(CFG, 0x00)             # 6581
    await s.idle(4)
    w0_6581 = core.u_audio.u_fc.w0.value.integer

    await s.write(CFG, 0x01)             # 8580
    await s.idle(4)
    w0_8580 = core.u_audio.u_fc.w0.value.integer

    dut._log.info(f"w0 6581={w0_6581} 8580={w0_8580}")
    assert w0_6581 != w0_8580, "the two cutoff laws should differ"
    assert w0_8580 > w0_6581, "the 8580 law is linear and higher at mid scale"


@cocotb.test()
async def test_i2s_stream(dut):
    """The I2S output carries the mixer sample, MSB first, one bit after WS."""
    s = await start(dut)

    # Hold the output at a constant value: TEST forces the pulse output
    # high, so with a full envelope the sample does not move.
    await s.write(MODEVOL, 0x0F)
    await s.set_adsr(0, a=0, d=0, s=15, r=0)
    await s.write(CTRL[0], PULSE | TEST | GATE)
    await s.idle(3000)

    expected = s.audio()
    assert expected != 0, "the test setup should produce a steady non-zero sample"
    # The DAC sends offset binary, so silence is 0x8000.
    want = (expected + 0x8000) & 0xFFFF
    dut._log.info(f"audio_o={expected}, expecting I2S word {want:#06x}")

    SD, WS, SCK = 2, 3, 4

    # Follow SCK rising edges, which is when an I2S receiver samples.
    prev_sck = 0
    prev_ws = None
    bits = []
    words = []

    for _ in range(40000):
        await RisingEdge(dut.clk)
        o = dut.uo_out.value.integer
        sck = (o >> SCK) & 1
        if sck and not prev_sck:
            ws = (o >> WS) & 1
            if prev_ws is not None and ws != prev_ws:
                if len(bits) >= 17:
                    # Drop the one-bit delay, then take the 16 data bits.
                    w = 0
                    for b in bits[1:17]:
                        w = (w << 1) | b
                    words.append(w)
                bits = []
            prev_ws = ws
            bits.append((o >> SD) & 1)
        prev_sck = sck
        if len(words) >= 5:
            break

    # The first word is discarded: the decoder starts part-way through a
    # frame, so it has no complete slot to work with.
    words = words[1:]

    assert len(words) >= 3, f"expected several I2S words, decoded {len(words)}"
    assert all(w == want for w in words), (
        f"I2S words {[hex(w) for w in words]} should all be {want:#06x}")
