#!/usr/bin/env python3
# ===================================================================
# verifie_osm3d.py - apps/OSM3D = le modèle tools/osm3d/osm3d.py
# ===================================================================
# Le VRAI binaire (page 1, $0000) tourne dans la machine de verifie_fs.py,
# appelé comme OSM-VISION l'appelle (App_Start), la carte OSM3D.MAP et
# OSM3D.RUE sur la carte SD émulée. Une trame toutes les TRAME
# instructions : l'IRQ VSYNC est prise (rvec_IRQ : Irq_3D puis le VRAI
# handler_IRQ du BIOS). Le clavier : des octets PS/2 bruts dans la file de
# la NMI.
#   - à l'arrêt (flèches relâchées, file de copies vide), à plusieurs
#     endroits atteints au clavier, les 30 rangées de l'écran (glyphes ET
#     attributs) sont EXACTEMENT ecran() du modèle pour la position et
#     l'angle que le binaire a en mémoire : la vue, la mini-carte et son
#     cadre, la plaque de la rue, l'aide, le reste vide ;
#   - chaque accès du CPU à la VRAM (lecture ou écriture) se fait DANS
#     l'IRQ, dans ses premières instructions, BUDGET octets au plus par
#     trame ;
#   - une longue marche contre un immeuble n'y entre pas ;
#   - au pont de la rue Montgolfier : au sol on passe dessous par l'avenue
#     Simone Veil (l'arche à l'écran = le modèle), on ne monte que par sa
#     rampe ; l'étage et la case toujours d'accord ;
#   - un appui sur une flèche de côté = un pas de 16/1024 ; tenue, un pas
#     par répétition automatique du clavier ; une flèche lâchée arrête tout (le clavier
#     est lu par l'IRQ à chaque trame : aucun octet perdu) ;
#   - Echap rend la main par RTS ; les rangées 25-29 d'avant rendues, la
#     file du clavier vidée, rvec_IRQ rendu au BIOS.
# Mesure (indicative) : trames par image en tournant.
# ===================================================================
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'osm3d'))
import verifie_fs as v          # noqa: E402
import carte                    # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_donjon39 as vd     # noqa: E402
import osm3d                    # noqa: E402
import osmcity as oc            # noqa: E402

BIN = os.path.join(RACINE, 'apps', 'OSM3D')
MAP = os.path.join(RACINE, 'apps', 'OSM3D.map')
HAUT, BAS, GAUCHE, DROITE = 0x75, 0x72, 0x6B, 0x74
BUDGET, COUT_COPIE = 580, 34
LIMITE = 1900                   # cycles estimés après l'entrée de l'IRQ


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


class Banc(vd.Banc):
    def __init__(self, *args):
        super().__init__(*args)
        self.images = []                # trames des échanges de tampons
        self.perdus = 0                 # octets du clavier perdus (file pleine)
        self.suivi = []                 # (x, y, sorte, étage) : suivi()

    def accede(self, adr):
        # cycles estimés : 4 par instruction depuis l'entrée de l'IRQ, plus
        # 3 par octet de TFM (un accès à la VRAM par octet copié)
        if 0x8000 <= adr < 0xA000 and self.page == 1 and self.rd16(0xDFF6) == self.a_['Irq_3D']:
            if self.n_irq != getattr(self, 'irq_vu', None):
                self.irq_vu, self.octets = self.n_irq, 0
            self.octets += 1
            self.ecritures.append((self.trame, 4 * (self.n - self.n_irq) + 3 * self.octets, self.dans_irq > 0))

    def octet_clavier(self, o):
        # comme la NMI : file pleine, l'octet est perdu
        t = self.mem[self.s_['kbd_tete']]
        self.mem[self.s_['kbd_buf'] + t] = o
        if (t + 1) & 15 != self.mem[self.s_['kbd_queue']]:
            self.mem[self.s_['kbd_tete']] = (t + 1) & 15
        else:
            self.perdus += 1

    def wr8(self, adr, val):
        self.accede(adr)
        if self.page == 1 and adr == self.a_['PtrPret'] + 1:     # un échange de tampons
            self.images.append(self.trame)
        va.MachineAsm.wr8(self, adr, val)

    def rd8(self, adr):
        if 0x8000 <= adr < 0xA000:
            self.accede(adr)
        return va.MachineAsm.rd8(self, adr)


def tenue(code, debut, fin, periode=2):
    # une flèche tenue : l'appui, la répétition automatique du clavier (un
    # code d'appui toutes les `periode` trames, 30 par seconde pour 2), le
    # relâchement
    return ([(debut, vd.appui(code))] + [(t, vd.appui(code)) for t in range(debut + 20, fin, periode)]
            + [(fin, vd.relache(code))])


def appuis(debut, fin, periode=2):
    """Les codes d'appui d'une flèche tenue (tenue()) : un pas chacun."""
    return 1 + len(range(debut + 20, fin, periode))


def position(m):
    a = m.a_
    return (mot(m, a, 'PosX'), mot(m, a, 'FrX', 1), mot(m, a, 'PosY'), mot(m, a, 'FrY', 1), mot(m, a, 'Ang'))


def mot(m, a, nom, n=2):
    b = m.banks[1][a[nom]:a[nom] + n]
    return int.from_bytes(bytes(b), 'big')


def photo(nom):
    def f(m):
        a = m.a_
        e = [carte.lit(m.mem, r * 80, 80) for r in range(30)]
        m.photos[nom] = dict(x=mot(m, a, 'PosX'), fx=mot(m, a, 'FrX', 1), y=mot(m, a, 'PosY'),
                             fy=mot(m, a, 'FrY', 1), ang=mot(m, a, 'Ang'), niv=mot(m, a, 'Niv', 1),
                             ecran=e, trame=m.trame,
                             vide=m.banks[1][a['JqQ']] == m.banks[1][a['JqT']])
    return f


BAS = bytes(range(256)) * 3 + bytes(32)             # les rangées 25-29 d'avant


def session(s, a, script, depart=None):
    """Le binaire, appelé comme OSM-VISION l'appelle, avec ce script ;
    depart = (x, y, angle) change DepartX/DepartY/DepartA. Rend (machine,
    comment il a fini)."""
    script = sorted(script, key=lambda e: e[0])
    d = tempfile.mkdtemp()
    c = va.Carte(d)
    c.ajoute('OSM3D.MAP', os.path.join(RACINE, 'apps', 'OSM3D.MAP'), page=2, adresse='0000', attr=0x06)
    c.ajoute('OSM3D.RUE', os.path.join(RACINE, 'apps', 'OSM3D.RUE'), page=1, adresse='6000', attr=0x06)
    m = Banc(c.image, s, a, script)
    m.s_ = s
    v.installe_bios(m)
    m.wr16(0xDFF6, s['handler_IRQ'])
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 1
    m.mem[0x8000 + 25 * 160:0x8000 + 30 * 160] = BAS
    m.banks[1][:] = bytes(len(m.banks[1]))
    code = open(BIN, 'rb').read()
    m.banks[1][:len(code)] = code
    if depart:
        for nom, val in zip(('DepartX', 'DepartY', 'DepartA'), depart):
            m.banks[1][a[nom]:a[nom] + 2] = val.to_bytes(2, 'big')
    m.page = 1
    try:
        v.appelle(m, a['App_Start'], 120_000_000)
        r = 'rendu'
    except vd.Fini:
        r = 'pas rendu (Echap ignoré)'
    except Exception as e:      # noqa: BLE001
        r = 'PLANTE : %s ($%04X page %d)' % (e, m.pc, m.page)
    return m, r


def compare(verifie, c_, rues, f, nom):
    att = osm3d.ecran(c_, f['x'], f['fx'], f['y'], f['fy'], f['ang'], rues, f['niv'])
    diff = [(r, k) for r in range(30) for k in range(80)
            if (f['ecran'][r][0][k], f['ecran'][r][1][k]) != att[r][k]]
    verifie(f['vide'] and not diff, 'écran « %s » (x=%d,%d y=%d,%d angle %d, étage %d, trame %d) = le modèle%s%s'
            % (nom, f['x'], f['fx'], f['y'], f['fy'], f['ang'], f['niv'], f['trame'],
               '' if f['vide'] else ' (file de copies pas vide)',
               '' if not diff else ' : %d cellules différentes, ex. %s' % (
                   len(diff), [(r, k, (f['ecran'][r][0][k], f['ecran'][r][1][k]), att[r][k]) for r, k in diff[:3]])))


def suivi(m):
    """Toutes les 5 trames : (case, sorte, étage)."""
    a = m.a_
    x, y = mot(m, a, 'PosX'), mot(m, a, 'PosY')
    m.suivi.append((x, y, oc.sorte_xy(osm3d.carte(), x, y), mot(m, a, 'Niv', 1)))


def main():
    s = v.sym()
    a = symboles()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    verifie(a.get('App_Start') == 0, 'App_Start à l\'offset 0')
    c_ = osm3d.carte()
    rues = oc.rues()
    script = [
        (150, photo('départ')),
        (151, vd.appui(HAUT)), (231, vd.relache(HAUT)),             # avancer
        (330, photo('avancé')),
        (331, vd.appui(DROITE)), (336, vd.relache(DROITE)),         # un appui court à droite
        (460, photo('tourné')),
        (461, vd.appui(GAUCHE)), (471, vd.appui(HAUT)),             # gauche + avancer
        (551, vd.relache(HAUT)), (552, vd.relache(GAUCHE)),
        (650, photo('virage')),
        *tenue(HAUT, 651, 1251),                                    # longue marche : un mur
        (1350, photo('mur')),
        *tenue(DROITE, 1351, 1495, 4),                              # tenue : 32 appuis, un demi-tour
        (1610, photo('demi-tour')),
        *tenue(HAUT, 1611, 1811),                                   # repartir
        (1812, lambda m: m.photos.__setitem__('lâché', position(m))),
        (1910, photo('reparti')),
        # Haut tenu, puis Droite : le clavier ne répète plus que Droite ;
        # Droite lâchée, Haut reste tenu (plus aucune répétition)
        *[e for e in tenue(HAUT, 1920, 2140) if e[0] < 1990 or e[0] == 2140],
        *tenue(DROITE, 1990, 2020),
        (1989, lambda m: m.photos.__setitem__('avant virage', position(m))),
        (2030, lambda m: m.photos.__setitem__('après virage', position(m))),
        (2139, lambda m: m.photos.__setitem__('fin virage', position(m))),
        (2241, vd.appui(0x76, False)), (2243, vd.relache(0x76, False)),   # Echap
        (2940, lambda m: (_ for _ in ()).throw(vd.Fini())),
    ]
    m, r = session(s, a, script)
    bas = BAS
    verifie(r == 'rendu', 'Echap : l\'application rend la main par RTS (%s)' % r)
    verifie(m.mem[s['kbd_queue']] == m.mem[s['kbd_tete']], 'en sortant, la file du clavier est vide')
    verifie(m.rd16(0xDFF6) == s['handler_IRQ'], 'en sortant, rvec_IRQ rendu au BIOS ($%04X)' % m.rd16(0xDFF6))
    verifie(bytes(m.mem[0x8000 + 25 * 160:0x8000 + 30 * 160]) == bas, 'en sortant, les rangées 25-29 d\'avant rendues')

    p = m.photos
    for nom in ('départ', 'avancé', 'tourné', 'virage', 'mur', 'demi-tour', 'reparti'):
        if nom not in p:
            verifie(False, 'photo « %s » prise' % nom)
            continue
        compare(verifie, c_, rues, p[nom], nom)
    if 'départ' in p and 'avancé' in p:
        verifie((p['avancé']['y'], p['avancé']['fy']) < (p['départ']['y'], p['départ']['fy'])
                and p['avancé']['ang'] == p['départ']['ang'], 'flèche haut : on avance (vers le nord, angle 768)')
    if 'avancé' in p and 'tourné' in p:
        verifie(p['tourné']['ang'] == (p['avancé']['ang'] + 16) & 1023, 'un appui sur flèche droite : un pas de 16/1024 (%d -> %d)'
                % (p['avancé']['ang'], p['tourné']['ang']))
    if 'mur' in p and 'demi-tour' in p:
        verifie(p['demi-tour']['ang'] == (p['mur']['ang'] + appuis(1351, 1495, 4) * 16) & 1023,
                'flèche droite tenue (l\'appui + les répétitions du clavier) : %d pas (%d -> %d)'
                % (appuis(1351, 1495, 4), p['mur']['ang'], p['demi-tour']['ang']))
    if 'avant virage' in p and 'fin virage' in p:
        a0, a1, a2 = p['avant virage'], p['après virage'], p['fin virage']
        verifie(a1[4] == (a0[4] + appuis(1990, 2020) * 16) & 1023 and a2[4] == a1[4] and a2[:4] != a1[:4],
                'Haut tenu + Droite 30 trames (le clavier ne répète que Droite) : %d pas, puis on avance encore (%s -> %s -> %s)'
                % (appuis(1990, 2020), a0, a1, a2))
    if 'lâché' in p and 'reparti' in p:
        f = p['reparti']
        verifie(p['lâché'][:4] != (p['demi-tour']['x'], p['demi-tour']['fx'], p['demi-tour']['y'], p['demi-tour']['fy'])
                and (f['x'], f['fx'], f['y'], f['fy'], f['ang']) == p['lâché'],
                'flèche haut tenue (répétition à 30/s) puis lâchée : on s\'arrête (%s, %s)' % (p['lâché'], (f['x'], f['fx'], f['y'], f['fy'], f['ang'])))
    verifie(m.perdus == 0, 'aucun octet du clavier perdu par la NMI (file pleine) : %d' % m.perdus)
    if 'mur' in p and 'virage' in p:
        f = p['mur']
        libre = oc.sorte_xy(c_, f['x'], f['y']) not in (oc.BATI, oc.EAU, oc.FALAISE)
        bouge = (f['x'], f['fx'], f['y'], f['fy']) != tuple(p['virage'][k] for k in ('x', 'fx', 'y', 'fy'))
        verifie(libre and bouge, 'longue marche : on bouge, jamais dans le bâti (case %d,%d : %s)'
                % (f['x'], f['y'], oc.NOMS[oc.sorte_xy(c_, f['x'], f['y'])]))
    # VRAM : dans l'IRQ, au début, BUDGET octets au plus par trame
    acc = m.ecritures
    tard = max((e[1] for e in acc), default=0)
    hors = sum(1 for e in acc if not e[2])
    par_trame = {}
    for t, _, _ in acc:
        par_trame[t] = par_trame.get(t, 0) + 1
    verifie(acc and hors == 0 and tard <= LIMITE,
            'accès à la VRAM : %d, tous dans l\'IRQ (%d hors), au plus %d cycles estimés après son entrée (limite %d)'
            % (len(acc), hors, tard, LIMITE))
    verifie(max(par_trame.values(), default=0) <= BUDGET - COUT_COPIE, 'au plus %d octets par trame (%d)'
            % (BUDGET - COUT_COPIE, max(par_trame.values(), default=0)))
    ecarts = [b - a_ for a_, b in zip(m.images, m.images[1:])]
    tourne = [b - a_ for a_, b in zip(m.images, m.images[1:]) if 1351 <= a_ < 1495]
    if ecarts:
        print('Mesure : trames par image : moyenne %.1f, au plus %d ; en tournant : %s (%d instructions par trame)'
              % (sum(ecarts) / len(ecarts), max(ecarts), tourne, vd.TRAME))

    # Le pont de la rue Montgolfier : au sol on passe dessous par l'avenue
    # Simone Veil (l'arche à l'écran), on ne monte que par la rampe nord-est,
    # on ne descend du tablier que par une rampe. Toutes les 5 trames :
    # jamais au sol sur un tablier qui n'est pas un passage, à l'étage 1
    # seulement sur un tablier (osm3d.TABLIERS).
    noms = dict(enumerate(oc.NOMS))
    noms.update({osm3d.CULEE: 'culée', osm3d.MURET: 'muret', osm3d.PONT_ARC: 'pont (arche)',
                 osm3d.SOUS_ARC: 'passage (arche)', osm3d.BORDURE: 'bordure'})
    for nom, depart, attendu in (('dessous', (308, 136, 229), 0), ('dessus', (317, 135, 369), 1)):
        sc = [(t, suivi) for t in range(100, 1000, 5)]
        sc += [(150, photo(nom + ' départ')), *tenue(HAUT, 151, 351), (450, photo(nom + ' 1')),
               *tenue(HAUT, 451, 651), (750, photo(nom + ' 2')),
               (751, vd.appui(0x76, False)), (753, vd.relache(0x76, False)),
               (1400, lambda m: (_ for _ in ()).throw(vd.Fini()))]
        mb, r2 = session(s, a, sc, depart)
        verifie(r2 == 'rendu', 'pont « %s » : Echap rend la main (%s)' % (nom, r2))
        for k in (' départ', ' 1', ' 2'):
            if nom + k in mb.photos:
                compare(verifie, c_, rues, mb.photos[nom + k], nom + k)
            else:
                verifie(False, 'photo « %s » prise' % (nom + k))
        faux = [e for e in mb.suivi if (e[2] in osm3d.TABLIERS and e[2] not in osm3d.PASSAGE and e[3] != 1)
                or (e[3] == 1 and e[2] not in osm3d.TABLIERS)]
        sortes = sorted({(noms[e[2]], e[3]) for e in mb.suivi})
        verifie(not faux and any(e[3] == attendu and e[2] in osm3d.TABLIERS for e in mb.suivi),
                'pont « %s » : étage et case toujours d\'accord, passé %s un tablier (vu : %s)%s'
                % (nom, 'sous' if attendu == 0 else 'sur', sortes, '' if not faux else ' FAUX : %s' % faux[:3]))
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
