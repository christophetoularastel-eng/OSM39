# Cartographie mémoire OSM39

Ce document décrit l'espace d'adressage **tel que le code l'utilise
aujourd'hui** (relevé le 13 nov. 2026, BIOS en deux parties, carte `v4`).
C'est la seule carte mémoire du projet : après un changement de `ram.asm`
ou du lien, reconstruire puis mettre ce document à jour. Les anciennes
descriptions (noyau en `$D000`, « paged buffer », moniteur au démarrage,
champ page jamais écrit…) sont dans `docs/historique.md`.

## Source de vérité

Chaque adresse se vérifie en une commande ; ce document est une aide à la
lecture, les fichiers ci-dessous font foi.

| Ce que vous cherchez | Où c'est vrai |
|---|---|
| Adresses des globales BSS | `bios/hardware.inc` (généré, ne pas éditer) |
| Offsets des services BIOS | `bios/sysfunc.inc` (généré, ne pas éditer) |
| Contrat des services (registres) | `docs/services.md` (généré par `test/verifie_contrat.py --doc`) |
| Sections et symboles du lien | `bios/osm39.map` (artefact de build) |
| Place libre EPROM et BIOS2 | `make -C bios` (dernières lignes) |
| Adresses matérielles | `bios/hardware.inc` ; vidéo : `video/carto.txt` |
| Vecteurs, pile, tas | `bios/vectors.asm` |
| Bornes de BIOS2 | `EXT_BASE`, `EXT_FIN` dans `bios/Makefile` |

```sh
grep -E "^Section:" bios/osm39.map            # modules, EPROM et BIOS2
grep "(ram.o)" bios/osm39.map | sort -k5      # la BSS, dans l'ordre
```

## 1. Vue d'ensemble

```text
$0000 ┌──────────────────────────────────────┐
      │  Fenêtre RAM paginée, 32 Ko          │  page 0-3 choisie par $A0C0
$7FFF └──────────────────────────────────────┘
$8000 ┌──────────────────────────────────────┐
      │  RAM vidéo, 8 Ko visibles            │  page vidéo 0-7 par $A120
      │  v4 : caractères $8000, couleurs $9000│
      │  mono : cellule c = $8000+2c, +1     │
$9FFF └──────────────────────────────────────┘
$A000 ┌──────────────────────────────────────┐
      │  Périphériques                       │  §4
$A1FF └──────────────────────────────────────┘
$A200   (rien de câblé jusqu'à $BFFF)
$C000 ┌──────────────────────────────────────┐
      │  BSS système    $C000-$CC6C          │  table des services, variables
      │  Tas système    $CC6D-$CD6C          │  256 octets (le SHELL)
      │  (libre)        $CD6D-$CDFF          │
      │  BIOS2          $CE00-$D9FF          │  chargé de /BIN/BIOS2 (§5.3)
      │  Pile           $DA00-$DFEF          │  vers le bas depuis $DFEF
$DFF0 │  Vecteurs RAM (.ram_vectors)         │  14 octets
$DFFF └──────────────────────────────────────┘
$E000 ┌──────────────────────────────────────┐
      │  BIOS en EPROM (.code)               │  §6
$FFE0 │  Table de sauts fixe (.romjmp)       │  FAR_CALL, FAR_CALLN
$FFF0 │  Vecteurs matériels (.vectors)       │  16 octets
$FFFF └──────────────────────────────────────┘
```

## 2. `$0000–$7FFF` — fenêtre RAM paginée (32 Ko)

**4 pages de 32 Ko, 128 Ko de RAM utilisateur** (U105). C'est une donnée
de la carte : aucun code n'en déduit le nombre, mais `FAR_CALL`,
`FS_LoadFile` et `FS_SaveFile` refusent une page au-delà de 3.

| Page | Occupant |
|---:|---|
| 0 | OSM-VISION (`$0000`, chargé au démarrage) ; le SHELL du Terminal en `$6000` à côté de lui |
| 1 | le programme lancé : commande console (`cmd/*`, ASM, FORTH, BBC BASIC, BASIC en `$5A00`) ou application d'OSM-VISION (attribut `a`, liée à `$0000`, appelée par `FAR_CALL`) |
| 2-3 | données : texte d'EDIT (2-3), cellules de CALC (3), binaire produit par ASM (2), Copier/Coller d'OSM-VISION (2-3), modules de PONT (2, 3), jeu de ZMACHINE (2-3), canaux de fichiers du BBC BASIC (n+1) |

- **Latch `$A0C0`** (`pager_reg`), écriture seule : il choisit la page vue
  en `$0000-$7FFF`. `current_page` (`$C4C1`) en est le miroir logiciel :
  le BIOS le remet à 0 au démarrage, `sys_pager` et `FAR_CALL` l'écrivent.
  Aucun registre de propriété des pages : rien ne dit quel programme
  occupe quelle page.
- Le BIOS change de page quand il doit toucher une autre page
  (`FarRead`/`FarWrite`, `FS_LoadFile`/`FS_SaveFile` vers une autre page,
  `FAR_CALL`) et **rend la page de l'appelant** avant de revenir.
- **Page et adresse de chargement** : octets `+24` (page) et `+25` (adresse)
  de l'entrée OSMFS. Le chargeur (OSM-VISION, SHELL) les prend dans
  l'entrée. Ils sont écrits par `egofs_deploy.py` (d'après
  `dist/manifest.txt`), par `FS_SetLoad` (ASM, `depose.py`) et conservés
  par le Copier/Coller d'OSM-VISION. `deploy_sd.sh` refuse une page 0 sous
  `$4000` (elle écraserait OSM-VISION).
- **Fichiers sur deux pages** : `FS_LoadFile`/`FS_SaveFile` passent de
  `$7FFF` à `$0000` de la page suivante (64 Ko au plus, jamais au-delà de
  la page 3). Une adresse `>= $8000` est copiée directement.
- **Pile d'un programme dans sa page** (BBC BASIC : `$01xx` de la page 1) :
  un service qui change de page (`FarRead`, `FarWrite`, `FS_LoadFile`
  vers une autre page) doit être appelé sur la pile système, sinon il relit
  son propre cadre dans la mauvaise page.

## 3. `$8000–$9FFF` — RAM vidéo

Deux RAM vidéo de 32 Ko (caractères, couleurs) lues ensemble par le
68B45. `$A120` (`VRAM_CTRL`, 74HC374, écriture seule) : D0-D2 = page vidéo
0-7 (8 × 4 Ko par RAM) ; en `mono`, D3 = GRAPH (garder 0) ; D4-D7 ignorés.
`video/carto.txt` est la référence matérielle.

**Carte `v4`** (`CARTE` = `v4`, CRT2 modifiée le 10 oct. 2026) : U126 A0
sur a12, le CPU voit les deux RAM à la fois.

| Adresses | Contenu | Constantes |
|---|---|---|
| `$8000–$8FFF` | caractères, une cellule par octet | `VRAM_BASE`..`VRAM_END` |
| `$9000–$9FFF` | couleurs, même cellule + `$1000` | `VRAM_COL`..`VRAM_COL_END`, `VRAM_COL_OFS` |

**Carte `mono`** (OSM39_mono) : VRAM **entrelacée**, la cellule c a son
caractère en `$8000+2c` et sa couleur en `$8001+2c` (A0 du CPU choisit la
RAM). `VRAM_PAS` = 2, `VRAM_LIGNE` = 160, `VRAM_COL_OFS` = 1. Le 6845
compte toujours en cellules : les décalages CPU sont divisés par 2 avant
R12-R15.

Les boucles « tout le plan » utilisent `VRAM_COL`/`VRAM_COL_END` avec le
pas `VRAM_PAS` : jamais `VRAM_END-VRAM_BASE` octets depuis `VRAM_COL`, qui
déborde dans `$A000` en `mono`.

- Écran 80 × 30 rangées de 8 × 16 points (VGA 640 × 480) ; le logiciel
  gère surtout 80 × 25, la console du BIOS défile sur 30.
- Un accès CPU perturbe l'image : écrire pendant le retour de trame, IRQ
  masquées (le gestionnaire VSYNC vide 8 caractères de `ASCII_BUF` /
  `COLOR_BUF` par trame).
- Octet de couleur : D0-D2 couleur du caractère (D0 bleu, D1 vert, D2
  rouge), D3 l'atténue, D4-D6 fond, D7 page de la police (0 alphabet,
  1 graphismes). Ni clignotement ni inversion sur CRT2.

## 4. `$A000–$A1FF` — périphériques

Symboles dans `bios/hardware.inc`.

| Adresse | Symbole | Périphérique |
|---|---|---|
| `$A000` | `CR_reg`, `SR` | ACIA 68B50 RS232 — contrôle / statut (NMI à la réception) |
| `$A001` | `TDR`, `RDR` | ACIA RS232 — émission / réception |
| `$A040` | `PIADRA`, `DDRA` | PIA 6821 port A — bus AD0-7 de l'horloge MC146818 |
| `$A041` | `PIADRB`, `DDRB` | PIA port B — PB0 = DS, PB1 = R/W de l'horloge |
| `$A042` | `CRA` | PIA contrôle A — CA2 = AS de l'horloge (`$34`) |
| `$A043` | `CRB` | PIA contrôle B |
| `$A080` | `CR1`, `CR3` | 68B40 — contrôle 1 et 3 |
| `$A081` | `CR2`, `STATUS` | 68B40 — contrôle 2 et statut |
| `$A082` | `TIMER1` | 68B40 timer 1 (VSYNC sur C1 : IRQ 60 Hz) |
| `$A084` | `TIMER2` | 68B40 timer 2 (son, voie 1 ; sortie O2) |
| `$A086` | `TIMER3` | 68B40 timer 3 (son, voie 2 ; horloge des échantillons de PAROLE) |
| `$A0C0` | `pager_reg` | latch de page RAM (§2), écriture seule |
| `$A100` | `CRTC_RS` | 68B45 — sélection de registre |
| `$A101` | `CRTC_DATA` | 68B45 — données |
| `$A120` | `VRAM_CTRL` | 74HC374 — page vidéo D0-D2 (§3) |
| `$A140` | `SD_CTRL` | carte SD-KBD-SON : latch SPI (écriture) — bit 0 /CS, bit 1 rapide ; copie dans `sd_ctrl` |
| `$A148` | `SD_DATA` | SPI — écrire envoie ; lire rend l'octet du transfert précédent ET le renvoie (mesuré) |
| `$A150` | `AY_ADR` | AY-3-8910 — écrire choisit le registre, lire le relit |
| `$A151` | `AY_DATA` | AY-3-8910 — écrire le registre choisi |
| `$A180` | `CR_key`, `SR_key` | ACIA clavier PS/2 (SD-KBD-SON) — contrôle / statut |
| `$A181` | `TDR_key`, `RDR_key` | ACIA clavier — données (dans les deux sens : voyants) |

- Les deux ACIA partagent la NMI (`handler_NMI` les sert jusqu'à ce
  qu'aucune n'ait d'octet). L'ACIA de la carte CPU en `$A1C0` n'est plus
  utilisée.
- Les IRQ du PIA vont à la FIRQ, dont le gestionnaire est un simple `RTI`.

## 5. `$C000–$DFFF` — RAM système (8 Ko, U102)

### 5.1 BSS — `$C000–$CC6C` (3181 octets)

`section .bss` à `$C000`, mise à zéro au démarrage à froid (pas au
redémarrage après un TRAP). Source : `bios/ram.asm`. Un programme prend
ces adresses dans `hardware.inc`, jamais en dur.

| Plage | Taille | Contenu |
|---|---:|---|
| `$C000–$C05B` | 92 | `table_function_ram` — 46 services (`sys_FS_RenameFile` … `sys_Console_Zone`), remplie au démarrage depuis `table_function_rom` |
| `$C05C–$C05F` | 4 | `table_reserve` — 2 emplacements libres (`Sys_Absent` : C = 1). Table de **96 octets fixes** (`TABLE_OCTETS`) |
| `$C060–$C062` | 3 | clavier brut : `SCAN_CODE`, `NEW_CODE`, `key_on` |
| `$C063–$C162` | 256 | `load_buffer` (Intel hex de `LOAD`) |
| `$C163–$C182` | 32 | `write_buffer` |
| `$C183–$C186` | 4 | `read_load_ptr`, `write_load_ptr` |
| `$C187–$C206` | 128 | `input_buffer` — saisie de ligne |
| `$C207–$C20A` | 4 | `read_line_ptr`, `write_line_ptr` |
| `$C20B–$C21A` | 16 | `buffer` (réponses SD, divers) |
| `$C21B` | 1 | `sd_ctrl` — copie de `SD_CTRL` |
| `$C21C–$C41B` | 512 | `SD_BUFFER` — un secteur |
| `$C41C–$C41F` | 4 | `BlockAddr` — LBA du secteur (BE) |
| `$C420` | 1 | `SDHC_Flag` |
| `$C421–$C430` | 16 | `CSD_BUFFER` |
| `$C431–$C43C` | 12 | `CMD17_Packet`, `CMD24_Packet` |
| `$C43D–$C45C` | 32 | `g_find_fileInfo` — copie de l'entrée trouvée (`+30` : son numéro + 1) |
| `$C45D–$C471` | 21 | contexte de lecture : `s_find_currentSector` … `s_file_destPtr` |
| `$C472–$C481` | 16 | `ExeFileNameBuffer` |
| `$C482–$C491` | 16 | `FormattedName` |
| `$C492–$C4A7` | 22 | contexte d'écriture : `s_save_fileNamePtr` … `s_save_dirEntryOffset` |
| `$C4A8–$C4AB` | 4 | décodage PS/2 : `e0_received`, `last_makecode`, `PS2_BIT_COUNT`, `PS2_PARITY` |
| `$C4AC–$C4BF` | 20 | `argv` |
| `$C4C0` | 1 | `argc` |
| `$C4C1` | 1 | `current_page` (§2) |
| `$C4C2–$C4C3` | 2 | `vsync_tick` |
| `$C4C4–$C4CA` | 7 | console : `BUF_HEAD`, `BUF_TAIL`, `VRAM_PTR`, `CUR_PAGE`, `vram_line_ptr` |
| `$C4CB–$C5CA` | 256 | `ASCII_BUF` — caractères en attente de la VSYNC |
| `$C5CB–$C6CA` | 256 | `COLOR_BUF` — leurs attributs |
| `$C6CB–$C6CC` | 2 | `SCREEN_START_OFFSET` |
| `$C6CD–$C6CF` | 3 | `MUSIC_PTR` (0 = rien ne joue ; = `SND_PTR` des applications), `MUSIC_TIMER` |
| `$C6D0` | 1 | `char_attribut` — attribut de la console |
| `$C6D1–$C6F0` | 32 | `trap_frame` — cadre 6309 du dernier TRAP |
| `$C6F1–$C7F0` | 256 | `far_transit_buffer` — relais de `FarRead`/`FarWrite` |
| `$C7F1` | 1 | `trap_active` — garde contre un TRAP dans le TRAP |
| `$C7F2–$C871` | 128 | `SND_BUF` — partition copiée par `snd_play` |
| `$C872–$C878` | 7 | moulinet des transferts SD : `spin_cnt`, `spin_on`, `spin_save`, `spin_dir` |
| `$C879` | 1 | `sd_err` — dernière erreur SD (`$E1`-`$E5`), 0 = aucune |
| `$C87A` | 1 | `sd_retry` — relectures depuis le démarrage (plafond 255) |
| `$C87B–$C882` | 8 | dossiers : `fs_dossier` (2, courant), `fs_cible` (2), `fs_explicite`, `fs_repli`, `fs_attr_neuf`, `fs_slot_suiv` |
| `$C883–$C8D2` | 80 | `fs_slots` — 4 × 20 : tampon formaté avec chemin (adresse, page, dossier, nom) |
| `$C8D3–$C8E8` | 22 | résolution des chemins : `fr_fin`, `fr_dos`, `fr_nom15`, `fs_tmp` |
| `$C8E9` | 1 | `boot_chaud` — <> 0 : redémarrage après un TRAP |
| `$C8EA–$C909` | 32 | `trap_info` — état au dernier TRAP (`MONITEUR R`) ; survit au redémarrage à chaud |
| `$C90A` | 1 | `sd_absente` — <> 0 : pas de carte au démarrage |
| `$C90B` | 1 | `son_coupe` — `$4D` : son coupé (touche M d'OSM-VISION) |
| `$C90C` | 1 | `serie_brute` — <> 0 : liaison série en mode brut |
| `$C90D` | 1 | `serie_tete` — écrit par la NMI seule |
| `$C90E` | 1 | `serie_queue` — écrit par le programme seul |
| `$C90F–$CA0E` | 256 | `serie_buf` — anneau du mode brut |
| `$CA0F–$CA1E` | 16 | `kbd_buf` — file des octets PS/2 |
| `$CA1F` | 1 | `kbd_tete` — écrit par la NMI seule |
| `$CA20` | 1 | `kbd_queue` — écrit par `kbd_poll` seul |
| `$CA21` | 1 | `kbd_apres_f0` |
| `$CA22–$CA2D` | 12 | zone console du Terminal : `cz_actif`, `cz_l`, `cz_h`, `cz_haut` (2), `cz_bas` (2), `cz_op`, `cz_n`, `cz_ptr` (2), `cz_cpt` |
| `$CA2E` | 1 | `kbd_echap` — `$80` sur le code PS/2 d'Échap (BBC BASIC) |
| `$CA2F–$CC2E` | 512 | `gfx_tampon` — au programme du premier plan (BBC BASIC : graphisme) ; le BIOS n'y touche pas |
| `$CC2F` | 1 | `kbd_verr` — voyants : bit 2 = Verr. Maj |
| `$CC30` | 1 | `kbd_led_dem` — envoi des voyants demandé |
| `$CC31` | 1 | `kbd_led_cpt` — trames avant l'octet des voyants |
| `$CC32` | 1 | `kbd_muet` — <> 0 : la NMI jette les octets du clavier |
| `$CC33–$CC41` | 15 | `ext_nom` — `/BIN/BIOS2` formaté (`Ext_Charge`) |
| `$CC42–$CC4F` | 14 | `ext_info` — l'entrée de `BIOS2` (`FS_FileInfo` : LBA, taille, page, adresse, attributs, dossier) |
| `$CC50` | 1 | `ext_ok` — 1 : BIOS2 installé (`M CC50` dans MONITEUR) |
| `$CC51–$CC6C` | 28 | `ExtV` — 14 vecteurs EPROM → BIOS2 (ordre dans `bios/ext.inc`) |

`__bss_start__ = $C000`, `__bss_end__ = $CC6D`.

### 5.2 Tas système — `$CC6D–$CD6C` (256 octets)

`HEAP_START = __bss_end__`, `HEAP_SIZE = $0100` (`bios/vectors.asm`).
`malloc_sys` / `free` : blocs précédés d'un en-tête de 3 octets. Seul le
SHELL s'en sert (16 octets par commande externe, rendus aussitôt).
`bios/bios2.py` refuse un tas qui atteindrait `EXT_BASE`. `$CD6D–$CDFF`
est libre.

### 5.3 BIOS2 — `$CE00–$D9FF` (3072 octets)

La seconde partie du BIOS : section `.ext`, liée en même temps que
l'EPROM à `EXT_BASE` = `$CE00` (`bios/Makefile`), au plus jusqu'à
`EXT_FIN` = `$DA00`. `bios2.py` l'extrait dans `bios/BIOS2`, livré en
`/BIN/BIOS2`, et inscrit sa longueur et sa somme dans l'EPROM (`ExtLong`
`$F79A`, `ExtSomme` `$F79C`).

| Adresse | Longueur | Module | Contenu |
|---|---:|---|---|
| `$CE00` | `$0074` | `SD.o` | `SD_WriteBlock` |
| `$CE74` | `$0180` | `IT.o` | `X_Zone_IRQ` (défilement de la zone du Terminal), `X_Audio` (séquenceur, à chaque VSYNC) |
| `$CFF4` | `$0428` | `osmfs.o` | `Fs_WriteBlk`, `FS_SaveFile`, `FS_FindFreeEntry`, `FS_DeleteFile`, `FS_SetAttributes`, `FS_RenameFile`, `FS_MkDir`, `FS_SetLoad`, `FS_ListRoot` |
| `$D41C` | `$009F` | `video.o` | `X_Console_Zone`, `Cz_Pose`, `X_Zone_Cls` |
| `$D4BB` | `$00B5` | `audio.o` | `X_snd_play`, `X_snd_stop`, `X_boot_jingle`, `Ay_Note` |
| `$D570` | `$0028` | `ext.o` | `Ext_Entree`, `Ext_Table` |
| | | | **fin : `$D597`**, 1944 octets, somme `$9C7B` ; 1128 octets libres avant `EXT_FIN` |

- **Chargement** : `Ext_Charge` (EPROM), à chaque démarrage, à froid ou
  après un TRAP, juste après la carte SD et avant le jingle. Il lit
  `/BIN/BIOS2` secteur par secteur en `$CE00`, vérifie la longueur et la
  somme, appelle `Ext_Entree` (qui copie `Ext_Table` dans `ExtV`) et met
  `ext_ok` à 1.
- **Sans BIOS2** (fichier absent, autre BIOS, carte absente) : `ExtV`
  garde les valeurs d'`Ext_Defauts` (reset) : les services déplacés
  répondent C = 1 (`Sys_Absent`), le son et l'effacement de zone ne font
  rien, l'IRQ continue au curseur. La machine démarre quand même.
- L'EPROM n'entre dans BIOS2 que par `jmp [ExtV+n]` (souches aux anciens
  noms) ; `bios/verifie_ext.py` le contrôle à chaque build.
- Une EPROM et son BIOS2 vont ensemble : reflasher l'EPROM impose de
  redéployer `/BIN/BIOS2`, sauf si `make -C bios` donne la même somme.

### 5.4 Pile système — depuis `$DFEF`, vers le bas

`RAM_TOP = $DFEF`, `lds #RAM_TOP` dans `__start`. La pile peut descendre
jusqu'à `$DA00` (`EXT_FIN`), 1,5 Ko. Mesuré le 13 nov. 2026 dans tous les
vérificateurs : jamais sous `$DDEB` (environ 520 octets). Cadre
d'interruption natif 6309 : 14 octets, `PC` à `12,S`.

Les vérificateurs rangent leurs zones de travail en `$DB00-$DDFF` (sous
leur pile en `$DF00`).

### 5.5 Vecteurs RAM — `$DFF0–$DFFD` (14 octets)

`section .ram_vectors` : `rvec_SWI3`, `SWI2`, `FIRQ`, `rvec_IRQ`
(`$DFF6`), `SWI`, `NMI`, `TRAP`, remplis par `__start`. Un programme peut
s'accrocher à `rvec_IRQ` devant le gestionnaire du BIOS (DONJON39, ZMACHINE,
AYJOUE) en le rendant à la sortie ; BBC BASIC prend `rvec_SWI3`.

Cette zone est de la RAM : `bios/Makefile` retire de l'image EPROM les
enregistrements S-Record à partir de `$DFF2` (`osm39.filtered.srec`). Ne
pas supprimer ce filtre.

## 6. `$E000–$FFFF` — BIOS en EPROM (8 Ko, U104)

`.code` à `$E000`. `bios/osm39.bin` fait exactement 8192 octets (`$FF`
dans les trous). Relevé dans `bios/osm39.map` le 13 nov. 2026 :

| Adresse | Longueur | Module | Rôle |
|---|---:|---|---|
| `$E000` | `$0179` | `vectors.o` | `__start` (mode natif, BSS, vecteurs), `Redemarrage`, `table_function_rom` |
| `$E179` | `$04CE` | `main.o` | initialisation, `Demarrage`, SECOURS (`LOAD`, `RUN`, `BOOT`), `Pager`, `FarRead`, `FarWrite`, `LoadandExec` |
| `$E647` | `$0125` | `SD.o` | pilote SPI : init, `SD_ReadBlock` |
| `$E76C` | `$042E` | `keyboard.o` | décodage PS/2, `scan_keyboard`, `kbd_poll`, voyants |
| `$EB9A` | `$0344` | `IT.o` | IRQ VSYNC, NMI (deux ACIA), TRAP |
| `$EEDE` | `$06CE` | `osmfs.o` | OSMFS en lecture : montage, recherche, chargement, dossiers, chemins (`Format_Filename_83`), `FS_FileInfo`, `FS_ReadSector`, `Fs_ReadBlk` |
| `$F5AC` | `$0027` | `filename.o` | `Convert_To_Upper`, `strlen`, `strcpy` |
| `$F5D3` | `$013B` | `video.o` | 68B45, console, effacement |
| `$F70E` | `$0043` | `audio.o` | `init_audio`, `Ay_Silence`, souches du son |
| `$F751` | `$0049` | `farcall.o` | `FAR_CALL`, `FAR_CALLN` |
| `$F79A` | `$00F7` | `ext.o` | `ExtLong`, `ExtSomme`, `Ext_Defauts`, `Ext_Charge` |
| | | | **fin de `.code` : `$F890`** ; 1871 octets libres jusqu'à `$FFDF` (`make -C bios` échoue au-delà) |
| `$FFE0` | `$0006` | `farcall.o` | `.romjmp`, adresses FIXES : `$FFE0` `FAR_CALL`, `$FFE3` `FAR_CALLN` (ajouter seulement à la fin, jusqu'à `$FFEF`) |
| `$FFF0` | `$0010` | `vectors.o` | `.vectors` — vecteurs matériels |

`bios/splash.asm` n'est pas lié (il lui faudrait environ 611 octets).

### Chaîne de démarrage

```text
reset → __start : pile $DFEF, LDMD #$01 (natif), BSS à 0, vecteurs RAM,
        table des services
      → main : PIA (horloge au repos), 68B40, Ext_Defauts, init_audio,
        ACIA série, VRAM effacée, 68B45, CLI
      → carte SD (4 essais) → FS_Mount → Ext_Charge (BIOS2)
      → clavier, current_page = 0
      → Demarrage : jingle (BIOS2), bannière, fenêtre de ~1 s
          touche ou caractère série → SECOURS (LOAD, RUN, BOOT)
          sinon → OSMVISION chargé en page 0, $0000, relancé à chaque retour
TRAP → handler_TRAP : rapport dans trap_frame/trap_info, une touche
      → Redemarrage : comme __start sans effacer la BSS, BIOS2 relu,
        OSM-VISION relancé sans fenêtre
```

Le nom chargé est `KERNEL_FILENAME` (`bios/main.asm`), aujourd'hui
`OSMVISION`, à la racine. Introuvable, ou pas de carte : SECOURS.

## 7. Conséquences pour les programmes

- Un programme possède `$0000-$7FFF` de sa page ; il est lié à `$0000`
  (SHELL `$6000`, BASIC `$5A00`). Un programme avec une `.bss` omet
  `--section-base` : sa `.bss` ne va jamais en `$C000`.
- Rien à écrire en `$C000-$DFFF` hors des variables documentées dans
  `hardware.inc` : le tas, BIOS2 et la pile s'y partagent la place.
  `gfx_tampon` est le seul tampon système laissé aux programmes.
- Ce qui doit survivre à un changement de page pendant un appel au BIOS va
  en RAM système (ou dans un tampon fourni par le BIOS), pas dans la page.
- Une partition lancée par `SND_PTR` est lue dans la page mappée à chaque
  VSYNC : la couper avant de rendre la main.
- `$8000-$9FFF` n'appartient qu'à la vidéo ; passer par `VRAM_*` de
  `hardware.inc` pour rester juste sur les deux cartes.

## 8. Ce qui n'existe pas

- **Pas de noyau ni de multitâche** : pas d'ordonnanceur, pas de
  processus. `KERNEL_START`/`KERNEL_FILENAME` désignent OSM-VISION.
- **Pas de « paged buffer »** (`pbuf`, `$D000`) : supprimé.
  `far_transit_buffer` est un simple relais de 256 octets.
- **Pas de registre ni de validation des pages** : `sys_pager` écrit le
  latch sans contrôle (seuls `FAR_CALL` et les services de fichiers
  refusent une page > 3).
- **Rien de câblé en `$A200-$BFFF`.**
- **Pas de moniteur complet dans l'EPROM** : SECOURS seul ; `MONITEUR` et
  `LS` sont sur la carte.
