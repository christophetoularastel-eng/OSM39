#!/usr/bin/env python3
# ===================================================================
# verifie_aytest.py - cmd/AYTEST face à un AY-3-8910 simulé
# ===================================================================
# Le VRAI BIOS et le VRAI cmd/AYTEST dans l'émulateur de verifie_fs.py.
# L'AY est modélisé comme le câble la carte SD-KBD-SON : écrire AY_ADR
# choisit le registre, écrire AY_DATA l'écrit (tronqué à sa largeur),
# lire AY_ADR le relit. video_wait_vsync compte les trames.
# Vérifie : relecture 28/28 sur un AY sain ; sur un AY dont R9 se relit
# toujours 0 (la puce de la carte, 30 oct. 2026) : 26/28 et les deux
# fautes affichées ; pour chaque étape d'écoute, l'état de l'AY pendant
# l'attente (période La 440 = 262, voie seule au mixeur, volume) et sa
# durée ; silence entre les étapes et à la fin ; ports A et B en entrée.
# Puis le séquenceur du BIOS (snd_play + AUDIO_UPDATE de l'IRQ) : voix 1
# sur la voie A, voix 2 sur la voie C, TP = (N+1)/8 plafonné à $FFF,
# note 0 = volume 0, durée+1 trames par ligne, silence à la fin ; le
# jingle de démarrage et une partition copiée depuis la page 1.
#   make -C bios && make -C cmd && python3 test/verifie_aytest.py
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_dossiers as vd   # noqa: E402

HW = {}
for ligne in open(os.path.join(RACINE, 'bios', 'hardware.inc')):
    p = ligne.split()
    if len(p) >= 3 and p[1].lower() == 'equ' and p[2].startswith('$'):
        HW[p[0].rstrip(':')] = int(p[2][1:], 16)
MASQUES = [0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F, 0xFF, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF]


class Machine(va.MachineAsm):
    def __init__(self, image, s, r9_mort):
        super().__init__(image, s)
        self.reg = [0] * 16
        self.adr = 0
        self.r9_mort = r9_mort
        self.attentes = []              # (trames, copie des registres)
        self.ports_sortie = False

    def rd8(self, a):
        if (a & 0xFFFF) == HW['AY_ADR']:
            if self.adr == 9 and self.r9_mort:
                return 0
            return self.reg[self.adr] if self.adr < 14 else 0xFF
        return super().rd8(a)

    def wr8(self, a, v_):
        a &= 0xFFFF
        if a == HW['AY_ADR']:
            self.adr = v_ & 0x0F
            return
        if a == HW['AY_DATA']:
            self.reg[self.adr] = v_ & MASQUES[self.adr]
            if self.adr == 7 and v_ & 0xC0:
                self.ports_sortie = True
            return
        super().wr8(a, v_)

    def step(self):
        if self.pc == self.s_['video_wait_vsync']:
            self.attentes.append(((self.w >> 8), list(self.reg)))
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        super().step()


def lance(r9_mort):
    b = vd.Banc()
    m = Machine(b.image, b.s, r9_mort)
    s = b.s
    v.installe_bios(m)          # table des services, et BIOS2
    code = open(os.path.join(RACINE, 'cmd', 'AYTEST'), 'rb').read()
    m.banks[1][:len(code)] = code
    m.mem[s['current_page']] = 1
    m.page = 1
    v.appelle(m, 0x0000, 5_000_000)
    return m, m.texte.decode('latin-1').replace('\r', '')


def sequenceur(partition):
    """snd_play puis AUDIO_UPDATE trame par trame (le vrai code de l'IRQ,
    jusqu'à END_IRQ) : l'AY doit suivre la partition ligne par ligne, chaque
    ligne durée+1 trames, puis le silence. partition None : le jingle en ROM."""
    b = vd.Banc()
    m = Machine(b.image, b.s, False)
    s = b.s
    m.reg[7] = 0x07                     # un programme a laissé le bruit au mixeur
    if partition is None:
        adr = s['SONG_TADA_2V']
        lignes, i = [], adr
        while (m.mem[i] << 8 | m.mem[i + 1]) != 0xFFFF:
            lignes.append((m.mem[i] << 8 | m.mem[i + 1], m.mem[i + 2] << 8 | m.mem[i + 3], m.mem[i + 4]))
            i += 5
    else:
        lignes, adr = partition, 0x1000
        octets = b''.join(bytes([n1 >> 8, n1 & 255, n2 >> 8, n2 & 255, d]) for n1, n2, d in lignes) + b'\xff\xff'
        m.banks[1][adr:adr + len(octets)] = octets
    m.mem[s['current_page']] = 1
    m.page = 1
    m.x = adr
    v.appelle(m, s['snd_play'])
    m.page = 0                          # la page change : la copie en SND_BUF doit suffire
    m.mem[s['current_page']] = 0

    def voie(n, per, vol):
        r = m.reg
        if n == 0:
            return r[vol] == 0
        tp = min((n + 1) >> 3, 0xFFF)
        return r[per] | r[per + 1] << 8 == tp and r[vol] == 15

    attendu = []
    for n1, n2, d in lignes:
        attendu += [(n1, n2)] * (d + 1)
    for t in range(len(attendu) + 3):
        m.s = 0xDF00
        m.pc = s['AUDIO_UPDATE']
        while m.pc != s['END_IRQ']:
            m.step()
        r = m.reg
        if t < len(attendu):
            n1, n2 = attendu[t]
            if not (voie(n1, 0, 8) and voie(n2, 4, 10) and r[7] == 0x3A and r[9] == 0):
                return False, 'trame %d : registres %s' % (t, ' '.join('%02X' % x for x in r[:14]))
        elif not (r[7] == 0x3A and r[8] == r[9] == r[10] == 0):
            return False, 'trame %d : pas de silence après la fin' % t
    return True, '%d lignes, %d trames, puis silence' % (len(lignes), len(attendu))


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    m, t = lance(False)
    verifie('Relecture des registres : 28/28 justes' in t and ' R' not in t.split('justes')[0].split('\n', 1)[1],
            'AY sain : 28/28, aucune faute affichée')
    silence = lambda r: r[7] == 0x3F and r[8] == r[9] == r[10] == 0       # noqa: E731
    sons = [(n, r) for n, r in m.attentes if not silence(r)]
    pauses = [(n, r) for n, r in m.attentes if silence(r)]
    attendus = [
        ('voie A', 60, lambda r: r[0] | r[1] << 8 == 262 and r[7] == 0x3E and r[8] == 15),
        ('voie B', 60, lambda r: r[2] | r[3] << 8 == 262 and r[7] == 0x3D and r[9] == 15 and r[8] == 0),
        ('voie C', 60, lambda r: r[4] | r[5] << 8 == 262 and r[7] == 0x3B and r[10] == 15 and r[8] == r[9] == 0),
        ('accord', 90, lambda r: (r[0], r[2], r[4]) == (220, 175, 147) and r[7] == 0x38 and r[8] == r[9] == r[10] == 12),
        ('bruit', 60, lambda r: r[6] == 15 and r[7] == 0x37 and r[8] == 15),
        ('enveloppe', 120, lambda r: r[7] == 0x3E and r[8] == 0x10 and r[13] == 0x08 and r[11] | r[12] << 8 == 0x0E10),
    ]
    verifie(len(sons) == len(attendus), '%d étapes sonores (attendu %d)' % (len(sons), len(attendus)))
    for (nom, n, test), (n_, r) in zip(attendus, sons):
        verifie(n_ == n and test(r), '%s : %d trames, registres %s' % (nom, n_, ' '.join('%02X' % x for x in r[:14])))
    verifie(len(pauses) == len(attendus) and all(n == 15 for n, _ in pauses), 'un quart de seconde de silence après chaque étape')
    verifie(silence(m.reg) and 'Fin : silence.' in t, 'fin : silence (R7 = $3F, volumes à 0)')
    verifie(not m.ports_sortie, 'ports A et B jamais en sortie')

    m, t = lance(True)
    verifie('28' in t and 'Relecture des registres : 26/28 justes' in t
            and t.count('R9 : ecrit $') == 2 and 'relu $00 (attendu $05)' in t,
            'AY dont R9 se relit 0 : 26/28, les deux fautes de R9 affichées')

    # --- Le séquenceur du BIOS sur l'AY : voix 1 -> voie A, voix 2 -> voie C ---
    for nom, partition in (('jingle de démarrage (ROM)', None),
                           ('partition en page 1 (copiée)', [(0x0DC2, 0x0000, 2), (0x0000, 0x0105, 0),
                                                              (0xFFFE, 0x0007, 3), (0x0000, 0x0000, 1)])):
        ok, detail = sequenceur(partition)
        verifie(ok, 'séquenceur, %s : %s' % (nom, detail))

    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
