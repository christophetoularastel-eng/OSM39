#!/usr/bin/env python3
# ===================================================================
# test/verifie_remplissage.py - contre-preuve des routines qui
# ecrivent une fenetre video ENTIERE.
# -------------------------------------------------------------------
# verifie_rendu.py ne couvre que splash_draw. Les routines de
# REMPLISSAGE (splash_bandes, splash_clear, ecran_noir) et celle
# d'attente n'etaient couvertes par AUCUNE verification, et
# splash_bandes -- la seule a fermer sa boucle sur un `bne` au lieu
# d'un `cmpx` -- portait exactement le bug qui a fige la carte le
# 28 septembre 2026 :
#
#         stb     ,x++
#         stb     ,x++
#         leau    -2,u
#         bne     sb_c
#
# Ni `stb` ni `leau` ne posent Z. `bne` regardait donc le Z laisse par
# `ldb #'W'` ($57, donc Z = 0) : la boucle ne sortait JAMAIS, X
# continuait au-dela de $8FFF, et le banc ecrivait 'W' par-dessus
# $9000 puis $A000 -- l'ACIA RS232. Symptome sur la carte : ecran
# fige et BREAK muet au moniteur, alors que la carte vivait encore.
#
# CE QUE CE SCRIPT VERIFIE. Deux invariants, et rien d'autre :
#
#   1. AUCUNE ecriture hors de $8000-$9FFF. C'est l'invariant qui
#      attrape la debordement de X. Il est formule comme une
#      propriete de la fenetre materielle, pas comme "la boucle doit
#      durer N tours" : une formule de duree serait vraie ici et
#      fausse ailleurs.
#
#      CARTE V4 (10 oct. 2026) : la fenetre fait 8 Ko, deux RAM a deux
#      adresses. U126 prend a12 : caracteres en $8000-$8FFF, couleurs
#      en $9000-$9FFF. Le PLAN d'une ecriture se lit donc dans son
#      ADRESSE, plus dans la derniere valeur de VRAM_CTRL ($A120), qui
#      ne porte plus que la page (D0-D2). Un debordement de la boucle
#      caracteres tombe desormais dans la RAM couleurs (controle des
#      plans, plus bas), et celui de la boucle couleurs sur $A000 --
#      l'ACIA RS232 (invariant 1).
#   2. LA ROUTINE REND LA MAIN. On execute jusqu'au RTS, avec un
#      plafond d'etapes. Une boucle infinie sature le plafond et sort
#      en erreur AVANT d'avoir rien ecrit hors fenetre, parce que
#      l'invariant 1 est verifie en continu et non a la fin.
#
# On ne verifie PAS le contenu pixel par pixel de ces routines :
# verifie_rendu.py le fait pour le rendu, qui est la partie qui compte.
# Le contenu d'un remplissage de test n'a pas d'interet, sa
# TERMINAISON et son ENVELOPPE en ont.
#
# Le modele de drapeaux est ici STRICTEMENT celui de la documentation :
# LEA ne pose AUCUN drapeau. Si ce modele etait faux, le
# verifieur_rendu serait faux aussi -- il a fait exactement cette
# erreur jusqu'au 28 septembre 2026.
#
# Usage : cd test && make STAGE=stage1_bandes all
# ===================================================================
import re
import sys

TEST = open("TEST", "rb").read()
LST = open(sys.argv[1] if len(sys.argv) > 1 else "stage1_bandes.lst").read()

# [0-9A-Fa-f] et NON [0-9a-f] : la classe minuscule seule ne matche pas
# les offsets lwasm, qui contiennent des majuscules (008B, 00EF...).
def label(nom):
    m = re.search(r"^([0-9A-Fa-f]{4})\s.*\b%s:" % nom, LST, re.M)
    if not m:
        sys.exit("label %s introuvable dans le listing" % nom)
    return int(m.group(1), 16)

LIGNE = re.compile(
    r"^\s*([0-9A-Fa-f]{4})\s+((?:[0-9A-Fa-f]{2})+)?"
    r"\s*\([^\)]*\):[0-9]+\s+(\S.*?)\s*$")

listing = {}
for ligne in LST.splitlines():
    m = LIGNE.match(ligne)
    if not m:
        continue
    ad = int(m.group(1), 16)
    brut = m.group(2) or ""
    src = re.sub(r";.*$", "", m.group(3)).strip()
    # `for o in "E781"` itere la CHAINE, pas les octets : on obtenait
    # 0xE,0x7,0x8,0x1 au lieu de 0xE7,0x81. Le meme defaut existait
    # dans verifie_rendu.py depuis le debut ; il y etait sans
    # consequence parce que ce script ne lit presque jamais la colonne
    # des octets. Ici elle est decisive (postbytes), donc il faut
    # decouper explicitement par PAIRES.
    octets = [int(brut[i:i + 2], 16) for i in range(0, len(brut), 2)]
    # Un LABEL et l'instruction qui le suit portent le meme offset.
    # On ne retient la ligne que si elle a des octets, sinon l'ordre
    # des lignes dans le listing decides du contenu du dictionnaire.
    if octets or ad not in listing:
        listing[ad] = (src, octets)

if not listing:
    sys.exit("listing illisible : aucune ligne instruction trouvee")

# Carte V4 : deux RAM, deux adresses. Une passe se mesure en offsets
# DANS SON PLAN (0..$FFF), quel que soit ce plan.
CAR_BASE, CAR_FIN = 0x8000, 0x9000      # VRAM_BASE .. VRAM_END
COL_BASE, COL_FIN = 0x9000, 0xA000      # VRAM_COL  .. VRAM_COL_END
BASE, FIN = CAR_BASE, COL_FIN           # toute la fenetre CPU
PLAN_NOM = {"C": "caracteres ($8000-$8FFF)", "A": "couleurs ($9000-$9FFF)"}
VRAM_CTRL = 0xA120


def plan_de(u):
    """'C' (caracteres), 'A' (attributs/couleurs) ou None (hors fenetre)."""
    if CAR_BASE <= u < CAR_FIN:
        return "C"
    if COL_BASE <= u < COL_FIN:
        return "A"
    return None

A = B = X = Y = U = 0
Z = False
pile = []
nwrite = 0
couvert = []                # une liste d'ENSEMBLES : un par passe
plans = []                  # le plan ('C' ou 'A') de chaque passe
passe = None                # index de la passe en cours
passe_fin = -1              # derniere adresse ecrite (detecte le rebouclage)
hors = None                 # premiere ecriture hors fenetre, pour le rapport
ctrl = []
ctrl_avant = [None]         # nb de VRAM_CTRL ecrits avant la 1re ecriture video
trace = []
_sortie = [False]

# --- Le CC, et pourquoi il compte -------------------------------------
# Le banc ne fait AUCUN appel BIOS, ce qui fait souvent oublier que le
# BIOS, lui, tourne toujours : ses vecteurs d'interruption sont en place
# et IRQ n'est masque que le temps des routines de remplissage, chacune
# finissant par un `puls ,cc` qui le REMET. Pendant `attente` et pendant
# le `bra fini` final, le gestionnaire VSYNC du BIOS reecrit donc
# l'ecran 62,5 fois par seconde a VRAM_PTR (IT.asm, "AFFICHAGE
# STANDARD"), et reprogramme a chaque trame les registres curseur
# R14/R15 du 68B45 depuis ce meme pointeur.
#
# Vu sur la carte le 30 septembre 2026, etape 4 : ecran noir PARFAIT
# sauf un caractere ligne 3 colonne 49 qui s'effacait puis revenait.
# Offset 208 = 2*80 + 48, soit exactement la position du curseur du
# moniteur au moment du `RUN 0000`. Le "revenir" etait la cadence de
# reecriture ; le "s'effacer en partie", l'arbitrage avec le 68B45 qui
# lit la meme RAM pendant que le CPU la reecrit.
#
# On modelise donc le CC. C'est ce qui permet de REFUSER un `andcc`
# qui retablirait IRQ, au lieu de le constater sur la carte.
IRQ_FIRQ = 0x50               # I (bit 4) et F (bit 5) du CC
CC = 0                        # depart : moniteur actif, interruptions ouvertes
_retablit = []                # (pc, source) : chaque reouverture revoquee


def _orcc(v):
    global CC
    CC |= v


def _andcc(v, src, pc):
    """Referme le masque. Si le bit etait reellement pose, on le note :
    le dire plus tard vaut mieux que le refuser ici, pour que le
    diagnostic cite la ligne fautive."""
    global CC
    if CC & IRQ_FIRQ & ~v:
        _retablit.append((pc, src))
    CC &= v


def getD():
    return (A << 8) | B


def s8(v):
    return v - 256 if v > 127 else v


def imm16(a):
    return TEST[a] << 8 | TEST[a + 1]


def _nz(v, bits):
    global Z
    Z = (v & ((1 << bits) - 1)) == 0


def seta(v):
    global A
    A = v & 0xFF
    _nz(A, 8)


def setb(v):
    global B
    B = v & 0xFF
    _nz(B, 8)


def setD(v):
    global A, B
    v &= 0xFFFF
    A, B = (v >> 8) & 0xFF, v & 0xFF
    _nz(v, 16)


def setX(v):
    global X
    X = v & 0xFFFF
    _nz(X, 16)


def setU(v):
    global U
    U = v & 0xFFFF
    _nz(U, 16)


def contexte(n=16):
    """`n` designe un INDEX ABSOLU dans `trace` (et non un nombre de
    lignes depuis la fin), parce que c'est ce qu'il faut pour afficher
    "les quelques instructions avant l'ecriture fautive"."""
    n = max(0, min(n, len(trace)))
    return "".join("     $%04X  %-20s D=%04X X=%04X Y=%04X U=%04X Z=%d\n"
                   % t for t in trace[max(0, n - 6):n])


# -------------------------------------------------------------------
# L'INVARIANT CENTRAL
# -------------------------------------------------------------------
def fenetre(u, quoi, val=None):
    """Toute ecriture doit tomber DANS la fenetre. On note la premiere
    violation et on continue : afficher l'infini d'ecritures hors
    fenetre n'apprendrait rien, l'adresse de la premiere dit tout.

    `couvert` est une liste d'ENSEMBLES d'offsets : un ensemble par
    PASSE, pas un total. Compter les instructions executees ne dit pas
    si la fenetre est remplie -- deux ecritures au meme endroit font
    deux pour le compteur et une seule pour l'ecran. Mais surtout,
    prendre l'UNION des passes ne dit rien du tout : dans
    `splash_bandes` la passe caracteres couvre deja les 4096 octets,
    donc une passe attributs qui n'ecrirait que les addresses paires
    laisserait l'union complete et l'ecran.Split en deux.

    Une passe est une suite d'ecritures d'adresses croissantes DANS UN
    MEME PLAN ; un retour en arriere, ou un changement de plan (carte
    V4 : la boucle couleurs suit la boucle caracteres a des adresses
    PLUS HAUTES, $9000 apres $8FFF, donc le seul retour en arriere ne
    suffit plus a les separer), ouvre la passe suivante. Chaque passe
    doit couvrir son plan entier ($000-$FFF dans ce plan) sans sauter
    aucun octet -- c'est l'exigence, pas l'union.

    `valeurs[passe]` note en plus les octets REELLEMENT ecrits. C'est ce
    qui manquait, et c'est une omission qui a laisse passer un vrai bug :
    la COUVERTURE ne dit pas QUOI est ecrit. `splash_bandes` ecrivait
    $00 $57 $00 $57... -- les 4096 octets y etaient tous, la
    couverture etait donc parfaite, et l'ecran affichait « W@W@W@W »
    (constate sur la carte le 30 septembre 2026). La cause : `std`
    ecrit A puis B, et un `ldb #'W'` seul laissait A = $00.
    Un remplissage doit ecrire la MEME valeur partout ; c'est ce que
    `valeurs` permet de demander, invariant 3 bis."""
    global nwrite, hors, passe, passe_fin
    plan = plan_de(u)
    if plan is None:
        if hors is None:
            hors = (u, quoi, len(trace))
        passe_fin = max(passe_fin, u)
        return u - BASE
    if passe is None or u <= passe_fin or plans[passe] != plan:
        passe_fin = -1
        couvert.append(set())
        valeurs.append(set())
        plans.append(plan)
        passe = len(couvert) - 1
    if ctrl_avant[0] is None:
        ctrl_avant[0] = len(ctrl)        # VRAM_CTRL ecrits avant la 1re
    nwrite += 1
    base = CAR_BASE if plan == "C" else COL_BASE
    couvert[passe].add(u - base)
    if val is not None:
        valeurs[passe].add(val)
    passe_fin = u
    return u - BASE


# -------------------------------------------------------------------
# formes couvertes
# -------------------------------------------------------------------
INDEXE = {}


def _idx(op, pb, effet, attendu):
    INDEXE[(op, pb)] = (effet, attendu)


def do_pshs(src):
    m = re.match(r"pshs\s+([\w,]+)$", src)
    if not m:
        sys.exit("pshs non reconnu : %r" % src)
    for r in m.group(1).split(","):
        if   r == "a":  pile.append(A)
        elif r == "b":  pile.append(B)
        elif r == "d":  pile.append(getD())
        elif r == "x":  pile.append(X)
        elif r == "y":  pile.append(Y)
        elif r == "u":  pile.append(U)
        elif r in ("cc", "dp"):
            # `dp` est empile avec `cc` sur cette architecture, mais
            # aucune routine du banc ne le lit : on ne garde que le CC,
            # qui est precisement ce que `andcc` pourrait retablir.
            pile.append(CC if r == "cc" else 0)
        else:
            sys.exit("pshs registre inconnu : %r" % r)


def do_puls(src):
    global A, B, X, Y, U
    m = re.match(r"puls\s+([\w,]+)$", src)
    if not m:
        sys.exit("puls non reconnu : %r" % src)
    for r in reversed(m.group(1).split(",")):
        v = pile.pop() if pile else sys.exit("pile vide")
        if   r == "a":  A = v & 0xFF
        elif r == "b":  B = v & 0xFF
        elif r == "d":  setD(v)
        elif r == "x":  X = v
        elif r == "y":  Y = v
        elif r == "u":  U = v
        elif r in ("cc", "dp"):
            # Le CC remonte de la pile. C'est ce qui rend le modele
            # exact : une routine de remplissage fait `orcc` puis
            # `puls ,cc`, donc elle rend la machine EXACTEMENT dans
            # l'etat ou elle l'a trouvee. Si elle se contente de
            # REFERMER sa propre boucle, le masque pose par
            # `prend_la_main` survit -- et c'est bien ce qu'on veut.
            if r == "cc":
                globals()["CC"] = v
        else:
            sys.exit("puls registre inconnu : %r" % r)


# Les formes d'ECRITURE INDEXEE ne sont pas installees ici a la main :
# voir la section 1, qui les lit dans le binaire. La raison est precise
# et elle vaut pour `,x++` comme pour `lea` : le postbyte reellement
# emis par lwasm en mode natif n'est pas documente dans ce depot
# (pour `,x++` on observe $81, pas le $91 du 6809). Les deviner serait
# exactement l'hypothese gratuite qui a produit le bug qu'on cherche.


def branche(pc, off, pris):
    global _pc
    _pc = (pc + 2 + off) & 0xFFFF if pris else (pc + 2)


def decode(pc):
    op = TEST[pc]
    src = listing.get(pc, ("", []))[0]
    if not src:
        sys.exit("!! $%04X (%02X) absent du listing : le code a change, "
                 "ce verificateur doit etre relu" % (pc, op))
    mn = src.split()[0].lower()

    def need(*noms):
        if mn not in noms:
            sys.exit("!! $%04X : attendu %s dans le source, trouve %r"
                     % (pc, "/".join(noms), src))

    # --- PSHS / PULS / RTS : sortie de la routine ---------------------
    if op == 0x34:
        need("pshs"); return 2, (lambda: do_pshs(src))
    if op == 0x35:
        need("puls"); return 2, (lambda: do_puls(src))
    if op == 0x39:
        need("rts"); return 1, (lambda: _sortie.__setitem__(0, True))

    # --- branche relative --------------------------------------------
    if op in (0x20, 0x27, 0x26):
        off = s8(TEST[pc + 1])
        if   op == 0x20: need("bra"); return 2, (lambda: branche(pc, off, True))
        elif op == 0x27: need("beq"); return 2, (lambda: branche(pc, off, Z))
        else:            need("bne"); return 2, (lambda: branche(pc, off, not Z))

    # --- ORCC : pose des bits de masque. AVANT, c'etait un no-op et le
    # --- commentaire affirmait qu'il "ne pose aucun drapeau teste ici".
    # --- C'etait vrai, et c'etait exactement le trou : le banc pouvait
    # --- laisser le gestionnaire VSYNC du BIOS reecrire l'ecran, et
    # --- tous les invariants passaient, car aucun ne regardait le CC.
    if op == 0x1A:
        need("orcc")
        v = TEST[pc + 1]
        return 2, (lambda: _orcc(v))
    if op == 0x1C:
        # ANDCC : la SEULE maniere de retablir IRQ/FIRQ par instruction.
        # Elle est donc refusee partout dans le banc -- c'est
        # l'invariant 4, et il a son propre message pour que la
        # contre-preuve soit distincte des trois autres.
        need("andcc")
        v = TEST[pc + 1]
        return 2, (lambda: _andcc(v, src, pc))
    if op == 0x03:
        # CLI : remet I et F a zero, meme effet que `andcc` sans
        # immediat. Traite comme lui, meme diagnostic.
        need("cli")
        return 1, (lambda: _andcc(0x00, src, pc))

    # --- 2 octets, immediat 8 bits ------------------------------------
    if op == 0x86: need("lda"); return 2, (lambda: seta(TEST[pc + 1]))
    if op == 0xC6: need("ldb"); return 2, (lambda: setb(TEST[pc + 1]))
    if op == 0x84:
        need("anda")
        v = TEST[pc + 1]
        return 2, (lambda: seta(A & v))
    if op == 0x4C:
        # INCA = $4C. ($3C est NEG -- verifier l'opcode dans le
        # listing plutot que de le supposer, c'est gratuit.)
        need("inca")
        return 1, (lambda: seta(A + 1))
    if op == 0x4F:
        need("clra")
        return 1, (lambda: seta(0))
    if op == 0x5A:
        # DECB = $5A : pose Z, contrairement a LEA. Compteur de colonnes
        # de remplit_motif (etape 7).
        need("decb")
        return 1, (lambda: setb(B - 1))

    # --- 3 octets ------------------------------------------------------
    if op == 0xCC: need("ldd"); return 3, (lambda: setD(imm16(pc + 1)))
    if op == 0x8E: need("ldx"); return 3, (lambda: setX(imm16(pc + 1)))
    if op == 0xCE: need("ldu"); return 3, (lambda: setU(imm16(pc + 1)))
    if op == 0x8C:
        # CMPX #imm16 : POSE Z. C'est la difference avec LEA, et c'est
        # pour cela que la boucle se ferme dessus.
        need("cmpx")
        v = imm16(pc + 1)
        return 3, (lambda: setZ((X - v) & 0xFFFF == 0))
    if op == 0x11 and TEST[pc + 1] == 0x83:
        # CMPU #imm16 (6309, prefixe 11) : pose Z lui aussi.
        need("cmpu")
        v = imm16(pc + 2)
        return 4, (lambda: setZ((U - v) & 0xFFFF == 0))

    # --- STA et STD en absolu : le latch de page ----------------------
    # VRAM_CTRL ($A120) n'est PAS dans la fenetre video : c'est un
    # registre du 74HC374. Il doit donc etre traite a part, sinon
    # l'invariant "rien hors de $8000-$9FFF" crierait a chaque
    # choix de page. Carte V4 : il ne choisit plus QUE la page (D0-D2),
    # plus le plan ni le mode d'affichage.
    if op == 0xB7:
        need("sta")
        v = imm16(pc + 1)
        if v != VRAM_CTRL:
            sys.exit("!! $%04X : STA $%04X alors que ce banc n'ecrit que "
                     "dans $%04X-$%04X et $%04X. Le code a change : ce "
                     "verificateur doit etre relu." % (pc, v, BASE, FIN - 1,
                                                        VRAM_CTRL))
        return 3, (lambda: ctrl.append(A))
    if op == 0xFD:
        need("std")
        v = imm16(pc + 1)
        if v != VRAM_CTRL:
            sys.exit("!! $%04X : STD $%04X hors de la fenetre video et du "
                     "latch. Le code a change." % (pc, v))
        return 3, (lambda: ctrl.append(A))

    # --- LEA, ecritures et lectures indexees : tables de la section 1 --
    if op in (0x30, 0x31, 0x32, 0x33,        # LEA R,...
              0xA7, 0xE7, 0xED,              # STA/STB/STD ,R...
              0xA6, 0xE6):                   # LDA/LDB ,R...

        pb = TEST[pc + 1]
        entree = INDEXE.get(pc)
        if entree is None:
            sys.exit("!! $%04X : forme non couverte (op=%02X pb=%02X), "
                     "source %r\n"
                     "   Si le code a change, ce verificateur doit etre "
                     "relu : ne le complete pas a l'aveugle." % (pc, op, pb, src))
        effet, want = entree
        if want not in src:
            sys.exit("!! $%04X : la forme installee pour cette adresse (%r) "
                     "ne correspond plus au source %r : le code a bouge."
                     % (pc, want, src))
        # La longueur se LIT dans le listing : `leau 80,u` fait 3 octets
        # (offset 8 bits, 33 C8 50), pas 2. Supposer 2 faisait repartir
        # le decodage au milieu de l'instruction (etape 7, 8 oct. 2026).
        return len(listing[pc][1]), effet

    sys.exit("!! $%04X : opcode $%02X non couvert, source %r" % (pc, op, src))


def setZ(v):
    global Z
    Z = v


# -------------------------------------------------------------------
# 1. installer les formes reellement employees, d'apres le BINAIRE
# -------------------------------------------------------------------
# DECLENCHEMENT PAR L'ADRESSE, JAMAIS PAR LE COUPLE (opcode, postbyte).
#
# On avait indexe par (op, pb), et c'est faux : `stb ,x++` et
# `stb ,x++` -- la meme forme, a DEUX adresses differentes -- partagent
# le couple (E7, 81). La seconde etait donc ecartee en silence, sa
# boucle de remplissage n'ecrivait rien, et le total d'ecritures
# tombait a moitie. Le script annonçait alors "4096 ecritures" la ou
# il en fait 8192, et le controle de couverture devenait incapable de
# distinguer une boucle correcte d'une boucle arretee tot -- c'est-a-dire
# exactement la confusion qu'il existe pour empecher.
#
# L'encodage 6309 en mode natif n'est pas documente dans ce depot (on
# observe `,x++` en $81 la ou le 6809 met $91), donc on lit les
# postbytes REELS du binaire plutot que de les deviner.
#
# LEA ne pose AUCUN drapeau. C'est le point entier de ce script, et
# c'est aussi ce que verifie_rendu.py supposait a tort jusqu'au
# 28 septembre 2026.
# Constantes `equ` du listing (hardware.inc compris) : un `leax` peut
# porter une expression symbolique depuis la carte V4
# (`leax VRAM_COL_OFS-80,x`, etape 8). On lit leur valeur dans le
# listing, la ou lwasm l'a imprimee, plutot que de la recopier ici.
EQU = {}
for _l in LST.splitlines():
    _m = re.match(r"^\s+([0-9A-Fa-f]{4})\s+\([^)]*\):\d+\s+(\w+):?\s+equ\b",
                  _l, re.I)
    if _m:
        EQU[_m.group(2)] = int(_m.group(1), 16)


def _evaluer(expr, ad):
    """Expression d'offset : entiers decimaux, $hex, symboles `equ`,
    `+` et `-`, SANS espace (piege lwasm). Rien d'autre."""
    if " " in expr:
        sys.exit("!! $%04X : espace dans l'expression %r (lwasm la tronque)"
                 % (ad, expr))
    total, signe = 0, 1
    for tok in re.findall(r"[+-]|[^+-]+", expr):
        if tok == "+":
            signe = 1
        elif tok == "-":
            signe = -signe
        else:
            if re.match(r"^\d+$", tok):
                v = int(tok)
            elif re.match(r"^\$[0-9A-Fa-f]+$", tok):
                v = int(tok[1:], 16)
            elif tok in EQU:
                v = EQU[tok]
            else:
                sys.exit("!! $%04X : symbole %r inconnu dans %r : ce "
                         "verificateur doit etre relu" % (ad, tok, expr))
            total += signe * v
            signe = 1
    return total


def _offset_emis(octets):
    """Offset relu dans les OCTETS d'un LEA indexe a offset constant :
    5 bits signes dans le postbyte (2 octets), puis 8 ou 16 bits signes
    (3 ou 4 octets). Sert a confronter l'expression du source."""
    pb = octets[1]
    if len(octets) == 2 and not pb & 0x80:
        v = pb & 0x1F
        return v - 32 if v > 15 else v
    if len(octets) == 3:
        return s8(octets[2])
    if len(octets) == 4:
        v = octets[2] << 8 | octets[3]
        return v - 65536 if v > 32767 else v
    return None


def _installer_formes():
    for ad, (src, octets) in listing.items():
        if len(octets) < 2:
            continue
        op, pb = octets[0], octets[1]

        # --- LEA <n>,<reg> : lea's le mnemonique porte le REGISTRE
        # (`leax`, `leay`, `leau`, `leas`), donc le motif doit tolerer
        # la lettre collee. Un `lea` nu ne l'est pas, et c'est
        # `tfr`/`lsl` qui s'appellent ainsi.
        m = re.match(r"lea([xyus])\s+([-+$\w]+)\s*,\s*([xyus])$", src)
        if m:
            n, reg = _evaluer(m.group(2), ad), m.group(3)
            emis = _offset_emis(octets)
            if emis is None or emis != n:
                sys.exit("!! $%04X : `%s` : offset %r dans les octets emis, "
                         "%d d'apres le source" % (ad, src, emis, n))
            if m.group(1) != reg:
                # Le registre annonce par le mnemonique et celui du
                # second operande doivent concorder.
                sys.exit("!! $%04X : `lea%s %d,%s` : registre incoherent"
                         % (ad, m.group(1), n, reg))

            def effet_lea(n=n, reg=reg):
                global X, Y, U
                g = {"x": X, "y": Y, "u": U}[reg]
                v = (g + n) & 0xFFFF
                # AUCUN drapeau n'est pose. C'est le point de ce
                # script : `leax`/`leau` calculent une adresse, ils ne
                # comparent rien. Le modele de verifie_rendu.py
                # supposait le contraire jusqu'au 28 septembre 2026.
                if   reg == "x": X = v
                elif reg == "y": Y = v
                else:            U = v

            INDEXE[ad] = (effet_lea, src)
            continue

        # --- ecriture indexee, avec ou sans post-incrementation ------
        # Le post-incrementation compte en OCTETS. On observe `,x++`
        # en $81 et `,x+` en $C4 : la distinction se lit donc dans le
        # postbyte, pas dans une convention supposee. Ici on suit le
        # SOURCE, et l'effet est verifie par la confrontation finale.
        m = re.match(r"(sta|stb|std)\s+,\s*([xyus])(\+\+|\+)?$", src)
        if m:
            op_mn, reg, inc = m.group(1), m.group(2), m.group(3)

            def effet_ecr(reg=reg, inc=inc, op_mn=op_mn):
                global X, Y, U
                p0 = {"x": X, "y": Y, "u": U}[reg]
                # `std` ecrit DEUX octets (D = A:B), `sta`/`stb` un
                # seul. Compter une ecriture par instruction sous-
                # evaluait la fenetre de moitie : c'est ce qui faisait
                # dire "4096 ecritures" a une routine qui en fait
                # 8192, et qui rendait le controle de couverture
                # incapable de distinguer une boucle correcte d'une
                # boucle arretee tot.
                n = 2 if op_mn == "std" else 1
                # Les VALEURS, pas seulement les adresses. `std` ecrit
                # A puis B : c'est exactement le defaut du 30 septembre
                # 2026, ou D = $0057 ecrivait $00 puis $57.
                octets = [A, B] if op_mn == "std" else [A if op_mn == "sta" else B]
                for i in range(n):
                    fenetre(p0 + i, "%s ,%s%s" % (op_mn.upper(), reg.upper(),
                                                  inc or ""), octets[i])
                # `,x++` avance de 2, `,x+` de 1. Les deux ne different
                # que par le bit 0 du postbyte : lwasm emet $80 pour
                # `,x+` et $81 pour `,x++`.
                #
                # Ce modele a dit le contraire jusqu'au 8 oct. 2026
                # (`,x+` = +2), et la CARTE le dement : Put_Text
                # d'OSM-VISION ecrit ses caracteres par `STA ,Y+` et le
                # texte s'affiche d'un seul tenant ; verifie_rendu.py
                # modelise `lda ,y+` en +1 et le splash rendu sur la
                # carte lui donne raison. Aucune routine verifiee ici
                # n'employait `,R+` avant la mire de l'etape 6, d'ou un
                # modele faux reste vert.
                v = (p0 + {"++": 2, "+": 1}.get(inc, 0)) & 0xFFFF
                if   reg == "x": X = v
                elif reg == "y": Y = v
                else:            U = v

            INDEXE[ad] = (effet_ecr, src)
            continue

        # --- lecture indexee 8 bits, avec ou sans post-incrementation.
        # Lit le BINAIRE emis (TEST), lie a $0000 : une table du banc
        # est donc a son adresse dans TEST. Pose N et Z comme LDA/LDB.
        # Ajoute pour la mire de l'etape 6 (`lda ,u+`).
        m = re.match(r"(lda|ldb)\s+,\s*([xyu])(\+\+|\+)?$", src)
        if m:
            op_mn, reg, inc = m.group(1), m.group(2), m.group(3)

            def effet_lec(reg=reg, inc=inc, op_mn=op_mn, ad=ad):
                global X, Y, U
                p0 = {"x": X, "y": Y, "u": U}[reg]
                if p0 >= len(TEST):
                    sys.exit("!! $%04X : %s lit $%04X, hors du binaire"
                             % (ad, op_mn, p0))
                (seta if op_mn == "lda" else setb)(TEST[p0])
                v = (p0 + {"++": 2, "+": 1}.get(inc, 0)) & 0xFFFF
                if   reg == "x": X = v
                elif reg == "y": Y = v
                else:            U = v

            INDEXE[ad] = (effet_lec, src)
            continue


_installer_formes()

# Toute forme indexedee rencontree mais non installee doit etre un
# echec DUR, jamais un silence.
manquantes = set()
for ad, (src, octets) in listing.items():
    if not src or not octets:
        continue
    # Le SOURCE est ce qui distingue une forme indexee d'un immediat :
    # `lda #$00` et `lda ,y+` font tous deux 2 octets, donc la longueur
    # ne peut pas servir a les separer. On exige une virgule suivie
    # d'un registre indexe en fin de ligne, et on ecarte le cas
    # immediat+registre (`ldx #-1,x`).
    if not re.match(r"lea[xyus]\s+", src) and \
       not re.match(r"(sta|stb|std)\s+,\s*[xyus]", src):
        continue                                  # ni LEA ni ecriture indexee
    op, pb = octets[0], octets[1] if len(octets) > 1 else None
    if ad not in INDEXE:
        manquantes.add((ad, src, " ".join("%02X" % o for o in octets)))
if manquantes:
    sys.exit("formes indexedes rencontrees mais non couvertes :\n%s"
             % "\n".join("     $%04X %s (%s)" % t for t in sorted(manquantes)))

# -------------------------------------------------------------------
# 2. execution, invariant par invariant
# -------------------------------------------------------------------
# ATTENDU[nom] = (nb d'octets par passe, page attendue dans VRAM_CTRL,
#                  [(plan, valeur attendue) pour chaque passe]).
#
# CARTE V4 : le deuxieme champ etait le VRAM_CTRL FINAL attendu ($10,
# « mode affichage », D4 = 1). Ce mode n'existe plus. Il devient la
# PAGE : toute ecriture dans VRAM_CTRL doit valoir exactement $00, et
# il en faut une AVANT la premiere ecriture video (le latch n'est pas
# relisible, le banc ne sait pas ce que le moniteur y a laisse). None
# pour une routine qui n'ecrit rien. Le plan de chaque passe ('C' =
# caracteres $8000-$8FFF, 'A' = couleurs $9000-$9FFF) est exige, lui,
# par le troisieme champ : c'est ce qui voit une boucle couleurs restee
# au schema V3 (`ldx #VRAM_BASE` sans le `$08` qui choisissait la RAM
# couleurs), qui ecrit alors ses attributs PAR-DESSUS les caracteres.
#
# Le nombre d'ecritures n'est PAS une formule de duree : c'est la
# COUVERTURE de la fenetre, et elle est derivable de la fenetre
# elle-meme. 4096 octets = $1000, donc une passe sur toute la fenetre
# en ecrit 1 octet (boucle d'attributs) ou 2 (boucle de caracteres,
# `stb ,x++` x2). C'est ce nombre-la qui a manque le 28 septembre
# 2026 : avec un `bne` au lieu d'un `cmpx`, la boucle d'attributs
# sortait apres 16 ecritures -- pas de debordement, donc l'invariant
# "rien hors de la fenetre" ne disait rien, et l'ecran etait a moitie
# rempli. Le controle par le NOMBRE est ce qui rend cette variante
# visible. Sans lui, un verificateur vert sur un banc casse.
#
# Le TROISIEME champ est l'invariant des VALEURS, ajoute le
# 30 septembre 2026 apres un second bug trouve SUR LA CARTE : la
# couverture des 4096 octets etait parfaite, et l'ecran affichait
# quand meme « W@W@W@W ». Remplir la fenetre, c'est ecrire la MEME
# valeur partout ; la couverture ne dit pas laquelle. Une entree de
# cette liste est soit l'octet attendu dans CETTE passe, soit None
# pour une passe dont les valeurs varient volontairement (la boucle
# d'attributs de splash_bandes, qui doit justement changer).
#
# ecran_noir reproduit ce que laisse sys_ClearScreen, donc les DEUX
# RAMS : video.asm:266 efface les caracteres ($2020) et video.asm:278
# efface les couleurs (char_attribut). La passe couleur manquait
# jusqu'au 30 septembre 2026, et l'etape 4 laissait alors « un ecran
# presque noir avec des traces diverses et variees » -- les attributs
# du splash qui continuaient de colorer le glyphe $20.
#
# (Avant la V4, ecran_noir etait la SEULE a reposer la fenetre en mode
# affichage, $10 ; splash_clear s'arretait a $08. Ce mode a disparu.)
ATTENDU = {
    "splash_bandes": (4096, 0x00, [("C", 0x57), ("A", None)]),  # 'W', puis attributs
    "splash_clear":  (4096, 0x00, [("C", 0x20), ("A", 0x00)]),  # espace, noir/noir
    "ecran_noir":    (4096, 0x00, [("C", 0x20), ("A", 0x00)]),  # les DEUX RAM
    "mire_bandes":   (4096, 0x00, [("C", None), ("A", None)]),  # etape 6 : mire
    "bureau_briques": (4096, 0x00, [("C", None), ("A", None)]),  # etape 7 : BRIQUES
    "bureau_uni":    (4096, 0x00, [("C", None), ("A", None)]),  # etape 7 : bleu uni
    "bureau_damier": (4096, 0x00, [("C", None), ("A", None)]),  # etape 7 : damier
    "ligne_haut":    (80,   0x00, [("C", 0x20), ("A", None)]),  # etape 8 : ligne 1
    "ligne_milieu":  (80,   0x00, [("C", 0x20), ("A", None)]),  # etape 8 : ligne 12
    "bandes_horiz":  (4096, 0x00, [("C", 0x20), ("A", None)]),  # etape 8 : 1 sur 2
    "attente":       (0,    None,  []),            # n'ecrit rien
    "prend_la_main": (0,    None,  []),            # n'ecrit rien, voir ci-dessous
}

# MASQUE_REQUIS[nom] = CC final obligatoire.
#
# Le banc ne fait aucun appel BIOS, mais le BIOS n'est pas arrete pour
# autant : ses vecteurs d'interruption restent en place. IRQ n'etait
# masque que LE TEMPS des routines de remplissage, chacune finissant par
# un `puls ,cc` qui le remettait -- donc pendant `attente` et pendant le
# `bra fini` final, handler_IRQ reecrivait l'ecran 62,5 fois par seconde
# a VRAM_PTR, et reprogrammait les registres curseur R14/R15 du 68B45.
#
# Symptome carte (etape 4, 30 septembre 2026) : ecran noir parfait sauf
# un caractere ligne 3 colonne 49, qui s'effacait partiellement et
# revenait. Offset 208 = 2*80 + 48, exactement la position du curseur du
# moniteur au moment du `RUN 0000`. Ce n'etait ni la table de l'etape ni
# un artefact d'`ecran_noir` : c'etait la sortie texte encore en file
# dans ASCII_BUF/COLOR_BUF, reappliquee a chaque trame. Le "revenir"
# etait la cadence ; le "s'effacer en partie", l'arbitrage avec le 68B45
# qui lit la meme RAM pendant que le CPU la reecrit.
#
# Cette entree est ce qui empeche le correctif de disparaitre en
# silence : sans elle, retirer le `orcc` -- ou le refermer par un `puls
# ,cc` -- laisserait les invariants 1 a 3 tous verts.
MASQUE_REQUIS = {
    "prend_la_main": IRQ_FIRQ,       # $50 : I et F, et rien d'autre de permis
}

CIBLES = sys.argv[2:] or None

# Une routine d'ATTENDU peut legitimement ne pas faire partie de
# CETTE etape : l'etape 1 n'inclut pas splash.asm, donc elle n'a ni
# `splash_clear` ni `splash_draw`, et il n'y a rien a y simuler. Son
# absence du listing n'est donc pas une erreur -- il faut mesurer sur
# le binaire reellement emis.
#
# Ce qui EST une erreur, et qui est exactement le piecage qu'on veut
# interdire : une routine ATTENDU presente dans le listing et laissee
# hors de la simulation. C'etait le cas de `attente` avant le
# 29 septembre 2026 -- presente dans ATTENDU, presente aussi dans le
# listing via common.inc, mais absente de CIBLES, donc jamais executee,
# et son `bne` sans `cmpu` (qui ne rend jamais la main) passait sans
# meme etre regarde. D'ou le controle porte sur l'intersection, et non
# sur une des deux listes seulement.
_presentes = [n for n in ATTENDU
              if re.search(r"^([0-9A-Fa-f]{4})\s.*\b%s:" % n, LST, re.M)]

if CIBLES is None:
    CIBLES = list(_presentes)

_absentes = [n for n in _presentes if n not in CIBLES]
if _absentes:
    sys.exit("ATTENDU declare %s, le listing les contient, mais elles ne "
             "sont pas simulees : tant qu'elles ne sont pas executees, "
             "elles ne sont pas verifiees." % ", ".join(repr(n) for n in _absentes))

if not CIBLES:
    sys.exit("aucune routine de remplissage trouvee dans le listing")

for nom in CIBLES:
    if nom not in ATTENDU:
        sys.exit("routine %r sans entree dans ATTENDU : ajoutez le nombre "
                 "d'ecritures attendu, ou le controle de couverture ne "
                 "sera pas fait" % nom)

# Le plafond n'est pas une limite de temps de calcul : c'est un
# garde-fou contre la boucle infinie, et il doit donc depasser la
# temporisation la plus LONGUE du banc, pas la plus lente a remplir.
# `attente` fait 600 tours x 1200 sous-tours, soit ~2 900 000 etapes --
# le plafond de 400 000 qu'on avait mis (calibre sur `splash_bandes`,
# 32 782 etapes) declarait donc la routine CORRECTE non terminante.
# 8 000 000 laisse une marge de 2,8x : assez pour distinguer un delai
# d'une boucle qui ne rend jamais la main.
PLAFOND = 8000000

for nom in CIBLES:
    A = B = X = Y = U = 0
    Z = False
    pile = []
    nwrite = 0
    couvert = []
    valeurs = []
    plans = []
    passe = None
    passe_fin = -1
    hors = None
    ctrl = []
    ctrl_avant = [None]
    trace = []
    _sortie[0] = False
    # Chaque routine est simulee SEULE, avec une machine qu'on pretend
    # rendre dans l'etat de depart : ici, le moniteur actif, IRQ et
    # FIRQ ouverts. C'est ce qui rend `prend_la_main` mesurable -- si
    # elle ne les refermait pas, `CC & IRQ_FIRQ` resterait nul et
    # l'invariant 4 la rejeterait.
    CC = 0
    _retablit = []
    _pc = label(nom)

    etapes = 0
    while not _sortie[0]:
        etapes += 1
        if etapes > PLAFOND:
            break
        if _pc >= len(TEST):
            sys.exit("!! %s : PC=$%04X sort du binaire (taille $%04X)\n"
                     "   contexte :\n%s" % (nom, _pc, len(TEST), contexte(len(trace))))
        trace.append((_pc, listing.get(_pc, ("?", []))[0], getD(), X, Y, U, 1 if Z else 0))
        del trace[:-16]
        n, effet = decode(_pc)
        _pc += n
        if effet:
            effet()

    # --- 1. enveloppe : rien hors de la fenetre ----------------------
    if hors is not None:
        ad, quoi, pos = hors
        sys.exit("!! %s : ecriture %s a $%04X, HORS de $%04X-$%04X\n"
                 "   C'est la debordement de X. Sur la carte, le banc\n"
                 "   ecrivait par-dessus $A000 (ACIA RS232) et figeait\n"
                 "   la machine : ecran fige ET BREAK muet au moniteur.\n"
                 "   Contexte immediat avant l'ecriture :\n%s"
                 % (nom, quoi, ad, BASE, FIN - 1, contexte(pos + 2)))

    # --- 2. terminaison ----------------------------------------------
    if not _sortie[0]:
        sys.exit("!! %s : la routine ne rend pas la main (plafond de %d\n"
                 "   etapes atteint). Une boucle qui ne se ferme pas --\n"
                 "   typiquement un `bne` apres une instruction qui ne pose\n"
                 "   pas Z, comme `leau`. Derniers etats :\n%s"
                 % (nom, PLAFOND, contexte(len(trace))))

    # --- 2 bis. le masque d'interruption TIENT-IL ? -------------------
    #
    # C'est l'invariant 4, ajoute le 30 septembre 2026 apres l'etape 4.
    # Le banc ne fait aucun appel BIOS, mais le BIOS n'est PAS arrete :
    # ses vecteurs d'interruption restent en place. Sans ce controle,
    # une seule ligne suffisait a tout casser -- supprimer le `orcc`
    # de `prend_la_main`, ou ajouter un `andcc` -- et les invariants 1 a
    # 3 seraient tous verts, car aucun ne regarde le CC.
    #
    # Symptome carte de l'absence de ce controle : ecran parfaitement
    # noir sauf UN caractere, ligne 3 colonne 49, qui s'effacait
    # partiellement et revenait. Offset 208 = 2*80+48, soit la
    # position du curseur du moniteur au moment du `RUN 0000` : c'etait
    # handler_IRQ qui reappliquait a chaque trame (62,5 Hz) le texte
    # encore en file dans ASCII_BUF/COLOR_BUF, a VRAM_PTR.
    if _retablit:
        pc, src = _retablit[0]
        sys.exit("!! %s : les interruptions sont REBLOQUEES ici (%04X)\n"
                 "   et `%s` les rouvre.\n"
                 "   Le banc ne fait aucun appel BIOS, mais cela ne veut pas\n"
                 "   dire que le BIOS est arrete : ses vecteurs restent en\n"
                 "   place, et handler_IRQ (IT.asm) ecrit le caractere ET sa\n"
                 "   couleur a VRAM_PTR, 8 par trame, plus les registres\n"
                 "   curseur R14/R15 du 68B45. Le symptome sur la carte etait\n"
                 "   un ecran noir sauf un caractere ligne 3 colonne 49, qui\n"
                 "   s'effacait puis revenait -- la position du curseur du\n"
                 "   moniteur au `RUN 0000`, reecrite 62,5 fois/seconde.\n"
                 "   Corrigé par `prend_la_main`, appele en tete de `start`.\n"
                 "   %d reouverture(s) en tout."
                 % (nom, pc, src.strip(), len(_retablit)))

    # Et l'autre moitie du meme invariant : la routine prescrite doit
    # RENDRE la machine masquee. Sans cela, un `orcc` suivi d'un `puls
    # ,cc` -- c'est-a-dire exactement la forme de toutes les routines
    # de remplissage -- passerait pour un masque alors qu'il n'en
    # laisse aucun.
    if nom in MASQUE_REQUIS and not CC & IRQ_FIRQ:
        sys.exit("!! %s : ne rend pas IRQ et FIRQ masques (CC final = $%02X,\n"
                 "   attendu $%02X). Le `orcc` de cette routine est soit\n"
                 "   absent, soit referme par un `puls ,cc`. Les deux\n"
                 "   retablissent exactement le defaut du 30 septembre\n"
                 "   2026 : le gestionnaire VSYNC du BIOS reecrit l'ecran\n"
                 "   pendant `attente` et pendant le `bra fini` final."
                 % (nom, CC, MASQUE_REQUIS[nom]))

    # --- 3. couverture : chaque PASSE remplit-elle la fenetre ? --------
    #
    # PAS sur l'union. C'est la legerie qui a fait passer un banc
    # faux : dans `splash_bandes` la passe caracteres ecrit deja les
    # 4096 octets, si bien qu'une passe attributs n'ecrivant que les
    # addresses paires laissait l'union complete -- verification verte
    # sur un ecran dont la moitie des attributs n'avait jamais ete
    # ecrite. Chaque passe se controle donc seule.
    natt, ctrl_att, vals_att = ATTENDU[nom]
    if natt:
        for i, ens in enumerate(couvert):
            if len(ens) != natt:
                manques = [o for o in range(natt) if o not in ens]
                sys.exit("!! %s : passe %d de %d -- %d des %d octets de la\n"
                         "   fenetre seulement (les autres passes sont, elles,\n"
                         "   correctes : c'est bien l'UNION qui masque le\n"
                         "   defaut). Premier octet non ecrit : $%04X, et %d\n"
                         "   de ce type. Cause habituelle : une ecriture d'un\n"
                         "   octet avec un post-incrementation de 2 (`sta ,x++`\n"
                         "   ecrit UN octet et avance X de DEUX), donc un octet\n"
                         "   sur deux saute. Derniers etats :\n%s"
                         % (nom, i + 1, len(couvert), len(ens), natt,
                            (CAR_BASE if plans[i] == "C" else COL_BASE)
                            + manques[0], len(manques),
                            contexte(len(trace))))


    # --- 3 bis. VALEURS : une passe de remplissage ecrit-elle UN SEUL
    #        octet, ou deux entre elles ? -----------------------------
    # La couverture dit QUELS offsets sont ecrits, pas QUOI. Une passe
    # qui ecrit bien les 4096 octets peut y mettre autre chose que le
    # caractere voulu -- et c'est exactement ce qui est arrive le
    # 30 septembre 2026, sur la carte : « W@W@W@W ». Les 4096 octets
    # y etaient tous, la couverture etait parfaite, les deux
    # verificateurs etaient verts, et l'ecran montrait un glyphe sur
    # deux. Cause : `std` ecrit A puis B, et un `ldb #'W'` seul
    # laissait A a $00 (venu du changement de page juste avant), donc
    # D = $0057 et la fenetre alternait $00 et $57.
    #
    # On exige donc, passe par passe, que TOUTES les valeurs ecrites
    # soient identiques a celle annoncee dans ATTENDU. Une passe a None
    # est un remplissage qui DOIT varier : les attributs de
    # `splash_bandes` ont precisement pour role de changer.
    # Le NOMBRE de passes doit correspondre a la declaration. Sans ce
    # controle, une passe entierement ABSENTE passait : la boucle
    # ci-dessous ne visitait que les passes existantes, donc
    # `vals_att[1]` n'etait jamais consulte. C'est exactement le bug
    # du 30 septembre 2026 -- la passe couleur de `ecran_noir`, que
    # le banc executait une fois de trop peu, laissait « un ecran
    # presque noir avec des traces diverses et variees » -- et
    # ATTENDU declarait cette unique passe comme correcte. Le
    # verificateur ne(validait) pas seulement le code : il ENCODE
    # aussi ce qu'il croit etre la specification, donc il peut
    # figer un bug au lieu de le voir.
    if natt and len(couvert) != len(vals_att):
        sys.exit("!! %s : %d passe(s) ecrites, %d attendues. "
                 "%s\n"
                 "   Une passe ENTIEREMENT ABSENTE passait jusqu'ici : le "
                 "controle des valeurs\n   ne visitait que les passes "
                 "reellement executees. Cause habituelle : une routine "
                 "qui n'efface\n   qu'une des deux RAM. `sys_ClearScreen` en "
                 "efface DEUX (bios/video.asm:266 les caracteres,\n"
                 "   :278 les couleurs) -- n'en effacer qu'une laisse "
                 "les attributs, et le glyphe $20\n   reste visible "
                 "dans les couleurs de ce qui precedait."
                 % (nom, len(couvert), len(vals_att),
                    ("la passe en trop" if len(couvert) > len(vals_att)
                     else "il manque la passe %d (RAM %s)"
                     % (len(couvert) + 1,
                        PLAN_NOM[vals_att[len(couvert)][0]]))))

    # --- 3 quater. PLAN de chaque passe (carte V4) ----------------------
    # Le plan se lit dans l'ADRESSE. Une boucle couleurs restee au
    # schema V3 -- `ldx #VRAM_BASE / ... / cmpx #VRAM_END`, sans le
    # `lda #$08 / sta VRAM_CTRL` qui choisissait la RAM couleurs et que
    # la carte V4 ignore -- couvre parfaitement 4096 octets, avec les
    # bonnes valeurs, au bon nombre de passes : TOUS les invariants
    # ci-dessus sont verts. Mais elle ecrit ses attributs PAR-DESSUS
    # les caracteres, et l'ecran n'a plus de texte.
    if natt:
        for i, plan in enumerate(plans):
            voulu = vals_att[i][0]
            if plan != voulu:
                sys.exit("!! %s : passe %d de %d ecrite dans la RAM %s, "
                         "attendue dans la RAM %s.\n"
                         "   Carte V4 : le plan se choisit par l'ADRESSE "
                         "(a12, U126), plus par\n   $08 dans VRAM_CTRL. "
                         "Couleurs = $9000-$9FFF (VRAM_COL..VRAM_COL_END)."
                         % (nom, i + 1, len(plans), PLAN_NOM[plan],
                            PLAN_NOM[voulu]))

        # Meme CELLULES dans les deux plans : une passe couleurs couvre
        # les offsets de la passe caracteres qui la precede. Trivial
        # pour un plan entier ; c'est `ecrit_ligne` (etape 8) qu'il
        # vise, ou la couleur se trouve par `leax VRAM_COL_OFS-80,x` :
        # une ligne de couleurs decalee d'une ligne passerait sinon,
        # 80 octets sur 80.
        for i in range(1, len(plans)):
            if plans[i - 1] == "C" and plans[i] == "A" \
               and couvert[i] != couvert[i - 1]:
                sys.exit("!! %s : la passe couleurs %d ne couvre pas les "
                         "memes cellules que la passe caracteres %d "
                         "(couleurs $%04X..., caracteres $%04X...)"
                         % (nom, i + 1, i,
                            COL_BASE + min(couvert[i]),
                            CAR_BASE + min(couvert[i - 1])))

    if natt:
        for i, ens in enumerate(couvert):
            attendu = vals_att[i][1] if i < len(vals_att) else None
            if attendu is None:
                continue
            vus = valeurs[i] if i < len(valeurs) else set()
            if vus != {attendu}:
                lus = " ".join("$%02X" % v for v in sorted(vus)[:4])
                sys.exit("!! %s : passe %d de %d -- la fenetre est bien "
                         "remplie (%d octets), mais elle contient %s, pas "
                         "$%02X.\n"
                         "   La COUVERTURE dit OU, pas QUOI : un remplissage "
                         "doit ecrire\n   la MEME valeur partout. Cause "
                         "habituelle : `std` ecrit A PUIS B,\n   donc un "
                         "`ldb $VAL` seul (A inchange) donne D = $00XX et "
                         "la fenetre\n   alterne deux octets. Valeurs vues : "
                         "%s"
                         % (nom, i + 1, len(couvert), len(ens), lus,
                            attendu, lus))

    # --- 4. latch de page (carte V4) -----------------------------------
    # Avant la V4 : « dernier VRAM_CTRL = $10 », D4 = 1 rendait la VRAM
    # au 68B45. Ce mode n'existe plus. Reste la PAGE : choisie AVANT la
    # premiere ecriture video, et toujours la page 0 ($00). Une valeur
    # avec D3-D5 ($08, $10) est un reste du schema V3.
    if ctrl_att is not None:
        if not ctrl:
            sys.exit("!! %s : VRAM_CTRL ($A120) n'a jamais ete ecrit : la "
                     "page video n'est pas choisie" % nom)
        if ctrl_avant[0] == 0:
            sys.exit("!! %s : ecriture video AVANT le premier VRAM_CTRL : "
                     "la page n'etait pas encore choisie" % nom)
        autres = [v for v in ctrl if v != ctrl_att]
        if autres:
            sys.exit("!! %s : VRAM_CTRL = $%02X ecrit, seule la page 0 "
                     "($%02X) est permise.\n"
                     "   Carte V4 : D0-D2 = page ; D3 (l'ancien $08, RAM "
                     "couleurs) et D4-D5\n   (l'ancien $10, mode "
                     "affichage) sont ignores par la carte."
                     % (nom, autres[0], ctrl_att))

    detail = []
    for i in range(len(couvert)):
        v = valeurs[i] if i < len(valeurs) else set()
        detail.append("$%02X" % v.pop() if len(v) == 1 else "variable")
    print("  %-14s rend la main : %7d etapes, %d passe(s), chacune %d/%-4d "
          "octets [%s], plans [%s], VRAM_CTRL %s"
          % (nom, etapes, len(couvert), len(couvert[0]) if couvert else 0,
             natt, " ".join(detail), " ".join(plans),
             " ".join("$%02X" % v for v in ctrl) or "-"))

print("  OK : aucune ecriture hors de la fenetre, toutes les routines "
      "terminent.")
