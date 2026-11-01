#!/usr/bin/env python3
# ===================================================================
# clouris.py - La Clouris en direct, par TELE (cmd/tele.asm lancé)
# ===================================================================
# Pose en page 1, $1000, une routine qui lit R14 (port A de l'AY) 250
# fois sur ~0,1 s et compte, pour chacun des 6 bits, les lectures à 1.
# Le PC l'appelle en boucle et affiche, par clou, la part du temps où
# le doigt est vu : de quoi régler tirages, clous, doigt mouillé...
#   python3 tools/tele/clouris.py            (Ctrl+C pour finir)
# Source de la routine (lwasm --6309, org $1000) :
#   Debut  ldx #Compte / ldb #6 / Raz clr ,x+ / decb / bne Raz
#          lde #250
#   Echant lda #14 / sta $A150 / lda $A150     ; R14
#          ldx #Compte / ldb #6
#   Bit    lsra / bcc Suiv / inc ,x
#   Suiv   leax 1,x / decb / bne Bit
#          ldy #60 / Pause leay -1,y / bne Pause
#          dece / bne Echant / rts
#   Compte rmb 6                                ; $1031
# Câblage (J104 de la carte SD-KBD-SON) : voir cmd/cloutest.asm.
# ===================================================================
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tele import ErreurTele, Liaison, Tele   # noqa: E402

ROUTINE = bytes.fromhex(
    '8e1031c6066f805a26fb1186fa860eb7a150b6a1508e1031c606442402'
    '6c8430015a26f6108e003c313f26fc114a26dd39')
ADR, COMPTE, N = 0x1000, 0x1031, 250
NOMS = ['haut', 'droite', 'bas', 'gauche', 'centre', 'clic gauche']
LARGEUR = 40


def main():
    t = Tele(Liaison())
    t.ping()
    t.ecrit(1, ADR, ROUTINE)
    if t.lit(1, ADR, len(ROUTINE)) != ROUTINE:
        print('routine mal relue')
        return 1
    maxi = [0] * 6
    sys.stdout.write('\033[2J')
    try:
        while True:
            t.appel(ADR)
            c = t.lit(1, COMPTE, 6)
            lignes = ['Clouris : part du temps où chaque clou est vu (~0,1 s)', '']
            for i in range(6):
                pc = 100 * c[i] // N
                maxi[i] = max(maxi[i], pc)
                barre = '#' * (LARGEUR * c[i] // N)
                lignes.append('IOA%d %-11s |%-*s| %3d %%  (max %3d %%)' % (
                    i, NOMS[i], LARGEUR, barre, pc, maxi[i]))
            lignes += ['', 'Ctrl+C pour finir ; reprises de trames : %d' % t.reprises]
            sys.stdout.write('\033[H' + '\n'.join(l + '\033[K' for l in lignes) + '\n')
            sys.stdout.flush()
    except KeyboardInterrupt:
        print()
    except ErreurTele as e:
        print('ERREUR : %s' % e)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
