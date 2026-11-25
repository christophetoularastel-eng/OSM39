#!/usr/bin/env python3
# ===================================================================
# verifie_graphe.py - Le mode graphique du BIOS (bios/graphe.asm) =
#                     le modèle tools/graphe/graphe.py
# ===================================================================
# Le VRAI BIOS (EPROM + BIOS2) dans la machine de verifie_fs.py, avec :
#   - la VRAM en 8 pages de 8 Ko (la page vidéo de $A120, D0-D2) ;
#   - l'IRQ du VSYNC toutes les TRAME instructions (le vrai handler_IRQ,
#     par $FFF8 et rvec_IRQ), prise dès que I = 0 ;
#   - un appelant en page 1 dont la PILE est dans sa page ($0400), comme
#     BBC BASIC, qui appelle sys_Graphe par la table des services ;
#   - /BIN/POLICE8 sur une carte OSMFS (egofs).
# Vérifie :
#   1. GR_DEBUT : la VRAM (8 pages) effacée, les couleurs des cases 0-1999
#      = l'attribut, le reste $08 ; la page 3 à 0 ; la police en $7D00 ;
#   2. après chaque fonction (points, lignes de toutes pentes, coupées,
#      inversées ; rectangles ; cercles et disques, r = 0, coupés,
#      inversés ; caractères ; couleurs ; effacement ; GR_LIT) : la page 3
#      = le modèle, octet pour octet ; registres rendus (sauf A de GR_LIT),
#      page 1 rendue, pile rendue, C = 0 ; refus (C = 1) : fonction
#      inconnue, mode non ouvert ;
#   3. après GR_ATTEND : l'image relue dans la VRAM (r x 2048 + case) = le
#      modèle, les couleurs des cases = le modèle, celles des rangées 26-29
#      à $08 ;
#   4. hors GR_DEBUT / GR_FIN, la VRAM n'est écrite QUE dans l'IRQ, au
#      plus LIMITE cycles estimés après son entrée (4 par instruction, 3 par
#      octet de TFM) ; ni la console ni le moulinet n'y touchent ;
#   5. GR_FIN : GRAPH coupé, l'écran texte effacé (espaces).
#   make -C bios && python3 test/verifie_graphe.py
# ===================================================================
import os
import random
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'graphe'))
sys.path.insert(0, os.path.join(RACINE, 'tools', 'egofs'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import egofs_core               # noqa: E402
import graphe as g              # noqa: E402

TRAME = 7000                    # instructions par trame
LIMITE = 1900                   # cycles estimés après l'entrée de l'IRQ
PILE = 0x0400                   # pile de l'appelant, dans SA page (1)
BLOC = 0x0500                   # bloc de paramètres (page 1)
RETOUR1 = 0x0600                # adresse de retour sentinelle (page 1)


class Banc(va.MachineAsm):
    def __init__(self, image, s):
        super().__init__(image, s)
        self.vram = [bytearray(0x2000) for _ in range(8)]
        self.vpage = 0
        self.graph = False
        self.trame = 0
        self.n = 0
        self.irq = False
        self.dans_irq = 0
        self.cyc = 0                    # cycles estimés depuis l'entrée de l'IRQ
        self.ecrit = False
        self.hors_irq = []              # écritures VRAM hors de l'IRQ
        self.cyc_max = 0
        self.permis = False             # GR_DEBUT / GR_FIN : écritures libres

    def rd8(self, a):
        a &= 0xFFFF
        if 0x8000 <= a < 0xA000:
            return self.vram[self.vpage][a - 0x8000]
        return super().rd8(a)

    def wr8(self, a, x):
        a &= 0xFFFF
        if a == 0xA120:
            self.vpage = x & 7
            self.graph = bool(x & 8)
        if 0x8000 <= a < 0xA000:
            self.vram[self.vpage][a - 0x8000] = x & 255
            self.ecrit = True
            if not self.dans_irq and not self.permis:
                self.hors_irq.append((hex(a), self.vpage, hex(self.pc)))
            return
        super().wr8(a, x)

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

    def step(self):
        self.n += 1
        if self.n % TRAME == 0:
            self.trame += 1
            self.irq = True
        if self.irq and not self.cc & 0x10:
            self.irq = False
            self.dans_irq += 1
            self.cyc = 0
            self.interruption(0xFFF8)
        tfm = 0
        if self.rd8(self.pc) == 0x11 and 0x38 <= self.rd8(self.pc + 1) <= 0x3B:
            tfm = self.w
        self.ecrit = False
        super().step()
        if self.dans_irq:
            self.cyc += 4 + 3 * tfm
            if self.ecrit:
                self.cyc_max = max(self.cyc_max, self.cyc)

    # --- ce que l'écran montre ---
    def image_vram(self):
        img = bytearray(g.HAUT * g.OCTETS_LIGNE)
        for y in range(g.HAUT):
            R, r = divmod(y, 16)
            for col in range(80):
                A = r * 2048 + R * 80 + col
                img[y * 80 + col] = self.vram[A >> 12][2 * (A & 4095)]
        return img

    def couleurs_vram(self):
        return bytes(self.vram[0][2 * c + 1] for c in range(2000))


def prepare():
    s = v.sym()
    d = tempfile.mkdtemp()
    image = os.path.join(d, 'carte.img')
    with open(image, 'wb') as f:
        f.truncate(8 * 1024 * 1024)
    core = egofs_core.OSMFS_Core(image)
    old = sys.stdout
    sys.stdout = open(os.devnull, 'w')
    core.format_fs()
    chemin = os.path.join(d, 'POLICE8')
    open(chemin, 'wb').write(g.police())
    core.inject_file(chemin, 'POLICE8', 1, '0000', 0x07)
    sys.stdout.close()
    sys.stdout = old
    m = Banc(image, s)
    v.installe_bios(m)
    m.wr16(s['rvec_IRQ'], s['handler_IRQ'])
    m.mem[s['current_page']] = 1
    m.page = 1
    return m, s


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    m, s = prepare()
    service = m.rd16(s['sys_Graphe'])
    mod = g.Ecran()
    alea = random.Random(39)
    fautes = []

    def appel(f, a=0, p=(), cc=0x00, max_pas=30_000_000):
        """sys_Graphe depuis la page 1, pile en page 1. Rend (C, A)."""
        for i, w in enumerate(list(p) + [0] * (4 - len(p))):
            w &= 0xFFFF
            m.banks[1][BLOC + 2 * i] = w >> 8
            m.banks[1][BLOC + 2 * i + 1] = w & 255
        m.page = 1
        m.mem[s['current_page']] = 1
        m.s = PILE - 2
        m.banks[1][PILE - 2] = RETOUR1 >> 8
        m.banks[1][PILE - 1] = RETOUR1 & 255
        regs = dict(b=f, x=BLOC, y=0x1234, u=0x5678, w=0x9ABC)
        m.a, m.b, m.x, m.y, m.u, m.w = a, f, BLOC, 0x1234, 0x5678, 0x9ABC
        m.cc = cc
        m.pc = service
        pas = 0
        while not (m.pc == RETOUR1 and m.page == 1 and m.dans_irq == 0):
            if m.sd():
                continue
            m.step()
            pas += 1
            if pas > max_pas:
                raise RuntimeError('trop long à $%04X (f = %d)' % (m.pc, f))
        ok = (m.b, m.x, m.y, m.u, m.w) == (regs['b'], regs['x'], regs['y'], regs['u'], regs['w']) \
            and m.s == PILE and m.mem[s['current_page']] == 1 and m.page == 1
        if f != g.GR_LIT and m.a != a:
            ok = False
        if not ok:
            fautes.append((f, p, m.a, m.b, hex(m.x), hex(m.y), hex(m.u), hex(m.w), hex(m.s)))
        return m.cc & 1, m.a

    def attend_trames(n):
        """Laisse tourner n trames, l'appelant en boucle (IRQ ouvertes)."""
        m.page = 1
        m.mem[s['current_page']] = 1
        m.banks[1][0x0700:0x0702] = bytes([0x20, 0xFE])        # BRA *
        m.pc = 0x0700
        m.cc = 0
        fin = m.trame + n
        while m.trame < fin:
            m.step()
        while m.dans_irq:
            m.step()

    # --- refus avant l'ouverture ---
    c, _ = appel(g.GR_POINT, 0, (1, 1))
    verifie(c == 1, 'mode non ouvert : GR_POINT refusé (C = 1)')

    # --- 1. ouverture ---
    m.permis = True
    c, _ = appel(g.GR_DEBUT, 0x07)
    m.permis = False
    mod.appel(g.GR_DEBUT, 0x07)
    verifie(c == 0 and m.mem[s['gr_actif']] and m.graph and m.vpage == 0,
            'GR_DEBUT : C = 0, gr_actif, GRAPH à $A120')
    pages_nulles = all(not any(m.vram[p][i] for i in range(0, 0x2000, 2)) for p in range(8))
    coul = m.couleurs_vram()
    cache = all(m.vram[0][i] == 0x08 for i in range(2 * 2000 + 1, 0x2000, 2))
    verifie(pages_nulles and coul == bytes([7]) * 2000 and cache,
            'GR_DEBUT : points à 0 dans les 8 pages, cases 0-1999 = $07, le reste $08')
    verifie(bytes(m.banks[3][:32000]) == bytes(32000) and bytes(m.banks[3][32000:32768]) == g.police(),
            'GR_DEBUT : page 3 à 0, la police 8 x 8 en $7D00 (/BIN/POLICE8)')

    # --- 2. les fonctions, une à une ---
    def essai(f, a, p, nom):
        c, ra = appel(f, a, p)
        mc, ma = mod.appel(f, a, p)
        bon = c == mc and bytes(m.banks[3][:32000]) == bytes(mod.img)
        if f == g.GR_LIT:
            bon = bon and ra == ma
        if not bon:
            diff = [i for i in range(32000) if m.banks[3][i] != mod.img[i]][:5]
            verifie(False, '%s : page 3 = modèle (écarts %s)' % (nom, diff))
        return bon

    cas = []
    for mode in (0, 2, 1):
        cas.append((g.GR_POINT, mode, (5, 7), 'point mode %d' % mode))
    cas += [(g.GR_POINT, 0, (639, 399), 'point (639, 399)'), (g.GR_POINT, 0, (640, 10), 'point x = 640 (ignoré)'),
            (g.GR_POINT, 0, (-1, 10), 'point x = -1 (ignoré)'), (g.GR_POINT, 0, (10, 400), 'point y = 400 (ignoré)')]
    for (x0, y0, x1, y1) in ((0, 0, 639, 399), (639, 0, 0, 399), (100, 50, 100, 300), (20, 200, 600, 200),
                             (300, 300, 310, 100), (310, 100, 300, 300), (-100, -50, 700, 450),
                             (50, 50, 50, 50), (600, 10, 30, 20)):
        cas.append((g.GR_LIGNE, 0, (x0, y0, x1, y1), 'ligne (%d,%d)-(%d,%d)' % (x0, y0, x1, y1)))
    cas.append((g.GR_LIGNE, 2, (0, 0, 639, 399), 'ligne inversée sur la diagonale (s\'efface)'))
    for (x0, y0, x1, y1, mode) in ((10, 10, 20, 20, 0), (3, 30, 4, 35, 0), (5, 40, 300, 60, 0),
                                   (630, 380, 700, 420, 0), (-20, -20, 7, 7, 0), (100, 100, 200, 150, 2),
                                   (150, 120, 50, 90, 1), (8, 200, 15, 210, 0), (9, 220, 9, 230, 2)):
        cas.append((g.GR_RECT, mode, (x0, y0, x1, y1), 'rectangle (%d,%d)-(%d,%d) mode %d' % (x0, y0, x1, y1, mode)))
    for (xc, yc, r, mode) in ((320, 200, 150, 0), (320, 200, 0, 0), (50, 50, 1, 0), (600, 380, 60, 0),
                              (100, 300, 40, 2), (0, 0, 30, 0)):
        cas.append((g.GR_CERCLE, mode, (xc, yc, r), 'cercle (%d,%d) r %d mode %d' % (xc, yc, r, mode)))
    for (xc, yc, r, mode) in ((400, 120, 50, 0), (200, 330, 1, 0), (500, 250, 0, 2), (630, 10, 25, 2),
                              (320, 200, 90, 2)):
        cas.append((g.GR_DISQUE, mode, (xc, yc, r), 'disque (%d,%d) r %d mode %d' % (xc, yc, r, mode)))
    for (col, rang, c, mode) in ((0, 0, ord('A'), 0), (79, 24, ord('z'), 0), (40, 12, ord('@'), 2),
                                 (10, 3, 0x05, 0), (11, 3, 0xE9, 0), (80, 0, ord('X'), 0), (0, 25, ord('X'), 0)):
        cas.append((g.GR_CAR, mode, (col, rang, c), 'caractère $%02X en (%d, %d) mode %d' % (c, col, rang, mode)))
    for (x, y) in ((5, 7), (6, 7), (639, 399), (700, 5), (320, 50)):
        cas.append((g.GR_LIT, 0, (x, y), 'GR_LIT (%d, %d)' % (x, y)))
    for _ in range(40):                 # au hasard
        f = alea.choice((g.GR_POINT, g.GR_LIGNE, g.GR_RECT, g.GR_CERCLE, g.GR_DISQUE, g.GR_LIT))
        p = (alea.randrange(-60, 700), alea.randrange(-60, 460), alea.randrange(-60, 700), alea.randrange(-60, 460))
        if f in (g.GR_CERCLE, g.GR_DISQUE):
            p = (p[0], p[1], alea.randrange(0, 120))
        cas.append((f, alea.randrange(3), p, 'au hasard f = %d %s' % (f, p)))
    bons = sum(essai(*c) for c in cas)
    verifie(bons == len(cas), 'page 3 = modèle après chacune des %d fonctions (%d bonnes)' % (len(cas), bons))
    verifie(not fautes, 'registres, pile (en page 1) et page rendus, A rendu sauf GR_LIT %s' % fautes[:3])

    # --- 3. l'écran rattrape l'image ---
    c, _ = appel(g.GR_COULEUR, 0x14, (2, 1, 30, 6))
    mod.appel(g.GR_COULEUR, 0x14, (2, 1, 30, 6))
    c2, _ = appel(g.GR_COULEUR, 0x63, (70, 20, 90, 30))
    mod.appel(g.GR_COULEUR, 0x63, (70, 20, 90, 30))
    verifie(c == 0 and c2 == 0, 'GR_COULEUR (deux, la seconde attend la première ; une coupée)')
    t0 = m.trame
    c, _ = appel(g.GR_ATTEND)
    verifie(c == 0 and m.image_vram() == bytes(mod.img),
            'GR_ATTEND (%d trames) : l\'image relue dans la VRAM = le modèle' % (m.trame - t0))
    verifie(m.couleurs_vram() == bytes(mod.coul), 'les couleurs des cases = le modèle')
    cache = all(m.vram[0][i] == 0x08 for i in range(2 * 2048 + 1, 0x2000, 2))
    verifie(cache, 'couleurs des rangées 26-29 ($9000-$9FFF, page 0) toujours $08')
    verifie(not m.hors_irq and m.cyc_max <= LIMITE,
            'VRAM écrite seulement dans l\'IRQ, au plus %d cycles estimés après son entrée (limite %d) %s'
            % (m.cyc_max, LIMITE, m.hors_irq[:3]))

    # --- l'effacement, puis un dessin et le rattrapage ---
    c, _ = appel(g.GR_EFFACE, 0x70)
    mod.appel(g.GR_EFFACE, 0x70)
    for i in range(0, 640, 40):
        appel(g.GR_LIGNE, 0, (i, 0, 639 - i, 399))
        mod.appel(g.GR_LIGNE, 0, (i, 0, 639 - i, 399))
    t0 = m.trame
    appel(g.GR_ATTEND)
    verifie(m.image_vram() == bytes(mod.img) and m.couleurs_vram() == bytes(mod.coul),
            'GR_EFFACE puis 16 lignes : l\'écran = le modèle après %d trames' % (m.trame - t0))

    # --- la console et le moulinet se taisent ---
    avant = [bytes(p) for p in m.vram]
    for ch in b'BONJOUR\r\n':        # PUTCHARV : MachineAsm intercepte PrintChar
        m.a, m.b = ch, 0x07
        v.appelle(m, s['PUTCHARV'])
    attend_trames(5)
    verifie([bytes(p) for p in m.vram] == avant and not m.hors_irq, 'console en mode graphique : la VRAM intacte')

    # --- refus, et IRQ masquées ---
    c, _ = appel(12)
    verifie(c == 1, 'fonction 12 inconnue : C = 1')
    c, _ = appel(g.GR_POINT, 0, (1, 2), cc=0x50)
    mod.appel(g.GR_POINT, 0, (1, 2))
    c2, _ = appel(g.GR_ATTEND, cc=0x50)
    verifie(c == 0 and c2 == 0 and bytes(m.banks[3][:32000]) == bytes(mod.img),
            'IRQ masquées chez l\'appelant : le point est dessiné, GR_ATTEND rend la main')
    verifie(not m.hors_irq and m.cyc_max <= LIMITE,
            'toujours rien hors de l\'IRQ, au plus %d cycles estimés' % m.cyc_max)

    # --- 5. fermeture ---
    m.permis = True
    c, _ = appel(g.GR_FIN)
    m.permis = False
    texte = all(m.vram[0][2 * i] == 0x20 for i in range(2400))
    verifie(c == 0 and not m.graph and not m.mem[s['gr_actif']] and texte,
            'GR_FIN : GRAPH coupé, gr_actif = 0, écran texte effacé (espaces)')
    c, _ = appel(g.GR_POINT, 0, (1, 1))
    verifie(c == 1, 'après GR_FIN : GR_POINT refusé')

    # --- 6. depuis le Terminal : la console reste dans sa zone ---
    m.page = 1
    m.mem[s['current_page']] = 1
    m.a, m.b, m.w, m.y = 10, 5, (40 << 8) | 10, 0x1F      # col 10, rangée 5, 40 x 10
    v.appelle(m, m.rd16(s['sys_Console_Zone']))
    attend_trames(12)
    m.permis = True
    appel(g.GR_DEBUT, 0x07)
    appel(g.GR_DISQUE, 0, (320, 200, 150))
    appel(g.GR_ATTEND)
    c, _ = appel(g.GR_FIN)
    m.permis = False
    attend_trames(12)
    for ch in b'SALUT':
        m.a, m.b = ch, 0x1F
        v.appelle(m, s['PUTCHARV'])
    attend_trames(5)

    def case(col, rang):
        return m.vram[0][2 * (rang * 80 + col)], m.vram[0][2 * (rang * 80 + col) + 1]
    dehors = all(case(cl, r) == (0x20, 0x08) for r in range(30) for cl in range(80)
                 if not (10 <= cl < 50 and 5 <= r < 15))
    dedans = all(case(cl, r) == (0x20, 0x1F) for r in range(5, 15) for cl in range(10, 50)
                 if not (r == 5 and cl < 15))
    texte = bytes(case(cl, 5)[0] for cl in range(10, 15)) == b'SALUT'
    verifie(c == 0 and m.mem[s['cz_actif']] and dehors and dedans and texte and not m.graph
            and m.mem[s['ecran_abime']] == 1,
            'GR_FIN dans le Terminal : écran noir ($08) autour, zone à sa couleur, '
            'le texte revient dans la zone, ecran_abime = 1 (le SHELL fera redessiner)')

    print()
    if erreurs:
        print('ÉCHEC : %d échec(s)' % len(erreurs))
        sys.exit(1)
    print('Tout est bon.')


if __name__ == '__main__':
    main()
