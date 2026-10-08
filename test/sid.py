"""
Helper for driving the tt_um_sid6581 tile over the 6581 phi2 bus.

clk is phi2, so one clock cycle is one phi2 period and a bus access
completes within a single cycle exactly as it does on the real chip:
the address, /CS and R//W are set up after the rising edge and a write
is latched by the falling edge.

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

from cocotb.triggers import FallingEdge, RisingEdge, Timer

# The original SID clock rates.
PHI2_PAL = 985248
PHI2_NTSC = 1022727

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

# RES/FILT bits.
FILTEX, FILT3, FILT2, FILT1 = 0x08, 0x04, 0x02, 0x01

# Mode/volume bits.
VOICE3OFF, HP, BP, LP = 0x80, 0x40, 0x20, 0x10

# ui_in bit positions.
CS_N, RW, EXT_IN = 0x20, 0x40, 0x80

# The audio pipeline produces one sample every 8 phi2 periods.
FRAME = 8


class Sid:
    def __init__(self, dut):
        self.dut = dut
        self._ext = 0

    # ------------------------------------------------------------ plumbing
    def _drive(self, addr=0, cs_n=1, rw=1):
        v = addr & 0x1F
        if cs_n:
            v |= CS_N
        if rw:
            v |= RW
        if self._ext:
            v |= EXT_IN
        self.dut.ui_in.value = v

    def set_ext_in(self, level):
        """Drive the 1-bit EXT IN pin."""
        self._ext = 1 if level else 0

    async def reset(self):
        self.dut.ena.value = 1
        self._drive()
        self.dut.uio_in.value = 0
        self.dut.rst_n.value = 0
        # The register file resets on the falling edge, so make sure a few
        # of those happen while reset is asserted.
        for _ in range(4):
            await RisingEdge(self.dut.clk)
        self.dut.rst_n.value = 1
        await RisingEdge(self.dut.clk)

    async def idle(self, periods=1):
        """Run phi2 with no bus access."""
        self._drive()
        for _ in range(periods):
            await RisingEdge(self.dut.clk)

    async def write(self, addr, data):
        """One write cycle; data is latched on the falling edge of phi2."""
        await RisingEdge(self.dut.clk)
        self.dut.uio_in.value = data & 0xFF
        self._drive(addr=addr, cs_n=0, rw=0)
        await FallingEdge(self.dut.clk)     # the register file latches here
        await RisingEdge(self.dut.clk)
        self.dut.uio_in.value = 0
        self._drive()

    async def read(self, addr):
        """One read cycle; the tile drives D0..D7 while /CS is low."""
        await RisingEdge(self.dut.clk)
        self._drive(addr=addr, cs_n=0, rw=1)
        await Timer(1, unit="ns")           # let the read path settle
        oe = self.dut.uio_oe.value.to_unsigned()
        assert oe == 0xFF, (
            f"tile should drive the data bus for a read of {addr:#04x}, "
            f"uio_oe={oe:#04x}")
        value = self.dut.uio_out.value.to_unsigned()
        await FallingEdge(self.dut.clk)
        self._drive()
        await Timer(1, unit="ns")
        oe = self.dut.uio_oe.value.to_unsigned()
        assert oe == 0x00, f"data bus must be released when /CS goes high ({oe:#04x})"
        await RisingEdge(self.dut.clk)
        return value

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
        return self.dut.user_project.u_core.u_audio.audio_o.value.to_signed()

    async def collect(self, frames):
        """Return one audio sample per filter frame."""
        out = []
        for _ in range(frames):
            await self.idle(FRAME)
            out.append(self.audio())
        return out
