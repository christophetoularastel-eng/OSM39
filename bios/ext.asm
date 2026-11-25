; ===================================================================
; ext.asm - La seconde partie du BIOS : BIOS2, chargée en RAM système
; ===================================================================
; L'EPROM est pleine. Les services qu'il ne faut pas pour démarrer ni pour
; réparer (écrire des fichiers, la console du Terminal, le son...) vivent
; dans la section .ext, liée en même temps que le reste du BIOS à EXT_BASE
; (RAM système, sous la pile) : ses appels vers l'EPROM et ceux de l'EPROM
; vers elle sont résolus par le même lien. bios2.py en tire le fichier
; BIOS2 (posé en /BIN par deploy_sd.sh) et inscrit dans l'EPROM sa longueur
; et sa somme (ExtLong, ExtSomme).
;
; Ext_Charge (EPROM), à chaque démarrage, à froid comme à chaud, juste après
; la carte SD : lit /BIN/BIOS2 secteur par secteur en EXT_BASE ; si la
; longueur et la somme sont celles de l'EPROM, appelle Ext_Entree, qui
; remplit ses créneaux de la table des services et ses crochets. Sinon
; rien : la machine démarre, ces services répondent « absent » (C = 1).
; EXT_BASE et EXT_FIN viennent du Makefile (-D).
; ===================================================================
    include "hardware.inc"
    include "sysfunc.inc"
    include "ext.inc"

    import  Format_Filename_83, FS_FileInfo, Fs_ReadBlk
    import  BlockAddr, SD_BUFFER
    import  ext_nom, ext_info, ext_ok, ExtV
    import  Sys_Absent, UPDATE_CURSOR
    import  X_FS_SaveFile, X_FS_DeleteFile, X_FS_SetAttributes, X_FS_RenameFile
    import  X_FS_SetLoad, X_FS_MkDir, X_FS_ListRoot, X_Console_Zone
    import  X_snd_play, X_snd_stop, X_boot_jingle, X_Zone_IRQ, X_Audio, X_Zone_Cls
    import  X_Graphe, X_Gr_IRQ
    export  Ext_Charge, ExtLong, ExtSomme, Ext_Entree, Ext_Defauts, Graphe, Gr_IRQ

    section .code

; ExtLong / ExtSomme : écrits dans l'image par bios2.py après le lien
ExtLong:    fdb     0
ExtSomme:   fdb     0
NomBios2:   fcn     "/BIN/BIOS2"

; Ext_Defauts : les vecteurs ExtV sans BIOS2 (au reset, avant les IRQ)
Ext_Defauts:
    pshs    x,y
    ldx     #Ext_Def
    ldy     #ExtV
    bra     Ext_Vecteurs
Ext_Rien:
    rts
; Ext_Def : sans BIOS2, FS_SaveFile, FS_DeleteFile et le graphisme
; répondent « absent » (C = 1). Le reste (attributs, renommer, dossiers,
; console du Terminal, son) est revenu dans l'EPROM le 21 nov. 2026 pour
; faire place au graphisme : ses vecteurs pointent sur elle dès le reset.
Ext_Def:
    fdb     Sys_Absent,Sys_Absent,X_FS_SetAttributes,X_FS_RenameFile,X_FS_SetLoad,X_FS_MkDir,X_FS_ListRoot
    fdb     X_Console_Zone,X_snd_play,X_snd_stop,X_boot_jingle,X_Zone_IRQ,X_Audio,X_Zone_Cls
    fdb     Sys_Absent,Ext_Rien
; Les souches du mode graphique (graphe.asm, BIOS2)
Graphe:
    jmp     [ExtV+EXTV_GRAPHE]
Gr_IRQ:
    jmp     [ExtV+EXTV_GRIRQ]
; Ext_Vecteurs : X = table de EXTV_N mots -> ExtV (Y), puis puls x,y,pc
Ext_Vecteurs:
    ldd     ,x++
    std     ,y++
    cmpy    #ExtV+2*EXTV_N
    blo     Ext_Vecteurs
    puls    x,y,pc

; Ext_Charge : C = 0 BIOS2 installé, C = 1 rien (absent, autre BIOS...)
Ext_Charge:
    pshs    d,x,y,u
    pshsw
    clr     ext_ok
    ldd     ExtLong
    lbeq    Ec_Rate                 ; ce BIOS n'a pas de seconde partie
    ldx     #NomBios2
    ldy     #ext_nom
    jsr     Format_Filename_83
    ldx     #ext_nom
    ldy     #ext_info
    jsr     FS_FileInfo
    lbcs    Ec_Rate
    ldd     ext_info+4              ; taille : exactement ExtLong
    lbne    Ec_Rate
    ldd     ext_info+6
    cmpd    ExtLong
    lbne    Ec_Rate
    ldd     ext_info                ; premier secteur
    std     BlockAddr
    ldd     ext_info+2
    std     BlockAddr+2
    ldy     #EXT_BASE
    ldu     ExtLong                 ; reste à copier
Ec_Secteur:
    pshs    y                       ; SD_ReadBlock use Y (attente du jeton)
    jsr     Fs_ReadBlk              ; -> SD_BUFFER ; A = 0 : lu
    puls    y
    tsta
    lbne    Ec_Rate
    ldw     #512
    cmpu    #512
    bhs     Ec_Copie
    tfr     u,w                     ; le dernier secteur : la fin seulement
Ec_Copie:
    pshsw
    ldx     #SD_BUFFER
    tfm     x+,y+
    tfr     u,d
    subd    ,s++
    tfr     d,u
    beq     Ec_Somme
    ldd     BlockAddr+2             ; secteur suivant (fichier contigu)
    addd    #1
    std     BlockAddr+2
    bcc     Ec_Secteur
    ldd     BlockAddr
    addd    #1
    std     BlockAddr
    bra     Ec_Secteur
Ec_Somme:
    ldx     #EXT_BASE
    ldw     ExtLong
    clra
    clrb
Ec_SomOct:
    addb    ,x+
    adca    #0
    decw
    bne     Ec_SomOct
    cmpd    ExtSomme
    lbne    Ec_Rate
    jsr     Ext_Entree
    inc     ext_ok
    pulsw
    andcc   #$fe
    puls    d,x,y,u,pc
Ec_Rate:
    pulsw
    orcc    #1
    puls    d,x,y,u,pc

; ===================================================================
; La section .ext : son point d'entrée d'abord (à EXT_BASE)
; ===================================================================
    section .ext

; Ext_Entree : installe la seconde partie : ses routines dans ExtV
Ext_Entree:
    pshs    x,y
    ldx     #Ext_Table
    ldy     #ExtV
    jmp     Ext_Vecteurs
Ext_Table:                          ; même ordre que ext.inc et Ext_Def
    fdb     X_FS_SaveFile,X_FS_DeleteFile,X_FS_SetAttributes,X_FS_RenameFile
    fdb     X_FS_SetLoad,X_FS_MkDir,X_FS_ListRoot,X_Console_Zone
    fdb     X_snd_play,X_snd_stop,X_boot_jingle,X_Zone_IRQ,X_Audio,X_Zone_Cls
    fdb     X_Graphe,X_Gr_IRQ
