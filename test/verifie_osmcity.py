#!/usr/bin/env python3
# ===================================================================
# verifie_osmcity.py - Le vrai apps/OSMCITY = le modèle de osmcity.py
# ===================================================================
# Le binaire tourne sur le vrai BIOS (EPROM + BIOS2), l'IRQ du VSYNC prise
# à chaque trame (TRAME instructions), des octets PS/2 bruts dans la file
# de la NMI (flèches tenues, relâchées ; Echap à la fin). Ce qui est
# vérifié :
#   1. à chaque entrée de Pas, la flèche lue (KeyHaut...) est notée ; le
#      modèle (tools/osmcity/osmcity.py, Jeu.pas) rejoue la même suite :
#      position, direction, vitesse, avance et départ égaux à CHAQUE pas ;
#   2. toutes les 10 trames, au signal de trame, l'écran lu à travers
#      l'adresse de départ du 6845 (R12/R13 + 1, la VRAM entrelacée de la
#      mono, modulo 4096 cases) = Jeu.ecran() de l'état d'avant le dernier
#      pas (lui n'est écrit qu'après le signal) : 80 x 30 cases, glyphe et
#      attribut ;
#   3. chaque écriture en VRAM du programme tombe au plus LIMITE cycles
#      estimés après l'entrée de l'IRQ (4 par instruction, 3 par octet de
#      TFM), dans la fenêtre qui suit le signal de trame ;
#   4. Echap : RTS, départ du 6845 rendu ($3FFF), banque 0 de la police,
#      les rangées 25-29 d'avant rendues, la file du clavier vide.
# La carte (OSMCITY.MAP, 64 Ko) est sur la carte SD émulée, chargée en
# pages 2-3 ; le jeu en garde 32 rangées en page 1.
# Le parcours passe le bout de la VRAM (départ au-delà de 4096 cases).
# OSMCITY_PNG=f.png : l'écran de la dernière photo, dessiné avec la police
# d'OSM City (tools/osmcity/glyphes.py).
# ===================================================================
import os
import random
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'osmcity'))
import verifie_fs as v          # noqa: E402
import verifie_asm as va        # noqa: E402
import verifie_donjon39 as vd     # noqa: E402
import osmcity as oc            # noqa: E402

BIN = os.path.join(RACINE, 'apps', 'OSMCITY')
MAP = os.path.join(RACINE, 'apps', 'OSMCITY.map')
LIMITE = 1900
HAUT, DROITE, BAS, GAUCHE = 0x75, 0x74, 0x72, 0x6B
FLECHES = (HAUT, DROITE, BAS, GAUCHE)
ESPACE = 0x29
KLAXON = 0x42                           # K
SIMPLES = (ESPACE, KLAXON)              # codes PS/2 sans E0
PONT_MONTGOLFIER = (306, 138)          # la rue qui passe sous le pont
PARKING = (156, 89)                     # place de Backnang : de la place pour le biais
MAIRIE = (160, 128)                      # rue de l'Hôtel-de-Ville : la police garée tout près
PONT_GRAINE = 41                        # (cherchée : dessus et dessous)


def symboles():
    return {n: int(a, 16) for n, a in re.findall(r'Symbol: (\S+) \(\S+\) = ([0-9A-F]{4})', open(MAP).read())}


class Banc(vd.Banc):
    def __init__(self, image, s, a, script):
        super().__init__(image, s, a, script)
        self.cyc = 0
        self.tard = []                  # (trame, cycles depuis l'IRQ) des écritures VRAM
        self.reg = 0
        self.crtc = {}
        self.pas = []                   # (voulu, état avant) à chaque entrée de Pas
        self.banques = []               # les écritures de $A120 (banque de police)

    def wr8(self, adr, val):
        adr &= 0xFFFF
        if adr == 0xA100:
            self.reg = val & 31
        elif adr == 0xA101:
            self.crtc[self.reg] = val & 255
        if adr == 0xA120 and self.page == 1 and self.pc < 0x8000:
            self.banques.append(val & 0xFF)
        if 0x8000 <= adr < 0xA000 and self.page == 1 and self.pc < 0x8000:
            self.tard.append((self.trame, self.cyc))
        return va.MachineAsm.wr8(self, adr, val)

    def step(self):
        if self.page == 1 and self.pc == self.a_['Pas']:
            b = self.banks[1]
            a = self.a_
            touches = [b[a['KeyHaut']], b[a['KeyDroite']], b[a['KeyBas']], b[a['KeyGauche']]]
            voulu = oc.voulu_de(*touches)
            self.pas.append((voulu, self.etat(), self.trame, bool(b[a['KeyEsp']]), self.garees(),
                             bool(b[a['KeyK']]), tuple(self.ay_regs[r] for r in oc.AY_REGS)))
        tfm = 0
        if self.rd8(self.pc) == 0x11 and 0x38 <= self.rd8(self.pc + 1) <= 0x3B:
            tfm = self.w
        irq_avant = self.n_irq
        super().step()
        if self.n_irq != irq_avant:
            self.cyc = 0
        self.cyc += 4 + 3 * tfm

    def etat(self):
        b, a = self.banks[1], self.a_
        return (b[a['PosX']] << 8 | b[a['PosX'] + 1], b[a['PosY']] << 8 | b[a['PosY'] + 1], b[a['Dir']], b[a['Vit']],
                b[a['Ax']] << 8 | b[a['Ax'] + 1], b[a['Ay']] << 8 | b[a['Ay'] + 1],
                b[a['Debut']] << 8 | b[a['Debut'] + 1], b[a['PlqNum']],
                b[a['Niv']], b[a['Pied']], b[a['VCoul']])

    def garees(self):
        b, g = self.banks[1], self.a_['Garees']
        return [(b[g + 8 * i] << 8 | b[g + 8 * i + 1], b[g + 8 * i + 2] << 8 | b[g + 8 * i + 3],
                 b[g + 8 * i + 4], b[g + 8 * i + 5], b[g + 8 * i + 6], b[g + 8 * i + 7])
                for i in range(oc.NGAREES + oc.NMOB_V + oc.NMOB_P + oc.NPOLICE + 2)] + [
                    tuple(b[self.a_['Phase']:self.a_['Phase'] + 18]), tuple(b[self.a_['PDir']:self.a_['PDir'] + 18]),
                    b[self.a_['AleaS']], b[self.a_['TMob']], b[self.a_['Etape']],
                    tuple(b[self.a_['PMode']:self.a_['PMode'] + 2]),
                    tuple((b[self.a_['PCX'] + 2 * k] << 8 | b[self.a_['PCX'] + 2 * k + 1],
                           b[self.a_['PCY'] + 2 * k] << 8 | b[self.a_['PCY'] + 2 * k + 1]) for k in range(2)),
                    tuple(b[self.a_['PPerdu']:self.a_['PPerdu'] + 2]), b[self.a_['Signal']]]

    def vue(self):
        """Les 80 x 30 cases à travers le départ du 6845 : (glyphe, attribut)."""
        dep = ((self.crtc.get(12, 0) << 8 | self.crtc.get(13, 0)) + 1) & 4095
        return [[(self.mem[0x8000 + 2 * ((dep + 80 * r + c) & 4095)],
                  self.mem[0x8001 + 2 * ((dep + 80 * r + c) & 4095)]) for c in range(80)] for r in range(30)], dep


def main():
    s = v.sym()
    a = symboles()
    erreurs = []

    def verifie(cond, texte):
        print(('OK   ' if cond else 'ÉCHEC ') + texte)
        if not cond:
            erreurs.append(texte)
    verifie(a.get('App_Start') == 0, 'App_Start à l\'offset 0')
    carte = oc.carte()
    rues = oc.rues()

    def seance(nom, depart=None, graine=39, duree=3200, plan=None, couverture=True, lieux=None):
        """Une partie : des flèches tenues de durées tirées au sort (graine
        fixe), parfois deux à la fois, parfois rien ; une photo toutes les 10
        trames ; Echap. depart : (x, y) écrit dans DepartX/DepartY du binaire.
        Vérifie 1 (le modèle à chaque pas), 2 (les photos), 3 (la VRAM), 4
        (la sortie). Rend (machine, pas)."""
        print('--- %s ---' % nom)
        photos = []

        def photo(m):
            photos.append((m.trame, len(m.pas), m.vue()))
        alea = random.Random(graine)
        script = []
        t = 60
        tenues = []
        for dur, fl in (plan or []):            # un parcours dirigé : (trames, flèches)
            for k in fl:
                script.append((t + 1, vd.appui(k, k not in SIMPLES)))
            t += dur
            for k in fl:
                script.append((t, vd.relache(k, k not in SIMPLES)))
            t += 2
        while plan is None and t < duree:
            for k in tenues:
                script.append((t, vd.relache(k, k not in SIMPLES)))
            tenues = []
            r = alea.random()
            if r < 0.85:                    # 35 % : deux flèches (en biais)
                tenues = [alea.choice(FLECHES)]
                if r < 0.35:
                    tenues.append(alea.choice(FLECHES))
            elif r < 0.93:                  # 8 % : Espace (sortir, entrer)
                script.append((t + 1, vd.appui(ESPACE, False)))
                script.append((t + 3, vd.relache(ESPACE, False)))
            elif r < 0.97:                  # 4 % : le klaxon
                tenues = [KLAXON]
            for k in tenues:
                script.append((t + 1, vd.appui(k, k not in SIMPLES)))
            t += alea.randint(20, 160)
        for k in tenues:
            script.append((t, vd.relache(k, k not in SIMPLES)))
        for f in range(40, t + 40, 10):
            script.append((f, photo))
        script.append((t + 60, vd.appui(0x76, False)))
        script.append((t + 62, vd.relache(0x76, False)))
        script.append((t + 400, lambda m: (_ for _ in ()).throw(vd.Fini())))
        script.sort(key=lambda e: e[0])

        d = tempfile.mkdtemp()
        c = va.Carte(d)
        c.ajoute('OSMCITY.MAP', os.path.join(RACINE, 'apps', 'OSMCITY.MAP'), page=2, adresse='0000', attr=0x06)
        c.ajoute('OSMCITY.RUE', os.path.join(RACINE, 'apps', 'OSMCITY.RUE'), page=1, adresse='6000', attr=0x06)
        m = Banc(c.image, s, a, script)
        v.installe_bios(m)
        m.wr16(0xDFF6, s['handler_IRQ'])
        m.mem[s['son_coupe']] = 0               # le son (l'AY) vérifié aussi
        m.mem[s['current_page']] = 1
        bas = bytes(range(256)) * 3 + bytes(32)           # les rangées 25-29 d'avant
        m.mem[0x8000 + 25 * 160:0x8000 + 30 * 160] = bas
        code = bytearray(open(BIN, 'rb').read())
        if depart is not None:
            for nomv, val in (('DepartX', depart[0]), ('DepartY', depart[1])):
                code[a[nomv]:a[nomv] + 2] = bytes([val >> 8, val & 255])
        if lieux is not None:                   # les cases candidates imposées
            for k, (x, y) in enumerate(lieux):
                code[a['Cands'] + 4 * k:a['Cands'] + 4 * k + 4] = bytes([x >> 8, x & 255, y >> 8, y & 255])
        m.banks[1][:len(code)] = code
        m.page = 1
        try:
            v.appelle(m, a['App_Start'], 80_000_000)
            r = 'rendu'
        except vd.Fini:
            r = 'pas rendu (Echap ignoré)'
        except Exception as e:      # noqa: BLE001
            r = 'PLANTE : %s ($%04X page %d)' % (e, m.pc, m.page)
        verifie(r == 'rendu', 'Echap : l\'application rend la main par RTS (%s)' % r)

        # 1. le modèle rejoue les flèches lues
        jeu = oc.Jeu(carte, rues, lieux, depart)
        faux = None
        son_faux = None
        sons = 0
        for i, (voulu, etat, trame, esp, gar, klax, ay) in enumerate(m.pas):
            if i and son_faux is None:          # l'AY : la trame d'avant, d'après le modèle
                att_ay = tuple(jeu.ayr[r] & v.AY_LARGEUR[r] for r in oc.AY_REGS)
                if ay != att_ay:
                    son_faux = (i, trame, ay, att_ay)
                sons += 1 if jeu.ayr[9] else 0
            att = (jeu.x, jeu.y, jeu.d, jeu.v, jeu.ax, jeu.ay, jeu.s, jeu.plaque, jeu.niv,
                   int(jeu.pied), jeu.coul)
            gatt = [(g[0], g[1], g[2], g[3], g[4], int(g[5])) for g in jeu.tous()] + [
                tuple(jeu.phase), tuple(jeu.pdir), jeu.alea_, jeu.tmob, jeu.etape, tuple(jeu.pmode),
                tuple(tuple(q) for q in jeu.pcible), tuple(jeu.pperdu), jeu.signal]
            if (etat != att or gar != gatt) and faux is None:
                faux = (i, trame, etat, att) if etat != att else (i, trame, 'garées', [
                    (k, q, r) for k, (q, r) in enumerate(zip(gar, gatt)) if q != r][:2])
            jeu.pas(voulu, esp, klax)
        verifie(son_faux is None, 'l\'AY (moteur, klaxon, bruitages) = le modèle à chaque trame%s'
                % ('' if son_faux is None else ' ; pas %d (trame %d) : %s au lieu de %s' % son_faux))
        xs = [e[1][0] for e in m.pas]
        ys = [e[1][1] for e in m.pas]
        verifie(m.pas and faux is None,
                '%d pas : position, direction, vitesse, avances, départ, plaque, étage, à pied, couleur, '
                'voitures garées, circulation = le modèle '
                'à chaque pas%s' % (len(m.pas), '' if faux is None else ' ; pas %d (trame %d) : %s au '
                                    'lieu de %s' % faux))
        if couverture:
            verifie(max(xs) - min(xs) >= 6 and max(ys) - min(ys) >= 3,
                    'le parcours bouge : x de %d à %d, y de %d à %d' % (min(xs), max(xs), min(ys), max(ys)))
            biais = sum(1 for e in m.pas if e[1][2] & 1)
            verifie(biais > 0, 'des trames en biais (direction impaire) : %d' % biais)
        ecarts = {}
        for p, q in zip(m.pas, m.pas[1:]):
            ecarts[q[2] - p[2]] = ecarts.get(q[2] - p[2], 0) + 1
        print('Mesure : trames entre deux pas -> nombre : %s (TRAME = %d instructions)'
              % (dict(sorted(ecarts.items())), vd.TRAME))

        # 2. l'écran à travers le 6845
        jeu = oc.Jeu(carte, rues, lieux, depart)
        j = 0
        mauvaises = []
        photos = [p for p in photos if p[1] >= 1]       # l'écran fini : après le premier pas
        for trame, npas, (vue, dep) in photos:
            while j < npas - 1:             # le dernier pas n'est écrit qu'après le signal
                jeu.pas(m.pas[j][0], m.pas[j][3], m.pas[j][5])
                j += 1
            att = jeu.ecran()
            diff = [(rg, col) for rg in range(30) for col in range(80)
                    if vue[rg][col] != att[rg][col]]
            if diff or dep != jeu.s:
                mauvaises.append((trame, dep, jeu.s, len(diff), diff[:3]))
                if os.environ.get('OSMCITY_DEBUG') and len(mauvaises) == 1:
                    q = diff[0]
                    print('DEBUG', q, 'vu', vue[q[0]][q[1]], 'attendu', att[q[0]][q[1]], 'pos', jeu.x, jeu.y,
                          'pied', jeu.pied, 'd', jeu.d, [g for g in jeu.tous() if not g[5] and
                                                          abs(g[0] - jeu.x) < 4 and abs(g[1] - jeu.y) < 3])
        verifie(photos and not mauvaises,
                '%d photos de l\'écran (toutes les 10 trames) = le modèle, départ compris%s'
                % (len(photos), '' if not mauvaises else ' ; %d fausses, ex. %s' % (len(mauvaises), mauvaises[:2])))
        if os.environ.get('OSMCITY_PNG') and photos:        # ce que montre le binaire
            sys.path.insert(0, os.path.join(RACINE, 'tools', 'osmcity'))
            import glyphes
            glyphes.dessine(photos[-1][2][0], None, os.environ['OSMCITY_PNG'].replace('.png', '_%s.png' % graine), 1)

        # 3. la VRAM touchée seulement juste après le signal de trame
        pire = max((cy for _, cy in m.tard), default=0)
        verifie(m.tard and pire <= LIMITE,
                '%d écritures en VRAM, au plus %d cycles estimés après l\'entrée de l\'IRQ (limite %d)'
                % (len(m.tard), pire, LIMITE))

        # 4. la sortie
        verifie(m.crtc.get(12) == 0x3F and m.crtc.get(13) == 0xFF, 'en sortant : départ du 6845 rendu ($3FFF)')
        verifie(m.banques == [0x10, 0x00], 'police : banque 1 en entrant, banque 0 en sortant ($A120 : %s)'
                % ' '.join('$%02X' % x for x in m.banques))
        verifie(bytes(m.mem[0x8000 + 25 * 160:0x8000 + 30 * 160]) == bas,
                'en sortant : les rangées 25-29 d\'avant rendues')
        verifie(m.mem[s['kbd_queue']] == m.mem[s['kbd_tete']], 'en sortant : la file du clavier est vide')
        verifie(m.ay_regs[8] == m.ay_regs[9] == m.ay_regs[10] == 0 and m.ay_regs[7] == 0x3A,
                'en sortant : silence, le mixeur du BIOS ($3A)')
        return m, m.pas

    # --- le départ du jeu : le centre ---
    m, pas = seance('départ du jeu (%d, %d)' % oc.depart(carte))
    r7 = {e[6][oc.AY_REGS.index(7)] for e in pas}
    verifie(oc.R7_KLAX in r7 and oc.R7_BRUIT in r7, 'le klaxon et des bruitages ont sonné (R7 : %s)'
            % ' '.join('$%02X' % x for x in sorted(r7)))
    tours = sum(1 for p, q in zip(pas, pas[1:]) if abs(q[1][6] - p[1][6]) > 2000)
    verifie(tours > 0, 'le départ passe le bout de la VRAM (4096 cases) : %d fois' % tours)
    plaques = {e[1][7] for e in pas} - {0}
    verifie(len(plaques) >= 3, 'la plaque change de rue : %s' % ', '.join(
        rues[0][n - 1].decode('cp437') for n in sorted(plaques)))
    vmax = max(e[1][3] for e in pas)
    verifie(vmax >= 120, 'la vitesse monte haut (%d, VMAX = %d)' % (vmax, oc.VMAX))

    # --- près du pont Montgolfier : dessus, dessous ---
    pont = PONT_MONTGOLFIER
    m, pas = seance('près du pont Montgolfier (%d, %d)' % pont, depart=pont, graine=PONT_GRAINE, duree=4000)
    dessus = sum(1 for e in pas if e[1][8] == 1)
    dessous = sum(1 for e in pas if e[1][8] == 0 and oc.sorte_xy(carte, e[1][0], e[1][1]) == oc.SOUS_PONT)
    verifie(dessus > 0 and dessous > 0,
            'la voiture passe sur un tablier (%d pas à l\'étage 1) et dessous (%d pas sous un pont)'
            % (dessus, dessous))

    # --- en biais, sur la place de Backnang : de longues diagonales,
    # une colonne et une rangée écrites dans la même trame ---
    diag = [(150, (HAUT, DROITE)), (40, (BAS,)), (150, (BAS, GAUCHE)), (60, ()), (150, (HAUT, GAUCHE)),
            (40, (DROITE,)), (150, (BAS, DROITE)), (60, ())] * 2
    m, pas = seance('en biais, place de Backnang (%d, %d)' % PARKING, depart=PARKING, plan=diag)
    doubles = sum(1 for p, q in zip(pas, pas[1:]) if p[1][0] != q[1][0] and p[1][1] != q[1][1])
    verifie(doubles >= 3, 'des pas en x et en y dans la même trame (colonne et rangée) : %d' % doubles)

    # --- la circulation : vue en entier sur une partie ---
    mobs = [e[4][oc.NGAREES:oc.NGAREES + oc.NMOB_V + oc.NMOB_P] for e in pas]
    print('(circulation vérifiée à chaque pas avec le reste)')

    # --- à pied : sortir, marcher, revenir, prendre la voiture garée à côté
    # du départ, repartir ---
    pied = [(80, ()), (4, (ESPACE,)), (60, ()), (90, (DROITE,)), (10, ()), (90, (GAUCHE,)), (10, ()),
            (4, (ESPACE,)), (20, ()), (120, (GAUCHE,)), (60, ()), (4, (ESPACE,)), (60, (BAS,)), (40, ())]
    m, pas = seance('à pied', plan=pied, couverture=False)
    a_pied = sum(1 for e in pas if e[1][9])
    couleurs = {e[1][10] for e in pas}
    verifie(a_pied > 50 and len(couleurs) >= 2,
            'sortir, marcher (%d pas à pied), prendre une autre voiture (couleurs %s)' % (a_pied, sorted(couleurs)))

    # --- le cache-cache : près de la mairie (la police y est garée), le
    # butin à deux cases, planque loin : le vol, la police qui part du
    # poste, l'arrestation, Espace : une autre partie ; puis, au départ du
    # jeu, butin et planque au même endroit : gagné ---
    x0, y0 = MAIRIE
    butin = (x0 + 2, y0)
    r = oc.ALEA0
    tirs = []
    for _ in range(2):
        r = (r >> 1) ^ (0xB8 if r & 1 else 0)
        tirs.append(r & (oc.NCANDS - 1))
    loin = next(q for q in oc.cands(carte) if abs(q[0] - butin[0]) + 2 * abs(q[1] - butin[1]) >= oc.DIST_PLANQUE)
    lieux = [butin] * oc.NCANDS
    lieux[tirs[1]] = loin
    verifie(tirs[0] != tirs[1] and oc.sorte_xy(carte, *butin) in (oc.ROUTE, oc.PLACE),
            'cache-cache : le butin en %s, la planque en %s' % (butin, loin))
    vol = [(30, ()), (20, (DROITE,)), (600, ()), (4, (ESPACE,)), (60, ())]
    m, pas = seance('cache-cache : arrêté', depart=MAIRIE, plan=vol, couverture=False, lieux=lieux)
    etapes = [e[4][-5] for e in pas]
    suite = [k for i, k in enumerate(etapes) if i == 0 or etapes[i - 1] != k]
    chasse = sum(1 for e in pas if any(e[4][-4]))
    verifie(suite[:4] == [oc.VOL, oc.FUITE, oc.ARRETE, oc.VOL],
            'le vol, la fuite, l\'arrestation, une autre partie (étapes %s ; %d pas de chasse)' % (suite, chasse))
    x0, y0 = oc.depart(carte)
    butin = (x0 + 2, y0)
    m, pas = seance('cache-cache : gagné', plan=[(30, ()), (20, (DROITE,)), (60, ()), (4, (ESPACE,)), (40, ())],
                    couverture=False, lieux=[butin] * oc.NCANDS)
    etapes = [e[4][-5] for e in pas]
    suite = [k for i, k in enumerate(etapes) if i == 0 or etapes[i - 1] != k]
    verifie(oc.GAGNE in suite, 'la planque atteinte : gagné (étapes %s)' % suite)
    print('\n%s : %d échec(s)' % ('ÉCHEC' if erreurs else 'OK', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
