#!/usr/bin/env python3
# ===================================================================
# verifie_ayjoue.py - cmd/AYJOUE (lib/ay_joue.asm) face au modèle de ay.py
# ===================================================================
# Le VRAI BIOS et le VRAI cmd/AYJOUE, le morceau sur une carte OSMFS,
# l'IRQ du VSYNC prise toutes les TRAME instructions (le lecteur, posé
# dans rvec_IRQ, puis le VRAI handler_IRQ). L'AY est modélisé comme le
# câble la carte SD-KBD-SON. Vérifie :
#   - à chaque trame (photo à l'entrée de l'IRQ suivante, ou de
#     AyJ_Arrete), les registres de l'AY = Lecteur.trame() de
#     tools/ay/ay.py (morceau d'essai qui passe par tout le format :
#     enveloppe, bruit, silences, ~, notes de plus de 64 trames, voix B,
#     voix qui finissent à des moments différents ; puis KOROBEINIKI) ;
#   - le morceau d'essai fini : AYJOUE rend la main tout seul ;
#     KOROBEINIKI (qui boucle) : Echap le coupe ;
#   - à la sortie : rvec_IRQ rendu au BIOS, silence (R7 = $3F, volumes à
#     0), ports jamais en sortie, chaque écriture de trame dans l'IRQ ;
#   - son_coupe = $4D : mêmes registres, volumes à 0 ;
#   - sans argument, morceau absent, fichier qui n'est pas un morceau :
#     un message, rien ne joue, rvec_IRQ intact.
#   make -C bios && make -C cmd && python3 test/verifie_ayjoue.py
# ===================================================================
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'ay'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_donjon39 as vdm    # noqa: E402
import ay                       # noqa: E402

BIN = os.path.join(RACINE, 'cmd', 'AYJOUE')
MAP = os.path.join(RACINE, 'cmd', 'AYJOUE.map')
KORO = os.path.join(RACINE, 'tools', 'ay', 'morceaux', 'korobeiniki.txt')
AY_ADR, AY_DATA = 0xA150, 0xA151
RVEC_IRQ = 0xDFF6

ESSAI = """
titre Essai du format
tempo 3
instrument a vol 15 10 5
instrument env env 14 50
instrument bruit bruit 3 son non vol 12 8 4 0
instrument tb bruit 20 vol 9
A: @a C4 D4*2 - ~ E4*30 @env G2*2 ~*2 @a A#8 C1 Gb5
B: @tb E3*4 -*3 @bruit C4 C4 - @a F#5*2
C: @env C3*25 - @a F#5 @bruit D2*3
"""


class Machine(vdm.Banc):
    def __init__(self, image, s, a, script):
        super().__init__(image, s, {'Irq_Donjon': -1}, script)
        self.sym = a
        self.reg = [0] * 16
        self.adr = 0
        self.photos = []                # registres à l'entrée de chaque IRQ, lecteur posé
        self.hors_irq = 0               # écritures de l'AY hors IRQ, lecteur en marche
        self.ports_sortie = False
        self.trames = 0                 # trames jouées (AyJ_Trame avec AyJ_Actif <> 0)
        self.zone_arret = set()

    def wr8(self, a, x):
        a &= 0xFFFF
        if a in (AY_ADR, AY_DATA):
            if a == AY_ADR:
                self.adr = x & 15
            else:
                self.reg[self.adr] = x
                if self.adr == 7 and x & 0xC0:
                    self.ports_sortie = True
            if not self.dans_irq and self.mem[0xDFF6] << 8 | self.mem[0xDFF7] == self.sym['AyJ_Irq'] \
                    and self.page == 1 and self.pc not in self.zone_arret:
                self.hors_irq += 1
            return
        super().wr8(a, x)

    def interruption(self, vecteur):
        if self.rd16(RVEC_IRQ) == self.sym['AyJ_Irq']:
            self.photos.append(list(self.reg))
        super().interruption(vecteur)

    def step(self):
        # dernière photo : à l'arrêt (la dernière trame n'est suivie d'aucune IRQ)
        if self.pc == self.sym['AyJ_Arrete'] and self.page == 1 and self.rd16(RVEC_IRQ) == self.sym['AyJ_Irq']:
            self.photos.append(list(self.reg))
        if self.pc == self.sym['AyJ_Trame'] and self.page == 1 and self.banks[1][self.sym['AyJ_Actif']]:
            self.trames += 1
        super().step()


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


def lance(fichiers, args, script=(), son_coupe=False):
    """fichiers : {nom sur la carte: octets} ; args : argv[1:]."""
    s, a = v.sym(), symboles()
    d = tempfile.mkdtemp()
    c = va.Carte(d)
    for nom, octets in fichiers.items():
        chemin = os.path.join(d, 'f%d' % len(os.listdir(d)))
        open(chemin, 'wb').write(octets)
        c.ajoute(nom, chemin, page=1, adresse='0000', attr=0x06)
    m = Machine(c.image, s, a, list(script) + [(4000, lambda m: (_ for _ in ()).throw(vdm.Fini()))])
    # les écritures d'AyJ_Demarre / AyJ_Arrete (silence) ne sont pas des trames
    m.zone_arret = set(range(a['AyJ_Arrete'], a['AyJ_Irq']))
    rom, fin = s['table_function_rom'], s['table_function_rom_end']
    for i in range(fin - rom):
        m.mem[s['table_function_ram'] + i] = m.mem[rom + i]
    m.wr16(RVEC_IRQ, s['handler_IRQ'])
    m.mem[s['son_coupe']] = 0x4D if son_coupe else 0
    code = open(BIN, 'rb').read()
    m.banks[1][:len(code)] = code
    adr, ptrs = 0xD300, []
    for x in ['AYJOUE'] + list(args):
        b = x.encode('ascii') + b'\0'
        m.mem[adr:adr + len(b)] = b
        ptrs.append(adr)
        adr += len(b)
    m.mem[s['argc']] = len(ptrs)
    for i, p in enumerate(ptrs):
        m.wr16(s['argv'] + 2 * i, p)
    m.mem[s['current_page']] = 1
    m.page = 1
    m.cc = 0
    try:
        v.appelle(m, 0x0000, 80_000_000)
        r = 'rendu'
    except vdm.Fini:
        r = 'pas rendu'
    except Exception as e:      # noqa: BLE001
        r = 'PLANTE : %s ($%04X page %d)' % (e, m.pc, m.page)
    return m, r, m.texte.decode('latin-1').replace('\r', '')


def compare(m, morceau, son_coupe=False):
    """Les photos (après 1, 2... trames) contre le modèle ; rend (nb, première différence)."""
    lec = ay.Lecteur(morceau, son_coupe)
    for t, p in enumerate(m.photos[1:m.trames + 1]):
        lec.trame()
        if p[:14] != lec.reg[:14]:
            return t, 'trame %d : AY %s, modèle %s' % (t, ' '.join('%02X' % x for x in p[:14]),
                                                       ' '.join('%02X' % x for x in lec.reg[:14]))
    return min(len(m.photos) - 1, m.trames), None


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    s = v.sym()
    a = symboles()
    verifie(a.get('Start') == 0, 'point d\'entrée à l\'offset 0')
    silence = lambda r: r[7] == 0x3F and r[8] == r[9] == r[10] == 0       # noqa: E731

    def sortie(m, r):
        verifie(r == 'rendu' and m.rd16(RVEC_IRQ) == s['handler_IRQ'] and silence(m.reg) and not m.ports_sortie,
                '   sortie : %s, rvec_IRQ = $%04X (BIOS $%04X), silence, ports en entrée'
                % (r, m.rd16(RVEC_IRQ), s['handler_IRQ']))
        verifie(m.hors_irq == 0, '   écritures de trame hors IRQ : %d' % m.hors_irq)

    # 1. Morceau d'essai, joué jusqu'au bout
    essai = ay.compile_partition(ESSAI)
    lec = ay.Lecteur(essai)
    n_modele = 0
    while lec.actif():
        lec.trame()
        n_modele += 1
    m, r, t = lance({'ESSAI.MUS': essai}, ['ESSAI.MUS'])
    n, diff = compare(m, essai)
    verifie(diff is None and m.trames == n_modele and n == n_modele,
            'morceau d\'essai : %d trames jouées (modèle %d), %d comparées : %s'
            % (m.trames, n_modele, n, diff or 'identiques'))
    verifie('Joue : Essai du format' in t, '   titre affiché')
    sortie(m, r)

    # 2. KOROBEINIKI (boucle) : Echap à la trame 300
    koro = ay.compile_partition(open(KORO, encoding='utf-8').read())
    esc = [(300, vdm.appui(0x76, False)), (302, vdm.relache(0x76, False))]
    m, r, t = lance({'KOROBEINIKI.MUS': koro}, ['KOROBEINIKI.MUS'], esc)
    n, diff = compare(m, koro)
    verifie(diff is None and 295 <= n <= 310, 'KOROBEINIKI : %d trames comparées avant Echap : %s'
            % (n, diff or 'identiques'))
    sortie(m, r)

    # 3. Son coupé (touche M d'OSM-VISION)
    m, r, t = lance({'ESSAI.MUS': essai}, ['ESSAI.MUS'], son_coupe=True)
    n, diff = compare(m, essai, son_coupe=True)
    verifie(diff is None and n == n_modele and not any(p[8] | p[9] | p[10] for p in m.photos),
            'son_coupe = $4D : %d trames, volumes toujours à 0 : %s' % (n, diff or 'identiques'))
    sortie(m, r)

    # 4. Erreurs : rien ne joue, rvec_IRQ intact
    for nom, fichiers, args, attendu in (
            ('sans argument', {}, [], 'Usage : AYJOUE'),
            ('morceau absent', {}, ['RIEN.MUS'], 'Morceau introuvable'),
            ('pas un morceau', {'TEXTE.TXT': b'Bonjour\n' * 20}, ['TEXTE.TXT'], 'Pas un morceau AY')):
        m, r, t = lance(fichiers, args)
        verifie(r == 'rendu' and attendu in t and not m.photos and m.trames == 0
                and m.rd16(RVEC_IRQ) == s['handler_IRQ'],
                '%s : « %s », rien ne joue, rvec_IRQ intact' % (nom, t.strip().splitlines()[-1] if t.strip() else ''))

    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
