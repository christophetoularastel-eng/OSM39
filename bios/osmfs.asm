; ===================================================================
; osmfs.asm - OSMFS Custom Filesystem for OSM09
; Contiguous-allocation FS for SD card (bit-banged SPI)
; Entry format inspired by EgoFS: 32 bytes, 15-char names, no 8.3
; No superblock: LBA 0=boot, LBA 1=root dir, LBA 2+=data
; ===================================================================
    include "hardware.inc"
    include "sysfunc.inc"

    import  SD_ReadBlock, SD_WriteBlock
    import  BlockAddr, SD_BUFFER
    import  table_function_ram, current_page

    import  s_entry_lba, s_entry_offset
    import  s_find_currentSector, s_find_currentEntry
    import  g_find_fileInfo
    import  s_file_size, s_file_bytesLeft, s_file_destPtr
    import  s_save_fileNamePtr, s_save_sourcePtr, s_save_bytesLeft, s_save_fileSize
    import  s_save_firstSector, s_save_dirEntryLBA, s_save_dirEntryOffset
    import  spin_cnt, spin_on, spin_save, spin_dir, SCREEN_START_OFFSET, gr_actif
    import  sd_err, sd_retry
    import  fs_dossier, fs_cible, fs_explicite, fs_repli, fs_attr_neuf
    import  fs_slot_suiv, fs_slots, fr_fin, fr_dos, fr_nom15, fs_tmp

    export  FS_Mount
    export  X_FS_SaveFile, X_FS_DeleteFile, X_FS_SetAttributes, X_FS_RenameFile
    export  X_FS_MkDir, X_FS_SetLoad, X_FS_ListRoot
    include "ext.inc"
    import  ExtV
    export  Fs_ReadBlk              ; (ext.asm : chargement de BIOS2)
    export  Spin_IRQ                ; (IT.asm : le moulinet au retour de trame)
    export  FS_FindEntry, FS_LoadFile
    export  FS_FindFirst, FS_FindNext
    export  FS_ListRoot
    export  FS_SaveFile, FS_DeleteFile
    export  FS_GetNextCluster, FS_ClusterToLBA_Offset
    export  FS_GetAttributes, FS_SetAttributes
    ;export  Divide_Y_by_X_16
    export  FS_RenameFile
    export  FS_FileInfo, FS_ReadSector, FS_SetLoad
    export  FS_ChDir, FS_MkDir, FS_Dossier, FS_DirInfo, Format_Filename_83

    section .code

; ===================================================================
; OSMFS Format Constants
; ===================================================================
; Root dir at LBA 1-256 (ROOT_DIR_SIZE sectors x 16 entries of 32 bytes).
; Data starts at LBA 257 (DATA_START_LBA), contiguous allocation.
;
; Directory entry (32 bytes):
;   +0  Status (1): $01=valid, $00=free, $E5=deleted
;   +1  Name (15), space-padded
;   +16 First sector LBA (4), big-endian
;   +20 File size in bytes (4), big-endian
;   +24 Boot page (1)
;   +25 Boot address (2), big-endian
;   +27 Attributes (1): bit2=r bit1=w bit0=x bit3=hidden bit4=app bit5=dossier
;   +28 Dossier parent (2, BE) : 0 = racine, sinon n° de l'entrée du dossier
;       + 1 (n° = (LBA - 1) * 16 + rang dans le secteur). Une carte d'avant
;       les dossiers a 0 partout : tout y est à la racine.
;   +30 Reserved (2). FS_FindNext y écrit, DANS SA COPIE g_find_fileInfo, le
;       n° + 1 de l'entrée (pour entrer dans un dossier avec FS_Dossier).
;
; Dossiers : une entrée d'attribut d (taille 0). Pas de fichier-répertoire :
; une seule table de 4096 entrées, chaque entrée nomme son parent.
; Le dossier courant est fs_dossier. Un nom formaté par Format_Filename_83
; à partir d'un chemin ("../LIB/UI.INC") garde son dossier dans fs_slots
; (clé : adresse et page du tampon, et le nom lui-même) ; FS_* le retrouve
; à partir de X. Sans chemin : le dossier courant. Une LECTURE (FS_FindEntry,
; FS_LoadFile, FS_GetAttributes) d'un nom sans chemin, introuvable dans le
; dossier courant, réessaie dans /BIN puis à la racine : les programmes
; s'y rangent et se lancent de partout.

DE_OFF_STATUS   equ 0
DE_OFF_NAME     equ 1
DE_OFF_FIRST    equ 16
DE_OFF_SIZE     equ 20
DE_OFF_PAGE     equ 24
DE_OFF_ADDR     equ 25
DE_OFF_ATTR     equ 27
DE_ENTRY_LEN    equ 32
ENTRIES_PER_SEC equ 16

ROOT_DIR_LBA    equ 1
ROOT_DIR_SIZE   equ 256
DATA_START_LBA  equ 257

MARK_VALID      equ $01
MARK_FREE       equ $00
MARK_DELETED    equ $E5

ATTR_EXEC       equ $01
ATTR_WRITE      equ $02
ATTR_READ       equ $04
ATTR_HIDDEN     equ $08
ATTR_DEFAULT    equ ATTR_READ+ATTR_WRITE+ATTR_EXEC  ; rwx = $07
ATTR_DIR        equ $20
DE_OFF_PARENT   equ 28
DE_OFF_ID       equ 30
FS_SLOT         equ 20
FS_NSLOTS       equ 4

; ===================================================================
; FS_Mount - Initialize filesystem (no superblock)
; Entry: none
; Exit:  A=0 success
; ===================================================================
FS_Mount:
    clra
    rts

; ===================================================================
; FS_FindEntry - Find file in root directory
; Entry: X -> 15-byte filename (space-padded)
; Exit:  carry=0 found: D=firstSector.low16, U=fileSize.low16
;        carry=1 not found
;        s_entry_lba/s_entry_offset set to entry location
; ===================================================================
FS_FindEntry:
    pshs    a
    lda     #1                  ; lecture : repli sur la racine permis
    bra     fe_go
; Fs_Exact - Comme FS_FindEntry, sans repli (écritures, suppressions).
Fs_Exact:
    pshs    a
    clra
fe_go:
    sta     fs_repli
    puls    a
    jsr     Fs_ParentDe         ; fs_cible, fs_explicite
    jsr     Fs_Scan
    bcc     fe_ret
    tst     fs_repli
    beq     fe_non
    tst     fs_explicite
    bne     fe_non
    ; pas dans le dossier courant : /BIN (comme le PATH de Linux), puis la racine
    clr     fs_cible
    clr     fs_cible+1
    pshs    x
    ldx     #Nom_BIN
    jsr     Fs_Scan             ; BIN, à la racine
    puls    x
    bcs     fe_racine
    lda     g_find_fileInfo+DE_OFF_ATTR
    bita    #ATTR_DIR
    beq     fe_racine
    jsr     Fs_IdEntree
    std     fs_cible
    jsr     Fs_Scan
    bcc     fe_ret
fe_racine:
    ldd     fs_dossier          ; la racine, si on n'y était pas déjà
    beq     fe_non
    clr     fs_cible
    clr     fs_cible+1
    jsr     Fs_Scan
fe_ret:
    rts
Nom_BIN:
    fcc     "BIN            "
fe_non:
    orcc    #%00000001
    rts

; Fs_Scan - X = nom, fs_cible = dossier : l'entrée valide de ce nom dans ce
; dossier. Sortie comme FS_FindEntry.
Fs_Scan:
    pshs    y,x
    pshsw
    tfr     x,u             ; U = filename pointer
    ldw     #ROOT_DIR_SIZE
    clr     s_entry_lba
    clr     s_entry_lba+1
    ldd     #ROOT_DIR_LBA
    std     s_entry_lba+2

Search_Next_Sector:
    clr     BlockAddr
    clr     BlockAddr+1
    ldd     s_entry_lba+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     Find_NotFound

    ldx     #SD_BUFFER
    ldb     #ENTRIES_PER_SEC
Find_EntryLoop:
    lda     ,x
    cmpa    #MARK_FREE
    beq     Find_Abort      ; Le fichier n'existe pas, on arrête les frais !
    cmpa    #$FF
    beq     Find_Abort      ; (Sécurité Flash)
    cmpa    #MARK_VALID
    bne     Find_Skip

    pshs    b,x
    leax    DE_OFF_NAME,x
    tfr     u,y
    ldb     #15
Find_NameCmp:
    lda     ,y+
    cmpa    ,x+
    bne     Find_NoMatch
    decb
    bne     Find_NameCmp
    puls    b,x
    pshs    b                   ; (B : compteur d'entrées du secteur)
    ldd     DE_OFF_PARENT,x     ; dans le bon dossier ?
    cmpd    fs_cible
    puls    b                   ; (PULS ne touche pas les drapeaux)
    bne     Find_Skip

    ; ==========================================================
    ; --- CORRECTIF : Copie de l'entrée dans g_find_fileInfo ---
    ; ==========================================================
    pshs    d,x,y
    ldy     #g_find_fileInfo
    ldb     #DE_ENTRY_LEN   ; 32 octets
Find_CopyInfo:
    lda     ,x+
    sta     ,y+
    decb
    bne     Find_CopyInfo
    puls    d,x,y
    ; ==========================================================

    ; Found! Store entry location
    clr     s_entry_lba
    clr     s_entry_lba+1
    ldd     BlockAddr+2         ; On prend le VRAI secteur où on a trouvé le fichier
    std     s_entry_lba+2

    tfr     x,d
    subd    #SD_BUFFER
    std     s_entry_offset

    ; Return firstSector.low16 in D, fileSize.low16 in U
    ldd     DE_OFF_FIRST+2,x
    pshs    d
    ldd     DE_OFF_SIZE+2,x
    tfr     d,u
    puls    d
    andcc   #%11111110
    pulsw
    puls    y,x,pc

Find_NoMatch:
    puls    b,x
Find_Skip:
    leax    DE_ENTRY_LEN,x
    decb
    bne     Find_EntryLoop

Find_NotFound:
    LDD     s_entry_lba+2
    ADDD #1
    std     s_entry_lba+2
    decw
    lbne Search_Next_Sector
Find_Abort:
    orcc    #%00000001
    pulsw
    puls    y,x,pc

; ===================================================================
; FS_LoadFile - Load file into RAM
; Entry: X -> 15-byte filename, Y -> destination address,
;        A = page de destination (bascule $A0C0, puis current_page rétablie)
; Exit:  carry=0 success, U=fileSize; carry=1 error
; Plusieurs pages : arrivé en $8000, le chargement continue en $0000 de la
; page SUIVANTE (64 Ko au plus, pas au-delà de la page 3 : sinon C=1).
; Y >= $8000 (mémoire commune) : copie directe, sans bascule.
; Note:  s_file_size / s_file_bytesLeft use [0:1]=low16, [2:3]=high16
; ===================================================================
FS_LoadFile:
    pshs    y,x,d
    pshs    a                   ; 0,s = page en cours (avance), 1,s = A d'origine
    lda     #'L'
    jsr     Fs_Spin_Init
    sty     s_file_destPtr
    jsr     FS_FindEntry
    lbcs    Load_Error

; On relit le secteur EXACT où se trouve notre fichier
    ldd     s_entry_lba          ; Poids fort du LBA
    std     BlockAddr
    ldd     s_entry_lba+2        ; Poids faible du LBA
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    lbne    Load_Error

    ldx     #SD_BUFFER
    ldd     s_entry_offset
    leax    d,x

    ldd     DE_OFF_FIRST,x
    std     BlockAddr
    ldd     DE_OFF_FIRST+2,x
    std     BlockAddr+2

    ; File size: 4 bytes big-endian on disk
    ldd     DE_OFF_SIZE+2,x     ; low word
    std     s_file_size
    std     s_file_bytesLeft
    ldd     DE_OFF_SIZE,x       ; high word
    std     s_file_size+2
    std     s_file_bytesLeft+2
    lbne    Load_Error          ; files > 64KB not supported yet

Load_SectorLoop:
    ldd     s_file_bytesLeft
    lbeq    Load_Success

    jsr     Fs_ReadBlk
    tsta
    bne     Load_Error

    ldu     #SD_BUFFER
    ldw     #512                ; W = 512 octets par défaut
    cmpw    s_file_bytesLeft
    bls     Load_Copy
    ldw     s_file_bytesLeft    ; W = reste des octets si < 512
Load_Copy:
    lda     0,s                 ; page en cours
    ldx     s_file_destPtr
    jsr     Fs_ToFar            ; passe à la page suivante en $8000
    bcs     Load_Error
    sta     0,s
    stx     s_file_destPtr
    jsr     Fs_Spin             ; signe de vie, un cran par secteur

    ldd     s_file_bytesLeft
    subd    #512
    bcc     Load_NextSector
    ldd     #0
Load_NextSector:
    std     s_file_bytesLeft

    ldd     BlockAddr+2
    addd    #1
    std     BlockAddr+2
    bcc     Load_SectorLoop
    ldd     BlockAddr
    addd    #1
    std     BlockAddr
    bra     Load_SectorLoop

Load_Success:
    jsr     Fs_Spin_End
    ldu     s_file_size
    leas    1,s
    andcc   #%11111110
    puls    y,x,d,pc

Load_Error:
    jsr     Fs_Spin_End
    leas    1,s
    orcc    #%00000001
    ldu     #0
    puls    y,x,d,pc

; ===================================================================
; Fs_ToFar / Fs_FromFar - copie entre un tampon en mémoire commune (U) et
; la mémoire paginée (page A, adresse X), W octets (W > 0).
; Fs_ToFar : U -> (A,X) ; Fs_FromFar : (A,X) -> U.
; En $8000, la copie continue en $0000 de la page suivante ; une page > 3
; est refusée (C = 1, rien n'est copié dans ce morceau). X >= $8000 au
; départ : mémoire commune, copie directe sans bascule.
; Chaque morceau est copié IRQ masquées, RAM basculée sur la page, puis
; current_page est rétablie : le séquenceur de son (IRQ) lit sa partition
; dans la page visible, il ne doit jamais y trouver une autre page.
; Sortie : C = 0, A = page et X = adresse qui SUIVENT la copie (X = $0000
; de la page suivante si on s'est arrêté pile en $8000), U avancé.
; Détruit D, Y, W.
; ===================================================================
Fs_ToFar:
    clr     ,-s                 ; 0,s = sens (0 : vers la page)
    bra     Far_Copy
Fs_FromFar:
    clr     ,-s
    inc     ,s                  ; 1 : depuis la page
Far_Copy:
    pshs    a                   ; 0,s = page, 1,s = sens
    tfr     w,d
    pshs    d                   ; 0,s = reste, 2,s = page, 3,s = sens
    cmpx    #$8000
    blo     FC_Paged
    tfr     x,y                 ; mémoire commune : tout d'un coup
    tst     3,s
    bne     FC_DirFrom
    tfm     u+,y+
    bra     FC_DirEnd
FC_DirFrom:
    tfm     y+,u+
FC_DirEnd:
    tfr     y,x
    bra     FC_Ok
FC_Paged:
    lda     2,s
    cmpa    #4                  ; pages 0 à 3
    bhs     FC_Err
    ldd     #$8000              ; morceau = min(place dans la page, reste)
    pshs    x
    subd    ,s++
    cmpd    ,s
    bls     FC_Chunk
    ldd     ,s
FC_Chunk:
    pshs    d                   ; 0,s = morceau
    ldd     2,s
    subd    ,s                  ; reste -= morceau
    std     2,s
    pulsw                       ; W = morceau (même ordre que PSHSW : poids fort en premier)
    tfr     x,y
    pshs    cc
    orcc    #%01010000          ; IRQ + FIRQ masquées pendant la bascule
    lda     3,s                 ; page (CC empilé au-dessus)
    sta     $A0C0
    tst     4,s                 ; sens (CC, reste, page empilés au-dessus)
    bne     FC_From
    tfm     u+,y+
    bra     FC_Back
FC_From:
    tfm     y+,u+
FC_Back:
    lda     current_page        ; la page de l'appelant revient
    sta     $A0C0
    puls    cc
    tfr     y,x
    cmpx    #$8000              ; fin de page : la suite est en $0000
    blo     FC_More
    ldx     #0
    inc     2,s
FC_More:
    ldd     ,s
    bne     FC_Paged
FC_Ok:
    leas    2,s
    puls    a
    leas    1,s
    andcc   #%11111110
    rts
FC_Err:
    leas    2,s
    puls    a
    leas    1,s
    orcc    #%00000001
    rts

; ===================================================================
; Moulinet des transferts : un signe de vie pendant les longs
; FS_LoadFile / FS_SaveFile, pour qu'on ne croie pas à un plantage.
; Deux cellules en haut à droite de l'écran VISIBLE (le défilement de la
; console est suivi) : 'L' ou 'E', puis | / - \ qui tourne d'un cran par
; secteur. Rien avant le 3e secteur (plus de 1 Ko) : les petits fichiers
; ne font pas clignoter le coin. Les deux cellules sont sauvées au premier
; affichage et remises à la fin, erreur comprise. V4 : la couleur est
; 4 Ko au-dessus du caractère ; mono : juste après (les deux cases font
; 4 octets contigus). La page vidéo est celle déjà affichée.
; Les trois routines préservent tous les registres (et C).
; ===================================================================
SPIN_DEBUT      equ 2           ; secteurs sans moulinet
SPIN_COL        equ 78          ; 'L'/'E' en colonne 78, moulinet en 79
SPIN_ATTR       equ $1F         ; blanc sur bleu, page 0 du générateur

Fs_Spin_Init:                   ; A = 'L' ou 'E'
    sta     spin_dir
    clr     spin_cnt
    clr     spin_on
    rts

; La VRAM ne se touche qu'au retour de trame (mono : sinon des parasites
; en haut de l'écran) : Fs_Spin et Fs_Spin_End ne font que DEMANDER, et
; Spin_IRQ, au début de l'IRQ du VSYNC, dessine ou remet le dessous.
; spin_on : bit 0 = dessous sauvé (moulinet à l'écran), bit 7 = dessin
; demandé, bit 6 = remise demandée. IRQ masquées chez l'appelant : rien
; n'est demandé (pas de moulinet) ; Fs_Spin_End remet alors le dessous
; elle-même si le moulinet était déjà affiché (seule écriture hors trame).
Fs_Spin:
    pshs    cc,d,x,y
    inc     spin_cnt
    lda     spin_cnt
    cmpa    #SPIN_DEBUT
    bls     FSp_End
    lda     ,s                  ; IRQ masquées : pas de moulinet
    bita    #$10
    bne     FSp_End
    tst     gr_actif            ; mode graphique : la VRAM est l'image
    bne     FSp_End
    oim     #$80,spin_on        ; une instruction : l'IRQ ne la coupe pas
FSp_End:
    puls    cc,d,x,y,pc

Fs_Spin_End:
    pshs    cc,d,x
    orcc    #%00010000
    lda     spin_on
    bita    #$01
    beq     FSe_Rien            ; jamais affiché : on oublie la demande
    lda     ,s
    bita    #$10
    bne     FSe_Direct
    lda     #$41                ; l'IRQ remet le dessous...
    sta     spin_on
    puls    cc                  ; ...IRQ rouvertes, on l'attend (une trame)
    pshs    cc
    ldx     #0
FSe_Att:
    tst     spin_on
    beq     FSe_End
    leax    -1,x
    bne     FSe_Att
FSe_Direct:
    bsr     Spin_Addr
    ldd     spin_save
    std     ,x
    ldd     spin_save+2
    ifne    CARTE_MONO
    std     2,x
    else
    std     VRAM_COL_OFS,x
    endc
FSe_Rien:
    clr     spin_on
FSe_End:
    puls    cc,d,x,pc

; Spin_IRQ : appelée par handler_IRQ au début du retour de trame (IRQ
; masquées). Exécute la demande de spin_on. Détruit A, B, X, Y.
Spin_IRQ:
    lda     spin_on
    bita    #$C0
    beq     SpI_Fin
    bsr     Spin_Addr
    bita    #$40
    beq     SpI_Dessin
    ldd     spin_save           ; remise du dessous
    std     ,x
    ldd     spin_save+2
    ifne    CARTE_MONO
    std     2,x
    else
    std     VRAM_COL_OFS,x
    endc
    clr     spin_on
SpI_Fin:
    rts
SpI_Dessin:
    bita    #$01
    bne     SpI_Pose
    ldd     ,x                  ; premier affichage : on garde le dessous
    std     spin_save
    ifne    CARTE_MONO
    ldd     2,x
    else
    ldd     VRAM_COL_OFS,x
    endc
    std     spin_save+2
SpI_Pose:
    lda     spin_dir
    sta     ,x
    lda     spin_cnt
    anda    #3
    ldy     #Spin_Car
    lda     a,y
    sta     VRAM_PAS,x
    lda     #SPIN_ATTR
    sta     VRAM_COL_OFS,x
    sta     VRAM_COL_OFS+VRAM_PAS,x
    lda     #$01
    sta     spin_on
    rts

; X = adresse (plan caractères) de la cellule SPIN_COL de la rangée du haut
; de l'écran visible, repliée dans la page vidéo de 4 Ko. Détruit B.
Spin_Addr:
    pshs    a
    ldd     SCREEN_START_OFFSET
    addd    #1+SPIN_COL
    anda    #$0F
    ifne    CARTE_MONO
    lslb                        ; case -> octets
    rola
    endc
    adda    #VRAM_BASE/256
    tfr     d,x
    puls    a,pc

Spin_Car:       fcc     "|/-\"

; ===================================================================
; Fs_ReadBlk / Fs_WriteBlk - SD_ReadBlock / SD_WriteBlock, jusqu'à
; SD_ESSAIS fois. Une carte SD câblée à la main rate parfois un secteur
; (bit perturbé, carte en retard sur le jeton) : sur 113 secteurs, une
; seule erreur faisait échouer tout le fichier. Même contrat que les
; routines SD (A = 0 succès, sinon le code de la dernière erreur) ; le
; secteur est relu ou réécrit en entier, BlockAddr et SD_BUFFER ne
; changent pas. Diagnostic : sd_err = dernier code d'erreur, sd_retry =
; nouvelles tentatives depuis le démarrage (MEM pour les lire).
; ===================================================================
SD_ESSAIS       equ 4

Fs_ReadBlk:
    pshs    b
    ldb     #SD_ESSAIS
FRB_Loop:
    pshs    b
    jsr     SD_ReadBlock
    puls    b
    tsta
    beq     FRB_End
    sta     sd_err
    decb
    beq     FRB_End             ; plus d'essai : A = le code d'erreur
    inc     sd_retry
    bne     FRB_Loop
    dec     sd_retry            ; plafonné à 255
    bra     FRB_Loop
FRB_End:
    puls    b,pc

    section .code
Fs_WriteBlk:
    pshs    b
    ldb     #SD_ESSAIS
FWB_Loop:
    pshs    b
    jsr     SD_WriteBlock
    puls    b
    tsta
    beq     FWB_End
    sta     sd_err
    decb
    beq     FWB_End
    inc     sd_retry
    bne     FWB_Loop
    dec     sd_retry
    bra     FWB_Loop
FWB_End:
    puls    b,pc

    section .code

; ===================================================================
; FS_FindFirst - Initialize directory scan
; Entry: none
; Exit:  carry=0 first entry found, carry=1 empty
; ===================================================================
FS_FindFirst:
    pshs    d,x
    clr     s_find_currentSector
    clr     s_find_currentSector+1
    ldd     #ROOT_DIR_LBA
    std     s_find_currentSector+2
    clr     s_find_currentEntry

    clr     BlockAddr
    clr     BlockAddr+1
    ldd     #ROOT_DIR_LBA
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     FindFirst_Error

    puls    d,x
    jmp     FS_FindNext

FindFirst_Error:
    orcc    #%00000001
    puls    d,x,pc

; ===================================================================
; FS_FindNext - Continue directory scan
; Entry: none (uses s_find_currentSector, s_find_currentEntry)
; Exit:  carry=0 found, g_find_fileInfo filled; carry=1 end
; ===================================================================
FS_FindNext:
    pshs    d,x,y,u
FindNext_Loop:
    lda     s_find_currentEntry
    cmpa    #ENTRIES_PER_SEC
    blo     FindNext_Check

; On a atteint 16 entrées. Y a-t-il un autre secteur racine ?
    ldd     s_find_currentSector+2
    addd    #1                          ; LBA suivant
    cmpd    #(ROOT_DIR_LBA+ROOT_DIR_SIZE)
    bhs     FindNext_End                ; Si LBA >= limite, c'est fini !

    std     s_find_currentSector+2      ; Sauvegarde le nouveau LBA
    clr     s_find_currentEntry         ; Remet l'index d'entrée à 0

    ; Charger le nouveau secteur depuis la SD
    std     BlockAddr+2
    clr     BlockAddr
    clr     BlockAddr+1
    jsr     Fs_ReadBlk
    tsta
    bne     FindNext_End                ; Erreur de lecture SD -> Fin

    bra     FindNext_Loop               ; On recommence la recherche sur ce nouveau secteur

FindNext_End:
    ; Fin du répertoire ou erreur
    orcc    #%00000001
    puls    d,x,y,u,pc
FindNext_Check:
    lda     s_find_currentEntry
    ldb     #DE_ENTRY_LEN
    mul
    ldx     #SD_BUFFER
    leax    d,x

    lda     ,x
    cmpa    #MARK_FREE
    beq     FindNext_End        ; Met la Carry à 1 pour dire à Forth de stopper son "ls"
    cmpa    #MARK_VALID
    beq     FindNext_Found

FindNext_Advance:
    inc     s_find_currentEntry
    bra     FindNext_Loop

FindNext_Found:
    ; Skip hidden files (attribute bit 3)
    lda     DE_OFF_ATTR,x
    bita    #ATTR_HIDDEN
    bne     FindNext_Advance
    ldd     DE_OFF_PARENT,x     ; seulement le dossier courant
    cmpd    fs_dossier
    bne     FindNext_Advance

    ; Copy full entry (32 bytes) to g_find_fileInfo
    ldy     #g_find_fileInfo
    ldb     #DE_ENTRY_LEN
FindNext_Copy:
    lda     ,x+
    sta     ,y+
    decb
    bne     FindNext_Copy
    ; n° + 1 de l'entrée, dans la copie (+30)
    ldd     s_find_currentSector+2
    subd    #ROOT_DIR_LBA
    lslb
    rola
    lslb
    rola
    lslb
    rola
    lslb
    rola
    addb    s_find_currentEntry
    adca    #0
    addd    #1
    std     g_find_fileInfo+DE_OFF_ID

    inc     s_find_currentEntry
    andcc   #%11111110
    puls    d,x,y,u,pc

    section .code
; ===================================================================
; FS_ListRoot - List all files in root directory
; Entry: none
; Exit:  A=0
; ===================================================================
X_FS_ListRoot:
    pshs    u,y,x,d
    clr     BlockAddr
    clr     BlockAddr+1
    ldd     #ROOT_DIR_LBA
    std     BlockAddr+2
List_ReadSector:
    jsr     Fs_ReadBlk
    tsta
    bne     List_Done_Error

    ldx     #SD_BUFFER
    ldb     #ENTRIES_PER_SEC
List_EntryLoop:

    lda     ,x
    cmpa    #MARK_FREE
    beq     List_Done_Success  ; Sortie immédiate si on atteint la fin des fichiers !
    cmpa    #$ff
    beq     List_Done_Success  ; Sortie immédiate si on atteint la fin des fichiers !
    cmpa    #MARK_VALID
    bne     List_Next
    pshs    b                   ; (B : compteur d'entrées)
    ldd     DE_OFF_PARENT,x     ; seulement le dossier courant
    cmpd    fs_dossier
    puls    b
    bne     List_Next

    pshs    b,x
    leax    DE_OFF_NAME,x
    ldb     #15
List_PrintName:
    lda     ,x+
    cmpa    #' '
    beq     List_SkipSpace
    jsr     [table_function_ram+sys_PrintChar]
    decb
    bne     List_PrintName
    bra     List_EndName
List_SkipSpace:
    decb
    bne     List_PrintName
List_EndName:
    puls    b,x
    lda     DE_OFF_ATTR,x
    bita    #ATTR_DIR
    beq     List_Fin
    lda     #'/'
    jsr     [table_function_ram+sys_PrintChar]
List_Fin:
    jsr     [table_function_ram+sys_PrintCRLF]
List_Next:
    leax    DE_ENTRY_LEN,x
    decb
    bne     List_EntryLoop

    ldd     BlockAddr+2         ; Récupère le LBA actuel
    addd    #1                  ; Passe au LBA suivant
    cmpd    #(ROOT_DIR_LBA+ROOT_DIR_SIZE)
    bhs     List_Done_Success          ; Si LBA >= limite, on a fini !

    std     BlockAddr+2         ; Sauvegarde le nouveau LBA
    bra     List_ReadSector     ; On boucle pour lire ce nouveau secteur !

List_Done_Success:
    andcc   #%11111110         ; Clear Carry (Succès)
    puls    u,y,x,d,pc
List_Done_Error:
    orcc    #%00000001         ; Set Carry (Erreur)
    puls    u,y,x,d,pc

    section .code
FS_ListRoot:
    jmp     [ExtV+EXTV_LISTROOT]

    section .ext
; ===================================================================
; FS_SaveFile - Save data to new file
; Entry: X -> 15-byte filename (space-padded), Y -> source, U=size,
;        A = page SOURCE : la RAM bascule dessus ($A0C0) le temps de chaque
;        copie, puis current_page est rétablie (comme FS_LoadFile).
;        Plusieurs pages : arrivée en $8000, la source continue en $0000 de
;        la page SUIVANTE (64 Ko au plus, pas au-delà de la page 3).
; Exit:  carry=0 success, carry=1 error
; Note:  s_save_* 32-bit vars use [0:1]=low16, [2:3]=high16
; ===================================================================
X_FS_SaveFile:
    pshs    u,y,x,d
    pshs    a                   ; 0,s = page source en cours (avance)
    lda     #'E'
    jsr     Fs_Spin_Init
    stx     s_save_fileNamePtr
    sty     s_save_sourcePtr
    stu     s_save_bytesLeft
    stu     s_save_fileSize
    clr     s_save_bytesLeft+2
    clr     s_save_bytesLeft+3
    clr     s_save_fileSize+2
    clr     s_save_fileSize+3

    ; dossier de destination (un chemin introuvable : $FFFF, refusé)
    jsr     Fs_ParentDe
    ldd     fs_cible
    cmpd    #$FFFF
    lbeq    Save_Exit_Error
    ; Find a free directory entry (writes filename + valid status)
    ldx     s_save_fileNamePtr
    jsr     FS_FindFreeEntry
    lbcs    Save_Exit_Error

    ; Default next free LBA
    ldd     #DATA_START_LBA
    std     s_save_firstSector
    clr     s_save_firstSector+2
    clr     s_save_firstSector+3

    ldd     s_save_bytesLeft
    lbeq    Save_Finalize

    ; Scan root dir: nextFree = max(firstSector + ceil(size/512))
    clr     BlockAddr
    clr     BlockAddr+1
    ldd     #ROOT_DIR_LBA
    std     BlockAddr+2
Save_ReadSector:
    jsr     Fs_ReadBlk
    tsta
    lbne    Save_Exit_Error

    ldx     #SD_BUFFER
    ldb     #ENTRIES_PER_SEC
Save_ScanMax:
    lda     ,x
    cmpa    #MARK_FREE
    beq     Save_ScanDone  ; Sortie immédiate si on atteint la fin des fichiers !
    cmpa    #MARK_VALID
    bne     Save_ScanMaxNext

    ; B est le compteur d'entrées du secteur : le calcul ci-dessous écrase
    ; D. Sans cette sauvegarde, un secteur de répertoire PLEIN (16 entrées,
    ; aucune $00) faisait sauter des entrées, et le fichier sauvé pouvait
    ; être écrit par-dessus un fichier existant (corrigé le 9 oct. 2026).
    ; Secteurs du fichier = ceil(taille/512), taille sur 32 bits :
    ; (mot faible >> 9) + (reste <> 0) + mot fort x 128. L'ancien calcul
    ; (taille + 511) >> 9 sur 16 bits débordait au-delà de 65 024 octets et
    ; ignorait le mot fort : le fichier suivant pouvait écraser celui-là.
    pshs    b
    ldd     DE_OFF_SIZE+2,x     ; mot faible
    pshs    d
    tfr     a,b
    clra
    lsrb                        ; D = mot faible >> 9
    pshs    d                   ; 0,s = secteurs pleins, 2,s = mot faible
    ldd     2,s
    anda    #$01                ; mot faible AND 511 : un secteur entamé ?
    bne     SSM_Part
    tstb
    beq     SSM_High
SSM_Part:
    ldd     ,s
    addd    #1
    std     ,s
SSM_High:
    ldd     DE_OFF_SIZE,x       ; mot fort : 128 secteurs par tranche de 64 Ko
    lsld
    lsld
    lsld
    lsld
    lsld
    lsld
    lsld
    addd    ,s
    leas    4,s
    addd    DE_OFF_FIRST+2,x    ; end LBA (exclusive) of this file
    cmpd    s_save_firstSector
    bls     Save_ScanMaxPop
    std     s_save_firstSector
Save_ScanMaxPop:
    puls    b

Save_ScanMaxNext:
    leax    DE_ENTRY_LEN,x
    decb
    bne     Save_ScanMax

    ldd     BlockAddr+2
    addd    #1
    cmpd    #(ROOT_DIR_LBA+ROOT_DIR_SIZE)
    bhs     Save_ScanDone       ; Si on a scanné tout le répertoire, c'est bon !
    std     BlockAddr+2
    bra     Save_ReadSector     ; Sinon on boucle

Save_ScanDone:
    ; BlockAddr = firstSector (next free LBA)
    ldd     s_save_firstSector+2     ; high word
    std     BlockAddr
    ldd     s_save_firstSector       ; low word
    std     BlockAddr+2

    ; Write data sectors
Save_WriteLoop:
    ldd     s_save_bytesLeft
    lbeq    Save_Finalize

    ; Clear SD_BUFFER
    ldy     #SD_BUFFER
    ldx     #256
    clrd
Save_ClearBuf:
    std     ,y++                ; Met 2 octets à zéro d'un coup
    leax    -1,x
    bne     Save_ClearBuf

; Copy data to SD_BUFFER
    ldy     #SD_BUFFER
    ldu     s_save_sourcePtr    ; <-- U devient le pointeur source

    ldw     s_save_bytesLeft
    cmpw    #512
    bls     Save_CopyPartial
    ldw     #512
Save_CopyPartial:
    pshsw                   ; Sauvegarde la quantité sur la pile
    ldu     #SD_BUFFER          ; destination : le tampon
    ldx     s_save_sourcePtr    ; source : (page en cours, X)
    lda     2,s                 ; page en cours (2,s à cause du pshs w)
    jsr     Fs_FromFar          ; rétablit current_page ; page suivante en $8000
    lbcs    Save_Copy_Error
    sta     2,s
    stx     s_save_sourcePtr    ; Met à jour le pointeur source

    ldd     s_save_bytesLeft
    subd    ,s++                ; bytesLeft -= quantité copiée (récupérée de la pile)
    std     s_save_bytesLeft

    jsr     Fs_WriteBlk
    tsta
    bne     Save_Exit_Error
    jsr     Fs_Spin             ; signe de vie, un cran par secteur

    ldd     BlockAddr+2
    addd    #1
    std     BlockAddr+2
    bcc     Save_WriteLoop
    ldd     BlockAddr
    addd    #1
    std     BlockAddr
    bra     Save_WriteLoop

Save_Finalize:
    ; Update directory entry with firstSector and fileSize
    ldd     s_save_dirEntryLBA
    std     BlockAddr
    ldd     s_save_dirEntryLBA+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     Save_Exit_Error

    ldy     #SD_BUFFER
    ldd     s_save_dirEntryOffset
    leay    d,y

    ; firstSector: 4 bytes big-endian on disk
    ldd     s_save_firstSector+2     ; high word
    std     DE_OFF_FIRST,y
    ldd     s_save_firstSector       ; low word
    std     DE_OFF_FIRST+2,y
    ; fileSize: 4 bytes big-endian on disk
    ldd     s_save_fileSize+2        ; high word
    std     DE_OFF_SIZE,y
    ldd     s_save_fileSize          ; low word
    std     DE_OFF_SIZE+2,y

    ldd     s_save_dirEntryLBA
    std     BlockAddr
    ldd     s_save_dirEntryLBA+2
    std     BlockAddr+2
    jsr     Fs_WriteBlk
    tsta
    bne     Save_Exit_Error
    lda current_page
    sta $a0c0
    jsr     Fs_Spin_End
    leas    1,s
    andcc   #%11111110
    puls    u,y,x,d,pc

Save_Copy_Error:
    leas    2,s                 ; la quantité empilée
Save_Exit_Error:
    lda current_page
    sta $a0c0
    jsr     Fs_Spin_End
    leas    1,s
    orcc    #%00000001
    puls    u,y,x,d,pc

; ===================================================================
; FS_FindFreeEntry - Find free entry in root dir, write filename+status
; Entry: X -> 15-byte filename (space-padded)
; Exit:  carry=0 found, s_entry_lba/s_entry_offset set, entry written
;        carry=1 root full
; ===================================================================
FS_FindFreeEntry:
    pshs    y,x,d
    tfr     x,u

    ;clr     s_entry_lba
    ;clr     s_entry_lba+1
    ;ldd     #ROOT_DIR_LBA
    ;std     s_entry_lba+2

    clr     BlockAddr
    clr     BlockAddr+1
    ldd     #ROOT_DIR_LBA
    std     BlockAddr+2
FFE_ReadSector:
    jsr     Fs_ReadBlk
    tsta
    bne     FFE_Full

    ldx     #SD_BUFFER
    ldb     #ENTRIES_PER_SEC
FFE_EntryLoop:
    lda     ,x
    cmpa    #MARK_FREE
    beq     FFE_Found
    cmpa    #MARK_DELETED
    beq     FFE_Found
    leax    DE_ENTRY_LEN,x
    decb
    bne     FFE_EntryLoop

    ldd     BlockAddr+2         ; Récupère le LBA actuel
    addd    #1                  ; LBA suivant
    cmpd    #(ROOT_DIR_LBA+ROOT_DIR_SIZE)
    bhs     FFE_Full            ; Si on dépasse la taille du répertoire, c'est plein !

    std     BlockAddr+2         ; Sauvegarde le nouveau LBA
    bra     FFE_ReadSector      ; Et on boucle pour charger le secteur suivant !

FFE_Full:
    orcc    #%00000001
    puls    y,x,d,pc

FFE_Found:
    clr     s_entry_lba
    clr     s_entry_lba+1
    ldd     BlockAddr+2         ; On utilise le LBA actuel (où on a trouvé la place)
    std     s_entry_lba+2       ; au lieu de forcer ROOT_DIR_LBA !
    ; Store entry offset
    tfr     x,d
    subd    #SD_BUFFER
    std     s_save_dirEntryOffset
    std     s_entry_offset

    ; Clear entire entry (32 bytes)
    pshs    x
    ldb     #DE_ENTRY_LEN
FFE_ClearEntry:
    clr     ,x+
    decb
    bne     FFE_ClearEntry
    puls    x

    ; Write status = valid
    lda     #MARK_VALID
    sta     ,x

    ; Default attributes: rwx (FS_MkDir : rwx + d) ; dossier parent
    lda     fs_attr_neuf
    bne     FFE_Attr
    lda     #ATTR_DEFAULT
FFE_Attr:
    sta     DE_OFF_ATTR,x
    ldd     fs_cible
    std     DE_OFF_PARENT,x

    ; Copy filename (15 bytes) starting at offset 1
    leax    DE_OFF_NAME,x
    ldb     #15
FFE_CopyName:
    lda     ,u+
    sta     ,x+
    decb
    bne     FFE_CopyName

    ; Write sector
    jsr     Fs_WriteBlk
    tsta
    bne     FFE_Full

    ; Sauvegarde le LBA actuel pour la fonction FS_SaveFile
    clr     s_save_dirEntryLBA
    clr     s_save_dirEntryLBA+1
    ldd     BlockAddr+2
    std     s_save_dirEntryLBA+2

    andcc   #%11111110          ; Efface le Carry (Succès)
    puls    y,x,d,pc

; ===================================================================
; FS_DeleteFile - Delete file (mark status as deleted)
; Entry: X -> 15-byte filename
; Exit:  carry=0 success, carry=1 error
; ===================================================================
X_FS_DeleteFile:
    pshs    y,x,d
    jsr     Fs_Exact
    bcs     Delete_Exit_Error
    ; un dossier ne s'efface que vide
    lda     g_find_fileInfo+DE_OFF_ATTR
    bita    #ATTR_DIR
    beq     Delete_Go
    jsr     Fs_IdEntree
    jsr     Fs_AEnfant
    bcc     Delete_Exit_Error
    jsr     Fs_Exact            ; (Fs_AEnfant a relu le répertoire)
    bcs     Delete_Exit_Error
Delete_Go:

    ldd     s_entry_lba
    std     BlockAddr
    ldd     s_entry_lba+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     Delete_Exit_Error

    ldy     #SD_BUFFER
    ldd     s_entry_offset
    leay    d,y
    lda     #MARK_DELETED
    sta     ,y

    jsr     Fs_WriteBlk
    tsta
    bne     Delete_Exit_Error

    andcc   #%11111110
    puls    y,x,d,pc

Delete_Exit_Error:
    orcc    #%00000001
    puls    y,x,d,pc

    section .code
FS_SaveFile:
    jmp     [ExtV+EXTV_SAVE]
FS_DeleteFile:
    jmp     [ExtV+EXTV_DELETE]

; ===================================================================
; FS_GetAttributes - Read file attributes
; Entry: X -> 15-byte filename
; Exit:  carry=0 found, A=attributes (bit2=r bit1=w bit0=x bit3=hidden)
;        carry=1 not found
; ===================================================================
FS_GetAttributes:
    pshs    y,x,d
    jsr     FS_FindEntry
    bcs     GetAttr_Error

    ldd     s_entry_lba
    std     BlockAddr
    ldd     s_entry_lba+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     GetAttr_Error

    ldx     #SD_BUFFER
    ldd     s_entry_offset
    leax    d,x
    lda     DE_OFF_ATTR,x
    sta     0,s             ; A dans la sauvegarde D (0,s=A) pour le puls
    andcc   #%11111110
    puls    y,x,d,pc

GetAttr_Error:
    orcc    #%00000001
    puls    y,x,d,pc

    section .code
; ===================================================================
; FS_SetAttributes - Write file attributes
; Entry: X -> 15-byte filename, A = new attributes
; Exit:  carry=0 success, carry=1 error
; ===================================================================
X_FS_SetAttributes:
    pshs    y,x,d
    jsr     Fs_Exact
    bcs     SetAttr_Error

    ldd     s_entry_lba
    std     BlockAddr
    ldd     s_entry_lba+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     SetAttr_Error

    ldx     #SD_BUFFER
    ldd     s_entry_offset
    leax    d,x
    lda     0,s             ; A original (0,s=A) = nouvelles attributs
    sta     DE_OFF_ATTR,x

    jsr     Fs_WriteBlk
    tsta
    bne     SetAttr_Error

    andcc   #%11111110
    puls    y,x,d,pc

SetAttr_Error:
    orcc    #%00000001
    puls    y,x,d,pc

    section .code
FS_SetAttributes:
    jmp     [ExtV+EXTV_SETATTR]

; ===================================================================
; FS_GetNextCluster - Dummy (contiguous FS, no cluster chain)
; Entry: D = cluster (unused)
; Exit:  carry=1 (not applicable)
; ===================================================================
FS_GetNextCluster:
    orcc    #%00000001
    rts

; ===================================================================
; FS_ClusterToLBA_Offset - Dummy (contiguous FS, no cluster mapping)
; Entry: D = value (unused)
; Exit:  carry=1 (not applicable)
; ===================================================================
FS_ClusterToLBA_Offset:
    orcc    #%00000001
    rts

    section .code
; ===================================================================
; FS_RenameFile - Renomme et/ou déplace une entrée
; Entry: X -> ancien nom, Y -> nouveau nom (15 octets, Format_Filename_83)
;        Le nouveau nom donne aussi le dossier d'arrivée : "LIB/UI.INC" y
;        déplace l'entrée ; un nom vide ("LIB/") garde l'ancien nom.
;        Un dossier ne se déplace pas dans lui-même (ni plus bas).
; Exit:  carry=0 success, carry=1 error
; ===================================================================
X_FS_RenameFile:
    pshs    u,y,x,d
    ; 1. dossier d'arrivée, d'après le nouveau nom
    tfr     y,x
    jsr     Fs_ParentDe
    ldd     fs_cible
    cmpd    #$FFFF
    lbeq    Rename_Error
    std     fs_tmp
    ; 2. l'entrée à renommer (sans repli)
    ldx     2,s
    jsr     Fs_Exact
    lbcs    Rename_Error
    ; 3. un dossier : l'arrivée ne doit pas être lui-même ni en dessous
    lda     g_find_fileInfo+DE_OFF_ATTR
    bita    #ATTR_DIR
    beq     Rename_Lire
    jsr     Fs_IdEntree
    std     fr_dos              ; n° du dossier déplacé
    ldd     fs_tmp
Rename_Monte:
    beq     Rename_Relit        ; racine atteinte : pas de cycle
    cmpd    fr_dos
    lbeq    Rename_Error
    ldy     #0
    jsr     Fs_DirInfo          ; D = parent
    lbcs    Rename_Error
    cmpd    #0
    bra     Rename_Monte
Rename_Relit:
    ldx     2,s                 ; Fs_DirInfo a relu le répertoire
    jsr     Fs_Exact
    lbcs    Rename_Error
Rename_Lire:
    ; 4. le secteur de l'entrée
    ldd     s_entry_lba
    std     BlockAddr
    ldd     s_entry_lba+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     Rename_Error
    ldd     s_entry_offset
    addd    #SD_BUFFER
    tfr     d,x
    ldd     fs_tmp
    std     DE_OFF_PARENT,x
    ; 5. le nouveau nom, s'il n'est pas vide
    ldy     4,s
    lda     ,y
    cmpa    #' '
    beq     Rename_Ecrit
    leax    DE_OFF_NAME,x
    ldb     #15
Rename_CopyLoop:
    lda     ,y+
    sta     ,x+
    decb
    bne     Rename_CopyLoop
Rename_Ecrit:
    jsr     Fs_WriteBlk
    tsta
    bne     Rename_Error
    andcc   #%11111110      ; Carry = 0
    puls    u,y,x,d,pc

Rename_Error:
    orcc    #%00000001      ; Carry = 1
    puls    u,y,x,d,pc

    section .code
FS_RenameFile:
    jmp     [ExtV+EXTV_RENAME]

; ===================================================================
; Dossiers
; ===================================================================

; Fs_ParentDe - X = nom formaté : son dossier dans fs_cible. Celui de
; Format_Filename_83 s'il a formaté ce tampon (adresse, page, contenu)
; avec un chemin (fs_explicite = 1), sinon le dossier courant.
; Préserve tous les registres.
Fs_ParentDe:
    pshs    d,y,u
    ldu     #fs_slots
    ldb     #FS_NSLOTS
fpd_lp:
    cmpx    ,u
    bne     fpd_suiv
    lda     current_page
    cmpa    2,u
    bne     fpd_suiv
    pshs    b,x
    leay    5,u
    ldb     #15
fpd_cmp:
    lda     ,x+
    cmpa    ,y+
    bne     fpd_diff
    decb
    bne     fpd_cmp
    puls    b,x
    ldd     3,u
    std     fs_cible
    lda     #1
    sta     fs_explicite
    puls    d,y,u,pc
fpd_diff:
    puls    b,x
fpd_suiv:
    leau    FS_SLOT,u
    decb
    bne     fpd_lp
    ldd     fs_dossier
    std     fs_cible
    clr     fs_explicite
    puls    d,y,u,pc

; Fs_IdEntree - D = n° + 1 de l'entrée trouvée (s_entry_lba, s_entry_offset).
Fs_IdEntree:
    pshs    x
    ldd     s_entry_offset
    lsra                        ; / 32 : rang dans le secteur
    rorb
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    tfr     d,x
    ldd     s_entry_lba+2
    subd    #ROOT_DIR_LBA
    lslb
    rola
    lslb
    rola
    lslb
    rola
    lslb
    rola
    leax    d,x
    leax    1,x
    tfr     x,d
    puls    x,pc

; Fs_DirInfo - D = n° d'un dossier (pas 0) : D = son parent, son nom en Y
; (15 octets) si Y <> 0. C=1 si ce n'est pas un dossier valide.
FS_DirInfo:
Fs_DirInfo:
    pshs    x,y
    cmpd    #0
    beq     fdi_non
    subd    #1
    pshs    b
    lsra                        ; secteur = (n° - 1) / 16 + 1
    rorb
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    addd    #ROOT_DIR_LBA
    std     BlockAddr+2
    clr     BlockAddr
    clr     BlockAddr+1
    jsr     Fs_ReadBlk
    puls    b
    tsta
    bne     fdi_non
    andb    #ENTRIES_PER_SEC-1
    lda     #DE_ENTRY_LEN
    mul
    addd    #SD_BUFFER
    tfr     d,x
    lda     ,x
    cmpa    #MARK_VALID
    bne     fdi_non
    lda     DE_OFF_ATTR,x
    bita    #ATTR_DIR
    beq     fdi_non
    ldy     2,s
    beq     fdi_parent
    pshs    x
    leax    DE_OFF_NAME,x
    ldb     #15
fdi_nom:
    lda     ,x+
    sta     ,y+
    decb
    bne     fdi_nom
    puls    x
fdi_parent:
    ldd     DE_OFF_PARENT,x
    andcc   #%11111110
    puls    x,y,pc
fdi_non:
    orcc    #%00000001
    puls    x,y,pc

; Fs_AEnfant - D = n° d'un dossier : C=0 si une entrée valide y est.
Fs_AEnfant:
    pshs    d,x
    clr     BlockAddr
    clr     BlockAddr+1
    ldd     #ROOT_DIR_LBA
fae_sect:
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     fae_non
    ldx     #SD_BUFFER
fae_lp:
    lda     ,x
    beq     fae_non             ; MARK_FREE : fin de la table
    cmpa    #MARK_VALID
    bne     fae_suiv
    ldd     DE_OFF_PARENT,x
    cmpd    ,s
    beq     fae_oui
fae_suiv:
    leax    DE_ENTRY_LEN,x
    cmpx    #SD_BUFFER+512
    blo     fae_lp
    ldd     BlockAddr+2
    addd    #1
    cmpd    #ROOT_DIR_LBA+ROOT_DIR_SIZE
    blo     fae_sect
fae_non:
    orcc    #%00000001
    puls    d,x,pc
fae_oui:
    andcc   #%11111110
    puls    d,x,pc

; Fs_Comp - Un composant de chemin (X, jusqu'à '/' ou NUL) en nom de 15
; octets (majuscules, blancs) en Y. Sortie : X sur le séparateur.
Fs_Comp:
    pshs    b,y
    ldb     #15
fc_lp:
    lda     ,x
    beq     fc_pad
    cmpa    #'/'
    beq     fc_pad
    leax    1,x
    tstb
    beq     fc_lp               ; au-delà de 15 : ignoré
    cmpa    #'a'
    blo     fc_maj
    cmpa    #'z'
    bhi     fc_maj
    suba    #$20
fc_maj:
    sta     ,y+
    decb
    bra     fc_lp
fc_pad:
    tstb
    beq     fc_fin
    lda     #' '
    sta     ,y+
    decb
    bra     fc_pad
fc_fin:
    puls    b,y,pc

; Fs_Resoudre - Chemin de dossiers de X à U (exclu ; U est sur un '/' ou
; le NUL final) : "/" en tête = racine, sinon le dossier courant ; "." et
; ".." ; composants vides ignorés. Sortie : C=0, D = n° du dossier ;
; C=1 si un composant n'existe pas ou n'est pas un dossier.
Fs_Resoudre:
    pshs    x,y,u
    stu     fr_fin
    lda     ,x                  ; "/" en tête : la racine
    cmpa    #'/'
    bne     fr_cour
    ldd     #0
    bra     fr_ok0
fr_cour:
    ldd     fs_dossier
fr_ok0:
    std     fr_dos
fr_comp:
    cmpx    fr_fin
    bhs     fr_ok
    lda     ,x
    cmpa    #'/'
    bne     fr_mot
    leax    1,x                 ; composant vide
    bra     fr_comp
fr_mot:
    cmpa    #'.'
    bne     fr_nom
    lda     1,x
    beq     fr_point            ; "."
    cmpa    #'/'
    beq     fr_point
    cmpa    #'.'
    bne     fr_nom
    lda     2,x
    beq     fr_pp               ; ".."
    cmpa    #'/'
    bne     fr_nom
fr_pp:
    leax    2,x
    ldd     fr_dos
    beq     fr_comp             ; la racine est son propre parent
    ldy     #0
    jsr     Fs_DirInfo
    bcs     fr_non
    std     fr_dos
    bra     fr_comp
fr_point:
    leax    1,x
    bra     fr_comp
fr_nom:
    ldy     #fr_nom15
    jsr     Fs_Comp
    pshs    x
    ldd     fr_dos
    std     fs_cible
    ldx     #fr_nom15
    jsr     Fs_Scan
    puls    x
    bcs     fr_non
    lda     g_find_fileInfo+DE_OFF_ATTR
    bita    #ATTR_DIR
    beq     fr_non
    jsr     Fs_IdEntree
    std     fr_dos
    bra     fr_comp
fr_ok:
    ldd     fr_dos
    andcc   #%11111110
    puls    x,y,u,pc
fr_non:
    orcc    #%00000001
    puls    x,y,u,pc

; ===================================================================
; Format_Filename_83 - Nom ou chemin -> nom OSMFS de 15 octets
; Entrée : X -> chaîne (NUL final), Y -> tampon (16 octets)
; Sortie : Y = le dernier composant, en majuscules, complété de blancs.
;          Avec un '/' ("../LIB/UI.INC", "/APPS/X") : les dossiers sont
;          résolus et le tampon garde son dossier (fs_slots) pour les
;          FS_* qui suivent ; dossier introuvable : $FFFF (FS_* échoue).
; ===================================================================
Format_Filename_83:
    pshs    d,x,y,u
    ldu     #0
ff_scan:
    lda     ,x+
    beq     ff_vu
    cmpa    #'/'
    bne     ff_scan
    leau    -1,x                ; le dernier '/'
    bra     ff_scan
ff_vu:
    ldx     2,s
    ldy     4,s
    cmpu    #0
    bne     ff_chemin
    jsr     Fs_Comp
    ; sans chemin : oublier ce tampon dans fs_slots
    jsr     Fs_SlotDe
    bcs     ff_ret
    clr     ,u
    clr     1,u
ff_ret:
    puls    d,x,y,u,pc
ff_chemin:
    jsr     Fs_Resoudre
    bcc     ff_dos
    ldd     #$FFFF
ff_dos:
    std     fs_tmp
    leax    1,u                 ; le nom, après le dernier '/'
    jsr     Fs_Comp
    jsr     Fs_SlotDe
    bcc     ff_place
    ; un emplacement libre ou le plus ancien
    ldb     fs_slot_suiv
    incb
    cmpb    #FS_NSLOTS
    blo     ff_s1
    clrb
ff_s1:
    stb     fs_slot_suiv
    lda     #FS_SLOT
    mul
    addd    #fs_slots
    tfr     d,u
ff_place:
    sty     ,u
    lda     current_page
    sta     2,u
    ldd     fs_tmp
    std     3,u
    leau    5,u
    ldb     #15
ff_cp:
    lda     ,y+
    sta     ,u+
    decb
    bne     ff_cp
    puls    d,x,y,u,pc

; Fs_SlotDe - Y = tampon : C=0, U = son emplacement dans fs_slots.
Fs_SlotDe:
    pshs    d
    ldu     #fs_slots
    ldb     #FS_NSLOTS
fsd_lp:
    cmpy    ,u
    bne     fsd_suiv
    lda     2,u
    cmpa    current_page
    beq     fsd_oui
fsd_suiv:
    leau    FS_SLOT,u
    decb
    bne     fsd_lp
    orcc    #%00000001
    puls    d,pc
fsd_oui:
    andcc   #%11111110
    puls    d,pc

; ===================================================================
; FS_ChDir - Change de dossier courant
; Entry: X -> chemin (NUL final) : "APPS", "..", "/", "/APPS/JEUX"...
; Exit:  carry=0 success ; carry=1 introuvable (dossier courant inchangé)
; ===================================================================
FS_ChDir:
    pshs    d,u
    tfr     x,u
fcd_fin:
    tst     ,u+
    bne     fcd_fin
    leau    -1,u                ; U sur le NUL
    jsr     Fs_Resoudre
    bcs     fcd_ret
    std     fs_dossier
fcd_ret:
    puls    d,u,pc

    section .code
; ===================================================================
; FS_MkDir - Crée un dossier
; Entry: X -> nom (15 octets, Format_Filename_83 : "APPS" ou "APPS/JEUX")
; Exit:  carry=0 success ; carry=1 existe déjà, chemin introuvable, plein
; ===================================================================
X_FS_MkDir:
    pshs    d,y,u
    jsr     Fs_Exact
    bcc     fmd_non             ; ce nom existe déjà ici
    lda     #ATTR_DEFAULT+ATTR_DIR
    sta     fs_attr_neuf
    ldy     #0
    ldu     #0
    clra
    jsr     FS_SaveFile         ; une entrée de taille 0
    pshs    cc                  ; (CLR efface C : celui de FS_SaveFile)
    clr     fs_attr_neuf
    puls    cc
    puls    d,y,u,pc
fmd_non:
    orcc    #%00000001
    puls    d,y,u,pc

    section .code
FS_MkDir:
    jmp     [ExtV+EXTV_MKDIR]

; ===================================================================
; FS_Dossier - Lit ou change le dossier courant par son n°
; Entry: D = n° (0 = racine ; celui de g_find_fileInfo+30 après FS_FindNext)
;        ou $FFFF pour seulement lire
; Exit:  D = dossier courant
; ===================================================================
FS_Dossier:
    cmpd    #$FFFF
    beq     fdo_lit
    std     fs_dossier
fdo_lit:
    ldd     fs_dossier
    rts



; ===================================================================
; Lecture d'un fichier morceau par morceau (l'assembleur ASM lit ainsi
; des sources plus grandes que la RAM, et ses INCLUDE).
; Un fichier OSMFS est contigu : FS_FileInfo donne son premier LBA et sa
; taille, FS_ReadSector lit les secteurs un par un.
; ===================================================================

; Fs_Entree - X -> nom (15 octets). Sortie : C=0, X -> l'entrée de 32
; octets dans SD_BUFFER (BlockAddr = son secteur) ; C=1 absent ou erreur.
Fs_Entree:
    jsr     Fs_Exact
    bcs     FEn_Err
    ldd     s_entry_lba
    std     BlockAddr
    ldd     s_entry_lba+2
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     FEn_Err
    ldd     s_entry_offset
    addd    #SD_BUFFER
    tfr     d,x
    andcc   #%11111110
    rts
FEn_Err:
    orcc    #%00000001
    rts

; ===================================================================
; FS_FileInfo - Ce que dit l'entrée d'un fichier
; Entry: X -> 15-byte filename, Y -> 14 octets à remplir (= octets +16 à
;        +29 de l'entrée) : premier LBA (4, BE), taille (4, BE), page (1),
;        adresse (2, BE), attributs (1), dossier parent (2, BE)
; Exit:  carry=0 found, carry=1 not found / SD error
; ===================================================================
FS_FileInfo:
    pshs    u,y,x,d
    bsr     Fs_Entree
    bcs     FI_Err
    leax    DE_OFF_FIRST,x
    ldy     4,s
    ldb     #14
FI_Copie:
    lda     ,x+
    sta     ,y+
    decb
    bne     FI_Copie
    andcc   #%11111110
    puls    u,y,x,d,pc
FI_Err:
    orcc    #%00000001
    puls    u,y,x,d,pc

; ===================================================================
; FS_ReadSector - Lit un secteur de 512 octets (4 essais)
; Entry: X -> LBA (4 octets, BE), Y -> 512 octets de destination, dans la
;        page visible (celle de l'appelant) ou la RAM système
; Exit:  carry=0 success, carry=1 error (sd_err)
; ===================================================================
FS_ReadSector:
    pshs    u,y,x,d
    pshsw
    ldd     ,x
    std     BlockAddr
    ldd     2,x
    std     BlockAddr+2
    jsr     Fs_ReadBlk
    tsta
    bne     RS_Err
    ldx     #SD_BUFFER
    ldy     6,s             ; (W empilé par-dessus : Y à 4+2,s)
    ldw     #512
    tfm     x+,y+
    pulsw
    andcc   #%11111110
    puls    u,y,x,d,pc
RS_Err:
    pulsw
    orcc    #%00000001
    puls    u,y,x,d,pc

    section .code
; ===================================================================
; FS_SetLoad - Page et adresse de chargement d'un fichier
; Entry: X -> 15-byte filename, A = page, Y = adresse
; Exit:  carry=0 success, carry=1 error
; ===================================================================
X_FS_SetLoad:
    pshs    u,y,x,d
    jsr     Fs_Entree
    bcs     SL_Err
    lda     0,s
    sta     DE_OFF_PAGE,x
    ldd     4,s
    std     DE_OFF_ADDR,x
    jsr     Fs_WriteBlk
    tsta
    bne     SL_Err
    andcc   #%11111110
    puls    u,y,x,d,pc
SL_Err:
    orcc    #%00000001
    puls    u,y,x,d,pc


    section .code
FS_SetLoad:
    jmp     [ExtV+EXTV_SETLOAD]

	end
