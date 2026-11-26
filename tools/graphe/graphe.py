#!/usr/bin/env python3
# ===================================================================
# graphe.py - Le modèle exact de la bibliothèque graphique (bios/graphe.asm)
# ===================================================================
# Le mode graphique de la carte OSM39_mono : 640 x 400 points, 1 bit par
# point (bit 7 = à gauche), une couleur par case de 8 x 16 (l'octet
# d'attribut du mode texte), que le BIOS écrit dans les 16 lignes de la
# case (la carte a une couleur par ligne de 8 points depuis le 26 nov.
# 2026). Le BIOS dessine dans une copie de l'image en RAM page 3 (ligne y
# à y x 80, 32 000 octets) ; l'IRQ du VSYNC la recopie à l'écran, au
# retour de trame, une ligne par trame.
#
# Ce fichier dit exactement quels points chaque fonction allume ; le
# vérificateur (test/verifie_graphe.py) compare la page 3 et la VRAM du
# vrai BIOS à ce modèle.
#
# Service sys_Graphe : B = fonction, X = bloc de paramètres (mots de 16
# bits signés, poids fort d'abord), A = mode ou couleur. C = 1 : fonction
# inconnue, ou mode graphique non ouvert (sauf GR_DEBUT).
#   0 GR_DEBUT   A = attribut de toutes les cases : passe en graphique,
#                image effacée (l'écran texte est perdu)
#   1 GR_FIN     retour au texte (écran texte effacé)
#   2 GR_POINT   X -> x, y ; A = mode
#   3 GR_LIGNE   X -> x0, y0, x1, y1 ; A = mode
#   4 GR_RECT    X -> x0, y0, x1, y1 (coins compris) : rectangle plein
#   5 GR_CERCLE  X -> xc, yc, r : le contour
#   6 GR_DISQUE  X -> xc, yc, r : plein
#   7 GR_LIT     X -> x, y : A = 0 ou 1 (0 hors de l'écran)
#   8 GR_EFFACE  A = attribut : tous les points éteints, toutes les cases
#   9 GR_CAR     X -> colonne (0-79), rangée (0-24), caractère : un
#                caractère de la police 8 x 8, chaque ligne doublée ;
#                A = mode (0 : posé tel quel, le fond éteint ; 2 : inversé)
#  10 GR_COULEUR X -> c0, r0, c1, r1 (cases, coins compris) ; A = attribut
#  11 GR_ATTEND  rend la main quand l'écran a rattrapé l'image
# Modes : 0 allumer (OU), 1 éteindre (ET NON), 2 inverser (OU EXCLUSIF).
# Coordonnées : -8192 à 8191 (au-delà, une ligne serait fausse) ; les
# points hors de l'écran sont ignorés, un par un.
#
# La police 8 x 8 est un fichier de la carte, /BIN/POLICE8 (768 octets),
# chargé par GR_DEBUT en page 3, $7D00 (absent : les caractères sont vides).
#   python3 tools/graphe/graphe.py --police         (aperçu)
#   python3 tools/graphe/graphe.py --fichier F      (écrit le fichier POLICE8)
# ===================================================================
import os
import sys

LARG, HAUT = 640, 400
OCTETS_LIGNE = LARG // 8
COLS, RANGS = 80, 25
GR_DEBUT, GR_FIN, GR_POINT, GR_LIGNE, GR_RECT, GR_CERCLE, GR_DISQUE, GR_LIT, \
    GR_EFFACE, GR_CAR, GR_COULEUR, GR_ATTEND = range(12)
OU, ETNON, OUX = 0, 1, 2
POLICE_PREMIER, POLICE_N = 0x20, 96          # $20-$7F, 8 octets chacun
POLICE_ADR = HAUT * OCTETS_LIGNE             # $7D00 dans la page 3

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
FONTE = os.path.join(RACINE, 'video', 'font_osm39.bin')


def police():
    """96 caractères 8 x 8 tirés de la police de la machine (8 x 16, page 0) :
    ligne k du 8 x 8 = OU des lignes 2k et 2k+1 du dessin (les traits fins
    d'une ligne sur deux restent)."""
    f = open(FONTE, 'rb').read()
    out = bytearray()
    for c in range(POLICE_PREMIER, POLICE_PREMIER + POLICE_N):
        g = f[c * 16:c * 16 + 16]           # A0-A3 ligne, A4-A11 code, A12 page
        for k in range(8):
            out.append(g[2 * k] | g[2 * k + 1])
    return bytes(out)


class Ecran:
    """L'image (page 3) et les couleurs des cases, après chaque fonction."""

    def __init__(self):
        self.img = bytearray(HAUT * OCTETS_LIGNE)
        self.coul = bytearray(COLS * RANGS)
        self.ouvert = False
        self.pol = police()             # None : pas de POLICE8 sur la carte

    # --- les points ---
    def point(self, x, y, mode):
        if not (0 <= x < LARG and 0 <= y < HAUT):
            return
        i = y * OCTETS_LIGNE + (x >> 3)
        m = 0x80 >> (x & 7)
        if mode == OU:
            self.img[i] |= m
        elif mode == ETNON:
            self.img[i] &= ~m & 255
        else:
            self.img[i] ^= m

    def lit(self, x, y):
        if not (0 <= x < LARG and 0 <= y < HAUT):
            return 0
        return (self.img[y * OCTETS_LIGNE + (x >> 3)] >> (7 - (x & 7))) & 1

    def ligne(self, x0, y0, x1, y1, mode):
        """Bresenham, chaque point une fois (le mode inverser est exact)."""
        dx, sx = abs(x1 - x0), (1 if x0 < x1 else -1)
        dy, sy = -abs(y1 - y0), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.point(x0, y0, mode)
            if x0 == x1 and y0 == y1:
                return
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def hligne(self, x0, x1, y, mode):
        """Points x0..x1 (x0 <= x1) de la ligne y, coupés à l'écran."""
        if not (0 <= y < HAUT) or x1 < 0 or x0 >= LARG:
            return
        x0, x1 = max(x0, 0), min(x1, LARG - 1)
        for x in range(x0, x1 + 1):
            self.point(x, y, mode)

    def rect(self, x0, y0, x1, y1, mode):
        if x0 > x1:
            x0, x1 = x1, x0
        if y0 > y1:
            y0, y1 = y1, y0
        for y in range(max(y0, 0), min(y1, HAUT - 1) + 1):
            self.hligne(x0, x1, y, mode)

    def cercle(self, xc, yc, r, mode, plein=False):
        """Point milieu : x de 0 à y. Contour : les 8 symétriques, chaque
        point une fois (doublons retirés, comme le BIOS). Plein : pour chaque
        ligne, la plus longue travée, une fois."""
        if r < 0:
            return
        pts = []
        x, y, d = 0, r, 1 - r
        while x <= y:
            pts.append((x, y))
            if d < 0:
                d += 2 * x + 3
            else:
                d += 2 * (x - y) + 5
                y -= 1
            x += 1
        if plein:
            demi = {}
            for x, y in pts:
                for a, b in ((x, y), (y, x)):
                    demi[b] = max(demi.get(b, -1), a)
            for dy, a in sorted(demi.items()):
                for yy in ({yc + dy, yc - dy}):
                    self.hligne(xc - a, xc + a, yy, mode)
            return
        vus = set()
        for x, y in pts:
            for px, py in ((x, y), (-x, y), (x, -y), (-x, -y), (y, x), (-y, x), (y, -x), (-y, -x)):
                if (px, py) not in vus:
                    vus.add((px, py))
                    self.point(xc + px, yc + py, mode)

    def car(self, col, rang, c, mode):
        if not (0 <= col < COLS and 0 <= rang < RANGS):
            return
        if not (POLICE_PREMIER <= c < POLICE_PREMIER + POLICE_N):
            c = ord('?')
        if self.pol is None:
            g = bytes(8)
        else:
            g = self.pol[(c - POLICE_PREMIER) * 8:(c - POLICE_PREMIER) * 8 + 8]
        for k in range(16):
            v = g[k >> 1]
            if mode == OUX:
                v ^= 255
            self.img[(rang * 16 + k) * OCTETS_LIGNE + col] = v

    def couleur(self, c0, r0, c1, r1, attr):
        if c0 > c1:
            c0, c1 = c1, c0
        if r0 > r1:
            r0, r1 = r1, r0
        for r in range(max(r0, 0), min(r1, RANGS - 1) + 1):
            for c in range(max(c0, 0), min(c1, COLS - 1) + 1):
                self.coul[r * COLS + c] = attr

    def efface(self, attr):
        self.img[:] = bytes(len(self.img))
        self.coul[:] = bytes([attr]) * len(self.coul)

    # --- le service ---
    def appel(self, f, a=0, p=()):
        """f = fonction, a = registre A, p = les mots du bloc. Rend (C, A)."""
        if f == GR_DEBUT:
            self.ouvert = True
            self.efface(a)
            return 0, a
        if not self.ouvert or f > GR_ATTEND:
            return 1, a
        if f == GR_FIN:
            self.ouvert = False
        elif f == GR_POINT:
            self.point(p[0], p[1], a)
        elif f == GR_LIGNE:
            self.ligne(*p[:4], a)
        elif f == GR_RECT:
            self.rect(*p[:4], a)
        elif f in (GR_CERCLE, GR_DISQUE):
            self.cercle(*p[:3], a, f == GR_DISQUE)
        elif f == GR_LIT:
            return 0, self.lit(p[0], p[1])
        elif f == GR_EFFACE:
            self.efface(a)
        elif f == GR_CAR:
            self.car(p[0], p[1], p[2], a)
        elif f == GR_COULEUR:
            self.couleur(*p[:4], a)
        return 0, a


if __name__ == '__main__':
    if '--fichier' in sys.argv:
        open(sys.argv[sys.argv.index('--fichier') + 1], 'wb').write(police())
    elif '--police' in sys.argv:
        pol = police()
        for rang in range(0, POLICE_N, 16):
            for k in range(8):
                print(''.join(''.join('#' if pol[(rang + i) * 8 + k] & (0x80 >> b) else '.'
                                      for b in range(8)) + ' ' for i in range(16)))
            print()
    else:
        print(__doc__ if __doc__ else open(__file__).read().split('import')[0])
