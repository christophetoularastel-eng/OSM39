#!/usr/bin/env python3
# ===================================================================
# verifie_demarrage.py - Démarrage, SECOURS et TRAP (bios/main.asm, IT.asm)
# ===================================================================
# Le VRAI BIOS, lancé par son vecteur de reset dans l'émulateur de
# verifie_fs.py, avec une carte OSMFS (tools/egofs). Le matériel qu'on
# n'émule pas est court-circuité : video_wait_vsync (une trame), init de la
# carte SD, jingle. Le clavier est simulé par NEW_CODE/SCAN_CODE et par
# scan_keyboard ; la liaison série par INPUT (LOAD) et handler_NMI (Ctrl+A).
# Vérifie : démarrage seul jusqu'à OSM-VISION ; une touche pendant la
# fenêtre -> SECOURS ; l'auto-test du clavier ($AA) ignoré ; LOAD d'un
# Intel hex, RUN, BOOT ; carte sans OSMVISION -> SECOURS ; un TRAP : une
# ligne, une touche, redémarrage à chaud sans fenêtre, rapport intact
# (trap_frame, trap_info) ; Ctrl+A sur la liaison série -> SECOURS.
#   make -C bios && python3 test/verifie_demarrage.py
# ===================================================================
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402

HW = dict((n, int(a, 16)) for n, a in re.findall(
    r'^(\w+):?\s+equ\s+\$([0-9A-Fa-f]+)', open(os.path.join(RACINE, 'bios', 'hardware.inc')).read(), re.M | re.I))


class Lance(Exception):
    pass


class Banc(va.MachineAsm):
    def __init__(self, image, s):
        super().__init__(image, s)
        self.trames = 0
        self.touche_trame = None        # (n° de trame, scan code) pour la fenêtre
        self.serie_trame = None         # n° de trame où un caractère arrive (comme handler_NMI)
        self.lignes = []                # lignes rendues par read_line (SECOURS)
        self.serie = []                 # caractères rendus par INPUT (LOAD)
        self.touche_trap = False
        self.lances = []                # (page, pc) des lancements en $0000
        self.miso = None                # sans carte : SD_DATA ($A148) se lit toujours ainsi
        self.init_ratees = 0            # carte lente : autant d'Init_SD_Card en échec d'abord
        self.inits = 0

    def ret(self):
        self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
        self.s += 2

    def rd8(self, a):
        # 6850 : lire RDR vide RDRF (bit 0 de SR), pour les deux ACIA
        a &= 0xFFFF
        v = super().rd8(a)
        if self.miso is not None and a == HW['SD_DATA']:
            return self.miso            # le VRAI Init_SD_Card, sans carte
        if a == HW['RDR']:
            self.mem[HW['SR']] &= 0xFE
        elif a == HW['RDR_key']:
            self.mem[HW['SR_key']] &= 0xFE
        return v

    def step(self):
        s, pc = self.s_, self.pc
        if self.miso is None and pc == s['Init_SD_Card']:
            self.inits += 1
            if self.inits <= self.init_ratees:
                self.cc |= 1            # pas encore prête (mise sous tension)
                self.ret()
                return
            self.cc &= 0xFE             # carte prête
            self.ret()
            return
        if pc in (s['SD_Select'], s['SD_Deselect'], s['boot_jingle']) and self.miso is None:
            self.a = 0
            self.ret()
            return
        if pc == s['boot_jingle']:
            self.ret()
            return
        if pc == s['video_wait_vsync']:
            self.trames += 1
            self.wr16(s['vsync_tick'], (self.rd16(s['vsync_tick']) + 1) & 0xFFFF)
            if self.touche_trame and self.trames == self.touche_trame[0]:
                self.mem[s['SCAN_CODE']] = self.touche_trame[1]
                self.mem[s['NEW_CODE']] = 1
            if self.serie_trame and self.trames == self.serie_trame:
                p = self.rd16(s['write_line_ptr'])
                self.mem[p] = 0x0D
                self.mem[p + 1] = 0
                self.wr16(s['write_line_ptr'], p + 1)
            self.ret()
            return
        if pc == s['read_line']:
            if not self.lignes:
                raise Lance('read_line : plus de lignes')
            t = self.lignes.pop(0).encode('ascii')
            b = s['input_buffer']
            self.mem[b:b + len(t) + 1] = t + b'\0'
            self.x = b + len(t)
            self.texte += t + b'\n'
            self.ret()
            return
        if pc == s['INPUT']:
            if not self.serie:
                raise Lance('INPUT : plus de caractères')
            self.a = ord(self.serie.pop(0))
            self.ret()
            return
        if pc == s['trap_touche'] and self.touche_trap:
            self.mem[s['NEW_CODE']] = 1
        if pc == 0 and self.page == 0:
            self.lances.append(self.page)
            raise Lance('OSMVISION')
        super().step()

    def mem_page0(self, a):
        return self.banks[0][a]

    # --- interruptions du 6309 en mode natif : frame de 14 octets ---
    def interruption(self, vecteur):
        self.s -= 14
        f = [self.cc | 0x80, self.a, self.b, self.w >> 8, self.w & 255, self.dp,
             self.x >> 8, self.x & 255, self.y >> 8, self.y & 255, self.u >> 8, self.u & 255,
             self.pc >> 8, self.pc & 255]
        for i, o in enumerate(f):
            self.wr8(self.s + i, o)
        self.cc |= 0x50
        self.pc = self.rd16(vecteur)

    def execute_pref(self, pref):
        op = self.rd8(self.pc)
        if pref == 0x11 and op == 0x3D:         # LDMD # : mode natif (pris pour acquis)
            self.pc = (self.pc + 2) & 0xFFFF
            self.steps += 1
            return
        return super().execute_pref(pref)

    def execute(self, op):
        if op == 0x3B and self.rd8(self.s) & 0x80:     # RTI natif : 14 octets
            f = [self.rd8(self.s + i) for i in range(14)]
            self.cc, self.a, self.b, self.dp = f[0], f[1], f[2], f[5]
            self.w = (f[3] << 8) | f[4]
            self.x, self.y, self.u = (f[6] << 8) | f[7], (f[8] << 8) | f[9], (f[10] << 8) | f[11]
            self.pc = (f[12] << 8) | f[13]
            self.s += 14
            return
        return super().execute(op)


def carte(dossier, avec_vision=True, bios2=True):
    """Une carte comme deploy_sd.sh la fait : OSMVISION, et /BIN/BIOS2 (la
    seconde partie du BIOS) ; bios2 = des octets : un autre BIOS2."""
    c = va.Carte(dossier)
    if avec_vision:
        c.ajoute('OSMVISION', os.path.join(RACINE, 'osmvision', 'OSMVISION'), page=0)
    if bios2 is True:
        c.ajoute('BIN/BIOS2', v.BIOS2, page=1, attr=0x06)
    elif bios2:
        chemin = os.path.join(dossier, 'bios2_autre')
        open(chemin, 'wb').write(bios2)
        c.ajoute('BIN/BIOS2', chemin, page=1, attr=0x06)
    return c


def demarre(c, s, pas=5_000_000, **reglages):
    m = Banc(c.image, s)
    # à froid, la RAM de BIOS2 ne contient rien : seul Ext_Charge peut l'y mettre
    # (Machine l'y pose d'office pour les autres bancs)
    base2 = min(int(x, 16) for x in re.findall(r'Section: \.ext \(\S+\) load at ([0-9A-F]+)', open(v.MAP).read()))
    m.mem[base2:0xDA00] = bytes([0xFF]) * (0xDA00 - base2)
    for k, val in reglages.items():
        setattr(m, k, val)
    m.pc = m.rd16(0xFFFE)
    m.s = 0xDF00
    m.steps = 0
    raison = None
    try:
        while m.steps < pas:
            if m.sd():
                continue
            m.step()
        raison = 'trop long à $%04X' % m.pc
    except Lance as e:
        raison = str(e)
    return m, raison, m.texte.decode('latin-1').replace('\r', '')


def ihex(adresse, octets):
    n = len(octets)
    rec = [n, adresse >> 8, adresse & 255, 0] + list(octets)
    ck = (-sum(rec)) & 255
    return ':' + ''.join('%02X' % b for b in rec + [ck]) + '\n:00000001FF\n'


def main():
    s = v.sym()
    for n in ('INPUT', 'trap_touche', 'Secours', 'Boot_Loop', 'handler_TRAP', 'handler_NMI'):
        if n not in s:
            print('ÉCHEC symbole %s absent de bios/osm39.map' % n)
            return 1
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, 'a'))
    c = carte(os.path.join(d, 'a'))

    # 1. démarrage seul
    m, r, t = demarre(c, s)
    verifie(r == 'OSMVISION' and 'SECOURS>' not in t and m.trames >= 60,
            'reset sans touche : %d trames d\'attente, puis OSM-VISION lancé en page 0, $0000 (%s)' % (m.trames, r))
    verifie('une touche : SECOURS' in t, 'la bannière annonce le secours')
    # 1b. BIOS2 (la seconde partie du BIOS) : chargé au démarrage
    def ext_etat(m):
        vec = [m.rd16(s['ExtV'] + 2 * i) for i in range(16)]
        return m.mem[s['ext_ok']], vec
    ok, vec = ext_etat(m)
    verifie(ok == 1 and vec[0] == s['X_FS_SaveFile'] and vec[11] == s['X_Zone_IRQ'] and vec[14] == s['X_Graphe'],
            'BIOS2 sur la carte : chargé et installé (FS_SaveFile -> $%04X, l\'IRQ du Terminal -> $%04X)' % (vec[0], vec[11]))
    d2 = os.path.join(d, 'sans_bios2')
    os.makedirs(d2)
    m2, r2, t2 = demarre(carte(d2, bios2=False), s)
    ok, vec = ext_etat(m2)
    verifie(r2 == 'OSMVISION' and ok == 0 and vec[0] == s['Sys_Absent'] and vec[1] == s['Sys_Absent']
            and vec[14] == s['Sys_Absent'] and vec[11] == s['X_Zone_IRQ'] and vec[2] == s['X_FS_SetAttributes'],
            'carte sans BIOS2 : OSM-VISION lancé quand même, FS_SaveFile, FS_DeleteFile et Graphe « absents », '
            'le Terminal et les attributs (EPROM) présents (%s)' % r2)
    autre = bytearray(open(v.BIOS2, 'rb').read())
    autre[len(autre) // 2] ^= 0x55
    d3 = os.path.join(d, 'autre_bios2')
    os.makedirs(d3)
    m3, r3, t3 = demarre(carte(d3, bios2=bytes(autre)), s)
    ok, vec = ext_etat(m3)
    verifie(r3 == 'OSMVISION' and ok == 0 and vec[0] == s['Sys_Absent'],
            'BIOS2 d\'un autre BIOS (un octet changé) : refusé (somme), OSM-VISION lancé (%s)' % r3)
    m, r, t = demarre(c, s, init_ratees=2)
    verifie(r == 'OSMVISION' and m.inits == 3 and 'absente' not in t,
            'carte lente à la mise sous tension : 2 échecs, prête au 3e essai, OSM-VISION lancé (%s)' % r)
    m, r, t = demarre(c, s, init_ratees=9)
    verifie('absente' in t and 'SECOURS>' in t and m.inits == 4,
            'carte muette : 4 essais (%d), puis « Carte SD absente », SECOURS' % m.inits)

    # 2. une touche pendant la fenêtre -> SECOURS, LOAD, RUN, BOOT
    # (en $5000 : OSM-VISION, rechargé par BOOT, occupe $0000-$3FFF)
    prog = bytes([0x86, 0x5A, 0xB7, 0x50, 0x20, 0x39])      # LDA #$5A / STA $5020 / RTS
    m, r, t = demarre(c, s, touche_trame=(20, 0x1C),
                      lignes=['LOAD', 'RUN 5000', 'BOOT'], serie=list(ihex(0x5000, prog)))
    verifie('SECOURS>' in t, 'une touche à la 20e trame : SECOURS')
    verifie(bytes(m.banks[0][0x5000:0x5006]) == prog, 'LOAD : l\'Intel hex est en page 0, $5000')
    verifie(m.banks[0][0x5020] == 0x5A, 'RUN 5000 : le programme a tourné et rendu la main au SECOURS')
    verifie(r == 'OSMVISION', 'BOOT : OSM-VISION lancé (%s)' % r)

    m, r, t = demarre(c, s, serie_trame=30, lignes=['BOOT'])
    verifie('SECOURS>' in t and r == 'OSMVISION', 'un caractère sur la liaison série pendant la fenêtre : SECOURS')

    # 3. l'auto-test du clavier ($AA) n'ouvre pas le secours
    m, r, t = demarre(c, s, touche_trame=(10, 0xAA))
    verifie(r == 'OSMVISION' and 'SECOURS>' not in t, '$AA (auto-test du clavier) ignoré : démarrage normal')

    # 4. carte sans OSMVISION
    d2 = os.path.join(d, 'b')
    os.makedirs(d2)
    m, r, t = demarre(carte(d2, avec_vision=False), s, lignes=[])
    verifie('OSMVISION introuvable' in t and 'SECOURS>' in t, 'carte sans OSMVISION : message, puis SECOURS')

    # 4b. sans carte SD : le vrai Init_SD_Card, MISO figé à $FF puis à $00
    for miso in (0xFF, 0x00):
        m, r, t = demarre(c, s, pas=30_000_000, miso=miso, lignes=['BOOT'])
        verifie('Carte SD absente' in t and t.count('SECOURS>') >= 2 and r.startswith('read_line'),
                'sans carte (MISO = $%02X) : « Carte SD absente », SECOURS ; BOOT : même message, '
                'pas de blocage (%.1f M instructions)' % (miso, m.steps / 1e6))

    # 5. TRAP pendant un programme : une ligne, une touche, redémarrage à chaud
    m, r, t = demarre(c, s)                 # jusqu'au lancement d'OSM-VISION
    m.page = 1
    m.mem[s['current_page']] = 1
    m.banks[1][0x2000:0x2008] = bytes([0x12, 0x12, 0x15, 0x99, 0x12, 0x12, 0x12, 0x12])
    m.pc, m.a, m.b, m.x, m.y, m.u, m.w, m.dp = 0x2003, 0x11, 0x22, 0x3344, 0x5566, 0x7788, 0x99AA, 0x00
    m.s = 0xDE00
    base2 = min(int(x, 16) for x in re.findall(r'Section: \.ext \(\S+\) load at ([0-9A-F]+)', open(v.MAP).read()))
    m.mem[base2:base2 + 64] = bytes(64)     # le programme planté a abîmé BIOS2
    m.interruption(0xFFF0)                  # vecteur TRAP du 6309
    m.texte = bytearray()
    m.touche_trap = True
    m.trames = 0
    m.steps = 0
    try:
        while m.steps < 5_000_000:
            if m.sd():
                continue
            m.step()
        r = 'trop long à $%04X' % m.pc
    except Lance as e:
        r = str(e)
    t = m.texte.decode('latin-1')
    verifie('TRAP 6309  PC=2003' in t and 'PC-2 : 12159912' in t,
            'TRAP : « TRAP 6309  PC=2003 », octets à partir de PC-2 : 12 15 99 12')
    verifie(r == 'OSMVISION' and m.trames < 60, 'une touche : OSM-VISION relancé à chaud, sans fenêtre de secours (%d trame(s), %s)' % (m.trames, r))
    corps2 = open(v.BIOS2, 'rb').read()
    verifie(m.mem[s['ext_ok']] == 1 and bytes(m.mem[base2:base2 + len(corps2)]) == corps2,
            'redémarrage à chaud : BIOS2 (abîmé par le programme) relu sur la carte et réinstallé')
    tf, ti = s['trap_frame'], s['trap_info']
    fr = bytes(m.mem[tf:tf + 14])
    verifie(fr[1] == 0x11 and fr[2] == 0x22 and fr[6:8] == b'\x33\x44' and fr[8:10] == b'\x55\x66'
            and fr[10:12] == b'\x77\x88' and fr[12:14] == b'\x20\x03' and fr[3:5] == b'\x99\xAA',
            'trap_frame intact après le redémarrage : A B W X Y U PC')
    verifie(m.mem[ti] == 0xA5 and m.mem[ti + 1] == 1 and bytes(m.mem[ti + 15:ti + 23]) == bytes(
        [0x12] * 0 + list(m.banks[1][0x1FFF:0x2007])),
        'trap_info : valide ($A5), page 1, octets à partir de PC-4')
    verifie(m.mem[s['trap_active']] == 0, 'trap_active remis à 0 (un TRAP suivant sera rapporté)')

    # 5b. MONITEUR (programme de la carte) lit ce rapport, la mémoire, appelle
    code = open(os.path.join(RACINE, 'cmd', 'MONITEUR'), 'rb').read()
    m.banks[1][:len(code)] = code
    m.banks[2][0x3000:0x3003] = bytes([0x86, 0x42, 0x39])        # LDA #$42 / RTS
    m.lignes = ['R', 'E 3:1234 DE AD BE EF', 'M 3:1230', 'M E000', 'G 2:3000', 'X', 'Q']
    m.texte = bytearray()
    m.mem[s['current_page']] = 1
    m.page = 1
    m.wr16(s['argv'], 0xD300)
    m.mem[s['argc']] = 1
    m.steps = 0
    try:
        v.appelle(m, 0x0000, 20_000_000)
        r = 'fin'
    except (Lance, RuntimeError) as e:
        r = str(e)
    t = m.texte.decode('latin-1').replace('\r', '')
    verifie(r == 'fin', 'MONITEUR : Q rend la main (%s)' % r)
    verifie('Dernier TRAP : PC=2003  page 01' in t and 'A=11 B=22 W=99AA' in t and 'X=3344 Y=5566 U=7788' in t,
            'MONITEUR R : PC, page, registres du TRAP')
    verifie('IRQ VSYNC : ' in t, 'MONITEUR R : état de l\'IRQ VSYNC')
    verifie(bytes(m.banks[3][0x1234:0x1238]) == b'\xde\xad\xbe\xef', 'MONITEUR E 3:1234 : écrit en page 3')
    verifie('03:1230  00 00 00 00 DE AD BE EF' in t, 'MONITEUR M 3:1230 : relu (%s)' % (t[t.find('03:1230'):t.find('03:1230') + 40]))
    eprom = ' '.join('%02X' % b for b in m.mem[0xE000:0xE004])
    verifie(('00:E000  ' + eprom) in t, 'MONITEUR M E000 : l\'EPROM, lue directement')
    verifie('Retour : A=42' in t, 'MONITEUR G 2:3000 : appel en page 2, A rendu ($42)')
    verifie('M [p:]aaaa' in t, 'MONITEUR : commande inconnue -> l\'aide')

    # 6. Ctrl+A sur la liaison série -> SECOURS
    m, r, t = demarre(c, s)
    m.mem[HW['SR']] = 0x01                  # ACIA : un caractère reçu
    m.mem[HW['RDR']] = 0x01                 # Ctrl+A
    m.s = 0xDE00
    m.interruption(0xFFFC)                  # NMI
    m.texte = bytearray()
    m.lignes = []
    m.steps = 0
    try:
        while m.steps < 3_000_000:
            if m.sd():
                continue
            m.step()
        r = 'trop long'
    except Lance as e:
        r = str(e)
    t = m.texte.decode('latin-1')
    verifie('break' in t and 'SECOURS>' in t, 'Ctrl+A sur la liaison série : SECOURS (%s)' % r)

    # 7. Mode brut (MINITEL) : serie_brute <> 0, les octets vont dans
    # l'anneau serie_buf, Ctrl+A compris, sans toucher au tampon de ligne.
    m, r, t = demarre(c, s)
    m.mem[HW['serie_brute']] = 1
    m.mem[HW['serie_tete']] = m.mem[HW['serie_queue']] = 0xFE       # le tour de l'anneau
    ligne = m.rd16(s['write_line_ptr'])
    m.mem[0x7000:0x7002] = b'\x20\xfe'                               # BRA * (le programme)

    def nmi(octet):
        m.mem[HW['SR']] = 0x01
        m.mem[HW['RDR']] = octet
        m.pc, m.s, m.steps = 0x7000, 0x6F00, 0
        m.interruption(0xFFFC)
        while m.pc != 0x7000 and m.steps < 1000:
            m.step()
        return m.steps
    pas = [nmi(o) for o in (0x41, 0x01, 0x0D, 0x13)]
    anneau = bytes(m.mem[HW['serie_buf'] + i] for i in (0xFE, 0xFF, 0x00, 0x01))
    verifie(anneau == b'\x41\x01\x0d\x13' and m.mem[HW['serie_tete']] == 0x02,
            'mode brut : 4 octets dans l\'anneau, Ctrl+A compris, tête $FE -> $02 (%s)' % anneau.hex())
    verifie(m.rd16(s['write_line_ptr']) == ligne and 'break' not in m.texte.decode('latin-1'),
            'mode brut : ni tampon de ligne, ni SECOURS')
    verifie(max(pas) < 40, 'mode brut : la NMI rend la main en %s instructions' % pas)
    m.mem[HW['serie_queue']] = 0x03                                   # anneau plein
    nmi(0x55)
    verifie(m.mem[HW['serie_tete']] == 0x02 and m.mem[HW['serie_buf'] + 2] == 0,
            'mode brut : anneau plein, l\'octet est perdu sans rien écraser')
    # Un octet série ET un octet clavier en même temps : une seule NMI
    # (front partagé) doit servir les deux.
    m.mem[HW['serie_queue']] = 0x02
    m.mem[HW['SR_key']] = 0x01
    m.mem[HW['RDR_key']] = 0x1C
    m.mem[HW['NEW_CODE']] = 0
    nmi(0x66)
    verifie(m.mem[HW['serie_buf'] + 2] == 0x66 and m.mem[HW['NEW_CODE']] == 1 and m.mem[HW['SCAN_CODE']] == 0x1C
            and not m.mem[HW['SR']] & 1 and not m.mem[HW['SR_key']] & 1,
            'NMI : un octet série et un octet clavier ensemble, les deux servis')
    m.mem[HW['serie_brute']] = 0
    ligne = m.rd16(s['write_line_ptr'])
    m.mem[HW['SR_key']] = 0x01
    m.mem[HW['RDR_key']] = 0x2D
    nmi(ord('Z'))
    verifie(m.mem[ligne] == ord('Z') and m.mem[HW['SCAN_CODE']] == 0x2D,
            'NMI, mode ligne : le caractère au tampon ET le code clavier')
    m.mem[HW['serie_brute']] = 1
    m.pc, m.s, m.steps = s['Redemarrage'], 0xDF00, 0
    try:
        while m.steps < 5_000_000:
            if m.sd():
                continue
            m.step()
    except Lance:
        pass
    verifie(m.mem[HW['serie_brute']] == 0, 'redémarrage à chaud : mode brut coupé (la console répond)')

    # 8. Clavier : le VRAI scan_keyboard / kbd_poll ; les codes PS/2 sont
    # TOUS dans la file avant l'appel (un programme en retard : rien ne doit
    # être écrasé). Un caractère au relâchement de la dernière touche
    # enfoncée, une seule fois ; kbd_poll ne bloque jamais.
    m, r, t = demarre(c, s)

    def file(codes):
        for o in codes:
            k = m.mem[s['kbd_tete']]
            m.mem[s['kbd_buf'] + k] = o
            m.mem[s['kbd_tete']] = (k + 1) & 15
            m.mem[HW['SCAN_CODE']] = o
            m.mem[HW['NEW_CODE']] = 1

    def appel(adr):
        m.s, m.steps = 0xDE00, 0
        m.s -= 2
        m.mem[m.s], m.mem[m.s + 1] = 0x70, 0x00
        m.banks[m.page][0x7000:0x7002] = b'\x20\xfe'
        m.pc = adr
        while m.pc != 0x7000 and m.steps < 300_000:
            m.step()
        return m.a if m.pc == 0x7000 else None

    def frappe(codes, n=1):
        file(codes)
        return [appel(s['scan_keyboard']) for _ in range(n)]
    q = frappe([0x15, 0xF0, 0x15])                                  # a (AZERTY : touche Q)
    verifie(q == [ord('a')], 'clavier : appui, relâchement -> « a » (%s)' % q)
    q = frappe([0x12, 0x2B, 0xF0, 0x2B, 0xF0, 0x12, 0x2B, 0xF0, 0x2B], 2)
    verifie(q == [ord('F'), ord('f')], 'clavier : Maj+F puis F, tout en file : « F », « f » (%s)' % q)
    q = frappe([0x2B, 0xF0, 0x2B, 0xF0, 0x2B, 0x1C, 0xF0, 0x1C], 2)
    verifie(q == [ord('f'), ord('q')], 'clavier : relâchement en double -> une seule lettre (%s)' % q)
    q = frappe([0x12, 0x2B, 0xF0, 0x2B, 0xF0, 0x00, 0x1C, 0xF0, 0x1C], 2)
    verifie(q == [ord('F'), ord('Q')], 'clavier : octet mal lu après F0 -> rien, pas la lettre précédente (%s)' % q)
    q = frappe([0xE0, 0x75, 0xE0, 0xF0, 0x75])
    verifie(q == [0x80], 'clavier : flèche haut (%s)' % q)
    p = s['kbd_poll']
    vide = appel(p)
    file([0x12, 0x2D, 0xF0, 0x2D])
    q = [appel(p)]
    file([0xF0, 0x12])
    q += [appel(p), appel(p)]
    file([0x2D, 0xF0, 0x2D])
    q += [appel(p)]
    verifie(vide == 0 and q == [ord('R'), 0, 0, ord('r')],
            'kbd_poll : file vide -> 0 ; Maj+R -> « R » ; lâcher Maj -> 0 sans attendre ; R -> « r » (%s)' % q)
    m.mem[HW['NEW_CODE']] = 0                                       # lu ailleurs (ENVAHIS...)
    file([0x1C, 0xF0, 0x1C])
    m.mem[HW['NEW_CODE']] = 0
    file([0x15, 0xF0, 0x15])
    m.mem[HW['NEW_CODE']] = 0
    q = appel(s['scan_keyboard'])
    verifie(q is None, 'scan_keyboard : une file lue par SCAN_CODE (NEW_CODE à 0) est jetée, on attend (%s)' % q)

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
