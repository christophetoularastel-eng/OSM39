#!/usr/bin/env python3
# ===================================================================
# verifie_banc_mono.py - L'étape 9 du banc (premier écran de la carte
#                        OSM39_mono) rejouée dans l'émulateur
# ===================================================================
# Le binaire test/TEST (stage9_mono) tourne seul dans la machine de
# verifie_fs.py, sans BIOS, jusqu'à sa boucle finale. Vérifie :
#   - aucune écriture hors de la VRAM $8000-$9FFF, sauf $A120 (page) et
#     $A100/$A101 (68B45) ; rien n'est écrit en $A000 (l'ACIA) ;
#   - les 4096 cases (caractère en $8000+2c, couleur en $8001+2c) sont
#     celles d'un modèle écrit ici à part ;
#   - page vidéo 0 (GRAPH = 0), 68B45 : départ $FFFF, curseur caché ;
#   - IRQ et FIRQ masquées, la boucle finale atteinte.
#   make -C test STAGE=stage9_mono
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402

TITRE = 'OSM39_mono - ETAPE 9 : VRAM ENTRELACEE (caractere pair, couleur impaire)'
TEXTES = [
    (0, TITRE),
    (2, "Rangee 3 : X rouge et O vert. X vert / O rouge = couleur decalee d'une case."),
    (14, 'Page 1 du generateur (attribut bit 7), codes $00-$4F :'),
    (16, 'Page 0, les 256 caracteres :'),
    (24, 'Rangees 5-12 : fond 0-7 (une rangee chacun) x texte 0-7 (blocs f/b).'),
    (29, 'Rangee 29 : la derniere rangee visible (80 x 30).'),
]


def modele():
    car = [0x20] * 4096
    col = [0x08] * 4096

    def pose(c, ch, at):
        car[c], col[c] = ch, at
    for r, t in TEXTES:
        for i, ch in enumerate(t):
            pose(r * 80 + i, ord(ch), 0x07)
    for k in range(80):
        pose(3 * 80 + k, ord('XO'[k % 2]), (0x04, 0x02)[k % 2])
    for fond in range(8):
        for texte in range(8):
            bloc = ' %d/%d OSM  ' % (texte, fond)
            for i, ch in enumerate(bloc):
                pose((5 + fond) * 80 + texte * 10 + i, ord(ch), fond * 16 + texte)
    for k in range(80):
        pose(15 * 80 + k, k, 0x87)
    for k in range(256):
        pose(17 * 80 + k, k, 0x07)
    for k in range(80):
        pose(22 * 80 + k, ord('0') + k % 10, 0x06)
    return bytes(car), bytes(col)


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    code = open(os.path.join(ICI, 'TEST'), 'rb').read()
    m = v.Machine(None, v.sym())
    m.banks[0][:len(code)] = code
    m.page = 0
    m.pc, m.s, m.cc = 0, 0x7F00, 0
    hors = []
    crtc = {'sel': None, 'r': {}}
    ctrl = []
    wr8 = m.wr8

    def ecrit(a, val):
        a &= 0xFFFF
        if a == 0xA100:
            crtc['sel'] = val
        elif a == 0xA101:
            crtc['r'][crtc['sel']] = val & 0xFF
        elif a == 0xA120:
            ctrl.append(val & 0xFF)
        elif not (a < 0x8000 or 0x8000 <= a < 0xA000):
            hors.append((a, val))
        wr8(a, val)
    m.wr8 = ecrit
    for _ in range(3):              # le banc n'a pas besoin de la carte SD
        pass
    pas, avant = 0, None
    while pas < 2_000_000:
        if m.pc == avant:
            break                   # BRA * : la boucle finale
        avant = m.pc
        m.step()
        pas += 1
    verifie(m.pc == avant, 'la boucle finale est atteinte (%d instructions)' % pas)
    verifie(not hors, 'aucune écriture hors de la VRAM, de $A120 et du 68B45 %s' % hors[:4])
    car = bytes(m.mem[0x8000 + 2 * c] for c in range(4096))
    col = bytes(m.mem[0x8001 + 2 * c] for c in range(4096))
    mcar, mcol = modele()
    diff = [(c % 80, c // 80) for c in range(4096) if (car[c], col[c]) != (mcar[c], mcol[c])]
    verifie(not diff, 'les 4096 cases (caractère pair, couleur impaire) = le modèle %s' % diff[:6])
    verifie(car[:len(TITRE)].decode('latin-1') == TITRE, 'rangée 0 : le titre')
    verifie(ctrl and all(x == 0 for x in ctrl), 'page vidéo 0, GRAPH = 0 ($A120 : %s)' % ctrl)
    verifie(crtc['r'].get(12) == 0xFF and crtc['r'].get(13) == 0xFF and crtc['r'].get(10) == 0x20,
            '68B45 : départ $FFFF, curseur caché (R10 = $20) %s' % crtc['r'])
    verifie(m.cc & 0x50 == 0x50, 'IRQ et FIRQ masquées (CC = $%02X)' % m.cc)
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
