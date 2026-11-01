; ===================================================================
; AYTEST.ASM — Essai de l'AY-3-8910 de la carte SD-KBD-SON
; Usage: AYTEST
; Charge: page 1, $0000
;
; L'AY est sur le bus : écrire AY_ADR ($A150) choisit le registre,
; écrire AY_DATA ($A151) y met la donnée, lire AY_ADR rend sa valeur.
; Horloge = E (1,8432 MHz) : période de ton = 115200 / f (La 440 = 262).
;
; 1. Relecture : deux motifs par registre (R0-R13), comparés selon la
;    largeur de chaque registre ; seules les fautes sont affichées.
;    Volumes à 0 pendant ce temps : silence.
; 2. Écoute, chaque étape annoncée à l'écran : voie A, B, C seules (La
;    440 Hz, 1 s chacune), les trois (accord Do Mi Sol), le bruit, une
;    enveloppe. Puis silence (R7 = $3F, volumes à 0).
; Les ports A et B de l'AY (J104) restent en entrée.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    LDX     #MsgTitre
    JSR     Aff_Ligne
    JSR     Silence

    ; --- 1. relecture ---
    CLR     Justes
    CLR     Total
    LDX     #Tests
RL_Test:
    LDA     ,X+                 ; registre ($FF : fin)
    BMI     RL_Fin
    LDB     ,X+                 ; motif
    STA     Reg
    STB     Motif
    JSR     Ay_Ecrit
    LDA     Reg
    JSR     Ay_Lit
    STA     Relu
    LDY     #Masques
    LDB     Reg
    LDA     B,Y
    ANDA    Motif
    STA     Attendu
    INC     Total
    CMPA    Relu
    BNE     RL_Faute
    INC     Justes
    BRA     RL_Test
RL_Faute:
    PSHS    X
    LDX     #MsgR
    JSR     Aff
    LDB     Reg
    CLRA
    JSR     Aff_Dec
    LDX     #MsgEcrit
    JSR     Aff
    LDA     Motif
    JSR     [table_function_ram+sys_PrintHexChar]
    LDX     #MsgRelu
    JSR     Aff
    LDA     Relu
    JSR     [table_function_ram+sys_PrintHexChar]
    LDX     #MsgAttendu
    JSR     Aff
    LDA     Attendu
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     #')'
    JSR     [table_function_ram+sys_PrintChar]
    JSR     [table_function_ram+sys_PrintCRLF]
    PULS    X
    BRA     RL_Test
RL_Fin:
    JSR     Silence
    LDX     #MsgRelecture
    JSR     Aff
    LDB     Justes
    CLRA
    JSR     Aff_Dec
    LDA     #'/'
    JSR     [table_function_ram+sys_PrintChar]
    LDB     Total
    CLRA
    JSR     Aff_Dec
    LDX     #MsgJustes
    JSR     Aff_Ligne

    ; --- 2. écoute : une étape = registres, texte, durée ---
    LDY     #Etapes
EC_Etape:
    LDX     ,Y++                ; texte (0 : fin)
    BEQ     EC_Fin
    JSR     Aff_Ligne
    JSR     Silence
EC_Reg:
    LDA     ,Y+                 ; registre ($FF : fin de la liste)
    BMI     EC_Duree
    LDB     ,Y+
    JSR     Ay_Ecrit
    BRA     EC_Reg
EC_Duree:
    LDE     ,Y+                 ; trames
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Silence
    LDE     #15                 ; un quart de seconde entre deux étapes
    JSR     [table_function_ram+sys_video_wait_vsync]
    BRA     EC_Etape
EC_Fin:
    JSR     Silence
    LDX     #MsgFin
    JMP     Aff_Ligne

; -------------------------------------------------------------------
; A = registre, B = valeur. Préserve X et Y.
Ay_Ecrit:
    STA     AY_ADR
    STB     AY_DATA
    RTS

; A = registre -> A = valeur
Ay_Lit:
    STA     AY_ADR
    LDA     AY_ADR
    RTS

; Mixeur tout coupé (ports en entrée), volumes à 0. Préserve X et Y.
Silence:
    LDA     #7
    LDB     #$3F
    BSR     Ay_Ecrit
    LDA     #8
    CLRB
    BSR     Ay_Ecrit
    LDA     #9
    BSR     Ay_Ecrit
    LDA     #10
    BRA     Ay_Ecrit

; -------------------------------------------------------------------
Aff:
    JMP     [table_function_ram+sys_PrintString]

Aff_Ligne:
    JSR     [table_function_ram+sys_PrintString]
    JMP     [table_function_ram+sys_PrintCRLF]

; D = valeur (< 1000), en décimal sans zéros de tête
Aff_Dec:
    PSHS    D,X
    LDX     #Puiss10
    CLR     Tete
AD_Chiffre:
    CLR     Chiffre
AD_Sous:
    CMPD    ,X
    BLO     AD_Aff
    SUBD    ,X
    INC     Chiffre
    BRA     AD_Sous
AD_Aff:
    PSHS    D
    LDA     Chiffre
    BNE     AD_Ecrit
    TST     Tete
    BNE     AD_Ecrit
    CMPX    #Puiss10+4          ; les unités : toujours
    BNE     AD_Saute
AD_Ecrit:
    INC     Tete
    ADDA    #'0'
    JSR     [table_function_ram+sys_PrintChar]
AD_Saute:
    PULS    D
    LEAX    2,X
    CMPX    #Puiss10+6
    BNE     AD_Chiffre
    PULS    D,X,PC

Puiss10:        FDB 100,10,1

; --- Relecture : registre, motif ; largeur de chaque registre ---
Tests:
    FCB     0,$55,0,$AA,1,$05,1,$0A,2,$55,2,$AA,3,$05,3,$0A
    FCB     4,$55,4,$AA,5,$05,5,$0A,6,$15,6,$0A,7,$15,7,$2A
    FCB     8,$05,8,$0A,9,$05,9,$0A,10,$05,10,$0A
    FCB     11,$55,11,$AA,12,$55,12,$AA,13,$05,13,$0A,$FF
Masques:
    FCB     $FF,$0F,$FF,$0F,$FF,$0F,$1F,$FF,$1F,$1F,$1F,$FF,$FF,$0F

; --- Écoute : FDB texte, puis (registre, valeur)..., $FF, trames ---
; La 440 Hz : période 262 = $0106 ; Do 523 : 220 ; Mi 659 : 175 ;
; Sol 784 : 147. Mixeur R7 : bits 0-2 ton A B C, 3-5 bruit, 0 = actif.
Etapes:
    FDB     MsgVoieA
    FCB     0,$06,1,$01,7,$3E,8,15,$FF,60
    FDB     MsgVoieB
    FCB     2,$06,3,$01,7,$3D,9,15,$FF,60
    FDB     MsgVoieC
    FCB     4,$06,5,$01,7,$3B,10,15,$FF,60
    FDB     MsgAccord
    FCB     0,220,1,0,2,175,3,0,4,147,5,0,7,$38,8,12,9,12,10,12,$FF,90
    FDB     MsgBruit
    FCB     6,15,7,$37,8,15,$FF,60
    FDB     MsgEnveloppe
    FCB     0,$06,1,$01,7,$3E,11,$10,12,$0E,13,$08,8,$10,$FF,120
    FDB     0

MsgTitre:       FCN "AYTEST - AY-3-8910 de la carte SD-KBD-SON ($A150/$A151)"
MsgR:           FCN "  R"
MsgEcrit:       FCN " : ecrit $"
MsgRelu:        FCN ", relu $"
MsgAttendu:     FCN " (attendu $"
MsgRelecture:   FCN "Relecture des registres : "
MsgJustes:      FCN " justes"
MsgVoieA:       FCN "Voie A seule : La 440 Hz"
MsgVoieB:       FCN "Voie B seule : La 440 Hz"
MsgVoieC:       FCN "Voie C seule : La 440 Hz"
MsgAccord:      FCN "Les trois voies : Do Mi Sol"
MsgBruit:       FCN "Bruit (voie A)"
MsgEnveloppe:   FCN "Enveloppe (voie A, La, dents de scie)"
MsgFin:         FCN "Fin : silence."

; --- Variables ---
Reg             rmb 1
Motif           rmb 1
Relu            rmb 1
Attendu         rmb 1
Justes          rmb 1
Total           rmb 1
Tete            rmb 1
Chiffre         rmb 1
