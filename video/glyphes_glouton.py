#!/usr/bin/env python3
# ===================================================================
# glyphes_glouton.py - Labyrinthe et glyphes de GLOUTON (apps/glouton.asm)
# ===================================================================
# Source UNIQUE du labyrinthe et des dessins de GLOUTON. Le script :
#   1. vérifie le labyrinthe (27 x 21 cases, symétrique, couloirs d'une
#      case, pas de cul-de-sac) ;
#   2. dessine les murs à la manière de la borne : contour de l'ensemble
#      des murs, en retrait de 4 pixels, coins arrondis ; puis découpe
#      l'image en cellules 8 x 16 et ne garde que les cellules distinctes ;
#   3. dessine les sprites (GLOUTON, fantômes, fruits, points...) ;
#   4. écrit ces glyphes dans la PAGE 1 de video/font_osm39.bin, dans la
#      plage réservée par lib/ui.inc (le reste de la plage est remis à 0) ;
#   5. génère apps/glout_data.inc (codes des glyphes, cases du
#      labyrinthe, glyphes des murs) : NE PAS l'éditer à la main.
#
#   python3 video/glyphes_glouton.py                 # police + .inc
#   python3 video/glyphes_glouton.py --apercu x.png  # + image de contrôle
#
# Une case du jeu = 2 cellules côte à côte = 16 x 16 pixels (carrés à
# l'écran). Ordre des bits d'une ligne de glyphe : bit 7 = pixel de gauche.
# Relancer le script est sans effet si rien n'a changé (idempotent).
# ===================================================================
import math
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
POLICE = os.path.join(ICI, 'font_osm39.bin')
INC = os.path.join(RACINE, 'apps', 'glout_data.inc')

# Plage de la page 1 réservée à GLOUTON (lib/ui.inc, à garder d'accord)
PLAGE = list(range(0x88, 0x100))

# --- Labyrinthe : la borne (28 x 31) ramenée à 27 x 21. Moitié gauche
#     (colonnes 0-13, la 13 est l'axe) ; la droite est le miroir.
#     # mur   X vide hors du jeu (dessiné comme un mur)   - porte
#     . point   o pastille   (espace) couloir sans point
#     Cases fixes : GLOUTON (13,15), Rouge (13,7) au-dessus de la porte
#     (13,8), maison (11-15,9), fruit (13,11), tunnel rangée 9. ---
MOITIE = [
    "##############",   # 0
    "#............#",   # 1
    "#o####.#####.#",   # 2
    "#.............",   # 3
    "#.####.##.####",   # 4
    "#......##....#",   # 5
    "######.##### #",   # 6
    "XXXXX#.##     ",   # 7
    "XXXXX#.## ###-",   # 8
    "      .   #   ",   # 9  tunnel
    "######.## ####",   # 10
    "XXXXX#.##     ",   # 11
    "######.## ####",   # 12
    "#............#",   # 13
    "#.####.#####.#",   # 14
    "#o..##....... ",   # 15
    "###.##.##.####",   # 16
    "#......##....#",   # 17
    "#.##########.#",   # 18
    "#.............",   # 19
    "##############",   # 20
]
LARG, HAUT = 27, 21
RANG_TUNNEL = 9
TUNNEL_BORDS = range(6, 13)     # hors écran à gauche/droite : mur

LAB = [m + m[:13][::-1] for m in MOITIE]

T_VIDE, T_POINT, T_PASTILLE, T_MUR, T_PORTE = 0, 1, 2, 3, 4
TYPES = {' ': T_VIDE, '.': T_POINT, 'o': T_PASTILLE,
         '#': T_MUR, 'X': T_MUR, '-': T_PORTE}


def verifie_labyrinthe():
    err = []
    assert len(LAB) == HAUT
    for y, r in enumerate(LAB):
        if len(r) != LARG:
            err.append('rangée %d : %d cases' % (y, len(r)))
    marche = lambda c: c in ' .o'
    maison = lambda x, y: y == RANG_TUNNEL and 11 <= x <= 15
    for y in range(HAUT - 1):
        for x in range(LARG - 1):
            q = [LAB[y][x], LAB[y][x + 1], LAB[y + 1][x], LAB[y + 1][x + 1]]
            if all(marche(c) for c in q) and not maison(x, y + 1):
                err.append('bloc 2x2 ouvert en (%d,%d)' % (x, y))
    for y in range(HAUT):
        for x in range(LARG):
            if not marche(LAB[y][x]) or maison(x, y):
                continue
            n = 0
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                xx, yy = x + dx, y + dy
                if y == RANG_TUNNEL:
                    xx %= LARG
                if 0 <= xx < LARG and 0 <= yy < HAUT and marche(LAB[yy][xx]):
                    n += 1
            if n < 2:
                err.append('cul-de-sac en (%d,%d)' % (x, y))
    for (x, y, c) in ((13, 15, ' '), (13, 7, ' '), (13, 8, '-'), (13, 11, ' ')):
        if LAB[y][x] != c:
            err.append('case fixe (%d,%d) : %r au lieu de %r' % (x, y, LAB[y][x], c))
    for x in (11, 12, 13, 14, 15):
        if LAB[RANG_TUNNEL][x] != ' ':
            err.append('maison (%d,9) pas vide' % x)
    if err:
        sys.exit('labyrinthe : ' + '; '.join(err))


# --- Bitmaps 16 x 16 : liste de 16 entiers de 16 bits (bit 15 = gauche) ---
def vide():
    return [[0] * 16 for _ in range(16)]


def moities(img):
    """img[y][x] 16x16 -> (glyphe gauche, glyphe droit), 16 octets chacun."""
    g = bytes(sum((img[y][x] & 1) << (7 - x) for x in range(8)) for y in range(16))
    d = bytes(sum((img[y][x + 8] & 1) << (7 - x) for x in range(8)) for y in range(16))
    return g, d


def disque(img, cx, cy, r):
    for y in range(16):
        for x in range(16):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                img[y][x] = 1


DIRS = 'HGBD'                   # haut, gauche, bas, droite (codes 0..3)
ANGLE = {'D': 0, 'H': 90, 'G': 180, 'B': 270}


def glouton(direction, ouverture):
    """ouverture = demi-angle de la bouche en degrés (0 : fermé)."""
    img = vide()
    a0 = ANGLE[direction]
    for y in range(16):
        for x in range(16):
            dx, dy = x - 7.5, 7.5 - y
            if dx * dx + dy * dy > 7.0 ** 2:
                continue
            if ouverture:
                ang = math.degrees(math.atan2(dy, dx))
                diff = abs((ang - a0 + 180) % 360 - 180)
                if diff < ouverture:
                    continue
            img[y][x] = 1
    return img


def mort(etape):
    """Bouche vers le haut qui s'ouvre jusqu'à disparaître ; puis étincelle."""
    if etape < 5:
        return glouton('H', (60, 90, 120, 150, 172)[etape])
    img = vide()
    for k in range(8):                       # 8 rayons courts
        a = math.radians(k * 45)
        for r in (4, 5, 6):
            x = round(7.5 + r * math.cos(a))
            y = round(7.5 - r * math.sin(a))
            img[y][x] = 1
    return img


def corps_fantome(jupe):
    img = vide()
    for y in range(16):
        for x in range(16):
            dx = x - 7.5
            if y <= 7:
                if dx * dx + (y - 7.5) ** 2 <= 7.0 ** 2:
                    img[y][x] = 1
            elif y <= 12:
                if 1 <= x <= 14:
                    img[y][x] = 1
    # jupe : pieds sur les rangées 13-14
    pieds = ((1, 2), (5, 6), (9, 10), (13, 14)) if jupe == 0 else \
            ((1, 1), (3, 4), (7, 8), (11, 12), (14, 14))
    for a, b in pieds:
        for x in range(a, b + 1):
            img[13][x] = 1
            if jupe == 0 or x not in (1, 14):
                img[14][x] = 1
    return img


DECAL_PUPILLE = {'H': (1, 0), 'G': (0, 2), 'B': (1, 3), 'D': (2, 2)}


def fantome(direction, jupe):
    """Yeux en creux (3 x 4), décalés vers la direction : en une seule
    couleur, une pupille pleine dans une orbite creuse se lit mal."""
    img = corps_fantome(jupe)
    dxo = {'G': -1, 'D': 1}.get(direction, 0)
    dyo = {'H': -2, 'B': 1}.get(direction, 0)
    for ox in (4, 9):
        for y in range(5 + dyo, 9 + dyo):
            for x in range(ox + dxo, ox + dxo + 3):
                img[y][x] = 0
    return img


def peur(jupe):
    img = corps_fantome(jupe)
    for ox in (4, 10):                        # petits yeux en creux
        for y in (5, 6):
            for x in (ox, ox + 1):
                img[y][x] = 0
    for x in range(2, 14):                    # bouche en zigzag
        img[10 if (x // 2) % 2 == 0 else 9][x] = 0
    return img


def yeux(direction):
    img = vide()
    px, py = DECAL_PUPILLE[direction]
    dxo = {'G': -1, 'D': 1}.get(direction, 0)
    dyo = {'H': -1, 'B': 1}.get(direction, 0)
    for ox in (3, 9):
        ox += dxo
        oy = 4 + dyo
        for y in range(oy, oy + 5):
            for x in range(ox, ox + 4):
                img[y][x] = 1
        for y in range(oy + py, oy + py + 2):
            for x in range(ox + px, ox + px + 2):
                img[y][x] = 0
    return img


def depuis_texte(lignes):
    img = vide()
    for y, l in enumerate(lignes):
        for x, c in enumerate(l):
            if c == '#':
                img[y][x] = 1
    return img


FRUITS = {
    'cerise': [
        "................",
        "...........##...",
        ".........##.#...",
        "........#...#...",
        ".......#....#...",
        "......#.....#...",
        ".....#......#...",
        "...###.....#....",
        "..#####..####...",
        ".######.######..",
        ".######.######..",
        ".######.######..",
        "..####..######..",
        "...##....####...",
        "................",
        "................"],
    'fraise': [
        "................",
        ".....#.##.#.....",
        "......####......",
        "....########....",
        "...##.####.##...",
        "..############..",
        "..#.####.####...",
        "..############..",
        "...###.####.#...",
        "...##########...",
        "....##.####.....",
        ".....#######....",
        "......####......",
        ".......##.......",
        "................",
        "................"],
    'orange': [
        "................",
        ".......#..###...",
        ".......####.....",
        ".....######.....",
        "...##########...",
        "..############..",
        "..############..",
        ".##############.",
        ".##############.",
        ".##############.",
        "..############..",
        "..############..",
        "...##########...",
        ".....######.....",
        "................",
        "................"],
    'pomme': [
        "................",
        "........#.......",
        ".......#..###...",
        "...####.#####...",
        "..############..",
        ".##############.",
        ".##############.",
        ".##############.",
        ".##############.",
        ".##############.",
        "..############..",
        "..############..",
        "...####..####...",
        "................",
        "................",
        "................"],
    'melon': [
        "................",
        "........#.......",
        ".......##.......",
        ".....######.....",
        "....#.#..#.#....",
        "...##.##.##.#...",
        "..###.##.##.##..",
        "..###.##.##.##..",
        "..###.##.##.##..",
        "..###.##.##.##..",
        "...##.##.##.#...",
        "....#.#..#.#....",
        ".....######.....",
        "................",
        "................",
        "................"],
}
ORDRE_FRUITS = ['cerise', 'fraise', 'orange', 'pomme', 'melon']

# Petits chiffres 3 x 5 pour les points gagnés
PETITS = {
    '0': ["###", "#.#", "#.#", "#.#", "###"],
    '1': [".#.", "##.", ".#.", ".#.", "###"],
    '2': ["###", "..#", "###", "#..", "###"],
    '3': ["###", "..#", ".##", "..#", "###"],
    '4': ["#.#", "#.#", "###", "..#", "..#"],
    '5': ["###", "#..", "###", "..#", "###"],
    '6': ["###", "#..", "###", "#.#", "###"],
    '7': ["###", "..#", ".#.", ".#.", ".#."],
    '8': ["###", "#.#", "###", "#.#", "###"],
}
POINTS = [200, 400, 800, 1600, 100, 300, 500, 700, 1000]


def nombre(n):
    s = str(n)
    img = vide()
    larg = 4 * len(s) - 1
    x0 = (16 - larg) // 2
    for i, c in enumerate(s):
        for y, l in enumerate(PETITS[c]):
            for x, p in enumerate(l):
                if p == '#':
                    img[5 + y][x0 + 4 * i + x] = 1
    return img


def point():
    img = vide()
    for y in (7, 8):
        for x in (7, 8):
            img[y][x] = 1
    return img


def pastille():
    img = vide()
    disque(img, 7.5, 7.5, 4.6)
    return img


def porte():
    img = vide()
    for x in range(16):
        img[6][x] = img[7][x] = 1
    return img


# --- Murs : contour de l'union des cases de mur, en retrait de 4 pixels ---
RETRAIT = 4


def murs():
    """Renvoie {(x, y): (gauche, droite)} : bitmaps 8x16 des cases de mur."""
    W, H = (LARG + 2) * 16, (HAUT + 2) * 16

    def est_mur(tx, ty):            # coordonnées de case, bordure comprise
        if 0 <= tx < LARG and 0 <= ty < HAUT:
            return TYPES[LAB[ty][tx]] == T_MUR
        if 0 <= ty < HAUT and ty in TUNNEL_BORDS:
            bord = 0 if tx < 0 else LARG - 1
            return TYPES[LAB[ty][bord]] == T_MUR
        return False

    u = [[est_mur(x // 16 - 1, y // 16 - 1) for x in range(W)] for y in range(H)]
    # érosion (distance de Tchebychev RETRAIT) : séparable
    lig = [[all(u[y][max(0, x - RETRAIT):x + RETRAIT + 1]) for x in range(W)]
           for y in range(H)]
    corps = [[all(lig[yy][x] for yy in range(max(0, y - RETRAIT), min(H, y + RETRAIT + 1)))
              for x in range(W)] for y in range(H)]

    def c(x, y):
        return 0 <= x < W and 0 <= y < H and corps[y][x]

    trait = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if not corps[y][x]:
                continue
            g, d, h, b = c(x - 1, y), c(x + 1, y), c(x, y - 1), c(x, y + 1)
            if g and d and h and b:
                continue
            # coin saillant (deux voisins orthogonaux absents) : arrondi
            if (not g or not d) and (not h or not b):
                continue
            trait[y][x] = 1
    res = {}
    for ty in range(HAUT):
        for tx in range(LARG):
            if TYPES[LAB[ty][tx]] != T_MUR:
                continue
            ox, oy = (tx + 1) * 16, (ty + 1) * 16
            img = [[trait[oy + y][ox + x] for x in range(16)] for y in range(16)]
            res[(tx, ty)] = moities(img)
    return res


# -------------------------------------------------------------------
def construit():
    verifie_labyrinthe()
    glyphes = []                  # (nom, octets) dans l'ordre d'attribution
    noms = {}

    def ajoute(nom, octets):
        noms[nom] = len(glyphes)
        glyphes.append((nom, octets))

    def ajoute_sprite(nom, img):
        g, d = moities(img)
        ajoute(nom, g)
        glyphes.append((nom + '+1', d))

    # Murs : cellules distinctes (la cellule vide devient le blanc $00)
    mur = murs()
    blanc = bytes(16)
    uniques = {}
    for k in sorted(mur, key=lambda t: (t[1], t[0])):
        for octets in mur[k]:
            if octets != blanc and octets not in uniques:
                uniques[octets] = len(glyphes)
                glyphes.append(('mur%d' % len(uniques), octets))
    ajoute('CHR_PORTE', moities(porte())[0])
    ajoute_sprite('CHR_POINT', point())
    ajoute_sprite('CHR_PASTILLE', pastille())
    ajoute_sprite('CHR_PAC_FERME', glouton('D', 0))
    for d in DIRS:                # CHR_PAC + dir*4 + (ouverture-1)*2
        for i, ouv in enumerate((28, 50)):
            ajoute_sprite('CHR_PAC' if (d, i) == ('H', 0) else 'pac%s%d' % (d, i),
                          glouton(d, ouv))
    for e in range(6):
        ajoute_sprite('CHR_MORT' if e == 0 else 'mort%d' % e, mort(e))
    for d in DIRS:                # CHR_FANT + dir*4 + jupe*2
        for j in (0, 1):
            ajoute_sprite('CHR_FANT' if (d, j) == ('H', 0) else 'fant%s%d' % (d, j),
                          fantome(d, j))
    for j in (0, 1):
        ajoute_sprite('CHR_PEUR' if j == 0 else 'peur1', peur(j))
    for d in DIRS:
        ajoute_sprite('CHR_YEUX' if d == 'H' else 'yeux%s' % d, yeux(d))
    for i, f in enumerate(ORDRE_FRUITS):
        ajoute_sprite('CHR_FRUIT' if i == 0 else 'fruit_' + f,
                      depuis_texte(FRUITS[f]))
    paires_points = []
    for n in POINTS:
        g, d = moities(nombre(n))
        paire = []
        for octets in (g, d):
            for i, (nom, o) in enumerate(glyphes):
                if o == octets and nom.startswith('pts'):
                    paire.append(i)
                    break
            else:
                paire.append(len(glyphes))
                glyphes.append(('pts%d' % len(glyphes), octets))
        paires_points.append(paire)

    if len(glyphes) > len(PLAGE):
        sys.exit('trop de glyphes : %d pour %d places' % (len(glyphes), len(PLAGE)))
    code = lambda i: PLAGE[i]
    murs_codes = {o: code(i) for o, i in uniques.items()}
    return glyphes, noms, mur, murs_codes, paires_points, code


def ecrit(glyphes, noms, mur, murs_codes, paires_points, code):
    police = bytearray(open(POLICE, 'rb').read())
    avant = bytes(police)
    for i, c in enumerate(PLAGE):
        octets = glyphes[i][1] if i < len(glyphes) else bytes(16)
        police[4096 + c * 16:4096 + c * 16 + 16] = octets
    if bytes(police) != avant:
        open(POLICE, 'wb').write(police)
        print('police : %d glyphes écrits' % len(glyphes))
    else:
        print('police : inchangée')

    L = []
    L.append('; ' + '=' * 67)
    L.append('; GLOUT_DATA.INC - GÉNÉRÉ par video/glyphes_glouton.py : NE PAS ÉDITER')
    L.append('; ' + '=' * 67)
    L.append('; Codes de la page 1 (attribut bit 7 = 1), labyrinthe et glyphes des')
    L.append('; murs. Modifier le script puis le relancer.')
    L.append('; Émet des octets : à inclure APRÈS le point d\'entrée.')
    L.append('; ' + '=' * 67)
    L.append('PM_W            equ %d' % LARG)
    L.append('PM_H            equ %d' % HAUT)
    L.append('PM_TUNNEL       equ %d' % RANG_TUNNEL)
    for t, v in (('T_VIDE', T_VIDE), ('T_POINT', T_POINT), ('T_PASTILLE', T_PASTILLE),
                 ('T_MUR', T_MUR), ('T_PORTE', T_PORTE)):
        L.append('%-15s equ %d' % (t, v))
    for nom in sorted(noms, key=lambda n: noms[n]):
        if nom.startswith('CHR_'):
            L.append('%-15s equ $%02X' % (nom, code(noms[nom])))
    L.append('NB_POINTS_LAB   equ %d' % sum(r.count('.') + r.count('o') for r in LAB))
    L.append('')
    L.append('; Points gagnés : paires (gauche, droite) pour %s' %
             ','.join(str(n) for n in POINTS))
    L.append('PtsGly:')
    for n, (g, d) in zip(POINTS, paires_points):
        L.append('    FCB     $%02X,$%02X          ; %d' % (code(g), code(d), n))
    L.append('')
    L.append('; Type de chaque case, rangée par rangée (PM_W x PM_H)')
    L.append('LabInit:')
    for y, r in enumerate(LAB):
        L.append('    FCB     ' + ','.join(str(TYPES[c]) for c in r) + '   ; ' + r)
    L.append('')
    L.append('; Glyphes des murs : gauche, droite (0 = blanc ou pas un mur)')
    L.append('LabMurs:')
    for y in range(HAUT):
        v = []
        for x in range(LARG):
            if (x, y) in mur:
                v += [murs_codes.get(o, 0) for o in mur[(x, y)]]
            else:
                v += [0, 0]
        L.append('    FCB     ' + ','.join('$%02X' % b for b in v))
    texte = '\n'.join(L) + '\n'
    if not os.path.exists(INC) or open(INC).read() != texte:
        open(INC, 'w').write(texte)
        print('%s : écrit' % os.path.relpath(INC, RACINE))
    else:
        print('%s : inchangé' % os.path.relpath(INC, RACINE))
    print('glyphes : %d (murs %d) sur %d réservés' %
          (len(glyphes), len(murs_codes), len(PLAGE)))


def apercu(chemin, glyphes, noms, mur, murs_codes, code):
    from PIL import Image
    pal = [(0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170), (170, 0, 0),
           (170, 0, 170), (170, 85, 0), (170, 170, 170)]
    pal += [(85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
            (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255)]
    par_code = {code(i): o for i, (n, o) in enumerate(glyphes)}
    im = Image.new('RGB', (LARG * 16, HAUT * 16 + 3 * 16 + 16))

    def cell(cx, cy, c, fg):
        o = par_code.get(c, bytes(16))
        for y in range(16):
            for x in range(8):
                if o[y] & (0x80 >> x):
                    im.putpixel((cx * 8 + x, cy * 16 + y), pal[fg])

    def sprite(tx, ty, c, fg):
        cell(tx * 2, ty, c, fg)
        cell(tx * 2 + 1, ty, c + 1, fg)

    for y, r in enumerate(LAB):
        for x, ch in enumerate(r):
            if (x, y) in mur:
                g, d = mur[(x, y)]
                cell(x * 2, y, murs_codes.get(g, 0), 9)
                cell(x * 2 + 1, y, murs_codes.get(d, 0), 9)
            elif ch == '.':
                sprite(x, y, code(noms['CHR_POINT']), 15)
            elif ch == 'o':
                sprite(x, y, code(noms['CHR_PASTILLE']), 15)
            elif ch == '-':
                cell(x * 2, y, code(noms['CHR_PORTE']), 13)
                cell(x * 2 + 1, y, code(noms['CHR_PORTE']), 13)
    pac = code(noms['CHR_PAC'])
    sprite(13, 15, pac + 1 * 4 + 2, 14)                      # gauche, grande
    f = code(noms['CHR_FANT'])
    sprite(13, 7, f + 1 * 4, 12)
    sprite(11, 9, f + 0 * 4, 11)
    sprite(13, 9, f + 2 * 4 + 2, 13)
    sprite(15, 9, f + 0 * 4 + 2, 6)
    sprite(13, 11, code(noms['CHR_FRUIT']), 12)
    # rangée du bas : catalogue des sprites
    y = HAUT + 1
    x = 0
    for n in ('CHR_PAC_FERME',):
        sprite(x, y, code(noms[n]), 14); x += 1
    for i in range(8):
        sprite(x, y, pac + i * 2, 14); x += 1
    for i in range(6):
        sprite(x, y, code(noms['CHR_MORT']) + i * 2, 14); x += 1
    for i in range(5):
        sprite(x, y, code(noms['CHR_FRUIT']) + i * 2, (12, 13, 6, 12, 10)[i]); x += 1
    x = 0
    y += 1
    for i in range(8):
        sprite(x, y, f + i * 2, (12, 13, 11, 6)[i // 2]); x += 1
    for i in range(2):
        sprite(x, y, code(noms['CHR_PEUR']) + i * 2, 9); x += 1
    for i in range(4):
        sprite(x, y, code(noms['CHR_YEUX']) + i * 2, 15); x += 1
    im = im.resize((im.width * 2, im.height * 2), Image.NEAREST)
    im.save(chemin)
    print('aperçu :', chemin)


if __name__ == '__main__':
    r = construit()
    ecrit(*r)
    if '--apercu' in sys.argv:
        glyphes, noms, mur, murs_codes, paires, code = r
        apercu(sys.argv[sys.argv.index('--apercu') + 1], glyphes, noms, mur, murs_codes, code)
