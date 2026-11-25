#!/usr/bin/env python3
# ===================================================================
# verifie_bureau.py - Le gestionnaire de fichiers d'OSM-VISION, au clavier
# ===================================================================
# Le VRAI OSM-VISION (page 0, $0000) sur le VRAI BIOS, dans l'émulateur de
# verifie_fs.py, avec une carte OSMFS (tools/egofs). Le clavier est une
# liste de touches rendue par scan_keyboard ; video_wait_vsync rend une
# trame. Vérifie, en relisant la carte : Ctrl+C puis Coller dans un autre
# dossier (contenu, page, adresse, attributs gardés), Ctrl+N (nouveau
# dossier, par la boîte de saisie), Ctrl+X puis Ctrl+V (déplacement),
# Renommer vers un nom qui n'existe qu'à la racine (accepté : pas de
# repli sur la racine), le menu Espace (Copier, Coller par leur lettre).
#   make -C bios osmvision && python3 test/verifie_bureau.py
# ===================================================================
import datetime
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_horloge as vh    # noqa: E402
import carte                    # noqa: E402  (VRAM : v4 ou mono)

HAUT, BAS, ENTREE, ECHAP, ESPACE = 0x80, 0x81, 0x0D, 0x1B, 0x20
LIMITE_TRAME = 1650     # cycles estimés après le signal de trame (voir Bureau)
CTRL_C, CTRL_X, CTRL_V, CTRL_N = 0x03, 0x18, 0x16, 0x0E
REPOS = 0xC0                    # la Clouris branchée, aucun doigt (IOA6-7 libres : 1)
ABSENTE = None                  # rien de branché : R14 = $FF (tirages de l'AY)
# Les essais disent les clous touchés (bit à 1) ; la carte Clouris à
# transistors PNP (lib/clouris.asm, CLOU_INVERSE = 1) donne un 0 par doigt posé :
# R14 lu = contacts ^ $3F.


def r14(contacts):
    return 0xFF if contacts is ABSENTE else contacts ^ 0x3F


class Fini(Exception):
    pass


class Bureau(va.MachineAsm):
    """touches : codes du clavier, ou (R14, n) : la Clouris tient R14 pendant
    n lectures du port A (une par trame), sans touche."""

    def __init__(self, image, s, touches):
        super().__init__(image, s)
        self.touches = list(touches)
        self.port_a = REPOS
        # Budget de la VRAM : cycles ESTIMÉS depuis le signal de trame (retour
        # de video_wait_vsync), 4 par instruction et 6 + 3 par octet d'un TFM
        # (mesuré sur la carte : 6 + 3n) ; cyc_max = le plus tard qu'une
        # écriture VRAM soit tombée dans sa trame, compté après la première
        # touche lue si mesure_cycles (le dessin initial n'est pas mesuré).
        self.mesure_cycles = False
        self.cyc = 0
        self.cyc_max = 0
        self.pc_i = 0

    def wr8(self, a, val):
        # (les écritures du BIOS ne comptent pas : son indicateur de
        # chargement, en haut à droite, écrit sans synchronisation)
        if self.mesure_cycles == 'actif' and 0x8000 <= a & 0xFFFF < 0xA000 and self.pc_i < 0x8000:
            self.cyc_max = max(self.cyc_max, self.cyc)
        # une lecture de la Clouris par trame : elle commence par le choix de
        # R14 (l'émulateur relit aussi l'adresse d'un STA : on ne compte pas
        # les lectures)
        if a & 0xFFFF == v.AY_ADR and val & 255 == 14:
            t = self.touches
            self.port_a = REPOS
            if t and isinstance(t[0], tuple):
                self.port_a, n = t[0]
                if n <= 1:
                    t.pop(0)
                else:
                    t[0] = (self.port_a, n - 1)
        super().wr8(a, val)

    def lit_port_a(self):
        return r14(self.port_a)

    def step(self):
        s, pc = self.s_, self.pc
        if pc in (s['scan_keyboard'], s['kbd_poll']):
            t = self.touches
            if t and isinstance(t[0], tuple):
                if pc == s['scan_keyboard']:
                    raise RuntimeError('scan_keyboard pendant un contact de la Clouris')
                self.a = 0
            elif not t:
                raise Fini()
            else:
                self.a = t.pop(0)
                if self.mesure_cycles:
                    self.mesure_cycles = 'actif'
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            return
        if pc == s['video_wait_vsync']:
            t = self.touches
            if not self.ay_present and t and isinstance(t[0], tuple):
                # sans AY, la Clouris n'est plus lue : une trame à vide = une attente
                port, n = t[0]
                if n <= 1:
                    t.pop(0)
                else:
                    t[0] = (port, n - 1)
            self.wr16(s['vsync_tick'], (self.rd16(s['vsync_tick']) + 1) & 0xFFFF)
            self.pc = (self.rd8(self.s) << 8) | self.rd8(self.s + 1)
            self.s += 2
            self.cyc = 0
            return
        self.pc_i = pc
        if self.mem[pc] == 0x11 and self.mem[pc + 1] in (0x38, 0x39, 0x3A, 0x3B) if pc >= 0x8000 else \
                self.banks[self.page][pc] == 0x11 and self.banks[self.page][pc + 1] in (0x38, 0x39, 0x3A, 0x3B):
            self.cyc += 6 + 3 * self.w
        else:
            self.cyc += 4
        super().step()


class BureauRtc(vh.PiaRtc, Bureau):
    """Le bureau avec le PIA et la carte RTC de verifie_horloge."""


def lance(c, s, touches, ov, rtc=None, sans_ay=False, mesure=False):
    if rtc is None:
        m = Bureau(c.image, s, touches)
    else:
        m = BureauRtc(c.image, s, touches)
        m.pia_init()
        m.rtc = rtc
    m.ay_present = not sans_ay
    m.mesure_cycles = mesure
    v.installe_bios(m)          # table des services, et BIOS2
    code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()
    m.banks[0][:len(code)] = code
    m.mem[s['son_coupe']] = 0x4D                # son coupé (RAM système) : pas d'attente de partition
    m.mem[s['current_page']] = 0
    m.page = 0
    m.steps = 0
    try:
        v.appelle(m, 0x0000, 80_000_000)
        r = 'rendu'
    except Fini:
        r = 'touches'
    except RuntimeError as e:
        r = str(e)
    return m, r


def main():
    s = v.sym()
    ov = {n: int(a, 16) for n, a in re.findall(
        r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(os.path.join(RACINE, 'osmvision', 'OSMVISION.map')).read())}
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)

    d = tempfile.mkdtemp()
    c = va.Carte(d)
    contenu = bytes((i * 13) & 255 for i in range(3000))
    for nom, data, page, adr, attr in (('ZJEU', contenu, 0, '4000', 0x17), ('EDIT', b'e' * 10, 0, '4000', 0x17)):
        p = os.path.join(d, nom)
        open(p, 'wb').write(data)
        c.ajoute(nom, p, page=page, adresse=adr, attr=attr)
    c.core.mkdir('APPS')
    # racine triée : APPS (dossier), EDIT, ZJEU
    m, r = lance(c, s, [BAS, BAS, CTRL_C, HAUT, HAUT, ENTREE, CTRL_V], ov)
    e = c.entree('APPS/ZJEU')
    verifie(r == 'touches' and e is not None, 'Ctrl+C sur ZJEU, Entrée sur APPS, Ctrl+V : APPS/ZJEU créé (%s)' % r)
    verifie(e and c.lit('APPS/ZJEU') == contenu and e['page'] == 0 and int(e['addr'], 16) == 0x4000
            and e['attr'] == 0x17, 'la copie : même contenu (3000 octets), page 0, $4000, attributs $17')
    verifie(c.entree('ZJEU') is not None, 'l\'original est resté à la racine')

    # Ctrl+N dans APPS : boîte de saisie, nom tapé, Entrée
    m, r = lance(c, s, [ENTREE, CTRL_N] + [ord(x) for x in 'SOUS'] + [ENTREE], ov)
    e = c.entree('APPS/SOUS')
    verifie(e is not None and e['is_dir'], 'Ctrl+N dans APPS, « SOUS », Entrée : APPS/SOUS est un dossier')

    # Ctrl+X sur APPS/ZJEU, entrer dans SOUS, Ctrl+V : déplacé
    # APPS trié : .., SOUS (dossier), ZJEU
    m, r = lance(c, s, [ENTREE, BAS, BAS, CTRL_X, HAUT, ENTREE, CTRL_V], ov)
    verifie(c.entree('APPS/SOUS/ZJEU') is not None and c.entree('APPS/ZJEU') is None
            and c.lit('APPS/SOUS/ZJEU') == contenu, 'Ctrl+X sur APPS/ZJEU, Entrée sur SOUS, Ctrl+V : déplacé')

    # Renommer dans APPS/SOUS en EDIT (qui n'existe qu'à la racine) : accepté
    m, r = lance(c, s, [ENTREE, BAS, ENTREE, BAS, ESPACE, ord('R')] + [8] * 6 + [ord(x) for x in 'EDIT'] + [ENTREE], ov)
    verifie(c.entree('APPS/SOUS/EDIT') is not None and c.entree('EDIT') is not None,
            'Renommer ZJEU en EDIT dans APPS/SOUS : accepté (EDIT de la racine ne compte pas)')

    # le menu Espace : C (Copier) sur EDIT de la racine, puis entrer dans APPS, Espace L (Coller)
    m, r = lance(c, s, [BAS, ESPACE, ord('C'), HAUT, ENTREE, ESPACE, ord('L')], ov)
    verifie(c.entree('APPS/EDIT') is not None and c.lit('APPS/EDIT') == b'e' * 10,
            'menu Espace : C sur EDIT, Entrée sur APPS, Espace L : APPS/EDIT copié')

    # l'icône du son (barre d'état, page 1 $1C + $1D/$1E) et le panneau d'aide (?)
    def ecran(m):
        return carte.lit(m.mem, 0, 2000)
    st = 23 * 80 + 12 + 9
    m0, r = lance(c, s, [], ov)
    car, col = ecran(m0)
    verifie(car[st:st + 2] == b'\x1c\x1e' and col[st] & 0x80 and col[st + 1] & 0x80,
            'son coupé : haut-parleur barré ($1C $1E, page 1) dans la barre d\'état')
    m, r = lance(c, s, [ord('M')], ov)
    car, col = ecran(m)
    verifie(car[st:st + 2] == b'\x1c\x1d' and col[st] & 0x80, 'M : haut-parleur avec ses ondes ($1C $1D)')
    m, r = lance(c, s, [ord('?')], ov)
    car, col = ecran(m)
    ligne = lambda r_: car[r_ * 80 + 54:r_ * 80 + 78].decode('latin-1')     # noqa: E731
    verifie(ligne(6).startswith('Haut, Bas   choisir') and ligne(20).startswith('Echap       quitter')
            and ov.get('AideOn') is not None and m.banks[0][ov['AideOn']] == 1,
            '? : le panneau des raccourcis à droite (« %s » ... « %s »)' % (ligne(6).strip(), ligne(20).strip()))
    verifie(car[:52] == ecran(m0)[0][:52] and all(car[r_ * 80:r_ * 80 + 50] == ecran(m0)[0][r_ * 80:r_ * 80 + 50]
                                                 for r_ in range(25)),
            '? : la fenêtre des fichiers (colonnes 0-49) intacte')
    m, r = lance(c, s, [ord('?'), ord('?')], ov)
    diff = [(i % 80, i // 80, p_) for p_ in (0, 1) for i in range(2000) if ecran(m)[p_][i] != ecran(m0)[p_][i]]
    verifie(not diff and m.banks[0][ov['AideOn']] == 0,
            '? puis ? : l\'écran redevient exactement celui du départ%s'
            % (' (cases différentes (colonne, rangée, plan) : %s)' % diff[:6] if diff else ''))
    m, r = lance(c, s, [ord('?'), ESPACE, ECHAP], ov)
    car, col = ecran(m)
    verifie(ligne(6).startswith('Haut, Bas'), '? puis le menu Espace ouvert et fermé : le panneau est toujours là')

    # Accents : le clavier donne du Latin-1, la police est en CP437 ; la saisie
    # (vis_Input -> Put_Text) les traduit en dessinant. Un nom de fichier
    # (INP_MAJ) les refuse : Renommer, « é » ne s'inscrit pas
    m, r = lance(c, s, [9, 0xE9, 0xE8, 0xE0, 0xE7, 0xF9, 0xC9], ov)
    car, col = ecran(m)
    attendu = bytes([0x82, 0x8A, 0x85, 0x87, 0x97, 0x90])       # é è à ç ù É en CP437
    verifie(attendu in car and not any(b in car for b in (0xE9, 0xE8, 0xE0, 0xE7, 0xF9, 0xC9)),
            'Exécuter (Tab), « éèàçùÉ » tapé (Latin-1) : dessiné en CP437 (%s)'
            % ' '.join('$%02X' % b for b in attendu))
    m, r = lance(c, s, [ESPACE, ord('R')] + [8] * 15 + [0xE9, ord('Q'), ord('W')], ov)
    car, col = ecran(m)
    i = car.find(b'QW_')                         # ($82 ailleurs : les icônes, page 1)
    verifie(i > 0 and car[i - 1] not in (0x82, 0xE9),
            'Renommer (nom de fichier, INP_MAJ) : « é » refusé, « QW » inscrit')

    # Sans AY-3-8910 (puce retirée) : la Clouris lit le bus vide ($50 : des
    # bits à 0, donc des « doigts posés »). La sonde de Clou_Lit le voit :
    # pas de pointeur, et le clavier marche (M change l'icône du son)
    m, r = lance(c, s, [(REPOS, 20), ord('M'), (REPOS, 3)], ov, sans_ay=True)
    car, col = ecran(m)
    verifie(r == 'touches' and m.banks[0][ov['PtrVu']] == 0 and m.banks[0][ov['PtrOn']] == 0
            and car[st:st + 2] == b'\x1c\x1d',
            'sans AY (bus vide) : pas de pointeur ni de clic fantôme, M change l\'icône du son (%s)' % r)
    m, r = lance(c, s, [(REPOS, 3)], ov)
    verifie(m.ay_regs[1] == 0 and m.ay_present,
            'avec l\'AY : la sonde rend au registre R1 sa valeur (R1 = $%02X)' % m.ay_regs[1])

    # La date et l'heure dans la barre d'état (rangée 23, colonnes 25-40),
    # lues sur la carte RTC (modèle de verifie_horloge : PIA et MC146818)
    HOR = 23 * 80 + 25
    def barre(m):
        return bytes(carte.lit(m.mem, 0, 2000)[0][HOR:HOR + 16])
    m0, r = lance(c, s, [(REPOS, 3)], ov)
    verifie(r == 'touches' and barre(m0) == bytes(16) and barre(m0) == bytes(ecran(m0)[0][HOR:HOR + 16]),
            'sans carte RTC : rien dans la barre d\'état après l\'icône du son, pas de blocage (%s)' % r)
    rtc = vh.Rtc()
    rtc.regle_heure(datetime.datetime(2026, 11, 14, 18, 32, 7))
    m, r = lance(c, s, [(REPOS, 3)], ov, rtc=rtc)
    car, col = ecran(m)
    verifie(r == 'touches' and barre(m) == b'14/11/2026 18:32' and all(x == 0x0F for x in col[HOR:HOR + 16])
            and car[HOR - 4:HOR - 2] in (b'\x1c\x1d', b'\x1c\x1e'),
            'carte RTC le 14/11/2026 à 18:32:07 : « %s » après l\'icône du son (COLOR_TEXT)'
            % barre(m).decode('latin-1'))
    verifie(not rtc.erreurs and not rtc.ecrits,
            'OSM-VISION ne fait que lire l\'horloge : rien d\'écrit dans la puce, règles du bus tenues (%s)'
            % (rtc.erreurs[:2] or rtc.ecrits[:2] or 'rien'))
    def reveillon():
        r_ = vh.Rtc()
        r_.regle_heure(datetime.datetime(2026, 12, 31, 23, 59, 59))
        r_.phase = vh.SECONDE // 2              # la seconde suivante dans 0,5 s
        return r_
    m, r = lance(c, s, [(REPOS, 3)], ov, rtc=reveillon())
    avant = barre(m)
    m, r = lance(c, s, [(REPOS, 3000)], ov, rtc=reveillon())
    verifie(avant == b'31/12/2026 23:59' and barre(m) == b'01/01/2027 00:00',
            'la minute passe : « %s », puis « %s » %.1f s plus tard (relue toutes les 60 trames)'
            % (avant.decode('latin-1'), barre(m).decode('latin-1'), m.steps / vh.SECONDE))
    rtc = vh.Rtc()
    rtc.regle_heure(datetime.datetime(2026, 11, 14, 18, 32, 7))
    rtc.reg[4] = 0x3F                                   # heure jamais réglée
    rtc.reg[10] = 0                                     # (et l'horloge arrêtée)
    m, r = lance(c, s, [(REPOS, 3)], ov, rtc=rtc)
    verifie(barre(m) == b'14/11/2026 3-:32', 'chiffre BCD impossible (heure $3F) : « - » (« %s »)'
            % barre(m).decode('latin-1'))

    # la Clouris (R14) : un contact compte à la 2e trame, puis répétition
    # après 12 trames, un pas toutes les 3 ; pointeur parti de (30, 12)
    def tape(v, n=1):
        return [(v, 2), (REPOS, 2)] * n
    po = lambda m: (m.banks[0][ov['PtrX']], m.banks[0][ov['PtrY']])     # noqa: E731
    m, r = lance(c, s, [(REPOS, 10), (ABSENTE, 10)], ov)
    verifie(ecran(m) == ecran(m0) and m.banks[0][ov['PtrVu']] == 0,
            'Clouris au repos (R14 = $FF), puis absente ($FF) : pas de pointeur, écran inchangé')
    m, r = lance(c, s, tape(0xC2), ov)
    car, col = ecran(m)
    k = 12 * 80 + 31
    car0, col0 = ecran(m0)
    verifie(po(m) == (31, 12) and car[k] == 0x1F and col[k] == 0x86 | (col0[k] & 0x70)
            and car[:k] + car[k + 1:] == car0[:k] + car0[k + 1:] and col[:k] + col[k + 1:] == col0[:k] + col0[k + 1:],
            'droite effleuré : la flèche ($1F, page 1, jaune sur le fond) en (31, 12), le reste intact %s' % (po(m),))
    m, r = lance(c, s, [(0xC4, 20), (REPOS, 2)], ov)
    verifie(po(m) == (30, 16), 'bas tenu 20 trames : 4 pas (2e trame, 14e, 17e, 20e) %s' % (po(m),))
    m, r = lance(c, s, [(0xC0 | 0x09, 2), (REPOS, 2)], ov)
    verifie(po(m) == (29, 11), 'haut + gauche ensemble : en diagonale %s' % (po(m),))
    # vers ZJEU (ligne 9) : la ligne survolée devient la sélection, en bleu
    # comme au clavier ; puis APPS (ligne 7), un clic : on y entre
    m, r = lance(c, s, tape(0xC1, 3) + tape(0xC8, 10), ov)
    car, col = ecran(m)
    verifie(po(m) == (20, 9) and m.banks[0][ov['Selection']] == 2 and col[9 * 80 + 15:9 * 80 + 30] == bytes([0x1F]) * 5 + b'\x96' + bytes([0x1F]) * 9
            and col[7 * 80 + 15:7 * 80 + 30] == bytes([0x0F]) * 15 and car[9 * 80 + 20] == 0x1F,
            'pointeur sur ZJEU : sélectionné et recoloré, la flèche par-dessus (jaune sur bleu, $96) (%d)' % m.banks[0][ov['Selection']])
    m, r = lance(c, s, tape(0xC1, 3) + tape(0xC8, 10) + tape(0xC1, 2) + tape(0xE0), ov)
    verifie(m.mem[s['fs_dossier']:s['fs_dossier'] + 2] != b'\0\0' and m.banks[0][ov['Selection']] == 0,
            'pointeur sur ZJEU puis sur APPS, un clic : on entre dans le dossier')
    m, r = lance(c, s, tape(0xC8, 25) + tape(0xC1, 3), ov)
    verifie(po(m) == (5, 9) and m.banks[0][ov['Selection']] == 0, 'hors de la liste (colonne 5) : la sélection ne bouge pas')
    m, r = lance(c, s, tape(0xD0), ov)
    car, col = ecran(m)
    verifie(b'Ouvrir' in car[9 * 80:10 * 80] and car[19 * 80 + 27:19 * 80 + 38] == b' Supprimer ',
            'centre : le menu Espace s\'ouvre')
    # menu en ligne 8 (entrées lignes 9-20, colonnes 27-46) ; flèche en (30, 12)
    m, r = lance(c, s, tape(0xD0) + tape(0xC4, 2), ov)
    car, col = ecran(m)
    k2 = 14 * 80 + 30
    verifie(m.banks[0][ov['MenuSel']] == 5 and car[k2] == 0x1F and col[14 * 80 + 28] == 0x1F
            and car[14 * 80 + 27:14 * 80 + 30] == b' Co' and car[14 * 80 + 31:14 * 80 + 34] == b'per',
            'centre, puis bas, bas : la flèche sur « Couper », qui passe en bleu (6e entrée)')
    m, r = lance(c, s, tape(0xD0) + tape(0xC4, 2) + tape(0xD0), ov)
    car, col = ecran(m)
    verifie(m.banks[0][ov['MenuSel']] == 5 and car[:k2] == car0[:k2] and car[k2 + 1:] == car0[k2 + 1:]
            and col[:k2] == col0[:k2] and col[k2 + 1:] == col0[k2 + 1:],
            'centre, bas, bas, centre : menu refermé, écran rendu (la flèche seule en plus)')
    m, r = lance(c, s, [BAS] + tape(0xD0) + tape(0xC4, 2) + tape(0xE0), ov)
    verifie(m.banks[0][ov['ClipMode']] == 1, 'sur EDIT : centre, flèche sur « Copier », pouce : copié (ClipMode %d)'
            % m.banks[0][ov['ClipMode']])
    m, r = lance(c, s, tape(0xD0) + tape(0xC8, 10) + tape(0xE0), ov)
    car, col = ecran(m)
    verifie(m.banks[0][ov['ClipMode']] == 0 and car[:k2 - 300] == car0[:k2 - 300],
            'centre, flèche hors du menu, pouce : menu refermé, rien de fait')

    # une liste de 20 fichiers : la flèche poussée contre le bas, puis le haut
    d2 = tempfile.mkdtemp()
    c2 = va.Carte(d2)
    for i in range(20):
        p_ = os.path.join(d2, 'F%02d' % i)
        open(p_, 'wb').write(b'x')
        c2.ajoute('F%02d' % i, p_, page=1, adresse='0000', attr=0x07)
    sel = lambda m: (m.banks[0][ov['Selection']], m.banks[0][ov['TopIndex']])     # noqa: E731
    m, r = lance(c2, s, tape(0xC4, 13), ov)
    car, col = ecran(m)
    verifie(po(m) == (30, 22) and sel(m) == (18, 3) and car[7 * 80 + 15:7 * 80 + 18] == b'F03'
            and car[22 * 80 + 15:22 * 80 + 18] == b'F18' and col[22 * 80 + 15] == 0x1F,
            'bas 13 fois : la flèche s\'arrête en bas de la liste, qui défile de 3 lignes (sélection, haut) = %s' % (sel(m),))
    m, r = lance(c2, s, tape(0xC4, 13) + tape(0xC1, 17), ov)
    car, col = ecran(m)
    verifie(po(m) == (30, 7) and sel(m) == (1, 1) and car[7 * 80 + 15:7 * 80 + 18] == b'F01',
            'puis haut 17 fois : la flèche monte en haut de la liste, qui redescend de 2 lignes = %s' % (sel(m),))
    m, r = lance(c2, s, tape(0xC4, 30), ov)
    verifie(sel(m) == (19, 4) and po(m) == (30, 24),
            'bas 30 fois : la liste s\'arrête au dernier fichier, la flèche sort par le bas = %s %s' % (sel(m), po(m)))
    # Défiler au clavier : la VRAM n'est écrite que dans la fenêtre de retour
    # de trame (~1990 cycles après le signal, ~300 pris par l'IRQ : mesures
    # de la carte, tools/tele/essai_cycles.asm). Avant : 16 noms case par case
    # d'un coup, ~5000 cycles estimés, parasites en haut de l'écran.
    m, r = lance(c2, s, [BAS] * 19 + [HAUT] * 19, ov, mesure=True)
    car, col = ecran(m)
    verifie(r == 'touches' and sel(m) == (0, 0) and m.cyc_max <= LIMITE_TRAME
            and car[7 * 80 + 15:7 * 80 + 18] == b'F00' and col[7 * 80 + 15] == 0x1F
            and col[8 * 80 + 15] == 0x0F and car[22 * 80 + 15:22 * 80 + 18] == b'F15',
            'bas 19 fois puis haut 19 fois au clavier : la liste défile, écritures VRAM '
            'au plus %d cycles après le signal (limite %d)' % (m.cyc_max, LIMITE_TRAME))
    # Entrer dans un dossier puis en ressortir (Full_Redraw : la fenêtre de
    # la liste, puis la liste) : même budget. Avant : Draw_Window vérifiait
    # son budget après coup, et la liste se préparait dans la fenêtre de
    # l'appelant (~6800 cycles estimés, parasites en haut de l'écran).
    d6 = tempfile.mkdtemp()
    c6 = va.Carte(d6)
    for i in range(5):
        p_ = os.path.join(d6, 'G%02d' % i)
        open(p_, 'wb').write(b'x')
        c6.ajoute('G%02d' % i, p_, page=1, adresse='0000', attr=0x07)
    for i in range(18):
        c6.ajoute('DOS/H%02d' % i, p_, page=1, adresse='0000', attr=0x07)
    m, r = lance(c6, s, [ENTREE, BAS, HAUT, ENTREE, BAS], ov, mesure=True)
    car, col = ecran(m)
    # CALC et EDIT : une ligne de 80 caractères par vis_Text dépassait déjà la
    # fenêtre (~32 cycles par caractère) ; vis_Prep compose hors synchro,
    # vis_Ligne copie par TFM. Avant : 4380 (CALC), 2716 (EDIT).
    for app_, fich, contenu, touches_ in (
            ('CALC', 'A.CAL', b'', [0x83] * 3 + [0x81] * 3 + [0x82, 0x80]),
            ('EDIT', 'A.TXT', b''.join(b'ligne %03d du texte\r\n' % i for i in range(60)), [0x81] * 30 + [0x80] * 3)):
        d7 = tempfile.mkdtemp()
        c7 = va.Carte(d7)
        c7.ajoute('BIN/' + app_, os.path.join(RACINE, 'apps', app_), page=1, adresse='0000', attr=0x17)
        p_ = os.path.join(d7, 'f')
        open(p_, 'wb').write(contenu)
        c7.ajoute(fich, p_, attr=0x06)
        m, r = lance(c7, s, [BAS, ENTREE] + touches_, ov, mesure=True)
        verifie(r == 'touches' and m.page == 1 and m.cyc_max <= LIMITE_TRAME,
                '%s : flèches, écritures VRAM du programme au plus %d cycles après le signal (limite %d)'
                % (app_, m.cyc_max, LIMITE_TRAME))

    # l'ombre de la fenêtre de la liste (rangée 25, colonnes 11-50) : un
    # Mono_Budget mal placé dans Draw_Window l'a déjà dessinée de travers
    ombre = all(carte.lit(m.mem, 25 * 80 + 11, 40)[0][i] == 0x02 and carte.lit(m.mem, 25 * 80 + 11, 40)[1][i] == 0x90
                for i in range(40))
    verifie(ombre, 'fenêtre de la liste redessinée : son ombre intacte (rangée 25, UI_SHADOW, COLOR_SHADOW)')
    verifie(r == 'touches' and m.mem[s['fs_dossier']:s['fs_dossier'] + 2] == b'\0\0'
            and car[7 * 80 + 15:7 * 80 + 18] == b'DOS' and car[8 * 80 + 15:8 * 80 + 18] == b'G00'
            and m.cyc_max <= LIMITE_TRAME,
            'entrer dans DOS (18 fichiers) puis en ressortir : écritures VRAM au plus %d cycles '
            'après le signal (limite %d)' % (m.cyc_max, LIMITE_TRAME))

    # coller deux fois au même endroit : refusé (le nom existe), rien d'écrasé
    n_avant = len(c.core.list_files())
    m, r = lance(c, s, [BAS, CTRL_C, HAUT, ENTREE, CTRL_V, ENTREE], ov)
    verifie(len(c.core.list_files()) == n_avant, 'Coller sur un nom qui existe : refusé, rien de créé')

    # association .CAL -> CALC (dans /BIN), la feuille dans BUDGET : Entrée
    # sur BUDGET, Entrée sur MAI.CAL, CALC la lit (en page 3), Echap
    lst = open(os.path.join(RACINE, 'apps', 'calc.lst'), encoding='utf-8', errors='replace').read()
    calc = {n: int(a, 16) for a, n in re.findall(r'^\s+([0-9A-F]{4})\s.*?\s(TEXT_SIZE|TEXT_PAGE)\s+equ', lst, re.M)}
    feuille = bytes((i * 7 + 3) & 0x7F for i in range(calc['TEXT_SIZE']))
    d2 = os.path.join(d, 'b')
    os.makedirs(d2)
    c2 = va.Carte(d2)
    c2.ajoute('BIN/CALC', os.path.join(RACINE, 'apps', 'CALC'), page=1, adresse='0000', attr=0x17)
    p = os.path.join(d2, 'mai')
    open(p, 'wb').write(feuille)
    c2.ajoute('BUDGET/MAI.CAL', p, attr=0x06)
    # racine : BIN, BUDGET (dossiers, triés) ; dans BUDGET : .., MAI.CAL
    m, r = lance(c2, s, [BAS, ENTREE, BAS, ENTREE, ECHAP], ov)
    verifie(bytes(m.banks[calc['TEXT_PAGE']][:len(feuille)]) == feuille,
            'Entrée sur BUDGET/MAI.CAL : CALC (de /BIN) lancé avec la feuille, et l\'a lue (%s)' % r)

    # un nom de 15 caractères, l'extension en fin de champ (KOROBEINIKI.MUS) :
    # l'association joue aussi
    d15 = os.path.join(d, 'nom15')
    os.makedirs(d15)
    c5 = va.Carte(d15)
    c5.ajoute('BIN/CALC', os.path.join(RACINE, 'apps', 'CALC'), page=1, adresse='0000', attr=0x17)
    feuille2 = bytes((i * 11 + 5) & 0x7F for i in range(calc['TEXT_SIZE']))
    p = os.path.join(d15, 'b2026')
    open(p, 'wb').write(feuille2)
    c5.ajoute('BUDGET/BUDGET_2026.CAL', p, attr=0x06)
    m, r = lance(c5, s, [BAS, ENTREE, BAS, ENTREE, ECHAP], ov)
    verifie(bytes(m.banks[calc['TEXT_PAGE']][:len(feuille2)]) == feuille2,
            'Entrée sur BUDGET_2026.CAL (15 caractères, extension en fin de nom) : CALC lancé avec la feuille (%s)' % r)

    # Echap sur une feuille modifiée : CALC demande O/N. Touches épuisées
    # dans CALC = page 1 ; revenu dans OSM-VISION = page 0.
    ouvre = [BAS, ENTREE, BAS, ENTREE, ord('7'), ENTREE]
    m, r = lance(c2, s, ouvre + [ECHAP, ord('N')], ov)
    verifie(r == 'touches' and m.page == 1, 'CALC : feuille modifiée, Echap puis N : on reste dans CALC (page %d)' % m.page)
    m, r = lance(c2, s, ouvre + [ECHAP, ord('O')], ov)
    verifie(r == 'touches' and m.page == 0, 'CALC : feuille modifiée, Echap puis O : retour à OSM-VISION (page %d)' % m.page)
    m, r = lance(c2, s, ouvre + [ord('/'), ord('S'), ENTREE, ECHAP], ov)
    verifie(r == 'touches' and m.page == 0 and c2.lit('BUDGET/MAI.CAL')[:2] == b'7\0',
            'CALC : /S puis Echap : sauvée (A1 = « 7 »), sortie sans question (page %d)' % m.page)

    # chaque application, lancée par Entrée : elle tourne dans SA page (1),
    # avec sa copie des services (lib/vision.asm) ; Echap, ou au bout d'un
    # moment pour les jeux qui lisent le clavier eux-mêmes
    d3 = os.path.join(d, 'c')
    os.makedirs(d3)
    c3 = va.Carte(d3)
    apps = [('CALC', 'apps'), ('EDIT', 'apps'), ('MIRE', 'apps'), ('ENVAHIS', 'apps'), ('GLOUTON', 'apps'),
            ('SON', 'apps'), ('PAROLE', 'apps'), ('PONT', 'apps'), ('MINITEL', 'apps'), ('BRIQUES', 'games')]
    for nom, rep_ in apps:
        c3.ajoute(nom, os.path.join(RACINE, rep_, nom), page=1, adresse='0000', attr=0x17)
    c3.ajoute('PONT2', os.path.join(RACINE, 'apps', 'PONT2'), page=2, attr=0x06)
    c3.ajoute('PONT3', os.path.join(RACINE, 'apps', 'PONT3'), page=3, attr=0x06)
    tries = sorted(n for n, _ in apps) + ['PONT2', 'PONT3']
    tries = sorted(tries)
    for nom, _ in apps:
        k = tries.index(nom)
        m = Bureau(c3.image, s, [BAS] * k + [ENTREE] + [ECHAP] * 6)
        m.vu_page1 = 0
        orig = m.step

        def step(m=m, orig=orig):
            if m.page == 1 and m.pc < 0x8000:
                m.vu_page1 += 1
                if m.vu_page1 > 3_000_000:
                    raise Fini()
            orig()
        m.step = step
        v.installe_bios(m)          # table des services, et BIOS2
        code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()
        m.banks[0][:len(code)] = code
        m.mem[s['son_coupe']] = 0x4D
        m.mem[s['current_page']] = 0
        m.page = 0
        try:
            v.appelle(m, 0x0000, 60_000_000)
            r = 'rendu'
        except Fini:
            r = 'fini'
        except Exception as e:      # noqa: BLE001 (un plantage de l'émulateur = un échec)
            r = 'PLANTE : %s' % e
        # le CODE d'OSM-VISION intact : ses variables bougent (celles de
        # lib/vision.asm, WinPlane..SaveBuf, et les siennes, FileCount..)
        a_, b_ = ov['WinPlane'], ov['SaveBuf'] + 1400
        intact = (m.banks[0][:a_] == code[:a_] and
                  m.banks[0][b_:ov['FileCount']] == code[b_:ov['FileCount']])
        verifie(m.vu_page1 > 1000 and not r.startswith('PLANTE') and intact,
                '%-8s : tourne en page 1 (%d instructions), OSM-VISION intact (%s)' % (nom, m.vu_page1, r))

    # une application d'avant (page 0, liée à $4000) : refusée, OSM-VISION intact
    c3.ajoute('VIEILLE', os.path.join(RACINE, 'apps', 'SON'), page=0, adresse='4000', attr=0x17)
    k = sorted(tries + ['VIEILLE']).index('VIEILLE')
    m, r = lance(c3, s, [BAS] * k + [ENTREE], ov)      # la boîte reste affichée
    verifie('page 0' in carte.lit(m.mem, 0, 4096)[0].decode('latin-1'),
            'une application en page 0 : « Application pour la page 0 : la reassembler. »')

    # Terminal (touche T) : le VRAI SHELL ($6000, page 0) dans une fenêtre,
    # une commande interne (VER), un programme de /BIN en page 1 (PWD), EXIT.
    d4 = os.path.join(d, 'd')
    os.makedirs(d4)
    c4 = va.Carte(d4)
    c4.ajoute('SHELL', os.path.join(RACINE, 'shell', 'SHELL'), page=0, adresse='6000', attr=0x07)
    c4.ajoute('PWD', os.path.join(RACINE, 'cmd', 'PWD'), page=1, adresse='0000', attr=0x07)
    def terminal(comment, tape):
        tape_txt = ''.join(chr(c) for c in tape if 32 <= c < 127)
        m = Bureau(c4.image, s, tape)
        r10 = []
        ecrit = m.wr8

        def wr8(a, val, ecrit=ecrit, etat={'i': 0}):
            if a & 0xFFFF == 0xA100:
                etat['i'] = val & 0xFF
            elif a & 0xFFFF == 0xA101 and etat['i'] == 10:
                r10.append(val & 0xFF)
            ecrit(a, val)
        m.wr8 = wr8
        zones = []
        orig = m.step

        def step(m=m, orig=orig):
            if m.pc == s['Console_Zone']:
                zones.append((m.a, m.b, m.w >> 8, m.w & 255, m.y & 255))
            orig()
        m.step = step
        v.installe_bios(m)          # table des services, et BIOS2
        code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()
        m.banks[0][:len(code)] = code
        m.mem[s['son_coupe']] = 0x4D
        m.mem[s['current_page']] = 0
        m.page = 0
        v.appelle(m, s['init_heap'])                    # le SHELL alloue (malloc_sys)
        try:
            v.appelle(m, 0x0000, 80_000_000)
            r = 'rendu'
        except Fini:
            r = 'fini'
        except Exception as e:      # noqa: BLE001
            r = 'PLANTE : %s' % e
        t = m.texte.decode('latin-1')
        shell = open(os.path.join(RACINE, 'shell', 'SHELL'), 'rb').read()
        ram = bytes(m.banks[0][0x6000:0x6000 + len(shell)])
        ecarts = [i for i in range(len(shell)) if ram[i] != shell[i]]
        # seule la variable Redessine (2 octets) change : l'adresse de
        # Term_Redessine d'OSM-VISION, posée par le SHELL à son entrée
        if ecarts and ecarts[-1] - ecarts[0] <= 1:
            i = ecarts[-1] - 1
            ecarts = [] if (ram[i] << 8 | ram[i + 1]) == ov['Term_Redessine'] else ecarts
        verifie(not ecarts,
                'Terminal (%s) : ' % comment + 'SHELL chargé en page 0, $6000 (%s)' % r)
        verifie(zones[:1] == [(2, 3, 76, 20, 0x0A)] and len(zones) == 2 and zones[1][2] == 0,
                'Terminal (%s) : ' % comment + 'console limitée à la fenêtre (2,3, 76 x 20), puis plein écran au retour (%s)' % zones)
        verifie('OSM39 Terminal' in t and (t.count('EXIT : retour') >= 2 or 'ver' not in tape_txt), 'Terminal (%s) : ' % comment + 'bannière, puis VER')
        verifie(('ver' in t or 'ver' not in tape_txt) and 'pwd' in t and 'exit' in t, 'Terminal (%s) : ' % comment + 'la saisie est renvoyée en écho')
        verifie('\n/' in t.replace('\r', '') or '/\n' in t.replace('\r', ''),
                'Terminal (%s) : ' % comment + 'PWD (page 1) affiche le dossier (%r)' % t[-120:])
        a_, b_ = ov['WinPlane'], ov['SaveBuf'] + 1400
        intact = (m.banks[0][:a_] == code[:a_] and m.banks[0][b_:ov['FileCount']] == code[b_:ov['FileCount']])
        verifie(0x6D in r10 and r10[-1] == 0x2D,
                'Terminal (%s) : curseur visible pendant le SHELL, caché au retour (R10 : %s)'
                % (comment, ' '.join('$%02X' % x for x in r10)))
        verifie(r == 'fini' and m.mem[s['cz_actif']] == 0 and intact,
                'Terminal (%s) : ' % comment + 'EXIT, OSM-VISION reprend (console plein écran, son code intact)')


    # Une commande qui écrase l'écran autour du Terminal (GR_FIN pose
    # ecran_abime ; ici 6 octets : LDA #1 / STA ecran_abime / RTS) : le
    # SHELL appelle Term_Redessine d'OSM-VISION, le bureau puis la fenêtre.
    abime = os.path.join(d, 'ABIME.bin')
    e_ = s['ecran_abime']
    open(abime, 'wb').write(bytes([0x86, 1, 0xB7, e_ >> 8, e_ & 255, 0x39]))
    c4.ajoute('ABIME', abime, page=1, adresse='0000', attr=0x07)
    m = Bureau(c4.image, s, [ord('t')] + [ord(c) for c in 'abime'] + [ENTREE] + [ord(c) for c in 'exit'] + [ENTREE])
    zones, dessins = [], []
    orig = m.step

    def step(m=m, orig=orig):
        if m.pc == s['Console_Zone']:
            zones.append((m.a, m.b, m.w >> 8, m.w & 255, m.y & 255))
        if m.pc == ov['Draw_Base_UI']:
            dessins.append(len(zones))
        orig()
    m.step = step
    v.installe_bios(m)
    code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()
    m.banks[0][:len(code)] = code
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 0
    m.page = 0
    v.appelle(m, s['init_heap'])
    try:
        v.appelle(m, 0x0000, 80_000_000)
        r = 'rendu'
    except Fini:
        r = 'fini'
    except Exception as e:      # noqa: BLE001
        r = 'PLANTE : %s' % e
    z = (2, 3, 76, 20, 0x0A)
    verifie(r == 'fini' and zones[:2] == [z, z] and len(zones) == 3 and zones[2][2] == 0
            and 1 in dessins and m.mem[s['ecran_abime']] == 0,
            'Terminal : après une commande qui pose ecran_abime (GR_FIN), le SHELL fait '
            'redessiner le bureau puis la fenêtre (%s, Draw_Base_UI après la zone n° %s)' % (zones, dessins))

    for comment, tape in (
            ('touche T', [ord('t')] + [ord(c) for c in 'ver'] + [ENTREE] + [ord(c) for c in 'pwd'] + [ENTREE] +
             [ord(c) for c in 'exit'] + [ENTREE]),
            ('Exécuter (Tab) SHELL', [0x09] + [0x08] * 12 + [ord(c) for c in 'shell'] + [ENTREE] + [ord(c) for c in 'pwd'] +
             [ENTREE] + [ord(c) for c in 'exit'] + [ENTREE])):
        terminal(comment, tape)

    # Un programme console (FORTH) lancé par Exécuter : dans une fenêtre titrée
    d5 = os.path.join(d, 'e')
    os.makedirs(d5)
    c5 = va.Carte(d5)
    c5.ajoute('FORTH', os.path.join(RACINE, 'forth', 'FORTH'), page=1, adresse='0000', attr=0x07)
    tape = [0x09] + [0x08] * 12 + [ord(c) for c in 'forth'] + [ENTREE] + [ord(c) for c in '2 3 + .'] + [ENTREE] + \
        [ord(c) for c in 'quit'] + [ENTREE] + [ENTREE]
    m = Bureau(c5.image, s, tape)
    zones = []
    orig = m.step

    def step5(m=m, orig=orig):
        if m.pc == s['Console_Zone']:
            zones.append((m.a, m.b, m.w >> 8, m.w & 255, m.y & 255))
        orig()
    m.step = step5
    v.installe_bios(m)          # table des services, et BIOS2
    code = open(os.path.join(RACINE, 'osmvision', 'OSMVISION'), 'rb').read()
    m.banks[0][:len(code)] = code
    m.mem[s['son_coupe']] = 0x4D
    m.mem[s['current_page']] = 0
    m.page = 0
    v.appelle(m, s['init_heap'])
    try:
        v.appelle(m, 0x0000, 80_000_000)
        r = 'rendu'
    except Fini:
        r = 'fini'
    except Exception as e:      # noqa: BLE001
        r = 'PLANTE : %s' % e
    t = m.texte.decode('latin-1')
    ecran = carte.lit(m.mem, 0, 2000)[0].decode('latin-1')
    verifie(zones[:1] == [(2, 3, 76, 20, 0x0A)] and len(zones) == 2 and zones[1][2] == 0 and r == 'fini'
            and m.mem[s['cz_actif']] == 0,
            'FORTH (Exécuter) : dans la fenêtre du Terminal, puis plein écran au retour (%s, %s)' % (zones, r))
    verifie('2 3 + .' in t and '5' in t.split('2 3 + .')[-1], 'FORTH : 2 3 + . donne 5 (%r)' % t[-80:])

    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
