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
# Puis la console plein écran (VSYNC_IRQ) : $0C, 35 lignes, défilement
# par l'adresse de départ du 68B45 (R12/R13, en cases), curseur (R14/R15).
# La VRAM est lue par test/carte.py : l'essai vaut pour les cartes v4 et
# mono (fichier CARTE).
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_demarrage as vd  # noqa: E402
import verifie_fs as v          # noqa: E402
import carte                    # noqa: E402

HW = vd.HW
X0, Y0, L, H = 2, 3, 76, 20      # la zone du Terminal d'OSM-VISION
ATTR = 0x0A


sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'video'))
import latin_cp437      # noqa: E402  (Latin-1 $A0-$FF -> CP437, la table du BIOS)


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
                if o >= 0xA0:               # PrintChar : Latin-1 -> CP437
                    c = chr(latin_cp437.cp437(o))
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
    carte.pose(m.mem, 0, fond, fond[::-1])
    crtc = {'sel': 0, 'r': {}}
    wr8 = m.wr8

    def wr8_crtc(a, val):
        a &= 0xFFFF
        if a == HW['CRTC_RS']:
            crtc['sel'] = val
        elif a == HW['CRTC_DATA']:
            crtc['r'][crtc['sel']] = val & 0xFF
        wr8(a, val)
    m.wr8 = wr8_crtc
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
        return [carte.lit(m.mem, (Y0 + r) * 80 + X0, L)[0].decode('latin-1') for r in range(H)]

    def hors_zone(plan, ref):
        ecran = carte.lit(m.mem, 0, 2400)[plan]
        return all(ecran[i] == ref[i] for i in range(2400)
                   if not (Y0 <= i // 80 < Y0 + H and X0 <= i % 80 < X0 + L))

    appel(s['Console_Zone'], a=X0, b=Y0, w=(L << 8) | H, y=ATTR)
    for _ in range(20):
        trame()
    verifie(m.mem[s['cz_actif']] != 0 and all(l == ' ' * L for l in zone_vram()),
            'sys_Console_Zone : zone effacée par l\'IRQ (%d rangées)' % H)
    attrs = {b for r in range(H) for b in carte.lit(m.mem, (Y0 + r) * 80 + X0, L)[1]}
    verifie(attrs == {ATTR}, 'zone : attribut $%02X partout (%s)' % (ATTR, sorted(attrs)[:4]))
    mod = Modele()
    cas = [
        ('lignes', 'Bonjour\r\nOSM39 Terminal\r\nA> '),
        ('BS', 'LSX\x08\x08\x08\x08\x08 ok\r\n'),
        ('ligne trop longue', ''.join(chr(0x41 + i % 26) for i in range(170)) + '\r\n'),
        ('défilement', ''.join('ligne %02d\r\n' % i for i in range(30))),
        ('codes ignorés', 'a\x07b\x80\x81c\x1bd\r\n'),
        ('accents Latin-1 en CP437', 'été à Noël, ça : 5 ° ½\r\n'),
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
    verifie(hors_zone(0, fond) and hors_zone(1, fond[::-1]),
            'hors de la zone : rien n\'a changé (caractères et couleurs)')
    curseur = m.rd16(HW['VRAM_PTR'])
    voulu = carte.adr((Y0 + mod.lig) * 80 + X0 + mod.col)
    verifie(curseur == voulu, 'curseur : $%04X (attendu $%04X)' % (curseur, voulu))
    verifie(max(pas_irq) < 1200, 'IRQ : au plus %d instructions par trame' % max(pas_irq))
    appel(s['Console_Zone'], a=0, b=0, w=0, y=0)
    verifie(m.mem[s['cz_actif']] == 0, 'E = 0 : console plein écran')

    # --- console plein écran : effacement, 35 lignes, défilement matériel ---
    def r16(h, b):
        return (crtc['r'].get(h, 0) << 8) | crtc['r'].get(b, 0)
    appel(s['PrintChar'], a=0x0C)
    car, col = carte.lit(m.mem, 0, 4096)
    attr = m.mem[s['char_attribut']]
    verifie(car == b' ' * 4096 and col == bytes([attr]) * 4096 and r16(12, 13) == 0xFFFF,
            'plein écran : $0C efface les 4096 cases (espace, attribut $%02X), départ $FFFF' % attr)
    lignes = ['L%02d %s' % (i, chr(0x41 + i % 26) * (i % 50)) for i in range(35)]
    ecrit(''.join(l + '\r\n' for l in lignes))
    depart = (-1 + 80 * (35 - 29)) & 0xFFFF            # 6 défilements de 80 cases
    ok = all(carte.lit(m.mem, 80 * i, len(l))[0] == l.encode() for i, l in enumerate(lignes))
    verifie(ok, 'plein écran : la ligne i est dans les cases 80 i... (35 lignes)')
    vues = [carte.lit(m.mem, depart + 1 + 80 * r, 80)[0].decode('latin-1').rstrip() for r in range(29)]
    verifie(r16(12, 13) == depart and vues == lignes[6:],
            'plein écran : défilement, R12/R13 = $%04X (attendu $%04X), rangées 0-28 = lignes 6-34'
            % (r16(12, 13), depart))
    verifie(r16(14, 15) == 35 * 80 - 1 and m.rd16(HW['VRAM_PTR']) == carte.adr(35 * 80),
            'plein écran : curseur R14/R15 = $%04X (attendu $%04X), VRAM_PTR = $%04X'
            % (r16(14, 15), 35 * 80 - 1, m.rd16(HW['VRAM_PTR'])))

    # les accents Latin-1 tapés (SHELL, BBC BASIC plein écran) : CP437 à l'écran,
    # et les flèches $80-$83 gardent leur rôle (é = $82 en CP437 n'en est pas une)
    ecrit('ça été\r\n')
    k = 35 * 80
    attendu = bytes(latin_cp437.cp437(ord(c)) if ord(c) >= 0xA0 else ord(c) for c in 'ça été')
    verifie(carte.lit(m.mem, k, 6)[0] == attendu,
            'plein écran : accents Latin-1 affichés en CP437 (%s)' % carte.lit(m.mem, k, 6)[0].hex())

    print('\n%s : %d échec(s) (carte %s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs), carte.NOM))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
