# Historique — corrections et fossiles

Ce que `AGENTS.md` ne dit plus parce que ce n'est plus vrai.

## 10 oct. 2026 — table des services de taille fixe

- `table_function_ram` passe de 35 services (70 octets) à 37 services plus
  11 emplacements réservés : **96 octets fixes**. Nouveaux : `sys_Far_Call`,
  `sys_Far_CallN`. Toute la RAM système derrière la table s'est décalée de
  +26 octets (`SCAN_CODE` $C046 → $C060, `sd_err` $C85F → $C879, `sd_retry`
  $C860 → $C87A, `char_attribut` $C6B6 → $C6D0). C'est la dernière
  rupture de ce genre : les services futurs prennent un emplacement réservé.
  Tout programme assemblé avant cette date doit être réassemblé.
- `AGENTS.md` disait que la passerelle FarCall n'était pas un `sys_*`
  « parce que agrandir la table décale la RAM » : c'est maintenant les deux
  (table fixe en $FFE0 et emplacements `sys_`).
- `bios/ram.asm` disait que basic69 codait `char_attribut` en dur à $C652 :
  faux depuis que basic69 prend l'adresse dans `hardware.inc`.
- `docs/memory-map.md` §5.1 décrivait une table de 32 vecteurs (64 octets),
  `BITCOUNT`/`PS2_BYTE` et un BSS finissant en $C7D3 : remplacé par le relevé
  de `bios/osm39.map`.

## 10 oct. 2026 — ASM refait : assembler GLOUTON sur la machine

- L'ancien ASM chargeait le source en entier (8 Ko au plus), 64 symboles de
  15 caractères, ni INCLUDE ni 6309 ; GLOUTON (88 Ko avec ses INCLUDE, 672
  symboles) le faisait planter. Il lit maintenant les fichiers secteur par
  secteur grâce à trois services pris dans la réserve (`sys_FS_FileInfo`,
  `sys_FS_ReadSector`, `sys_FS_SetLoad` : la RAM système n'a pas bougé).
- Bogues de l'ancien ASM trouvés par `test/verifie_asm.py` (jamais vus parce
  que rien ne faisait tourner ASM en entier) : toute branche courte refusée
  en passe 2 (`lda pass_no` écrasait l'octet haut de la distance) ; LBRA et
  LBSR codés `$1600`/`$1700` (émis `16 00 xx xx`) ; LEAS et LEAU inversés ;
  une liste PSHS/PULS s'arrêtait au premier registre ; `*` multipliait par
  le pointeur de texte et `/` perdait le reste ; une parenthèse rendait A =
  `)` ; un nombre dont le dernier chiffre fait une retenue était « trop
  grand » ; `ParseReg` ne mettait pas C = 1 sur un nom inconnu.
- La règle « tout symbole force la forme longue » de l'ancien ASM visait
  `lwasm --format=raw` ; la cible est désormais le mode objet de lwasm
  (celui des Makefiles), dont les règles mesurées sont dans `AGENTS.md`.
- `AGENTS.md` disait lwtools 4.17 : `lwasm --version` donne 4.24.
- `AGENTS.md` disait que `LEAX D,X` s'assemblait en indexé indirect 8 bits :
  lwasm 4.24 donne `30 8B` (D,X direct), `LEAU D,U` `33 CB`, `LEAX [D,X]`
  `30 9B`. Piège retiré ; s'il revient, le prouver par un `.lst`.
- `asm/Makefile` ne dépendait pas de `opcodes.inc` ni de `bioslib.asm` : une
  table modifiée n'était pas réassemblée. Corrigé.

## 10 oct. 2026 — dossiers dans l'OSMFS

- Champ parent en +28 de chaque entrée, attribut d (bit 5) : une seule table,
  compatible avec les cartes d'avant (0 partout = racine). Services
  `sys_FS_ChDir`, `sys_FS_MkDir`, `sys_FS_Dossier`, `sys_FS_DirInfo` (réserve :
  4 emplacements libres restent). `Format_Filename_83` passe de
  `filename.asm` à `osmfs.asm` et résout les chemins.
- `FS_FileInfo` rend 14 octets (le parent en plus) au lieu de 12 : seul ASM
  s'en servait.
- `bios/splash.asm` n'est plus lié dans l'EPROM (611 octets, appel commenté
  depuis toujours) : la place a servi aux dossiers.
- `bios/Makefile` laissait passer un code qui dépassait `$FFFF` (lwlink le
  place en `$10000...` sans rien dire, l'image perdait la fin). Il échoue
  maintenant au-delà de `$FFDF` et affiche la place libre.
- `cmd/Makefile clean` oubliait `RM` (signalé dans `AGENTS.md`) : corrigé.
  `RM` affichait « Fichier efface. » même en cas d'échec : corrigé.
- En-tête de `osmfs.asm` : « données en LBA 2, répertoire d'un secteur »,
  périmé depuis longtemps (257 et 256) : corrigé.
- Bogue trouvé sur la carte le jour même : dans `Fs_Scan`, la comparaison du
  dossier (`ldd DE_OFF_PARENT,x`) écrasait B, le compteur d'entrées du
  secteur. Dès qu'un fichier de même nom existait dans un autre dossier plus
  haut dans la table (GLOUTON à la racine, puis APPS/GLOUTON), la recherche
  partait au-delà du tampon et ratait l'entrée : `ASM glouton.asm glouton
  4000` dans APPS échouait à moitié (fichier créé, pas sa page) et `RM
  GLOUTON` ne le trouvait plus. `verifie_dossiers.py` le reproduit maintenant
  (même nom, un secteur plus loin) ; il ne le voyait pas, les noms y étaient
  tous différents.

## 11 oct. 2026 — le moniteur quitte l'EPROM (démarrage comme un PC)

- Le moniteur (MEM, REG, RUN, LOAD, LS, FLOAD, BOOT, QUIT) et le long
  rapport du TRAP occupaient environ 2 Ko d'EPROM. Restent : le démarrage
  automatique, le SECOURS (LOAD, RUN, BOOT) et un TRAP d'une ligne. Place
  libre : 29 -> 1065 octets. `bios/fload.asm` est supprimé (FLOAD).
- Ce qui disait que `BOOT` était une commande du moniteur, que le banc se
  lançait par `LOAD` dès le prompt, et que les diagnostics SD se lisaient par
  `MEM C879` : périmé (SECOURS, puis `MONITEUR` : `M C879`).
- `sys_reg_cmd`, `sys_ls`, `sys_PrintFileName83` : services retirés, mais
  emplacements gardés (C=1). Le `LS` intégré du shell appelait `sys_ls` :
  retiré, c'est `cmd/LS`.
- Le TRAP figeait la machine après son rapport ; Ctrl+A affichait les
  registres et relançait `main`. Maintenant : retour à OSM-VISION par un
  redémarrage à chaud (`Redemarrage`) qui garde le rapport pour `MONITEUR R`,
  et Ctrl+A mène au SECOURS.
- Messages morts retirés de `main.asm` (`FILE_FOUND`, `MsgFileLoaded`...) et
  de `IT.asm` (`MsgNMI`).
- Sur la carte, le jour même : sans carte SD, le démarrage restait figé
  dans `Init_SD_Card` (attentes de CMD0, CMD8 et ACMD41 sans fin). Elles sont
  bornées, l'écho `$AA` de CMD8 est vérifié, et `Init_SD_Card` rend C=1 :
  message, SECOURS ; `BOOT` y réessaie. `verifie_demarrage.py` le rejoue avec
  le vrai `Init_SD_Card` et MISO figé à `$FF` puis `$00`.

## 11 oct. 2026 — OSM-VISION, gestionnaire de fichiers

- Menu Espace : Copier, Couper, Coller, Nouveau dossier (et Ctrl+C/X/V/N).
  « Editer (VI) » devient « Editer » : c'est EDIT qui se lance depuis
  longtemps.
- Défaut hérité des dossiers : Renommer testait l'existence du nouveau nom
  par `FS_FindEntry`, qui retombe sur la racine. Un nom présent seulement à
  la racine (EDIT...) était refusé dans un dossier. Corrigé (`FS_FileInfo`).
- La machine de test (`verifie_fs.py`) connaît maintenant le jeu 6309 que
  les programmes de la carte emploient (inhérents D/W/E/F, mémoire sur W, E,
  F, registre à registre, PSHUW/PULUW, MULD, toutes les formes de TFM).
- Les programmes passent dans `/BIN` : le repli des lectures cherche dans le
  dossier courant, puis `/BIN`, puis la racine. `egofs_deploy.py` enlève les
  anciennes copies de la racine ; la racine ne garde que les dossiers,
  OSMVISION et les données. ASM : `ASM GLOUTON.ASM /BIN/GLOUTON 4000` (avec
  `/GLOUTON`, l'ancien chemin, OSM-VISION lancerait toujours celui de `/BIN`).
- CALC prend la feuille en argument ; OSM-VISION associe `.CAL` à CALC.

## 11 oct. 2026 — les applications quittent la page 0

- Une application d'OSM-VISION était liée à `$4000` en page 0 et appelait
  les services d'OSM-VISION par une table à adresse fixe (`$0003`) : elle
  avait 16 Ko, et OSM-VISION ne pouvait pas dépasser `$3FFF` (il ne lui
  restait que 400 octets). Désormais chaque application tourne dans sa page
  (page 1, `$0000`), appelée par FAR_CALL, et emporte sa copie des services
  (`lib/vision.asm`, sortie d'`osmvision.asm`, source unique). Plus d'en-tête
  `$0002`/`$0003` ni de contrôle `VIS_REQUIS` effectif ; `deploy_sd.sh` ne
  compare plus le nombre de services.
- « Son coupé » passe dans la RAM du BIOS (`son_coupe`) : chaque copie des
  services le lit.
- ASM : une origine `$4000` ne veut plus dire « application » ; c'est un
  source qui inclut `VISION.ASM` qui reçoit l'attribut `a`. `VIS_TABLE` et
  `VIS_COUNT_ADR` sont des étiquettes (un `EQU` vers une étiquette plus loin
  coûtait une passe 3 à l'ASM de la carte).
- `docs/memory-map.md` donnait `current_page` en `$C4A3` : c'est `$C4C1`.
- PAROLE écrivait ses trames dans `FrBuf equ *`, au-delà de la fin de son
  binaire : `lib/vision.asm`, d'abord ajouté en fin de fichier, se serait
  fait écraser (table des services comprise) dès la première phrase.
  L'include est placé avant `FrBuf` ; `verifie_parole.py` l'a vu (il charge
  maintenant PAROLE à l'adresse de sa map et bouche SA table de services).

## 15 oct. 2026 — MINITEL, et la liaison série en mode brut

- BIOS : mode brut de la liaison série (`serie_brute`, anneau `serie_buf`
  de 256 octets en fin de BSS ; le tas et la zone libre reculent de 259
  octets). Un programme ne peut pas prendre la NMI lui-même : elle sert
  aussi le clavier, et le BIOS change de page pendant les transferts SD.
  Le premier jet rangeait l'octet par `STA B,X` : B est SIGNÉ, la moitié
  haute de l'anneau tombait 256 octets trop bas ; `verifie_demarrage.py`
  l'a vu (anneau parcouru depuis `$FE`), corrigé par `ABX`. EPROM : 869
  octets libres.
- `apps/minitel.asm`, `tools/minitel/` (modem Hayes simulé sur le PC,
  modèle Vidéotex `videotex.py`, capture réelle de MiniPavi). Choix : une
  colonne Minitel = deux cellules (80 x 25, proportions d'un Minitel) ;
  14 glyphes suffisent au lieu de 63. En G1, `$40-$5F` sont des mosaïques
  (le logo de MiniPavi le montre ; les rendre en lettres était faux).
- Police : page 1 `$50-$5D` écrite par `videotex.py --police` : l'EPROM de
  caractères est à reprogrammer.
- MINITEL passe l'ACIA à E/64 = 28800 bauds (idée de l'utilisateur) : 347 µs
  par octet pour la NMI au lieu de 87 ; la console garde 115200. `modem.py`
  règle cette vitesse non standard par termios2 (vérifié sur le CH340).
- Sur la carte : plus de démarrage automatique, SECOURS sans message
  (`BOOT` y marchait). Cause : `modem.py` tournait sur le PC ; il renvoyait
  en écho la bannière que la console écrit sur la liaison série (et
  « ERROR » aux lignes sans AT) : un caractère reçu dans la fenêtre d'une
  seconde ouvre le SECOURS. Le modem est muet par défaut (pas d'écho,
  lignes sans AT ignorées). Une première hypothèse (carte SD pas prête à la
  mise sous tension) a laissé au démarrage jusqu'à 4 essais
  d'`Init_SD_Card` à ~160 ms d'écart : inoffensif, gardé.
- Sur la carte, MINITEL affiche MiniPavi. Ensuite :
  - la console n'écrit plus sur la liaison série (`PrintChar` : l'écran
    seul) ; au SECOURS, le terminal du PC ne voit plus rien, `LOAD` lit
    toujours l'hex collé ;
  - le raccrochage ne marchait pas : MINITEL envoyait `ATH` 1,1 s après
    `+++` et le modem, qui ne regardait la seconde de garde que tous les
    0,1 s, envoyait parfois `+++ATH` au serveur. Le modem bascule désormais
    dès qu'un octet suit `+++` d'une seconde ; la garde de MINITEL passe à
    1,5 s ;
  - `modem.py --capture` enregistre le flux des serveurs (sur la carte,
    « Créez » montrait « Cré » puis deux blancs, à la bonne place : à
    rejouer dans le modèle).
- Clavier peu réactif dans MINITEL. Les deux ACIA partagent la NMI, sur
  front : `handler_NMI` servait un octet série puis `RTI` ; un octet
  clavier arrivé en même temps gardait la ligne basse sans nouveau front,
  et attendait que l'IRQ VSYNC coupe puis rende les IT du clavier (une
  trame). Sous le flux de MINITEL, `F0` et le code s'écrasaient. La NMI
  sert maintenant les deux ACIA en boucle jusqu'à ce qu'aucune n'ait
  d'octet (`verifie_demarrage.py` : les deux ensemble, une NMI). MINITEL
  regarde aussi le clavier après chaque octet décodé.
- Raccrochage, suite : le modem voyait `+++` mais jamais `ATH`.
  `Cmd_ATH fcn "ATH"` suivi de `fcb $0D,0` : FCN met son 0 AVANT le CR,
  `Envoie_Chaine` s'arrêtait là. Le serveur restait en ligne ; après la
  sortie de MINITEL, ses octets remplissaient le tampon de ligne du BIOS,
  qui affiche un BEL (un point vert) par octet en trop. Le test ne l'avait
  pas vu : le CR de l'appel suivant terminait la ligne. Il exige
  maintenant le CR dans la même trame que `ATH`.
- MINITEL : fenêtre 40 x 25 dans OSM-VISION par défaut (demande de
  l'utilisateur : les espaces du 80 colonnes gênaient), plein écran 80 x 25
  par Ctrl+F. Le décodeur remplit désormais un écran LOGIQUE (code, genre,
  attribut par case) ; deux rendus en sont tirés. 56 glyphes 2 x 3 de plus
  en page 1 (les 7 dont les deux colonnes sont pareilles réutilisent ceux
  du plein écran) : page 1 `$07-$1B` et `$4F-$7F` prises ; le disjoint est
  dessiné contigu en fenêtre. EPROM de caractères à reprogrammer.
- Clavier qui doublait les lettres en MINITEL : le journal de `modem.py`
  (`carte -> ...`) montrait en double les caractères tapés avec Maj, en
  simple les touches étendues. `scan_keyboard` rend le caractère au
  relâchement à partir de `last_makecode` : un second relâchement sans
  nouvel appui (l'octet qui suit le F0 de Maj mal lu, ou un F0 en double)
  rendait encore la lettre. Désormais un relâchement ne rend un caractère
  que s'il porte le code du dernier appui, une seule fois (bit
  `appui_attente` de `key_on`). `verifie_demarrage.py` rejoue ces suites ;
  l'ancien BIOS y donne « FF ». La cause matérielle (timing de l'impulsion
  RTS après F0 sous le flux série) n'est pas prouvée.
- Clavier, suite : même sans Maj, en MINITEL les touches sortaient avec un
  temps de retard (r donnait le f précédent). MINITEL ne lisait le clavier
  qu'entre deux trames, et le BIOS ne gardait qu'UN octet PS/2 : le code
  d'appui était écrasé par F0. EDIT, toujours en attente dans
  `scan_keyboard`, ne le voyait pas. Désormais la NMI remplit aussi une
  file de 16 octets, et le service non bloquant `sys_kbd_poll` (une place
  de la réserve : il en reste 3) la traite ; `scan_keyboard` boucle dessus.
  `$FA` (acquittement) n'est plus rendu comme une touche.
- Carte SD-KBD-SON (schéma KiCad de l'utilisateur) : relue sur la netlist
  (LM386 alimenté à l'envers, AY : bus retourné, BC1 non validé, BDIR à
  l'envers, sans charges ; 4040 remis à zéro à l'envers ; DS du 165 ;
  HC595 sur MISO 3,3 V -> HCT595), corrigée par l'utilisateur. Puis
  `tools/carte_sd_kbd_son/simule.py` (simulation logique d'après la
  netlist) : impulsion de 12 ns sur SCLK au début de chaque accès (course
  BUSY / validation du 157), impulsion de 2 ns en vitesse lente (E/16
  change en même temps que la fin d'un accès), verrou $A140 qui mémorise
  7 ns avant la fin des données (tDHW 30 ns supposé). Correctifs proposés
  et validés en simulation : SCLK = Za . /Q3 (sans la bascule BUSY), U103
  compté sur la montée de E, 74AC138 et 74AC32.
- Le schéma corrigé (SCLK = Za . /Q3, U103 sur la montée de E, 74AC138,
  74AC32, 74HCT595) passe `simule.py` sans correctif ; le simulateur lit
  la famille sur la valeur (AC/ACT plus rapides que HC/HCT). PCB : 0
  violation, 0 pastille non connectée.
- Terminal dans OSM-VISION (touche T) : le SHELL passe de $0000 (page 0,
  à la place d'OSM-VISION, inaccessible depuis le démarrage automatique)
  à $6000, à côté d'OSM-VISION ; la page 2, d'abord envisagée, sert déjà à
  ASM, EDIT et Coller. BIOS : zone console (`sys_Console_Zone`, une place
  de la réserve : il en reste 2), défilement de la zone par recopie dans
  l'IRQ. EPROM : 252 octets libres après cela.
- Sur la carte, le SHELL s'ouvrait en plein écran : lancé comme un programme
  (Entrée sur /BIN/SHELL, Exécuter), il passait par `Run_Command`. Ce chemin
  ouvre maintenant le Terminal aussi (`Terminal_Run`, sous-programme commun
  avec la touche T). OSM-VISION dépasse $4000 ($4006) : sans conséquence,
  le SHELL est à $6000.

## 16 oct. 2026 — programmes console en fenêtre, rangement de la carte

- Tout programme console lancé par OSM-VISION (Entrée, Exécuter) tourne
  dans la fenêtre du Terminal, titrée à son nom ; VI seul reste en plein
  écran (il écrit la VRAM lui-même). FORTH et BASIC ne passent que par la
  console. Un programme introuvable : boîte de message.
- Émulateur : PSHU/PULU écrivaient la mémoire « plate » sous $8000 au lieu
  de la page courante ; le FORTH (pile de données en page 1) y donnait
  2 3 + . = 2. Les piles passent par rd8/wr8.
- Carte rangée : BIN (système, plus EDIT et CALC, lancés par leur nom),
  APPS, GAMES, SRC (sources), LIB, BIOS, BUDGET (vide). egofs_deploy efface
  les copies d'un fichier déplacé, seulement dans les dossiers qu'il gère.
- Curseur : OSM-VISION le cachait (R10 = $2D) et rien ne le rallumait :
  plus de curseur dans le SHELL, le FORTH, les programmes plein écran.
  Il est visible ($6D, clignotement au 1/32, lib/ui.inc) pendant un
  programme console. MINITEL gère CON/COFF (modèle et décodeur) et place
  le curseur matériel sur la case du Minitel (VRAM_PTR, que l'IRQ du BIOS
  recopie dans R14/R15).
- VI retiré (EDIT le remplace) : vi/ supprimé, plus dans le manifeste ; la
  liste SUPPRIMER de deploy_sd.sh (dist/supprimer.txt) fait effacer
  BIN/VI de la carte par egofs_deploy. OSM-VISION : PleinEcran vide.
- Bancs de test : les crochets (PrintChar, scan_keyboard...) relisaient
  l'adresse de retour dans la mémoire plate ; avec une pile sous $8000
  (le BASIC a la sienne en page 1) ils repartaient en $0000. Ils passent
  par rd8, comme PSHSW/PULSW et les trames d'interruption.
- BASIC (Microsoft 6809 Extended BASIC 1982) essayé dans la fenêtre :
  calcul, lignes, LIST, SAVE/LOAD sur l'OSMFS marchent. Pas de commande
  pour en sortir ; il lit le clavier pendant l'exécution (les touches
  tapées d'avance sont mangées).

## 16 oct. 2026 — BBC BASIC

- BBC BASIC IV 6809/6309 (Dominic Beesley, beeb6809 branche sbc09) porté :
  la version « petite carte » (SBC09) désactive LOAD/SAVE et les fichiers ;
  on prend les chemins BBC complets avec un mode OSM39 (entrée, couche
  système osm39_mos.asm à la place des adresses $FFxx de la BBC, prises par
  le BIOS ici). asm6809 construit par le Makefile (autotools : dates
  remises dans l'ordre).
- BIOS : kbd_echap ($80 dès le code PS/2 d'Échap dans la NMI), le drapeau
  d'échappement du BASIC : une boucle sans affichage s'arrête sur Échap.
  hardware.inc : rvec_SWI3 (fixé à $DFF0 par l'édition de liens), cz_*,
  kbd_*. EPROM : 242 octets libres.
- Émulateur : AIM/OIM/EIM/TIM, opérations sur bits, ADCR/SBCR 16 bits,
  LDQ #, SWI3 natif ajoutés à verifie_fs.Machine.
- BBC BASIC, deux défauts de l'original corrigés (marqués OSM39) :
  - version 6309 de negateIntA et de fpReal2Int_NegateMantissa : CLRD
    remettait C à 0 entre SUBD et SBCD, le mot haut perdait la retenue
    (PRINT -1 = 65535, FOR ... STEP -1 s'arrêtait au premier tour) ;
    LDD #0 à la place, comme la version 6809 ;
  - popStackedStringNew : une chaîne dépilée vide sautait le CLRA qui
    marque le type chaîne ; R$="":R$=R$+MID$(...) donnait Type mismatch,
    ""+CHR$(65) donnait 65.
  Émulateur : SBCD/ADCD calculent aussi V.

## 17 oct. 2026 — BBC BASIC : fichiers ouverts, *EXEC

- Couche système : OPENIN/OPENOUT/OPENUP, BGET#, BPUT#, PTR#, EXT#, EOF#,
  CLOSE# (deux canaux, fichier entier en page 2 ou 3, écrit au CLOSE) et
  *EXEC (texte tapé comme au clavier). Le BASIC descend de $3800 à $3400
  (programmes : 11 Ko au lieu de 12) ; le Makefile refait tout quand BASE
  change et efface un binaire trop grand.
- SAVE créait un doublon à chaque nouvel enregistrement (FS_SaveFile ajoute
  toujours une entrée) et LOAD relisait l'ancien : l'ancien est supprimé
  d'abord. FS_DeleteFile ne garde pas U : la taille calculée ensuite était
  fausse, et le LOAD suivant écrasait le BASIC (vu dans l'émulateur).
- La pile du BASIC est en $01xx de la page 1 : FarRead, qui bascule la page
  puis relit ses paramètres sur la pile, lisait ceux de la page 2 et
  repartait dans la page 3. Ces services passent par la pile du système
  (Om_Sys).
- Défauts de l'original (marqués OSM39) : INPUT# chargeait le canal dans U
  au lieu de Y ; PTR#= inversait les octets pour un MOS grand-boutiste ;
  PTR#= et BPUT# gardent maintenant Y (le canal) autour de l'expression ;
  evalHashChannel, commenté « save TXTPTR », ne le sauvait pas : PRINT#
  relisait sans fin le début de la ligne, BGET#/EOF#/PTR#/EXT# repartaient
  d'une position périmée ; BPUT# reprenait le texte avant sa valeur (la
  suite de la ligne, CLOSE# compris, était sautée) ; PTR# et EXT# lus
  rendaient la valeur sans le type entier (affichés comme la dernière
  chaîne).
- FS_LoadFile ne garde pas U non plus : Om_Sys le protège.
- bbcbasic/AIDE.TXT : aide-mémoire en français (ASCII, 76 colonnes),
  chaque point essayé dans l'émulateur ; déployé dans BASIC/AIDE.TXT,
  annoncé par *HELP. ERROR n,"..." n'existe pas en BASIC IV (BASIC V).
- cmd/TYPE : affichait jusqu'au premier octet nul APRÈS le fichier (rien
  ne le terminait) ; s'arrête maintenant à la taille, compte LF et CR LF
  comme une fin de ligne, et fait une pause à chaque page (zone du
  Terminal ou écran ; Échap arrête).
- BBCPLUS : le même BASIC sans l'assembleur intégré (NOASM=1), 13 Ko pour
  les programmes au lieu de 10,5 ; *LOAD/*SAVE pour le code machine fait
  avec ASM ou lwasm. BBCBASIC descend à $3200 (la couche a grandi).
- Graphisme du BBC BASIC (osm39_gfx.asm) : mosaïques 2 x 3 dans la zone
  du Terminal (152 x 60 points), lignes de Bresenham réentrantes, triangle
  plein par des lignes du sommet vers chaque point du côté opposé,
  rectangles, GCOL poser/inverser/effacer, POINT, origine. BBCBASIC passe
  à $2E00 (9,5 Ko de programmes), BBCPLUS à $3800 (12 Ko).
- SOUND du BBC BASIC (osm39_son.asm) : file de notes dans SND_BUF pour le
  séquenceur du BIOS ; hauteur BBC arrondie au demi-ton (table de 12
  périodes, décalée par octave), durée en lignes de 256 trames au plus.
  EXG ne pose pas les drapeaux : TSTA avant le BPL (une durée de 200
  passait pour -1). hardware.inc exporte SND_BUF (BIOS inchangé).
  BBCPLUS passe à $3700 (11,5 Ko).
- Sur la carte : *EXEC "/BASIC/MUSIQUE.BAS" -> Fichier introuvable. Les
  commandes * reçoivent le texte avec ses guillemets et la copie du nom
  s'arrêtait au premier : nom vide. Les guillemets de l'argument sont
  maintenant ignorés (*EXEC "X" = *EXEC X) ; le banc tape la forme de
  l'aide, avec guillemets et dossier.
- Sur la carte : le tracé des formes pleines scintillait (lecture et
  écriture de la VRAM point par point, plusieurs fois par cellule, hors
  du retour de trame). Les points remplissent maintenant une file de
  cellules (masques K/C) dans gfx_tampon, nouveau tampon de 512 octets
  en fin de BSS du BIOS, appliquée juste après le début d'une trame, 10
  cellules par trame. Le banc mesure que chaque écriture du BASIC en VRAM
  tombe dans les premières instructions d'une trame. BBCBASIC à $2D00
  (9 Ko), BBCPLUS à $3600 (11 Ko).
- BIOS malloc_sys : un bloc découpé rendait un pointeur 3 octets trop
  loin (LEAX BLK_DATA,X deux fois). Sans appelant ; corrigé, effectif au
  prochain flash. Le tas commence maintenant en $CC2F.
- Mesuré sur la carte (BASIC/LUMIERE.BAS, attributs écrits en VRAM) : le
  bit D3 de l'attribut ATTÉNUE le premier plan (couleurs ternes) ; D3 = 0
  est aussi vif que la couleur de fond. AGENTS.md disait « D3 foreground
  bright » : corrigé. Le logiciel met D3 = 1 presque partout (COLOUR et
  graphisme du BBC BASIC, Terminal $0A, MINITEL, le noir dessiné $8 contre
  les traits roses) : l'image tournait en mode atténué.
- Schéma CRT2 : couleur = HCT08 -> 470 ohms -> 75 ohms du moniteur
  (0,69 V, la norme VGA) ; D3 (Vlum0) met 150 ohms à la masse par un
  2N7000 (0,48 V). Le conseil « passer R1-R3 de 150 à 75-82 ohms pour
  éclaircir » était faux (le mode atténué serait encore plus sombre) :
  les 150 ohms restent ; le bon réglage est logiciel (D3 = 0).
- Essayé sur la carte (80fe920) : COLOUR et graphisme en D3 = 0. Beaucoup
  plus lumineux, jugé trop vif pour les yeux : annulé, le BASIC reste en
  D3 = 1 (atténué). Pour y revenir : git revert du commit d'annulation.

## 18 oct. 2026 — DONJON39, étape 1

- apps/donjon39.asm : labyrinthe 3D par lancer de rayons (64 colonnes x 18
  rangées, hauteurs au tiers de rangée en mosaïques 2 x 3), source unique
  tools/donjon39/donjon39.py (tables, carte, modèle exact). Image composée en
  RAM, rangées changées recopiées par TFM au début des trames (4 par
  trame). Clavier brut lu dans kbd_buf (exporté dans hardware.inc). Le
  banc : vues = modèle à 6 positions, écritures VRAM au début des trames,
  murs, Echap ; ~8 trames par image en tournant (estimation émulateur).
- DONJON39 plus fluide : deux tampons d'image ; la recopie se fait dans
  l'IRQ VSYNC (Irq_Donjon dans rvec_IRQ, avant le BIOS ; hardware.inc exporte
  rvec_IRQ) pendant que la boucle calcule l'image suivante. DDA par
  pointeur dans la carte, colonne écrite par séries (plafond, mur, sol ;
  calcul détaillé pour les deux cellules de bord). Rendu : 38 000 ->
  17 000 instructions ; 8 -> 5 trames par image en tournant (émulateur).
  Le banc prend la vraie IRQ (Irq_Donjon puis handler_IRQ du BIOS).
- DONJON39 étape 2 : portes (valeur 8, Espace, refermeture après 300
  trames si le joueur est sorti), carte lue dans DONJON39.TXT (règles de
  texte_carte(), tour forcé en mur ; GAMES/DONJON39.TXT déployé), mini-carte
  (Tab). Le banc : seconde séance avec un DONJON39.TXT piégé (commentaires,
  CR LF / LF, minuscules, lignes courtes), le modèle prend la carte en
  mémoire.
- Carte CRT2 : mode graphique dessiné (U200-U202, GRAPH = U125 O3, U122D)
  et simulé (tools/crt2/simule_crt2.py) : mode texte identique pixel à
  pixel à l'ancienne carte, adresses de U112 en graphique, pixels et
  couleur de la même cellule, écriture CPU à la bonne adresse (bits de
  page permutés par U125 : page logicielle 5 = banc 6). Pas encore soudé.
- tools/carte_sd_kbd_son/simule.py : les modèles 157, 595 et 165 lisaient
  certaines broches par fermeture tardive (celles du DERNIER circuit du
  même type). Sans effet sur SD-KBD-SON (un seul de chaque, résultat
  inchangé) ; corrigé.

## 27 oct. 2026 — MINITEL sur un vrai modem V.23

- Modem Olitec Speed'Com 2000 (56000 V2.245DS) essayé au PC (minicom,
  115200) sur la ligne de la box : `ATB2` (V.23 d'après le glossaire AT
  Olitec), `ATDT0972101721;` puis `ATD` après le message vocal de
  MiniPavi : `CONNECT 75/1200` et des données. Composé d'un coup, le
  modem prenait la voix pour une porteuse (CONNECT puis NO CARRIER).
- MINITEL : 115200 bauds au lieu de 28800 (CR $95 : ÷64 n'est pas une
  vitesse qu'un modem reconnaît) ; appel `ATE0&D0B2M1DT` ; « 36xx » tapé
  devient `0972101721,,,,` ; touches en 7 bits + parité paire. modem.py
  suit (115200 par défaut, réglages et virgules acceptés, numéro de
  MiniPavi dans l'annuaire, bit 7 retiré vers Internet) ; banc à jour.
- Connecteur série de la carte V3 : brochage DTE (comme un PC) sur une DE9
  FEMELLE : adaptateur mâle-mâle droit pour un modem. Schéma OSM39_mono :
  DE9 mâle ; DCD (1) et CTS (8) reliés ensemble vers DCD/CTS du 6850 :
  deux sorties d'un modem en court-circuit, et CTS bloquerait l'émission
  (à corriger : 6850 DCD/CTS à la masse comme la V3).
- Mode graphique case par case (bit 3 de la couleur) étudié sur la carte
  globale avec tools/osm39_mono/simule_mono.py : la RAM couleur en série
  devant l'adresse de la RAM caractères ne tient pas le temps avec les
  composants actuels ; écarté.

## 27 oct. 2026 — Le clavier passe sur la carte SD-KBD-SON (`$A180`)

La carte SD-KBD-SON est montée. Son 68B50 (U1, `~CS2` = `$A180-$A1BF`, RS =
a0) a été essayé à la main dans MONITEUR avant de toucher au BIOS :

- au repos, `$A180` = `00` : le 6850 sort de la mise sous tension en reset,
  sans TDRE ; lire ne bloque rien ;
- écrire `$5C` sans `$03` avant a laissé IRQ (donc ~NMI, partagée et sur
  front) à 0 : plus de clavier ni de Ctrl+A. Avec `$03` puis `$5C`, le
  statut vaut `02` et IRQ reste haute (programme en page 2, `G 2:0000`) ;
- clavier sur J1, en scrutation : la touche A (AZERTY) donne `03 15`, puis
  `23` (débordement : `F0 15` arrivé derrière). Horloge, données, 8 bits
  parité impaire, RTS/D1 : bons.

Le clavier de la CPU (`$A1C0`) n'est plus utilisé : `CR_key`/`SR_key`/
`TDR_key`/`RDR_key` valent `$A180`/`$A181` (`bios/update_includes.py`). Le
BIOS écrit toujours `$03` avant de configurer (`keyboard_init`). Vérifiés
après le changement : `demarrage`, `terminal`, `bureau`, `minitel`, `donjon39`,
`farcall`. EPROM à reflasher.

## 27 oct. 2026 — Aides d'EDIT et CALC ; CALC demande avant de quitter

- `docs/manuel-edit-calc.md` (complet) et `DOC/EDIT.TXT`, `DOC/CALC.TXT`
  sur la carte (sources dans `apps/`, ASCII 76 colonnes comme
  `BASIC/AIDE.TXT`), écrits d'après les tables de touches du code.
- CALC : Echap quittait sans sauver ni demander. Il demande maintenant O/N
  tant que la feuille n'est pas sauvée (`Modified` : mis par `Store_Cell`,
  remis à 0 par la sauvegarde, la lecture et l'effacement de la feuille).
- `verifie_fs.Machine` exécute DIVD/DIVQ (signés, quotient tronqué, erreur
  sur division par zéro ou dépassement) : CALC s'en sert pour afficher un
  nombre, et `verifie_bureau` n'avait jamais saisi de valeur. Trois cas
  ajoutés : Echap+N reste, Echap+O sort, /S puis Echap sort sans question.

## 30 oct. 2026 — SDTEST : essai de la carte SD sur le SPI matériel

Avant de toucher au BIOS, un programme de la carte habituelle (`BIN/SDTEST`,
`cmd/sdtest.asm`) parle à une seconde carte SD (32 Go, neuve) dans le
support de la carte SD-KBD-SON, par `SD_CTRL` ($A140) et `SD_DATA` ($A148),
ajoutés à `hardware.inc` (`update_includes.py`). Init en lent, CID, CSD,
secteur 0, 200 lectures comparées, écriture d'essai au secteur $00100000
sur O (contenu remis). Toutes les réponses sont affichées en hexa.

`test/verifie_sdtest.py` : une carte SDHC simulée au niveau des octets
SPI. Le registre n'a pas de bit « occupé » : l'espacement entre transferts
est vérifié en accès au bus distincts par instruction (borne basse des
cycles). Piège de l'émulateur : `alu_mem8` lit l'opérande avant un STA ;
sans correction, chaque écriture en $A148 lançait deux transferts.
Contrôle négatif : 30 tours d'attente en lent (121 accès) sont refusés,
60 (211) passent.

## 30 oct. 2026 — Premier essai réel de SDTEST ; télécommande TELE

Sur la vraie carte (no-name « TI SD32G », fabricant $9F, 29 844 Mo) :
init, CID, CSD, secteur 0 (`55 AA` en 510-511 : lectures alignées) et 200
lectures en rapide sans erreur, 52 Ko/s. L'écriture échoue : après le CRC,
8 octets à $00 (pas de réponse de données), puis CMD13 R1 = $07 (repos +
commande illégale) : la carte est revenue à l'état de mise sous tension.
Pistes : chute d'alimentation à l'écriture, ou octets décalés pris pour un
CMD0 (le motif contient $40). Le simulateur de la carte, avec 8 écritures
rapides espacées de 9 à 14 cycles, ne reproduit rien : 8 fronts par octet.

Pour aller plus vite, `cmd/TELE` + `tools/tele/tele.py` : la machine se
pilote depuis le PC par la liaison série (mémoire, appels). SECOURS ne
peut pas servir : ses commandes ne se lisent qu'au clavier.

## 30 oct. 2026 — Écriture SD : la lecture renvoie l'octet lu

Par TELE (`tools/tele/essai_sd.py`), en quelques minutes :
- écrire en lent ou en rapide, avec ou sans changement de vitesse : même
  défaut. Sans octets de CRC, la réponse $E5 se lit décalée d'un bit
  (`F2 80`) et arrive pendant le dernier octet de données ;
- le secteur relu vaut le motif décalé de 23 bits, précédé de 7 bits à 0 :
  la carte a pris un 0 envoyé PENDANT L'ATTENTE DE R1 pour le début du bloc ;
- CMD24 « à l'aveugle » (aucune lecture avant le jeton) : écriture rapide
  juste, 10 secteurs aléatoires sur 10 relus identiques ;
- 4 octets de données envoyés par des lectures, juste après $FE : stockés
  $FF. L'entrée DS du 165 est donc bonne ; c'est la valeur LUE (R1 = 00)
  qui repart : le 165 se charge aussi en lecture. Suspect : l'entrée R/W
  de U104 (broches 1-2-3, `~SEL_WR`), à vérifier à l'ohmmètre.
SDTEST passe CMD24 à l'aveugle ; la carte simulée de verifie_sdtest.py
renvoie l'octet lu et prend le premier 0 après CMD24 pour le jeton :
l'ancien SDTEST y échoue comme sur la carte, le nouveau passe.

## 30 oct. 2026 — Le BIOS passe sur le SPI matériel

`bios/SD.asm` réécrit pour la carte SD-KBD-SON (686 -> 404 octets ; les
routines mortes `Set_Block_Size_512` et `SD_Read_CSD` retirées). Même
contrat et mêmes codes d'erreur ; init en lent, le reste en rapide ; CMD24 à
l'aveugle. `RECEIVED_BYTE` (seul l'ancien pilote s'en servait) devient
`sd_ctrl`, à la même adresse : rien ne bouge en RAM.
Essayé AVANT de flasher, depuis la RAM par TELE (`tools/tele/
essai_bios_sd.py`, banc `banc_bios_sd.asm`) : 51 200 lectures sans erreur
(~52 Ko/s ; l'ancien SPI logiciel était bien plus lent), 20 écritures
aléatoires relues. Piège du banc : un `equ` placé dans une section est
relatif à la section pour lwlink ; les adresses de la RAM du BIOS vont dans
une section `.abs` posée en $0000, et le script vérifie la carte de liens.
`verifie_sdtest` fait tourner le vrai pilote face à la carte simulée ;
`verifie_demarrage` simule l'absence de carte au registre $A148.

## 30 oct. 2026 — AY-3-8910 : premiers essais

Par TELE, sans assembleur : écrire $A150 (registre), $A151 (donnée), relire
$A150. Silence pendant l'essai (volumes à 0). 300 relectures aléatoires :
tous les registres justes SAUF R9 (volume de la voix B), qui se relit
toujours $00 ; écrire R9 ne touche aucun autre registre. Puce qui ne garde
pas R9, ou relecture seule défaillante (clone ?) : à trancher à l'oreille.
`cmd/AYTEST` (BIN) : relecture, puis voies A, B, C seules (La 440), accord,
bruit, enveloppe, annoncés à l'écran. Lancé sur la machine par TELE (copie
reliée à $2000) : 26/28, 9 s comme prévu. `verifie_aytest.py` : AY simulé.
`tele.py` rejoue P/R/W après un silence ou une somme refusée : sur ~1200
trames, 7 rejouées (un octet perdu de temps en temps sur la ligne).
AY_ADR/AY_DATA ajoutés à hardware.inc.
Verdict à l'oreille et au multimètre : R9 ne retient vraiment rien, la
voie B est muette (broche 3 à ~90 mV au volume 15, A et C à 750 mV). Horloge
vue par une enveloppe lente (rampe de 9 s sur la broche 4), ton, bruit,
enveloppe justes sur A et C. Le premier silence total venait d'un
court-circuit sur la sortie J103 (corrigé sur la carte). L'ampli LM386 n'est
pas monté : J103 sort en niveau ligne vers l'ampli de l'écran, à la place du
6840 (débranché). Puce défectueuse : à remplacer.

## 30 oct. 2026 — Le séquenceur du BIOS joue sur l'AY

`AUDIO_UPDATE` (IRQ) envoie chaque ligne de partition au 6840 ET à l'AY :
voix 1 sur la voie A, voix 2 sur la voie C (B est muette sur la puce de la
carte). Format inchangé : compte N du 6840 -> période TP = (N+1)/8 (f =
E/(2(N+1)) = E/(16 TP)), plafonnée à $FFF ; note 0 = volume 0. `snd_play`
remet le mixeur à $3A. Le jingle de démarrage passe par le séquenceur
(partition SONG_TADA_2V, jusque-là inutilisée, 55 trames comme avant) au
lieu d'écrire les timers ; COUPER_SON supprimé. EPROM : fin du .code en
$FE01 (+48 octets). `verifie_aytest.py` rejoue l'IRQ trame par trame.

## 30 oct. 2026 — Lecteur de musique pour l'AY ; émulateur : bits de CC

Le séquenceur du BIOS ne fait que deux carrés à volume fixe : sur l'AY,
« pas beaucoup mieux que le 6840 ». D'où `lib/ay_joue.asm` (accroché à
rvec_IRQ, lit le morceau dans la page du programme), `cmd/AYJOUE`, le
format et son modèle exact dans `tools/ay/ay.py` (partition texte,
instruments : volume par trame, bruit, enveloppe), `MUSIQUE/` sur la carte
et `.MUS` dans OSM-VISION. KOROBEINIKI (347 octets) joué sur la machine par
TELE : « la musique est beaucoup mieux ». Volume encore faible malgré R103
passée de 470 à 2k2.

En l'essayant dans l'émulateur, l'IRQ n'était jamais prise : `emu6809.py`
rangeait les bits hauts de CC à l'envers (H en $10, I en $80). Toute
addition avec demi-retenue masquait ou démasquait l'IRQ au hasard, dans
tous les vérificateurs qui prennent des IRQ ; ADDD posait H (le 6809 n'y
touche pas) ; RTI dépilait S. Corrigé ; autotest et tous les vérificateurs
repassent.

## 30 oct. 2026 — PAROLE sur l'AY ; niveaux de l'AY mesurés

La sortie son du 6840 est débranchée (l'AY a pris sa place) : PAROLE était
muet. Il sort maintenant par l'AY en convertisseur : ton et bruit coupés,
la sortie d'une voie vaut son volume ; A + C additionnées (4k7 chacune),
un couple de volumes par échantillon (tables_ay() de parole.py), écrits
coup sur coup par STD AY_ADR dans la seconde tranche de 128 cycles. Le
timer 3 reste l'horloge à 7200 Hz. Plus de porteuse à 14,4 kHz.
Niveaux des 16 volumes mesurés au multimètre sur la broche 4 (TELE, R7 =
$3F) : 0 5 7 12 18 28 40 69 83 140 190 260 345 440 581 721 mV
(MESURES_MV de tools/ay/ay.py) : 73 niveaux distincts pour A + C.
Sur la machine : « une vraie voix de robot » (celle de S.A.M.).

## 30 oct. 2026 — MINITEL par le vrai modem : parité et PCE

Premier appel de MiniPavi par MINITEL avec le modem Olitec : connexion,
puis « D:iD:hD:iD » à l'écran. Deux causes :
- le modem répond avec la parité de la commande AT (7 bits + parité
  paire) : « CONNECT » arrivait en C3 CF 4E 4E C5 C3 D4 et n'était pas
  reconnu ; MINITEL restait dans la phase d'appel et montrait les octets
  du serveur comme une ligne du modem. modem.py, lui, répond sans parité.
  Les lignes du modem sont comparées bit 7 retiré (NO CARRIER aussi) ;
- par le téléphone, MiniPavi demande la PCE (PRO2 START PROCEDURE, 1B 3A
  69 44, répété toutes les 3 s sans réponse), ENQROM, puis envoie tout en
  blocs PCE. Capturé au PC par tools/minitel/capture.py (modem branché sur
  le PC) : 75 blocs, CRC x^7+x^3+1 sur 8 bits (parité comprise), poids
  fort d'abord, trouvé en essayant les conventions sur la capture.
Couche Terminal (videotex.py) / Term_Octet (minitel.asm) : réponses au
serveur, blocs, NACK et reprise sur SYN SYN, DLE. Adaptateur DE9
mâle-mâle droit à 5 fils (2 3 5 7 8).
Essai suivant sur la machine : « :-D », TD et RD en alternance, puis
MINITEL figé (reset). Capture au PC avec le modèle en terminal
(capture.py --terminal) : MiniPavi n'avait pas pris la réponse à START et
le répétait ; nos START reçus en PCE devenaient un bloc faux -> NACK en
boucle. Correction : START guetté sur les octets bruts, réponse à chacun,
PCE remise au bloc 0. Mais la ligne de la box était devenue très bruitée
(START mutilés : 1B 3A 60 44, 3A 69 44, 1B 3A 44...) et MiniPavi n'a pris
aucune réponse, ni 44 ni 40, sur quatre appels ; à refaire. Cause du figé
de MINITEL non trouvée.
Puis, DECT débranché, toujours refusé ; avec le modem plus fort (ATS91=6 :
émission à -6 dBm au lieu de -10) : MiniPavi prend la réponse, la page
d'accueil arrive entière en PCE au terminal du PC (capture.py --terminal,
le modèle), avec trois NACK et leurs reprises. S91=6 ajouté à l'appel de
MINITEL ; modem.py accepte S91=6.
Sur la machine ensuite : NO CARRIER pendant la voix (4 virgules, 8 s :
trop juste, le modem écoutait avant la fin du message). 5 virgules, et
l'AT envoyé avec parité (comme les touches ; modem.py retire le bit 7 en
mode commande) : la page d'accueil de MiniPavi s'affiche sur OSM39 par le
téléphone (« ça marche !!! »).

## 30 oct. 2026 — Les schémas sous git

Sources KiCad de toutes les cartes dans un dépôt à part,
~/Documents/kicad/OSM09 (rien n'a bougé : KiCad et les simulateurs
gardent leurs chemins), sauvegarde osm09-kicad.bare sur la clé. 131
fichiers, 12 Mo compressés (le dossier faisait 604 Mo avec les
sauvegardes, caches et copies). OSM39_mono/gerber.zip = la commande du
soir.

## 31 oct. 2026 — Voyants du clavier et Verr. Maj

« Chantier abandonné et peut-être impossible » : la carte SD-KBD-SON a
TxD sur DATA et TxC sur CLOCK (et RTS -> D1 -> CLOCK) ; CR_key est déjà
en 8 bits + parité impaire, /1. Essai par TELE (tools/tele/essai_leds.asm) :
TDR chargé, RTS bas ~200 µs (le 6850 sort son start au front), RTS haut :
le clavier cadence les 11 bits ; $ED $04 allume le voyant Verr. Maj, $ED
$00 l'éteint. Le récepteur ramasse notre trame et lit l'accusé $FA en
$F4 (le bit d'accusé pris pour un start) ; la file du clavier reste
propre ensuite. Dans le BIOS : Verr. Maj (lettres seulement, é è à ç ù
compris, en Latin-1 comme les tables), envoi par l'IRQ, NMI muette 4
trames. Constaté au passage : le clavier rend les accents en Latin-1, la
police est en page 437 (accents tapés mal dessinés).

## 31 oct. 2026 — OSM-VISION : icône du son, aide sur ?

« Son » / « Mute » dans la barre d'état remplacés par un haut-parleur
(avec ses ondes, ou barré) ; ? ouvre et ferme un panneau des raccourcis à
droite du bureau (on ne savait jamais comment couper le son : M). Les
icônes et la flèche de la future souris prennent les 4 dernières cases
libres de la page 1 ($1C-$1F, video/glyphes_ui.py) : reprogrammer
l'EPROM des caractères (deploy_sd.sh copie désormais la police dans
dist/EPROM et vérifie qu'elle contient ces glyphes).


## 31 oct. 2026 — Manuel de l'utilisateur ; trois défauts trouvés en l'écrivant

- OSM-VISION : un nom de 15 caractères dont l'extension finit le champ
  (`KOROBEINIKI.MUS`, `BUDGET_2026.CAL`) n'ouvrait rien sur Entrée :
  `AO_Search` exigeait une espace après l'extension. Test ajouté dans
  `verifie_bureau.py`.
- PAROLE : « Pr\x88t » s'affichait tel quel (lwasm n'interprète pas `\x`) ;
  les textes sont faits de `FCC` et `FCB $88`.
- FORTH : `SETPAGE` retiré. Il écrivait la page en `$A000`, le contrôle de
  la liaison série depuis la V3 ; en `$A0C0`, il aurait basculé la page où
  tourne le FORTH lui-même.


## 31 oct. 2026 — La Clouris dans OSM-VISION

- La boucle d'événements d'OSM-VISION n'appelle plus `scan_keyboard`
  (bloquant) mais `sys_kbd_poll`, pour lire la Clouris à chaque trame ;
  elle vide la file en entrant comme le faisait `scan_keyboard` (d'où
  `e0_received` exporté dans `hardware.inc`). Le menu Espace aussi.
- `verifie_fs.Machine` modélise R14 (port A de l'AY, `$FF` par défaut) ;
  l'émulateur relit l'adresse d'un `STA` : `verifie_bureau.py` compte donc
  les trames de la Clouris sur l'écriture de 14 dans `AY_ADR`.
- Câblage réel : J104 de la carte SD-KBD-SON (pas J602) ; ni clic droit ni
  « centre = clic », le clic est sous le pouce (IOA5). Tirages de 1 Mohm :
  doigt mouillé seulement ; 1 + 8,2 Mohm partout sauf le centre.

## 1er nov. 2026 — ASM : SBCA et SBCB ; dépôt public

- L'assembleur de la machine (`asm/opcodes.inc`) n'avait ni `SBCA` ni
  `SBCB` : `ASM DONJON39.ASM` échouait (« mnémonique inconnu », ligne 463),
  et `make -C test asm-tout` aussi depuis l'arrivée de DONJON39 sans que
  personne le lance. Ajoutés, et essayés dans `asm/test/test6309.asm`.
- `tools/publie/publie.py` fabrique le dépôt public (GitHub) à partir de ce
  qui est commité : voir AGENTS.md, « Version control ».

## 6 nov. 2026 — Horloge MC146818 sur le PIA

- Petite carte RTC (dépôt KiCad, `RTC/`) sur le connecteur du PIA (J4 de
  la V3, J102 de la mono) : AD0-7 sur PA, AS sur CA2, DS sur PB0, R/W sur
  PB1, /IRQ sur CA1, 18650 rechargée à part. Le bus à 1,8432 MHz est trop
  rapide pour la puce (tcyc ≥ 953 ns) : elle est menée à la main.
- `lib/horloge.asm` (pilote), `cmd/HORLOGE` (lire, régler), prouvés par
  `make -C test horloge` avant la première carte. Le vérificateur
  attrape : AD laissé en sorties pendant une lecture, R/W qui bouge DS
  haut, une seule lecture, et l'absence d'attente de UIP (deux lectures
  pendant la mise à jour rendaient les mêmes octets faux).
- `main` mettait CRA à `$0C` : CA2 en entrée avec son IT. Avec la carte,
  CA2 est l'AS flottant de la puce ; un front lançait une FIRQ que
  `handler_FIRQ` (un RTI) n'acquitte pas. CRA = `$34` (CA2 sortie basse)
  et PB = `$02` (R/W à 1) ; taille de l'EPROM inchangée.

## 8-9 nov. 2026 — Horloge : premier essai sur la carte, écriture parasite au RESET

- DS1287 de 1989 sur plaque d'essai, piloté par TELE : lectures bonnes,
  toutes les écritures ignorées -> R/W mal soudé (un cycle à la main,
  DS = 1 avec R/W = 0, rendait encore la donnée). Ressoudé : réglage,
  secondes au rythme du PC, heure gardée 35 min machine éteinte ; son bit
  VRT reste à 0 (pile faible une fois, jamais remis à 1).
- MC146818 : l'oscillateur ne démarre pas (quartz de récupération ?).
- Une relecture (un autre Claude) a vu que `Hor_Init` écrivait PIADRB
  avant de choisir ORB : après un reset (CRB = 0) cela tombe dans DDRB et
  fait une écriture parasite. Sans effet ici (le BIOS laisse CRB = `$04`),
  mais le même défaut était dans `main` : port B en sorties avec ORB = 0,
  DS et R/W (tirés à 1 tant que PB est en entrée) tombaient ensemble ->
  `$FF` dans le dernier registre adressé, à chaque RESET (registre B :
  horloge figée, « pas réglée »). Corrigé dans les deux (ORB = `$02`
  d'abord) ; `verifie_horloge.py` part d'un PIA remis à zéro, lance le
  vrai `main` et `Hor_Init`, et refuse que DS et R/W changent ensemble
  (l'ancien code échoue). EPROM +5 octets. Tirer DS à la masse sur la
  carte (R1) rendrait ce genre d'erreur inoffensif.

## 9 nov. 2026 — Carte OSM39_mono : un logiciel pour deux cartes (fichier `CARTE`)

- Inventaire de la netlist de la mono (exportée de KiCad) contre le
  logiciel : mêmes adresses d'entrées-sorties (ACIA `$A000`, PIA `$A040`,
  6840 `$A080`, pages `$A0C0`, 68B45 `$A100`, verrou `$A120`, SD
  `$A140/$A148`, AY `$A150`, clavier `$A180`), même octet d'attribut, même
  rangement de l'EEPROM de police que `font_osm39.bin`. Seule différence :
  la VRAM est entrelacée (caractère en `$8000+2c`, couleur en `$8001+2c`)
  et `$A120` D3 = GRAPH.
- Fichier `CARTE` (`v4` / `mono`) lu par `update_includes.py` :
  `CARTE_MONO`, `VRAM_PAS`, `VRAM_LIGNE`, bornes des boucles. BIOS,
  `lib/vram.asm`, `lib/vision.asm` et OSM-VISION convertis par
  `IFNE CARTE_MONO`. Une construction `v4` reste octet pour octet celle
  d'avant (38 binaires comparés à une référence).
- Trouvé en route : `Draw_Base_UI` remplissait `VRAM_END-VRAM_BASE` octets
  depuis `VRAM_COL` ; sur la mono, cela aurait écrit en `$A000` (l'ACIA).
  `verifie_bureau.py` l'a vu (panneau `?`), corrigé.
- Vérificateurs : `test/carte.py` lit la disposition dans `hardware.inc` ;
  `terminal` (nouvel essai plein écran : R12/R13, R14/R15), `fs`
  (moulinet), `bureau`, `dossiers` passent sur les deux cartes, ainsi que
  `demarrage`, `farcall`, `tele`, `clavier`, `aytest` et `asm-tout` (l'ASM
  de la machine identique à lwasm aussi pour la mono). BIOS mono : 336
  octets libres (v4 : 291).
- Banc : `stage9_mono` (premier écran de la mono, sans BIOS) et
  `verifie_banc_mono.py` ; les étapes 1-8 refusent de s'assembler en mono.
- `tools/crt2/simule_crt2.py` ne reconnaissait la police que sous le nom
  `KM28C64` : avec l'`AT28C64` de la mono, `simule_mono.py` concluait à
  tort à un mode texte cassé. Corrigé. Il reste dans le modèle un décalage
  d'une case entre dessin et couleur, identique sur la CRT2 (qui affiche
  juste) : limite du modèle de temps, pas un défaut de la mono.
- AGENTS.md disait « lwasm rejette les equ dans les conditions » : faux
  pour `IFNE`/`IFEQ`/`IF x>1` sur un equ défini avant (mesuré, et utilisé
  partout désormais) ; seule la forme du commentaire de `test/Makefile`
  (`if SPL_TEST = 3`) n'a pas été réessayée.
- Pas encore convertis (écrivent la VRAM en direct) : MIRE, MINITEL, PONT,
  ENVAHIS, GLOUTON, DONJON39, BRIQUES, graphismes de BBC BASIC
  (`PAS_MONO` dans `deploy_sd.sh`).

## 12 nov. 2026 — Clouris : carte à transistors PNP, polarité inversée

- La carte de la Clouris (KiCad `clouris/`) met un PNP (BC516 Darlington sur le schéma, S9015 monté : il marche
  mieux, gain plus faible ;
  émetteur au +5 V, 100 k vers le clou, collecteur tiré à la masse par
  47 k) avant chaque porte du 74HC14 : doigt posé = bit à 0, repos = 1.
  Le premier montage (clou -> 74HC14) donnait l'inverse : AGENTS.md disait
  « touch = bit 1, at rest R14 = `$C0` ».
- `lib/clouris.asm` et `cmd/cloutest.asm` : `CLOU_INVERSE` (1 par défaut,
  0 pour l'ancien montage). En inversé, `COMA` suffit : une Clouris
  absente ($FF) devient « aucun contact » sans test.
- `verifie_bureau.py` écrit les essais en clous touchés et les convertit
  (`r14()`) ; avec `CLOU_INVERSE = 0`, quatre essais échouent (vérifié).
- Le manuel n'avait pas le brochage : section « Brancher la Clouris »
  (J7 -> J602), et la ligne « Extension » ne met plus la Clouris sur le
  connecteur 48 broches.
- La base n'a pas de résistance vers l'émetteur ; elle flotte au repos.
  Avec le Darlington, le secteur suffisait presque ; le S9015 est franc.
  Le S9015 est E-B-C, le BC516 C-B-E : sur l'empreinte du BC516, le
  monter retourné.

## 12 nov. 2026 — ZMACHINE : interpréteur Z-machine (v4, v5, v7, v8)

- Modèle de référence d'abord (`tools/zmachine/zmachine.py`, commité le
  12 nov.) : czech identique à `czech.out5`, praxix complet sauf
  `multiundo`, jeux comparés à dfrotz (écarts expliqués : ligne d'état
  absente de dfrotz, hasard, menus d'aide selon l'interpréteur).
- Changements du modèle pour le 6309 : pas d'annulation (`@save_undo`
  rend -1, bit 4 de Flags 2 à 0 : pas de place pour une copie de la
  mémoire dynamique) ; sauvegardes Quetzal (UMem à l'écriture, UMem ou
  CMem à la lecture ; frotz relit les nôtres, nous relisons les siennes,
  vérifié dans les deux sens) ; graine du hasard = `vsync_tick` ; le
  script est un flux de touches (l'ancien jetait le reste d'une ligne
  après `@read_char` : dreamlands divergeait) ; `Flags 2` : le modèle
  effaçait les bits images/souris/son dans l'octet `$10` au lieu de `$11` ;
  alphabet personnalisé lu en ZSCII.
- 6309 (`zmachine/`) : cache de 32 blocs de 256 octets en page 1 (3
  épinglés pour les globales), jeu en pages 2-3 (`FarRead`/`FarWrite`),
  au-delà de 64 Ko lu sur la carte ; copie d'écran recopiée par l'IRQ.
  Pièges rencontrés : `FCC "/\\"` donne deux barres (lwasm n'échappe
  pas) ; `PULS B,X` après un appel écrasait l'octet bas de l'opérande ;
  `NOps` non remis à 0 pour `EXT` (`@save` croyait avoir une table).
- Mesure dans l'émulateur : 130-190 instructions 6309 par instruction Z.
  Estimation (pas mesurée sur la carte) : aventure ~1,5 s par tour,
  Zork_LXIX ~8 s.

## 13 nov. 2026 — ZMACHINE : version 3 (Zork I)

- Zork I-III publiés sous MIT (dépôts `historicalsource`) ; `zork1.z3`
  (release 119) est dans `COMPILED/`. Les `.thl` trouvés d'abord étaient
  des fichiers d'indices pour « The Hint Library » (Windows 95).
- Modèle : v3 ajoutée ; il traitait aussi mal la v4 (locales initiales
  de l'en-tête de routine, saisie au format v1-4, `not` en 1OP 15, `pop`
  en 0OP 9, save/restore en 0OP). Comparé à dfrotz sur Zork I : identique ;
  sauvegardes croisées avec frotz dans les deux sens.
- Fenêtre 1 : le modèle et le binaire la coupaient à sa hauteur ; Z-Snake
  dessine sans `@split_window` (seul un « carré blanc » paraissait sur la
  carte, le 12 nov.) : coupée au bord de l'écran, comme frotz. Le banc
  sait maintenant laisser s'écouler un délai (`None` dans le script).
- 6309 : course avec l'IRQ de recopie : `Rang_Vide` marquait la rangée
  sale avant de la remplir (la ligne d'état restait fausse en VRAM) ;
  marquée après. Place : tables de caractères sorties du code (cache à
  30 créneaux).

## 13 nov. 2026 — Seconde sauvegarde : dépôts privés sur GitHub

- La clé USB était le seul dépôt distant (logiciel et KiCad sur la même
  clé) ; le miroir public exclut BBC BASIC, basic69 et les polices.
- `osm39-prive` et `osm09-kicad-prive` (privés) ; `origin` pousse vers la
  clé puis GitHub. Premier envoi refusé (« email privacy restrictions ») :
  option du compte décochée le temps de l'envoi, et `user.email` local mis
  à l'adresse no-reply pour la suite.

## 13 nov. 2026 — Carte mono : tous les programmes convertis

- `PAS_MONO` est vide : PONT/PONT2, ENVAHIS, GLOUTON, BRIQUES
  (`lib/rowaddr.inc`), MINITEL, DONJON39, BBC BASIC convertis ; MIRE n'avait
  rien à faire (tout par `vis_*`, la sauvegarde d'écran fait 2 octets par
  case dans les deux formats).
- Les 12 binaires v4 restent identiques à l'octet (sommes MD5 avant et
  après). Un piège : `LEAX VUE_L,X` (VUE_L défini plus bas) était en forme
  longue ; la constante `RANG_O`, connue d'avance, donnait la forme courte.
- `verifie_donjon39.py`, `verifie_minitel.py`, `verifie_bbcbasic.py` lisaient
  la VRAM à des adresses v4 écrites en dur : ils passent par `carte.py`.
- Pas encore fait (proposé dans la revue du projet) : une bibliothèque
  commune « copie d'écran + rangées sales + IRQ » ; chaque programme garde
  son propre mécanisme.

## 13 nov. 2026 — Le BIOS en deux parties : EPROM + BIOS2 sur la carte

- L'EPROM était pleine (291 octets libres). L'écriture de fichiers, la
  console du Terminal et le séquenceur de son passent dans BIOS2
  (`bios/ext.asm`, section `.ext`), chargé en `$CE00` à chaque démarrage :
  1 875 octets libres dans l'EPROM, 1 944 octets de BIOS2 (place : 1 128).
- Ma première proposition plaçait BIOS2 en `$D340-$D9FF` en annonçant
  2,75 Ko : c'était 1,7 Ko. Le tas système (1 792 octets, le SHELL n'en
  prend que 19) a été réduit à 256 octets pour libérer `$CE00`.
- Pile mesurée dans 13 vérificateurs avant de fixer `EXT_FIN` : jamais
  sous `$DDEB` (sonde sur S dans `verifie_fs.Machine.step`).
- Les vérificateurs utilisaient `$CF00`, `$D000-$D3xx` comme brouillon en
  RAM système : déplacés en `$DB00-$DDFF` (et en page 0 pour les 2 Ko de
  `verifie_dossiers`). Les 17 copies de la table des services passent par
  `installe_bios()`. Premier essai : `Machine` installait BIOS2 en
  exécutant du code avant que les bancs dérivés soient prêts ; il recopie
  désormais les tables (`Ext_Def`, `Ext_Table`).
- Pas encore essayé sur la carte : il faut graver l'EPROM et poser
  `/BIN/BIOS2` ensemble.


## 13 nov. 2026 — BIOS2 jamais chargé sur la carte : Y détruit par le pilote SD

- Sur la carte, le premier BIOS en deux parties ne chargeait jamais BIOS2
  (`ext_ok` = 0, vecteurs par défaut, `$CE00` vierge) : plus de Terminal en
  fenêtre, plus de son. `Ext_Charge` gardait l'adresse de copie dans Y, et
  `SD_ReadBlock` se sert de Y pour attendre le jeton (`LDY #20000`) :
  `Fs_ReadBlk` ne sauve que B. La copie partait vers `$4Exx`, la somme
  échouait. Corrigé : `pshs y` / `puls y` autour de `Fs_ReadBlk`. Prouvé
  sur la carte par TELE (le nouvel `Ext_Charge` lancé depuis la RAM), puis
  EPROM reflashée : `M CC50` = 01.
- Les vérificateurs ne pouvaient pas le voir : `Machine.sd()` servait
  `SD_ReadBlock` en Python sans toucher aux registres, et `demarrage`
  partait d'une RAM où `installe_bios` avait déjà posé BIOS2. Le modèle
  rend maintenant les registres du vrai pilote (X au bout de `SD_BUFFER`,
  W = 0, Y = compteur d'attente entamé), et un démarrage à froid remplit
  la zone BIOS2 de `$FF`. L'ancien `ext.asm` y échoue avec les valeurs
  photographiées sur la carte (`F76F`, `ECD1`) ; les 18 vérificateurs
  passent avec le nouveau.
- Effet de bord de l'essai à chaud : OSM-VISION écrit `SND_PTR` lui-même ;
  sans BIOS2, le pointeur d'un ancien bip était resté, et le séquenceur
  installé à chaud l'a relu dans la page de TELE (ronflement A et C,
  période `$FFF`). Impossible au démarrage normal (BSS remis à zéro).

## 13 nov. 2026 — Cartographie mémoire refaite

`docs/memory-map.md` décrivait encore, à côté de BIOS2 : un démarrage sur
le moniteur (`BRA Monitor`, `BOOT` pour lancer le SHELL), des champs page
et adresse OSMFS « écrits par personne » (FS_SetLoad, egofs_deploy et
OSM-VISION les écrivent), ASM limité à 8 Ko de source (il lit secteur par
secteur), VI (retiré), un octet de couleur avec clignotement et inversion
(V3), `fload.o` dans l'EPROM, un BSS finissant en `$CC33` et des modules
EPROM mesurés le 10 oct. Réécrit d'après `bios/osm39.map` : BSS complète
jusqu'à `ExtV`, BIOS2 module par module, EPROM, cartes `v4` et `mono`,
AY et horloge dans les périphériques, chaîne de démarrage actuelle.
Le manuel parle maintenant de BIOS2 (mémoires mortes, démarrage,
dépannage avec `M CC50`, annexe A) ; `bios/README.txt` ne donne plus de
commandes d'avant lwtools.

## 13 nov. 2026 — Contrat des services mesuré, `make -C test tout`

- Les en-têtes des services ne disaient presque rien des registres
  détruits. `test/verifie_contrat.py` les mesure tous (registres témoins,
  appel par la table) : W perdu par tous les services de fichiers sauf
  `FS_ReadSector`, U par `FS_DeleteFile`/`FS_GetAttributes`/
  `FS_SetAttributes`, `PrintHexChar` ne rend pas A, etc. Le contrat est
  `test/contrat_services.py`, `docs/services.md` en est tiré.
- `make -C test tout` remplace la boucle à la main sur les cibles :
  21 vérificateurs en ~6 min sur 4 cœurs.

## 13 nov. 2026 — Les accents tapés s'affichent (Latin-1 traduit en CP437)

- AGENTS.md disait « accented letters typed in EDIT are not drawn as
  accents (known, not fixed) ». Le clavier reste en Latin-1 : en CP437,
  `$80-$8B` sont é à ç è ê, les codes des touches spéciales. `Put_Text`
  (`lib/vision.asm`, donc `vis_Text` et `vis_Input`) traduit `$A0-$FF` en
  dessinant (`lib/latin_cp437.inc`, de `video/latin_cp437.py`) ;
  `vis_Input` refusait tout au-delà de `$7E`, il accepte maintenant les
  lettres Latin-1 sauf avec `INP_MAJ` (noms de fichiers). La console du
  BIOS ne traduit pas (il faudrait reflasher). Prouvé par `make -C test
  bureau` (Exécuter, Renommer).

## 14 nov. 2026 — La date et l'heure dans la barre d'état d'OSM-VISION

- Le MC146818 changé, la carte RTC marche. OSM-VISION lit l'horloge une
  fois par seconde (avant l'attente de trame) et écrit `JJ/MM/AAAA HH:MM`
  après l'icône du son, juste après la trame ; rien sans carte.
- Le banc de `verifie_fs` rendait au port A du PIA le dernier octet écrit :
  selon le hasard des écritures, une horloge absente pouvait passer pour
  présente. Il rend maintenant `$FF` (les tirages). Le PIA et la puce de
  `verifie_horloge.py` sont devenus un mixin (`PiaRtc`), que le bureau
  utilise aussi.

## 15 nov. 2026 — Premier allumage de la carte OSM39_mono ; NEIGE

- 450 mA, démarrage, BIOS2, OSM-VISION, jeux, ZMACHINE, BBC BASIC : tout
  tourne, la VRAM entrelacée est juste partout.
- De la neige dans les applications, pas dans OSM-VISION au repos. Écartés
  par mesure : le moment de l'IRQ de trame (même câblage que la CRT2,
  fenêtre de 34 lignes contre 35 en V4), les 74HC157. `cmd/NEIGE` montre
  que tout accès à la RAM U105 (`$0000-$7FFF`) perturbe l'image, et non
  les entrées-sorties ni la RAM système ; la logique du schéma est juste :
  cause électrique, à chercher sur la carte.

## 15 nov. 2026 — La carte OSM39_mono fonctionne : les deux corrections

- La neige ne venait pas de la RAM U105 ni de la diaphonie (couper le
  tronçon d'A15 vers U302 n'a rien changé) : U106, validé par A15 à travers
  l'inverseur U101, décodait `$8000-$9FFF` une dizaine de ns au retour des
  cycles morts `$FFFF` vers `$0000-$1FFF` (`NEIGE` mode D : la même boucle
  en `$4000` est propre). Corrigé en qualifiant `/8000-9FFF` par E (U103).
  La V4 a le même décodage ; le fond de panier filtrait l'impulsion.
- La couleur en avance d'une case n'était pas une course de vitesse
  (échanger le 6845 n'a rien changé) : l'OE de l'EPROM de police sur
  `~LOAD`, plus le retard des 74HC157 du mode graphique. OE à la masse.
- Schéma KiCad corrigé (`483890c` du dépôt KiCad) ; circuit imprimé à
  reprendre.

## 15 nov. 2026 — Mode graphique de la mono essayé sur la carte

`tools/tele/essai_graphique.asm` (par TELE) : cadre, grille, diagonales,
cercle en 640 x 400, couleurs par case ; l'image de la carte est celle de
l'émulateur (modèle des 8 pages de VRAM). `tools/tele/tele.py` tolère les
faux réveils de `select` sur le port série (un autre programme qui lit le
même port, ici le terminal VT100, donne des échecs aléatoires).

## 18 nov. 2026 — Bascule sur la carte mono, la V4 archivée

- OSM39_mono fonctionne (corrections de la « neige » et du décalage de
  couleur, câblées) : `CARTE` passe à `mono` dans le dépôt, les 21
  vérificateurs sont verts en mono. La machine V4 (cartes CPU, CRT2,
  SD-KBD-SON) est archivée : ses branches `IFNE CARTE_MONO` restent et
  assemblent, son dernier état vérifié est l'étiquette `v4-archive`
  (= release v1.2 pour ses fichiers), plus rien ne la contrôle.
- La règle « un build v4 est identique octet pour octet au code d'avant
  la mono » est levée. `docs/memory-map.md` est relevé sur le BIOS mono.

## 18 nov. 2026 — Le « défaut de lwasm sur LDX/LDY indexés » n'existait pas

- `test/Makefile` gardait une cible `indexation` (script absent du dépôt,
  resté non suivi dans l'ancienne copie OSM39V2) et un commentaire disant
  que lwasm 4.24 émettait l'opcode étendu au lieu de l'indexé pour
  LDX/LDY/STX/STY (`AE 62` « au lieu de » `BE 62`). C'est l'inverse :
  `AE`/`10 AE` est la forme indexée, `BE`/`10 BE` l'étendue ; lwasm émet
  `10 AE 60` pour `LDY 0,S`, et l'exécution charge bien la pile. Cible
  et commentaire retirés.
- AGENTS.md décrivait l'octet d'indexation 5 bits comme « `$20+offset`,
  registre dans les bits 2-0 » : faux. Registre dans les bits 6-5 (X `$00`,
  Y `$20`, U `$40`, S `$60`), décalage dans les bits 4-0.

## 18 nov. 2026 — OSM-VISION ne se bloque plus sans AY

- La V4, rebranchée sans son AY-3-8910 (retiré), restait bloquée sur la
  flèche : la Clouris lisait le bus vide, des bits à 0, donc des doigts
  posés en permanence. `Clou_Lit` sonde l'AY à son premier appel
  (`Clou_Sonde` : `$05` puis `$0A` dans R1, relus, R1 rendu) ; sans puce,
  plus aucun contact.
- L'émulateur des vérificateurs relisait au registre de l'AY le numéro de
  registre écrit : il garde maintenant les 16 registres (largeurs de la
  puce), et `ay_present = False` simule la puce retirée.

## 20 nov. 2026 — Nouvel AY-3-8910 sur la mono, et premiers essais depuis le mini PC

- Carte SD de la mono écrite depuis le mini PC (lecteur USB) : la carte
  arrivait formatée en FAT32 avec une partition ; OSMFS veut le disque
  entier (`/dev/sdX`), secteur 0 vide avant `format_fs` (qui ne pose la
  signature `OSMF` que sur un secteur 0 nul). 81 fichiers relus à
  l'identique.
- TELE depuis le mini PC : ping, EPROM relue identique à `dist/`, BIOS2
  chargé. ~1 % des trames perdues, réessayées sans dommage.
- AY-3-8910 de remplacement (récupération, marqué Microchip) : `AYTEST`
  28/28, la voie B s'entend comme A et C. Par TELE, 1195 relectures : R9
  seul perd parfois un bit faible (5/91), inaudible. L'ancienne puce
  relisait toujours `00` dans R9.

## 20 nov. 2026 — Parasites en haut de l'écran en faisant défiler la liste d'OSM-VISION

- Mesuré sur la carte (`tools/tele/essai_cycles.asm`, par TELE) : fenêtre
  de retour de trame ~1990 cycles, IRQ du BIOS ~250 au repos, 1316 pendant
  un défilement du Terminal, 1792 à sa fin ; `TFM` = 6 + 3 n ; une case au
  `STD ,X++` = 12 cycles. L'estimation de `lib/vision.asm` (~2600) était
  trop haute.
- La liste d'OSM-VISION (`Draw_FileList`, `Draw_Names` par `Update_List`)
  écrivait 16 lignes case par case d'un coup : ~6200 cycles estimés. Sur
  la mono, les lignes sont composées en RAM (`DFL_Prepare`) puis copiées
  par `TFM` (`DFL_Copie`), budget vérifié avant chaque ligne (~1440 cycles
  par trame au plus). Écran identique case par case à l'ancien code sur 7
  suites de touches ; `verifie_bureau` mesure désormais le retard des
  écritures VRAM (contre-preuve : l'ancien code échoue à 6204).
- `verifie_dossiers` appelait `Draw_FileList` sans signal de trame : il y
  répond maintenant (`video_wait_vsync` rend la main tout de suite).
- `tools/tele/depose.py` effaçait l'ancien fichier AVANT de copier et
  relire le nouveau en RAM : une trame perdue pendant la relecture a
  laissé la carte sans OSMVISION (reposé aussitôt, relu secteur par
  secteur identique). Il copie et vérifie maintenant d'abord, et n'efface
  l'ancien que juste avant `FS_SaveFile`.
- Puis en entrant dans un dossier ou en en sortant (`Full_Redraw`) :
  `Draw_Window` (mono) vérifiait son budget APRÈS chaque rangée et ne
  comptait ni le bas, ni l'ombre, ni le filet du titre ; la liste se
  préparait dans la fenêtre de l'appelant déjà synchronisé (~6800 cycles
  estimés). `Mono_Budget` devient prédictif, `Draw_Window` compte toutes
  ses rangées, la liste se resynchronise après sa préparation. Écran
  identique case par case sur 13 parcours (une première version abîmait
  l'ombre des fenêtres : vue par cette comparaison, désormais vérifiée par
  `verifie_bureau`). Essayé sur la carte : « propre et rapide ».

## 20 nov. 2026 — Lot EPROM : accents de la console, PrintHexChar, effacement du Terminal

- La console du BIOS (SHELL, BBC BASIC, FORTH) affiche les accents
  Latin-1 en CP437 : `Con_Lat` (EPROM) au moment d'écrire la case, dans
  l'IRQ, plein écran et zone. Une première version traduisait dans
  `PrintChar` : é devenait `$82`, une des flèches `$80-$83` que l'IRQ
  interprète, et disparaissait (vu par `verifie_terminal`).
- `PrintHexChar` rend A (il gardait son chiffre bas) : contrat mis à jour.
- `Zone_IRQ` efface la dernière rangée par `TFM` (481 cycles au lieu de
  920 : la trame qui finit un défilement passait à ~200 cycles du bord de
  la fenêtre).
- EPROM et BIOS2 changent ensemble (somme de BIOS2 dans l'EPROM).

## 20 nov. 2026 — CALC et EDIT sans parasites : vis_Prep et vis_Ligne

- Signalé sur la carte : parasites en haut de l'écran dans CALC à chaque
  déplacement, dans EDIT en faisant défiler. `vis_Text` coûte ~32 cycles
  par caractère sur la mono : une ligne de 80 caractères (2716 cycles
  estimés dans EDIT, 4380 dans CALC avec la case surlignée) dépassait
  seule la fenêtre de retour de trame.
- Deux services ajoutés en fin de table (`lib/vis.inc`, VIS_COUNT 14) :
  `vis_Prep` compose la ligne en RAM hors synchronisation (plusieurs
  appels pour superposer la case courante ou le curseur), `vis_Ligne` la
  copie par TFM dans la trame, budget compté. `Sync_Begin` remet le
  budget à zéro. CALC et EDIT les emploient pour leurs lignes longues :
  ~1200 cycles estimés au pire, écrans identiques case par case sur six
  parcours ; `verifie_bureau` mesure CALC et EDIT.
- Reste : l'indicateur de chargement du BIOS (en haut à droite) écrit sans
  synchronisation pendant les longs transferts.

## 21 nov. 2026 — Lot EPROM : touches mortes ^ ¨, moulinet dessiné au retour de trame

- Touches mortes dans `keyboard.asm` : `^` et Maj+`^` (¨) attendent la
  touche suivante (â ê î ô û, ä ë ï ö ü ÿ, capitales ; espace = l'accent
  seul ; une autre touche = l'accent puis elle). Signalé : Noël se tapait
  en deux fois. La touche est au code `$53` dans les tables (et non `$54`,
  le code PS/2 habituel) : l'accent est reconnu par le caractère lu.
  `kbd_mort` et `kbd_suite` ajoutés à la fin de la BSS (rien ne bouge).
- Moulinet de chargement : `Fs_Spin` / `Fs_Spin_End` ne font plus que
  demander ; `Spin_IRQ` (début de `handler_IRQ`) écrit la VRAM au retour
  de trame. C'était la dernière écriture du BIOS hors trame pendant les
  longs transferts (parasites en haut de l'écran).
  `verifie_fs` simule l'IRQ pendant les transferts.
- EPROM et BIOS2 changent ensemble.
- Essai sur la carte : tout bon sauf les touches mortes (ê, ë donnaient
  e). `scan_keyboard` effaçait l'accent en attente en « jetant la file
  périmée » ; or `NEW_CODE` = 0 est l'état normal d'une file vide.
  Corrigé (le vérificateur attendait l'effacement : il exige maintenant
  ê) ; part au prochain flash.

## 21 nov. 2026 — Le mode graphique dans le BIOS (sys_Graphe)

- Banc sur la carte (`tools/tele/essai_graphe.asm`, par TELE) : l'image
  dessinée en RAM page 3, recopiée au retour de trame. Boucle un octet sur
  deux : ~1190 cycles par ligne de 640 points ; par TFM de paires
  point:$08 préparées hors fenêtre : 3 lignes = 1528 cycles, l'écran entier
  en 150 trames. Une première mesure TFM (7966) comptait la préparation :
  le drapeau de trame était resté levé. Un premier TFM écrivait 0 dans les
  octets impairs de $9000-$9FFF (page 0) : ce sont les couleurs des
  rangées 26-29, le bas de l'écran se remplissait ; $08 les cache.
- `bios/graphe.asm` (BIOS2), service `sys_Graphe` (le dernier emplacement
  libre sauf un), modèle `tools/graphe/graphe.py`, vérificateur
  `verifie_graphe.py`, démonstration `cmd/GRAPHE`, police `/BIN/POLICE8`.
- La bibliothèque (2144 octets) ne tenait pas dans BIOS2 : à la demande de
  l'utilisateur, renommer, attributs, dossiers, `SetLoad`, `ListRoot`,
  `Fs_WriteBlk`, `SD_WriteBlock`, la console du Terminal et le son sont
  revenus dans l'EPROM (253 octets libres ensuite) ; BIOS2 commence en
  `$CE80` (les variables du mode graphique allongent la BSS). En
  déplaçant `X_Audio`, `UPDATE_CURSOR` tombait dedans au lieu
  d'`AUDIO_UPDATE` : un `BRA` (vu par sept vérificateurs).
- `installe_bios` des vérificateurs lit `EXTV_N` dans `ext.inc` (il en
  recopiait 14 en dur).

- Essai sur la carte : GRAPHE marche ; ê et ë toujours « e ». La touche
  `^` de l'AZERTY envoie `$54` (le `[` du QWERTY), les tables la
  rangeaient à `$53` (aucune touche) : la touche morte n'était jamais
  armée, et `verifie_clavier.py` envoyait `$53` d'après la table. Les
  tables et le vérificateur passent à `$54`.
- Retour de GRAPHE dans le Terminal « en plein écran » : la zone restait,
  mais GR_FIN effaçait tout l'écran à la couleur du Terminal. Il l'efface
  en noir (`$08`) autour, puis la zone. Le test « console muette en mode
  graphique » de `verifie_graphe.py` appelait `PrintChar`, que
  `MachineAsm` intercepte : il ne prouvait rien ; il passe par `PUTCHARV`.
- Essai suivant : ê et ë marchent ; au retour de GRAPHE, ni le fond ni le
  cadre du Terminal (l'image a écrasé l'écran texte ; aucune place pour le
  garder). `GR_FIN` pose `ecran_abime` ; OSM-VISION passe au SHELL (U)
  `Term_Redessine`, que le SHELL appelle après une commande qui l'a posé.
  Prouvé par `verifie_bureau.py` (un programme de 6 octets pose le
  drapeau) et `verifie_graphe.py` (GR_FIN dans une zone le pose).
- BBC BASIC : `MODE 0` (1, 2, 4, 5) passe au mode graphique du BIOS
  (`sys_Graphe`) : PLOT/MOVE/DRAW/POINT, cercles `PLOT 144-159`, texte par
  `GR_CAR`, curseur en OU EXCLUSIF. Les triangles pleins (aussi en
  mosaïques) sont remplis rangée par rangée : l'éventail d'avant
  (une ligne du sommet vers chaque point du côté opposé) laissait des
  trous et repassait sur les mêmes points (GCOL 3 faux). ~970 octets :
  BASE `$2D00` -> `$2900` (BBCBASIC, 8 Ko de programmes), `$3600` ->
  `$3200` (BBCPLUS, 10 Ko). Un premier essai colorait la case de chaque
  caractère : GR_COULEUR attend la fin du précédent (une trame par
  caractère), et le banc sans IRQ s'y bloquait.
- OSM City, étape 1 (`apps/osmcity.asm`, `tools/osmcity/osmcity.py`,
  `verifie_osmcity.py`) : la carte du centre d'Annonay tirée
  d'OpenStreetMap (téléchargée avec l'accord de l'utilisateur), une
  voiture qui roule, la ville qui défile par l'adresse de départ du 6845.
  Mode texte choisi (le graphique recopie 3 lignes par trame). La police
  n'a pas de ☺ ni de CP437 en `$01-$1F` : voitures ▲►▼◄ de la page 1,
  piétons plus tard. Une table « 80 dy » fausse (`0,80,0,-80`) rendait la
  case quittée une rangée trop bas : vu par les photos du vérificateur.
- OSM City, étape 2 : sur la carte, la vue de l'étape 1 était « vue de
  trop haut » ; l'utilisateur veut un dessin à la GLOUTON. Vue deux fois
  plus fine (512 x 255 cases, carte de 64 Ko en pages 2-3, anneau de 32
  rangées en page 1), tuiles choisies par la sorte et les 4 voisines,
  dessinées dans une nouvelle banque de police : la police passe à un
  28C256 (4 banques par $A120 D4-D5, accord de l'utilisateur ; composant
  à trouver). Une carte de 65 536 octets pile : FS_LoadFile la refuse
  (taille sur 16 bits) -> 255 rangées. Une rangée de 80 tuiles calculées
  une à une prenait 2-3 trames ; décodée d'abord (3 rangées de sortes),
  presque toujours une.
- OSM City : le nom des rues (demande de l'utilisateur, qui reconnaît les
  rues) : une plaque bleue en rangée 29, la rue du bloc de 4 x 4 cases de
  la voiture (OSMCITY.RUE). L'utilisateur a aussi vu que tout est à plat
  (on passe de la rue de Riboulon au pont Montgolfier qui l'enjambe) :
  les ponts à deux niveaux viennent ensuite.
- OSM City, ponts à deux niveaux : la voiture a un étage ; on ne monte sur
  un tablier que par une rampe et on n'en descend que par elle ; une rue
  qui passe sous un pont se traverse (voiture cachée). Les ponts viennent
  des voies bridge=yes : la règle d'avant (route au-dessus de l'eau =
  pont) aurait bloqué les rues qui longent une berge.
- OSM City : coins arrondis (l'utilisateur a choisi l'arrondi plutôt que
  le biais, aperçus comparés) ; TALUS : on montait sur le pont Montgolfier
  depuis la rue de Riboulon par la pelouse. Le saut de la place de Backnang
  à la rue Maurice-Chomel : aucun mur dans OpenStreetMap à cet endroit
  (murs.json : 12 murs en tout) ; piste : le relief de l'IGN.
- OSM City : relief de l'IGN (accord de l'utilisateur) ; les pentes
  d'herbe de plus de 70 % et 2 m deviennent FALAISE : la place de Backnang
  ne mène plus d'un saut à la rue Maurice-Chomel (9 m de marche dans une
  pelouse), il faut passer par le carrefour.
- OSM City : sans bordures de rue ni de trottoir (les coins arrondis les
  coupaient en petits traits) ; les jardins (VIDE) arrêtent la voiture
  (rue Melchior-de-Vogüé : des pelouses derrière des murs).
- OSM City : 8 directions (deux flèches), deux avances, glissade le long
  d'un mur en biais. La règle des tuiles en une seule routine (Calc_Case)
  pour les cases, les rangées et les colonnes ; colonnes décodées droit
  dans l'anneau (186 pas de 2 trames sur 1484 en biais avant, 45 après).
- OSM City : sortir de la voiture (Espace), marcher, prendre une voiture
  garée (31 au départ). Un piège : Tuile appelait Garee_Case avec X
  détruit par Calc_Case : la voiture qu'on venait de quitter s'affichait
  comme de la chaussée (vu par les photos du vérificateur).
- Essai sur la carte : le piéton semblait ne pas monter ni descendre (son
  premier pas vertical venait après 32 trames, l'avance repartant de 0) :
  le premier pas est maintenant immédiat. Espace en roulant arrête net la
  voiture et fait sortir (demande de l'utilisateur, pour se garer).
- OSM City : la circulation et les passants (8 + 8 autour du joueur). Le
  6309 ne connaît que les rangées de l'anneau : des voitures apparues à
  20 rangées lisaient une rangée périmée (une rue là où le modèle voyait
  un bâtiment) : la circulation vit maintenant dans l'anneau. Une voiture
  passait sur la plaque du nom de rue. Mesuré (profil par routine) : une
  rangée coûtait ~8900 instructions (plus d'une trame) depuis Calc_Case ;
  raccourci des cases sans voisine différente.
- OSM City : le son sur l'AY (moteur, klaxon K, pas, portière, choc),
  comparé registre par registre au modèle à chaque trame.
- OSM City : le cache-cache (butin, planque, deux voitures de police).
  Pièges vus par le vérificateur : la police coincée dans un cul-de-sac
  (elle refaisait le même pas : plus de demi-tour sauf s'il est seul, un
  pas au hasard quand rien ne rapproche) ; la circulation qui tournait
  pendant la trame de relance (le joueur volait aussitôt : `Fige`) ; la
  plaque d'une trame en retard quand c'est la police qui change l'étape ;
  le butin et la planque sur la même case dessinés dans un ordre différent
  par les rangées et par Garee_Case ; une voiture de police qui chevauchait
  le joueur effaçait sa case en repartant.
- OSM City, essai sur la carte : la police arrivait dès le vol (elle
  apparaissait juste hors de l'écran, comme la circulation). Elle part
  maintenant de devant la mairie et voyage sans carte hors de la zone
  connue. La séance du pont a changé de graine (35) : le hasard de la
  circulation n'est plus le même.
- OSM City : la circulation conduit (remarque de l'utilisateur : « des
  fourmis ») : tourner aux carrefours seulement, serrer à droite, attendre
  derrière une voiture, demi-tour seulement au bout d'une impasse ; les
  voitures se garent sur les places (et peuvent être prises). Pas de sens
  uniques (choix de l'utilisateur, la mémoire manque). Graine du pont : 27
  (graines essayées sur la vraie séance, le modèle approché ne suffit pas).

## 21 nov. 2026 — OSM City : plus de glissade de côté ni de voiture bloquée

- « Serrer à droite » faisait un pas de côté en gardant le glyphe de la
  direction : sur la machine, des voitures roulaient de travers,
  perpendiculaires à la voie. C'est maintenant un pas en biais
  avant-droite, et seulement dans une rue étroite (sinon, sur une place
  large, les voitures la traversaient en biais et tournaient en rond).
- Une voiture derrière une autre attendait indéfiniment (deux voitures
  face à face, une voiture garée sur la chaussée) : elle double en biais
  après `ATT_DOUBLE` pas, fait demi-tour après `ATT_DEMI` ; coincée
  au-delà de `ATT_FIN`, elle se gare (sur une place) ou disparaît hors de
  l'écran.
- Une voiture apparaissait dans une direction tirée au hasard, parfois en
  travers de la rue : elle apparaît maintenant dans le sens de la rue.
- Graine de la séance du pont du vérificateur : 27 -> 41.

## 21 nov. 2026 — OSM3D : Annonay en 3D (première étape, à pied)

- Nouveau jeu séparé (la page 1 d'OSM City est pleine) : lancer de
  rayons sur la carte d'OSM City, mini-carte encadrée, plaque de la rue.
  Le prototype en virgule flottante (`tools/osm3d/apercu.py`, jardins en
  haies de 1,8 m puis 1 m) a été remplacé par le modèle exact
  `tools/osm3d/osm3d.py` ; les jardins (VIDE) sont restés à plat.
- Premier rendu : 86 000 instructions par image ; ramené à ~45 000 (sol
  peint aux seuls changements de couleur, plages de cellules unies,
  tables de quartets, indice des hauteurs = mot haut de MULD). Un bogue
  trouvé par le vérificateur : la distance d'un pas en y prenait SideX.

## 22 nov. 2026 — OSM3D : rotation par pas, carte faite pour la 3D

- Essai sur la machine : un appui sur une flèche de côté tournait d'un
  quart de tour, et parfois la rotation ne s'arrêtait plus. Deux causes :
  la rotation était proportionnelle au temps (8/1024 par trame, 8 trames
  au plus par image), et le clavier n'était lu qu'entre deux images ;
  pendant une image longue, la répétition automatique d'une flèche tenue
  remplissait la file de 16 octets de la NMI, qui perd alors les octets
  suivants : le relâchement se perdait, la touche restait tenue.
  Maintenant `Irq_3D` lit le clavier à chaque trame, et chaque appui (ou
  répétition) de gauche/droite tourne d'un pas de 16/1024 (5,6°).
  Le vérificateur simule la répétition (et la file qui perd des octets
  quand elle est pleine, comme la NMI). Note : le scénario « flèche
  tenue puis lâchée » passe aussi sur l'ancien binaire dans l'émulateur
  (le débordement n'y est pas reproduit) ; ce qui est prouvé, c'est
  qu'aucun octet n'est perdu avec la lecture par l'IRQ.
- Rues trop étroites et façades en escalier en 3D : OSM3D a sa carte,
  `OSM3D.MAP` (`osm3d.carte()`) : voies 1,5 fois plus larges, trottoir
  de 2,5 m pris sur le bâti, puis le bâti lissé (`lisse()`). La carte
  d'OSM City n'a pas changé (vérifié octet pour octet). Coût : 6,8
  trames par image en moyenne au lieu de 5,4 (plus de sol à peindre).
- Même jour, après essai : la rotation par pas convient (Haut tenu,
  appuis brefs sur les côtés). Une flèche de côté TENUE ne dépend plus de
  la répétition du clavier (qui ne répète que la dernière touche
  enfoncée) : `Rep_Tourne`, dans l'IRQ, fait un pas 20 trames après
  l'appui puis toutes les 6. Les rues sont tirées au cordeau
  (`osmcity.simplifie()`, Douglas-Peucker à 8 m entre les carrefours,
  qui restent en place ; des angles imposés tous les 30° auraient
  déplacé les carrefours). Le plan montre les trottoirs en blanc.
- Puis retour en arrière : sur la machine, avec `Rep_Tourne`, un appui
  bref faisait tourner sans fin (le relâchement de la flèche n'était
  donc pas vu ; dans l'émulateur il l'est : cause inconnue). Retour à un
  pas par code d'appui (répétitions du clavier comprises), qui ne dépend
  pas du relâchement ; `TOURNE_MAX` 8.

## 24 nov. 2026 — OSM3D : immeubles de 16 m, couleurs, vieille ville, chaussée grise

- Après les photos Street View de l'utilisateur (dans `tools/osm3d/`) :
  murs de 16 m au lieu de 10 (immeubles de 4-6 étages), façades
  surtout blanches (gris pierre à l'ombre), un peu de jaune (ocre) et de
  rouge (brique), plus de magenta.
- La vieille ville gardait des rues de 7 m élargies de moitié (la rue du
  Docteur Barry fait 1,8 m, classée « residential » sans largeur dans
  OSM) : seules les routes principales sont élargies, avec trottoir ; les
  petites rues cèdent au bâti, seul leur axe reste route.
- Chaussée grise, trottoir et bordure (`BORDURE`) blancs, parking noir ;
  les allées de parking tracées en parking (le Champ de Mars était
  recouvert de routes élargies) ; les zones piétonnes en `PIETON` (la
  place des Cordeliers était noire, tracée comme un parking).
- Essayés dans le modèle et abandonnés : tirets du milieu et lignes de
  stop en cases entières (un pavé de 5 x 6 m de près, rien au loin).
  Prototype des bords de chaussée en vraies lignes (projetées, cachées
  par les murs) : `tools/osm3d/essais/lignes.py`, pas encore dans le
  moteur (5508 segments, ~44 Ko : à mettre en tuiles sur la carte SD).
- Rien dans le code 6309 : hauteur, couleurs et sortes passent par les
  tables générées (`--inc`) et la carte.
- Même soir, sur la machine : chaussée grise et faces à l'ombre des
  immeubles blancs avaient le même gris (la machine n'en a qu'un) :
  chaussée remise en noir, parking en gris.
- Les ponts : on passait de l'avenue Simone Veil au tablier du pont
  Valgelas (et à la rue Montgolfier) : OSM3D ignorait les étages d'OSM
  City, et la carte posait des rampes sur toute rue proche d'un bout de
  pont, y compris l'avenue qui passe dessous. Étages repris (`Passe`),
  rampes seulement sur les voies raccordées au pont (`RACCORDS`), et les
  tabliers dessinés en bande grise au-dessus de la rue quand on est au
  sol. Le vérificateur passe sous le pont Valgelas et monte par sa rampe.

## 25 nov. 2026 — OSM3D : ponts refaits, arche, fenêtres, ciel cyan

- Sur la machine, la version « étages » laissait encore passer de
  l'avenue Simone Veil à la rue Montgolfier : la carte est plate, les
  rampes touchaient la rue du dessous ; le pont n'était qu'une bande grise
  flottante. Le pâté de cases d'OSM City (12 m de biais) donnait un mur.
- Les ponts sont refaits d'après les voies OSM (`ponts()`) ; un passage
  dessous seulement pour une voie qui croise l'axe du pont (le Valgelas
  n'enjambe que la Deûme) ; culées, remblais pleins, muret bas entre la
  rue du dessous et celle qui monte ; l'arche (pied 3 m, clé 5 m) d'après
  la place de chaque case dans la portée. Essayés et abandonnés : la
  dalle plate sur deux piles, l'arrondi calculé à l'écran (dépendait de
  l'angle de vue), la demi-ellipse continue (le 6309 n'a que des cases).
- Après un dessin de l'utilisateur (`tools/osm3d/dessin.py`, nouveau) :
  ciel cyan (l'eau garde le bleu), immeubles atténués (ocre, brique,
  crépi), fenêtres sur les faces à l'ombre, parapet blanc.
- PARC et TALUS fondus dans VIDE dans OSM3D (mêmes vert et marche) : leurs
  numéros servent au pied de l'arche. `osm3d.passe` suit maintenant le
  6309 (l'herbe se traverse) ; le modèle utilisait `osmcity.passe`, qui
  bloque l'herbe : les vérifications de passage étaient trop optimistes.
- `Cel_Mini` prenait toujours p5 comme fond : faux dès qu'une couleur
  atténuée (le gris des ponts) est sur le plan ; même règle que le modèle.
- Le vérificateur passe sous le pont Montgolfier (avenue Simone Veil) et
  monte par sa rampe nord-est.
- Neige en mode graphique mesurée par webcam (`tools/tele/essai_neige_gr`) :
  écrire la VRAM pendant l'affichage détruit l'image (BLANK remis à zéro
  par ~VCRAM-SELECT) ; piste d'une RAM double port pour une révision de
  la carte.
- Reste : la carte n'a pas de relief ; la rue Montgolfier monte en pente
  vers le pont et, de la place de la Liberté ou des Cordeliers, on bute
  contre lui (signalé par l'utilisateur sur la machine).

## 26 nov. 2026 — Mode graphique : une couleur par ligne de 8 points

- En mode graphique la couleur venait de la RAM des couleurs (U512)
  adressée par `sa11` et les bits de page : une couleur par case 8 x 16.
  La conversion V4 -> mono n'avait relié RA (par U514) qu'à la RAM des
  caractères. L'utilisateur a corrigé le schéma (4 fils : U512 A11-A14
  sur `RA11`-`RA14`) : une couleur par ligne de 8 points, l'octet qui
  suit celui des points ; le texte ne change pas.
- Le BIOS (`bios/graphe.asm`) suit : chaque case est écrite dans ses 16
  lignes ; les points sont recopiés un octet sur deux (les paires
  point:`$08` effaceraient les couleurs) : une ligne par trame au lieu
  de 3 (image entière ~6,7 s au lieu de 2,5) ; l'effacement devient une
  tâche de remplissage par TFM (paires (0, couleur), ~2,3 s) ; R6 = 25 en
  mode graphique (les rangées 26-29 répéteraient le haut, couleurs
  comprises, et `$08` ne les cache plus). BIOS2 : 2821 octets (6 de moins).
- `AGENTS.md` disait que les octets impairs des pages 1-7 n'étaient pas
  affichés et qu'il fallait garder `$08` en `$9000-$9FFF` : vrai pour
  l'ancien câblage seulement.

## 26 nov. 2026 — Liste du matériel en suspens ; l'horloge marche

- `docs/materiel-en-suspens.md` rassemble les problèmes matériels connus
  (74HC165 de la carte SD chargé en lecture, PCB à router, défauts
  d'affichage, neige, R9 de l'AY, police 28C256, joystick).
- L'horloge : le MC146818 de récupération ne battait pas ; des MC146818
  neufs marchent très bien (l'utilisateur). `AGENTS.md` le disait « non
  prouvé ».

## 27 nov. 2026 — La couleur 8 x 1 vérifiée sur la carte

- Les 4 fils de U512 soudés. `cmd/GRAPHE` propre mais identique à avant (le
  BIOS ne met qu'une couleur par case) : la mire `tools/tele/essai_8x1.asm`
  (par TELE) met une couleur différente sur chaque ligne des rangées 0-11
  et une par case en dessous ; la carte montre exactement l'aperçu calculé
  sur le PC.

## 27 nov. 2026 — Couleur 8 x 1 : diagnostic, la carte est bonne

- Sur des lignes d'un point de 16 couleurs (`tools/tele/essai_16.asm`),
  l'utilisateur ne voyait que noir, cyan, rouge et blanc ; 8 couleurs en
  bandes de 4 points. Mesures au multimètre des 4 fils de U512 : bonnes.
- Banc par TELE + webcam en gros plan (`tools/tele/essai_mire.asm`, mire
  de télévision tirée de `tools/tele/mire_tv.py`, pour la mise au point) :
  le moniteur rend les rayures horizontales d'une ligne en noir et blanc.
  `tools/tele/essai_bits.asm` : chaque ligne d'adresse `RA11`-`RA14`
  alterne à la bonne période (1, 2, 4, 8 lignes) et chaque bit de couleur
  D0-D3 change d'une ligne à l'autre.
- Conclusion : la carte est bonne ; des lignes d'un point de couleurs
  différentes se mélangent à l'œil (mise à l'échelle de l'écran plat,
  atténuées collées aux vives). Pour le rendu : des aplats de 2 à 4 lignes.
