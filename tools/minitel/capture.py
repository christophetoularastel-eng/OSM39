#!/usr/bin/env python3
# ===================================================================
# capture.py - Appelle MiniPavi par le vrai modem, depuis le PC, comme
# apps/minitel.asm, et enregistre les octets reçus
# ===================================================================
# Le modem branché sur le PC (/dev/ttyUSB0, 115200 bauds) à la place de
# la carte. Même chaîne d'appel que MINITEL (ATE0&D0B2M1S91=6DT0972101721,,,,,),
# octets émis en 7 bits + parité paire comme Envoie_P. Tout ce qui arrive
# est horodaté, affiché en hexadécimal et en texte (bit 7 retiré), et
# enregistré brut. Puis raccroche : 1,5 s de silence, +++, 1,5 s, ATH.
#   python3 tools/minitel/capture.py [-o capture.vdt] [--duree 60]
#                                    [--numero 0972101721,,,,,]
#                                    [--repond HEX]  (après chaque salve)
#                                    [--terminal]
# --repond : octets envoyés après chaque salve reçue (ex. une réponse à
# l'ENQROM), pour voir si le serveur continue.
# --terminal : après CONNECT, le PC fait ce que fait MINITEL (classe
# Terminal de videotex.py : réponses au serveur, PCE, NACK renvoyé après
# 1,12 s) ; chaque octet émis est montré (->), l'état de la PCE aussi.
# ===================================================================
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tele'))
from tele import Liaison        # noqa: E402  port série brut, 115200
import videotex                 # noqa: E402


def parite_paire(octets):
    return bytes(o | 0x80 if bin(o & 0x7F).count('1') & 1 else o & 0x7F for o in octets)


def montre(t0, donnees):
    for i in range(0, len(donnees), 16):
        bout = donnees[i:i + 16]
        print('%6.2f  %-48s %s' % (time.monotonic() - t0, ' '.join('%02X' % o for o in bout),
                                   ''.join(chr(o & 0x7F) if 32 <= (o & 0x7F) < 127 else '.' for o in bout)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('-o', default='capture.vdt')
    p.add_argument('--duree', type=float, default=60)
    p.add_argument('--numero', default='0972101721,,,,,')
    p.add_argument('--repond', help='octets (hexa) envoyés après chaque salve')
    p.add_argument('--port', default='/dev/ttyUSB0')
    p.add_argument('--terminal', action='store_true')
    p.add_argument('--status', default='44', help='octet de status de la réponse à START (hexa)')
    p.add_argument('--avant', default='S91=6', help='réglages AT ajoutés avant D (comme MINITEL : S91=6)')
    a = p.parse_args()
    l = Liaison(a.port)
    tout = bytearray()
    t0 = time.monotonic()
    appel = ('ATE0&D0B2M1' + a.avant + 'DT' + a.numero + '\r').encode('ascii')
    print('-> %s' % appel.decode().strip())
    l.ecrit(parite_paire(appel))
    fin = t0 + a.duree
    term, connecte, nack_t = None, False, None
    while time.monotonic() < fin:
        d = l.lit(512, 0.3)
        if a.terminal and term:
            if term.etat == 2 and nack_t and time.monotonic() - nack_t > 1.12:
                term.envoie([videotex.NACK, 0x40 | term.num])       # Pce_Garde
                nack_t = None
            if term.envoi:
                print('%6.2f  -> %s   (pce %d, état %d, bloc %d)' % (time.monotonic() - t0, term.envoi.hex(' '),
                                                                    term.pce, term.etat, term.num))
                if term.etat == 2:
                    nack_t = time.monotonic()
                l.ecrit(bytes(term.envoi))
                term.envoi = bytearray()
        if d:
            tout += d
            montre(t0, d)
            if a.terminal:
                if not connecte:
                    k = bytes(o & 0x7F for o in tout).find(b'CONNECT')
                    if k >= 0 and b'\n' in bytes(o & 0x7F for o in tout[k:]):
                        connecte = True
                        term = videotex.Terminal()
                        term.status_start = int(a.status, 16)
                        reste = tout[k:]
                        reste = reste[bytes(o & 0x7F for o in reste).index(b'\n') + 1:]
                        for o in reste:
                            term.octet(o)
                else:
                    for o in d:
                        term.octet(o)
                continue
            if a.repond and b'CONNECT' not in bytes(o & 0x7F for o in d):
                l.ecrit(parite_paire(bytes.fromhex(a.repond)))
                print('%6.2f  -> %s' % (time.monotonic() - t0, a.repond))
    open(a.o, 'wb').write(tout)
    if term:
        e = term.ecran
        print('écran du terminal :')
        for r in range(videotex.LIGNES):
            ligne = ''.join(chr(e.g[r * 40 + c]) if e.t[r * 40 + c] == 0 and 32 <= e.g[r * 40 + c] < 127 else
                            ('#' if e.t[r * 40 + c] else ' ') for c in range(40))
            if ligne.strip():
                print('  %2d |%s|' % (r, ligne))
    print('%d octets dans %s ; raccroche' % (len(tout), a.o))
    time.sleep(1.5)
    l.ecrit(b'+++')
    time.sleep(1.5)
    l.ecrit(parite_paire(b'ATH\r'))
    montre(t0, l.lit(64, 2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
