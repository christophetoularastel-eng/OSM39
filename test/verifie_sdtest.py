#!/usr/bin/env python3
# ===================================================================
# verifie_sdtest.py - cmd/SDTEST face à une carte SD simulée sur le SPI
#                     matériel de la carte SD-KBD-SON
# ===================================================================
# Le VRAI BIOS et le VRAI cmd/SDTEST dans l'émulateur de verifie_fs.py.
# Les registres de la carte sont modélisés comme les décrit
# tools/carte_sd_kbd_son/simule.py :
#   SD_CTRL (écriture) : bit 0 = /CS, bit 1 = rapide ;
#   SD_DATA : écrire envoie l'octet, lire rend l'octet reçu au transfert
#   PRÉCÉDENT et lance un transfert qui renvoie CET octet (mesuré sur la
#   carte le 30 oct. 2026 : le 165 se charge aussi en lecture ; le schéma
#   et simule.py disent $FF).
# La carte simulée (SPI, SDHC 32 Go) répond à CMD0, CMD8, CMD55/ACMD41,
# CMD58, CMD9, CMD10, CMD17, CMD24, et vérifie les CRC de CMD0/CMD8 et
# les 74 coups d'horloge /CS haut avant CMD0. Comme la vraie, elle prend
# le premier bit 0 après CMD24 pour le début du bloc : un octet non $FF
# renvoyé par une lecture décale tout le bloc (jeton_faux).
#
# Pas de bit « occupé » sur la carte : entre deux accès à SD_DATA (ou un
# accès et une écriture de SD_CTRL), le transfert lancé doit être fini.
# simule.py a validé 9 cycles de bus en rapide et 150 en lent. On compte
# ici, pour chaque instruction, ses accès au bus DISTINCTS (octets
# d'instruction, lectures, écritures) : chacun prend au moins un cycle,
# donc la somme est une borne BASSE du temps réel. Les appels interceptés
# (PrintChar, scan_keyboard) ne comptent rien : borne encore plus basse.
# L'émulateur lit l'opérande avant un STA : une lecture de SD_DATA ne
# lance donc son transfert qu'en fin d'instruction, si celle-ci n'a pas
# écrit SD_DATA, et une adresse lue et écrite dans la même instruction
# ne compte qu'une fois.
#   make -C bios && make -C cmd && python3 test/verifie_sdtest.py
# ===================================================================
import os
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_dossiers as vd   # noqa: E402

RACINE = os.path.dirname(ICI)
HW = {}
for ligne in open(os.path.join(RACINE, 'bios', 'hardware.inc')):
    p = ligne.split()
    if len(p) >= 3 and p[1].lower() == 'equ' and p[2].startswith('$'):
        HW[p[0].rstrip(':')] = int(p[2][1:], 16)
SD_CTRL, SD_DATA = HW['SD_CTRL'], HW['SD_DATA']
ECART_RAPIDE, ECART_LENT = 9, 150
LBA_ESSAI = 0x00100000
C_SIZE = 61023                  # 32 Go : (C_SIZE + 1) / 2 = 30512 Mo


class CarteSD:
    """Une carte SDHC en mode SPI, octet par octet."""

    def __init__(self, absente=False, panne_lecture=0, reponse=0xE5, occupee=3):
        self.absente = absente
        self.panne = panne_lecture  # une lecture sur n reste sans jeton
        self.reponse = reponse      # réponse de données après un bloc écrit
        self.occupee = occupee      # octets à 0 qui suivent (None : sans fin)
        self.secteurs = {}
        self.sortie = []            # octets que la carte enverra
        self.cmd = []
        self.etat = 'cmd'           # 'cmd', 'jeton' (après CMD24), 'donnees'
        self.tampon = []
        self.lba = 0
        self.horloges_cs_haut = 0
        self.au_repos = False
        self.prete = False
        self.app = False
        self.essais41 = 0
        self.lectures = 0
        self.ecritures = []         # (lba, données)
        self.journal = []           # commandes reçues
        self.crc_faux = []
        self.jeton_faux = 0
        self.bits = ''

    def secteur(self, lba):
        return self.secteurs.get(lba, bytes(512))

    def transfert(self, mosi, cs):
        if self.absente:
            return 0xFF
        if cs:
            if not self.au_repos:
                self.horloges_cs_haut += 8
            return 0xFF
        emet = bool(self.sortie)            # la carte émet : MOSI ignoré
        if self.sortie:
            miso = self.sortie.pop(0)
        else:
            miso = 0x00 if self.etat == 'occupee' else 0xFF
        if self.etat == 'jeton':
            if mosi != 0xFF:                    # premier bit 0 : début du bloc
                b = format(mosi, '08b')
                self.jeton_faux += mosi != 0xFE
                self.bits, self.etat = b[b.index('0') + 1:], 'donnees'
        elif self.etat == 'donnees':
            self.bits += format(mosi, '08b')
            if len(self.bits) >= 514 * 8:       # 512 + CRC
                donnees = bytes(int(self.bits[i:i + 8], 2) for i in range(0, 4096, 8))
                self.secteurs[self.lba] = donnees
                self.ecritures.append((self.lba, donnees))
                if self.occupee is None:
                    self.sortie, self.etat = [self.reponse], 'occupee'
                else:
                    self.sortie = [self.reponse] + [0x00] * self.occupee
                    self.etat = 'cmd'
        elif emet and not self.cmd:
            pass
        elif self.cmd or (mosi & 0xC0) == 0x40:
            self.cmd.append(mosi)
            if len(self.cmd) == 6:
                self.commande()
                self.cmd = []
        return miso

    def r1(self):
        return 0x00 if self.prete else 0x01

    def commande(self):
        n = self.cmd[0] & 0x3F
        arg = int.from_bytes(bytes(self.cmd[1:5]), 'big')
        crc = self.cmd[5]
        app, self.app = self.app, False
        self.journal.append(('A' if app else '') + 'CMD%d' % n)
        rep = None
        if n == 0:
            if crc != 0x95:
                self.crc_faux.append('CMD0')
                rep = [0x09]                    # erreur de CRC
            elif self.horloges_cs_haut < 74:
                rep = None                      # pas réveillée : muette
            else:
                self.au_repos = True
                rep = [0x01]
        elif not self.au_repos:
            rep = None
        elif n == 8:
            if crc != 0x87:
                self.crc_faux.append('CMD8')
                rep = [0x09]
            else:
                rep = [0x01, 0x00, 0x00, 0x01, arg & 0xFF]
        elif n == 55:
            self.app = True
            rep = [self.r1()]
        elif n == 41 and app:
            if arg & 0x40000000:                # HCS : sinon jamais prête
                self.essais41 += 1
                self.prete = self.essais41 >= 3
            rep = [self.r1()]
        elif not self.prete:
            rep = [0x05]                        # repos + commande illégale
        elif n == 58:
            rep = [0x00, 0xC0, 0xFF, 0x80, 0x00]
        elif n in (9, 10):
            if n == 9:
                b = bytearray(16)
                b[0] = 0x40
                b[7], b[8], b[9] = (C_SIZE >> 16) & 0x3F, (C_SIZE >> 8) & 0xFF, C_SIZE & 0xFF
            else:
                b = bytearray(b'\x03SDSC32G\x80' + bytes(7))
            rep = [0x00, 0xFF, 0xFE] + list(b) + [0x12, 0x34]
        elif n == 17:
            self.lectures += 1
            if self.panne and self.lectures % self.panne == 0:
                rep = [0x00]                    # jamais de jeton
            else:
                rep = [0x00, 0xFF, 0xFF, 0xFF, 0xFE] + list(self.secteur(arg)) + [0xAB, 0xCD]
        elif n == 13:
            rep = [0x00, 0x00]                  # R2
        elif n == 24:
            self.lba = arg
            self.etat = 'jeton'
            rep = [0x00]
        else:
            rep = [0x05]
        if rep is not None:
            self.sortie = [0xFF] + rep          # NCR : un octet avant R1


class Banc(va.MachineAsm):
    def __init__(self, image, s, carte, touches):
        super().__init__(image, s)
        self.carte = carte
        self.touches = list(touches)
        self.ctrl = None
        self.ctrls = []
        self.recu = 0xFF            # octet reçu au dernier transfert
        self.lu = 0xFF              # octet rendu par la lecture en cours
        self.bus = 0                # accès au bus (borne basse des cycles)
        self.acces = None
        self.dernier = None         # (bus, rapide) du dernier transfert lancé
        self.ecarts = {True: [], False: []}
        self.transferts = {True: 0, False: 0}

    def _note(self, a, sens):
        if self.acces is not None:
            self.acces.add((a & 0xFFFF, sens))

    def _maintenant(self):
        return self.bus + len({a for a, _ in self.acces or ()})

    def _ecart(self):
        """Le transfert précédent doit être fini."""
        if self.dernier is not None:
            b, rapide = self.dernier
            self.ecarts[rapide].append(self._maintenant() - b)

    def _lance(self, mosi):
        self._ecart()
        rapide = bool(self.ctrl & 2)
        self.recu = self.carte.transfert(mosi, self.ctrl & 1)
        self.transferts[rapide] += 1
        self.dernier = (self._maintenant(), rapide)

    def rd8(self, a):
        self._note(a, 'r')
        if (a & 0xFFFF) == SD_DATA:
            self.lu = self.recu
            return self.recu                    # le transfert part en fin d'instruction
        return super().rd8(a)

    def wr8(self, a, v_):
        self._note(a, 'w')
        a &= 0xFFFF
        if a == SD_DATA:
            self._lance(v_ & 0xFF)
            return
        if a == SD_CTRL:
            self._ecart()
            self.ctrl = v_ & 0xFF
            self.ctrls.append(self.ctrl)
            return
        super().wr8(a, v_)

    def sd(self):
        return False                    # le vrai pilote du BIOS, pas l'interception

    def step(self):
        if self.pc == self.s_['scan_keyboard']:
            if not self.touches:
                raise RuntimeError('SDTEST attend une touche de trop')
            self.a = self.touches.pop(0)
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        self.acces = set()
        super().step()
        if (SD_DATA, 'r') in self.acces and (SD_DATA, 'w') not in self.acces:
            self._lance(self.lu)                # le 165 renvoie l'octet lu
        self.bus = self._maintenant()
        self.acces = None


def lance(carte, touches=()):
    b = vd.Banc()
    m = Banc(b.image, b.s, carte, touches)
    s = b.s
    rom, fin = s['table_function_rom'], s['table_function_rom_end']
    for i in range(fin - rom):
        m.mem[s['table_function_ram'] + i] = m.mem[rom + i]
    code = open(os.path.join(RACINE, 'cmd', 'SDTEST'), 'rb').read()
    m.banks[1][:len(code)] = code
    m.mem[s['argc']] = 1
    m.mem[s['current_page']] = 1
    m.page = 1
    v.appelle(m, 0x0000, 60_000_000)
    return m, m.texte.decode('latin-1').replace('\r', '')


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    def espacement(m, nom):
        r, l_ = m.ecarts[True], m.ecarts[False]
        verifie(m.transferts[False] > 0 and min(l_) >= ECART_LENT,
                '%s : en lent, %d transferts, au moins %s accès au bus entre deux (il en faut %d)'
                % (nom, m.transferts[False], min(l_) if l_ else '-', ECART_LENT))
        if m.transferts[True]:
            verifie(min(r) >= ECART_RAPIDE,
                    '%s : en rapide, %d transferts, au moins %d accès au bus entre deux (il en faut %d)'
                    % (nom, m.transferts[True], min(r), ECART_RAPIDE))

    # --- carte présente, secteur 0 OSMFS, écriture refusée (N) ---
    sect0 = bytearray((i * 13 + 1) & 255 for i in range(512))
    sect0[508:512] = b'OSMF'
    origine = bytes((i * 5 + 9) & 255 for i in range(512))
    c = CarteSD()
    c.secteurs[0] = bytes(sect0)
    c.secteurs[LBA_ESSAI] = origine
    m, t = lance(c, [ord('n')])
    print('    | ' + t.strip().replace('\n', '\n    | '))
    verifie(c.horloges_cs_haut >= 74 and c.journal[:2] == ['CMD0', 'CMD8'],
            '%d coups d\'horloge /CS haut, puis CMD0, CMD8' % c.horloges_cs_haut)
    verifie(not c.crc_faux, 'CRC de CMD0 et CMD8 justes')
    verifie('CMD0   R1=01' in t and 'CMD8   R1=01' in t and 'suite 000001AA' in t, 'CMD0 et CMD8 affichés')
    verifie('ACMD41 prete apres 3 essai(s)' in t and c.journal.count('ACMD41') == 3, 'ACMD41 avec HCS, prête au 3e essai')
    verifie('suite C0FF8000' in t and 'SDHC' in t, 'CMD58 : OCR et CCS')
    verifie('fabricant $03  OEM SD  nom SC32G' in t, 'CID : fabricant, OEM, nom')
    verifie('capacite 30512 Mo' in t, 'CSD v2 : capacité en Mo')
    verifie('Secteur 0 : 01 0E 1B 28' in t and 'OSMF  (carte OSMFS)' in t, 'secteur 0 : octets et signature')
    verifie('200 lectures, 0 erreur(s)' in t and c.lectures == 201, '200 lectures comparées à la première')
    verifie(not c.ecritures and 'N' in t.split('(O/N)')[1][:3], 'N : aucune écriture')
    verifie('Essai termine.' in t and m.ctrls[-1] == 0x01, 'fin : carte libérée, vitesse lente (SD_CTRL = 01)')
    verifie(0x02 in m.ctrls, 'passage en rapide (SD_CTRL = 02)')
    espacement(m, 'lecture')

    # --- écriture (O) : motif, relecture, origine remise ---
    c = CarteSD()
    c.secteurs[0] = bytes(sect0)
    c.secteurs[LBA_ESSAI] = origine
    m, t = lance(c, [ord('O')])
    motif = bytes((3 + 7 * i) & 255 for i in range(512))
    verifie(c.jeton_faux == 0, 'O : aucune lecture ne fait croire à un jeton (CMD24 sans lecture avant $FE)')
    verifie([lba for lba, _ in c.ecritures] == [LBA_ESSAI, LBA_ESSAI] and c.ecritures[0][1] == motif,
            'O : le motif 3 + 7i écrit au secteur $%08X' % LBA_ESSAI)
    verifie('identique' in t and c.secteur(LBA_ESSAI) == origine and 'origine remis' in t,
            'O : relu identique, puis contenu d\'origine remis')
    espacement(m, 'écriture')

    verifie('apres le CRC : FF E5 00 00 00 FF FF FF  occupee 0 trames' in t,
            'O : diagnostic de l\'écriture (octets après le CRC, occupation)')

    # --- écriture : réponse « erreur d'écriture » ($0D), puis carte occupée sans fin ---
    c = CarteSD(reponse=0x0D)
    c.secteurs[0] = bytes(sect0)
    m, t = lance(c, [ord('O')])
    verifie('apres le CRC : FF 0D' in t and 'ecriture du motif (code $0D)' in t and 'CMD13  R1=00' in t
            and 'Essai arrete.' in t and m.ctrls[-1] == 0x01,
            'réponse $0D : échec, code $0D, état CMD13 affiché, carte libérée')
    c = CarteSD(occupee=None)
    c.secteurs[0] = bytes(sect0)
    m, t = lance(c, [ord('O')])
    verifie('ecriture du motif (code $00)' in t and 'Essai arrete.' in t and c.lectures == 202,
            'carte occupée sans fin : abandon après l\'attente, code $00')

    # --- une lecture sur 50 sans jeton : comptée, l'essai continue ---
    c = CarteSD(panne_lecture=50)
    c.secteurs[0] = bytes(sect0)
    m, t = lance(c, [ord('N')])
    verifie('200 lectures, 4 erreur(s)' in t and 'Essai termine.' in t,
            'lectures sans jeton (1 sur 50) : 4 erreurs comptées sur 200, essai fini')

    # --- pas de carte ---
    m, t = lance(CarteSD(absente=True))
    verifie('CMD0   R1=rien' in t and 'Essai arrete.' in t and m.ctrls[-1] == 0x01,
            'sans carte : « rien » à CMD0, arrêt propre, carte libérée')

    # --- le pilote du BIOS (bios/SD.asm) face à la même carte ---
    def bios(carte):
        b = vd.Banc()
        m = Banc(b.image, b.s, carte, [])
        s = b.s
        rom, fin = s['table_function_rom'], s['table_function_rom_end']
        for i in range(fin - rom):
            m.mem[s['table_function_ram'] + i] = m.mem[rom + i]
        return m, s

    def appel(m, nom, lba=None, donnees=None):
        if lba is not None:
            m.mem[m.s_['BlockAddr']:m.s_['BlockAddr'] + 4] = lba.to_bytes(4, 'big')
        if donnees is not None:
            m.mem[m.s_['SD_BUFFER']:m.s_['SD_BUFFER'] + 512] = donnees
        ok = v.appelle(m, m.s_[nom], 20_000_000)
        return ok, m.a

    c = CarteSD()
    c.secteurs[0] = bytes(sect0)
    m, s = bios(c)
    ok, _ = appel(m, 'Init_SD_Card')
    verifie(ok and c.prete and m.ctrls[-1] == 0x03 and c.journal[:2] == ['CMD0', 'CMD8'],
            'BIOS : Init_SD_Card prête, puis rapide et carte libérée (SD_CTRL = %02X)' % m.ctrls[-1])
    _, a = appel(m, 'SD_ReadBlock', 0)
    verifie(a == 0 and bytes(m.mem[s['SD_BUFFER']:s['SD_BUFFER'] + 512]) == bytes(sect0) and m.ctrls[-1] & 1,
            'BIOS : SD_ReadBlock du secteur 0 : A = 0, contenu, carte libérée')
    _, a = appel(m, 'SD_WriteBlock', LBA_ESSAI + 7, motif)
    verifie(a == 0 and c.secteur(LBA_ESSAI + 7) == motif and c.jeton_faux == 0,
            'BIOS : SD_WriteBlock : A = 0, secteur écrit, aucun faux jeton (CMD24 à l\'aveugle)')
    m.mem[s['SD_BUFFER']:s['SD_BUFFER'] + 512] = bytes(512)
    _, a = appel(m, 'SD_ReadBlock', LBA_ESSAI + 7)
    verifie(a == 0 and bytes(m.mem[s['SD_BUFFER']:s['SD_BUFFER'] + 512]) == motif, 'BIOS : relu identique')
    espacement(m, 'BIOS')
    c.reponse = 0x0D
    _, a = appel(m, 'SD_WriteBlock', LBA_ESSAI + 8, motif)
    verifie(a == 0xE4, 'BIOS : bloc refusé ($0D) -> A = $E4 (%02X)' % a)
    c.reponse, c.occupee = 0xE5, None
    _, a = appel(m, 'SD_WriteBlock', LBA_ESSAI + 9, motif)
    verifie(a == 0xE5, 'BIOS : carte occupée sans fin -> A = $E5 (%02X)' % a)
    c2 = CarteSD(panne_lecture=1)
    m, s = bios(c2)
    appel(m, 'Init_SD_Card')
    _, a = appel(m, 'SD_ReadBlock', 0)
    verifie(a == 0xE2, 'BIOS : lecture sans jeton -> A = $E2 (%02X)' % a)
    m, s = bios(CarteSD(absente=True))
    ok, _ = appel(m, 'Init_SD_Card')
    verifie(not ok and m.ctrls[-1] & 1, 'BIOS : sans carte, Init_SD_Card rend C = 1, carte libérée')

    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
