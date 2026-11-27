#!/usr/bin/env python3
# ===================================================================
# verifie_calcul.py - apps/CALCUL face à son modèle tools/calcul/calcul.py
# ===================================================================
# Le VRAI BIOS (EPROM + BIOS2) et le VRAI apps/CALCUL dans l'émulateur
# (page 1, comme OSM-VISION le lance) :
#   1. l'arithmétique appelée directement (Opere + - x ÷, Multiplie avec
#      Decal = 2 pour %, Racine) sur des nombres tirés au hasard (graine
#      fixe) et des cas limites : le résultat (signe, 24 chiffres) et
#      l'Erreur (C = 1) = le modèle, au chiffre près ;
#   2. des séances entières (verifie_bureau.Bureau : le clavier par
#      kbd_poll, le joystick par le port A de l'AY, une trame par lecture) :
#      avant chaque touche et à la fin, les rangées que CALCUL compose
#      (l'écran LCD, les 5 rangées de touches avec la sélection, l'aide)
#      = calcul.Calcul.rangees() (caractères et attributs) ; des séances
#      écrites (enchaînements, %, =, mémoire, Erreur, saisie bornée) et 30
#      au hasard ; une au joystick (pas, répétition, bouton) mêlé au
#      clavier ; les écritures VRAM au plus LIMITE_TRAME cycles estimés
#      après le signal de trame ; Échap rend la main (RTS).
#   make -C apps CALCUL && python3 test/verifie_calcul.py
# ===================================================================
import os
import random
import re
import sys
import tempfile
from fractions import Fraction

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'calcul'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_bureau as vb     # noqa: E402
import carte                    # noqa: E402
import calcul                   # noqa: E402

BIN = os.path.join(RACINE, 'apps', 'CALCUL')
MAP = os.path.join(RACINE, 'apps', 'CALCUL.map')
NB, ND = 25, 24
ECHAP = 0x1B


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


def code(x):
    """Un nombre du modèle -> ses NB octets (signe, 24 chiffres)."""
    n = int(abs(x) * 10 ** 11)
    assert n == abs(x) * 10 ** 11 and n < 10 ** 23
    return bytes([1 if x < 0 else 0]) + bytes(int(c) for c in str(n).rjust(ND, '0'))


def decode(b):
    n = int(''.join(str(c) for c in b[1:NB]))
    return Fraction(-n if b[0] else n, 10 ** 11)


def hasard(r):
    """Un nombre gardable : 1-12 chiffres significatifs, de 10^11 à 10^-11."""
    if r.random() < 0.05:
        return Fraction(0)
    k = r.choice([1, 1, 2, 3, 4, 6, 8, 10, 12, 12, 12])
    haut = r.randint(-11 + k - 1, 11)
    chiffres = [r.randint(1, 9)] + [r.randint(0, 9) for _ in range(k - 1)]
    n = int(''.join(map(str, chiffres)))
    x = Fraction(n) * Fraction(10) ** (haut - k + 1)
    return -x if r.random() < 0.5 else x


class Arith:
    """CALCUL chargé en page 1 ; les routines appelées une à une."""

    def __init__(self, s, a):
        d = tempfile.mkdtemp()
        self.c = va.Carte(d)
        self.m = va.MachineAsm(self.c.image, s)
        v.installe_bios(self.m)
        b = open(BIN, 'rb').read()
        self.m.banks[1][:len(b)] = b
        self.m.mem[s['current_page']] = 1
        self.m.page = 1
        self.a = a

    def pose(self, nom, x):
        self.m.banks[1][self.a[nom]:self.a[nom] + NB] = code(x)

    def lance(self, routine, a=0, x=None, y=None, decal=None):
        m = self.m
        self.pose('OpA', x)
        if y is not None:
            self.pose('OpB', y)
        if decal is not None:
            m.banks[1][self.a['Decal']] = decal
        m.banks[1][self.a['Res']:self.a['Res'] + NB] = bytes([0x5A] * NB)
        m.a = a
        ok = v.appelle(m, self.a[routine], 5_000_000)
        if not ok:
            return None
        return decode(bytes(m.banks[1][self.a['Res']:self.a['Res'] + NB])), \
            bytes(m.banks[1][self.a['Res']:self.a['Res'] + NB])


class Seance(vb.Bureau):
    """CALCUL seul (page 1) ; avant chaque touche du clavier, les rangées
    composées sont relevées."""

    def __init__(self, image, s, touches):
        super().__init__(image, s, touches)
        self.vues = []

    def releve(self):
        r = {}
        for y in calcul.Calcul().rangees():
            car, att = carte.lit(self.mem, (calcul.WIN_Y + y) * 80 + calcul.WIN_X + 1, calcul.LARGE)
            r[y] = (bytes(car), bytes(att))
        self.vues.append(r)

    def step(self):
        if self.pc == self.s_['kbd_poll'] and (not self.touches or not isinstance(self.touches[0], tuple)):
            self.releve()
        super().step()


def seance(s, touches):
    d = tempfile.mkdtemp()
    c = va.Carte(d)
    m = Seance(c.image, s, touches)
    m.mesure_cycles = True
    v.installe_bios(m)
    b = open(BIN, 'rb').read()
    m.banks[1][:len(b)] = b
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 1
    m.page = 1
    try:
        v.appelle(m, 0x0000, 200_000_000)
        r = 'rendu'
    except vb.Fini:
        r = 'touches'
    return m, r


class JoyModele:
    """Joy_Evts de lib/joy.asm (une lecture par trame)."""
    def __init__(self):
        self.prec = self.tenu = self.rep = 0

    def evts(self, std):
        b = std & self.prec
        self.prec = std
        a = self.tenu
        self.tenu = b
        nouv = b & ~a & 0xFF
        dirs = self.tenu & 0x0F
        if not dirs:
            out = 0
        elif nouv & 0x0F:
            self.rep = 12
            out = dirs
        else:
            self.rep = (self.rep - 1) & 0xFF
            if self.rep == 0:
                self.rep = 3
                out = dirs
            else:
                out = 0
        return out | (nouv & 0x10)


def attendues(touches):
    """Les vues du modèle aux mêmes instants que Seance.releve."""
    c, j = calcul.Calcul(), JoyModele()
    vues = []
    for t in touches:
        if isinstance(t, tuple):
            contacts, n = t
            std = (contacts & 0x0F) | (0x10 if contacts & 0x20 else 0)
            for _ in range(n):
                e = j.evts(std)
                if e:
                    c.joystick(e)
        else:
            vues.append(c.rangees())
            if t == ECHAP:
                return vues, True
            c.touche(t)
    vues.append(c.rangees())
    return vues, False


def compare(vues, att):
    """-> None, ou (indice, rangée, ce qu'on voit, ce qu'on attend)."""
    if len(vues) != len(att):
        return ('nombre de relevés', len(vues), len(att))
    for i, (vu, at) in enumerate(zip(vues, att)):
        for y in at:
            if vu[y] != at[y]:
                return (i, y, vu[y][0].decode('cp437'), at[y][0].decode('cp437'), vu[y][1].hex(), at[y][1].hex())
    return None


def texte_touches(t):
    return [ord(ch) for ch in t]


def main():
    s = v.sym()
    a = symboles()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    verifie(a.get('App_Start') == 0, 'App_Start à l\'offset 0')

    # --- 1. l'arithmétique ---
    r = random.Random(1789)
    ar = Arith(s, a)
    bornes = [Fraction(0), Fraction(1), Fraction(-1), Fraction(10 ** 12 - 1), Fraction(-(10 ** 12 - 1)),
              Fraction(1, 10 ** 11), Fraction(-1, 10 ** 11), Fraction(999999999999, 10 ** 11),
              Fraction(5, 10 ** 11), Fraction(123456789012), Fraction(1, 3 * 10 ** 10).limit_denominator(10 ** 11),
              Fraction(99999999999, 10 ** 11), Fraction(500000000000), Fraction(2), Fraction(3)]
    bornes = [calcul.arrondi(b) for b in bornes]
    for op, nom, n in (('+', 'addition', 1500), ('-', 'soustraction', 1500), ('*', 'multiplication', 1500),
                       ('/', 'division', 400)):
        faux = []
        paires = [(x, y) for x in bornes for y in bornes] + [(hasard(r), hasard(r)) for _ in range(n)]
        # des opérandes proches (soustractions qui s'annulent, quotients ronds)
        for _ in range(n // 10):
            x = hasard(r)
            paires.append((x, x + Fraction(r.choice([1, -1]), 10 ** 11)) if abs(x) < 10 ** 11 else (x, x))
        for x, y in paires:
            y = calcul.arrondi(y) if calcul.arrondi(y) is not None else Fraction(0)
            att = calcul.opere(x, op, y)
            vu = ar.lance('Opere', ord(op), x, y)
            if (vu[0] if vu else None) != att or (vu and vu[0] == 0 and vu[1][0] != 0):
                faux.append((str(x), op, str(y), str(vu[0]) if vu else 'Erreur', str(att) if att is not None else 'Erreur'))
        verifie(not faux, '%s : %d cas = le modèle%s' % (nom, len(paires), '' if not faux else ' FAUX : %s' % faux[:3]))

    faux, n = [], 0
    for x, y in [(x, y) for x in bornes for y in bornes[:6]] + [(hasard(r), hasard(r)) for _ in range(600)]:
        n += 1
        att = calcul.arrondi(x * y / 100)
        vu = ar.lance('Multiplie', 0, x, y, decal=2)
        if (vu[0] if vu else None) != att:
            faux.append((str(x), str(y), str(vu[0]) if vu else 'Erreur', str(att)))
    verifie(not faux, '%% (Multiplie, Decal = 2) : %d cas = le modèle%s' % (n, '' if not faux else ' FAUX : %s' % faux[:3]))

    faux, n = [], 0
    for x in bornes + [abs(hasard(r)) for _ in range(300)] + [hasard(r) for _ in range(30)] \
            + [Fraction(k * k) for k in range(12)] + [Fraction(k * k, 10 ** 10) for k in range(1, 10)]:
        n += 1
        att = calcul.racine(x)
        vu = ar.lance('Racine', 0, x)
        if (vu[0] if vu else None) != att:
            faux.append((str(x), str(vu[0]) if vu else 'Erreur', str(att)))
    verifie(not faux, 'racine : %d cas = le modèle%s' % (n, '' if not faux else ' FAUX : %s' % faux[:3]))

    # --- 2. des séances ---
    ecrites = ['0.1+0.2=', '2/3=*3=', '2*3===', '200+10%=', '200*10%=', '50-10%=',
               '999999999999+1=c5+5=', '999999999999*2=12', '1/0=+5c7', '2nv', '2v*=', 'c9v',
               '1234567890123456', '.123456789012345', '0000.5', '12.5', 'nn3n',
               '5p3pr', 'c2mrem', '7p+r=', '5+=', '5+-*/3=', '8-3=', '-3=', '3.14159**2=',
               '1+2+3+4=', '100/7=', '1/3=+1/3=', '.00000000001/2=', '.00000000001/3=',
               '123.45\x08\x08\x08\x089', '12.\x08\x08\x08', '0.5\x08\x08n',
               '1e2', '9xX*3%', '6,5+1=', '4\r\r', '\x88\x88']
    for t in ecrites:
        touches = texte_touches(t)
        m, rr = seance(s, touches)
        att, _ = attendues(touches)
        d = compare(m.vues, att)
        verifie(rr == 'touches' and d is None and m.cyc_max <= vb.LIMITE_TRAME,
                'séance %-22r : l\'écran = le modèle à chaque touche (%d relevés, VRAM <= %d cycles)%s'
                % (t, len(att), m.cyc_max, '' if d is None else ' DIFF : %s' % (d,)))

    jeu = [ord(ch) for ch in '0123456789012345678.....++--**//==%vnpmrec'] + [0x08, 0x08, 0x88, ord(',')]
    faux = []
    for k in range(30):
        touches = [r.choice(jeu) for _ in range(r.randint(20, 70))]
        m, rr = seance(s, touches)
        att, _ = attendues(touches)
        d = compare(m.vues, att)
        if rr != 'touches' or d is not None or m.cyc_max > vb.LIMITE_TRAME:
            faux.append((bytes(touches), d, m.cyc_max))
    verifie(not faux, '30 séances au hasard : l\'écran = le modèle à chaque touche%s'
            % ('' if not faux else ' FAUX : %s' % (faux[0],)))

    # le joystick (le brochage de la Clouris, sans /BIN/JOYSTICK.CFG) :
    # haut 1, droite 2, bas 4, gauche 8, bouton $20 ; un appui compte vu
    # deux trames, se répète après 12 puis toutes les 3
    H, D_, B, G, BT = 1, 2, 4, 8, 0x20
    touches = [(0, 3), (H, 3), (0, 2), (H, 2), (0, 2), (G, 2), (0, 2), (BT, 2), (0, 2),    # 9 : appuyé
               ord('+'),
               (B, 30), (0, 2), (D_, 3), (0, 2), (BT, 3), (0, 2),                            # tenu : répété
               (G | H, 3), (0, 2), (BT, 2), (BT, 2), (0, 2), (B, 2), (0, 2), (BT, 2), (0, 3),
               ord('2'), (D_, 40), (0, 2), (BT, 2), (0, 2), ord('c'), (H, 40), (0, 2), (BT, 2), (0, 2)]
    m, rr = seance(s, touches)
    att, _ = attendues(touches)
    d = compare(m.vues, att)
    verifie(rr == 'touches' and d is None and m.cyc_max <= vb.LIMITE_TRAME,
            'joystick : pas, répétition, diagonale, bouton, mêlés au clavier : l\'écran = le modèle (VRAM <= %d cycles)%s'
            % (m.cyc_max, '' if d is None else ' DIFF : %s' % (d,)))

    m, rr = seance(s, texte_touches('12+3') + [ECHAP])
    verifie(rr == 'rendu', 'Échap : CALCUL rend la main (RTS)')

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
