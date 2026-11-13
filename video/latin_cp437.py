#!/usr/bin/env python3
# ===================================================================
# latin_cp437.py - Le clavier (Latin-1) vers la police (CP437)
# ===================================================================
# Le clavier rend les lettres accentuées en Latin-1 (é = $E9) ; la page 0
# de la police est en CP437 (é = $82). lib/vision.asm traduit en dessinant
# (Put_Text, donc vis_Text et vis_Input) les octets $A0-$FF avec cette
# table. Le clavier ne passe pas en CP437 : ses touches spéciales
# $80-$8B tomberaient sur é à ç è ê.
# Absent du CP437 : la lettre de base (À -> A, Ê -> E), sinon « ? ».
#   python3 video/latin_cp437.py --inc     -> lib/latin_cp437.inc (ne pas éditer)
#   python3 video/latin_cp437.py           -> la table, lisible
# ===================================================================
import os
import sys
import unicodedata

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INC = os.path.join(RACINE, 'lib', 'latin_cp437.inc')


def cp437(octet):
    """Latin-1 -> code CP437 de la police (page 0)."""
    c = bytes([octet]).decode('latin-1')
    try:
        return c.encode('cp437')[0]
    except UnicodeEncodeError:
        base = unicodedata.normalize('NFD', c)[0]
        if base != c and base.isascii():
            return ord(base)
        return ord('?')


def table():
    return [cp437(o) for o in range(0xA0, 0x100)]


def inc():
    t = table()
    l = ['; ===================================================================',
         '; latin_cp437.inc - Latin-1 $A0-$FF -> CP437 (police page 0)',
         '; Généré par video/latin_cp437.py --inc : NE PAS ÉDITER.',
         '; ===================================================================',
         'Tab_LatCp:']
    for i in range(0, 96, 16):
        l.append('    FCB     ' + ','.join('$%02X' % b for b in t[i:i + 16]) + '   ; $%02X' % (0xA0 + i))
    return '\n'.join(l) + '\n'


def main():
    if '--inc' in sys.argv:
        texte = inc()
        if not os.path.exists(INC) or open(INC).read() != texte:
            open(INC, 'w').write(texte)
        print(INC)
        return
    for o, c in zip(range(0xA0, 0x100), table()):
        print('$%02X %s -> $%02X %s' % (o, bytes([o]).decode('latin-1'), c, bytes([c]).decode('cp437')))


if __name__ == '__main__':
    main()
