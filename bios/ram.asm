    export __bss_start__, __bss_end__
    export  spin_cnt, spin_on, spin_save, spin_dir, sd_err, sd_retry
    export  fs_dossier, fs_cible, fs_explicite, fs_repli, fs_attr_neuf
    export  fs_slot_suiv, fs_slots, fr_fin, fr_dos, fr_nom15, fs_tmp
    export  boot_chaud, trap_info, sd_absente, son_coupe
    export  serie_brute, serie_tete, serie_queue, serie_buf
    export  kbd_buf, kbd_tete, kbd_queue, kbd_apres_f0
    export  cz_actif, cz_l, cz_h, cz_haut, cz_bas, cz_op, cz_n, cz_ptr, cz_cpt
    export  kbd_echap, gfx_tampon
    export  kbd_verr, kbd_led_dem, kbd_led_cpt, kbd_muet
    export  SCAN_CODE
    export  NEW_CODE
    export  key_on
    export  input_buffer
    export  write_buffer
    export  read_line_ptr
    export  write_line_ptr
    export  load_buffer
    export  read_load_ptr
    export  write_load_ptr
    export  buffer
    export  sd_ctrl
    export  SD_BUFFER
    export  BlockAddr
    export  trap_frame
    export  trap_active
    export  SDHC_Flag
    export  CMD17_Packet
    export  CMD24_Packet
    export  CSD_BUFFER

    export g_find_fileInfo,s_find_currentSector,s_find_currentEntry
    export s_entry_lba,s_entry_offset
    export s_file_size,s_file_bytesLeft,s_file_destPtr
    export s_save_fileNamePtr,s_save_sourcePtr,s_save_bytesLeft,s_save_fileSize
    export s_save_firstSector,s_save_dirEntryLBA,s_save_dirEntryOffset
    export ExeFileNameBuffer,FormattedName
    export table_function_ram,sys_scan_keyboard,sys_read_line,sys_PrintChar,sys_PrintString,sys_PrintHexChar,sys_PrintHexWord
    export sys_PrintCRLF,sys_PrintFileName83,sys_FS_Mount,sys_FS_FindFirst,sys_FS_FindNext,sys_FS_GetNextCluster,sys_FS_LoadFile
    export sys_FS_FindEntry,sys_FS_ListRoot,sys_FS_SaveFile,sys_reg_cmd,sys_FS_ClusterToLBA_Offset,sys_Format_Filename_83,sys_strcpy
    export sys_strlen,sys_pager,sys_loadandexec,sys_ls,sys_malloc_sys,sys_free,sys_FS_DeleteFile,sys_FarRead,sys_FarWrite
    export sys_FS_GetAttributes,sys_FS_SetAttributes, sys_FS_RenameFile, sys_video_wait_vsync,sys_snd_play, sys_snd_stop
    export sys_Far_Call,sys_Far_CallN,sys_FS_FileInfo,sys_FS_ReadSector,sys_FS_SetLoad,sys_FS_ChDir,sys_FS_MkDir,sys_FS_Dossier,sys_FS_DirInfo,sys_kbd_poll,sys_Console_Zone,table_reserve,table_function_ram_end
    export e0_received,last_makecode,PS2_BIT_COUNT,PS2_PARITY
    export argv, argc,current_page
    export vsync_tick,SCREEN_START_OFFSET
    export MUSIC_PTR, MUSIC_TIMER, SND_BUF, char_attribut,far_transit_buffer

    section .bss

__bss_start__:

table_function_ram:
sys_FS_RenameFile   rmb 2
sys_scan_keyboard rmb 2
sys_read_line rmb 2
sys_PrintChar rmb 2
sys_PrintString rmb 2
sys_PrintHexChar rmb 2
sys_PrintHexWord rmb 2
sys_PrintCRLF rmb 2
sys_PrintFileName83 rmb 2
sys_FS_Mount rmb 2
sys_FS_FindFirst rmb 2
sys_FS_FindNext rmb 2
sys_FS_GetNextCluster rmb 2
sys_FS_LoadFile rmb 2
sys_FS_FindEntry rmb 2
sys_FS_ListRoot rmb 2
sys_FS_SaveFile rmb 2
sys_reg_cmd rmb 2
sys_FS_ClusterToLBA_Offset rmb 2
sys_Format_Filename_83 rmb 2
sys_strcpy rmb 2
sys_strlen rmb 2
sys_pager rmb 2
sys_loadandexec     rmb 2
sys_ls              rmb 2
sys_malloc_sys      rmb 2
sys_free      rmb 2
sys_FS_DeleteFile      rmb 2
sys_FS_GetAttributes   rmb 2
sys_FS_SetAttributes   rmb 2
sys_FarRead   rmb 2
sys_FarWrite   rmb 2
sys_video_wait_vsync   rmb 2
sys_snd_play    rmb 2
sys_snd_stop     rmb 2
sys_Far_Call     rmb 2
sys_Far_CallN    rmb 2
sys_FS_FileInfo  rmb 2
sys_FS_ReadSector rmb 2
sys_FS_SetLoad   rmb 2
sys_FS_ChDir     rmb 2
sys_FS_MkDir     rmb 2
sys_FS_Dossier   rmb 2
sys_FS_DirInfo   rmb 2
sys_kbd_poll     rmb 2      ; clavier sans attente : A = caractère, ou 0
sys_Console_Zone rmb 2      ; console limitée à un rectangle (E = 0 : plein écran)
; Réserve : la table a une taille FIXE (TABLE_OCTETS dans update_includes.py),
; pour qu'un nouveau service ne décale plus la RAM système qui suit. Ajouter
; un service = un `sys_X rmb 2` juste au-dessus ET 2 octets de moins ici ;
; dans vectors.asm, un `fdb X` à la même place ET un `fdb Sys_Absent` de moins.
table_reserve:   rmb 4
table_function_ram_end:

SCAN_CODE:       RMB 1
NEW_CODE:        RMB 1

key_on:         RMB 1

load_buffer:    RMB 256
write_buffer:    RMB 32

read_load_ptr:   RMB 2
write_load_ptr:  RMB 2

; 128 octets, et NON PAS 32 : ce buffer EST la ligne de saisie série
; (IT.asm : `line_ptr: equ input_buffer`, borné par `CMPX #line_ptr+127`),
; et le shell déclare `MAX_INPUT_LEN EQU 128`. En 32 octets, toute ligne plus
; longue écrasait read_line_ptr, write_line_ptr puis le début de SD_BUFFER.
; (basic69 prend `char_attribut` dans hardware.inc, plus en dur.)
input_buffer:   RMB 128
read_line_ptr:   RMB 2
write_line_ptr:  RMB 2

buffer:          rmb $10

sd_ctrl:         RMB 1          ; copie de SD_CTRL ($A140, écriture seule : bios/SD.asm)

SD_BUFFER:      RMB     512
BlockAddr:      RMB     4
SDHC_Flag:      RMB     1

CSD_BUFFER: RMB 16

CMD17_Packet:   RMB 6

CMD24_Packet:   RMB 6

g_find_fileInfo:         rmb   32

; --- Directory scan ---
s_find_currentSector:    rmb   4
s_find_currentEntry:     rmb   1

; --- Entry info (from FindEntry) ---
s_entry_lba:             rmb   4
s_entry_offset:          rmb   2

; --- File load ---
s_file_size:             rmb   4
s_file_bytesLeft:        rmb   4
s_file_destPtr:          rmb   2

ExeFileNameBuffer: rmb 16
FormattedName:     rmb 16

; --- File save ---
s_save_fileNamePtr:      rmb   2
s_save_sourcePtr:        rmb   2
s_save_bytesLeft:        rmb   4
s_save_fileSize:         rmb   4
s_save_firstSector:      rmb   4
s_save_dirEntryLBA:      rmb   4
s_save_dirEntryOffset:   rmb   2

e0_received:    rmb 1
last_makecode:  rmb 1
PS2_BIT_COUNT:  rmb 1
PS2_PARITY:     rmb 1
argv:   rmb 20
argc:   rmb 1
current_page: rmb 1
vsync_tick:	rmb 2
; --- Constantes ---


; --- Variables RAM (Idéalement en Direct Page pour aller plus vite) ---
BUF_HEAD:    RMB 1           ; Pointeur d'écriture (Modifié par le programme OS)
BUF_TAIL:    RMB 1           ; Pointeur de lecture (Modifié par l'IRQ)
VRAM_PTR:    RMB 2           ; Pointeur direct dans la VRAM ($8000 à $8FFF)
CUR_PAGE:    RMB 1           ; La page actuelle (0 à 7, pour D0/D1/D2 de $A120)
vram_line_ptr:      RMB 2

; --- Buffers Circulaires (Alignés pour un index 8 bits) ---
ASCII_BUF:   RMB 256         ; Buffer de 256 octets pour les caractères
COLOR_BUF:   RMB 256         ; Buffer de 256 octets pour les attributs
SCREEN_START_OFFSET:  RMB 2   ; Offset du haut de l'écran ($FFFF = -1, sinon 0 à 1696)
MUSIC_PTR:   RMB 2           ; Pointeur de lecture de la partition (0000 = Stop)
MUSIC_TIMER: RMB 1           ; Compte à rebours avant la ligne suivante
char_attribut: RMB 1
trap_frame:  RMB 32          ; Diagnostic TRAP 6309 : frame(14) + SP(2) + pile(16)
far_transit_buffer:     RMB 256
;readkey2_ptr:   rmb 2
;key2_ptr:    rmb 2
;key2_buffer: rmb 256
; Place en TOUTE FIN : rien au-dessus ne bouge, donc argv/argc/input_buffer
; gardent leurs adresses et le binaire SHELL reste identique.
trap_active: RMB 1          ; 1 = deja dans handler_TRAP (garde anti-boucle)
SND_BUF:    RMB 128
; Moulinet des transferts SD (osmfs.asm), en toute fin lui aussi : aucune
; adresse ne bouge (hardware.inc inchangé).
spin_cnt:   RMB 1           ; secteurs transférés (le moulinet tourne avec)
spin_on:    RMB 1           ; <>0 : cellules sauvées, moulinet affiché
spin_save:  RMB 4           ; 2 caractères puis 2 couleurs sous le moulinet
spin_dir:   RMB 1           ; 'L' lecture, 'E' écriture
; Diagnostic SD (osmfs.asm, Fs_ReadBlk / Fs_WriteBlk), lisible par MEM :
sd_err:     RMB 1           ; code de la dernière erreur SD ($E1-$E5), 0 = aucune
sd_retry:   RMB 1           ; nouvelles tentatives depuis le démarrage (plafonné à 255)
; --- Dossiers (osmfs.asm) ---
fs_dossier:  RMB 2          ; dossier courant : 0 = racine, sinon n° d'entrée + 1
fs_cible:    RMB 2          ; dossier de l'opération en cours
fs_explicite: RMB 1         ; 1 : le nom portait un chemin (pas de repli racine)
fs_repli:    RMB 1          ; 1 : une lecture introuvable réessaie à la racine
fs_attr_neuf: RMB 1         ; attributs d'une nouvelle entrée (FS_MkDir : d)
fs_slot_suiv: RMB 1         ; prochain emplacement de fs_slots à réutiliser
fs_slots:    RMB 4*20       ; nom formaté par Format_Filename_83 avec un chemin :
                            ; adresse (2), page (1), dossier (2), nom (15)
fr_fin:      RMB 2          ; Fs_Resoudre : fin du chemin
fr_dos:      RMB 2          ;               dossier atteint
fr_nom15:    RMB 16         ;               composant formaté
fs_tmp:      RMB 2
; --- Démarrage et TRAP (main.asm, IT.asm) ---
boot_chaud:  RMB 1          ; <>0 : redémarrage après un TRAP (pas de fenêtre de secours)
trap_info:   RMB 32         ; complète trap_frame, lu par MONITEUR (R) :
                            ; +0 $A5 si valide, +1 page, +2 page vidéo, +3 SCREEN_START_OFFSET,
                            ; +5 VRAM_PTR, +7 vsync_tick, +9 vsync_tick un peu après
                            ; (différent : l'IRQ VSYNC vit), +11 read_line_ptr,
                            ; +13 write_line_ptr, +15 16 octets à partir de PC-4
sd_absente:  RMB 1          ; <>0 : Init_SD_Card a échoué (démarrage : SECOURS)
son_coupe:   RMB 1          ; $4D : son coupé (touche M d'OSM-VISION), lu par
                            ; toutes les copies de lib/vision.asm
; --- Liaison série en mode brut (IT.asm, handler_NMI) ---
; serie_brute <> 0 : chaque octet reçu va dans serie_buf[serie_tete++]
; (anneau de 256), sans écho, sans tampon de ligne, sans Ctrl+A. Le
; programme lit serie_buf[serie_queue++] tant que queue <> tete. Anneau
; plein : l'octet est perdu. Remis à 0 par Demarrage et Secours.
serie_brute: RMB 1
serie_tete:  RMB 1          ; écrit par la NMI seule
serie_queue: RMB 1          ; écrit par le programme seul
serie_buf:   RMB 256
; --- File du clavier (IT.asm remplit, keyboard.asm vide) ---
; La NMI range chaque octet PS/2 dans kbd_buf[kbd_tete++] (16, anneau) EN
; PLUS de SCAN_CODE/NEW_CODE (lus tels quels par ENVAHIS, le démarrage).
; kbd_poll/scan_keyboard le reprennent dans l'ordre : un programme lent
; ne perd plus un code écrasé par le suivant.
kbd_buf:     RMB 16
kbd_tete:    RMB 1          ; écrit par la NMI seule
kbd_queue:   RMB 1          ; écrit par kbd_poll seul
kbd_apres_f0: RMB 1         ; 1 : l'octet suivant est un code de relâchement
; --- Zone console (video.asm : Console_Zone ; IT.asm : Zone_IRQ) ---
; cz_actif <> 0 : la console n'écrit que dans le rectangle (Terminal
; d'OSM-VISION). Pas de défilement matériel : l'IRQ recopie les rangées de
; la zone, par lots, pendant le retour de trame (cz_op).
cz_actif:    RMB 1
cz_l:        RMB 1          ; largeur (colonnes)
cz_h:        RMB 1          ; hauteur (rangées)
cz_haut:     RMB 2          ; adresse VRAM de la case en haut à gauche
cz_bas:      RMB 2          ;                          en bas à gauche
cz_op:       RMB 1          ; travail en cours : 0 rien, 1 défilement, 2 effacement
cz_n:        RMB 1          ; rangées qui restent à traiter
cz_ptr:      RMB 2          ; rangée en cours
cz_cpt:      RMB 1          ; caractères encore permis dans cette trame
; --- Échap (IT.asm, handler_NMI) : $80 dès que le code PS/2 d'Échap ($76)
; arrive. Lu tel quel par le BBC BASIC (son drapeau d'échappement), remis
; à 0 par qui le traite. ---
kbd_echap:   RMB 1
; --- Tampon de 512 octets pour un programme (BBC BASIC : graphisme, la
; table inverse des mosaïques et les cellules à réécrire au retour de
; trame). Le BIOS n'y touche pas ; en RAM commune, lisible dans toutes les
; pages. Un seul utilisateur à la fois (le programme au premier plan). ---
gfx_tampon:  RMB 512
; --- Verr. Maj et voyants du clavier (ajoutés à la fin : rien ne bouge
; pour les programmes déjà construits). kbd_poll bascule kbd_verr et
; demande les voyants ; l'IRQ envoie $ED puis, deux trames plus tard,
; l'octet des voyants ; la NMI jette ce que le clavier renvoie pendant
; kbd_muet trames (l'écho de l'envoi, l'accusé $FA lu décalé d'un bit). ---
kbd_verr:    RMB 1          ; octet des voyants : bit 2 = Verr. Maj
kbd_led_dem: RMB 1          ; <>0 : voyants à envoyer
kbd_led_cpt: RMB 1          ; <>0 : trames avant l'octet des voyants ($ED parti)
kbd_muet:    RMB 1          ; <>0 : la NMI jette les octets du clavier
__bss_end__:
