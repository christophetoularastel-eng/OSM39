#!/usr/bin/env python3
# ===================================================================
# verifie_dossiers.py - Les dossiers de l'OSMFS (bios/osmfs.asm)
# ===================================================================
# Le VRAI BIOS dans l'émulateur de verifie_fs.py, sur une carte créée par
# tools/egofs. Vérifie : une carte d'avant les dossiers (tout à la racine) ;
# FS_MkDir, FS_ChDir (nom, "..", "/", chemins), FS_Dossier, FS_DirInfo ;
# Format_Filename_83 avec un chemin ("APPS/X", "../ROOT", "/APPS/JEUX/Y"),
# deux tampons formatés de suite (comme CP et MV) ; FS_FindFirst/Next ne
# listent que le dossier courant, n° d'entrée en +30 ; une lecture sans
# chemin introuvable réessaie à la racine, une suppression jamais ; un
# chemin inexistant fait échouer lecture et écriture ; un dossier non vide
# ne s'efface pas ; FS_RenameFile déplace (et refuse un cycle).
#   make -C bios && python3 test/verifie_dossiers.py
# ===================================================================
import os
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import carte                    # noqa: E402  (VRAM : v4 ou mono)
import egofs_core               # noqa: E402

RACINE = os.path.dirname(ICI)

CHAINE = 0xDD00                 # chaînes en RAM commune (hors de BIOS2 et de la pile)
TAMPON1, TAMPON2 = 0xDD80, 0xDDA0
DONNEES = 0x4000                # en page 0 (2 Ko pour FS_LoadFile ; BIOS2 occupe $CE00+)


class Banc:
    def __init__(self):
        self.s = v.sym()
        d = tempfile.mkdtemp()
        self.image = os.path.join(d, 'carte.img')
        with open(self.image, 'wb') as f:
            f.truncate(8 * 1024 * 1024)
        self.core = egofs_core.OSMFS_Core(self.image)
        old = sys.stdout
        sys.stdout = open(os.devnull, 'w')
        self.core.format_fs()
        for nom, taille in (('ROOTPROG', 700), ('AUTRE', 40)):
            chemin = os.path.join(d, nom)
            open(chemin, 'wb').write(bytes((i * 7 + len(nom)) & 255 for i in range(taille)))
            self.core.inject_file(chemin, nom, 1, '0000', 0x07)
        sys.stdout.close()
        sys.stdout = old
        self.m = va.MachineAsm(self.image, self.s)
        m = self.m
        v.installe_bios(m)          # table des services, et BIOS2
        m.mem[self.s['current_page']] = 0

    def appel(self, nom, **regs):
        m = self.m
        for r, val in regs.items():
            setattr(m, r, val)
        return v.appelle(m, self.s[nom])

    def chaine(self, txt, adr=CHAINE):
        b = txt.encode('ascii') + b'\0'
        self.m.mem[adr:adr + len(b)] = b

    def formate(self, txt, tampon=TAMPON1):
        self.chaine(txt)
        self.appel('Format_Filename_83', x=CHAINE, y=tampon)
        return bytes(self.m.mem[tampon:tampon + 15]).decode('ascii')

    def trouve(self, txt, tampon=TAMPON1):
        self.formate(txt, tampon)
        return self.appel('FS_FindEntry', x=tampon)

    def sauve(self, txt, donnees, tampon=TAMPON1):
        self.formate(txt, tampon)
        self.m.banks[0][DONNEES:DONNEES + len(donnees)] = donnees
        return self.appel('FS_SaveFile', a=0, x=tampon, y=DONNEES, u=len(donnees))

    def charge(self, txt, tampon=TAMPON1):
        self.formate(txt, tampon)
        self.m.banks[0][DONNEES:DONNEES + 2048] = bytes(2048)
        ok = self.appel('FS_LoadFile', a=0, x=tampon, y=DONNEES)
        return ok, bytes(self.m.banks[0][DONNEES:DONNEES + self.m.u])

    def mkdir(self, txt):
        self.formate(txt)
        return self.appel('FS_MkDir', x=TAMPON1)

    def cd(self, txt):
        self.chaine(txt)
        return self.appel('FS_ChDir', x=CHAINE)

    def dossier(self):
        self.appel('FS_Dossier', a=0xFF, b=0xFF)
        return (self.m.a << 8) | self.m.b

    def efface(self, txt):
        self.formate(txt)
        return self.appel('FS_DeleteFile', x=TAMPON1)

    def liste(self):
        """FS_FindFirst/Next : [(nom, attributs, n°)]."""
        m, g = self.m, self.s['g_find_fileInfo']
        out = []
        ok = self.appel('FS_FindFirst')
        while ok:
            nom = bytes(m.mem[g + 1:g + 16]).decode('ascii').rstrip()
            out.append((nom, m.mem[g + 27], (m.mem[g + 30] << 8) | m.mem[g + 31]))
            ok = self.appel('FS_FindNext')
        return out

    def commande(self, prog, *args):
        """Lance cmd/PROG en page 1 avec ces arguments (comme le shell) ;
        rend ce qui est affiché."""
        m, s = self.m, self.s
        code = open(os.path.join(RACINE, 'cmd', prog), 'rb').read()
        m.banks[1][:len(code)] = code
        adr, ptrs = 0xDDC0, []
        for a in [prog] + list(args):
            b = a.encode('ascii') + b'\0'
            m.mem[adr:adr + len(b)] = b
            ptrs.append(adr)
            adr += len(b)
        m.mem[s['argc']] = len(ptrs)
        for i, p in enumerate(ptrs):
            m.wr16(s['argv'] + 2 * i, p)
        m.mem[s['current_page']] = 1
        m.page = 1
        m.texte = bytearray()
        v.appelle(m, 0x0000)
        m.mem[s['current_page']] = 0
        m.page = 0
        return m.texte.decode('latin-1').replace('\r', '').replace('\n', '|')

    def entree(self, nom, parent=None):
        """L'entrée sur la carte (relue par egofs, octets bruts)."""
        with open(self.image, 'rb') as f:
            for lba in range(1, 257):
                f.seek(lba * 512)
                sec = f.read(512)
                for i in range(16):
                    e = sec[i * 32:(i + 1) * 32]
                    if e[0] == 0:
                        return None
                    if e[0] == 1 and e[1:16].decode('ascii').rstrip() == nom:
                        p = (e[28] << 8) | e[29]
                        if parent is None or p == parent:
                            return {'parent': p, 'attr': e[27], 'id': (lba - 1) * 16 + i + 1,
                                    'taille': int.from_bytes(e[20:24], 'big')}
        return None


def main():
    b = Banc()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    # 1. carte d'avant les dossiers
    verifie(b.dossier() == 0 and b.trouve('ROOTPROG') and [n for n, _, _ in b.liste()] == ['ROOTPROG', 'AUTRE'],
            'carte sans dossiers : tout à la racine, FS_FindEntry et FS_FindFirst/Next comme avant')
    verifie(b.formate('rootprog') == 'ROOTPROG       ', 'Format_Filename_83 sans chemin : majuscules, 15 octets')

    # 2. MkDir, ChDir, liste du dossier courant
    verifie(b.mkdir('APPS'), 'FS_MkDir APPS')
    verifie(not b.mkdir('APPS'), 'FS_MkDir APPS une 2e fois : refusé')
    e = b.entree('APPS')
    verifie(e and e['attr'] == 0x27 and e['taille'] == 0 and e['parent'] == 0,
            'APPS : attributs rwx + d ($27), taille 0, à la racine')
    apps = e['id']
    lst = b.liste()
    verifie(('APPS', 0x27, apps) in lst, 'la racine liste APPS avec son n° en +30 (%d)' % apps)
    verifie(b.cd('APPS') and b.dossier() == apps, 'FS_ChDir APPS : dossier courant = n° de APPS')
    verifie(b.liste() == [], 'APPS est vide : FS_FindFirst ne rend rien de la racine')
    contenu = bytes(range(256)) * 3
    verifie(b.sauve('JEU', contenu), 'FS_SaveFile JEU dans APPS')
    e = b.entree('JEU')
    verifie(e and e['parent'] == apps, 'JEU a pour parent APPS sur la carte')
    verifie([n for n, _, _ in b.liste()] == ['JEU'], 'APPS liste JEU seulement')

    # 3. repli à la racine pour une lecture, jamais pour une suppression
    ok, lu = b.charge('ROOTPROG')
    verifie(ok and len(lu) == 700, 'depuis APPS, FS_LoadFile ROOTPROG (sans chemin) : trouvé à la racine')
    verifie(not b.efface('ROOTPROG') and b.entree('ROOTPROG'),
            'depuis APPS, FS_DeleteFile ROOTPROG : refusé, la racine est intacte')
    verifie(b.trouve('/ROOTPROG') and b.trouve('../AUTRE'), 'chemins "/ROOTPROG" et "../AUTRE" depuis APPS')
    verifie(not b.trouve('./ROOTPROG'), '"./ROOTPROG" (chemin explicite) : pas de repli, introuvable')

    # 3b. /BIN, comme le PATH : dossier courant, puis /BIN, puis la racine
    b.cd('/')
    verifie(b.mkdir('BIN') and b.sauve('BIN/OUTIL', b'bin') and b.sauve('/OUTIL', b'racine'),
            '/BIN/OUTIL et /OUTIL créés')
    b.cd('APPS')
    ok, lu = b.charge('OUTIL')
    verifie(ok and lu == b'bin', 'depuis APPS, OUTIL (sans chemin) : celui de /BIN avant celui de la racine')
    verifie(not b.efface('OUTIL') and b.entree('OUTIL', b.entree('BIN')['id']),
            'depuis APPS, FS_DeleteFile OUTIL : refusé, /BIN intact')
    b.cd('/')
    ok, lu = b.charge('OUTIL')
    verifie(ok and lu == b'racine', 'à la racine, OUTIL : celui de la racine (le dossier courant d\'abord)')
    verifie(b.efface('/OUTIL') and b.cd('APPS') and b.charge('OUTIL')[1] == b'bin' and b.cd('/')
            and b.efface('BIN/OUTIL'), 'nettoyage')
    b.cd('APPS')                            # la suite repart de APPS

    # 4. sous-dossier, chemins absolus et relatifs
    verifie(b.mkdir('JEUX') and b.cd('/APPS/JEUX'), 'APPS/JEUX créé, FS_ChDir "/APPS/JEUX"')
    jeux = b.dossier()
    verifie(b.sauve('NIVEAU', b'abc'), 'NIVEAU dans APPS/JEUX')
    verifie(b.trouve('../JEU') and b.trouve('../../ROOTPROG') and b.trouve('/APPS/JEUX/NIVEAU'),
            'depuis APPS/JEUX : "../JEU", "../../ROOTPROG", "/APPS/JEUX/NIVEAU"')
    b.appel('FS_DirInfo', a=jeux >> 8, b=jeux & 255, y=TAMPON2)
    verifie(((b.m.a << 8) | b.m.b) == apps and bytes(b.m.mem[TAMPON2:TAMPON2 + 4]) == b'JEUX',
            'FS_DirInfo(JEUX) : parent APPS, nom JEUX')
    verifie(b.cd('..') and b.dossier() == apps and b.cd('/') and b.dossier() == 0, 'FS_ChDir ".." puis "/"')
    verifie(not b.cd('RIEN') and b.dossier() == 0, 'FS_ChDir RIEN : refusé, dossier inchangé')
    verifie(b.appel('FS_Dossier', a=jeux >> 8, b=jeux & 255) is not None and b.dossier() == jeux
            and b.cd('/'), 'FS_Dossier : entrer par le n° (celui de la liste)')

    # 5. chemins inexistants
    verifie(not b.trouve('RIEN/ROOTPROG'), 'lecture "RIEN/ROOTPROG" : dossier introuvable, échec (pas de repli)')
    verifie(not b.sauve('RIEN/X', b'1') and not b.entree('X'), 'écriture "RIEN/X" : refusée, rien créé')
    verifie(not b.trouve('ROOTPROG/X'), '"ROOTPROG/X" : ROOTPROG n\'est pas un dossier')

    # 6. deux tampons formatés de suite (CP, MV), puis un tampon réécrit
    b.formate('APPS/JEU', TAMPON1)
    b.formate('AUTRE', TAMPON2)
    t1 = b.appel('FS_FindEntry', x=TAMPON1)
    t2 = b.appel('FS_FindEntry', x=TAMPON2)
    verifie(t1 and t2, 'deux tampons : "APPS/JEU" et "AUTRE" gardent chacun leur dossier')
    b.formate('APPS/JEU', TAMPON1)
    b.m.mem[TAMPON1:TAMPON1 + 15] = b'AUTRE          '
    verifie(b.appel('FS_FindEntry', x=TAMPON1), 'tampon réécrit à la main : le dossier courant, pas celui du chemin')

    # 7. dossier non vide
    verifie(not b.efface('APPS/JEUX') and b.entree('JEUX'), 'APPS/JEUX non vide : FS_DeleteFile refusé')
    verifie(b.efface('APPS/JEUX/NIVEAU') and b.efface('APPS/JEUX') and not b.entree('JEUX'),
            'vidé, il s\'efface')

    # 8. déplacements
    b.formate('APPS/JEU', TAMPON1)
    b.formate('/JEU2', TAMPON2)
    verifie(b.appel('FS_RenameFile', x=TAMPON1, y=TAMPON2) and b.entree('JEU2', 0) and not b.entree('JEU'),
            'FS_RenameFile "APPS/JEU" -> "/JEU2" : déplacé à la racine et renommé')
    b.formate('JEU2', TAMPON1)
    b.formate('APPS/', TAMPON2)
    verifie(b.appel('FS_RenameFile', x=TAMPON1, y=TAMPON2) and b.entree('JEU2', apps),
            'FS_RenameFile "JEU2" -> "APPS/" : déplacé, nom gardé')
    verifie(b.mkdir('APPS/SOUS'), 'APPS/SOUS créé')
    b.formate('APPS', TAMPON1)
    b.formate('APPS/SOUS/', TAMPON2)
    verifie(not b.appel('FS_RenameFile', x=TAMPON1, y=TAMPON2) and b.entree('APPS', 0),
            'APPS dans APPS/SOUS : cycle refusé')
    ok, lu = b.charge('APPS/JEU2')
    verifie(ok and lu == contenu, 'le contenu a suivi : APPS/JEU2 = JEU')

    # 8b. même nom dans deux dossiers, celui de la racine d'abord dans le
    #     même secteur (le bogue de la carte : B écrasé, la fin du secteur
    #     sautée) : chacun se trouve, s'efface, et rien d'autre
    verifie(b.sauve('/DOUBLE', b'r') and all(b.sauve('/REMPLI%02d' % i, b'.') for i in range(20))
            and b.sauve('APPS/DOUBLE', b'a') and b.entree('DOUBLE', apps)['id'] - b.entree('DOUBLE', 0)['id'] > 16,
            'DOUBLE à la racine, 20 fichiers, puis DOUBLE dans APPS (un secteur plus loin)')
    b.cd('APPS')
    ok, lu = b.charge('DOUBLE')
    verifie(ok and lu == b'a', 'depuis APPS, DOUBLE est celui de APPS (pas celui de la racine)')
    verifie(b.efface('DOUBLE') and not b.entree('DOUBLE', apps) and b.entree('DOUBLE', 0),
            'depuis APPS, RM DOUBLE efface celui de APPS seulement')
    b.cd('/')
    verifie(b.efface('DOUBLE') and not b.entree('DOUBLE'), 'puis celui de la racine')
    for i in range(20):
        b.efface('/REMPLI%02d' % i)

    # 9. les commandes CD, MKDIR, PWD (programmes en page 1)
    t = b.commande('PWD')
    verifie(t == '/|', 'PWD à la racine : "/" (%r)' % t)
    t = b.commande('MKDIR', 'apps/sous/fond')
    verifie(t == '' and b.entree('FOND'), 'MKDIR apps/sous/fond')
    t = b.commande('CD', 'APPS/SOUS/FOND') + b.commande('PWD')
    verifie(t == '/APPS/SOUS/FOND|', 'CD APPS/SOUS/FOND puis PWD : %r' % t)
    t = b.commande('CD', '../..') + b.commande('PWD')
    verifie(t == '/APPS|', 'CD ../.. puis PWD : %r' % t)
    t = b.commande('CD', 'NULLEPART')
    verifie('introuvable' in t and b.dossier() == apps, 'CD NULLEPART : message, dossier inchangé')
    t = b.commande('MKDIR', 'SOUS')
    verifie('Impossible' in t, 'MKDIR SOUS (existe) : message')
    b.commande('CD', '/')
    t = b.commande('LS')
    verifie('APPS/\t0\trwx|' in t and 'ROOTPROG\t700\trwx|' in t, 'LS à la racine : "APPS/", "ROOTPROG 700 rwx" (%r)' % t[:80])
    t = b.commande('LS', 'APPS/SOUS')
    verifie(t == '|FOND/\t0\trwx|' and b.dossier() == 0, 'LS APPS/SOUS : son contenu, dossier courant inchangé (%r)' % t)
    b.commande('RM', 'APPS/SOUS/FOND')
    verifie(not b.entree('FOND'), 'RM APPS/SOUS/FOND (dossier vide)')

    # 10. OSM-VISION : sa liste (Load_Directory + tri + Draw_FileList)
    import re
    plan = open(os.path.join(RACINE, 'osmvision', 'OSMVISION.map')).read()
    ov = {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', plan)}
    code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()

    def liste_ov(chemin):
        m = b.m
        b.cd(chemin)
        m.banks[0][:len(code)] = code
        m.mem[b.s['current_page']] = 0
        m.page = 0
        v.appelle(m, ov['Load_Directory'])
        n = m.banks[0][ov['FileCount']]
        recs = [bytes(m.banks[0][ov['FileNames'] + 16 * i:ov['FileNames'] + 16 * i + 16]) for i in range(n)]
        v.appelle(m, ov['Draw_FileList'])
        icones = [m.mem[carte.adr((i + 7) * 80 + 12)] for i in range(min(n, 16))]
        return [(r[:15].decode('ascii').rstrip(), r[15]) for r in recs], icones

    b.sauve('/ZZFICH', b'z')
    b.mkdir('/BDOS')
    lst, ico = liste_ov('/')
    verifie([x for x, _ in lst] == ['APPS', 'BDOS', 'BIN', 'AUTRE', 'ROOTPROG', 'ZZFICH'],
            'OSM-VISION à la racine : dossiers d\'abord, triés, puis fichiers : %s' % [x for x, _ in lst])
    verifie(all((f == 1) == (i == 0x80) for (_, f), i in zip(lst, ico)),
            'icône dossier ($80) pour les dossiers seulement : %s' % ico)
    lst, ico = liste_ov('/APPS')
    verifie(lst and lst[0] == ('..', 3) and ico[0] == 0x80, 'dans APPS : ".." en tête (drapeaux 3) : %s' % lst)
    b.cd('/')

    # 11. egofs (PC) lit la carte écrite par le BIOS
    noms = sorted(f['name'] for f in b.core.list_files())
    verifie(noms == sorted(['ROOTPROG', 'AUTRE', 'APPS', 'JEU2', 'SOUS', 'ZZFICH', 'BDOS', 'BIN']),
            'egofs relit la carte : %s' % noms)

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
