#!/usr/bin/env python3
# ===================================================================
# essai_sd.py - Essais de la carte SD (SPI matériel) à travers TELE
# ===================================================================
# Assemble tools/tele/essai_sd.asm à $1000, le charge en page 1 par TELE
# (lancé sur la machine), puis enchaîne les essais demandés :
#   python3 tools/tele/essai_sd.py init
#   python3 tools/tele/essai_sd.py lit LBA
#   python3 tools/tele/essai_sd.py ecrit LBA FACON [MOTIF]
#       FACON : 0 boucle serrée (rapide), 1 octets espacés (rapide),
#               2 tout en lent ; MOTIF : 'sept' (3 + 7i), 'zero', 'ff',
#               'sans40' (3 + 7i, jamais $40-$7F)
#   python3 tools/tele/essai_sd.py etat
#   python3 tools/tele/essai_sd.py vitesse lent|rapide
# LBA en hexa. Le module reste chargé : --pas-de-charge évite de le
# recharger entre deux essais.
# ===================================================================
import os
import re
import subprocess
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import tele                     # noqa: E402

ORIGINE = 0x1000
TAMPON_E, TAMPON_L = 0x3000, 0x3200     # données à écrire, données lues


def assemble():
    src = os.path.join(ICI, 'essai_sd.asm')
    obj = os.path.join(ICI, 'essai_sd.o')
    out = os.path.join(ICI, 'ESSAI_SD')
    carte = os.path.join(ICI, 'ESSAI_SD.map')
    subprocess.run(['lwasm', '--format=obj', '--6309', '-o', obj, src], check=True, cwd=ICI)
    subprocess.run(['lwlink', '--format=raw', '--section-base=.code=0x%04x' % ORIGINE,
                    '--map=' + carte, '-o', out, obj], check=True)
    sym = {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(carte).read())}
    return open(out, 'rb').read(), sym


def motif(nom):
    if nom == 'zero':
        return bytes(512)
    if nom == 'ff':
        return b'\xff' * 512
    m = bytes((3 + 7 * i) & 255 for i in range(512))
    if nom == 'sans40':
        m = bytes(o if not 0x40 <= o <= 0x7F else o ^ 0x80 for o in m)
    return m


def main():
    args = sys.argv[1:]
    charge = '--pas-de-charge' not in args
    args = [a for a in args if a != '--pas-de-charge']
    code, sym = assemble()
    t = tele.Tele(tele.Liaison())
    if charge:
        t.ecrit(1, ORIGINE, code)
        if t.lit(1, ORIGINE, len(code)) != code:
            print('module mal chargé')
            return 1
    S = lambda n: sym[n]                                    # noqa: E731

    def arg(lba):
        t.ecrit(1, S('Arg'), lba.to_bytes(4, 'big'))

    c = args[0]
    if c == 'init':
        r = t.appel(S('Init'))
        q = t.lit(1, S('Quatre'), 4)
        n = int.from_bytes(t.lit(1, S('Essais'), 2), 'big')
        print('Init : A=%02X (0 = prête) B=%02X C=%d, ACMD41 %d essai(s), OCR %s'
              % (r['a'], r['b'], r['c'], n, q.hex().upper()))
    elif c == 'vitesse':
        t.appel(S('Ctrl'), a=0x02 if args[1] == 'rapide' else 0x00)
        print('SD_CTRL =', '02' if args[1] == 'rapide' else '00')
    elif c == 'lit':
        arg(int(args[1], 16))
        r = t.appel(S('Lit'), x=TAMPON_L)
        d = t.lit(1, TAMPON_L, 512)
        print('Lit %s : A=%02X C=%d' % (args[1], r['a'], r['c']))
        for i in (0, 16, 496):
            print('  %03X  %s' % (i, ' '.join('%02X' % o for o in d[i:i + 16])))
    elif c == 'ecrit':
        lba, facon = int(args[1], 16), int(args[2])
        m = motif(args[3] if len(args) > 3 else 'sept')
        t.ecrit(1, TAMPON_E, m)
        arg(lba)
        r = t.appel(S('Ecrit'), b=facon, x=TAMPON_E, delai=20.0)
        tr = t.lit(1, S('Trace'), 16)
        occ = int.from_bytes(t.lit(1, S('Occupe'), 2), 'big')
        print('Ecrit %s façon %d : A=%02X C=%d, après le CRC : %s, occupée %d trames'
              % (args[1], facon, r['a'], r['c'], tr.hex(' ').upper(), occ))
        if not r['c']:
            arg(lba)
            r2 = t.appel(S('Lit'), x=TAMPON_L)
            d = t.lit(1, TAMPON_L, 512)
            print('  relu : A=%02X C=%d, %s' % (r2['a'], r2['c'], 'IDENTIQUE' if d == m else
                  'différent (%d octets)' % sum(1 for a, b in zip(d, m) if a != b)))
    elif c == 'etat':
        r = t.appel(S('Etat'))
        print('CMD13 : R1=%02X suite=%02X C=%d' % (r['a'], r['b'], r['c']))
    else:
        print('commande inconnue')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
