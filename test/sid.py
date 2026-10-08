"""
Helper for driving the tt_um_sid6581 tile over the 6581 phi2 bus.

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

from cocotb.triggers import RisingEdge, Timer

# Register map of the original chip.
FREQLO = (0x00, 0x07, 0x0E)
FREQHI = (0x01, 0x08, 0x0F)
PWLO   = (0x02, 0x09, 0x10)
PWHI   = (0x03, 0x0A, 0x11)
CTRL   = (0x04, 0x0B, 0x12)
ATKDCY = (0x05, 0x0C, 0x13)
SUSREL = (0x06, 0x0D, 0x14)

FCLO, FCHI, RESFILT, MODEVOL = 0x15, 0x16, 0x17, 0x18
POTX, POTY, OSC3, ENV3 = 0x19, 0x1A, 0x1B, 0x1C
POTX_SET, POTY_SET, CFG = 0x1D, 0x1E, 0x1F

# Control register bits.
NOISE, PULSE, SAW, TRI, TEST, RING, SYNC, GATE = (
    0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01)

# Mode/volume bits.
VOICE3OFF, HP, BP, LP = 0x80, 0x40, 0x20, 0x10

CS_N, RW, PHI2 = 0x20, 0x40, 0x80


class Sid:
    """Drives phi2, /CS, R//W, A0..A4 and D0..D7 like a 6502 bus master."""

    def __init__(self, dut, clk_per_phi2=50):
        self.dut = dut
        # clk cycles in each half of a phi2 period
        self.half = clk_per_phi2 // 2

    async def _clks(self, n):
        for _ in range(n):
            await RisingEdge(self.dut.clk)

    def _set(self, addr=0, cs_n=1, rw=1, phi2=0):
        v = addr & 0x1F
        if cs_n:
            v |= CS_N
        if rw:
            v |= RW
        if phi2:
            v |= PHI2
        self.dut.ui_in.value = v

    async def idle(self, periods=1):
        """Run phi2 with no bus access."""
        for _ in range(periods):
            self._set(phi2=1)
            await self._clks(self.half)
            self._set(phi2=0)
            await self._clks(self.half)

    async def write(self, addr, data):
        """One write cycle: data is latched on the falling edge of phi2."""
        self.dut.uio_in.value = data & 0xFF
        self._set(addr=addr, cs_n=0, rw=0, phi2=1)
        await self._clks(self.half)
        self._set(addr=addr, cs_n=0, rw=0, phi2=0)
        await self._clks(self.half)
        self.dut.uio_in.value = 0
        self._set(phi2=1)
        await self._clks(self.half)
        self._set(phi2=0)
        await self._clks(self.half)

    async def read(self, addr):
        """One read cycle: the tile drives D0..D7 while phi2 and /CS allow."""
        self._set(addr=addr, cs_n=0, rw=1, phi2=1)
        await self._clks(self.half)
        assert self.dut.uio_oe.value.integer == 0xFF, (
            f"tile should be driving the data bus for a read of {addr:#04x}, "
            f"uio_oe={self.dut.uio_oe.value.integer:#04x}")
        value = self.dut.uio_out.value.integer
        self._set(addr=addr, cs_n=0, rw=1, phi2=0)
        await self._clks(self.half)
        assert self.dut.uio_oe.value.integer == 0x00, (
            "data bus must be released when phi2 is low")
        self._set(phi2=1)
        await self._clks(self.half)
        self._set(phi2=0)
        await self._clks(self.half)
        return value

    async def reset(self):
        self.dut.ena.value = 1
        self._set()
        self.dut.uio_in.value = 0
        self.dut.rst_n.value = 0
        await self._clks(10)
        self.dut.rst_n.value = 1
        await self._clks(5)

    # ---------------------------------------------------------- convenience
    async def set_freq(self, voice, value):
        await self.write(FREQLO[voice], value & 0xFF)
        await self.write(FREQHI[voice], (value >> 8) & 0xFF)

    async def set_pw(self, voice, value):
        await self.write(PWLO[voice], value & 0xFF)
        await self.write(PWHI[voice], (value >> 8) & 0x0F)

    async def set_adsr(self, voice, a, d, s, r):
        await self.write(ATKDCY[voice], (a << 4) | d)
        await self.write(SUSREL[voice], (s << 4) | r)

    async def set_cutoff(self, value):
        await self.write(FCLO, value & 0x07)
        await self.write(FCHI, (value >> 3) & 0xFF)

    def audio(self):
        """Current signed 16-bit sample, read from inside the core."""
        return self.dut.user_project.u_core.u_audio.audio_o.value.signed_integer
