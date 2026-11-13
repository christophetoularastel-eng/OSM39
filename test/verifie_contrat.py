#!/usr/bin/env python3
# ===================================================================
# verifie_contrat.py - Le contrat de chaque service du BIOS, mesuré
# ===================================================================
# CONTRAT (contrat_services.py) dit, pour chaque emplacement de
# table_function_ram : entrées, sorties, registres que le service peut
# détruire. Ici, chaque service est appelé PAR LA TABLE, sur le vrai BIOS
# (EPROM + BIOS2) avec une carte OSMFS émulée, tous les registres chargés
# de valeurs témoins, dans un ou plusieurs scénarios (réussite, échec).
# Échec si un registre change sans être une sortie ni « détruit », si la
# pile n'est pas rendue, si DP change, si la page de l'appelant ne revient
# pas, ou si la retenue n'est pas celle attendue.
# Le pilote SD émulé détruit X, Y, W comme le vrai (verifie_fs.Machine.sd).
#   python3 verifie_contrat.py            (vérifier)
#   python3 verifie_contrat.py --mesure   (afficher ce qui change, sans juger)
#   python3 verifie_contrat.py --doc      (écrire docs/services.md)
# ===================================================================
import os
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
sys.path.insert(0, ICI)
sys.path.insert(0, os.path.join(RACINE, 'tools', 'egofs'))
import verifie_fs as v                          # noqa: E402
import egofs_core                               # noqa: E402
from contrat_services import CONTRAT, REGS      # noqa: E402

TEMOIN = {'A': 0x5A, 'B': 0xC3, 'E': 0x3C, 'F': 0x96, 'X': 0x7311, 'Y': 0x6422,
          'U': 0x5533}
CHAINES = 0xDB00            # chaînes et tampons du banc (RAM système, sous la pile)
TAMPON = 0xDC00             # 512 octets
NOM_DEB = 0xDB80            # 16 octets : nom formaté


def lit(m, r):
    return {'A': m.a, 'B': m.b, 'E': m.w >> 8, 'F': m.w & 0xFF, 'X': m.x,
            'Y': m.y, 'U': m.u, 'DP': m.dp}[r]


def pose(m, r, val):
    if r == 'A':
        m.a = val & 0xFF
    elif r == 'B':
        m.b = val & 0xFF
    elif r == 'D':
        m.a, m.b = (val >> 8) & 0xFF, val & 0xFF
    elif r == 'E':
        m.w = ((val & 0xFF) << 8) | (m.w & 0xFF)
    elif r == 'F':
        m.w = (m.w & 0xFF00) | (val & 0xFF)
    elif r == 'W':
        m.w = val & 0xFFFF
    elif r == 'X':
        m.x = val & 0xFFFF
    elif r == 'Y':
        m.y = val & 0xFFFF
    elif r == 'U':
        m.u = val & 0xFFFF
    else:
        raise KeyError(r)


def chaine(m, adr, txt):
    b = txt.encode('latin-1') + b'\0'
    m.mem[adr:adr + len(b)] = b
    return adr


def nom15(m, adr, txt):
    m.mem[adr:adr + 15] = txt.ljust(15).encode('ascii')
    m.mem[adr + 15] = 0
    return adr


def carte_image(d):
    image = os.path.join(d, 'carte.img')
    with open(image, 'wb') as f:
        f.truncate(16 * 1024 * 1024)
    core = egofs_core.OSMFS_Core(image)
    old = sys.stdout
    sys.stdout = open(os.devnull, 'w')
    try:
        core.format_fs()
        for n, contenu, page, adr in (('TEXTE', bytes(range(256)) * 2 + b'fin', 1, '2000'),
                                      ('PROG', bytes([0x39]), 1, '1000'),
                                      ('VIEUX', b'a effacer', 1, '0000'),
                                      ('ANCIEN', b'a renommer', 1, '0000')):
            p = os.path.join(d, n)
            open(p, 'wb').write(contenu)
            core.inject_file(p, n, page, adr, 0x07)
        core.mkdir('DOSS')
    finally:
        sys.stdout.close()
        sys.stdout = old
    return image


class Banc(v.Machine):
    """La machine de verifie_fs, plus : clavier en file, VSYNC simulée
    (vsync_tick avance, le tampon de la console se vide) pendant l'appel."""

    def appelle(self, adr, max_pas=3_000_000):
        s = self.s_
        self.s = 0xDF00 - 2
        self.mem[self.s], self.mem[self.s + 1] = v.RETOUR >> 8, v.RETOUR & 0xFF
        self.pc = adr
        pas = 0
        while self.pc != v.RETOUR:
            if self.sd():
                continue
            self.step()
            pas += 1
            if pas % 400 == 0:
                self.mem[s['vsync_tick'] + 1] = (self.mem[s['vsync_tick'] + 1] + 1) & 0xFF
                self.mem[s['BUF_TAIL']] = self.mem[s['BUF_HEAD']]
            if pas > max_pas:
                raise RuntimeError('trop long à $%04X' % self.pc)
        return pas

    def touches(self, octets):
        s = self.s_
        q = self.mem[s['kbd_tete']]
        for o in octets:
            self.mem[s['kbd_buf'] + q] = o
            q = (q + 1) & 15
        self.mem[s['kbd_tete']] = q
        self.mem[s['NEW_CODE']] = 1


def machine(image, s):
    m = Banc(image, s)
    m.wr16(s['SCREEN_START_OFFSET'], 0xFFFF)
    m.s = 0xDF00
    v.appelle(m, s['init_heap'])
    m.s = 0xDF00
    v.appelle(m, s['FS_Mount'])
    m.banks[1][0x1000] = 0x39                   # RTS : appelée de FAR_CALL
    m.banks[2][0x1000] = 0x39
    m.banks[2][0:2] = bytes([0x10, 0x00])       # table de FAR_CALLN, page 2
    return m


def scenario(m, sc):
    """Prépare un scénario : dict des registres d'entrée (valeurs ou
    chaînes à poser), et la mémoire nécessaire."""
    s = m.s_
    if sc.get('prep'):
        sc['prep'](m)
    entree = {}
    for r, val in sc.get('regs', {}).items():
        if callable(val):
            val = val(m)
        elif isinstance(val, tuple):
            genre, txt = val
            if genre == 'nom':
                val = nom15(m, NOM_DEB, txt)
            elif genre == 'nom2':
                val = nom15(m, CHAINES + 0x40, txt)
            elif genre == 'chaine':
                val = chaine(m, CHAINES, txt)
            elif genre == 'chaine2':
                val = chaine(m, CHAINES + 0x40, txt)
            elif genre == 'tampon':
                val = TAMPON
            elif genre == 'lba':
                m.mem[CHAINES:CHAINES + 4] = txt.to_bytes(4, 'big')
                val = CHAINES
            elif genre == 'partition':
                m.banks[m.page][0x3000:0x3000 + len(txt)] = txt
                val = 0x3000
            elif genre == 'sym':
                val = s[txt]
        entree[r] = val
    if sc.get('touches'):
        m.touches(sc['touches'])
    return entree


def mesure(m, num, sc):
    """Appelle le service num : (registres changés, retenue, défauts)."""
    s = m.s_
    page = sc.get('page', 0)
    m.page = page
    m.mem[s['current_page']] = page
    entree = scenario(m, sc)
    for r, val in TEMOIN.items():
        pose(m, r, val)
    m.dp = 0
    for r, val in entree.items():
        pose(m, r, val)
    avant = {r: lit(m, r) for r in REGS}
    adr = m.rd16(s['table_function_ram'] + 2 * num)
    m.cc = 0x50                     # IRQ et FIRQ masquées, E = 0
    m.appelle(adr)
    apres = {r: lit(m, r) for r in REGS}
    change = {r for r in REGS if apres[r] != avant[r]}
    defauts = []
    if m.s != 0xDF00:
        defauts.append('pile rendue en $%04X au lieu de $DF00' % m.s)
    if 'DP' in change:
        defauts.append('DP changé')
    if not sc.get('change_page') and (m.page != page or m.mem[s['current_page']] != page):
        defauts.append('page %d au retour au lieu de %d' % (m.page, page))
    return change, m.cc & 1, apres, defauts


def contre_preuve(image, s):
    """Le banc doit voir une faute : strlen détourné par LDY #0 / JMP strlen
    (un Y détruit), puis par INC current_page / JMP strlen (page non rendue)."""
    c = next(x for x in CONTRAT if x['nom'] == 'strlen')
    sc = c['scenarios'][0]
    vus = []
    cp = s['current_page']
    for code, faute in ((bytes([0x10, 0x8E, 0x00, 0x00]), 'Y'),
                        (bytes([0x7C, cp >> 8, cp & 0xFF]), 'page')):
        m = machine(image, s)
        tab = s['table_function_ram'] + 2 * c['num']
        vrai = m.rd16(tab)
        m.mem[0xDD00:0xDD00 + len(code) + 3] = code + bytes([0x7E, vrai >> 8, vrai & 0xFF])
        m.wr16(tab, 0xDD00)
        change, _, _, defauts = mesure(m, c['num'], sc)
        permis = set(c['detruit']) | set(c['sortie_regs'])
        vu = (faute == 'Y' and 'Y' in change - permis) or (faute == 'page' and any('page' in d for d in defauts))
        print(('OK   ' if vu else 'ÉCHEC ') + 'contre-preuve : strlen faussé (%s) est vu' % faute)
        vus.append(vu)
    return all(vus)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    if mode == '--doc':
        import contrat_services
        contrat_services.ecrit_doc(os.path.join(RACINE, 'docs', 'services.md'))
        return 0
    s = v.sym()
    d = tempfile.mkdtemp()
    image = carte_image(d)
    tab = s['table_function_ram']
    n_slots = 48
    erreurs = []
    vus = set()
    for c in CONTRAT:
        num = (s['sys_' + c['sys']] - tab) // 2 if c['sys'] != 'reserve' else c['num']
        if c['sys'] != 'reserve' and num != c['num']:
            erreurs.append('%s : emplacement %d dans la table, %d dans le contrat' % (c['nom'], num, c['num']))
        vus.add(num)
        permis = set(c['detruit']) | set(c['sortie_regs'])
        jamais = set(c['detruit'])
        for i, sc in enumerate(c['scenarios']):
            m = machine(image, s)
            try:
                change, retenue, apres, defauts = mesure(m, num, sc)
            except Exception as e:                      # noqa: BLE001
                erreurs.append('%s [%s] : %s' % (c['nom'], sc.get('nom', i), e))
                print('ÉCHEC %-18s %-22s %s' % (c['nom'], sc.get('nom', ''), e))
                continue
            jamais -= change
            hors = sorted(change - permis, key=REGS.index)
            att = sc.get('c')
            if att is not None and retenue != att:
                defauts.append('C = %d au lieu de %d' % (retenue, att))
            if hors:
                defauts.append('détruit %s (hors contrat)' % ' '.join(hors))
            for r, val in sc.get('verif', {}).items():
                if apres[r] != val:
                    defauts.append('%s = $%X au lieu de $%X' % (r, apres[r], val))
            texte = '%-18s %-22s change : %-16s C=%d' % (
                c['nom'], sc.get('nom', ''), ' '.join(sorted(change, key=REGS.index)) or '-', retenue)
            if mode == '--mesure':
                print(texte + ('   ' + '; '.join(defauts) if defauts else ''))
            elif defauts:
                erreurs.append('%s [%s] : %s' % (c['nom'], sc.get('nom', ''), '; '.join(defauts)))
                print('ÉCHEC ' + texte + '   ' + '; '.join(defauts))
            else:
                print('OK   ' + texte)
    manque = sorted(set(range(n_slots)) - vus)
    if manque:
        erreurs.append('emplacements sans contrat : %s' % manque)
        print('ÉCHEC emplacements sans contrat : %s' % manque)
    if mode == '--mesure':
        return 0
    if not contre_preuve(image, s):
        erreurs.append('contre-preuve')
    import contrat_services
    chemin = os.path.join(RACINE, 'docs', 'services.md')
    a_jour = os.path.exists(chemin) and open(chemin, encoding='utf-8').read() == contrat_services.doc()
    print(('OK   ' if a_jour else 'ÉCHEC ') + 'docs/services.md = la table (sinon : verifie_contrat.py --doc)')
    if not a_jour:
        erreurs.append('docs/services.md périmé')
    print('\n%s : %d échec(s)' % ('OK' if not erreurs else 'ÉCHEC', len(erreurs)))
    return 1 if erreurs else 0


if __name__ == '__main__':
    sys.exit(main())
