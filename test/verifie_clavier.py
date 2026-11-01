#!/usr/bin/env python3
# ===================================================================
# verifie_clavier.py - Verr. Maj et voyants du clavier (bios/keyboard.asm)
# ===================================================================
# Le VRAI BIOS dans la machine de verifie_fs.py, avec le 6850 du clavier
# ($A180/$A181) simulé : SR (RDRF si un octet attend, TDRE toujours), RDR,
# et chaque écriture de CR et TDR notée avec le nombre d'instructions.
#   1. kbd_poll sur des codes PS/2 posés dans kbd_buf : Verr. Maj ($58)
#      bascule kbd_verr (bit 2) et demande les voyants ; avec Verr. Maj,
#      a-z -> A-Z, Maj+lettre -> minuscule, é è à ç ù -> É È À Ç Ù
#      (Latin-1, comme les tables), chiffres, & " ' ( et ponctuation
#      inchangés, Ctrl et AltGr inchangés ; un second appui rend tout.
#   2. l'IRQ du VSYNC (le vrai handler_IRQ, trame par trame) : $ED dans
#      la trame de la demande, l'octet des voyants deux trames plus tard ;
#      chaque fois TDR écrit, puis CR = $1C (RTS bas) tenu au moins 100
#      instructions (> 100 µs), puis CR = $5C ; kbd_muet = 4 et décompté ;
#      CR = $DC en sortie d'IRQ (RIE, RTS haut).
#   3. la NMI (le vrai handler_NMI) : pendant kbd_muet, l'écho et l'accusé
#      sont lus et jetés (kbd_buf, SCAN_CODE, NEW_CODE intacts) ; ensuite,
#      un octet entre dans la file comme avant.
# L'essai sur la machine (voyant Verr. Maj allumé puis éteint par TELE,
# 31 oct. 2026) : tools/tele/essai_leds.asm.
#   make -C bios && python3 test/verifie_clavier.py
# ===================================================================
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_dossiers as vd   # noqa: E402
import verifie_donjon39 as vdm    # noqa: E402

SR_KEY, RDR_KEY = 0xA180, 0xA181
SR_SERIE = 0xA000
FRAPPE = {'a': 0x15, 'q': 0x1C, 'z': 0x1D, 'e': 0x24, 'é': 0x1E, 'è': 0x3D, 'à': 0x45, 'ç': 0x46,
          'ù': 0x52, '&': 0x16, '"': 0x26, ',': 0x3A, 'm': 0x4C, ' ': 0x29}
MAJ, CTRL, VERR = 0x12, 0x14, 0x58


class Machine(vdm.Banc):
    def __init__(self, image, s):
        super().__init__(image, s, {'Irq_Donjon': -1}, [])
        self.rx = []
        self.journal = []               # (registre, valeur, instructions)

    def rd8(self, a):
        a &= 0xFFFF
        if a == SR_KEY:
            return 0x02 | (1 if self.rx else 0)
        if a == RDR_KEY:
            return self.rx.pop(0) if self.rx else 0
        if a == SR_SERIE:
            return 0x02
        return super().rd8(a)

    def wr8(self, a, x):
        a &= 0xFFFF
        if a == SR_KEY:
            self.journal.append(('CR', x, self.n))
            return
        if a == RDR_KEY:
            self.journal.append(('TDR', x, self.n))
            return
        super().wr8(a, x)

    def step(self):
        self.n += 1
        v.Machine.step(self)            # pas d'IRQ spontanée : on les donne à la main


def touche(code, relache=True):
    return [code] + ([0xF0, code] if relache else [])


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    b = vd.Banc()
    s = b.s
    m = Machine(b.image, s)
    m.wr16(s['rvec_IRQ'], s['handler_IRQ'])
    m.wr16(s['rvec_NMI'], s['handler_NMI'])

    def frappe(codes):
        """Pose les codes dans kbd_buf, appelle kbd_poll jusqu'à la file vide ;
        rend les caractères obtenus."""
        out = []
        for c in codes:
            t = m.mem[s['kbd_tete']]
            m.mem[s['kbd_buf'] + t] = c
            m.mem[s['kbd_tete']] = (t + 1) & 15
            m.mem[s['NEW_CODE']] = 1
            while m.mem[s['kbd_queue']] != m.mem[s['kbd_tete']]:
                m.cc = 0x50
                v.appelle(m, s['kbd_poll'], 2_000_000)
                if m.a:
                    out.append(m.a)
        return out

    def mot(texte, maj=False):
        codes = []
        for ch in texte:
            if maj:
                codes += [MAJ]
            codes += touche(FRAPPE[ch])
            if maj:
                codes += [0xF0, MAJ]
        return bytes(frappe(codes))

    l1 = lambda t: t.encode('latin-1')     # noqa: E731
    m.mem[s['kbd_verr']] = 0
    verifie(mot('aqzeéèàçù') == l1('aqzeéèàçù') and mot('a', maj=True) == b'A',
            'sans Verr. Maj : minuscules, Maj+a = A')
    verifie(frappe(touche(VERR)) == [] and m.mem[s['kbd_verr']] == 0x04 and m.mem[s['kbd_led_dem']] == 1,
            'Verr. Maj : aucun caractère, kbd_verr = $04, voyants demandés')
    got = mot('aqzeéèàçù')
    verifie(got == l1('AQZEÉÈÀÇÙ'), 'avec Verr. Maj : a q z e é è à ç ù -> %s' % got.decode('latin-1'))
    verifie(mot('a', maj=True) == b'a' and mot('é', maj=True) == b'2',
            'avec Verr. Maj, Maj+a = a, Maj+é = 2 (rangée du haut : chiffres seulement avec Maj)')
    verifie(mot('&",m ') == l1('&",M '), 'avec Verr. Maj : & " , espace inchangés, m -> M')
    ctrl = bytes(frappe([CTRL] + touche(FRAPPE['a']) + [0xF0, CTRL]))
    altgr = bytes(frappe([0xE0, 0x11] + touche(FRAPPE['é']) + [0xE0, 0xF0, 0x11]))
    verifie(ctrl == b'\x01' and altgr == b'~', 'avec Verr. Maj : Ctrl+a = $01, AltGr+é = ~ (inchangés)')
    m.mem[s['kbd_led_dem']] = 0
    frappe(touche(VERR))
    verifie(m.mem[s['kbd_verr']] == 0 and mot('aé') == l1('aé') and m.mem[s['kbd_led_dem']] == 1,
            'second Verr. Maj : kbd_verr = 0, minuscules, voyants demandés')

    # --- 2. l'IRQ envoie les voyants ---
    m.mem[s['kbd_verr']] = 0x04
    m.mem[s['kbd_led_dem']] = 1
    m.mem[s['kbd_led_cpt']] = 0
    m.mem[s['kbd_muet']] = 0
    trames = []
    for t in range(8):
        m.journal = []
        m.s = 0xDF00
        m.pc = v.RETOUR
        m.cc = 0x00
        m.interruption(0xFFF8)          # le vrai vecteur IRQ, puis rvec_IRQ
        while m.pc != v.RETOUR:
            m.step()
        trames.append((list(m.journal), m.mem[s['kbd_muet']]))

    def envoi(j):
        """[(octet, instructions RTS bas)] des envois d'une trame."""
        out = []
        for k, (r, x, n) in enumerate(j):
            if r == 'TDR' and k + 2 < len(j) and j[k + 1][:2] == ('CR', 0x1C) and j[k + 2][:2] == ('CR', 0x5C):
                out.append((x, j[k + 2][2] - j[k + 1][2]))
        return out
    e = [envoi(j) for j, _ in trames]
    muets = [mu for _, mu in trames]
    verifie(e[0][:1] and e[0][0][0] == 0xED and e[1] == [] and e[2][:1] and e[2][0][0] == 0x04
            and all(x == [] for x in e[3:]),
            'IRQ : $ED à la trame 0, rien à la 1, $04 à la 2, puis rien (%s)'
            % ' | '.join(' '.join('%02X' % o for o, _ in x) or '-' for x in e))
    tenu = [n for x in e for _, n in x]
    verifie(tenu and min(tenu) >= 100, 'RTS bas tenu %s instructions (>= 100 : plus de 100 µs)' % tenu)
    verifie(muets[:7] == [4, 3, 4, 3, 2, 1, 0] and all(j and j[-1][:2] == ('CR', 0xDC) for j, _ in trames),
            'kbd_muet %s ; CR = $DC (RIE, RTS haut) en sortie de chaque IRQ' % muets)

    # --- 3. la NMI pendant et après kbd_muet ---
    def nmi(octets):
        m.rx = list(octets)
        m.s = 0xDF00
        m.pc = v.RETOUR
        m.cc = 0x00
        m.interruption(0xFFFC)
        while m.pc != v.RETOUR:
            m.step()
    t0, sc = m.mem[s['kbd_tete']], m.mem[s['SCAN_CODE']]
    m.mem[s['NEW_CODE']] = 0
    m.mem[s['kbd_muet']] = 3
    nmi([0xED, 0x04, 0xF4])
    verifie(not m.rx and m.mem[s['kbd_tete']] == t0 and m.mem[s['SCAN_CODE']] == sc and m.mem[s['NEW_CODE']] == 0,
            'NMI pendant kbd_muet : écho et accusé lus et jetés, file intacte')
    m.mem[s['kbd_muet']] = 0
    nmi([0x1C])
    verifie(m.mem[s['kbd_tete']] == (t0 + 1) & 15 and m.mem[s['kbd_buf'] + t0] == 0x1C
            and m.mem[s['SCAN_CODE']] == 0x1C and m.mem[s['NEW_CODE']] == 1,
            'NMI ensuite : l\'octet entre dans la file comme avant')

    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
