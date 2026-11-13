#!/usr/bin/env python3
# ===================================================================
# bios2.py - La seconde partie du BIOS (section .ext) et sa somme
# ===================================================================
# Le BIOS est lié une seule fois : la section .ext (code chargé en RAM
# système depuis la carte, fichier BIOS2) est liée à EXT_BASE avec le
# reste. Ce script, après srec2bin :
#   - extrait du S-Record les octets de .ext -> BIOS2 ;
#   - écrit dans l'image EPROM (osm39.bin) leur longueur et leur somme
#     (16 bits, octets additionnés), aux adresses des symboles ExtLong et
#     ExtSomme (lus dans la map) : l'EPROM ne charge qu'un BIOS2 qui est
#     exactement celui construit avec elle.
#   python3 bios2.py osm39.srec osm39.map osm39.bin BIOS2 EXT_BASE EXT_FIN
# ===================================================================
import re
import sys


def main():
    srec, carte, eprom, sortie = sys.argv[1:5]
    base, limite = int(sys.argv[5], 0), int(sys.argv[6], 0)
    texte = open(carte).read()
    sec = re.findall(r'Section: \.ext \(\S+\) load at ([0-9A-F]+), length ([0-9A-F]+)', texte)
    sym = {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', texte)}
    debut, fin = base, max([base] + [int(a, 16) + int(n, 16) for a, n in sec])
    mem = {}
    for ligne in open(srec):
        ligne = ligne.strip()
        if not ligne.startswith('S1'):
            continue
        n = int(ligne[2:4], 16)
        a = int(ligne[4:8], 16)
        for i in range(n - 3):
            mem[a + i] = int(ligne[8 + 2 * i:10 + 2 * i], 16)
    corps = bytes(mem.get(a, 0) for a in range(debut, fin))
    tas = sym['__bss_end__'] + 0x100                      # HEAP_SIZE (vectors.asm)
    if tas > base:
        sys.exit('ERREUR : le tas système finit en $%04X, au-delà de EXT_BASE $%04X' % (tas, base))
    if fin > limite:
        sys.exit('ERREUR : BIOS2 finit en $%04X, au-delà de $%04X (la pile)' % (fin, limite))
    somme = sum(corps) & 0xFFFF
    open(sortie, 'wb').write(corps)
    image = bytearray(open(eprom, 'rb').read())
    for nom, val in (('ExtLong', len(corps)), ('ExtSomme', somme)):
        o = sym[nom] - 0xE000
        image[o], image[o + 1] = val >> 8, val & 0xFF
    open(eprom, 'wb').write(image)
    print('BIOS2 : $%04X-$%04X, %d octets (place : %d), somme $%04X'
          % (debut, fin - 1 if fin > debut else debut, len(corps), limite - fin, somme))


if __name__ == '__main__':
    main()
