; ===================================================================
; CLOUTEST.ASM — Essai de la Clouris (souris tactile) sur le port A de l'AY
; Usage: CLOUTEST
; Charge: page 1, $0000
;
; La Clouris : six clous et une plaque pour la paume (à la masse), sortie
; sur le port A de l'AY : J602 de la carte OSM39_mono, ou J104 de la carte
; SD-KBD-SON (même brochage).
; CLOU_INVERSE = 1 (carte Clouris, KiCad clouris/) : chaque clou attaque par
; 100 k la base d'un PNP (S9015 ; émetteur au +5 V), collecteur
; tiré à la masse par 47 k vers une porte de 74HC14 : doigt posé = bit à 0,
; repos = 1. Connecteur J7 de la carte : 1 +5 V, 2-7 clous J1-J6 (haut,
; droite, bas, gauche, centre, pouce), 8 GND.
; CLOU_INVERSE = 0 (premier montage) : clou -> 74HC14, tirage au +5 V,
; doigt posé = bit à 1.
;   IOA0 haut (J602-17)  IOA1 droite (15)  IOA2 bas (13)
;   IOA3 gauche (11)  IOA4 centre (9)  IOA5 clic gauche, le pouce (7)
;   IOA6-7 libres (5, 3 : lus à 1)  GND 19-20  +5 V 1-2
; Le port A est lu dans R14 (écrire 14 dans AY_ADR, lire AY_ADR) ; il doit
; être en entrée : bit 6 de R7 à 0 (le BIOS y met $3A, déjà bon).
; À chaque trame, R14 est relu ; à chaque changement, une ligne :
;   R14 = 11111110  haut       (les noms : les clous touchés)
; Échap pour sortir.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

CLOU_INVERSE    equ 1               ; 1 : carte à transistors PNP (doigt = 0)

    section .code

Start:
    LDX     #MsgTitre
    JSR     Aff_Ligne
    LDX     #MsgAide
    JSR     Aff_Ligne
    LDA     #7                  ; port A en entrée, le reste de R7 intact
    STA     AY_ADR
    LDB     AY_ADR
    ANDB    #%10111111
    STB     AY_DATA
    LDA     #14                 ; Avant = complément de la 1re lecture :
    STA     AY_ADR              ; celle-ci s'affiche toujours
    LDA     AY_ADR
    COMA
    STA     Avant

Boucle:
    JSR     [table_function_ram+sys_kbd_poll]
    CMPA    #$1B
    BEQ     Fin
    JSR     [table_function_ram+sys_video_wait_vsync]
    LDA     #14
    STA     AY_ADR
    LDA     AY_ADR
    CMPA    Avant
    BEQ     Boucle
    STA     Avant
    JSR     Aff_Etat
    BRA     Boucle

Fin:
    LDX     #MsgFin
    JMP     Aff_Ligne

; -------------------------------------------------------------------
; Aff_Etat : A = R14 ; « R14 = bbbbbbbb  zones... »
Aff_Etat:
    PSHS    A
    LDX     #MsgR14
    JSR     Aff
    LDB     #8
    LDA     ,S
AE_Bit:
    PSHS    A,B
    LDA     #'0'
    TST     ,S
    BPL     AE_Zero
    LDA     #'1'
AE_Zero:
    JSR     [table_function_ram+sys_PrintChar]
    PULS    A,B
    LSLA
    DECB
    BNE     AE_Bit
    LDX     #TabNoms            ; les noms des clous touchés, du bit 0 au bit 5
    PULS    A
    IFNE    CLOU_INVERSE
    COMA                        ; doigt posé = bit à 0
    ENDC
AE_Nom:
    LSRA
    BCC     AE_Suivant
    PSHS    A,X
    LDX     ,X
    JSR     Aff
    PULS    A,X
AE_Suivant:
    LEAX    2,X
    CMPX    #TabNoms+12
    BLO     AE_Nom
    JMP     [table_function_ram+sys_PrintCRLF]

; -------------------------------------------------------------------
Aff:
    JMP     [table_function_ram+sys_PrintString]

Aff_Ligne:
    JSR     [table_function_ram+sys_PrintString]
    JMP     [table_function_ram+sys_PrintCRLF]

; -------------------------------------------------------------------
TabNoms     FDB NomHaut,NomDroite,NomBas,NomGauche,NomCentre,NomClic
NomHaut     FCN "  haut"
NomDroite   FCN "  droite"
NomBas      FCN "  bas"
NomGauche   FCN "  gauche"
NomCentre   FCN "  centre"
NomClic     FCN "  clic"
MsgTitre    FCN "CLOUTEST - la Clouris sur le port A de l'AY (R14)"
MsgAide     FCN "Touchez les clous ; Echap pour sortir."
MsgR14      FCN "R14 = "
MsgFin      FCN "Fin."
Avant       FCB 0
