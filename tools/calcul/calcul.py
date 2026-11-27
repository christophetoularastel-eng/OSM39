#!/usr/bin/env python3
# ===================================================================
# calcul.py - Le modèle exact de CALCUL (apps/calcul.asm), la
# calculatrice de poche d'OSM-VISION
# ===================================================================
# Les nombres : décimaux EXACTS, ce qu'on voit est ce qui est gardé : au
# plus 12 chiffres significatifs et 11 décimales, moins de 10^12 en valeur
# absolue. Chaque résultat (+ - x ÷ √ %, M+ M-) est la valeur exacte
# arrondie au plus proche, la moitié en s'éloignant de zéro (0,1 + 0,2 =
# 0,3 ; 2 ÷ 3 = 0,66666666667) ; 10^12 ou plus : « Erreur », que seule
# la touche C efface. Racine d'un négatif, division par zéro : Erreur.
#
# Le clavier de la calculatrice (5 x 5, indices 0-24) :
#     MC  MR  M-  M+  C
#     7   8   9   ÷   <-
#     4   5   6   x   Rac  (la racine carrée)
#     1   2   3   -   %
#     0   .   ±   +   =
# Toutes les commandes sont ces 25 touches : le clavier du PC en choisit
# une (TOUCHES) et la sélectionne ; le joystick déplace la sélection, son
# bouton appuie la touche sélectionnée.
#
# Enchaînement (calculatrice ordinaire, sans priorités) :
#   chiffres, point : la saisie (12 chiffres au plus, 11 décimales) ;
#   + - x ÷ : calcule l'opération en attente si un nombre a été tapé
#     depuis, puis attend la suivante (deux opérateurs de suite : le
#     second remplace le premier) ;
#   = : l'opération en attente avec le nombre affiché (5 + = donne 10) ;
#     répété, refait la dernière opération (constante : 2 x 3 = = = donne
#     6, 18, 54) ;
#   % : avec + ou - en attente, le nombre devient acc x n / 100 (200 + 10 %
#     = 220), sinon n / 100 ;
#   ± : change le signe (de la saisie ou du résultat) ; <- efface le
#     dernier caractère tapé ; C remet tout à zéro sauf la mémoire ;
#   MC efface la mémoire, MR la rappelle, M+ / M- y ajoutent / retranchent
#     le nombre affiché.
#
# L'affichage (rangée de l'écran LCD, 24 cases) : case 0 « M » si la
# mémoire n'est pas nulle, case 1 l'opération en attente, le nombre calé
# à droite (22 cases). Les rangées de la fenêtre : rangees().
#   python3 tools/calcul/calcul.py 2 / 3 =      (essai : les touches)
# ===================================================================
import sys
from fractions import Fraction
from math import floor, isqrt

UN = Fraction(1)
LIMITE = 10 ** 12

# --- la fenêtre (mêmes valeurs que apps/calcul.asm) ---
WIN_X, WIN_Y, WIN_W, WIN_H = 25, 4, 30, 17
LARGE = WIN_W - 2                   # cases intérieures composées par rangée
R_LCD = 2                           # rangées, depuis le haut de la fenêtre
R_TOUCHES = (4, 6, 8, 10, 12)
R_AIDE = (14, 15)
FOND = (0x00, 0x8F)                 # l'intérieur des fenêtres (UI_SPACE)
A_LCD = 0x28                        # chiffres noirs sur vert
A_AIDE = 0x0F
A_SEL = 0x68                        # la touche sélectionnée : noir sur jaune
A_CHIFFRE, A_OPER, A_FONC = 0x17, 0x47, 0x27
DIV, PM = 0xF6, 0xF1               # ÷ ± en CP437 (le $FB de notre police n'est pas un √)

ETIQ = [b' MC ', b' MR ', b' M- ', b' M+ ', b'  C ',
        b'  7 ', b'  8 ', b'  9 ', bytes([32, 32, DIV, 32]), b' <- ',
        b'  4 ', b'  5 ', b'  6 ', b'  x ', b' Rac',
        b'  1 ', b'  2 ', b'  3 ', b'  - ', b'  % ',
        b'  0 ', b'  . ', bytes([32, 32, PM, 32]), b'  + ', b'  = ']
GENRE = [A_FONC] * 5 + [A_CHIFFRE] * 3 + [A_OPER, A_FONC] + [A_CHIFFRE] * 3 + [A_OPER, A_FONC] \
    + [A_CHIFFRE] * 3 + [A_OPER, A_FONC] + [A_CHIFFRE] * 3 + [A_OPER] * 2
AIDE = (b'v=racine n=' + bytes([PM]) + b' c=C Echap=fin',
        b'p=M+ m=M- r=MR e=MC')

MC, MR, MMOINS, MPLUS, EFF = 0, 1, 2, 3, 4
T_DIV, T_RET, T_MUL, T_RAC, T_MOINS, T_PC, T_POINT, T_PM, T_PLUS, T_EGAL = 8, 9, 13, 14, 18, 19, 21, 22, 23, 24
CHIFFRE = {5: 7, 6: 8, 7: 9, 10: 4, 11: 5, 12: 6, 15: 1, 16: 2, 17: 3, 20: 0}
OPER = {T_PLUS: '+', T_MOINS: '-', T_MUL: '*', T_DIV: '/'}
SYMB = {'+': ord('+'), '-': ord('-'), '*': ord('x'), '/': DIV}

# le clavier du PC -> l'indice de la touche (Échap : fin)
TOUCHES = {ord('0'): 20, ord('1'): 15, ord('2'): 16, ord('3'): 17, ord('4'): 10, ord('5'): 11,
           ord('6'): 12, ord('7'): 5, ord('8'): 6, ord('9'): 7, ord('.'): T_POINT, ord(','): T_POINT,
           ord('+'): T_PLUS, ord('-'): T_MOINS, ord('*'): T_MUL, ord('x'): T_MUL, ord('X'): T_MUL,
           ord('/'): T_DIV, ord('='): T_EGAL, 0x0D: T_EGAL, ord('c'): EFF, ord('C'): EFF, 0x88: EFF,
           0x08: T_RET, ord('v'): T_RAC, ord('V'): T_RAC, ord('n'): T_PM, ord('N'): T_PM,
           ord('%'): T_PC, ord('p'): MPLUS, ord('P'): MPLUS, ord('m'): MMOINS, ord('M'): MMOINS,
           ord('r'): MR, ord('R'): MR, ord('e'): MC, ord('E'): MC}


def arrondi(v):
    """La valeur exacte v -> le nombre gardé, ou None (10^12 ou plus)."""
    v = Fraction(v)
    if v == 0:
        return Fraction(0)
    a = abs(v)
    e = len(str(floor(a))) - 1 if a >= 1 else -1
    while a < Fraction(10) ** e:
        e -= 1
    q = Fraction(10) ** max(-11, e - 11)
    r = floor(a / q + Fraction(1, 2)) * q
    if r >= LIMITE:
        return None
    return r if v > 0 else -r


def racine(x):
    if x < 0:
        return None
    X = int(x * 10 ** 11)
    return arrondi(Fraction(isqrt(X * 10 ** 13), 10 ** 12))


def opere(a, op, b):
    if op == '+':
        return arrondi(a + b)
    if op == '-':
        return arrondi(a - b)
    if op == '*':
        return arrondi(a * b)
    if b == 0:
        return None
    return arrondi(a / b)


def texte(x):
    """Le nombre tel qu'affiché : « -1234.5 », « 0.3 », « 0 »."""
    s = '-' if x < 0 else ''
    a = abs(x)
    n = floor(a)
    f = a - n
    t = s + str(n)
    if f:
        d = str(int(f * 10 ** 11)).rjust(11, '0').rstrip('0')
        t += '.' + d
    return t


class Calcul:
    def __init__(self):
        self.acc = Fraction(0)
        self.x = Fraction(0)
        self.mem = Fraction(0)
        self.op = None
        self.dern = None            # (opération, nombre) du dernier =
        self.err = False
        self.saisie = None          # (entier, décimales, point, négatif) ou None
        self.sel = 24               # la touche sélectionnée : =

    # --- la saisie ---
    def valeur(self):
        ent, dec, _, neg = self.saisie
        v = Fraction(int(ent or '0')) + (Fraction(int(dec), 10 ** len(dec)) if dec else 0)
        return -v if neg else v

    def ecrit(self):
        ent, dec, pt, neg = self.saisie
        return ('-' if neg else '') + (ent or '0') + ('.' + dec if pt else '')

    def touche(self, k):
        """Le clavier du PC : sélectionne la touche et l'appuie (False :
        touche inconnue, rien ne change)."""
        if k not in TOUCHES:
            return False
        self.sel = TOUCHES[k]
        self.appuie(self.sel)
        return True

    def joystick(self, evts):
        """Les événements de Joy_Evts (bits 0-3 un pas, bit 4 le bouton)."""
        r, c = divmod(self.sel, 5)
        if evts & 1 and r > 0:
            r -= 1
        if evts & 4 and r < 4:
            r += 1
        if evts & 8 and c > 0:
            c -= 1
        if evts & 2 and c < 4:
            c += 1
        self.sel = r * 5 + c
        if evts & 0x10:
            self.appuie(self.sel)

    def erreur(self):
        self.err = True
        self.op = None
        self.saisie = None

    def appuie(self, t):
        if t == EFF:
            mem, sel = self.mem, self.sel
            self.__init__()
            self.mem, self.sel = mem, sel
            return
        if self.err:
            return
        if t in CHIFFRE or t == T_POINT:
            if self.saisie is None:
                self.saisie = ('', '', False, False)
            ent, dec, pt, neg = self.saisie
            if t == T_POINT:
                pt = True
            elif len(ent) + len(dec) < 12 and (not pt or len(dec) < 11):
                d = str(CHIFFRE[t])
                if pt:
                    dec += d
                elif ent or d != '0':
                    ent += d
            self.saisie = (ent, dec, pt, neg)
            self.x = self.valeur()
        elif t == T_RET:
            if self.saisie is not None:
                ent, dec, pt, neg = self.saisie
                if dec:
                    dec = dec[:-1]
                elif pt:
                    pt = False
                elif ent:
                    ent = ent[:-1]
                self.saisie = (ent, dec, pt, neg)
                self.x = self.valeur()
        elif t == T_PM:
            if self.saisie is not None:
                ent, dec, pt, neg = self.saisie
                self.saisie = (ent, dec, pt, not neg)
                self.x = self.valeur()
            else:
                self.x = -self.x
        elif t in OPER:
            if self.op is not None and self.saisie is not None:
                r = opere(self.acc, self.op, self.x)
                if r is None:
                    return self.erreur()
                self.acc = self.x = r
            elif self.op is None:
                self.acc = self.x
            self.op = OPER[t]
            self.saisie = None
        elif t == T_EGAL:
            if self.op is not None:
                self.dern = (self.op, self.x)
                r = opere(self.acc, self.op, self.x)
                self.op = None
            elif self.dern is not None:
                r = opere(self.x, *self.dern)
            else:
                self.saisie = None
                return
            if r is None:
                return self.erreur()
            self.acc = self.x = r
            self.saisie = None
        elif t == T_PC:
            if self.op in ('+', '-'):
                r = arrondi(self.acc * self.x / 100)
            else:
                r = arrondi(self.x / 100)
            if r is None:
                return self.erreur()
            self.x = r
            self.saisie = None
        elif t == T_RAC:
            r = racine(self.x)
            if r is None:
                return self.erreur()
            self.x = r
            self.saisie = None
        elif t == MC:
            self.mem = Fraction(0)
        elif t == MR:
            self.x = self.mem
            self.saisie = None
        elif t in (MPLUS, MMOINS):
            r = arrondi(self.mem + self.x if t == MPLUS else self.mem - self.x)
            if r is None:
                return self.erreur()
            self.mem = r
            self.saisie = None

    # --- l'écran ---
    def affiche(self):
        if self.err:
            return 'Erreur'
        if self.saisie is not None:
            return self.ecrit()
        return texte(self.x)

    def lcd(self):
        """Les 24 cases de l'écran LCD (codes CP437)."""
        n = self.affiche().encode('ascii')
        return bytes([ord('M') if self.mem else 32, SYMB[self.op] if self.op else 32]) + n.rjust(22)

    def rangees(self):
        """{rangée de la fenêtre: (caractères, attributs)} des LARGE cases
        intérieures (colonnes WIN_X+1 ...) que CALCUL compose."""
        r = {}
        car = bytes([FOND[0]] * 2) + self.lcd() + bytes([FOND[0]] * 2)
        att = bytes([FOND[1]] * 2 + [A_LCD] * 24 + [FOND[1]] * 2)
        r[R_LCD] = (car, att)
        for ligne, y in enumerate(R_TOUCHES):
            car, att = bytearray([FOND[0]] * 2), bytearray([FOND[1]] * 2)
            for c in range(5):
                k = ligne * 5 + c
                car += ETIQ[k]
                att += bytes([A_SEL if k == self.sel else GENRE[k]] * 4)
                if c < 4:
                    car.append(FOND[0])
                    att.append(FOND[1])
            car += bytes([FOND[0]] * 2)
            att += bytes([FOND[1]] * 2)
            r[y] = (bytes(car), bytes(att))
        for y, t in zip(R_AIDE, AIDE):
            car = bytes([FOND[0]]) + t + bytes([FOND[0]] * (LARGE - 1 - len(t)))
            att = bytes([FOND[1]] + [A_AIDE] * len(t) + [FOND[1]] * (LARGE - 1 - len(t)))
            r[y] = (car, att)
        return r


def main():
    c = Calcul()
    for mot in sys.argv[1:]:
        for ch in mot:
            c.touche(ord(ch))
        print('%-10s %s' % (mot, c.lcd().decode('cp437')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
