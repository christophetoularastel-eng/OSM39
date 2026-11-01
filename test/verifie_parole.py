#!/usr/bin/env python3
# ===================================================================
# verifie_parole.py - Le binaire apps/PAROLE fait-il ce que dit le modèle ?
# ===================================================================
# Fait tourner le VRAI binaire apps/PAROLE (chargé à son adresse, $0000) dans le cœur
# 6809 de asm/emu6809.py, complété des quelques instructions 6309 que
# PAROLE utilise, et le compare au modèle tools/parole/parole.py :
#   1. table sinus x amplitude ($7000-$7FFF) construite par Build_SinAmp ;
#   2. texte normalisé (Normalise) pour une série de phrases, aux espaces
#      près (plusieurs espaces = une frontière de mot pour les règles) ;
#   3. trames (Build_Frames), octet par octet, groupe par groupe ;
#   4. échantillons envoyés à l'AY (Play, boucle automodifiante) pour une
#      phrase courte : drapeau du timer 3 toujours levé, écritures de
#      l'AY enregistrées (registre, valeur) : mixeur $3F, puis pour chaque
#      échantillon s, R8 = TabA[s] et R10 = TabC[s] (tables_ay() du
#      modèle, relues dans le binaire), volumes à 0 à la fin.
# Les services vis_* (sa copie de lib/vision.asm) sont remplacés par des
# RTS dans SA table VIS_TABLE. Lancer après make -C apps PAROLE.
#   python3 test/verifie_parole.py
# ===================================================================
import os
import re
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, os.path.join(RACINE, 'asm'))
sys.path.insert(0, os.path.join(RACINE, 'tools', 'parole'))
import emu6809                  # noqa: E402
import parole                   # noqa: E402

BIN = os.path.join(RACINE, 'apps', 'PAROLE')
MAP = os.path.join(RACINE, 'apps', 'PAROLE.map')
RETOUR = 0xFFF0                 # adresse de retour sentinelle
STUB = 0x6F00                   # RTS pour les services vis_* (sous la table $7000)
STATUS = 0xA081
AY_ADR, AY_DATA = 0xA150, 0xA151

PHRASES = [
    "Bonjour, je suis OSM 39. Je parle français !",
    "Bienvenue dans le monde de l'informatique de 1985.",
    "Quel temps fait-il aujourd'hui ?",
    "C'est génial, j'adore !",
    "Le petit chat gris mange une souris dans le grenier.",
    "Mon fils a un ESP32 ; moi, un 6309 de 71 ans, 80 ou 99 ?",
    "a e i o u, 0 7 17 21 100 1000 2026 12345",
]


class CPU6309(emu6809.CPU6809):
    """Le cœur 6809, plus les instructions 6309 de PAROLE et un 6840."""

    def __init__(self):
        super().__init__()
        self.w = 0
        self.ecrits = []        # écritures de l'AY : (registre, valeur)
        self.ay_reg = 0

    def rd8(self, a):
        if a & 0xFFFF == STATUS:
            return 0x04         # drapeau du timer 3 : toujours levé
        return super().rd8(a)

    def wr8(self, a, v):
        if a & 0xFFFF == AY_ADR:
            self.ay_reg = v & 0x0F
        elif a & 0xFFFF == AY_DATA:
            self.ecrits.append((self.ay_reg, v & 0xFF))
        super().wr8(a, v)

    def wr16(self, a, v):                       # STD AY_ADR : registre puis valeur
        self.wr8(a, (v >> 8) & 0xFF)
        self.wr8(a + 1, v & 0xFF)

    def _d(self):
        return (self.a << 8) | self.b

    def _setd(self, v):
        v &= 0xFFFF
        self.a, self.b = v >> 8, v & 0xFF
        self.cc &= ~(emu6809.CC_N | emu6809.CC_Z | emu6809.CC_V) & 0xFF
        if v & 0x8000:
            self.cc |= emu6809.CC_N
        if v == 0:
            self.cc |= emu6809.CC_Z

    def _carry(self, c):
        self.cc = (self.cc | emu6809.CC_C) if c else (self.cc & ~emu6809.CC_C & 0xFF)

    def execute_pref(self, pref):
        op = self.mem[self.pc]
        if pref == 0x10 and op in (0x48, 0x44, 0x47, 0x84, 0x86):
            self.pc = (self.pc + 1) & 0xFFFF
            self.steps += 1
            d = self._d()
            if op == 0x48:                      # LSLD
                self._setd(d << 1)
                self._carry(d & 0x8000)
            elif op == 0x44:                    # LSRD
                self._setd(d >> 1)
                self._carry(d & 1)
            elif op == 0x47:                    # ASRD
                self._setd((d >> 1) | (d & 0x8000))
                self._carry(d & 1)
            elif op == 0x84:                    # ANDD #
                self._setd(d & self.fet16())
            else:                               # LDW #
                self.w = self.fet16()
            return
        if pref == 0x11 and op == 0x86:         # LDE #
            self.pc = (self.pc + 2) & 0xFFFF
            self.steps += 1
            return
        super().execute_pref(pref)


def symboles():
    s = {}
    for nom, v in re.findall(r'Symbol: (\S+) \(parole\.o\) = ([0-9A-F]{4})', open(MAP).read()):
        s[nom] = int(v, 16)
    return s


def machine():
    cpu = CPU6309()
    data = open(BIN, 'rb').read()
    base = int(re.search(r'Section: \.code \(parole\.o\) load at ([0-9A-F]{4})', open(MAP).read()).group(1), 16)
    cpu.mem[base:base + len(data)] = data
    assert base + len(data) <= STUB, 'PAROLE recouvre STUB'
    cpu.mem[STUB] = 0x39                        # RTS
    table = symboles()['VIS_TABLE']             # sa table des services
    for k in range(cpu.mem[symboles()['VIS_COUNT_ADR']]):
        cpu.wr16(table + 2 * k, STUB)
    return cpu


def appelle(cpu, adr, arret=None, max_pas=60_000_000):
    """JSR adr ; s'arrête au retour, ou quand arret(cpu) rend vrai."""
    cpu.s = 0xDF00
    cpu.s -= 2
    cpu.wr16(cpu.s, RETOUR)
    cpu.pc = adr
    pas = 0
    while cpu.pc != RETOUR:
        if arret and arret(cpu):
            continue
        cpu.step()
        pas += 1
        if pas > max_pas:
            raise RuntimeError('trop long à $%04X' % cpu.pc)


def trame_octets(t):
    i1, i2, i3, m, a1, a2, a3, per = t
    return bytes([i1 >> 8, i1 & 255, i2 >> 8, i2 & 255, i3 >> 8, i3 & 255, m >> 8, m & 255,
                  0x70 + a1, 0x70 + a2, 0x70 + a3, per])


def main():
    sym = symboles()
    erreurs = 0
    cpu = machine()

    # 1. table sinus x amplitude
    appelle(cpu, sym['Build_SinAmp'])
    attendu = bytes(v & 0xFF for rang in parole.SIN for v in rang)
    if bytes(cpu.mem[0x7000:0x8000]) != attendu:
        print('ÉCHEC : table sinus x amplitude')
        erreurs += 1
    else:
        print('OK   table sinus x amplitude (4096 octets)')

    for n, phrase in enumerate(PHRASES):
        octets = phrase.encode('latin-1')
        assert len(octets) <= sym['InEnd'] - sym['InBuf'], 'phrase trop longue pour InBuf'
        cpu.mem[sym['InBuf']:sym['InBuf'] + len(octets)] = octets
        cpu.mem[sym['InLen']] = len(octets)
        cpu.mem[sym['Voix']] = 0

        # 2. normalisation
        appelle(cpu, sym['Normalise'])
        nb = sym['NormBuf']
        fin = cpu.mem.index(0, nb)
        obtenu = bytes(cpu.mem[nb:fin]).decode('latin-1')
        attendu = '  ' + parole.normalise(phrase) + ' '
        # plusieurs espaces = une frontière de mot pour les règles : on
        # compare aux espaces près (Num_Words en met un après « cent »)
        if obtenu.split(' ') != attendu.split(' ') and ' '.join(obtenu.split()) != ' '.join(attendu.split()):
            print('ÉCHEC normalisation : %r\n  6309   : %r\n  modèle : %r' % (phrase, obtenu, attendu))
            erreurs += 1
            continue

        # 3. trames, groupe par groupe (Play intercepté)
        groupes_asm = []
        echantillons = (n == 2)             # une phrase courte : Play complet

        def arret(c):
            if c.pc == sym['Play'] and not getattr(c, 'dans_play', False):
                deb, fp = sym['FrBuf'], c.rd16(sym['FrPtr'])
                groupes_asm.append(bytes(c.mem[deb:fp]))
                if echantillons:
                    c.dans_play = True
                    return False
                c.pc = c.rd16(c.s)          # RTS simulé
                c.s += 2
                return True
            if c.pc == sym['P_Fin']:
                c.dans_play = False
            return False

        cpu.ecrits = []
        appelle(cpu, sym['Parse_Speak'], arret)
        groupes_py = parole.texte_en_groupes(phrase)
        trames_py = parole.groupes_en_trames(groupes_py)
        asm = b''.join(groupes_asm)
        py = b''.join(trame_octets(t) for t in trames_py)
        if asm != py:
            k = next(i for i in range(min(len(asm), len(py)) + 1)
                     if i >= min(len(asm), len(py)) or asm[i] != py[i])
            print('ÉCHEC trames : %r (%d / %d octets, 1re différence trame %d)'
                  % (phrase, len(asm), len(py), k // 12))
            print('  6309   :', asm[k // 12 * 12:k // 12 * 12 + 12].hex(' '))
            print('  modèle :', py[k // 12 * 12:k // 12 * 12 + 12].hex(' '))
            erreurs += 1
            continue
        print('OK   %r : %d groupes, %d trames' % (phrase, len(groupes_asm), len(trames_py)))

        # 4. échantillons (une phrase)
        if echantillons:
            w = cpu.ecrits
            ta, tc = parole.tables_ay()
            ok = list(cpu.mem[sym['TabA']:sym['TabA'] + 121]) == ta \
                and list(cpu.mem[sym['TabC']:sym['TabC'] + 121]) == tc
            if not ok:
                print('ÉCHEC : TabA / TabC du binaire différentes de tables_ay()')
            # Un Play par groupe : mixeur, couple de MILIEU (Ouvre_Dac) ;
            # chaque échantillon sort à la tranche B suivante (le dernier
            # calculé ne sort pas) ; volumes à 0 (Ferme_Dac).
            attendu = []
            for g in groupes_py:
                s_py = parole.synthese(parole.groupes_en_trames([g]))
                attendu += [(7, 0x3F), (8, ta[parole.MILIEU]), (10, tc[parole.MILIEU])]
                for x in [parole.MILIEU] + s_py[:-1]:
                    attendu += [(8, ta[x]), (10, tc[x])]
                attendu += [(8, 0), (10, 0)]
            if ok and w != attendu:
                k = next((i for i in range(min(len(w), len(attendu))) if w[i] != attendu[i]), None)
                print('ÉCHEC écritures de l\'AY : %d sur la carte, %d au modèle, 1re différence %s'
                      % (len(w), len(attendu), k))
                ok = False
            if ok:
                print('OK   échantillons de %r : %d écritures de l\'AY, identiques au modèle'
                      % (phrase, len(w)))
            else:
                erreurs += 1

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', erreurs))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
