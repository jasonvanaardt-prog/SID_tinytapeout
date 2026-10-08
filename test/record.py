"""
Renders a short demo from the tile and writes it to sid_demo.wav.

Run with:  make record        (optionally DURATION_MS=500)

This drives the tile exactly as a C64 would -- every note is a sequence of
register writes over the phi2 bus -- and captures the sample stream from
the mixer output.

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

import os
import wave

import cocotb
from cocotb.clock import Clock

import sid
from sid import (CTRL, MODEVOL, RESFILT, FCLO, FCHI,
                 SAW, PULSE, NOISE, TRI, GATE, LP, BP)

CLK_NS = 20
CLK_PER_PHI2 = 16          # the minimum the audio pipeline allows
PHI2_HZ = 1_000_000
DECIMATE = 20              # 1 MHz / 20 = 50 kHz output rate
SAMPLE_RATE = PHI2_HZ // DECIMATE

DURATION_MS = int(os.environ.get("DURATION_MS", "300"))


def note(freq_hz):
    """SID frequency register value for a pitch, at a 1 MHz phi2."""
    return min(0xFFFF, round(freq_hz * (1 << 24) / PHI2_HZ))


# A short descending figure, with a fifth above on voice 2.
TUNE = [
    (587.33, 880.00),   # D5 + A5
    (493.88, 740.00),   # B4
    (440.00, 659.25),   # A4
    (369.99, 554.37),   # F#4
]


@cocotb.test()
async def render_wav(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    s = sid.Sid(dut, CLK_PER_PHI2)
    await s.reset()

    total_periods = DURATION_MS * PHI2_HZ // 1000
    step = total_periods // len(TUNE)

    # Master volume up, low-pass selected, voices 1 and 2 through the filter.
    await s.write(MODEVOL, LP | 0x0F)
    await s.write(RESFILT, 0x08 | 0x03)      # RES=0, filter voices 1 and 2
    await s.set_adsr(0, a=2, d=9, s=10, r=9)
    await s.set_adsr(1, a=3, d=10, s=8, r=10)
    await s.set_adsr(2, a=0, d=6, s=0, r=6)
    await s.set_pw(0, 0x0600)

    samples = []
    dut._log.info(f"rendering {DURATION_MS} ms at {SAMPLE_RATE} Hz "
                  f"({total_periods} phi2 periods)")

    for idx, (f1, f2) in enumerate(TUNE):
        await s.set_freq(0, note(f1))
        await s.set_freq(1, note(f2))
        await s.write(CTRL[0], PULSE | GATE)
        await s.write(CTRL[1], SAW | GATE)
        # Voice 3 is a short noise hit on the first beat of each pair.
        await s.write(CTRL[2], (NOISE | GATE) if idx % 2 == 0 else 0)
        await s.set_freq(2, 0xC000)

        for n in range(step):
            # Sweep the cutoff down across each note.
            if n % 64 == 0:
                fc = 0x7FF - (0x600 * n) // step
                await s.write(FCLO, fc & 0x07)
                await s.write(FCHI, (fc >> 3) & 0xFF)
            else:
                await s.idle(1)

            if n % DECIMATE == 0:
                samples.append(s.audio())

        # Release the notes for the last part of each step.
        await s.write(CTRL[0], PULSE)
        await s.write(CTRL[1], SAW)
        await s.write(CTRL[2], 0)

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "sid_demo.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(
            int(v).to_bytes(2, "little", signed=True) for v in samples))

    peak = max(abs(v) for v in samples)
    dut._log.info(f"wrote {len(samples)} samples to {path}, peak {peak}")
    assert peak > 1000, f"the render is nearly silent (peak {peak})"
