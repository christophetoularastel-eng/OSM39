#!/usr/bin/env python3
# ===================================================================
# verifie_asm.py - L'assembleur natif ASM, octet pour octet contre lwasm
# ===================================================================
# Fait tourner le VRAI ASM (asm/ASM, en page 1) sur le VRAI BIOS
# (bios/osm39.bin) dans l'émulateur de verifie_fs.py, avec une carte SD
# OSMFS (tools/egofs) qui porte les sources et leurs INCLUDE sous leur
# nom de carte (../lib/ui.inc -> UI.INC). Pour chaque source, le binaire
# que ASM enregistre sur la carte doit être identique à celui de
#   lwasm --format=obj --6309 + lwlink --format=raw --section-base=.code=ORG
# Vérifie aussi la page, l'adresse et les attributs de l'entrée, qu'une
# erreur nomme le fichier et la ligne, et qu'un ancien fichier garde sa
# page et ses attributs. Donne le nombre d'instructions exécutées (le
# temps sur la carte en est une estimation grossière).
#   make -C bios && make -C asm && python3 test/verifie_asm.py [glouton]
# ===================================================================
import os
import re
import shutil
import subprocess
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import egofs_core               # noqa: E402

ASM = os.path.join(RACINE, 'asm', 'ASM')
CHAINES = 0xDB40                # arguments (argv) en RAM commune (hors de BIOS2 et de la pile)
MAX_PAS = 80_000_000           # GLOUTON : ~16 M ; au-delà, ASM boucle


class MachineAsm(v.Machine):
    """La machine de verifie_fs, qui garde ce que l'on affiche."""

    def __init__(self, image, s):
        super().__init__(image, s)
        self.texte = bytearray()

    def step(self):
        if self.pc == self.s_['PrintChar']:
            self.texte.append(self.a)
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        self.steps += 1
        super().step()


def lwasm(source, origine, dossier):
    """Le binaire de référence. Renvoie (octets, None) ou (None, erreur)."""
    obj = os.path.join(dossier, 'ref.o')
    sortie = os.path.join(dossier, 'ref.bin')
    r = subprocess.run(['lwasm', '--format=obj', '--6309', '-o', obj, source],
                       capture_output=True, text=True, cwd=os.path.dirname(source))
    if r.returncode:
        return None, r.stdout + r.stderr
    r = subprocess.run(['lwlink', '--format=raw', '--section-base=.code=0x%04x' % origine,
                        '-o', sortie, obj], capture_output=True, text=True)
    if r.returncode:
        return None, r.stdout + r.stderr
    return open(sortie, 'rb').read(), None


def includes(source, vus=None):
    """Les fichiers INCLUDE d'un source, récursivement : {nom carte: chemin}."""
    vus = {} if vus is None else vus
    for ligne in open(source, encoding='utf-8', errors='replace'):
        m = re.match(r'\s+include\s+"?([^"\s]+)"?', ligne, re.I)
        if m:
            chemin = os.path.normpath(os.path.join(os.path.dirname(source), m.group(1)))
            if not os.path.exists(chemin):          # cherché comme lwasm -I
                for d in ('bios', 'lib', 'asm'):
                    c = os.path.join(RACINE, d, os.path.basename(m.group(1)))
                    if os.path.exists(c):
                        chemin = c
                        break
            nom = os.path.basename(chemin).upper()
            if nom not in vus:
                vus[nom] = chemin
                includes(chemin, vus)
    return vus


class Carte:
    def __init__(self, dossier):
        self.dossier = dossier
        self.image = os.path.join(dossier, 'carte.img')
        with open(self.image, 'wb') as f:
            f.truncate(16 * 1024 * 1024)
        self.core = egofs_core.OSMFS_Core(self.image)
        self._muet(self.core.format_fs)

    @staticmethod
    def _muet(f, *a):
        old = sys.stdout
        sys.stdout = open(os.devnull, 'w')
        try:
            return f(*a)
        finally:
            sys.stdout.close()
            sys.stdout = old

    def ajoute(self, nom, chemin, page=1, adresse='0000', attr=0x07):
        if self.entree(nom):
            return
        self._muet(self.core.inject_file, chemin, nom, page, adresse, attr)

    def entree(self, nom):
        """nom : un nom à la racine, ou un chemin "APPS/X"."""
        for f in self.core.list_files():
            if f['path'] == nom:
                return f
        return None

    def lit(self, nom):
        f = self.entree(nom)
        if not f:
            return None
        chemin = os.path.join(self.dossier, 'extrait')
        self._muet(self.core.extract_file, f['index'], chemin)
        return open(chemin, 'rb').read()


def assemble(carte, s, args, dossier=0):
    """Lance ASM avec ces arguments, depuis ce dossier (n°). Renvoie (texte
    affiché, pas exécutés, machine)."""
    m = MachineAsm(carte.image, s)
    m.wr16(s['fs_dossier'], dossier)
    v.installe_bios(m)          # table des services, et BIOS2
    code = open(ASM, 'rb').read()
    m.banks[1][:len(code)] = code
    adr, ptrs = CHAINES, []
    for a in ['ASM'] + args:
        b = a.encode('ascii') + b'\0'
        m.mem[adr:adr + len(b)] = b
        ptrs.append(adr)
        adr += len(b)
    m.mem[s['argc']] = len(ptrs)
    for i, p in enumerate(ptrs):
        m.wr16(s['argv'] + 2 * i, p)
    m.mem[s['current_page']] = 1
    m.page = 1
    m.steps = 0
    try:
        v.appelle(m, 0x0000, MAX_PAS)
    except RuntimeError as e:                   # ASM ne rend pas la main
        m.texte += ('\n[%s]' % e).encode()
    return m.texte.decode('latin-1').replace('\r', ''), m.steps, m


def sans_org(source, dossier):
    """asm/test/*.asm commencent par ORG : version « section » pour lwasm
    en mode objet, et l'origine. (ASM lit l'ORG lui-même.)"""
    lignes = open(source, encoding='utf-8', errors='replace').read().split('\n')
    origine = 0
    for i, l in enumerate(lignes):
        m = re.match(r'\s+ORG\s+\$([0-9A-Fa-f]+)', l, re.I)
        if m:
            origine = int(m.group(1), 16)
            lignes[i] = ' section .code'
            break
    chemin = os.path.join(dossier, os.path.basename(source))
    open(chemin, 'w').write('\n'.join(lignes))
    return chemin, origine


def main():
    s = v.sym()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    # ASM à jour : un binaire périmé passerait les tests à sa place
    r = subprocess.run(['make', '-s', '-C', os.path.join(RACINE, 'asm')],
                       capture_output=True, text=True)
    if r.returncode or 'ERROR' in r.stdout + r.stderr:
        print('ÉCHEC make -C asm\n' + r.stdout + r.stderr)
        return 1

    dossier = tempfile.mkdtemp()
    carte = Carte(dossier)

    # (source, origine, nom du binaire) ; origine None = celle de l'ORG
    cas = [
        (os.path.join(RACINE, 'asm', 'test', 'test6309.asm'), 0x0000, 'T6309'),
        (os.path.join(RACINE, 'asm', 'test', 'test1.asm'), None, 'T1'),
        (os.path.join(RACINE, 'asm', 'test', 'test_edge.asm'), None, 'TEDGE'),
        (os.path.join(RACINE, 'asm', 'test', 'test_pcr.asm'), None, 'TPCR'),
        (os.path.join(RACINE, 'asm', 'test', 'test_pcr2.asm'), None, 'TPCR2'),
        (os.path.join(RACINE, 'asm', 'test', 'test_dir.asm'), None, 'TDIR'),
        (os.path.join(RACINE, 'apps', 'mire.asm'), 0x0000, 'MIRE'),
        (os.path.join(RACINE, 'apps', 'glouton.asm'), 0x0000, 'GLOUTON'),
    ]
    # « tout » : toutes les applications et BRIQUES (long : quelques minutes)
    if 'tout' in sys.argv[1:]:
        sys.argv.remove('tout')
        for f in sorted(os.listdir(os.path.join(RACINE, 'apps'))):
            if f.endswith('.asm') and f not in ('mire.asm', 'glouton.asm'):
                org = 0
                cas.append((os.path.join(RACINE, 'apps', f), org, f[:-4].upper()[:15]))
        cas.append((os.path.join(RACINE, 'games', 'briques.asm'), 0x0000, 'BRIQUES'))
    seul = sys.argv[1:]
    for source, origine, sortie in cas:
        if seul and not any(x.lower() in source.lower() for x in seul):
            continue
        nom_src = os.path.basename(source).upper()
        if origine is None:
            ref_src, org_ref = sans_org(source, dossier)
            args = [nom_src, sortie]
        else:
            ref_src, org_ref = source, origine
            args = [nom_src, sortie, '%04X' % origine]
        ref, err = lwasm(ref_src, org_ref, dossier)
        if ref is None:
            verifie(False, '%s : lwasm refuse le source de référence\n%s' % (nom_src, err))
            continue
        carte.ajoute(nom_src, source)
        for nom, chemin in includes(source).items():
            carte.ajoute(nom, chemin)
        texte, pas, _ = assemble(carte, s, args)
        bin_ = carte.lit(sortie)
        pareil = bin_ == ref
        detail = ''
        if not pareil:
            detail = '\n' + texte
            if bin_ is not None:
                n = next((i for i in range(min(len(bin_), len(ref))) if bin_[i] != ref[i]),
                         min(len(bin_), len(ref)))
                detail += '\n  tailles ASM %d / lwasm %d ; 1re différence à +$%04X (adresse $%04X)' % (
                    len(bin_), len(ref), n, org_ref + n)
                detail += '\n  ASM   ' + bin_[n:n + 12].hex(' ')
                detail += '\n  lwasm ' + ref[n:n + 12].hex(' ')
        verifie(pareil, '%s -> %s : %d octets identiques à lwasm (%.1f M instructions, ~%d s sur la carte)%s'
                % (nom_src, sortie, len(ref), pas / 1e6, pas * 5 / 1.8432e6, detail))
        if pareil:
            e = carte.entree(sortie)
            # une application (le source inclut lib/vision.asm) : attribut « app »
            app = 'lib/vision.asm' in open(source, encoding='utf-8', errors='replace').read()
            page_att = 1
            attr_att = 0x17 if app else 0x07
            verifie(e['page'] == page_att and int(e['addr'], 16) == org_ref and e['attr'] == attr_att,
                    '%s : entrée page %d, adresse $%04X, attributs $%02X' % (sortie, e['page'], int(e['addr'], 16), e['attr']))

    if not seul:
        # un ancien fichier garde sa page et ses attributs
        chemin = os.path.join(dossier, 'vieux')
        open(chemin, 'wb').write(b'\0' * 10)
        carte.ajoute('VIEUX', chemin, page=3, attr=0x05)
        carte.ajoute('TEST_DIR.ASM', os.path.join(RACINE, 'asm', 'test', 'test_dir.asm'))
        texte, _, _ = assemble(carte, s, ['TEST_DIR.ASM', 'VIEUX'])
        e = carte.entree('VIEUX')
        verifie(e and e['page'] == 3 and e['attr'] == 0x05 and e['size'] != 10,
                'un ancien fichier garde sa page (3) et ses attributs ($05)')

        # une erreur nomme le fichier (INCLUDE) et la ligne
        inc = os.path.join(dossier, 'faux.inc')
        open(inc, 'w').write('; un include\n\n    lda #1\n    ldq #3\n')
        src = os.path.join(dossier, 'faux.asm')
        open(src, 'w').write(' section .code\n include "lib/FAUX.INC"\n rts\n')
        carte.ajoute('FAUX.ASM', src)
        carte.ajoute('FAUX.INC', inc)
        texte, _, _ = assemble(carte, s, ['FAUX.ASM', 'FAUX'])
        verifie('FAUX.INC ligne 4' in texte and 'ldq #3' in texte and carte.entree('FAUX') is None,
                'erreur dans un INCLUDE : « FAUX.INC ligne 4 », la ligne affichée, pas de binaire\n  '
                + texte.strip().replace('\n', '\n  '))

        texte, _, _ = assemble(carte, s, ['ABSENT.ASM', 'X'])
        verifie('introuvable' in texte, 'source absent : « introuvable »')

    if not seul or 'dossiers' in seul:
        # carte rangée comme le dépôt (deploy_sd.sh) : APPS/, LIB/, BIOS/,
        # sans aucune copie à plat ; ASM lancé depuis APPS, sortie "/GLOUTON"
        d2 = os.path.join(dossier, 'd2')
        os.makedirs(d2)
        c2 = Carte(d2)
        src = os.path.join(RACINE, 'apps', 'glouton.asm')
        for chemin in [src] + list(includes(src).values()):
            c2.ajoute(os.path.relpath(chemin, RACINE).upper(), chemin)
        ref, _ = lwasm(src, 0x0000, dossier)
        apps = c2.entree('APPS')['id']
        texte, pas, _ = assemble(c2, s, ['GLOUTON.ASM', '/GLOUTON'], dossier=apps)
        e = c2.entree('GLOUTON')
        verifie(c2.lit('GLOUTON') == ref and e['parent'] == 0 and e['page'] == 1 and e['attr'] == 0x17,
                'carte en dossiers, ASM lancé dans APPS : INCLUDE "../lib/ui.inc" -> LIB/UI.INC, '
                'sortie "/GLOUTON" à la racine, identique à lwasm (%.1f M instructions)%s'
                % (pas / 1e6, '' if c2.lit('GLOUTON') == ref else '\n' + texte))
        texte, _, _ = assemble(c2, s, ['GLOUTON.ASM', 'GLOUTON2'], dossier=apps)
        verifie(c2.entree('APPS/GLOUTON2') is not None and c2.entree('GLOUTON2') is None,
                'sortie sans chemin : dans le dossier courant (APPS/GLOUTON2)')

    shutil.rmtree(dossier, ignore_errors=True)
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
