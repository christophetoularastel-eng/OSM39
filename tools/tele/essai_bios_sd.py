#!/usr/bin/env python3
# ===================================================================
# essai_bios_sd.py - Le VRAI pilote bios/SD.asm, en RAM, sur la carte,
#                    par TELE (avant de flasher l'EPROM)
# ===================================================================
# Assemble bios/SD.asm et tools/tele/banc_bios_sd.asm, les relie à $1000
# (page 1) avec les adresses de la RAM du BIOS lues dans bios/osm39.map
# (le BIOS de l'EPROM a le même plan RAM), charge par TELE, puis :
#   1. Init_SD_Card ;
#   2. SD_ReadBlock du secteur 0, puis N lectures comparées (débit) ;
#   3. SD_WriteBlock de motifs aléatoires sur des secteurs d'essai à
#      partir de $00100000, relus par SD_ReadBlock.
#   python3 tools/tele/essai_bios_sd.py [N_LECTURES] [N_ECRITURES]
# ===================================================================
import os
import random
import re
import subprocess
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, ICI)
import tele                     # noqa: E402

ORIGINE = 0x1000
IMPORTS = ('buffer', 'sd_ctrl', 'SD_BUFFER', 'BlockAddr', 'CMD17_Packet', 'CMD24_Packet')
LBA_ESSAI = 0x00100000


def construit():
    carte = open(os.path.join(RACINE, 'bios', 'osm39.map')).read()
    adr = {n: a for n, a in re.findall(r'Symbol: (\S+) \(ram\.o\) = ([0-9A-F]{4})', carte)}
    d = tempfile.mkdtemp()
    ram = os.path.join(d, 'ram_bios.asm')
    with open(ram, 'w') as f:
        for n in IMPORTS:               # section .abs posée en $0000 : adresses exactes
            f.write('    export  %s\n' % n)
        f.write('    section .abs\n')
        for n in IMPORTS:
            f.write('%s equ $%s\n' % (n, adr[n]))
    objs = []
    for src, inc in ((os.path.join(RACINE, 'bios', 'SD.asm'), os.path.join(RACINE, 'bios')),
                     (os.path.join(ICI, 'banc_bios_sd.asm'), ICI), (ram, d)):
        o = os.path.join(d, os.path.basename(src) + '.o')
        subprocess.run(['lwasm', '--format=obj', '--6309', '-I', inc, '-o', o, src], check=True, cwd=os.path.dirname(src))
        objs.append(o)
    out, m = os.path.join(d, 'BANC'), os.path.join(d, 'BANC.map')
    subprocess.run(['lwlink', '--format=raw', '--section-base=.code=0x%04x' % ORIGINE, '--section-base=.abs=0x0000', '--map=' + m, '-o', out] + objs,
                   check=True)
    sym = {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(m).read())}
    for n in IMPORTS:                   # le pilote doit voir la VRAIE RAM du BIOS
        if sym[n] != int(adr[n], 16):
            raise SystemExit('%s relié en $%04X au lieu de $%s' % (n, sym[n], adr[n]))
    return open(out, 'rb').read(), sym


def main():
    n_lect = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    n_ecr = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    code, S = construit()
    if ORIGINE + len(code) > 0x8000:
        print('banc trop grand')
        return 1
    t = tele.Tele(tele.Liaison())
    t.ecrit(1, ORIGINE, code)
    if t.lit(1, ORIGINE, len(code)) != code:
        print('banc mal chargé')
        return 1
    print('banc chargé : %d octets en 1:%04X (SD.o du BIOS + banc)' % (len(code), ORIGINE))
    echecs = 0

    r = t.appel(S['Init_SD_Card'], delai=20)
    print('Init_SD_Card : C=%d, sd_ctrl=%02X' % (r['c'], t.lit(0, S['sd_ctrl'], 1)[0]))
    if r['c']:
        return 1

    def lba(n):
        t.ecrit(0, S['BlockAddr'], n.to_bytes(4, 'big'))

    lba(0)
    r = t.appel(S['SD_ReadBlock'])
    s0 = t.lit(0, S['SD_BUFFER'], 512)
    print('SD_ReadBlock 0 : A=%02X, octets 508-511 %s' % (r['a'], s0[508:].hex(' ')))
    echecs += r['a'] != 0
    t.ecrit(1, S['Reference'], s0)
    r = t.appel(S['Banc_Lectures'], a=n_lect >> 8, b=n_lect & 255, delai=600)
    tr = int.from_bytes(t.lit(1, S['Trames'], 2), 'big')
    err = (r['a'] << 8) | r['b']
    ko = n_lect * 512 * 60 // 1024 // tr if tr else 0
    print('%d lectures du secteur 0 : %d erreur(s) (dernier code %02X), %d trames, %d Ko/s'
          % (n_lect, err, t.lit(1, S['Dernier'], 1)[0], tr, ko))
    echecs += err != 0

    rnd = random.Random(30)
    bons = 0
    for k in range(n_ecr):
        m = bytes(rnd.randrange(256) for _ in range(512))
        t.ecrit(0, S['SD_BUFFER'], m)
        lba(LBA_ESSAI + 0x10 + k)
        w = t.appel(S['SD_WriteBlock'], delai=20)
        t.ecrit(0, S['SD_BUFFER'], bytes(512))
        r = t.appel(S['SD_ReadBlock'])
        d = t.lit(0, S['SD_BUFFER'], 512)
        bon = w['a'] == 0 and r['a'] == 0 and d == m
        bons += bon
        if not bon:
            print('  secteur %08X : SD_WriteBlock A=%02X, SD_ReadBlock A=%02X, %s'
                  % (LBA_ESSAI + 0x10 + k, w['a'], r['a'], 'relu identique' if d == m else 'relu différent'))
    print('%d écritures (motifs aléatoires) : %d relues identiques' % (n_ecr, bons))
    echecs += bons != n_ecr
    print('BILAN : %s' % ('OK' if not echecs else '%d ÉCHEC(S)' % echecs))
    return 1 if echecs else 0


if __name__ == '__main__':
    sys.exit(main())
