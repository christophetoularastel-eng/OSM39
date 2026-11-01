#!/usr/bin/env python3
# ===================================================================
# simule_mono.py - Vidéo de la carte globale OSM39_mono : graphique
#                  case par case (bit 3 de la couleur), en simulation
# ===================================================================
# Lit la netlist de ~/Documents/kicad/OSM09/OSM39_mono (kicad-cli 10),
# garde la feuille vidéo et la rejoue avec les modèles de
# tools/crt2/simule_crt2.py (quartz 25,175 MHz, 74F163, 166, RAM, police,
# 6845 comportemental). Le CPU est au repos : ~CE_CHAR = ~CE_COLOR = 1,
# R/W = 1 ; GRAPH et la page sont posés directement (U525 retiré).
#
# Variantes (modifications ajoutées à la netlist, pas au schéma) :
#   tel_quel  la carte dessinée : texte, puis graphique plein écran
#   et        + U526 (74HCT08) : GRAPH_C = GRAPH ET Vlum0 vers U507/U509 S
#             et U510 broche 2 (adresse de U511 par RA)
#   retard    + U527 (74HC374, horloge ~LOAD) entre bd0-7 et U507/U509,
#             et GRAPH_C retardé par U516 D7/O7 vers U507/U509 S
#
# Pour chaque chargement visible du 166 : l'octet chargé doit être celui
# de la cellule MA - k (police si la case est texte, U511 à
# RA x 2048 + MA si elle est graphique) et la couleur latchée par U516
# celle de la même cellule. Délais supposés (voir simule_crt2.DELAIS) :
# --ram NS, --police NS, --crtc NS pour en essayer d'autres.
#
#   python3 tools/osm39_mono/simule_mono.py [OSM09.kicad_sch | netlist.xml]
#           [--ram 100] [--police 250] [--crtc 120] [--variante et]
# ===================================================================
import os
import random
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, os.path.join(RACINE, 'tools', 'crt2'))
import simule_crt2 as crt2      # noqa: E402

SCH = '/home/christophe/Documents/kicad/OSM09/OSM39_mono/OSM09.kicad_sch'
V = '/video/'
# circuits du CPU (tampons, décodage, verrou ; U501 est sur la feuille principale) : au repos, donc retirés
RETIRES = ('U501', 'U508', 'U513', 'U517', 'U524', 'U525')
COULEUR = [V + n for n in ('vbd0', 'vgd1', 'vrd2', 'Vlum0')] + ['Net-(U512-Q4)'] + \
    [V + n for n in ('Vclign', 'Vinv', 'charpage')]


def variante(val, broche, nom):
    """Ajoute à la netlist la porte ET (et le registre de retard)."""
    val, broche = dict(val), dict(broche)
    if nom == 'tel_quel':
        return val, broche
    val['U526'] = '74HCT08'
    broche[('U526', '1')] = V + 'GRAPH'
    broche[('U526', '2')] = V + 'Vlum0'
    broche[('U526', '3')] = V + 'GRAPH_C'
    for p in ('4', '5', '9', '10', '12', '13'):
        broche[('U526', p)] = 'GND'
    broche[('U510', '2')] = V + 'GRAPH_C'
    s_157 = V + 'GRAPH_C'
    if nom == 'retard':
        val['U527'] = '74HC374'
        for i, (d, q) in enumerate(zip((3, 4, 7, 8, 13, 14, 17, 18), (2, 5, 6, 9, 12, 15, 16, 19))):
            broche[('U527', str(d))] = V + 'bd%d' % i
            broche[('U527', str(q))] = V + 'bdr%d' % i
        broche[('U527', '11')] = V + '~{LOAD}'
        for i, p in enumerate((3, 6, 10, 13)):
            broche[('U507', str(p))] = V + 'bdr%d' % i
            broche[('U509', str(p))] = V + 'bdr%d' % (i + 4)
        broche[('U516', '18')] = V + 'GRAPH_C'
        broche[('U516', '19')] = V + 'GRAPH_R'
        s_157 = V + 'GRAPH_R'
    broche[('U507', '1')] = broche[('U509', '1')] = s_157
    return val, broche


class Carte(crt2.Carte):
    def __init__(self, netlist, registres, police):
        val, broche = netlist
        val = {r: v for r, v in val.items() if r not in RETIRES and
               (r.startswith(('U5', 'X5')) or r in ('U526', 'U527'))}
        super().__init__((val, broche), registres, police)

    def bus_repos(self):
        sim = self.sim
        for n, v in ((V + '~{CE_CHAR}', 1), (V + '~{CE_COLOR}', 1), (V + '~{WE}', 1), ('/R/~{WR}', 1),
                     ('Net-(U501-Pad3)', 0), ('/E', 0)):
            sim.pose(n, v, 0)

    def quartz(self, ref):
        sim = self.sim
        out = self.P(ref, 5)
        etat = {'n': 0}

        def tic():
            etat['n'] += 1
            sim.pose(out, etat['n'] & 1, 0)
            sim.pose('_quartz', etat['n'], crt2.PIXEL / 2)
        sim.sur('_quartz', lambda *_: tic())
        sim.pose('_quartz', 0, 1)

    def au_chargement(self):
        sim = self.sim
        zv = sum(sim.lit(e) << i for i, e in enumerate(self.zv))
        ma, ra, de = self.fils_crtc
        m = sum(sim.lit(x) << i for i, x in enumerate(ma))
        sous = sum(sim.lit(x) << i for i, x in enumerate(ra))
        self.chargements.append((sim.t, zv, (m, sous, sim.lit(de))))
        self.t_charge = sim.t

    def latch_couleur(self):
        """U516 latche au front montant de ~LOAD, juste après le chargement
        du 166 : on note l'octet de couleur qu'il prend pour ce chargement."""
        sim = self.sim

        def f(net, ancien, v):
            if ancien == 0 and v == 1 and self.chargements and len(self.couleurs) < len(self.chargements):
                self.couleurs.append(sum(sim.lit(n) << i for i, n in enumerate(COULEUR)))
        self.couleurs = []
        sim.sur(V + '~{LOAD}', f)


def preparer(c, mode, graine=1):
    """Texte et couleurs variés ; mode 'texte' : D3 = 1 partout (comme le
    logiciel actuel) ; 'mixte' : D3 tiré au hasard case par case."""
    rnd = random.Random(graine)
    car, col = c.ram['U511'], c.ram['U512']
    for i in range(32768):
        car[i] = rnd.randrange(256)
        col[i] = (rnd.randrange(256) & ~0x08) | (0x08 if mode != 'mixte' or rnd.random() < 0.5 else 0)


def tourne(netlist, mode, police, lignes=34):
    """mode : 'texte' (GRAPH = 0), 'graphique' (GRAPH = 1, D3 = 1 partout),
    'mixte' (GRAPH = 1, D3 au hasard)."""
    r = {'R0': 99, 'R1': 80, 'R6': 25, 'R9': 15, 'debut': 0x3FFF}
    c = Carte(netlist, r, police)
    preparer(c, mode)
    c.latch_couleur()
    sim = c.sim
    for n in ('page0', 'page1', 'page2'):
        sim.pose(V + n, 0, 0)
    sim.pose(V + 'GRAPH', 0 if mode == 'texte' else 1, 0)
    while c.crtc_compteur['ligne'] < lignes:
        sim.avance(sim.t + 2000)
    return c


def bilan(c, police, mode):
    """(k, justes, total) : meilleur décalage k pour les pixels, et pour la
    couleur ; une case est graphique si GRAPH et son D3."""
    car, col = c.ram['U511'], c.ram['U512']
    ch = [(x, coul) for x, coul in zip(c.chargements, c.couleurs) if x[2][2]]

    def attendu(m, sous, k):
        mm = (m - k) & 0x3FFF
        cc = col[mm & 0xFFF]
        if mode != 'texte' and cc & 0x08:
            return car[(sous << 11) | (mm & 2047)]
        return police[((cc >> 7) << 12) | (car[mm & 0xFFF] << 4) | sous]

    def score(test):
        res = [(k, sum(1 for x in ch if test(x, k))) for k in range(3)]
        return max(res, key=lambda y: y[1])
    kp, np_ = score(lambda x, k: x[0][1] == attendu(x[0][2][0], x[0][2][1], k))
    kc, nc = score(lambda x, k: x[1] == col[(x[0][2][0] - k) & 0xFFF])
    # pixels justes, à part : cases texte / cases graphiques
    par = {}
    for (t, zv, (m, sous, de)), coul in ch:
        g = mode != 'texte' and col[(m - kp) & 0xFFF] & 0x08
        bon = zv == attendu(m, sous, kp)
        a = par.setdefault('graphique' if g else 'texte', [0, 0])
        a[0] += bon
        a[1] += 1
    return kp, np_, kc, nc, len(ch), par


def main():
    args = sys.argv[1:]

    def opt(nom, defaut):
        if nom in args:
            i = args.index(nom)
            v = args[i + 1]
            del args[i:i + 2]
            return v
        return defaut
    crt2.DELAIS['ram_acces'] = int(opt('--ram', crt2.DELAIS['ram_acces']))
    crt2.DELAIS['eep_acces'] = int(opt('--police', crt2.DELAIS['eep_acces']))
    crt2.DELAIS['6845'] = int(opt('--crtc', crt2.DELAIS['6845']))
    seule = opt('--variante', None)
    sch = args[0] if args else SCH
    police = open(crt2.POLICE, 'rb').read()
    net = crt2.charge_netlist(sch)
    print('délais : RAM %d ns, police %d ns, 6845 %d ns (supposés)'
          % (crt2.DELAIS['ram_acces'], crt2.DELAIS['eep_acces'], crt2.DELAIS['6845']))
    essais = [('tel_quel', 'texte'), ('tel_quel', 'graphique'), ('et', 'texte'), ('et', 'mixte'),
              ('retard', 'texte'), ('retard', 'mixte')]
    echecs = 0
    for nom, mode in essais:
        if seule and nom != seule:
            continue
        c = tourne(variante(*net, nom), mode, police)
        kp, np_, kc, nc, total, par = bilan(c, police, mode)
        m = min(x for x in c.marges if x < 10 ** 6)
        al = [a for a in c.sim.alertes if 'U520' in a or 'setup' in a]
        # le premier caractère d'une ligne n'a pas de précédent : 98 %
        ok = np_ >= 0.98 * total and nc >= 0.98 * total and kp == kc and not al
        echecs += not ok
        print('%s %-8s %-9s pixels MA-%d %5d/%d  couleur MA-%d %5d/%d  marge 166 %4d ns  %s%s'
              % ('OK   ' if ok else 'ÉCHEC', nom, mode, kp, np_, total, kc, nc, total, m,
                 ' '.join('%s %d/%d' % (k, a, b) for k, (a, b) in sorted(par.items())),
                 ('  alertes : %d (%s)' % (len(al), al[0])) if al else ''))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
