"""
A compact 6502 core, enough to run a C64 SID player routine.

Implements the documented instruction set plus the undocumented opcodes
that period music players actually use (LAX, SAX, DCP, ISC, SLO, RLA,
SRE, RRA, ANC, ALR, ARR, SBX). Cycle counts are the standard ones
including page-cross and branch-taken penalties, which matters because
register writes are timestamped against them.

SPDX-FileCopyrightText: 2026 Jason van Aardt
SPDX-License-Identifier: CERN-OHL-S-2.0
"""

C, Z, I, D, B, U, V, N = 1, 2, 4, 8, 16, 32, 64, 128


class CPU:
    def __init__(self, read, write):
        self.read = read
        self.write = write
        self.a = self.x = self.y = 0
        self.sp = 0xFD
        self.pc = 0
        self.p = U | I
        self.cycles = 0
        self.jammed = False

    # ------------------------------------------------------------ helpers
    def _rd(self, addr):
        return self.read(addr & 0xFFFF) & 0xFF

    def _wr(self, addr, v):
        self.write(addr & 0xFFFF, v & 0xFF)

    def _rd16(self, addr):
        return self._rd(addr) | (self._rd(addr + 1) << 8)

    def _rd16_bug(self, addr):
        """JMP (ind) page-wrap bug."""
        lo = self._rd(addr)
        hi = self._rd((addr & 0xFF00) | ((addr + 1) & 0xFF))
        return lo | (hi << 8)

    def _push(self, v):
        self._wr(0x100 + self.sp, v)
        self.sp = (self.sp - 1) & 0xFF

    def _pop(self):
        self.sp = (self.sp + 1) & 0xFF
        return self._rd(0x100 + self.sp)

    def _setzn(self, v):
        v &= 0xFF
        self.p = (self.p & ~(Z | N)) | (Z if v == 0 else 0) | (v & N)
        return v

    def _fetch(self):
        v = self._rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def _fetch16(self):
        v = self._rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        return v

    # --------------------------------------------------------- addressing
    # Each returns (address, extra_cycles_if_page_crossed)
    def _am(self, mode):
        if mode == "imp" or mode == "acc":
            return None, 0
        if mode == "imm":
            a = self.pc
            self.pc = (self.pc + 1) & 0xFFFF
            return a, 0
        if mode == "zp":
            return self._fetch(), 0
        if mode == "zpx":
            return (self._fetch() + self.x) & 0xFF, 0
        if mode == "zpy":
            return (self._fetch() + self.y) & 0xFF, 0
        if mode == "abs":
            return self._fetch16(), 0
        if mode == "abx":
            base = self._fetch16()
            a = (base + self.x) & 0xFFFF
            return a, 1 if (base & 0xFF00) != (a & 0xFF00) else 0
        if mode == "aby":
            base = self._fetch16()
            a = (base + self.y) & 0xFFFF
            return a, 1 if (base & 0xFF00) != (a & 0xFF00) else 0
        if mode == "izx":
            zp = (self._fetch() + self.x) & 0xFF
            return self._rd(zp) | (self._rd((zp + 1) & 0xFF) << 8), 0
        if mode == "izy":
            zp = self._fetch()
            base = self._rd(zp) | (self._rd((zp + 1) & 0xFF) << 8)
            a = (base + self.y) & 0xFFFF
            return a, 1 if (base & 0xFF00) != (a & 0xFF00) else 0
        if mode == "rel":
            off = self._fetch()
            if off & 0x80:
                off -= 256
            return (self.pc + off) & 0xFFFF, 0
        raise ValueError(mode)

    # --------------------------------------------------------- operations
    def _adc(self, m):
        a = self.a
        if self.p & D:
            lo = (a & 0x0F) + (m & 0x0F) + (self.p & C)
            hi = (a >> 4) + (m >> 4)
            if lo > 9:
                lo += 6
                hi += 1
            self.p &= ~(C | V | N | Z)
            if ((a + m + (self.p & C)) & 0xFF) == 0:
                self.p |= Z
            if hi & 0x08:
                self.p |= N
            if (~(a ^ m) & (a ^ (hi << 4)) & 0x80):
                self.p |= V
            if hi > 9:
                hi += 6
            if hi > 15:
                self.p |= C
            self.a = ((hi << 4) | (lo & 0x0F)) & 0xFF
        else:
            s = a + m + (self.p & C)
            self.p &= ~(C | V)
            if s > 0xFF:
                self.p |= C
            if (~(a ^ m) & (a ^ s) & 0x80):
                self.p |= V
            self.a = self._setzn(s)

    def _sbc(self, m):
        if self.p & D:
            a = self.a
            borrow = 1 - (self.p & C)
            lo = (a & 0x0F) - (m & 0x0F) - borrow
            hi = (a >> 4) - (m >> 4)
            if lo & 0x10:
                lo -= 6
                hi -= 1
            if hi & 0x10:
                hi -= 6
            s = a - m - borrow
            self.p &= ~(C | V)
            if not (s & 0x100):
                self.p |= C
            if ((a ^ m) & (a ^ s) & 0x80):
                self.p |= V
            self._setzn(s & 0xFF)
            self.a = ((hi << 4) | (lo & 0x0F)) & 0xFF
        else:
            self._adc((~m) & 0xFF)

    def _cmp(self, reg, m):
        d = (reg - m) & 0x1FF
        self.p = (self.p & ~C) | (C if reg >= m else 0)
        self._setzn(d & 0xFF)

    def _branch(self, addr, taken):
        if taken:
            self.cycles += 2 if (self.pc & 0xFF00) != (addr & 0xFF00) else 1
            self.pc = addr
    # ------------------------------------------------------------ interrupt
    def irq(self):
        if self.p & I:
            return False
        self._push((self.pc >> 8) & 0xFF)
        self._push(self.pc & 0xFF)
        self._push((self.p | U) & ~B)
        self.p |= I
        self.pc = self._rd16(0xFFFE)
        self.cycles += 7
        return True

    def nmi(self):
        self._push((self.pc >> 8) & 0xFF)
        self._push(self.pc & 0xFF)
        self._push((self.p | U) & ~B)
        self.p |= I
        self.pc = self._rd16(0xFFFA)
        self.cycles += 7

# opcode -> (mnemonic, addressing mode, base cycles, add page-cross penalty)
OPS = {}


def _o(code, name, mode, cyc, pc_pen=False):
    OPS[code] = (name, mode, cyc, pc_pen)


for _c, _m, _cy, _p in [
    (0x69, "imm", 2, 0), (0x65, "zp", 3, 0), (0x75, "zpx", 4, 0),
    (0x6D, "abs", 4, 0), (0x7D, "abx", 4, 1), (0x79, "aby", 4, 1),
    (0x61, "izx", 6, 0), (0x71, "izy", 5, 1)]:
    _o(_c, "ADC", _m, _cy, _p)
for _c, _m, _cy, _p in [
    (0xE9, "imm", 2, 0), (0xEB, "imm", 2, 0), (0xE5, "zp", 3, 0),
    (0xF5, "zpx", 4, 0), (0xED, "abs", 4, 0), (0xFD, "abx", 4, 1),
    (0xF9, "aby", 4, 1), (0xE1, "izx", 6, 0), (0xF1, "izy", 5, 1)]:
    _o(_c, "SBC", _m, _cy, _p)
for _n, _tbl in [
    ("AND", [(0x29, "imm", 2, 0), (0x25, "zp", 3, 0), (0x35, "zpx", 4, 0),
             (0x2D, "abs", 4, 0), (0x3D, "abx", 4, 1), (0x39, "aby", 4, 1),
             (0x21, "izx", 6, 0), (0x31, "izy", 5, 1)]),
    ("ORA", [(0x09, "imm", 2, 0), (0x05, "zp", 3, 0), (0x15, "zpx", 4, 0),
             (0x0D, "abs", 4, 0), (0x1D, "abx", 4, 1), (0x19, "aby", 4, 1),
             (0x01, "izx", 6, 0), (0x11, "izy", 5, 1)]),
    ("EOR", [(0x49, "imm", 2, 0), (0x45, "zp", 3, 0), (0x55, "zpx", 4, 0),
             (0x4D, "abs", 4, 0), (0x5D, "abx", 4, 1), (0x59, "aby", 4, 1),
             (0x41, "izx", 6, 0), (0x51, "izy", 5, 1)]),
    ("LDA", [(0xA9, "imm", 2, 0), (0xA5, "zp", 3, 0), (0xB5, "zpx", 4, 0),
             (0xAD, "abs", 4, 0), (0xBD, "abx", 4, 1), (0xB9, "aby", 4, 1),
             (0xA1, "izx", 6, 0), (0xB1, "izy", 5, 1)]),
    ("CMP", [(0xC9, "imm", 2, 0), (0xC5, "zp", 3, 0), (0xD5, "zpx", 4, 0),
             (0xCD, "abs", 4, 0), (0xDD, "abx", 4, 1), (0xD9, "aby", 4, 1),
             (0xC1, "izx", 6, 0), (0xD1, "izy", 5, 1)]),
    ("LAX", [(0xA7, "zp", 3, 0), (0xB7, "zpy", 4, 0), (0xAF, "abs", 4, 0),
             (0xBF, "aby", 4, 1), (0xA3, "izx", 6, 0), (0xB3, "izy", 5, 1)]),
]:
    for _c, _m, _cy, _p in _tbl:
        _o(_c, _n, _m, _cy, _p)

_o(0x85, "STA", "zp", 3); _o(0x95, "STA", "zpx", 4); _o(0x8D, "STA", "abs", 4)
_o(0x9D, "STA", "abx", 5); _o(0x99, "STA", "aby", 5); _o(0x81, "STA", "izx", 6)
_o(0x91, "STA", "izy", 6)
_o(0x86, "STX", "zp", 3); _o(0x96, "STX", "zpy", 4); _o(0x8E, "STX", "abs", 4)
_o(0x84, "STY", "zp", 3); _o(0x94, "STY", "zpx", 4); _o(0x8C, "STY", "abs", 4)
_o(0x87, "SAX", "zp", 3); _o(0x97, "SAX", "zpy", 4); _o(0x8F, "SAX", "abs", 4)
_o(0x83, "SAX", "izx", 6)
_o(0xA2, "LDX", "imm", 2); _o(0xA6, "LDX", "zp", 3); _o(0xB6, "LDX", "zpy", 4)
_o(0xAE, "LDX", "abs", 4); _o(0xBE, "LDX", "aby", 4, True)
_o(0xA0, "LDY", "imm", 2); _o(0xA4, "LDY", "zp", 3); _o(0xB4, "LDY", "zpx", 4)
_o(0xAC, "LDY", "abs", 4); _o(0xBC, "LDY", "abx", 4, True)
_o(0xE0, "CPX", "imm", 2); _o(0xE4, "CPX", "zp", 3); _o(0xEC, "CPX", "abs", 4)
_o(0xC0, "CPY", "imm", 2); _o(0xC4, "CPY", "zp", 3); _o(0xCC, "CPY", "abs", 4)
_o(0x24, "BIT", "zp", 3); _o(0x2C, "BIT", "abs", 4)

for _n, _tbl in [
    ("ASL", [(0x0A, "acc", 2), (0x06, "zp", 5), (0x16, "zpx", 6),
             (0x0E, "abs", 6), (0x1E, "abx", 7)]),
    ("LSR", [(0x4A, "acc", 2), (0x46, "zp", 5), (0x56, "zpx", 6),
             (0x4E, "abs", 6), (0x5E, "abx", 7)]),
    ("ROL", [(0x2A, "acc", 2), (0x26, "zp", 5), (0x36, "zpx", 6),
             (0x2E, "abs", 6), (0x3E, "abx", 7)]),
    ("ROR", [(0x6A, "acc", 2), (0x66, "zp", 5), (0x76, "zpx", 6),
             (0x6E, "abs", 6), (0x7E, "abx", 7)]),
    ("INC", [(0xE6, "zp", 5), (0xF6, "zpx", 6), (0xEE, "abs", 6),
             (0xFE, "abx", 7)]),
    ("DEC", [(0xC6, "zp", 5), (0xD6, "zpx", 6), (0xCE, "abs", 6),
             (0xDE, "abx", 7)]),
    ("SLO", [(0x07, "zp", 5), (0x17, "zpx", 6), (0x0F, "abs", 6),
             (0x1F, "abx", 7), (0x1B, "aby", 7), (0x03, "izx", 8),
             (0x13, "izy", 8)]),
    ("RLA", [(0x27, "zp", 5), (0x37, "zpx", 6), (0x2F, "abs", 6),
             (0x3F, "abx", 7), (0x3B, "aby", 7), (0x23, "izx", 8),
             (0x33, "izy", 8)]),
    ("SRE", [(0x47, "zp", 5), (0x57, "zpx", 6), (0x4F, "abs", 6),
             (0x5F, "abx", 7), (0x5B, "aby", 7), (0x43, "izx", 8),
             (0x53, "izy", 8)]),
    ("RRA", [(0x67, "zp", 5), (0x77, "zpx", 6), (0x6F, "abs", 6),
             (0x7F, "abx", 7), (0x7B, "aby", 7), (0x63, "izx", 8),
             (0x73, "izy", 8)]),
    ("DCP", [(0xC7, "zp", 5), (0xD7, "zpx", 6), (0xCF, "abs", 6),
             (0xDF, "abx", 7), (0xDB, "aby", 7), (0xC3, "izx", 8),
             (0xD3, "izy", 8)]),
    ("ISC", [(0xE7, "zp", 5), (0xF7, "zpx", 6), (0xEF, "abs", 6),
             (0xFF, "abx", 7), (0xFB, "aby", 7), (0xE3, "izx", 8),
             (0xF3, "izy", 8)]),
]:
    for _c, _m, _cy in _tbl:
        _o(_c, _n, _m, _cy)

for _c, _n in [(0xAA, "TAX"), (0xA8, "TAY"), (0x8A, "TXA"), (0x98, "TYA"),
               (0xBA, "TSX"), (0x9A, "TXS"), (0xE8, "INX"), (0xC8, "INY"),
               (0xCA, "DEX"), (0x88, "DEY"), (0x18, "CLC"), (0x38, "SEC"),
               (0x58, "CLI"), (0x78, "SEI"), (0xB8, "CLV"), (0xD8, "CLD"),
               (0xF8, "SED"), (0xEA, "NOP")]:
    _o(_c, _n, "imp", 2)
_o(0x48, "PHA", "imp", 3); _o(0x08, "PHP", "imp", 3)
_o(0x68, "PLA", "imp", 4); _o(0x28, "PLP", "imp", 4)
_o(0x4C, "JMP", "abs", 3); _o(0x6C, "JMPI", "abs", 5)
_o(0x20, "JSR", "abs", 6); _o(0x60, "RTS", "imp", 6)
_o(0x40, "RTI", "imp", 6); _o(0x00, "BRK", "imp", 7)
for _c, _n in [(0x10, "BPL"), (0x30, "BMI"), (0x50, "BVC"), (0x70, "BVS"),
               (0x90, "BCC"), (0xB0, "BCS"), (0xD0, "BNE"), (0xF0, "BEQ")]:
    _o(_c, _n, "rel", 2)
_o(0x0B, "ANC", "imm", 2); _o(0x2B, "ANC", "imm", 2)
_o(0x4B, "ALR", "imm", 2); _o(0x6B, "ARR", "imm", 2)
_o(0xCB, "SBX", "imm", 2)
# Undocumented NOPs, which players do hit.
for _c in (0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA):
    _o(_c, "NOP", "imp", 2)
for _c in (0x80, 0x82, 0x89, 0xC2, 0xE2):
    _o(_c, "NOP", "imm", 2)
for _c in (0x04, 0x44, 0x64):
    _o(_c, "NOP", "zp", 3)
for _c in (0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4):
    _o(_c, "NOP", "zpx", 4)
_o(0x0C, "NOP", "abs", 4)
for _c in (0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC):
    _o(_c, "NOP", "abx", 4, True)


def _step(self):
    op = self._fetch()
    ent = OPS.get(op)
    if ent is None:
        self.jammed = True
        self.cycles += 2
        return
    name, mode, cyc, pen = ent
    addr, cross = self._am(mode)
    self.cycles += cyc + (cross if pen else 0)

    if name == "LDA":
        self.a = self._setzn(self._rd(addr))
    elif name == "LDX":
        self.x = self._setzn(self._rd(addr))
    elif name == "LDY":
        self.y = self._setzn(self._rd(addr))
    elif name == "LAX":
        self.a = self.x = self._setzn(self._rd(addr))
    elif name == "STA":
        self._wr(addr, self.a)
    elif name == "STX":
        self._wr(addr, self.x)
    elif name == "STY":
        self._wr(addr, self.y)
    elif name == "SAX":
        self._wr(addr, self.a & self.x)
    elif name == "ADC":
        self._adc(self._rd(addr))
    elif name == "SBC":
        self._sbc(self._rd(addr))
    elif name == "AND":
        self.a = self._setzn(self.a & self._rd(addr))
    elif name == "ORA":
        self.a = self._setzn(self.a | self._rd(addr))
    elif name == "EOR":
        self.a = self._setzn(self.a ^ self._rd(addr))
    elif name == "CMP":
        self._cmp(self.a, self._rd(addr))
    elif name == "CPX":
        self._cmp(self.x, self._rd(addr))
    elif name == "CPY":
        self._cmp(self.y, self._rd(addr))
    elif name == "BIT":
        m = self._rd(addr)
        self.p = (self.p & ~(Z | N | V)) | (Z if (self.a & m) == 0 else 0) \
            | (m & (N | V))
    elif name in ("ASL", "LSR", "ROL", "ROR"):
        v = self.a if mode == "acc" else self._rd(addr)
        if name == "ASL":
            self.p = (self.p & ~C) | (1 if v & 0x80 else 0)
            v = (v << 1) & 0xFF
        elif name == "LSR":
            self.p = (self.p & ~C) | (v & 1)
            v >>= 1
        elif name == "ROL":
            nc = 1 if v & 0x80 else 0
            v = ((v << 1) | (self.p & C)) & 0xFF
            self.p = (self.p & ~C) | nc
        else:
            nc = v & 1
            v = (v >> 1) | ((self.p & C) << 7)
            self.p = (self.p & ~C) | nc
        v = self._setzn(v)
        if mode == "acc":
            self.a = v
        else:
            self._wr(addr, v)
    elif name == "INC":
        self._wr(addr, self._setzn(self._rd(addr) + 1))
    elif name == "DEC":
        self._wr(addr, self._setzn(self._rd(addr) - 1))
    elif name in ("SLO", "RLA", "SRE", "RRA", "DCP", "ISC"):
        v = self._rd(addr)
        if name == "SLO":
            self.p = (self.p & ~C) | (1 if v & 0x80 else 0)
            v = (v << 1) & 0xFF
            self._wr(addr, v)
            self.a = self._setzn(self.a | v)
        elif name == "RLA":
            nc = 1 if v & 0x80 else 0
            v = ((v << 1) | (self.p & C)) & 0xFF
            self.p = (self.p & ~C) | nc
            self._wr(addr, v)
            self.a = self._setzn(self.a & v)
        elif name == "SRE":
            self.p = (self.p & ~C) | (v & 1)
            v >>= 1
            self._wr(addr, v)
            self.a = self._setzn(self.a ^ v)
        elif name == "RRA":
            nc = v & 1
            v = (v >> 1) | ((self.p & C) << 7)
            self.p = (self.p & ~C) | nc
            self._wr(addr, v)
            self._adc(v)
        elif name == "DCP":
            v = (v - 1) & 0xFF
            self._wr(addr, v)
            self._cmp(self.a, v)
        else:
            v = (v + 1) & 0xFF
            self._wr(addr, v)
            self._sbc(v)
    elif name == "TAX":
        self.x = self._setzn(self.a)
    elif name == "TAY":
        self.y = self._setzn(self.a)
    elif name == "TXA":
        self.a = self._setzn(self.x)
    elif name == "TYA":
        self.a = self._setzn(self.y)
    elif name == "TSX":
        self.x = self._setzn(self.sp)
    elif name == "TXS":
        self.sp = self.x
    elif name == "INX":
        self.x = self._setzn(self.x + 1)
    elif name == "INY":
        self.y = self._setzn(self.y + 1)
    elif name == "DEX":
        self.x = self._setzn(self.x - 1)
    elif name == "DEY":
        self.y = self._setzn(self.y - 1)
    elif name == "CLC":
        self.p &= ~C
    elif name == "SEC":
        self.p |= C
    elif name == "CLI":
        self.p &= ~I
    elif name == "SEI":
        self.p |= I
    elif name == "CLV":
        self.p &= ~V
    elif name == "CLD":
        self.p &= ~D
    elif name == "SED":
        self.p |= D
    elif name == "PHA":
        self._push(self.a)
    elif name == "PHP":
        self._push(self.p | U | B)
    elif name == "PLA":
        self.a = self._setzn(self._pop())
    elif name == "PLP":
        self.p = (self._pop() | U) & ~B
    elif name == "JMP":
        self.pc = addr
    elif name == "JMPI":
        self.pc = self._rd16_bug(addr)
    elif name == "JSR":
        r = (self.pc - 1) & 0xFFFF
        self._push((r >> 8) & 0xFF)
        self._push(r & 0xFF)
        self.pc = addr
    elif name == "RTS":
        self.pc = (self._pop() | (self._pop() << 8)) + 1 & 0xFFFF
    elif name == "RTI":
        self.p = (self._pop() | U) & ~B
        self.pc = self._pop() | (self._pop() << 8)
    elif name == "BRK":
        self.pc = (self.pc + 1) & 0xFFFF
        self._push((self.pc >> 8) & 0xFF)
        self._push(self.pc & 0xFF)
        self._push(self.p | U | B)
        self.p |= I
        self.pc = self._rd16(0xFFFE)
    elif name == "BPL":
        self._branch(addr, not (self.p & N))
    elif name == "BMI":
        self._branch(addr, bool(self.p & N))
    elif name == "BVC":
        self._branch(addr, not (self.p & V))
    elif name == "BVS":
        self._branch(addr, bool(self.p & V))
    elif name == "BCC":
        self._branch(addr, not (self.p & C))
    elif name == "BCS":
        self._branch(addr, bool(self.p & C))
    elif name == "BNE":
        self._branch(addr, not (self.p & Z))
    elif name == "BEQ":
        self._branch(addr, bool(self.p & Z))
    elif name == "ANC":
        self.a = self._setzn(self.a & self._rd(addr))
        self.p = (self.p & ~C) | (1 if self.a & 0x80 else 0)
    elif name == "ALR":
        self.a &= self._rd(addr)
        self.p = (self.p & ~C) | (self.a & 1)
        self.a = self._setzn(self.a >> 1)
    elif name == "ARR":
        self.a &= self._rd(addr)
        self.a = (self.a >> 1) | ((self.p & C) << 7)
        self._setzn(self.a)
        self.p = (self.p & ~(C | V)) | (1 if self.a & 0x40 else 0) \
            | (V if ((self.a >> 6) ^ (self.a >> 5)) & 1 else 0)
    elif name == "SBX":
        v = (self.a & self.x) - self._rd(addr)
        self.p = (self.p & ~C) | (1 if (v & 0x100) == 0 else 0)
        self.x = self._setzn(v & 0xFF)
    elif name == "NOP":
        pass
    else:
        self.jammed = True


CPU.step = _step
