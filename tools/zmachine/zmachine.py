#!/usr/bin/env python3
"""ZMACHINE - modèle de référence d'un interpréteur Z-machine v5/v8 pour OSM39.

Source unique du comportement du futur binaire 6309 (comme parole.py ou
donjon39.py) : décodage des instructions, objets, texte, dictionnaire, et
l'écran exact (grille de caractères + attributs OSM39) que le 6309 devra
produire. Standard suivi : Z-Machine Standard 1.1, versions 3, 4, 5, 7 et 8
(pas la 6). En v3 : objets de 9 octets, clés de 4 octets, saisie terminée
par 0, @save/@restore en branchements, et la ligne d'état dessinée par
l'interpréteur en rangée 0 (lieu ; « Score: s  Moves: t » ou « Time: »).

Utilisation :
  python3 zmachine.py JEU.z5                 jouer dans le terminal (grille 80 x 30)
  python3 zmachine.py JEU.z5 --brut          texte brut, sans grille (comme dfrotz)
  python3 zmachine.py JEU.z5 --script F      lignes de F en entrée, puis fin
  python3 zmachine.py czech.z5 --czech czech.out5
                                             la sortie doit égaler la référence
                                             (lignes d'en-tête exceptées)

Choix d'OSM39 (le 6309 fera exactement pareil) :
  - écran LARGEUR x HAUTEUR (80 x 30) ; fenêtre du haut (1) sans retour à
    la ligne (coupée à droite et en bas de l'ÉCRAN, pas à sa hauteur :
    Z-Snake dessine partout sans @split_window, comme frotz le permet), fenêtre du bas (0) avec coupure aux mots
    quand le tampon est actif, défilement de la seule fenêtre du bas,
    « [Suite] » quand une page entière a défilé sans saisie ;
  - attribut OSM39 : fond D4-D6, encre D0-D2, D3 = atténué. Texte normal
    atténué, gras/italique pleine intensité, inverse = encre et fond
    échangés ; une encre noire s'écrit $8 (défaut matériel de l'encre 0) ;
  - caractères : Unicode -> CP437 (la police de la page 0), sinon « ? » ;
  - hasard : xorshift 16 bits (7, 9, 8) ; graine au lancement = le compteur
    de trames (vsync_tick, jamais 0), @restart la garde ; tirage =
    (x mod n) + 1 ; une graine < 1000 donne la suite 1, 2... n, 1, 2...
  - pas d'annulation (pas de place en RAM) : @save_undo rend -1, @restore_undo
    rend 0, et le bit 4 de Flags 2 (« le jeu veut UNDO ») est remis à 0 ;
  - @save / @restore : format Quetzal (IFhd, UMem non compressée, Stks),
    lisible par frotz ; @restore lit aussi CMem. Le nom est demandé dans la
    fenêtre du bas (PROMPT_FICHIER, puis une saisie comme @read) ; sans
    point, « .SAV » est ajouté ; en majuscules ; vide = échec.
"""
import argparse
import os
import select
import sys

LARGEUR, HAUTEUR = 80, 30
PROMPT_FICHIER = 'Fichier : '
DEFAUT_UNICODE = ('äöüÄÖÜß»«ëïÿËÏáéíóúýÁÉÍÓÚÝàèìòùÀÈÌÒÙâêîôûÂÊÎÔÛåÅøØãñõÃÑÕæÆçÇþðÞÐ£œŒ¡¿')
A0 = 'abcdefghijklmnopqrstuvwxyz'
A1 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
A2 = ' \n0123456789.,!?_#\'"/\\-:()'       # positions 6.. (6 = échappement, 7 = \n)

# Unicode -> CP437 (police page 0 d'OSM39)
CP437 = {}
for i, c in enumerate(bytes(range(128, 256)).decode('cp437')):
    CP437[c] = 128 + i
for i in range(32, 127):
    CP437[chr(i)] = i


class Dossier(dict):
    """Les fichiers de sauvegarde dans un dossier du PC (pour jouer dans le terminal)."""

    def __init__(self, chemin='.'):
        super().__init__()
        self.chemin = chemin

    def __contains__(self, nom):
        return os.path.exists(os.path.join(self.chemin, nom))

    def __getitem__(self, nom):
        return open(os.path.join(self.chemin, nom), 'rb').read()

    def __setitem__(self, nom, octets):
        open(os.path.join(self.chemin, nom), 'wb').write(octets)


class Fin(Exception):
    pass


class ErreurZ(Exception):
    pass


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


# --------------------------------------------------------------------------
# Écran : la grille d'OSM39
# --------------------------------------------------------------------------
Z_COUL = {2: 0, 3: 4, 4: 2, 5: 6, 6: 1, 7: 5, 8: 3, 9: 7}    # Z -> bits OSM (D0 bleu, D1 vert, D2 rouge)


class Grille:
    """La grille exacte que le 6309 doit écrire en VRAM : (caractère CP437, attribut)."""

    def __init__(self, largeur=LARGEUR, hauteur=HAUTEUR, suite_auto=True):
        self.L, self.H = largeur, hauteur
        self.encre, self.fond = 9, 2          # couleurs Z courantes (blanc sur noir)
        self.style = 0
        self.base = 0                         # 1 en v3 : la rangée 0 est la ligne d'état
        self.haut = 0                         # première rangée de la fenêtre 0 (= base + fenêtre 1)
        self.fen = 0
        self.ux = self.uy = 0                 # curseur fenêtre 1
        self.x = self.y = 0                   # curseur fenêtre 0
        self.tampon = True
        self.mot = []
        self.lignes = 0                       # lignes défilées depuis la dernière saisie
        self.suite_auto = suite_auto
        self.suites = 0
        self.cases = [[(32, self.attr())] * self.L for _ in range(self.H)]
        self.attendre_touche = None           # fonction fournie par la machine (pour [Suite])

    def attr(self, style=None):
        style = self.style if style is None else style
        e, f = Z_COUL[self.encre], Z_COUL[self.fond]
        if style & 1:
            e, f = f, e
        e |= 0 if style & 6 else 8            # normal atténué ; gras/italique plein
        if e & 7 == 0:
            e = 8
        return f << 4 | e

    def efface_lignes(self, y0, y1):
        a = self.attr(0)
        for y in range(y0, y1):
            self.cases[y] = [(32, a)] * self.L

    def efface_fenetre(self, n):
        self.vide_mot()
        if n in (-1, -2):
            if n == -1:
                self.haut = self.base
            self.efface_lignes(self.base, self.H)
            self.x, self.y = 0, self.haut
            self.ux, self.uy = 0, self.base
            self.fen = 0 if n == -1 else self.fen
            self.lignes = 0
        elif n == 0:
            self.efface_lignes(self.haut, self.H)
            self.x, self.y = 0, self.haut
            self.lignes = 0
        elif n == 1:
            self.efface_lignes(self.base, self.haut)
            self.ux, self.uy = 0, self.base

    def coupe(self, n):
        self.vide_mot()
        self.haut = max(self.base, min(self.base + n, self.H))
        if self.uy >= self.haut:
            self.ux, self.uy = 0, self.base
        if self.y < self.haut:
            self.x, self.y = 0, self.haut

    def choisit(self, w):
        self.vide_mot()
        self.fen = w
        if w == 1:
            self.ux, self.uy = 0, self.base

    def curseur(self, ligne, col):
        if self.fen == 1:
            self.vide_mot()
            self.uy = self.base + max(0, ligne - 1)
            self.ux = max(0, col - 1)

    def lit_curseur(self):
        if self.fen == 1:
            return self.uy - self.base + 1, self.ux + 1
        return self.y + 1, self.x + 1

    def ligne_etat(self, gauche, droite):
        """v3 : la rangée 0 en inverse, le lieu à gauche (colonne 1), le score
        ou l'heure à droite (finissant colonne L-2)."""
        a = self.attr(1)
        r = [(32, a)] * self.L
        for i, u in enumerate(gauche):
            r[1 + i] = (CP437.get(u, ord('?')), a)
        for i, u in enumerate(droite):
            r[self.L - 1 - len(droite) + i] = (CP437.get(u, ord('?')), a)
        self.cases[0] = r

    def efface_ligne(self):
        a = self.attr(0)
        if self.fen == 1:
            if self.uy < self.H:
                for x in range(self.ux, self.L):
                    self.cases[self.uy][x] = (32, a)
        else:
            self.vide_mot()
            for x in range(self.x, self.L):
                self.cases[self.y][x] = (32, a)

    # --- fenêtre du bas -----------------------------------------------
    def defile(self):
        h0 = self.haut
        if h0 >= self.H - 1:
            return
        del self.cases[h0]
        self.cases.insert(self.H - 1, [(32, self.attr(0))] * self.L)

    def nouvelle_ligne(self):
        self.x = 0
        if self.y < self.H - 1:
            self.y += 1
        else:
            self.defile()
        self.lignes += 1
        if self.lignes >= self.H - self.haut - 1:
            self.suite()

    def suite(self):
        """Une page a défilé sans saisie : « [Suite] » et une touche."""
        self.lignes = 0
        self.suites += 1
        a = self.attr(1)
        texte = '[Suite]'
        sauve = list(self.cases[self.y])
        for i, c in enumerate(texte):
            self.cases[self.y][i] = (ord(c), a)
        if not self.suite_auto and self.attendre_touche:
            self.attendre_touche()
        self.cases[self.y] = sauve

    def pose(self, c, a):
        if self.x >= self.L:
            self.nouvelle_ligne()
        self.cases[self.y][self.x] = (c, a)
        self.x += 1

    def vide_mot(self):
        mot, self.mot = self.mot, []
        if not mot:
            return
        if self.x + len(mot) > self.L and self.x > 0:
            self.nouvelle_ligne()
        for c, a in mot:
            self.pose(c, a)

    def car(self, u):
        """Un caractère Unicode (ou '\\n') vers la fenêtre courante."""
        c = CP437.get(u, ord('?')) if u != '\n' else 10
        a = self.attr()
        if self.fen == 1:
            if u == '\n':
                self.uy += 1
                self.ux = 0
            else:
                if self.uy < self.H and self.ux < self.L:     # (comme frotz : pas coupée à Haut)
                    self.cases[self.uy][self.ux] = (c, a)
                self.ux += 1
            return
        if not self.tampon:
            if u == '\n':
                self.nouvelle_ligne()
            else:
                self.pose(c, a)
            return
        if u == '\n':
            self.vide_mot()
            self.nouvelle_ligne()
        elif u == ' ':
            self.vide_mot()
            if self.x >= self.L:
                self.nouvelle_ligne()
            else:
                self.pose(c, a)
        else:
            self.mot.append((c, a))

    def saisie_debut(self):
        self.vide_mot()
        self.lignes = 0

    def echo(self, u):
        if u == '\n':
            self.nouvelle_ligne()
            self.lignes = 0
        else:
            self.pose(CP437.get(u, ord('?')), self.attr())

    def recul(self):
        if self.x > 0:
            self.x -= 1
            self.cases[self.y][self.x] = (32, self.attr())

    def texte(self):
        """La grille en texte (CP437 décodé), une ligne par rangée."""
        return '\n'.join(bytes(c for c, a in r).decode('cp437').rstrip() for r in self.cases)

    def ansi(self):
        tc = [30, 34, 32, 36, 31, 35, 33, 37]
        out = ['\x1b[H']
        for r in self.cases:
            prec = None
            for c, a in r:
                if a != prec:
                    e, f = a & 7, a >> 4 & 7
                    out.append('\x1b[0;%d;%d%sm' % (tc[e], tc[f] + 10, '' if a & 8 else ';1'))
                    prec = a
                out.append(bytes([c]).decode('cp437') if c >= 32 else ' ')
            out.append('\x1b[0m\n')
        return ''.join(out)


class Brut:
    """Sortie brute (flux 1 en texte), pour comparer avec czech.out5 ou dfrotz."""

    def __init__(self, vers=None):
        self.morceaux = []
        self.vers = vers
        self.haut = 0
        self.fen = 0
        self.tampon = True
        self.attendre_touche = None
        self.style, self.encre, self.fond = 0, 9, 2

    def car(self, u):
        if self.fen == 1:
            return                             # la fenêtre du haut (ligne d'état) est ignorée
        self.morceaux.append(u)
        if self.vers:
            self.vers.write(u)

    def __getattr__(self, nom):                # toutes les opérations d'écran : sans effet
        return lambda *a, **k: (1, 1) if nom == 'lit_curseur' else None

    def choisit(self, w):
        self.fen = w

    def echo(self, u):
        self.car(u)

    def texte(self):
        return ''.join(self.morceaux)


# --------------------------------------------------------------------------
# Entrées
# --------------------------------------------------------------------------
class EntreeScript:
    """Le clavier d'un script : les lignes, chacune suivie d'Entrée, en un seul
    flux de touches (comme le vrai clavier : @read_char en prend une, @read
    jusqu'à Entrée ; au-delà de la place, les touches sont perdues). Plus de
    touches : fin."""

    def __init__(self, lignes, touches=''):
        self.flux = list(touches)
        for ligne in lignes:                    # None : un délai qui s'écoule
            self.flux += [None] if ligne is None else list(ligne) + ['\r']

    def ligne(self, maxi, dixiemes):
        t = []
        while True:
            if not self.flux:
                raise Fin()
            c = self.flux.pop(0)
            if c is None:                       # délai écoulé (si délai demandé)
                if dixiemes:
                    return None
                continue
            if c == '\r':
                return ''.join(t)[:maxi], 13
            t.append(c)

    def touche(self, dixiemes):
        while True:
            if not self.flux:
                raise Fin()
            c = self.flux.pop(0)
            if c is not None or dixiemes:       # None : délai écoulé
                return c


class EntreeTerminal:
    def __init__(self, ecran):
        self.ecran = ecran

    def montre(self):
        if isinstance(self.ecran, Grille):
            sys.stdout.write(self.ecran.ansi())
            sys.stdout.write('\x1b[%d;%dH' % (self.ecran.y + 1, self.ecran.x + 1))
            sys.stdout.flush()

    def ligne(self, maxi, dixiemes):
        self.montre()
        try:
            t = input()
        except EOFError:
            raise Fin()
        return t[:maxi], 13

    def touche(self, dixiemes):
        import termios
        import tty
        self.montre()
        fd = sys.stdin.fileno()
        ancien = termios.tcgetattr(fd)
        try:
            tty.setcbreak(fd)
            r, _, _ = select.select([fd], [], [], dixiemes / 10 if dixiemes else None)
            if not r:
                return None
            c = os.read(fd, 8).decode('utf-8', 'replace')
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, ancien)
        fleches = {'\x1b[A': 129, '\x1b[B': 130, '\x1b[D': 131, '\x1b[C': 132}
        if c in fleches:
            return fleches[c]
        return c[0]


# --------------------------------------------------------------------------
# La machine
# --------------------------------------------------------------------------
class ZMachine:
    def __init__(self, histoire, ecran, entree, largeur=LARGEUR, hauteur=HAUTEUR,
                 graine=1, fichiers=None):
        self.histoire = bytes(histoire)
        self.v = self.histoire[0]
        if self.v not in (3, 4, 5, 7, 8):
            raise ErreurZ('version %d non prise en charge' % self.v)
        self.ecran, self.entree = ecran, entree
        self.L, self.H = largeur, hauteur
        self.nb_instr = 0
        self.fichiers = {} if fichiers is None else fichiers   # nom -> octets (la carte)
        self.alea = graine & 0xFFFF or 1
        self.alea_seq = 0                        # > 0 : mode prévisible
        self.alea_n = 0
        if self.v <= 3:                          # la ligne d'état occupe la rangée 0
            ecran.base = ecran.haut = ecran.y = 1
        self.demarre()

    # --- démarrage / en-tête -----------------------------------------------
    def demarre(self, garde_flags2=None):
        self.m = bytearray(self.histoire)
        if garde_flags2 is not None:
            self.m[0x11] = (self.m[0x11] & ~3) | (garde_flags2 & 3)
        self.entete()
        self.pile = []
        self.cadres = [dict(retour=None, stocke=None, locales=[], base=0, nargs=0)]
        self.pc = self.mot(6)
        self.flux3 = []
        self.flux1 = True

    def entete(self):
        m = self.m
        if self.v <= 3:                            # ligne d'état et fenêtres : oui ; police fixe
            m[1] = (m[1] | 0x20) & ~(0x10 | 0x40)
        else:
            m[1] = (m[1] | 0x01 | 0x04 | 0x08 | 0x10 | 0x80) & ~0x22    # couleurs, gras, italique, fixe, délai
            m[0x1E], m[0x1F] = 6, ord('A')
            m[0x20], m[0x21] = self.H, self.L
            self.ecrit_mot(0x22, self.L)
            self.ecrit_mot(0x24, self.H)
            m[0x26], m[0x27] = 1, 1
            m[0x2C], m[0x2D] = 2, 9
        m[0x11] &= ~(0x08 | 0x10 | 0x20 | 0x80)                      # ni images, ni UNDO, ni souris, ni son
        m[0x32], m[0x33] = 1, 1                    # standard 1.1
        self.statique = self.mot(0x0E)
        self.globales = self.mot(0x0C)
        self.objets = self.mot(0x0A)
        self.abrev = self.mot(0x18)
        self.dico = self.mot(0x08)
        self.mult = 2 if self.v <= 3 else (8 if self.v == 8 else 4)
        self.unicode = DEFAUT_UNICODE
        ext = self.mot(0x36)
        if ext and self.mot(ext) >= 3 and self.mot(ext + 6):
            t = self.mot(ext + 6)
            self.unicode = ''.join(chr(self.mot(t + 1 + 2 * i)) for i in range(min(m[t], 97)))
        alpha = self.mot(0x34)
        if alpha:
            t = ''.join(self.zscii(b) for b in m[alpha:alpha + 78])  # des codes ZSCII
            self.alphabets = [t[0:26], t[26:52], ' \n' + t[54:78]]
        else:
            self.alphabets = [A0, A1, A2]

    # --- mémoire --------------------------------------------------------
    def octet(self, a):
        return self.m[a & 0xFFFFF] if a < len(self.m) else 0

    def mot(self, a):
        return self.octet(a) << 8 | self.octet(a + 1)

    def ecrit_octet(self, a, v):
        a &= 0xFFFF
        if a >= self.statique and a >= 0x40:
            raise ErreurZ('écriture en mémoire statique $%04X' % a)
        self.m[a] = v & 0xFF

    def ecrit_mot(self, a, v):
        a &= 0xFFFF
        self.m[a] = v >> 8 & 0xFF
        self.m[a + 1] = v & 0xFF

    def ecrit_mot_z(self, a, v):
        self.ecrit_octet(a, v >> 8)
        self.ecrit_octet(a + 1, v)

    # --- variables -------------------------------------------------------
    def lit_var(self, n):
        if n == 0:
            if len(self.pile) <= self.cadres[-1]['base']:
                raise ErreurZ('pile vide')
            return self.pile.pop()
        if n < 16:
            return self.cadres[-1]['locales'][n - 1]
        return self.mot(self.globales + 2 * (n - 16))

    def ecrit_var(self, n, v):
        v &= 0xFFFF
        if n == 0:
            self.pile.append(v)
        elif n < 16:
            self.cadres[-1]['locales'][n - 1] = v
        else:
            self.ecrit_mot(self.globales + 2 * (n - 16), v)

    def lit_var_ind(self, n):                    # référence indirecte : la pile lue sur place
        if n == 0:
            return self.pile[-1]
        return self.lit_var(n)

    def ecrit_var_ind(self, n, v):
        if n == 0:
            self.pile[-1] = v & 0xFFFF
        else:
            self.ecrit_var(n, v)

    # --- décodage --------------------------------------------------------
    def octet_pc(self):
        b = self.octet(self.pc)
        self.pc += 1
        return b

    def mot_pc(self):
        w = self.mot(self.pc)
        self.pc += 2
        return w

    def operandes(self, types):
        ops = []
        for t in types:
            if t == 0:
                ops.append(self.mot_pc())
            elif t == 1:
                ops.append(self.octet_pc())
            elif t == 2:
                ops.append(self.lit_var(self.octet_pc()))
        return ops

    def stocke(self, v):
        self.ecrit_var(self.octet_pc(), v)

    def branche(self, cond):
        b = self.octet_pc()
        sur_vrai = b & 0x80
        if b & 0x40:
            dep = b & 0x3F
        else:
            dep = (b & 0x3F) << 8 | self.octet_pc()
            if dep & 0x2000:
                dep -= 0x4000
        if bool(cond) == bool(sur_vrai):
            if dep in (0, 1):
                self.retour(dep)
            else:
                self.pc += dep - 2

    def adr_paquee(self, p):
        return p * self.mult

    # --- appels -----------------------------------------------------------
    def appel(self, routine, args, stocke):
        """stocke : numéro de variable, ou None (call_*n)."""
        if routine == 0:
            if stocke is not None:
                self.ecrit_var(stocke, 0)
            return
        a = self.adr_paquee(routine)
        n = self.octet(a)
        if self.v <= 4:                          # v1-4 : valeurs initiales dans l'en-tête
            locales = [self.mot(a + 1 + 2 * i) for i in range(n)]
            debut = a + 1 + 2 * n
        else:
            locales = [0] * n
            debut = a + 1
        for i, v in enumerate(args[:n]):
            locales[i] = v
        self.cadres.append(dict(retour=self.pc, stocke=stocke, locales=locales,
                                base=len(self.pile), nargs=len(args)))
        self.pc = debut

    def appel_interne(self, routine, args=()):
        """Appel d'une routine depuis l'interpréteur (délai de saisie) : rend sa valeur."""
        prof = len(self.cadres)
        self.appel(routine, list(args), -1)
        while len(self.cadres) > prof:
            self.pas()
        return self.valeur_interne

    def retour(self, v):
        c = self.cadres.pop()
        del self.pile[c['base']:]
        self.pc = c['retour']
        if c['stocke'] == -1:
            self.valeur_interne = v & 0xFFFF
        elif c['stocke'] is not None:
            self.ecrit_var(c['stocke'], v)

    # --- objets ----------------------------------------------------------
    def obj(self, o):
        if o == 0:
            raise ErreurZ('objet 0')
        if self.v <= 3:                          # 9 octets : 32 attributs, liens sur 1 octet
            return self.objets + 62 + 9 * (o - 1)
        return self.objets + 126 + 14 * (o - 1)

    def lien(self, o, k):
        """k = 0 parent, 1 frère, 2 enfant."""
        if self.v <= 3:
            return self.octet(self.obj(o) + 4 + k)
        return self.mot(self.obj(o) + 6 + 2 * k)

    def ecrit_lien(self, o, k, v):
        if self.v <= 3:
            self.ecrit_octet(self.obj(o) + 4 + k, v)
        else:
            self.ecrit_mot(self.obj(o) + 6 + 2 * k, v)

    def parent(self, o):
        return self.lien(o, 0)

    def frere(self, o):
        return self.lien(o, 1)

    def enfant(self, o):
        return self.lien(o, 2)

    def table_prop(self, o):
        return self.mot(self.obj(o) + (7 if self.v <= 3 else 12))

    def ote(self, o):
        p = self.parent(o)
        if p == 0:
            return
        if self.enfant(p) == o:
            self.ecrit_lien(p, 2, self.frere(o))
        else:
            c = self.enfant(p)
            while c:
                s = self.frere(c)
                if s == o:
                    self.ecrit_lien(c, 1, self.frere(o))
                    break
                c = s
        self.ecrit_lien(o, 0, 0)
        self.ecrit_lien(o, 1, 0)

    def insere(self, o, dest):
        self.ote(o)
        self.ecrit_lien(o, 1, self.enfant(dest))
        self.ecrit_lien(o, 0, dest)
        self.ecrit_lien(dest, 2, o)

    def props(self, o):
        """(numéro, adresse des données, longueur) de chaque propriété, dans l'ordre."""
        a = self.table_prop(o)
        a += 1 + 2 * self.octet(a)
        while True:
            b = self.octet(a)
            if b == 0:
                return
            if self.v <= 3:                      # v3 : numéro bits 0-4, longueur - 1 bits 5-7
                n, lg = b & 31, (b >> 5) + 1
                a += 1
            elif b & 0x80:
                n = b & 0x3F
                lg = self.octet(a + 1) & 0x3F or 64
                a += 2
            else:
                n = b & 0x3F
                lg = 2 if b & 0x40 else 1
                a += 1
            yield n, a, lg
            a += lg

    def trouve_prop(self, o, p):
        for n, a, lg in self.props(o):
            if n == p:
                return a, lg
            if n < p:
                break
        return 0, 0

    def long_prop(self, a):
        if a == 0:
            return 0
        b = self.octet(a - 1)
        if self.v <= 3:
            return (b >> 5) + 1
        if b & 0x80:
            return b & 0x3F or 64
        return 2 if b & 0x40 else 1

    # --- texte -----------------------------------------------------------
    def zchars(self, a):
        zs = []
        while True:
            w = self.mot(a)
            a += 2
            zs += [(w >> 10) & 31, (w >> 5) & 31, w & 31]
            if w & 0x8000:
                return zs, a

    def decode(self, a, abrev=True):
        zs, fin = self.zchars(a)
        out = []
        alpha = 0
        i = 0
        while i < len(zs):
            z = zs[i]
            i += 1
            if z == 0:
                out.append(' ')
            elif z in (1, 2, 3):
                if i >= len(zs):
                    break
                if not abrev:
                    raise ErreurZ('abréviation dans une abréviation')
                n = 32 * (z - 1) + zs[i]
                i += 1
                t, _ = self.decode(self.mot(self.abrev + 2 * n) * 2, False)
                out.append(t)
            elif z == 4:
                alpha = 1
                continue
            elif z == 5:
                alpha = 2
                continue
            elif alpha == 2 and z == 6:              # ZSCII sur 10 bits
                if i + 2 > len(zs):
                    break
                out.append(self.zscii(zs[i] << 5 | zs[i + 1]))
                i += 2
            else:
                out.append(self.alphabets[alpha][z - 6] if not (alpha == 2 and z == 7) else '\n')
            alpha = 0
        return ''.join(out), fin

    def zscii(self, c):
        if c == 13:
            return '\n'
        if 32 <= c <= 126:
            return chr(c)
        if 155 <= c < 155 + len(self.unicode):
            return self.unicode[c - 155]
        if c == 0:
            return ''
        return '?'

    def vers_zscii(self, u):
        if u in ('\n', '\r'):
            return 13
        o = ord(u)
        if 32 <= o <= 126:
            return o
        if u in self.unicode:
            return 155 + self.unicode.index(u)
        return ord('?')

    def encode(self, texte):
        """Texte (minuscules ZSCII) -> la clé du dictionnaire : 6 octets (9
        caractères Z), 4 octets (6 caractères Z) en v1-3."""
        nz = 6 if self.v <= 3 else 9
        zs = []
        for c in texte:
            if c in self.alphabets[0]:
                zs.append(6 + self.alphabets[0].index(c))
            elif c in self.alphabets[1]:
                zs += [4, 6 + self.alphabets[1].index(c)]
            elif c in self.alphabets[2][2:] and c != '\n':
                zs += [5, 8 + self.alphabets[2][2:].index(c)]
            else:
                z = self.vers_zscii(c)
                zs += [5, 6, z >> 5, z & 31]
            if len(zs) >= nz:
                break
        zs = (zs + [5] * nz)[:nz]
        mots = [(zs[i] << 10) | (zs[i + 1] << 5) | zs[i + 2] for i in range(0, nz, 3)]
        mots[-1] |= 0x8000
        return b''.join(w.to_bytes(2, 'big') for w in mots)

    # --- sortie ------------------------------------------------------------
    def imprime(self, texte):
        for u in texte:
            if self.flux3:
                table, n = self.flux3[-1]
                z = self.vers_zscii(u) if u != '\n' else 13
                self.ecrit_octet(table + 2 + n, z)
                self.flux3[-1] = (table, n + 1)
            elif self.flux1:
                self.ecran.car(u)

    # --- dictionnaire et saisie ----------------------------------------------
    def decoupe(self, texte_buf, analyse, dico=0, sauf_inconnus=False):
        dico = dico or self.dico
        n_sep = self.octet(dico)
        seps = bytes(self.m[dico + 1:dico + 1 + n_sep])
        lg_entree = self.octet(dico + 1 + n_sep)
        nb = s16(self.mot(dico + 2 + n_sep))
        entrees = dico + 4 + n_sep
        if self.v <= 4:                          # v1-4 : le texte en +1, fini par 0
            debut = texte_buf + 1
            lg = 0
            while self.octet(debut + lg):
                lg += 1
        else:
            debut = texte_buf + 2
            lg = self.octet(texte_buf + 1)
        txt = bytes(self.m[debut:debut + lg])
        mots = []
        i = 0
        while i < lg:
            c = txt[i]
            if c == 32:
                i += 1
            elif c in seps:
                mots.append((i, 1))
                i += 1
            else:
                d = i
                while i < lg and txt[i] != 32 and txt[i] not in seps:
                    i += 1
                mots.append((d, i - d))
        maxi = self.octet(analyse)
        mots = mots[:maxi]
        self.ecrit_octet(analyse + 1, len(mots))
        for k, (d, n) in enumerate(mots):
            cle = self.encode(''.join(self.zscii(b) for b in txt[d:d + n]))
            trouve = 0
            if nb > 0:
                bas, haut = 0, nb - 1
                while bas <= haut:
                    mil = (bas + haut) // 2
                    a = entrees + mil * lg_entree
                    e = bytes(self.m[a:a + len(cle)])
                    if e == cle:
                        trouve = a
                        break
                    if e < cle:
                        bas = mil + 1
                    else:
                        haut = mil - 1
            else:
                for j in range(-nb):
                    a = entrees + j * lg_entree
                    if bytes(self.m[a:a + len(cle)]) == cle:
                        trouve = a
                        break
            b = analyse + 2 + 4 * k
            if trouve or not sauf_inconnus:
                self.ecrit_mot_z(b, trouve)
                self.ecrit_octet(b + 2, n)
                self.ecrit_octet(b + 3, d + debut - texte_buf)

    def lit_ligne(self, texte_buf, analyse, dixiemes, routine):
        if self.v <= 3:
            self.etat()
        self.ecran.saisie_debut()
        if self.v <= 4:                          # v1-4 : octet 0 = place + 1, texte en +1
            maxi, deja = max(0, self.octet(texte_buf) - 1), 0
        else:
            maxi = self.octet(texte_buf)
            deja = self.octet(texte_buf + 1)
        while True:
            r = self.entree.ligne(maxi - deja, dixiemes if routine else 0)
            if r is not None:
                break
            if self.appel_interne(routine):          # délai écoulé, la routine dit d'arrêter
                self.ecrit_octet(texte_buf + 1, 0)
                return 0
        ligne, term = r
        for u in ligne:
            self.ecran.echo(u)
        self.ecran.echo('\n')
        if self.flux3:
            pass
        txt = [self.vers_zscii(u.lower()) for u in ligne]
        if self.v <= 4:
            for i, z in enumerate(txt + [0]):
                self.ecrit_octet(texte_buf + 1 + i, z)
        else:
            for i, z in enumerate(txt):
                self.ecrit_octet(texte_buf + 2 + deja + i, z)
            self.ecrit_octet(texte_buf + 1, deja + len(txt))
        if analyse:
            self.decoupe(texte_buf, analyse)
        return term

    def lit_touche(self, dixiemes, routine):
        self.ecran.saisie_debut()
        while True:
            t = self.entree.touche(dixiemes if routine else 0)
            if t is not None:
                break
            if self.appel_interne(routine):
                return 0
        if isinstance(t, int):
            return t
        if t in ('\r', '\n'):
            return 13
        if t in ('\x7f', '\x08'):
            return 8
        if t == '\x1b':
            return 27
        return self.vers_zscii(t)

    # --- hasard ---------------------------------------------------------------
    def hasard(self, n):
        n = s16(n)
        if n < 0:
            if -n < 1000:
                self.alea_seq, self.alea_n = -n, 0
            else:
                self.alea_seq = 0
                self.alea = (-n) & 0xFFFF or 1
            return 0
        if n == 0:
            self.alea_seq = 0
            self.alea = 1
            return 0
        if self.alea_seq:
            self.alea_n = self.alea_n % self.alea_seq + 1
            return (self.alea_n - 1) % n + 1
        x = self.alea
        x ^= (x << 7) & 0xFFFF
        x ^= x >> 9
        x ^= (x << 8) & 0xFFFF
        self.alea = x
        return x % n + 1

    # --- une instruction ---------------------------------------------------------
    def pas(self):
        self.nb_instr += 1
        debut = self.pc
        b = self.octet_pc()
        if b == 0xBE:
            op = self.octet_pc()
            ops = self.operandes(self.types_lus())
            return self.etendu(op, ops)
        if b >= 0xC0:
            if b in (0xEC, 0xFA):
                t1 = self.octet_pc()
                t2 = self.octet_pc()
                types = []
                for t in (t1, t2):
                    for s in (6, 4, 2, 0):
                        if (t >> s) & 3 == 3:
                            break
                        types.append((t >> s) & 3)
                    else:
                        continue
                    break
                ops = self.operandes(types)
            else:
                ops = self.operandes(self.types_lus())
            if b < 0xE0:
                return self.op2(b & 0x1F, ops)
            return self.opvar(b & 0x1F, ops)
        if b >= 0x80:
            t = (b >> 4) & 3
            if t == 3:
                return self.op0(b & 0x0F)
            return self.op1(b & 0x0F, self.operandes([t]))
        ops = self.operandes([2 if b & 0x40 else 1, 2 if b & 0x20 else 1])
        del debut
        return self.op2(b & 0x1F, ops)

    def types_lus(self):
        t = self.octet_pc()
        types = []
        for s in (6, 4, 2, 0):
            if (t >> s) & 3 == 3:
                break
            types.append((t >> s) & 3)
        return types

    def op2(self, op, o):
        a = o[0] if o else 0
        b = o[1] if len(o) > 1 else 0
        if op == 1:
            self.branche(any(a == x for x in o[1:]))
        elif op == 2:
            self.branche(s16(a) < s16(b))
        elif op == 3:
            self.branche(s16(a) > s16(b))
        elif op == 4:
            v = s16(self.lit_var_ind(a) - 1)
            self.ecrit_var_ind(a, v)
            self.branche(v < s16(b))
        elif op == 5:
            v = s16(self.lit_var_ind(a) + 1)
            self.ecrit_var_ind(a, v)
            self.branche(v > s16(b))
        elif op == 6:
            self.branche(a != 0 and self.parent(a) == b)
        elif op == 7:
            self.branche(a & b == b)
        elif op == 8:
            self.stocke(a | b)
        elif op == 9:
            self.stocke(a & b)
        elif op == 10:
            self.branche(a != 0 and self.octet(self.obj(a) + b // 8) & (0x80 >> (b % 8)))
        elif op == 11:
            if a:
                ad = self.obj(a) + b // 8
                self.ecrit_octet(ad, self.octet(ad) | (0x80 >> (b % 8)))
        elif op == 12:
            if a:
                ad = self.obj(a) + b // 8
                self.ecrit_octet(ad, self.octet(ad) & ~(0x80 >> (b % 8)))
        elif op == 13:
            self.ecrit_var_ind(a, b)
        elif op == 14:
            if a and b:
                self.insere(a, b)
        elif op == 15:
            self.stocke(self.mot((a + 2 * s16(b)) & 0xFFFF))
        elif op == 16:
            self.stocke(self.octet((a + s16(b)) & 0xFFFF))
        elif op == 17:
            ad, lg = self.trouve_prop(a, b) if a else (0, 0)
            if ad == 0:
                self.stocke(self.mot(self.objets + 2 * (b - 1)))
            elif lg == 1:
                self.stocke(self.octet(ad))
            else:
                self.stocke(self.mot(ad))
        elif op == 18:
            self.stocke(self.trouve_prop(a, b)[0] if a else 0)
        elif op == 19:
            if a == 0:
                self.stocke(0)
            else:
                lst = list(self.props(a))
                if b == 0:
                    self.stocke(lst[0][0] if lst else 0)
                else:
                    nums = [n for n, _, _ in lst]
                    if b not in nums:
                        raise ErreurZ('get_next_prop : propriété %d absente' % b)
                    i = nums.index(b)
                    self.stocke(nums[i + 1] if i + 1 < len(nums) else 0)
        elif op == 20:
            self.stocke(a + b)
        elif op == 21:
            self.stocke(a - b)
        elif op == 22:
            self.stocke(s16(a) * s16(b))
        elif op in (23, 24):
            if s16(b) == 0:
                raise ErreurZ('division par zéro')
            q = abs(s16(a)) // abs(s16(b))
            if (s16(a) < 0) != (s16(b) < 0):
                q = -q
            self.stocke(q if op == 23 else s16(a) - q * s16(b))
        elif op == 25:
            self.appel(a, o[1:], self.octet_pc())
        elif op == 26:
            self.appel(a, o[1:], None)
        elif op == 27:
            self.couleur(a, b)
        elif op == 28:
            while len(self.cadres) > b:
                self.cadres.pop()
            self.retour(a)
        else:
            raise ErreurZ('2OP %d inconnu à $%X' % (op, self.pc))

    def couleur(self, e, f):
        if e == 1:
            e = 9
        if f == 1:
            f = 2
        if 2 <= e <= 9:
            self.ecran.encre = e
        if 2 <= f <= 9:
            self.ecran.fond = f

    def vraie_couleur(self, c, defaut):
        """@set_true_colour : 15 bits (0bbbbbgggggrrrrr) -> la couleur Z la plus proche
        des huit d'OSM39 (une composante >= 16 allume son bit). -1 : défaut ;
        -2, -3 : inchangée."""
        c = s16(c)
        if c == -1:
            return defaut
        if c < 0:
            return 0
        bits = (4 if c & 0x10 else 0) | (2 if c & 0x200 else 0) | (1 if c & 0x4000 else 0)
        return {v: k for k, v in Z_COUL.items()}[bits]

    def op1(self, op, o):
        a = o[0]
        if op == 0:
            self.branche(a == 0)
        elif op == 1:
            v = self.frere(a) if a else 0
            self.stocke(v)
            self.branche(v)
        elif op == 2:
            v = self.enfant(a) if a else 0
            self.stocke(v)
            self.branche(v)
        elif op == 3:
            self.stocke(self.parent(a) if a else 0)
        elif op == 4:
            self.stocke(self.long_prop(a))
        elif op == 5:
            self.ecrit_var_ind(a, self.lit_var_ind(a) + 1)
        elif op == 6:
            self.ecrit_var_ind(a, self.lit_var_ind(a) - 1)
        elif op == 7:
            self.imprime(self.decode(a)[0])
        elif op == 8:
            self.appel(a, [], self.octet_pc())
        elif op == 9:
            if a:
                self.ote(a)
        elif op == 10:
            if a:
                self.imprime(self.decode(self.table_prop(a) + 1)[0])
        elif op == 11:
            self.retour(a)
        elif op == 12:
            self.pc += s16(a) - 2
        elif op == 13:
            self.imprime(self.decode(self.adr_paquee(a))[0])
        elif op == 14:
            self.stocke(self.lit_var_ind(a))
        elif op == 15:
            if self.v <= 4:                      # v1-4 : not
                self.stocke(~a)
            else:
                self.appel(a, [], None)

    def op0(self, op):
        if op == 0:
            self.retour(1)
        elif op == 1:
            self.retour(0)
        elif op in (2, 3):
            t, self.pc = self.decode(self.pc)
            self.imprime(t)
            if op == 3:
                self.imprime('\n')
                self.retour(1)
        elif op == 4:
            pass
        elif op == 5 and self.v <= 4:            # save (v3 : branchement, v4 : résultat)
            self.sauve_partie()
        elif op == 6 and self.v <= 4:
            self.charge_partie()
        elif op == 7:
            self.demarre(self.m[0x11])
            self.ecran.efface_fenetre(-1)
        elif op == 8:
            self.retour(self.lit_var(0))
        elif op == 9:
            if self.v <= 4:                      # v1-4 : pop
                self.lit_var(0)
            else:
                self.stocke(len(self.cadres))
        elif op == 10:
            raise Fin()
        elif op == 11:
            self.imprime('\n')
        elif op == 12:
            if self.v <= 3:
                self.etat()
        elif op == 13:
            lg = self.mot(0x1A) * self.mult
            somme = sum(self.histoire[0x40:lg]) & 0xFFFF
            self.branche(somme == self.mot(0x1C))
        elif op == 15:
            self.branche(True)
        else:
            raise ErreurZ('0OP %d inconnu' % op)

    def opvar(self, op, o):
        a = o[0] if o else 0
        b = o[1] if len(o) > 1 else 0
        if op == 0:
            self.appel(a, o[1:], self.octet_pc())
        elif op == 1:
            self.ecrit_mot_z((a + 2 * s16(b)) & 0xFFFF, o[2])
        elif op == 2:
            self.ecrit_octet((a + s16(b)) & 0xFFFF, o[2])
        elif op == 3:
            ad, lg = self.trouve_prop(a, b)
            if ad == 0:
                raise ErreurZ('put_prop : propriété %d absente de %d' % (b, a))
            if lg == 1:
                self.ecrit_octet(ad, o[2])
            else:
                self.ecrit_mot_z(ad, o[2])
        elif op == 4:
            st = self.octet_pc() if self.v >= 5 else None
            t = self.lit_ligne(a, b, o[2] if len(o) > 2 else 0, o[3] if len(o) > 3 else 0)
            if st is not None:
                self.ecrit_var(st, t)
        elif op == 5:
            self.imprime(self.zscii(a))
        elif op == 6:
            self.imprime(str(s16(a)))
        elif op == 7:
            self.stocke(self.hasard(a))
        elif op == 8:
            self.ecrit_var(0, a)
        elif op == 9:
            v = self.lit_var(0)
            self.ecrit_var_ind(a, v)
        elif op == 10:
            self.ecran.coupe(a)
        elif op == 11:
            self.ecran.choisit(a)
        elif op == 12:
            self.appel(a, o[1:], self.octet_pc())
        elif op == 13:
            self.ecran.efface_fenetre(s16(a))
        elif op == 14:
            if a == 1:
                self.ecran.efface_ligne()
        elif op == 15:
            self.ecran.curseur(a, b)
        elif op == 16:
            ligne, col = self.ecran.lit_curseur()
            self.ecrit_mot_z(a, ligne)
            self.ecrit_mot_z(a + 2, col)
        elif op == 17:
            self.ecran.vide_mot()
            self.ecran.style = 0 if a == 0 else self.ecran.style | a
        elif op == 18:
            self.ecran.vide_mot()
            self.ecran.tampon = bool(a)
        elif op == 19:
            n = s16(a)
            if n == 1:
                self.flux1 = True
            elif n == -1:
                self.flux1 = False
            elif n == 3:
                if len(self.flux3) >= 16:
                    raise ErreurZ('flux 3 : plus de 16 tables')
                self.flux3.append((b, 0))
            elif n == -3:
                if self.flux3:
                    table, cpt = self.flux3.pop()
                    self.ecrit_mot_z(table, cpt)
        elif op == 20:
            pass
        elif op == 21:
            pass                                   # sound_effect : bip non modélisé
        elif op == 22:
            self.stocke(self.lit_touche(b if len(o) > 1 else 0, o[2] if len(o) > 2 else 0))
        elif op == 23:
            forme = o[3] if len(o) > 3 else 0x82
            pas = forme & 0x7F
            trouve = 0
            for i in range(o[2]):
                ad = (b + i * pas) & 0xFFFF
                v = self.mot(ad) if forme & 0x80 else self.octet(ad)
                if v == a:
                    trouve = ad
                    break
            self.stocke(trouve)
            self.branche(trouve)
        elif op == 24:
            self.stocke(~a)
        elif op == 25 or op == 26:
            self.appel(a, o[1:], None)
        elif op == 27:
            self.decoupe(a, b, o[2] if len(o) > 2 else 0, len(o) > 3 and o[3] != 0)
        elif op == 28:
            txt = ''.join(self.zscii(self.octet(a + o[2] + i)) for i in range(b))
            for i, x in enumerate(self.encode(txt)):
                self.ecrit_octet(o[3] + i, x)
        elif op == 29:
            prem, sec, taille = a, b, s16(o[2])
            if sec == 0:
                for i in range(abs(taille)):
                    self.ecrit_octet(prem + i, 0)
            elif taille < 0 or sec < prem:
                for i in range(abs(taille)):
                    self.ecrit_octet(sec + i, self.octet(prem + i))
            else:
                for i in reversed(range(taille)):
                    self.ecrit_octet(sec + i, self.octet(prem + i))
        elif op == 30:
            larg, haut = b, o[2] if len(o) > 2 else 1
            saut = o[3] if len(o) > 3 else 0
            ligne, col = self.ecran.lit_curseur()
            ad = a
            for r in range(haut):
                if r:
                    if self.ecran.fen == 1:
                        self.ecran.curseur(ligne + r, col)
                    else:
                        self.imprime('\n' + ' ' * (col - 1))
                self.imprime(''.join(self.zscii(self.octet(ad + i)) for i in range(larg)))
                ad += larg + saut
        elif op == 31:
            self.branche(a <= self.cadres[-1]['nargs'])
        else:
            raise ErreurZ('VAR %d inconnu' % op)

    def etendu(self, op, o):
        a = o[0] if o else 0
        b = o[1] if len(o) > 1 else 0
        if op == 0:
            if o:                                   # sauvegarde d'une table : non prise en charge
                self.stocke(0)
                return
            self.sauve_partie()
        elif op == 1:
            if o:
                self.stocke(0)
                return
            self.charge_partie()
        elif op == 2:
            n = s16(b)
            self.stocke(a << n if n >= 0 else a >> -n)
        elif op == 3:
            n = s16(b)
            self.stocke(s16(a) << n if n >= 0 else s16(a) >> -n)
        elif op == 4:
            if a == 0:
                self.stocke(self.fonte if hasattr(self, 'fonte') else 1)
            elif a in (1, 4):
                prec = getattr(self, 'fonte', 1)
                self.fonte = a
                self.stocke(prec)
            else:
                self.stocke(0)
        elif op == 9:
            self.stocke(0xFFFF)                     # @save_undo : pas d'annulation
        elif op == 10:
            self.stocke(0)
        elif op == 11:
            self.imprime(chr(a))
        elif op == 13:
            self.couleur(self.vraie_couleur(a, 9), self.vraie_couleur(b, 2))
        elif op == 12:
            u = chr(a)
            self.stocke((1 if u in CP437 else 0) | (2 if u in CP437 else 0))
        else:
            raise ErreurZ('EXT %d inconnu' % op)

    # --- sauvegarde : Quetzal (IFhd, UMem, Stks), comme frotz -----------------
    def demande_nom(self):
        """« Fichier : » puis une saisie : le nom en majuscules (+ .SAV), ou None."""
        for u in PROMPT_FICHIER:
            self.ecran.car(u)
        self.ecran.saisie_debut()
        ligne, _ = self.entree.ligne(12, 0)
        for u in ligne:
            self.ecran.echo(u)
        self.ecran.echo('\n')
        nom = ligne.strip().upper()
        if not nom:
            return None
        if '.' not in nom:
            nom += '.SAV'
        return nom

    def quetzal(self, pc):
        def bloc(nom, data):
            data = bytes(data)
            return nom + len(data).to_bytes(4, 'big') + data + (b'\0' if len(data) & 1 else b'')
        ifhd = self.m[2:4] + self.m[0x12:0x18] + self.m[0x1C:0x1E] + pc.to_bytes(3, 'big')
        stks = bytearray()
        for k, c in enumerate(self.cadres):
            fin = self.cadres[k + 1]['base'] if k + 1 < len(self.cadres) else len(self.pile)
            evals = self.pile[c['base']:fin]
            if k == 0:
                stks += bytes(6)
            else:
                stks += c['retour'].to_bytes(3, 'big')
                stks.append(len(c['locales']) | (0x10 if c['stocke'] is None else 0))
                stks.append(0 if c['stocke'] is None else c['stocke'])
                stks.append((1 << min(c['nargs'], 7)) - 1)
            stks += len(evals).to_bytes(2, 'big')
            for v in c['locales'] if k else []:
                stks += v.to_bytes(2, 'big')
            for v in evals:
                stks += v.to_bytes(2, 'big')
        corps = b'IFZS' + bloc(b'IFhd', ifhd) + bloc(b'UMem', self.m[:self.statique]) + bloc(b'Stks', stks)
        return b'FORM' + len(corps).to_bytes(4, 'big') + corps

    def lit_quetzal(self, f):
        """Les octets d'un fichier Quetzal -> (mémoire dynamique, cadres, pile, pc), ou None."""
        if len(f) < 12 or f[:4] != b'FORM' or f[8:12] != b'IFZS':
            return None
        blocs = {}
        i, fin = 12, min(len(f), 8 + int.from_bytes(f[4:8], 'big'))
        while i + 8 <= fin:
            n = int.from_bytes(f[i + 4:i + 8], 'big')
            blocs.setdefault(f[i:i + 4], f[i + 8:i + 8 + n])
            i += 8 + n + (n & 1)
        h = blocs.get(b'IFhd')
        if not h or len(h) < 13 or h[0:2] != self.histoire[2:4] or h[2:8] != self.histoire[0x12:0x18] \
                or h[8:10] != self.histoire[0x1C:0x1E]:
            return None
        pc = int.from_bytes(h[10:13], 'big')
        if b'UMem' in blocs:
            mem = bytes(blocs[b'UMem'])
            if len(mem) != self.statique:
                return None
        elif b'CMem' in blocs:
            mem = bytearray(self.histoire[:self.statique])
            j = 0
            c = blocs[b'CMem']
            k = 0
            while k < len(c) and j < len(mem):
                if c[k] == 0:
                    j += (c[k + 1] if k + 1 < len(c) else 0) + 1
                    k += 2
                else:
                    mem[j] ^= c[k]
                    j += 1
                    k += 1
            mem = bytes(mem)
        else:
            return None
        s = blocs.get(b'Stks')
        if s is None:
            return None
        cadres, pile = [], []
        k = 0
        while k + 8 <= len(s):
            retour = int.from_bytes(s[k:k + 3], 'big')
            fl, var, args = s[k + 3], s[k + 4], s[k + 5]
            n = int.from_bytes(s[k + 6:k + 8], 'big')
            k += 8
            nl = fl & 15
            locales = [int.from_bytes(s[k + 2 * x:k + 2 * x + 2], 'big') for x in range(nl)]
            k += 2 * nl
            base = len(pile)
            pile += [int.from_bytes(s[k + 2 * x:k + 2 * x + 2], 'big') for x in range(n)]
            k += 2 * n
            nargs = 0
            while args & (1 << nargs):
                nargs += 1
            if not cadres:
                cadres.append(dict(retour=None, stocke=None, locales=[], base=0, nargs=0))
            else:
                cadres.append(dict(retour=retour, stocke=None if fl & 0x10 else var,
                                   locales=locales, base=base, nargs=nargs))
        if not cadres:
            return None
        return mem, cadres, pile, pc

    def resultat_partie(self, var, v):
        """v3 : un branchement (v <> 0 : pris) ; sinon la variable de résultat."""
        if self.v <= 3:
            self.branche(v)
        else:
            self.ecrit_var(var, v)

    def sauve_partie(self):
        pc = self.pc                            # l'octet de résultat (de branchement en v3)
        var = self.octet_pc() if self.v >= 4 else None   # v3 : le branchement, lu après
        nom = self.demande_nom()
        if nom is None:
            self.resultat_partie(var, 0)
            return
        self.fichiers[nom] = self.quetzal(pc)
        self.resultat_partie(var, 1)

    def charge_partie(self):
        var = self.octet_pc() if self.v >= 4 else None
        nom = self.demande_nom()
        r = self.lit_quetzal(self.fichiers[nom]) if nom in self.fichiers else None
        if r is None:
            self.resultat_partie(var, 0)
            return
        mem, self.cadres, self.pile, self.pc = r
        f2 = self.m[0x11]
        self.m[:len(mem)] = mem
        self.m[0x11] = (self.m[0x11] & ~3) | (f2 & 3)
        self.entete()
        if self.v <= 3:
            self.branche(True)
        else:
            self.ecrit_var(self.octet_pc(), 2)

    # --- v3 : la ligne d'état --------------------------------------------------
    def etat(self):
        o = self.lit_var(16)
        lieu = self.decode(self.table_prop(o) + 1)[0] if o else ''
        a, b = s16(self.lit_var(17)), self.lit_var(18)
        if self.m[1] & 0x02:                     # l'heure
            droite = 'Time: %d:%02d %s' % ((a % 12) or 12, b, 'pm' if a >= 12 else 'am')
        else:
            droite = 'Score: %d  Moves: %d' % (a, b)
        lieu = lieu[:max(0, self.L - len(droite) - 4)]
        self.ecran.ligne_etat(lieu, droite)

    def tourne(self, limite=None):
        try:
            while limite is None or self.nb_instr < limite:
                self.pas()
        except Fin:
            pass


def ecrit_inc(chemin):
    """zmachine/zmachine_data.inc : les tables de caractères du 6309 (GÉNÉRÉ)."""
    l = ['; GÉNÉRÉ par tools/zmachine/zmachine.py --inc : ne pas éditer.',
         '; Uni_Cp437 : point de code Unicode des caractères CP437 $80-$FF (police page 0)',
         'Uni_Cp437:']
    hauts = bytes(range(128, 256)).decode('cp437')
    for i in range(0, 128, 8):
        l.append('    FDB     ' + ','.join('$%04X' % ord(c) for c in hauts[i:i + 8]))
    l.append('; Uni_Defaut : table Unicode par défaut (ZSCII 155-%d)' % (154 + len(DEFAUT_UNICODE)))
    l.append('UNI_DEFAUT_N    EQU %d' % len(DEFAUT_UNICODE))
    l.append('Uni_Defaut:')
    for i in range(0, len(DEFAUT_UNICODE), 8):
        l.append('    FDB     ' + ','.join('$%04X' % ord(c) for c in DEFAUT_UNICODE[i:i + 8]))
    open(chemin, 'w').write('\n'.join(l) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('jeu', nargs='?')
    p.add_argument('--inc', metavar='F', help='écrit les tables du 6309 (zmachine/zmachine_data.inc)')
    p.add_argument('--brut', action='store_true', help='texte brut, sans grille')
    p.add_argument('--script', help='fichier de commandes (une par ligne)')
    p.add_argument('--czech', metavar='REF', help='compare la sortie brute à REF (czech.outN)')
    p.add_argument('--grille', action='store_true', help='avec --script : affiche la grille finale')
    p.add_argument('--graine', type=int, default=1, help='graine du hasard (le 6309 prend vsync_tick)')
    a = p.parse_args()
    if a.inc:
        ecrit_inc(a.inc)
        return
    fichiers = Dossier()
    histoire = open(a.jeu, 'rb').read()
    if a.czech:
        ecran = Brut()
        z = ZMachine(histoire, ecran, EntreeScript([]))
        z.tourne()
        obtenu = ecran.texte().replace('\r', '').split('\n')
        attendu = open(a.czech, encoding='latin1').read().replace('\r', '').split('\n')
        def sans_entete(ls):
            out, saute = [], False
            for x in ls:
                if x.startswith('Header'):
                    saute = True
                    continue
                if saute and (x.startswith('    ') or not x.strip()):
                    continue
                saute = False
                out.append(x.rstrip())
            return out
        ob, at = sans_entete(obtenu), sans_entete(attendu)
        import difflib
        diff = list(difflib.unified_diff(at, ob, 'attendu', 'obtenu', lineterm='', n=1))
        print('\n'.join(diff) if diff else 'Identique à %s (hors en-tête), %d instructions.' % (a.czech, z.nb_instr))
        sys.exit(1 if diff else 0)
    if a.script:
        lignes = open(a.script, encoding='utf-8').read().split('\n')
        ecran = Brut(None if a.grille else sys.stdout) if a.brut or not a.grille else Grille()
        z = ZMachine(histoire, ecran, EntreeScript(lignes), graine=a.graine, fichiers=fichiers)
        if isinstance(ecran, Brut):
            ecran.vers = sys.stdout
        z.tourne()
        if isinstance(ecran, Grille):
            print(ecran.texte())
        print('\n[%d instructions]' % z.nb_instr)
        return
    if a.brut:
        ecran = Brut(sys.stdout)
        z = ZMachine(histoire, ecran, EntreeTerminal(ecran), graine=a.graine, fichiers=fichiers)
    else:
        ecran = Grille(suite_auto=False)
        ent = EntreeTerminal(ecran)
        z = ZMachine(histoire, ecran, ent, graine=a.graine, fichiers=fichiers)
        ecran.attendre_touche = lambda: ent.touche(0)
        sys.stdout.write('\x1b[2J')
    z.tourne()
    print()


if __name__ == '__main__':
    main()
