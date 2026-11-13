#!/usr/bin/env python3
# ===================================================================
# verifie_donjon39.py - apps/DONJON39 = le modèle tools/donjon39/donjon39.py
# ===================================================================
# Le VRAI binaire (page 1, $0000) tourne dans la machine de verifie_fs.py,
# appelé comme OSM-VISION l'appelle (App_Start). Une trame toutes les
# TRAME instructions : l'IRQ VSYNC est prise (mode natif, vecteur $FFF8,
# donc rvec_IRQ : Irq_Donjon puis le VRAI handler_IRQ du BIOS). Le clavier :
# des octets PS/2 bruts déposés dans la file de la NMI (kbd_buf, kbd_tete).
#   - à l'arrêt, à plusieurs positions et angles (atteints au clavier),
#     la vue en VRAM (glyphes ET attributs) est EXACTEMENT celle du modèle
#     pour la position et l'angle que le binaire a en mémoire ;
#   - chaque écriture en VRAM se fait DANS l'IRQ, dans ses premières
#     instructions, au plus RANGEES_TRAME rangées (x 128 octets) par trame ;
#   - on ne traverse pas les murs (marche longue contre un mur) ;
#   - Echap rend la main par RTS, la file du clavier vidée, rvec_IRQ rendu ;
#   - avec un DONJON39.TXT sur la carte (commentaires, CR LF et LF, ligne
#     vide, minuscules, lignes courtes) : la carte en mémoire et le départ
#     = texte_carte() du modèle ; Espace ouvre la porte de devant (la vue
#     suit), Tab montre la mini-carte (= le modèle), la porte se referme
#     seule. Le modèle prend la carte EN MÉMOIRE (les portes la changent).
# Mesure (indicative) : trames par image en tournant (tout l'écran change).
# ===================================================================
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'donjon39'))
import verifie_fs as v          # noqa: E402
import carte                    # noqa: E402
import verifie_asm as va        # noqa: E402
import donjon39                   # noqa: E402

BIN = os.path.join(RACINE, 'apps', 'DONJON39')
MAP = os.path.join(RACINE, 'apps', 'DONJON39.map')
TRAME = 7000                    # instructions par trame (~30 700 cycles à 4,4 cycles l'une)
F_X, F_Y = 8, 3                 # intérieur de la fenêtre (donjon39.asm)
HAUT, BAS, GAUCHE, DROITE = 0x75, 0x72, 0x6B, 0x74


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


class Fini(Exception):
    pass


class Banc(va.MachineAsm):
    def __init__(self, image, s, a, script):
        super().__init__(image, s)
        self.a_ = a                     # symboles de l'application
        self.script = list(script)      # (trame, action)
        self.trame = 0
        self.n = 0
        self.ecritures = []             # (trame, instructions depuis l'IRQ, dans l'IRQ ?)
        self.photos = {}
        self.irq = False                # IRQ VSYNC en attente (niveau : prise dès que I = 0)
        self.dans_irq = 0
        self.n_irq = 0

    def octet_clavier(self, o):
        s = self.s_
        t = self.mem[s['kbd_tete']]
        self.mem[s['kbd_buf'] + t] = o
        self.mem[s['kbd_tete']] = (t + 1) & 15

    def wr8(self, adr, val):
        # après le branchement d'Irq_Donjon (avant : la fenêtre de vis_Window)
        if 0x8000 <= adr < 0xA000 and self.page == 1 and self.rd16(0xDFF6) == self.a_['Irq_Donjon']:
            self.ecritures.append((self.trame, self.n - self.n_irq, self.dans_irq > 0))
        super().wr8(adr, val)

    def interruption(self, vecteur):        # mode natif : 14 octets
        self.s -= 14
        f = [self.cc | 0x80, self.a, self.b, self.w >> 8, self.w & 255, self.dp,
             self.x >> 8, self.x & 255, self.y >> 8, self.y & 255, self.u >> 8, self.u & 255,
             self.pc >> 8, self.pc & 255]
        for i, o in enumerate(f):
            self.wr8(self.s + i, o)
        self.cc |= 0x50
        self.pc = self.rd16(vecteur)

    def execute(self, op):
        if op == 0x3B and self.rd8(self.s) & 0x80:     # RTI natif
            f = [self.rd8(self.s + i) for i in range(14)]
            self.cc, self.a, self.b, self.dp = f[0], f[1], f[2], f[5]
            self.w = (f[3] << 8) | f[4]
            self.x, self.y, self.u = (f[6] << 8) | f[7], (f[8] << 8) | f[9], (f[10] << 8) | f[11]
            self.pc = (f[12] << 8) | f[13]
            self.s += 14
            self.dans_irq -= 1
            return
        return super().execute(op)

    def step(self):
        self.n += 1
        if self.n % TRAME == 0:
            self.trame += 1
            self.irq = True
            while self.script and self.script[0][0] <= self.trame:
                self.script.pop(0)[1](self)
        if self.irq and not self.cc & 0x10:
            self.irq = False
            self.dans_irq += 1
            self.n_irq = self.n
            self.interruption(0xFFF8)
        super().step()


def appui(code, etendu=True):
    def f(m):
        if etendu:
            m.octet_clavier(0xE0)
        m.octet_clavier(code)
    return f


def relache(code, etendu=True):
    def f(m):
        if etendu:
            m.octet_clavier(0xE0)
        m.octet_clavier(0xF0)
        m.octet_clavier(code)
    return f


def photo(nom):
    def f(m):
        a = m.a_
        vram = [carte.lit(m.mem, (F_Y + r) * 80 + F_X, 64) for r in range(20)]
        m.photos[nom] = (m.banks[1][a['PosX']] << 8 | m.banks[1][a['PosX'] + 1],
                         m.banks[1][a['PosY']] << 8 | m.banks[1][a['PosY'] + 1],
                         m.banks[1][a['Ang']] << 8 | m.banks[1][a['Ang'] + 1], vram, m.trame,
                         m.banks[1][a['Trames']], list(m.banks[1][a['Carte']:a['Carte'] + 256]),
                         m.banks[1][a['MiniOn']])
    return f


def main():
    s = v.sym()
    a = symboles()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    verifie(a.get('App_Start') == 0, 'App_Start à l\'offset 0')
    # Le parcours : arrêts (photos) entre des touches tenues
    script = [
        (40, photo('départ')),
        (41, appui(HAUT)), (61, relache(HAUT)),                 # avancer
        (100, photo('avancé')),
        (101, appui(DROITE)), (131, relache(DROITE)),           # tourner à droite
        (180, photo('tourné')),
        (181, appui(GAUCHE)), (191, appui(HAUT)),               # gauche + avancer
        (231, relache(HAUT)), (232, relache(GAUCHE)),
        (280, photo('virage')),
        (281, appui(HAUT)), (481, relache(HAUT)),               # longue marche : contre un mur
        (540, photo('mur')),
        (541, appui(DROITE)), (601, relache(DROITE)),           # un demi-tour environ, en mesurant
        (590, lambda m: m.photos.__setitem__('mesure', m.banks[1][m.a_['Trames']])),
        (650, photo('demi-tour')),
        (651, appui(0x76, False)), (653, relache(0x76, False)),  # Echap
        (2000, lambda m: (_ for _ in ()).throw(Fini())),
    ]
    def seance(script, fichier=None):
        d = tempfile.mkdtemp()
        c = va.Carte(d)
        if fichier is not None:
            chemin = os.path.join(d, 'carte.txt')
            open(chemin, 'wb').write(fichier)
            c.ajoute('DONJON39.TXT', chemin, page=1, adresse='0000', attr=0x06)
        m = Banc(c.image, s, a, script)
        v.installe_bios(m)          # table des services, et BIOS2
        m.wr16(0xDFF6, s['handler_IRQ'])
        m.mem[s['son_coupe']] = 0x4D
        m.mem[s['current_page']] = 1
        code = open(BIN, 'rb').read()
        m.banks[1][:len(code)] = code
        m.page = 1
        try:
            v.appelle(m, a['App_Start'], 60_000_000)
            r = 'rendu'
        except Fini:
            r = 'pas rendu (Echap ignoré)'
        except Exception as e:      # noqa: BLE001
            r = 'PLANTE : %s ($%04X page %d)' % (e, m.pc, m.page)
        return m, r

    def compare(m, nom):
        if nom not in m.photos:
            verifie(False, 'photo « %s » prise' % nom)
            return
        px, py, ang, vram, trame, _, carte, mini = m.photos[nom]
        g, at = donjon39.vue(px, py, ang, carte, mini)
        diff = [(rg, col) for rg in range(donjon39.VUE_H) for col in range(64)
                if vram[rg][0][col] != g[rg][col] or vram[rg][1][col] != at[rg][col]]
        verifie(not diff, 'vue « %s » (x=%.2f y=%.2f angle %d%s, trame %d) = le modèle%s'
                % (nom, px / 256, py / 256, ang, ', mini-carte' if mini else '', trame,
                   '' if not diff else ' : %d cellules différentes, ex. %s' % (len(diff), diff[:3])))

    m, r = seance(script)
    verifie(r == 'rendu', 'Echap : l\'application rend la main par RTS (%s)' % r)
    verifie(m.mem[s['kbd_queue']] == m.mem[s['kbd_tete']], 'en sortant, la file du clavier est vide')
    verifie(m.rd16(0xDFF6) == s['handler_IRQ'], 'en sortant, rvec_IRQ rendu au BIOS ($%04X)' % m.rd16(0xDFF6))

    verifie(m.photos.get('départ', [None] * 7)[6] == donjon39.T['Carte'], 'sans DONJON39.TXT : la carte intégrée')
    for nom in ('départ', 'avancé', 'tourné', 'virage', 'mur', 'demi-tour'):
        compare(m, nom)
    p = m.photos
    if 'départ' in p and 'avancé' in p:
        verifie(p['avancé'][0] > p['départ'][0] and p['avancé'][2] == p['départ'][2], 'flèche haut : on avance en x (angle 0), angle inchangé')
    if 'avancé' in p and 'tourné' in p:
        verifie(p['tourné'][2] != p['avancé'][2], 'flèche droite : l\'angle change (%d -> %d)' % (p['avancé'][2], p['tourné'][2]))
    if 'mur' in p:
        px, py = p['mur'][0], p['mur'][1]
        libre = all(donjon39.T['Carte'][((py + dy) >> 8) * 16 + ((px + dx) >> 8)] == 0
                    for dx in (-60, 0, 60) for dy in (-60, 0, 60))
        verifie(libre, 'longue marche contre un mur : toujours à distance (x=%.2f y=%.2f)' % (px / 256, py / 256))
    # VRAM : au début des trames, et pas plus que permis par trame
    vue = m.ecritures
    tard = max((e[1] for e in vue), default=0)
    hors = sum(1 for e in vue if not e[2])
    par_trame = {}
    for t, _, _ in vue:
        par_trame[t] = par_trame.get(t, 0) + 1
    # Irq_Donjon : ~35 instructions par rangée recopiée (2 TFM de 64 octets,
    # ~200 cycles chacun), ~6 par rangée propre sautée : 4 rangées
    # ~ 2 100 cycles, pour ~2 600 cycles de retour de trame (45 lignes).
    verifie(vue and hors == 0 and tard < 260,
            'écritures en VRAM : %d, toutes dans l\'IRQ (%d hors), dans ses %d premières instructions (< 260)' % (len(vue), hors, tard))
    verifie(max(par_trame.values(), default=0) <= 4 * 128, 'au plus 4 rangées (512 octets) par trame (%d)' % max(par_trame.values(), default=0))
    if 'mesure' in p:
        print('Mesure : %d trames par image en tournant (indicatif : %d instructions par trame)' % (p['mesure'], TRAME))

    # --- Seconde séance : DONJON39.TXT, porte, mini-carte ---
    fichier = (b"; carte d'essai : commentaires, CR LF et LF, minuscules\r\n"
               b"1111111111111111\r\n"
               b"1jp....3\n"                       # courte : le reste vide, le bord en mur
               b"\r\n"
               b"1..............1\r\n"
               b"1..4444...7....1\n"
               b";\n"
               b"1..4..4...7....1\r\n"
               b"1..4..p...7....1\r\n"
               b"1..............1")                  # dernière ligne sans fin ; 7 rangées seulement
    attendu, dep = donjon39.texte_carte(fichier)
    script = [
        (40, photo('fichier')),
        (41, appui(0x29, False)), (42, relache(0x29, False)),          # Espace : la porte de devant
        (80, photo('porte ouverte')),
        (81, appui(0x0D, False)), (82, relache(0x0D, False)),          # Tab : mini-carte
        (120, photo('mini-carte')),
        (121, appui(0x0D, False)), (122, relache(0x0D, False)),        # Tab : plus de mini-carte
        (450, photo('porte refermée')),
        (451, appui(0x76, False)), (453, relache(0x76, False)),
        (2000, lambda m: (_ for _ in ()).throw(Fini())),
    ]
    m, r = seance(script, fichier)
    verifie(r == 'rendu', 'séance DONJON39.TXT : Echap rend la main (%s)' % r)
    p = m.photos
    if 'fichier' in p:
        verifie(p['fichier'][6] == attendu, 'DONJON39.TXT : la carte en mémoire = texte_carte() du modèle')
        verifie(p['fichier'][:3] == dep, 'DONJON39.TXT : départ sur le J (x=%.2f y=%.2f angle %d)' % (p['fichier'][0] / 256, p['fichier'][1] / 256, p['fichier'][2]))
    porte = 1 * 16 + 2
    if 'porte ouverte' in p and 'fichier' in p:
        verifie(p['fichier'][6][porte] == donjon39.PORTE and p['porte ouverte'][6][porte] == 0,
                'Espace : la porte de devant s\'ouvre (case %d -> 0)' % p['fichier'][6][porte])
    if 'porte refermée' in p:
        verifie(p['porte refermée'][6][porte] == donjon39.PORTE, 'la porte se referme seule (%d trames)' % 300)
    for nom in ('fichier', 'porte ouverte', 'mini-carte', 'porte refermée'):
        compare(m, nom)
    if 'mini-carte' in p and 'porte refermée' in p:
        verifie(p['mini-carte'][7] == 1 and p['porte refermée'][7] == 0, 'Tab montre puis cache la mini-carte')
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
