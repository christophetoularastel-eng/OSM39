#!/usr/bin/env python3
# ===================================================================
# depose.py - Pose un fichier du PC sur la carte SD de la machine, par TELE
# ===================================================================
# Sur la machine : TELE lancé dans le Terminal. Ici :
#   python3 tools/tele/depose.py fichier /DOSSIER/NOM [attributs] [page:adresse]
#     attributs : rwx, rwxa, rw (défaut rw) ; page:adresse : défaut 1:0000
#   python3 tools/tele/depose.py apps/MIGRATION.TXT /DOC/MIGRATION.TXT
# Les mêmes appels qu'un programme : le fichier va en page 1 à $2000 (TELE
# finit avant $1000), puis Format_Filename_83, FS_FileInfo, FS_DeleteFile si
# le nom existe (FS_SaveFile crée toujours une entrée), FS_SaveFile,
# FS_SetLoad, FS_SetAttributes, et l'entrée est relue. Au-delà de 24 Ko
# (65 535 octets au plus), le fichier passe par les pages 2-3 à $0000
# (FS_SaveFile continue d'une page à la suivante).
# ===================================================================
import os
import re
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
sys.path.insert(0, ICI)
import tele                     # noqa: E402

TABLE = 0xC000                  # table_function_ram (bios/hardware.inc)
CHAINE = 0x1000                 # le chemin, NUL final
NOM = 0x1080                    # tampon formaté (16 octets)
INFO = 0x10A0                   # 14 octets de FS_FileInfo
DONNEES = 0x2000
MAXI = 0x8000 - DONNEES
ATTR = {'rw': 0x06, 'rwx': 0x07, 'rwxa': 0x17}


def services():
    s = {}
    for ligne in open(os.path.join(RACINE, 'bios', 'sysfunc.inc'), encoding='utf-8'):
        m = re.match(r'(sys_\w+):\s+equ\s+(\d+)', ligne)
        if m:
            s[m.group(1)] = int(m.group(2))
    return s


def depose(t, data, chemin, attr=0x06, page=1, adr=0, dire=print):
    """Pose data sous chemin par la liaison TELE t ; ErreurTele si ça rate.
    Rend l'entrée relue : (lba, taille, page, adresse, attributs)."""
    if len(data) > 0xFFFF:
        raise tele.ErreurTele('trop gros : %d octets (65 535 au plus)' % len(data))
    grand = len(data) > MAXI            # par les pages 2-3
    sv = services()

    def service(nom, **reg):
        lo, hi = t.lit(1, TABLE + sv['sys_' + nom], 2)
        return t.appel((lo << 8) | hi, **reg)

    t.ecrit(1, CHAINE, chemin.upper().encode('ascii') + b'\0')
    service('Format_Filename_83', x=CHAINE, y=NOM)
    dire('nom OSMFS : "%s"' % t.lit(1, NOM, 15).decode('ascii'))

    # La copie en RAM d'abord, vérifiée : l'ancien fichier n'est effacé
    # qu'ensuite, juste avant FS_SaveFile. Effacé d'abord, une trame perdue
    # pendant la copie laissait la carte sans le fichier (20 nov. 2026 :
    # sans OSMVISION, la machine ne démarre plus que sur SECOURS).
    morceaux = [(2, 0, data[:0x8000]), (3, 0, data[0x8000:])] if grand else [(1, DONNEES, data)]
    for pg, a, m in morceaux:
        if not m:
            continue
        t.ecrit(pg, a, m)
        if t.lit(pg, a, len(m)) != m:
            raise tele.ErreurTele('copie en RAM relue différente (page %d)' % pg)
    dire('%d octets en %s' % (len(data), '2:0000 (pages 2-3)' if grand else '1:%04X' % DONNEES))

    if not service('FS_FileInfo', x=NOM, y=INFO)['c']:
        if service('FS_DeleteFile', x=NOM)['c']:
            raise tele.ErreurTele('FS_DeleteFile refuse l\'ancien %s' % chemin)
        dire('ancien %s effacé' % chemin)

    if service('FS_SaveFile', a=2 if grand else 1, x=NOM, y=0 if grand else DONNEES, u=len(data))['c']:
        raise tele.ErreurTele('FS_SaveFile a échoué (dossier absent ? carte pleine ?)')
    if service('FS_SetLoad', a=page, x=NOM, y=adr)['c']:
        raise tele.ErreurTele('FS_SetLoad a échoué')
    if service('FS_SetAttributes', a=attr, x=NOM)['c']:
        raise tele.ErreurTele('FS_SetAttributes a échoué')

    if service('FS_FileInfo', x=NOM, y=INFO)['c']:
        raise tele.ErreurTele('le fichier est introuvable après l\'écriture')
    e = t.lit(1, INFO, 14)
    entree = (int.from_bytes(e[0:4], 'big'), int.from_bytes(e[4:8], 'big'),
              e[8], (e[9] << 8) | e[10], e[11])
    dire('entrée : LBA %d, %d octets, page %d, adresse %04X, attributs %02X' % entree)
    if entree[1:] != (len(data), page, adr, attr):
        raise tele.ErreurTele('l\'entrée ne correspond pas')
    return entree


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(open(__file__, encoding='utf-8').read().split('# ===')[1])
        return 2
    source, chemin = args[0], args[1].upper()
    attr = ATTR[args[2]] if len(args) > 2 else 0x06
    page, adr = tele.adresse(args[3]) if len(args) > 3 else (1, 0)
    data = open(source, 'rb').read()
    t = tele.Tele(tele.Liaison())
    try:
        print('TELE :', t.ping())
        depose(t, data, chemin, attr, page, adr)
        print('%s posé sur la carte (reprises de trames : %d)' % (chemin, t.reprises))
    except tele.ErreurTele as err:
        print('ERREUR :', err)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
