#!/usr/bin/env python3
"""
Play a .sid file on an emulated 6502 and dump the SID register writes.

Produces a cycle-stamped trace that a Verilog or Verilator testbench can
replay over the phi2 bus, so the tune is driven into the RTL exactly the
way a C64 would drive the real chip -- as a stream of register writes.

    tools/sid2regs.py Antics_Chip_War.sid --seconds 30 -o trace.txt

Output lines: "<phi2_cycle> <reg_hex> <value_hex>".

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

import argparse
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cpu6502 import CPU

PAL_CYCLES_PER_FRAME = 19656      # 312 lines * 63 cycles
PAL_PHI2 = 985248

TRAP = 0xFFF0                     # return address we watch for


class SidFile:
    def __init__(self, path):
        raw = open(path, "rb").read()
        magic = raw[0:4]
        if magic not in (b"PSID", b"RSID"):
            raise ValueError(f"not a PSID/RSID file: {magic!r}")
        (self.version, self.data_offset, self.load_addr, self.init_addr,
         self.play_addr, self.songs, self.start_song,
         self.speed) = struct.unpack(">HHHHHHHI", raw[4:22])
        self.magic = magic.decode()
        self.name = raw[22:54].split(b"\0")[0].decode("latin-1")
        self.author = raw[54:86].split(b"\0")[0].decode("latin-1")
        self.released = raw[86:118].split(b"\0")[0].decode("latin-1")
        self.flags = struct.unpack(">H", raw[118:120])[0] if self.version >= 2 else 0

        data = raw[self.data_offset:]
        if self.load_addr == 0:
            self.load_addr = data[0] | (data[1] << 8)
            data = data[2:]
        self.data = data

    @property
    def is_pal(self):
        return ((self.flags >> 2) & 3) != 2

    @property
    def model(self):
        return {0: "unknown", 1: "6581", 2: "8580", 3: "any"}[(self.flags >> 4) & 3]


class C64:
    """Enough of a C64 to run a player: RAM, a CIA timer and a raster."""

    def __init__(self, sid):
        self.mem = bytearray(0x10000)
        self.mem[sid.load_addr:sid.load_addr + len(sid.data)] = sid.data
        self.writes = []
        self.cycle_base = 0
        self.cpu = CPU(self.read, self.write)

        # CIA 1 timer A
        self.cia_latch = 0x4025       # the usual ~50 Hz default
        self.cia_timer = 0x4025
        self.cia_running = False
        self.cia_irq_en = False

        # VIC raster interrupt
        self.raster_cmp = 0
        self.vic_irq_en = False

        # CIA 2 timer A, which drives the NMI (digi playback on this tune)
        self.cia2_latch = 0
        self.cia2_running = False
        self.cia2_nmi_en = False

        # Set while the CPU is inside the NMI handler, so volume-register
        # digi writes can be told apart from the music player's.
        self.in_nmi = False
        self.nmi_sp = 0
        self.drop_digi = False

    # ------------------------------------------------------------- memory
    def read(self, a):
        if 0xD400 <= a <= 0xD41F:
            # OSC3/ENV3 read back as a changing value; some players poll them.
            if a == 0xD41B:
                return (self.cpu.cycles * 7 + 13) & 0xFF
            if a == 0xD41C:
                return (self.cpu.cycles * 3) & 0xFF
            return 0
        if a == 0xD012:
            return ((self.cpu.cycles // 63) % 312) & 0xFF
        if a == 0xD011:
            return 0x1B | (0x80 if ((self.cpu.cycles // 63) % 312) > 255 else 0)
        if a == 0xD019:
            return 0x81
        if a == 0xDC04:
            return self.cia_timer & 0xFF
        if a == 0xDC05:
            return (self.cia_timer >> 8) & 0xFF
        if a == 0xDC0D:
            return 0x81
        return self.mem[a]

    def write(self, a, v):
        if 0xD400 <= a <= 0xD41F:
            if not (self.drop_digi and self.in_nmi and a == 0xD418):
                self.writes.append(
                    (self.cycle_base + self.cpu.cycles, a - 0xD400, v))
            return
        if a == 0xD012:
            self.raster_cmp = (self.raster_cmp & 0x100) | v
        elif a == 0xD011:
            self.raster_cmp = (self.raster_cmp & 0xFF) | ((v & 0x80) << 1)
        elif a == 0xD01A:
            self.vic_irq_en = bool(v & 1)
        elif a == 0xDC04:
            self.cia_latch = (self.cia_latch & 0xFF00) | v
        elif a == 0xDC05:
            self.cia_latch = (self.cia_latch & 0x00FF) | (v << 8)
        elif a == 0xDC0D:
            if v & 0x80:
                self.cia_irq_en |= bool(v & 1)
            else:
                self.cia_irq_en &= not (v & 1)
        elif a == 0xDC0E:
            self.cia_running = bool(v & 1)
            if v & 0x10:
                self.cia_timer = self.cia_latch
        elif a == 0xDD04:
            self.cia2_latch = (self.cia2_latch & 0xFF00) | v
        elif a == 0xDD05:
            self.cia2_latch = (self.cia2_latch & 0x00FF) | (v << 8)
        elif a == 0xDD0D:
            if v & 0x80:
                self.cia2_nmi_en = self.cia2_nmi_en or bool(v & 1)
            elif v & 1:
                self.cia2_nmi_en = False
        elif a == 0xDD0E:
            self.cia2_running = bool(v & 1)
        self.mem[a] = v

    # ---------------------------------------------------------- execution
    def run_free(self, total_cycles, progress=None):
        """Run the way a C64 does: an idle loop, interrupted by the VIC
        raster IRQ and the CIA 2 NMI, which is what actually drives this
        kind of player."""
        c = self.cpu
        # An idle loop for the CPU to sit in between interrupts.
        self.mem[0xFFF0:0xFFF3] = bytes((0x4C, 0xF0, 0xFF))   # JMP $FFF0
        c.pc = 0xFFF0
        c.p &= ~0x04                      # CLI: the player wants interrupts
        c.cycles = 0
        self.cycle_base = 0

        next_nmi = self.cia2_latch if (self.cia2_running and self.cia2_nmi_en) else None
        last_line = -1
        irq_pending = False
        next_mark = 0

        while c.cycles < total_cycles:
            if progress and c.cycles >= next_mark:
                progress(c.cycles, total_cycles)
                next_mark += total_cycles // 20

            line = (c.cycles // 63) % 312
            if line != last_line:
                if self.vic_irq_en and line == (self.raster_cmp & 0x1FF):
                    irq_pending = True
                last_line = line

            if next_nmi is not None and c.cycles >= next_nmi:
                c.nmi()
                self.in_nmi = True
                self.nmi_sp = c.sp
                next_nmi += max(self.cia2_latch, 1)
            elif irq_pending and not (c.p & 0x04):
                c.irq()
                irq_pending = False

            c.step()

            if self.in_nmi and c.sp > self.nmi_sp:
                self.in_nmi = False
            if c.jammed:
                raise RuntimeError(f"CPU jammed at ${c.pc:04X}")
        return c.cycles

    def run_until_trap(self, budget):
        """Run until the routine returns to TRAP, or the budget runs out."""
        self.cpu.cycles = 0
        while self.cpu.cycles < budget:
            if self.cpu.pc == TRAP or self.cpu.jammed:
                break
            self.cpu.step()
        return self.cpu.cycles

    def call(self, addr, a=0, budget=2_000_000, rti=False):
        c = self.cpu
        c.pc = addr
        c.a = a & 0xFF
        c.x = c.y = 0
        c.sp = 0xFD
        c.jammed = False
        if rti:
            # Leave an interrupt frame so an RTI lands on the trap.
            c._push((TRAP >> 8) & 0xFF)
            c._push(TRAP & 0xFF)
            c._push(c.p & ~0x10)
        else:
            r = TRAP - 1
            c._push((r >> 8) & 0xFF)
            c._push(r & 0xFF)
        used = self.run_until_trap(budget)
        self.cycle_base += used
        return used, (c.pc == TRAP)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sidfile")
    ap.add_argument("-o", "--out", default="trace.txt")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--song", type=int, default=None)
    ap.add_argument("--no-digi", action="store_true",
                    help="drop volume-register digi writes "
                         "(see docs: this design does not "
                         "reproduce them anyway)")
    args = ap.parse_args()

    sid = SidFile(args.sidfile)
    song = args.song if args.song is not None else sid.start_song
    print(f"{sid.magic} v{sid.version}: {sid.name!r} by {sid.author!r} ({sid.released})")
    print(f"  load ${sid.load_addr:04X} init ${sid.init_addr:04X} "
          f"play ${sid.play_addr:04X} songs {sid.songs} start {sid.start_song}")
    print(f"  {'PAL' if sid.is_pal else 'NTSC'}, model {sid.model}, "
          f"data {len(sid.data)} bytes")

    c64 = C64(sid)

    # Init. RSID passes the song number in A, zero-based.
    # Its register writes matter -- that is where volume, the filter and
    # the ADSR defaults get set -- so they are kept, not discarded.
    init_used, ok = c64.call(sid.init_addr, a=song - 1, rti=False)
    print(f"  init: {init_used} cycles, returned={ok}, "
          f"{len(c64.writes)} register writes")

    print(f"  IRQ $FFFE -> ${c64.mem[0xFFFE] | (c64.mem[0xFFFF] << 8):04X}, "
          f"NMI $FFFA -> ${c64.mem[0xFFFA] | (c64.mem[0xFFFB] << 8):04X}")
    print(f"  VIC raster IRQ: {'on' if c64.vic_irq_en else 'off'} "
          f"at line {c64.raster_cmp}")
    if c64.cia2_running and c64.cia2_nmi_en:
        print(f"  CIA2 NMI: every {c64.cia2_latch} cycles "
              f"({PAL_PHI2 / max(c64.cia2_latch, 1):.0f} Hz) -- this is a "
              f"volume-register digi player")

    c64.drop_digi = args.no_digi
    if args.no_digi:
        # This tune's music player never writes $D418 at all -- the NMI
        # digi routine owns it. Dropping those writes alone would leave
        # the volume at the zero the init loop cleared it to, so put a
        # sensible master volume in instead.
        print("  (dropping the NMI handler's volume-register digi writes, "
              "and holding master volume at 15)")
        c64.writes.append((c64.cycle_base + c64.cpu.cycles, 0x18, 0x0F))

    # Keep the init writes, then run the machine for real.
    base = len(c64.writes)
    total = int(args.seconds * PAL_PHI2)

    def progress(done, tot):
        pct = 100.0 * done / tot
        sys.stdout.write(f"\r  emulating... {pct:5.1f}%")
        sys.stdout.flush()

    c64.run_free(total, progress=progress)
    sys.stdout.write("\r" + " " * 30 + "\r")

    print(f"  {args.seconds:g} s = {total} phi2 cycles, "
          f"{len(c64.writes) - base} register writes from the player "
          f"({base} from init)")

    c64.writes.sort(key=lambda w: w[0])
    with open(args.out, "w") as fh:
        for cyc, reg, val in c64.writes:
            fh.write(f"{cyc} {reg:02x} {val:02x}\n")
    print(f"  wrote {args.out}")

    touched = sorted({r for _, r, _ in c64.writes})
    print(f"  registers touched: {' '.join(f'{r:02X}' for r in touched)}")


if __name__ == "__main__":
    main()
