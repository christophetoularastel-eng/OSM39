#!/usr/bin/env python3
# ===================================================================
# test/verifie_constantes.py - attrape le piege lwasm qui rend une
#                              CONSTANTE silencieusement fausse.
# -------------------------------------------------------------------
# Ce controle existe parce qu'il a trouve un VRAI bug le 30 septembre
# 2026, dans la palette de common.inc :
#
#         SPL_FOND_BLEU  equ 1 << SPL_FOND      ; <-- vaut 1, pas 16
#
# DOUBLE PIEGE lwasm 4.24, tous deux SILENCIEUX :
#
#   1. UNE ESPACE AUTOUR D'UN OPERATEUR TRONQUE L'EXPRESSION AU PREMIER
#      MOT. `equ 15 + 1` vaut 15. `equ (15 + 1)` vaut 15 aussi : ce
#      n'est ni une question de precedence ni de parentheses. Ce qui
#      casse, c'est l'ESPACE.
#   2. `<<` N'EST PAS UN OPERATEUR. Meme sans espaces, `equ 1<<16`
#      est refuse : `Bad operand`. Il faut multiplier.
#
# Consequence sur la palette : les fonds sortaient 0,1,2,3,4,5,6,7 au
# lieu de 0,16,32,48,64,80,96,112. Les huit bandes de l'etape 5
# changeaient donc le PREMIER PLAN et jamais le fond -- c'est-a-dire
# que l'etape censee prouver la couleur de fond ne la prouvait pas.
#
# POURQUOI LES DEUX VERIFICATEURS NE L'ONT PAS VU
# verifie_rendu.py relit la table dans le binaire et la confronte a
# une formule ecrite separement : c'est solide. Mais la formule relue,
# c'est LA TABLE ELLE-MEME. Le verificateur controle donc que le code
# ecrit ce que la table dit, pas que la table dit ce qu'elle veut
# dire. Une constante mal evaluee est invisible a cette classe de
# controle par construction -- c'est precisement pour cela qu'elle
# meritait un controle a part entiere.
#
# AUCUN FAUX POSITIF. Une expression sans espace autour de ses
# operateurs est correcte, et c'est la seule forme acceptee ici. Le
# motif ne peut donc pas signaler du code qui fonctionne.
#
# Usage : cd test && make all
# ===================================================================
import io
import os
import re
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(ICI)

# Seuls les repertoires de CODE assemble. Ni docs, ni Python, ni le
# banc `asm/` (qui est un assembleur 6809 ecrit a la main, dont la
# syntaxe est la sienne et n'a rien a voir avec celle de lwasm).
REPERTOIRES = ["bios", "lib", "cmd", "shell", "forth", "basic69",
               "test", "audio", "osmvision", "games", "apps"]
FICHIERS_RACINE = ["basic69.asm", "main.asm", "shell.asm"]

# `equ` : NOM equ valeur
EQU = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s+equ\s+(\S.*?)\s*$")
# `fcb` / `fdb` : la ligne ENTIERE est la valeur.
#
# Le LABELLE EST OPTIONNEL, et il ne l'est pas par hasard. Sans lui, une
# table nommee passait au travers du linter : trouve le 2 octobre 2026 en
# ecrivant la contre-preuve `NOM fcb 15 + 1`. Aucun fichier de l'arbre
# n'a de `fcb`/`fdb` etiquete AUJOURD'HUI, mais `NOM fdb $8000+4` est
# la forme la plus naturelle du tout, et elle n'etait pas couverte.
FF = re.compile(r"^\s*(?:[A-Za-z_][A-Za-z0-9_]*\s+)?(?:fcb|fdb)\s+(\S.*?)\s*$")
# `rmb` : NOM rmb taille
#
# Meme piege, meme silence, meme directive famille -- et le linter
# l'ignoreait. Trouve le 2 octobre 2026 dans osmvision/osmvision.asm :
#         FileNames  rmb 16 * 15   ; <-- vaut 16, PAS 240
# `.bss` mesurait alors 18 octets au lieu de 242, et la copie des noms
# ecrivait 240 octets sur le code du programme. Meme message, meme
# cause que la palette du splash : l'ESPACE autour de l'operateur.
RMB = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s+rmb\s+(\S.*?)\s*$")

CHAINE = re.compile(r'"[^"]*"')


def _valeur(ligne):
    """La partie qui compte : avant le commentaire, sans les chaines.

    Sans ca, `SPL_BRIGHT equ $08  ; + D3 = luminosite` serait signale
    alors que le `+` est dans le commentaire et ne fait rien."""
    ligne = ligne.split(";", 1)[0]
    ligne = CHAINE.sub('""', ligne)
    return ligne.rstrip()


def _analyser(chemin, lignes):
    """Retourne la liste des (numero, motif, texte) fautifs du fichier."""
    fautifs = []
    for n, brute in enumerate(lignes, 1):
        ligne = _valeur(brute)
        if not ligne:
            continue
        m = EQU.match(ligne) or RMB.match(ligne)
        if m:
            corps = m.group(1)
        else:
            m = FF.match(ligne)
            if not m:
                continue
            corps = m.group(1)
        if "<<" in corps:
            fautifs.append((n, "`<<` n'est pas un operateur lwasm "
                               "(meme sans espaces) : multipliez par 2^n",
                            brute.rstrip()))
            continue
        for op in re.finditer(r"\s([+*/])\s", corps):
            fautifs.append((n, "l'espace autour de `%s` tronque l'expression "
                               "au premier mot" % op.group(1),
                           brute.rstrip()))
    return fautifs


def _cibler():
    cibles = []
    for d in REPERTOIRES:
        p = os.path.join(RACINE, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if f.endswith((".asm", ".inc")):
                cibles.append(os.path.join(p, f))
    for f in FICHIERS_RACINE:
        p = os.path.join(RACINE, f)
        if os.path.isfile(p):
            cibles.append(p)
    return cibles


def main():
    cibles = _cibler()
    if not cibles:
        sys.exit("aucun source trouve sous %s" % RACINE)

    total = 0
    rapportes = 0
    for chemin in cibles:
        with io.open(chemin, encoding="utf-8", errors="replace") as f:
            fautifs = _analyser(chemin, f.readlines())
        rel = os.path.relpath(chemin, RACINE)
        total += 1
        if not fautifs:
            continue
        rapportes += 1
        print("  !! %s" % rel)
        for n, pourquoi, texte in fautifs:
            print("     ligne %-4d %s\n        %s" % (n, pourquoi, texte))

    print("  %d fichiers relus (%d avec un probleme)"
          % (total, rapportes))
    if rapportes:
        print("  lwasm tronquera silencieusement chacune de ces lignes : "
              "la constante vaudra le premier mot, pas l'expression. "
              "Retire les ESPACES autour des operateurs, et remplace "
              "`<<` par une multiplication.")
        return 1
    print("  OK : aucune constante ne peut etre mal evaluee par lwasm.")
    return 0


# -------------------------------------------------------------------
# CONTRE-PREUVES
# -------------------------------------------------------------------
# Un verificateur qui ne peut pas echouer ne prouve rien. Ce mode
# s'injecte des lignes FAUSSES une par une dans un fichier temporaire
# et exige de chacune un message DISTINCT. Une traceback compte comme
# le verificateur etant casse, pas comme une detection.
#
# Ces cas ne sont pas theoriques : les quatre premiers sont des bugs
# REELS de ce depot, avec leur date et leur consequence.
#
# (fichier, ligne injectee, fragment attendu dans le message)
CONTRE_PREUVES = [
    ("palette_splash.inc",
     "SPL_FOND_BLEU  equ 1 << SPL_FOND",
     "`<<` n'est pas un operateur",
     "30 sept. 2026 : les huit bandes de l'etape 5 changeaient le "
     "PREMIER PLAN et jamais le fond."),
    ("t1.asm",
     "T_A           equ 15 + 1",
     "tronque l'expression",
     "l'espace autour de `+` : vaut 15, pas 16."),
    # Les deux cas suivants sont mesures sur les OCTETS EMIS, pas
    # supposes. Le second est le plus mechant des deux : 300 et 301 sont
    # tous les deux plausibles, donc rien enAval ne le rattrape.
    ("t2.asm",
     "T_B           fcb 15 + 1",
     "tronque l'expression",
     "mesure : emet `0F` (15), et non `10` (16). Cette contre-preuve a "
     "trouve un DEUXIEME trou : sans libelle optionnel, le motif ne "
     "reconnaissait pas `NOM fcb ...` et la ligne passait."),
    ("t3.asm",
     "T_D           fdb 300 + 5",
     "tronque l'expression",
     "mesure : emet `01 2C` (300), et non `01 2D` (301)."),
    ("fichier_de_noms.asm",
     "FileNames       rmb 16 * 15",
     "tronque l'expression",
     "2 oct. 2026 : vaut 16, PAS 240. `.bss` mesurait 18 octets au "
     "lieu de 242, et la copie des noms ecrivait 240 octets sur le "
     "code du programme. C'est ce cas-ci qui a fait ajouter `rmb` a "
     "ce linter."),
    ("sys_inexistant.asm",
     "sys_bidon      rmb 2",
     "",
     "ligne correcte : le linter doit la laisser passer. C'est la "
     "contre-preuve inverse, sans elle on ne sait pas si le motif "
     "signale des choses ou TOUT."),
]

# CAS DELIBEREMENT NON COUVERTS, et pourquoi. Les ajouter serait
# inutile : lwasm les signale deja lui-meme.
#
#   fcb 1, 2, 3   ->  ERROR : Bad expression (#1)   (il s'en apercoit)
#   fdb 1, 2      ->  idem
#   rmb 16* 15    ->  ERROR : Bad expression         (il s'en apercoit)
#   equ 1<<16     ->  ERROR : Bad operand            (il s'en apercoit)
#
# Seuls les pieges SILENCIEUX meritent un verificateur : un piege que
# l'assembleur signale deja ne peut pas eviter d'etre vu.
#
# En revanche `rmb 16 * 15` (espaces des deux cotes) ne produit
# AUCUN diagnostic et vaut 16 -- c'est le cas de la liste ci-dessus.


def _contre_preuve(nom, ligne):
    """Analyse une ligne isolee et rend le texte du diagnostic, ou ''."""
    with tempfile.NamedTemporaryFile("w", suffix=".asm", delete=False,
                                     encoding="utf-8") as f:
        f.write("section .code\n%s\n" % ligne)
        chemin = f.name
    try:
        with io.open(chemin, encoding="utf-8") as f:
            fautifs = _analyser(chemin, f.readlines())
    finally:
        os.unlink(chemin)
    return "\n".join("%s" % p for _, p, _ in fautifs)


def _verifier_contre_preuves():
    print("  contre-preuves du linter lui-meme :")
    echecs = 0
    for nom, ligne, attendu, pourquoi in CONTRE_PREUVES:
        try:
            message = _contre_preuve(nom, ligne)
        except Exception:
            print("  !! %-22s le verificateur a PLANTE, il n'a rien "
                  "verifie" % nom)
            echecs += 1
            continue
        if not message:
            if attendu:
                print("  !! %-22s AUCUN diagnostic pour une ligne fausse :"
                      " le linter ne peut pas echouer.\n        %s"
                      % (nom, ligne))
                echecs += 1
            else:
                print("     %-22s ligne correcte, aucun faux positif" % nom)
            continue
        if not attendu:
            print("  !! %-22s FAUX POSITIF sur une ligne correcte :\n"
                  "        %s\n        %s" % (nom, ligne, message))
            echecs += 1
            continue
        if attendu not in message:
            print("  !! %-22s detecte, mais pas le message attendu %r :\n"
                  "        %s" % (nom, attendu, message))
            echecs += 1
            continue
        print("     %-22s detecte : %s" % (nom, message.split("\n")[0]))
        print("        %s" % pourquoi)
    return echecs


if __name__ == "__main__":
    if "--contre-preuve" in sys.argv:
        sys.exit(1 if _verifier_contre_preuves() else 0)
    sys.exit(main())