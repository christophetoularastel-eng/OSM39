#!/usr/bin/env python3
# ===================================================================
# osm3d.py - Source unique d'OSM3D (apps/osm3d.asm) : Annonay en 3D.
# Tables, fichier des rues, et modèle EXACT, en entiers, de l'écran que
# test/verifie_osm3d.py compare au binaire.
# ===================================================================
#   python3 tools/osm3d/osm3d.py --inc        # -> apps/osm3d_data.inc
#   python3 tools/osm3d/osm3d.py --rues F     # -> F (OSM3D.RUE, en $6000)
#   python3 tools/osm3d/osm3d.py --carte F    # -> F (OSM3D.MAP, pages 2-3)
#   python3 tools/osm3d/osm3d.py --png X Y A f.png   # l'écran (essai)
#        (X, Y : la case ; A : l'angle 0-1023, 0 = est, 256 = sud)
#
# CARTE : OSM3D.MAP, tirée des mêmes données que celle d'OSM City
# (osmcity.carte(), même format, mêmes sortes, cases de ~2,455 m (x) sur
# ~5,89 m (y)) mais faite pour la 3D (carte()) : les voies tirées au
# cordeau (entre deux carrefours, Douglas-Peucker à CORDEAU mètres : les
# détails disparaissent, les carrefours restent), ELARGI fois plus larges, un trottoir de TROTTOIR mètres de chaque côté des routes
# pris sur le bâti, puis le bâti lissé (lisse() : ni saillie ni encoche
# d'une case). Unité de longueur : une colonne de la carte ; une rangée
# vaut R = 2,4 unités (RY = 614 / 256).
#
# POSITION : la case (x, y : 16 bits) et la fraction (fx, fy : 0-255) ;
# angle 0-1023 (un tour), 0 = +x (est), 256 = +y (sud).
#
# VUE (64 x 18 cellules en mosaïques 2 x 3 de la page 1, celles du
# MINITEL ; 54 sous-rangées, l'horizon entre 26 et 27) : un rayon par
# colonne (DDA case par case, comme DONJON39), jusqu'au premier bâti, à
# DMAX unités au plus, ou hors des rangées de l'anneau (y - 16 .. y + 15).
# Chaque case traversée peint le sol de sa couleur (Sol) entre les deux
# distances où le rayon y entre et en sort ; le bâti est un mur de 10 m
# (sa couleur : Facade, par pâtés ; faces nord/sud atténuées, D3 = 1) ;
# au-dessus, le ciel. Hauteurs : tables Bas (de l'horizon au pied d'un
# mur, l'œil à 1,7 m) et Haut (de l'horizon au sommet), indice = distance
# perpendiculaire / 16.
#
# DEUX COULEURS PAR CELLULE : les 3 sous-rangées v0, v1, v2 (0-15 ; 8-15
# atténuées, en premier plan seulement). Fond = la première de v2, v1, v0
# qui n'est pas atténuée (sinon 0) ; premier plan = la première de v0,
# v1, v2 qui n'est pas le fond ; les sous-rangées de cette couleur
# allument leurs 2 points, les autres montrent le fond. Premier plan 0 :
# écrit 8 (noir aussi ; 0 donne les traits roses du matériel).
#
# MINI-CARTE : colonnes 64-79, rangées 0-17 : un cadre (CP437) et 14 x 16
# cellules ; un point = 2 colonnes x 1 rangée de la carte (28 x 48 points
# autour du joueur), Mini[sorte] ; deux couleurs : fond = le dernier
# point (bas droite), premier plan = le premier qui en diffère. Au centre,
# une flèche jaune (CP437 $18-$1B) : la direction au quart de tour.
#
# PLAQUE (rangée 19) : le nom de la rue du pâté 4 x 4 du joueur, centré
# sous la vue. Rangée 20 : l'aide. Rangées 18, 21-29 : vides.
#
# OSM3D.RUE (chargé en $6000) : la grille des rues (64 x 128 pâtés)
# compressée par plages (compte, numéro), et les noms (CP437, NUL).
#   $6000 : fdb l'adresse de la table des noms
#   $6002 : 64 x fdb l'adresse de chaque rangée de plages
# Carte : © contributeurs OpenStreetMap (ODbL).
# ===================================================================
import math
import os
import sys

import numpy as np

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, os.path.join(RACINE, 'tools', 'osmcity'))
import osmcity as oc                                    # noqa: E402

VUE_L, VUE_H = 64, 18
SOUS = 3 * VUE_H                # 54 sous-rangées
HORIZON = SOUS // 2             # 27 : la première sous-rangée du sol
CHAMP = 60.0                    # degrés
FOCALE = 83                     # sous-rangées d'un objet de 1 unité à 1 unité
M = 2.455                       # mètres par unité (une colonne de la carte)
RY = 614                        # une rangée = RY / 256 unités (2,4)
DMAX = 40 * 256                 # distance (8.8) où le rayon s'arrête
NIDX = DMAX >> 4                # 640 : indices des tables Bas et Haut
OEIL = 1.7                      # mètres (à pied)
HAUT_BATI = 16.0                # mètres (4 à 5 étages)
PONT_BAS, PONT_HAUT = 5.0, 7.0  # mètres : le haut de l'arche, le dessus du tablier
MURET_HAUT = 1.2                # mètres : le muret entre la rue du dessous et celle du dessus
GARDE_HAUT = 8.0                # mètres : le haut du parapet
PONT_COUL = 15                  # gris pierre (face au nord ou au sud, comme les façades à l'ombre)
PIERRE_CLAIRE = 15              # les faces est et ouest des culées (même pierre)
DESSOUS_COUL = 15              # le dessous du tablier : la même pierre (le dessin de l'utilisateur n'a pas de bande noire)
GARDE_COUL = 7                  # le parapet : blanc (dessin de l'utilisateur, 25 nov. 2026)
DESSOUS = 0x40                  # dans SolB : un tablier
DELTA_MAX = 32767
ANNEAU_H, ANNEAU_B = -16, 15    # les rangées de l'anneau autour du joueur

CIEL = 3                        # cyan : l'eau garde le bleu
# sortes ajoutées par marquages() (la carte a 4 bits par case : 16 sortes)
BORDURE = 13
CULEE = 14      # un mur de pierre du sol au tablier : arrête au sol, tablier à l'étage 1
MURET = 15      # un mur bas entre la rue du dessous et celle qui monte au pont : arrête
# PARC et TALUS d'OSM City sont fondus dans VIDE (même vert, on y marche) :
# leurs numéros servent au pied de l'arche (sous_pont / pont près du bord
# du passage, ARC_BORD : l'ouverture y est à ARC_H au lieu de PONT_BAS)
PONT_ARC = oc.PARC              # 5
SOUS_ARC = oc.TALUS             # 11
NSORTES = 16
TABLIERS = (oc.PONT, oc.TABLIER, oc.SOUS_PONT, CULEE, PONT_ARC, SOUS_ARC)
DESSOUS_S = (oc.PONT, oc.SOUS_PONT, PONT_ARC, SOUS_ARC)   # au sol, le rayon passe dessous
PASSAGE = (oc.SOUS_PONT, SOUS_ARC)                        # au sol, on passe dessous
MURS_P = (CULEE, oc.TABLIER)                              # au sol : de la pierre jusqu'au tablier
ARC_BORD = 0.5                  # place dans la portée sous laquelle une case est le pied de l'arche
ARC_H = 3.0                     # mètres : l'ouverture au pied de l'arche
# hauteurs tirées des tables existantes (le 6309 : un MUL 8 bits) :
# rangées(h) = (table x Q) >> 8
Q_ARC = round(256 * (ARC_H - OEIL) / (PONT_BAS - OEIL))                  # de PBot2
Q_GARDE = round(256 * ((GARDE_HAUT - OEIL) / (PONT_HAUT - OEIL) - 1))    # PTop2 + ...
Q_MUR = round(256 * (OEIL - MURET_HAUT) / OEIL)                          # de Bas (sous l'horizon)
# drapeaux de SolB (avec DESSOUS)
ARC_F, MUR_P, MURET_F = 0x80, 0x20, 0x10
# la chaussée noire, le trottoir blanc, le parking gris (blanc atténué :
# premier plan seulement). La chaussée grise se confondait avec les faces
# à l'ombre des immeubles blancs (le même gris).
SOL = {oc.ROUTE: 0, oc.PLACE: 15, oc.RAMPE: 0, oc.SOUS_PONT: 0, oc.PONT: 0, oc.TABLIER: 0,
       oc.PIETON: 7, oc.EAU: 1, oc.VIDE: 2, oc.FALAISE: 2, oc.BATI: 0,
       BORDURE: 7, CULEE: 0, MURET: 0, PONT_ARC: 0, SOUS_ARC: 0}
FACADES = [14, 12, 14, 15]      # ocre, brique, ocre, crépi gris (atténuées) ; à l'ombre : des fenêtres
MINI = {oc.PONT: 15, oc.TABLIER: 15, oc.SOUS_PONT: 15, CULEE: 15, PONT_ARC: 15, SOUS_ARC: 15,
        MURET: 7, oc.BATI: 4, oc.PIETON: 7, BORDURE: 7, oc.EAU: 1, oc.VIDE: 2, oc.FALAISE: 2}

MINI_COL, MINI_L, MINI_H = 65, 14, 16          # l'intérieur du cadre
PLQ_RANG, AIDE_RANG = 19, 20
CADRE_ATTR = 0x07
FLECHES = (0x1A, 0x19, 0x1B, 0x18)             # est, sud, ouest, nord
FLECHE_ATTR = 0x06
VIDE_CEL = (0x20, 0x08)
AIDE = 'Flèches : avancer, reculer, tourner      Echap : quitter'

# Mosaïques : valeur 0-63 (bit 2 x sous-rangée + colonne) -> glyphe page 1
TAB_MOS = [0x00, 0x5E, 0x5F, 0x50, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x51, 0x68, 0x69, 0x52,
           0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
           0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x4F, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
           0x53, 0x10, 0x11, 0x54, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x55, 0x1A, 0x1B, 0x56]


# les routes principales élargies, avec un trottoir de 2,5 m pris sur le
# bâti ; les petites rues (FAIBLES) gardent leur largeur et cèdent au bâti
# (seul l'axe reste route) : la vieille ville garde ses ruelles
ELARGI = {'primary': 1.5, 'secondary': 1.5, 'tertiary': 1.5, 'tertiary_link': 1.5}
TROTTOIR = {k: 2.5 for k in ELARGI}
FAIBLES = ('residential', 'unclassified', 'road', 'living_street', 'service')
CORDEAU = 8.0                   # mètres : les rues tirées au cordeau
LISSAGES = 2


def lisse(c):
    """Le bâti sans saillie ni encoche d'une case. Une case de bâti qui a
    au plus une voisine (4-connexité) bâtie devient du sol : trottoir si
    elle touche une rue, un chemin ou un trottoir, sinon VIDE ; une case
    VIDE qui a au moins 3 voisines bâties devient du bâti. Bords : comptés
    non bâtis."""
    import numpy as np
    c = c.copy()
    for _ in range(LISSAGES):
        b = np.pad(c == oc.BATI, 1)
        n = b[:-2, 1:-1].astype(int) + b[2:, 1:-1] + b[1:-1, :-2] + b[1:-1, 2:]
        r = np.pad(np.isin(c, (oc.ROUTE, oc.PIETON, oc.PLACE)), 1)
        rue = r[:-2, 1:-1] | r[2:, 1:-1] | r[1:-1, :-2] | r[1:-1, 2:]
        saillie = (c == oc.BATI) & (n <= 1)
        encoche = (c == oc.VIDE) & (n >= 3)
        c[saillie & rue] = oc.PIETON
        c[saillie & ~rue] = oc.VIDE
        c[encoche] = oc.BATI
    return c


_CARTE = []


CHAUSSEE = (oc.ROUTE, oc.PLACE, oc.RAMPE, oc.SOUS_PONT, oc.PONT, oc.TABLIER)


ROULANTE = (oc.ROUTE, oc.RAMPE, oc.SOUS_PONT, oc.PONT, oc.TABLIER)


def marquages(c):
    """Le tracé de la route : BORDURE, une case de trottoir qui touche la
    chaussée, ou de parking qui touche la chaussée roulante (4-connexité). (Des tirets du milieu et des lignes de stop en
    cases entières ont été essayés le 22 nov. 2026 : un pavé de 5 x 6 m de
    près, rien au-delà d'une dizaine de mètres.)"""
    c = c.copy()
    p = np.pad(np.isin(c, CHAUSSEE), 1)
    touche = p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:]
    p = np.pad(np.isin(c, ROULANTE), 1)
    roule = p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:]
    c[((c == oc.PIETON) & touche) | ((c == oc.PLACE) & roule)] = BORDURE
    return c


def _voisin4(m):
    p = np.pad(m, 1)
    return p[:-2, 1:-1] | p[2:, 1:-1] | p[1:-1, :-2] | p[1:-1, 2:]


def _dilate(m, rx, ry):
    out = m.copy()
    h, w = m.shape
    for dy in range(-ry, ry + 1):
        for dx in range(-rx, rx + 1):
            ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
            xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
            out[yd, xd] |= m[ys, xs]
    return out


RAC_LONG = 12                   # cases d'axe : l'approche d'un pont (le haut)
DESSOUS_RX, DESSOUS_RY = 10, 4  # autour du passage sous le pont (le bas)
DEMI_RX, DEMI_RY = 2, 1         # demi-largeur d'une rue (cases) : les ponts refaits sont à la vraie largeur


def culees(c):
    """Les culées : la carte est plate, mais la rue qui passe sous un pont
    est plus bas que celles qui y montent. Le HAUT : les RAC_LONG
    premières cases d'axe des rues qui partent du bout d'un pont, et leur
    largeur ; le BAS : l'axe des rues qui passent sous un tablier
    (SOUS_PONT) sans partir d'un bout de pont, autour du passage, et sa
    largeur. Une case du haut (pas une rampe) qui est du bas ou le touche
    devient MURET (un mur bas : on ne passe plus d'une rue à l'autre) ;
    les CULEE (un mur de pierre jusqu'au tablier, aux deux bouts du pont
    seulement) : une case du bas ou un SOUS_PONT qui touche une rampe."""
    c = c.copy()
    kx, ky, w, h = oc.projection()
    noeuds, voies = oc.lit()

    def case(n):
        lat, lon = noeuds[n]
        return int((lon - oc.O_) * kx / w * oc.LARG), int((oc.N_ - lat) * ky / h * oc.HAUT)

    def axe(nds):
        p = [case(n) for n in nds if n in noeuds]
        out = []
        for a, b in zip(p, p[1:]):
            out += [q for q in oc.ligne4(*a, *b) if not out or q != out[-1]]
        return out
    routes = [v for v in voies if 'highway' in v.get('tags', {})]
    ponts = [v for v in routes if v['tags'].get('bridge') == 'yes']
    autres = [v for v in routes if v['tags'].get('bridge') != 'yes']
    bouts = {v['nodes'][k] for v in ponts for k in (0, -1)}
    H, L = c.shape
    sol = np.isin(c, (oc.ROUTE, oc.RAMPE, oc.PIETON, oc.PLACE, BORDURE))
    rampe = c == oc.RAMPE
    sous = c == oc.SOUS_PONT

    def dans(q):
        return 0 <= q[0] < L and 0 <= q[1] < H
    # les rues du dessous : (axe, cases SOUS_PONT de l'axe)
    dessous = []
    for v in autres:
        if bouts.intersection(v['nodes']):
            continue                    # elle part d'un pont : son prolongement
        a = axe(v['nodes'])
        d = [q for q in a if dans(q) and sous[q[1], q[0]]]
        if d:
            dessous.append((a, d))
    culee = sous & _voisin4(rampe)
    mur = np.zeros(c.shape, bool)
    for p in ponts:
        pa = axe(p['nodes'])
        haut = np.zeros(c.shape, bool)
        bas = np.zeros(c.shape, bool)
        for v in autres:
            nd = v['nodes']
            for k, n in enumerate(nd):
                if n in (p['nodes'][0], p['nodes'][-1]):
                    for sens in (nd[k:], nd[k::-1]):
                        if len(sens) > 1:
                            for q in axe(sens)[:RAC_LONG]:
                                if dans(q):
                                    haut[q[1], q[0]] = True
        for a, d in dessous:
            d = [q for q in d if any(abs(q[0] - r[0]) <= 3 and abs(q[1] - r[1]) <= 2 for r in pa)]
            for q in a:
                if dans(q) and any(abs(q[0] - r[0]) <= DESSOUS_RX and abs(q[1] - r[1]) <= DESSOUS_RY for r in d):
                    bas[q[1], q[0]] = True
        if not bas.any():
            continue
        haut = _dilate(haut, DEMI_RX, DEMI_RY) & sol
        bas = (_dilate(bas, DEMI_RX, DEMI_RY) & (sol | sous) & ~haut) | (bas & sous)
        mur |= haut & ~rampe & (bas | _voisin4(bas))
        culee |= bas & _voisin4(rampe) & ~rampe
    c[mur & ~culee] = MURET
    c[culee] = CULEE
    return c


def passe(c, x0, y0, x1, y1, niv):
    """Comme Passe du 6309 (oc.passe sans l'herbe : à pied on marche sur
    l'herbe) : bâti, eau, falaise, muret arrêtent ; sur un tablier
    (TABLIERS) on arrive d'un tablier (étage 1) ou d'une rampe (on monte) ;
    au sol, seul le passage (PASSAGE) se traverse ; du tablier on ne
    descend que sur une rampe. -> l'étage d'arrivée, ou None."""
    s1 = oc.sorte_xy(c, x1, y1)
    if s1 in (oc.BATI, oc.EAU, oc.FALAISE, MURET):
        return None
    if s1 in TABLIERS:
        if niv == 1 or oc.sorte_xy(c, x0, y0) == oc.RAMPE:
            return 1
        return 0 if s1 in PASSAGE else None
    if niv == 1:
        return 0 if s1 == oc.RAMPE else None
    return 0


ARCHE_D = {}                    # (x, y) -> place dans la portée : 0 au bord du passage, 1 au milieu (ponts())
PONT_MARGE = 0.5                # mètres ajoutés à la demi-largeur du tablier
RAMPE_LONG = 3                  # cases d'axe des rues d'approche : la rampe


def ponts(c):
    """Les ponts refaits d'après les voies bridge=yes (dessin de
    l'utilisateur, 25 nov. 2026) : l'ancien pont (les cases d'OSM City,
    un pâté de biais) est retiré et le sol retrouvé dessous (PONT -> EAU,
    SOUS_PONT et RAMPE -> ROUTE, TABLIER -> la sorte majoritaire autour) ;
    puis le tablier est redessiné le long de l'axe de la voie, à la largeur
    réelle de la rue qu'il porte (oc.ROUTES, oc.PIETONS) : PONT sur l'eau,
    SOUS_PONT sur une rue ou un chemin (on passe dessous : l'arche),
    TABLIER ailleurs (un remblai plein) ; les RAMPE : les RAMPE_LONG
    premières cases d'axe des rues qui partent d'un bout, et leur largeur,
    contre le tablier."""
    c = c.copy()
    kx, ky, w, h = oc.projection()
    noeuds, voies = oc.lit()
    H, L = c.shape
    mx, my = w / L, h / H                       # mètres par case

    def pos(n):
        lat, lon = noeuds[n]
        return (lon - oc.O_) * kx / w * L, (oc.N_ - lat) * ky / h * H

    # 1. le sol sous l'ancien pont (ancien : ses cases, pour savoir plus
    # bas qu'une case de rue y était le pont lui-même, pas une autre rue)
    ancien = np.isin(c, (oc.PONT, oc.SOUS_PONT, oc.RAMPE, oc.TABLIER))
    c[c == oc.PONT] = oc.EAU
    c[np.isin(c, (oc.SOUS_PONT, oc.RAMPE))] = oc.ROUTE
    reste = c == oc.TABLIER
    while reste.any():
        for y, x in zip(*np.nonzero(reste)):
            v = [int(c[y + b, x + a]) for a in (-1, 0, 1) for b in (-1, 0, 1)
                 if 0 <= y + b < H and 0 <= x + a < L and not reste[y + b, x + a]]
            if v:
                c[y, x] = max(set(v), key=v.count)
                reste[y, x] = False

    def bande(pts, demi):
        """Les cases dont le centre est à moins de demi mètres de la
        ligne brisée pts (coordonnées en cases, flottantes)."""
        m = np.zeros(c.shape, bool)
        r = int(demi / min(mx, my)) + 2
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            for y in range(max(0, int(min(y0, y1)) - r), min(H, int(max(y0, y1)) + r + 1)):
                for x in range(max(0, int(min(x0, x1)) - r), min(L, int(max(x0, x1)) + r + 1)):
                    ax, ay = (x + 0.5 - x0) * mx, (y + 0.5 - y0) * my
                    bx, by = (x1 - x0) * mx, (y1 - y0) * my
                    t = max(0.0, min(1.0, (ax * bx + ay * by) / max(1e-9, bx * bx + by * by)))
                    if math.hypot(ax - t * bx, ay - t * by) <= demi:
                        m[y, x] = True
        return m

    def coupe(a1, a2, b1, b2):
        def cote(p, q, r):
            return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
        return (cote(a1, a2, b1) * cote(a1, a2, b2) < 0) and (cote(b1, b2, a1) * cote(b1, b2, a2) < 0)

    def dist_axe(q, x, y):
        best = 1e9
        for (x0, y0), (x1, y1) in zip(q, q[1:]):
            ax, ay = (x + 0.5 - x0) * mx, (y + 0.5 - y0) * my
            bx, by = (x1 - x0) * mx, (y1 - y0) * my
            t = max(0.0, min(1.0, (ax * bx + ay * by) / max(1e-9, bx * bx + by * by)))
            best = min(best, math.hypot(ax - t * bx, ay - t * by))
        return best

    def largeur(tg):
        # la largeur dessinée sur la carte : élargie, trottoirs compris
        hw = tg.get('highway')
        if hw in oc.ROUTES:
            return oc.ROUTES[hw] * ELARGI.get(hw, 1.0) + 2 * TROTTOIR.get(hw, 0.0)
        return oc.PIETONS.get(hw) or 4.0
    routes = [v for v in voies if 'highway' in v.get('tags', {})]
    for p in routes:
        if p['tags'].get('bridge') != 'yes':
            continue
        pts = [pos(n) for n in p['nodes'] if n in noeuds]
        if len(pts) < 2:
            continue
        demi = largeur(p['tags']) / 2 + PONT_MARGE
        m = bande(pts, demi)
        # au moins l'axe (une passerelle plus étroite qu'une case)
        for a, b in zip(pts, pts[1:]):
            for x, y in oc.ligne4(int(a[0]), int(a[1]), int(b[0]), int(b[1])):
                if 0 <= x < L and 0 <= y < H:
                    m[y, x] = True
        dessous = c.copy()
        eau = m & (dessous == oc.EAU)
        # une rue passe dessous seulement si son axe croise celui du pont
        # (Montgolfier, Chevalier) ; un pont qui n'enjambe que l'eau
        # (Valgelas) n'a pas de passage : ses bouts sont des rampes
        rue = np.zeros(c.shape, bool)
        dessous_axes = []
        for v in routes:
            if v['tags'].get('bridge') == 'yes' or set(v['nodes']) & set(p['nodes']):
                continue
            q = [pos(u) for u in v['nodes'] if u in noeuds]
            if any(coupe(a1, a2, b1, b2) for a1, a2 in zip(pts, pts[1:]) for b1, b2 in zip(q, q[1:])):
                rue |= bande(q, largeur(v['tags']) / 2 + PONT_MARGE)
                dessous_axes.append((q, largeur(v['tags']) / 2 + PONT_MARGE))
        sol = np.isin(dessous, (oc.ROUTE, oc.PIETON, oc.PLACE, BORDURE))
        rue &= m & sol
        # sur une autre rue qui ne passe pas dessous (le bout du Valgelas
        # sur l'avenue Simone Veil) : le tablier s'arrête, la rue reste
        c[m & (~sol | ancien)] = oc.TABLIER
        c[rue] = oc.SOUS_PONT
        c[eau] = oc.PONT
        # l'arche : pour chaque case du passage, sa distance (mètres) au
        # bord du passage, en travers (la rue dessous : demi-largeur moins
        # la distance à son axe ; l'eau : la case non-eau la plus proche)
        vals = {}
        for y, x in zip(*np.nonzero(rue | eau)):
            if rue[y, x]:
                dm = None
                for q, dl in dessous_axes:
                    e = (dl - dist_axe(q, x, y)) / dl          # 0 au bord, 1 sur l'axe
                    dm = e if dm is None else max(dm, e)
            else:
                dm = min((math.hypot(a * mx, b * my) - 0.5 * mx
                          for a in range(-4, 5) for b in range(-2, 3)
                          if 0 <= y + b < H and 0 <= x + a < L and dessous[y + b, x + a] != oc.EAU),
                         default=99.0)
                dm = -dm                                        # normalisé plus bas
            vals[(int(x), int(y))] = dm
        neg = [-v for v in vals.values() if v < 0]
        for k_, v in vals.items():
            ARCHE_D[k_] = min(1.0, max(0.0, v if v >= 0 else -v / max(neg)))
        # 2. les rampes : le début des rues qui partent des bouts
        bouts = (p['nodes'][0], p['nodes'][-1])
        for v in routes:
            if v['tags'].get('bridge') == 'yes':
                continue
            nd = v['nodes']
            for k, n in enumerate(nd):
                if n not in bouts:
                    continue
                for sens in (nd[k:], nd[k::-1]):
                    q = [pos(u) for u in sens if u in noeuds]
                    if len(q) < 2:
                        continue
                    # RAMPE_LONG cases le long de l'axe, de la largeur de la rue
                    lg = RAMPE_LONG * max(mx, my)
                    cumul, court = 0.0, [q[0]]
                    for a, b in zip(q, q[1:]):
                        dl = math.hypot((b[0] - a[0]) * mx, (b[1] - a[1]) * my)
                        if cumul + dl >= lg:
                            t = (lg - cumul) / dl
                            court.append((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])))
                            break
                        court.append(b)
                        cumul += dl
                    r = bande(court, largeur(v['tags']) / 2 + PONT_MARGE) & ~np.isin(c, TABLIERS) \
                        & ~np.isin(c, oc.BLOQUE)
                    c[r] = oc.RAMPE
    return c


def finir(c):
    """PARC et TALUS fondus dans VIDE ; le pied de l'arche : un passage
    (SOUS_PONT, PONT) dont la place dans la portée (ARCHE_D) est sous
    ARC_BORD devient SOUS_ARC / PONT_ARC."""
    c = c.copy()
    c[np.isin(c, (oc.PARC, oc.TALUS))] = oc.VIDE
    for (x, y), t in ARCHE_D.items():
        if t < ARC_BORD:
            if c[y, x] == oc.SOUS_PONT:
                c[y, x] = SOUS_ARC
            elif c[y, x] == oc.PONT:
                c[y, x] = PONT_ARC
    return c


def carte():
    """La carte d'OSM3D (voir l'en-tête), calculée une fois."""
    if not _CARTE:
        _CARTE.append(finir(culees(marquages(ponts(lisse(oc.carte(ELARGI=ELARGI, TROTTOIR=TROTTOIR, CORDEAU=CORDEAU,
                                                    ALLEES=True, FAIBLES=FAIBLES,
                                                    PIETONNES=True, RACCORDS=True)))))))
    return _CARTE[0]


def tables():
    t = {}
    t['SinQ'] = [round(math.sin(q * math.pi / 512) * 256) for q in range(257)]
    t['DeltaQ'] = [DELTA_MAX if q == 256 else min(DELTA_MAX, round(256 / math.cos(q * math.pi / 512)))
                   for q in range(257)]
    demi = math.tan(math.radians(CHAMP / 2))
    off, cos_ = [], []
    for c in range(VUE_L):
        x = ((c + 0.5) / VUE_L * 2 - 1) * demi
        ang = math.atan(x)
        off.append(round(ang / (2 * math.pi) * 1024))
        cos_.append(round(math.cos(ang) * 256))
    t['ColOff'] = off
    t['ColCos'] = cos_
    oeil, haut = OEIL / M, (HAUT_BATI - OEIL) / M
    t['Bas'] = [min(SOUS - HORIZON, round(FOCALE * oeil * 16 / max(i, 1))) for i in range(NIDX)]
    t['Haut'] = [min(HORIZON, round(FOCALE * haut * 16 / max(i, 1))) for i in range(NIDX)]
    t['PTop2'] = [min(HORIZON, round(FOCALE * (PONT_HAUT - OEIL) / M * 16 / max(2 * j, 1))) for j in range(NIDX // 2)]
    t['PBot2'] = [min(HORIZON, round(FOCALE * (PONT_BAS - OEIL) / M * 16 / max(2 * j, 1))) for j in range(NIDX // 2)]
    t['Sol'] = [SOL.get(k, 0) for k in range(NSORTES)]
    t['Mini'] = [MINI.get(k, 0) for k in range(NSORTES)]
    return t


T = tables()


def sin_(a):
    a &= 1023
    q, k = a & 255, a >> 8
    v = T['SinQ'][q] if k in (0, 2) else T['SinQ'][256 - q]
    return v if k < 2 else -v


def cos_(a):
    return sin_(a + 256)


def delta(a):
    """1 / |cos a| en 8.8 (plafonné)."""
    q = a & 511
    if q > 256:
        q = 512 - q
    return T['DeltaQ'][q]


def mul_milieu(a, b):
    """MULD (signés) puis les 16 bits du milieu : (a x b) >> 8."""
    sa = a - 0x10000 if a & 0x8000 else a
    sb = b - 0x10000 if b & 0x8000 else b
    return ((sa * sb) >> 8) & 0xFFFF


def facade(x, y):
    return FACADES[((x >> 3) + 3 * (y >> 2)) & 3]


def rayon(c, x0, fx, y0, fy, ang, col, niv=0):
    """La colonne col : 54 couleurs, de haut en bas. niv : l'étage du
    joueur (0 au sol, 1 sur un pont). Au-dessus de l'horizon, tout ne
    peint que le ciel (ce qui est devant reste). Au sol :
      - sous un tablier (DESSOUS_S), d'i_in à i_out : le parapet blanc
        [HORIZON - pg, HORIZON - PTop2[i_in / 2]) (pg = pt + pt x Q_GARDE /
        256), puis la pierre jusqu'à HORIZON - PBot2[i_out / 2] (x Q_ARC /
        256 si la dernière case sous le tablier est le pied de l'arche) ;
      - une culée ou un remblai (MURS_P) : le parapet, la pierre de
        HORIZON - PTop2[i / 2] jusqu'en bas ; le rayon continue au-dessus ;
    - un muret : la pierre depuis HORIZON + Bas[i] x Q_MUR / 256 ;
    - le bâti : la façade, des fenêtres à l'ombre (face en x, x pair : une
      sous-rangée sur 3 noire)."""
    r = (ang + T['ColOff'][col]) & 1023
    dx = delta(r)
    dy = min(DELTA_MAX, (delta((r - 256) & 1023) * RY) >> 8)
    sx = 1 if (r <= 256 or r >= 768) else -1
    sy = 1 if r <= 512 else -1
    side_x = mul_milieu((256 - fx) if sx > 0 else fx, dx)
    side_y = mul_milieu((256 - fy) if sy > 0 else fy, dy)
    v = [CIEL] * HORIZON + [0] * (SOUS - HORIZON)
    bas = SOUS
    x, y = x0, y0
    sorte = oc.sorte_xy(c, x, y)

    def peint(a, b, coul):
        for k in range(a, b):
            if k >= HORIZON or v[k] == CIEL:
                v[k] = coul

    def dessous(s_):
        return niv == 0 and s_ in DESSOUS_S

    def parapet(i):
        pt = T['PTop2'][i >> 1]
        pg = min(HORIZON, pt + ((pt * Q_GARDE) >> 8))
        peint(HORIZON - pg, HORIZON - pt, GARDE_COUL)
        return HORIZON - pt

    def bande(i_in, i_out, der):
        h = parapet(i_in)
        b = T['PBot2'][i_out >> 1]
        if der in (PONT_ARC, SOUS_ARC):
            b = (b * Q_ARC) >> 8
        peint(h, HORIZON - b, PONT_COUL)
    i_in = 1 if dessous(sorte) else None
    der = sorte
    while True:
        if side_x < side_y:
            d = side_x
            side_x = min(0xFFFF, side_x + dx)
            x += sx
            cote = 0
        else:
            d = side_y
            side_y = min(0xFFFF, side_y + dy)
            y += sy
            cote = 1
        if d >= DMAX:
            if i_in is not None:
                bande(i_in, NIDX - 1, der)
            peint(HORIZON, bas, T['Sol'][sorte])
            return v
        i = max(1, mul_milieu(d, T['ColCos'][col]) >> 4)
        g = HORIZON + T['Bas'][i]
        if g < bas:
            peint(g, bas, T['Sol'][sorte])
            bas = g
        if not ANNEAU_H <= y - y0 <= ANNEAU_B:
            if i_in is not None:
                bande(i_in, NIDX - 1, der)
            peint(HORIZON, bas, T['Sol'][sorte])
            return v
        sorte = oc.sorte_xy(c, x, y)
        if sorte == oc.BATI:
            if i_in is not None:
                bande(i_in, i, der)
            fen = cote and not x & 1
            coul = facade(x, y)
            for k in range(HORIZON - T['Haut'][i], bas):
                if k >= HORIZON or v[k] == CIEL:
                    v[k] = 0 if (fen and k % 3 == 2) else coul
            return v
        if dessous(sorte):
            if i_in is None:
                i_in = i
            der = sorte
            continue
        if i_in is not None:
            bande(i_in, i, der)
            i_in = None
        if niv == 0 and sorte in MURS_P:
            h = parapet(i)
            if h < bas:
                peint(h, bas, PONT_COUL)
                bas = h
        elif sorte == MURET:
            m = HORIZON + ((T['Bas'][i] * Q_MUR) >> 8)
            if m < bas:
                peint(m, bas, PONT_COUL)
                bas = m


def cellule(vals, bits):
    """vals : les couleurs des points (dans l'ordre des bits) -> (glyphe,
    attribut). Fond : la première non atténuée en partant de la fin (sinon
    0) ; premier plan : la première qui n'est pas le fond."""
    fond = next((u for u in reversed(vals) if u < 8), 0)
    avant = next((u for u in vals if u != fond), None)
    if avant is None:
        return TAB_MOS[0], 0x80 | (fond << 4) | 8
    m = 0
    for u, b in zip(vals, bits):
        if u == avant:
            m |= b
    return TAB_MOS[m], 0x80 | (fond << 4) | (avant or 8)


BITS_VUE = (3, 12, 48)
BITS_MINI = (1, 2, 4, 8, 16, 32)


ARC_PIED = 1.0                  # mètres : le pied de l'arche (au bord du passage) ; la clé à PONT_BAS
MY = M * RY / 256               # mètres par rangée de la carte (5,9)


def vue(c, x, fx, y, fy, ang, niv=0):
    """-> 18 rangées de 64 (glyphe, attribut)."""
    cols = [rayon(c, x, fx, y, fy, ang, i, niv) for i in range(VUE_L)]
    return [[cellule(cols[i][3 * r:3 * r + 3], BITS_VUE) for i in range(VUE_L)] for r in range(VUE_H)]


def mini(c, x, y, ang):
    """-> 16 rangées de 14 (glyphe, attribut) : l'intérieur du cadre."""
    out = []
    for r in range(MINI_H):
        rang = []
        for q in range(MINI_L):
            vals = [T['Mini'][oc.sorte_xy(c, x - 2 * MINI_L + 2 * (2 * q + b), y - 3 * MINI_H // 2 + 3 * r + k)]
                    for k in range(3) for b in range(2)]
            rang.append(cellule(vals, BITS_MINI))
        out.append(rang)
    out[MINI_H // 2][MINI_L // 2] = (FLECHES[((ang + 128) & 1023) >> 8], FLECHE_ATTR)
    return out


def aide_octets():
    return AIDE.encode('cp437')


def ecran(c, x, fx, y, fy, ang, rues_=None, niv=0):
    """L'écran du jeu : 30 rangées de 80 (glyphe, attribut)."""
    noms, grille = rues_ if rues_ is not None else oc.rues()
    e = [[VIDE_CEL] * 80 for _ in range(30)]
    for r, rang in enumerate(vue(c, x, fx, y, fy, ang, niv)):
        e[r][:VUE_L] = rang
    g, d, h, b = MINI_COL - 1, MINI_COL + MINI_L, 0, MINI_H + 1
    for k in range(g + 1, d):
        e[h][k] = e[b][k] = (0xC4, CADRE_ATTR)
    for k in range(h + 1, b):
        e[k][g] = e[k][d] = (0xB3, CADRE_ATTR)
    e[h][g], e[h][d], e[b][g], e[b][d] = ((0xDA, CADRE_ATTR), (0xBF, CADRE_ATTR),
                                          (0xC0, CADRE_ATTR), (0xD9, CADRE_ATTR))
    for k, o in enumerate(b' PLAN '):
        e[h][g + 5 + k] = (o, CADRE_ATTR)
    for r, rang in enumerate(mini(c, x, y, ang)):
        e[1 + r][MINI_COL:MINI_COL + MINI_L] = rang
    n = numero_rue(grille, x, y)
    if n:
        txt = b' ' + noms[n - 1] + b' '
        for k, o in enumerate(txt):
            e[PLQ_RANG][VUE_L // 2 - len(txt) // 2 + k] = (o, oc.PLQ_ATTR)
    for k, o in enumerate(aide_octets()):
        e[AIDE_RANG][k] = (o, 0x07)
    return e


def numero_rue(grille, x, y):
    if 0 <= x < oc.LARG and 0 <= y < oc.HAUT:
        return int(grille[y // oc.RUES_BL, x // oc.RUES_BL])
    return 0


def fichier_rues(rues_=None):
    """OSM3D.RUE : voir l'en-tête."""
    noms, grille = rues_ if rues_ is not None else oc.rues()
    base = 0x6000
    rangs = []
    for r in grille:
        p = []
        k = 0
        while k < len(r):
            n = 1
            while k + n < len(r) and r[k + n] == r[k] and n < 255:
                n += 1
            p += [n, int(r[k])]
            k += n
        rangs.append(bytes(p))
    tete = 2 + 2 * len(rangs)
    out = bytearray(tete)
    adr = []
    for p in rangs:
        adr.append(base + len(out))
        out += p
    table = base + len(out)
    out += bytes(2 * len(noms))
    for i, nm in enumerate(noms):
        a = base + len(out)
        out[table - base + 2 * i:table - base + 2 * i + 2] = a.to_bytes(2, 'big')
        out += nm[:VUE_L - 2] + b'\0'
    out[0:2] = table.to_bytes(2, 'big')
    for i, a in enumerate(adr):
        out[2 + 2 * i:4 + 2 * i] = a.to_bytes(2, 'big')
    assert len(out) <= 0x2000, len(out)
    return bytes(out)


def inc():
    L = ['; ===================================================================',
         '; osm3d_data.inc - GÉNÉRÉ par tools/osm3d/osm3d.py --inc : ne pas',
         '; éditer. Tables d\'OSM3D (voir l\'en-tête de osm3d.py).',
         '; ===================================================================',
         'VUE_L           equ %d' % VUE_L, 'VUE_H           equ %d' % VUE_H,
         'SOUS            equ %d' % SOUS, 'HORIZON         equ %d' % HORIZON,
         'DMAX            equ %d' % DMAX, 'RY              equ %d' % RY,
         'CIEL            equ %d' % CIEL, 'DELTA_MAX       equ %d' % DELTA_MAX,
         'MINI_COL        equ %d' % MINI_COL, 'MINI_L          equ %d' % MINI_L,
         'MINI_H          equ %d' % MINI_H, 'PLQ_RANG        equ %d' % PLQ_RANG,
         'AIDE_RANG       equ %d' % AIDE_RANG, 'CADRE_ATTR      equ $%02X' % CADRE_ATTR,
         'FLECHE_ATTR     equ $%02X' % FLECHE_ATTR, 'PLQ_ATTR        equ $%02X' % oc.PLQ_ATTR,
         'S_BATI          equ %d' % oc.BATI, 'S_EAU           equ %d' % oc.EAU,
         'S_FALAISE       equ %d' % oc.FALAISE,
         'S_PONT          equ %d' % oc.PONT, 'S_TABLIER       equ %d' % oc.TABLIER,
         'S_SOUS_PONT     equ %d' % oc.SOUS_PONT, 'S_RAMPE         equ %d' % oc.RAMPE,
         'S_CULEE         equ %d' % CULEE, 'S_MURET         equ %d' % MURET,
         'S_PONT_ARC      equ %d' % PONT_ARC, 'S_SOUS_ARC      equ %d' % SOUS_ARC,
         'Q_ARC           equ %d' % Q_ARC, 'Q_GARDE         equ %d' % Q_GARDE,
         'Q_MUR           equ %d' % Q_MUR, 'GARDE_COUL      equ %d' % GARDE_COUL,
         'ARC_F           equ $%02X' % ARC_F, 'MUR_P           equ $%02X' % MUR_P,
         'MURET_F         equ $%02X' % MURET_F,
         'PONT_COUL       equ %d' % PONT_COUL, 'NIDX            equ %d' % NIDX,
         'DESSOUS         equ $%02X' % DESSOUS,
         'CARTE_L         equ %d' % oc.LARG, 'CARTE_H         equ %d' % oc.HAUT,
         'DEPART_X        equ %d' % oc.depart(carte())[0],
         'DEPART_Y        equ %d' % oc.depart(carte())[1],
         'DEPART_A        equ 768']

    def bloc(nom, val, mot):
        L.append(nom)
        pas = 8 if mot else 16
        for i in range(0, len(val), pas):
            if mot:
                L.append('        fdb ' + ','.join('$%04X' % (v & 0xFFFF) for v in val[i:i + pas]))
            else:
                L.append('        fcb ' + ','.join('$%02X' % (v & 0xFF) for v in val[i:i + pas]))
    bloc('SinQ', T['SinQ'], True)
    bloc('DeltaQ', T['DeltaQ'], True)
    bloc('ColOff', T['ColOff'], True)
    bloc('ColCos16', [16 * v for v in T['ColCos']], True)
    bloc('Bas', T['Bas'], False)
    bloc('Haut', T['Haut'], False)
    bloc('PTop2', T['PTop2'], False)
    bloc('PBot2', T['PBot2'], False)
    # SolB : la couleur du sol, $FF pour le bâti, + DESSOUS pour un tablier
    # (le rayon voit où il passe dessous ; la couleur peinte est & 15)
    def code(k):
        if k == oc.BATI:
            return 0xFF
        v = T['Sol'][k]
        if k in DESSOUS_S:
            v |= DESSOUS | (ARC_F if k in (PONT_ARC, SOUS_ARC) else 0)
        if k in MURS_P:
            v |= MUR_P
        if k == MURET:
            v |= MURET_F
        return v
    solb = [code(k) for k in range(NSORTES)]
    bloc('SolB', solb, False)
    # SolHi / SolLo : SolB du quartet haut / bas d'un octet, dans l'ordre signé
    bloc('SolHi', [solb[min((k ^ 0x80) >> 4, NSORTES - 1)] for k in range(256)], False)
    bloc('SolLo', [solb[min((k ^ 0x80) & 15, NSORTES - 1)] for k in range(256)], False)
    bloc('UniCel', [(g << 8) | at for g, at in (cellule([u, u, u], BITS_VUE) for u in range(16))], True)
    # MiniHi / MiniLo : la couleur (Mini) du quartet haut / bas d'un octet
    # de la carte, rangées dans l'ordre signé (l'octet b à l'indice b ^ $80)
    bloc('MiniHi', [T['Mini'][min((k ^ 0x80) >> 4, NSORTES - 1)] for k in range(256)], False)
    bloc('MiniLo', [T['Mini'][min((k ^ 0x80) & 15, NSORTES - 1)] for k in range(256)], False)
    bloc('UniMini', [(TAB_MOS[0] << 8) | 0x88 | (f << 4) for f in range(8)], True)
    bloc('Shl4', [0x80 | (f << 4) for f in range(8)], False)
    bloc('Facades', FACADES, False)
    bloc('TabMos', TAB_MOS, False)
    bloc('MarkT', [((j // 3) << 8) | (1 if j % 3 else 2) for j in range(SOUS + 1)], True)
    bloc('Fleches', FLECHES, False)
    bloc('TxtAide', list(aide_octets()) + [0], False)
    return '\n'.join(L) + '\n'


def png(e, fichier):
    from PIL import Image
    police = open(os.path.join(RACINE, 'video', 'font_osm39.bin'), 'rb').read()
    im = Image.new('RGB', (80 * 8, 30 * 16))
    px = im.load()

    def rgb(v, avant):
        k = 120 if (avant and v & 8) else 220
        v &= 7
        return ((v >> 2 & 1) * k, (v >> 1 & 1) * k, (v & 1) * k)
    for r in range(30):
        for x in range(80):
            o, a = e[r][x]
            for yy in range(16):
                ligne = police[(a >> 7) * 4096 + o * 16 + yy]
                for xx in range(8):
                    on = ligne & (0x80 >> xx)
                    px[x * 8 + xx, 16 * r + yy] = rgb(a & 15, True) if on else rgb((a >> 4) & 7, False)
    im.resize((im.width * 2, im.height * 2), Image.NEAREST).save(fichier)


def main():
    a = sys.argv[1:]
    if a[:1] == ['--inc']:
        open(os.path.join(RACINE, 'apps', 'osm3d_data.inc'), 'w').write(inc())
    elif a[:1] == ['--rues']:
        open(a[1], 'wb').write(fichier_rues())
    elif a[:1] == ['--carte']:
        open(a[1], 'wb').write(oc.fichier_carte(carte()))
    elif a[:1] == ['--png']:
        x, y, ang = int(a[1]), int(a[2]), int(a[3])
        png(ecran(carte(), x, 128, y, 128, ang), a[4])
        print(a[4])
    else:
        print(__doc__ or 'voir l\'en-tête')


if __name__ == '__main__':
    main()
