#!/usr/bin/env python3
# ===================================================================
# dessin.py - Dessiner sur le PC à la résolution d'OSM3D (mosaïques 2 x 3)
# ===================================================================
# La vue d'OSM3D : 64 x 18 cases, chacune 2 x 3 points = 128 x 54 points
# (--plein : l'écran entier, 80 x 30 cases = 160 x 90). Couleurs de la
# machine : 0-7 (D0 bleu, D1 vert, D2 rouge), 8-15 les mêmes atténuées,
# qui ne peuvent être que le PREMIER PLAN d'une case. Une case n'a que 2
# couleurs : l'affichage montre ce que la machine afficherait (la règle de
# cellule() d'osm3d.py) et entoure de rouge les cases impossibles.
#
#   python3 tools/osm3d/dessin.py FICHIER.txt [--plein] [--osm3d X Y ANGLE [NIV]]
#
# FICHIER.txt : une ligne d'en-tête puis une rangée de points par ligne,
# un chiffre hexadécimal (0-F) par point ; il est relu s'il existe.
# --osm3d : partir de la vue du modèle en (X, Y) case, angle 0-1023
# (0 est, 256 sud ; un rayon par colonne de cases : 2 points de large).
#
# Souris : gauche dessine, droite prend la couleur (pipette).
# Touches : C crayon, L ligne, R rectangle plein, A arc (arche : tirer un
# rectangle ; Maj : cuvette), E ellipse, S seau, D pinceau double
# largeur (une colonne du moteur), B brut/machine, G grille,
# 0-7 couleur (chiffres, avec ou sans Maj, ou pavé), T atténuée (+8),
# clic sur le nuancier : les 16 ; Ctrl+Z annuler, Ctrl+S enregistrer (+ .png).
# ===================================================================
import os
import sys
import tkinter as tk

ICI = os.path.dirname(os.path.abspath(__file__))
ZX, ZY = 6, 8                               # un point : 4 x 5,33 pixels sur la machine (3 : 4)
BITS = 6                                    # points par case : 2 de large, 3 de haut


# les couleurs 0-7 au clavier : chiffres, rangée AZERTY sans Maj, pavé
CHIFFRES = {}
for _v, _noms in enumerate((('0', 'agrave', 'KP_0', 'KP_Insert'), ('1', 'ampersand', 'KP_1', 'KP_End'),
                            ('2', 'eacute', 'KP_2', 'KP_Down'), ('3', 'quotedbl', 'KP_3', 'KP_Next'),
                            ('4', 'apostrophe', 'KP_4', 'KP_Left'), ('5', 'parenleft', 'KP_5', 'KP_Begin'),
                            ('6', 'minus', 'KP_6', 'KP_Right'), ('7', 'egrave', 'KP_7', 'KP_Home'))):
    for _n in _noms:
        CHIFFRES[_n] = _v


def rgb(v, avant=True):
    k = 120 if (avant and v & 8) else 220
    v &= 7
    return '#%02x%02x%02x' % ((v >> 2 & 1) * k, (v >> 1 & 1) * k, (v & 1) * k)


def cellule(vals):
    """vals : les 6 couleurs (ordre : haut-gauche, haut-droit, milieu...,
    comme osm3d.cellule) -> (fond, premier plan, masque des points en
    premier plan, possible ?)."""
    fond = next((u for u in reversed(vals) if u < 8), 0)
    avant = next((u for u in vals if u != fond), None)
    if avant is None:
        return fond, 8, [False] * BITS, True
    masque = [u == avant for u in vals]
    possible = all(u in (fond, avant) for u in vals)
    return fond, avant, masque, possible


class Dessin:
    def __init__(self, fichier, larg, haut, points):
        self.fichier, self.L, self.H = fichier, larg, haut
        self.p = points
        self.annule = []
        self.outil, self.coul, self.double = 'C', 7, False
        self.brut, self.grille = False, True
        self.debut = None
        self.fen = tk.Tk()
        self.fen.title('Dessin OSM39 - %s' % os.path.basename(fichier))
        self.can = tk.Canvas(self.fen, width=larg * ZX, height=haut * ZY, bg='black',
                             highlightthickness=0)
        self.can.pack(anchor='nw')
        self.fen.resizable(False, False)
        self.rect = [[self.can.create_rectangle(x * ZX, y * ZY, (x + 1) * ZX, (y + 1) * ZY,
                                                width=0) for x in range(larg)] for y in range(haut)]
        self.cadres = {}
        bas = tk.Frame(self.fen)
        bas.pack(fill='x')
        self.nuancier = []
        for v in range(16):
            b = tk.Label(bas, text='%X' % v, width=3, bg=rgb(v), fg='white' if v in (0, 1, 4, 8, 9, 12) else 'black',
                         relief='raised', bd=2)
            b.pack(side='left')
            b.bind('<Button-1>', lambda e, v=v: self.choisit(v))
            self.nuancier.append(b)
        self.etat = tk.Label(self.fen, anchor='w', font=('monospace', 10), width=1)   # width=1 : ne pousse jamais la fenêtre
        self.etat.pack(fill='x')
        self.can.bind('<Button-1>', self.appui)
        self.can.bind('<B1-Motion>', self.glisse)
        self.can.bind('<ButtonRelease-1>', self.relache)
        self.can.bind('<Button-3>', self.pipette)
        self.can.bind('<Motion>', self.survol)
        self.fen.bind('<Key>', self.touche)
        self.fen.bind('<Control-z>', lambda e: self.defait())
        self.fen.bind('<Control-s>', lambda e: self.enregistre())
        self.choisit(7)
        self.redessine()

    # --- affichage ---
    def redessine(self, cases=None):
        if cases is None:
            cases = [(cx, cy) for cy in range(self.H // 3) for cx in range(self.L // 2)]
        for cx, cy in cases:
            pts = [(2 * cx + b, 3 * cy + k) for k in range(3) for b in range(2)]
            vals = [self.p[y][x] for x, y in pts]
            fond, avant, masque, possible = cellule(vals)
            for (x, y), m, v in zip(pts, masque, vals):
                c = rgb(v) if self.brut else (rgb(avant) if m else rgb(fond, False))
                self.can.itemconfigure(self.rect[y][x], fill=c)
            cle = (cx, cy)
            if cle in self.cadres:
                self.can.delete(self.cadres.pop(cle))
            if not possible:
                self.cadres[cle] = self.can.create_rectangle(2 * cx * ZX, 3 * cy * ZY, (2 * cx + 2) * ZX - 1,
                                                             (3 * cy + 3) * ZY - 1, outline='red', width=2)
        self.can.delete('grille')
        if self.grille:
            for cx in range(1, self.L // 2):
                self.can.create_line(2 * cx * ZX, 0, 2 * cx * ZX, self.H * ZY, fill='#303030', tags='grille')
            for cy in range(1, self.H // 3):
                self.can.create_line(0, 3 * cy * ZY, self.L * ZX, 3 * cy * ZY, fill='#303030', tags='grille')
        for c in self.cadres.values():
            self.can.tag_raise(c)
        self.montre_etat()

    def montre_etat(self, xy=None):
        noms = {'C': 'crayon', 'L': 'ligne', 'R': 'rectangle', 'S': 'seau', 'A': 'arc', 'E': 'ellipse'}
        t = 'outil %s%s  couleur %X%s  %s  cases impossibles : %d' % (
            noms[self.outil], ' double' if self.double else '', self.coul,
            ' atténuée' if self.coul & 8 else '',
            'BRUT' if self.brut else 'machine', len(self.cadres))
        if xy:
            t += '   point %d,%d  case %d,%d' % (xy[0], xy[1], xy[0] // 2, xy[1] // 3)
        self.etat.configure(text=t)

    def choisit(self, v):
        self.coul = v
        for k, b in enumerate(self.nuancier):
            b.configure(relief='sunken' if k == v else 'raised')
        self.montre_etat()

    # --- édition ---
    def memorise(self):
        self.annule.append([r[:] for r in self.p])
        del self.annule[:-100]

    def defait(self):
        if self.annule:
            self.p = self.annule.pop()
            self.redessine()

    def pose(self, x, y, touchees):
        for xx in ((x & ~1, (x & ~1) + 1) if self.double else (x,)):
            if 0 <= xx < self.L and 0 <= y < self.H:
                self.p[y][xx] = self.coul
                touchees.add((xx // 2, y // 3))

    def ligne(self, x0, y0, x1, y1, touchees):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        e = dx + dy
        while True:
            self.pose(x0, y0, touchees)
            if (x0, y0) == (x1, y1):
                return
            e2 = 2 * e
            if e2 >= dy:
                e += dy
                x0 += sx
            if e2 <= dx:
                e += dx
                y0 += sy

    def point(self, ev):
        return (min(self.L - 1, max(0, ev.x // ZX)), min(self.H - 1, max(0, ev.y // ZY)))

    def appui(self, ev):
        x, y = self.point(ev)
        self.memorise()
        self.debut = (x, y)
        self.avant = [r[:] for r in self.p]
        t = set()
        if self.outil == 'C':
            self.pose(x, y, t)
        elif self.outil == 'S':
            self.seau(x, y, t)
        self.redessine(t)

    def glisse(self, ev):
        x, y = self.point(ev)
        t = set()
        if self.outil == 'C':
            self.ligne(*self.debut, x, y, t)
            self.debut = (x, y)
        elif self.outil in 'LRAE':
            self.p = [r[:] for r in self.avant]           # aperçu : on repart de l'image d'avant
            if self.outil == 'L':
                self.ligne(*self.debut, x, y, t)
            elif self.outil in 'AE':
                self.arc(self.debut, (x, y), self.outil == 'E', bool(ev.state & 1), t)
            else:
                for yy in range(min(self.debut[1], y), max(self.debut[1], y) + 1):
                    for xx in range(min(self.debut[0], x), max(self.debut[0], x) + 1):
                        self.pose(xx, yy, t)
            t = None
        self.redessine(t)
        self.montre_etat((x, y))

    def relache(self, ev):
        self.debut = None

    def arc(self, a, b, entiere, cuvette, t):
        """Le rectangle a-b : arche = la moitié haute de l'ellipse dont le
        centre est au milieu du bas du rectangle (les pieds aux coins du
        bas, le sommet au milieu du haut) ; cuvette (Maj) : retournée ;
        entiere : l'ellipse inscrite dans le rectangle."""
        import math
        x0, x1 = sorted((a[0], b[0]))
        y0, y1 = sorted((a[1], b[1]))
        cx, rx = (x0 + x1) / 2, (x1 - x0) / 2
        if entiere:
            cy, ry, t0, t1 = (y0 + y1) / 2, (y1 - y0) / 2, 0.0, 2 * math.pi
        elif cuvette:
            cy, ry, t0, t1 = y0, y1 - y0, 0.0, math.pi
        else:
            cy, ry, t0, t1 = y1, y1 - y0, math.pi, 2 * math.pi
        n = max(8, int(4 * (rx + ry)))
        pts = [(round(cx + rx * math.cos(t0 + (t1 - t0) * k / n)),
                round(cy + ry * math.sin(t0 + (t1 - t0) * k / n))) for k in range(n + 1)]
        for p, q in zip(pts, pts[1:]):
            self.ligne(*p, *q, t)

    def seau(self, x, y, t):
        v0 = self.p[y][x]
        if v0 == self.coul:
            return
        pile = [(x, y)]
        while pile:
            x, y = pile.pop()
            if 0 <= x < self.L and 0 <= y < self.H and self.p[y][x] == v0:
                self.p[y][x] = self.coul
                t.add((x // 2, y // 3))
                pile += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]

    def pipette(self, ev):
        x, y = self.point(ev)
        self.choisit(self.p[y][x])

    def survol(self, ev):
        self.montre_etat(self.point(ev))

    def touche(self, ev):
        k = ev.keysym.upper()
        if ev.state & 4:
            return                                         # Ctrl+... : liaisons à part
        if k in ('C', 'L', 'R', 'S', 'A', 'E'):
            self.outil = k
        elif k == 'D':
            self.double = not self.double
        elif k == 'B':
            self.brut = not self.brut
            self.redessine()
        elif k == 'G':
            self.grille = not self.grille
            self.redessine()
        elif k == 'T':
            self.choisit(self.coul ^ 8)
        elif ev.keysym in CHIFFRES:
            self.choisit(CHIFFRES[ev.keysym])
        self.montre_etat()

    # --- fichiers ---
    def enregistre(self):
        with open(self.fichier, 'w') as f:
            f.write('# OSM39 dessin %dx%d (points ; cases de 2 x 3)\n' % (self.L, self.H))
            for r in self.p:
                f.write(''.join('%X' % v for v in r) + '\n')
        try:
            from PIL import Image
            im = Image.new('RGB', (self.L, self.H))
            for cy in range(self.H // 3):
                for cx in range(self.L // 2):
                    pts = [(2 * cx + b, 3 * cy + k) for k in range(3) for b in range(2)]
                    fond, avant, masque, _ = cellule([self.p[y][x] for x, y in pts])
                    for (x, y), m in zip(pts, masque):
                        c = rgb(avant) if m else rgb(fond, False)
                        im.putpixel((x, y), tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)))
            im.resize((self.L * ZX, self.H * ZY), Image.NEAREST).save(os.path.splitext(self.fichier)[0] + '.png')
        except ImportError:
            pass
        self.fen.title('Dessin OSM39 - %s (enregistré)' % os.path.basename(self.fichier))


def lit(fichier, larg, haut):
    lignes = [l.strip() for l in open(fichier) if l.strip() and not l.startswith('#')]
    p = [[int(c, 16) for c in l[:larg].ljust(larg, '0')] for l in lignes[:haut]]
    return p + [[0] * larg for _ in range(haut - len(p))]


def depuis_osm3d(x, y, ang, niv, larg, haut):
    sys.path.insert(0, ICI)
    import osm3d
    c = osm3d.carte()
    p = [[0] * larg for _ in range(haut)]
    for col in range(osm3d.VUE_L):
        v = osm3d.rayon(c, x, 128, y, 128, ang, col, niv)
        for k in range(min(haut, len(v))):
            p[k][2 * col] = p[k][2 * col + 1] = v[k] & 15
    return p


def main():
    a = sys.argv[1:]
    if not a or a[0].startswith('-'):
        print(__doc__ if __doc__ else 'voir l\'en-tête de dessin.py')
        return 2
    fichier, a = a[0], a[1:]
    larg, haut = 128, 54
    if '--plein' in a:
        a.remove('--plein')
        larg, haut = 160, 90
    if a[:1] == ['--osm3d']:
        x, y, ang = int(a[1]), int(a[2]), int(a[3])
        niv = int(a[4]) if len(a) > 4 else 0
        p = depuis_osm3d(x, y, ang, niv, larg, haut)
    elif os.path.exists(fichier):
        p = lit(fichier, larg, haut)
    else:
        p = [[1] * larg for _ in range(haut // 2)] + [[0] * larg for _ in range(haut - haut // 2)]
    Dessin(fichier, larg, haut, p).fen.mainloop()


if __name__ == '__main__':
    main()
