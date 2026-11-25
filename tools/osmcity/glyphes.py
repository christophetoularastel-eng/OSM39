#!/usr/bin/env python3
# ===================================================================
# glyphes.py - Les tuiles d'OSM City (banque de police 1, page 1)
# ===================================================================
# Projet : la police de la mono passe à un 28C256 (4 banques de 2 pages,
# choisies par $A120 D4-D5 ; U525 O4/O5 -> U515 A13/A14). La banque 1 est
# celle d'OSM City : sa page 0 = la page 0 d'aujourd'hui (le texte), sa
# page 1 = les tuiles dessinées ici.
#
# Chaque case prend un glyphe selon sa sorte ET ses quatre voisines (bits
# N=1, E=2, S=4, O=8 : le côté où la voisine est d'une autre famille) :
# bords de trottoir, contours des toits, berges, comme les murs de
# GLOUTON. Herbe : trois dessins tirés par la position.
#
#   python3 tools/osmcity/glyphes.py --planche F.png     les glyphes
#   python3 tools/osmcity/glyphes.py --police F          la police 32 Ko
#   python3 tools/osmcity/glyphes.py --essai F           une police d'essai de
#        8 Ko pour l'AT28C64 d'aujourd'hui : page 0 = le texte, page 1 = les
#        tuiles (OSM City s'y voit ; les autres programmes perdent leurs
#        glyphes de la page 1 : cadres, mosaïques, GLOUTON...)
# Le choix du glyphe de chaque case (sorte + voisines) est dans osmcity.py
# (tuile), avec la carte et le modèle du jeu.
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
FONTE = os.path.join(RACINE, 'video', 'font_osm39.bin')

# --- numéros des glyphes (page 1 de la banque 1) ---
G_ROUTE = 0x00      # + masque (16 glyphes vides : la chaussée, sans bordure)
G_BATI = 0x10       # + masque : contour du toit
G_EAU = 0x20        # + masque : berges
G_PIETON = 0x30     # + masque : pavés, bordure
G_HERBE = 0x40      # 4 dessins
G_ARBRE = 0x44
G_PLACE = 0x45      # une place de stationnement (rangées paires d'un parking)
G_P = 0x46          # « P » dans l'allée
G_PONT = 0x60       # + masque de l'eau voisine : garde-corps
G_FALAISE = 0x80    # + masque : hachures (pente forte, d'après le relief de l'IGN)
G_VOITD = 0x90      # voitures en biais, 2 glyphes chacune : NE, SE, SO, NO
G_COIN = 0x70       # 4 coins arrondis : N+O, N+E, E+S, S+O exposés (dedans = premier plan)
G_VOIT = 0x50       # nord, sud, est (arrière, avant), ouest (avant, arrière)
G_PIETONNE = 0x56   # une personne vue de dessus
G_BUTIN = 0x57      # le sac du butin
G_PLANQUE = 0x58    # la planque (une maison)
G_FLECHE = 0x98     # + direction 0..7 (N, NE, E, SE, S, SO, O, NO) : vers l'objectif


def g(*rangees):
    """16 rangées de 8 caractères ('#' = point allumé) -> 16 octets."""
    assert len(rangees) == 16 and all(len(r) == 8 for r in rangees), rangees
    return bytes(int(r.replace('#', '1').replace('.', '0'), 2) for r in rangees)


def vide():
    return bytearray(16)


def bords(base, m, plein=False, retrait=0):
    """Ajoute à base (16 octets) les côtés du masque m : une ligne au bord
    (retrait 0) ou en retrait (contour intérieur, comme un mur de GLOUTON)."""
    b = bytearray(base)
    r = retrait
    if m & 1:                               # nord
        b[r] = 0xFF
    if m & 4:                               # sud
        b[15 - r] = 0xFF
    for y in range(16):
        if m & 8:                           # ouest
            b[y] |= 0x80 >> r
        if m & 2:                           # est
            b[y] |= 0x01 << r
    if plein:                               # contour doublé
        if m & 1:
            b[r + 1] |= 0xFF
        if m & 4:
            b[14 - r] |= 0xFF
    return bytes(b)


def efface_bords(b, m, r):
    """Le motif intérieur ne déborde pas sur le contour en retrait r."""
    b = bytearray(b)
    for y in range(16):
        if (m & 1 and y <= r) or (m & 4 and y >= 15 - r):
            b[y] = 0
        if m & 8:
            b[y] &= 0xFF >> (r + 1)
        if m & 2:
            b[y] &= (0xFF << (r + 1)) & 0xFF
    return bytes(b)


TOIT = g('........', '.#...#..', '........', '...#...#', '........', '.#...#..', '........',
         '...#...#', '........', '.#...#..', '........', '...#...#', '........', '.#...#..',
         '........', '...#...#')
VAGUES = g('........', '........', '........', '........', '..#.....', '...#.#..', '....#...',
           '........', '........', '........', '.....#..', '..#.#...', '...#....', '........',
           '........', '........')            # (colonnes 2-5 : les berges ne les mangent pas)
HACHURES = g('........', '..#.....', '...#....', '....#...', '........', '......#.',
             '.......#', '........', '........', '.#......', '..#.....', '...#....', '........',
             '.....#..', '......#.', '........')
PAVES = g('#.......', '........', '........', '........', '....#...', '........', '........',
          '........', '#.......', '........', '........', '........', '....#...', '........',
          '........', '........')
HERBES = [
    g('........', '........', '..#.....', '........', '........', '......#.', '.....#..',
      '........', '........', '.#......', '........', '........', '........', '....#...',
      '........', '........'),
    g('........', '.....#..', '........', '........', '.#......', '........', '........',
      '........', '......#.', '........', '...#....', '........', '........', '........',
      '.#......', '........'),
    g('........', '........', '........', '.#.#....', '........', '........', '........',
      '.....#..', '........', '........', '........', '........', '..#.....', '.#......',
      '........', '........'),
    g('........', '......#.', '........', '........', '........', '..#.....', '........',
      '........', '........', '........', '.....#..', '....#...', '........', '........',
      '........', '#.......'),
]
ARBRE = g('........', '..####..', '.##..##.', '##.##.##', '#.####.#', '##.##.##', '#.#..#.#',
          '.##.###.', '..####..', '...##...', '...##...', '...##...', '........', '........',
          '........', '........')
PLACE = g('........', '#.......', '#.......', '#.......', '#.......', '#.......', '#.......',
          '#.......', '#.......', '#.......', '#.......', '#.......', '#.......', '#.......',
          '#.......', '........')
PANNEAU = g('........', '........', '........', '.#####..', '.##..##.', '.##..##.', '.##..##.',
            '.#####..', '.##.....', '.##.....', '.##.....', '.##.....', '........', '........',
            '........', '........')
VOIT_N = g('..####..', '.######.', '.#....#.', '.#....#.', '##....##', '########', '.######.',
           '.######.', '.######.', '.######.', '########', '##....##', '.#....#.', '.######.',
           '..####..', '........')
VOIT_E = ['................', '................', '................',
          '..###......###..', '.##############.', '.##.#######..##.', '.##.#######..###',
          '.##.#######..###', '.##.#######..###', '.##.#######..###', '.##.#######..##.',
          '.##############.', '..###......###..', '................', '................',
          '................']
BUTIN = g('........', '........', '...##...', '..#..#..', '...##...', '..####..', '.######.',
          '##.##.##', '#.####.#', '#..#...#', '#.###..#', '#...#..#', '##.##.##', '.######.',
          '........', '........')
PLANQUE = g('........', '...##...', '..####..', '.######.', '########', '.#....#.', '.#.##.#.',
            '.#.##.#.', '.#....#.', '.#.##.#.', '.#.##.#.', '.######.', '........', '........',
            '........', '........')
PERSONNE = g('........', '........', '........', '........', '...##...', '..####..',
             '..####..', '...##...', '.######.', '#.####.#', '..####..', '..#..#..',
             '..#..#..', '.##..##.', '........', '........')


def voiture_biais(dx, dy):
    """La voiture tournée de 45 degrés (vers dx, dy : +-1 ; y vers le bas),
    16 x 16 points sur deux cases : un rectangle de 14 x 7, ses vitres
    évidées (comme VOIT_N). Rend les 16 rangées de 16 caractères."""
    import math
    ax, ay = dx / math.sqrt(2), dy / math.sqrt(2)
    out = []
    for py in range(16):
        r = ''
        for px in range(16):
            rx, ry = px - 7.5, py - 7.5
            le_long, en_travers = rx * ax + ry * ay, -rx * ay + ry * ax
            dedans = abs(le_long) <= 7 and abs(en_travers) <= 3.6
            vitre = abs(en_travers) <= 2.2 and (2.0 <= le_long <= 3.8 or -5.2 <= le_long <= -4.0)
            r += '#' if dedans and not vitre else '.'
        out.append(r)
    return out


def demi(rangees, gauche):
    return g(*[(r[:8] if gauche else r[8:]) for r in rangees])


def miroir(rangees):
    return [r[::-1] for r in rangees]


def fleche(k):
    """La flèche de la direction k (0 nord ... 7 nord-ouest) : 8 x 16."""
    import math
    a = math.radians(45 * k)
    ux, uy = math.sin(a), -math.cos(a) * 2          # (les points sont 2 fois plus hauts)
    b = bytearray(16)
    for y in range(16):
        for x in range(8):
            rx, ry = (x - 3.5), (y - 7.5) / 2
            le_long = rx * math.sin(a) + ry * -math.cos(a)
            en_travers = rx * math.cos(a) + ry * math.sin(a)
            tige = -3.2 <= le_long <= 1.5 and abs(en_travers) <= 0.6
            pointe = 0.8 <= le_long <= 3.6 and abs(en_travers) <= (3.6 - le_long) * 0.9
            if tige or pointe:
                b[y] |= 0x80 >> x
    return bytes(b)


def coin(m):
    """Un coin arrondi : m = 9 (nord + ouest exposés), 3 (N + E), 6 (E + S),
    12 (S + O). Dedans (le premier plan) : le quart d'ellipse centré sur le
    coin opposé."""
    b = bytearray(16)
    for y in range(16):
        for x in range(8):
            u = (x + 0.5) / 8 if m in (9, 12) else 1 - (x + 0.5) / 8
            v = (y + 0.5) / 16 if m in (9, 3) else 1 - (y + 0.5) / 16
            if (1 - u) ** 2 + (1 - v) ** 2 <= 1:
                b[y] |= 0x80 >> x
    return bytes(b)


COINS = (9, 3, 6, 12)                       # G_COIN + 0..3


def page_tuiles():
    """Les 256 glyphes de la page 1 de la banque 1 (4096 octets)."""
    p = [bytes(16)] * 256
    for m in range(16):
        p[G_ROUTE + m] = bytes(16)          # pas de bordure : coupées par les coins arrondis,
                                            # elles laissaient des bouts de trait
        p[G_BATI + m] = bords(efface_bords(TOIT, m, 2), m, retrait=1)
        p[G_EAU + m] = bords(efface_bords(VAGUES, m, 1), m)
        p[G_PIETON + m] = PAVES                 # (pas de bordure non plus)
        p[G_FALAISE + m] = bords(HACHURES, m)
    for i, h in enumerate(HERBES):
        p[G_HERBE + i] = h
    p[G_ARBRE] = ARBRE
    p[G_PLACE] = PLACE
    p[G_P] = PANNEAU
    for m in range(16):                     # pont : garde-corps côté eau
        p[G_PONT + m] = bords(vide(), m, plein=True)
    p[G_VOIT] = VOIT_N
    p[G_VOIT + 1] = bytes(reversed(VOIT_N))
    p[G_VOIT + 2] = demi(VOIT_E, True)
    p[G_VOIT + 3] = demi(VOIT_E, False)
    p[G_VOIT + 4] = demi(miroir(VOIT_E), True)
    p[G_VOIT + 5] = demi(miroir(VOIT_E), False)
    p[G_PIETONNE] = PERSONNE
    p[G_BUTIN] = BUTIN
    p[G_PLANQUE] = PLANQUE
    for k in range(8):                      # les flèches : un trait et sa pointe
        p[G_FLECHE + k] = fleche(k)
    for k, (dx, dy) in enumerate(((1, -1), (1, 1), (-1, 1), (-1, -1))):    # NE, SE, SO, NO
        v = voiture_biais(dx, dy)
        p[G_VOITD + 2 * k] = demi(v, True)
        p[G_VOITD + 2 * k + 1] = demi(v, False)
    for k, m in enumerate(COINS):
        p[G_COIN + k] = coin(m)
    return b''.join(p)


def banques():
    """La police de 32 Ko (28C256) : 4 banques de 2 pages (A13-A14 =
    $A120 D4-D5). Banque 0 = la police d'aujourd'hui ; banque 1 = OSM City
    (page 0 : le texte d'aujourd'hui, page 1 : les tuiles) ; 2 et 3 : la
    banque 0 en attendant d'autres jeux."""
    f = open(FONTE, 'rb').read()
    assert len(f) == 8192
    return f + f[:4096] + page_tuiles() + f + f


def dessine(cases, page, fichier, echelle=2):
    """cases : rangées de (glyphe, attribut) ; page : 4096 octets (une
    page), ou 8192 (une banque : D7 de l'attribut choisit la page).
    page=None : la banque 1 (celle d'OSM City)."""
    if page is None:
        page = banques()[8192:16384]
    from PIL import Image
    h, w = len(cases), len(cases[0])
    im = Image.new('RGB', (w * 8, h * 16))
    px = im.load()
    for r, rang in enumerate(cases):
        for col, (gl, a) in enumerate(rang):
            av, ar = couleur(a & 15), couleur(a >> 4 & 7, True)
            base = gl * 16 + (4096 if len(page) > 4096 and a & 0x80 else 0)
            for ly in range(16):
                b = page[base + ly]
                for lx in range(8):
                    px[col * 8 + lx, r * 16 + ly] = av if b >> (7 - lx) & 1 else ar
    if echelle != 1:
        im = im.resize((im.width * echelle, im.height * echelle), Image.NEAREST)
    im.save(fichier)


def couleur(i, fond=False):
    v = 255 if (fond or not i & 8) else 150
    return ((i >> 2 & 1) * v, (i >> 1 & 1) * v, (i & 1) * v)


def planche(fichier):
    p = page_tuiles()
    cases = [[(r * 16 + col, 0x87) for col in range(16)] for r in range(7)]
    dessine(cases, p, fichier, 3)


if __name__ == '__main__':
    a = sys.argv[1:]
    if '--planche' in a:
        planche(a[a.index('--planche') + 1])
    if '--police' in a:
        open(a[a.index('--police') + 1], 'wb').write(banques())
    if '--essai' in a:
        open(a[a.index('--essai') + 1], 'wb').write(banques()[8192:16384])
