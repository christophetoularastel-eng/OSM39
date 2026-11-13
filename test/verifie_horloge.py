#!/usr/bin/env python3
# ===================================================================
# verifie_horloge.py - cmd/HORLOGE (lib/horloge.asm) face à un MC146818
# simulé, branché sur un 68B21 simulé comme la carte RTC
# ===================================================================
# Le VRAI BIOS et le VRAI cmd/HORLOGE dans l'émulateur de verifie_fs.py.
# Le PIA ($A040-$A043 : PRA/DDRA, PRB/DDRB, CRA, CRB ; b2 de CRx choisit
# DDR ou PR) est modélisé broche par broche : PA0-7 = AD0-7, CA2 = AS
# (sortie si CRA b5 = b4 = 1, niveau b3), PB0 = DS, PB1 = R/W (tirages à
# +5 V : une broche en entrée lit 1), port A en entrée tiré à 1.
# La puce suit la fiche (figures 2 et 9) : mode Motorola si DS est bas au
# front descendant de AS (sinon erreur), adresse prise à ce front, lecture
# tenue sur AD tant que DS = 1 et R/W = 1, écriture au front descendant
# de DS avec R/W = 0 ; erreurs : AS ou R/W qui bougent DS haut, conflit
# sur AD (puce et PIA en sorties), AD pas tout en sorties à un front.
# Le temps : 1 s = SECONDE pas ; UIP passe à 1 UIP_AVANT pas avant la mise
# à jour, qui dure MAJ pas, octets d'heure illisibles pendant (rendus EE).
# Vérifie : pas de carte, pile neuve (VRT), horloge pas réglée, réglage
# (registres, SET pendant les écritures, A = $20, B = $02, affichage),
# jour de la semaine contre Python sur des dates choisies, années à 2
# chiffres, dates et heures refusées sans rien écrire, et une lecture
# jamais incohérente quelle que soit la phase de la mise à jour (passage
# du 31/12/2026 23:59:59 au 01/01/2027) ; PIA laissé au repos.
#   make -C bios && make -C cmd && python3 test/verifie_horloge.py
# ===================================================================
import datetime
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)
import verifie_asm as va        # noqa: E402
import verifie_fs as v          # noqa: E402
import verifie_dossiers as vd   # noqa: E402

PRA, PRB, CRA, CRB = 0xA040, 0xA041, 0xA042, 0xA043


def symbole_horloge(nom):
    for ligne in open(os.path.join(os.path.dirname(ICI), 'cmd', 'HORLOGE.map')):
        p = ligne.split()
        if len(p) >= 4 and p[0] == 'Symbol:' and p[1] == nom:
            return int(p[-1], 16)
    raise KeyError(nom)


HOR_INIT = symbole_horloge('Hor_Init')
SECONDE = 400_000               # ~ 1,8432 MHz / 4,6 cycles par instruction
UIP_AVANT = 110                 # 244 µs
MAJ = 900                       # 1984 µs
JOURS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi']


def bcd(n):
    return (n // 10) << 4 | n % 10


def debcd(b):
    return (b >> 4) * 10 + (b & 15)


class Rtc:
    def __init__(self):
        self.reg = [0] * 64
        self.erreurs = []
        self.ecrits = []            # (registre, valeur, SET au moment de l'écriture)
        self.adr = 0
        self.lu = None              # valeur tenue sur AD (None : AD relâché)
        self.prev = None            # (AS, DS, RW)
        self.phase = 0              # pas de la prochaine mise à jour
        self.ok_pas = 0

    def regle_heure(self, dt):
        r = self.reg
        r[0], r[2], r[4] = bcd(dt.second), bcd(dt.minute), bcd(dt.hour)
        r[6] = dt.isoweekday() % 7 + 1
        r[7], r[8], r[9] = bcd(dt.day), bcd(dt.month), bcd(dt.year - 2000)
        r[10], r[11], r[13] = 0x20, 0x02, 0x80

    def heure(self):
        r = self.reg
        return datetime.datetime(2000 + debcd(r[9]), debcd(r[8]), debcd(r[7]),
                                 debcd(r[4]), debcd(r[2]), debcd(r[0]))

    def marche(self):
        return (self.reg[10] & 0x70) == 0x20 and not (self.reg[11] & 0x80)

    def avance(self, pas):
        """Mises à jour échues ; rend (UIP, en cours de mise à jour)."""
        if not self.marche():
            return 0, False
        while pas >= self.phase + MAJ:
            avant = self.heure()
            dt = avant + datetime.timedelta(seconds=1)
            js = self.reg[6] % 7 + 1 if dt.day != avant.day else self.reg[6]
            self.regle_heure(dt)
            self.reg[6] = js            # la puce compte le jour, ne le calcule pas
            self.phase += SECONDE
        if pas >= self.phase:
            return 1, True
        return (1 if pas >= self.phase - UIP_AVANT else 0), False

    def lit(self, a, pas):
        uip, maj = self.avance(pas)
        r = self.reg
        if a < 10:
            return 0xEE if maj else r[a]
        if a == 10:
            return (r[10] & 0x7F) | uip << 7
        if a == 12:
            v_ = r[12]
            r[12] = 0
            return v_
        if a == 13:
            v_ = r[13]
            r[13] |= 0x80               # VRT : mis à 1 par la lecture
            return v_
        return r[a]

    def ecrit(self, a, v_, pas):
        self.avance(pas)
        self.ecrits.append((a, v_, bool(self.reg[11] & 0x80)))
        if a == 10:
            if (v_ & 0x70) == 0x20 and (self.reg[10] & 0x70) != 0x20:
                self.phase = pas + SECONDE // 2     # première mise à jour 0,5 s après
            self.reg[10] = v_ & 0x7F
        elif a == 11:
            if (self.reg[11] & 0x80) and not (v_ & 0x80):
                self.phase = pas + SECONDE          # SET levé : le compte repart
            self.reg[11] = v_
        elif a not in (12, 13):
            self.reg[a] = v_

    def broches(self, as_, ds, rw, ad, ad_sorties, pas):
        if self.prev is None:
            self.prev = (as_, ds, rw)
        pas_, pds, prw = self.prev
        if pds and ds:
            if as_ != pas_:
                self.erreurs.append('AS bouge pendant DS = 1')
            if rw != prw:
                self.erreurs.append('R/W bouge pendant DS = 1')
        if pds != ds and prw != rw:
            self.erreurs.append('DS et R/W changent ensemble : une écriture selon qui gagne')
        if pas_ == 1 and as_ == 0:
            if ds:
                self.erreurs.append('DS haut au front de AS : mode concurrent')
            if ad_sorties != 0xFF:
                self.erreurs.append('adresse : AD pas en sorties (DDRA=%02X)' % ad_sorties)
            self.adr = ad & 0x3F
        if not pds and ds and rw:
            self.lu = self.lit(self.adr, pas)
        if not (ds and rw):
            self.lu = None
        if pds and not ds and not prw and not rw:
            if ad_sorties != 0xFF:
                self.erreurs.append('écriture : AD pas en sorties (DDRA=%02X)' % ad_sorties)
            self.ecrit(self.adr, ad, pas)
        self.prev = (as_, ds, rw)


class Machine(va.MachineAsm):
    def __init__(self, image, s):
        super().__init__(image, s)
        self.rtc = None                 # None : pas de carte
        self.ora = self.ddra = self.orb = 0
        self.ddrb, self.cra, self.crb = 0xFF, 0x34, 0x04
        self.orb = 0x02
        self.dernier_io = 0

    def ca2(self):
        return (self.cra >> 3) & 1 if (self.cra & 0x30) == 0x30 else 0     # R9 : AS tiré à 0

    def pb(self):
        return (self.orb & self.ddrb) | (~self.ddrb & 0xFF)

    def pa(self):
        v_ = (self.ora & self.ddra) | (~self.ddra & 0xFF)
        if self.rtc is not None and self.rtc.lu is not None:
            if self.ddra:
                self.rtc.erreurs.append('conflit sur AD : DDRA=%02X pendant une lecture' % self.ddra)
            v_ = (self.ora & self.ddra) | (self.rtc.lu & ~self.ddra & 0xFF)
        return v_

    def bouge(self):
        if self.rtc is not None:
            pb = self.pb()
            self.rtc.broches(self.ca2(), pb & 1, (pb >> 1) & 1,
                             (self.ora & self.ddra) | (~self.ddra & 0xFF), self.ddra, self.steps)

    def rd8(self, a):
        a &= 0xFFFF
        if a == PRA:
            return self.pa() if self.cra & 4 else self.ddra
        if a == PRB:
            return self.pb() if self.crb & 4 else self.ddrb
        if a == CRA:
            return self.cra
        if a == CRB:
            return self.crb
        return super().rd8(a)

    def wr8(self, a, v_):
        a &= 0xFFFF
        v_ &= 0xFF
        if 0xA000 <= a < 0xC000:
            self.dernier_io = a
        if a == PRA:
            if self.cra & 4:
                self.ora = v_
            else:
                self.ddra = v_
        elif a == PRB:
            if self.crb & 4:
                self.orb = v_
            else:
                self.ddrb = v_
        elif a == CRA:
            self.cra = (self.cra & 0xC0) | (v_ & 0x3F)
        elif a == CRB:
            self.crb = (self.crb & 0xC0) | (v_ & 0x3F)
        else:
            return super().wr8(a, v_)
        self.bouge()


def main():
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    b = vd.Banc()
    m = Machine(b.image, b.s)
    v.installe_bios(m)          # table des services, et BIOS2
    m.mem[b.s['current_page']] = 0
    b.m = m

    def lance(*args, rtc=True):
        if rtc:
            m.rtc.erreurs, m.rtc.ecrits = [], []
        return b.commande('HORLOGE', *args)

    def repos_b():
        return (m.crb & 0x04) and m.ddrb == 0xFF and m.pb() & 3 == 2

    def repos():
        pb = m.pb()
        return (m.cra & 0x3F) == 0x34 and m.ddra == 0xFF and pb & 3 == 2

    def pia_reset():
        m.ora = m.ddra = m.orb = m.ddrb = m.cra = m.crb = 0
        m.rtc.prev = None
        m.bouge()                       # PB en entrée : DS = R/W = 1 (tirages)

    # --- après un RESET : la puce alimentée garde son dernier registre
    # adressé (B après un réglage) ; ni main ni Hor_Init n'y écrivent ---
    m.rtc = Rtc()
    m.rtc.regle_heure(datetime.datetime(2026, 11, 9, 20, 0))
    m.rtc.adr = 11
    pia_reset()
    m.rtc.erreurs, m.rtc.ecrits = [], []
    m.pc, m.s = b.s['main'], 0xDF00
    pas = 0
    while not (0xA080 <= m.dernier_io < 0xA088) and pas < 200:
        m.step()
        pas += 1
    verifie(not m.rtc.ecrits and not m.rtc.erreurs and m.rtc.reg[11] == 0x02 and repos_b(),
            'main du BIOS après un RESET : aucune écriture dans la puce (%s %s), PB = %02X'
            % (m.rtc.ecrits[:2], m.rtc.erreurs[:2], m.pb()))
    pia_reset()
    m.rtc.erreurs, m.rtc.ecrits = [], []
    code = open(os.path.join(os.path.dirname(ICI), 'cmd', 'HORLOGE'), 'rb').read()
    m.banks[1][:len(code)] = code
    m.mem[b.s['current_page']] = 1
    m.page = 1
    v.appelle(m, HOR_INIT)
    m.mem[b.s['current_page']] = 0
    m.page = 0
    verifie(not m.rtc.ecrits and not m.rtc.erreurs and repos(),
            'Hor_Init sur un PIA remis à zéro : aucune écriture, PIA au repos (%s %s)'
            % (m.rtc.ecrits[:2], m.rtc.erreurs[:2]))
    m.rtc = None
    m.cra, m.crb, m.ddrb, m.orb, m.ddra = 0x34, 0x04, 0xFF, 0x02, 0

    # --- pas de carte : le port A tiré à 1 ---
    t = lance(rtc=False)
    verifie('pas de réponse' in t.lower().replace('\x82', 'é') and repos(), 'sans carte : « %s », PIA au repos' % t)

    # --- pile neuve : VRT = 0, rien de réglé ---
    m.rtc = Rtc()
    t = lance().replace('\x82', 'é').replace('\x83', 'â')
    verifie('pile' in t and 'pas réglée' in t and not m.rtc.ecrits and not m.rtc.erreurs,
            'pile neuve : « %s »' % t)
    t = lance().replace('\x82', 'é')
    verifie('pile' not in t and 'pas réglée' in t, 'VRT remis à 1 par la lecture : « %s »' % t)

    # --- réglage ---
    t = lance('06/11/2026', '19:45:00')
    r = m.rtc.reg
    tps = [e for e in m.rtc.ecrits if e[0] < 10]
    verifie(t == 'vendredi 06/11/2026 19:45:00|', 'réglage puis affichage : « %s »' % t)
    verifie([r[i] for i in (0, 2, 4, 6, 7, 8, 9)] == [0, 0x45, 0x19, 6, 6, 0x11, 0x26]
            and r[10] == 0x20 and r[11] == 0x02,
            'registres 0-9 en BCD, A = %02X, B = %02X' % (r[10], r[11]))
    verifie(len(tps) == 7 and all(e[2] for e in tps), 'les 7 octets écrits avec SET = 1')
    verifie(not m.rtc.erreurs and repos(), 'protocole du bus respecté, PIA au repos %s'
            % (m.rtc.erreurs[:3] or ''))
    m.steps += 3 * SECONDE + 1000
    t = lance()
    verifie(t == 'vendredi 06/11/2026 19:45:03|', '3 s plus tard : « %s »' % t)

    # --- jour de la semaine et formes acceptées ---
    dates = [('1/1/2000', '0:00', datetime.datetime(2000, 1, 1)),
             ('29/02/2000', '12:00:00', datetime.datetime(2000, 2, 29, 12)),
             ('1/3/2000', '0:0', datetime.datetime(2000, 3, 1)),
             ('28/02/2001', '23:59:59', datetime.datetime(2001, 2, 28, 23, 59, 59)),
             ('29/2/24', '7:05', datetime.datetime(2024, 2, 29, 7, 5)),
             ('6/11/26', '9:05', datetime.datetime(2026, 11, 6, 9, 5)),
             ('14/07/2089', '22:30:15', datetime.datetime(2089, 7, 14, 22, 30, 15)),
             ('31/12/2099', '23:59:59', datetime.datetime(2099, 12, 31, 23, 59, 59))]
    d0 = datetime.date(2000, 1, 1)
    for k in range(40):                                 # un jour sur 913 : tous les mois, tous les jours
        d = d0 + datetime.timedelta(days=k * 913)
        dates.append(('%d/%d/%d' % (d.day, d.month, d.year), '1:02:03',
                      datetime.datetime(d.year, d.month, d.day, 1, 2, 3)))
    mauvais_js = []
    for jour, heure, dt in dates:
        t = lance(jour, heure)
        attendu = '%s %02d/%02d/%04d %02d:%02d:%02d|' % (JOURS[dt.isoweekday() % 7], dt.day, dt.month,
                                                        dt.year, dt.hour, dt.minute, dt.second)
        if t != attendu or m.rtc.reg[6] != dt.isoweekday() % 7 + 1 or m.rtc.erreurs:
            mauvais_js.append('%s %s -> %s' % (jour, heure, t))
    verifie(not mauvais_js, '%d dates : jour de la semaine et affichage %s' % (len(dates), mauvais_js[:3]))

    # --- refusés sans rien écrire ---
    refus = [('31/04/2026', '12:00'), ('29/02/2025', '12:00'), ('0/1/2026', '12:00'),
             ('32/1/2026', '12:00'), ('1/13/2026', '12:00'), ('1/0/2026', '12:00'),
             ('1/1/2100', '12:00'), ('1/1/1999', '12:00'), ('1/1/202', '12:00'),
             ('1/1/20261', '12:00'), ('1-1-2026', '12:00'), ('1/1/2026x', '12:00'),
             ('123/1/2026', '12:00'), ('1/1/2026', '24:00'), ('1/1/2026', '12:60'),
             ('1/1/2026', '12:00:60'), ('1/1/2026', '12'), ('1/1/2026', '12:'),
             ('1/1/2026', '12:00:'), ('1/1/2026', 'midi'), ('', '12:00')]
    acceptes = [x for x in refus
                if (lambda t: 'invalide' not in t or m.rtc.ecrits)(lance(*x))]
    verifie(not acceptes, '%d dates ou heures refusées sans écriture %s' % (len(refus), acceptes[:3]))
    t = lance('1/1/2026')
    verifie(t.startswith('Usage') and not m.rtc.ecrits, 'un seul argument : usage')

    # --- horloge arrêtée ou dans un autre mode ---
    for reg, val, quoi in ((11, 0x82, 'SET = 1'), (11, 0x06, 'binaire'), (11, 0x00, '12 h'),
                           (10, 0x60, 'diviseur arrêté')):
        m.rtc.regle_heure(datetime.datetime(2026, 11, 6))
        m.rtc.reg[reg] = val
        t = lance().replace('\x82', 'é')
        verifie('pas réglée' in t, '%s : « %s »' % (quoi, t))

    # --- lecture au moment de la mise à jour : jamais un mélange ---
    avant = 'jeudi 31/12/2026 23:59:59|'
    apres = 'vendredi 01/01/2027 00:00:00|'
    vus, faux = {}, []
    for decalage in range(-1500, 600, 20):
        m.rtc.regle_heure(datetime.datetime(2026, 12, 31, 23, 59, 59))
        m.rtc.phase = m.steps + 1500 + decalage + UIP_AVANT     # la lecture commence vers là
        t = lance()
        vus[t] = vus.get(t, 0) + 1
        if t not in (avant, apres) or m.rtc.erreurs:
            faux.append((decalage, t, m.rtc.erreurs[:1]))
    verifie(not faux and len(vus) == 2,
            'passage à 2027, %d phases : %s %s' % (sum(vus.values()),
                                                  ', '.join('%s x%d' % (k.rstrip('|'), n) for k, n in vus.items()),
                                                  faux[:3]))
    verifie(repos(), 'PIA au repos à la fin : CRA=%02X DDRA=%02X PB=%02X' % (m.cra, m.ddra, m.pb()))

    print()
    if erreurs:
        print('%d ÉCHEC(S)' % len(erreurs))
        sys.exit(1)
    print('tout est bon')


if __name__ == '__main__':
    main()
