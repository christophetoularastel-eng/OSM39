# ===================================================================
# Makefile - test/ : banc d'essai du splash, charge en RAM par le
# moniteur de la machine.
#
# Volontairement HORS du Makefile racine : ce n'est pas un livrable,
# c'est un outil de mise au point sur carte.
#
# `make STAGE=stage1_bandes`   -> builde test/TEST + test/TEST.hex
# `make -C test send STAGE=...` -> affiche le texte a coller, ETAPE en tete
#
# ATTENTION : `TEST` est un nom partage par les CINQ etapes. Changer
# de STAGE sans passer par `clean` peut laisser le binaire de l'etape
# precedente : c'est deja arrive, et ca se lit "l'ecran est vide" alors
# que l'etape 1 n'a jamais ete envoyee. Le tampon `.stage` y remedie,
# mais `ETAPE = ...` affiche par le build reste la verite a regarder.
#
# Sur la carte :
#       LOAD                puis attendre l'invite
#       <coller le contenu de TEST.hex sur la LIGNE SERIE>
#       RUN 0000
#
# -------------------------------------------------------------------
# LE CANAL : 128 OCTETS EN VOL, PAS 128 OCTETS AU TOTAL
#
# handler_NMI (bios/IT.asm:344-357) depose chaque caractere recu sur
# le port serie dans input_buffer, et beep+puis JETTE au-dela de
# input_buffer+127. load_cmd (bios/main.asm:837) relit ensuite le
# tampon caractere par caractere. Donc :
#   - la taille TOTALE du .hex n'a pas de limite ;
#   - mais si la serie deborde 128 octets devant la consommation,
#     vous entendez des bips et des caracteres sont perdus.
# Un bip = transfert corrompu, il faut reenvoyer plus lentement.
# Le prefixe "LOAD" que vous tapez au clavier est ignore exprès
# (load_cmd fait `CMPA #':' / BNE load_cmd`) : il saute jusqu'au
# premier deux-points.
#
# -------------------------------------------------------------------
# AUCUNE ADRESSE DE CODE DU BIOS ICI
#
# Le moniteur ne charge que TEST.hex, donc ce banc n'est pas lie au
# BIOS et ne peut pas utiliser `import`. Plutot que d'extraire des
# adresses de bios/osm39.map, ce banc n'appelle AUCUNE routine du
# BIOS (voir common.inc) : il n'utilise que $A120 (page video) et
# $8000-$9FFF (carte V4 : caracteres $8000-$8FFF, couleurs
# $9000-$9FFF), des adresses materielles. Il tourne donc sur
# n'importe quel build, y compris une EPROM anterieure a splash.asm.
# ===================================================================

AS = lwasm
LD = lwlink
OBJCOPY = objcopy

ASFLAGS = --format=obj --6309 -I../bios
LDFLAGS = --format=raw --section-base=.code=0x0000

# Une etape = un fichier source. Pas d'assemblage conditionnel :
# `if` de lwasm 4.24 n'accepte qu'un litteral, pas un equ, donc on ne
# pourrait pas ecrire `if SPL_TEST = 3`. Un fichier par etape evite la
# astuce ET evite qu'un binaire embarque 500 octets de table pour rien
# quand on veut juste verifier l'ecriture video.
STAGES = stage1_bandes stage2_rendu stage3_splash stage4_symptome stage5_fond stage6_mire stage7_bureau stage8_adresse stage9_mono
STAGE ?= stage3_splash

SRC = $(STAGE).asm
OBJ = $(STAGE).o
HDR = common.inc

# splash.asm = le CODE du rendu (splash_clear, splash_draw).
# splash_ecran.inc = la table de REFERENCE (splash_data).
#
# La separation n'est pas cosmetique : les etapes 2 et 5 ont leur propre
# table, donc elles n'incluent pas splash_ecran.inc. Sinon elles
# embarqueraient 480 octets qu'elles n'affichent jamais -- spends sur la
# ligne serie, ou chaque octet est une occasion de corrompre le transfert.
ifneq ($(filter $(STAGE),stage2_rendu stage3_splash stage4_symptome stage5_fond),)
HDR += splash.asm
endif
ifneq ($(filter $(STAGE),stage3_splash stage4_symptome),)
HDR += splash_ecran.inc
endif

# Chaque etape nomme la table que splash_draw doit rendre, et ce nom
# est passe a verifie_rendu.py en argument. Ce n'est pas une commodite :
# splash.asm porte le splash DE REFERENCE sous le nom `splash_data`,
# donc une etape qui a sa propre table ne peut pas s'appeler comme lui
# (collision a l'assemblage). Le nom de la table est une donnee de
# l'etape, pas une convention codee en dur dans le verificateur.
TABLE_stage1_bandes =
TABLE_stage2_rendu  = table_rendu
TABLE_stage3_splash = splash_data
TABLE_stage4_symptome = splash_data
TABLE_stage5_fond   = table_fond
TABLE_stage6_mire   =
TABLE_stage7_bureau =
TABLE_stage8_adresse =
TABLE_stage9_mono =
TABLE = $(TABLE_$(STAGE))

# Les etapes qui rendent le splash passent par splash_draw. Avant
# d'envoyer plusieurs centaines d'octets sur la ligne serie, on
# verifie hors carte que le rendu est juste : verifie_rendu.py relit la
# table DANS le binaire emis, rejoue splash_draw instruction par
# instruction, et confronte chaque caractere a une formule ecrite
# separement. Un banc ne doit pas partir sur la carte avec un rendu
# faux -- et surtout pas avec le bug qu'il est cense tester. C'est ce
# controle qui a attrape le defaut de multiplication de splash_draw le
# 28 septembre 2026, avant le moindre octet envoye.
#
# verifie_remplissage.py couvre l'AUTRE moitie du banc : les routines
# qui ecrivent une fenetre entiere (splash_bandes, splash_clear,
# ecran_noir) et celle qui temporise (attente). Elles n'etaient
# verifiees par RIEN, et splash_bandes -- la seule a fermer sa boucle
# sur un `bne` -- portait le defaut qui a fige la carte le 28 septembre
# 2026. Un banc dont une etape n'est pas verifiee n'est pas un banc.
# Il tourne donc sur les CINQ etapes, y compris l'etape 1 qui ne rend
# aucun texte.
#
# Ce bloc doit precede `all` : make etend les dependances de `all` au
# moment ou il lit la ligne, donc un `$(VERIF)` defini plus bas
# vaudrait vide.
ifneq ($(filter $(STAGE),stage2_rendu stage3_splash stage4_symptome stage5_fond),)
VERIF = verifier
endif
# L'etape 9 (carte OSM39_mono, VRAM entrelacee) n'a pas les routines de
# la V4 que verifie_remplissage.py connait : elle a son propre
# verificateur, qui rejoue le binaire et compare les 4096 cases.
ifeq ($(STAGE),stage9_mono)
VERIF += banc_mono constantes
else
VERIF += remplissage constantes
endif

all: TEST.hex $(VERIF)

verifier: TEST.hex
	@python3 verifie_rendu.py $(STAGE).lst $(TABLE)

# L'etape 1 n'a pas de table de splash : elle n'a donc rien a passer a
# verifie_rendu.py. Elle n'est pas pour autant dispensee de controle --
# c'est justement l'etape qui a fige la carte.
remplissage: TEST.hex
	@python3 verifie_remplissage.py $(STAGE).lst

banc_mono: TEST.hex
	@python3 verifie_banc_mono.py

# Ni dependant de l'etape, ni de TEST : un controle REPO. lwasm 4.24
# tronque silencieusement toute expression dont un operande est entoure
# d'espaces, et refuse `<<`. Une constante peut donc valoir le premier
# mot de sa definition au lieu de l'expression -- et les deux
# verificateurs ci-dessus ne le peuvent PAS voir : ils confrontent le
# code a la table, donc ils valideraient une table dont les attributs sont
# faux. C'est exactement ce qui est arrive a la palette des fonds le
# 30 septembre 2026 : huit bandes qui ne changeaient que le premier
# plan. Ce controle a ete ecrit apres, contre la forme fautive.
constantes:
	@python3 verifie_constantes.py
	@python3 verifie_constantes.py --contre-preuve

# Meme raison pour `--contre-preuve` : verifie_constantes.py doit
# ECHOUER sur des lignes fausses connues, sinon « 42 fichiers relus, 0
# probleme » ne prouve rien. Le mode injecte six lignes fautives (dont
# le bug REEL de palette du 30 sept. 2026 et le `rmb 16 * 15` du
# 2 oct. 2026) et exige de chacune un message distinct, plus une
# contre-preuve INVERSE sur une ligne correcte, sans laquelle on ne
# saurait pas si le motif signale des choses ou tout.
#
# C'est ce mode-la qui a trouve le second trou du linter : `NOM fcb ...`
# avec libelle n'etait pas reconnu.

# La contre-preuve : verifie_rendu.py doit ECHOUER sur six bugs
# injectes dans splash_draw. Un verificateur qui reussit toujours ne
# prouve rien, donc on le met lui-meme a l'epreuve avant de croire
# une reussite. A lancer apres toute modification de splash_draw.
negatifs:
	@$(MAKE) -s STAGE=$(ETAPE_NEG) TEST.hex
	@python3 verifie_negatifs.py

ETAPE_NEG = stage3_splash

# -------------------------------------------------------------------
# `TEST` EST UN NOM PARTAGE : NE JAMAIS LUIRE "a jour" A TORT
# -------------------------------------------------------------------
# Bug reel du 28 sept 2026, constate sur la carte. La regle est
# `TEST: $(OBJ)` et `$(OBJ)` vaut `$(STAGE).o`, donc demander
#
#     make STAGE=stage4_symptome     ->  TEST = 810 octets
#     make STAGE=stage1_bandes      ->  ...RIEN, et TEST reste a 810
#
# make compare les dates : `stage1_bandes.o` (ancien) n'est pas plus
# recent que `TEST` (fabrique par l'etape 4), donc il considere TEST a
# jour et ne relie pas. Le resultat : on colle le .hex de l'etape 4 en
# croyant tester l'etape 1, et on lit l'ecran vide comme un echec de
# l'etape 1 alors que l'etape 1 n'a jamais ete envoyee.
#
# Le tampon `.stage` ci-dessous rompt le cycle : il ne touche son
# mtime QUE si le nom de l'etape change, donc un changement d'etape
# invalide TEST, et deux `make` de la meme etape ne relient rien.
TEST: $(OBJ) .stage
	$(LD) $(LDFLAGS) -o $@ $<

FORCE:

.stage: FORCE
	@if [ "$$(cat $@ 2>/dev/null)" != "$(STAGE)" ]; then \
	  echo "$(STAGE)" > $@; \
	fi

# Le nom de l'etape est affiche AVEC la taille, au moment ou l'on
# s'apprrete a coller : c'est la seule occasion de verifier qu'on
# envoie bien l'etape voulue. Ne pas le retirer.
TEST.hex: TEST
	$(OBJCOPY) -I binary -O ihex TEST TEST.hex
	@echo "  ETAPE     = $(STAGE)"
	@echo "  TEST.bin  = $$(stat -c%s TEST) octets a charger"
	@echo "  TEST.hex  = $$(stat -c%s TEST.hex) caracteres a envoyer"

$(OBJ): $(SRC) $(HDR) ../bios/hardware.inc
	$(AS) $(ASFLAGS) --list=$(STAGE).lst -o $@ $<
	@# GARDE-FOU : `start` DOIT etre a l'offset 0000. Le moniteur fait
	@# `JSR $0000`. Si un `include` se glisse avant `start` dans le source,
	@# la routine incluse se retrouve a 0000, le banc demarre au milieu
	@# d'une routine et `RUN 0000` n'execute pas le test. Ca donne
	@# exactement le symptome "rien ne se passe", sans aucune trace a
	@# l'ecran ni au moniteur -- c'est deja arrive une fois (28 sept 2026).
	@# On le fait echouer ici plutot que sur la carte.
	@# `[[:xdigit:]]` et NON `[0-9a-f]` : cette derniere classe ne
	@# contient PAS les majuscules, et un offset comme 00EF passait
	@# sous le test avec une sortie vide.
	@off=$$(grep -oE '^[[:xdigit:]]{4} .*start:' $(STAGE).lst | head -1 \
	       | grep -oE '^[[:xdigit:]]{4}'); \
	 if [ "$$off" != "0000" ]; then \
	   echo "ERREUR : start est a l'offset '$$off', pas 0000." >&2; \
	   echo "         Deplace les \`include\` APRES \`start:\`." >&2; \
	   exit 1; \
	 else \
	   echo "  start : offset 0000, OK"; \
	 fi

# Affiche le contenu a envoyer, sans numero de ligne, pret a coller.
send: TEST.hex
	@tr -d '\r' < TEST.hex

# PAROLE (apps/parole.asm) : le VRAI binaire rejoué dans asm/emu6809.py
# (+ les instructions 6309 qu'il utilise, 6840 simulé) et comparé au modèle
# tools/parole/parole.py : table sinus, textes, trames, échantillons.
# Hors carte ; indépendant de STAGE.
parole:
	@$(MAKE) -s -C ../apps PAROLE
	@python3 verifie_parole.py


# Terminal : la console du BIOS dans une zone (sys_Console_Zone, Zone_IRQ),
# texte écrit par le vrai PrintChar et rendu par la vraie IRQ VSYNC.
terminal:
	@$(MAKE) -s -C ../bios
	@python3 verifie_terminal.py

# MINITEL (apps/minitel.asm) : le décodeur Vidéotex du VRAI binaire = le
# modèle tools/minitel/videotex.py (capture MiniPavi, page d'essai, flux
# aléatoires) ; puis l'application entière, modem et clavier simulés.
minitel:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../apps MINITEL
	@python3 verifie_minitel.py

# ZMACHINE (zmachine/) : le VRAI binaire sur le VRAI BIOS, jeux sur une
# carte émulée ; écran = le modèle tools/zmachine/zmachine.py à chaque
# saisie ; sauvegarde Quetzal = celle du modèle. Jeux : ~/Documents/zmachine.
zmachine:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../zmachine
	@python3 verifie_zmachine.py

zmachine-tout:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../zmachine
	@python3 verifie_zmachine.py tout

# DONJON39 (apps/donjon39.asm) : le VRAI binaire, trames et clavier PS/2
# simulés ; à l'arrêt, la vue en VRAM = le modèle tools/donjon39/donjon39.py ;
# écritures VRAM au début des trames ; murs infranchissables ; Echap.
donjon39:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../apps DONJON39
	@python3 verifie_donjon39.py

# OSM City (apps/osmcity.asm) : le VRAI binaire, trames et flèches PS/2
# simulées ; à chaque pas l'état = le modèle tools/osmcity/osmcity.py,
# l'écran lu à travers le départ du 6845 = le modèle ; VRAM juste après le
# signal de trame ; Echap rend le départ et les rangées 25-29.
osmcity:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../apps OSMCITY
	@python3 verifie_osmcity.py

# OSM3D (apps/osm3d.asm) : le VRAI binaire, trames et flèches PS/2
# simulées ; à l'arrêt, les 30 rangées de l'écran = ecran() du modèle
# tools/osm3d/osm3d.py ; toute la VRAM dans l'IRQ (file de copies) ;
# Echap rend les rangées 25-29.
osm3d:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../apps OSM3D
	@python3 verifie_osm3d.py

# OSMFS (bios/osmfs.asm) : le VRAI BIOS rejoué dans asm/emu6809.py, 4 pages
# de 32 Ko derrière $A0C0, carte SD = image créée par tools/egofs.
# FS_LoadFile / FS_SaveFile à cheval sur deux pages, refus au-delà de la
# page 3, pas de recouvrement de fichiers. Hors carte.
fs:
	@$(MAKE) -s -C ../bios
	@python3 verifie_fs.py

# Passerelle entre pages (bios/farcall.asm) : le vrai BIOS, fonctions de
# test en code machine dans les pages 2 et 3. Hors carte.
farcall:
	@$(MAKE) -s -C ../bios
	@python3 verifie_farcall.py

clean:
	rm -f *.o *.lst *.map TEST TEST.hex .stage
	rm -rf tout

# Le contrat des services du BIOS (test/contrat_services.py) : chaque
# emplacement de la table appelé sur le vrai BIOS, registres témoins ;
# docs/services.md doit être celui que donne la table (--doc).
contrat:
	@$(MAKE) -s -C ../bios
	@python3 verifie_contrat.py

# Tous les vérificateurs d'une commande (test/tout.py) : constructions une
# fois, puis vérifications en parallèle, bilan, journaux dans test/tout/.
# `tout-long` : zmachine-tout et asm-tout. Sur la carte de CARTE seulement.
tout:
	@python3 tout.py

tout-long:
	@python3 tout.py --long

# Assembleur natif (asm/ASM) : le vrai ASM sur le vrai BIOS, sources et
# INCLUDE sur une carte OSMFS ; chaque binaire identique à lwasm (GLOUTON,
# MIRE, tests 6309...). `make asm-tout` : toutes les applications et BRIQUES.
# Démarrage automatique, SECOURS, TRAP et MONITEUR : le vrai BIOS depuis son
# vecteur de reset, le matériel non émulé court-circuité.
demarrage:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@$(MAKE) -s -C ../osmvision
	@python3 verifie_demarrage.py

# Gestionnaire de fichiers d'OSM-VISION (copier/couper/coller, nouveau dossier,
# renommer), au clavier simulé, sur le vrai BIOS.
bureau:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../osmvision
	@python3 verifie_bureau.py

# Dossiers de l'OSMFS : BIOS, commandes CD/MKDIR/PWD/RM, liste d'OSM-VISION.
dossiers:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@$(MAKE) -s -C ../osmvision
	@python3 verifie_dossiers.py

# cmd/SDTEST face à une carte SD simulée sur le SPI matériel de la carte
# SD-KBD-SON ($A140/$A148) : protocole, et espacement des accès (borne basse
# en accès au bus : 150 en lent, 9 en rapide).
sdtest:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@python3 verifie_sdtest.py

# Le mode graphique (bios/graphe.asm) = le modèle tools/graphe/graphe.py.
graphe:
	@$(MAKE) -s -C ../bios
	@python3 verifie_graphe.py

# Verr. Maj et voyants du clavier : le vrai BIOS, 6850 du clavier simulé.
clavier:
	@$(MAKE) -s -C ../bios
	@python3 verifie_clavier.py

# AY-3-8910 de la carte SD-KBD-SON : le vrai cmd/AYTEST face à un AY simulé.
aytest:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@python3 verifie_aytest.py

# Horloge MC146818 sur le PIA : le vrai cmd/HORLOGE face à un PIA et une puce simulés.
horloge:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@python3 verifie_horloge.py

# Lecteur de morceaux : le vrai cmd/AYJOUE (lib/ay_joue.asm), IRQ à chaque
# trame, face au modèle de tools/ay/ay.py.
ayjoue:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@python3 verifie_ayjoue.py

# Télécommande : le vrai cmd/TELE piloté par tools/tele/tele.py, liaison
# série simulée (anneau de la NMI, TDR).
tele:
	@$(MAKE) -s -C ../bios
	@$(MAKE) -s -C ../cmd
	@python3 verifie_tele.py

asm:
	@$(MAKE) -s -C ../bios
	@python3 verifie_asm.py

asm-tout:
	@$(MAKE) -s -C ../bios
	@python3 verifie_asm.py tout

.PHONY: all clean tout tout-long contrat send verifier remplissage banc_mono negatifs parole minitel terminal donjon39 osmcity osm3d zmachine zmachine-tout fs farcall asm asm-tout dossiers demarrage bureau sdtest tele aytest ayjoue clavier horloge graphe FORCE
