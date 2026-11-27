; ===================================================================
; JOYCAL.ASM - Étalonnage du joystick (port A de l'AY)
; Usage: JOYCAL
; Charge: page 1, $0000
;
; Le joystick : quatre micro-rupteurs et un bouton, chacun entre un bit du
; port A de l'AY (J602 de la carte OSM39_mono ; IOAn sur la broche 17 - 2n)
; et la masse. Il peut être monté dans n'importe quel sens et câblé dans
; n'importe quel ordre : JOYCAL demande le haut, la droite, le bas, la
; gauche, puis le bouton ; pour chacun, il attend que tout soit lâché, puis
; un seul bit appuyé, stable JC_STABLE trames, pas encore pris (une
; diagonale ou un bit déjà pris : on recommence) ; il affiche le bit et
; la broche. Puis il écrit /BIN/JOYSTICK.CFG (lib/joy.asm : "JOY", 1, les
; cinq masques), que lib/joy.asm lit au démarrage des programmes.
; Échap : abandon, rien n'est écrit.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

JC_STABLE       equ 6               ; trames identiques pour accepter un appui

    section .code

Start:
    LDX     #MsgTitre
    JSR     Aff_Ligne
    LDA     #7                      ; port A en entrée, le reste de R7 intact
    STA     AY_ADR
    LDB     AY_ADR
    ANDB    #%10111111
    STB     AY_DATA
    JSR     Joy_Init
    JSR     Joy_Brut                ; (sonde l'AY)
    LDA     JoyAY
    BPL     Etapes
    LDX     #MsgSansAY
    JMP     Aff_Ligne

Etapes:
    CLR     Etape
    CLR     Pris
Et_Une:
    LDB     Etape                   ; « Poussez vers le HAUT »...
    ASLB
    LDX     #TabNoms
    LDX     B,X
    PSHS    X
    LDX     #MsgPoussez
    JSR     Aff
    PULS    X
    JSR     Aff_Ligne
Et_Lacher:
    JSR     Attend_Lache
    LBCS    Abandon
Et_Appui:
    JSR     Attend_Appui            ; A = le bit, stable
    LBCS    Abandon
    STA     Masque
    DECA                            ; un seul bit ?
    ANDA    Masque
    BEQ     Et_Seul
    LDX     #MsgUnSeul
    JSR     Aff_Ligne
    BRA     Et_Lacher
Et_Seul:
    LDA     Masque                  ; pas déjà pris ?
    BITA    Pris
    BEQ     Et_Libre
    LDX     #MsgPris
    JSR     Aff_Ligne
    BRA     Et_Lacher
Et_Libre:
    ORA     Pris
    STA     Pris
    LDB     Etape                   ; le masque dans le fichier
    LDX     #Fichier+4
    LDA     Masque
    STA     B,X
    LDX     #MsgBit                 ; « -> IOAn (J602-p) »
    JSR     Aff
    CLRB                            ; n = le numéro du bit
    LDA     Masque
Et_N:
    LSRA
    BCS     Et_NOk
    INCB
    BRA     Et_N
Et_NOk:
    STB     NumBit
    TFR     B,A
    ADDA    #'0'
    JSR     [table_function_ram+sys_PrintChar]
    LDX     #MsgBroche
    JSR     Aff
    LDA     #17                     ; broche = 17 - 2n
    SUBA    NumBit
    SUBA    NumBit
    JSR     Aff_Nombre
    LDX     #MsgFerme
    JSR     Aff_Ligne
    INC     Etape
    LDA     Etape
    CMPA    #JOY_N
    LBLO    Et_Une
    JSR     Attend_Lache
    LBCS    Abandon

; --- l'écriture de /BIN/JOYSTICK.CFG ---
    LDX     #NomFic
    LDY     #NomFmt
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #NomFmt                 ; l'ancien d'abord (FS_SaveFile crée
    JSR     [table_function_ram+sys_FS_DeleteFile]  ; toujours une entrée)
    LDX     #NomFmt
    LDA     >current_page
    LDY     #Fichier
    LDU     #JOY_TAILLE
    JSR     [table_function_ram+sys_FS_SaveFile]
    BCS     Erreur
    LDX     #MsgFini
    JMP     Aff_Ligne
Erreur:
    LDX     #MsgErreur
    JMP     Aff_Ligne
Abandon:
    LDX     #MsgAbandon
    JMP     Aff_Ligne

; -------------------------------------------------------------------
; Attend_Lache : jusqu'à JC_STABLE trames sans rien d'appuyé -> C = 0 ;
; Échap -> C = 1.
Attend_Lache:
    LDA     #JC_STABLE
    STA     Compte
AL_Trame:
    BSR     Trame
    BCS     AL_Fin
    JSR     Joy_Brut
    BEQ     AL_Rien
    LDA     #JC_STABLE              ; encore appuyé : on recompte
    STA     Compte
    BRA     AL_Trame
AL_Rien:
    DEC     Compte
    BNE     AL_Trame
    ANDCC   #$FE
AL_Fin:
    RTS

; Attend_Appui : jusqu'à JC_STABLE trames de suite avec la même lecture,
; non nulle -> A = cette lecture, C = 0 ; Échap -> C = 1.
Attend_Appui:
    CLR     Avant
    LDA     #JC_STABLE
    STA     Compte
AA_Trame:
    BSR     Trame
    BCS     AA_Fin
    JSR     Joy_Brut
    BEQ     Attend_Appui            ; rien : on recommence
    CMPA    Avant
    BEQ     AA_Meme
    STA     Avant                   ; autre chose : on recompte
    LDA     #JC_STABLE
    STA     Compte
    BRA     AA_Trame
AA_Meme:
    DEC     Compte
    BNE     AA_Trame
    LDA     Avant
    ANDCC   #$FE
AA_Fin:
    RTS

; Trame : une trame ; Échap au clavier -> C = 1. Détruit A, B, E.
Trame:
    JSR     [table_function_ram+sys_kbd_poll]
    CMPA    #$1B
    BEQ     Tr_Echap
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    ANDCC   #$FE
    RTS
Tr_Echap:
    ORCC    #1
    RTS

; Aff_Nombre : A = 0-99 en décimal
Aff_Nombre:
    CLRB
AN_Diz:
    CMPA    #10
    BLO     AN_Un
    SUBA    #10
    INCB
    BRA     AN_Diz
AN_Un:
    PSHS    A
    TSTB
    BEQ     AN_U
    TFR     B,A
    ADDA    #'0'
    JSR     [table_function_ram+sys_PrintChar]
AN_U:
    PULS    A
    ADDA    #'0'
    JMP     [table_function_ram+sys_PrintChar]

Aff:
    JMP     [table_function_ram+sys_PrintString]

Aff_Ligne:
    JSR     [table_function_ram+sys_PrintString]
    JMP     [table_function_ram+sys_PrintCRLF]

    include "../lib/joy.asm"

; -------------------------------------------------------------------
TabNoms     FDB NomHaut,NomDroite,NomBas,NomGauche,NomBouton
NomHaut     FCN "le joystick vers le HAUT"
NomDroite   FCN "le joystick vers la DROITE"
NomBas      FCN "le joystick vers le BAS"
NomGauche   FCN "le joystick vers la GAUCHE"
NomBouton   FCN "le BOUTON"
MsgTitre    FCN "JOYCAL - etalonnage du joystick (Echap : abandon)"
MsgSansAY   FCN "Pas d'AY : pas de joystick."
MsgPoussez  FCN "Poussez "
MsgUnSeul   FCN "  un seul contact a la fois : lachez, recommencez."
MsgPris     FCN "  deja pris : lachez, recommencez."
MsgBit      FCN "  -> IOA"
MsgBroche   FCN " (J602 broche "
MsgFerme    FCN ")"
MsgFini     FCN "Etalonnage ecrit dans /BIN/JOYSTICK.CFG."
MsgErreur   FCN "ERREUR : /BIN/JOYSTICK.CFG non ecrit."
MsgAbandon  FCN "Abandon : rien n'est ecrit."
NomFic      FCN "/BIN/JOYSTICK.CFG"
Fichier     FCC "JOY"
            FCB 1
            RMB JOY_N
Etape       RMB 1
Pris        RMB 1
Masque      RMB 1
Compte      RMB 1
Avant       RMB 1
NumBit      RMB 1
NomFmt      RMB 16
