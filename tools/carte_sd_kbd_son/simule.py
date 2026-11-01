#!/usr/bin/env python3
# ===================================================================
# simule.py - Simulation logique de la carte SD-KBD-SON, d'après KiCad
# ===================================================================
# Lit la netlist du schéma (kicad-cli sch export netlist --format
# kicadxml), donne à chaque circuit son comportement et ses délais de
# propagation (74HC à 5 V, valeurs typiques ; --lent / --rapide les
# multiplient), et rejoue des cycles de bus du 6309 à 1,8432 MHz :
#   - verrou $A140 (U107) : /CS de la carte SD, vitesse SPI ;
#   - $A148 : écrire envoie un octet, lire rend l'octet reçu au transfert
#     précédent et en lance un autre ($FF) ;
#   - AY-3-8910 en $A150/$A151 : mode BDIR/BC1 vu par la puce.
# Une carte SD simulée (SPI mode 0 : lit MOSI au front montant de SCLK,
# change MISO au front descendant) compte les fronts et les bits.
# Contrôles : octets reçus par la carte = octets écrits, octets lus = ce
# que la carte a envoyé, nombre de fronts SCLK par transfert, impulsions
# trop courtes, temps de prépositionnement et de maintien aux fronts des
# bascules, conflit de bus avec l'AY.
#
#   python3 tools/carte_sd_kbd_son/simule.py [chemin/SD-KBD-SON.kicad_sch] [++sclk]
#   (++nom : applique un correctif de CORRECTIFS à la netlist, pour l'essayer)
# ===================================================================
import os
import random
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SCH = '/home/christophe/Documents/kicad/OSM09/SD-KBD-SON/SD-KBD-SON.kicad_sch'
NS = 1                                  # le temps est en ns

# Délais typiques à 5 V (ns), d'après les fiches 74HC
DELAIS = {'porte': 9, '138': 15, '157': 12, '374': 15, '4040_1': 18, '4040_n': 8,
          '595': 15, '165': 16, 'inv': 8}
# Contraintes vérifiées aux fronts (ns)
SETUP, HOLD = 12, 3                     # 74HC374 / 595 / 165, valeurs prudentes
CARTE_SETUP, CARTE_HOLD = 5, 5          # carte SD (MOSI autour du front montant)
IMPULSION_MIN = 25                      # largeur minimale d'une impulsion SCLK

# Bus du 6309 en mode E à 1,8432 MHz : un cycle = 543 ns, E haut 271 ns.
CYCLE = 543
E_HAUT = 271
T_ADR = 60                              # adresse et R/W valides après le début du cycle
T_DONNEE_ECR = 150                      # donnée écrite valide après la montée de E
T_MAINTIEN = 30                         # tDHW, maintien des données après la descente de E


class Sim:
    def __init__(self):
        self.t = 0
        self.file = []                  # (t, n°, net, valeur)
        self.n = 0
        self.val = {}
        self.ecoute = {}                # net -> [fonctions]
        self.trace = {}                 # net -> [(t, v)]
        self.alertes = []

    def lit(self, net):
        return self.val.get(net, 0)

    def pose(self, net, v, apres=0):
        import heapq
        heapq.heappush(self.file, (self.t + apres, self.n, net, v))
        self.n += 1

    def avance(self, jusqua):
        import heapq
        while self.file and self.file[0][0] <= jusqua:
            t, _, net, v = heapq.heappop(self.file)
            self.t = t
            if self.val.get(net) == v:
                continue
            ancien = self.val.get(net, 0)
            self.val[net] = v
            self.trace.setdefault(net, []).append((t, v))
            for f in self.ecoute.get(net, []):
                f(net, ancien, v)
        self.t = jusqua

    def sur(self, net, f):
        self.ecoute.setdefault(net, []).append(f)

    def stable_depuis(self, net, t):
        """Instant du dernier changement de net avant t."""
        tr = [x for x, _ in self.trace.get(net, []) if x <= t]
        return tr[-1] if tr else -10**9

    def alerte(self, texte):
        self.alertes.append('%7.0f ns  %s' % (self.t, texte))


def netlist(sch):
    d = tempfile.mkdtemp()
    xml = os.path.join(d, 'net.xml')
    subprocess.run(['kicad-cli', 'sch', 'export', 'netlist', '--format', 'kicadxml', '-o', xml, sch],
                   check=True, capture_output=True)
    t = ET.parse(xml).getroot()
    val = {c.get('ref'): (c.findtext('value') or '') for c in t.iter('comp')}
    broche = {}
    for n in t.iter('net'):
        for x in n.iter('node'):
            broche[(x.get('ref'), x.get('pin'))] = n.get('name')
    return val, broche


def construit(sim, val, broche, facteur, vitesse=None):
    vitesse = vitesse or {}
    courant = {'ref': None}

    def P(ref, pin):
        courant['ref'] = ref
        return broche.get((ref, str(pin)), '%s.%s-libre' % (ref, pin))

    def D(nom, ref=None):
        return max(1, round(DELAIS[nom] * facteur * vitesse.get(ref or courant['ref'], 1.0)))
    sim.val['+5V'] = 1
    sim.val['GND'] = 0
    modeles = []
    for ref, v in sorted(val.items()):
        # famille : HC / HCT (délais ci-dessus), AC / ACT (environ 2,5 fois plus rapides)
        u = v.upper()
        rapide = u.startswith('74AC')
        for fam in ('74HCT', '74ACT', '74AC'):
            u = u.replace(fam, '74HC')
        dl = {k: max(1, round(D(k, ref) * (0.45 if rapide else 1.0))) for k in DELAIS}
        if u.endswith('HC08') or u.endswith('HC00') or u.endswith('HC32'):
            op = {'08': lambda a, b: a & b, '00': lambda a, b: 1 - (a & b), '32': lambda a, b: a | b}[u[-2:]]
            for a, b, y in ((1, 2, 3), (4, 5, 6), (9, 10, 8), (12, 13, 11)):
                na, nb, ny = P(ref, a), P(ref, b), P(ref, y)

                def f(*_, na=na, nb=nb, ny=ny, op=op, dl=dl):
                    sim.pose(ny, op(sim.lit(na), sim.lit(nb)), dl['porte'])
                sim.sur(na, f)
                sim.sur(nb, f)
                modeles.append(f)
        elif u.endswith('HC04'):
            for a, y in ((1, 2), (3, 4), (5, 6), (9, 8), (11, 10), (13, 12)):
                na, ny = P(ref, a), P(ref, y)

                def f(*_, na=na, ny=ny, dl=dl):
                    sim.pose(ny, 1 - sim.lit(na), dl['inv'])
                sim.sur(na, f)
                modeles.append(f)
        elif u.endswith('HC138'):
            ent = [P(ref, p) for p in (1, 2, 3, 4, 5, 6)]
            sorties = [P(ref, p) for p in (15, 14, 13, 12, 11, 10, 9, 7)]

            def f(*_, ent=ent, sorties=sorties, dl=dl):
                a0, a1, a2, e1, e2, e3 = (sim.lit(n) for n in ent)
                actif = (not e1) and (not e2) and e3
                k = a0 | (a1 << 1) | (a2 << 2)
                for i, s in enumerate(sorties):
                    sim.pose(s, 0 if actif and i == k else 1, dl['138'])
            for n in ent:
                sim.sur(n, f)
            modeles.append(f)
        elif u.endswith('HC157'):
            s_, e_ = P(ref, 1), P(ref, 15)
            voies = [(2, 3, 4), (5, 6, 7), (11, 10, 9), (14, 13, 12)]
            for i0, i1, z in voies:
                n0, n1, nz = P(ref, i0), P(ref, i1), P(ref, z)

                # s_ et e_ liés ici : sinon tous les 157 liraient ceux du dernier
                def f(*_, n0=n0, n1=n1, nz=nz, dl=dl, s_=s_, e_=e_):
                    v = 0 if sim.lit(e_) else (sim.lit(n1) if sim.lit(s_) else sim.lit(n0))
                    sim.pose(nz, v, dl['157'])
                for n in (s_, e_, n0, n1):
                    sim.sur(n, f)
                modeles.append(f)
        elif u.endswith('HC374'):
            cp = P(ref, 11)
            ds = [P(ref, p) for p in (3, 4, 7, 8, 13, 14, 17, 18)]
            qs = [P(ref, p) for p in (2, 5, 6, 9, 12, 15, 16, 19)]

            def f(net, ancien, v, ds=ds, qs=qs, ref=ref, dl=dl):
                if ancien == 0 and v == 1:
                    for d, q in zip(ds, qs):
                        if sim.t - sim.stable_depuis(d, sim.t) < SETUP:
                            sim.alerte('%s : donnée %s changée %d ns avant le front (setup %d)'
                                       % (ref, d, sim.t - sim.stable_depuis(d, sim.t), SETUP))
                        sim.pose(q, sim.lit(d), dl['374'])
                        sim.verif_maintien.append((sim.t, d, ref))
            sim.sur(cp, f)
        elif u == '4040':
            clk, mr = P(ref, 10), P(ref, 11)
            qs = [P(ref, p) for p in (9, 7, 6, 5, 3, 2, 4, 13, 12, 14, 15, 1)]
            etat = {'n': 0}

            def sortir(etat=etat, qs=qs, dl=dl):
                for i, q in enumerate(qs):
                    sim.pose(q, (etat['n'] >> i) & 1, dl['4040_1'] + i * dl['4040_n'])

            def fclk(net, ancien, v, etat=etat, mr=mr, sortir=sortir, dl=dl):
                if ancien == 1 and v == 0 and not sim.lit(mr):
                    etat['n'] = (etat['n'] + 1) & 0xFFF
                    sortir()

            def fmr(net, ancien, v, etat=etat, sortir=sortir, dl=dl):
                if v:
                    etat['n'] = 0
                    sortir()
            sim.sur(clk, fclk)
            sim.sur(mr, fmr)
            sim.compteurs[ref] = etat
        elif u.endswith('HC595'):
            ser, sck, rck, clr, oe = (P(ref, p) for p in (14, 11, 12, 10, 13))
            qs = [P(ref, p) for p in (15, 1, 2, 3, 4, 5, 6, 7)]
            etat = {'sr': 0, 'st': 0}

            def fsck(net, ancien, v, etat=etat, ref=ref, dl=dl, clr=clr, ser=ser):
                if ancien == 0 and v == 1 and sim.lit(clr):
                    if sim.t - sim.stable_depuis(ser, sim.t) < SETUP:
                        sim.alerte('%s : SER (MISO) changé %d ns avant SRCLK' % (ref, sim.t - sim.stable_depuis(ser, sim.t)))
                    etat['sr'] = ((etat['sr'] << 1) | sim.lit(ser)) & 0xFF

            def fsort(*_, etat=etat, qs=qs, oe=oe, dl=dl):
                for i, q in enumerate(qs):
                    sim.pose(q, (etat['st'] >> i) & 1 if not sim.lit(oe) else None, dl['595'])

            def frck(net, ancien, v, etat=etat, fsort=fsort, dl=dl):
                if ancien == 0 and v == 1:
                    etat['st'] = etat['sr']
                    fsort()

            def fclr(net, ancien, v, etat=etat, dl=dl, clr=clr):
                if not v:
                    etat['sr'] = 0
            sim.sur(sck, fsck)
            sim.sur(rck, frck)
            sim.sur(oe, fsort)
            sim.sur(clr, fclr)
            sim.pilotes[ref] = (qs, oe)
        elif u.endswith('HC165'):
            pl, cp, ce, dsr = (P(ref, p) for p in (1, 2, 15, 10))
            ds = [P(ref, p) for p in (11, 12, 13, 14, 3, 4, 5, 6)]
            q7 = P(ref, 9)
            etat = {'r': 0, 'pl_haut': -10**9}

            def charge(*_, etat=etat, pl=pl, ds=ds, q7=q7, dl=dl):
                if not sim.lit(pl):
                    etat['r'] = sum(sim.lit(d) << i for i, d in enumerate(ds))
                    sim.pose(q7, (etat['r'] >> 7) & 1, dl['165'])

            def fpl(net, ancien, v, etat=etat, charge=charge, dl=dl):
                if v == 1:
                    etat['pl_haut'] = sim.t
                charge()

            def fcp(net, ancien, v, etat=etat, ref=ref, dl=dl, ce=ce, dsr=dsr, pl=pl, q7=q7):
                if ancien == 0 and v == 1 and not sim.lit(ce):
                    if not sim.lit(pl):
                        sim.alerte('%s : front CP pendant /PL bas (pas de décalage)' % ref)
                        return
                    if sim.t - etat['pl_haut'] < 15:
                        sim.alerte('%s : CP %d ns après la remontée de /PL (temps de recouvrement)'
                                   % (ref, sim.t - etat['pl_haut']))
                    etat['r'] = ((etat['r'] << 1) | sim.lit(dsr)) & 0xFF
                    sim.pose(q7, (etat['r'] >> 7) & 1, dl['165'])
            sim.sur(pl, fpl)
            for d in ds:
                sim.sur(d, charge)
            sim.sur(cp, fcp)
        elif 'AY-3-8910' in u:
            bdir, bc1, bc2 = P(ref, 27), P(ref, 29), P(ref, 28)
            sim.ay = (bdir, bc1, bc2)
    for f in modeles:                   # état initial cohérent
        f()


class Carte:
    """Carte SD en SPI mode 0, vue de ses broches."""

    def __init__(self, sim, cs, sclk, mosi, miso, reponses):
        self.sim, self.cs, self.sclk, self.mosi, self.miso = sim, cs, sclk, mosi, miso
        self.bits_recus = []
        self.reponses = list(reponses)
        self.bits_a_envoyer = []
        self.fronts = 0
        self.dernier_front = None
        # À la mise sous tension, U107 et U108 sont quelconques : des fronts
        # peuvent partir avec /CS bas. Une vraie carte ne les écoute pas
        # (elle n'entre en SPI qu'après >= 74 coups avec /CS haut, puis CMD0) :
        # la carte simulée ne compte qu'après avoir vu /CS remonter.
        self.armee = False
        sim.sur(cs, self.selection)
        sim.sur(sclk, self.horloge)
        self.suivant()

    def suivant(self):
        if not self.bits_a_envoyer:
            o = self.reponses.pop(0) if self.reponses else 0xFF
            self.bits_a_envoyer = [(o >> (7 - i)) & 1 for i in range(8)]
        self.sim.pose(self.miso, self.bits_a_envoyer.pop(0), 20)

    def selection(self, net, ancien, v):
        if v:
            self.armee = True

    def horloge(self, net, ancien, v):
        sim = self.sim
        if self.dernier_front is not None and sim.t - self.dernier_front < IMPULSION_MIN:
            sim.alerte('SCLK : impulsion de %d ns' % (sim.t - self.dernier_front))
        self.dernier_front = sim.t
        if sim.lit(self.cs) or not self.armee:
            return
        if ancien == 0 and v == 1:
            self.fronts += 1
            if sim.t - sim.stable_depuis(self.mosi, sim.t) < CARTE_SETUP:
                sim.alerte('carte : MOSI changé %d ns avant SCLK' % (sim.t - sim.stable_depuis(self.mosi, sim.t)))
            self.bits_recus.append((sim.t, sim.lit(self.mosi)))
            sim.verif_maintien.append((sim.t, self.mosi, 'carte'))
        elif ancien == 1 and v == 0:
            self.suivant()


CORRECTIFS = {
    # SCLK = Za . /Q3 : plus de bascule BUSY (U110 1-6), la course
    # BUSY / validation du 157 disparaît (impulsion de 12 ns sinon)
    'sclk': {('U102', '4'): '/RESET_BUSY'},
    # U103 (E/16) compté sur la MONTÉE de E, par une porte NAND libérée par
    # 'sclk' (U110 1,2 -> 3) : E/16 ne change plus à la fin d'un accès
    'lent': {('U110', '1'): '/E', ('U110', '2'): '/E', ('U110', '3'): 'E_INV', ('U103', '10'): 'E_INV'},
    # 74AC138 et 74AC32 (même brochage) : le front du verrou $A140 arrive
    # plus tôt après la descente de E (maintien des données du 6309). Inutile
    # une fois les valeurs changées dans le schéma (famille lue sur la valeur).
    'ac': {'_vitesse': {'U101': 0.45, 'U104': 0.45}},
}


def simule(facteur, sch, phase_lente, idle_rapide, idle_lent, correctifs=(), verbeux=False):
    val, broche = netlist(sch)
    vitesse = {}
    for c in correctifs:
        for k, v in CORRECTIFS[c].items():
            if k == '_vitesse':
                vitesse.update(v)
            else:
                broche[k] = v
    sim = Sim()
    sim.verif_maintien = []
    sim.compteurs = {}
    sim.pilotes = {}
    sim.ay = None

    def J(pin):
        return broche[('J101', pin)]
    E, RW, A0, A3, A4, A5, SEL, RESET = (J(p) for p in ('C11', 'A12', 'A7', 'A6', 'C6', 'B5', 'B2', 'A15'))
    D = [J(p) for p in ('A11', 'B10', 'A10', 'C10', 'B9', 'A9', 'C9', 'B8')]
    construit(sim, val, broche, facteur, vitesse)
    cs, sclk, mosi, miso = (broche[('J102', str(p))] for p in (1, 2, 3, 4))
    envoyes = [0x40, 0x00, 0x00, 0x00, 0x00, 0x95]                  # CMD0
    reponses = [0xFF] * 7 + [0x01, 0xA5, 0x5A, 0x3C] + [0xFF] * 40
    carte = Carte(sim, cs, sclk, mosi, miso, reponses)

    # U103 (4040 libre sur E) : phase de départ quelconque
    for ref, etat in sim.compteurs.items():
        if broche.get((ref, '11')) == 'GND':
            etat['n'] = phase_lente

    lus = []
    ay_modes = []
    marges = []
    CP374 = next(broche[(r, '11')] for r, v in val.items() if v.upper().endswith('374'))

    def cycle(adr=None, ecrit=None):
        """Un cycle de bus ; adr None = cycle ailleurs (pas de sélection)."""
        t0 = sim.t
        sim.pose(E, 0)
        sel = adr is not None and 0xA140 <= adr <= 0xA17F
        sim.pose(SEL, 0 if sel else 1, T_ADR)
        a = adr if adr is not None else 0xE000
        sim.pose(A0, a & 1, T_ADR)
        for n, b in ((A3, 3), (A4, 4), (A5, 5)):
            sim.pose(n, (a >> b) & 1, T_ADR)
        sim.pose(RW, 0 if ecrit is not None else 1, T_ADR)
        sim.pose(E, 1, CYCLE - E_HAUT)
        if ecrit is not None:
            for i, d in enumerate(D):
                sim.pose(d, (ecrit >> i) & 1, CYCLE - E_HAUT + T_DONNEE_ECR)
        sim.avance(t0 + CYCLE - 1)
        if adr is not None and ecrit is None:
            v = 0
            for i, d in enumerate(D):
                v |= (sim.lit(d) or 0) << i
            lus.append(v)
        if sim.ay:
            ay_modes.append((adr, ecrit is not None, sim.lit(sim.ay[0]), sim.lit(sim.ay[1])))
        sim.pose(E, 0, 1)                       # fin du cycle : E retombe
        if ecrit is not None:
            for d in D:
                sim.pose(d, 0, 1 + T_MAINTIEN)      # la donnée disparaît après tDHW
        sim.pose(SEL, 1, 1 + 20)                    # adresse suivante
        sim.avance(t0 + CYCLE + 80)
        if adr == 0xA140 and ecrit is not None:     # front du verrou / fin des données
            fronts = [t for t, v in sim.trace.get(CP374, []) if v == 1 and t > t0 + CYCLE - E_HAUT]
            if fronts:
                marges.append(t0 + CYCLE + 1 + T_MAINTIEN - fronts[0])
        sim.t = t0 + CYCLE

    # repos du bus, puis stabilisation (les alertes du démarrage à 0 ne comptent pas)
    sim.pose(E, 0)
    sim.pose(RW, 1)
    sim.pose(SEL, 1)
    sim.pose(RESET, 0)
    sim.avance(2000)
    sim.alertes.clear()
    sim.verif_maintien.clear()
    sim.t = 2000
    # reset
    for _ in range(3):
        cycle()
    sim.pose(RESET, 1)
    cycle()
    # comme le pilote : vitesse lente (bit1 = 0, E/16), /CS haut (bit0 = 1),
    # 80 coups d'horloge ($FF x 10), puis /CS bas et CMD0
    cycle(0xA140, 0b01)
    for _ in range(10):
        cycle(0xA148, 0xFF)
        for _ in range(idle_lent):
            cycle()
    cycle(0xA140, 0b00)
    for o in envoyes:
        cycle(0xA148, o)
        for _ in range(idle_lent):
            cycle()
    lent = list(envoyes)
    n_lent = len(carte.bits_recus)
    # vitesse rapide (E), deux lectures (envoient $FF)
    cycle(0xA140, 0b10)
    cycle(0xA148, 0xFF)
    for _ in range(idle_rapide):
        cycle()
    lus.clear()
    for _ in range(3):
        cycle(0xA148)
        for _ in range(idle_rapide):
            cycle()
    # AY : registre 7, donnée $38, relecture
    cycle(0xA150, 0x07)
    cycle(0xA151, 0x38)
    cycle(0xA150)
    cycle()

    # --- bilan ---
    bits = [b for _, b in carte.bits_recus]
    octets = [int(''.join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits) - len(bits) % 8, 8)]
    attendu = lent + [0xFF, 0xFF, 0xFF, 0xFF]
    for t, net, qui in sim.verif_maintien:
        apres = [x for x, _ in sim.trace.get(net, []) if t < x < t + HOLD + 1]
        if apres:
            sim.alerte('%s : %s change %d ns après le front (maintien %d)' % (qui, net, apres[0] - t, HOLD))
    res = {
        'fronts': len(bits), 'octets_carte': octets, 'attendu': attendu,
        'lus': lus[:3], 'alertes': sim.alertes, 'n_lent': n_lent, 'marge374': min(marges) if marges else None,
        'ay': [m for m in ay_modes if m[0] is not None and 0xA150 <= m[0] <= 0xA157],
        'ay_hors': [m for m in ay_modes if not (m[0] is not None and 0xA150 <= m[0] <= 0xA157) and (m[2] or m[3])],
    }
    return res


def main():
    sch = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1][0] not in '-+' else SCH
    erreurs = 0

    def verdict(ok, texte):
        nonlocal erreurs
        print(('OK    ' if ok else 'ÉCHEC ') + texte)
        erreurs += not ok
    correctifs = [a[2:] for a in sys.argv[1:] if a.startswith('+')]
    if correctifs:
        print('correctifs appliqués à la netlist : %s' % ', '.join(correctifs))
    for nom, facteur in (('typique', 1.0), ('lent x1,5', 1.5), ('rapide x0,6', 0.6)):
        print('--- délais %s ---' % nom)
        for phase in (0, 3, 7, 8, 12, 15):
            r = simule(facteur, sch, phase, idle_rapide=9, idle_lent=150, correctifs=correctifs)
            ok = r['octets_carte'] == r['attendu'] and r['fronts'] == 8 * len(r['attendu'])
            verdict(ok, 'phase E/16 = %2d : %d fronts SCLK (attendus %d), carte a reçu %s'
                    % (phase, r['fronts'], 8 * len(r['attendu']), ' '.join('%02X' % o for o in r['octets_carte'])))
            if phase == 0:
                verdict(r['marge374'] is not None and r['marge374'] >= 10,
                        'verrou $A140 (U107) : son front vient %s ns AVANT la fin des données (tDHW %d ns ; il faut au moins 10)'
                        % (r['marge374'], T_MAINTIEN))
                verdict(r['lus'] == [0xFF, 0x01, 0xA5], 'lectures en $A148 : %s (attendu FF 01 A5 : octet du transfert précédent)'
                        % ' '.join('%02X' % o for o in r['lus']))
                modes = [(('écrit' if e else 'lit') + ' $%04X' % a, 'BDIR=%d BC1=%d' % (b, c)) for a, e, b, c in r['ay']]
                bons = [m[1] for m in modes] == ['BDIR=1 BC1=1', 'BDIR=1 BC1=0', 'BDIR=0 BC1=1']
                verdict(bons, 'AY : %s' % ', '.join('%s %s' % m for m in modes))
                verdict(not r['ay_hors'], 'AY : inactif hors de $A150-$A157 (pas de conflit de bus)')
            for a in sorted(set(r['alertes']))[:6]:
                print('        ! ' + a)
    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', erreurs))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
