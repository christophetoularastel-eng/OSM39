# Cartographie mémoire OSM39 V2

Ce document décrit l'espace d'adressage **tel que le code l'utilise aujourd'hui**.

Il a été réécrit le 27 septembre 2026. La version précédente décrivait une
machine qui n'existe plus : quatre banques, un noyau chargé en `$D000`, un
sous-système de « paged buffer », un ordonnanceur multitâche. Ces composants
ont été **supprimés** ; leur description, elle, est restée. Si vous lisez encore
la version 4-banques, c'est un fossile — voir `AGENTS.md`, section « Archaeology ».

## Source de vérité

Chaque adresse de ce document se vérifie en une commande. Ne le croyez pas sur
parole, vérifiez-le :

| Ce que vous cherchez | Où c'est vrai |
|---|---|
| Adresses des globales BSS | `bios/hardware.inc` (généré, ne pas éditer) |
| Offsets des services BIOS | `bios/sysfunc.inc` (généré, ne pas éditer) |
| Adresses et sections du lien | `bios/osm39.map` (artefact de build) |
| Adresses BSS effectives | `bios/ram.map` (artefact de build) |
| Adresses matériel | `bios/hardware.inc`, section « pagination/PIA/ACIA/… » |
| Vecteurs, pile, tas | `bios/vectors.asm` |

`bios/hardware.inc` et `bios/sysfunc.inc` sont **générés** par
`bios/update_includes.py` à partir de `ram.asm`. Le générateur échoue le build si
la table de dispatch des services est désynchronisée. Ces deux fichiers font
foi ; ce document est une aide à la lecture.

## 1. Vue d'ensemble

```text
$0000 ┌──────────────────────────────────────┐
       │  Fenêtre RAM paginée, 32 Ko         │  sélectionnée par $A0C0
$7FFF └──────────────────────────────────────┘
$8000 ┌──────────────────────────────────────┐
       │  RAM vidéo caractères, 4 Ko         │  page choisie par $A120 (D0-D2)
$8FFF └──────────────────────────────────────┘
$9000 ┌──────────────────────────────────────┐
       │  RAM vidéo couleurs, 4 Ko (V4)      │  même page, a12 = 1
$9FFF └──────────────────────────────────────┘
$A000 ┌──────────────────────────────────────┐
       │  Périphériques (I/O mappé)          │
$A1FF └──────────────────────────────────────┘
$C000 ┌──────────────────────────────────────┐
       │  BSS système ($C000–$CC32)         │  .bss (gfx_tampon en $CA2F)
       │  Tas système ($CC33–$D332)          │  malloc_sys / free
       │  Libre ($D333–$DFEE)                │
$DFEF │  ← pile matériel (ldx #RAM_TOP)      │
$DFF0 │  Vecteurs RAM (.ram_vectors)         │  14 octets
$DFFF └──────────────────────────────────────┘
$E000 ┌──────────────────────────────────────┐
       │  BIOS / EPROM                       │  .code
       │  (espace libre : $FBB6–$FFDF)       │
$FFE0 │  Table de sauts fixe (.romjmp)       │  FAR_CALL, FAR_CALLN
$FFF0 │  Vecteurs matériels (.vectors)       │  16 octets
$FFFF └──────────────────────────────────────┘
```

## 2. `$0000–$7FFF` — fenêtre RAM paginée (32 Ko)

C'est ici que les programmes **se chargent et s'exécutent**. Tous les programmes
utilisateurs sauf `basic69` sont liés avec `--section-base=.code=0x0000`
(`basic69.asm` utilise `0x5A00` avec `.bss=0x0000`).

Qui occupe quelle page :

| Page | Contenu |
|---|---|
| 0 | OSM-VISION (`$0000`, jusqu'à `$7FFF` au besoin), ou le SHELL qui le remplace en le quittant |
| 1 | le programme lancé : console (`cmd/*`, ASM, FORTH, BASIC en `$5A00`) ou application d'OSM-VISION (attribut `a`, liée à `$0000`, appelée par `FAR_CALL`) |
| 2-3 | données : tampon d'EDIT (2-3), textes de CALC (3), binaire produit par ASM (2), Copier/Coller et Voir d'OSM-VISION (2-3), modules de PONT (2, 3) |

La fenêtre est **matériel** : un latch à `$A0C0` (@A0C0-2) sélectionne la page
physique qui apparaît dans `$0000–$7FFF`.

- Le latch est **écrit seul**. Toutes ses occurrences dans le BIOS sont des
  `STA $A0C0` : `main.asm` (dans `FarRead`/`FarWrite`), `osmfs.asm`. Il n'est
  jamais relu par le CPU. L'état de la pagination ne vit donc que dans le
  matériel, pas en mémoire.
- Le BIOS bascule de page quand il doit toucher une page qui n'est pas celle du
  programme appelant, puis **restaure la page de l'appelant avant de rendre la
  main** — sinon le retour au `RTS` s'exécuterait dans la mauvaise page. Voir le
  motif dans `osmfs.asm:237-240` :
  ```asm
  lda     0,s             ; Page cible, sauvegardée sur la pile
  sta     $A0C0           ; Bascule la RAM ($0000-$7FFF) sur la page cible
  tfm     u+,y+           ; [6309] Transfert à vitesse maximale
  lda     current_page    ; Page d'exécution du programme appelant
  sta     $A0C0           ; Restaure la RAM pour éviter le crash au RTS
  ```
- `current_page` (`$C4C1`, 1 octet) est le miroir logiciel de la page courante.
  Il est mis à zéro au démarrage (`main.asm:140`) et écrit uniquement par le
  service `sys_pager`. **Ce n'est pas une table de pages** : il n'y a ni
  registre de pages, ni validation, ni ordonnanceur.

### Combien de pages sont installées ?

**4 pages de 32 Ko, soit 128 Ko de RAM utilisateur** au total. C'est un fait
matériel, rappelé ici par le concepteur de la carte ; **aucune source de cet
arborescence ne le déduit**. Le BIOS n'a nulle part de constante « nombre de
pages » : il écrit un numéro de page dans le latch et n'y touche plus.

| Page | Fenêtre | Usage typique |
|---:|---|---|
| 0 | `$0000–$7FFF` | `SHELL` et la plupart des programmes (adresse de boot) |
| 1 | idem | programmes chargés à la demande |
| 2 | idem |idem |
| 3 | idem | idem |

La page courante n'est **jamais bornée** : `sys_pager` accepte n'importe quelle
valeur, et `FarRead`/`FarWrite` écrivent le numéro de page tel qu'il vient de
`current_page`. Une valeur hors 0–3 fait porter par le hardware une adresse
inconnue ; le logiciel ne le détectera pas.

> Les anciennes versions de ce document, comme `AGENTS.md` avant le
> 27 septembre 2026, affirmaient « 4 banques de 32 Ko » en la présentant comme
> une affirmation non sourcée. Elle était **juste**, mais elle ne venait pas du
> code : c'est une donnée de la carte. La nuance est conservée ici parce
> qu'elle compte pour qui reprend le projet : la lire dans le code est
> impossible, la lire dans ce document est possible.

Contraste utile : la RAM vidéo, elle, **est** corroborée par le code. Le champ
D0–D2 du 74HC374 est sur 3 bits, donc 8 valeurs, et `video.asm:9` le documente
comme « page 0-7 ». 8 × 4 Ko = 32 Ko, ce qui correspond exactement à l'en-tête
de `video.asm:4` (« caractères 32 Ko, couleurs 32 Ko »). Les 4 × 32 Ko de RAM
utilisateur, eux, ne sont vérifiables par rien dans l'arbre : c'est la seule
donnée de cette carte qui repose sur une information externe.

Ce que le code fait, et qui est vérifiable :

- `sys_pager` est un **stub de trois instructions** (`Pager`, `main.asm:791`) :
  `STA pager_reg` / `STA current_page` / `RTS`. Il n'interroge rien, ne valide
  rien, ne bascule rien de plus qu'un latch.
- `sys_FarRead` et `sys_FarWrite` font, eux, du travail réel : ils copient par
  blocs de 256 octets à travers `far_transit_buffer` (`$C6D3`, 256 octets) avec
  `TFM`, IRQ et FIRQ masqués (`ORCC #%01010000`), en restaurant la page de
  l'appelant avant de rendre la main.

### Le champ « page de boot » de OSMFS n'est écrit par personne

C'est le point bloquant du chantier multipage, et il est facile à manquer parce
que **le code qui le lit est enthousiaste et bien commenté**. L'entrée de
répertoire OSMFS prévoit deux champs (`bios/osmfs.asm:43-44`) :

- `+24` page de boot (1 octet)
- `+25` adresse de boot (2 octets, big-endian) — `DE_OFF_PAGE` / `DE_OFF_ADDR`

Trois endroits les lisent en annonçant une valeur dynamique :

| Lecteur | Commentaire dans le code |
|---|---|
| `shell/shell.asm:73-74` | `; A = Page cible dynamique` / `; Y = Adresse d'exécution dynamique` |
| `bios/fload.asm:37,39` | `; A = Page cible dynamique` / `; Y = Adresse d'exécution dynamique` |
| `shell/shellV2.asm:73-74` | idem (variante WIP, hors Makefile) |

**Aucun code de l'arborescence ne les écrit.** Vérifié par recherche exhaustive :

- `DE_OFF_PAGE` / `DE_OFF_ADDR` n'apparaissent que comme `equ` dans
  `osmfs.asm:52-53`, comme lectures, et dans `osm39.map` / `osmfs.lst`.
- `FS_FindFreeEntry` **efface les 32 octets** de l'entrée neuve
  (`osmfs.asm`, boucle `FFE_ClearEntry`) — donc `+24` et `+25` valent 0.
- `FS_SaveFile` ne réécrit que deux choses dans l'entrée, en `Save_Finalize` :
  `DE_OFF_FIRST` (`+16`) et `DE_OFF_SIZE` (`+20`). Rien d'autre.
- `deploy_sd.sh` ne fabrique pas d'entrée OSMFS : il copie des fichiers plats
  dans `dist/SD/`, qui n'est qu'un répertoire de transit.

**Conséquence vérifiable** : les deux champs valent toujours 0, donc tout
programme externe lancé depuis le shell part en **page 0, adresse `$0000`**. La
page n'est pas choisie, elle est imposée par l'absence d'écriture.

Corollaire concret, et c'est le vrai sujet du chantier : `asm/asm.asm:4`
annonce « Charge : page 1, $0000 », mais le chargeur ne peut pas honorable cette
page. Lancer `ASM` depuis le shell le charge en **page 0 par-dessus le shell**.
L'assembleur fonctionne — sa sortie part bien en page 2 via `FarWrite` — mais il
écrase le shell sous lui, et rien ne le recharge. C'est le premier obstacle à
lever pour qui veut « laisser un programme utiliser les 4 pages » : il manque un
écrivain pour `+24`, donc il n'existe aucun moyen de *placer* un programme sur une
page autre que 0 par le système de fichiers.

> Ce que le chargeur sait faire, en revanche : `main.asm:LoadandExec` reçoit la
> page et l'adresse **en A et Y de l'appelant** et ne regarde pas l'entrée de
> répertoire. La capacité de charger sur une page quelconque existe donc au niveau
> du service ; c'est le chemin « depuis un fichier sur la carte SD » qui est
> incomplet. `fload_cmd` et le shell utilisent le chemin incomplet, `BOOT`
> (`main.asm:145`) utilise le chemin complet avec `CLRA` = page 0.


## 3. `$8000–$9FFF` — RAM vidéo (2 × 4 Ko visibles)

Carte vidéo MC68B45 (CRTC) + **deux** RAM vidéo de 32 Ko : une pour les
caractères, une pour les couleurs.

**V4 (carte CRT2 modifiée le 10 oct. 2026)** : l'entrée A0 du décodeur U126
(74HC138) est reliée à la ligne d'adresse CPU **a12** (J6 broche A3), A1 et A2
sont à la masse. Le CPU voit donc **les deux RAM à la fois** :

| Adresses | RAM |
|---|---|
| `$8000–$8FFF` | caractères (`VRAM_BASE`..`VRAM_END`) |
| `$9000–$9FFF` | couleurs (`VRAM_COL`..`VRAM_COL_END`) : même cellule + `VRAM_COL_OFS` ($1000) |

Le 74HC374 à `$A120` (`VRAM_CTRL`, écriture seule) ne sert plus qu'à la page :

| Bits | Effet |
|---|---|
| D0–D2 | page 0–7 — **8 pages** de 4 Ko par RAM vidéo (vues par le CPU ET le 68B45) |
| D3–D5 | ignorés en V4 (en V3 : D3 = RAM caractères/couleurs, D4–D5 = mode, `$10` « rend la VRAM au 68B45 ») |

U126 n'est validé que pendant un accès du CPU à `$8000–$9FFF` : hors de ces
accès, la VRAM appartient au 68B45, sans « mode » à commuter. Chaque accès
bascule un instant les multiplexeurs d'adresses (VCRAM-SELECT) et remet à zéro
U116 : on écrit donc toujours pendant le retour de trame.

Ici, contrairement à la RAM utilisateur, **le code corrobore le nombre de
pages**, et la carte le confirme. Les deux sources sont d'accord et l'arithmétique
tient :

- `video.asm:9` documente le champ D0–D2 comme « page 0-7 » — 3 bits, 8 valeurs.
- `video/carto.txt:10` (description matérielle du concepteur) dit exactement la
  même chose : « D0, D1, D2 selectionne 1 des 8 pages des rams vidéo
  (2 rams de 4kox8) ».
- 8 × 4 Ko = 32 Ko par RAM vidéo, ce qui correspond à l'en-tête de `video.asm:4`
  (« caractères 32 Ko, couleurs 32 Ko ») et à la fiche `carto.txt` ellemême.

**`video/carto.txt` est la source matérielle de référence pour la vidéo.** Elle
précise ce que `video.asm` n'énonce qu'en passant :

- Le 74HC374 est en **écriture seule** (`carto.txt:7`).
- **Règle d'accès** : en V3, D4 = D5 = 0 pour accéder (`carto.txt`, partie V3) ;
  en V4 il n'y a plus de mode, mais les accès se font toujours pendant
  VSYNC = 0 pour ne pas perturber l'image.
- Les deux RAM sont **lues en parallèle** par le 68B45 (`carto.txt:69`) : à chaque
  caractère, une lecture de la RAM caractères et une de la RAM couleurs.
- Horloge : quartz 25,175 MHz → 74HC166 (sérialise les RAM vidéo) et 74F163 dont
  la sortie Q2 (`CHARCLOCK`) horloge le 6845 et la sortie TC (`LOAD`). 25,175/8 =
  3,146875 MHz, ce que confirme `video.asm`.
- VSYNC est relié à C1 du 68B40 : tick 60 Hz **et** IRQ au moment où la RAM vidéo
  est accessible au CPU (`carto.txt:8`).

Octet d'attribut couleur, un par caractère (`carto.txt:71-77`) :

| Bit | Effet |
|---|---|
| D0–D2 | couleur 0–7 du caractère |
| D3 | luminosité |
| D4 | clignotement (active le clignotement) |
| D5 | à complémenter à chaque VSYNC (effectue le clignotement) |
| D6 | inverse les bits du caractère |
| D7 | page 0 ou 1 du **générateur de caractères** |

Deux points méritent attention :

- Il existe donc **deux pages de générateur de caractères** (bit D7 de l'octet
  couleur), en format 8×16. C'est ce que incarnent `video/font8x16.bin` et
  `video/font2.bin`.
- `carto.txt:11` dit « D3, D4, D5 donne l'accès à 1 des 2 rams vidéo », ce qui
  contredit son propre tableau (`carto.txt:18-63`) où **seul D3** choisit la RAM et
  D4/D5 sont le mode. **Le tableau fait foi** : c'est lui que `video.asm:9`
  reproduit. La phrase de la ligne 11 est une imprécision de rédaction, pas une
  troisième fonction. De même `carto.txt:74` annonce « D4 NC » puis `carto.txt:75`
  réutilise D4 pour le clignotement : c'est la seconde ligne qui est juste.


**Contrainte d'accès** : la fenêtre vidéo n'est lisible par le CPU que pendant
le blanc, `VSYNC = 0`. Le gestionnaire d'interruption VSYNC (IRQ 60 Hz) exploite
ce créneau — voir `bios/IT.asm` et `docs/rapport-hd6309-natif.md` pour l'analyse
de cycles. Le tampon circulaire d'affichage (`ASCII_BUF`/`COLOR_BUF`, 256 octets
chacun) est vidé pendant ce blanc.

Mode texte 80×25, caractères 8×16, 2000 octets par écran.

## 4. `$A000–$A1FF` — périphériques

Registres mémoire-mappés. Symboles dans `bios/hardware.inc`.

| Adresse | Symbole | Périphérique |
|---|---|---|
| `$A000` | `CR_reg`, `SR` | ACIA RS232 — contrôle / statut |
| `$A001` | `TDR`, `RDR` | ACIA RS232 — émission / réception |
| `$A040` | `PIADRA`, `DDRA` | PIA — données et direction port A |
| `$A041` | `PIADRB`, `DDRB` | PIA — données et direction port B |
| `$A042` | `CRA` | PIA — contrôle A |
| `$A043` | `CRB` | PIA — contrôle B |
| `$A080` | `CR1`, `CR3` | Timer 6840 — contrôle 1 et 3 |
| `$A081` | `CR2`, `STATUS` | Timer 6840 — contrôle 2 et statut |
| `$A082` | `TIMER1` | Timer 6840 — données timer 1 |
| `$A084` | `TIMER2` | Timer 6840 — données timer 2 |
| `$A086` | `TIMER3` | Timer 6840 — données timer 3 |
| `$A0C0` | `pager_reg` | Latch de pagination (§2) |
| `$A100` | `CRTC_RS` | CRTC 68B45 — sélection de registre |
| `$A101` | `CRTC_DATA` | CRTC 68B45 — données |
| `$A120` | `VRAM_CTRL` | 74HC374 — page vidéo D0–D2 (§3 ; V4 : plus de choix de plan) |
| `$A140` | `SD_CTRL` | Carte SD-KBD-SON : verrou SPI (écriture) — bit 0 /CS, bit 1 rapide (E au lieu de E/16) |
| `$A148` | `SD_DATA` | Carte SD-KBD-SON : données SPI — écrire envoie, lire rend l'octet du transfert précédent et le renvoie à la carte (mesuré ; le schéma dit `$FF`) |
| `$A150` | — | Carte SD-KBD-SON : AY-3-8910 |
| `$A180` | `CR_key`, `SR_key` | **ACIA clavier** (carte SD-KBD-SON) — contrôle / statut |
| `$A181` | `TDR_key`, `RDR_key` | **ACIA clavier** (carte SD-KBD-SON) — données |

L'ACIA clavier (`$A180`/`$A181`, répété dans `$A180-$A1BF` ; celui de la CPU en
`$A1C0` n'est plus utilisé depuis le 27 oct. 2026) est une **seconde** liaison série, distincte de
la RS232. Le clavier PS/2 y est branché et ses octets sont reçus par NMI
(`handler_NMI`, `bios/IT.asm:340`). L'ancienne description du clavier comme
« pilote PS/2 bit-bangé » est périmée : seul le transport a changé, le décodage
des codes de scan reste du PS/2 classique.

`$A000` est drainé par le même `handler_NMI`, avec bip et bascule vers le
moniteur `reg_cmd` sur `BREAK`.

## 5. `$C000–$DFEF` — RAM système (8 Ko)

### 5.1 BSS — `$C000–$CC32` (3123 octets)

`section .bss`, linkée à `--section-base=.bss=0xc000`, mise à zéro au
démarrage. Source de vérité : `bios/ram.asm`. Adresses relevées dans
`bios/osm39.map` le 10 oct. 2026, après l'agrandissement de la table.

| Plage | Taille | Contenu |
|---|---:|---|
| `$C000–$C057` | 88 | `table_function_ram` — 44 services de 2 octets (… `sys_FS_SetLoad`, `sys_FS_ChDir`, `sys_FS_MkDir`, `sys_FS_Dossier`, `sys_FS_DirInfo`). Remplie au boot depuis `table_function_rom` |
| `$C058–$C05F` | 8 | `table_reserve` — 4 emplacements libres (`fdb Sys_Absent` : C = 1). La table fait **96 octets fixes** (`TABLE_OCTETS`, `update_includes.py`) : un nouveau service y prend sa place sans décaler ce qui suit |
| `$C060–$C062` | 3 | Clavier : `SCAN_CODE`, `NEW_CODE`, `key_on` |
| `$C063–$C162` | 256 | `load_buffer` |
| `$C163–$C182` | 32 | `write_buffer` |
| `$C183–$C186` | 4 | `read_load_ptr`, `write_load_ptr` |
| `$C187–$C206` | **128** | `input_buffer` — tampon de saisie. **128 octets**, pas 32 |
| `$C207–$C20A` | 4 | `read_line_ptr`, `write_line_ptr` |
| `$C20B–$C21A` | 16 | `buffer` |
| `$C21B` | 1 | `sd_ctrl` (copie de `SD_CTRL`) |
| `$C21C–$C41B` | 512 | `SD_BUFFER` — un secteur de carte SD |
| `$C41C–$C41F` | 4 | `BlockAddr` |
| `$C420` | 1 | `SDHC_Flag` |
| `$C421–$C430` | 16 | `CSD_BUFFER` |
| `$C431–$C43C` | 12 | `CMD17_Packet`, `CMD24_Packet` |
| `$C43D–$C45C` | 32 | `g_find_fileInfo` |
| `$C45D–$C471` | 21 | Contexte de lecture : `s_find_currentSector`, `s_find_currentEntry`, `s_entry_lba`, `s_entry_offset`, `s_file_size`, `s_file_bytesLeft`, `s_file_destPtr` |
| `$C472–$C481` | 16 | `ExeFileNameBuffer` |
| `$C482–$C491` | 16 | `FormattedName` — nom formaté 8.3, pour `sys_FS_*` |
| `$C492–$C4A7` | 22 | Contexte d'écriture : `s_save_fileNamePtr`, `s_save_sourcePtr`, `s_save_bytesLeft`, `s_save_fileSize`, `s_save_firstSector`, `s_save_dirEntryLBA`, `s_save_dirEntryOffset` |
| `$C4A8–$C4AB` | 4 | État PS/2 : `e0_received`, `last_makecode`, `PS2_BIT_COUNT`, `PS2_PARITY` |
| `$C4AC–$C4BF` | 20 | `argv` |
| `$C4C0` | 1 | `argc` |
| `$C4C1` | 1 | `current_page` — page d'exécution (§2) |
| `$C4C2–$C4C3` | 2 | `vsync_tick` |
| `$C4C4–$C4CA` | 7 | Vidéo : `BUF_HEAD`, `BUF_TAIL`, `VRAM_PTR`, `CUR_PAGE`, `vram_line_ptr` |
| `$C4CB–$C5CA` | 256 | `ASCII_BUF` — tampon circulaire de caractères |
| `$C5CB–$C6CA` | 256 | `COLOR_BUF` — tampon circulaire d'attributs |
| `$C6CB–$C6CC` | 2 | `SCREEN_START_OFFSET` |
| `$C6CD–$C6D0` | 4 | `MUSIC_PTR`, `MUSIC_TIMER`, `char_attribut` (`$C6D0`) |
| `$C6D1–$C6F0` | 32 | `trap_frame` — frame 6309 complète |
| `$C6F1–$C7F0` | 256 | `far_transit_buffer` — relais pour `FarRead`/`FarWrite` |
| `$C7F1` | 1 | `trap_active` — garde-fou anti-récursion du TRAP |
| `$C7F2–$C871` | 128 | `SND_BUF` — copie de partition pour `sys_snd_play` |
| `$C872–$C878` | 7 | moulinet des transferts SD (`spin_cnt`, `spin_on`, `spin_save`, `spin_dir`, `osmfs.asm`) |
| `$C879` | 1 | `sd_err` — code de la dernière erreur SD (`$E1`-`$E5`), 0 = aucune (lire par `MEM C879`) |
| `$C87A` | 1 | `sd_retry` — nouvelles tentatives SD depuis le démarrage, plafonné à 255 |
| `$C87B–$C882` | 8 | dossiers : `fs_dossier` (dossier courant, 0 = racine), `fs_cible`, `fs_explicite`, `fs_repli`, `fs_attr_neuf`, `fs_slot_suiv` |
| `$C883–$C8D2` | 80 | `fs_slots` — 4 noms formatés avec un chemin : adresse, page, dossier, nom |
| `$C8D3–$C8E8` | 22 | `fr_fin`, `fr_dos`, `fr_nom15`, `fs_tmp` (résolution des chemins) |
| `$C8E9` | 1 | `boot_chaud` — <>0 : redémarrage après un TRAP (pas de fenêtre de secours) |
| `$C8EA–$C909` | 32 | `trap_info` — état de la machine au dernier TRAP (format dans `bios/ram.asm`), lu par `MONITEUR R` ; survit au redémarrage à chaud |
| `$C90A` | 1 | `sd_absente` — <>0 : pas de carte SD au démarrage (SECOURS) |
| `$C90B` | 1 | `son_coupe` — $4D : son coupé (touche M d'OSM-VISION), lu par chaque copie de `lib/vision.asm` |
| `$C90C` | 1 | `serie_brute` — <>0 : liaison série en mode brut (MINITEL) ; remis à 0 par `Demarrage` et `Secours` |
| `$C90D` | 1 | `serie_tete` — écrit par la NMI seule |
| `$C90E` | 1 | `serie_queue` — écrit par le programme seul |
| `$C90F–$CA0E` | 256 | `serie_buf` — anneau des octets reçus en mode brut (plein : l'octet est perdu) |
| `$CA0F–$CA1E` | 16 | `kbd_buf` — file des octets PS/2 (la NMI y range chaque octet, en plus de `SCAN_CODE`) |
| `$CA1F` | 1 | `kbd_tete` — écrit par la NMI seule |
| `$CA20` | 1 | `kbd_queue` — écrit par `kbd_poll` seul |
| `$CA21` | 1 | `kbd_apres_f0` — 1 : l'octet suivant de la file est un code de relâchement |
| `$CA22–$CA2D` | 12 | `cz_actif`, `cz_l`, `cz_h`, `cz_haut` (2), `cz_bas` (2), `cz_op`, `cz_n`, `cz_ptr` (2), `cz_cpt` — zone console du Terminal (`sys_Console_Zone`) |

| `$CA2E` | 1 | `kbd_echap` — $80 dès le code PS/2 d'Échap (NMI) : drapeau d'échappement du BBC BASIC |
| `$CA2F` | 512 | `gfx_tampon` — tampon pour le programme au premier plan (BBC BASIC : table inverse des mosaïques et file des cellules du graphisme). Le BIOS n'y touche pas. Avec une EPROM antérieure, c'était le début du tas (en-tête écrit au démarrage seulement, `malloc_sys` n'a pas d'appelant) |
| `$CC2F` | 1 | `kbd_verr` — octet des voyants du clavier : bit 2 = Verr. Maj (lettres en majuscules) |
| `$CC30` | 1 | `kbd_led_dem` — <>0 : `kbd_poll` demande l'envoi des voyants |
| `$CC31` | 1 | `kbd_led_cpt` — <>0 : `$ED` parti, trames avant l'octet des voyants (IRQ) |
| `$CC32` | 1 | `kbd_muet` — <>0 : la NMI jette les octets du clavier (écho de l'envoi, accusé décalé) |

`__bss_start__ = $C000`, `__bss_end__ = $CC33`.

### 5.2 Tas système — `$CC33–$D332` (1792 octets)

Défini dans `bios/vectors.asm` :

```asm
HEAP_START  EQU __bss_end__      ; $CC33
HEAP_SIZE   EQU $0700            ; 1792
HEAP_END    EQU HEAP_START+HEAP_SIZE   ; $D333
```

Géré par `malloc_sys` et `free`, qui découpent la zone en blocs précédés d'un
en-tête de 3 octets (2 pour la taille, 1 pour l'état d'occupation).
Aucun programme ne s'en sert. Jusqu'au 17 oct. 2026, un bloc découpé
rendait un pointeur 3 octets trop loin (`LEAX BLK_DATA,X` deux fois) :
corrigé dans le source, effectif au prochain flash de l'EPROM.

L'ancienne valeur `HEAP_START = $D900` de ce document était fausse : elle
provient de la version à noyau chargé en `$D000`. Le tas commence réellement
juste après la fin du BSS.

### 5.3 Libre — `$D333–$DFEE` (3260 octets)

Non utilisé par le BIOS aujourd'hui. C'est la seule réserve d'extension du
système : y placer un buffer, ou agrandir le BSS, est sans risque tant que
`__bss_end__` reste sous `HEAP_START` — ce qui est garanti par construction,
puisque le tas est défini comme partant de `__bss_end__`.

### 5.4 Pile matériel — depuis `$DFEF`, vers le bas

```asm
RAM_TOP  equ $dFeF
    lds  #RAM_TOP
```

La pile croît **vers le bas** et partage la zone 5.3 avec le tas. Une allocation
qui s'approcherait de `$DFEF` entrerait en collision avec la pile. La frame
native 6309 fait 14 octets, `PC` à `S+12` — voir `bios/IT.asm:364`.

### 5.5 Vecteurs RAM — `$DFF0–$DFFD` (14 octets)

`section .ram_vectors`, 7 vecteurs de 2 octets : `SWI3`, `SWI2`, `FIRQ`, `IRQ`,
`SWI`, `NMI`, `TRAP`. Remplis au boot par `vectors.asm:__start`.

Cette zone est **RAM**, pas ROM : elle ne doit surtout pas être gravée dans
l'image EPROM. C'est le rôle du filtre appliqué par `bios/Makefile` :

```sh
grep -vE "^S10FDFF2|^S[0-9]3DFF2" osm39.srec > osm39.filtered.srec
```

Le filtre retire les enregistrements S-Record à partir de `$DFF2`. Ne supprimez
pas ce filtre : `bios/srec2bin.py` mapperait alors des octets de RAM dans
l'EPROM.

## 6. `$E000–$FFFF` — BIOS en EPROM (8 Ko)

`--section-base=.code=0xE000`. L'image finale `bios/osm39.bin` fait exactement
8192 octets, `$FF` pour les trous (`srec2bin.py`).

| Adresse | Longueur | Module | Rôle |
|---|---:|---|---|
| `$E000` | `$0152` | `vectors.o` | `__start`, `LDMD #$01` (mode natif), table de dispatch |
| `$E152` | `$082D` | `main.o` | Moniteur, `reg_cmd`, `Pager`, `FarRead`, `FarWrite` |
| `$E97F` | `$027B` | `SD.o` | Pilote carte SD |
| `$EBFA` | `$0266` | `keyboard.o` | Initialisation de l'ACIA clavier, acquisition |
| `$EE60` | `$0455` | `IT.o` | Interruptions : VSYNC, NMI, TRAP 6309 |
| `$F2B5` | `$04FE` | `osmfs.o` | Système de fichiers OSMFS |
| `$F7B3` | `$0046` | `filename.o` | Formatage des noms 8.3 |
| `$F7F9` | `$0080` | `fload.o` | Chargement et exécution des binaires |
| `$F879` | `$0159` | `video.o` | CRTC 68B45, écriture VRAM |
| `$F9D2` | `$0073` | `audio.o` | Musique |
| | | | **fin de `.code` : `$FBB5`** (sans splash.o, sans moniteur : SECOURS seul ; `make -C bios` affiche la place libre et échoue au-delà de `$FFDF`) (mesurée le 10 oct. 2026 ; les lignes au-dessus sont antérieures et à re-mesurer) |
| `$FFE0` | `$0006` | `farcall.o` | `.romjmp` — table de sauts à adresse FIXE : `$FFE0` `FAR_CALL`, `$FFE3` `FAR_CALLN` (n'ajouter qu'à la fin, jusqu'à `$FFEF`) |
| `$FFF0` | `$0010` | `vectors.o` | `.vectors` — vecteurs matériels, 16 octets |

Il reste donc `$FA45–$FFEF` libres dans l'EPROM (1451 octets) si le BIOS doit
grandir.

### Chaîne de démarrage

```text
réinitialisation → __start (vectors.asm) → mode natif → init BSS → init vecteurs
      → init SD → mount → jingle → BRA Monitor (moniteur, PAS de chargement auto)
      → [opérateur tape BOOT] → LoadandExec "SHELL" page 0, $0000 → shell
```

**Le BIOS ne charge aucun programme au démarrage.** `bios/main.asm:141` fait
`BRA Monitor` juste après `clr current_page` et `jsr boot_jingle` : le chemin
`bootloader:` qui suit (`main.asm:145`) n'est **pas** dans le flux de boot. Il
est atteint par la commande moniteur **`BOOT`** (`main.asm:926`, `FCN "BOOT"` /
`FDB bootloader`), qui est la seule voie de chargement de `SHELL` prévue. C'est
une nuance qui trompe : la documentation de déploiement annonçait un
chargement automatique, et `BOOT` se lit comme un programme nommé « boot ».

Il n'y a **pas de noyau**. `KERNEL_START = $0000` est l'adresse de chargement de
`SHELL`, et `KERNEL_LOAD_ADDR` l'alias utilisé par le chargeur. Le nom de boot
est `KERNEL_FILENAME: FCC "SHELL          "` dans `bios/main.asm` — changez-le
là, pas dans le répertoire de la carte SD. `bootloader` fait `CLRA` (`main.asm:151`),
donc **page 0**.


## 7. Conséquences pour les programmes

- Un programme utilisateur est lié à `$0000` et s'exécute dans la fenêtre
  paginée. Il doit savoir sur quelle page il tourne, et le BIOS doit lui
  rendre cette page avant tout retour.
- Ne comptez sur rien entre `$D333` et `$DFEF` : c'est non alloué aujourd'hui,
  mais la pile occupe la même zone par le haut.
- Les buffers qui doivent survivre à un changement de page pendant un appel BIOS
  vont dans la RAM système, pas dans la fenêtre paginée.
- `$9000–$9FFF` est la RAM vidéo couleurs depuis la V4 : rien d'autre ne doit y aller.

### Où en est le chantier « un programme utilise les 4 pages »

État vérifié dans le code, parce que les deux exemples que vous citez ne sont pas
au même point.

**L'assembleur `asm/asm.asm` est le seul consommateur multipage qui marche, et il
utilise 2 pages sur 4 :**

| Page | Rôle | Code |
|---:|---|---|
| 1 | l'assembleur lui-même + le source chargé en mémoire | `asm.asm:4` « Charge : page 1, $0000 » |
| 2 | le binaire en cours d'émission | `asm.asm:169-171`, `asm.asm:196` |

Le mécanisme de flux existe et fonctionne : `FlushOutBuf` (`asm.asm:2073`) expédie
un tampon local de 256 octets de la page 1 vers la page 2 par
`bsc_FarWrite` (`A` = 2 destination, `B` = 1 source), à chaque fois que le tampon
est plein (`asm.asm:2063`). C'est exactement le motif dont le projet a besoin.

Mais les deux limites sont **asymétriques**, et c'est ce qui surprend :

| Ce qui est limité | Limite | Contrôle |
|---|---:|---|
| le **source** en entrée | **8 Ko** | `MAX_SRC EQU 8192` (`asm.asm:47`), testé `cmpu #MAX_SRC : lbhs ErrTooBig` (`asm.asm:117-118`) |
| la **sortie** | 32 Ko (une page) | **aucun contrôle** : `OutPtr` est un 16 bits qui déborde au-delà de `$7FFF` sans être testé |

Donc aujourd'hui : un source de 20 Ko est **refusé**, alors qu'une sortie de
32 Ko passe. Le goulot est du côté de la lecture, pas de l'écriture.

Le prolongement du travail tient en trois événements, pas en une refonte :

1. **Sortie** : dans `FlushOutBuf`, quand `OutPtr` atteint `$8000`, passer la
   destination à la page 3. Le service est déjà là ; seul le numéro de page est
   en dur à deux endroits (`asm.asm:198` et `asm.asm:2081`).
2. **Source** : au lieu de charger le source entier en mémoire
   (`asm.asm:136-141`, `cmpu #MAX_SRC` puis `bsc_FS_LoadFile` vers `src_buf`), le
   lire par blocs. Attention : la couche OSMFS refuse les fichiers de plus de
   64 Ko ; elle passe d'une page à la suivante depuis le 10 oct. 2026.
3. **`+24`/`+25`** : sans écrivain, `ASM` ne peut pas être *placé* en page 1
   comme son en-tête l'annonce. Il est aujourd'hui chargé en page 0, par-dessus le
   shell.

**`vi/vi.asm` n'a rien** : aucun usage de `FarRead`/`FarWrite`/`sys_pager`, aucune
gestion de taille. Il appelle `FS_LoadFile` et `FS_SaveFile` directement
(`vi/load.asm:30`, `vi/save.asm:76`), donc il est plafonné par la limite de
64 Ko de la couche FS, et par son propre tampon. OSMFS passe d'une page à la
suivante depuis le 10 oct. 2026 : EDIT (`apps/edit.asm`) en profite, VI non.

## 8. Ce qui n'existe pas

Écrit ici exprès, parce que les documents qui les décrivaient ont été retirés et
que leur absence n'est pas évidente. Attention à distinguer ce qui est **absent**
de ce qui est **seulement non géré** :

- **Pas de noyau.** `kernel/` n'existe plus. Pas d'ordonnanceur, pas de
  multitâche, pas de processus, pas de changement de contexte.
- **Pas de « paged buffer » (pbuf).** Les services 64–80, `bios/pbuf.asm` et
  `PBUF_SCRATCH` à `$D000` ont été supprimés. Le tampon de transit qui reste,
  `far_transit_buffer` (256 octets à `$C6D3`), n'a rien à voir : c'est un relais
  de 256 octets pour copier par blocs, pas un buffer paginé.
- **Pas d'allocation de pages, et pas d'écriture du champ page.** La capacité de
  charger sur une page quelconque existe au niveau du service — `loadandexec`
  reçoit page et adresse en A et Y — mais **le chemin « depuis un fichier sur la
  carte SD » ne peut pas l'atteindre** : voir §2, « Le champ "page de boot" de
  OSMFS n'est écrit par personne ». En pratique tout programme lancé depuis le
  shell arrive en page 0 à `$0000`.
  Ce qui manque, et c'est l'essentiel : un écrivain pour `+24`/`+25`, un
  ordonnanceur de propriété des pages, et une validation du numéro de page.
  `basic69`, lié en `0x5A00`, ne peut donc pas être lancé par le shell tel quel :
  il lui faudrait une entrée dont `+24`/`+25` sont renseignés, donc un chemin
  d'écriture qui n'existe pas encore.
- **Pas de registre de pages.** `current_page` est un octet miroir, pas une
  table : il ne dit pas quel programme occupe quelle page.
- **Pas de validation de page.** Aucun service ne contrôle que le numéro écrit
  dans `$A0C0` est bien dans 0–3.
- **Fichiers sur plusieurs pages (depuis le 10 oct. 2026).** `FS_LoadFile` et
  `FS_SaveFile` passent de `$7FFF` à `$0000` de la page **suivante**
  (`Fs_ToFar` / `Fs_FromFar` dans `osmfs.asm`) et refusent d'aller au-delà de la
  page 3 (C = 1). Une adresse ≥ `$8000` (mémoire commune) est copiée directement.
  Un fichier fait au plus 64 Ko (`lbne Load_Error` sur le mot haut de la
  taille). `FS_SaveFile` mesure maintenant les fichiers existants sur 32 bits
  (l'ancien `(taille + 511) >> 9` 16 bits débordait au-delà de 65 024 octets).
  Vérifié hors carte par `test/verifie_fs.py`.
- **`$9000–$BFFF` n'est pas « 16 Ko de périphériques »** comme l'affirmait la
  version précédente : seuls `$8000–$9FFF` (vidéo, couleurs en `$9000` depuis
  la V4) et `$A000–$A1FF` (I/O) sont mappés.
