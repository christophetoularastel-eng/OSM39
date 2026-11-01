#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
emu6809.py - Emulateur 6809 complet + stubs BIOS OSM09.

But : exécuter le binaire ASM (l'assembleur OSM09 assemblé par lwasm) en
"machine hôte", sur les fichiers de test, pour valider le code produit
avant chargement sur la vraie machine.

Usage :
    python3 emu6809.py ASM test/test_dir.asm /tmp/out.bin
    python3 emu6809.py --selftest
    python3 emu6809.py --dis <fichier.bin> <org>

Conventions 6809 (vérifiées contre lwasm 4.24, voir test*.asm/.bin/.lst) :
  - Codes TFR/EXG : D=0 A=8 B=9 CC=A DP=B X=1 Y=2 U=3 S=4 PC=5
  - Masques PSHS/PULS : CC=01 A=02 B=04 DP=08 X=10 Y=20 U/S=40 PC=80
  - Postbyte indexé : bit7=1 forme spéciale ; sinon 5 bits décalage signé ;
    bit4 (0x10) = indirect sur les formes spéciales.
"""

import sys

# ----------------------------------------------------------------------
# Constantes matérielles OSM09 (simulation)
# ----------------------------------------------------------------------
VEC_TABLE    = 0xC000     # table_function_ram
FORMAT_NAME  = 0xC402     # buffer 15+ octets
ARGV         = 0xC42C     # tableau de pointeurs
ARGC         = 0xC440     # nombre d'arguments
HEAP_START   = 0xC900     # heap (même layout que bios/vectors.asm)
HEAP_SIZE    = 0x0700
HEAP_END     = HEAP_START + HEAP_SIZE
STUB_BASE    = 0xE000     # adresses des stubs BIOS (simule l'EPROM)
STUB_GAP     = 16
STUB_COUNT   = 61         # services 0..60 (sys_* = 2 octets dans la table)
EXIT_MARKER  = 0xFFFF     # adresse de retour "fin de programme"

# Drapeaux CC 6809
CC_C  = 0x01
CC_V  = 0x02
CC_Z  = 0x04
CC_N  = 0x08
CC_I  = 0x10
CC_H  = 0x20
CC_F  = 0x40
CC_E  = 0x80

# Offsets sys_* (bios/sysfunc.inc)
SYS_INKEY            = 0
SYS_SCAN_KEYBOARD    = 2
SYS_READ_LINE        = 4
SYS_PRINTCHAR        = 6
SYS_PRINTSTRING      = 8
SYS_PRINTHEXCHAR     = 10
SYS_PRINTHEXWORD     = 12
SYS_PRINTCRLF        = 14
SYS_PRINTFILENAME83  = 16
SYS_FS_MOUNT         = 18
SYS_FS_FINDFIRST     = 20
SYS_FS_FINDNEXT      = 22
SYS_FS_GETNEXTCLUSTER= 24
SYS_FS_LOADFILE      = 26
SYS_FS_FINDENTRY     = 28
SYS_FS_LISTROOT      = 30
SYS_FS_SAVEFILE      = 32
SYS_REG_CMD          = 34
SYS_FS_CLUSTERTO_OFF = 36
SYS_FORMAT_FILENAME83= 38
SYS_STRCPY           = 40
SYS_STRLEN           = 42
SYS_PAGER            = 44
SYS_MEMCPY_32        = 46
SYS_LOADANDEXEC      = 48
SYS_LS               = 50
SYS_MALLOC_SYS       = 52
SYS_FREE             = 54
SYS_FS_DELETEFILE    = 56
SYS_FS_GETATTR       = 58
SYS_FS_SETATTR       = 60

# ----------------------------------------------------------------------
class CPU6809Error(Exception):
    pass

class TrapError(CPU6809Error):
    pass

# ----------------------------------------------------------------------
# CPU 6809
# ----------------------------------------------------------------------
class CPU6809:
    def __init__(self):
        self.mem = bytearray(65536)
        self.reset()

    def reset(self):
        self.a = 0
        self.b = 0
        self.dp = 0
        self.x = 0
        self.y = 0
        self.u = 0
        self.s = 0
        self.pc = 0
        self.cc = CC_I | CC_F          # interruptions masquées
        self.halted = False
        self.halt_reason = ""
        self.steps = 0
        self.max_steps = 500_000_000

    # ----- accès mémoire -----
    def rd8(self, a):
        return self.mem[a & 0xFFFF]

    def wr8(self, a, v):
        self.mem[a & 0xFFFF] = v & 0xFF

    def rd16(self, a):
        a &= 0xFFFF
        return (self.mem[a] << 8) | self.mem[(a + 1) & 0xFFFF]

    def wr16(self, a, v):
        a &= 0xFFFF
        v &= 0xFFFF
        self.mem[a] = v >> 8
        self.mem[(a + 1) & 0xFFFF] = v & 0xFF

    def fet8(self):
        b = self.mem[self.pc & 0xFFFF]
        self.pc = (self.pc + 1) & 0xFFFF
        return b

    def fet16(self):
        w = self.rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        return w

    def push8(self, v):
        self.s = (self.s - 1) & 0xFFFF
        self.wr8(self.s, v & 0xFF)

    def push16(self, v):
        self.push8(v & 0xFF)
        self.push8(v >> 8)

    def pull8(self):
        v = self.rd8(self.s & 0xFFFF)
        self.s = (self.s + 1) & 0xFFFF
        return v

    def pull16(self):
        hi = self.pull8()
        lo = self.pull8()
        return (hi << 8) | lo

    # ----- drapeaux -----
    def setnz8(self, v):
        v &= 0xFF
        self.cc &= ~(CC_N | CC_Z)
        if v & 0x80:
            self.cc |= CC_N
        if v == 0:
            self.cc |= CC_Z

    def setnz16(self, v):
        v &= 0xFFFF
        self.cc &= ~(CC_N | CC_Z)
        if v & 0x8000:
            self.cc |= CC_N
        if v == 0:
            self.cc |= CC_Z

    def add8(self, a, b):
        r = a + b
        h = (a ^ b ^ r) & 0x10
        c = r & 0x100
        r &= 0xFF
        v = (~(a ^ b) & (a ^ r)) & 0x80
        self.cc &= ~(CC_H | CC_N | CC_Z | CC_V | CC_C)
        if h:
            self.cc |= CC_H
        if v:
            self.cc |= CC_V
        if c:
            self.cc |= CC_C
        self.setnz8(r)
        return r

    def adc8(self, a, b):
        c = self.cc & CC_C
        r = a + b + c
        h = (a ^ b ^ r) & 0x10
        cn = r & 0x100
        r &= 0xFF
        v = (~(a ^ b) & (a ^ r)) & 0x80
        self.cc &= ~(CC_H | CC_N | CC_Z | CC_V | CC_C)
        if h:
            self.cc |= CC_H
        if v:
            self.cc |= CC_V
        if cn:
            self.cc |= CC_C
        self.setnz8(r)
        return r

    def sub8(self, a, b):
        r = a - b
        c = r & 0x100
        r &= 0xFF
        v = ((a ^ b) & (a ^ r)) & 0x80
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if v:
            self.cc |= CC_V
        if c:
            self.cc |= CC_C
        self.setnz8(r)
        return r

    def sbc8(self, a, b):
        c = self.cc & CC_C
        r = a - b - c
        cn = r & 0x100
        r &= 0xFF
        v = ((a ^ b) & (a ^ r)) & 0x80
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if v:
            self.cc |= CC_V
        if cn:
            self.cc |= CC_C
        self.setnz8(r)
        return r

    def add16(self, a, b):
        # ADDD : N Z V C ; H n'est pas touché (6809)
        r = a + b
        c = r & 0x10000
        r &= 0xFFFF
        v = (~(a ^ b) & (a ^ r)) & 0x8000
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if v:
            self.cc |= CC_V
        if c:
            self.cc |= CC_C
        self.setnz16(r)
        return r

    def sub16(self, a, b):
        r = a - b
        c = r & 0x10000
        r &= 0xFFFF
        v = ((a ^ b) & (a ^ r)) & 0x8000
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if v:
            self.cc |= CC_V
        if c:
            self.cc |= CC_C
        self.setnz16(r)
        return r

    def neg8(self, a):
        r = (0 - a) & 0xFF
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if a != 0:
            self.cc |= CC_C
        if a == 0x80:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def com8(self, a):
        r = a ^ 0xFF
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        self.cc |= CC_C
        self.setnz8(r)
        return r

    def lsr8(self, a):
        c = a & 1
        r = a >> 1
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if c:
            self.cc |= CC_C | CC_V      # V = N xor C, N = 0
        self.setnz8(r)
        return r

    def asr8(self, a):
        c = a & 1
        r = (a >> 1) | (a & 0x80)
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if c:
            self.cc |= CC_C
        n = r & 0x80
        if (n >> 7) ^ c:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def asl8(self, a):
        c = (a >> 7) & 1
        r = (a << 1) & 0xFF
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if c:
            self.cc |= CC_C
        n = r & 0x80
        if (n >> 7) ^ c:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def rol8(self, a):
        oc = self.cc & CC_C
        c = (a >> 7) & 1
        r = ((a << 1) & 0xFF) | oc
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if c:
            self.cc |= CC_C
        n = r & 0x80
        if (n >> 7) ^ c:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def ror8(self, a):
        oc = self.cc & CC_C
        c = a & 1
        r = (a >> 1) | (oc << 7)
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        if c:
            self.cc |= CC_C
        n = r & 0x80
        if (n >> 7) ^ c:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def inc8(self, a):
        r = (a + 1) & 0xFF
        self.cc &= ~(CC_N | CC_Z | CC_V)
        if a == 0x7F:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def dec8(self, a):
        r = (a - 1) & 0xFF
        self.cc &= ~(CC_N | CC_Z | CC_V)
        if a == 0x80:
            self.cc |= CC_V
        self.setnz8(r)
        return r

    def tst8(self, a):
        self.cc &= ~(CC_N | CC_Z | CC_V)
        self.setnz8(a)
        return a

    def clr8(self):
        self.cc &= ~(CC_N | CC_Z | CC_V | CC_C)
        self.cc |= CC_Z
        return 0

    def daa(self):
        a = self.a
        oldc = self.cc & CC_C
        oldh = self.cc & CC_H
        if (a & 0x0F) > 9 or oldh:
            a += 0x06
        if a > 0x99 or oldc:
            a += 0x60
            c = 1
        else:
            c = 0
        a &= 0xFF
        self.a = a
        self.cc = (self.cc & (CC_F | CC_E | CC_I)) | (CC_C if c else 0)
        self.cc &= ~CC_V
        self.setnz8(a)
        return a

    def sex(self):
        if self.b & 0x80:
            self.a = 0xFF
        else:
            self.a = 0
        d = (self.a << 8) | self.b
        self.cc &= ~CC_V
        self.setnz16(d)

    def mul(self):
        d = self.a * self.b
        self.a = (d >> 8) & 0xFF
        self.b = d & 0xFF
        if d == 0:
            self.cc |= CC_Z
        else:
            self.cc &= ~CC_Z
        if d & 0x80:
            self.cc |= CC_C
        else:
            self.cc &= ~CC_C

    # ----- registres TFR/EXG -----
    def getreg(self, code):
        code &= 0x0F
        if code == 0:
            return (self.a << 8) | self.b
        if code == 1:
            return self.x
        if code == 2:
            return self.y
        if code == 3:
            return self.u
        if code == 4:
            return self.s
        if code == 5:
            return self.pc
        if code == 8:
            return self.a
        if code == 9:
            return self.b
        if code == 0xA:
            return self.cc
        if code == 0xB:
            return self.dp
        # registre non défini : sur un 6809 réel, TFR/EXG lisent $FF
        return 0xFFFF

    def setreg(self, code, v):
        v &= 0xFFFF
        code &= 0x0F
        if code == 0:
            self.a = v >> 8
            self.b = v & 0xFF
        elif code == 1:
            self.x = v
        elif code == 2:
            self.y = v
        elif code == 3:
            self.u = v
        elif code == 4:
            self.s = v
        elif code == 5:
            self.pc = v
        elif code == 8:
            self.a = v & 0xFF
        elif code == 9:
            self.b = v & 0xFF
        elif code == 0xA:
            self.cc = v & 0xFF
        elif code == 0xB:
            self.dp = v & 0xFF
        # registre non défini : écriture ignorée (comportement 6809 réel)

    def tfr(self, byte):
        src = byte >> 4
        dst = byte & 0x0F
        self.setreg(dst, self.getreg(src))

    def exg(self, byte):
        r1 = byte >> 4
        r2 = byte & 0x0F
        v1 = self.getreg(r1)
        v2 = self.getreg(r2)
        self.setreg(r1, v2)
        self.setreg(r2, v1)

    # ----- push/pull -----
    def push_mask(self, m, is_pul, which):
        # which : 0 = PSHS/PULS, 1 = PSHU/PULU
        order = [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]
        vals = {}
        if m & 0x80:
            vals[0x80] = self.pc
        if m & 0x40:
            vals[0x40] = self.s if which else self.u   # PSHS/U poussent l'autre
        if m & 0x20:
            vals[0x20] = self.y
        if m & 0x10:
            vals[0x10] = self.x
        if m & 0x08:
            vals[0x08] = self.dp
        if m & 0x04:
            vals[0x04] = self.b
        if m & 0x02:
            vals[0x02] = self.a
        if m & 0x01:
            vals[0x01] = self.cc
        if not is_pul:
            sp = self.s if not which else self.u
            for bit in order:
                if m & bit:
                    if bit in (0x80, 0x40, 0x20, 0x10):   # registres 16 bits (MSB d'abord)
                        sp = (sp - 1) & 0xFFFF
                        self.wr8(sp, vals[bit] & 0xFF)
                        sp = (sp - 1) & 0xFFFF
                        self.wr8(sp, (vals[bit] >> 8) & 0xFF)
                    else:                                 # registres 8 bits
                        sp = (sp - 1) & 0xFFFF
                        self.wr8(sp, vals[bit] & 0xFF)
            if which:
                self.u = sp
            else:
                self.s = sp
        else:
            sp = self.s if not which else self.u
            for bit in reversed(order):
                if m & bit:
                    if bit in (0x80, 0x40, 0x20, 0x10):   # registres 16 bits (MSB d'abord)
                        hi = self.rd8(sp & 0xFFFF)
                        sp = (sp + 1) & 0xFFFF
                        lo = self.rd8(sp & 0xFFFF)
                        sp = (sp + 1) & 0xFFFF
                        v = (hi << 8) | lo
                    else:
                        v = self.rd8(sp & 0xFFFF)
                        sp = (sp + 1) & 0xFFFF
                    if bit == 0x80:
                        self.pc = v
                    elif bit == 0x40:
                        if which:
                            self.s = v
                        else:
                            self.u = v
                    elif bit == 0x20:
                        self.y = v
                    elif bit == 0x10:
                        self.x = v
                    elif bit == 0x08:
                        self.dp = v
                    elif bit == 0x04:
                        self.b = v
                    elif bit == 0x02:
                        self.a = v
                    elif bit == 0x01:
                        self.cc = v
            if which:
                self.u = sp
            else:
                self.s = sp

    # ----- adressage indexé -----
    def indexed_ea(self, pb):
        reg = (pb >> 5) & 3
        rname = (self.x, self.y, self.u, self.s)[reg]
        upd = None
        if not (pb & 0x80):
            off = pb & 0x1F
            if off & 0x10:
                off -= 0x20
            return (rname + off) & 0xFFFF, None, False
        m = pb & 0x0F
        ind = bool(pb & 0x10)
        if m == 0x00:
            return rname, ('post', 1, reg), ind
        if m == 0x01:
            return rname, ('post', 2, reg), ind
        if m == 0x02:
            ea = (rname - 1) & 0xFFFF
            return ea, ('pre', 1, reg), ind
        if m == 0x03:
            ea = (rname - 2) & 0xFFFF
            return ea, ('pre', 2, reg), ind
        if m == 0x04:
            return rname, None, ind
        if m == 0x05:                       # B,R : déplacement SIGNÉ
            return (rname + (self.b - 0x100 if self.b & 0x80 else self.b)) & 0xFFFF, None, ind
        if m == 0x06:                       # A,R : déplacement SIGNÉ
            return (rname + (self.a - 0x100 if self.a & 0x80 else self.a)) & 0xFFFF, None, ind
        if m == 0x0B:
            return (rname + ((self.a << 8) | self.b)) & 0xFFFF, None, ind
        if m == 0x08:
            off = self.fet8()
            if off & 0x80:
                off -= 0x100
            return (rname + off) & 0xFFFF, None, ind
        if m == 0x09:
            off = self.fet16()
            if off & 0x8000:
                off -= 0x10000
            return (rname + off) & 0xFFFF, None, ind
        if m == 0x0C:                       # n8,PCR
            off = self.fet8()
            if off & 0x80:
                off -= 0x100
            return (self.pc + off) & 0xFFFF, None, False
        if m == 0x0D:                       # n16,PCR
            off = self.fet16()
            if off & 0x8000:
                off -= 0x10000
            return (self.pc + off) & 0xFFFF, None, False
        if m == 0x0E:                       # [n16,PCR]
            off = self.fet16()
            if off & 0x8000:
                off -= 0x10000
            return (self.pc + off) & 0xFFFF, None, True
        if m == 0x0F:                       # [adresse] étendu indirect
            addr = self.fet16()
            return addr, None, True
        raise CPU6809Error("postbyte indexé non supporté $%02X" % pb)

    def apply_update(self, upd):
        if not upd:
            return
        kind, n, reg = upd
        cur = (self.x, self.y, self.u, self.s)[reg]
        if kind == 'post':
            cur = (cur + n) & 0xFFFF
        else:
            cur = (cur - n) & 0xFFFF
        if reg == 0:
            self.x = cur
        elif reg == 1:
            self.y = cur
        elif reg == 2:
            self.u = cur
        else:
            self.s = cur

    def eff_ea(self):
        # lecture postbyte puis calcul de l'adresse effective (avec indirect)
        pb = self.fet8()
        ea, upd, ind = self.indexed_ea(pb)
        self.apply_update(upd)
        if ind:
            ea = self.rd16(ea)
        return ea

    # ----- branches -----
    def cond(self, op):
        c = self.cc & CC_C
        v = self.cc & CC_V
        z = self.cc & CC_Z
        n = self.cc & CC_N
        nv = bool(n) ^ bool(v)
        op &= 0x0F
        if op == 0x0:   # BRA / LBRA (inconditionnel)
            return True
        if op == 0x1:   # BRN
            return False
        if op == 0x2:   # BHI
            return not c and not z
        if op == 0x3:   # BLS
            return c or z
        if op == 0x4:   # BCC
            return not c
        if op == 0x5:   # BCS
            return c
        if op == 0x6:   # BNE
            return not z
        if op == 0x7:   # BEQ
            return z
        if op == 0x8:   # BVC
            return not v
        if op == 0x9:   # BVS
            return v
        if op == 0xA:   # BPL
            return not n
        if op == 0xB:   # BMI
            return n
        if op == 0xC:   # BGE
            return not nv
        if op == 0xD:   # BLT
            return nv
        if op == 0xE:   # BGT
            return not z and not nv
        if op == 0xF:   # BLE
            return z or nv
        return False

    # ----- 8 bits ALU sur accumulateur (A ou B) -----
    def alu_mem8(self, op, isA):
        cls = (op >> 4) & 0xF      # A: 8=imm 9=dir A=idx B=ext ; B: C=imm D=dir E=idx F=ext
        mode = cls & 3             # 0=imm 1=dir 2=idx 3=ext (valable A et B)
        sub = op & 0xF
        reg = self.a if isA else self.b
        if mode == 0:              # immédiat 8 bits (pas de store)
            val = self.fet8()
            if sub == 0:
                r = self.sub8(reg, val)
            elif sub == 1:
                self.sub8(reg, val)
                return
            elif sub == 2:
                r = self.sbc8(reg, val)
            elif sub == 4:
                r = reg & val
                self.cc &= ~CC_V
                self.setnz8(r)
            elif sub == 5:
                r = reg & val
                self.cc &= ~CC_V
                self.setnz8(r)
                return
            elif sub == 6:
                r = val
                self.cc &= ~CC_V
                self.setnz8(r)
            elif sub == 8:
                r = reg ^ val
                self.cc &= ~CC_V
                self.setnz8(r)
            elif sub == 9:
                r = self.adc8(reg, val)
            elif sub == 0xA:
                r = reg | val
                self.cc &= ~CC_V
                self.setnz8(r)
            elif sub == 0xB:
                r = self.add8(reg, val)
            else:
                raise CPU6809Error("op imm 8 invalide $%02X" % op)
            if isA:
                self.a = r
            else:
                self.b = r
            return
        # direct / indexé / étendu
        if mode == 1:
            ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
        elif mode == 2:
            ea = self.eff_ea()
        else:
            ea = self.fet16()
        val = self.rd8(ea)
        if sub == 0:
            r = self.sub8(reg, val)
        elif sub == 1:
            self.sub8(reg, val)
            return
        elif sub == 2:
            r = self.sbc8(reg, val)
        elif sub == 3:      # SUBD / ADDD 16 bits
            val16 = self.rd16(ea)
            if isA:         # 0x93/0xA3/0xB3 = SUBD
                r = self.sub16((self.a << 8) | self.b, val16)
                self.a = r >> 8
                self.b = r & 0xFF
            else:           # 0xD3/0xE3/0xF3 = ADDD
                r = self.add16((self.a << 8) | self.b, val16)
                self.a = r >> 8
                self.b = r & 0xFF
            return
        elif sub == 4:
            r = reg & val
            self.cc &= ~CC_V
            self.setnz8(r)
        elif sub == 5:
            r = reg & val
            self.cc &= ~CC_V
            self.setnz8(r)
            return
        elif sub == 6:
            r = val
            self.cc &= ~CC_V
            self.setnz8(r)
        elif sub == 7:      # STORE
            self.wr8(ea, reg)
            self.cc &= ~CC_V
            self.setnz8(reg)
            return
        elif sub == 8:
            r = reg ^ val
            self.cc &= ~CC_V
            self.setnz8(r)
        elif sub == 9:
            r = self.adc8(reg, val)
        elif sub == 0xA:
            r = reg | val
            self.cc &= ~CC_V
            self.setnz8(r)
        elif sub == 0xB:
            r = self.add8(reg, val)
        else:
            raise CPU6809Error("op mémoire invalide $%02X" % op)
        if isA:
            self.a = r
        else:
            self.b = r

    # ----- opérations mémoire 8 bits / JMP -----
    def memop8(self, op):
        cls = (op >> 4) & 0xF      # 0=dir 6=indexé 7=étendu
        sub = op & 0xF
        if cls == 0:
            ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
            if sub == 0xE:      # JMP direct
                self.pc = ea
                return
        elif cls == 6:
            if sub == 0xE:
                ea = self.eff_ea()
                self.pc = ea
                return
            ea = self.eff_ea()
        else:
            if sub == 0xE:
                self.pc = self.fet16()
                return
            ea = self.fet16()
        val = self.rd8(ea)
        if sub == 0x0:
            r = self.neg8(val)
        elif sub == 0x3:
            r = self.com8(val)
        elif sub == 0x4:
            r = self.lsr8(val)
        elif sub == 0x6:
            r = self.ror8(val)
        elif sub == 0x7:
            r = self.asr8(val)
        elif sub == 0x8:
            r = self.asl8(val)
        elif sub == 0x9:
            r = self.rol8(val)
        elif sub == 0xA:
            r = self.dec8(val)
        elif sub == 0xC:
            r = self.inc8(val)
        elif sub == 0xD:
            self.tst8(val)
            return
        elif sub == 0xF:
            r = self.clr8()
        else:
            raise CPU6809Error("memop8 invalide $%02X" % op)
        self.wr8(ea, r)

    # ----- exécution d'un octet d'opcode -----
    def execute(self, op):
        self.steps += 1
        if self.steps > self.max_steps:
            self.halted = True
            self.halt_reason = "limite d'instructions dépassée"
            return
        # A-block (accumulateur A / registres X)
        if 0x80 <= op <= 0xBF:
            if op == 0x83:      # SUBD #
                v = self.fet16()
                r = self.sub16((self.a << 8) | self.b, v)
                self.a = r >> 8
                self.b = r & 0xFF
            elif op == 0x8C:
                v = self.fet16()
                self.sub16(self.x, v)
            elif op == 0x8D:    # BSR : retour APRÈS le déplacement
                off = self.fet8()
                if off & 0x80:
                    off -= 0x100
                self.push16(self.pc)
                self.pc = (self.pc + off) & 0xFFFF
            elif op == 0x8E:
                self.x = self.fet16()
                self.cc &= ~CC_V
                self.setnz16(self.x)
            elif op == 0x9C:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                v = self.rd16(ea)
                self.sub16(self.x, v)
            elif op == 0x9D:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.push16(self.pc)
                self.pc = ea
            elif op == 0x9E:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.x = self.rd16(ea)
                self.cc &= ~CC_V
                self.setnz16(self.x)
            elif op == 0x9F:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.wr16(ea, self.x)
                self.cc &= ~CC_V
                self.setnz16(self.x)
            elif op == 0xAC:
                v = self.rd16(self.eff_ea())
                self.sub16(self.x, v)
            elif op == 0xAD:
                ea = self.eff_ea()
                self.push16(self.pc)
                self.pc = ea
            elif op == 0xAE:
                self.x = self.rd16(self.eff_ea())
                self.cc &= ~CC_V
                self.setnz16(self.x)
            elif op == 0xAF:
                ea = self.eff_ea()
                self.wr16(ea, self.x)
                self.cc &= ~CC_V
                self.setnz16(self.x)
            elif op == 0xBC:
                v = self.rd16(self.fet16())
                self.sub16(self.x, v)
            elif op == 0xBD:
                ea = self.fet16()
                self.push16(self.pc)
                self.pc = ea
            elif op == 0xBE:
                self.x = self.rd16(self.fet16())
                self.cc &= ~CC_V
                self.setnz16(self.x)
            elif op == 0xBF:
                ea = self.fet16()
                self.wr16(ea, self.x)
                self.cc &= ~CC_V
                self.setnz16(self.x)
            else:
                self.alu_mem8(op, True)
            return

        # B-block (accumulateur B / registres U,D)
        if 0xC0 <= op <= 0xFF:
            if op == 0xC3:
                v = self.fet16()
                r = self.add16((self.a << 8) | self.b, v)
                self.a = r >> 8
                self.b = r & 0xFF
            elif op == 0xCC:
                v = self.fet16()
                self.a = v >> 8
                self.b = v & 0xFF
                self.cc &= ~CC_V
                self.setnz16(v)
            elif op == 0xCE:
                self.u = self.fet16()
                self.cc &= ~CC_V
                self.setnz16(self.u)
            elif op == 0xDC:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                v = self.rd16(ea)
                self.a = v >> 8
                self.b = v & 0xFF
                self.cc &= ~CC_V
                self.setnz16(v)
            elif op == 0xDD:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.wr16(ea, (self.a << 8) | self.b)
                self.cc &= ~CC_V
                self.setnz16((self.a << 8) | self.b)
            elif op == 0xDE:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.u = self.rd16(ea)
                self.cc &= ~CC_V
                self.setnz16(self.u)
            elif op == 0xDF:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.wr16(ea, self.u)
                self.cc &= ~CC_V
                self.setnz16(self.u)
            elif op == 0xEC:
                v = self.rd16(self.eff_ea())
                self.a = v >> 8
                self.b = v & 0xFF
                self.cc &= ~CC_V
                self.setnz16(v)
            elif op == 0xED:
                ea = self.eff_ea()
                self.wr16(ea, (self.a << 8) | self.b)
                self.cc &= ~CC_V
                self.setnz16((self.a << 8) | self.b)
            elif op == 0xEE:
                self.u = self.rd16(self.eff_ea())
                self.cc &= ~CC_V
                self.setnz16(self.u)
            elif op == 0xEF:
                ea = self.eff_ea()
                self.wr16(ea, self.u)
                self.cc &= ~CC_V
                self.setnz16(self.u)
            elif op == 0xFC:
                v = self.rd16(self.fet16())
                self.a = v >> 8
                self.b = v & 0xFF
                self.cc &= ~CC_V
                self.setnz16(v)
            elif op == 0xFD:
                ea = self.fet16()
                self.wr16(ea, (self.a << 8) | self.b)
                self.cc &= ~CC_V
                self.setnz16((self.a << 8) | self.b)
            elif op == 0xFE:
                self.u = self.rd16(self.fet16())
                self.cc &= ~CC_V
                self.setnz16(self.u)
            elif op == 0xFF:
                ea = self.fet16()
                self.wr16(ea, self.u)
                self.cc &= ~CC_V
                self.setnz16(self.u)
            else:
                self.alu_mem8(op, False)
            return

        # Branches courtes / longs
        if 0x20 <= op <= 0x2F:
            if self.cond(op & 0x0F):
                off = self.fet8()
                if off & 0x80:
                    off -= 0x100
                self.pc = (self.pc + off) & 0xFFFF
            else:
                self.fet8()
            return
        if op == 0x16:      # LBRA
            off = self.fet16()
            if off & 0x8000:
                off -= 0x10000
            self.pc = (self.pc + off) & 0xFFFF
            return
        if op == 0x17:      # LBSR : retour APRÈS le déplacement
            off = self.fet16()
            if off & 0x8000:
                off -= 0x10000
            self.push16(self.pc)
            self.pc = (self.pc + off) & 0xFFFF
            return

        # LEA
        if 0x30 <= op <= 0x33:
            ea = self.eff_ea()
            if op == 0x30:
                self.x = ea
                self.cc &= ~CC_V
                self.setnz16(ea)
            elif op == 0x31:
                self.y = ea
                self.cc &= ~CC_V
                self.setnz16(ea)
            elif op == 0x32:
                self.s = ea
            else:
                self.u = ea
            return

        # PSHS/PULS/PSHU/PULU
        if 0x34 <= op <= 0x37:
            m = self.fet8()
            if op == 0x34:
                self.push_mask(m, False, 0)
            elif op == 0x35:
                self.push_mask(m, True, 0)
            elif op == 0x36:
                self.push_mask(m, False, 1)
            else:
                self.push_mask(m, True, 1)
            return

        # Divers
        if op == 0x12:
            return
        if op == 0x13:      # SYNC (pas d'interruption ici)
            return
        if op == 0x19:
            self.daa()
            return
        if op == 0x1A:
            self.cc |= self.fet8()
            return
        if op == 0x1C:
            self.cc &= self.fet8()
            return
        if op == 0x1D:
            self.sex()
            return
        if op == 0x1E:
            self.exg(self.fet8())
            return
        if op == 0x1F:
            self.tfr(self.fet8())
            return
        if op == 0x39:
            self.pc = self.pull16()
            return
        if op == 0x3A:
            self.x = (self.x + self.b) & 0xFFFF
            return
        if op == 0x3B:      # RTI
            cc = self.pull8()
            self.cc = cc
            self.a = self.pull8()
            self.b = self.pull8()
            self.dp = self.pull8()
            if cc & CC_E:
                self.x = self.pull16()
                self.y = self.pull16()
                self.u = self.pull16()
            self.pc = self.pull16()
            return
        if op == 0x3C:      # CWAI
            self.cc &= self.fet8()
            self.push_mask(0xFF, False, 0)
            self.cc |= CC_E
            return
        if op == 0x3D:
            self.mul()
            return
        if op == 0x3F:
            raise TrapError("SWI à $%04X" % self.pc)

        # Accumulateurs A (0x40-0x4F)
        if 0x40 <= op <= 0x4F:
            sub = op & 0x0F
            if sub == 0x0:
                self.a = self.neg8(self.a)
            elif sub == 0x3:
                self.a = self.com8(self.a)
            elif sub == 0x4:
                self.a = self.lsr8(self.a)
            elif sub == 0x6:
                self.a = self.ror8(self.a)
            elif sub == 0x7:
                self.a = self.asr8(self.a)
            elif sub == 0x8:
                self.a = self.asl8(self.a)
            elif sub == 0x9:
                self.a = self.rol8(self.a)
            elif sub == 0xA:
                self.a = self.dec8(self.a)
            elif sub == 0xC:
                self.a = self.inc8(self.a)
            elif sub == 0xD:
                self.tst8(self.a)
            elif sub == 0xF:
                self.clr8()
                self.a = 0
            else:
                raise CPU6809Error("op A invalide $%02X" % op)
            return

        # Accumulateurs B (0x50-0x5F)
        if 0x50 <= op <= 0x5F:
            sub = op & 0x0F
            if sub == 0x0:
                self.b = self.neg8(self.b)
            elif sub == 0x3:
                self.b = self.com8(self.b)
            elif sub == 0x4:
                self.b = self.lsr8(self.b)
            elif sub == 0x6:
                self.b = self.ror8(self.b)
            elif sub == 0x7:
                self.b = self.asr8(self.b)
            elif sub == 0x8:
                self.b = self.asl8(self.b)
            elif sub == 0x9:
                self.b = self.rol8(self.b)
            elif sub == 0xA:
                self.b = self.dec8(self.b)
            elif sub == 0xC:
                self.b = self.inc8(self.b)
            elif sub == 0xD:
                self.tst8(self.b)
            elif sub == 0xF:
                self.clr8()
                self.b = 0
            else:
                raise CPU6809Error("op B invalide $%02X" % op)
            return

        # opérations mémoire 8 bits / JMP
        if 0x00 <= op <= 0x0F or 0x60 <= op <= 0x6F or 0x70 <= op <= 0x7F:
            self.memop8(op)
            return

        raise CPU6809Error("opcode inconnu $%02X" % op)

    def execute_pref(self, pref):
        self.steps += 1
        op = self.fet8()
        if pref == 0x10:
            if op == 0x3F:
                raise TrapError("SWI2 à $%04X" % self.pc)
            if 0x21 <= op <= 0x2F:
                if self.cond(op & 0x0F):
                    off = self.fet16()
                    if off & 0x8000:
                        off -= 0x10000
                    self.pc = (self.pc + off) & 0xFFFF
                else:
                    self.fet16()
                return
            # CMPD / CMPY / LDY / STY / LDS / STS
            if op == 0x83:
                v = self.fet16()
                self.sub16((self.a << 8) | self.b, v)
            elif op == 0x93:
                v = self.rd16(((self.dp << 8) | self.fet8()) & 0xFFFF)
                self.sub16((self.a << 8) | self.b, v)
            elif op == 0xA3:
                v = self.rd16(self.eff_ea())
                self.sub16((self.a << 8) | self.b, v)
            elif op == 0xB3:
                v = self.rd16(self.fet16())
                self.sub16((self.a << 8) | self.b, v)
            elif op == 0x8C:
                v = self.fet16()
                self.sub16(self.y, v)
            elif op == 0x9C:
                v = self.rd16(((self.dp << 8) | self.fet8()) & 0xFFFF)
                self.sub16(self.y, v)
            elif op == 0xAC:
                v = self.rd16(self.eff_ea())
                self.sub16(self.y, v)
            elif op == 0xBC:
                v = self.rd16(self.fet16())
                self.sub16(self.y, v)
            elif op == 0x8E:
                self.y = self.fet16()
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0x9E:
                self.y = self.rd16(((self.dp << 8) | self.fet8()) & 0xFFFF)
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0xAE:
                self.y = self.rd16(self.eff_ea())
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0xBE:
                self.y = self.rd16(self.fet16())
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0x9F:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.wr16(ea, self.y)
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0xAF:
                ea = self.eff_ea()
                self.wr16(ea, self.y)
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0xBF:
                ea = self.fet16()
                self.wr16(ea, self.y)
                self.cc &= ~CC_V
                self.setnz16(self.y)
            elif op == 0xCE:
                self.s = self.fet16()
                self.cc &= ~CC_V
                self.setnz16(self.s)
            elif op == 0xDE:
                self.s = self.rd16(((self.dp << 8) | self.fet8()) & 0xFFFF)
                self.cc &= ~CC_V
                self.setnz16(self.s)
            elif op == 0xEE:
                self.s = self.rd16(self.eff_ea())
                self.cc &= ~CC_V
                self.setnz16(self.s)
            elif op == 0xFE:
                self.s = self.rd16(self.fet16())
                self.cc &= ~CC_V
                self.setnz16(self.s)
            elif op == 0xDF:
                ea = ((self.dp << 8) | self.fet8()) & 0xFFFF
                self.wr16(ea, self.s)
                self.cc &= ~CC_V
                self.setnz16(self.s)
            elif op == 0xEF:
                ea = self.eff_ea()
                self.wr16(ea, self.s)
                self.cc &= ~CC_V
                self.setnz16(self.s)
            elif op == 0xFF:
                ea = self.fet16()
                self.wr16(ea, self.s)
                self.cc &= ~CC_V
                self.setnz16(self.s)
            else:
                raise CPU6809Error("opcode 0x10 $%02X inconnu" % op)
            return
        elif pref == 0x11:
            if op == 0x3F:
                raise TrapError("SWI3 à $%04X" % self.pc)
            if op == 0x83:
                v = self.fet16()
                self.sub16(self.u, v)
            elif op == 0x93:
                v = self.rd16(((self.dp << 8) | self.fet8()) & 0xFFFF)
                self.sub16(self.u, v)
            elif op == 0xA3:
                v = self.rd16(self.eff_ea())
                self.sub16(self.u, v)
            elif op == 0xB3:
                v = self.rd16(self.fet16())
                self.sub16(self.u, v)
            elif op == 0x8C:
                v = self.fet16()
                self.sub16(self.s, v)
            elif op == 0x9C:
                v = self.rd16(((self.dp << 8) | self.fet8()) & 0xFFFF)
                self.sub16(self.s, v)
            elif op == 0xAC:
                v = self.rd16(self.eff_ea())
                self.sub16(self.s, v)
            elif op == 0xBC:
                v = self.rd16(self.fet16())
                self.sub16(self.s, v)
            else:
                raise CPU6809Error("opcode 0x11 $%02X inconnu" % op)
            return
        raise CPU6809Error("préfixe invalide $%02X" % pref)

    def step(self):
        if getattr(self, 'trace', False):
            print("[trace] pc=$%04X op=$%02X A=$%02X B=$%02X X=$%04X Y=$%04X U=$%04X S=$%04X CC=$%02X"
                  % (self.pc, self.rd8(self.pc), self.a, self.b, self.x, self.y, self.u, self.s, self.cc))
        op = self.fet8()
        if op == 0x10 or op == 0x11:
            self.execute_pref(op)
        else:
            self.execute(op)

    def run(self):
        while not self.halted:
            if self.pc == EXIT_MARKER:
                self.halted = True
                self.halt_reason = "fin de programme"
                return
            if STUB_BASE <= self.pc < STUB_BASE + STUB_COUNT * STUB_GAP:
                n = ((self.pc - STUB_BASE) // STUB_GAP) * 2   # décalage sys_* (0,2,4..60)
                self.call_bios(n)
                continue
            self.step()


# ----------------------------------------------------------------------
# Simulateur OSM09 : BIOS stubs + disque virtuel
# ----------------------------------------------------------------------
class OSM09(CPU6809):
    def __init__(self):
        super().__init__()
        self.disk = {}            # nom 15 octets (strip) -> bytes
        self.output_host_path = None
        self.input_name = None    # nom 8.3 du fichier source
        self.output_name = None
        self.print_log = []
        self.trace = False

    def trace_line(self, txt):
        if self.trace:
            print("[trace] %s" % txt)

    def install_table(self):
        for n in range(31):
            self.wr16(VEC_TABLE + n * 2, STUB_BASE + n * STUB_GAP)

    def setup_args(self, prog_name, src_name, out_name):
        # zone des chaînes dans la RAM système
        base = 0xC450
        ptrs = []
        for s in (prog_name, src_name, out_name):
            self.wr16(ARGV + 2 * len(ptrs), base)
            bs = s.encode('latin-1')
            for i, ch in enumerate(bs):
                self.mem[base] = ch
                base += 1
            self.mem[base] = 0
            base += 1
            ptrs.append(base)
        self.wr8(ARGC, len(ptrs))
        self.input_name = self.format_83(src_name)
        self.output_name = self.format_83(out_name).rstrip(' ')
    @staticmethod
    def format_83(name):
        # reproduit Format_Filename_83 : majuscules, pad espaces (15)
        out = []
        for ch in name[:15]:
            if 'a' <= ch <= 'z':
                ch = chr(ord(ch) - 0x20)
            out.append(ch)
        out.extend(' ' * (15 - len(out)))
        return ''.join(out)

    @staticmethod
    def strip_name(buf15):
        return bytes(b for b in buf15 if b != 0x20).rstrip(b'\x00')

    def load_source_into_disk(self, src_path):
        with open(src_path, 'rb') as f:
            data = f.read()
        # clé du disque = nom 8.3 sans espaces de fin, en octets
        key = self.input_name.rstrip(' ').encode('latin-1')
        self.disk[key] = data
        # le nom "8.3" sans le point est aussi présent (test1asM etc.)
        no_dot = key.replace(b'.', b'')
        if no_dot not in self.disk:
            self.disk[no_dot] = data

    # ----- sortie -----
    def putchar(self, ch):
        sys.stdout.write(chr(ch))
        sys.stdout.flush()
        self.print_log.append(ch)

    def print_str(self, x):
        while True:
            ch = self.rd8(x)
            if ch == 0:
                break
            self.putchar(ch)
            x = (x + 1) & 0xFFFF

    def print_hex8(self, v):
        h = "0123456789ABCDEF"
        self.putchar(ord(h[(v >> 4) & 0xF]))
        self.putchar(ord(h[v & 0xF]))

    def print_hex16(self, v):
        self.print_hex8(v >> 8)
        self.print_hex8(v & 0xFF)

    # ----- heap (même layout que bios/vectors.asm) -----
    BLK_SIZE = 0
    BLK_USED = 2
    BLK_DATA = 3

    def init_heap(self):
        self.wr16(HEAP_START + 0, HEAP_SIZE)
        self.wr8(HEAP_START + 2, 0)

    def malloc_sys(self):
        req = (self.a << 8) | self.b
        req += 3
        x = HEAP_START
        while x < HEAP_END:
            if self.rd8(x + 2) != 0:                 # utilisé
                sz = self.rd16(x + 0)
                x += sz
                continue
            blksz = self.rd16(x + 0)
            if blksz < req:
                x += blksz
                continue
            self.wr8(x + 2, 1)
            y = self.rd16(x + 0)
            if blksz != req:
                self.wr16(x + 0, req)
                newblk = x + req
                self.wr16(newblk + 0, blksz - req)
                self.wr8(newblk + 2, 0)
                y = newblk
            self.x = x + 3
            return
        self.x = 0

    def free(self):
        x = self.x
        if x == 0:
            return
        hdr = (x - 3) & 0xFFFF
        if HEAP_START <= hdr < HEAP_END:
            self.wr8(hdr + 2, 0)

    # ----- services fichiers -----
    def fs_findentry(self):
        # X -> nom 15 octets ; sortie : U = taille, C=0 trouvé / C=1 absent
        name = bytes(self.mem[self.x:self.x + 15])
        key = name.rstrip(b' ')
        if key in self.disk:
            self.u = len(self.disk[key]) & 0xFFFF
            self.cc &= ~CC_C
        else:
            self.u = 0
            self.cc |= CC_C

    def fs_loadfile(self):
        # X -> nom, Y -> dest ; sortie : U = taille, C=0
        name = bytes(self.mem[self.x:self.x + 15])
        key = name.rstrip(b' ')
        data = self.disk.get(key)
        if data is None:
            self.u = 0
            self.cc |= CC_C
            return
        for i, ch in enumerate(data):
            self.mem[(self.y + i) & 0xFFFF] = ch
        self.u = len(data) & 0xFFFF
        self.cc &= ~CC_C

    def fs_savefile(self):
        # X -> nom, Y -> données, D = taille ; sortie : C=0 ok
        name = bytes(self.mem[self.x:self.x + 15])
        key = name.rstrip(b' ')
        size = (self.a << 8) | self.b
        data = bytes(self.mem[(self.y + i) & 0xFFFF] for i in range(size))
        self.disk[key] = data
        if self.output_host_path is not None and key == self.output_name.encode('latin-1'):
            with open(self.output_host_path, 'wb') as f:
                f.write(data)
        self.cc &= ~CC_C

    def fs_deletefile(self):
        name = bytes(self.mem[self.x:self.x + 15])
        key = name.rstrip(b' ')
        self.disk.pop(key, None)
        self.cc &= ~CC_C

    def format_filename(self):
        # X -> chaîne source, Y -> buffer 15
        src = self.x
        dst = self.y
        out = []
        for i in range(15):
            ch = self.rd8(src)
            src = (src + 1) & 0xFFFF
            if ch == 0:
                break
            if ord('a') <= ch <= ord('z'):
                ch -= 0x20
            out.append(ch)
        for i in range(15):
            self.mem[(dst + i) & 0xFFFF] = out[i] if i < len(out) else 0x20

    # ----- appel BIOS -----
    def call_bios(self, n):
        if n == SYS_PRINTCHAR:
            self.putchar(self.a)
        elif n == SYS_PRINTSTRING:
            self.print_str(self.x)
        elif n == SYS_PRINTHEXCHAR:
            self.print_hex8(self.a)
        elif n == SYS_PRINTHEXWORD:
            self.print_hex16((self.a << 8) | self.b)
        elif n == SYS_PRINTCRLF:
            self.putchar(0x0A)
            self.putchar(0x0D)
        elif n == SYS_FORMAT_FILENAME83:
            self.format_filename()
        elif n == SYS_FS_FINDENTRY:
            self.fs_findentry()
        elif n == SYS_FS_LOADFILE:
            self.fs_loadfile()
        elif n == SYS_FS_SAVEFILE:
            self.fs_savefile()
        elif n == SYS_FS_DELETEFILE:
            self.fs_deletefile()
        elif n == SYS_MALLOC_SYS:
            self.malloc_sys()
        elif n == SYS_FREE:
            self.free()
        elif n == SYS_STRCPY:
            while True:
                v = self.rd8(self.x)
                self.wr8(self.y, v)
                self.x = (self.x + 1) & 0xFFFF
                self.y = (self.y + 1) & 0xFFFF
                if v == 0:
                    break
        elif n == SYS_STRLEN:
            l = 0
            while self.rd8((self.x + l) & 0xFFFF) != 0:
                l += 1
            self.a = l >> 8
            self.b = l & 0xFF
        elif n == SYS_PAGER:
            pass
        else:
            raise CPU6809Error("service BIOS %d non implémenté" % n)
        # RTS : le thunk a fait JMP, le RTS retourne à l'appelant du thunk
        self.pc = self.pull16()

    def run_program(self, max_steps=None):
        if max_steps is not None:
            self.max_steps = max_steps
        self.run()
        return self.halt_reason


# ----------------------------------------------------------------------
def run_asm(asm_path, src_path, out_path, max_steps=None, trace=False):
    m = OSM09()
    m.trace = trace
    data = open(asm_path, 'rb').read()
    m.mem[0:len(data)] = data
    m.install_table()
    m.init_heap()
    src_name = src_path.split('/')[-1]
    out_name = out_path.split('/')[-1]
    m.setup_args("ASM", src_name, out_name)
    m.load_source_into_disk(src_path)
    m.output_host_path = out_path
    # pile initiale : marqueur de retour au shell
    m.s = 0xDFEF
    m.push16(EXIT_MARKER)
    m.pc = 0x0000
    reason = m.run_program(max_steps)
    return m, reason


# ----------------------------------------------------------------------
def selftest():
    import os
    tests = ["test1", "test_dir", "test_edge", "test_pcr", "test_pcr2"]
    ok = True
    for t in tests:
        binpath = os.path.join("test", t + ".bin")
        if not os.path.exists(binpath):
            binpath = t + ".bin"
        data = open(binpath, 'rb').read()
        m = OSM09()
        org = 0x0100 if t == "test1" else (0x1000 if t in ("test_pcr", "test_edge") else 0x2000)
        m.mem[org:org + len(data)] = data
        m.pc = org
        m.s = 0xD000
        m.max_steps = 300
        try:
            while m.steps < 300 and not m.halted:
                m.step()
            print("%-10s : exécuté %d instructions sans erreur de décodage"
                  % (t, m.steps))
        except TrapError as e:
            print("%-10s : %s (stop propre)" % (t, e))
        except CPU6809Error as e:
            print("%-10s : ERREUR %s (pc=$%04X)" % (t, e, m.pc))
            ok = False
    return ok


# ----------------------------------------------------------------------
def disasm(binpath, org):
    """Désassembleur minimal de contrôle (valide le décodage indexé)."""
    data = open(binpath, 'rb').read()
    m = OSM09()
    m.mem[org:org + len(data)] = data
    names = {
        0x12: "NOP", 0x13: "SYNC", 0x19: "DAA", 0x1A: "ORCC", 0x1C: "ANDCC",
        0x1D: "SEX", 0x1E: "EXG", 0x1F: "TFR", 0x39: "RTS", 0x3A: "ABX",
        0x3B: "RTI", 0x3C: "CWAI", 0x3D: "MUL", 0x3F: "SWI",
    }
    regs = ["X", "Y", "U", "S"]
    acc = ["A", "B"]
    subname = {0: "NEG", 3: "COM", 4: "LSR", 6: "ROR", 7: "ASR", 8: "ASL",
               9: "ROL", 0xA: "DEC", 0xC: "INC", 0xD: "TST", 0xE: "JMP", 0xF: "CLR"}
    aalu = {0: "SUBA", 1: "CMPA", 2: "SBCA", 3: "SUBD", 4: "ANDA", 5: "BITA",
            6: "LDA", 7: "STA", 8: "EORA", 9: "ADCA", 0xA: "ORA", 0xB: "ADDA",
            0xC: "CMPX", 0xD: "BSR", 0xE: "LDX", 0xF: "STX"}
    balu = {0: "SUBB", 1: "CMPB", 2: "SBCB", 3: "ADDD", 4: "ANDB", 5: "BITB",
            6: "LDB", 7: "STB", 8: "EORB", 9: "ADCB", 0xA: "ORB", 0xB: "ADDB"}
    mode = {0: ",R+", 1: ",R++", 2: ",-R", 3: ",--R", 4: ",R", 5: "B,R",
            6: "A,R", 8: "n8,R", 9: "n16,R", 0xB: "D,R", 0xC: "n8,PCR",
            0xD: "n16,PCR", 0xE: "[n16,PCR]", 0xF: "[n16]"}
    addr = org
    count = 0
    while count < 400:
        if addr >= org + len(data):
            break
        op = m.rd8(addr)
        start = addr
        toks = []
        if op == 0x10 or op == 0x11:
            p = m.rd8((addr + 1) & 0xFFFF)
            toks.append(("10" if op == 0x10 else "11") + "%02X" % p)
            addr += 2
            if op == 0x10 and 0x21 <= p <= 0x2F:
                off = m.rd16(addr); addr += 2
                toks.append("LBxx %+d" % ((off - 0x10000) if off & 0x8000 else off))
            else:
                toks.append("0x10-op")
            print("%04X: %s" % (start, " ".join(toks)))
            count += 1
            continue
        toks.append("%02X" % op)
        addr += 1
        if op == 0x12 or op == 0x13 or op == 0x19 or op == 0x1D or op == 0x3A or \
           op == 0x3B or op == 0x3D or op == 0x39:
            toks.append(names.get(op, "?"))
        elif op in (0x1A, 0x1C, 0x3C):
            toks.append(names.get(op, "?") + " #$%02X" % m.rd8(addr)); addr += 1
        elif op in (0x1E, 0x1F):
            b = m.rd8(addr); addr += 1
            codes = {0: "D", 1: "X", 2: "Y", 3: "U", 4: "S", 5: "PC", 6: "W", 7: "V",
                     8: "A", 9: "B", 0xA: "CC", 0xB: "DP", 0xC: "0", 0xD: "0",
                     0xE: "E", 0xF: "F"}
            toks.append("%s %s,%s" % (names[op], codes.get(b >> 4, "?"), codes.get(b & 0xF, "?")))
        elif 0x20 <= op <= 0x2F:
            off = m.rd8(addr); addr += 1
            if off & 0x80: off -= 0x100
            toks.append("Bxx %+d" % off)
        elif op == 0x16 or op == 0x17:
            off = m.rd16(addr); addr += 2
            if off & 0x8000: off -= 0x10000
            toks.append(("LBRA" if op == 0x16 else "LBSR") + " %+d" % off)
        elif 0x30 <= op <= 0x33:
            pb = m.rd8(addr); addr += 1
            ea, extra = disidx(m, addr, pb)
            toks.append("LEA%s %s" % (regs[op - 0x30], ea))
        elif 0x34 <= op <= 0x37:
            mb = m.rd8(addr); addr += 1
            nm = []
            for bit, nm_ in ((0x80, "PC"), (0x40, "S" if op in (0x36, 0x37) else "U"),
                             (0x20, "Y"), (0x10, "X"), (0x08, "DP"), (0x04, "B"),
                             (0x02, "A"), (0x01, "CC")):
                if mb & bit:
                    nm.append(nm_)
            toks.append({0x34: "PSHS", 0x35: "PULS", 0x36: "PSHU", 0x37: "PULU"}[op] + " " + ",".join(nm))
        elif 0x40 <= op <= 0x4F:
            toks.append({0: "NEGA", 3: "COMA", 4: "LSRA", 6: "RORA", 7: "ASRA",
                         8: "ASLA", 9: "ROLA", 0xA: "DECA", 0xC: "INCA",
                         0xD: "TSTA", 0xF: "CLRA"}.get(op & 0xF, "?"))
        elif 0x50 <= op <= 0x5F:
            toks.append({0: "NEGB", 3: "COMB", 4: "LSRB", 6: "RORB", 7: "ASRB",
                         8: "ASLB", 9: "ROLB", 0xA: "DECB", 0xC: "INCB",
                         0xD: "TSTB", 0xF: "CLRB"}.get(op & 0xF, "?"))
        elif 0x00 <= op <= 0x0F:
            ea = (m.dp << 8) | m.rd8(addr); addr += 1
            toks.append(subname.get(op, "?") + " <%04X" % ea)
        elif 0x60 <= op <= 0x6F:
            pb = m.rd8(addr); addr += 1
            ea, _ = disidx(m, addr, pb)
            toks.append(subname.get(op, "?") + " " + ea)
        elif 0x70 <= op <= 0x7F:
            ea = m.rd16(addr); addr += 2
            toks.append(subname.get(op, "?") + " >%04X" % ea)
        elif 0x80 <= op <= 0xBF:
            if op == 0x8D:
                off = m.rd8(addr); addr += 1
                if off & 0x80: off -= 0x100
                toks.append("BSR %+d" % off)
                print("%04X: %s" % (start, " ".join(toks)))
                count += 1
                continue
            cls = (op >> 4) & 0xF
            sub = op & 0xF
            nm = aalu[sub]
            if cls == 8:
                toks.append(nm + " #$%02X" % m.rd8(addr)); addr += 1
            elif cls == 9:
                toks.append(nm + " <%04X" % ((m.dp << 8) | m.rd8(addr))); addr += 1
            elif cls == 0xA:
                pb = m.rd8(addr); addr += 1
                ea, _ = disidx(m, addr, pb)
                toks.append(nm + " " + ea)
            else:
                toks.append(nm + " >%04X" % m.rd16(addr)); addr += 2
        elif 0xC0 <= op <= 0xFF:
            cls = (op >> 4) & 0xF
            sub = op & 0xF
            nm = balu.get(sub, "?")
            if op == 0xCC or op == 0xCE:
                toks.append("LD%s #$%04X" % ("D" if op == 0xCC else "U", m.rd16(addr))); addr += 2
            elif cls == 8:
                toks.append(nm + " #$%02X" % m.rd8(addr)); addr += 1
            elif cls == 9:
                toks.append(nm + " <%04X" % ((m.dp << 8) | m.rd8(addr))); addr += 1
            elif cls == 0xA:
                pb = m.rd8(addr); addr += 1
                ea, _ = disidx(m, addr, pb)
                toks.append(nm + " " + ea)
            else:
                toks.append(nm + " >%04X" % m.rd16(addr)); addr += 2
        else:
            toks.append("?")
        print("%04X: %s" % (start, " ".join(toks)))
        count += 1


def disidx(m, addr, pb):
    reg = ["X", "Y", "U", "S"][(pb >> 5) & 3]
    if not (pb & 0x80):
        off = pb & 0x1F
        if off & 0x10: off -= 0x20
        return "%d,%s" % (off, reg), addr
    msub = pb & 0x0F
    ind = "[" if (pb & 0x10) else ""
    end = "]" if (pb & 0x10) else ""
    if msub == 0x00: return ind + "," + reg + "+" + end, addr
    if msub == 0x01: return ind + "," + reg + "++" + end, addr
    if msub == 0x02: return ind + ",-" + reg + end, addr
    if msub == 0x03: return ind + ",--" + reg + end, addr
    if msub == 0x04: return ind + "," + reg + end, addr
    if msub == 0x05: return ind + "b," + reg + end, addr
    if msub == 0x06: return ind + "a," + reg + end, addr
    if msub == 0x0B: return ind + "d," + reg + end, addr
    if msub == 0x08:
        v = m.rd8(addr)
        if v & 0x80: v -= 0x100
        return ind + "%d,%s" % (v, reg) + end, addr + 1
    if msub == 0x09:
        v = m.rd16(addr)
        if v & 0x8000: v -= 0x10000
        return ind + "%d,%s" % (v, reg) + end, addr + 2
    if msub == 0x0C:
        v = m.rd8(addr)
        if v & 0x80: v -= 0x100
        return "%d,pcr" % v, addr + 1
    if msub == 0x0D:
        v = m.rd16(addr)
        if v & 0x8000: v -= 0x10000
        return "%d,pcr" % v, addr + 2
    if msub == 0x0E:
        v = m.rd16(addr)
        if v & 0x8000: v -= 0x10000
        return "[%d,pcr]" % v, addr + 2
    if msub == 0x0F:
        return "[%04X]" % m.rd16(addr), addr + 2
    return "?", addr


# ----------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    if args[0] == "--selftest":
        return 0 if selftest() else 1
    if args[0] == "--dis":
        disasm(args[1], int(args[2], 0))
        return 0
    if len(args) < 3:
        print("Usage : emu6809.py <ASM.bin> <source.asm> <sortie.bin>")
        return 1
    asm_path, src_path, out_path = args[0], args[1], args[2]
    max_steps = None
    trace = False
    if "--limit" in args:
        max_steps = int(args[args.index("--limit") + 1])
    if "--trace" in args:
        trace = True
    m, reason = run_asm(asm_path, src_path, out_path, max_steps, trace)
    print()
    print("== fin : %s (%d instructions) ==" % (reason, m.steps))
    if reason != "fin de programme":
        print("== REGISTRES ==")
        print("A=$%02X B=$%02X D=$%04X" % (m.a, m.b, (m.a << 8) | m.b))
        print("X=$%04X Y=$%04X U=$%04X S=$%04X PC=$%04X DP=$%02X CC=$%02X"
              % (m.x, m.y, m.u, m.s, m.pc, m.dp, m.cc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
