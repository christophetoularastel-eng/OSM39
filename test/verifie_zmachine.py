#!/usr/bin/env python3
# ===================================================================
# verifie_zmachine.py - zmachine/ZMACHINE = le modèle tools/zmachine/zmachine.py
# ===================================================================
# Le VRAI binaire (page 1, $0000) tourne sur le VRAI BIOS dans la machine
# de verifie_fs.py, appelé comme OSM-VISION l'appelle (App_Start, argv =
# le jeu, posé sur une carte OSMFS émulée). Une trame toutes les TRAME
# instructions : l'IRQ VSYNC (Irq_Z puis le vrai handler_IRQ). Le clavier :
# sys_kbd_poll est servi par le banc (les lignes du script, Entrée = 13 ;
# une espace pour chaque « [Suite] »).
#   - chaque caractère envoyé à l'écran (Ecran_Car) = celui du modèle
#     (Grille.car), dans le même ordre, du début à la fin ;
#   - à chaque saisie, la copie d'écran (30 x 80 cases, caractère et
#     attribut) = la grille du modèle au même moment ;
#   - la VRAM rattrape la copie d'écran (au plus RANG_TRAME rangées de
#     160 octets par trame, toutes les écritures dans l'IRQ) ;
#   - les rangées 25-29 d'OSM-VISION sont rendues, rvec_IRQ aussi ;
#   - sauvegardes : le fichier écrit sur la carte = celui du modèle
#     (Quetzal), et le relire redonne le même écran.
# Les jeux (pas dans le dépôt) : ~/Documents/zmachine, ou $ZMACHINE_JEUX.
#   python3 verifie_zmachine.py            czech, dreamlands, zsnake (délais), sauver/charger
#   python3 verifie_zmachine.py tout       + praxix, aventure, lieuxcommuns, Zork_LXIX
#   python3 verifie_zmachine.py JEU SCRIPT une séance (une commande par ligne)
# ===================================================================
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'zmachine'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import carte                    # noqa: E402
import zmachine as zm           # noqa: E402

BIN = os.path.join(RACINE, 'zmachine', 'ZMACHINE')
MAP = os.path.join(RACINE, 'zmachine', 'ZMACHINE.map')
JEUX = os.environ.get('ZMACHINE_JEUX', os.path.expanduser('~/Documents/zmachine'))
TRAME = 7000                    # instructions par trame
CHAINES = 0xDB40                # argv en RAM commune (hors de BIOS2 et de la pile)
ECRAN = 0x4000
GRAINE_TICK = 0x1234            # vsync_tick au lancement


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


class Fini(Exception):
    pass


class Banc(va.MachineAsm):
    def __init__(self, image, s, a, flux):
        super().__init__(image, s)
        self.a_ = a
        self.flux = list(flux)          # caractères à taper
        self.trame = 0
        self.n = 0
        self.irq = False
        self.dans_irq = 0
        self.n_irq = 0
        self.ecritures = []             # (trame, instructions depuis l'IRQ, dans l'IRQ ?)
        self.sorties = []               # Ecran_Car : A
        self.photos = []                # copie d'écran à chaque saisie
        self.vram_ok = []               # VRAM = copie, vérifié à chaque saisie
        self.suites = 0
        self.pas_z = 0
        self.attente = 0                # trames d'attente avant de taper
        self.graine = None

    def lit_ecran(self):
        b = self.banks[1]
        g = []
        for r in range(30):
            base = ECRAN + 160 * r
            if carte.MONO:
                g.append([(b[base + 2 * c], b[base + 2 * c + 1]) for c in range(80)])
            else:
                g.append([(b[base + c], b[base + 80 + c]) for c in range(80)])
        return g

    def lit_vram(self):
        return [[(self.mem[carte.adr(r * 80 + c)], self.mem[carte.adr_coul(r * 80 + c)]) for c in range(80)]
                for r in range(30)]

    def wr8(self, adr, val):
        if 0x8000 <= adr < 0xA000:
            self.ecritures.append((self.trame, self.n - self.n_irq, self.dans_irq > 0 or self.pc >= 0xE000))
        super().wr8(adr, val)

    def interruption(self, vecteur):        # mode natif : 14 octets
        self.s -= 14
        f = [self.cc | 0x80, self.a, self.b, self.w >> 8, self.w & 255, self.dp,
             self.x >> 8, self.x & 255, self.y >> 8, self.y & 255, self.u >> 8, self.u & 255,
             self.pc >> 8, self.pc & 255]
        for i, o in enumerate(f):
            self.wr8(self.s + i, o)
        self.cc |= 0x50
        self.pc = self.rd16(vecteur)

    def execute(self, op):
        if op == 0x3B and self.rd8(self.s) & 0x80:     # RTI natif
            f = [self.rd8(self.s + i) for i in range(14)]
            self.cc, self.a, self.b, self.dp = f[0], f[1], f[2], f[5]
            self.w = (f[3] << 8) | f[4]
            self.x, self.y, self.u = (f[6] << 8) | f[7], (f[8] << 8) | f[9], (f[10] << 8) | f[11]
            self.pc = (f[12] << 8) | f[13]
            self.s += 14
            self.dans_irq -= 1
            return
        return super().execute(op)

    def rts(self):
        self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
        self.s += 2

    def clavier(self):
        a = self.a_
        if self.banks[1][a['EnSuite']]:
            self.suites += 1
            self.a = 32
            return
        if self.attente:                # la VRAM rattrape avant de taper
            self.a = 0
            if self.trame >= self.attente:
                self.attente = 0
                self.vram_ok.append(self.lit_vram() == self.lit_ecran())
            return
        if not self.flux:
            raise Fini()
        if self.flux[0] is None:        # délai : plus rien jusqu'à la routine
            self.a = 0
            return
        self.a = ord(self.flux.pop(0)) if isinstance(self.flux[0], str) else self.flux.pop(0)

    def sonde(self):
        """Le PC va être exécuté (après une éventuelle prise d'IRQ)."""
        if self.page == 1:
            a = self.a_
            if self.pc == a['Pas']:
                self.pas_z += 1
            elif self.pc == a['Ecran_Car'] and self.graine is not None:
                self.sorties.append(self.a)         # (pas « Chargement de... »)
            elif self.pc in (a['Lit_Saisie'], a['LT_Attente']):
                self.photos.append(self.lit_ecran())
                self.attente = self.trame + 12      # 12 trames : la VRAM rattrape
            elif self.pc == a['Appel_Interne'] and self.flux and self.flux[0] is None:
                self.flux.pop(0)                    # le délai s'est écoulé
            elif self.pc == a['Demarre'] and self.graine is None:
                b = self.banks[1]
                self.graine = (b[a['Alea']] << 8) | b[a['Alea'] + 1]

    def step(self):
        self.n += 1
        if self.n % TRAME == 0:
            self.trame += 1
            self.irq = True
        if self.irq and not self.cc & 0x10:
            self.irq = False
            self.dans_irq += 1
            self.n_irq = self.n
            self.interruption(0xFFF8)
        if self.pc == self.s_['kbd_poll']:
            self.clavier()
            self.rts()
            return
        self.sonde()
        super().step()


class GrilleTrace(zm.Grille):
    """La Grille du modèle, qui garde chaque caractère reçu (comme Ecran_Car)."""

    def __init__(self):
        super().__init__()
        self.sorties = []

    def car(self, u):
        self.sorties.append(10 if u == '\n' else zm.CP437.get(u, ord('?')))
        super().car(u)


class EntreeTrace(zm.EntreeScript):
    def __init__(self, lignes, ecran):
        super().__init__(lignes)
        self.ecran = ecran
        self.photos = []

    def photo(self):
        self.photos.append([list(r) for r in self.ecran.cases])

    def ligne(self, maxi, dixiemes):
        self.photo()
        return super().ligne(maxi, dixiemes)

    def touche(self, dixiemes):
        self.photo()
        return super().touche(dixiemes)


def seance(s, a, jeu, lignes, fichiers=None):
    """Le binaire puis le modèle sur le même jeu et les mêmes lignes."""
    d = tempfile.mkdtemp()
    c = va.Carte(d)
    nom = os.path.basename(jeu).upper()
    c.ajoute(nom, jeu, page=1, adresse='0000', attr=0x06)
    for n, octets in (fichiers or {}).items():
        p = os.path.join(d, 'f_' + n)
        open(p, 'wb').write(octets)
        c.ajoute(n, p, page=1, adresse='0000', attr=0x06)
    flux = []
    for l in lignes:
        flux += [None] if l is None else list(l) + ['\r']
    m = Banc(c.image, s, a, flux)
    v.installe_bios(m)          # table des services, et BIOS2
    m.wr16(0xDFF6, s['handler_IRQ'])
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 1
    m.wr16(s['vsync_tick'], GRAINE_TICK)
    for r in range(25, 30):                 # les rangées d'OSM-VISION, reconnaissables
        for col in range(80):
            m.mem[carte.adr(r * 80 + col)] = 0x41 + (r + col) % 26
            m.mem[carte.adr_coul(r * 80 + col)] = 0x17
    avant = m.lit_vram()[25:30]
    code = open(BIN, 'rb').read()
    m.banks[1][:len(code)] = code
    adr, ptrs = CHAINES, []
    for t in ('ZMACHINE', nom):
        b = t.encode('ascii') + b'\0'
        m.mem[adr:adr + len(b)] = b
        ptrs.append(adr)
        adr += len(b)
    m.mem[s['argc']] = len(ptrs)
    for i, p in enumerate(ptrs):
        m.wr16(s['argv'] + 2 * i, p)
    m.page = 1
    try:
        v.appelle(m, a['App_Start'], 400_000_000)
        r = 'rendu'
    except Fini:
        r = 'fini'
    except Exception as e:      # noqa: BLE001
        r = 'PLANTE : %s ($%04X page %d)' % (e, m.pc, m.page)
    # le modèle
    ecran = GrilleTrace()
    ent = EntreeTrace(lignes, ecran)
    modele_fichiers = dict(fichiers or {})
    z = zm.ZMachine(open(jeu, 'rb').read(), ecran, ent, graine=m.graine or 1, fichiers=modele_fichiers)
    z.tourne()
    return m, r, ecran, ent, z, c, avant, modele_fichiers


def compare(verifie, nom, m, r, ecran, ent, z, avant, attendu_fin='fini'):
    verifie(r == attendu_fin, '%s : le binaire %s (%s)' % (nom, 'rend la main' if attendu_fin == 'rendu' else 'attend la saisie suivante', r))
    so_b, so_m = m.sorties, ecran.sorties
    i = next((k for k in range(min(len(so_b), len(so_m))) if so_b[k] != so_m[k]), None)
    if i is None and len(so_b) == len(so_m):
        verifie(True, '%s : %d caractères vers l\'écran, les mêmes que le modèle' % (nom, len(so_b)))
    else:
        i = min(len(so_b), len(so_m)) if i is None else i
        ctx = lambda t: bytes(c if 32 <= c < 256 else 32 for c in t[max(0, i - 60):i + 20]).decode('cp437')
        verifie(False, '%s : écran (Ecran_Car) différent au caractère %d / %d-%d\n   binaire : %r\n   modèle  : %r'
                % (nom, i, len(so_b), len(so_m), ctx(so_b), ctx(so_m)))
    pb, pm = m.photos, ent.photos
    diff = []
    for k in range(min(len(pb), len(pm))):
        d = [(rg, col) for rg in range(30) for col in range(80) if pb[k][rg][col] != tuple(pm[k][rg][col])]
        if d:
            diff.append((k, d))
    verifie(len(pb) == len(pm) and not diff,
            '%s : %d saisies (modèle %d), l\'écran entier = la grille du modèle à chacune%s'
            % (nom, len(pb), len(pm), '' if not diff else ' : saisie %d, %d cases, ex. %s binaire %s modèle %s'
               % (diff[0][0], len(diff[0][1]), diff[0][1][0], pb[diff[0][0]][diff[0][1][0][0]][diff[0][1][0][1]],
                  pm[diff[0][0]][diff[0][1][0][0]][diff[0][1][0][1]])))
    if pm:
        verifie(m.vram_ok and all(m.vram_ok), '%s : la VRAM rattrape la copie d\'écran avant chaque saisie (%d fois)'
                % (nom, len(m.vram_ok)))
    if r == 'rendu':
        verifie(m.rd16(0xDFF6) == m.s_['handler_IRQ'], '%s : en sortant, rvec_IRQ rendu au BIOS' % nom)
        verifie(m.lit_vram()[25:30] == avant, '%s : en sortant, les rangées 25-29 d\'OSM-VISION rendues' % nom)
    vue = m.ecritures
    hors = sum(1 for e in vue if not e[2])
    par_trame = {}
    for t, _, _ in vue:
        par_trame[t] = par_trame.get(t, 0) + 1
    verifie(vue and hors == 0, '%s : %d écritures en VRAM, toutes dans l\'IRQ ou le BIOS (roue de FS_SaveFile) (%d hors)' % (nom, len(vue), hors))
    verifie(max(par_trame.values(), default=0) <= 480,
            '%s : au plus 3 rangées (480 octets) par trame (%d)' % (nom, max(par_trame.values(), default=0)))
    print('     %d instructions Z, %d instructions 6309 (%.0f par instruction Z), %d [Suite]'
          % (m.pas_z, m.n, m.n / max(1, m.pas_z), m.suites))


SEANCES = [
    # (jeu, lignes, fin attendue, « tout » seulement)
    ('czech.z5', [], 'rendu', False),
    ('dreamlands.z8', ['z', 'regarder', 'inventaire', 'nord', 'ouest', 'examiner porte', 'prendre tout', 'score'],
     'fini', False),
    # Zork I (v3, Infocom, MIT) : objets v3, ligne d'état de l'interpréteur
    ('zork/zork1.z3', ['look', 'open mailbox', 'take leaflet', 'read leaflet', 'south', 'east',
                       'open window', 'enter', 'take all', 'west', 'take lamp', 'move rug',
                       'open trap door', 'turn on lamp', 'down', 'score', 'inventory'], 'fini', False),
    # Z-Snake : dessine dans la fenêtre 1 sans @split_window, avance par délais
    ('zsnake.z5', [''] + [None] * 12, 'fini', False),
    ('praxix.z5', ['all'], 'fini', True),
    ('aventure.z5', ['regarder', 'inventaire', 'nord', 'sud', 'est', 'prendre tout', 'examiner chemin', 'score'],
     'fini', True),
    ('lieuxcommuns.z8', ['regarder', 'inventaire', 'nord', 'sud', 'est', 'prendre tout', 'examiner chemin'],
     'fini', True),
    ('Zork_LXIX.z5', ['look', 'inventory', 'north', 'south', 'examine me', 'score'], 'fini', True),
]


def main():
    s = v.sym()
    a = symboles()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    verifie(a.get('App_Start') == 0, 'App_Start à l\'offset 0')
    if len(sys.argv) == 3:
        lignes = open(sys.argv[2], encoding='utf-8').read().split('\n')
        m, r, ecran, ent, z, c, avant, _ = seance(s, a, sys.argv[1], lignes)
        compare(verifie, os.path.basename(sys.argv[1]), m, r, ecran, ent, z, avant)
        return 1 if erreurs else 0
    tout = len(sys.argv) == 2 and sys.argv[1] == 'tout'
    if not os.path.isdir(JEUX):
        print('Pas de jeux dans %s (ZMACHINE_JEUX) : rien à vérifier.' % JEUX)
        return 1
    for jeu, lignes, fin, long in SEANCES:
        if long and not tout:
            continue
        chemin = os.path.join(JEUX, jeu)
        if not os.path.exists(chemin):
            print('--   %s absent de %s : sauté' % (jeu, JEUX))
            continue
        m, r, ecran, ent, z, c, avant, _ = seance(s, a, chemin, lignes)
        compare(verifie, jeu, m, r, ecran, ent, z, avant, fin)
    jeu = os.path.join(JEUX, 'zork', 'zork1.z3')
    if os.path.exists(jeu):                 # v3 : @save / @restore sont des branchements
        lignes = ['open mailbox', 'north', 'east', 'open window', 'save', 'zork1',
                  'enter', 'take all', 'restore', 'zork1', 'look', 'inventory']
        m, r, ecran, ent, z, c, avant, mf = seance(s, a, jeu, lignes)
        compare(verifie, 'zork1 sauver/charger', m, r, ecran, ent, z, avant)
        f = c.lit('ZORK1.SAV')
        verifie(f is not None and f == mf.get('ZORK1.SAV'),
                'ZORK1.SAV (v3) sur la carte = le fichier Quetzal du modèle (%s / %s octets)'
                % (len(f) if f else None, len(mf.get('ZORK1.SAV', b''))))
    jeu = os.path.join(JEUX, 'zork_285.z5')
    if os.path.exists(jeu):
        lignes = ['open mailbox', 'north', 'east', 'open window', 'save', 'partie', 'enter',
                  'take all', 'restore', 'partie', 'look', 'inventory']
        m, r, ecran, ent, z, c, avant, mf = seance(s, a, jeu, lignes)
        compare(verifie, 'zork_285 sauver/charger', m, r, ecran, ent, z, avant)
        f = c.lit('PARTIE.SAV')
        verifie(f is not None and f == mf.get('PARTIE.SAV'),
                'PARTIE.SAV sur la carte = le fichier Quetzal du modèle (%s / %s octets)'
                % (len(f) if f else None, len(mf.get('PARTIE.SAV', b''))))
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
