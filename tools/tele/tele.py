#!/usr/bin/env python3
# ===================================================================
# tele.py - Côté PC de la télécommande TELE (cmd/tele.asm)
# ===================================================================
# Sur la machine : lancer TELE dans le Terminal (Echap pour en sortir).
# Ici : lire, écrire la mémoire, appeler une routine, par la liaison
# série (115200 bauds 8N1, /dev/ttyUSB0). Protocole : voir cmd/tele.asm.
#
#   python3 tools/tele/tele.py ping
#   python3 tools/tele/tele.py lit [page:]aaaa n
#   python3 tools/tele/tele.py ecrit [page:]aaaa octets-hexa...
#   python3 tools/tele/tele.py charge fichier.bin [page:]aaaa
#   python3 tools/tele/tele.py appel aaaa [A=xx] [B=xx] [X=xxxx] [Y=xxxx] [U=xxxx]
#   python3 tools/tele/tele.py fin          (TELE rend la main)
# Page par défaut : 1 (celle de TELE ; le code d'essai va de $1000 à $7FFF).
# Bibliothèque standard seule ; la classe Tele sert aussi aux scripts
# d'essai et à test/verifie_tele.py (liaison simulée).
# ===================================================================
import os
import select
import sys
import termios
import time
import tty

PORT = '/dev/ttyUSB0'
PAQUET = 64                     # octets par trame 'W' (l'anneau de la NMI fait 256)


def trame(cmd, donnees=b''):
    donnees = bytes(donnees)
    if len(donnees) > 255:
        raise ValueError('trame trop longue')
    corps = bytes([ord(cmd), len(donnees)]) + donnees
    return b'T' + corps + bytes([sum(corps) & 255])


class Liaison:
    """Le port série, en mode brut."""

    def __init__(self, chemin=PORT, vitesse=termios.B115200):
        self.fd = os.open(chemin, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        att = termios.tcgetattr(self.fd)
        att[4] = att[5] = vitesse
        att[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
        att[2] |= termios.CS8 | termios.CLOCAL | termios.CREAD
        termios.tcsetattr(self.fd, termios.TCSANOW, att)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def ecrit(self, octets):
        reste = memoryview(bytes(octets))
        while reste:
            select.select([], [self.fd], [], 1.0)
            n = os.write(self.fd, reste)
            reste = reste[n:]
        termios.tcdrain(self.fd)

    def lit(self, n, delai):
        """Jusqu'à n octets ; moins si rien n'arrive pendant delai secondes."""
        out = bytearray()
        fin = time.monotonic() + delai
        while len(out) < n:
            reste = fin - time.monotonic()
            if reste <= 0:
                break
            r, _, _ = select.select([self.fd], [], [], reste)
            if r:
                out += os.read(self.fd, n - len(out))
        return bytes(out)

    def vide(self):
        termios.tcflush(self.fd, termios.TCIFLUSH)


class ErreurTele(Exception):
    pass


class Tele:
    def __init__(self, liaison, delai=2.0):
        self.l = liaison
        self.delai = delai
        self.reprises = 0           # trames rejouées (diagnostic de la ligne)

    def demande(self, cmd, donnees, n_reponse, delai=None):
        """Une trame et sa réponse. P, R et W se rejouent sans danger : en
        cas de silence ou de somme refusée (un octet perdu sur la ligne :
        TELE a lu la trame suivante comme la fin de la précédente, puis se
        recale), on réessaie deux fois. Jamais C (l'appel serait refait)."""
        essais = 3 if cmd in 'PRW' else 1
        for k in range(essais):
            try:
                return self._demande(cmd, donnees, n_reponse, delai)
            except ErreurTele:
                if k == essais - 1:
                    raise
                self.reprises += 1

    def _demande(self, cmd, donnees, n_reponse, delai=None):
        self.l.vide()
        self.l.ecrit(trame(cmd, donnees))
        d = self.delai if delai is None else delai
        tete = self.l.lit(1, d)
        if not tete:
            raise ErreurTele('pas de réponse à %s (TELE lancé ?)' % cmd)
        if tete == b'E':
            code = self.l.lit(1, d)
            raise ErreurTele('TELE refuse %s : code %s' % (cmd, code.hex() or '?'))
        if tete != b'K':
            raise ErreurTele('réponse inattendue à %s : %s' % (cmd, tete.hex()))
        corps = self.l.lit(n_reponse + 1, d)
        if len(corps) != n_reponse + 1:
            raise ErreurTele('réponse courte à %s : %d octets sur %d' % (cmd, len(corps), n_reponse + 1))
        if sum(corps[:-1]) & 255 != corps[-1]:
            raise ErreurTele('somme fausse dans la réponse à %s' % cmd)
        return corps[:-1]

    def ping(self):
        return self.demande('P', b'', 5).decode('ascii')

    def lit(self, page, adr, n):
        out = bytearray()
        while n:
            k = min(n, 255)
            out += self.demande('R', bytes([page, adr >> 8, adr & 255, k]), k)
            adr, n = adr + k, n - k
        return bytes(out)

    def ecrit(self, page, adr, octets):
        octets = bytes(octets)
        for i in range(0, len(octets), PAQUET):
            bout = octets[i:i + PAQUET]
            self.demande('W', bytes([page, (adr + i) >> 8, (adr + i) & 255]) + bout, 0)

    def appel(self, adr, a=0, b=0, x=0, y=0, u=0, delai=10.0):
        """JSR adr (page 1 ou >= $8000), registres chargés ; rend les registres."""
        d = bytes([adr >> 8, adr & 255, a, b, x >> 8, x & 255, y >> 8, y & 255, u >> 8, u & 255])
        r = self.demande('C', d, 11, delai)
        return {'cc': r[0], 'a': r[1], 'b': r[2], 'w': (r[3] << 8) | r[4],
                'x': (r[5] << 8) | r[6], 'y': (r[7] << 8) | r[8], 'u': (r[9] << 8) | r[10],
                'c': r[0] & 1}

    def fin(self):
        self.demande('Q', b'', 0)


def adresse(txt):
    if ':' in txt:
        p, a = txt.split(':')
        return int(p, 16), int(a, 16)
    return 1, int(txt, 16)


def main():
    args = sys.argv[1:]
    port = PORT
    if args[:1] == ['--port']:
        port, args = args[1], args[2:]
    if not args:
        print(__doc__ if __doc__ else 'voir l\'en-tête de tools/tele/tele.py')
        return 2
    t = Tele(Liaison(port))
    c = args[0]
    try:
        # Sans TELE en face, le BIOS n'est pas en mode brut : un octet $01
        # (la page 1 d'une trame W ou R) y est un Ctrl+A et ouvre SECOURS
        # par-dessus l'écran. Le ping, lui, ne contient jamais $01.
        if c != 'ping':
            t.ping()
        if c == 'ping':
            print(t.ping())
        elif c == 'lit':
            page, adr = adresse(args[1])
            data = t.lit(page, adr, int(args[2], 0))
            for i in range(0, len(data), 16):
                print('%d:%04X  %s' % (page, adr + i, ' '.join('%02X' % o for o in data[i:i + 16])))
        elif c == 'ecrit':
            page, adr = adresse(args[1])
            t.ecrit(page, adr, bytes(int(o, 16) for o in args[2:]))
        elif c == 'charge':
            page, adr = adresse(args[2])
            data = open(args[1], 'rb').read()
            t.ecrit(page, adr, data)
            relu = t.lit(page, adr, len(data))
            print('%d octets en %d:%04X, relus %s' % (len(data), page, adr, 'identiques' if relu == data else 'DIFFÉRENTS'))
        elif c == 'appel':
            reg = {'a': 0, 'b': 0, 'x': 0, 'y': 0, 'u': 0}
            for a in args[2:]:
                k, v = a.split('=')
                reg[k.lower()] = int(v, 16)
            r = t.appel(int(args[1], 16), **reg)
            print('CC=%02X A=%02X B=%02X W=%04X X=%04X Y=%04X U=%04X' % (
                r['cc'], r['a'], r['b'], r['w'], r['x'], r['y'], r['u']))
        elif c == 'fin':
            t.fin()
            print('TELE a rendu la main')
        else:
            print('commande inconnue : %s' % c)
            return 2
    except ErreurTele as e:
        print('ERREUR : %s' % e)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
