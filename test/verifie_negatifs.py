#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ===================================================================
# test/verifie_negatifs.py - verifie que les verificateurs ECHOIENT
# -------------------------------------------------------------------
# Un verificateur qui reussit toujours ne prouve rien. Celui-ci ne
# fait donc pas confiance aux deux verificateurs : il leur injecte des
# bugs dans LEUR source, un par un, et exige a chaque fois un echec.
# Si l'un de ces bugs passe, c'est la preuve que la verification
# d'apres n'a aucune valeur -- donc ce script echoue.
#
# Deux familles, deux verificateurs, DEUX FICHIERS, et c'est delibere :
#
#   - CAS         touche `splash_draw`, verifie par verifie_rendu.py.
#                 Les six premiers bugs portent sur le calcul d'adresse
#                 et les conventions 6309 non prouvees ; les deux
#                 derniers (10 oct. 2026) sur la carte V4, ou le plan
#                 caracteres/couleurs se choisit par l'ADRESSE ($8000 /
#                 $9000) et plus par $08 dans VRAM_CTRL. splash_draw est
#                 dans splash.asm depuis le 29 septembre 2026 : les
#                 ancres suivent le code, pas son ancien emplacement.
#   - CAS_REMPL   touche les routines qui remplissent la fenetre
#                 (splash_bandes, attente), verifiees par
#                 verifie_remplissage.py. Elles sont restees dans
#                 common.inc, qui garde ce qui est commun a toutes les
#                 etapes. Ces routines n'etaient verifiees par RIEN
#                 avant le 29 septembre 2026, et c'est pourtant la
#                 boucle caracteres de `splash_bandes` qui a fige la
#                 carte.
#
# Chaque cas porte donc le nom du fichier a modifier. C'est une
# source d'erreur de plus, donc un controle de plus : si une ancre
# n'est plus presente dans le fichier qu'elle annonce, le cas est
# signale plutot que passe.
#
#   cd test && make STAGE=stage3_splash && make -C . negatifs
#
# Chaque cas doit produire une erreur DISTINTE et lisible, pas un
# simple code de sortie non nul : un `TypeError` ou une traceback
# serait le signe que le verificateur s'est casse, pas qu'il a
# detecte le bug. Le script distingue les deux.
#
# Les deux sources sont restaurees dans un `finally` : une erreur ne
# doit jamais laisser un source bricole derriere elle.
# ===================================================================
import io
import os
import re
import shutil
import subprocess
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
COMMUN = os.path.join(ICI, "common.inc")
SPLASH = os.path.join(ICI, "splash.asm")
ETAPE = "stage3_splash"

# Les cinq etapes, dans l'ordre du banc. Doit correspondre a STAGES du
# Makefile, sinon ce test controle moins d'etapes qu'il n'en croit.
STAGES = ["stage1_bandes", "stage2_rendu", "stage3_splash",
          "stage4_symptome", "stage5_fond"]

# La table que verifie_rendu.py doit rendre pour l'etape de reference.
# Doit correspondre a TABLE_stage3_splash du Makefile.
TABLE = "splash_data"

# --- le texte qu'on ne touche pas, pris tel quel sur le disque -----
# On ne part pas de `git show` : le but est de tester CE QUI EST SUR
# LE DISQUE, y compris une modification non commitee. Si la reference
# elle-meme est fausse, la premiere etape du script le dit.
AVANT = {
    COMMUN: io.open(COMMUN, encoding="utf-8").read(),
    SPLASH: io.open(SPLASH, encoding="utf-8").read(),
}

# --- les bugs a injecter dans splash_draw -------------------------
# Chaque cas : (titre, [(cherche, remplacement), ...], fragment
# attendu dans le message d'echec). Le fragment distingue "detecte"
# de "casse".
#
# ⚠ CHAQUE ANCRE DOIT ETRE UNIQUE DANS LE FICHIER QU'ELLE CIBLE,
# sinon l'injection ne touche pas splash_draw et le bug "passe" --
# c'est-a-dire que le test est vert sans rien tester. C'est deja
# arrive : `ldx #VRAM_BASE` apparait SIX fois dans common.inc
# (ecran_noir, splash_clear, splash_bandes...) alors que l'ancre visait
# splash_draw, et un remplacement par le premier coupait splash_bandes.
# Depuis la separation des sources, les six occurrences sont reparties
# sur deux fichiers, mais le piege reste entier : le controle
# d'unicite ci-dessous echoue plutot que de laisser croire a une
# contre-preuve. Il porte sur le fichier DECLARE par le cas, et chaque
# ancre y estcomptee.
CAS = [
    ("convention non prouvee : `ldu #0 / ldb` depend de "
     "l'aliasing de B sur U, que la doc n'etablit pas",
     [("        ldu     0,y                 ; U = numero de ligne "
       "(2 octets)",
       "        ldu     #0\n"
       "        ldb     ,y                  ; INCERTAIN : suppose "
       "que B alias U")],
     "forme indexee non couverte"),

    ("un doublement manquant dans la chaine x80",
     [("        addr    d,d                 ; ligne * 40\n"
       "        addr    d,d                 ; ligne * 80",
       "        addr    d,d                 ; ligne * 40  "
       "(il manque le *80)")],
     "ligne"),

    ("attribut lu a l'offset 3 au lieu de 4",
     [("        ldb     4,y                 ; attribut, valable pour le segment",
       "        ldb     3,y                 ; FAUX : attribut")],
     "forme indexee non couverte"),

    ("leay 5,y remplace par leau 5,u",
     [("        leay    5,y                 ; Y = premier caractere",
       "        leau    5,u                 ; FAUX : deplace U, pas Y")],
     "forme indexee non couverte"),

    ("terminateur de table errone ($00FE)",
     [("        cmpu    #$00FF              ; $00FF = fin de table",
       "        cmpu    #$00FE              ; FAUX : terminateur faux")],
     "hors du binaire"),

    ("base de la fenetre video decalee de $1000 : les caracteres "
     "tombent dans la RAM couleurs (carte V4), et les attributs, "
     "4 Ko plus haut, sur $A000 et au-dela -- l'ACIA RS232",
     # l'ancre contient la ligne d'avant, la SEULE qui suit ce
     # commentaire propre a splash_draw
     [("        addr    u,d                 ; D = ligne * 80 + colonne\n"
       "        ldx     #VRAM_BASE",
       "        addr    u,d                 ; D = ligne * 80 + colonne\n"
       "        ldx     #VRAM_COL           ; FAUX : fenetre decalee")],
     "hors fenetre video"),

    # --- carte V4 (10 oct. 2026) : le plan se choisit par l'ADRESSE ---
    ("attribut ecrit a l'adresse du caractere (`stb ,u`) : c'est le "
     "schema V3, ou `lda #$08 / sta VRAM_CTRL` choisissait la RAM "
     "couleurs a la MEME adresse. En V4, D3 est ignore et l'attribut "
     "ecrase le caractere",
     [("        stb     VRAM_COL_OFS,u      ; RAM couleurs, meme cellule + $1000",
       "        stb     ,u                  ; FAUX : schema V3")],
     "aucun attribut dans la RAM couleurs"),

    ("VRAM_CTRL recoit $08 au lieu de $00 : un reste du schema V3 "
     "(D3 = RAM couleurs), que la carte V4 ignore -- le code croit "
     "choisir un plan par le latch",
     [("        lda     #$00                ; page 0 (V4 : D0-D2 seuls comptent)\n"
       "        sta     VRAM_CTRL\n"
       "sd_next:",
       "        lda     #$08                ; FAUX : schema V3\n"
       "        sta     VRAM_CTRL\n"
       "sd_next:")],
     "la page doit etre 0"),
]

# --- les bugs des routines de remplissage --------------------------
# Meme mecanique (injection, build, echec exige avec un fragment de
# message distinct), mais un AUTRE verificateur.
#
# Les dix messages attendus designent dix controles distincts :
#   * "HORS de"             -> invariant 1, rien hors de la fenetre
#   * "passe 2 de 2"        -> invariant 3, couverture MESUREE PAR PASSE
#   * "ne rend pas la main" -> invariant 2, terminaison
#   * "MEME valeur partout" -> invariant 3 bis, VALEURS (ajoute le
#                              30 septembre 2026, apres le bug « W@W@W@W »)
#   * "$56, pas $57"        -> invariant 3 bis, valeur attendue et non
#                              seulement uniforme
#   * "passe(s) ecrites"    -> invariant 3 ter, NOMBRE de passes (ajoute le
#                              30 septembre 2026 : la passe couleur de
#                              `ecran_noir` manquait, et elle n'etait pas
#                              vue parce que la boucle sur les valeurs ne
#                              visitait que les passes executees)
#   * "sont REBLOQUEES ici" -> invariant 4, le masque d'interruption tient
#                              (ajoute le 30 septembre 2026 : un `andcc`
#                              qui rouvre IRQ)
#   * "ne rend pas IRQ et FIRQ masques" -> invariant 4 bis, la routine
#                              prescrite rend la machine masquee (le
#                              `orcc` de `prend_la_main` supprime)
#   * "attendue dans la RAM couleurs" -> invariant 3 quater, carte V4 :
#                              le PLAN de chaque passe, lu dans l'adresse
#   * "seule la page 0"     -> latch, carte V4 : VRAM_CTRL ne recoit que
#                              $00 (l'ancienne exigence « VRAM_CTRL final
#                              = $10 », mode affichage, n'existe plus)
# Les deux premiers etaient indiscernables tant que la couverture
# etait prise sur l'UNION des passes : la passe caracteres ecrit deja
# les 4096 octets, donc une passe attributs n'ecrivant que les octets
# pairs laissait l'union complete -- verification verte sur un ecran
# dont la moitie des attributs n'avait jamais ete ecrite.
#
# Les deux cas de valeurs sont deliberement un COUPLE : l'un met deux
# valeurs DANS la fenetre, l'autre une seule valeur -- mais la MAUVAISE.
# Aucun des deux ne change la couverture, donc aucun des deux ne serait
# vu par les invariants 1 a 3. C'est la demonstration que l'invariant
# 3 bis n'est pas redondant.
#
# ⚠ Un verificateur ne VALIDE pas seulement le code : il ENCODE ce qu'il
# croit etre la specification, et peut donc FIGER un bug. C'est
# exactement ce qui est arrive a `ecran_noir` : ATTENDU declarait une
# seule passe, la routine n'en faisait qu'une, et « corriger » la
# routine se faisait REJETER par le controle de couverture. Le
# verificateur etait vert, la carte montrait « un ecran presque noir
# avec des traces diverses et variees ». Le sixieme cas rejoue ce bug
# par injection, pour que la fermeture soit elle-meme testee.
CAS_REMPL = [
    ("boucle caracteres fermee sur un `bne` au lieu d'un `cmpx` : "
     "c'est le bug qui a fige la carte le 28 septembre 2026",
     [("        std     ,x++\n"
       "        cmpx    #VRAM_END\n"
       "        bne     sb_c",
       "        std     ,x++\n"
       "        leau    -2,u                ; NE POSE PAS Z\n"
       "        bne     sb_c")],
     "HORS de"),

    ("boucle attributs avec `sta ,x++` : ecrit UN octet et avance de "
     "DEUX, donc un attribut sur deux n'est jamais ecrit",
     [("        anda    #$0F                ; 0..15 = 8 teintes x normal/lumieux\n"
       "        sta     ,x\n"
       "        inca\n"
       "        leax    1,x\n"
       "        cmpx    #VRAM_COL_END",
       "        anda    #$0F\n"
       "        sta     ,x++                ; 1 octet, X +2\n"
       "        inca\n"
       "        cmpx    #VRAM_COL_END")],
     "passe 2 de 2"),

    ("boucle d'attente sans `cmpu` : le `bne` teste le Z laisse par "
     "`ldu #1200` et la temporisation ne rend jamais la main",
     [("        leau    -1,u\n"
       "        cmpu    #0                  ; `leau` ne pose pas Z (piege 3)\n"
       "        bne     at2",
       "        leau    -1,u\n"
       "        bne     at2")],
     "ne rend pas la main"),

    ("`ldb #'W'` seul : `std` ecrit A PUIS B, A est donc encore $00 et "
     "la fenetre alterne $00 et $57 -- c'est le bug « W@W@W@W » vu sur "
     "la carte le 30 septembre 2026, invisible a l'invariant de "
     "couverture parce que les 4096 octets y sont bien TOUS",
     [("        lda     #'W'\n"
       "        ldb     #'W'",
       "        ldb     #'W'                ; A reste a $00 : D = $0057")],
     "MEME valeur partout"),

    ("le caractere de remplissage change ('W' -> 'V') : une seule "
     "valeur dans toute la fenetre, donc la COUVERTURE est parfaite "
     "-- il faut la comparaison a la valeur attendue, pas seulement "
     "l'uniformite",
     [("        lda     #'W'\n"
       "        ldb     #'W'",
       "        lda     #'V'\n"
       "        ldb     #'V'")],
     "$56, pas $57"),

    ("passe couleur SUPPRIMEE de `ecran_noir` : la routine n'efface "
     "qu'une des deux RAM. C'est le bug vu sur la carte le 30 septembre "
     "2026 -- « ecran presque noir avec des traces diverses et variees », "
     "les attributs du splash survivant. Cas special parce que le "
     "verificateur ne le voyait pas : sa boucle sur les valeurs ne "
     "visitait que les passes reellement executees, donc une passe "
     "ABSENTE ne declenchait rien. D'ou le controle du NOMBRE de passes",
     [("        ldx     #VRAM_COL           ; page 0, RAM couleurs\n"
       "        ldd     #SPL_BLACK          ; $0000 : noir sur noir\n"
       "en_a:\n"
       "        std     ,x++\n"
       "        cmpx    #VRAM_COL_END\n"
       "        bne     en_a\n",
       "        ; passe couleur supprimee -- INJECTION\n")],
     "passe(s) ecrites"),

    ("`andcc` rajoute a `prend_la_main` : le masque est pose puis "
     "ROMPU, ce qui est le contresens exact du correctif. Le banc ne "
     "fait aucun appel BIOS, mais le BIOS n'est pas arrete -- ses "
     "vecteurs d'interruption restent en place et handler_IRQ ecrit le "
     "caractere ET sa couleur a VRAM_PTR 8 fois par trame, plus les "
     "registres curseur R14/R15 du 68B45. Symptome carte : ecran noir "
     "sauf un caractere ligne 3 colonne 49, qui s'effacait et revenait "
     "-- la position du curseur du moniteur au `RUN 0000`, reecrite "
     "62,5 fois par seconde. Aucun des invariants 1 a 3 ne regarde le "
     "CC, donc ils seraient tous verts",
     [("        orcc    #%01010000          ; F + I. Volontairement sans `puls` :\n"
       "                                    ; ce masque ne se rend JAMAIS.\n"
       "        rts",
       "        orcc    #%01010000\n"
       "        andcc   #%00101111          ; INJECTION : on rouvre\n"
       "        rts")],
     "sont REBLOQUEES ici"),

    ("le `orcc` de `prend_la_main` disparait : plus aucune interruption "
     "n'est masquee, et le gestionnaire VSYNC du BIOS reecrit l'ecran "
     "pendant `attente` et pendant le `bra fini` final. C'est la "
     "regression la plus facile a introduire -- supprimer une ligne -- et "
     "celle que la seule lecture des invariants 1 a 3 ne voit pas. "
     "D'ou MASQUE_REQUIS, qui exige en plus que la routine prescrite "
     "rende la machine masquee",
     [("        orcc    #%01010000          ; F + I. Volontairement sans `puls` :\n"
       "                                    ; ce masque ne se rend JAMAIS.\n"
       "        rts",
       "        rts                     ; INJECTION : plus de orcc du tout")],
     "ne rend pas IRQ et FIRQ masques"),

    # --- carte V4 (10 oct. 2026) --------------------------------------
    ("passe couleurs d'`ecran_noir` restee au schema V3 : `ldx "
     "#VRAM_BASE` ... `cmpx #VRAM_END`, sans le `lda #$08 / sta "
     "VRAM_CTRL` que la carte V4 ignore. 4096 octets, bonnes valeurs, "
     "bon nombre de passes : seuls les PLANS la trahissent -- elle "
     "efface les caracteres une seconde fois et laisse les couleurs",
     [("        ldx     #VRAM_COL           ; page 0, RAM couleurs\n",
       "        ldx     #VRAM_BASE          ; FAUX : schema V3\n"),
      ("        cmpx    #VRAM_COL_END\n"
       "        bne     en_a\n",
       "        cmpx    #VRAM_END\n"
       "        bne     en_a\n")],
     "attendue dans la RAM couleurs"),

    ("`ecran_noir` ecrit $08 dans VRAM_CTRL au lieu de $00 : D3 ne "
     "choisit plus rien en V4, c'est un reste du schema V3",
     [("        lda     #$00\n"
       "        sta     VRAM_CTRL\n"
       "        ldx     #VRAM_BASE\n"
       "        ldd     #$2020\n"
       "en_c:",
       "        lda     #$08                ; FAUX : schema V3\n"
       "        sta     VRAM_CTRL\n"
       "        ldx     #VRAM_BASE\n"
       "        ldd     #$2020\n"
       "en_c:")],
     "seule la page 0"),
]


# Quel fichier chaque famille de cas doit modifier. C'est le decoupage
# reel des sources depuis le 29 septembre 2026 : splash_draw est dans
# splash.asm, les routines de remplissage sont restees dans common.inc.
# Une famille ne doit pas toucher le fichier de l'autre : sinon une
# contre-preuve passerait pour une autre, et le message attendu ne
# voudrait plus rien dire.
CIBLE = {"rendu": SPLASH, "remplissage": COMMUN}


def _controler_ancres():
    """Chaque ancre doit apparaitre EXACTEMENT une fois DANS LE FICHIER
    QU'ELLE CIBLE. Une ancre absente ou ambigue rendrait le test vert
    sans rien tester."""
    for quel, cas in (("rendu", CAS), ("remplissage", CAS_REMPL)):
        f = CIBLE[quel]
        for titre, rustines, _ in cas:
            for cherche, _r in rustines:
                n = AVANT[f].count(cherche)
                if n != 1:
                    print("  !! ancre trouvee %d fois dans %s (cas %r) :\n"
                          "     %r"
                          % (n, os.path.basename(f), titre, cherche[:70]))
                    return False
    return True


def _construire(etape=None, quel="rendu"):
    """Reconstruit le binaire et rend (code, sortie) du verificateur.

    `quel` : "rendu" pour verifie_rendu.py (splash_draw), "remplissage"
    pour verifie_remplissage.py (les routines de remplissage). Les
    deux tournent sur le meme binaire mais repondent a des questions
    differentes -- les confondre ferait passer une contre-preuve qui
    n'a rien teste."""
    etape = ETAPE if etape is None else etape
    p = subprocess.run(["make", "-s", "STAGE=" + etape, "TEST.hex"],
                       cwd=ICI, capture_output=True, text=True)
    if p.returncode != 0:
        return 90, "make a echoue :\n" + p.stdout + p.stderr
    script = {"rendu": "verifie_rendu.py",
              "remplissage": "verifie_remplissage.py"}[quel]
    # verifie_rendu.py prend le nom de la table a rendre en 2e argument.
    # Il doit etre passe ici aussi, sinon la contre-preuve tournerait
    # sur la table par defaut alors que l'etape de reference en a
    # peut-etre une autre -- et l'echec viendrait de la mauvaise table.
    args = [etape + ".lst"]
    if quel == "rendu":
        args.append(TABLE)
    p = subprocess.run(["python3", script] + args,
                       cwd=ICI, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def _make_sortie(etape):
    """Sortie du build pour l'etape demandee, reconstruction forcee.

    Le `ETAPE = ...` est un @echo d'une regle de TEST.hex : sans
    reconstruction, `make -s` n'affiche rien du tout. D'ou le
    `_construire` prealable, qui garantit que le fichier existe et est
    donc vu comme a jour -- mais sur un changement d'etape c'est justement
    ce qu'on veut voir rebatir, donc on force par defaut.
    """
    return subprocess.run(["make", "-B", "-s", "STAGE=" + etape, "TEST.hex"],
                          cwd=ICI, capture_output=True,
                          text=True).stdout


def _ecrire(texte, fichier=None):
    io.open(fichier or COMMUN, "w", encoding="utf-8").write(texte)


def _ligne(titre):
    print("  --- %s" % titre)


def main():
    echecs = []

    # 0. les ancres doivent etre uniques DANS LEUR FICHIER, sinon
    #    l'injection est un no-op et le cas "passe" sans avoir rien teste
    if not _controler_ancres():
        print("  les sources ont change depuis l'ecriture de ce script : "
              "les ancres ne sont plus uniques, ou plus presentes.")
        return 1

    # 1. la reference doit PASSER, sinon les contre-preuves ne veulent
    #    rien dire. Les DEUX verificateurs : un banc dont une moitié
    #    n'est pas verifiee reste un banc a moitie verifie.
    for quel in ("rendu", "remplissage"):
        _ligne("reference %s : doit passer" % quel)
        rc, out = _construire(quel=quel)
        if rc != 0:
            print("      !! la reference echoue deja :\n%s" % out)
            return 1
        print("      OK")

    total = len(CAS) + len(CAS_REMPL)
    try:
        for quel, cas in (("rendu", CAS), ("remplissage", CAS_REMPL)):
            f = CIBLE[quel]
            for titre, rustines, attendu in cas:
                _ligne("[%s] %s" % (quel, titre))
                texte = AVANT[f]
                for cherche, remplacement in rustines:
                    if cherche not in texte:
                        print("      !! %s ne contient plus %r."
                              "\n      La source a ete modifiee : ce script "
                              "doit etre relu, pas complete a l'aveugle."
                              % (os.path.basename(f), cherche))
                        return 1
                    texte = texte.replace(cherche, remplacement, 1)
                _ecrire(texte, f)
                rc, out = _construire(quel=quel)
                if rc == 0:
                    print("      !! le verificateur a ACCEPTE un binaire "
                          "faux")
                    echecs.append(titre)
                elif "Traceback" in out or "Error" in out:
                    print("      !! le verificateur s'est casse, il n'a pas "
                          "diagnostique :\n%s" % out)
                    echecs.append(titre)
                elif attendu not in out:
                    print("      !! echec sans le message attendu %r :\n%s"
                          % (attendu, out))
                    echecs.append(titre)
                else:
                    # Le diagnostic doit etre lisible SEUL. On affiche
                    # la tete (`!! ...`) et, si le fragment attendu
                    # n'y est pas, la ligne qui le porte : deux cas
                    # peuvent commencer pareil et diverger ensuite
                    # (valeurs $00 $57 contre $56, par exemple), et
                    # n'afficher que la tete les rendrait identiques
                    # a l'ecran alors qu'ils sont bien distincts.
                    lignes = [l.strip() for l in out.split("\n") if l.strip()]
                    tete = next((l for l in lignes
                                 if l.startswith("!!")), lignes[0] if lignes else "?")
                    if attendu not in tete:
                        portee = next((l for l in lignes if attendu in l), None)
                        if portee:
                            tete += "\n                " + portee
                    print("      detecte : %s" % tete[:200])
    finally:
        # Les DEUX sources sont restaurees, pas seulement common.inc :
        # splash_draw est dans splash.asm, et un cas interrompu y
        # laisserait un rendu bricole qui passerait peut-etre encore.
        for f, texte in AVANT.items():
            _ecrire(texte, f)
        _construire()          # on laisse le bon binaire sur le disque

    if echecs:
        print("\n  %d cas sur %d ne sont pas detectes : %s"
              % (len(echecs), total, ", ".join(echecs)))
        return 1
    print("\n  les %d bugs injectes sont tous rejetes, et les references "
          "passent." % total)

    _ligne("le build ne ressert pas l'etape precedente")
    if verifier_stade() != 0:
        return 1
    print("      OK")
    return 0


# ===================================================================
# CONTRE-PREUVE 2 : le BUILD ne doit pas resservir l'etape d'avant
# ===================================================================
# Bug reel du 28 sept 2026, constate sur la carte. `TEST` est un nom
# partage par les CINQ etapes et la regle etait `TEST: $(OBJ)`. En
# comparant les dates, `make STAGE=stage1_bandes` trouvait `TEST` (fabrique
# par l'etape 4) plus recent que `stage1_bandes.o` et ne reliait RIEN :
# on collait le .hex de l'etape 4 en croyant tester l'etape 1, et un
# ecran vide se lisait "l'etape 1 a echoue".
#
# Ce test aurait ete VERT au commit precedent : les quatre etapes
# donnaient des md5 differents quand on les construisait dans l'ordre
# depuis `clean`. Le defaut n'apparait QUE si l'on change d'etape sans
# nettoyer, ce qu'aucune boucle de verification ne faisait.
def verifier_stade():
    tailles = {}
    for etape in STAGES:
        _construire(etape)
        tailles[etape] = os.path.getsize("TEST.hex")

    distinctes = len(set(tailles.values()))
    if distinctes != len(STAGES):
        print("  !! %d etapes donnent des .hex identiques -- `TEST` est un "
              "nom partage et make ne relie pas" % len(STAGES))
        return 1

    # L'aller-retour SANS clean, qui est le cas qui echouait.
    for etape in STAGES + list(reversed(STAGES)):
        _construire(etape)
        if os.path.getsize("TEST.hex") != tailles[etape]:
            print("  !! apres `make STAGE=%s` sans clean, TEST.hex fait %d "
                  "octets au lieu de %d -- binaire perime"
                  % (etape, os.path.getsize("TEST.hex"), tailles[etape]))
            return 1

    # Et le build doit declarer quelle etape il a produite.
    out = _make_sortie(STAGES[0])
    if "ETAPE" not in out:
        print("  !! le build n'affiche pas ETAPE = ... : impossible de "
              "verifier qu'on colle le bon .hex")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
