#!/usr/bin/env python3
# ===================================================================
# tout.py - Tous les vérificateurs, d'une commande : make -C test tout
# ===================================================================
# Les recettes viennent de test/Makefile (source unique) : pour chaque
# cible, les lignes « $(MAKE) ... » sont les constructions, les lignes
# « python3 ... » les vérifications. Les constructions passent d'abord,
# une seule fois chacune et dans l'ordre (deux make concurrents dans
# bios/ se marcheraient dessus) ; puis les vérifications tournent en
# parallèle, les plus longues d'abord, chacune avec son journal.
#   python3 tout.py             (zmachine et asm courts)
#   python3 tout.py --long      (zmachine-tout, asm-tout)
#   python3 tout.py -j 2 fs bureau
# Échec = code de sortie <> 0, une ligne « ÉCHEC » ou un Traceback.
# Code de sortie : 0 tout vert, 1 sinon. Journaux : test/tout/*.txt.
# ===================================================================
import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import time

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)
JOURNAUX = os.path.join(ICI, 'tout')

# Les plus longues d'abord (mesuré : bbcbasic et zmachine ~10 min)
CIBLES = ['bbcbasic', 'zmachine', 'asm', 'bureau', 'graphe', 'minitel', 'donjon39', 'osmcity', 'osm3d',
          'demarrage', 'dossiers', 'fs', 'parole', 'terminal', 'farcall',
          'tele', 'clavier', 'horloge', 'aytest', 'joycal', 'ayjoue', 'sdtest',
          'contrat', 'constantes', 'negatifs']
LONGUES = {'zmachine': 'zmachine-tout', 'asm': 'asm-tout'}
# Carte mono : le banc V4 (étapes 1-8) refuse de s'assembler, donc pas de
# negatifs ; à sa place le banc de premier allumage, stage9_mono.
MONO_SANS = ['negatifs']
MONO_EN_PLUS = {'banc_mono': ['make -s STAGE=stage9_mono TEST.hex', 'python3 verifie_banc_mono.py']}


def recettes():
    """{cible: [lignes de commande]} lues dans le Makefile."""
    texte = open(os.path.join(ICI, 'Makefile'), encoding='utf-8').read()
    variables = dict(re.findall(r'^([A-Z_]+)\s*=\s*(\S+)\s*$', texte, re.M))
    r, cible = {}, None
    for ligne in texte.splitlines():
        m = re.match(r'^([A-Za-z0-9_-]+):', ligne)
        if m:
            cible = m.group(1)
            r[cible] = []
        elif ligne.startswith('\t') and cible:
            c = ligne.strip().lstrip('@')
            c = c.replace('$(MAKE)', 'make')
            c = re.sub(r'\$\((\w+)\)', lambda v: variables.get(v.group(1), ''), c)
            r[cible].append(c)
        elif ligne.strip() and not ligne.startswith('#'):
            cible = None
    return r


def lance(cible, commandes):
    """Les vérifications d'une cible : (cible, ok, durée, résumé)."""
    debut = time.time()
    journal = os.path.join(JOURNAUX, cible + '.txt')
    ok, sortie = True, b''
    for c in commandes:
        p = subprocess.run(c, shell=True, cwd=ICI, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
        sortie += p.stdout
        if p.returncode:
            ok = False
            break
    open(journal, 'wb').write(sortie)
    t = sortie.decode('utf-8', 'replace')
    echecs = len(re.findall(r'^ÉCHEC', t, re.M))
    traces = t.count('Traceback')
    if echecs or traces:
        ok = False
    resume = ''
    if not ok:
        resume = '%d ÉCHEC, %d Traceback' % (echecs, traces)
        if not echecs and not traces:
            resume = (t.strip().splitlines() or ['(rien)'])[-1][:70]
    return cible, ok, time.time() - debut, resume


def main():
    a = argparse.ArgumentParser(description='Tous les vérificateurs')
    a.add_argument('--long', action='store_true', help='zmachine-tout et asm-tout')
    a.add_argument('-j', type=int, default=os.cpu_count() or 2, help='vérifications en parallèle')
    a.add_argument('cibles', nargs='*')
    o = a.parse_args()
    toutes = recettes()
    cibles = o.cibles or CIBLES
    if not o.cibles:                    # liste par défaut : sauter ce qui manque
        absentes = [c for c in cibles if c not in toutes]   # (miroir public : bbcbasic)
        if absentes:
            print('absentes de test/Makefile, sautées : ' + ' '.join(absentes))
        cibles = [c for c in cibles if c in toutes]
    carte = open(os.path.join(RACINE, 'CARTE')).read().strip()
    if carte == 'mono' and not o.cibles:
        cibles = [c for c in cibles if c not in MONO_SANS] + list(MONO_EN_PLUS)
    toutes.update(MONO_EN_PLUS)
    if o.long:
        cibles = [LONGUES.get(c, c) for c in cibles]
    for c in cibles:
        if c not in toutes:
            sys.exit('cible inconnue dans test/Makefile : %s' % c)
    print('Carte : %s ; %d cibles, %d en parallèle' % (carte, len(cibles), o.j))

    # 1. les constructions, une fois chacune, dans l'ordre
    faites, verifs = set(), {}
    for c in cibles:
        verifs[c] = []
        for cmd in toutes[c]:
            if cmd.startswith('make'):
                if cmd not in faites:
                    faites.add(cmd)
                    p = subprocess.run(cmd, shell=True, cwd=ICI,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    if p.returncode:
                        sys.stdout.write(p.stdout.decode('utf-8', 'replace'))
                        sys.exit('ÉCHEC de la construction : %s' % cmd)
            else:
                verifs[c].append(cmd)
    print('Constructions : %d, faites' % len(faites))

    # 2. les vérifications, en parallèle
    os.makedirs(JOURNAUX, exist_ok=True)
    debut = time.time()
    resultats = []
    with concurrent.futures.ThreadPoolExecutor(o.j) as ex:
        attente = [ex.submit(lance, c, verifs[c]) for c in cibles]
        for f in concurrent.futures.as_completed(attente):
            c, ok, d, resume = f.result()
            resultats.append((c, ok))
            print('%-5s %-14s %6.0f s  %s' % ('OK' if ok else 'ÉCHEC', c, d, resume), flush=True)
    rates = [c for c, ok in resultats if not ok]
    print('\n%d/%d vertes en %.0f s (carte %s) ; journaux dans test/tout/'
          % (len(resultats) - len(rates), len(resultats), time.time() - debut, carte))
    if rates:
        print('ÉCHEC : ' + ' '.join(rates))
        sys.exit(1)


if __name__ == '__main__':
    main()
