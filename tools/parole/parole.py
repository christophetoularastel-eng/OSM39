#!/usr/bin/env python3
# ===================================================================
# parole.py - Synthèse de la parole en français pour OSM39 (prototype)
# ===================================================================
# Source UNIQUE de la synthèse vocale de apps/parole.asm :
#   * règles de prononciation (texte -> phonèmes), au format des règles
#     NRL du « Reciter » de S.A.M. : gauche [lettres] droite = phonèmes ;
#   * table des phonèmes (formants, amplitudes, durées, souffle) ;
#   * prosodie (durées, mélodie de la phrase) ;
#   * MODÈLE EXACT de la boucle d'échantillons du 6309 (mêmes tables,
#     mêmes calculs entiers, 7200 échantillons/s) : ce qu'on entend dans
#     le .wav est ce que la carte jouera (au filtre près).
#
#   python3 tools/parole/parole.py "Bonjour, je suis OSM39." -o essai.wav
#   python3 tools/parole/parole.py -p "Bonjour"        # phonèmes seulement
#   python3 tools/parole/parole.py --6840 ... -o x.wav # l'ancienne sortie
#
# SORTIE : l'AY-3-8910 de la carte SD-KBD-SON en convertisseur. Ton et
# bruit coupés (R7 = $3F), la sortie d'une voie vaut son volume ; les
# voies A et C s'additionnent (4k7 chacune vers le même point). Chaque
# échantillon (0..120) donne un couple de volumes (TabA, TabC) : celui
# dont la somme des niveaux de l'AY (NIVEAUX de tools/ay/ay.py) est la
# plus proche, 80 niveaux distincts. Le .wav rend ces niveaux à 7 200 Hz
# (la voie C écrite une demi-période après A, comme la carte).
# --6840 : l'ancienne sortie (impulsions du timer 2, filtre RC 1,4 kHz).
#
# MOTEUR (une trame de paramètres toutes les 10 ms = 72 échantillons) :
#   trois oscillateurs (formants F1, F2, F3), phase 16 bits, lus dans une
#   table sinus x amplitude (16 niveaux, crête 4 x niveau). Voix : les
#   phases sont remises à 0 au début de chaque période de la voix (le
#   « coup de glotte » de S.A.M.). Souffle : à chaque échantillon on
#   ajoute aux phases un nombre au hasard (masque de la trame), ce qui
#   étale chaque formant en bande de bruit.
# ===================================================================
import math
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ay'))
from ay import NIVEAUX          # noqa: E402  niveaux des 16 volumes de l'AY

FS = 7200                       # échantillons par seconde
TRAME = 72                      # échantillons par trame (10 ms)
MILIEU = 60                     # silence ; échantillons 0..120


def inc(f):
    return round(f * 65536 / FS) & 0xFFFF


# ---------------------------------------------------------------
# Phonèmes : code -> (F1, F2, F3, A1, A2, A3, durée en trames, masque de
# souffle, voisé, sorte). A1+A2+A3 <= 15 (crête 60). Sortes :
#   V voyelle, N nasale/liquide, F fricative, P occlusive, J semi-voyelle
# Occlusives : F1-F3 = « locus » (d'où partent les formants de la
# voyelle suivante), A = l'explosion ; tenue = silence (sourde) ou
# murmure grave (sonore).
# ---------------------------------------------------------------
PH = {
    # voyelles
    'a': (750, 1350, 2500, 8, 5, 2, 10, 0, 1, 'V'),
    'e': (400, 2100, 2650, 7, 5, 3, 9, 0, 1, 'V'),     # é
    'E': (550, 1850, 2550, 8, 5, 2, 9, 0, 1, 'V'),     # è
    'i': (280, 2250, 2900, 6, 5, 4, 10, 0, 1, 'V'),    # l'aigu fait le i
    'o': (420, 850, 2400, 9, 5, 1, 10, 0, 1, 'V'),     # o fermé
    'O': (550, 1000, 2500, 9, 5, 1, 9, 0, 1, 'V'),     # o ouvert
    'u': (300, 750, 2300, 10, 4, 1, 9, 0, 1, 'V'),     # ou
    'y': (280, 1800, 2200, 7, 5, 3, 9, 0, 1, 'V'),     # u
    '2': (400, 1450, 2300, 9, 4, 2, 9, 0, 1, 'V'),     # eu (deux)
    '9': (550, 1400, 2300, 9, 4, 2, 9, 0, 1, 'V'),     # eu (peur)
    '@': (480, 1450, 2400, 8, 4, 2, 6, 0, 1, 'V'),     # e muet
    '1': (650, 1050, 2500, 9, 4, 1, 12, 0, 1, 'V'),    # an
    '3': (450, 800, 2400, 10, 3, 1, 12, 0, 1, 'V'),    # on
    '5': (600, 1500, 2500, 9, 4, 1, 12, 0, 1, 'V'),    # in
    # semi-voyelles
    'j': (260, 2250, 3000, 5, 4, 3, 5, 0, 1, 'J'),
    'w': (300, 700, 2300, 8, 3, 1, 5, 0, 1, 'J'),
    'H': (280, 1800, 2200, 7, 3, 2, 5, 0, 1, 'J'),     # u de « lui »
    # nasales, liquides
    'm': (250, 1000, 2200, 7, 1, 0, 7, 0, 1, 'N'),
    'n': (250, 1600, 2600, 7, 1, 1, 7, 0, 1, 'N'),
    'J': (250, 2000, 2700, 7, 2, 1, 8, 0, 1, 'N'),     # gn
    'l': (350, 1150, 2700, 8, 3, 1, 6, 0, 1, 'N'),
    'R': (500, 1250, 2400, 3, 4, 2, 7, 0x3FFF, 1, 'F'),  # r du fond de la gorge : surtout un frottement
    # fricatives
    'f': (1400, 2600, 3300, 0, 2, 2, 9, 0x7FFF, 0, 'F'),
    's': (2500, 3000, 3450, 0, 2, 5, 10, 0x3FFF, 0, 'F'),
    'S': (1700, 2200, 2800, 0, 4, 4, 10, 0x3FFF, 0, 'F'),  # ch
    'v': (300, 1200, 2300, 5, 2, 1, 7, 0x1FFF, 1, 'F'),
    'z': (300, 1700, 3200, 3, 2, 4, 8, 0x3FFF, 1, 'F'),
    'Z': (300, 2000, 2800, 3, 5, 5, 9, 0x3FFF, 1, 'F'),  # j : souffle du ch + voix
    # occlusives : locus des formants, amplitudes de l'explosion
    'p': (400, 900, 2200, 3, 3, 2, 8, 0x7FFF, 0, 'P'),
    'b': (300, 900, 2200, 3, 2, 1, 7, 0x7FFF, 1, 'P'),
    't': (400, 1700, 2900, 1, 3, 5, 8, 0x7FFF, 0, 'P'),
    'd': (300, 1700, 2700, 2, 2, 3, 7, 0x7FFF, 1, 'P'),
    'k': (400, 2000, 2500, 2, 5, 3, 8, 0x7FFF, 0, 'P'),
    'g': (300, 2000, 2500, 2, 4, 2, 7, 0x7FFF, 1, 'P'),
}
VOYELLES_PH = set('aeEioOuy2915@3')

# ---------------------------------------------------------------
# Règles : (gauche, lettres, droite, phonèmes), essayées dans l'ordre
# pour la première lettre ; la première qui convient gagne.
# Contextes :  ' ' bord de mot   '#' voyelle   '^' consonne
#              '!' consonne ou bord (pas une voyelle)   '+' e i y é è ê
# Les autres caractères se comparent tels quels.
# ---------------------------------------------------------------
REGLES = [
    # --- mots irréguliers (mot entier : bords des deux côtés) et
    #     élisions (« l' », « d' »... : l'apostrophe sépare les mots) ---
    (' ', 'aujourd', ' ', 'oZuRd'),
    (' ', 'est', ' ', 'E'),
    (' ', 'fils', ' ', 'fis'),
    (' ', 'mille', ' ', 'mil'),
    (' ', 'ville', ' ', 'vil'),
    (' ', 'monsieur', ' ', 'm@sj2'),
    (' ', 'femme', ' ', 'fam'),
    (' ', 'oui', ' ', 'wi'),
    (' ', 'osm', ' ', 'oEsEm'),
    (' ', 'osmvision', ' ', 'oEsEmvizj3'),
    (' ', 'eu', ' ', 'y'),
    (' ', 'plus', ' ', 'plys'),
    (' ', 'six', ' ', 'sis'),
    (' ', 'soixante', ' ', 'swas1t'),
    (' ', 'dix', ' ', 'dis'),
    (' ', 'sept', ' ', 'sEt'),
    (' ', 'huit', ' ', 'Hit'),
    (' ', 'cinq', ' ', 's5k'),
    (' ', 'neuf', ' ', 'n9f'),
    (' ', 'e', ' ', '2'),
    (' ', 'l', ' ', 'l'),
    (' ', 'd', ' ', 'd'),
    (' ', 'j', ' ', 'Z'),
    (' ', 'c', ' ', 's'),
    (' ', 'qu', ' ', 'k'),
    (' ', 'n', ' ', 'n'),
    (' ', 'm', ' ', 'm'),
    (' ', 's', ' ', 's'),
    (' ', 't', ' ', 't'),
    # --- a ---
    ('', 'aient', ' ', 'E'),
    ('', 'ais', ' ', 'E'),
    ('', 'ait', ' ', 'E'),
    ('', 'aill', '', 'aj'),
    ('', 'ail', ' ', 'aj'),
    ('', 'aim', '!', '5'),
    ('', 'ain', '!', '5'),
    ('', 'ai', '', 'E'),
    ('', 'au', '', 'o'),
    ('', 'ay', '#', 'Ej'),
    ('', 'ay', '', 'E'),
    ('', 'amm', '', 'am'),
    ('', 'ann', '', 'an'),
    ('', 'am', '!', '1'),
    ('', 'an', '!', '1'),
    ('', 'a', '', 'a'),
    ('', 'à', '', 'a'),
    ('', 'â', '', 'a'),
    # --- e ---
    ('', 'eaux', '', 'o'),
    ('', 'eau', '', 'o'),
    ('', 'eur', '', '9R'),
    ('', 'eux', '', '2'),
    ('', 'eu', '', '2'),
    ('', 'eill', '', 'Ej'),
    ('', 'eil', ' ', 'Ej'),
    ('', 'ein', '!', '5'),
    ('', 'eim', '!', '5'),
    ('', 'ei', '', 'E'),
    ('i', 'en', '!', '5'),
    ('', 'ent', ' ', '1'),             # vent, cent, souvent (pas « ils parlent »)
    ('', 'emm', '', 'am'),
    ('', 'enn', '', 'En'),
    ('', 'em', '!', '1'),
    ('', 'en', '!', '1'),
    (' ^', 'er', ' ', 'ER'),
    ('', 'er', ' ', 'e'),
    ('', 'ez', ' ', 'e'),
    (' ', 'et', ' ', 'e'),
    ('', 'et', ' ', 'E'),
    (' ', 'es', ' ', 'E'),
    (' ^', 'es', ' ', 'e'),
    ('', 'es', ' ', ''),
    ('', 'ex', '#', 'Egz'),
    ('', 'ex', '', 'Eks'),
    (' ^', 'e', ' ', '@'),
    (' qu', 'e', ' ', '@'),
    ('', 'e', ' ', ''),
    ('', 'e', '^^', 'E'),
    ('', 'e', '^ ', 'E'),
    ('', 'e', '', '@'),
    ('', 'é', '', 'e'),
    ('', 'è', '', 'E'),
    ('', 'ê', '', 'E'),
    ('', 'ë', '', 'E'),
    # --- i ---
    ('^', 'ill', '', 'ij'),
    ('', 'imm', '', 'im'),
    ('', 'inn', '', 'in'),
    ('', 'im', '!', '5'),
    ('', 'in', '!', '5'),
    ('', 'i', '#', 'j'),
    ('', 'i', '', 'i'),
    ('', 'î', '', 'i'),
    ('', 'ï', '', 'i'),
    # --- o ---
    ('', 'oin', '!', 'w5'),
    ('', 'oi', '', 'wa'),
    ('', 'oy', '', 'waj'),
    ('', 'oue', ' ', 'u'),             # joue, roue (e muet : pas le w de « oui »)
    ('', 'oues', ' ', 'u'),
    ('', 'ou', '#', 'w'),
    ('', 'ou', '', 'u'),
    ('', 'où', '', 'u'),
    ('', 'onn', '', 'On'),
    ('', 'omm', '', 'Om'),
    ('', 'om', '!', '3'),
    ('', 'on', '!', '3'),
    ('', 'o', ' ', 'o'),
    ('', 'o', 's ', 'o'),
    ('', 'o', '', 'O'),
    ('', 'ô', '', 'o'),
    # --- u ---
    ('', 'um', '!', '5'),
    ('', 'un', '!', '5'),
    ('', 'ue', ' ', 'y'),
    ('', 'ues', ' ', 'y'),
    ('', 'u', '#', 'H'),
    ('', 'u', '', 'y'),
    ('', 'ù', '', 'y'),
    ('', 'û', '', 'y'),
    ('', 'ü', '', 'y'),
    # --- y ---
    ('', 'y', '#', 'j'),
    ('', 'y', '', 'i'),
    # --- consonnes ---
    ('', 'bb', '', 'b'),
    ('', 'b', '', 'b'),
    ('', 'ch', '', 'S'),
    ('', 'cc', '+', 'ks'),
    ('', 'c', '+', 's'),
    ('', 'c', '', 'k'),
    ('', 'ç', '', 's'),
    ('', 'dd', '', 'd'),
    ('', 'd', ' ', ''),
    ('', 'd', '', 'd'),
    ('', 'ff', '', 'f'),
    ('', 'f', '', 'f'),
    ('', 'gn', '', 'J'),
    ('', 'gu', '+', 'g'),
    ('', 'gg', '', 'g'),
    ('', 'ge', '#', 'Z'),
    ('', 'g', '+', 'Z'),
    ('', 'gt', ' ', ''),
    ('', 'g', ' ', ''),
    ('', 'g', '', 'g'),
    ('', 'h', '', ''),
    ('', 'j', '', 'Z'),
    ('', 'k', '', 'k'),
    ('', 'll', '', 'l'),
    ('', 'l', '', 'l'),
    ('', 'mm', '', 'm'),
    ('', 'm', '', 'm'),
    ('', 'nn', '', 'n'),
    ('', 'n', '', 'n'),
    ('', 'ph', '', 'f'),
    ('', 'pp', '', 'p'),
    ('', 'ps', ' ', ''),
    ('', 'p', ' ', ''),
    ('', 'p', '', 'p'),
    ('', 'qu', '', 'k'),
    ('', 'q', '', 'k'),
    ('', 'rr', '', 'R'),
    ('', 'r', '', 'R'),
    ('', 'sch', '', 'S'),
    ('', 'sh', '', 'S'),
    ('', 'ss', '', 's'),
    ('', 'sc', '+', 's'),
    ('#', 's', '#', 'z'),
    ('', 's', ' ', ''),
    ('', 's', '', 's'),
    ('s', 'tion', '', 'tj3'),
    ('', 'tion', '', 'sj3'),
    ('', 'tt', '', 't'),
    ('', 'th', '', 't'),
    ('', 't', ' ', ''),
    ('', 't', '', 't'),
    ('', 'v', '', 'v'),
    ('', 'w', '', 'w'),
    ('', 'x', ' ', ''),
    ('', 'x', '', 'ks'),
    ('', 'z', ' ', ''),
    ('', 'z', '', 'z'),
]

LETTRES_V = set('aeiouyàâéèêëîïôùûü')
LETTRES = LETTRES_V | set('bcdfghjklmnpqrstvwxzç')


def classe_ok(c, ch):
    if c == ' ':
        return ch not in LETTRES
    if c == '#':
        return ch in LETTRES_V
    if c == '^':
        return ch in LETTRES and ch not in LETTRES_V
    if c == '!':
        return ch not in LETTRES_V
    if c == '+':
        return ch in 'eiyéèê'
    return ch == c


def mot_en_phonemes(texte):
    """texte en minuscules, bordé d'espaces -> chaîne de phonèmes."""
    t = ' ' + texte + ' '
    out = ''
    i = 1
    while i < len(t) - 1:
        ch = t[i]
        if ch not in LETTRES:
            i += 1
            continue
        for g, m, d, ph in REGLES:
            if not t.startswith(m, i):
                continue
            j = i + len(m)
            if not all(j + k < len(t) and classe_ok(c, t[j + k]) for k, c in enumerate(d)):
                continue
            if not all(i - 1 - k >= 0 and classe_ok(c, t[i - 1 - k])
                       for k, c in enumerate(reversed(g))):
                continue
            out += ph
            i = j
            break
        else:
            i += 1
    return out


# ---------------------------------------------------------------
# Texte -> groupes de phonèmes. Même algorithme que apps/parole.asm.
# ---------------------------------------------------------------
UNITES = ['zéro', 'un', 'deux', 'trois', 'quatre', 'cinq', 'six', 'sept', 'huit', 'neuf',
          'dix', 'onze', 'douze', 'treize', 'quatorze', 'quinze', 'seize']
DIZAINES = ['', '', 'vingt', 'trente', 'quarante', 'cinquante', 'soixante']


def moins_de_100(r):
    if r < 17:
        return UNITES[r]
    if r < 20:
        return 'dix ' + UNITES[r - 10]
    if r < 70:
        d, u = divmod(r, 10)
        if u == 0:
            return DIZAINES[d]
        return DIZAINES[d] + (' et un' if u == 1 else ' ' + UNITES[u])
    if r < 80:
        return 'soixante ' + ('et onze' if r == 71 else moins_de_100(r - 60))
    # en un mot : « katR@v5 », d'un souffle (en deux, le R bute sur le v)
    return 'quatrevingt' + ('' if r == 80 else ' ' + moins_de_100(r - 80))


def nombre(n):
    """0 à 9999 en lettres (mots séparés par des espaces)."""
    if n == 0:
        return UNITES[0]
    mots = []
    m, n = divmod(n, 1000)
    if m:
        mots.append('mille' if m == 1 else UNITES[m] + ' mille')
    c, r = divmod(n, 100)
    if c:
        mots.append('cent' if c == 1 else UNITES[c] + ' cent')
    if r:
        mots.append(moins_de_100(r))
    return ' '.join(mots)


# Nom des lettres (sigles épelés), écrit pour que les règles le lisent bien
NOM_LETTRE = ['a', 'bé', 'cé', 'dé', 'euh', 'èf', 'gé', 'ache', 'i', 'ji', 'ka', 'èl',
              'èm', 'èn', 'o', 'pé', 'ku', 'èr', 'èss', 'té', 'u', 'vé', 'double vé',
              'ix', 'i grec', 'zède']
MAJ = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
CHIFFRES = '0123456789'


def est_lettre(c):
    return c in MAJ or c in LETTRES


def normalise(texte):
    """Texte (Latin-1) -> texte des règles : minuscules, sigles épelés
    (un mot en majuscules de 2 ou 3 lettres, ou plus long sans voyelle),
    nombres de 1 à 4 chiffres en lettres (au-delà : chiffre par chiffre),
    ponctuation de groupe ramenée à « , . ? », tout le reste en espaces."""
    out = ''
    i = 0
    while i < len(texte):
        c = texte[i]
        j = i
        if c in CHIFFRES:
            while j < len(texte) and texte[j] in CHIFFRES:
                j += 1
            ch = texte[i:j]
            if len(ch) <= 4:
                out += ' ' + nombre(int(ch)) + ' '
            else:
                out += ' ' + ' '.join(UNITES[int(d)] for d in ch) + ' '
        elif est_lettre(c):
            while j < len(texte) and est_lettre(texte[j]):
                j += 1
            mot = texte[i:j]
            if (all(x in MAJ for x in mot) and len(mot) >= 2
                    and (len(mot) <= 3 or not any(x in 'AEIOUY' for x in mot))):
                out += ' ' + ' '.join(NOM_LETTRE[MAJ.index(x)] for x in mot) + ' '
            else:
                out += ''.join(chr(ord(x) + 32) if x in MAJ else x for x in mot)
        else:
            j = i + 1
            out += ',' if c in ',;:' else '.' if c in '.!' else '?' if c == '?' else ' '
        i = j
    return out


MAX_PH = 40                     # phonèmes par groupe au plus (tampon de trames)


def texte_en_groupes(texte):
    """-> liste de (phonèmes, ponctuation finale). Un groupe par virgule,
    point, point d'interrogation ; un groupe trop long est coupé entre
    deux mots, comme à une virgule."""
    groupes = []
    courant = ''
    t = normalise(texte) + '.'
    i = 0
    while i < len(t):
        c = t[i]
        if c in ',.?':
            if courant:
                groupes.append((courant, c))
            courant = ''
            i += 1
        elif c in LETTRES:
            j = i
            while j < len(t) and t[j] in LETTRES:
                j += 1
            ph = mot_en_phonemes(t[i:j])
            if courant and len(courant) + len(ph) > MAX_PH:
                groupes.append((courant, ','))
                courant = ''
            courant += ph[:MAX_PH]
            i = j
        else:
            i += 1
    return groupes


# ---------------------------------------------------------------
# Trames : (inc1, inc2, inc3, masque, a1, a2, a3, période), entiers.
# ---------------------------------------------------------------
TRANS = 3                       # trames de transition (par quarts)
DECLIN = 12                     # la période s'allonge de 12 sur un groupe
PAUSE = {',': 12, '.': 30, '?': 30}
SORTES = 'VJNFP'


def cible(p):
    F1, F2, F3, A1, A2, A3 = PH[p][:6]
    return (inc(F1), inc(F2), inc(F3), A1, A2, A3)


def groupes_en_trames(groupes, p0=62):
    trames = []
    for phon, ponct in groupes:
        der = max((k for k, p in enumerate(phon) if PH[p][9] == 'V'), default=-1)
        durs = [PH[p][6] + (PH[p][6] >> 1 if k == der else 0) for k, p in enumerate(phon)]
        total = sum(durs)
        etat = {'t': 0, 'acc': 0, 'pd': p0}

        def emet(v, masque, voise):
            r = total - etat['t']
            P = etat['pd']
            if r <= 24:
                q = 24 - r
                if ponct == '.':
                    P += (q * 3) >> 3
                elif ponct == ',':
                    P -= q >> 3
                else:
                    P -= (q * 3) >> 2
            trames.append(_trame(v, masque, P if voise else 0))
            etat['t'] += 1
            etat['acc'] += DECLIN
            while etat['acc'] >= total:
                etat['acc'] -= total
                etat['pd'] += 1

        prec = None
        for k, p in enumerate(phon):
            c = cible(p)
            dur, masque, voise, sorte = durs[k], PH[p][7], PH[p][8], PH[p][9]
            if sorte == 'P':
                for _ in range(dur - 2):          # tenue
                    emet((inc(200), c[1], c[2], 2 if voise else 0, 0, 0), 0, voise)
                for _ in range(2):                # explosion
                    emet(c, masque, 0)
            else:
                for f in range(dur):
                    if prec is not None and f < TRANS:
                        k1 = f + 1
                        v = tuple(prec[q] + ((c[q] - prec[q]) >> 2) * k1 for q in range(3)) + \
                            tuple(prec[q] + (((c[q] - prec[q]) * k1) >> 2) for q in range(3, 6))
                    else:
                        v = c
                    emet(v, masque, voise)
            prec = c
        for _ in range(PAUSE[ponct]):
            trames.append((0, 0, 0, 0, 0, 0, 0, 0))
    return trames


def _trame(v, masque, periode):
    i1, i2, i3, A1, A2, A3 = v
    while A1 + A2 + A3 > 15:          # arrondis d'une transition : crête <= 60
        if A3:
            A3 -= 1
        elif A2:
            A2 -= 1
        else:
            A1 -= 1
    m = masque >> 1
    return ((i1 - m) & 0xFFFF, (i2 - m) & 0xFFFF, (i3 - m) & 0xFFFF, masque, A1, A2, A3, periode)


# ---------------------------------------------------------------
# Table sinus x amplitude, calculée par le 6309 au démarrage :
#   SIN[a][i] = signe(S) x ((a x |S| + 8) >> 4),  S = sinus x 64
# ---------------------------------------------------------------
S64 = [round(64 * math.sin(2 * math.pi * i / 256)) for i in range(256)]
SIN = [[(1 if s >= 0 else -1) * ((a * abs(s) + 8) >> 4) for s in S64] for a in range(16)]
GRAINE = 0x1234


def synthese(trames):
    """Modèle exact de la boucle du 6309 -> échantillons 0..120.
    Hasard : x <- 5x + 13849 (période 65 536). Entre deux trames, un
    échantillon est répété : le 6309 recharge ses paramètres."""
    ph = [0, 0, 0]
    graine = GRAINE
    sortie = []
    pitch = 1
    for n, (i1, i2, i3, masque, a1, a2, a3, periode) in enumerate(trames):
        if n:                       # chargement de la trame : un échantillon
            sortie.append(sortie[-1])   # tenu (le 6309 réécrit ses opérandes)
        for _ in range(TRAME):
            pitch -= 1
            if pitch == 0:
                if periode:
                    ph = [0, 0, 0]
                    pitch = periode
                else:
                    pitch = 64
            graine = (graine * 5 + 13849) & 0xFFFF
            j = graine & masque
            ph[0] = (ph[0] + i1 + j) & 0xFFFF
            ph[1] = (ph[1] + i2 + j) & 0xFFFF
            ph[2] = (ph[2] + i3 + j) & 0xFFFF
            s = SIN[a1][ph[0] >> 8] + SIN[a2][ph[1] >> 8] + SIN[a3][ph[2] >> 8]
            sortie.append(s + MILIEU)
    return sortie


def tables_ay():
    """Échantillon 0..120 -> (volume de A, volume de C) : la somme des
    niveaux la plus proche de 2 x s / 120 ; à égalité, le couple le plus
    équilibré, puis A >= C."""
    couples = [(a, c) for a in range(16) for c in range(16)]
    ta, tc = [], []
    for s in range(2 * MILIEU + 1):
        a, c = min(couples, key=lambda p: (abs(NIVEAUX[p[0]] + NIVEAUX[p[1]] - 2 * s / (2 * MILIEU)),
                                            abs(p[0] - p[1]), -p[0]))
        ta.append(a)
        tc.append(c)
    return ta, tc


def ecrit_wav_ay(chemin, ech):
    """Ce que sort l'AY : à 14 400 Hz, la voie A prend l'échantillon à la
    première impulsion, la voie C à la seconde (comme dans Play)."""
    ta, tc = tables_ay()
    a = c = MILIEU
    data = bytearray()
    for s in [MILIEU] + ech[:-1]:
        a = s
        data += struct.pack('<h', int((NIVEAUX[ta[a]] + NIVEAUX[tc[c]] - 1) * 16000))
        c = s
        data += struct.pack('<h', int((NIVEAUX[ta[a]] + NIVEAUX[tc[c]] - 1) * 16000))
    with open(chemin, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 2 * FS, 4 * FS, 2, 16))
        f.write(b'data' + struct.pack('<I', len(data)) + data)


def ecrit_wav(chemin, ech):
    """14 400 Hz (chaque échantillon deux fois, comme la carte), filtre RC
    1,4 kHz du premier ordre, puis 16 bits."""
    rc = 1 / (2 * math.pi * 1400)
    dt = 1 / (2 * FS)
    al = dt / (rc + dt)
    y = MILIEU
    data = bytearray()
    for s in ech:
        for _ in range(2):
            y += al * (s - y)
            data += struct.pack('<h', int((y - MILIEU) * 450))
    with open(chemin, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 2 * FS, 4 * FS, 2, 16))
        f.write(b'data' + struct.pack('<I', len(data)) + data)


# ---------------------------------------------------------------
# apps/parole_data.inc
# ---------------------------------------------------------------
def octets(s):
    return ','.join('$%02X' % b for b in s.encode('latin-1'))


def genere_inc(chemin):
    codes = list(PH)
    L = []
    L.append('; ' + '=' * 67)
    L.append('; PAROLE_DATA.INC - GÉNÉRÉ par tools/parole/parole.py : NE PAS ÉDITER')
    L.append('; ' + '=' * 67)
    L.append('; Phonèmes, règles de prononciation, mots des nombres et des lettres,')
    L.append('; sinus. Modifier le script puis le relancer (--inc).')
    L.append('; Émet des octets : à inclure APRÈS le point d\'entrée.')
    L.append('; ' + '=' * 67)
    L.append('NB_PHON         equ %d' % len(codes))
    L.append('TRAME           equ %d' % TRAME)
    L.append('TRANS           equ %d' % TRANS)
    L.append('DECLIN          equ %d' % DECLIN)
    L.append('MAX_PH          equ %d' % MAX_PH)
    L.append('GRAINE          equ $%04X' % GRAINE)
    for k, s in enumerate(SORTES):
        L.append('K_%s             equ %d' % (s, k))
    L.append('PH_I200         equ %d          ; incrément de 200 Hz (tenue des occlusives)' % inc(200))
    L.append('PAUSE_VIRG      equ %d' % PAUSE[','])
    L.append('PAUSE_POINT     equ %d' % PAUSE['.'])
    L.append('')
    L.append('; Phonèmes, 16 octets : FDB inc F1, F2, F3 / FCB A1, A2, A3, durée /')
    L.append('; FDB masque / FCB voisé, sorte, symbole, 0')
    L.append('PhonTbl:')
    for c in codes:
        F1, F2, F3, A1, A2, A3, dur, m, v, k = PH[c]
        L.append('    FDB     %d,%d,%d' % (inc(F1), inc(F2), inc(F3)))
        L.append("    FCB     %d,%d,%d,%d" % (A1, A2, A3, dur))
        L.append('    FDB     $%04X' % m)
        L.append("    FCB     %d,%d,$%02X,0      ; %s" % (v, SORTES.index(k), ord(c), c))
    L.append('')
    L.append('; Règles par première lettre : FCB lettre / FDB règles ; 0 = fin')
    lettres = []
    for g, m, d, p in REGLES:
        if m[0] not in lettres:
            lettres.append(m[0])
    L.append('RegIdx:')
    for c in lettres:
        L.append('    FCB     $%02X' % ord(c))
        L.append('    FDB     Reg_%02X' % ord(c))
    L.append('    FCB     0')
    L.append('; Une règle : FCB n, gauche À L\'ENVERS / n, lettres / n, droite /')
    L.append('; n, phonèmes (indices de PhonTbl). $FF : fin des règles de la lettre.')
    for c in lettres:
        L.append('Reg_%02X:' % ord(c))
        for g, m, d, p in REGLES:
            if m[0] != c:
                continue
            champs = []
            for s in (g[::-1], m, d):
                champs.append('%d' % len(s) + (',' + octets(s) if s else ''))
            champs.append('%d' % len(p) + (',' + ','.join(str(codes.index(x)) for x in p) if p else ''))
            L.append('    FCB     ' + ','.join(champs) + '   ; ' + repr((g, m, d, p)).encode('ascii', 'replace').decode())
        L.append('    FCB     $FF')
    L.append('')
    L.append('; Mots des nombres et noms des lettres (Latin-1, 0 final)')
    def table(nom, mots):
        L.append('%s:' % nom)
        L.append('    FDB     ' + ','.join('%s_%d' % (nom, k) for k in range(len(mots))))
        for k, w in enumerate(mots):
            L.append('%s_%d:   FCB     %s' % (nom, k, octets(w) + ',0' if w else '0'))
    table('MotUnite', UNITES)
    table('MotDiz', ['', ''] + DIZAINES[2:])
    table('MotLettre', NOM_LETTRE)
    for nom, w in (('MotCent', 'cent'), ('MotMille', 'mille'), ('MotEt', 'et'),
                   ('MotEtOnze', 'et onze'), ('MotEtUn', 'et un'), ('MotQV', 'quatrevingt')):
        L.append('%s:   FCB     %s,0' % (nom, octets(w)))
    L.append('')
    L.append('; Classe de chaque caractère Latin-1 : bit 0 lettre (minuscule, accentuée),')
    L.append('; bit 1 voyelle, bit 2 majuscule A-Z, bit 3 chiffre, bit 4 e i y é è ê,')
    L.append('; bit 5 voyelle majuscule (sigles)')
    L.append('C_LETTRE        equ $01')
    L.append('C_VOY           equ $02')
    L.append('C_MAJ           equ $04')
    L.append('C_CHIF          equ $08')
    L.append('C_AVANT         equ $10')
    L.append('C_MAJVOY        equ $20')
    cl = []
    for k in range(256):
        c = chr(k)
        v = 0
        if c in LETTRES:
            v |= 1
        if c in LETTRES_V:
            v |= 2
        if c in MAJ:
            v |= 4
        if c in CHIFFRES:
            v |= 8
        if c in 'eiyéèê':
            v |= 16
        if c in 'AEIOUY':
            v |= 32
        cl.append(v)
    L.append('ClassTbl:')
    for k in range(0, 256, 16):
        L.append('    FCB     ' + ','.join('$%02X' % x for x in cl[k:k + 16]))
    L.append('')
    ta, tc = tables_ay()
    L.append('; Échantillon 0..120 -> volumes des voies A et C de l\'AY (tables_ay)')
    for nom, t in (('TabA', ta), ('TabC', tc)):
        L.append('%s:' % nom)
        for k in range(0, len(t), 16):
            L.append('    FCB     ' + ','.join(str(x) for x in t[k:k + 16]))
    L.append('')
    L.append('; Sinus x 64 (signé), 256 pas : la table sinus x amplitude en dérive')
    L.append('S64:')
    for k in range(0, 256, 16):
        L.append('    FCB     ' + ','.join(str(x) for x in S64[k:k + 16]))
    texte = '\n'.join(L) + '\n'
    if not os.path.exists(chemin) or open(chemin, encoding='utf-8').read() != texte:
        open(chemin, 'w', encoding='utf-8').write(texte)
        print('%s : écrit' % chemin)
    else:
        print('%s : inchangé' % chemin)


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--inc':
        racine = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        genere_inc(os.path.join(racine, 'apps', 'parole_data.inc'))
        sys.exit(0)
    if args and args[0] == '-p':
        for g, p in texte_en_groupes(' '.join(args[1:])):
            print(p, g)
        sys.exit(0)
    sortie = 'parole.wav'
    ancien = '--6840' in args
    if ancien:
        args.remove('--6840')
    if '-o' in args:
        k = args.index('-o')
        sortie = args[k + 1]
        del args[k:k + 2]
    texte = ' '.join(args) or 'Bonjour, je suis OSM 39. Je parle français !'
    groupes = texte_en_groupes(texte)
    for g, p in groupes:
        print(p, g)
    tr = groupes_en_trames(groupes)
    ech = synthese(tr)
    (ecrit_wav if ancien else ecrit_wav_ay)(sortie, ech)
    print('%s : %d trames, %.1f s' % (sortie, len(tr), len(ech) / FS))
