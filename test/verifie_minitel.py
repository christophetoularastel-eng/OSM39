#!/usr/bin/env python3
# ===================================================================
# verifie_minitel.py - Le décodeur Vidéotex de apps/MINITEL = le modèle
# ===================================================================
# Le VRAI binaire apps/MINITEL (page 1, $0000) tourne dans la machine de
# verifie_fs.py : Vt_Init, puis Vt_Octet pour chaque octet d'un flux.
# Son écran logique (LG, LT, LA : 40 x 25 cases, code, genre, attribut) et
# sa position (Lig, Col) doivent être, octet pour octet, ceux du modèle
# tools/minitel/videotex.py (classe Ecran), à intervalles réguliers.
# Puis l'application entière : la VRAM doit être cellules40 (fenêtre) ou
# cellules80 (plein écran, Ctrl+F) du modèle, et le bureau revenir.
# Flux : la page d'accueil de MiniPavi (capture réelle), la page d'essai
# de tools/minitel/modem.py, et des flux aléatoires (graine fixe) qui
# insistent sur les séquences : ESC, US, REP, SS2, SO/SI, CAN, PRO...
# Ils passent par Term_Octet (classe Terminal) : la couche PCE et les
# réponses au serveur, dont les octets émis sont comparés aussi. Flux PCE :
# blocs_pce() du modèle, propres, avec un bloc abîmé ou un octet perdu
# (NACK puis SYN SYN), STOP, STATUS ; et l'appel réel de MiniPavi par
# téléphone (minipavi_pce.vdt : START répété, blocs, premier bloc abîmé),
# dont les 75 blocs entiers doivent avoir le CRC de crc7().
# Application : le modem répond avec la parité de l'appel (comme le vrai,
# Olitec) ; « 3615 » joue un serveur comme MiniPavi : START toutes les
# 3 s jusqu'à la réponse, ENQROM, blocs PCE dont un abîmé, reprise sur
# NACK.
# ===================================================================
import os
import random
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'minitel'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import videotex                 # noqa: E402
import modem                    # noqa: E402

BIN = os.path.join(RACINE, 'apps', 'MINITEL')
MAP = os.path.join(RACINE, 'apps', 'MINITEL.map')
HW = dict((n, int(a, 16)) for n, a in re.findall(
    r'^(\w+):?\s+equ\s+\$([0-9A-Fa-f]+)', open(os.path.join(RACINE, 'bios', 'hardware.inc')).read(), re.M | re.I))
POINT = 97                      # comparaison tous les POINT octets


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


def flux_aleatoire(graine, n):
    r = random.Random(graine)
    f = bytearray()
    while len(f) < n:
        t = r.random()
        if t < 0.25:
            f += bytes(r.randrange(0x20, 0x80) for _ in range(r.randrange(1, 12)))
        elif t < 0.35:
            f += bytes([0x1B, r.choice([r.randrange(0x40, 0x60), r.randrange(0x20, 0x40), 0x5B, 0x23])])
        elif t < 0.45:
            f += bytes([0x1F, r.randrange(0x3E, 0x5C), r.randrange(0x3F, 0x6B)])
        elif t < 0.5:
            f += bytes([0x12, r.randrange(0x40, 0x80)])
        elif t < 0.58:
            f += bytes([0x19, r.choice([0x41, 0x42, 0x43, 0x48, 0x4B, r.randrange(0x20, 0x80)]),
                        r.choice(b'aeiouAEIOUcCxz')])
        elif t < 0.68:
            f += bytes([r.choice([0x0E, 0x0F])])
        elif t < 0.85:
            f += bytes([r.choice([0x08, 0x09, 0x0A, 0x0B, 0x0D, 0x18, 0x1E, 0x13, 0x00, 0x07, 0x11, 0x14])])
        elif t < 0.86:
            f += b'\x0c'
        else:
            f += bytes([r.randrange(256)])
    return bytes(f[:n])


# --- L'application entière : un modem et un clavier simulés ---
ENTREE, ECHAP, RETARR, CTRL_F = 0x0D, 0x1B, 0x08, 0x06
KEY_UP, KEY_HOME = 0x80, 0x84
CONNECT = b'\r\nCONNECT 75/1200\r\n'
START_PCE = b'\x1b\x3a\x69\x44'


def avec_parite(octets):                # le modem répond comme on lui a parlé
    return bytes(videotex.parite(o) for o in octets)


class Serveur:
    """MiniPavi par téléphone, vu du modem : START toutes les 180 trames
    tant que le terminal ne répond pas (la première réponse est ignorée), puis les blocs PCE des données
    (le bloc ABIME envoyé une fois avec un bit faux) ; sur NACK, SYN SYN
    40+n et reprise au bloc n."""
    ABIME = 3

    def __init__(self, donnees):
        self.blocs = videotex.blocs_pce(donnees)
        self.pce = False
        self.recu = bytearray()
        self.attente = 0
        self.abime = True
        self.reponses = 0

    def recoit(self, o, envoie):
        self.recu.append(o)
        r = bytes(x & 0x7F for x in self.recu)
        if not self.pce and r.endswith(b'\x1b\x3a\x73\x44'):
            self.reponses += 1
            if self.reponses < 2:               # comme MiniPavi : la première réponse
                return                          # n'est pas prise, START revient
            self.pce = True
            envoie(b''.join(self.donne(0)))
        elif self.pce and len(r) >= 2 and r[-2] == videotex.NACK and r[-1] & 0xF0 == 0x40:
            n = r[-1] & 15
            envoie(avec_parite([videotex.SYN, videotex.SYN, 0x40 | n]) + b''.join(self.donne(n)))

    def donne(self, n):
        out = []
        for k, b in enumerate(self.blocs):
            if k % 16 != n and not out:
                continue
            if k == self.ABIME and self.abime:
                self.abime = False
                b = bytes([b[0] ^ 0x04]) + b[1:]
            out.append(b)
        return out

    def trame(self, envoie):
        if not self.pce:
            self.attente += 1
            if self.attente % 180 == 1:
                envoie(START_PCE)


class Banc(va.MachineAsm):
    """MINITEL en page 1. Clavier : (trames d'attente, touche, contrôle).
    Modem : lit TDR, répond dans l'anneau du BIOS (serie_buf), comme la NMI."""

    def __init__(self, image, s, touches):
        super().__init__(image, s)
        self.touches = list(touches)
        self.trame = 0
        self.prochaine = self.touches[0][0] if self.touches else 0
        self.tx = []                    # (trame, octet) envoyés au modem
        self.ligne = b''
        self.a_recevoir = bytearray()
        self.mem[HW['SR']] = 0x02       # ACIA : émetteur toujours libre
        self.serveur = None
        self.cr = []                    # écritures dans le registre de contrôle
        self.crtc_idx = 0
        self.r10 = []                   # valeurs écrites dans R10 (curseur)

    def wr8(self, a, val):
        if a & 0xFFFF == HW['TDR']:
            self.tx.append((self.trame, val & 0xFF))
            if self.serveur:
                self.serveur.recoit(val & 0xFF, self.a_recevoir.extend)
            self.modem(val & 0xFF)
            return
        if a & 0xFFFF == HW['CR_reg']:          # même adresse que SR (lu)
            self.cr.append(val & 0xFF)
            return
        if a & 0xFFFF == HW['CRTC_RS']:
            self.crtc_idx = val & 0xFF
        elif a & 0xFFFF == HW['CRTC_DATA'] and self.crtc_idx == 10:
            self.r10.append(val & 0xFF)
        super().wr8(a, val)

    def modem(self, o):
        o &= 0x7F                               # l'AT arrive avec sa parité
        if o != 0x0D:
            self.ligne += bytes([o])
            if self.ligne.endswith(b'+++'):
                self.ligne = b''
            return
        l, self.ligne = self.ligne, b''
        l = bytes(o & 0x7F for o in l)
        if l == b'ATE0&D0B2M1S91=6DT0972101721,,,,,':       # 3615 tapé : le numéro de MiniPavi
            self.a_recevoir += avec_parite(CONNECT)
            self.serveur = Serveur(b'\x1b\x39\x7b' + modem.page_de_test())
        elif l == b'ATE0&D0B2M1S91=6DT0':
            self.a_recevoir += avec_parite(CONNECT) + b'\x0cBonjour' + avec_parite(b'\r\nNO CARRIER\r\n')
        elif l == b'ATH':
            self.serveur = None
            self.a_recevoir += avec_parite(b'\r\nOK\r\n')

    def passe_trame(self):
        self.trame += 1
        s = self.s_
        if self.serveur:
            self.serveur.trame(self.a_recevoir.extend)
        for _ in range(12):                     # ~720 octets/s
            if not self.a_recevoir:
                break
            t, q = self.mem[s['serie_tete']], self.mem[s['serie_queue']]
            if (t + 1) & 255 == q:
                break
            self.mem[s['serie_buf'] + t] = self.a_recevoir.pop(0)
            self.mem[s['serie_tete']] = (t + 1) & 255
        self.mem[s['NEW_CODE']] = 1 if self.touches and self.trame >= self.prochaine else 0

    def step(self):
        s, pc = self.s_, self.pc
        if pc == s['kbd_poll']:                 # sans attente : la touche due, ou 0
            self.a = 0
            if self.touches and self.trame >= self.prochaine:
                _, touche, controle = self.touches.pop(0)
                if controle:
                    controle(self)
                self.a = touche
                if self.touches:
                    self.prochaine = self.trame + self.touches[0][0]
            elif not self.touches:
                raise Fini()
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        if pc == s['scan_keyboard']:
            if self.touches and self.trame >= self.prochaine:
                _, touche, controle = self.touches.pop(0)
                if controle:
                    controle(self)
                self.a = touche
                if self.touches:
                    self.prochaine = self.trame + self.touches[0][0]
            elif not self.touches:
                raise Fini()
            else:
                self.a = 0
                self.passe_trame()              # le temps passe pendant l'attente
            self.mem[s['NEW_CODE']] = 0
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        if pc == s['video_wait_vsync']:
            self.passe_trame()
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        super().step()

    def texte_vram(self, rangees=range(30)):
        return '\n'.join(bytes(self.mem[0x8000 + r * 80:0x8000 + r * 80 + 80]).decode('latin-1') for r in rangees)


class Fini(Exception):
    pass


def application(s_app, verifie):
    s = v.sym()
    d = tempfile.mkdtemp()
    c = va.Carte(d)
    vus = {}

    def photo(nom):
        def f(m):
            vus[nom] = (bytes(m.mem[0x8000:0x8000 + 2400]), bytes(m.mem[0x9000:0x9000 + 2400]), m.texte_vram(), m.trame,
                        m.rd16(HW['VRAM_PTR']), m.r10[-1] if m.r10 else None)
        return f
    touches = [
        (5, ENTREE, None),                      # 3615 (prérempli)
        (450, ord('a'), photo('en ligne')),     # 2e START (3 s) pris, puis la page en PCE
        (2, ENTREE, None), (2, 0xE9, None), (2, KEY_HOME, None), (2, KEY_UP, None), (2, RETARR, None),
        (2, CTRL_F, None),                      # plein écran
        (40, CTRL_F, photo('plein')),           # retour en fenêtre
        (40, ECHAP, photo('fenêtre')),          # raccrocher
        (300, RETARR, photo('raccroché')), (1, RETARR, None), (1, RETARR, None), (1, RETARR, None),
        (1, ord('0'), None), (1, ENTREE, None),   # le serveur raccroche
        (120, ENTREE, photo('fin')),
        (10, RETARR, None), (1, ord('9'), None), (1, ord('9'), None), (1, ENTREE, None),  # modem muet
        (1900, ENTREE, photo('muet')),
        (10, ECHAP, None),                      # retour à OSM-VISION
    ]
    m = Banc(c.image, s, touches)
    rom, fin = s['table_function_rom'], s['table_function_rom_end']
    for i in range(fin - rom):
        m.mem[s['table_function_ram'] + i] = m.mem[rom + i]
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 1
    bureau = (bytes((i * 13) & 255 for i in range(2000)), bytes((i * 7 + 3) & 255 for i in range(2000)))
    m.mem[0x8000:0x8000 + 2000], m.mem[0x9000:0x9000 + 2000] = bureau
    barre = bytes((i * 7) & 255 for i in range(400))
    m.mem[0x8000 + 2000:0x8000 + 2400] = barre
    m.mem[0x9000 + 2000:0x9000 + 2400] = barre[::-1]
    code = open(BIN, 'rb').read()
    m.banks[1][:len(code)] = code
    m.page = 1
    try:
        v.appelle(m, s_app['App_Start'], 120_000_000)
        r = 'rendu'
    except Fini:
        r = 'touches épuisées'
    except Exception as e:      # noqa: BLE001
        r = 'PLANTE : %s' % e
    tx = bytes(o for _, o in m.tx)
    tx7 = bytes(o & 0x7F for o in tx)
    verifie(r == 'rendu' and not m.touches, 'application : rend la main par RTS après Échap (%s)' % r)
    appel = b'\rATE0&D0B2M1S91=6DT0972101721,,,,,\r'
    verifie(tx.startswith(avec_parite(appel)), 'appel : 3615 tapé, « ATE0&D0B2M1S91=6DT0972101721,,,,, » part au modem (%r)'
            % tx[:len(appel)])
    t = videotex.Terminal()
    for o in avec_parite(b'\n') + START_PCE + b''.join(videotex.blocs_pce(b'\x1b\x39\x7b' + modem.page_de_test())):
        t.octet(o)
    e = t.ecran
    verifie(videotex.parite(0x1B) == 0x1B and avec_parite(b'\x1b\x3a\x73\x44') in tx and avec_parite(videotex.ROM) in tx
            and avec_parite(b'\x15\x43') in tx,
            'serveur PCE : START reconnu (1B 3A 73 44), ENQROM (SOH C u 4 EOT), NACK 43 pour le bloc abîmé')
    c40, a40 = videotex.cellules40(e)
    c80, a80 = videotex.cellules80(e)

    def zone(plan, rangee0, col0, larg):
        return b''.join(plan[(rangee0 + r) * 80 + col0:(rangee0 + r) * 80 + col0 + larg] for r in range(25))

    def hors_fenetre(plan):
        return b''.join(plan[r * 80:r * 80 + 19] + plan[r * 80 + 62:r * 80 + 80] for r in range(25))
    for nom in ('en ligne', 'fenêtre'):
        if nom in vus:
            chr_, att, _, _, _, _ = vus[nom]
            verifie(zone(chr_, 1, 20, 40) == c40 and zone(att, 1, 20, 40) == a40,
                    '%s : la fenêtre (colonnes 20-59, rangées 1-25) est cellules40 du modèle' % nom)
            verifie(hors_fenetre(chr_) == hors_fenetre(bureau[0]) and hors_fenetre(att) == hors_fenetre(bureau[1]),
                    '%s : autour de la fenêtre, le bureau d\'OSM-VISION intact' % nom)
        else:
            verifie(False, '%s : jamais atteint' % nom)
    if 'plein' in vus:
        chr_, att, _, _, _, _ = vus['plein']
        verifie(chr_[:2000] == c80 and att[:2000] == a80, 'Ctrl+F : plein écran, rangées 0-24 = cellules80 du modèle')
    else:
        verifie(False, 'Ctrl+F : jamais atteint')
    def parite(octets):                         # 7 bits + parité paire, comme un Minitel
        return bytes(o | (bin(o).count('1') & 1) << 7 for o in octets)
    attendu = parite(b'a' + b'\x13\x41' + b'\x19\x42e' + b'\x13\x46' + b'\x1b[A' + b'\x13\x47')
    verifie(attendu in tx, 'touches : a, ENVOI, é (SS2), SOMMAIRE, flèche, CORRECTION, avec parité paire (%r)'
            % tx[len(appel):len(appel) + 26])
    i = tx7.find(b'+++')
    if i > 0:
        t_av, t_plus, t_ap = m.tx[i - 1][0], m.tx[i][0], m.tx[i + 3][0]
        # le CR dans la MÊME trame que ATH : celui de l'appel suivant ne compte pas
        verifie(t_plus - t_av >= 60 and t_ap - m.tx[i + 2][0] >= 60 and tx7[i + 3:i + 7] == b'ATH\r'
                and m.tx[i + 6][0] == t_ap,
                'Échap : silence %d trames, « +++ », silence %d trames, ATH' % (t_plus - t_av, t_ap - m.tx[i + 2][0]))
    else:
        verifie(False, 'Échap : pas de « +++ »')
    verifie('raccroche' in vus.get('fin', (0, 0, '', 0, 0, 0))[2], 'NO CARRIER du serveur : « Le serveur a raccroche. »')
    verifie('ne repond pas' in vus.get('muet', (0, 0, '', 0, 0, 0))[2], 'modem muet 30 s : « Le modem ne repond pas »')
    if 'en ligne' in vus and 'plein' in vus:
        ptr, r10 = vus['en ligne'][4], vus['en ligne'][5]
        voulu = 0x8000 + (e.lig + 1) * 80 + 20 + e.col
        verifie(e.curseur == 1 and r10 == 0x6D and ptr == voulu,
                'curseur (CON) en fenêtre : R10 $%02X, VRAM_PTR $%04X (attendu $6D, $%04X : case %d,%d)'
                % (r10 or 0, ptr, voulu, e.lig, e.col))
        ptr = vus['plein'][4]
        voulu = 0x8000 + e.lig * 80 + 2 * e.col
        verifie(ptr == voulu, 'curseur en plein écran : VRAM_PTR $%04X (attendu $%04X)' % (ptr, voulu))
    verifie(m.r10 and m.r10[-1] == 0x2D, 'sortie : curseur caché (R10 $2D) pour le bureau')
    verifie(m.cr == [0x95, 0x95], 'ACIA : $95 (E/16 = 115200 bauds, comme un vrai modem) au départ et à la sortie (%s)'
            % ' '.join('$%02X' % o for o in m.cr))
    verifie(m.mem[s['serie_brute']] == 0, 'sortie : liaison série rendue à la console (serie_brute = 0)')
    verifie(bytes(m.mem[0x8000 + 2000:0x8000 + 2400]) == barre and bytes(m.mem[0x9000 + 2000:0x9000 + 2400]) == barre[::-1],
            'sortie : rangées 25-29 rendues telles qu\'avant')


def main():
    s = symboles()
    for nom in ('Vt_Init', 'Term_Octet', 'LG', 'LT', 'LA', 'Lig', 'Col'):
        if nom not in s:
            print('ÉCHEC symbole %s absent de apps/MINITEL.map' % nom)
            return 1
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    class Ligne(v.Machine):
        def wr8(self, a, val):
            if a & 0xFFFF == HW['TDR']:
                self.envoi.append(val & 0xFF)
                return
            super().wr8(a, val)
    m = Ligne(None, v.sym())
    m.envoi = bytearray()
    m.mem[HW['SR']] = 0x02
    m.banks[1][:len(open(BIN, 'rb').read())] = open(BIN, 'rb').read()
    m.page = 1
    taille = videotex.LIGNES * videotex.COLONNES

    def ecart(e, n):
        pos = (m.banks[1][s['Lig']], m.banks[1][s['Col']], m.banks[1][s['Curseur']])
        if pos != (e.lig, e.col, e.curseur):
            return 'après %d octets : position et curseur %s, modèle %s' % (n, pos, (e.lig, e.col, e.curseur))
        for nom, plan, b in (('code', 'LG', e.g), ('genre', 'LT', e.t), ('attribut', 'LA', e.a)):
            a = bytes(m.banks[1][s[plan]:s[plan] + taille])
            if a != bytes(b):
                i = next(k for k in range(taille) if a[k] != b[k])
                return 'après %d octets : %s rangée %d case %d = $%02X, modèle $%02X' % (
                    n, nom, i // 40, i % 40, a[i], b[i])
        return None

    def essai(nom, flux, envoi_attendu=None):
        t = videotex.Terminal()
        e = t.ecran
        m.envoi = bytearray()
        v.appelle(m, s['Vt_Init'])
        pas = 0
        for n, o in enumerate(flux, 1):
            m.a = o
            m.s = 0xDF00
            m.s -= 2
            m.mem[m.s], m.mem[m.s + 1] = v.RETOUR >> 8, v.RETOUR & 0xFF
            m.pc = s['Term_Octet']
            k = 0
            while m.pc != v.RETOUR:
                m.step()
                k += 1
                if k > 200_000:
                    verifie(False, '%s : octet %d ($%02X) ne rend pas la main' % (nom, n, o))
                    return
            pas = max(pas, k)
            t.octet(o)
            if n % POINT == 0 or n == len(flux):
                d = ecart(e, n)
                if not d and bytes(m.envoi) != bytes(t.envoi):
                    d = 'après %d octets : émis %s, modèle %s' % (n, m.envoi.hex(' '), t.envoi.hex(' '))
                if d:
                    verifie(False, '%s : %s' % (nom, d))
                    return
        if envoi_attendu is not None and bytes(t.envoi) != envoi_attendu:
            verifie(False, '%s : le modèle émet %s, attendu %s' % (nom, t.envoi.hex(' '), envoi_attendu.hex(' ')))
            return
        verifie(True, '%s : %d octets, écran et octets émis identiques au modèle%s (au plus %d instructions par octet)'
                % (nom, len(flux), ' (%s)' % t.envoi.hex(' ') if t.envoi else '', pas))

    application(s, verifie)

    essai('accueil MiniPavi', open(os.path.join(RACINE, 'tools', 'minitel', 'accueil_minipavi.vdt'), 'rb').read())
    essai('page d\'essai du modem', modem.page_de_test())
    for graine in range(1, 7):
        essai('flux aléatoire %d' % graine, flux_aleatoire(graine, 4000))

    # --- PCE ---
    P = avec_parite
    reel = open(os.path.join(RACINE, 'tools', 'minitel', 'minipavi_pce.vdt'), 'rb').read()
    sept = bytes(o & 0x7F for o in reel)
    reel = reel[sept.index(b'\n', sept.index(b'CONNECT')) + 1:]
    nuls = [k for k, o in enumerate(reel) if o == 0]
    blocs = [reel[k - 16:k + 1] for k in nuls if k >= 17 and reel[k - 17] == 0]
    verifie(len(blocs) >= 70 and all(videotex.crc7(b[:15]) == b[15] & 0x7F for b in blocs),
            'appel réel de MiniPavi : %d blocs entiers, CRC = crc7() pour tous' % len(blocs))
    essai('appel réel de MiniPavi (START, blocs, 1er bloc abîmé)', reel, P(b'\x1b\x3a\x73\x44\x15\x40'))
    accueil = open(os.path.join(RACINE, 'tools', 'minitel', 'accueil_minipavi.vdt'), 'rb').read()
    b = videotex.blocs_pce(b'\x1b\x39\x7b' + accueil)
    essai('PCE : accueil MiniPavi en blocs, ENQROM', P(b'\n') + START_PCE + b''.join(b),
          P(b'\x1b\x3a\x73\x44' + videotex.ROM) + P(videotex.ROM) * accueil.count(b'\x1b\x39\x7b'))
    faux = bytes([b[2][0] ^ 0x01]) + b[2][1:]
    essai('PCE : bloc 2 abîmé, NACK 42, SYN SYN 42, reprise',
          START_PCE + b''.join(b[:2]) + faux + b''.join(b[3:5]) + P(b'\x16\x16\x42') + b''.join(b[2:]))
    essai('PCE : un octet perdu dans le bloc 4',
          START_PCE + b''.join(b[:4]) + b[4][:6] + b[4][7:] + b''.join(b[5:7]) + P(b'\x16\x16\x44') + b''.join(b[4:]))
    def ecran_de(flux):
        t = videotex.Terminal()
        for o in flux:
            t.octet(o)
        return t.ecran.g, t.ecran.t, t.ecran.a
    propre = ecran_de(START_PCE + b''.join(b))
    verifie(ecran_de(START_PCE + b''.join(b[:2]) + faux + b''.join(b[3:5]) + P(b'\x16\x16\x42') + b''.join(b[2:])) == propre
            and ecran_de(START_PCE + b''.join(b[:4]) + b[4][:6] + b[4][7:] + b''.join(b[5:7]) + P(b'\x16\x16\x44')
                         + b''.join(b[4:])) == propre,
            'PCE (modèle) : après le bloc abîmé ou l\'octet perdu, le même écran que sans erreur')
    bruit = open(os.path.join(RACINE, 'tools', 'minitel', 'minipavi_bruit.vdt'), 'rb').read()
    sept = bytes(o & 0x7F for o in bruit)
    bruit = bruit[sept.index(b'\n', sept.index(b'CONNECT')) + 1:]
    essai('appel réel bruité (START mutilés et répétés) : une réponse par START intact', bruit,
          P(b'\x1b\x3a\x73\x44') * bytes(o & 0x7F for o in bruit).count(START_PCE))
    essai('PCE : START au milieu d\'un bloc, réponse, bloc 0 de nouveau',
          START_PCE + b''.join(b[:3]) + b[3][:7] + START_PCE + b''.join(b))
    for graine in (11, 12):
        f = flux_aleatoire(graine, 3000)
        essai('PCE : flux aléatoire %d en blocs (NUL, DLE, SYN, NACK transparents), STATUS, STOP' % graine,
              START_PCE + b''.join(videotex.blocs_pce(f + b'\x1b\x39\x72\x1b\x3a\x6a\x44'))
              + P(b'\x1b\x39\x72') + f[:500])

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
