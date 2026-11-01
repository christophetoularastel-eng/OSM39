#!/usr/bin/env python3
# ===================================================================
# videotex.py - Source UNIQUE du décodeur Vidéotex de l'application MINITEL
# ===================================================================
# Ce fichier est le MODÈLE : apps/minitel.asm doit donner, octet pour
# octet, le même écran que Ecran.decode() pour le même flux (prouvé par
# test/verifie_minitel.py). Changer une règle ici, c'est la changer
# dans l'assembleur aussi.
#
#   python3 tools/minitel/videotex.py --police      # glyphes -> video/font_osm39.bin
#   python3 tools/minitel/videotex.py --inc         # apps/minitel_data.inc
#   python3 tools/minitel/videotex.py --png x.png flux.vdt [--80]   # aperçu
#
# Le décodeur remplit l'écran LOGIQUE du Minitel, 40 x 25 cases ; chaque
# case : g (code CP437, ou valeur 0-63 d'une mosaïque), t (genre : 0 texte,
# 1 mosaïque contiguë, 2 disjointe), a (attribut OSM39, bit 7 = page 1 pour
# une mosaïque). Deux rendus en sont tirés :
#   cellules40 : une case = une cellule (fenêtre 40 x 25 d'OSM-VISION) ;
#     mosaïque -> Tab_Mos40[valeur] (56 glyphes 2 x 3 + les 7 contigus
#     du 80 colonnes quand les deux colonnes sont pareilles ; le disjoint
#     y est dessiné contigu : plus de place en page 1) ;
#   cellules80 : une case = DEUX cellules (plein écran 80 x 25,
#     proportions d'un vrai Minitel) : lettre + espace, ou les deux
#     colonnes de 3 pavés d'une mosaïque (7 contigus + 7 disjoints).
# Glyphes : page 1, voir lib/ui.inc. Rangée 0 (ligne de service) comprise.
#
# Sous-ensemble du Vidéotex (STUM1B) traité, et simplifications :
#   BS HT LF VT CR FF RS US(rang,colonne) CAN REP SEP SS2 SO SI ESC
#   ESC $40-$47 couleur caractère, $50-$57 couleur de fond (immédiate,
#   même en G0), $4C-$4F taille (seule la double largeur avance de 2),
#   $59/$5A disjoint (mosaïques ; le soulignement du texte est ignoré),
#   $5C/$5D inversion. PRO1/2/3, CSI et désignations : octets sautés.
#   Curseur : invisible au départ ; CON ($11) l'allume, COFF ($14) l'éteint ;
#   il est en (lig, col). Ignorés : clignotement, masquage, double hauteur,
#   demandes d'état. US, RS et FF remettent les attributs par défaut.
#   Mode page (pas de défilement) : LF après la rangée 24 -> rangée 1.
#
# Devant l'écran, la couche TERMINAL (classe Terminal, Term_Octet dans
# minitel.asm) : ce qu'un vrai Minitel fait de la ligne avant d'afficher.
#   - Réponses au serveur (7 bits + parité paire) : PRO2 START PROCEDURE
#     (1B 3A 69 44, guetté sur les octets reçus, avant la PCE : MiniPavi le
#     répète tant qu'il n'a pas pris la réponse, même si la PCE a déjà
#     démarré chez nous) -> REP STATUS FONCTIONNEMENT 1B 3A 73 44, la PCE
#     (re)démarre au bloc 0, le bloc entamé est jeté ; STOP PROCEDURE (1B 3A 6A 44) -> 1B 3A 73 40, elle s'arrête ;
#     ENQROM (1B 39 7B) -> SOH C u 4 EOT (un Minitel 1B) ; STATUS
#     FONCTIONNEMENT (1B 39 72) -> 1B 3A 73 (40 + 4 si PCE). MiniPavi par
#     téléphone répète START toutes les 3 s tant qu'il n'a pas de réponse.
#   - PCE (procédure de correction d'erreurs, STUM1B) : blocs de 17
#     octets, 15 utiles, CRC (x^7 + x^3 + 1 sur les 8 bits de chaque
#     octet, parité comprise, poids fort d'abord ; vérifié sur 75 blocs
#     reçus de MiniPavi), NUL. Les NUL entre les blocs sont sautés ; un
#     bloc commence au premier octet non nul. Bloc juste : ses octets
#     passent à l'écran, sans les NUL ; DLE x passe x tel quel. Bloc
#     faux (CRC, ou 17e octet non nul : un octet perdu décale tout) :
#     NACK, 40 + numéro du bloc attendu (modulo 16), puis on attend SYN
#     SYN 40 + numéro, et le serveur repart de ce bloc. Sans réponse
#     pendant 1,12 s, minitel.asm renvoie le NACK (le modèle n'a pas
#     d'horloge).
#
# Couleurs : Minitel 1 rouge, 4 bleu ; OSM39 1 bleu, 4 rouge (bits 0 et 2
# échangés). Premier plan toujours clair (bit 3) : le noir devient gris
# foncé $8, ce qui évite aussi les traits roses du premier plan 0.
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
POLICE = os.path.join(RACINE, 'video', 'font_osm39.bin')
INC = os.path.join(RACINE, 'apps', 'minitel_data.inc')

LIGNES, COLONNES = 25, 40
MOS_CONT = 0x4F                 # glyphe contigu n (1..7) = MOS_CONT + n
MOS_DISJ = 0x56                 # glyphe disjoint n (1..7) = MOS_DISJ + n
# places de la page 1 pour les mosaïques du 40 colonnes (lib/ui.inc)
PLACES40 = list(range(0x5E, 0x80)) + [0x4F] + list(range(0x07, 0x20))


def gauche(v):                  # colonne gauche d'une mosaïque : pavés b0 b2 b4
    return (v & 1) | ((v >> 1) & 2) | ((v >> 2) & 4)


def droite(v):                  # colonne droite : b1 b3 b5 (b5 = bit 6 du code reçu)
    return ((v >> 1) & 1) | ((v >> 2) & 2) | ((v >> 3) & 4)


def table_mos40():
    t, libres = [], iter(PLACES40)
    for v in range(64):
        if v == 0:
            t.append(0)
        elif gauche(v) == droite(v):
            t.append(MOS_CONT + gauche(v))      # pleine largeur : le glyphe du 80 colonnes
        else:
            t.append(next(libres))
    return t


MOS40 = table_mos40()
COUL = [0, 4, 2, 6, 1, 5, 3, 7]  # couleur Minitel -> couleur OSM39

# SS2 + diacritique ($41 grave, $42 aigu, $43 circonflexe, $48 tréma,
# $4B cédille) + lettre -> code CP437 de la page 0 (absent : la lettre seule)
COMBI = {
    (0x41, 'a'): 0x85, (0x41, 'e'): 0x8A, (0x41, 'i'): 0x8D, (0x41, 'o'): 0x95, (0x41, 'u'): 0x97,
    (0x42, 'a'): 0xA0, (0x42, 'e'): 0x82, (0x42, 'i'): 0xA1, (0x42, 'o'): 0xA2, (0x42, 'u'): 0xA3,
    (0x42, 'E'): 0x90,
    (0x43, 'a'): 0x83, (0x43, 'e'): 0x88, (0x43, 'i'): 0x8C, (0x43, 'o'): 0x93, (0x43, 'u'): 0x96,
    (0x48, 'a'): 0x84, (0x48, 'e'): 0x89, (0x48, 'i'): 0x8B, (0x48, 'o'): 0x94, (0x48, 'u'): 0x81,
    (0x48, 'A'): 0x8E, (0x48, 'O'): 0x99, (0x48, 'U'): 0x9A,
    (0x4B, 'c'): 0x87, (0x4B, 'C'): 0x80,
}
# SS2 + caractère : symboles du jeu G2 -> CP437
SPECIAUX = {
    0x23: 0x9C, 0x24: 0x24, 0x26: 0x23, 0x27: 0x15, 0x2C: 0x1B, 0x2D: 0x18, 0x2E: 0x1A,
    0x2F: 0x19, 0x30: 0xF8, 0x31: 0xF1, 0x38: 0xF6, 0x3C: 0xAC, 0x3D: 0xAB, 0x3E: 0xAC,
    0x6A: 0x4F, 0x7A: 0x6F, 0x7B: 0xE1,
}
G0_SPECIAL = {0x60: 0xC4, 0x7E: 0xC4}    # barre horizontale du Minitel


class Ecran:
    def __init__(self):
        n = LIGNES * COLONNES
        self.g = bytearray([0x20] * n)
        self.t = bytearray(n)
        self.a = bytearray([0x0F] * n)
        self.lig, self.col = 1, 0
        self.raz_attributs()
        self.g1 = 0
        self.dernier = None         # (g, t, largeur) du dernier caractère posé, pour REP
        self.etat = None            # séquence en cours
        self.reste = 0
        self.diac = 0
        self.curseur = 0            # CON / COFF

    def raz_attributs(self):
        self.fg, self.bg, self.inv, self.disj, self.larg = 7, 0, 0, 0, 1
        self.g1 = 0

    def attribut(self, page1):
        f, b = COUL[self.fg], COUL[self.bg]
        if self.inv:
            f, b = b, f
        return (b << 4) | f | 8 | (0x80 if page1 else 0)

    def pose(self, g, t, larg):
        a = self.attribut(t != 0)
        i = self.lig * COLONNES + self.col
        self.g[i], self.t[i], self.a[i] = g, t, a
        if larg == 2 and self.col < COLONNES - 1:
            self.g[i + 1], self.t[i + 1], self.a[i + 1] = 0x20, 0, a
        self.dernier = (g, t, larg)
        self.avance(larg)

    def avance(self, n):
        self.col += n
        if self.col >= COLONNES:
            if self.lig == 0:
                self.col = COLONNES - 1
            else:
                self.col = 0
                self.lig = self.lig + 1 if self.lig < LIGNES - 1 else 1

    def mosaique(self, b):
        self.pose((b & 0x1F) | ((b >> 1) & 0x20), 2 if self.disj else 1, 1)

    def efface_ligne(self, lig, depuis):
        a = self.attribut(False)
        for c in range(depuis, COLONNES):
            i = lig * COLONNES + c
            self.g[i], self.t[i], self.a[i] = 0x20, 0, a

    def octet(self, o):
        o &= 0x7F
        e = self.etat
        if e is not None:
            self.etat = None
            if e == 'saute':
                self.reste -= 1
                if self.reste:
                    self.etat = 'saute'
            elif e == 'csi':
                if not 0x40 <= o <= 0x7E:
                    self.etat = 'csi'
            elif e == 'esc':
                self.echap(o)
            elif e == 'us':
                self.us_lig = o
                self.etat = 'us2'
            elif e == 'us2':
                if 0x40 <= self.us_lig <= 0x40 + LIGNES - 1 and 0x41 <= o <= 0x40 + COLONNES:
                    self.lig, self.col = self.us_lig - 0x40, o - 0x41
                    self.raz_attributs()
            elif e == 'rep':
                if self.dernier:
                    for _ in range(o & 0x3F):
                        self.pose(*self.dernier)
            elif e == 'ss2':
                if 0x41 <= o <= 0x4F:
                    self.diac = o
                elif o in SPECIAUX:
                    self.pose(SPECIAUX[o], 0, self.larg)
            return
        if o >= 0x20:
            if o == 0x7F and not self.g1:
                return
            if self.g1:
                self.mosaique(o)
                return
            c = G0_SPECIAL.get(o, o)
            if self.diac:
                c = COMBI.get((self.diac, chr(o)), c)
                self.diac = 0
            self.pose(c, 0, self.larg)
            return
        if o == 0x08:
            if self.col:
                self.col -= 1
            elif self.lig:
                self.col = COLONNES - 1
                self.lig = self.lig - 1 if self.lig > 1 else LIGNES - 1
        elif o == 0x09:
            self.avance(1)
        elif o == 0x0A:
            self.lig = self.lig + 1 if 0 < self.lig < LIGNES - 1 else 1
        elif o == 0x0B:
            self.lig = self.lig - 1 if self.lig > 1 else LIGNES - 1
        elif o == 0x0C:
            for i in range(COLONNES, LIGNES * COLONNES):
                self.g[i], self.t[i], self.a[i] = 0x20, 0, 0x0F
            self.lig, self.col = 1, 0
            self.raz_attributs()
        elif o == 0x0D:
            self.col = 0
        elif o == 0x0E:
            self.g1 = 1
        elif o == 0x0F:
            self.g1 = 0
        elif o == 0x11:
            self.curseur = 1
        elif o == 0x14:
            self.curseur = 0
        elif o == 0x12:
            self.etat = 'rep'
        elif o == 0x13:
            self.etat, self.reste = 'saute', 1
        elif o == 0x18:
            self.efface_ligne(self.lig, self.col)
        elif o == 0x19:
            self.etat = 'ss2'
        elif o == 0x1B:
            self.etat = 'esc'
        elif o == 0x1E:
            self.lig, self.col = 1, 0
            self.raz_attributs()
        elif o == 0x1F:
            self.etat = 'us'

    def echap(self, o):
        if 0x40 <= o <= 0x47:
            self.fg = o - 0x40
        elif 0x50 <= o <= 0x57:
            self.bg = o - 0x50
        elif o in (0x4C, 0x4D):
            self.larg = 1
        elif o in (0x4E, 0x4F):
            self.larg = 2
        elif o == 0x59:
            self.disj = 0
        elif o == 0x5A:
            self.disj = 1
        elif o == 0x5C:
            self.inv = 0
        elif o == 0x5D:
            self.inv = 1
        elif 0x39 <= o <= 0x3B:
            self.etat, self.reste = 'saute', o - 0x38
        elif o == 0x5B:
            self.etat = 'csi'
        elif o == 0x23:
            self.etat, self.reste = 'saute', 2
        elif 0x20 <= o <= 0x2F:
            self.etat, self.reste = 'saute', 1

    def decode(self, flux):
        for o in flux:
            self.octet(o)
        return self


# -------------------------------------------------------------------
# Couche terminal : réponses au serveur et PCE
# -------------------------------------------------------------------
NUL, DLE, NACK, SYN = 0x00, 0x10, 0x15, 0x16
ROM = b'\x01Cu4\x04'                    # réponse à ENQROM : Minitel 1B


def parite(o):
    """7 bits + parité paire au bit 7, comme le Minitel (Envoie_P)."""
    o &= 0x7F
    return o | (bin(o).count('1') & 1) << 7


def crc7(bloc):
    """Reste de la division par x^7 + x^3 + 1 des 15 octets (8 bits chacun,
    parité comprise, poids fort d'abord) suivis de 7 zéros."""
    c = 0
    for o in bloc:
        for k in range(7, -1, -1):
            r = ((c >> 6) ^ (o >> k)) & 1
            c = (c << 1) & 0x7F
            if r:
                c ^= 0x09
    return c


def blocs_pce(donnees):
    """Ce qu'envoie le serveur : les blocs de 17 octets (avec parité).
    NUL, DLE, NACK et SYN des données passent précédés de DLE ; le dernier
    bloc est complété de NUL."""
    flot = []
    for o in donnees:
        o &= 0x7F
        flot.append([DLE, o] if o in (NUL, DLE, NACK, SYN) else [o])
    blocs, b = [], []
    for unite in flot:
        if len(b) + len(unite) > 15:
            blocs.append(b + [NUL] * (15 - len(b)))
            b = []
        b += unite
    if b:
        blocs.append(b + [NUL] * (15 - len(b)))
    out = []
    for b in blocs:
        octets = bytes(parite(o) for o in b)
        out.append(octets + bytes([parite(crc7(octets)), 0]))
    return out


class Terminal:
    """La ligne -> l'écran (Ecran) et les réponses au serveur (envoi)."""

    def __init__(self):
        self.ecran = Ecran()
        self.envoi = bytearray()        # octets émis (avec parité)
        self.pce = False
        self.etat = 0                   # PCE : 0 entre deux blocs, 1 dans un bloc, 2 attend SYN SYN
        self.bloc = bytearray()
        self.num = 0                    # numéro du bloc attendu (modulo 16)
        self.syn = 0
        self.dle = False
        self.hist = b'\0\0\0'          # les trois derniers octets passés à l'écran
        self.brut = b'\0\0\0'          # les trois derniers octets reçus (7 bits)
        self.status_start = 0x44        # octet de status de la réponse à START

    def envoie(self, octets):
        self.envoi += bytes(parite(o) for o in octets)

    def octet(self, o):
        """o : l'octet reçu de la ligne (8 bits)."""
        h = self.brut + bytes([o & 0x7F])
        self.brut = h[1:]
        if h == b'\x1b\x3a\x69\x44':                  # START PROCEDURE, guetté sur la ligne
            avant = self.pce                            # même en PCE : on répond à chacun
            self.envoie([0x1B, 0x3A, 0x73, self.status_start])
            self.pce, self.etat, self.num, self.dle = True, 0, 0, False
            if not avant:
                self.livre(0x44)                        # fin de la séquence PRO2 pour l'écran
            return                                      # (en PCE : le bloc entamé est jeté)
        if not self.pce:
            self.livre(o & 0x7F)
            return
        if self.etat == 2:
            b = o & 0x7F
            if b == SYN:
                self.syn += 1
                return
            if self.syn >= 2 and b == 0x40 | self.num:
                self.etat = 0
            self.syn = 0
            return
        if self.etat == 0:
            if o & 0x7F == 0:
                return
            self.bloc = bytearray()
            self.etat = 1
        self.bloc.append(o)
        if len(self.bloc) < 17:
            return
        self.etat = 0
        b = self.bloc
        if b[16] != 0 or crc7(b[:15]) != b[15] & 0x7F:
            self.envoie([NACK, 0x40 | self.num])
            self.etat, self.syn = 2, 0
            return
        self.num = (self.num + 1) & 15
        for x in b[:15]:
            x &= 0x7F
            if self.dle:
                self.dle = False
                self.livre(x)
            elif x == DLE:
                self.dle = True
            elif x:
                self.livre(x)

    def livre(self, x):
        h = self.hist + bytes([x])
        if h == b'\x1b\x3a\x6a\x44':                  # STOP PROCEDURE
            self.envoie(b'\x1b\x3a\x73\x40')
            self.pce = False
        elif h[1:] == b'\x1b\x39\x7b':                 # ENQROM
            self.envoie(ROM)
        elif h[1:] == b'\x1b\x39\x72':                 # STATUS FONCTIONNEMENT
            self.envoie([0x1B, 0x3A, 0x73, 0x44 if self.pce else 0x40])
        self.hist = h[1:]
        self.ecran.octet(x)


def cellules40(e):
    """Fenêtre 40 x 25 : (caractères, attributs), 1000 octets chacun."""
    return (bytes(e.g[i] if e.t[i] == 0 else MOS40[e.g[i]] for i in range(LIGNES * COLONNES)), bytes(e.a))


def cellules80(e):
    """Plein écran 80 x 25 : (caractères, attributs), 2000 octets chacun."""
    c, a = bytearray(LIGNES * 80), bytearray(LIGNES * 80)
    for i in range(LIGNES * COLONNES):
        g, t = e.g[i], e.t[i]
        if t == 0:
            c[2 * i], c[2 * i + 1] = g, 0x20
        else:
            base = MOS_CONT if t == 1 else MOS_DISJ
            n, m = gauche(g), droite(g)
            c[2 * i], c[2 * i + 1] = (base + n if n else 0), (base + m if m else 0)
        a[2 * i] = a[2 * i + 1] = e.a[i]
    return bytes(c), bytes(a)


# --- glyphes des mosaïques : une demi-cellule = une colonne de 3 pavés ---
BANDES = [(0, 5), (5, 11), (11, 16)]            # lignes 0-4, 5-10, 11-15
BANDES_DISJ = [(0, 4), (5, 10), (11, 15)]       # un trait de séparation sous chaque pavé


def glyphe_mosaique(n, disjoint):
    g = bytearray(16)
    for bit, (h, b) in enumerate(BANDES_DISJ if disjoint else BANDES):
        if n >> bit & 1:
            for y in range(h, b):
                g[y] = 0xFC if disjoint else 0xFF
    return bytes(g)


def glyphe_mos40(v):
    g = bytearray(16)
    for bit, (h, b) in enumerate(BANDES):
        o = (0xF0 if gauche(v) >> bit & 1 else 0) | (0x0F if droite(v) >> bit & 1 else 0)
        for y in range(h, b):
            g[y] = o
    return bytes(g)


def ecrit_police():
    p = bytearray(open(POLICE, 'rb').read())
    for n in range(1, 8):
        for base, dj in ((MOS_CONT, False), (MOS_DISJ, True)):
            o = 4096 + (base + n) * 16
            p[o:o + 16] = glyphe_mosaique(n, dj)
    for v in range(1, 64):
        o = 4096 + MOS40[v] * 16
        if MOS40[v] in PLACES40:
            p[o:o + 16] = glyphe_mos40(v)
        assert p[o:o + 16] == glyphe_mos40(v), 'mosaïque %d : glyphe $%02X faux' % (v, MOS40[v])
    if bytes(p) != open(POLICE, 'rb').read():
        open(POLICE, 'wb').write(p)
        n40 = sum(1 for c in MOS40 if c in PLACES40)
        print('police : 14 glyphes en page 1 $%02X-$%02X, %d du 40 colonnes ($%02X-$%02X, $4F, $07-$%02X)'
              % (MOS_CONT + 1, MOS_DISJ + 7, n40, PLACES40[0], 0x7F, max(c for c in MOS40 if c < 0x20)))
    else:
        print('police : déjà à jour')


def ecrit_inc():
    L = ['; minitel_data.inc - GÉNÉRÉ par tools/minitel/videotex.py --inc : NE PAS ÉDITER',
         'MOS_CONT        equ $%02X         ; glyphe contigu n (1..7) = MOS_CONT+n (page 1)' % MOS_CONT,
         'MOS_DISJ        equ $%02X         ; glyphe disjoint n (1..7) = MOS_DISJ+n' % MOS_DISJ,
         '; couleur Minitel (0..7) -> couleur OSM39',
         'Tab_Coul        fcb ' + ','.join('$%02X' % c for c in COUL),
         '; SS2 + diacritique + lettre : diacritique, lettre, code CP437 ; 0 final',
         'Tab_Combi']
    for (d, l), c in sorted(COMBI.items()):
        L.append('        fcb $%02X,$%02X,$%02X' % (d, ord(l), c))
    L.append('        fcb 0')
    L.append('; SS2 + symbole : code G2, code CP437 ; 0 final')
    L.append('Tab_Speciaux')
    for g, c in sorted(SPECIAUX.items()):
        L.append('        fcb $%02X,$%02X' % (g, c))
    L.append('        fcb 0')
    L.append('; mosaïque (valeur 0-63) -> glyphe de la page 1, fenêtre 40 colonnes')
    L.append('Tab_Mos40')
    for k in range(0, 64, 8):
        L.append('        fcb ' + ','.join('$%02X' % c for c in MOS40[k:k + 8]))
    L.append('; G0 : caractères remplacés (code, CP437) ; 0 final')
    L.append('Tab_G0')
    for g, c in sorted(G0_SPECIAL.items()):
        L.append('        fcb $%02X,$%02X' % (g, c))
    L.append('        fcb 0')
    texte = '\n'.join(L) + '\n'
    if not os.path.exists(INC) or open(INC).read() != texte:
        open(INC, 'w').write(texte)
        print('écrit', INC)
    else:
        print(INC, 'déjà à jour')


def png(chemin, e, mode=40):
    from PIL import Image
    pal = [(0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170), (170, 0, 0),
           (170, 0, 170), (170, 85, 0), (170, 170, 170)]
    pal += [(85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
            (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255)]
    pol = open(POLICE, 'rb').read()
    larg = 80 if mode == 80 else COLONNES
    chr_, att = cellules80(e) if mode == 80 else cellules40(e)
    im = Image.new('RGB', (larg * 8, LIGNES * 16))
    px = im.load()
    for i in range(LIGNES * larg):
        c, a = chr_[i], att[i]
        g = pol[(4096 if a & 0x80 else 0) + c * 16:][:16]
        x0, y0 = (i % larg) * 8, (i // larg) * 16
        for y in range(16):
            for x in range(8):
                px[x0 + x, y0 + y] = pal[a & 15] if g[y] & (0x80 >> x) else pal[(a >> 4) & 7]
    im.save(chemin)


def main():
    a = sys.argv[1:]
    if '--police' in a:
        ecrit_police()
    if '--inc' in a:
        ecrit_inc()
    if '--png' in a:
        i = a.index('--png')
        png(a[i + 1], Ecran().decode(open(a[i + 2], 'rb').read()), 80 if '--80' in a else 40)
    if not a:
        print(__doc__ or 'voir l\'en-tête du fichier')


if __name__ == '__main__':
    main()
