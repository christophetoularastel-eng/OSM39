; ===================================================================
; ZM_FICHIER.ASM - Sauvegardes (Quetzal), @restart, @verify
; ===================================================================
; SAUVER. Le fichier Quetzal est écrit d'un bloc par FS_SaveFile depuis
; la page 2 : son en-tête (42 octets : FORM, IFhd, en-tête de UMem) est
; posé juste devant la mémoire dynamique (qui commence en $0100 de la
; page 2), la fin (Stks) juste après ; les octets du jeu ainsi couverts
; sont relus sur la carte ensuite. Le cache est vidé puis oublié.
; CHARGER. Le fichier est lu secteur par secteur (un lecteur : LBA,
; taille, position) ; une première passe vérifie IFhd (même jeu), la
; mémoire (UMem de la bonne taille, ou CMem) et Stks avant de rien
; toucher. CMem : différence (XOR, zéros comptés) avec le jeu d'origine,
; lu en même temps sur la carte.
; ===================================================================
QZ_ENTETE       equ 42              ; FORM(12) + IFhd(8+13+1) + UMem(8)
QZ_ADR          equ $0100-QZ_ENTETE ; dans la page 2
LECT_TAMPON     equ CRENEAUX+$0200  ; lecteur du jeu (CMem, @verify...)
SORTIE_T        equ CRENEAUX        ; 256 octets en route vers les pages
STKS_T          equ CRENEAUX+$0400  ; Stks en construction (le cache est oublié)

; -------------------------------------------------------------------
; Demande_Nom : « Fichier : », une saisie -> NomSv (15 octets formatés)
; C = 1 : rien de tapé
; -------------------------------------------------------------------
Demande_Nom:
    LDX     #TxtFichier
DN_Prompt:
    LDA     ,X+
    BEQ     DN_Saisie
    PSHS    X
    JSR     Ecran_Car
    PULS    X
    BRA     DN_Prompt
DN_Saisie:
    JSR     Saisie_Debut
    LDA     #12
    STA     LgMax
    CLRA
    CLRB
    STD     LgDelai
    STD     LgRoutine
    JSR     Lit_Saisie
    LDX     #LIGNE                  ; sans les espaces autour, en majuscules
    LDB     LgN
    ABX
    CLR     ,X
    LDX     #LIGNE
DN_Debut:
    LDA     ,X
    CMPA    #' '
    BNE     DN_Copie
    LEAX    1,X
    BRA     DN_Debut
DN_Copie:
    PSHS    Y                       ; (Y est le PC)
    LDY     #NomTxt
    CLR     DnPoint
DN_Car:
    LDA     ,X+
    BEQ     DN_Fin
    CMPA    #'.'
    BNE     DN_Maj
    STA     DnPoint
DN_Maj:
    CMPA    #'a'
    BLO     DN_Pose
    CMPA    #'z'
    BLS     DN_Moins
    CMPA    #$E0
    BLO     DN_Pose
    CMPA    #$FE
    BHI     DN_Pose
    CMPA    #$F7
    BEQ     DN_Pose
DN_Moins:
    SUBA    #32
DN_Pose:
    STA     ,Y+
    BRA     DN_Car
DN_Fin:
    LEAY    -1,Y                    ; les espaces de la fin
    CMPY    #NomTxt
    BLO     DN_Vide
    LDA     ,Y
    CMPA    #' '
    BEQ     DN_Fin
    LEAY    1,Y
    TST     DnPoint
    BNE     DN_Zero
    LDX     #TxtSav
DN_Ext:
    LDA     ,X+
    STA     ,Y+
    BNE     DN_Ext
    BRA     DN_Format
DN_Zero:
    CLR     ,Y
DN_Format:
    PULS    Y
    LDX     #NomTxt
    PSHS    Y,U
    LDY     #NomSv
    JSR     [table_function_ram+sys_Format_Filename_83]
    PULS    Y,U
    ANDCC   #$FE
    RTS
DN_Vide:
    PULS    Y
    ORCC    #1
    RTS

; -------------------------------------------------------------------
; Lecteur de fichier. X = le lecteur : +0 LBA (4), +4 taille (4),
; +8 position (4), +12 secteur en tampon (2, $FFFF : aucun), +14 tampon
; Lc_Octet : l'octet à la position, qui avance -> A ; C = 1 : fin
; -------------------------------------------------------------------
Lc_Ouvre:                           ; X = lecteur, Y = 8 octets LBA + taille
    LDD     ,Y
    STD     ,X
    LDD     2,Y
    STD     2,X
    LDD     4,Y
    STD     4,X
    LDD     6,Y
    STD     6,X
    CLRA
    CLRB
    STD     8,X
    STD     10,X
    LDD     #$FFFF
    STD     12,X
    RTS

Lc_Octet:
    LDD     8,X                     ; position >= taille : fin
    CMPD    4,X
    BLO     LO_Ok
    BHI     LO_Fin
    LDD     10,X
    CMPD    6,X
    BHS     LO_Fin
LO_Ok:
    LDD     9,X                     ; secteur = position >> 9
    LSRA
    RORB
    CMPD    12,X
    BEQ     LO_Lit
    STD     12,X
    ADDD    2,X
    STD     LcLBA+2
    LDD     ,X
    ADCB    #0
    ADCA    #0
    STD     LcLBA
    PSHS    X,Y,U
    LDY     14,X
    LDX     #LcLBA
    JSR     [table_function_ram+sys_FS_ReadSector]
    PULS    X,Y,U
    BCC     LO_Lit
    LDX     #TxtLecture
    JMP     Erreur
LO_Lit:
    LDD     10,X                    ; décalage = position & 511
    ANDA    #1
    ADDD    14,X
    PSHS    X
    TFR     D,X
    LDA     ,X
    PULS    X
    PSHS    A
    LDD     10,X                    ; position + 1
    ADDD    #1
    STD     10,X
    LDD     8,X
    ADCB    #0
    ADCA    #0
    STD     8,X
    PULS    A
    ANDCC   #$FE
    RTS
LO_Fin:
    CLRA
    ORCC    #1
    RTS

; Lc_Va : X = lecteur, D = position (16 bits)
Lc_Va:
    STD     10,X
    CLR     8,X
    CLR     9,X
    RTS

; Lc_Mot / Lc_Long : grand-boutiste -> D / LcL (4 octets)
Lc_Mot:
    BSR     Lc_Octet
    PSHS    A
    BSR     Lc_Octet
    TFR     A,B
    PULS    A
    RTS
Lc_Long:
    BSR     Lc_Mot
    STD     LcL
    BSR     Lc_Mot
    STD     LcL+2
    RTS

; -------------------------------------------------------------------
; @verify : somme des octets $40..longueur-1 du fichier du jeu
; -------------------------------------------------------------------
Verifie:
    LDX     #$1A
    JSR     Lit16
    STD     VfLg+1                  ; longueur = mot * 2, 4 ou 8 (comme les paquées)
    CLR     VfLg
    LDB     Decal
Vf_Mul:
    LSL     VfLg+2
    ROL     VfLg+1
    ROL     VfLg
    DECB
    BNE     Vf_Mul
    LDX     #LectJeu
    LDD     #SECTEUR                ; (le cache reste valide)
    JSR     Lect_Jeu
    LDD     #$40
    JSR     Lc_Va
    CLRA
    CLRB
    STD     VfSomme
Vf_Boucle:
    LDX     #LectJeu                ; position < longueur ?
    LDA     9,X
    CMPA    VfLg
    BLO     Vf_Octet
    BHI     Vf_Fin
    LDD     10,X
    CMPD    VfLg+1
    BHS     Vf_Fin
Vf_Octet:
    JSR     Lc_Octet
    BCS     Vf_Fin
    TFR     A,B
    CLRA
    ADDD    VfSomme
    STD     VfSomme
    BRA     Vf_Boucle
Vf_Fin:
    LDX     #$1C
    JSR     Lit16
    CMPD    VfSomme
    BEQ     Vf_Oui
    CLRA
    RTS
Vf_Oui:
    LDA     #1
    RTS

; Lect_Jeu : X = lecteur ouvert sur le fichier du jeu, D = son tampon
Lect_Jeu:
    PSHS    D,Y
    LDY     #InfoJeu
    JSR     Lc_Ouvre
    PULS    D,Y
    STD     14,X
    RTS

; -------------------------------------------------------------------
; @restart : la mémoire dynamique d'origine (relue sur la carte), les
; bits 0-1 de Flags 2 gardés, puis Demarre
; -------------------------------------------------------------------
Redemarre:
    LDX     #$11
    JSR     Lit8
    STA     RdF2
    JSR     Cache_Init
    JSR     Recharge_Dyn
    LDX     #$11
    JSR     Lit8
    ANDA    #$FC
    LDB     RdF2
    ANDB    #3
    PSHS    B
    ORA     ,S+
    LDX     #$11
    JSR     Ecrit8
    JMP     Demarre

; Recharge_Dyn : les blocs de la mémoire dynamique, relus sur la carte
Recharge_Dyn:
    LDD     Statique
    ADDD    #255
    TFR     A,B
    CLRA
    STD     RdN                     ; blocs
    CLRA
    CLRB
    STD     CjBloc
RD_Boucle:
    LDD     CjBloc
    CMPD    RdN
    BHS     RD_Fin
    STD     CbBloc
    JSR     Lit_Secteur_Bloc
    LDD     CjBloc
    JSR     Ecrit_Bloc_Pages
    LDD     CjBloc
    ADDD    #1
    STD     CjBloc
    CMPD    RdN
    BHS     RD_Fin
    JSR     Ecrit_Bloc_Pages
    LDD     CjBloc
    ADDD    #1
    STD     CjBloc
    BRA     RD_Boucle
RD_Fin:
    RTS

; -------------------------------------------------------------------
; @save
; -------------------------------------------------------------------
Sauve_Partie:
    JSR     Lit_PC                  ; IFhd : le PC de l'octet de résultat
    LDA     ZPC
    STA     QPC
    LDD     ZPC+1
    STD     QPC+1
    TST     V3                      ; v3 : un branchement, lu à la fin
    BNE     SP_Demande
    JSR     Octet_PC
    STA     SvVar
SP_Demande:
    JSR     Demande_Nom
    BCC     SP_Nom
    CLRA
    CLRB
    LBRA    SP_Rend0
SP_Nom:
    JSR     Cache_Vide
    JSR     Cache_Init              ; (le PC sera refait)
    JSR     Epingle
    ; --- Stks en STKS_T+16, puis son en-tête (et le bourrage) devant
    LDX     #STKS_T+16
    STX     OutP
    JSR     Fait_Stks
    LDD     OutP
    SUBD    #STKS_T+16
    STD     SvStks                  ; longueur des données de Stks
    LDX     #STKS_T+16
    LEAX    -8,X
    LDA     #'S'
    STA     ,X
    LDD     #$746B                  ; "tk"
    STD     1,X
    LDA     #'s'
    STA     3,X
    CLR     4,X
    CLR     5,X
    LDD     SvStks
    STD     6,X
    LDA     Statique+1              ; mémoire de longueur impaire : bourrage
    ANDA    #1
    STA     SvPad
    BEQ     SP_Queue
    LEAX    -1,X
    CLR     ,X
SP_Queue:
    STX     SvQueue
    ; --- l'en-tête (42 octets) dans SECTEUR
    LDX     #SECTEUR
    LDD     #$464F                  ; "FORM"
    STD     ,X
    LDD     #$524D
    STD     2,X
    CLR     4,X                     ; longueur : 4 + 22 + 8 + D + pad + 8 + S
    CLR     5,X
    LDD     Statique
    ADDD    #4+22+8+8
    ADDB    SvPad
    ADCA    #0
    ADDD    SvStks
    STD     6,X
    BCC     SP_Form
    INC     5,X
SP_Form:
    LDD     #$4946                  ; "IFZS"
    STD     8,X
    LDD     #$5A53
    STD     10,X
    LDD     #$4946                  ; "IFhd", 13
    STD     12,X
    LDD     #$6864
    STD     14,X
    CLRA
    CLRB
    STD     16,X
    LDD     #13
    STD     18,X
    PSHS    X
    LDX     #2                      ; release
    JSR     Lit16
    PULS    X
    STD     20,X
    LDB     #0
SP_Serie:
    PSHS    B,X
    CLRA
    ADDD    #$12
    TFR     D,X
    JSR     Lit8
    PULS    B,X
    PSHS    X
    ABX
    STA     22,X
    PULS    X
    INCB
    CMPB    #6
    BLO     SP_Serie
    PSHS    X
    LDX     #$1C                    ; somme de contrôle
    JSR     Lit16
    PULS    X
    STD     28,X
    LDA     QPC
    STA     30,X
    LDD     QPC+1
    STD     31,X
    CLR     33,X                    ; bourrage de IFhd
    LDD     #$554D                  ; "UMem", D
    STD     34,X
    LDD     #$656D
    STD     36,X
    CLRA
    CLRB
    STD     38,X
    LDD     Statique
    STD     40,X
    ; --- vers la page 2 : l'en-tête devant, la queue derrière
    LDX     #SECTEUR
    LDD     #QZ_ADR
    LDW     #QZ_ENTETE
    JSR     Vers_Pages
    LDX     SvQueue
    LDD     Statique
    ADDD    #$0100
    PSHS    D
    LDD     SvStks
    ADDD    #8
    ADDB    SvPad
    ADCA    #0
    STD     SvQueueLg
    TFR     D,W
    PULS    D
    JSR     Vers_Pages
    ; --- le fichier : l'ancien d'abord effacé (FS_SaveFile en crée un)
    LDD     Statique
    ADDD    #QZ_ENTETE
    ADDD    SvQueueLg
    STD     SvTotal
    JSR     IRQ_Bios
    PSHS    Y,U
    LDX     #NomSv
    JSR     [table_function_ram+sys_FS_DeleteFile]
    LDX     #NomSv
    LDY     #QZ_ADR
    LDU     SvTotal
    LDA     #2
    JSR     [table_function_ram+sys_FS_SaveFile]
    PULS    Y,U
    LDD     #1
    BCC     SP_Ok
    CLRB
SP_Ok:
    STD     SvRes
    JSR     IRQ_Z
    ; --- les octets du jeu recouverts par la queue : relus
    LDD     Statique
    TFR     A,B
    CLRA
    STD     CjBloc                  ; premier bloc touché
    LDD     Statique
    ADDD    SvQueueLg
    ADDD    #255
    TFR     A,B
    CLRA
    STD     RdN                     ; jusqu'à ce bloc (exclu)
SP_Repare:
    LDD     CjBloc
    CMPD    RdN
    BHS     SP_PC
    CMPD    NBlocsRam
    BHS     SP_PC
    STD     CbBloc
    JSR     Lit_Secteur_Bloc
    LDD     CjBloc
    JSR     Ecrit_Bloc_Pages
    LDD     CjBloc
    ADDD    #1
    STD     CjBloc
    BRA     SP_Repare
SP_PC:
    LDD     QPC+1                   ; le PC : après l'octet de résultat
    ADDD    #1                      ; (v3 : sur le branchement)
    SUBB    V3
    SBCA    #0
    STD     ZPC+1
    LDA     QPC
    ADCA    #0
    STA     ZPC
    JSR     Va_PC
    LDD     SvRes
SP_Rend0:
    TFR     D,X
    LDB     SvVar
; Rend_Partie : X = résultat (0 échec) dans la variable B, ou en v3 le
; branchement (pris si X <> 0)
Rend_Partie:
    TST     V3
    LBEQ    Ecrit_Var
    TFR     X,D
    JMP     Branche_D

; Vers_Pages : X = source (page 1), D = adresse linéaire dans les pages
; 2-3 (0 = $0000 de la page 2), W = longueur. Coupé à $8000.
Vers_Pages:
    STD     VpDest
    STX     VpSrc
    STW     VpN
VP_Boucle:
    LDD     VpN
    BEQ     VP_Fin
    LDD     VpDest                  ; place jusqu'à la fin de la page
    ANDA    #$7F
    PSHS    D
    LDD     #$8000
    SUBD    ,S++
    CMPD    VpN
    BLS     VP_Morceau
    LDD     VpN
VP_Morceau:
    STD     VpM
    PSHS    Y,U
    LDA     VpDest
    ROLA                            ; bit 15 -> page 2 ou 3
    ROLA
    ANDA    #1
    ADDA    #2
    LDY     VpDest
    PSHS    A
    TFR     Y,D
    ANDA    #$7F
    TFR     D,Y
    PULS    A
    LDX     VpSrc
    LDB     >current_page
    LDU     VpM
    JSR     [table_function_ram+sys_FarWrite]
    PULS    Y,U
    LDD     VpDest
    ADDD    VpM
    STD     VpDest
    LDD     VpSrc
    ADDD    VpM
    STD     VpSrc
    LDD     VpN
    SUBD    VpM
    STD     VpN
    BRA     VP_Boucle
VP_Fin:
    RTS

; IRQ_Bios / IRQ_Z : l'IRQ du BIOS seule (FS_SaveFile change de page),
; puis la nôtre de nouveau
IRQ_Bios:
    PSHS    CC
    ORCC    #%00010000
    LDX     AncienIRQ
    STX     >rvec_IRQ
    PULS    CC,PC
IRQ_Z:
    PSHS    CC
    ORCC    #%00010000
    LDX     #Irq_Z
    STX     >rvec_IRQ
    PULS    CC,PC

; Fait_Stks : les cadres, du premier (fictif) au dernier, vers OutP
Fait_Stks:
    LDX     #SECTEUR                ; la chaîne des FP, du dernier au premier
    LDD     FP
FS_Chaine:
    STD     ,X++
    PSHS    X
    TFR     D,X
    LDD     ,X
    PULS    X
    BNE     FS_Chaine
    STX     FsFin                   ; après le premier cadre
    LEAX    -2,X
FS_Cadre:
    STX     FsPtr
    LDY     ,X                      ; (le PC est refait plus tard)
    STY     FsF
    LDB     6,Y
    ANDB    #$0F
    STB     FsNl
    ; la limite : l'en-tête du cadre suivant + 8, ou U
    CMPX    #SECTEUR
    BEQ     FS_Haut
    LDD     -2,X
    ADDD    #8
    BRA     FS_Lim
FS_Haut:
    TFR     U,D
FS_Lim:
    STD     FsLim
    LDX     FsFin
    LEAX    -2,X
    CMPX    FsPtr
    BNE     FS_Normal
    CLRA                            ; le cadre fictif : 6 zéros
    JSR     Out_Octet
    JSR     Out_Octet
    JSR     Out_Octet
    JSR     Out_Octet
    JSR     Out_Octet
    JSR     Out_Octet
    BRA     FS_Eval
FS_Normal:
    LDY     FsF
    LDA     2,Y
    JSR     Out_Octet
    LDA     3,Y
    JSR     Out_Octet
    LDA     4,Y
    JSR     Out_Octet
    LDA     FsNl
    TST     6,Y
    BPL     FS_Garde
    ORA     #$10
    JSR     Out_Octet
    CLRA
    JSR     Out_Octet
    BRA     FS_Args
FS_Garde:
    JSR     Out_Octet
    LDA     5,Y
    JSR     Out_Octet
FS_Args:
    LDB     7,Y
    CMPB    #7
    BLS     FS_ArgN
    LDB     #7
FS_ArgN:
    CLRA
FS_ArgB:
    TSTB
    BEQ     FS_ArgF
    LSLA
    INCA
    DECB
    BRA     FS_ArgB
FS_ArgF:
    JSR     Out_Octet
FS_Eval:
    ; nombre de mots de la pile d'évaluation : (F - 2 nl - limite) / 2
    LDB     FsNl
    CLRA
    LSLB
    STD     FsT
    LDD     FsF
    SUBD    FsT
    STD     FsHautEv                ; juste sous les locales
    SUBD    FsLim
    LSRA
    RORB
    STD     FsNev
    JSR     Out_Mot
    LDX     FsFin                   ; locales (pas pour le cadre fictif)
    LEAX    -2,X
    CMPX    FsPtr
    BEQ     FS_Ev
    LDY     FsF
    LDB     FsNl
FS_Loc:
    TSTB
    BEQ     FS_Ev
    LEAY    -2,Y
    PSHS    B
    LDD     ,Y
    JSR     Out_Mot
    PULS    B
    DECB
    BRA     FS_Loc
FS_Ev:
    LDY     FsHautEv
FS_EvB:
    CMPY    FsLim
    BLS     FS_Suiv
    LEAY    -2,Y
    LDD     ,Y
    JSR     Out_Mot
    BRA     FS_EvB
FS_Suiv:
    LDX     FsPtr
    CMPX    #SECTEUR
    BEQ     FS_Fin
    LEAX    -2,X
    JMP     FS_Cadre
FS_Fin:
    RTS

Out_Octet:
    PSHS    X
    LDX     OutP
    STA     ,X+
    STX     OutP
    PULS    X,PC
Out_Mot:
    PSHS    B
    BSR     Out_Octet
    PULS    A
    BRA     Out_Octet

; -------------------------------------------------------------------
; @restore
; -------------------------------------------------------------------
Charge_Partie:
    TST     V3
    BNE     CP_Demande
    JSR     Octet_PC
    STA     RsVar
CP_Demande:
    JSR     Demande_Nom
    LBCS    RS_Echec
    PSHS    Y,U
    LDX     #NomSv
    LDY     #RsInfo
    JSR     [table_function_ram+sys_FS_FileInfo]
    PULS    Y,U
    LBCS    RS_Echec
    LDX     #LectSv
    PSHS    Y
    LDY     #RsInfo
    JSR     Lc_Ouvre
    PULS    Y
    LDD     #SECTEUR
    STD     14,X
    ; --- passe 1 : les blocs
    JSR     Lc_Long
    LDD     LcL
    CMPD    #$464F
    LBNE    RS_Echec
    LDD     LcL+2
    CMPD    #$524D
    LBNE    RS_Echec
    JSR     Lc_Long                 ; longueur de FORM : la fin = 8 + longueur
    LDD     LcL+2
    ADDD    #8
    STD     RsFin
    LDD     LcL
    BEQ     RS_FinOk
    LDD     #$FFFF
    STD     RsFin
RS_FinOk:
    LDD     RsInfo+6                ; (au plus la taille du fichier)
    TST     RsInfo+4
    BNE     RS_Type
    TST     RsInfo+5
    BNE     RS_Type
    CMPD    RsFin
    BHS     RS_Type
    STD     RsFin
RS_Type:
    JSR     Lc_Long
    LDD     LcL
    CMPD    #$4946
    LBNE    RS_Echec
    LDD     LcL+2
    CMPD    #$5A53
    LBNE    RS_Echec
    CLRA
    CLRB
    STD     RsIFhd
    STD     RsUMem
    STD     RsCMem
    STD     RsStks
    LDD     #12
    STD     RsPos
RS_Bloc:
    LDD     RsPos
    ADDD    #8
    LBCS    RS_Verif
    CMPD    RsFin
    BHI     RS_Verif
    LDX     #LectSv
    LDD     RsPos
    JSR     Lc_Va
    JSR     Lc_Long                 ; le nom
    LDD     LcL
    STD     RsNom
    LDD     LcL+2
    STD     RsNom+2
    JSR     Lc_Long                 ; la longueur (< 64 Ko)
    LDD     LcL+2
    STD     RsN
    LDD     RsPos
    ADDD    #8
    STD     RsDon
    LDX     #RsTypes
RS_Cherche:
    LDD     ,X
    BEQ     RS_Suiv
    CMPD    RsNom
    BNE     RS_Autre
    LDD     2,X
    CMPD    RsNom+2
    BNE     RS_Autre
    LDX     4,X                     ; où le noter, s'il n'est pas déjà vu
    LDD     ,X
    BNE     RS_Suiv
    LDD     RsDon
    STD     ,X
    LDD     RsN
    STD     2,X
    BRA     RS_Suiv
RS_Autre:
    LEAX    6,X
    BRA     RS_Cherche
RS_Suiv:
    LDD     RsN                     ; bloc suivant : 8 + n + (n & 1)
    ADDD    RsDon
    BCS     RS_Verif
    LDB     RsN+1
    ANDB    #1
    BEQ     RS_Pair
    LDD     RsN
    ADDD    RsDon
    ADDD    #1
    BRA     RS_Pos
RS_Pair:
    LDD     RsN
    ADDD    RsDon
RS_Pos:
    STD     RsPos
    LBRA    RS_Bloc
    ; --- vérifications
RS_Verif:
    LDD     RsIFhd
    LBEQ    RS_Echec
    LDD     RsIFhd+2
    CMPD    #13
    LBLO    RS_Echec
    LDX     #LectSv
    LDD     RsIFhd
    JSR     Lc_Va
    CLR     RsI
RS_Hd:                              ; 10 octets : release, série, somme
    LDX     #LectSv
    JSR     Lc_Octet
    PSHS    A
    LDB     RsI
    LDX     #RsHdAdr
    LDB     B,X
    CLRA
    TFR     D,X
    JSR     Lit8
    CMPA    ,S+
    LBNE    RS_Echec
    INC     RsI
    LDA     RsI
    CMPA    #10
    BLO     RS_Hd
    LDX     #LectSv
    JSR     Lc_Octet
    STA     QPC
    JSR     Lc_Octet
    STA     QPC+1
    JSR     Lc_Octet
    STA     QPC+2
    LDD     RsUMem
    BEQ     RS_CMem
    LDD     RsUMem+2
    CMPD    Statique
    LBNE    RS_Echec
    BRA     RS_Stks
RS_CMem:
    LDD     RsCMem
    LBEQ    RS_Echec
RS_Stks:
    LDD     RsStks
    LBEQ    RS_Echec
    ; --- tout est bon : la mémoire
    LDX     #$11
    JSR     Lit8
    STA     RdF2
    JSR     Cache_Init
    LDX     #LectJeu
    LDD     #LECT_TAMPON
    JSR     Lect_Jeu
    LDX     #LectSv
    LDD     RsUMem
    BNE     RS_UVa
    LDD     RsCMem
RS_UVa:
    JSR     Lc_Va
    LDD     RsCMem+2
    STD     RsN                     ; octets de CMem restants
    CLRA
    CLRB
    STD     RsJ                     ; octets de mémoire écrits
    STD     RsZeros
RS_Mem:
    LDD     RsJ
    CMPD    Statique
    LBHS    RS_MemFin
    LDD     RsUMem
    BEQ     RS_C
    LDX     #LectSv                 ; UMem : l'octet tel quel
    JSR     Lc_Octet
    BRA     RS_Pose
RS_C:
    LDX     #LectJeu                ; CMem : l'origine XOR la différence
    JSR     Lc_Octet
    STA     RsOrig
    LDD     RsZeros
    BEQ     RS_CLit
    SUBD    #1
    STD     RsZeros
    LDA     RsOrig
    BRA     RS_Pose
RS_CLit:
    LDD     RsN
    BEQ     RS_CRien
    SUBD    #1
    STD     RsN
    LDX     #LectSv
    JSR     Lc_Octet
    TSTA
    BNE     RS_CXor
    LDD     RsN                     ; 0, n : n + 1 zéros (celui-ci compris)
    BEQ     RS_CRien
    SUBD    #1
    STD     RsN
    LDX     #LectSv
    JSR     Lc_Octet
    TFR     A,B
    CLRA
    STD     RsZeros
RS_CRien:
    LDA     RsOrig
    BRA     RS_Pose
RS_CXor:
    EORA    RsOrig
RS_Pose:
    LDB     RsJ+1
    LDX     #SORTIE_T
    ABX
    STA     ,X
    LDD     RsJ
    ADDD    #1
    STD     RsJ
    TSTB
    BNE     RS_Mem
    LDD     RsJ                     ; un bloc complet
    SUBD    #1
    JSR     RS_Bloc_Pages
    JMP     RS_Mem
RS_MemFin:
    LDB     RsJ+1                   ; le dernier bloc entamé : le reste du jeu
    BEQ     RS_Pile
    LDX     #LectJeu
    LDD     RsJ
    JSR     Lc_Va
RS_Reste:
    LDX     #LectJeu
    JSR     Lc_Octet
    LDB     RsJ+1
    LDX     #SORTIE_T
    ABX
    STA     ,X
    LDD     RsJ
    ADDD    #1
    STD     RsJ
    TSTB
    BNE     RS_Reste
    LDD     RsJ
    SUBD    #1
    JSR     RS_Bloc_Pages
    ; --- la pile
RS_Pile:
    LDX     #LectSv
    LDD     RsStks
    JSR     Lc_Va
    LDD     RsStks+2
    STD     RsN
    LDU     #ZPILE_HAUT
    CLRA
    CLRB
    STD     FP
    STD     Prof
RS_Cadre:
    LDD     RsN
    CMPD    #8
    LBLO    RS_PileFin
    SUBD    #8
    STD     RsN
    LDX     #LectSv
    JSR     Lc_Octet
    STA     RsCad
    JSR     Lc_Octet
    STA     RsCad+1
    JSR     Lc_Octet
    STA     RsCad+2
    JSR     Lc_Octet
    STA     RsCad+3                 ; drapeaux
    JSR     Lc_Octet
    STA     RsCad+4                 ; variable
    JSR     Lc_Octet
    STA     RsCad+5                 ; arguments
    JSR     Lc_Mot
    STD     RsNev
    LDA     RsCad+3
    ANDA    #$0F
    STA     RsNl
    LEAU    -8,U
    CMPU    #ZPILE_BAS+64
    LBLO    RS_Deborde
    LDX     FP
    STX     ,U
    LDD     Prof
    BNE     RS_Vrai
    CLRA                            ; le cadre fictif
    CLRB
    STD     2,U
    STD     4,U
    STD     6,U
    BRA     RS_Lie
RS_Vrai:
    LDA     RsCad
    STA     2,U
    LDD     RsCad+1
    STD     3,U
    LDA     RsCad+4
    STA     5,U
    LDA     RsNl
    LDB     RsCad+3
    BITB    #$10
    BEQ     RS_Gard
    ORA     #$80
    CLR     5,U
RS_Gard:
    STA     6,U
    CLRB                            ; arguments : les bits 0, 1... consécutifs
    LDA     RsCad+5
RS_Arg:
    LSRA
    BCC     RS_ArgF
    INCB
    BRA     RS_Arg
RS_ArgF:
    STB     7,U
RS_Lie:
    STU     FP
    LDD     Prof
    ADDD    #1
    STD     Prof
    LDB     RsNl                    ; locales (lues, gardées sauf au cadre fictif)
RS_Loc:
    TSTB
    BEQ     RS_Ev
    PSHS    B
    LDD     RsN
    SUBD    #2
    STD     RsN
    LDX     #LectSv
    JSR     Lc_Mot
    LDX     Prof
    CMPX    #1
    BEQ     RS_LocJete
    STD     ,--U
RS_LocJete:
    PULS    B
    DECB
    BRA     RS_Loc
RS_Ev:
    LDD     Prof                    ; le cadre fictif n'a pas de locales
    CMPD    #1
    BNE     RS_EvB
    LDX     FP
    CLR     6,X
RS_EvB:
    LDD     RsNev
    LBEQ    RS_Cadre
    SUBD    #1
    STD     RsNev
    LDD     RsN
    SUBD    #2
    STD     RsN
    CMPU    #ZPILE_BAS+64
    BLO     RS_Deborde
    LDX     #LectSv
    JSR     Lc_Mot
    STD     ,--U
    BRA     RS_EvB
RS_PileFin:
    ; --- l'en-tête, le PC, le résultat 2
    LDX     #$11
    JSR     Lit8
    ANDA    #$FC
    LDB     RdF2
    ANDB    #3
    PSHS    B
    ORA     ,S+
    LDX     #$11
    JSR     Ecrit8
    JSR     Entete
    JSR     Epingle
    LDA     QPC
    STA     ZPC
    LDD     QPC+1
    STD     ZPC+1
    JSR     Va_PC
    TST     V3                      ; v3 : le branchement de @save, pris
    BNE     RS_Branche
    JSR     Octet_PC
    TFR     A,B
RS_Branche:
    LDX     #2
    JMP     Rend_Partie
RS_Echec:
    LDB     RsVar
    LDX     #0
    JMP     Rend_Partie
RS_Deborde:
    LDX     #TxtPile
    JMP     Erreur

; RS_Bloc_Pages : D = une adresse dans le bloc complet de SORTIE_T
RS_Bloc_Pages:
    TFR     A,B
    CLRA
    STD     CbBloc
    JSR     Phys
    PSHS    Y,U
    TFR     X,Y
    LDX     #SORTIE_T
    LDB     >current_page
    LDU     #256
    JSR     [table_function_ram+sys_FarWrite]
    PULS    Y,U,PC

; Les blocs cherchés : nom (4), où noter (début, longueur)
RsTypes:
    FCC     "IFhd"
    FDB     RsIFhd
    FCC     "UMem"
    FDB     RsUMem
    FCC     "CMem"
    FDB     RsCMem
    FCC     "Stks"
    FDB     RsStks
    FDB     0
; IFhd : les octets de l'en-tête à comparer (release, série, somme)
RsHdAdr:        FCB 2,3,$12,$13,$14,$15,$16,$17,$1C,$1D

TxtFichier:     FCN "Fichier : "
TxtSav:         FCN ".SAV"
TxtPile:        FCN "pile Z pleine"

NomTxt:         RMB 20
NomSv:          RMB 15
DnPoint:        RMB 1
LcLBA:          RMB 4
LcL:            RMB 4
LectJeu:        RMB 16
LectSv:         RMB 16
VfLg:           RMB 3
VfSomme:        RMB 2
RdF2:           RMB 1
RdN:            RMB 2
QPC:            RMB 3
SvVar:          RMB 1
SvRes:          RMB 2
SvStks:         RMB 2
SvPad:          RMB 1
SvQueue:        RMB 2
SvQueueLg:      RMB 2
SvTotal:        RMB 2
OutP:           RMB 2
VpDest:         RMB 2
VpSrc:          RMB 2
VpN:            RMB 2
VpM:            RMB 2
FsFin:          RMB 2
FsPtr:          RMB 2
FsF:            RMB 2
FsNl:           RMB 1
FsLim:          RMB 2
FsT:            RMB 2
FsHautEv:       RMB 2
FsNev:          RMB 2
RsVar:          RMB 1
RsInfo:         RMB 14
RsFin:          RMB 2
RsPos:          RMB 2
RsNom:          RMB 4
RsN:            RMB 2
RsDon:          RMB 2
RsIFhd:         RMB 4               ; début, longueur
RsUMem:         RMB 4
RsCMem:         RMB 4
RsStks:         RMB 4
RsI:            RMB 1
RsJ:            RMB 2
RsZeros:        RMB 2
RsOrig:         RMB 1
RsCad:          RMB 6
RsNev:          RMB 2
RsNl:           RMB 1
