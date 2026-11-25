#!/usr/bin/env python3
# ===================================================================
# ay.py - Partitions pour l'AY-3-8910 (lecteur lib/ay_joue.asm)
# ===================================================================
# Source unique du format : la partition texte, sa compilation en
# fichier binaire pour la carte, le modèle EXACT du lecteur 6309 (l'état
# des registres de l'AY à chaque trame, ce que verifie_ayjoue.py compare
# au vrai code) et un rendu WAV pour écouter sur le PC.
#
#   python3 tools/ay/ay.py morceau.txt -o MORCEAU      fichier pour la carte
#   python3 tools/ay/ay.py morceau.txt --wav m.wav     écoute (--b-muette :
#                                                       comme l'ancienne puce, voie B morte)
#   python3 tools/ay/ay.py morceau.txt --trames 20     registres, trame par trame
#
# ---- La partition (texte) ----
#   # commentaire (en début de ligne ou après une espace : G#4 est une note)
#   titre Korobeiniki
#   tempo 8                      trames par unité (60 trames = 1 s)
#   instrument piano vol 15 13 12 10 9 8 7 6 5 4
#   instrument tambour bruit 6 son non vol 15 10 6 3 0
#   instrument bourdon env 10 400            enveloppe matérielle : forme, période
#   A: @piano E5*2 B4 C5 D5*2 C5 B4 | A4*2 - ~
#   C: [ @bourdon E2*4 @tambour C4 ]
# Voix A, B, C (une voix peut s'étaler sur plusieurs lignes). Jetons :
#   @nom      instrument            C4 D#4 Eb4 : note (octaves 1 à 8)
#   -         silence               ~ : la note précédente continue
#   *n        après une note, un silence ou ~ : n unités (défaut 1)
#   [ ... ]   boucle : à la fin de la voix, on repart au [ (sans fin)
#   |         ignoré (barres de mesure)
# Instrument : `vol` = volume (0-15) à chaque trame depuis le début de la
# note, le dernier est tenu ; `bruit P` (période 0-31) ajoute le bruit ;
# `son non` retire le ton ; `env FORME PERIODE` : volume par l'enveloppe
# de l'AY (R13 = forme, relancée à chaque note ; R11-R12 = période).
#
# ---- Le fichier binaire (déplaçable : adresses relatives au début) ----
#   +0  "AY", 1          signature, version
#   +3  FDB titre        texte terminé par 0
#   +5  FDB voix A, B, C (0 : voix absente)
#   +11 FDB table des instruments (FDB par instrument)
#   instrument : drapeaux (b0 ton, b1 bruit, b2 enveloppe), période du
#                bruit, forme, période de l'enveloppe (FDB, poids FAIBLE
#                d'abord : R11 puis R12), volumes..., $FF
#   voix : $00 silence, $01-$5F note (1 = Do 1), $60 la note continue,
#          $80-$BF durée = n - $7F trames (gardée jusqu'au changement),
#          $C0-$DF instrument n - $C0, $E0 repère de boucle, $E1 retour
#          au repère, $FF fin de la voix
# Une note, un silence ou ~ dure la durée courante ; plus de 64 trames :
# la note puis des $60.
#
# ---- Le lecteur (une trame = un VSYNC, 60 par seconde) ----
# Pour chaque voix : quand son compte tombe à 0, lire jusqu'à une note,
# un silence, $60 ou la fin. Note n : période = TABLE[(n-1) % 12] >>
# ((n-1) / 12), volumes de l'instrument depuis le premier, enveloppe
# relancée. Puis volume = volume courant (le suivant au prochain coup,
# sauf si c'est $FF : on garde). Registres écrits à chaque trame :
# périodes et volumes des trois voix, R6 (bruit de la dernière voix qui
# en joue), R7 (tons et bruits des voix qui jouent ; ports en entrée),
# R11-R13 seulement à une note d'un instrument à enveloppe. Une voix
# finie ou en silence : volume 0, rien au mixeur. son_coupe = $4D :
# volumes à 0.
# ===================================================================
import argparse
import math
import re
import struct
import sys
import wave

HORLOGE = 1843200                       # E
TP_DO1 = [round(HORLOGE / 16 / (440 * 2 ** ((k - 45) / 12))) for k in range(12)]
NOMS = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}


class Erreur(Exception):
    pass


def note(txt):
    """'C4', 'D#4', 'Eb3' -> 1..95"""
    if txt[0] not in NOMS:
        raise Erreur('note inconnue : %s' % txt)
    k = NOMS[txt[0]]
    reste = txt[1:]
    while reste and reste[0] in '#b':
        k += 1 if reste[0] == '#' else -1
        reste = reste[1:]
    if not reste.isdigit():
        raise Erreur('octave manquante : %s' % txt)
    n = (int(reste) - 1) * 12 + k + 1
    if not 1 <= n <= 0x5F:
        raise Erreur('note hors de portée (Do 1 à La# 8) : %s' % txt)
    return n


def lit_partition(texte):
    titre, tempo, instr, voix = '', 8, {}, {'A': [], 'B': [], 'C': []}
    for num, ligne in enumerate(texte.splitlines(), 1):
        if not ligne.lstrip().startswith('titre'):
            ligne = re.sub(r'(^|\s)#.*', '', ligne)        # G#4 n'est pas un commentaire
        mots = ligne.split()
        if not mots:
            continue
        try:
            if mots[0] == 'titre':
                titre = ligne.split(None, 1)[1].strip() if len(mots) > 1 else ''
            elif mots[0] == 'tempo':
                tempo = int(mots[1])
            elif mots[0] == 'instrument':
                instr[mots[1]] = lit_instrument(mots[2:])
            elif mots[0] in ('A:', 'B:', 'C:'):
                voix[mots[0][0]].extend(mots[1:])
            else:
                raise Erreur('ligne incomprise')
        except (Erreur, ValueError, IndexError) as e:
            raise Erreur('ligne %d : %s' % (num, e))
    return titre, tempo, instr, voix


def lit_instrument(mots):
    d = {'ton': True, 'bruit': None, 'env': None, 'vol': [15]}
    i = 0
    while i < len(mots):
        m = mots[i]
        if m == 'vol':
            j = i + 1
            while j < len(mots) and mots[j].isdigit():
                j += 1
            d['vol'] = [int(x) for x in mots[i + 1:j]]
            if not d['vol'] or max(d['vol']) > 15:
                raise Erreur('volumes : 0 à 15')
            i = j
        elif m == 'bruit':
            d['bruit'] = int(mots[i + 1]) & 31
            i += 2
        elif m == 'son' and mots[i + 1] == 'non':
            d['ton'] = False
            i += 2
        elif m == 'env':
            d['env'] = (int(mots[i + 1]) & 15, int(mots[i + 2]) & 0xFFFF)
            i += 3
        else:
            raise Erreur('instrument : %s ?' % m)
    return d


def compile_partition(texte):
    titre, tempo, instr, voix = lit_partition(texte)
    noms = list(instr)
    if len(noms) > 32:
        raise Erreur('32 instruments au plus')
    flots = {}
    for v, jetons in voix.items():
        if not jetons:
            continue
        out, duree, boucle, note_vue, instr_vu = bytearray(), None, False, False, False

        def ecrit(code, unites):
            nonlocal duree
            trames = unites * tempo
            premier = True
            while trames > 0:
                k = min(trames, 64)
                if k != duree:
                    out.append(0x7F + k)
                    duree = k
                out.append(code if premier else 0x60)
                premier = False
                trames -= k
        for j in jetons:
            if j == '|':
                continue
            if j == '[':
                out.append(0xE0)
                boucle, note_vue = True, False
                continue
            if j == ']':
                if not boucle or not note_vue:
                    raise Erreur('voix %s : ] sans [ ou boucle vide' % v)
                out.append(0xE1)
                boucle = False
                continue
            if j.startswith('@'):
                if j[1:] not in instr:
                    raise Erreur('voix %s : instrument inconnu %s' % (v, j))
                out.append(0xC0 + noms.index(j[1:]))
                instr_vu = True
                continue
            base, _, mult = j.partition('*')
            unites = int(mult) if mult else 1
            if unites < 1:
                raise Erreur('voix %s : durée %s' % (v, j))
            code = 0 if base == '-' else 0x60 if base == '~' else note(base)
            if code not in (0, 0x60) and not instr_vu:
                raise Erreur('voix %s : note avant tout instrument' % v)
            ecrit(code, unites)
            note_vue = True
        if boucle:
            raise Erreur('voix %s : [ sans ]' % v)
        if out[-1:] != b'\xe1':
            out.append(0xFF)
        flots[v] = bytes(out)
    # assemblage
    corps = bytearray(b'AY\x01') + bytes(10)
    pos_titre = len(corps)
    corps += titre.encode('latin-1') + b'\0'
    pos_voix = {}
    for v in 'ABC':
        if v in flots:
            pos_voix[v] = len(corps)
            corps += flots[v]
    pos_table = len(corps)
    corps += bytes(2 * len(noms))
    for k, n in enumerate(noms):
        d = instr[n]
        struct.pack_into('>H', corps, pos_table + 2 * k, len(corps))
        drap = (1 if d['ton'] else 0) | (2 if d['bruit'] is not None else 0) | (4 if d['env'] else 0)
        forme, per = d['env'] or (0, 0)
        corps += bytes([drap, d['bruit'] or 0, forme, per & 255, per >> 8]) + bytes(d['vol']) + b'\xff'
    struct.pack_into('>HHHHH', corps, 3, pos_titre, pos_voix.get('A', 0), pos_voix.get('B', 0),
                     pos_voix.get('C', 0), pos_table)
    return bytes(corps)


# -------------------------------------------------------------------
# Modèle exact du lecteur (lib/ay_joue.asm)
# -------------------------------------------------------------------
def periode(n):
    return TP_DO1[(n - 1) % 12] >> ((n - 1) // 12)


class Lecteur:
    def __init__(self, morceau, son_coupe=False):
        if morceau[:3] != b'AY\x01':
            raise Erreur('pas un morceau AY')
        self.m = morceau
        self.son_coupe = son_coupe
        self.reg = [0] * 16
        self.voix = []
        for k in range(3):
            p = struct.unpack_from('>H', morceau, 5 + 2 * k)[0]
            self.voix.append({'ptr': p or None, 'boucle': p, 'reste': 1, 'duree': 1, 'instr': None,
                              'vol': None, 'tp': 0, 'decl': False})
        self.table = struct.unpack_from('>H', morceau, 11)[0]

    def actif(self):
        return any(v['ptr'] is not None for v in self.voix)

    def trame(self):
        """Une trame ; rend la liste ordonnée des écritures (registre, valeur)."""
        m, ecr = self.m, []
        mix, bruit = 0x3F, None
        for k, v in enumerate(self.voix):
            vol = 0
            if v['ptr'] is not None:
                v['reste'] = (v['reste'] - 1) & 255
                if v['reste'] == 0:
                    while True:
                        b = m[v['ptr']]
                        v['ptr'] += 1
                        if b == 0:
                            v['vol'] = None
                            v['reste'] = v['duree']
                            break
                        if b < 0x60:
                            if v['instr'] is None:
                                raise Erreur('note avant tout instrument')
                            v['tp'] = periode(b)
                            v['vol'] = v['instr'] + 5
                            v['decl'] = bool(m[v['instr']] & 4)
                            v['reste'] = v['duree']
                            break
                        if b == 0x60:
                            v['reste'] = v['duree']
                            break
                        if 0x80 <= b < 0xC0:
                            v['duree'] = b - 0x7F
                        elif 0xC0 <= b < 0xE0:
                            v['instr'] = struct.unpack_from('>H', m, self.table + 2 * (b - 0xC0))[0]
                        elif b == 0xE0:
                            v['boucle'] = v['ptr']
                        elif b == 0xE1:
                            v['ptr'] = v['boucle']
                        elif b >= 0xE2:
                            v['ptr'] = None
                            break
                if v['ptr'] is not None and v['vol'] is not None:
                    i = v['instr']
                    drap = m[i]
                    vol = m[v['vol']]
                    if m[v['vol'] + 1] != 0xFF:
                        v['vol'] += 1
                    if drap & 4:
                        vol = 0x10
                    if drap & 1:
                        mix &= ~(1 << k)
                    if drap & 2:
                        mix &= ~(8 << k)
                        bruit = m[i + 1]
            ecr += [(2 * k, v['tp'] & 255), (2 * k + 1, v['tp'] >> 8), (8 + k, 0 if self.son_coupe else vol)]
            if v['decl']:
                v['decl'] = False
                i = v['instr']
                ecr += [(11, m[i + 3]), (12, m[i + 4]), (13, m[i + 2])]
        if bruit is not None:
            ecr.append((6, bruit))
        ecr.append((7, mix))
        for r, x in ecr:
            self.reg[r] = x
        return ecr


# -------------------------------------------------------------------
# Rendu WAV (pour écouter ; approché, pas exact au cycle)
# -------------------------------------------------------------------
# Tension de sortie de chaque volume, mesurée sur la puce de la carte (broche
# 4, voie A, ton et bruit coupés, 30 oct. 2026), en mV, rapportée au 15.
MESURES_MV = [0, 5, 7, 12, 18, 28, 40, 69, 83, 140, 190, 260, 345, 440, 581, 721]
NIVEAUX = [x / MESURES_MV[15] for x in MESURES_MV]


def rendu(morceau, secondes, b_muette=False, taux=44100):
    lec = Lecteur(morceau)
    tic = HORLOGE / 8 / taux                    # tics de l'AY (E/8) par échantillon
    par_trame = taux / 60
    sortie = []
    phase = [0.0, 0.0, 0.0]
    bruit_c, lfsr, bruit_s = 0.0, 1, 1
    env_c, env_pos, env_att, env_tenu, niv_env = 0.0, 0, False, False, 15
    n_ech = 0.0
    for _ in range(int(secondes * 60)):
        if not lec.actif():
            break
        ecr = lec.trame()
        r = lec.reg
        forme = r[13]
        if any(x == 13 for x, _ in ecr):          # écrire R13 relance l'enveloppe
            env_c, env_pos, env_tenu = 0.0, 0, False
            env_att = bool(forme & 4)
            niv_env = 0 if env_att else 15
        tp = [max(1, r[2 * k] | (r[2 * k + 1] & 15) << 8) for k in range(3)]
        np_ = max(1, r[6] & 31)
        ep = max(1, r[11] | r[12] << 8)
        n_ech += par_trame
        while n_ech >= 1:
            n_ech -= 1
            s = 0.0
            # bruit : un décalage tous les 2 NP tics (E / (16 NP))
            bruit_c += tic
            while bruit_c >= 2 * np_:
                bruit_c -= 2 * np_
                lfsr = (lfsr >> 1) | (((lfsr ^ (lfsr >> 3)) & 1) << 16)
                bruit_s = lfsr & 1
            # enveloppe : un pas tous les 2 EP tics (16 pas = 256 EP cycles de E)
            if not env_tenu:
                env_c += tic
                while env_c >= 2 * ep and not env_tenu:
                    env_c -= 2 * ep
                    env_pos += 1
                    if env_pos >= 16:
                        if not forme & 8:                       # sans Continue : 0
                            env_tenu, niv_env = True, 0
                        elif forme & 1:                         # Maintien
                            env_tenu = True
                            niv_env = 15 if env_att ^ bool(forme & 2) else 0
                        else:
                            env_pos = 0
                            if forme & 2:                       # Alterne
                                env_att = not env_att
                    if not env_tenu:
                        niv_env = env_pos if env_att else 15 - env_pos
            for k in range(3):
                # ton : bascule tous les TP tics (E / (16 TP))
                phase[k] = (phase[k] + tic / tp[k]) % 2.0
                if b_muette and k == 1:
                    continue
                t = (phase[k] < 1.0) | (r[7] >> k & 1)
                b = bruit_s | (r[7] >> (k + 3) & 1)
                v = r[8 + k]
                if t and b:
                    s += NIVEAUX[niv_env if v & 16 else v & 15]
            sortie.append(s / 3)
    # filtre passe-haut (le condensateur C114) et normalisation
    out, prec_x, prec_y = [], 0.0, 0.0
    a = math.exp(-2 * math.pi * 20 / taux)
    for x in sortie:
        y = a * (prec_y + x - prec_x)
        prec_x, prec_y = x, y
        out.append(y)
    return out, taux


def ecrit_wav(chemin, echantillons, taux):
    with wave.open(chemin, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(taux)
        w.writeframes(b''.join(struct.pack('<h', max(-32767, min(32767, int(x * 60000)))) for x in echantillons))


def main():
    p = argparse.ArgumentParser(description='Partitions pour l\'AY-3-8910 (lib/ay_joue.asm)')
    p.add_argument('partition')
    p.add_argument('-o', help='fichier binaire pour la carte')
    p.add_argument('--wav', help='rendu à écouter')
    p.add_argument('--secondes', type=float, default=30)
    p.add_argument('--b-muette', action='store_true', help='voie B muette (ancienne puce de la carte, R9 mort)')
    p.add_argument('--trames', type=int, help='affiche les registres des N premières trames')
    a = p.parse_args()
    try:
        morceau = compile_partition(open(a.partition, encoding='utf-8').read())
    except Erreur as e:
        print('%s : %s' % (a.partition, e))
        return 1
    print('%s : %d octets' % (a.partition, len(morceau)))
    if a.o:
        open(a.o, 'wb').write(morceau)
    if a.trames:
        lec = Lecteur(morceau)
        for t in range(a.trames):
            lec.trame()
            print('%4d  %s' % (t, ' '.join('%02X' % x for x in lec.reg[:14])))
    if a.wav:
        ech, taux = rendu(morceau, a.secondes, a.b_muette)
        ecrit_wav(a.wav, ech, taux)
        print('%s : %.1f s' % (a.wav, len(ech) / taux))
    return 0


if __name__ == '__main__':
    sys.exit(main())
