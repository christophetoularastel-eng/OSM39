#!/usr/bin/env python3
# ===================================================================
# ecran.py - La VRAM d'OSM39 en image, pour le manuel
# ===================================================================
# image(caracteres, couleurs) dessine l'écran 80 x 30 tel que la carte
# vidéo l'affiche : police 8 x 16 de l'EPROM des caractères
# (video/font_osm39.bin, page choisie par le bit 7 de l'attribut),
# premier plan D0 bleu, D1 vert, D2 rouge, D3 atténué ; fond D4-D6
# (même ordre). Les captures du manuel viennent du VRAI logiciel lancé
# dans l'émulateur des vérificateurs (captures.py), jamais d'une maquette.
# ===================================================================
import os

from PIL import Image

RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
POLICE = open(os.path.join(RACINE, 'video', 'font_osm39.bin'), 'rb').read()
COLONNES, RANGEES = 80, 30
PLEIN, ATTENUE = 235, 165       # 0,69 V et ~0,48 V sur 75 ohms (AGENTS.md, Video)


def couleur(bits, attenue=False):
    v = ATTENUE if attenue else PLEIN
    return ((v if bits & 4 else 0), (v if bits & 2 else 0), (v if bits & 1 else 0))


def image(car, col, rangees=RANGEES, echelle=2):
    """car, col : octets de la VRAM ($8000 et $9000), 80 par rangée."""
    im = Image.new('RGB', (COLONNES * 8, rangees * 16))
    px = im.load()
    for r in range(rangees):
        for c in range(COLONNES):
            i = r * COLONNES + c
            a = col[i]
            pp = couleur(a & 7, bool(a & 8))
            fond = couleur((a >> 4) & 7)
            g = POLICE[(a >> 7) * 4096 + car[i] * 16:][:16]
            for y in range(16):
                b = g[y]
                for x in range(8):
                    px[c * 8 + x, r * 16 + y] = pp if b >> (7 - x) & 1 else fond
    if echelle != 1:
        im = im.resize((im.width * echelle, im.height * echelle), Image.NEAREST)
    return im
