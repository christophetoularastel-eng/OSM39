#!/usr/bin/env python3
# ===================================================================
# simule_crt2.py - Simulation logique de la carte vidéo CRT2, d'après KiCad
# ===================================================================
# Lit la netlist du schéma (kicad-cli 10) et rejoue la carte : quartz
# 25,175 MHz, 74F163 (horloge caractère, ~LOAD), 74HCT166 (sérialiseur),
# RAM caractères et couleurs (KM62256), police (KM28C64A, contenu =
# video/font_osm39.bin), verrous, multiplexeurs, portes, tampons 74HCT245
# et un 6845 COMPORTEMENTAL (MA, RA, DE : seul circuit non pris porte à
# porte). Le bus du 6309 (mode E, 1,8432 MHz) est rejoué par le banc.
#
# Moteur à événements et modèles de portes : tools/carte_sd_kbd_son/simule.py.
#
# Contrôles :
#   1. mode texte : la nouvelle carte sort EXACTEMENT les mêmes pixels
#      (R, G, B à chaque pixel) que l'ancienne (osm09-CRT2 avant le mode
#      graphique, netlist de référence) ;
#   2. mode graphique (verrou $A120, D3) : à chaque chargement du 166, U112
#      voit l'adresse RA x 2048 + (MA & 2047) ; les pixels sortis sont ses
#      octets, avec la couleur de la cellule (alignement = celui du texte) ;
#   3. une écriture du CPU en mode graphique, pendant l'affichage, tombe à
#      l'adresse page x 4096 + offset (le CPU garde l'adressage par page) ;
#   4. marges au front de chargement du 166 (données zv stables avant).
# Délais : valeurs typiques supposées (DELAIS ci-dessous), pas mesurées.
#
#   python3 tools/crt2/simule_crt2.py [carte.kicad_sch | netlist.xml] [--ref ancienne.xml]
#   (--ref par défaut : tools/crt2/crt2_avant_graphique.xml, la carte du
#    18 oct. 2026 avant le mode graphique, pour le contrôle 1)
# ===================================================================
import os
import random
import sys
import xml.etree.ElementTree as ET

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, os.path.join(RACINE, 'tools', 'carte_sd_kbd_son'))
import simule as base           # noqa: E402

SCH = '/home/christophe/Documents/kicad/OSM09/osm09-CRT2/osm09-CRT.kicad_sch'
POLICE = os.path.join(RACINE, 'video', 'font_osm39.bin')

PIXEL = 39.72                   # ns, 25,175 MHz
# Délais supposés (ns) : typiques à 5 V ; la RAM et la police d'après leur
# référence (-10 : 100 ns ; 28C64 -25 : 250 ns), le 6845 d'après sa famille.
DELAIS = {'86': 12, '175': 16, '166': 18, '163': 6, '245': 10,
          'ram_acces': 100, 'ram_oe': 40, 'ram_flot': 30,
          'eep_acces': 250, 'eep_oe': 35, 'eep_flot': 30,
          '6845': 120}
SETUP_166 = 15


class Sim(base.Sim):
    def __init__(self):
        super().__init__()
        self.verif_maintien = []
        self.compteurs = {}
        self.pilotes = {}
        self.ay = None
        self.bus = {}                   # net -> {pilote: valeur ou None}
        self.conflits = []

    def pilote(self, net, qui, v, apres):
        """Une sortie trois états : la valeur du net = celle du seul pilote
        actif ; aucun : il garde sa valeur (capacité) ; deux : conflit."""
        cle = '%s@%s' % (net, qui)
        self.pose(cle, v, apres)
        if cle not in self.ecoute:
            def f(_n, _a, val, net=net, qui=qui):
                d = self.bus.setdefault(net, {})
                d[qui] = val
                actifs = {k: x for k, x in d.items() if x is not None}
                if len(actifs) > 1 and len(set(actifs.values())) > 1:
                    self.conflits.append('%7.0f ns  %s : %s' % (self.t, net, actifs))
                if actifs:
                    self.pose(net, list(actifs.values())[-1], 0)
            self.sur(cle, f)


def charge_netlist(chemin):
    if chemin.endswith('.xml'):
        t = ET.parse(chemin).getroot()
        val = {c.get('ref'): (c.findtext('value') or '') for c in t.iter('comp')}
        broche = {}
        for n in t.iter('net'):
            for x in n.iter('node'):
                broche[(x.get('ref'), x.get('pin'))] = n.get('name')
        return val, broche
    return base.netlist(chemin)


class Carte:
    def __init__(self, netlist, registres, police):
        self.sim = sim = Sim()
        self.val, self.broche = netlist
        self.r = registres
        self.ram = {}
        base.construit(sim, {k: v for k, v in self.val.items()
                             if not v.upper().replace('HCT', 'HC').endswith(('HC86', 'HC175', 'HC166', 'HC245'))},
                       self.broche, 1.0)
        self.pixels = []                # (t, R, G, B) à chaque pixel
        self.chargements = []           # (t, adresse U112, zv, couleur latchée)
        for ref, v in sorted(self.val.items()):
            u = v.upper().replace('HCT', 'HC')
            if u.endswith('HC86'):
                self.xor(ref)
            elif u.endswith('HC175'):
                self.b175(ref)
            elif u.endswith('HC166'):
                self.s166(ref)
            elif u.endswith('HC245'):
                self.t245(ref)
            elif u.endswith('F163'):
                self.c163(ref)
            elif 'KM62256' in u:
                self.ram[ref] = bytearray(32768)
                self.r62256(ref)
            elif '28C64' in u:            # KM28C64A (CRT2), AT28C64 (mono)
                self.eeprom(ref, police)
            elif u == 'MC6845':
                self.crtc(ref)
            elif ref.startswith('X'):
                self.quartz(ref)
        sim.val['/~{RESET}'] = 1
        for n in ('/E', '/~{8000-9FFF}', '/~{A100-A17F}', '/R/~{WR}'):
            pass
        self.bus_repos()

    def P(self, ref, pin):
        return self.broche.get((ref, str(pin)), '%s.%s-libre' % (ref, pin))

    # --- circuits ---
    def xor(self, ref):
        sim = self.sim
        for a, b, y in ((1, 2, 3), (4, 5, 6), (9, 10, 8), (12, 13, 11)):
            na, nb, ny = self.P(ref, a), self.P(ref, b), self.P(ref, y)

            def f(*_, na=na, nb=nb, ny=ny):
                sim.pose(ny, sim.lit(na) ^ sim.lit(nb), DELAIS['86'])
            sim.sur(na, f)
            sim.sur(nb, f)
            f()

    def b175(self, ref):
        sim = self.sim
        mr, cp = self.P(ref, 1), self.P(ref, 9)
        etages = [(4, 2, 3), (5, 7, 6), (12, 10, 11), (13, 15, 14)]

        def fcp(net, ancien, v):
            if ancien == 0 and v == 1 and sim.lit(mr):
                for d, q, nq in etages:
                    x = sim.lit(self.P(ref, d))
                    sim.pose(self.P(ref, q), x, DELAIS['175'])
                    sim.pose(self.P(ref, nq), 1 - x, DELAIS['175'])

        def fmr(net, ancien, v):
            if not v:
                for d, q, nq in etages:
                    sim.pose(self.P(ref, q), 0, DELAIS['175'])
                    sim.pose(self.P(ref, nq), 1, DELAIS['175'])
        sim.sur(cp, fcp)
        sim.sur(mr, fmr)

    def c163(self, ref):
        sim = self.sim
        cp, pe, mr, cep, cet = (self.P(ref, p) for p in (2, 9, 1, 7, 10))
        ds = [self.P(ref, p) for p in (3, 4, 5, 6)]
        qs = [self.P(ref, p) for p in (14, 13, 12, 11)]
        tc = self.P(ref, 15)
        etat = {'n': 8}

        def sortir():
            for i, q in enumerate(qs):
                sim.pose(q, (etat['n'] >> i) & 1, DELAIS['163'])
            sim.pose(tc, 1 if etat['n'] == 15 and sim.lit(cet) else 0, DELAIS['163'])

        def fcp(net, ancien, v):
            if ancien == 0 and v == 1:
                if not sim.lit(mr):
                    etat['n'] = 0
                elif not sim.lit(pe):
                    etat['n'] = sum(sim.lit(d) << i for i, d in enumerate(ds))
                elif sim.lit(cep) and sim.lit(cet):
                    etat['n'] = (etat['n'] + 1) & 15
                sortir()
        sim.sur(cp, fcp)
        sortir()

    def s166(self, ref):
        sim = self.sim
        clk, pe, ce, ds, clr = (self.P(ref, p) for p in (7, 15, 6, 1, 9))
        ent = [self.P(ref, p) for p in (2, 3, 4, 5, 10, 11, 12, 14)]     # A..H
        qh = self.P(ref, 13)
        etat = {'r': 0}
        self.zv = ent

        def fclk(net, ancien, v):
            if ancien == 0 and v == 1 and not sim.lit(ce) and sim.lit(clr):
                if not sim.lit(pe):
                    for e in ent:
                        m = sim.t - sim.stable_depuis(e, sim.t)
                        self.marges.append(m)
                        if m < SETUP_166:
                            sim.alerte('%s : %s changée %d ns avant le chargement (setup %d)' % (ref, e, m, SETUP_166))
                    etat['r'] = sum(sim.lit(e) << i for i, e in enumerate(ent))
                    self.au_chargement()
                else:
                    etat['r'] = ((etat['r'] << 1) | sim.lit(ds)) & 0xFF
                sim.pose(qh, (etat['r'] >> 7) & 1, DELAIS['166'])
        sim.sur(clk, fclk)
        self.marges = []

    def t245(self, ref):
        sim = self.sim
        sens, oe = self.P(ref, 1), self.P(ref, 19)
        a = [self.P(ref, p) for p in range(2, 10)]
        b = [self.P(ref, p) for p in (18, 17, 16, 15, 14, 13, 12, 11)]

        def f(*_):
            actif = not sim.lit(oe)
            for x, y in zip(a, b):
                if actif and sim.lit(sens):           # A -> B
                    sim.pilote(y, ref, sim.lit(x), DELAIS['245'])
                    sim.pilote(x, ref, None, DELAIS['245'])
                elif actif:                           # B -> A
                    sim.pilote(x, ref, sim.lit(y), DELAIS['245'])
                    sim.pilote(y, ref, None, DELAIS['245'])
                else:
                    sim.pilote(x, ref, None, DELAIS['245'])
                    sim.pilote(y, ref, None, DELAIS['245'])
        for n in [sens, oe] + a + b:
            sim.sur(n, f)

    def r62256(self, ref):
        sim = self.sim
        noms = {}
        for (r, p), n in self.broche.items():
            if r == ref:
                noms[int(p)] = n
        # brochage du 62256
        adr = [noms[p] for p in (10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 1)]     # A0..A14
        dq = [noms[p] for p in (11, 12, 13, 15, 16, 17, 18, 19)]
        cs, oe, we = noms[20], noms[22], noms[27]
        mem = self.ram[ref]

        def adresse():
            return sum(sim.lit(a) << i for i, a in enumerate(adr))

        def lecture(*_):
            if not sim.lit(cs) and not sim.lit(oe) and sim.lit(we):
                o = mem[adresse()]
                for i, d in enumerate(dq):
                    sim.pilote(d, ref, (o >> i) & 1, DELAIS['ram_acces'])
            else:
                for d in dq:
                    sim.pilote(d, ref, None, DELAIS['ram_flot'])

        def fwe(net, ancien, v):
            if ancien == 0 and v == 1 and not sim.lit(cs):      # fin d'écriture
                mem[adresse()] = sum(sim.lit(d) << i for i, d in enumerate(dq))
                self.ecritures.append((ref, adresse(), mem[adresse()]))
            lecture()
        for n in adr + [cs, oe]:
            sim.sur(n, lecture)
        sim.sur(we, fwe)
        self.adr_ram = getattr(self, 'adr_ram', {})
        self.adr_ram[ref] = adresse
        self.ecritures = getattr(self, 'ecritures', [])

    def eeprom(self, ref, police):
        sim = self.sim
        noms = {int(p): n for (r, p), n in self.broche.items() if r == ref}
        adr = [noms[p] for p in (10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2)]           # A0..A12
        dq = [noms[p] for p in (11, 12, 13, 15, 16, 17, 18, 19)]
        ce, oe = noms[20], noms[22]
        etat = {'adr_t': 0, 'oe_t': 0}

        def f(net, ancien, v):
            if net in adr:
                etat['adr_t'] = sim.t
            if net == oe and v == 0:
                etat['oe_t'] = sim.t
            if not sim.lit(ce) and not sim.lit(oe):
                a = sum(sim.lit(x) << i for i, x in enumerate(adr))
                o = police[a]
                pret = max(etat['adr_t'] + DELAIS['eep_acces'], etat['oe_t'] + DELAIS['eep_oe']) - sim.t
                for i, d in enumerate(dq):
                    sim.pilote(d, ref, (o >> i) & 1, max(1, pret))
            else:
                for d in dq:
                    sim.pilote(d, ref, None, DELAIS['eep_flot'])
        for n in adr + [ce, oe]:
            sim.sur(n, f)

    def crtc(self, ref):
        """6845 comportemental : MA, RA, DE changent DELAIS['6845'] ns après le
        front descendant de CLK (horloge caractère)."""
        sim = self.sim
        clk = self.P(ref, 21)
        ma = [self.P(ref, p) for p in range(4, 18)]
        ra = [self.P(ref, p) for p in (38, 37, 36, 35, 34)]
        de, cur = self.P(ref, 18), self.P(ref, 19)
        self.fils_crtc = (ma, ra, de)
        r = self.r
        etat = {'c': 0, 'ligne': 0}

        def sortir():
            c, ligne = etat['c'], etat['ligne']
            rangee, sous = divmod(ligne, r['R9'] + 1)
            m = (r['debut'] + rangee * r['R1'] + c) & 0x3FFF
            visible = c < r['R1'] and rangee < r['R6']
            for i, x in enumerate(ma):
                sim.pose(x, (m >> i) & 1, DELAIS['6845'])
            for i, x in enumerate(ra):
                sim.pose(x, (sous >> i) & 1, DELAIS['6845'])
            sim.pose(de, 1 if visible else 0, DELAIS['6845'])
            sim.pose(cur, 0, DELAIS['6845'])
            self.crtc_etat = (m, sous, visible)

        def fclk(net, ancien, v):
            if ancien == 1 and v == 0:
                etat['c'] += 1
                if etat['c'] > r['R0']:
                    etat['c'] = 0
                    etat['ligne'] += 1
                sortir()
        sim.sur(clk, fclk)
        sortir()
        self.crtc_compteur = etat

    def quartz(self, ref):
        sim = self.sim
        out = self.P(ref, 5)
        self.horloge = out
        etat = {'n': 0}

        def tic():
            etat['n'] += 1
            sim.pose(out, etat['n'] & 1, 0)
            sim.pose('_quartz', etat['n'], PIXEL / 2)
        sim.sur('_quartz', lambda *_: tic())
        sim.pose('_quartz', 0, 1)

        # un pixel : échantillonné juste avant chaque front montant
        def fpix(net, ancien, v):
            if ancien == 0 and v == 1:
                self.pixels.append((sim.t, sim.lit('Net-(R6-Pad1)'), sim.lit('Net-(R5-Pad1)'), sim.lit('Net-(R4-Pad1)')))
        sim.sur(out, fpix)

    def au_chargement(self):
        """Au front qui charge le 166 : l'adresse vue par U112, l'octet chargé,
        l'octet de couleur (sortie de U113) et MA, RA, DE sur les fils."""
        sim = self.sim
        u112 = self.adr_ram['U112']() if 'U112' in self.adr_ram else None
        zv = sum(sim.lit(e) << i for i, e in enumerate(self.zv))
        ma, ra, de = self.fils_crtc
        m = sum(sim.lit(x) << i for i, x in enumerate(ma))
        sous = sum(sim.lit(x) << i for i, x in enumerate(ra))
        coul = sum(sim.lit(n) << i for i, n in enumerate(
            ('/vbd0', '/vgd1', '/vbd2', '/Vlum0', 'Net-(U110-A4)', '/Vclign', '/Vinv', '/charpage')))
        self.chargements.append((sim.t, u112, zv, (m, sous, sim.lit(de)), coul))

    # --- bus du 6309 ---
    def bus_repos(self):
        sim = self.sim
        for n in ('/~{8000-9FFF}', '/~{A100-A17F}', '/R/~{WR}'):
            sim.pose(n, 1, 0)
        sim.pose('/E', 0, 0)

    def cycle(self, adresse, donnee=None):
        """Un cycle du 6309 (543 ns) : écriture si donnee, sinon lecture."""
        sim = self.sim
        t0 = sim.t
        for i in range(16):
            n = '/a%d' % i
            sim.pose(n, (adresse >> i) & 1, base.T_ADR)
        sim.pose('/R/~{WR}', 0 if donnee is not None else 1, base.T_ADR)
        sim.pose('/~{8000-9FFF}', 0 if 0x8000 <= adresse < 0xA000 else 1, base.T_ADR + 10)
        sim.pose('/~{A100-A17F}', 0 if 0xA100 <= adresse < 0xA180 else 1, base.T_ADR + 10)
        sim.pose('/E', 1, base.CYCLE - base.E_HAUT)
        if donnee is not None:
            for i in range(8):
                sim.pilote('/d%d' % i, 'cpu', (donnee >> i) & 1, base.CYCLE - base.E_HAUT + base.T_DONNEE_ECR)
        sim.avance(t0 + base.CYCLE)
        lu = sum(sim.lit('/d%d' % i) << i for i in range(8))
        sim.pose('/E', 0, 0)
        if donnee is not None:
            for i in range(8):
                sim.pilote('/d%d' % i, 'cpu', None, base.T_MAINTIEN)
        sim.avance(sim.t + base.T_MAINTIEN + 5)
        self.bus_repos()
        sim.avance(sim.t + 20)
        return lu


def preparer(carte, graine=1):
    """Contenu des RAM : du texte et des couleurs variés, un bitmap varié."""
    rnd = random.Random(graine)
    car, col = carte.ram['U112'], carte.ram['U113']
    for i in range(32768):
        car[i] = rnd.randrange(256)
        col[i] = rnd.randrange(128) | 0x08 if rnd.random() < 0.9 else rnd.randrange(256)


def tourne(netlist, mode_graphique, lignes, police, ecriture=None, avant=None):
    r = {'R0': 99, 'R1': 80, 'R6': 25, 'R9': 15, 'debut': 0x3FFF}
    c = Carte(netlist, r, police)
    preparer(c)
    if avant:
        avant(c)
    sim = c.sim
    sim.avance(200)
    c.cycle(0xA120, 0x08 if mode_graphique else 0x00)      # page 0, mode
    c.t_graph = sim.t
    debut = len(c.pixels)
    fin_ligne = lignes
    while c.crtc_compteur['ligne'] < fin_ligne:
        if ecriture and c.crtc_compteur['ligne'] == ecriture[0] and not ecriture[3]:
            ecriture[3].append(c.cycle(ecriture[1], ecriture[2]))
        sim.avance(sim.t + 2000)
    return c, c.pixels[debut:]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    sch = args[0] if args else SCH
    ref = os.path.join(ICI, 'crt2_avant_graphique.xml')
    if '--ref' in sys.argv:
        ref = sys.argv[sys.argv.index('--ref') + 1]
    police = open(POLICE, 'rb').read()
    nouveau = charge_netlist(sch)
    erreurs = []

    def verifie(cond, texte):
        print(('OK    ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    # 1. mode texte : ancienne carte = nouvelle carte
    lignes = 34
    c_n, px_n = tourne(nouveau, False, lignes, police)
    if ref:
        c_a, px_a = tourne(charge_netlist(ref), False, lignes, police)
        n = min(len(px_n), len(px_a))
        diff = sum(1 for x, y in zip(px_n[:n], px_a[:n]) if x[1:] != y[1:])
        verifie(n > 10000 and diff == 0, 'mode texte : %d pixels, identiques à l\'ancienne carte (%d différents)' % (n, diff))
    pt, ct = decalages(c_n, police, False)
    print('      mode texte : pixels de la cellule MA - %s, couleur de MA - %s (dépend des temps de la police et du 6845 :'
          % (pt, ct))
    print('      supposés ici, pas mesurés ; la carte réelle montre texte et couleur alignés)')

    # 2. mode graphique
    c_g, px_g = tourne(nouveau, True, lignes, police)
    actifs = [x for x in c_g.chargements if x[3][2] and x[0] > c_g.t_graph]
    mauvais = [(t, a, m) for t, a, zv, m, _ in actifs if a != ((m[1] << 11) | (m[0] & 2047))]
    verifie(actifs and not mauvais, 'mode graphique : U112 voit RA x 2048 + (MA & 2047) à chaque chargement visible (%d, %d faux%s)'
            % (len(actifs), len(mauvais), '' if not mauvais else ', ex. %s' % mauvais[:2]))
    pg, cg = decalages(c_g, police, True)
    verifie(pg is not None and pg == cg,
            'mode graphique : pixels = octets de U112 de la cellule MA - %s, couleur de MA - %s : la même cellule' % (pg, cg))
    if pt is not None and pg is not None:
        print('      (décalage graphique/texte des pixels : %d colonne(s), corrigeable par R12/R13 en mode graphique)' % (pt - pg))

    # 3. écriture CPU en mode graphique pendant l'affichage (page 5, $8123)
    ecr = [20, 0x8123, 0xA5, []]

    def page5(c):
        c.sim.avance(100)
    c_w, _ = tourne(nouveau, True, 24, police, ecriture=None)
    c_w.cycle(0xA120, 0x08 | 5)                             # page 5 (D0-D2 brouillés : voir U125)
    c_w.sim.avance(c_w.sim.t + 3000)
    c_w.cycle(0x8123, 0xA5)
    e = [x for x in c_w.ecritures if x[0] == 'U112']
    # U125 : D0 -> page2 (A14), D1 -> page0 (A12), D2 -> page1 (A13)
    banc = ((5 >> 0) & 1) << 2 | ((5 >> 2) & 1) << 1 | ((5 >> 1) & 1)
    verifie(e and e[-1][2] == 0xA5 and e[-1][1] == banc * 4096 + 0x123,
            'écriture CPU en mode graphique (page logicielle 5, $8123) : $A5 en U112 à $%04X (attendu : banc %d, $%04X)'
            % (e[-1][1] if e else 0, banc, banc * 4096 + 0x123))
    nouveaux = len(c_w.sim.conflits)
    anciens = None
    if ref:
        c_r, _ = tourne(charge_netlist(ref), True, 24, police)
        c_r.cycle(0xA120, 0x08 | 5)
        c_r.sim.avance(c_r.sim.t + 3000)
        c_r.cycle(0x8123, 0xA5)
        anciens = len(c_r.sim.conflits)
    verifie(not c_g.sim.conflits and not c_n.sim.conflits and (anciens is None or nouveaux <= anciens),
            'conflits de bus : aucun à l\'affichage ; écriture CPU : %d, comme l\'ancienne carte (%s) — %s'
            % (nouveaux, anciens, (c_w.sim.conflits[:1] or ['-'])[0]))
    for nom, c in (('texte', c_n), ('graphique', c_g)):
        m = [x for x in c.marges if x < 10 ** 6]
        print('      marge au chargement du 166 (%s) : %d ns au plus juste (setup %d ns)' % (nom, min(m), SETUP_166))
        al = [a for a in c.sim.alertes if '166' in a or 'U117' in a]
        verifie(not al, 'chargement du 166 en mode %s : données stables à temps%s' % (nom, '' if not al else ' : %s' % al[:2]))
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


def decalages(c, police, graphique):
    """(k pixels, k couleur) : les octets chargés dans le 166 et la couleur
    présente sont ceux de la cellule MA - k, pour au moins 98 % des
    chargements visibles (le premier caractère d'une ligne n'a pas de
    précédent). None si aucun k ne convient."""
    car, col = c.ram['U112'], c.ram['U113']
    ch = [x for x in c.chargements if x[3][2] and x[0] > getattr(c, 't_graph', 0)]

    def meilleur(test):
        for k in range(0, 4):
            if ch and sum(1 for x in ch if test(x, k)) >= 0.98 * len(ch):
                return k
        return None

    def pix(x, k):
        t, a, zv, (m, sous, vis), coul = x
        mm = (m - k) & 0x3FFF
        if graphique:
            return zv == car[(sous << 11) | (mm & 2047)]
        return zv == police[(((col[mm & 0xFFF] >> 7) & 1) << 12) | (car[mm & 0xFFF] << 4) | sous]

    def cou(x, k):
        t, a, zv, (m, sous, vis), coul = x
        return coul == col[((m - k) & 0x3FFF) & 0xFFF]
    return meilleur(pix), meilleur(cou)


if __name__ == '__main__':
    sys.exit(main())
