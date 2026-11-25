#!/usr/bin/env python3
# ===================================================================
# osmcity.py - La carte d'OSM City, tirée d'OpenStreetMap (Annonay)
# ===================================================================
# Données : donnees/annonay.json (API Overpass, le 21 nov. 2026 ; ODbL,
# « © contributeurs OpenStreetMap »). La zone est projetée en mètres puis
# découpée en LARG x HAUT cases (environ 2,45 m x 5,85 m : le rapport 1:2
# des cases de l'écran, le plan n'est pas déformé).
#
# Chaque catégorie (eau, parcs, bâtiments, routes selon leur largeur,
# chemins piétons) est dessinée dans un masque fin (SUR x SUR points par
# mètre... voir SX, SY), puis chaque case prend une sorte selon la part
# qu'elle couvre (priorités dans sorte()). Les axes des routes et des
# chemins sont aussi tracés case par case en 4-connexité : une rue en
# diagonale reste praticable.
#
#   python3 tools/osmcity/osmcity.py --apercu F.png   le plan entier
#   python3 tools/osmcity/osmcity.py --ecran X Y D F.png  l'écran 80 x 30
#                          (la voiture en X, Y, direction D : 0 N 1 E 2 S 3 O)
#   python3 tools/osmcity/osmcity.py --carte F   la carte (65 536 octets)
#   python3 tools/osmcity/osmcity.py --inc       apps/osmcity_data.inc
#   python3 tools/osmcity/osmcity.py --rues F    la grille des rues (8 Ko)
# Les glyphes (dessins, police de 32 Ko) : glyphes.py.
# ===================================================================
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glyphes as gl            # noqa: E402

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.normpath(os.path.join(ICI, '..', '..'))
DONNEES = os.path.join(ICI, 'donnees', 'annonay.json')
FONTE = os.path.join(RACINE, 'video', 'font_osm39.bin')

LARG, HAUT = 512, 255                   # 65 280 octets à 4 bits, pages 2-3 (64 Ko
                                        # pile : FS_LoadFile refuse, taille sur 16 bits)
S_, O_, N_, E_ = 45.2335, 4.6630, 45.2470, 4.6790      # la zone (degrés)
SX, SY = 10, 24                         # points du masque par case

# sortes de case
VIDE, ROUTE, PIETON, BATI, EAU, PARC, PONT, PLACE, TABLIER, SOUS_PONT, RAMPE, TALUS, FALAISE = \
    range(13)
NOMS = ['vide', 'route', 'piéton', 'bâti', 'eau', 'parc', 'pont', 'place', 'tablier',
        'sous-pont', 'rampe', 'talus', 'falaise']
NSORTES = 13
# FALAISE : une case d'herbe (VIDE, PARC, TALUS) qui fait avec une voisine
# une pente de plus de FAL_PENTE et une marche de plus de FAL_MARCHE mètres
# (relief de l'IGN, donnees/altitudes.bin) : hachures, elle arrête la voiture.
ALTITUDES = os.path.join(ICI, 'donnees', 'altitudes.bin')
FAL_PENTE, FAL_MARCHE = 0.7, 2.0
# Les ponts (voies bridge=yes) : PONT au-dessus de l'eau, TABLIER au-dessus
# du reste, SOUS_PONT au-dessus d'une rue ou d'un chemin (on passe dessous) ;
# RAMPE : une case de rue au bout d'un pont, voisine du tablier (on monte et
# on descend par là). TALUS : l'herbe près d'un tablier (3 cases en x, 2
# en y) : dessinée comme l'herbe, elle arrête la voiture (sans quoi on
# passait de la rue d'en dessous à la rampe par la pelouse).
TABLIERS = (PONT, TABLIER, SOUS_PONT)

# largeur (m) des routes pour les voitures, et des chemins piétons
ROUTES = {'primary': 11, 'secondary': 10, 'tertiary': 8, 'tertiary_link': 7,
          'residential': 7, 'unclassified': 7, 'living_street': 6,
          'road': 7, 'service': 4.5}
PIETONS = {'footway': 3, 'steps': 3, 'path': 2.5, 'pedestrian': 6,
           'track': 3, 'platform': 3}


def projection():
    lat0 = (S_ + N_) / 2
    kx = 111320 * math.cos(math.radians(lat0))
    ky = 110570
    w, h = (E_ - O_) * kx, (N_ - S_) * ky
    return kx, ky, w, h


def lit():
    d = json.load(open(DONNEES))
    noeuds = {e['id']: (e['lat'], e['lon']) for e in d['elements'] if e['type'] == 'node'}
    voies = [e for e in d['elements'] if e['type'] == 'way']
    return noeuds, voies


def simplifie(noeuds, voies, eps, pt):
    """Les voies (highway, ouvertes) tirées au cordeau : Douglas-Peucker
    de tolérance eps (unités de pt) entre les nœuds gardés d'office, ceux
    que plusieurs voies partagent (les carrefours) et les extrémités."""
    usage = {}
    for v in voies:
        if 'highway' in v.get('tags', {}):
            for i in set(v['nodes']):
                usage[i] = usage.get(i, 0) + 1

    def dp(ids):
        if len(ids) < 3:
            return ids
        (x0, y0), (x1, y1) = pt(noeuds[ids[0]]), pt(noeuds[ids[-1]])
        lg = math.hypot(x1 - x0, y1 - y0) or 1e-9
        loin, k = -1, 0
        for j in range(1, len(ids) - 1):
            x, y = pt(noeuds[ids[j]])
            d = abs((x1 - x0) * (y0 - y) - (x0 - x) * (y1 - y0)) / lg
            if d > loin:
                loin, k = d, j
        if loin <= eps:
            return [ids[0], ids[-1]]
        return dp(ids[:k + 1])[:-1] + dp(ids[k:])
    sortie = []
    for v in voies:
        ids = [i for i in v['nodes'] if i in noeuds]
        if 'highway' not in v.get('tags', {}) or len(ids) < 3 or ids[0] == ids[-1]:
            sortie.append(v)
            continue
        garde, debut = [ids[0]], 0
        for j in range(1, len(ids)):
            if j == len(ids) - 1 or usage.get(ids[j], 0) > 1:
                garde += dp(ids[debut:j + 1])[1:]
                debut = j
        sortie.append(dict(v, nodes=garde))
    return sortie


def carte(LARG=LARG, HAUT=HAUT, ELARGI=1.0, TROTTOIR=0.0, CORDEAU=0.0, ALLEES=False, FAIBLES=(),
          PIETONNES=False, RACCORDS=False):
    """La carte : HAUT lignes de LARG octets (sortes). LARG, HAUT : la
    finesse (même zone ; 512 x 256 pour la vue rapprochée). ELARGI : les
    voies (routes, chemins, ponts) tracées ELARGI fois plus larges ;
    TROTTOIR : un trottoir (PIETON) de TROTTOIR mètres de chaque côté des
    routes, sur le bâti seulement (OSM3D : des rues plus larges, des
    façades alignées sur la rue). CORDEAU : les voies simplifiées
    (simplifie(), tolérance CORDEAU mètres). ALLEES : les allées de
    parking (service=parking_aisle) tracées en parking (PLACE), pas en
    route. ELARGI et TROTTOIR peuvent être des dictionnaires par valeur de
    highway (absente : 1 et 0). FAIBLES : les valeurs de highway dont la
    chaussée cède au bâti (seul l'axe reste route) : dans la vieille ville,
    la rue prend la largeur laissée entre les bâtiments. PIETONNES : les
    zones piétonnes (highway piéton, area=yes) tracées en PIETON, pas en
    PLACE (la place des Cordeliers). RACCORDS : une rampe seulement sur
    l'axe d'une voie qui partage un nœud d'extrémité avec le pont (les 3
    premières cases depuis ce nœud) : une rue qui passe dessous n'en reçoit
    plus (l'avenue Simone Veil sous le pont Valgelas)."""
    def fois(hw):
        return ELARGI.get(hw, 1.0) if isinstance(ELARGI, dict) else ELARGI

    def trot(hw):
        return TROTTOIR.get(hw, 0.0) if isinstance(TROTTOIR, dict) else TROTTOIR
    kx, ky, w, h = projection()
    W, H = LARG * SX, HAUT * SY
    mx, my = W / w, H / h                   # points du masque par mètre

    def pt(n):
        lat, lon = n
        return ((lon - O_) * kx * mx, (N_ - lat) * ky * my)

    def case(n):
        x, y = pt(n)
        return int(x // SX), int(y // SY)
    noeuds, voies = lit()
    if CORDEAU:
        voies = simplifie(noeuds, voies, CORDEAU * (mx + my) / 2, pt)
    masques = {k: Image.new('L', (W, H), 0) for k in ('eau', 'parc', 'bati', 'route', 'pieton', 'place',
                                                       'pont') + (('trottoir',) if TROTTOIR else ())
                + (('faible',) if FAIBLES else ())}
    dessins = {k: ImageDraw.Draw(m) for k, m in masques.items()}
    axes_route, axes_pieton, axes_pont, bouts, bouts_id = [], [], [], [], []
    mm = (mx + my) / 2
    for v in voies:
        t = v.get('tags', {})
        pts = [pt(noeuds[i]) for i in v['nodes'] if i in noeuds]
        if len(pts) < 2:
            continue
        ferme = v['nodes'][0] == v['nodes'][-1] and len(pts) > 3
        if t.get('waterway') and (t.get('tunnel') or t.get('layer', '0').startswith('-')):
            continue                        # couvert (la Deûme sous l'avenue de l'Europe)
        if t.get('waterway') in ('river', 'stream', 'canal'):
            larg = 14 if t['waterway'] == 'river' else 4
            dessins['eau'].line(pts, fill=255, width=max(1, int(larg * mm)))
        elif t.get('natural') == 'water' and ferme:
            dessins['eau'].polygon(pts, fill=255)
        elif 'building' in t and ferme:
            dessins['bati'].polygon(pts, fill=255)
        elif (t.get('leisure') in ('park', 'garden', 'playground', 'pitch') or
              t.get('landuse') in ('grass', 'village_green', 'allotments', 'forest', 'meadow')) and ferme:
            dessins['parc'].polygon(pts, fill=255)
        elif t.get('amenity') == 'parking' and ferme:
            dessins['place'].polygon(pts, fill=255)
        elif (t.get('highway') in ROUTES or t.get('highway') in PIETONS) and \
                t.get('bridge') not in (None, 'no') and not t.get('layer', '1').startswith('-'):
            larg = (ROUTES.get(t['highway']) or PIETONS[t['highway']]) * fois(t['highway'])
            dessins['pont'].line(pts, fill=255, width=max(1, int(larg * mm)))
            axe = [case(noeuds[i]) for i in v['nodes'] if i in noeuds]
            axes_pont.append(axe)
            bouts += [axe[0], axe[-1]]
            bouts_id.extend((v['nodes'][0], v['nodes'][-1]))
        elif t.get('highway') in ROUTES:
            if t.get('area') == 'yes' and ferme:
                dessins['place'].polygon(pts, fill=255)
                continue
            if ALLEES and t.get('service') == 'parking_aisle':
                dessins['place'].line(pts, fill=255, width=max(1, int(ROUTES[t['highway']] * fois(t['highway']) * mm)))
                continue
            dessins['faible' if t['highway'] in FAIBLES else 'route'].line(
                pts, fill=255, width=max(1, int(ROUTES[t['highway']] * fois(t['highway']) * mm)))
            if trot(t['highway']):
                dessins['trottoir'].line(pts, fill=255,
                                       width=int((ROUTES[t['highway']] * fois(t['highway'])
                                                  + 2 * trot(t['highway'])) * mm))
            axes_route.append([case(noeuds[i]) for i in v['nodes'] if i in noeuds])
        elif t.get('highway') in PIETONS or t.get('railway') == 'abandoned':
            if t.get('area') == 'yes' and ferme:
                dessins['pieton' if PIETONNES else 'place'].polygon(pts, fill=255)
                continue
            larg = PIETONS.get(t.get('highway'), 3) * fois(t.get('highway'))
            dessins['pieton'].line(pts, fill=255, width=max(1, int(larg * mm)))
            axes_pieton.append([case(noeuds[i]) for i in v['nodes'] if i in noeuds])
    part = {}
    for k, m in masques.items():
        a = np.asarray(m, dtype=np.float32) / 255
        part[k] = a.reshape(HAUT, SY, LARG, SX).mean(axis=(1, 3))
    axe_r = np.zeros((HAUT, LARG), bool)
    axe_p = np.zeros((HAUT, LARG), bool)
    axe_t = np.zeros((HAUT, LARG), bool)
    for axes, cible in ((axes_route, axe_r), (axes_pieton, axe_p), (axes_pont, axe_t)):
        for poly in axes:
            for (x0, y0), (x1, y1) in zip(poly, poly[1:]):
                for x, y in ligne4(x0, y0, x1, y1):
                    if 0 <= x < LARG and 0 <= y < HAUT:
                        cible[y, x] = True
    c = np.zeros((HAUT, LARG), np.uint8)
    for y in range(HAUT):
        for x in range(LARG):
            c[y, x] = sorte({k: p[y, x] for k, p in part.items()}, axe_r[y, x], axe_p[y, x],
                            axe_t[y, x])
    if TROTTOIR:
        c[(c == BATI) & (part['trottoir'] >= 0.35)] = PIETON
    # les rampes : au bout de chaque pont (2 cases en x, 1 en y du nœud
    # d'extrémité), les cases de rue qui touchent le tablier
    raccord = None
    if RACCORDS:
        raccord = set()
        for v in voies:
            t = v.get('tags', {})
            if not (t.get('highway') in ROUTES or t.get('highway') in PIETONS) or \
                    t.get('bridge') not in (None, 'no'):
                continue
            ids = [i for i in v['nodes'] if i in noeuds]
            for k, i in enumerate(ids):
                if i not in bouts_id:
                    continue
                for q in (k - 1, k + 1):
                    if 0 <= q < len(ids):
                        (x0, y0), (x1, y1) = case(noeuds[i]), case(noeuds[ids[q]])
                        raccord.update(ligne4(x0, y0, x1, y1)[:3])
    for bx, by in bouts:
        for y in range(by - 1, by + 2):
            for x in range(bx - 2, bx + 3):
                if raccord is not None and (x, y) not in raccord:
                    continue
                if 0 <= x < LARG and 0 <= y < HAUT and c[y, x] in (ROUTE, PIETON, PLACE) and \
                        any(0 <= x + dx < LARG and 0 <= y + dy < HAUT and c[y + dy, x + dx] in TABLIERS
                            for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0))):
                    c[y, x] = RAMPE
    for y, x in zip(*np.nonzero(np.isin(c, TABLIERS))):
        for yy in range(y - 2, y + 3):
            for xx in range(x - 3, x + 4):
                if 0 <= xx < LARG and 0 <= yy < HAUT and c[yy, xx] in (VIDE, PARC):
                    c[yy, xx] = TALUS
    if LARG == 512 and os.path.exists(ALTITUDES):
        alt = np.frombuffer(open(ALTITUDES, 'rb').read(), dtype='>i2').reshape(HAUT, LARG) / 10.0
        kx, ky, w, h = projection()
        herbe = np.isin(c, (VIDE, PARC, TALUS))
        fal = np.zeros_like(herbe)
        for dy, dx, d in ((0, 1, w / LARG), (1, 0, h / HAUT)):
            a, b = alt[:HAUT - dy, :LARG - dx], alt[dy:, dx:]
            raide = (np.abs(a - b) / d > FAL_PENTE) & (np.abs(a - b) > FAL_MARCHE)
            fal[:HAUT - dy, :LARG - dx] |= raide & herbe[:HAUT - dy, :LARG - dx]
            fal[dy:, dx:] |= raide & herbe[dy:, dx:]
        c[fal] = FALAISE
    return c


def sorte(p, axe_r, axe_p, axe_t=False):
    """La sorte d'une case d'après la part de chaque masque (0..1)."""
    if axe_t or p['pont'] >= 0.35:
        if axe_r or axe_p or p['route'] >= 0.35 or p['pieton'] >= 0.35:
            return SOUS_PONT
        return PONT if p['eau'] >= 0.3 else TABLIER
    if axe_r or p['route'] >= 0.35:
        return ROUTE
    if axe_p or p['pieton'] >= 0.35:
        return PIETON
    if p['eau'] >= 0.4:
        return EAU
    if p['bati'] >= 0.45:
        return BATI
    if p.get('faible', 0) >= 0.35:
        return ROUTE
    if p['place'] >= 0.4:
        return PLACE
    if p['parc'] >= 0.4:
        return PARC
    return VIDE


def ligne4(x0, y0, x1, y1):
    """Les cases d'un segment, chacune voisine de la précédente par un côté."""
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx, sy = (1 if x1 >= x0 else -1), (1 if y1 >= y0 else -1)
    x, y, err = x0, y0, dx - dy
    pts = [(x, y)]
    while (x, y) != (x1, y1):
        e2 = 2 * err
        if e2 > -dy and (x != x1):
            err -= dy
            x += sx
        elif y != y1:
            err += dx
            y += sy
        else:
            err -= dy
            x += sx
        pts.append((x, y))
    return pts


# ===================================================================
# Les noms des rues : la grille RUES_BL x RUES_BL cases -> le numéro (1..)
# du nom de la rue dominante du bloc (0 : aucune), d'après les axes des
# voies nommées tracés case par case ; les noms en CP437 (la page 0 de la
# police). Le jeu montre le nom du bloc de la voiture ; un bloc à 0 garde
# la plaque.
# ===================================================================
RUES_BL = 4
RUES_L, RUES_H = LARG // RUES_BL, (HAUT + RUES_BL - 1) // RUES_BL      # 128 x 64
PLQ_ATTR = 0x17                         # blanc sur bleu, page 0 : une plaque de rue
PLQ_R = 29


def rues():
    """(noms, grille) : noms[i - 1] = le nom n° i (octets CP437) ; grille :
    RUES_H rangées de RUES_L octets."""
    kx, ky, w, h = projection()
    noeuds, voies = lit()

    def case(n):
        lat, lon = n
        return int((lon - O_) * kx / w * LARG), int((N_ - lat) * ky / h * HAUT)
    noms, num = [], {}
    cases = np.zeros((HAUT, LARG), np.int32)
    for v in voies:
        tg = v.get('tags', {})
        if 'highway' not in tg or 'name' not in tg:
            continue
        nom = tg['name']
        if nom not in num:
            noms.append(nom.encode('cp437'))
            num[nom] = len(noms)
        poly = [case(noeuds[i]) for i in v['nodes'] if i in noeuds]
        for (x0, y0), (x1, y1) in zip(poly, poly[1:]):
            for x, y in ligne4(x0, y0, x1, y1):
                if 0 <= x < LARG and 0 <= y < HAUT and not cases[y, x]:
                    cases[y, x] = num[nom]
    assert len(noms) < 256
    grille = np.zeros((RUES_H, RUES_L), np.uint8)
    for by in range(RUES_H):
        for bx in range(RUES_L):
            bloc = cases[by * RUES_BL:(by + 1) * RUES_BL, bx * RUES_BL:(bx + 1) * RUES_BL].flatten()
            ids = [int(i) for i in bloc if i]
            if ids:
                grille[by, bx] = max(sorted(set(ids)), key=ids.count)     # le plus fréquent, le plus petit
    return noms, grille


def cands(c):
    """NCANDS cases pour le butin et la planque : rue ou parking, au sol,
    avec un nom de rue, réparties (graine fixe)."""
    import random
    al = random.Random(7)
    _, grille = rues()
    cs = [(x, y) for y in range(2, HAUT - 2) for x in range(2, LARG - 2)
          if c[y, x] in (ROUTE, PLACE) and grille[y // RUES_BL, x // RUES_BL]]
    al.shuffle(cs)
    pris = []
    for x, y in cs:
        if all(abs(x - a) + 2 * abs(y - b) >= 40 for a, b in pris):
            pris.append((x, y))
        if len(pris) == NCANDS:
            break
    return pris


def fleche_vers(dx, dy):
    """La direction (0-7) d'un objectif en (dx, dy) cases : en mètres, une
    case est ~2,5 fois plus haute que large (dy x 5 / 2)."""
    dyw = (dy * 5) >> 1 if dy >= 0 else -((-dy * 5) >> 1)
    ax, ay = abs(dx), abs(dyw)
    if ax > 2 * ay:
        return 2 if dx > 0 else 6
    if ay > 2 * ax:
        return 4 if dyw > 0 else 0
    if dx > 0:
        return 3 if dyw > 0 else 1
    return 5 if dyw > 0 else 7


def plaque_cases(nom):
    """La plaque : (colonne de départ, [(glyphe, attribut)...]) : le nom
    entouré d'une espace, centré."""
    txt = b' ' + nom + b' '
    return 40 - len(txt) // 2, [(o, PLQ_ATTR) for o in txt]


# ===================================================================
# Les tuiles : le glyphe (page 1 de la banque 1) et l'attribut d'une case,
# d'après sa sorte et ses quatre voisines. Le jeu (apps/osmcity.asm, Tuile)
# fait exactement la même chose, par les tables écrites par --inc :
#   FAMILLE[s] : les voisines d'une autre famille font un bord (masque N=1,
#                E=2, S=4, O=8) ;
#   GENRE[s]   : 0 = BASE + masque ; 1 = place (avec un bord : route +
#                masque ; sinon y pair : BASE, une place ; y impair :
#                l'allée, « P » si x & 15 = 0) ; 2 = tablier (garde-corps :
#                masque des voisines GARDE) ; 3 = herbe (arbre si (x+y) & 3 = 0 dans
#                un parc, sinon HERBE + ((x - y) & 3)).
# Attribut : D0-D2 premier plan, D3 atténué, D4-D6 fond, D7 page 1.
# ===================================================================
FAMILLE = {VIDE: 0, ROUTE: 1, PIETON: 2, BATI: 3, EAU: 4, PARC: 0, PONT: 1, PLACE: 1,
           TABLIER: 1, SOUS_PONT: 1, RAMPE: 1, TALUS: 0, FALAISE: 0}
GENRE = {VIDE: 3, ROUTE: 0, PIETON: 0, BATI: 0, EAU: 0, PARC: 3, PONT: 2, PLACE: 1,
         TABLIER: 2, SOUS_PONT: 2, RAMPE: 0, TALUS: 3, FALAISE: 0}
BASE = {VIDE: gl.G_HERBE, ROUTE: gl.G_ROUTE, PIETON: gl.G_PIETON, BATI: gl.G_BATI,
        EAU: gl.G_EAU, PARC: gl.G_HERBE, PONT: gl.G_PONT, PLACE: gl.G_PLACE,
        TABLIER: gl.G_PONT, SOUS_PONT: gl.G_PONT, RAMPE: gl.G_ROUTE, TALUS: gl.G_HERBE,
        FALAISE: gl.G_FALAISE}
ATTR = {VIDE: 0xAA, ROUTE: 0x8F, PIETON: 0x8F, BATI: 0xC6, EAU: 0x93, PARC: 0xAA,
        PONT: 0x87, PLACE: 0x8F, TABLIER: 0x87, SOUS_PONT: 0x87, RAMPE: 0x8F, TALUS: 0xAA,
        FALAISE: 0xA8}
# la couleur de chaque sorte (pour les coins arrondis : le premier plan
# d'une case de coin, le fond de ses voisines exposées)
COUL = {VIDE: 2, ROUTE: 0, PIETON: 0, BATI: 4, EAU: 1, PARC: 2, PONT: 0, PLACE: 0,
        TABLIER: 0, SOUS_PONT: 0, RAMPE: 0, TALUS: 2, FALAISE: 2}
COIN = {m: k + 1 for k, m in enumerate(gl.COINS)}      # masque -> 1..4 (0 : pas un coin)
# un tablier a un garde-corps du côté d'une voisine qui n'est ni un tablier
# ni une rampe
GARDE = {s: (s not in TABLIERS and s != RAMPE) for s in range(NSORTES)}
VOISINES = ((1, 0, -1), (2, 1, 0), (4, 0, 1), (8, -1, 0))


def sorte_xy(c, x, y):
    if 0 <= x < LARG and 0 <= y < HAUT:
        return int(c[y, x])
    return BATI


def tuile(c, x, y):
    """(glyphe, attribut) de la case x, y. Genres 0 et 3 : une case de coin
    (deux côtés voisins exposés, ces deux voisines de la même couleur,
    autre que la sienne) est arrondie : G_COIN, sa couleur en premier plan
    (8 pour le noir : pas de premier plan à 0), la leur en fond."""
    s = sorte_xy(c, x, y)
    gen = GENRE[s]
    m, nc = 0, None
    for bit, dx, dy in VOISINES:
        v = sorte_xy(c, x + dx, y + dy)
        if GARDE[v] if gen == 2 else (FAMILLE[v] != FAMILLE[s]):
            m |= bit
            nc = COUL[v] if nc is None or nc == COUL[v] else -1
    if gen in (0, 3) and COIN.get(m) and nc not in (None, -1) and nc != COUL[s]:
        return gl.G_COIN + COIN[m] - 1, 0x80 | (nc << 4) | (COUL[s] or 8)
    if gen == 3:
        if s == PARC and (x + y) & 3 == 0:
            return gl.G_ARBRE, ATTR[s]
        return gl.G_HERBE + ((x - y) & 3), ATTR[s]
    if gen == 1:
        if m:
            return gl.G_ROUTE + m, ATTR[s]
        if y & 1 == 0:
            return BASE[s], ATTR[s]
        return (gl.G_P if x & 15 == 0 else gl.G_ROUTE), ATTR[s]
    return BASE[s] + m, ATTR[s]


def apercu(c, fichier):
    pal = {VIDE: (40, 70, 40), ROUTE: (20, 20, 20), PIETON: (150, 150, 150), BATI: (190, 70, 40),
           EAU: (40, 90, 220), PARC: (40, 160, 40), PONT: (230, 230, 230), PLACE: (110, 110, 110),
           TABLIER: (230, 230, 230), SOUS_PONT: (255, 255, 0), RAMPE: (255, 0, 255),
           TALUS: (80, 120, 40), FALAISE: (120, 90, 40)}
    im = Image.new('RGB', (c.shape[1], c.shape[0]))
    im.putdata([pal[v] for v in c.flatten()])
    im.resize((c.shape[1] * 2, c.shape[0] * 4), Image.NEAREST).save(fichier)


# ===================================================================
# La conduite : le modèle exact (apps/osmcity.asm fait la même chose, au
# bit près ; test/verifie_osmcity.py compare). Une trame = un pas.
#   état : x, y (case), d (0 nord, 1 est, 2 sud, 3 ouest), v (0..VMAX),
#          acc (avance accumulée), s (adresse de départ, en cases, mod 4096)
#   voulu : la flèche (0-3) ou None (plusieurs : haut, droite, bas, gauche).
# Une case fait ~2,45 m de large et ~5,85 m de haut : en vertical, l'avance
# est v x 107 / 256 (le rapport des deux). Une case quand acc atteint PAS.
# La voiture : colonne 40 (nord, sud), colonnes 39-40 (est, ouest), rangée 15.
# ===================================================================
VMAX, VLENT, PAS = 160, 48, 640
ACCEL, FROTTE, FREIN, RALENTI = 2, 1, 4, 4
LENT = (VIDE, PARC, PIETON)
BLOQUE = (BATI, EAU, TALUS, FALAISE, VIDE)    # VIDE : en ville, des jardins clos
# 8 directions : 0 nord, 1 nord-est, 2 est, 3 sud-est, 4 sud, 5 sud-ouest,
# 6 ouest, 7 nord-ouest. En biais, chaque axe reçoit v x DIAG / 256.
DX, DY = (0, 1, 1, 1, 0, -1, -1, -1), (-1, -1, 0, 1, 1, 1, 0, -1)
DIAG = 181
# glyphes de la voiture en colonnes 39 et 40 (None : la tuile), par direction
V = gl.G_VOIT
D = gl.G_VOITD
VOIT_G = ((None, V), (D, D + 1), (V + 2, V + 3), (D + 2, D + 3), (None, V + 1), (D + 4, D + 5),
          (V + 4, V + 5), (D + 6, D + 7), (None, gl.G_PIETONNE),     # 8 : un passant
          (None, gl.G_BUTIN), (None, gl.G_PLANQUE))                  # 9, 10 : les objets


def voulu_de(haut, droite, bas, gauche):
    """La direction voulue d'après les flèches tenues (haut et bas, ou
    gauche et droite, s'annulent), ou None."""
    dx = (1 if droite else 0) - (1 if gauche else 0)
    dy = (1 if bas else 0) - (1 if haut else 0)
    if dx == 0 and dy == 0:
        return None
    return [k for k in range(8) if DX[k] == dx and DY[k] == dy][0]
VOIT_ATTR = 0x80                         # page 1 (fond : la case ; premier plan : sa couleur)
COUL_JOUEUR = 6                          # la voiture du départ : jaune
PIED_COUL = 7                            # le piéton : blanc
VPIED = 48                               # la vitesse à pied (constante, sans élan)
NGAREES = 32                             # les places de la liste des voitures garées
COULEURS = (4, 7, 3, 5, 2, 1)            # rouge, blanc, cyan, magenta, vert, bleu
# la circulation : NMOB_V voitures et NMOB_P passants autour du joueur ;
# trop loin (MOB_LOIN_X, MOB_LOIN_Y), ils réapparaissent juste hors de
# l'écran. Une voiture avance à chaque trame sur 8 (en vertical : une fois
# sur deux), un passant une sur 16 ; pas de trame de circulation quand
# l'écran défile (le joueur a fait un pas).
# Le 6309 ne connaît que les rangées y - 16 .. y + 15 (l'anneau) : la
# circulation y vit (hors de ces rangées : un mur, ou trop loin).
NMOB_V, NMOB_P = 8, 8
MOB_LOIN_X, MOB_HAUT, MOB_BAS = 52, -16, 15
MOB_ROUTES = (ROUTE, PLACE, RAMPE, SOUS_PONT)
COUL_MOB_V = (4, 7, 3, 5, 2, 1, 4, 3)
# conduite : une rue qui part de côté = OUV_V rangées (côté nord ou sud)
# ou OUV_H colonnes (est, ouest) de chaussée ; tourner : un tirage < VIRAGE
# (côté : bit 0) ; se garer sur une place : un tirage >= GARER
OUV_V, OUV_H = 3, 6
VIRAGE, GARER = 0x30, 0xF0
# bloquée devant : attendre ATT_DOUBLE pas, puis doubler (en biais, à
# gauche puis à droite) ; après ATT_DEMI pas, faire demi-tour
ATT_DOUBLE, ATT_DEMI = 2, 6
# coincée plus de ATT_FIN pas hors de l'écran : elle disparaît (réapparaîtra)
ATT_FIN = 24
# serrer à droite seulement dans une rue : à droite, 1 à LARGE_V rangées
# ou 1 à LARGE_H colonnes de chaussée (plus large : une place, tout droit)
LARGE_V, LARGE_H = 2, 3
COUL_MOB_P = (3, 5, 2, 6, 3, 5, 2, 6)
ALEA0 = 0x5A
# Le son (l'AY) : A le moteur (en voiture : période 1000 - 5 v, volume 8 +
# v / 32) ; B le klaxon (touche K : 262 / 208 toutes les 8 trames) ou un
# bruitage (du bruit qui s'éteint : volume - 2 par trame) ; C libre.
# EFFETS : type -> (trames, période du bruit, volume) ; un bruitage en
# remplace un autre s'il est au moins aussi fort, ou si l'autre est fini.
EF_PAS, EF_PORTE, EF_CHOC = 1, 2, 3
EFFETS = {EF_PAS: (2, 3, 7), EF_PORTE: (6, 12, 13), EF_CHOC: (12, 24, 15)}
CHOC_V = 48                              # le choc : arrêté net à cette vitesse ou plus
KLAX_A, KLAX_B = 262, 208
R7_KLAX, R7_BRUIT, R7_RIEN = 0x3C, 0x2E, 0x3E   # tons A (+ B), bruit B ; C coupé
AY_REGS = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
# ===================================================================
# Le cache-cache. Phases : VOL (aller au butin), FUITE (la police chasse ;
# aller à la planque), ARRETE, GAGNE (tout s'arrête ; Espace : une autre
# partie). Butin et planque tirés au sort parmi CANDS (une planque à au
# moins DIST_PLANQUE du butin : |dx| + 2 |dy|), dessinés comme des objets
# (directions 9, 10). Deux voitures de police (mobiles 16, 17) : patrouille
# (comme la circulation), chasse (vers le joueur vu), recherche (vers où il
# a été vu, PERDU_MAX pas au plus) ; une trame sur 4 chacune ; elles voient
# à VUE_X, VUE_Y cases si le joueur n'est pas sous un pont et qu'il a
# l'apparence signalée (sa couleur, 8 à pied) ou qu'il est tout près.
# ===================================================================
VOL, FUITE, ARRETE, GAGNE = range(4)
NPOLICE = 2
PATROUILLE, CHASSE, RECHERCHE = range(3)
VUE_X, VUE_Y, PRES_X, PRES_Y = 24, 10, 4, 2
PERDU_MAX = 120
DIST_PLANQUE = 120
NCANDS = 64
COUL_POLICE, COUL_GYRO = 7, 1
# la police garée devant la mairie (rue de l'Hôtel-de-Ville) : x, y, direction
POSTE = ((142, 129, 2), (146, 129, 2))
SIRENE_A, SIRENE_B = 265, 198
PLQ_FUITE = 0x47                         # blanc sur rouge
PLQ_FIN = {ARRETE: (0x47, 'ARRETE ! Espace : rejouer'), GAGNE: (0x27, 'BRAVO ! Espace : rejouer')}
# sortir (Espace, à l'arrêt) : le piéton sur la première case libre de :
SORTIES = ((0, -1), (0, 1), (1, 0), (-1, 0), (1, -1), (-1, -1), (1, 1), (-1, 1))
CENTRE_C, CENTRE_R = 40, 15


def depart(c):
    """La case de route la plus proche du centre du plan."""
    best = None
    for y in range(HAUT):
        for x in range(LARG):
            if c[y, x] == ROUTE:
                dd = (x - LARG // 2) ** 2 + 4 * (y - HAUT // 2) ** 2
                if best is None or dd < best[0]:
                    best = (dd, x, y)
    return best[1], best[2]


def passe(c, x0, y0, x1, y1, niv):
    """La voiture, à l'étage niv (0 sol, 1 pont) en (x0, y0), peut-elle
    aller en (x1, y1) ? Rend son étage d'arrivée, ou None. Sur un tablier
    on arrive d'un tablier (étage 1) ou d'une rampe (on monte) ; au sol,
    seul SOUS_PONT se traverse (dessous). Du tablier on ne descend que sur
    une rampe."""
    s1 = sorte_xy(c, x1, y1)
    if s1 in BLOQUE:
        return None
    if s1 in TABLIERS:
        if niv == 1 or sorte_xy(c, x0, y0) == RAMPE:
            return 1
        return 0 if s1 == SOUS_PONT else None
    if niv == 1:
        return 0 if s1 == RAMPE else None
    return 0


def garees_depart(c):
    """Les voitures garées au départ : [x, y, d, couleur, étage, libre] x
    NGAREES. Une à 2-5 cases du départ (pour en changer vite), les autres
    au hasard (graine fixe) sur les rues et les parkings, espacées ; dans le
    sens de la rue (est/ouest si la rue continue à gauche et à droite)."""
    import random
    al = random.Random(39)
    x0, y0 = depart(c)

    def bonne(x, y):
        return 1 <= x < LARG - 1 and 0 <= y < HAUT and c[y, x] in (ROUTE, PLACE)

    def sens(x, y):
        if bonne(x - 1, y) and bonne(x + 1, y):
            return al.choice((2, 6))
        return al.choice((0, 4))
    cand = [(x, y) for y in range(1, HAUT - 1) for x in range(2, LARG - 2) if bonne(x, y)]
    al.shuffle(cand)
    pres = sorted(((x, y) for x, y in cand if 2 <= max(abs(x - x0), 2 * abs(y - y0)) <= 5
                   and (x, y) != (x0, y0)), key=lambda q: (abs(q[0] - x0) + abs(q[1] - y0), q))
    garees = []

    def libre_pour(x, y, d):
        cases = [(x - 1, y), (x, y)] if VOIT_G[d][0] is not None else [(x, y)]
        if not all(bonne(*q) for q in cases) or (x0, y0) in cases or (x0 - 1, y0) in cases:
            return False
        return all(abs(x - g[0]) >= 12 or abs(y - g[1]) >= 5 for g in garees)
    for x, y in pres[:1] + cand:
        if len(garees) == NGAREES - 1:
            break
        d = sens(x, y)
        if libre_pour(x, y, d):
            garees.append([x, y, d, COULEURS[len(garees) % len(COULEURS)], 0, False])
    garees.append([0, 0, 0, 0, 0, True])        # une place libre : la voiture qu'on quitte
    return garees


def cases_voiture(x, y, d):
    """Les cases d'une voiture : (x, y), et (x - 1, y) en est-ouest et en biais."""
    return [(x - 1, y), (x, y)] if VOIT_G[d][0] is not None else [(x, y)]


class Jeu:
    def __init__(self, c, rues_=None, cands_=None, depart_=None):
        self.c = c
        self.noms, self.grille = rues_ if rues_ is not None else rues()
        self.x, self.y = depart_ if depart_ is not None else depart(c)
        self.d, self.v, self.ax, self.ay, self.s = 0, 0, 0, 0, 0
        self.plaque = int(self.grille[self.y // RUES_BL, self.x // RUES_BL])   # la rue du départ
        self.niv = 0                    # l'étage : 0 sol, 1 sur un pont
        self.pied = False               # à pied (sinon en voiture)
        self.coul = COUL_JOUEUR         # la couleur de la voiture qu'on conduit
        self.garees = garees_depart(c)
        # la circulation : même format que garees (direction 8 : un passant)
        self.mobiles = [[0, 0, 8, 0, 0, True] for _ in range(NMOB_V + NMOB_P)]
        self.phase = [0] * (NMOB_V + NMOB_P)    # voitures : le pas vertical, une fois sur deux
        self.pdir = [0] * (NMOB_V + NMOB_P)     # passants : leur direction (0, 2, 4, 6)
        self.att = [0] * (NMOB_V + NMOB_P + NPOLICE)   # voitures : les pas attendus
        self.alea_ = ALEA0                       # le hasard : LFSR 8 bits ($B8)
        self.tmob = 0                            # le compteur de la circulation
        self.bt, self.bty, self.bv, self.bp = 0, 0, 0, 0   # le bruitage en cours
        self.trame = 0
        self.ayr = {}                            # les registres de l'AY de la trame
        self.mobiles += [[0, 0, 0, COUL_POLICE, 0, True] for _ in range(NPOLICE)]
        self.phase += [0] * NPOLICE
        self.pdir += [0] * NPOLICE
        self.pmode = [PATROUILLE] * NPOLICE
        self.pcible = [(0, 0)] * NPOLICE
        self.pperdu = [0] * NPOLICE
        self.signal = 0                          # l'apparence signalée
        self.pcoul = COUL_POLICE
        self.cands = cands_ if cands_ is not None else cands(c)
        self.objets = [[0, 0, 9, 6, 0, True], [0, 0, 10, 2, 0, True]]
        self.etape = VOL
        self.nouvelle_partie()

    def tous(self):
        return self.garees + self.mobiles + self.objets

    def nouvelle_partie(self):
        """Butin et planque au hasard, la police remise en patrouille."""
        b = self.cands[self.alea() & (NCANDS - 1)]
        for _ in range(8):
            q = self.cands[self.alea() & (NCANDS - 1)]
            if abs(q[0] - b[0]) + 2 * abs(q[1] - b[1]) >= DIST_PLANQUE:
                break
        self.objets[0][:] = [b[0], b[1], 9, 6, 0, False]
        self.objets[1][:] = [q[0], q[1], 10, 2, 0, False]
        self.etape = VOL
        for k in range(NPOLICE):                # la police au poste
            self.mobiles[NMOB_V + NMOB_P + k][:] = [POSTE[k][0], POSTE[k][1], POSTE[k][2], COUL_POLICE, 0, False]
            self.pmode[k] = PATROUILLE

    def apparence(self):
        return 8 if self.pied else self.coul

    def touche(self, x, y):
        """La case (x, y) touche-t-elle le joueur (8 voisines) ?"""
        return any(max(abs(x - a), abs(y - b)) <= 1 for a, b in self.cases_joueur())

    def objectif(self):
        return self.objets[0] if self.etape == VOL else self.objets[1]

    def bilan(self):
        """Après un mouvement : le butin pris, la planque atteinte, une
        voiture de police au contact."""
        if self.etape == VOL and self.touche(*self.objets[0][:2]):
            self.etape = FUITE
            self.objets[0][5] = True
            self.signal = self.apparence()
            for k in range(NPOLICE):
                self.pmode[k] = CHASSE
                self.pcible[k] = (self.x, self.y)
                self.pperdu[k] = 0
        elif self.etape == FUITE and self.touche(*self.objets[1][:2]):
            self.etape = GAGNE
        if self.etape == FUITE:
            for k in range(NPOLICE):
                pm = self.mobiles[NMOB_V + NMOB_P + k]
                if not pm[5] and any(self.touche(*q) for q in cases_voiture(pm[0], pm[1], pm[2])):
                    self.etape = ARRETE

    def occupe(self, x, y, sauf=None):
        """Une voiture garée, une voiture ou un passant de la circulation
        (sauf l'entrée sauf) occupe-t-il la case (x, y) ?"""
        return any(g is not sauf and not g[5] and (x, y) in cases_voiture(g[0], g[1], g[2])
                   for g in self.tous())

    def cases_joueur(self):
        return [(self.x, self.y)] if self.pied else cases_voiture(self.x, self.y, self.d)

    def alea(self):
        r = self.alea_
        self.alea_ = (r >> 1) ^ (0xB8 if r & 1 else 0)
        return self.alea_

    def population(self):
        """Une trame de circulation : la voiture tmob & 7, et (tmob impair)
        le passant 8 + (tmob / 2) & 7 ; la police tmob & 3 (si < NPOLICE)."""
        t = self.tmob
        self.tick(t & 7)
        if t & 1:
            self.tick(8 + ((t >> 1) & 7))
        if (t & 3) < NPOLICE:
            self.tick(NMOB_V + NMOB_P + (t & 3))
            self.bilan()
        self.tmob = (t + 1) & 255

    def dans_zone(self, x, y):
        """Là où le 6309 connaît la carte (les rangées de l'anneau)."""
        return abs(x - self.x) <= MOB_LOIN_X and MOB_HAUT <= y - self.y <= MOB_BAS

    def tick(self, i):
        m = self.mobiles[i]
        if i >= NMOB_V + NMOB_P:                # la police : garée tant qu'il n'y a pas de vol
            if self.etape != FUITE:
                return
            k = i - NMOB_V - NMOB_P
            dehors = not self.dans_zone(m[0], m[1])
            if dehors or any(sorte_xy(self.c, *q) not in MOB_ROUTES for q in cases_voiture(m[0], m[1], m[2])):
                self.aveugle(k, dehors)
            else:
                self.police_tick(k)
            return
        if m[5] or abs(m[0] - self.x) > MOB_LOIN_X or not MOB_HAUT <= m[1] - self.y <= MOB_BAS:
            self.apparait(i)
        elif i >= NMOB_V + NMOB_P:
            self.police_tick(i - NMOB_V - NMOB_P)
        elif i < NMOB_V:
            self.roule(i)
        else:
            self.flane(i)

    def police_tick(self, k):
        """Voir, puis rouler : patrouille (au hasard), sinon vers la cible
        (de N, E, S, O, la case permise la plus proche : |dx| + 2 |dy|)."""
        i = NMOB_V + NMOB_P + k
        m = self.mobiles[i]
        if self.etape == FUITE:
            dx, dy = abs(self.x - m[0]), abs(self.y - m[1])
            cache = self.niv == 0 and sorte_xy(self.c, self.x, self.y) == SOUS_PONT
            app = self.apparence()
            if dx <= VUE_X and dy <= VUE_Y and not cache and (
                    app == self.signal or (dx <= PRES_X and dy <= PRES_Y)):
                self.pmode[k] = CHASSE
                self.pcible[k] = (self.x, self.y)
                self.pperdu[k] = 0
                self.signal = app
            elif self.pmode[k] == CHASSE:
                self.pmode[k] = RECHERCHE
                self.pperdu[k] = 0
        # le gyrophare : la couleur prise en avançant (c'est là qu'elle est redessinée)
        self.pcoul = COUL_GYRO if self.pmode[k] != PATROUILLE and self.trame & 8 else COUL_POLICE
        if self.pmode[k] == PATROUILLE:
            self.roule(i)
            return
        self.phase[i] ^= 1
        tx, ty = self.pcible[k]
        # les directions permises (en vertical une fois sur deux) ; pas de
        # demi-tour, sauf s'il n'y a que lui ; la plus proche de la cible
        # si elle rapproche, sinon une au hasard (contourner l'obstacle)
        poss = [nd for nd in (0, 2, 4, 6) if not (nd in (0, 4) and self.phase[i])
                and self.mob_libre(i, m[0] + DX[nd], m[1] + DY[nd], nd)]
        avant = [nd for nd in poss if nd != (m[2] + 4) % 8] or poss
        if avant:
            cout = [abs(tx - m[0] - DX[nd]) + 2 * abs(ty - m[1] - DY[nd]) for nd in avant]
            k_ = cout.index(min(cout))
            if cout[k_] >= abs(tx - m[0]) + 2 * abs(ty - m[1]):
                k_ = self.alea() % len(avant)
            self.essaie(i, avant[k_], avant[k_])
        if self.pmode[k] == RECHERCHE:
            self.pperdu[k] += 1
            if abs(tx - m[0]) + abs(ty - m[1]) <= 1 or self.pperdu[k] > PERDU_MAX:
                self.pmode[k] = PATROUILLE

    def aveugle(self, k, dehors):
        """La police hors de la carte connue (ou hors des rues) : un pas
        vers la cible sans carte (en vertical une fois sur deux) ; elle
        n'entre dans la zone que sur des cases libres, sinon de côté."""
        i = NMOB_V + NMOB_P + k
        m = self.mobiles[i]
        if self.pmode[k] == CHASSE:
            self.pmode[k] = RECHERCHE
            self.pperdu[k] = 0
        tx, ty = self.pcible[k]
        if self.pmode[k] == RECHERCHE and abs(tx - m[0]) + abs(ty - m[1]) <= 1:
            self.pmode[k] = PATROUILLE
        self.pcoul = COUL_GYRO if self.pmode[k] != PATROUILLE and self.trame & 8 else COUL_POLICE
        if self.pmode[k] == PATROUILLE:
            tx, ty = self.x, self.y
        self.phase[i] ^= 1
        dv = 4 if ty > m[1] else 0 if ty < m[1] else None
        dh = 2 if tx > m[0] else 6 if tx < m[0] else None
        if dv is not None and (self.phase[i] or dh is None):
            d = dv
        elif dh is not None:
            d = dh
        else:
            return

        def bloque(d):
            nx, ny = m[0] + DX[d], m[1] + DY[d]
            return dehors and self.dans_zone(nx, ny) and not self.mob_libre(i, nx, ny, d)
        if bloque(d):
            if d in (0, 4):
                d = dh if dh is not None else (2 if self.alea() & 0x80 else 6)
            else:
                d = dv if dv is not None else (4 if self.alea() & 0x80 else 0)
            if bloque(d):
                return
        m[0], m[1], m[2], m[3] = m[0] + DX[d], m[1] + DY[d], d, self.pcoul

    def mob_libre(self, i, x, y, d):
        """La voiture / le passant i peut-il occuper ses cases en (x, y, d) ?"""
        m = self.mobiles[i]
        ok = (PIETON,) if NMOB_V <= i < NMOB_V + NMOB_P else MOB_ROUTES
        joueur = self.cases_joueur()
        if not MOB_HAUT <= y - self.y <= MOB_BAS:
            return False
        for q in cases_voiture(x, y, d):
            if sorte_xy(self.c, *q) not in ok or q in joueur or self.occupe(*q, sauf=m):
                return False
        return True

    def apparait(self, i):
        """Juste hors de l'écran : à gauche, à droite, en haut ou en bas
        (4 tirages, toujours), sur une case permise et libre ; sinon rien."""
        a, b, c3, e = self.alea(), self.alea(), self.alea(), self.alea()
        cote = a & 3
        if cote < 2:
            x = self.x - 44 - (b & 7) if cote == 0 else self.x + 43 + (b & 7)
            y = self.y + ((b >> 3) & 31) - 16
        else:
            y = self.y + MOB_HAUT if cote == 2 else self.y + MOB_BAS
            x = self.x + (b >> 1) - 64
        m = self.mobiles[i]
        voiture = not NMOB_V <= i < NMOB_V + NMOB_P
        d = (c3 & 3) * 2 if voiture else 8
        m[5] = True
        if voiture:                 # dans le sens de la rue (elle continue devant)
            for k in range(4):
                if self.ouverture(x, y, d):
                    break
                d = (d + 2) % 8
            else:
                return
        if self.mob_libre(i, x, y, d):
            coul = COUL_POLICE if i >= NMOB_V + NMOB_P else (COUL_MOB_V if voiture else COUL_MOB_P)[e & 7]
            m[:] = [x, y, d, coul, 0, False]
            self.phase[i] = 0
            self.pdir[i] = (c3 & 3) * 2

    def essaie(self, i, d, glyphe_d):
        """Avance i dans la direction d (cases en glyphe_d) si c'est permis."""
        m = self.mobiles[i]
        nx, ny = m[0] + DX[d], m[1] + DY[d]
        if self.mob_libre(i, nx, ny, glyphe_d):
            m[0], m[1], m[2] = nx, ny, glyphe_d
            self.att[i] = 0
            if i >= NMOB_V + NMOB_P:
                m[3] = self.pcoul
            return True
        return False

    def ordre(self, d, seuil):
        """Tout droit, puis un côté, l'autre, le demi-tour ; un tirage sous
        seuil : tourner d'abord."""
        r = self.alea()
        g, dr = (d + 6) % 8, (d + 2) % 8
        cotes = (g, dr) if r & 0x80 else (dr, g)
        return cotes + (d, (d + 4) % 8) if r < seuil else (d,) + cotes + ((d + 4) % 8,)

    def route_connue(self, x, y):
        """Une case de chaussée, dans les rangées de l'anneau."""
        return MOB_HAUT <= y - self.y <= MOB_BAS and sorte_xy(self.c, x, y) in MOB_ROUTES

    def ouverture(self, x, y, s, n=None):
        """Une rue part-elle de (x, y) vers s (OUV_V / OUV_H cases de chaussée,
        ou n) ?"""
        if n is None:
            n = OUV_V if s in (0, 4) else OUV_H
        return all(self.route_connue(x + DX[s] * k, y + DY[s] * k) for k in range(1, n + 1))

    def roule(self, i):
        """Conduire : tourner à un carrefour (au hasard), sinon serrer à
        droite, sinon tout droit ; une voiture devant : attendre ; la rue
        finie : un côté, l'autre, le demi-tour (cul-de-sac). Une voiture
        de la circulation sur une place s'y gare parfois."""
        m = self.mobiles[i]
        d = m[2]
        self.phase[i] ^= 1
        if d in (0, 4) and self.phase[i]:
            return                              # en vertical : une fois sur deux
        r = self.alea()
        dr, ga = (d + 2) % 8, (d + 6) % 8
        if r < VIRAGE:
            s = dr if r & 1 else ga
            if self.ouverture(m[0], m[1], s) and self.essaie(i, s, s):
                return
        # serrer à droite : changer de voie en biais (dans une rue étroite)
        large = (LARGE_V if dr in (0, 4) else LARGE_H) + 1
        if (self.ouverture(m[0], m[1], dr, 1) and not self.ouverture(m[0], m[1], dr, large)
                and self.essaie(i, (d + 1) % 8, d)):
            self.garer(i, r)
            return
        if self.essaie(i, d, d):
            self.garer(i, r)
            return
        if all(self.route_connue(*q) for q in cases_voiture(m[0] + DX[d], m[1] + DY[d], d)):
            self.att[i] = min(self.att[i] + 1, 255)     # quelqu'un devant : attendre,
            if self.att[i] <= ATT_DOUBLE:       # puis doubler en biais,
                return
            if self.essaie(i, (d + 7) % 8, d) or self.essaie(i, (d + 1) % 8, d):
                return
            if self.att[i] > ATT_DEMI and self.essaie(i, (d + 4) % 8, (d + 4) % 8):
                return                          # puis faire demi-tour
        else:
            cotes = (dr, ga) if r & 2 else (ga, dr)
            for nd in cotes + ((d + 4) % 8,):
                if self.essaie(i, nd, nd):
                    return
            self.att[i] = min(self.att[i] + 1, 255)
        if self.att[i] > ATT_FIN and i < NMOB_V:    # coincée : se garer (sur
            if sorte_xy(self.c, m[0], m[1]) == PLACE:   # une place), sinon
                self.garer(i, GARER)                # disparaître hors de l'écran
            elif abs(m[0] - self.x) > 41 or abs(m[1] - self.y) > 15:
                m[5] = True

    def garer(self, i, r):
        """Une voiture de la circulation sur une place, un tirage >= GARER :
        elle se gare (prend la fiche d'une voiture garée hors de l'écran)."""
        m = self.mobiles[i]
        if i >= NMOB_V or r < GARER or sorte_xy(self.c, m[0], m[1]) != PLACE:
            return
        for g in self.garees:
            if not g[5] and (abs(g[0] - self.x) > 41 or abs(g[1] - self.y) > 16):
                g[:] = m[:]
                m[5] = True
                return

    def flane(self, i):
        for nd in self.ordre(self.pdir[i], 0x40):
            if self.essaie(i, nd, 8):
                self.pdir[i] = nd
                return

    def passe(self, x0, y0, x1, y1, niv):
        """passe(), et les voitures garées arrêtent aussi."""
        if self.occupe(x1, y1):
            return None
        return passe(self.c, x0, y0, x1, y1, niv)

    def effet(self, ty):
        if self.bt == 0 or ty >= self.bty:
            self.bty = ty
            self.bt, self.bp, self.bv = EFFETS[ty]

    def son(self, klaxon, muet):
        """Les registres de l'AY de cette trame (self.ayr), puis le bruitage
        s'éteint d'un cran."""
        if self.pied:
            pa, va = 1000, 0
        else:
            pa, va = 1000 - 5 * self.v, 8 + (self.v >> 5)
        pb = 0
        if klaxon:
            pb, r7, vb = (KLAX_B if self.trame & 8 else KLAX_A), R7_KLAX, 12
        elif self.bt:
            r7, vb = R7_BRUIT, self.bv
        else:
            r7, vb = R7_RIEN, 0
        pc, vc = 0, 0
        if self.etape == FUITE and any(md != PATROUILLE for md in self.pmode):
            pc, vc, r7 = (SIRENE_B if self.trame & 16 else SIRENE_A), 10, r7 & ~4
        if muet:
            va = vb = vc = 0
        self.ayr = {0: pa & 255, 1: pa >> 8, 2: pb & 255, 3: pb >> 8, 4: pc & 255, 5: pc >> 8,
                    6: self.bp, 7: r7, 8: va, 9: vb, 10: vc}
        if self.bt:
            self.bt -= 1
            self.bv = max(0, self.bv - 2)
        self.trame = (self.trame + 1) & 255

    def pas(self, voulu, espace=False, klaxon=False, muet=False):
        if self.etape in (ARRETE, GAGNE):       # la partie finie : Espace en relance une
            if espace:
                self.nouvelle_partie()
            self.v = 0
            self.son(False, muet)
            return None
        return self.pas_jeu(voulu, espace, klaxon, muet)

    def pas_jeu(self, voulu, espace, klaxon, muet):
        """Une trame : Espace (sortir de la voiture, à l'arrêt ; ou entrer
        dans une voiture garée voisine), sinon la conduite ou la marche ;
        puis la plaque (le nom du bloc, s'il en a un). Rend le pas (dx, dy)
        ou None."""
        if espace:
            r = self.bascule()
        elif self.pied:
            r = self.marche(voulu)
        else:
            r = self.conduite(voulu)
        n = int(self.grille[self.y // RUES_BL, self.x // RUES_BL])
        if n:
            self.plaque = n
        if r:
            self.bilan()
        if not r:                               # pas de pas : la circulation
            self.population()
        self.son(klaxon, muet)
        return r

    def deplace(self, dx, dy):
        self.x += dx
        self.y += dy
        self.s = (self.s + dx + 80 * dy) % 4096
        return (dx, dy) if dx or dy else None

    def bascule(self):
        """Sortir (même en roulant : la voiture s'arrête net) : une place
        libre dans la liste, une case libre autour (SORTIES, hors de la
        voiture) : la voiture y reste garée.
        Entrer : la première voiture garée dont la case (x, y) touche le
        piéton (8 voisines), au même étage : on la conduit."""
        if not self.pied:
            place = next((g for g in self.garees if g[5]), None)
            if place is None:
                return None
            soi = cases_voiture(self.x, self.y, self.d)
            for dx, dy in SORTIES:
                px, py = self.x + dx, self.y + dy
                if (px, py) in soi:
                    continue
                niv = self.passe(self.x, self.y, px, py, self.niv)
                if niv is not None:
                    place[:] = [self.x, self.y, self.d, self.coul, self.niv, False]
                    self.pied, self.niv, self.v, self.ax, self.ay = True, niv, 0, 0, 0
                    self.effet(EF_PORTE)
                    return self.deplace(dx, dy)
            return None
        for g in self.garees:
            if not g[5] and max(abs(g[0] - self.x), abs(g[1] - self.y)) <= 1 and g[4] == self.niv:
                dx, dy = g[0] - self.x, g[1] - self.y
                self.d, self.coul, g[5] = g[2], g[3], True
                self.pied, self.v, self.ax, self.ay = False, 0, 0, 0
                self.effet(EF_PORTE)
                return self.deplace(dx, dy)
        return None

    def marche(self, voulu):
        """À pied : la direction de la flèche tout de suite, VPIED, sans élan ;
        au départ ou à un changement de direction, le premier pas tout de
        suite (avances à PAS - 1)."""
        if voulu is None:
            self.v, self.ax, self.ay = 0, 0, 0
            return None
        if voulu != self.d or self.v == 0:
            self.d, self.ax, self.ay = voulu, PAS - 1, PAS - 1
        self.v = VPIED
        return self.avance()

    def peut(self, d):
        """Un virage vers d : la case voisine (en biais : l'une des deux
        voisines d'axe) accepte-t-elle la voiture ?"""
        x, y = self.x, self.y
        if DX[d] and DY[d]:
            return (self.passe(x, y, x + DX[d], y, self.niv) is not None or
                    self.passe(x, y, x, y + DY[d], self.niv) is not None)
        return self.passe(x, y, x + DX[d], y + DY[d], self.niv) is not None

    def conduite(self, voulu):
        """Rend le pas fait (dx, dy), ou None. Deux avances : ax (en x),
        ay (en y, v x 107 / 256). En biais, un côté bloqué : la voiture
        glisse le long (l'avance de ce côté perdue) ; les deux à la fois,
        ou tout droit contre un mur : arrêt net."""
        c, d = self.c, self.d
        if voulu is None:
            self.v = max(0, self.v - FROTTE)
        elif voulu == d:
            self.v = min(VMAX, self.v + ACCEL)
        elif voulu == (d + 4) % 8:
            if self.v > 0:
                self.v = max(0, self.v - FREIN)
            else:
                self.d = voulu
        elif self.v == 0 or self.peut(voulu):
            self.d = voulu
            self.ax = self.ay = 0
        if sorte_xy(c, self.x, self.y) in LENT and self.v > VLENT:
            self.v = max(VLENT, self.v - RALENTI)
        return self.avance()

    def avance(self):
        """Le pas de la trame à la vitesse v dans la direction d (voiture
        ou piéton)."""
        if self.v == 0:
            return None
        dx, dy = DX[self.d], DY[self.d]
        w = (self.v * DIAG) >> 8 if dx and dy else self.v
        mx = my = 0
        bloque = 0
        if dx:
            self.ax += w
            if self.ax >= PAS:
                self.ax -= PAS
                niv = self.passe(self.x, self.y, self.x + dx, self.y, self.niv)
                if niv is None:
                    self.ax = 0
                    bloque += 1
                else:
                    self.x += dx
                    self.niv = niv
                    mx = dx
        if dy:
            self.ay += (w * 107) >> 8
            if self.ay >= PAS:
                self.ay -= PAS
                niv = self.passe(self.x, self.y, self.x, self.y + dy, self.niv)
                if niv is None:
                    self.ay = 0
                    bloque += 1
                else:
                    self.y += dy
                    self.niv = niv
                    my = dy
        if bloque and (bloque == 2 or not (dx and dy)):
            if not self.pied and self.v >= CHOC_V:
                self.effet(EF_CHOC)
            self.v, self.ax, self.ay = 0, 0, 0
        if not (mx or my):
            return None
        if self.pied:
            self.effet(EF_PAS)
        self.s = (self.s + mx + 80 * my) % 4096
        return mx, my

    def tuile_vue(self, x, y):
        """La tuile, ou la voiture garée, la voiture ou le passant de la
        circulation qui couvre la case (caché sous un tablier s'il est au
        sol). Le fond d'une voiture, d'un passant : celui de la sorte de la
        case (ATTR), pas de la tuile (moins cher pour le 6309 ; seuls les
        coins arrondis diffèrent)."""
        t = tuile(self.c, x, y)
        for g in reversed(self.tous()):         # la dernière dessinée l'emporte
            if g[5] or g[1] != y:
                continue
            for k, cx in enumerate((g[0] - 1, g[0])):
                gl_ = VOIT_G[g[2]][k]
                if gl_ is not None and cx == x:
                    if g[4] == 0 and sorte_xy(self.c, x, y) in TABLIERS:
                        continue
                    return gl_, VOIT_ATTR | (ATTR[sorte_xy(self.c, x, y)] & 0x70) | g[3]
        return t

    def ecran(self):
        """Les 80 x 30 cases (glyphe, attribut) que l'on doit voir."""
        cases = [[self.tuile_vue(self.x - CENTRE_C + col, self.y - CENTRE_R + r)
                  for col in range(80)] for r in range(30)]
        for k, col in enumerate((CENTRE_C - 1, CENTRE_C)):
            if self.pied:
                g = gl.G_PIETONNE if k == 1 else None
                coul = PIED_COUL
            else:
                g = VOIT_G[self.d][k]
                coul = self.coul
            sous = self.niv == 0 and sorte_xy(self.c, self.x + col - CENTRE_C, self.y) in TABLIERS
            if g is not None and not sous:          # sous un pont : caché
                s = sorte_xy(self.c, self.x + col - CENTRE_C, self.y)
                cases[CENTRE_R][col] = (g, VOIT_ATTR | (ATTR[s] & 0x70) | coul)
        c0, pl = self.plaque_cases()
        cases[PLQ_R][c0:c0 + len(pl)] = pl
        return cases

    def plaque_cases(self):
        """La plaque : en jeu, la flèche vers l'objectif puis le nom de la
        rue (bleue pendant le vol, rouge pendant la fuite) ; à la fin, le
        message. Centrée."""
        if self.etape in PLQ_FIN:
            attr, msg = PLQ_FIN[self.etape]
            txt = [(o, attr) for o in b' ' + msg.encode('cp437') + b' ']
        else:
            attr = PLQ_ATTR if self.etape == VOL else PLQ_FUITE
            o = self.objectif()
            f = fleche_vers(o[0] - self.x, o[1] - self.y)
            nom = self.noms[self.plaque - 1] if self.plaque else b''
            txt = [(gl.G_FLECHE + f, 0x80 | attr)] + [(c_, attr) for c_ in b' ' + nom + b' ']
        return 40 - len(txt) // 2, txt


def fichier_carte(c):
    """OSMCITY.MAP : rangée y à 256 y, case x à l'octet x / 2 (x pair : poids fort)."""
    flat = c.flatten()
    return bytes((int(flat[j]) << 4) | int(flat[j + 1]) for j in range(0, LARG * HAUT, 2))


def inc(c, fichier):
    """apps/osmcity_data.inc : constantes et tables (la carte est OSMCITY.MAP)."""
    x0, y0 = depart(c)
    out = ['; GÉNÉRÉ par tools/osmcity/osmcity.py --inc : ne pas éditer.',
           '; Carte tirée d\'OpenStreetMap (Annonay) : © contributeurs OpenStreetMap, ODbL.',
           'CARTE_L         equ %d' % LARG, 'CARTE_H         equ %d' % HAUT,
           'DEPART_X        equ %d' % x0, 'DEPART_Y        equ %d' % y0,
           'VMAX            equ %d' % VMAX, 'VLENT           equ %d' % VLENT,
           'PAS             equ %d' % PAS, 'ACCEL           equ %d' % ACCEL,
           'FROTTE          equ %d' % FROTTE, 'FREIN           equ %d' % FREIN,
           'RALENTI         equ %d' % RALENTI, 'VOIT_ATTR       equ $%02X' % VOIT_ATTR,
           'S_BATI          equ %d' % BATI, 'S_EAU           equ %d' % EAU,
           'S_PARC          equ %d' % PARC, 'S_RAMPE         equ %d' % RAMPE,
           'S_SOUS_PONT     equ %d' % SOUS_PONT,
           'G_ROUTE         equ $%02X' % gl.G_ROUTE, 'G_HERBE         equ $%02X' % gl.G_HERBE,
           'G_ARBRE         equ $%02X' % gl.G_ARBRE, 'G_PLACE         equ $%02X' % gl.G_PLACE,
           'G_P             equ $%02X' % gl.G_P, 'G_COIN          equ $%02X' % gl.G_COIN,
           '; sortes : %s' % ' '.join('%d %s' % (i, n) for i, n in enumerate(NOMS))]
    for nom, tab in (('Famille', FAMILLE), ('Genre', GENRE), ('Base', BASE), ('Attr', ATTR)):
        out.append('%-8sfcb ' % (nom + ':') + ','.join('$%02X' % tab[k] for k in range(NSORTES)))
    out.append('Lente:  fcb ' + ','.join('1' if k in LENT else '0' for k in range(NSORTES)))
    out.append('Bloque: fcb ' + ','.join('1' if k in BLOQUE else '0' for k in range(NSORTES)))
    out.append('Tablier: fcb ' + ','.join('1' if k in TABLIERS else '0' for k in range(NSORTES)))
    out.append('Garde:  fcb ' + ','.join('1' if GARDE[k] else '0' for k in range(NSORTES)))
    out.append('Coul:   fcb ' + ','.join('%d' % COUL[k] for k in range(NSORTES)))
    out.append('; masque -> 0 (pas un coin) ou 1..4 (G_COIN + 0..3)')
    out.append('CoinT:  fcb ' + ','.join('%d' % COIN.get(m, 0) for m in range(16)))
    noms, _ = rues()
    out += ['RUES_BL         equ %d' % RUES_BL, 'RUES_L          equ %d' % RUES_L,
            'RUES_H          equ %d' % RUES_H, 'PLQ_ATTR        equ $%02X' % PLQ_ATTR,
            'PLQ_R           equ %d' % PLQ_R,
            '; les noms des rues (n° 1..) : longueur, octets CP437 ; Noms : leurs adresses',
            'Noms:   fdb ' + ','.join('Nom%d' % (i + 1) for i in range(len(noms)))]
    for i, n in enumerate(noms):
        out.append('Nom%d:   fcb %d,%s' % (i + 1, len(n), ','.join('$%02X' % o for o in n)))
    out.append('; glyphes de la voiture, colonnes 39 et 40 (0 : la tuile), par direction')
    out.append('VoitG:  fcb ' + ','.join('$%02X' % (g or 0) for p in VOIT_G for g in p))
    out.append('; la direction voulue : VouluT[8 haut + 4 droite + 2 bas + gauche] ($FF : aucune)')
    out.append('VouluT: fcb ' + ','.join('$%02X' % (0xFF if voulu_de(k & 8, k & 4, k & 2, k & 1) is None
                                                    else voulu_de(k & 8, k & 4, k & 2, k & 1)) for k in range(16)))
    out.append('DIAG            equ %d' % DIAG)
    out += ['NPOLICE         equ %d' % NPOLICE, 'VUE_X           equ %d' % VUE_X,
            'VUE_Y           equ %d' % VUE_Y, 'PRES_X          equ %d' % PRES_X,
            'PRES_Y          equ %d' % PRES_Y, 'PERDU_MAX       equ %d' % PERDU_MAX,
            'DIST_PLANQUE    equ %d' % DIST_PLANQUE, 'NCANDS          equ %d' % NCANDS,
            'COUL_POLICE     equ %d' % COUL_POLICE, 'COUL_GYRO       equ %d' % COUL_GYRO,
            'SIRENE_A        equ %d' % SIRENE_A, 'SIRENE_B        equ %d' % SIRENE_B,
            'PLQ_FUITE       equ $%02X' % PLQ_FUITE, 'G_FLECHE        equ $%02X' % gl.G_FLECHE,
            'E_VOL           equ %d' % VOL, 'E_FUITE         equ %d' % FUITE,
            'E_ARRETE        equ %d' % ARRETE, 'E_GAGNE         equ %d' % GAGNE,
            'S_SOUS_PONT2    equ %d' % SOUS_PONT,
            '; les messages de fin : attribut, longueur, texte',
            'MsgArrete: fcb $%02X,%d,%s' % (PLQ_FIN[ARRETE][0], len(PLQ_FIN[ARRETE][1]),
                                         ','.join('$%02X' % o for o in PLQ_FIN[ARRETE][1].encode('cp437'))),
            'MsgGagne: fcb $%02X,%d,%s' % (PLQ_FIN[GAGNE][0], len(PLQ_FIN[GAGNE][1]),
                                        ','.join('$%02X' % o for o in PLQ_FIN[GAGNE][1].encode('cp437'))),
            '; butin et planque : NCANDS cases (x, y)', 'Cands:'] + [
        '    fdb %d,%d' % q for q in cands(c)]
    out += ['CHOC_V          equ %d' % CHOC_V, 'KLAX_A          equ %d' % KLAX_A,
            'KLAX_B          equ %d' % KLAX_B, 'R7_KLAX         equ $%02X' % R7_KLAX,
            'R7_BRUIT        equ $%02X' % R7_BRUIT, 'R7_RIEN         equ $%02X' % R7_RIEN,
            'EF_PAS          equ %d' % EF_PAS, 'EF_PORTE        equ %d' % EF_PORTE,
            'EF_CHOC         equ %d' % EF_CHOC,
            '; les bruitages : trames, période du bruit, volume (type 1, 2, 3)',
            'EffT:   fcb ' + ','.join('%d,%d,%d' % EFFETS[k] for k in (1, 2, 3))]
    out += ['NMOB_V          equ %d' % NMOB_V, 'NMOB            equ %d' % (NMOB_V + NMOB_P),
            'MOB_LOIN_X      equ %d' % MOB_LOIN_X, 'MOB_HAUT        equ %d' % MOB_HAUT,
            'MOB_BAS         equ %d' % MOB_BAS,
            'OUV_V           equ %d' % OUV_V, 'OUV_H           equ %d' % OUV_H,
            'VIRAGE          equ $%02X' % VIRAGE, 'GARER           equ $%02X' % GARER,
            'ATT_DOUBLE      equ %d' % ATT_DOUBLE, 'ATT_DEMI        equ %d' % ATT_DEMI,
            'ATT_FIN         equ %d' % ATT_FIN,
            'LARGE_V         equ %d' % LARGE_V, 'LARGE_H         equ %d' % LARGE_H,
            'S_PLACE         equ %d' % PLACE,
            'ALEA0           equ $%02X' % ALEA0, 'S_PIETON        equ %d' % PIETON,
            'CoulMobV: fcb ' + ','.join('%d' % k for k in COUL_MOB_V),
            'CoulMobP: fcb ' + ','.join('%d' % k for k in COUL_MOB_P),
            'MobRoute: fcb ' + ','.join('1' if k in MOB_ROUTES else '0' for k in range(NSORTES))]
    out += ['VPIED           equ %d' % VPIED, 'NGAREES         equ %d' % NGAREES,
            'COUL_JOUEUR     equ %d' % COUL_JOUEUR, 'PIED_COUL       equ %d' % PIED_COUL,
            'G_PIETONNE      equ $%02X' % gl.G_PIETONNE,
            '; sortir : les cases essayées pour le piéton (dx, dy)',
            'Sorties: fcb ' + ','.join('%d,%d' % q for q in SORTIES),
            '; les voitures garées au départ : x (2), y (2), direction, couleur, étage, libre',
            'Garees:']
    for g in garees_depart(c):
        out.append('    fdb %d,%d' % (g[0], g[1]))
        out.append('    fcb %d,%d,%d,%d' % (g[2], g[3], g[4], 1 if g[5] else 0))
    out.append('; la circulation (même format, juste après : une seule liste pour le dessin)')
    out.append('Mobiles:')
    for _ in range(NMOB_V + NMOB_P):
        out.append('    fdb 0,0')
        out.append('    fcb 8,0,0,1')
    out.append('; la police (2 entrées, juste après la circulation)')
    for _ in range(NPOLICE):
        out.append('    fdb 0,0')
        out.append('    fcb 0,%d,0,1' % COUL_POLICE)
    out.append('; les objets : le butin, la planque (directions 9, 10)')
    out.append('Objets:')
    out.append('    fdb 0,0')
    out.append('    fcb 9,6,0,1')
    out.append('    fdb 0,0')
    out.append('    fcb 10,2,0,1')
    out.append('; la police au poste (devant la mairie), au début de chaque partie')
    out.append('Poste:')
    for x, y, d in POSTE:
        out.append('    fdb %d,%d' % (x, y))
        out.append('    fcb %d,%d,0,0' % (d, COUL_POLICE))
    open(fichier, 'w').write('\n'.join(out) + '\n')


def main(a):
    c = carte()
    n = np.bincount(c.flatten(), minlength=8)
    print(' '.join('%s %d' % (NOMS[i], n[i]) for i in range(8)))
    if '--apercu' in a:
        apercu(c, a[a.index('--apercu') + 1])
    if '--carte' in a:
        open(a[a.index('--carte') + 1], 'wb').write(fichier_carte(c))
    if '--rues' in a:
        open(a[a.index('--rues') + 1], 'wb').write(rues()[1].tobytes())
    if '--inc' in a:
        inc(c, os.path.join(RACINE, 'apps', 'osmcity_data.inc'))
        print('départ', depart(c))
    if '--ecran' in a:
        i = a.index('--ecran')
        j = Jeu(c)
        j.x, j.y, j.d = int(a[i + 1]), int(a[i + 2]), int(a[i + 3])
        gl.dessine(j.ecran(), None, a[i + 4], 1)


if __name__ == '__main__':
    main(sys.argv[1:])
