#!/usr/bin/env python3
# ===================================================================
# donjon39.py - Source unique de DONJON39 (apps/donjon39.asm) : tables, carte
# et modèle EXACT, en entiers, du rendu du 6309.
# ===================================================================
#   python3 tools/donjon39/donjon39.py --inc     # -> apps/donjon_data.inc
#   python3 tools/donjon39/donjon39.py --txt     # -> apps/DONJON39.TXT (la carte)
#   python3 tools/donjon39/donjon39.py --vue X Y A   # la vue en texte (essai)
#
# Carte : octet 0 vide, 1-7 mur de cette couleur, 8 porte (fermée ; ouverte
# = 0 le temps qu'elle reste ouverte). Fichier texte DONJON39.TXT (lu au
# lancement, sinon la carte intégrée) : voir texte_carte().
#
# Rendu (« lancer de rayons » à la Wolfenstein 3D) : un rayon par colonne
# de la vue (VUE_L = 64 cellules), algorithme DDA case par case dans la
# carte (CARTE_L x CARTE_L, octet 0 = vide, 1-7 = mur de cette couleur).
# Chaque cellule de la vue vaut 2 x 3 points (mosaïques de la page 1 de
# la police, celles du MINITEL) : la hauteur d'un mur est en tiers de
# rangée (SOUS = 3 x VUE_H = 54 sous-rangées).
#
# Nombres : position en 8.8 (unités de carte), angle 0-1023 (un tour),
# angle 0 = +x, 256 = +y. Pas de division : tables.
#   Delta[a]   = min(127,99 ; 1/|cos a|) en 8.8 (distance le long du rayon
#                pour franchir une case en x ; en y : Delta[(a-256)&1023])
#   ColOff[c]  = écart d'angle de la colonne c (projection plane, champ
#                de 60 degrés)
#   ColCos[c]  = cos(ColOff[c]) x 256 (correction de l'« œil de poisson »)
#   HTab[i]    = hauteur en sous-rangées d'un mur à la distance i/32
#   Sin[a]     = sin a x 256 (1024 + 256 : cos a = Sin[a+256])
# ===================================================================
import math
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))

VUE_L, VUE_H = 64, 18           # vue en cellules ; + 2 rangées d'état
SOUS = 3 * VUE_H                # 54 sous-rangées
CHAMP = 60.0                    # degrés
FOCALE = 83                     # sous-rangées d'un mur de 1 à la distance 1
CARTE_L = 16
DELTA_MAX = 32767               # 127,99 en 8.8 (MULD est signé)
PAS_MAX = 40                    # cases traversées au plus par un rayon

# Mosaïques : valeur 0-63 (bit 2 x sous-rangée + colonne) -> glyphe page 1
TAB_MOS = [0x00, 0x5E, 0x5F, 0x50, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x51, 0x68, 0x69, 0x52,
           0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
           0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x4F, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
           0x53, 0x10, 0x11, 0x54, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x55, 0x1A, 0x1B, 0x56]

# Couleurs OSM39 (D0 bleu, D1 vert, D2 rouge) ; D3 = 1 : atténué, comme
# le reste du système. Mur de valeur v : premier plan MUR_FG[v].
MUR_FG = [0x08, 0x0C, 0x0A, 0x09, 0x0E, 0x0B, 0x0D, 0x0F, 0x0E]   # 8 : porte, jaune
SOL_FG = 0x0C                   # sol : points rouges atténués (brique)
VIDE_ATTR = 0x88                # page 1, premier plan $8 (pas de traits roses), fond noir

# Motifs par sous-rangée k (0-2) d'une cellule : mur plein, mur ombré (faces
# nord/sud : damier), sol (points de plus en plus serrés vers le bas)
MASQUE_PLEIN = [3 << (2 * k) for k in range(3)]
MASQUE_OMBRE = [(1 if k != 1 else 2) << (2 * k) for k in range(3)]
MASQUE_PORTE = [1 << (2 * k) for k in range(3)]         # porte : planches verticales
PORTE = 8

# Mini-carte (Tab) : en haut à droite de la vue, une cellule = 2 x 3 cases
MINI_COL = VUE_L - 8
MINI_H = 6
MINI_ATTR = 0x8F                # murs : blanc atténué
MINI_JOUEUR = 0x8C              # la cellule du joueur : rouge atténué

CARTE = [
    "1111111111111111",
    "1000000000000001",
    "1002220000333001",
    "1002000000003001",
    "1002000400003001",
    "1000000400000001",
    "1000000000000001",
    "1555000000006661",
    "1000000000000001",
    "1000077777000001",
    "1000070007000001",
    "1000080007000001",
    "1003000000000401",
    "1003000000000401",
    "1000000000000001",
    "1111111111111111",
]
DEPART = (int(1.5 * 256), int(1.5 * 256), 0)


def sol_masque(j):
    """Sous-rangée j (0..SOUS-1) sous l'horizon : points du sol."""
    p = j - SOUS // 2
    if p < 0:
        return 0
    if p < 6:
        return 1 if p % 3 == 2 else 0           # loin : rares
    if p < 14:
        return 1 if p % 2 else 2                # moyen
    return 3 if p % 2 else 0                    # près : lignes


def tables():
    t = {}
    t['Sin'] = [round(math.sin(a * 2 * math.pi / 1024) * 256) for a in range(1024 + 256)]
    d = []
    for a in range(1024):
        c = abs(math.cos(a * 2 * math.pi / 1024))
        d.append(DELTA_MAX if c < 1e-9 else min(DELTA_MAX, round(256 / c)))
    t['Delta'] = d
    demi = math.tan(math.radians(CHAMP / 2))
    off, cos_ = [], []
    for c in range(VUE_L):
        x = ((c + 0.5) / VUE_L * 2 - 1) * demi
        ang = math.atan(x)
        off.append(round(ang / (2 * math.pi) * 1024))
        cos_.append(round(math.cos(ang) * 256))
    t['ColOff'] = off
    t['ColCos'] = cos_
    h = [255]
    for i in range(1, 1024):
        h.append(min(255, round(FOCALE * 32 / i)))
    t['HTab'] = h
    t['Carte'] = [int(ch) for ligne in CARTE for ch in ligne]
    t['SolMasque'] = [sol_masque(j) for j in range(SOUS)]
    # rangée entièrement sous le mur : sa valeur de mosaïque, d'un coup
    t['SolVal'] = [sum(sol_masque(3 * rg + k) << (2 * k) for k in range(3)) for rg in range(VUE_H)]
    t['MurVal'] = [sum(MASQUE_PLEIN), sum(MASQUE_OMBRE), sum(MASQUE_PORTE)]
    # pour écrire une colonne par séries : divisions par 3 et cellules de sol
    t['Div3'] = [j // 3 for j in range(SOUS + 1)]
    t['Mod3'] = [j % 3 for j in range(SOUS + 1)]
    t['SolCel'] = [(TAB_MOS[v] << 8) | (0x80 | SOL_FG) if v else (TAB_MOS[0] << 8) | VIDE_ATTR
                   for v in t['SolVal']]
    return t


T = tables()


def u16(v):
    return v & 0xFFFF


def mul_milieu(a, b):
    """MULD (signés) puis les 16 bits du milieu : (a x b) >> 8."""
    sa = a - 0x10000 if a & 0x8000 else a
    sb = b - 0x10000 if b & 0x8000 else b
    return ((sa * sb) >> 8) & 0xFFFF


def texte_carte(txt):
    """Le fichier DONJON39.TXT -> (carte de 256 octets, (x, y, angle) de départ).
    Une ligne : ce qui est entre deux CR ou LF ; vides et « ; ... » sautées ;
    les 16 premières font les 16 rangées, 16 premiers caractères : '1'-'7'
    mur, 'P' porte, 'J' départ (case vide), le reste vide. Le tour de la
    carte devient mur '1' s'il est vide. Départ : le dernier 'J', angle 0 ;
    sans 'J', DEPART."""
    carte = [0] * 256
    dep = DEPART
    rg = 0
    for ligne in txt.replace(b'\r', b'\n').split(b'\n'):
        if rg >= CARTE_L:
            break
        if not ligne or ligne[:1] == b';':
            continue
        for c in range(min(CARTE_L, len(ligne))):
            ch = chr(ligne[c]).upper()
            if '1' <= ch <= '7':
                carte[rg * CARTE_L + c] = ord(ch) - ord('0')
            elif ch == 'P':
                carte[rg * CARTE_L + c] = PORTE
            elif ch == 'J':
                dep = (c * 256 + 128, rg * 256 + 128, 0)
        rg += 1
    for i in range(CARTE_L):
        for k in (i, 240 + i, 16 * i, 16 * i + 15):
            if carte[k] == 0:
                carte[k] = 1
    return carte, dep


def carte_texte(carte, dep):
    """La carte -> le texte de DONJON39.TXT (le contraire de texte_carte)."""
    L = ['; DONJON39 : la carte (16 x 16). 1-7 mur, P porte, J depart, . vide.',
         '; Le tour devient mur s\'il est vide. Lignes ; : commentaires.']
    for rg in range(CARTE_L):
        ligne = ''
        for c in range(CARTE_L):
            v = carte[rg * CARTE_L + c]
            if (c, rg) == (dep[0] >> 8, dep[1] >> 8):
                ligne += 'J'
            else:
                ligne += '.' if v == 0 else ('P' if v == PORTE else str(v))
        L.append(ligne)
    return ('\r\n'.join(L) + '\r\n').encode('ascii')


def rayon(px, py, ang, col, carte=None):
    """-> (hauteur en sous-rangées, valeur du mur, côté 0 = face est/ouest)"""
    carte = carte or T['Carte']
    r = (ang + T['ColOff'][col]) & 1023
    dx, dy = T['Delta'][r], T['Delta'][(r - 256) & 1023]
    sx = 1 if (r <= 256 or r >= 768) else -1
    sy = 1 if r <= 512 else -1
    cx, cy = px >> 8, py >> 8
    fx, fy = px & 255, py & 255
    side_x = mul_milieu((256 - fx) if sx > 0 else fx, dx)
    side_y = mul_milieu((256 - fy) if sy > 0 else fy, dy)
    cote, mur = 0, 0
    for _ in range(PAS_MAX):
        if side_x < side_y:
            side_x = min(0xFFFF, side_x + dx)
            cx += sx
            cote = 0
        else:
            side_y = min(0xFFFF, side_y + dy)
            cy += sy
            cote = 1
        mur = carte[(cy & 15) * CARTE_L + (cx & 15)]
        if mur:
            break
    dist = (side_x - dx) if cote == 0 else (side_y - dy)
    dist &= 0xFFFF
    perp = mul_milieu(dist, T['ColCos'][col])
    i = perp >> 3
    i = max(1, min(1023, i))
    return T['HTab'][i], mur, cote


def colonne(h, mur, cote):
    """-> [(glyphe, attribut)] x VUE_H, de haut en bas."""
    if h >= SOUS:
        haut, bas = 0, SOUS
    else:
        haut = (SOUS - h) >> 1
        bas = haut + h
    masques = MASQUE_PORTE if mur == PORTE else (MASQUE_OMBRE if cote else MASQUE_PLEIN)
    fg = MUR_FG[mur]
    cel = []
    for rg in range(VUE_H):
        vm = vs = 0
        for k in range(3):
            j = 3 * rg + k
            if haut <= j < bas:
                vm |= masques[k]
            elif j >= bas:
                vs |= T['SolMasque'][j] << (2 * k)
        if vm:
            cel.append((TAB_MOS[vm], 0x80 | fg))
        elif vs:
            cel.append((TAB_MOS[vs], 0x80 | SOL_FG))
        else:
            cel.append((TAB_MOS[0], VIDE_ATTR))
    return cel


def vue(px, py, ang, carte=None, mini=False):
    """-> (glyphes, attributs) : VUE_H rangées de VUE_L octets."""
    carte = carte or T['Carte']
    g = [bytearray(VUE_L) for _ in range(VUE_H)]
    a = [bytearray(VUE_L) for _ in range(VUE_H)]
    for c in range(VUE_L):
        for rg, (gl, at) in enumerate(colonne(*rayon(px, py, ang, c, carte))):
            g[rg][c], a[rg][c] = gl, at
    if mini:                        # la mini-carte par-dessus
        jx, jy = px >> 8, py >> 8
        for r in range(MINI_H):
            for c in range(8):
                v, at = 0, MINI_ATTR
                for k in range(3):
                    for b in range(2):
                        y, x = 3 * r + k, 2 * c + b
                        if y < CARTE_L and (carte[y * CARTE_L + x] or (x, y) == (jx, jy)):
                            v |= 1 << (2 * k + b)
                        if (x, y) == (jx, jy):
                            at = MINI_JOUEUR
                g[r][MINI_COL + c], a[r][MINI_COL + c] = TAB_MOS[v], at
    return g, a


def inc():
    L = ['; ===================================================================',
         '; donjon_data.inc - GÉNÉRÉ par tools/donjon39/donjon39.py --inc : ne pas',
         '; éditer. Tables et carte de DONJON39 (voir l\'en-tête de donjon39.py).',
         '; ===================================================================',
         'VUE_L           equ %d' % VUE_L,
         'VUE_H           equ %d' % VUE_H,
         'SOUS            equ %d' % SOUS,
         'CARTE_L         equ %d' % CARTE_L,
         'PAS_MAX         equ %d' % PAS_MAX,
         'SOL_FG          equ $%02X' % SOL_FG,
         'VIDE_ATTR       equ $%02X' % VIDE_ATTR,
         'DEPART_X        equ $%04X' % DEPART[0],
         'DEPART_Y        equ $%04X' % DEPART[1],
         'DEPART_A        equ %d' % DEPART[2],
         'PORTE           equ %d' % PORTE,
         'MINI_COL        equ %d' % MINI_COL,
         'MINI_H          equ %d' % MINI_H,
         'MINI_ATTR       equ $%02X' % MINI_ATTR,
         'MINI_JOUEUR     equ $%02X' % MINI_JOUEUR]

    def bloc(nom, val, mot):
        L.append(nom)
        pas = 8 if mot else 16
        for i in range(0, len(val), pas):
            if mot:
                L.append('        fdb ' + ','.join('$%04X' % (v & 0xFFFF) for v in val[i:i + pas]))
            else:
                L.append('        fcb ' + ','.join('$%02X' % (v & 0xFF) for v in val[i:i + pas]))
    bloc('Sin', T['Sin'], True)
    bloc('Delta', T['Delta'], True)
    bloc('ColOff', T['ColOff'], True)
    bloc('ColCos', T['ColCos'], True)
    bloc('HTab', T['HTab'], False)
    bloc('Carte', T['Carte'], False)
    bloc('SolMasque', T['SolMasque'], False)
    bloc('SolVal', T['SolVal'], False)
    bloc('MurVal', T['MurVal'], False)
    bloc('Div3', T['Div3'], False)
    bloc('Mod3', T['Mod3'], False)
    bloc('SolCel', T['SolCel'], True)
    bloc('TabMos', TAB_MOS, False)
    bloc('MurFg', MUR_FG, False)
    bloc('MasquePlein', MASQUE_PLEIN, False)
    bloc('MasqueOmbre', MASQUE_OMBRE, False)
    bloc('MasquePorte', MASQUE_PORTE, False)
    return '\n'.join(L) + '\n'


def texte(px, py, ang):
    inv = {g: i for i, g in enumerate(TAB_MOS)}
    g, _ = vue(px, py, ang)
    out = []
    for rg in range(VUE_H):
        lignes = [[' '] * (2 * VUE_L) for _ in range(3)]
        for c in range(VUE_L):
            v = inv.get(g[rg][c], 0)
            for b in range(6):
                if v >> b & 1:
                    lignes[b // 2][2 * c + (b & 1)] = '#'
        out += [''.join(x) for x in lignes]
    return '\n'.join(out)


if __name__ == '__main__':
    if '--txt' in sys.argv:
        with open(os.path.join(RACINE, 'apps', 'DONJON39.TXT'), 'wb') as f:
            f.write(carte_texte(T['Carte'], DEPART))
        print('apps/DONJON39.TXT écrit')
    elif '--inc' in sys.argv:
        with open(os.path.join(RACINE, 'apps', 'donjon_data.inc'), 'w') as f:
            f.write(inc())
        print('apps/donjon_data.inc écrit')
    elif '--vue' in sys.argv:
        i = sys.argv.index('--vue')
        x, y, a = (float(sys.argv[i + 1]), float(sys.argv[i + 2]), int(sys.argv[i + 3]))
        print(texte(int(x * 256), int(y * 256), a))
    else:
        print(__doc__ if __doc__ else 'donjon39.py --inc | --vue X Y A')
