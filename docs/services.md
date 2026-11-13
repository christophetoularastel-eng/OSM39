# Services du BIOS : le contrat

Généré par `python3 test/verifie_contrat.py --doc` depuis `test/contrat_services.py` :
ne pas éditer ici. Chaque ligne est mesurée sur le vrai BIOS par
`make -C test contrat`.

Appel : `JSR [table_function_ram+sys_XXX]` (`bios/sysfunc.inc`, `bios/hardware.inc`).
Retenue : quand la sortie dit C, C = 1 échec et C = 0 réussite ; sinon elle ne signifie rien.
Un registre qui n'est ni une sortie ni
« détruit » est rendu tel quel (A B E F X Y U, DP et la pile) ; les autres bits de
CC ne sont pas garantis. Les noms de fichier sont de 15 octets, mis en forme par
`Format_Filename_83`. « BIOS2 » : sans `/BIN/BIOS2`, le service rend C = 1.

| n° | Service | Entrée | Sortie | Détruit | Notes |
|---:|---|---|---|---|---|
| 0 | `FS_RenameFile` | X -> ancien nom, Y -> nouveau nom (15 octets, `Format_Filename_83`) | C | E F | BIOS2. Le nouveau nom donne le dossier d'arrivée (`"LIB/UI.INC"` déplace ; `"LIB/"` garde le nom). Refuse un nom pris et un dossier mis dans lui-même. |
| 1 | `scan_keyboard` | - | A = caractère (jamais 0) | B | Attend une touche (rendue au relâchement). Jette une file déjà lue par un programme qui lit `SCAN_CODE` lui-même. Codes spéciaux `$80-$8B` : `lib/ui.inc`. |
| 2 | `read_line` | - | `input_buffer` = la ligne (NUL final), X = sa fin | A B | Attend Entrée ; écho à l'écran ; Ret. arr. efface. |
| 3 | `PrintChar` | A = caractère | - | - | Écran seulement (jamais la liaison série), attribut `char_attribut`. `$0C` efface, `$09` tabule. Attend si le tampon de 256 est plein. |
| 4 | `PrintString` | X -> chaîne (NUL final) | - | - |  |
| 5 | `PrintHexChar` | A = octet | - | A | Deux chiffres hexadécimaux. A n'est PAS rendu (il reste son chiffre bas). |
| 6 | `PrintHexWord` | D = mot | - | - | Quatre chiffres. |
| 7 | `PrintCRLF` | - | - | - | LF puis CR. |
| 8 | `PrintFileName83` | - | C = 1 | - | Retiré (moniteur). |
| 9 | `FS_Mount` | - | A = 0 | - | Pas de superbloc : remet l'état de lecture à zéro. Le BIOS l'a déjà fait au démarrage. |
| 10 | `FS_FindFirst` | - | C = 0 : `g_find_fileInfo` = la première entrée du dossier courant | E F Y | Puis `FS_FindNext`. `g_find_fileInfo+30` = numéro de l'entrée + 1. |
| 11 | `FS_FindNext` | - | C = 0 : entrée suivante dans `g_find_fileInfo` ; C = 1 : fin | E F |  |
| 12 | `FS_GetNextCluster` | - | C = 1 | - | Sans objet (fichiers contigus). |
| 13 | `FS_LoadFile` | X -> nom (15), A = page, Y = adresse | C ; U = taille (16 bits bas) | E F | Continue en `$0000` de la page suivante après `$7FFF` (64 Ko, page 3 au plus). Y >= `$8000` : copie directe. Nom sans chemin introuvable : réessaie dans /BIN, puis à la racine. La page de l'appelant revient. |
| 14 | `FS_FindEntry` | X -> nom (15) | C ; D = premier secteur (16 bits bas), U = taille (16 bits bas) | E F | Repli /BIN puis racine comme `FS_LoadFile`. `s_entry_lba`/`s_entry_offset` = l'entrée. |
| 15 | `FS_ListRoot` | - | A = 0 | E F | BIOS2. Affiche le dossier courant. |
| 16 | `FS_SaveFile` | X -> nom (15), A = page source, Y = source, U = taille | C | E F | BIOS2. Crée TOUJOURS une nouvelle entrée : effacer l'ancien fichier d'abord. Source sur deux pages comme `FS_LoadFile`. |
| 17 | `reg_cmd` | - | C = 1 | - | Retiré (moniteur ; `MONITEUR R` sur la carte). |
| 18 | `FS_ClusterToLBA_Offset` | - | C = 1 | - | Sans objet (fichiers contigus). |
| 19 | `Format_Filename_83` | X -> nom ou chemin (NUL final), Y -> tampon de 16 octets | tampon = dernier composant, majuscules, complété de blancs (15) | E F | Avec un `/` (`../LIB/UI.INC`, `/APPS/X`) : les dossiers sont résolus et retenus pour ce tampon (4 au plus, `fs_slots`) ; dossier introuvable : les `FS_*` échoueront. À appeler avant tout `FS_*` qui prend un nom. La retenue ne signifie rien. |
| 20 | `strcpy` | X -> source, Y -> destination (NUL final copié) | - | - |  |
| 21 | `strlen` | X -> chaîne | D = longueur | - |  |
| 22 | `Pager` | A = page | la page A est visible en `$0000-$7FFF` | - | Ne vérifie rien (page > 3 : adresse inconnue). Le code qui l'appelle doit être hors de la page qu'il quitte (RAM système, EPROM). |
| 23 | `LoadandExec` | X -> nom (15), A = page, Y = adresse | C | E F U | Charge, appelle en Y (JSR), puis remet la page 0 : pour un appelant de la page 0. Les registres au retour sont ceux de l'entrée, pas ceux du programme. |
| 24 | `ls_cmd` | - | C = 1 | - | Retiré (commande `LS` sur la carte). |
| 25 | `malloc_sys` | D = taille | X = bloc, ou 0 (plein) | Y | Tas système de 256 octets (le SHELL). Pas de retenue. |
| 26 | `free` | X = bloc (0 : rien) | - | X | Pas de retenue. |
| 27 | `FS_DeleteFile` | X -> nom (15) | C | E F U | BIOS2. Refuse un dossier non vide. |
| 28 | `FS_GetAttributes` | X -> nom (15) | C ; A = attributs | E F U | Bit 0 x, 1 w, 2 r, 3 caché, 4 application, 5 dossier. |
| 29 | `FS_SetAttributes` | X -> nom (15), A = attributs | C | E F U | BIOS2. |
| 30 | `FarRead` | A = page source, B = page destination, X = source, Y = destination, U = taille | - | - | Par blocs de 256 (`far_transit_buffer`), IRQ et FIRQ masquées pendant chaque bloc. À appeler sur la pile système si la pile du programme est dans une page. |
| 31 | `FarWrite` | A = page destination, B = page source, X = source, Y = destination, U = taille | - | - | Comme `FarRead`. |
| 32 | `video_wait_vsync` | E = nombre de trames | C = 0 | - | Les IRQ doivent être démasquées (le compteur avance dans l'IRQ VSYNC). |
| 33 | `snd_play` | X -> partition (`FDB voix1,voix2 / FCB durée`..., `FDB $FFFF`) | - | - | BIOS2. Copiée dans `SND_BUF` (128 octets) sauf si X >= `$C000`. Interrompt le son en cours. Format : `lib/snd.inc`. |
| 34 | `snd_stop` | - | - | - | BIOS2. Le silence vient à la trame suivante. |
| 35 | `Far_Call` | A = page (0-3), X = adresse ; B, Y, U, W passés à l'appelée | D, X, Y, U, W et C rendus par l'appelée | - | L'appelée reçoit A = sa page et doit fixer C elle-même (sinon C est quelconque). Page > 3 : C = 1, rien n'est appelé. Aussi en `$FFE0`. |
| 36 | `Far_CallN` | A = page (0-3), B = n° dans la table `FDB` en `$0000` de la page | comme `Far_Call` | - | L'appelée reçoit X = sa propre adresse. Aussi en `$FFE3`. |
| 37 | `FS_FileInfo` | X -> nom (15), Y -> 14 octets | C ; les octets +16..+29 de l'entrée en Y | E F | Premier LBA (4), taille (4), page, adresse (2), attributs, dossier parent (2) ; tous en big-endian. Pas de repli /BIN. |
| 38 | `FS_ReadSector` | X -> LBA (4 octets BE), Y -> 512 octets | C (`sd_err`) | - | Dans la page visible ou la RAM système. 4 essais. |
| 39 | `FS_SetLoad` | X -> nom (15), A = page, Y = adresse | C | E F | BIOS2. Page et adresse de chargement de l'entrée. |
| 40 | `FS_ChDir` | X -> chemin (NUL final) : `APPS`, `..`, `/`, `/APPS/JEUX` | C | E F | Échec : dossier courant inchangé. Le dossier courant est commun à tous les programmes. |
| 41 | `FS_MkDir` | X -> nom (15, `Format_Filename_83`) | C | E F | BIOS2. Refuse un nom pris. |
| 42 | `FS_Dossier` | D = n° de dossier (0 racine), ou `$FFFF` pour lire | D = dossier courant | - | Le n° est celui de `g_find_fileInfo+30` après `FS_FindNext`. |
| 43 | `FS_DirInfo` | D = n° de dossier (pas 0), Y -> 15 octets ou 0 | C ; D = son parent, son nom en Y | E F | C = 1 : pas un dossier. |
| 44 | `kbd_poll` | - | A = caractère, ou 0 : rien | B | Sans attendre ; à appeler à chaque trame au moins (file de 16 octets). |
| 45 | `Console_Zone` | A = colonne, B = rangée, E = largeur, F = hauteur, Y = attribut (octet bas) ; E = 0 : plein écran | C = 0 | - | BIOS2. La zone est effacée par l'IRQ au fil des trames, le curseur va en haut à gauche. |
| 46 | (réserve) | - | C = 1 | - | Libre. |
| 47 | (réserve) | - | C = 1 | - | Libre. |
