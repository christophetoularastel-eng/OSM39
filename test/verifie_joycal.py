#!/usr/bin/env python3
# ===================================================================
# verifie_joycal.py - cmd/JOYCAL et lib/joy.asm face à un joystick simulé
# ===================================================================
# Le VRAI BIOS (EPROM + BIOS2) et le VRAI cmd/JOYCAL dans l'émulateur de
# verifie_fs.py, une carte OSMFS avec /BIN. Le port A de l'AY (R14) suit
# un script trame par trame (video_wait_vsync compte les trames ; un
# appui = son bit à 0) ; kbd_poll rend Échap à la trame voulue.
#   - le câblage de la machine (haut IOA4, droite IOA3, bas IOA2, gauche
#     IOA0, bouton IOA5 : le joystick tourné), avec un rebond, une
#     diagonale (refusée) et un bit déjà pris (refusé) : /BIN/JOYSTICK.CFG
#     = "JOY", 1, les cinq masques ; l'écran nomme chaque bit et sa broche
#     (J602, 17 - 2n) ;
#   - Joy_Init lit ce fichier (A = 1) et Joy_Lit rend, pour les 32
#     combinaisons d'appuis, exactement les bits JOY_* (diagonales
#     comprises), Z = 1 si rien ;
#   - un autre câblage (miroir) : un autre fichier, la même lecture ;
#   - sans fichier, ou avec un fichier faux (taille, en-tête, deux
#     masques égaux, un masque à deux bits) : le brochage de la Clouris
#     (A = 0) ;
#   - sans AY (le bus vide) : Joy_Lit ne rend jamais rien, JOYCAL le dit ;
#   - Échap : rien n'est écrit, l'ancien fichier reste.
#   make -C cmd JOYCAL && python3 test/verifie_joycal.py
# ===================================================================
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'egofs'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import egofs_core               # noqa: E402

BIN = os.path.join(RACINE, 'cmd', 'JOYCAL')
MAP = os.path.join(RACINE, 'cmd', 'JOYCAL.map')
NOMS = ('haut', 'droite', 'bas', 'gauche', 'bouton')
MACHINE = (0x10, 0x08, 0x04, 0x01, 0x20)    # le joystick de la machine (27 nov. 2026)
MIROIR = (0x04, 0x08, 0x01, 0x02, 0x80)
CLOURIS = (0x01, 0x02, 0x04, 0x08, 0x20)


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


class Machine(va.MachineAsm):
    def __init__(self, image, s, script, echap=None):
        super().__init__(image, s)
        self.trame = 0
        self.script = script            # trame -> valeur du port A (suivie jusqu'au changement)
        self.echap = echap

    def lit_port_a(self):
        val = 0xFF
        for t in sorted(self.script):
            if t <= self.trame:
                val = self.script[t]
        return val

    def step(self):
        s = self.s_
        if self.pc == s['video_wait_vsync']:
            self.trame += 1
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            self.cc &= 0xFE
            return
        if self.pc == s['kbd_poll']:
            self.a = 0x1B if self.echap is not None and self.trame >= self.echap else 0
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        super().step()


def carte(fichier=None):
    d = tempfile.mkdtemp()
    image = os.path.join(d, 'carte.img')
    with open(image, 'wb') as f:
        f.truncate(8 * 1024 * 1024)
    core = egofs_core.OSMFS_Core(image)
    old = sys.stdout
    sys.stdout = open(os.devnull, 'w')
    core.format_fs()
    core.mkdir('BIN')
    if fichier is not None:
        chemin = os.path.join(d, 'JOYSTICK.CFG')
        open(chemin, 'wb').write(fichier)
        core.inject_file(chemin, 'BIN/JOYSTICK.CFG', 1, '0000', 0x06)
    sys.stdout.close()
    sys.stdout = old
    return image, core


def lu(core):
    """Le contenu de /BIN/JOYSTICK.CFG sur la carte (None : absent)."""
    for i, f in enumerate(core.list_files()):
        if f['path'].upper() == 'BIN/JOYSTICK.CFG':
            d = tempfile.mkdtemp()
            core.extract_file(f['index'], os.path.join(d, 'x'))
            return open(os.path.join(d, 'x'), 'rb').read()
    return None


def machine(s, image, script, echap=None):
    m = Machine(image, s, script, echap)
    v.installe_bios(m)
    code = open(BIN, 'rb').read()
    m.banks[1][:len(code)] = code
    m.mem[s['current_page']] = 1
    m.page = 1
    return m


def etalonne(cablage, extra=True):
    """Le script d'un étalonnage : pour chaque direction, 10 trames
    lâchées, l'appui (avec un rebond), 10 trames tenues, lâché. extra :
    avant la droite, une diagonale (haut + droite), puis le bit du haut à
    nouveau (déjà pris)."""
    sc, t = {0: 0xFF}, 15                   # (JOYCAL attend d'abord 6 trames lâchées)
    for k, bit in enumerate(cablage):
        if extra and k == 1:
            sc[t] = 0xFF & ~(cablage[0] | bit)      # diagonale : refusée
            t += 12
            sc[t] = 0xFF
            t += 10
            sc[t] = 0xFF & ~cablage[0]              # déjà pris : refusé
            t += 12
            sc[t] = 0xFF
            t += 10
        sc[t] = 0xFF & ~bit                         # rebond
        sc[t + 1] = 0xFF
        sc[t + 2] = 0xFF & ~bit
        t += 14
        sc[t] = 0xFF
        t += 12
    return sc


def lecture(s, a, image, port, ay=True):
    """Joy_Init puis Joy_Lit (adresses de JOYCAL.map) avec le port A donné
    -> (A de Joy_Init, A de Joy_Lit, Z)."""
    m = machine(s, image, {0: port})
    m.ay_present = ay
    v.appelle(m, a['Joy_Init'])
    init = m.a
    v.appelle(m, a['Joy_Lit'])
    return init, m.a, bool(m.cc & 0x04)


def attendu(cablage, appuis):
    """Le port A et la lecture JOY_* pour un ensemble d'appuis (bits 0-4)."""
    port, std = 0xFF, 0
    for k in range(5):
        if appuis >> k & 1:
            port &= ~cablage[k] & 0xFF
            std |= 1 << k
    return port, std


def main():
    s = v.sym()
    a = symboles()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    verifie(a.get('Start') == 0, 'Start à l\'offset 0')

    for nom, cablage in (('la machine', MACHINE), ('miroir', MIROIR)):
        image, core = carte()
        m = machine(s, image, etalonne(cablage, nom == 'la machine'))
        v.appelle(m, 0x0000, 20_000_000)
        txt = m.texte.decode('latin-1').replace('\r', '')
        f = lu(core)
        verifie(f == b'JOY\x01' + bytes(cablage), 'JOYCAL (%s) : /BIN/JOYSTICK.CFG = %s (attendu %s)'
                % (nom, f.hex() if f else None, (b'JOY\x01' + bytes(cablage)).hex()))
        broches = ['IOA%d (J602 broche %d)' % (b.bit_length() - 1, 17 - 2 * (b.bit_length() - 1)) for b in cablage]
        verifie(all(b in txt for b in broches) and 'Etalonnage ecrit' in txt,
                'JOYCAL (%s) : l\'écran nomme chaque bit et sa broche : %s' % (nom, broches))
        if nom == 'la machine':
            verifie('un seul contact' in txt and 'deja pris' in txt,
                    'JOYCAL : une diagonale et un bit déjà pris sont refusés (et redemandés)')
        faux = []
        for app in range(32):
            port, std = attendu(cablage, app)
            init, lit, z = lecture(s, a, image, port)
            if (init, lit, z) != (1, std, std == 0):
                faux.append((app, port, init, lit, z))
        verifie(not faux, 'Joy_Init (A = 1, le fichier) et Joy_Lit sur les 32 combinaisons (%s)%s'
                % (nom, '' if not faux else ' FAUX : %s' % faux[:3]))


    # sans fichier, ou un fichier faux : le brochage de la Clouris
    for nom, fic in (('sans fichier', None), ('taille', b'JOY\x01\x10\x08\x04\x01\x20\x00'),
                     ('en-tête', b'JOI\x01\x10\x08\x04\x01\x20'), ('deux égaux', b'JOY\x01\x10\x10\x04\x01\x20'),
                     ('deux bits', b'JOY\x01\x30\x08\x04\x01\x20'), ('version', b'JOY\x02\x10\x08\x04\x01\x20')):
        image, core = carte(fic)
        faux = []
        for app in range(32):
            port, std = attendu(CLOURIS, app)
            init, lit, z = lecture(s, a, image, port)
            if (init, lit, z) != (0, std, std == 0):
                faux.append((app, port, init, lit, z))
        verifie(not faux, 'fichier %s : le brochage de la Clouris (A = 0)%s' % (nom, '' if not faux else ' FAUX : %s' % faux[:3]))

    # sans AY
    image, core = carte(b'JOY\x01' + bytes(MACHINE))
    rien = all(lecture(s, a, image, port, ay=False)[1:] == (0, True) for port in (0x00, 0x50, 0xFF))
    verifie(rien, 'sans AY (bus vide) : Joy_Lit ne rend jamais rien')
    m = machine(s, image, {0: 0x00})
    m.ay_present = False
    v.appelle(m, 0x0000, 5_000_000)
    verifie('Pas d\'AY' in m.texte.decode('latin-1') and lu(core) == b'JOY\x01' + bytes(MACHINE),
            'JOYCAL sans AY : le dit, ne touche pas au fichier')

    # Échap au milieu : l'ancien fichier reste
    ancien = b'JOY\x01' + bytes(MIROIR)
    image, core = carte(ancien)
    sc = etalonne(MACHINE, False)
    m = machine(s, image, sc, echap=45)
    v.appelle(m, 0x0000, 20_000_000)
    verifie('Abandon' in m.texte.decode('latin-1') and lu(core) == ancien,
            'Échap au milieu : abandon, l\'ancien /BIN/JOYSTICK.CFG reste')

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
