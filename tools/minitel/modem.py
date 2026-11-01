#!/usr/bin/env python3
# ===================================================================
# modem.py - Un modem Hayes simulé entre OSM39 et les serveurs Minitel
# ===================================================================
# La carte (application MINITEL d'OSM-VISION) parle à ce programme par la
# liaison série comme à un modem : elle compose un numéro (ATDT3615), le
# modem « décroche » vers un serveur Minitel d'Internet, puis relaie les
# octets dans les deux sens jusqu'au raccrochage.
#
#   python3 tools/minitel/modem.py                  # /dev/ttyUSB0, 115200 bauds
#   python3 tools/minitel/modem.py --port /dev/ttyUSB1 --vitesse 115200
#   python3 tools/minitel/modem.py --debit 4800     # pages plus rapides
#   python3 tools/minitel/modem.py --pty            # pseudo-terminal (essais)
#   python3 tools/minitel/modem.py --capture x.vdt  # garde le flux des serveurs
#
# Vitesse : 115200 bauds, celle que MINITEL donne à l'ACIA (E/16), la même
# qu'avec un vrai modem V.23 (Olitec Speed'Com 2000). Une vitesse hors norme
# (--vitesse 28800, E/64) passe par l'ioctl termios2 (BOTHER).
# Débit : la liaison va à 115200 bauds, mais la carte ne peut pas
# afficher aussi vite (elle n'écrit la vidéo que pendant le retour de
# trame). Le modem dose donc ce qu'il envoie vers la carte : --debit en
# bauds Minitel (1200 par défaut, comme un vrai Minitel : ~120 octets/s).
#
# MUET tant qu'on ne lui parle pas : la console du BIOS écrit tout ce
# qu'elle affiche sur la liaison série (bannière de démarrage...) ; un
# écho, ou un « ERROR », reviendrait pendant la seconde d'attente du
# démarrage et ouvrirait le SECOURS. Donc : pas d'écho par défaut (ATE1
# le remet), et une ligne qui ne commence pas par AT est ignorée.
# Commandes (terminées par CR) : AT, ATZ, ATE0/ATE1 (écho), ATI, ATH,
# ATO (retour en ligne), ATD/ATDT/ATDP <numéro>, A/ (refaire) ; B, M, L,
# &D, &C... (réglages d'un vrai modem : MINITEL envoie ATE0&D0B2M1S91=6DT)
# sont acceptés sans effet, comme les virgules (pauses) du numéro. En ligne,
# « +++ » entouré d'une seconde de silence repasse en mode commande.
# Réponses : OK, CONNECT 1200, NO CARRIER, ERROR, BUSY.
#
# Annuaire (--annuaire fichier : une ligne « numéro adresse ») :
#   3615, 3611 ... -> MiniPavi, tcp://go.minipavi.fr:516
#   0972101721     -> MiniPavi aussi (son numéro de téléphone : MINITEL
#                     compose celui-ci quand on tape 3615)
#   3617           -> 3617 PAVI, wss://www.3617.fr/ws (module websockets)
#   0              -> serveur de TEST local, sans Internet (une page fixe)
#   une adresse tcp://hôte:port ou ws(s)://... composée telle quelle
# Bibliothèque standard seule (termios, asyncio, socket) ; ws/wss demande
# le module websockets.
# ===================================================================
import argparse
import asyncio
import fcntl
import struct
import os
import sys
import termios
import time
import tty

ANNUAIRE = {
    '3615': 'tcp://go.minipavi.fr:516',
    '3611': 'tcp://go.minipavi.fr:516',
    '3614': 'tcp://go.minipavi.fr:516',
    '3616': 'tcp://go.minipavi.fr:516',
    '3617': 'wss://www.3617.fr/ws',
    '0972101721': 'tcp://go.minipavi.fr:516',
    '0': 'test:',
}

VITESSES = {1200: termios.B1200, 2400: termios.B2400, 4800: termios.B4800, 9600: termios.B9600,
            19200: termios.B19200, 38400: termios.B38400, 57600: termios.B57600, 115200: termios.B115200}


def page_de_test():
    """Une page Vidéotex fixe : de quoi essayer l'affichage sans Internet."""
    ESC, US, FF, SO, SI = b'\x1b', b'\x1f', b'\x0c', b'\x0e', b'\x0f'

    def pos(lig, col):
        return US + bytes([0x40 + lig, 0x40 + col])
    p = FF
    p += pos(1, 1) + ESC + b'\x5d' + b' OSM39 ' + ESC + b'\x5c' + b' Minitel de test (modem.py) '
    p += pos(3, 1) + ESC + b'\x41' + b'Rouge ' + ESC + b'\x42' + b'Vert ' + ESC + b'\x43' + b'Jaune '
    p += ESC + b'\x44' + b'Bleu ' + ESC + b'\x45' + b'Magenta ' + ESC + b'\x46' + b'Cyan ' + ESC + b'\x47' + b'Blanc'
    p += pos(5, 1) + b'Accents : ' + b'\x19\x42e\x19\x41a\x19\x43o\x19\x4bc\x19\x48i'
    p += pos(7, 1) + SO
    for c in range(0x20, 0x40):
        p += bytes([c])
    p += pos(8, 1)
    for c in range(0x60, 0x80):
        p += bytes([c])
    p += SI + pos(10, 1) + b'Repetition : ' + b'*\x12\x49'
    p += pos(12, 1) + ESC + b'\x54' + b' fond bleu ' + ESC + b'\x50'
    p += pos(24, 1) + b'Tapez un texte puis ENVOI'
    p += pos(22, 1) + b'> \x11'                  # CON : le curseur attend la saisie
    return p


class Modem:
    def __init__(self, fd, debit, annuaire, journal, capture=None):
        self.capture = capture                      # fichier : le flux du serveur, tel quel
        self.fd = fd
        self.debit = max(1, debit // 10)            # octets par seconde
        self.annuaire = annuaire
        self.journal = journal
        self.echo = False                       # voir l'en-tête : modem muet
        self.ligne = b''
        self.derniere = b''
        self.en_ligne = False
        self.connexion = None                       # (lecteur, écrivain, fermer)
        self.a_envoyer = bytearray()                # vers la carte, dosé
        self.dernier_octet = 0.0
        self.plus = 0                               # « +++ » en cours
        self.debut_plus = 0.0

    def log(self, *a):
        if self.journal:
            print('[modem]', *a, file=sys.stderr, flush=True)

    # --- vers la carte ---
    def vers_carte(self, data, dose=True):
        if dose and self.capture:
            self.capture.write(data)
            self.capture.flush()
        if dose:
            self.a_envoyer += data
        else:
            os.write(self.fd, data)

    def reponse(self, texte):
        self.vers_carte(b'\r\n' + texte.encode('ascii') + b'\r\n', dose=False)

    async def doseur(self):
        """Envoie a_envoyer vers la carte au débit choisi, par tranches de 20 ms."""
        tranche = max(1, self.debit // 50)
        while True:
            if self.a_envoyer:
                bloc = bytes(self.a_envoyer[:tranche])
                del self.a_envoyer[:tranche]
                os.write(self.fd, bloc)
            await asyncio.sleep(0.02)

    # --- depuis la carte ---
    def bascule_commande(self):
        self.plus = 0
        self.en_ligne = False
        self.log('+++ : mode commande')
        self.reponse('OK')

    def recu(self, data):
        maintenant = time.monotonic()
        if self.en_ligne:
            self.log('carte ->', data.hex(' '), repr(data))   # ce que le clavier envoie
        for o in data:
            # « +++ » suivi d'une seconde de silence : la commande qui suit
            # (ATH) ne doit pas partir au serveur, même si veille() n'a pas
            # encore vu passer la seconde (elle ne regarde que tous les 0,1 s)
            if self.en_ligne and self.plus == 3 and maintenant - self.debut_plus >= 1.0:
                self.bascule_commande()
            if self.en_ligne:
                # +++ : seconde de garde avant, trois '+', seconde après (vérifiée par veille())
                if o == ord('+') and (self.plus or maintenant - self.dernier_octet >= 1.0):
                    self.plus += 1
                    self.debut_plus = maintenant
                    if self.plus <= 3:
                        self.dernier_octet = maintenant
                        continue
                if self.plus:
                    self.connexion_envoie(b'+' * self.plus)
                    self.plus = 0
                self.connexion_envoie(bytes([o]))
            else:
                self.commande_octet(o)
            self.dernier_octet = maintenant

    async def veille(self):
        while True:
            await asyncio.sleep(0.1)
            if self.en_ligne and self.plus == 3 and time.monotonic() - self.debut_plus >= 1.0:
                self.bascule_commande()

    def connexion_envoie(self, data):
        if self.connexion:                          # les touches ont leur parité au bit 7
            self.connexion[1](bytes(o & 0x7F for o in data))

    def commande_octet(self, o):
        o &= 0x7F                                   # MINITEL envoie l'AT avec sa parité
        if self.echo:
            os.write(self.fd, bytes([o]))
        if o in (8, 127):
            self.ligne = self.ligne[:-1]
            return
        if o == 13:
            ligne, self.ligne = self.ligne.strip(), b''
            asyncio.get_event_loop().create_task(self.commande(ligne))
            return
        if o == ord('/') and self.ligne.upper() == b'A':
            self.ligne = b''
            asyncio.get_event_loop().create_task(self.commande(self.derniere))
            return
        if 32 <= o < 127 and len(self.ligne) < 80:
            self.ligne += bytes([o])

    async def commande(self, ligne):
        u = ligne.upper().replace(b' ', b'')
        if not u:
            return
        if not u.startswith(b'AT'):
            return                                  # la console de la carte : on se tait
        self.derniere = ligne
        self.log('commande', ligne.decode('latin-1'))
        # ATE0DT3615 : les réglages d'abord, puis D et le numéro (pris dans
        # la ligne d'origine : une adresse tcp:// garde sa casse)
        brut = ligne.strip()[2:]
        numero = None
        i = brut.upper().find(b'D')
        while i > 0 and brut[i - 1:i] == b'&':        # &D0 : un réglage, pas D
            i = brut.upper().find(b'D', i + 1)
        if i >= 0:
            numero = brut[i + 1:].lstrip(b'TtPp').decode('latin-1').strip()
            u = u[:2 + len(brut[:i].replace(b' ', b''))]
        reste = u[2:]
        while reste:
            c, reste = reste[:1], reste[1:]
            if c == b'Z':
                self.echo = False
                await self.raccroche()
            elif c == b'E':
                self.echo = reste[:1] != b'0'
                reste = reste[1:]
            elif c == b'H':
                reste = reste[1:] if reste[:1] in (b'0', b'1') else reste
                await self.raccroche()
            elif c == b'O':
                if self.connexion:
                    self.en_ligne = True
                    self.reponse('CONNECT 1200')
                    return
                self.reponse('NO CARRIER')
                return
            elif c == b'I':
                self.reponse('OSM39 modem Minitel (tools/minitel/modem.py)')
            elif c in b'QVXS&LMBCDK0123456789=?' and c:     # S91=6 : niveau d'émission
                continue                            # réglages sans effet ici
            else:
                self.reponse('ERROR')
                return
        if numero is not None:
            await self.compose(numero)
            return
        self.reponse('OK')

    async def compose(self, numero):
        cle = numero.replace(' ', '').replace('.', '').replace(',', '')
        adresse = self.annuaire.get(cle) or self.annuaire.get(cle[:4]) or (numero if '://' in numero or numero.startswith('test') else None)
        if not adresse:
            self.reponse('NO CARRIER')
            return
        await self.raccroche(silencieux=True)
        self.log('compose', numero, '->', adresse)
        try:
            self.connexion = await ouvre(adresse, self)
        except Exception as e:                      # noqa: BLE001 (réseau : tout échec = pas de porteuse)
            self.log('échec', e)
            self.reponse('NO CARRIER')
            return
        self.en_ligne = True
        self.reponse('CONNECT 1200')

    async def raccroche(self, silencieux=False):
        if self.connexion:
            try:
                self.connexion[2]()
            except Exception:                       # noqa: BLE001
                pass
        self.connexion = None
        self.en_ligne = False
        self.a_envoyer.clear()

    def perdu(self):
        """Le serveur a raccroché."""
        if self.connexion:
            self.connexion = None
            self.en_ligne = False
            self.log('le serveur a raccroché')
            self.reponse('NO CARRIER')


async def ouvre(adresse, modem):
    """Ouvre la connexion ; rend (None, envoie(octets), ferme())."""
    if adresse.startswith('test'):
        modem.vers_carte(page_de_test())

        tampon = bytearray()                        # les octets arrivent un par un

        def envoie(data):
            tampon.extend(data)
            if tampon.endswith(b'\x13\x41'):          # ENVOI : on répond
                texte = bytes(tampon[:-2]).decode('latin-1')
                tampon.clear()
                modem.vers_carte(b'\x1f\x56\x41\x18Recu : ' + texte[-30:].encode('latin-1'))
        return (None, envoie, lambda: None)
    if adresse.startswith('tcp://'):
        hote, port = adresse[6:].rsplit(':', 1)
        lecteur, ecrivain = await asyncio.open_connection(hote, int(port))

        async def lit():
            while True:
                data = await lecteur.read(1024)
                if not data:
                    modem.perdu()
                    return
                modem.vers_carte(bytes(o & 0x7F for o in data))
        tache = asyncio.get_event_loop().create_task(lit())
        return (None, lambda data: ecrivain.write(data), lambda: (tache.cancel(), ecrivain.close()))
    if adresse.startswith(('ws://', 'wss://')):
        import websockets                           # noqa: PLC0415 (seulement si on en a besoin)
        ws = await websockets.connect(adresse)

        async def lit_ws():
            try:
                async for msg in ws:
                    data = msg.encode('latin-1') if isinstance(msg, str) else msg
                    modem.vers_carte(bytes(o & 0x7F for o in data))
            except Exception:                       # noqa: BLE001
                pass
            modem.perdu()
        tache = asyncio.get_event_loop().create_task(lit_ws())

        def envoie_ws(data):
            asyncio.get_event_loop().create_task(ws.send(data.decode('latin-1')))
        return (None, envoie_ws, lambda: (tache.cancel(), asyncio.get_event_loop().create_task(ws.close())))
    raise ValueError('adresse inconnue : %s' % adresse)


# struct termios2 (Linux) : 4 drapeaux, c_line, c_cc[19], ispeed, ospeed
TCGETS2, TCSETS2, BOTHER, CBAUD = 0x802C542A, 0x402C542B, 0o010000, 0o010017
TERMIOS2 = '=IIIIB19sII'


def vitesse_libre(fd, vitesse):
    """Vitesse quelconque (28800...) : termios2 avec BOTHER."""
    t = list(struct.unpack(TERMIOS2, fcntl.ioctl(fd, TCGETS2, bytes(struct.calcsize(TERMIOS2)))))
    t[2] = (t[2] & ~CBAUD) | BOTHER
    t[6] = t[7] = vitesse
    fcntl.ioctl(fd, TCSETS2, struct.pack(TERMIOS2, *t))
    lu = struct.unpack(TERMIOS2, fcntl.ioctl(fd, TCGETS2, bytes(struct.calcsize(TERMIOS2))))
    return lu[7]


def ouvre_port(chemin, vitesse):
    fd = os.open(chemin, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    att = termios.tcgetattr(fd)
    if vitesse in VITESSES:
        att[4] = att[5] = VITESSES[vitesse]         # ispeed, ospeed
    att[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    att[2] |= termios.CS8 | termios.CLOCAL | termios.CREAD
    termios.tcsetattr(fd, termios.TCSANOW, att)
    if vitesse not in VITESSES:
        obtenue = vitesse_libre(fd, vitesse)
        if obtenue != vitesse:
            print('attention : le pilote donne %d bauds au lieu de %d' % (obtenue, vitesse), flush=True)
    return fd


def main():
    ap = argparse.ArgumentParser(description='Modem Hayes simulé pour l\'application MINITEL d\'OSM39')
    ap.add_argument('--port', default='/dev/ttyUSB0')
    ap.add_argument('--vitesse', type=int, default=115200, help='bauds de la liaison (115200 : ACIA E/16)')
    ap.add_argument('--debit', type=int, default=1200, help='bauds Minitel vers la carte (1200)')
    ap.add_argument('--pty', action='store_true', help='pseudo-terminal au lieu d\'un port (essais)')
    ap.add_argument('--annuaire', help='fichier « numéro adresse » en plus de l\'annuaire intégré')
    ap.add_argument('--muet', action='store_true', help='pas de journal sur la sortie d\'erreur')
    ap.add_argument('--capture', help='enregistre le flux reçu des serveurs (rejouable : videotex.py --png)')
    a = ap.parse_args()

    annuaire = dict(ANNUAIRE)
    if a.annuaire:
        for ligne in open(a.annuaire, encoding='utf-8'):
            ligne = ligne.split('#')[0].split()
            if len(ligne) == 2:
                annuaire[ligne[0]] = ligne[1]

    if a.pty:
        maitre, esclave = os.openpty()
        tty.setraw(maitre)
        print('pseudo-terminal :', os.ttyname(esclave), flush=True)
        fd = maitre
    else:
        fd = ouvre_port(a.port, a.vitesse)
        print('modem prêt sur %s à %d bauds, débit Minitel %d bauds' % (a.port, a.vitesse, a.debit), flush=True)

    modem = Modem(fd, a.debit, annuaire, not a.muet, open(a.capture, 'ab') if a.capture else None)
    boucle = asyncio.new_event_loop()
    asyncio.set_event_loop(boucle)

    def lisible():
        try:
            data = os.read(fd, 1024)
        except BlockingIOError:
            return
        if data:
            modem.recu(data)
    boucle.add_reader(fd, lisible)
    boucle.create_task(modem.doseur())
    boucle.create_task(modem.veille())
    try:
        boucle.run_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
