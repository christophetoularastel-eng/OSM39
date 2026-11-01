#!/usr/bin/env python3
# ===================================================================
# police.py - Les deux pages de la police d'OSM39 en tableaux, pour le manuel
# ===================================================================
# Lit video/font_osm39.bin (2 pages x 256 caractères de 8 x 16) et dessine
# chaque page en grille 16 x 16 : la rangée donne le chiffre fort du
# code, la colonne le chiffre faible. Les repères sont écrits avec la
# police elle-même (page 0). Images : docs/manuel/images/police0.png et
# police1.png. Appelé par fabrique.py.
# ===================================================================
import os

from PIL import Image

from ecran import POLICE, RACINE

SORTIE = os.path.join(RACINE, 'docs', 'manuel', 'images')
ECH = 2                         # 8 x 16 -> 16 x 32
PAS_X, PAS_Y = 8 * ECH + 8, 16 * ECH + 6
MARGE_X, MARGE_Y = 40, 40
ENCRE, PAPIER, REPERE, GRILLE = (35, 38, 44), (250, 246, 236), (150, 120, 60), (222, 214, 196)


def glyphe(px, page, code, x0, y0, couleur, ech=ECH):
    g = POLICE[page * 4096 + code * 16:][:16]
    for y in range(16):
        for x in range(8):
            if g[y] >> (7 - x) & 1:
                for dy in range(ech):
                    for dx in range(ech):
                        px[x0 + x * ech + dx, y0 + y * ech + dy] = couleur


def texte(px, t, x0, y0, couleur):
    for k, ch in enumerate(t):
        glyphe(px, 0, ord(ch), x0 + k * 8 * 1, y0, couleur, 1)


def page(n):
    im = Image.new('RGB', (MARGE_X + 16 * PAS_X, MARGE_Y + 16 * PAS_Y), PAPIER)
    px = im.load()
    for k in range(16):
        texte(px, '%X' % k, MARGE_X + k * PAS_X + PAS_X // 2 - 4, 12, REPERE)
        texte(px, '%X_' % k, 12, MARGE_Y + k * PAS_Y + PAS_Y // 2 - 8, REPERE)
    for r in range(17):
        for x in range(MARGE_X - 2, MARGE_X + 16 * PAS_X):
            px[x, MARGE_Y - 2 + r * PAS_Y - (1 if r == 16 else 0)] = GRILLE
    for c in range(17):
        for y in range(MARGE_Y - 2, MARGE_Y + 16 * PAS_Y):
            px[MARGE_X - 2 + c * PAS_X - (1 if c == 16 else 0), y] = GRILLE
    for code in range(256):
        glyphe(px, n, code, MARGE_X + (code % 16) * PAS_X + 2, MARGE_Y + (code // 16) * PAS_Y + 1, ENCRE)
    return im


def main():
    os.makedirs(SORTIE, exist_ok=True)
    for n in (0, 1):
        page(n).save(os.path.join(SORTIE, 'police%d.png' % n))


if __name__ == '__main__':
    main()
