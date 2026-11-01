#!/usr/bin/env python3
# ===================================================================
# verifie_terminal.py - La console du BIOS dans une zone (Terminal)
# ===================================================================
# Le VRAI BIOS démarre dans la machine de verifie_demarrage.py ; on pose une
# zone (sys_Console_Zone), on écrit par le vrai PrintChar (PUTCHARV : le
# texte attend dans ASCII_BUF) et on déclenche l'IRQ VSYNC trame par trame
# (handler_IRQ, Zone_IRQ). La VRAM doit être celle d'un modèle simple :
# texte rangé dans le rectangle, retour à la ligne au bord droit,
# défilement de la zone seule, BS borné, $0C qui n'efface que la zone,
# rien d'écrit hors du rectangle, curseur du 68B45 au bon endroit.
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_demarrage as vd  # noqa: E402
import verifie_fs as v          # noqa: E402

HW = vd.HW
X0, Y0, L, H = 2, 3, 76, 20      # la zone du Terminal d'OSM-VISION
ATTR = 0x0A


class Modele:
    def __init__(self):
        self.g = [[' '] * L for _ in range(H)]
        self.lig = self.col = 0

    def ligne(self):
        if self.lig == H - 1:
            self.g = self.g[1:] + [[' '] * L]
        else:
            self.lig += 1

    def ecrit(self, texte):
        for c in texte:
            o = ord(c)
            if o == 0x0D:
                self.col = 0
            elif o == 0x0A:
                self.ligne()
            elif o == 0x08:
                self.col = max(0, self.col - 1)
            elif o == 0x0C:
                self.g = [[' '] * L for _ in range(H)]
                self.lig = self.col = 0
            elif o < 0x20 or 0x80 <= o <= 0x83:
                pass
            else:
                if self.col >= L:
                    self.col = 0
                    self.ligne()
                self.g[self.lig][self.col] = c
                self.col += 1


def main():
    s = v.sym()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    for n in ('Console_Zone', 'handler_IRQ', 'PrintChar'):
        if n not in s:
            print('ÉCHEC symbole %s absent' % n)
            return 1
    c = vd.carte(__import__('tempfile').mkdtemp())
    m, r, t = vd.demarre(c, s)
    sv = dict(s)
    sv['PrintChar'] = -1                # le vrai PrintChar (pas le crochet de texte)
    m.s_ = sv
    fond = bytes((i * 7 + 1) & 0xFF for i in range(2400))
    m.mem[0x8000:0x8000 + 2400] = fond
    m.mem[0x9000:0x9000 + 2400] = fond[::-1]
    m.banks[0][0x7000:0x7002] = b'\x20\xfe'                         # BRA * : le programme interrompu
    m.page = 0
    pas_irq = []

    def appel(adr, **regs):
        for k, val in regs.items():
            setattr(m, k, val)
        v.appelle(m, adr, 2_000_000)

    def trame():
        m.pc, m.s, m.steps = 0x7000, 0xDE00, 0
        m.interruption(0xFFF8)                                      # IRQ VSYNC
        while m.pc != 0x7000 and m.steps < 200_000:
            if m.sd():
                continue
            m.step()
        pas_irq.append(m.steps)

    def ecrit(texte):
        for i in range(0, len(texte), 100):                         # moins que l'anneau de 256
            for ch in texte[i:i + 100]:
                appel(s['PrintChar'], a=ord(ch))
            for _ in range(300):
                trame()
                if m.mem[HW['BUF_HEAD']] == m.mem[HW['BUF_TAIL']] and not m.mem[s['cz_op']]:
                    break
        for _ in range(40):                                         # travaux de rangées finis
            trame()

    def zone_vram():
        return [''.join(chr(m.mem[0x8000 + (Y0 + r) * 80 + X0 + k]) for k in range(L)) for r in range(H)]

    def hors_zone(base, ref):
        return all(m.mem[base + i] == ref[i] for i in range(2400)
                   if not (Y0 <= i // 80 < Y0 + H and X0 <= i % 80 < X0 + L))

    appel(s['Console_Zone'], a=X0, b=Y0, w=(L << 8) | H, y=ATTR)
    for _ in range(20):
        trame()
    verifie(m.mem[s['cz_actif']] != 0 and all(l == ' ' * L for l in zone_vram()),
            'sys_Console_Zone : zone effacée par l\'IRQ (%d rangées)' % H)
    attrs = {m.mem[0x9000 + (Y0 + r) * 80 + X0 + k] for r in range(H) for k in range(L)}
    verifie(attrs == {ATTR}, 'zone : attribut $%02X partout (%s)' % (ATTR, sorted(attrs)[:4]))
    mod = Modele()
    cas = [
        ('lignes', 'Bonjour\r\nOSM39 Terminal\r\nA> '),
        ('BS', 'LSX\x08\x08\x08\x08\x08 ok\r\n'),
        ('ligne trop longue', ''.join(chr(0x41 + i % 26) for i in range(170)) + '\r\n'),
        ('défilement', ''.join('ligne %02d\r\n' % i for i in range(30))),
        ('codes ignorés', 'a\x07b\x80\x81c\x1bd\r\n'),
        ('effacement $0C', 'avant\x0capres\r\nfin'),
    ]
    for nom, texte in cas:
        mod.ecrit(texte)
        ecrit(texte)
        attendu = [''.join(l) for l in mod.g]
        obtenu = zone_vram()
        ok = obtenu == attendu
        detail = ''
        if not ok:
            k = next(i for i in range(H) if obtenu[i] != attendu[i])
            detail = ' ; rangée %d : %r au lieu de %r' % (k, obtenu[k].rstrip(), attendu[k].rstrip())
        verifie(ok, 'zone : %s%s' % (nom, detail))
    verifie(hors_zone(0x8000, fond) and hors_zone(0x9000, fond[::-1]),
            'hors de la zone : rien n\'a changé (caractères et couleurs)')
    curseur = m.rd16(HW['VRAM_PTR'])
    voulu = 0x8000 + (Y0 + mod.lig) * 80 + X0 + mod.col
    verifie(curseur == voulu, 'curseur : $%04X (attendu $%04X)' % (curseur, voulu))
    verifie(max(pas_irq) < 1200, 'IRQ : au plus %d instructions par trame' % max(pas_irq))
    appel(s['Console_Zone'], a=0, b=0, w=0, y=0)
    verifie(m.mem[s['cz_actif']] == 0, 'E = 0 : console plein écran')

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
