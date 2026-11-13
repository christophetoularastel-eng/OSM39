#!/usr/bin/env python3
# ===================================================================
# carte.py - La disposition de la VRAM pour les vérificateurs
# ===================================================================
# Lue dans bios/hardware.inc (généré d'après le fichier CARTE) :
#   v4   : case c = caractère en $8000+c, couleur en $9000+c ;
#   mono : case c = caractère en $8000+2c, couleur en $8001+2c.
# Les vérificateurs lisent et posent l'écran par ces fonctions, jamais par
# des adresses écrites en dur : le même essai vaut pour les deux cartes.
# ===================================================================
import os
import re

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _hw():
    v = {}
    for ligne in open(os.path.join(RACINE, 'bios', 'hardware.inc'), encoding='utf-8'):
        m = re.match(r'\s*(\w+):?\s+equ\s+(\$[0-9A-Fa-f]+|\d+)', ligne)
        if m:
            t = m.group(2)
            v[m.group(1)] = int(t[1:], 16) if t.startswith('$') else int(t)
    return v


_V = _hw()
MONO = bool(_V['CARTE_MONO'])
NOM = 'mono' if MONO else 'v4'
BASE = _V['VRAM_BASE']
PAS = _V['VRAM_PAS']                    # octets par case pour le CPU
COUL = _V['VRAM_COL_OFS']               # couleur = caractère + COUL
LIGNE = _V['VRAM_LIGNE']                # octets par rangée de 80 cases
CASES = 4096                            # cases d'une page vidéo


def adr(c):
    """Adresse CPU du caractère de la case c (0..4095)."""
    return BASE + (c % CASES) * PAS


def adr_coul(c):
    return adr(c) + COUL


def case(a):
    """Case d'une adresse CPU de caractère ou de couleur."""
    o = a - BASE
    return (o // PAS) if MONO else (o % 0x1000)


def est_couleur(a):
    o = a - BASE
    return bool(o & 1) if MONO else o >= 0x1000


def lit(mem, debut, n):
    """(caractères, couleurs) des cases debut..debut+n-1."""
    car = bytes(mem[adr(debut + i)] for i in range(n))
    col = bytes(mem[adr_coul(debut + i)] for i in range(n))
    return car, col


def pose(mem, debut, car, col):
    for i, (a, b) in enumerate(zip(car, col)):
        mem[adr(debut + i)] = a
        mem[adr_coul(debut + i)] = b
