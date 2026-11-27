#!/usr/bin/env python3
# ===================================================================
# captures.py - Les écrans du manuel, pris sur le vrai logiciel
# ===================================================================
# Une carte SD est préparée comme sur la machine (une image vierge,
# formatée par egofs, puis dist/SD appliqué par egofs_deploy.py) ; le
# vrai OSM-VISION tourne sur le vrai BIOS dans l'émulateur de
# test/verifie_bureau.py, avec des touches écrites d'avance ; la VRAM est
# dessinée par ecran.py. Les images vont dans docs/manuel/images/.
#   ./deploy_sd.sh && tools/manuel/.venv/bin/python tools/manuel/captures.py
# (ou python3 : il faut seulement PIL)
# ===================================================================
import os
import re
import subprocess
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, os.path.join(RACINE, 'test'))
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_bureau as vb     # noqa: E402
import carte                    # noqa: E402
import verifie_donjon39 as vdm    # noqa: E402
import ecran                    # noqa: E402

SORTIE = os.path.join(RACINE, 'docs', 'manuel', 'images')
ESPACE, BAS, ENTREE, HAUT, DROITE = 0x20, 0x81, 0x0D, 0x80, 0x83


def carte_deployee():
    d = tempfile.mkdtemp()
    c = va.Carte(d)
    subprocess.run([sys.executable, os.path.join(RACINE, 'tools', 'egofs', 'egofs_deploy.py'), c.image, '--oui'],
                   check=True, capture_output=True)
    return c


def vram(m):
    """Les 2400 caractères et couleurs, d'après la carte de CARTE (test/carte.py :
    sur la mono, caractère et couleur sont entrelacés)."""
    return (bytes(m.mem[carte.adr(c)] for c in range(2400)),
            bytes(m.mem[carte.adr_coul(c)] for c in range(2400)))


def ecrit(nom, m, rangees=30):
    car, col = vram(m)
    os.makedirs(SORTIE, exist_ok=True)
    ecran.image(car, col, rangees).save(os.path.join(SORTIE, nom + '.png'))
    print('%s.png' % nom)


class Machine(vdm.Banc):
    """Le vrai BIOS et OSM-VISION, l'IRQ du VSYNC à chaque trame (comme le
    vérificateur de DONJON39) ; les touches arrivent par kbd_poll, chacune
    à sa trame ; Fini à la trame de la photo."""

    def __init__(self, image, s, touches, photo):
        super().__init__(image, s, {'Irq_Donjon': -1}, [(photo, self.stop)])
        self.touches = list(touches)          # (trame, code)
        self.s_ = dict(self.s_)
        self.s_['PrintChar'] = -1             # la vraie console écrit en VRAM

    @staticmethod
    def stop(m):
        raise vdm.Fini()

    def step(self):
        s = self.s_
        if self.pc == s['kbd_poll']:
            self.a = 0
            if self.touches and self.trame >= self.touches[0][0]:
                self.a = self.touches.pop(0)[1]
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        super().step()


def scene(c, s, nom, touches, photo, rangees=30):
    """touches : liste de codes (une toutes les 4 trames) ou de (trame, code)."""
    t = []
    for k, x in enumerate(touches):
        t.append(x if isinstance(x, tuple) else (20 + 4 * k, x))
    m = Machine(c.image, s, t, photo)
    v.installe_bios(m)          # table des services, et BIOS2
    m.wr16(0xDFF6, s['handler_IRQ'])
    m.wr16(0xDFFA, s['handler_NMI'])
    code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()
    m.banks[0][:len(code)] = code
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 0
    m.page = 0
    m.cc = 0
    v.appelle(m, s['init_heap'])
    try:
        v.appelle(m, 0x0000, 400_000_000)
    except vdm.Fini:
        pass
    ecrit(nom, m, rangees)
    return m


def texte(t):
    return [ord(ch) if ch != '\n' else ENTREE for ch in t]


def main():
    s = v.sym()
    ov = {n: int(a, 16) for n, a in re.findall(
        r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(os.path.join(RACINE, 'osmvision', 'OSMVISION.map')).read())}
    c = carte_deployee()
    scenes = {
        'osmvision': [],
        'osmvision_aide': [ord('?')],
        'osmvision_menu': [BAS, BAS, ESPACE],
    }
    for nom, touches in scenes.items():
        m, r = vb.lance(c, s, touches, ov)
        ecrit(nom, m, 25)
    # le Terminal : T, puis des commandes
    scene(c, s, 'terminal', [ord('T'), (60, 0)] + texte('cd /games\n') + texte('ls\n') + texte('pwd\n'), 400, 25)
    # la liste comme OSM-VISION : « .. » hors de la racine, les dossiers,
    # puis les fichiers, chacun par ordre alphabétique
    fichiers = c.core.list_files()

    def liste(dossier):
        n = len(dossier) + 1 if dossier else 0
        ici = [f for f in fichiers if (f['path'].rsplit('/', 1)[0] if '/' in f['path'] else '') == dossier]
        noms = sorted(f['path'][n:] for f in ici if f['is_dir']) + sorted(f['path'][n:] for f in ici if not f['is_dir'])
        return (['..'] if dossier else []) + noms

    def dans(dossier, nom):
        return [BAS] * liste('').index(dossier) + [ENTREE, (40, 0)] + [BAS] * liste(dossier).index(nom) + [ENTREE]
    budget = (texte('Budget octobre\n') + texte('Loyer\n') + texte('Courses\n') + texte('Electricite\n')
              + texte('Total\n') + [HAUT] * 4 + [DROITE] + texte('650\n') + texte('312,40\n')
              + texte('78,90\n') + texte('@SUM(B2...B4)\n'))
    scenes2 = [
        ('edit', dans('DOC', 'EDIT.TXT'), 160),
        ('calc', dans('BIN', 'CALC') + [(90, 0)] + budget, 420),
        ('minitel', dans('APPS', 'MINITEL'), 320),
        ('parole', dans('APPS', 'PAROLE') + [(120, 0)] + texte('Bonjour, je suis OSM 39.'), 260),
        ('mire', dans('APPS', 'MIRE'), 160),
        ('musique', dans('MUSIQUE', 'KOROBEINIKI.MUS'), 420),
        ('donjon39', dans('GAMES', 'DONJON39'), 420),
        ('envahis', dans('GAMES', 'ENVAHIS'), 420),
        ('glouton', dans('GAMES', 'GLOUTON'), 420),
        ('briques', dans('GAMES', 'BRIQUES') + [(300, ord(' '))], 520),
    ]
    # la page d'accueil de MiniPavi (capture réelle), rendue par le décodeur de MINITEL
    subprocess.run([sys.executable, os.path.join(RACINE, 'tools', 'minitel', 'videotex.py'), '--png',
                    os.path.join(SORTIE, 'minipavi.png'), os.path.join(RACINE, 'tools', 'minitel', 'accueil_minipavi.vdt')],
                   check=True, capture_output=True)
    print('minipavi.png')
    for nom, touches, photo in scenes2:
        try:
            scene(c, s, nom, touches, photo, 30)
        except Exception as e:      # noqa: BLE001
            print('%s : %s' % (nom, e))


if __name__ == '__main__':
    main()
