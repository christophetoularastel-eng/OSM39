#!/usr/bin/env python3
# ===================================================================
# glyphes_ui.py - Glyphes d'OSM-VISION en page 1 du générateur, $1C-$1F
# ===================================================================
# Les quatre dernières cases libres de la page 1 (voir lib/ui.inc) :
#   $1C  UI_HP        le haut-parleur (à gauche de l'indicateur du son)
#   $1D  UI_HP_ONDES  ses ondes : son en marche
#   $1E  UI_HP_MUET   une croix : son coupé (touche M)
#   $1F  UI_FLECHE    la flèche du pointeur (la future souris)
# Écrit les glyphes dans video/font_osm39.bin (page 1 = octets 4096 et
# plus, 16 octets par glyphe, bit 7 = pixel de gauche), puis il faut
# reprogrammer l'EPROM des caractères avec ce fichier.
#   python3 video/glyphes_ui.py            écrit (refuse une case occupée
#                                           par autre chose)
#   python3 video/glyphes_ui.py --verifie  dit si la police est à jour
# ===================================================================
import os
import sys

POLICE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'font_osm39.bin')
PAGE1 = 4096

GLYPHES = {
    0x1C: [                     # UI_HP : le haut-parleur
        '........',
        '........',
        '........',
        '......#.',
        '.....##.',
        '....###.',
        '#######.',
        '#######.',
        '#######.',
        '#######.',
        '#######.',
        '....###.',
        '.....##.',
        '......#.',
        '........',
        '........',
    ],
    0x1D: [                     # UI_HP_ONDES : son en marche
        '........',
        '........',
        '........',
        '...#....',
        '....#...',
        '.#...#..',
        '..#..#..',
        '..#...#.',
        '..#...#.',
        '..#...#.',
        '..#..#..',
        '.#...#..',
        '....#...',
        '...#....',
        '........',
        '........',
    ],
    0x1E: [                     # UI_HP_MUET : son coupé
        '........',
        '........',
        '........',
        '........',
        '........',
        '#.....#.',
        '.#...#..',
        '..#.#...',
        '...#....',
        '..#.#...',
        '.#...#..',
        '#.....#.',
        '........',
        '........',
        '........',
        '........',
    ],
    0x1F: [                     # UI_FLECHE : le pointeur
        '#.......',
        '##......',
        '###.....',
        '####....',
        '#####...',
        '######..',
        '#######.',
        '########',
        '#####...',
        '##.##...',
        '#..##...',
        '....##..',
        '....##..',
        '.....##.',
        '.....##.',
        '........',
    ],
}


def octets(dessin):
    assert len(dessin) == 16 and all(len(l) == 8 for l in dessin)
    return bytes(int(l.replace('#', '1').replace('.', '0'), 2) for l in dessin)


def main():
    police = bytearray(open(POLICE, 'rb').read())
    assert len(police) == 8192
    a_jour = True
    for code, dessin in GLYPHES.items():
        voulu = octets(dessin)
        k = PAGE1 + code * 16
        actuel = bytes(police[k:k + 16])
        if actuel == voulu:
            continue
        a_jour = False
        if '--verifie' in sys.argv:
            continue
        if any(actuel):
            print('page 1 $%02X : occupée par un autre dessin, rien écrit' % code)
            return 1
        police[k:k + 16] = voulu
    if '--verifie' in sys.argv:
        print('police : glyphes $1C-$1F %s' % ('à jour' if a_jour else 'ABSENTS (lancer sans --verifie)'))
        return 0 if a_jour else 1
    if not a_jour:
        open(POLICE, 'wb').write(police)
        print('%s : glyphes $1C-$1F écrits ; reprogrammer l\'EPROM des caractères' % POLICE)
    else:
        print('police déjà à jour')
    return 0


if __name__ == '__main__':
    sys.exit(main())
