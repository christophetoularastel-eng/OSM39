#!/usr/bin/env python3
# ===================================================================
# mire_tv.py - Une mire de télévision des années 80 pour le mode graphique
# ===================================================================
# Dessine la mire en 640 x 400 (points carrés : 400 lignes VGA) et écrit
# tools/tele/mire_tv_data.inc pour essai_mire.asm :
#   - PixRLE : les octets de points dans l'ordre où le module les écrit
#     (ligne r 0-15, rangée 0-24, colonne 0-79), en plages (n 1-255, octet),
#     terminées par n = 0 ;
#   - CoulRLE : la couleur de chaque case (2000, rangée par rangée), en
#     plages ; le module la met sur les 16 lignes de la case.
#   python3 tools/tele/mire_tv.py [--png apercu.png]
# Éléments : fond noir, grille blanche, grand cercle et croix, barres des 8
# couleurs vives puis atténuées, zones de netteté (rayures verticales de
# 1, 2 et 4 points, rayures horizontales de 1 et 2 lignes, damier d'un
# point), cercles dans les coins, le titre.
# ===================================================================
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ICI = os.path.dirname(os.path.abspath(__file__))
L, H = 640, 400


def dessine():
    im = Image.new('1', (L, H), 0)
    d = ImageDraw.Draw(im)
    coul = [[0x07] * 80 for _ in range(25)]          # blanc sur noir
    # grille : tous les 40 points en x, 40 lignes en y
    for x in range(0, L, 40):
        d.line([(x, 0), (x, H - 1)], fill=1)
    d.line([(L - 1, 0), (L - 1, H - 1)], fill=1)
    for y in range(0, H, 40):
        d.line([(0, y), (L - 1, y)], fill=1)
    d.line([(0, H - 1), (L - 1, H - 1)], fill=1)
    # barres de couleur : rangées 7-9 (vives), 10-11 (atténuées), x 160-480
    for R in range(7, 12):
        for c in range(20, 60):
            k = (c - 20) // 5
            coul[R][c] = k if R < 10 else k + 8
    d.rectangle([160, 112, 479, 191], fill=1)
    # zones de netteté : rangées 13-17, de gauche à droite
    zone = [(160, 'v1'), (200, 'v2'), (240, 'v4'), (280, 'h1'), (320, 'h2'), (360, 'dam'), (400, 'v1'), (440, 'h1')]
    for x0, kind in zone:
        for y in range(208, 288):
            for x in range(x0, x0 + 40):
                if kind == 'v1':
                    on = x & 1
                elif kind == 'v2':
                    on = (x >> 1) & 1
                elif kind == 'v4':
                    on = (x >> 2) & 1
                elif kind == 'h1':
                    on = y & 1
                elif kind == 'h2':
                    on = (y >> 1) & 1
                else:
                    on = (x ^ y) & 1
                im.putpixel((x, y), on)
    for R in range(13, 18):
        for c in range(20, 60):
            coul[R][c] = 0x07 if c < 50 else (0x02 if c < 55 else 0x04)   # les 2 dernières en vert, rouge
    # grand cercle, croix centrale
    for e in range(3):
        d.ellipse([320 - 190 + e, 200 - 190 + e, 320 + 190 - e, 200 + 190 - e], outline=1)
    d.line([(300, 200), (340, 200)], fill=1)
    d.line([(320, 180), (320, 220)], fill=1)
    # petits cercles dans les coins
    for cx, cy in ((40, 40), (600, 40), (40, 360), (600, 360)):
        d.ellipse([cx - 30, cy - 30, cx + 30, cy + 30], outline=1)
    # le titre, rangées 4-5
    d.rectangle([200, 64, 439, 95], fill=0)
    try:
        f = ImageFont.load_default(size=24)
    except TypeError:
        f = ImageFont.load_default()
    t = 'OSM39  MIRE'
    w = d.textlength(t, font=f)
    d.text((320 - w / 2, 66), t, font=f, fill=1)
    for c in range(25, 55):
        coul[4][c] = coul[5][c] = 0x06              # titre jaune
    return im, coul


def octets(im):
    """Les octets de points dans l'ordre du module."""
    px = im.load()
    out = []
    for r in range(16):
        for R in range(25):
            y = 16 * R + r
            for c in range(80):
                b = 0
                for k in range(8):
                    if px[8 * c + k, y]:
                        b |= 0x80 >> k
                out.append(b)
    return out


def rle(v):
    out = []
    i = 0
    while i < len(v):
        n = 1
        while i + n < len(v) and v[i + n] == v[i] and n < 255:
            n += 1
        out += [n, v[i]]
        i += n
    return out + [0, 0]


def main():
    im, coul = dessine()
    pix = rle(octets(im))
    cou = rle([coul[R][c] for R in range(25) for c in range(80)])
    L_ = ['; mire_tv_data.inc - GÉNÉRÉ par tools/tele/mire_tv.py : ne pas éditer']
    for nom, v in (('PixRLE', pix), ('CoulRLE', cou)):
        L_.append(nom)
        for i in range(0, len(v), 16):
            L_.append('        fcb ' + ','.join('$%02X' % o for o in v[i:i + 16]))
    open(os.path.join(ICI, 'mire_tv_data.inc'), 'w').write('\n'.join(L_) + '\n')
    print('points : %d octets compressés, couleurs : %d' % (len(pix), len(cou)))
    if '--png' in sys.argv:
        rgb = Image.new('RGB', (L, H))
        p, q = im.load(), rgb.load()
        for y in range(H):
            for x in range(L):
                a = coul[y // 16][x // 8]
                k = 120 if a & 8 else 220
                fg = ((a >> 2 & 1) * k, (a >> 1 & 1) * k, (a & 1) * k)
                q[x, y] = fg if p[x, y] else (0, 0, 0)
        rgb.save(sys.argv[sys.argv.index('--png') + 1])


if __name__ == '__main__':
    main()
