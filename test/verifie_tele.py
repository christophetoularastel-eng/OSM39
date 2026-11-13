#!/usr/bin/env python3
# ===================================================================
# verifie_tele.py - La télécommande : le VRAI cmd/TELE sur le VRAI BIOS
#                   (émulateur de verifie_fs.py), piloté par la VRAIE
#                   classe Tele de tools/tele/tele.py
# ===================================================================
# La liaison série est simulée : ce que le PC envoie entre dans l'anneau
# serie_buf comme le ferait la NMI en mode brut ; ce que TELE écrit dans
# TDR revient au PC (SR dit toujours « TDR libre »). La machine tourne
# jusqu'à ce que TELE attende un octet qui ne vient pas.
# Vérifie : présence, écriture et relecture en page 1 (directe), en page 2
# (FarWrite / FarRead) et en RAM système, appel avec registres et retenue,
# appel d'un service du BIOS (PrintChar), somme fausse et commande
# inconnue refusées sans perdre la suite, fin : mode brut coupé et retour.
#   make -C bios && make -C cmd && python3 test/verifie_tele.py
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'tele'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_dossiers as vd   # noqa: E402
import tele                     # noqa: E402
import depose                   # noqa: E402

HW = {}
for ligne in open(os.path.join(RACINE, 'bios', 'hardware.inc')):
    p = ligne.split()
    if len(p) >= 3 and p[1].lower() == 'equ' and p[2].startswith('$'):
        HW[p[0].rstrip(':')] = int(p[2][1:], 16)


class Attente(Exception):
    pass


class Machine(va.MachineAsm):
    def __init__(self, image, s):
        super().__init__(image, s)
        self.entree = bytearray()       # du PC, pas encore dans l'anneau
        self.sortie = bytearray()       # vers le PC
        self.mem[HW['SR']] = 0x02

    def wr8(self, a, v_):
        if (a & 0xFFFF) == HW['TDR']:
            self.sortie.append(v_ & 0xFF)
            return
        super().wr8(a, v_)

    def nmi(self):
        """Ce que la NMI ferait en mode brut, octet par octet."""
        s = self.s_
        while self.entree and self.mem[s['serie_brute']]:
            tete = self.mem[s['serie_tete']]
            if (tete + 1) & 255 == self.mem[s['serie_queue']]:
                break                   # anneau plein : on attend
            self.mem[s['serie_buf'] + tete] = self.entree.pop(0)
            self.mem[s['serie_tete']] = (tete + 1) & 255

    def step(self):
        if self.pc == self.s_['kbd_poll']:
            self.nmi()
            if self.mem[self.s_['serie_tete']] == self.mem[self.s_['serie_queue']]:
                raise Attente()         # TELE attend, rien ne vient
            self.a = 0
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        super().step()


class LiaisonSimulee:
    def __init__(self, m):
        self.m = m
        self.fini = False

    def tourne(self):
        m = self.m
        pas = 0
        try:
            while m.pc != v.RETOUR:
                if m.sd():              # la carte SD (comme v.appelle)
                    continue
                m.step()
                pas += 1
                if pas > 5_000_000:
                    raise RuntimeError('TELE ne rend pas la main ($%04X)' % m.pc)
            self.fini = True
        except Attente:
            pass

    def ecrit(self, octets):
        self.m.entree += octets
        self.tourne()

    def lit(self, n, delai):
        out = bytes(self.m.sortie[:n])
        del self.m.sortie[:n]
        return out

    def vide(self):
        self.m.sortie.clear()


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    b = vd.Banc()
    m = Machine(b.image, b.s)
    s = b.s
    v.installe_bios(m)          # table des services, et BIOS2
    code = open(os.path.join(RACINE, 'cmd', 'TELE'), 'rb').read()
    verifie(len(code) < 0x1000, 'TELE tient sous $1000 (%d octets) : la page 1 reste au code d\'essai' % len(code))
    m.banks[1][:len(code)] = code
    m.mem[s['current_page']] = 1
    m.page = 1
    m.s = 0xDF00 - 2
    m.mem[m.s], m.mem[m.s + 1] = v.RETOUR >> 8, v.RETOUR & 0xFF
    m.pc = 0
    li = LiaisonSimulee(m)
    li.tourne()
    t = tele.Tele(li)
    verifie(m.mem[s['serie_brute']] == 1 and 'TELE' in m.texte.decode('latin-1'),
            'au lancement : titre affiché, mode brut')

    verifie(t.ping() == 'TELE1', 'P : « TELE1 »')

    motif = bytes((i * 11 + 5) & 255 for i in range(300))
    t.ecrit(1, 0x2000, motif)
    verifie(bytes(m.banks[1][0x2000:0x2000 + 300]) == motif and t.lit(1, 0x2000, 300) == motif,
            'W/R page 1 (directe) : 300 octets en 5 trames, relus')
    t.ecrit(2, 0x7F00, motif[:200])
    verifie(bytes(m.banks[2][0x7F00:0x7FC8]) == motif[:200] and t.lit(2, 0x7F00, 200) == motif[:200]
            and m.mem[s['current_page']] == 1 and m.page == 1,
            'W/R page 2 (FarWrite / FarRead) : écrit, relu, page 1 rendue')
    t.ecrit(0, 0xD800, b'\x12\x34\x56')
    verifie(bytes(m.mem[0xD800:0xD803]) == b'\x12\x34\x56' and t.lit(3, 0xD800, 3) == b'\x12\x34\x56',
            'W/R en RAM système ($D800) : la page ne compte pas')

    # une routine en page 1 : A+1, B+1, X+1, Y+2, U+3, W = $1234, C = 1
    routine = bytes([0x8B, 0x01, 0x5C, 0x30, 0x01, 0x31, 0x22, 0x33, 0x43,
                     0x10, 0x86, 0x12, 0x34, 0x1A, 0x01, 0x39])
    t.ecrit(1, 0x1000, routine)
    r = t.appel(0x1000, a=0x10, b=0x20, x=0x3000, y=0x4000, u=0x5000)
    verifie((r['a'], r['b'], r['x'], r['y'], r['u'], r['w'], r['c']) == (0x11, 0x21, 0x3001, 0x4002, 0x5003, 0x1234, 1),
            'C : registres chargés, rendus après la routine, retenue (%s)' % r)
    avant = len(m.texte)
    t_ = s['table_function_ram'] + 6        # sys_PrintChar (bios/sysfunc.inc)
    pc = (m.mem[t_] << 8) | m.mem[t_ + 1]
    t.appel(pc, a=ord('Z'))
    verifie(m.texte[avant:] == b'Z', 'C : un service du BIOS (PrintChar, adresse lue dans la table)')

    li.vide()
    m.entree += b'TP\x00\x51'               # somme fausse ($50 attendu)
    li.tourne()
    verifie(bytes(m.sortie) == b'E\x01', 'somme fausse : « E 01 »')
    li.vide()
    m.entree += tele.trame('Z')
    li.tourne()
    verifie(bytes(m.sortie) == b'E\x02', 'commande inconnue : « E 02 »')
    verifie(t.ping() == 'TELE1', 'la trame suivante passe')
    li.vide()
    m.entree += tele.trame('R', b'\x01\x20\x00')
    li.tourne()
    verifie(bytes(m.sortie) == b'E\x03', 'R de 3 octets au lieu de 4 : « E 03 »')

    # tools/tele/depose.py : un fichier du PC posé sur la carte par les
    # services du BIOS ; la carte relue par egofs_core (l'outil du PC)
    sv = depose.services()

    def service(nom, **reg):
        p = s['table_function_ram'] + sv['sys_' + nom]
        return t.appel((m.mem[p] << 8) | m.mem[p + 1], **reg)

    t.ecrit(1, depose.CHAINE, b'DOC\0')
    service('Format_Filename_83', x=depose.CHAINE, y=depose.NOM)
    verifie(not service('FS_MkDir', x=depose.NOM)['c'], 'C : FS_MkDir crée DOC')
    muet = lambda *a: None                  # noqa: E731
    texte1 = b'PREMIER ESSAI\n' * 40
    texte2 = bytes(range(32, 127)) * 70     # 6650 octets : 13 secteurs
    try:
        depose.depose(t, texte1, '/DOC/NOTE.TXT', dire=muet)
        depose.depose(t, texte2, '/DOC/NOTE.TXT', 0x17, 1, 0x1234, dire=muet)
        ok = True
    except tele.ErreurTele as e:
        ok = False
        print('     ', e)
    fichiers = b.core.list_files()
    notes = [f for f in fichiers if f['path'] == 'DOC/NOTE.TXT']
    relu = os.path.join(os.path.dirname(b.image), 'relu')
    if len(notes) == 1:
        b.core.extract_file(notes[0]['index'], relu)
    verifie(ok and len(notes) == 1 and open(relu, 'rb').read() == texte2
            and (notes[0]['page'], notes[0]['addr'], notes[0]['attr']) == (1, '0x1234', 0x17),
            'depose.py : /DOC/NOTE.TXT posé puis remplacé, une seule entrée, '
            'contenu, page, adresse, attributs (relu par egofs_core)')
    try:
        depose.depose(t, b'X', '/ABSENT/NOTE.TXT', dire=muet)
        refuse = False
    except tele.ErreurTele:
        refuse = True
    verifie(refuse and not any(f['name'] == 'NOTE.TXT' and f['path'] != 'DOC/NOTE.TXT'
                               for f in b.core.list_files()),
            'depose.py : dossier absent refusé, rien écrit')

    t.fin()
    verifie(li.fini and m.mem[s['serie_brute']] == 0 and 'TELE termine.' in m.texte.decode('latin-1'),
            'Q : réponse, mode brut coupé, TELE rend la main')

    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
