#!/usr/bin/env python3
# ===================================================================
# verifie_fs.py - FS_LoadFile / FS_SaveFile sur plusieurs pages
# ===================================================================
# Fait tourner le VRAI BIOS (bios/osm39.bin en $E000) dans le cœur 6809
# de asm/emu6809.py, complété des instructions 6309 que l'OSMFS utilise,
# avec :
#   * les 4 pages de 32 Ko en $0000-$7FFF derrière le latch $A0C0
#     (une valeur > 3 écrite dans $A0C0 est une ERREUR du BIOS) ;
#   * une carte SD = une image OSMFS créée et relue par tools/egofs
#     (SD_ReadBlock / SD_WriteBlock interceptés : BlockAddr, SD_BUFFER).
# Vérifie : un enregistrement de 40 Ko à cheval sur les pages 2 et 3,
# sa relecture, le refus de dépasser la page 3, un petit fichier sans
# changement de page, la mémoire commune (Y >= $8000), la page de
# l'appelant rétablie, qu'un nouveau fichier ne recouvre aucun fichier
# existant (dont un de plus de 64 Ko et un de 65 100 octets), et le
# moulinet (coin haut droit de l'écran, VRAM $8000/$9000) : il tourne
# pendant un gros transfert, rend les cellules intactes, et un petit
# fichier ne touche pas la VRAM ; enfin une carte capricieuse (erreurs
# passagères : le BIOS réessaie) et un secteur illisible (échec propre).
#   make -C bios && python3 test/verifie_fs.py
# ===================================================================
import os
import random
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, os.path.join(RACINE, 'asm'))
sys.path.insert(0, os.path.join(RACINE, 'tools', 'egofs'))
import emu6809                  # noqa: E402
import egofs_core               # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import carte                    # noqa: E402  (disposition de la VRAM : v4 ou mono)

BIN = os.path.join(RACINE, 'bios', 'osm39.bin')
MAP = os.path.join(RACINE, 'bios', 'osm39.map')
RETOUR = 0xDFF0 - 0x10          # adresse de retour sentinelle (RAM commune)
RETOUR_IRQ = 0xDFE8             # celle de l'IRQ simulée (irq_vsync)
NOM = 0xDB00                    # nom de fichier (15 octets) en RAM commune (hors de BIOS2)
PAGER = 0xA0C0
AY_ADR = 0xA150                 # AY-3-8910 : choix du registre, et relecture
AY_LARGEUR = [0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF,      # bits gardés
              0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF]      # par registre


def sym():
    s = {}
    for nom, v in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read()):
        s[nom] = int(v, 16)
    return s


class Machine(emu6809.CPU6809):
    """6809 + instructions 6309 de l'OSMFS + RAM paginée + carte SD."""

    def __init__(self, image, s):
        super().__init__()
        self.banks = [bytearray(32768) for _ in range(4)]
        self.page = 0
        self.mauvaise_page = []
        self.image = image
        self.s_ = s
        self.w = 0
        self.vram_ecrits = []           # (adresse, valeur) dans $8000-$9FFF
        self.irq_tous = None            # pas : une IRQ du VSYNC (Spin_IRQ) tous les n pas
        self.dans_irq = False
        self.vram_hors_irq = []         # écritures VRAM hors de cette IRQ
        self.panne = None               # (lecture?, lba, essai) -> code d'erreur ou 0
        self.essais = {}
        self.ay_reg = 0                 # registre choisi de l'AY (AY_ADR)
        self.ay_regs = [0] * 16         # ses registres, relus par AY_ADR (largeurs de la puce)
        self.ay_present = True          # False : puce retirée, AY_ADR lit le bus vide
        self.port_a = 0xFF              # R14 : port A (la Clouris), rien de branché
        self.mem[0xE000:0x10000] = open(BIN, 'rb').read()
        installe_bios(self)             # comme au démarrage : table, vecteurs, BIOS2

    def lit_port_a(self):
        return self.port_a

    # --- mémoire : $0000-$7FFF = page courante ---
    def rd8(self, a):
        a &= 0xFFFF
        if a < 0x8000:
            return self.banks[self.page][a]
        if a == AY_ADR:
            if not self.ay_present:
                return 0x50             # bus vide : le dernier octet vu, celui de l'adresse
            if self.ay_reg == 14:
                return self.lit_port_a()
            return self.ay_regs[self.ay_reg & 15]
        if a == 0xA040:                 # port A du PIA : sans carte RTC, les
            return 0xFF                 # tirages le tiennent à $FF
        return self.mem[a]

    def wr8(self, a, v):
        a &= 0xFFFF
        v &= 0xFF
        if a < 0x8000:
            self.banks[self.page][a] = v
        elif 0x8000 <= a < 0xA000:
            self.vram_ecrits.append((a, v))
            if not self.dans_irq:
                self.vram_hors_irq.append((a, v, self.pc))
            self.mem[a] = v
        elif a == AY_ADR:
            self.ay_reg = v
            self.mem[a] = v
        elif a == AY_ADR + 1:           # AY_DATA : le registre choisi
            self.ay_regs[self.ay_reg & 15] = v & AY_LARGEUR[self.ay_reg & 15]
            self.mem[a] = v
        elif a == PAGER:
            if v > 3:
                self.mauvaise_page.append((v, self.pc))
            self.page = v & 3
        else:
            self.mem[a] = v

    def rd16(self, a):
        return (self.rd8(a) << 8) | self.rd8(a + 1)

    def wr16(self, a, v):
        self.wr8(a, v >> 8)
        self.wr8(a + 1, v)

    # --- registres 6309 : W = E:F ---
    def getreg(self, code):
        code &= 0x0F
        if code == 6:
            return self.w
        if code == 0xE:
            return self.w >> 8
        if code == 0xF:
            return self.w & 0xFF
        return super().getreg(code)

    def setreg(self, code, v):
        code &= 0x0F
        if code == 6:
            self.w = v & 0xFFFF
        elif code == 0xE:
            self.w = ((v & 0xFF) << 8) | (self.w & 0xFF)
        elif code == 0xF:
            self.w = (self.w & 0xFF00) | (v & 0xFF)
        else:
            super().setreg(code, v)

    def tfr(self, byte):
        self.setreg(byte & 0x0F, self.getreg(byte >> 4))

    def _nzw(self, v):
        self.cc &= ~(emu6809.CC_N | emu6809.CC_Z | emu6809.CC_V) & 0xFF
        if v & 0x8000:
            self.cc |= emu6809.CC_N
        if v & 0xFFFF == 0:
            self.cc |= emu6809.CC_Z

    # les instructions aussi sont lues dans la page courante
    def fet8(self):
        b = self.rd8(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return b

    def fet16(self):
        w = self.rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        return w

    def step(self):
        op = self.fet8()
        if op in (0x10, 0x11):
            self.execute_pref(op)
        else:
            self.execute(op)

    def execute_pref(self, pref):
        op = self.rd8(self.pc)
        d = (self.a << 8) | self.b
        if pref == 0x10 and op in (0x38, 0x39, 0x48, 0x4F, 0x5A, 0x81, 0x86, 0xB1, 0xB6):
            self.pc = (self.pc + 1) & 0xFFFF
            self.steps += 1
            if op == 0x38:                      # PSHSW : E puis F en mémoire
                self.s = (self.s - 2) & 0xFFFF
                self.wr8(self.s, self.w >> 8)
                self.wr8(self.s + 1, self.w & 0xFF)
            elif op == 0x39:                    # PULSW
                self.w = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
                self.s = (self.s + 2) & 0xFFFF
            elif op == 0x48:                    # LSLD
                r = (d << 1) & 0xFFFF
                self.a, self.b = r >> 8, r & 0xFF
                self._nzw(r)
                self.cc = (self.cc | 1) if d & 0x8000 else (self.cc & 0xFE)
            elif op == 0x4F:                    # CLRD
                self.a = self.b = 0
                self.cc = (self.cc & ~(emu6809.CC_N | emu6809.CC_V | emu6809.CC_C) & 0xFF) | emu6809.CC_Z
            elif op == 0x5A:                    # DECW
                self.w = (self.w - 1) & 0xFFFF
                self._nzw(self.w)
            elif op == 0x81:                    # CMPW #
                self.sub16(self.w, self.fet16())
            elif op == 0xB1:                    # CMPW étendu
                self.sub16(self.w, self.rd16(self.fet16()))
            elif op == 0x86:                    # LDW #
                self.w = self.fet16()
                self._nzw(self.w)
            elif op == 0xB6:                    # LDW étendu
                self.w = self.rd16(self.fet16())
                self._nzw(self.w)
            return
        if pref == 0x10 and op == 0xA6:         # LDW indexé (FarRead/FarWrite)
            self.pc = (self.pc + 1) & 0xFFFF
            self.steps += 1
            self.w = self.rd16(self.eff_ea())
            self._nzw(self.w)
            return
        if pref == 0x11 and op in (0x86, 0xC6):  # LDE # / LDF #
            self.pc = (self.pc + 1) & 0xFFFF
            self.steps += 1
            self.setreg(0xE if op == 0x86 else 0xF, self.fet8())
            return
        if pref == 0x11 and op in (0x38, 0x39, 0x3A, 0x3B):  # TFM r0+,r1+ / -,- / +,r1 / r0,+
            self.pc = (self.pc + 1) & 0xFFFF
            self.steps += 1
            pb = self.fet8()
            src, dst = pb >> 4, pb & 0x0F
            ds, dd = {0x38: (1, 1), 0x39: (-1, -1), 0x3A: (1, 0), 0x3B: (0, 1)}[op]
            while self.w:
                sa, da = self.getreg(src), self.getreg(dst)
                self.wr8(da, self.rd8(sa))
                self.setreg(src, sa + ds)
                self.setreg(dst, da + dd)
                self.w -= 1
            return
        if self.exec6309(pref, op):
            return
        super().execute_pref(pref)

    # --- le reste du jeu 6309 que les programmes de la carte emploient ---
    def _op(self, op, taille):
        """Opérande d'une instruction mémoire : mode selon les bits 4-5."""
        mode = op & 0x30
        if mode == 0x00:
            return self.fet8() if taille == 1 else self.fet16()
        ea = {0x10: lambda: (self.dp << 8) | self.fet8(), 0x20: self.eff_ea, 0x30: self.fet16}[mode]()
        return self.rd8(ea) if taille == 1 else self.rd16(ea)

    def _ea(self, op):
        mode = op & 0x30
        return {0x10: lambda: (self.dp << 8) | self.fet8(), 0x20: self.eff_ea, 0x30: self.fet16}[mode]()

    def _cv(self, c, v=None):
        self.cc = (self.cc | 1) if c else (self.cc & 0xFE)
        if v is not None:
            self.cc = (self.cc | emu6809.CC_V) if v else (self.cc & ~emu6809.CC_V & 0xFF)

    def _adc16(self, a, b):
        c = self.cc & 1
        r = a + b + c
        self.setnz16(r & 0xFFFF)
        self._cv(r >> 16, (~(a ^ b) & (a ^ r)) & 0x8000)
        return r & 0xFFFF

    def _sbc16(self, a, b):
        c = self.cc & 1
        r = a - b - c
        self.setnz16(r & 0xFFFF)
        self._cv(r < 0, ((a ^ b) & (a ^ r)) & 0x8000)
        return r & 0xFFFF

    # AIM / OIM / EIM / TIM (#imm puis direct, indexé ou étendu) et LDQ #
    def execute(self, op):
        if op in (0x01, 0x02, 0x05, 0x0B, 0x61, 0x62, 0x65, 0x6B, 0x71, 0x72, 0x75, 0x7B):
            imm = self.fet8()
            mode = op & 0xF0
            ea = ((self.dp << 8) | self.fet8()) if mode == 0x00 else self.eff_ea() if mode == 0x60 else self.fet16()
            v = self.rd8(ea)
            k = op & 0x0F
            r = (v | imm) if k == 1 else (v ^ imm) if k == 5 else (v & imm)
            self.setnz8(r)
            self.cc &= ~emu6809.CC_V & 0xFF
            if k != 0x0B:
                self.wr8(ea, r)
            self.steps += 1
            return
        if op == 0xCD:                                  # LDQ #
            q = (self.fet16() << 16) | self.fet16()
            self.a, self.b, self.w = (q >> 24) & 255, (q >> 16) & 255, q & 0xFFFF
            self.cc &= ~(emu6809.CC_N | emu6809.CC_Z | emu6809.CC_V) & 0xFF
            self.cc |= (emu6809.CC_N if q & 0x80000000 else 0) | (emu6809.CC_Z if q == 0 else 0)
            self.steps += 1
            return
        return super().execute(op)

    def exec6309(self, pref, op):
        d = (self.a << 8) | self.b
        CC_V = emu6809.CC_V
        un = lambda: setattr(self, 'pc', (self.pc + 1) & 0xFFFF)

        def setd(v):
            self.a, self.b = (v >> 8) & 255, v & 255

        if pref == 0x10 and (0x40 <= op <= 0x5F) and op not in (0x48, 0x4F, 0x5A):
            un()
            w = op >= 0x50
            v = self.w if w else d
            k = op & 0x0F
            c = self.cc & 1
            if k == 0x0:
                r = (-v) & 0xFFFF
                self._cv(v != 0, v == 0x8000)
            elif k == 0x3:
                r = (~v) & 0xFFFF
                self._cv(1, 0)
            elif k == 0x4:
                r = v >> 1
                self._cv(v & 1)
            elif k == 0x6:
                r = (v >> 1) | (c << 15)
                self._cv(v & 1)
            elif k == 0x7:
                r = (v >> 1) | (v & 0x8000)
                self._cv(v & 1)
            elif k == 0x8:
                r = (v << 1) & 0xFFFF
                self._cv(v & 0x8000)
            elif k == 0x9:
                r = ((v << 1) | c) & 0xFFFF
                self._cv(v & 0x8000)
            elif k == 0xA:
                r = (v - 1) & 0xFFFF
                self.cc = (self.cc | CC_V) if v == 0x8000 else (self.cc & ~CC_V & 0xFF)
            elif k == 0xC:
                r = (v + 1) & 0xFFFF
                self.cc = (self.cc | CC_V) if v == 0x7FFF else (self.cc & ~CC_V & 0xFF)
            elif k == 0xD:
                r = v
                self.cc &= ~CC_V & 0xFF
            elif k == 0xF:
                r = 0
                self._cv(0, 0)
            else:
                return False
            self.setnz16(r)
            if w:
                self.w = r
            else:
                setd(r)
            return True
        if pref == 0x11 and (0x40 <= op <= 0x5F):
            un()
            reg = 0xF if op >= 0x50 else 0xE
            v = self.getreg(reg)
            k = op & 0x0F
            if k == 0x3:
                r = self.com8(v)
            elif k == 0xA:
                r = self.dec8(v)
            elif k == 0xC:
                r = self.inc8(v)
            elif k == 0xD:
                r = self.tst8(v)
            elif k == 0xF:
                r = self.clr8()
            else:
                return False
            self.setreg(reg, r)
            return True
        if pref == 0x10 and 0x30 <= op <= 0x37:          # ADDR ... CMPR
            un()
            pb = self.fet8()
            r0, r1 = pb >> 4, pb & 0x0F
            a, b = self.getreg(r1), self.getreg(r0)
            huit = r1 >= 8
            k = op & 7
            if huit:
                f = [self.add8, self.adc8, self.sub8, self.sbc8, None, None, None, self.sub8][k]
            else:
                f = [self.add16, self._adc16, self.sub16, self._sbc16, None, None, None, self.sub16][k]
            if k in (4, 5, 6):
                r = (a & b) if k == 4 else (a | b) if k == 5 else (a ^ b)
                (self.setnz8 if huit else self.setnz16)(r)
                self.cc &= ~CC_V & 0xFF
            elif f is None:
                return False
            else:
                r = f(a, b)
            if k != 7:
                self.setreg(r1, r)
            return True
        if pref == 0x11 and op == 0x3F:                  # SWI3, mode natif : frame de 14 octets
            un()
            self.s = (self.s - 14) & 0xFFFF
            f = [self.cc | 0x80, self.a, self.b, self.w >> 8, self.w & 255, self.dp,
                 self.x >> 8, self.x & 255, self.y >> 8, self.y & 255, self.u >> 8, self.u & 255,
                 self.pc >> 8, self.pc & 255]
            for i, o in enumerate(f):
                self.wr8(self.s + i, o)
            self.cc |= 0x80
            self.pc = self.rd16(0xFFF2)
            return True
        if pref == 0x11 and 0x30 <= op <= 0x37:          # BAND ... STBT (bit de mémoire directe)
            un()
            pb = self.fet8()
            ea = (self.dp << 8) | self.fet8()
            reg = [None, 0x8, 0x9, None][pb >> 6]       # CC, A, B
            rv = self.cc if pb >> 6 == 0 else self.getreg(reg)
            sb, db = (pb >> 3) & 7, pb & 7
            mb = (self.rd8(ea) >> sb) & 1
            rb = (rv >> db) & 1
            if op == 0x37:                              # STBT : bit du registre -> mémoire
                m = self.rd8(ea)
                self.wr8(ea, (m & ~(1 << sb)) | (rb << sb))
                return True
            nb = [rb & mb, rb & (mb ^ 1), rb | mb, rb | (mb ^ 1), rb ^ mb, rb ^ (mb ^ 1), mb][op - 0x30]
            rv = (rv & ~(1 << db) & 0xFF) | (nb << db)
            if pb >> 6 == 0:
                self.cc = rv
            else:
                self.setreg(reg, rv)
            return True
        if pref == 0x10 and op in (0x3A, 0x3B):          # PSHUW / PULUW
            un()
            if op == 0x3A:
                self.u = (self.u - 2) & 0xFFFF
                self.wr16(self.u, self.w)
            else:
                self.w = self.rd16(self.u)
                self.u = (self.u + 2) & 0xFFFF
            return True
        if pref == 0x10 and (op & 0xC0) == 0x80 and (op & 0x0F) in (0x0, 0x1, 0x2, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA, 0xB):
            k = op & 0x0F
            un()
            if k == 0x7:                                # STW
                if (op & 0x30) == 0:
                    return False
                self.wr16(self._ea(op), self.w)
                self._nzw(self.w)
                return True
            m = self._op(op, 2)
            if k == 0x0:
                self.w = self.sub16(self.w, m)
            elif k == 0x1:
                self.sub16(self.w, m)
            elif k == 0x2:                              # SBCD
                c = self.cc & 1
                r = d - m - c
                setd(r & 0xFFFF)
                self.setnz16(r & 0xFFFF)
                self._cv(r < 0, ((d ^ m) & (d ^ r)) & 0x8000)
            elif k in (0x4, 0x5, 0x8, 0xA):
                r = {0x4: d & m, 0x5: d & m, 0x8: d ^ m, 0xA: d | m}[k]
                if k != 0x5:
                    setd(r)
                self.setnz16(r)
                self.cc &= ~CC_V & 0xFF
            elif k == 0x6:
                self.w = m
                self._nzw(m)
            elif k == 0x9:                              # ADCD
                c = self.cc & 1
                r = d + m + c
                setd(r & 0xFFFF)
                self.setnz16(r & 0xFFFF)
                self._cv(r >> 16, (~(d ^ m) & (d ^ r)) & 0x8000)
            elif k == 0xB:
                self.w = self.add16(self.w, m)
            return True
        if pref == 0x11 and (op & 0x80) and (op & 0x0F) in (0x0, 0x1, 0x6, 0x7, 0xB) and (op & 0x40) in (0, 0x40):
            k = op & 0x0F
            reg = 0xF if op & 0x40 else 0xE
            un()
            if k == 0x7:                                # STE / STF
                if (op & 0x30) == 0:
                    return False
                v = self.getreg(reg)
                self.wr8(self._ea(op), v)
                self.tst8(v)
                return True
            m = self._op(op, 1)
            v = self.getreg(reg)
            if k == 0x0:
                self.setreg(reg, self.sub8(v, m))
            elif k == 0x1:
                self.sub8(v, m)
            elif k == 0x6:
                self.setreg(reg, m)
                self.tst8(m)
            elif k == 0xB:
                self.setreg(reg, self.add8(v, m))
            return True
        if pref == 0x10 and op in (0xDC, 0xEC, 0xFC, 0xDD, 0xED, 0xFD):   # LDQ / STQ
            un()
            ea = self._ea(op - 0xC0)            # $DC -> mode direct, $EC indexé, $FC étendu
            if op & 1:
                self.wr16(ea, d)
                self.wr16(ea + 2, self.w)
                q = (d << 16) | self.w
            else:
                q = (self.rd16(ea) << 16) | self.rd16(ea + 2)
                setd(q >> 16)
                self.w = q & 0xFFFF
            self.cc &= ~(emu6809.CC_N | emu6809.CC_Z | emu6809.CC_V) & 0xFF
            if q & 0x80000000:
                self.cc |= emu6809.CC_N
            if q == 0:
                self.cc |= emu6809.CC_Z
            return True
        if pref == 0x11 and op in (0x8F, 0x9F, 0xAF, 0xBF):   # MULD : Q = D * m (signés)
            un()
            m = self._op(op, 2)
            sd = d - 0x10000 if d & 0x8000 else d
            sm = m - 0x10000 if m & 0x8000 else m
            q = (sd * sm) & 0xFFFFFFFF
            setd(q >> 16)
            self.w = q & 0xFFFF
            self.cc &= ~(emu6809.CC_N | emu6809.CC_Z) & 0xFF
            if q & 0x80000000:
                self.cc |= emu6809.CC_N
            if q == 0:
                self.cc |= emu6809.CC_Z
            return True
        if pref == 0x11 and op in (0x8D, 0x9D, 0xAD, 0xBD, 0x8E, 0x9E, 0xAE, 0xBE):
            # DIVD (D / m8 : B = quotient, A = reste) et DIVQ (Q / m16 : W =
            # quotient, D = reste), signés, quotient tronqué vers zéro (CALC).
            un()
            quad = op & 0x0F == 0x0E
            m = self._op(op, 2 if quad else 1)
            bits = 16 if quad else 8
            sm = m - (1 << bits) if m >> (bits - 1) else m
            if quad:
                n = (d << 16) | self.w
                n = n - (1 << 32) if n & 0x80000000 else n
            else:
                n = d - 0x10000 if d & 0x8000 else d
            if sm == 0:
                raise RuntimeError('DIV%s par zéro en $%04X' % ('Q' if quad else 'D', self.pc))
            qt = abs(n) // abs(sm) * (1 if (n < 0) == (sm < 0) else -1)
            rs = n - qt * sm
            if not -(1 << (bits - 1)) <= qt < (1 << (bits - 1)):
                raise RuntimeError('DIV%s : dépassement en $%04X' % ('Q' if quad else 'D', self.pc))
            qt &= (1 << bits) - 1
            if quad:
                setd(rs & 0xFFFF)
                self.w = qt
            else:
                self.a, self.b = rs & 0xFF, qt
            self.cc &= ~(emu6809.CC_N | emu6809.CC_Z | emu6809.CC_V | emu6809.CC_C) & 0xFF
            if qt >> (bits - 1):
                self.cc |= emu6809.CC_N
            if qt == 0:
                self.cc |= emu6809.CC_Z
            if qt & 1:
                self.cc |= emu6809.CC_C
            return True
        return False

    # --- carte SD : une image OSMFS ---
    def lba(self):
        return (self.rd16(self.s_['BlockAddr']) << 16) | self.rd16(self.s_['BlockAddr'] + 2)

    def sd(self):
        """Intercepte SD_ReadBlock / SD_WriteBlock : vrai si on a servi."""
        if self.pc not in (self.s_['SD_ReadBlock'], self.s_['SD_WriteBlock']):
            return False
        buf = self.s_['SD_BUFFER']
        lecture = self.pc == self.s_['SD_ReadBlock']
        cle = (lecture, self.lba())
        n = self.essais.get(cle, 0)
        code = self.panne(lecture, cle[1], n) if self.panne else 0
        if code:                                # panne simulée : rien de lu/écrit
            self.essais[cle] = n + 1
            if lecture:
                self.mem[buf:buf + 512] = bytes([0xA5]) * 512
            self.a = code
            self.detruit(lecture)
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return True
        self.essais.pop(cle, None)
        with open(self.image, 'rb+') as f:
            f.seek(self.lba() * 512)
            if self.pc == self.s_['SD_ReadBlock']:
                self.mem[buf:buf + 512] = f.read(512).ljust(512, b'\0')
            else:
                f.write(bytes(self.mem[buf:buf + 512]))
        self.a = 0                              # succès
        self.detruit(lecture)
        self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
        self.s += 2
        return True

    def detruit(self, lecture):
        """Les registres que le vrai pilote (bios/SD.asm) laisse : X au bout
        de SD_BUFFER, W = 0, B usé, Y = le compteur d'attente (jeton : 20000
        moins les tours ; fin d'écriture : 40000 moins les tours). La carte
        ne répond jamais au premier tour : Y n'est pas sa valeur de départ."""
        self.x = (self.s_['SD_BUFFER'] + 512) & 0xFFFF
        self.w = 0
        self.b = 0x09
        self.y = (20000 if lecture else 40000) - 37


BIOS2 = os.path.join(RACINE, 'bios', 'BIOS2')


def installe_bios(m, ext=True):
    """Ce que fait le BIOS au démarrage, sans exécuter de code (les bancs
    dérivés ne sont pas encore prêts quand Machine s'initialise) : la table
    des services recopiée de l'EPROM ; les vecteurs ExtV par défaut (la
    table Ext_Def de l'EPROM, comme Ext_Defauts) ; puis la seconde partie
    (bios/BIOS2) posée au début de la section .ext et ses vecteurs (la
    table Ext_Table de BIOS2, comme Ext_Entree)."""
    s = m.s_
    rom, fin = s['table_function_rom'], s['table_function_rom_end']
    for i in range(fin - rom):
        m.mem[s['table_function_ram'] + i] = m.mem[rom + i]
    n = 2 * int(re.search(r'EXTV_N\s+equ\s+(\d+)', open(os.path.join(RACINE, 'bios', 'ext.inc')).read()).group(1))
    m.mem[s['ExtV']:s['ExtV'] + n] = m.mem[s['Ext_Def']:s['Ext_Def'] + n]
    m.mem[s['ext_ok']] = 0
    if not ext or not os.path.exists(BIOS2):
        return
    corps = open(BIOS2, 'rb').read()
    if not corps:
        return
    base = min(int(x, 16) for x in re.findall(r'Section: \.ext \(\S+\) load at ([0-9A-F]+)', open(MAP).read()))
    m.mem[base:base + len(corps)] = corps
    m.mem[s['ExtV']:s['ExtV'] + n] = m.mem[s['Ext_Table']:s['Ext_Table'] + n]
    m.mem[s['ext_ok']] = 1


def appelle(m, adr, max_pas=50_000_000):
    m.s = 0xDF00
    m.s -= 2
    m.mem[m.s], m.mem[m.s + 1] = RETOUR >> 8, RETOUR & 0xFF
    m.pc = adr
    pas = 0
    while m.pc != RETOUR:
        if m.sd():
            continue
        m.step()
        pas += 1
        if m.irq_tous and pas % m.irq_tous == 0 and not (m.cc & 0x10):
            irq_vsync(m)
        if pas > max_pas:
            raise RuntimeError('trop long à $%04X' % m.pc)
    return not (m.cc & 1)                       # C = 0 : succès


def irq_vsync(m):
    """Le retour de trame vu par le moulinet : Spin_IRQ (la part de
    handler_IRQ qui le dessine), registres rendus, comme une IRQ."""
    etat = (m.a, m.b, m.x, m.y, m.u, m.cc, m.pc, m.w)
    s0 = m.s
    m.s -= 14                           # la pile d'une IRQ native
    m.s -= 2
    m.mem[m.s], m.mem[m.s + 1] = RETOUR_IRQ >> 8, RETOUR_IRQ & 0xFF
    m.pc = m.s_['Spin_IRQ']
    m.cc |= 0x50
    m.dans_irq = True
    while m.pc != RETOUR_IRQ:
        m.step()
    m.dans_irq = False
    m.a, m.b, m.x, m.y, m.u, m.cc, m.pc, m.w = etat
    m.s = s0


def nom(m, txt):
    m.mem[NOM:NOM + 15] = txt.ljust(15).encode('ascii')


def save(m, txt, page, adr, taille, appelant=0):
    nom(m, txt)
    m.mem[m.s_['current_page']] = appelant
    m.page = appelant
    m.a, m.x, m.y, m.u = page, NOM, adr, taille
    ok = appelle(m, m.s_['FS_SaveFile'])
    return ok


def load(m, txt, page, adr, appelant=0):
    nom(m, txt)
    m.mem[m.s_['current_page']] = appelant
    m.page = appelant
    m.a, m.x, m.y = page, NOM, adr
    ok = appelle(m, m.s_['FS_LoadFile'])
    return ok, m.u


def lineaire(m, page, adr, n):
    """n octets de la mémoire paginée vus comme un seul espace (page*32K+adr)."""
    out = bytearray()
    p, a = page, adr
    while len(out) < n:
        out.append(m.banks[p][a])
        a += 1
        if a == 0x8000:
            p, a = p + 1, 0
    return bytes(out)


def main():
    s = sym()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    tmp = tempfile.mkdtemp()
    image = os.path.join(tmp, 'carte.img')
    with open(image, 'wb') as f:
        f.truncate(16 * 1024 * 1024)
    core = egofs_core.OSMFS_Core(image)
    with open(os.devnull, 'w') as nul:
        old = sys.stdout
        sys.stdout = nul
        core.format_fs()
        # fichiers déjà présents : 70 000 octets (> 64 Ko) et 65 100 octets
        # (débordait l'ancien calcul (taille + 511) >> 9 sur 16 bits)
        for n, taille in (('PETIT', 300), ('GRAND', 70000), ('PRESQUE64K', 65100)):
            chemin = os.path.join(tmp, n)
            open(chemin, 'wb').write(bytes(random.Random(n).randrange(256) for _ in range(taille)))
            core.inject_file(chemin, n, 1, '0000', 0x07)
        sys.stdout = old

    m = Machine(image, s)
    alea = random.Random(1985)
    m.wr16(s['SCREEN_START_OFFSET'], 0xFFFF)   # comme video_clean : écran en haut
    COIN, COIN2 = carte.adr(78), carte.adr(79)  # cellules du moulinet (rangée 0)
    m.mem[0x8000:0xA000] = bytes(alea.randrange(256) for _ in range(0x2000))
    ecran = bytes(m.mem[0x8000:0xA000])

    # 1. 40 000 octets depuis la page 2 en $0000 : 32 768 en page 2, 7 232 en page 3
    for p in (2, 3):
        m.banks[p][:] = bytes(alea.randrange(256) for _ in range(32768))
    attendu = lineaire(m, 2, 0, 40000)
    m.irq_tous = 1500                   # IRQ ouvertes : le VSYNC dessine le moulinet
    m.cc = 0x00
    m.vram_hors_irq = []
    ok = save(m, 'GROS40K', 2, 0x0000, 40000)
    verifie(ok, 'FS_SaveFile de 40 000 octets, pages 2 puis 3')
    verifie((COIN, ord('E')) in m.vram_ecrits and (carte.adr_coul(78), 0x1F) in m.vram_ecrits
            and (carte.adr_coul(79), 0x1F) in m.vram_ecrits and bytes(m.mem[0x8000:0xA000]) == ecran,
            'moulinet : « E » blanc sur bleu pendant l\'enregistrement, écran intact après (carte %s)'
            % carte.NOM)
    verifie(not m.vram_hors_irq, 'moulinet : VRAM écrite seulement par l\'IRQ du VSYNC %s'
            % ['%04X@%04X' % (a, pc) for a, _, pc in m.vram_hors_irq[:4]])
    verifie(m.page == 0, 'page de l\'appelant rétablie après l\'enregistrement')
    f = {x['name']: x for x in core.list_files()}
    chemin = os.path.join(tmp, 'relu')
    core.extract_file(f['GROS40K']['index'], chemin)
    verifie(open(chemin, 'rb').read() == attendu, 'contenu sur la carte = pages 2 et 3 (relu par egofs)')

    # 2. le nouveau fichier ne recouvre aucun fichier existant
    def recouvrements():
        fl = core.list_files()
        r = []
        for a in fl:
            for b in fl:
                if a['name'] < b['name'] and a['size'] and b['size']:
                    if a['lba'] < b['lba'] + b['sectors'] and b['lba'] < a['lba'] + a['sectors']:
                        r.append((a['name'], b['name']))
        return r
    verifie(not recouvrements(), 'aucun fichier ne se recouvre (dont GRAND > 64 Ko, PRESQUE64K)')

    # 3. relecture en page 2, après effacement des pages 2 et 3
    for p in (2, 3):
        m.banks[p][:] = bytes(32768)
    m.vram_ecrits = []
    m.vram_hors_irq = []
    m.cc = 0x00
    m.irq_tous = 150                    # un chargement va vite : des trames serrées
    ok, taille = load(m, 'GROS40K', 2, 0x0000)
    m.irq_tous = 1500
    verifie(ok and taille == 40000, 'FS_LoadFile de 40 000 octets (U = taille)')
    verifie(lineaire(m, 2, 0, 40000) == attendu, 'relu octet pour octet, à cheval sur les pages 2 et 3')
    car = [v for a, v in m.vram_ecrits if a == COIN2]
    verifie(set(car) >= set(b'|/-\\') and (COIN, ord('L')) in m.vram_ecrits,
            'moulinet : « L » et | / - \\ en haut à droite pendant le chargement')
    verifie(bytes(m.mem[0x8000:0xA000]) == ecran and not m.vram_hors_irq,
            'moulinet : écran intact après le chargement, VRAM écrite seulement par l\'IRQ')
    m.vram_ecrits = []
    m.cc = 0x50                         # IRQ masquées chez l'appelant : pas de moulinet
    ok, _ = load(m, 'GROS40K', 2, 0x0000)
    verifie(ok and not m.vram_ecrits, 'IRQ masquées : chargement sans moulinet, VRAM jamais touchée')
    m.cc = 0x00
    verifie(m.page == 0, 'page de l\'appelant rétablie après le chargement')

    # 4. départ en milieu de page : page 2 en $6000 (8 Ko en page 2, le reste en page 3)
    for p in (2, 3):
        m.banks[p][:] = bytes(32768)
    ok, taille = load(m, 'GROS40K', 2, 0x6000)
    verifie(ok and lineaire(m, 2, 0x6000, 40000) == attendu,
            'chargement en page 2, $6000 : la suite en page 3 dès $0000')

    # 5. au-delà de la page 3 : refus, et les pages 0 et 1 ne sont pas touchées
    for p in range(4):
        m.banks[p][:] = bytes([0x55]) * 32768
    ok, _ = load(m, 'GROS40K', 3, 0x4000)
    verifie(not ok, 'chargement qui dépasserait la page 3 : refusé (C = 1)')
    verifie(m.banks[0] == bytes([0x55]) * 32768 and m.banks[1] == bytes([0x55]) * 32768,
            'pages 0 et 1 intactes après le refus')
    verifie(not m.mauvaise_page, 'aucune page > 3 écrite dans $A0C0 %s' % m.mauvaise_page)

    # 6. petit fichier sans changement de page, appelant en page 1
    m.banks[1][0x1000:0x1000 + 300] = bytes(range(256)) + bytes(range(44))
    ok = save(m, 'PETIT2', 1, 0x1000, 300, appelant=1)
    verifie(ok and m.page == 1, 'petit FS_SaveFile depuis la page 1, appelant en page 1 rétabli')
    m.banks[3][0x2000:0x2000 + 300] = bytes(300)
    m.vram_ecrits = []
    ok, taille = load(m, 'PETIT2', 3, 0x2000, appelant=1)
    verifie(not m.vram_ecrits, 'moulinet : rien à l\'écran pour un petit fichier (1 secteur)')
    verifie(ok and taille == 300 and m.banks[3][0x2000:0x2000 + 300] == m.banks[1][0x1000:0x1000 + 300]
            and m.page == 1, 'petit FS_LoadFile en page 3, appelant en page 1 rétabli')

    # 7. mémoire commune (Y >= $8000) : copie directe
    m.mem[0xDC00:0xDC00 + 300] = bytes(300)
    ok, taille = load(m, 'PETIT2', 0, 0xDC00)
    verifie(ok and bytes(m.mem[0xDC00:0xDC00 + 300]) == m.banks[1][0x1000:0x1000 + 300],
            'chargement en mémoire commune ($D000, zone libre)')

    # 8. 32 768 octets pile (page 2 entière) puis un fichier derrière
    m.banks[2][:] = bytes(alea.randrange(256) for _ in range(32768))
    ok = save(m, 'PAGE2', 2, 0, 32768)
    m.banks[2][:] = bytes(32768)
    ok2, taille = load(m, 'PAGE2', 3, 0)          # page 3 pleine : pas de page 4
    verifie(ok and ok2 and taille == 32768 and not m.mauvaise_page,
            'exactement 32 Ko jusqu\'à la fin de la page 3 : pas de page 4')
    verifie(not recouvrements(), 'toujours aucun recouvrement après tous les enregistrements')

    # 9. carte capricieuse : un secteur de données sur trois rate au premier
    #    essai (lecture et écriture) ; le BIOS réessaie, le fichier passe
    m.mem[s['sd_retry']] = 0
    m.panne = lambda lecture, lba, essai: 0xE2 if (lba >= 257 and lba % 3 == 0 and essai == 0) else 0
    for p in (2, 3):
        m.banks[p][:] = bytes(alea.randrange(256) for _ in range(32768))
    attendu = lineaire(m, 2, 0, 40000)
    ok = save(m, 'CAPRICE', 2, 0, 40000)
    for p in (2, 3):
        m.banks[p][:] = bytes(32768)
    ok2, taille = load(m, 'CAPRICE', 2, 0)
    verifie(ok and ok2 and lineaire(m, 2, 0, 40000) == attendu,
            'erreurs SD passagères : 40 Ko enregistrés puis relus intacts')
    verifie(m.mem[s['sd_retry']] > 20 and m.mem[s['sd_err']] == 0xE2,
            'sd_retry compte les nouvelles tentatives (%d), sd_err = $%02X'
            % (m.mem[s['sd_retry']], m.mem[s['sd_err']]))
    # 10. un secteur définitivement illisible : échec propre après 4 essais
    f = {x['name']: x for x in core.list_files()}
    mort = f['CAPRICE']['lba'] + 10
    m.essais = {}
    m.panne = lambda lecture, lba, essai: 0xE1 if (lecture and lba == mort) else 0
    ok, _ = load(m, 'CAPRICE', 2, 0)
    verifie(not ok and m.essais.get((True, mort)) == 4 and m.mem[s['sd_err']] == 0xE1,
            'secteur illisible : échec (C = 1) après 4 essais, sd_err = $E1')
    verifie(m.page == 0 and not m.mauvaise_page, 'page de l\'appelant rétablie après l\'échec')
    m.panne = None

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
