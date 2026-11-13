#!/usr/bin/env python3
# ===================================================================
# verifie_ext.py - L'EPROM n'appelle jamais BIOS2 en direct
# ===================================================================
# BIOS2 (section .ext) peut manquer, ou ne pas correspondre à l'EPROM : le
# code de l'EPROM (sections .code, .vectors, .romjmp) ne doit nommer AUCUNE
# étiquette de .ext, sauf à travers les vecteurs ExtV (souches « jmp
# [ExtV+n] »), que Ext_Defauts remplit au reset. Le lien, lui, résout ces
# références sans rien dire : ce script les cherche dans les sources.
# Les données de .ext qui nomment l'EPROM (BIOS2 -> EPROM) sont permises,
# et une seule exception dans l'autre sens : Ext_Entree, qu'Ext_Charge
# n'appelle qu'une fois la longueur et la somme de BIOS2 vérifiées.
#   python3 verifie_ext.py *.asm       (échec : code de sortie 1)
# ===================================================================
import re
import sys

ETIQ = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*):?(?=\s|$)')
SECTION = re.compile(r'^\s+section\s+(\S+)', re.I)


def lignes(p):
    """(n°, section, texte sans commentaire) de chaque ligne de p."""
    sec = '.code'
    for n, l in enumerate(open(p, encoding='utf-8', errors='replace'), 1):
        m = SECTION.match(l)
        if m:
            sec = m.group(1).lower()
            continue
        t = l.split(';', 1)[0].rstrip()
        yield n, sec, t


def main():
    fichiers = sys.argv[1:]
    ext = set()
    for p in fichiers:
        for n, sec, t in lignes(p):
            m = ETIQ.match(t)
            if m and sec == '.ext' and not re.search(r'\bequ\b', t, re.I):
                ext.add(m.group(1))
    fautes = []
    for p in fichiers:
        for n, sec, t in lignes(p):
            if sec == '.ext' or sec == '.bss' or not t.strip():
                continue
            corps = ETIQ.sub('', t, count=1)
            m = re.match(r'\s*(\S+)\s*(.*)$', corps)
            if not m or m.group(1).lower() in ('export', 'import', 'section', 'include'):
                continue
            for mot in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', m.group(2)):
                if mot in ext and mot != 'Ext_Entree':
                    fautes.append('%s:%d : %s (dans %s)' % (p, n, t.strip(), mot))
    if fautes:
        print('ERREUR : l\'EPROM nomme BIOS2 en direct (passer par ExtV) :')
        for f in fautes:
            print('  ' + f)
        sys.exit(1)
    print('EPROM -> BIOS2 : uniquement par ExtV (%d étiquettes dans BIOS2)' % len(ext))


if __name__ == '__main__':
    main()
