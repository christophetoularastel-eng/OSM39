; ===================================================================
; ZMACHINE.ASM - Interpréteur Z-machine (versions 4, 5, 7, 8) pour OSM39
; ===================================================================
; Lance les fictions interactives d'Infocom et d'Inform (.z5, .z8) en
; plein écran 80 x 30 : ligne d'état en haut (fenêtre 1), texte qui
; défile en bas (fenêtre 0). Application d'OSM-VISION (page 1, liée à
; $0000, App_Start à l'offset 0, attribut a) ; le jeu en argument :
;       ZMACHINE AVENTURE.Z5        (Entrée sur un .Z5/.Z8 d'OSM-VISION)
;
; SOURCE UNIQUE : tools/zmachine/zmachine.py, le modèle exact (décodage,
; objets, texte, dictionnaire, écran, sauvegardes Quetzal) que
; test/verifie_zmachine.py compare à ce binaire. zmachine_data.inc est
; GÉNÉRÉ (zmachine.py --inc) : ne pas l'éditer.
;
; MÉMOIRE. Le jeu (jusqu'à 256 Ko) est lu par blocs de 256 octets dans
; un cache en page 1 (CRENEAUX, $xx00) : bloc b de la Z-machine = octets
; b*256..b*256+255. Les blocs 0-254 (64 Ko moins 256) sont copiés au
; lancement dans les pages 2-3, le bloc b en (b+1)*256 (le premier bloc
; des pages reste libre : l'en-tête Quetzal d'une sauvegarde s'y écrit,
; juste devant la mémoire dynamique) ; les blocs suivants sont lus sur la
; carte, secteur par secteur. Cache à réécriture : une écriture marque le
; créneau sale, renvoyé en page 2-3 (FarWrite) quand on le libère. Carte
; Carte des blocs CARTE : un octet par bloc, la page ($xx) du créneau ou
; 0 ; entrée du bloc b en CARTE + (b EOR $80) (index signé A,X pour un
; bloc < 256 : CARTEC + b).
;
; REGISTRES DU CŒUR. Y = octet suivant du code Z (dans le créneau du
; bloc PCBLOC, qui n'est jamais choisi comme victime ; Y = PCFIN : le bloc
; suivant, chargé à la lecture). U = sommet de la pile Z (descendante,
; mots grand-boutistes). Toute routine préserve Y et U, sauf celles qui
; ont pour rôle de les changer (sauts, appels, pile).
;
; PILE Z. Un cadre : 8 octets d'en-tête à FP (FP précédent, PC de retour
; sur 3 octets, variable de résultat, drapeaux : bit 7 résultat jeté, bit
; 6 appel interne, bits 0-3 nombre de locales ; nombre d'arguments), puis
; les locales (locale k en FP-2k), puis la pile d'évaluation. PROF compte
; les cadres (le premier, fictif, compris), comme len(cadres) du modèle.
;
; ÉCRAN. Une copie de l'écran en page 1 (ECRAN, 160 octets par rangée,
; dans le format de la carte : v4 caractères puis attributs, mono
; entrelacés) ; une rangée modifiée est marquée SALE et l'IRQ du VSYNC
; (Irq_Z, posée devant celle du BIOS) en recopie au plus RANG_TRAME par
; trame, au tout début du retour de trame. Les rangées 25-29 d'OSM-VISION
; sont sauvées au lancement et rendues à la sortie (par l'IRQ aussi).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"

    export App_Start

LARGEUR         equ 80
HAUTEUR         equ 30
RANG_OCT        equ 160             ; octets d'une rangée de la copie d'écran
    IFNE    CARTE_MONO
ATTR_OFS        equ 1               ; l'attribut suit le caractère
CASE_PAS        equ 2
    ELSE
ATTR_OFS        equ 80              ; les attributs après les 80 caractères
CASE_PAS        equ 1
    ENDC
RANG_TRAME      equ 3               ; rangées recopiées par VSYNC au plus
TRAMES_DIXIEME  equ 6               ; 1/10 s = 6 trames (60 Hz)

; --- Page 1 : au-delà du code (le Makefile vérifie que le code finit avant)
ZONE            equ $3800
ZPILE_BAS       equ ZONE            ; pile Z : 2 Ko
ZPILE_HAUT      equ ZONE+$0800
ECRAN           equ $4000           ; 30 x 160 = 4800 octets
SALE            equ $52C0           ; 30 rangées à recopier (1 = sale)
LIGNE           equ $5300           ; la saisie en cours (256)
MOT             equ $5400           ; le mot en attente : 160 caractères...
MOT_ATTR        equ $54A0           ; ... et leurs 160 attributs
MOT_MAX         equ 160
SECTEUR         equ $5600           ; un secteur de la carte (512)
SAUVE           equ $5800           ; rangées 25-29 d'OSM-VISION (800)
AlphaT          equ $5B20           ; les 3 alphabets (78)
Flux3T          equ AlphaT+78       ; flux 3 : (table, compte) x 16 (64)
DcSeps          equ Flux3T+64       ; séparateurs du dictionnaire (32)
CARTE           equ $5C00           ; carte des blocs : 1024 octets (256 Ko)
CARTEC          equ CARTE+$80
TABLES_CAR      equ $6000           ; tables de caractères (483 octets, Unicode_Init)
UniT            equ TABLES_CAR      ; la table Unicode du jeu (97 mots)
ZsCp            equ UniT+194        ; ZSCII 155+ -> CP437
LatZs           equ ZsCp+97         ; Latin-1 $A0-$FF -> ZSCII
LatCp           equ LatZs+96        ; Latin-1 $A0-$FF -> CP437
CRENEAUX        equ $6200           ; créneaux du cache : $6200-$7FFF
CREN_HI         equ $62
NB_CRENEAUX     equ 30
CREN_EPINGLES   equ 3               ; créneaux 0-2 : les globales (480 octets)
BLOCS_MAX       equ 1024            ; 256 Ko
BLOCS_RAM       equ 255             ; blocs 0-254 en pages 2-3

; OCTET : l'octet suivant du code -> A (Y avance ; au bout du créneau, le
; bloc suivant est chargé par PC_Suivant, qui préserve B, X et W)
OCTET   MACRO
        CMPY    PCFIN
        BNE     *+5
        JSR     PC_Suivant
        LDA     ,Y+
        ENDM

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0), appelé par OSM-VISION (FAR_CALL, page 1).
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    STS     PileHote                ; pour sortir de n'importe où (erreur)
    LDA     >argc
    CMPA    #2
    BHS     AS_Arg
    LDX     #TxtUsage
    JMP     Erreur_Avant
AS_Arg:
    LDX     >argv+2
    LDY     #NomJeu
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #NomJeu
    LDY     #InfoJeu
    JSR     [table_function_ram+sys_FS_FileInfo]
    BCC     AS_Trouve
    LDX     #TxtAbsent
    JMP     Erreur_Avant
AS_Trouve:
    JSR     Ecran_Init              ; copie d'écran vide, IRQ posée
    LDX     #TxtCharge              ; « Chargement de JEU... »
    JSR     Ecrit_Message
    LDX     >argv+2
    JSR     Ecrit_Message
    LDX     #TxtPoints
    JSR     Ecrit_Message
    JSR     Vide_Mot
    JSR     Charge_Jeu              ; en-tête vérifié, pages 2-3 remplies
    LBCS    Erreur
    JSR     Ecran_RAZ               ; l'écran du début (comme le modèle)
    JSR     Cache_Init
    LDD     >vsync_tick             ; graine du hasard : jamais 0
    BNE     AS_Graine
    INCB
AS_Graine:
    STD     Alea
    CLR     AleaSeq
    CLR     AleaSeq+1
    LDA     #1
    STA     Fonte
    JSR     Demarre                 ; en-tête, pile, PC
    LBCS    Erreur
Boucle:
    JSR     Pas
    BRA     Boucle

; -------------------------------------------------------------------
; Demarre : en-tête de l'interpréteur, pile Z vide, PC initial
; (début, @restart et après @restore pour l'en-tête seulement).
; -------------------------------------------------------------------
Demarre:
    JSR     Entete
    JSR     Epingle
    LDU     #ZPILE_HAUT-8           ; le cadre fictif
    CLR     ,U
    CLR     1,U
    CLR     2,U
    CLR     3,U
    CLR     4,U
    CLR     5,U
    CLR     6,U
    CLR     7,U
    STU     FP
    LDD     #1
    STD     Prof
    CLR     Flux3N
    LDA     #1
    STA     Flux1
    CLR     ZPC
    LDX     #6
    JSR     Lit16
    STD     ZPC+1
    JMP     Va_PC

; Entete : les champs que l'interpréteur écrit (comme entete() du modèle)
Entete:
    LDX     #1
    JSR     Lit8
    TST     V3
    BEQ     En_V4
    ORA     #$20                    ; v3 : fenêtres oui, ligne d'état oui,
    ANDA    #$AF                    ; police fixe (~$50)
    BRA     En_F1
En_V4:
    ORA     #$9D                    ; couleurs, gras, italique, fixe, délai
    ANDA    #$DD                    ; ~$22
En_F1:
    LDX     #1
    JSR     Ecrit8
    LDX     #$11
    JSR     Lit8
    ANDA    #$47                    ; ni images, ni UNDO, ni souris, ni son
    LDX     #$11
    JSR     Ecrit8
    LDX     #$32
    LDD     #$0101                  ; standard 1.1
    JSR     Ecrit16
    TST     V3
    BNE     En_Champs               ; (v3 : pas de champs d'écran)
    LDX     #$1E
    LDD     #$0641                  ; interpréteur 6, version 'A'
    JSR     Ecrit16
    LDX     #$20
    LDD     #(HAUTEUR*256)+LARGEUR
    JSR     Ecrit16
    LDX     #$22
    LDD     #LARGEUR
    JSR     Ecrit16
    LDX     #$24
    LDD     #HAUTEUR
    JSR     Ecrit16
    LDX     #$26
    LDD     #$0101
    JSR     Ecrit16
    LDX     #$2C
    LDD     #$0209
    JSR     Ecrit16
En_Champs:
    LDX     #$0E
    JSR     Lit16
    STD     Statique
    LDX     #$0C
    JSR     Lit16
    STD     Globales
    LDX     #$0A
    JSR     Lit16
    ADDD    #126-14                 ; objet o en ObjBase + 14*o
    TST     V3
    BEQ     En_Obj
    SUBD    #126-14-62+9            ; v3 : ObjBase + 9*o
En_Obj:
    STD     ObjBase
    LDX     #$0A
    JSR     Lit16
    STD     Objets
    LDX     #$18
    JSR     Lit16
    STD     Abrev
    LDX     #$08
    JSR     Lit16
    STD     Dico
    JSR     Alphabets
    JMP     Unicode_Init

; -------------------------------------------------------------------
; Erreurs. Erreur_Avant : avant l'écran du jeu (message par la console).
; Erreur : X = message ; affiché en bas de l'écran du jeu, une touche,
; puis sortie.
; -------------------------------------------------------------------
Erreur_Avant:
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_PrintCRLF]
    JSR     [table_function_ram+sys_scan_keyboard]
    LDS     PileHote
    RTS

Erreur:
    LDS     PileHote
    LDU     #ZPILE_HAUT             ; (la pile Z ne sert plus)
    PSHS    X
    JSR     Vide_Mot
    LDX     #TxtErreur
    JSR     Ecrit_Message
    PULS    X
    JSR     Ecrit_Message
    JSR     Nouvelle_Ligne
    JSR     Attend_Touche
    JMP     Quitte

; Ecrit_Message : X = texte ASCII (0 final) vers la fenêtre du bas
Ecrit_Message:
    CLR     Fen
EM_Car:
    LDA     ,X+
    BEQ     EM_Fin
    PSHS    X
    JSR     Ecran_Car
    PULS    X
    BRA     EM_Car
EM_Fin:
    RTS

; Quitte : l'écran d'OSM-VISION revient (rangées 25-29 par l'IRQ, le
; reste par OSM-VISION), le cache est perdu.
Quitte:
    LDS     PileHote
    JSR     Ecran_Fin
    RTS

; ===================================================================
; DÉCODAGE D'UNE INSTRUCTION
; ===================================================================
Pas:
    OCTET
    STA     OpCode
    CMPA    #$80
    LBLO    P_Long
    CMPA    #$C0
    LBHS    P_Var
    CMPA    #$B0
    BHS     P_Zero
    ; court, 1OP : type dans les bits 5-4
    LSLA
    LSLA
    ANDA    #$C0
    JSR     Lit_OpH
    STD     Ops
    LDA     #1
    STA     NOps
    LDA     OpCode
    ANDA    #$0F
    LSLA
    LDX     #Tab1OP
    JMP     [A,X]
P_Zero:
    CMPA    #$BE
    BEQ     P_Etendu
    ANDA    #$0F
    LSLA
    LDX     #Tab0OP
    JMP     [A,X]
P_Etendu:
    CLR     NOps
    OCTET
    STA     OpCode
    OCTET
    LDX     #Ops
    JSR     Lit_Types
    LDA     OpCode
    CMPA    #14
    LBHS    Op_Illegal
    LSLA
    LDX     #TabEXT
    JMP     [A,X]
P_Long:                             ; bit 6 / bit 5 : variable, sinon petite constante
    LDA     #2
    STA     NOps
    OCTET
    TFR     A,B
    LDA     OpCode
    BITA    #$40
    BEQ     PL1_C
    JSR     Lit_Var
    BRA     PL1_F
PL1_C:
    CLRA
PL1_F:
    STD     Ops
    OCTET
    TFR     A,B
    LDA     OpCode
    BITA    #$20
    BEQ     PL2_C
    JSR     Lit_Var
    BRA     PL2_F
PL2_C:
    CLRA
PL2_F:
    STD     Ops+2
    BRA     P_2OP
P_Var:
    CLR     NOps
    CMPA    #$EC                    ; call_vs2 / call_vn2 : deux octets de types
    BEQ     P_Var8
    CMPA    #$FA
    BEQ     P_Var8
    JSR     Octet_PC
    LDX     #Ops
    JSR     Lit_Types
    BRA     P_VarSuite
P_Var8:
    JSR     Octet_PC
    STA     Types2
    JSR     Octet_PC
    STA     Types2+1
    LDA     Types2
    LDX     #Ops
    JSR     Lit_Types
    BCS     P_VarSuite              ; arrêt dès le premier « omis »
    LDA     Types2+1
    LDX     #Ops+8
    JSR     Lit_Types
P_VarSuite:
    LDA     OpCode
    CMPA    #$E0
    BHS     P_VarOp
P_2OP:
    LDA     OpCode
    ANDA    #$1F
    LSLA
    LDX     #Tab2OP
    JMP     [A,X]
P_VarOp:
    ANDA    #$1F
    LSLA
    LDX     #TabVAR
    JMP     [A,X]

; Lit_Types : A = octet de types, X = où ranger ; NOps augmente.
; C = 1 si un type « omis » (3) a arrêté la lecture.
Lit_Types:
    STA     TypesOct
    LDB     #4
    STB     LtN
LT_Boucle:
    LDA     TypesOct
    ANDA    #$C0
    CMPA    #$C0
    BEQ     LT_Omis
    TSTA
    PSHS    X
    JSR     Lit_OpH
    PULS    X
    STD     ,X++
    INC     NOps
    LSL     TypesOct
    LSL     TypesOct
    DEC     LtN
    BNE     LT_Boucle
    ANDCC   #$FE
    RTS
LT_Omis:
    ORCC    #1
    RTS

; Lit_OpH : type dans les bits 7-6 de A, drapeaux posés ($00 grande
; constante, $40 petite, $80 variable) -> D
Lit_OpH:
    BMI     LOH_Var
    BNE     LOH_Petit
    OCTET
    TFR     A,B
    OCTET
    EXG     A,B
    RTS
LOH_Petit:
    OCTET
    TFR     A,B
    CLRA
    RTS
LOH_Var:
    OCTET
    TFR     A,B
    JMP     Lit_Var

; -------------------------------------------------------------------
; Variables : B = numéro. Lit_Var -> D (0 : dépile). Ecrit_Var : X =
; valeur (0 : empile). Les « indirectes » lisent/écrivent la pile en place.
; -------------------------------------------------------------------
Lit_Var:
    TSTB
    BEQ     LV_Pile
    CMPB    #16
    BHS     LV_Glob
    LDX     FP
    LSLB
    NEGB
    LDD     B,X
    RTS
LV_Pile:
    LDD     ,U++
    RTS
LV_Glob:                            ; les globales : épinglées (GlobHote)
    SUBB    #16
    CLRA
    LSLB
    ROLA
    ADDD    GlobHote
    TFR     D,X
    LDD     ,X
    RTS

Ecrit_Var:
    TSTB
    BEQ     EV_Pile
    CMPB    #16
    BHS     EV_Glob
    LSLB
    NEGB
    PSHS    X
    LDX     FP
    LEAX    B,X
    PULS    D
    STD     ,X
    RTS
EV_Pile:
    STX     ,--U
    RTS
EV_Glob:
    SUBB    #16
    CLRA
    LSLB
    ROLA
    ADDD    GlobHote
    EXG     D,X
    STD     ,X
    TFR     X,D                     ; le créneau (et le suivant si à cheval) : sale
    LDX     #CrenSale-CREN_HI
    STA     A,X
    CMPB    #$FF
    BNE     EV_Fin
    INCA
    STA     A,X
EV_Fin:
    RTS

Lit_Var_Ind:
    TSTB
    BNE     Lit_Var
    LDD     ,U
    RTS

Ecrit_Var_Ind:
    TSTB
    BNE     Ecrit_Var
    STX     ,U
    RTS

; Stocke : D = valeur, dans la variable que nomme l'octet suivant du code
Stocke:
    PSHS    D
    OCTET
    TFR     A,B
    PULS    X
    JMP     Ecrit_Var

; Stocke_Branche : D = valeur, stockée puis branchement si non nulle
Stocke_Branche:
    PSHS    D
    BSR     Stocke
    PULS    D
    JMP     Branche_D

; -------------------------------------------------------------------
; Branchements. Branche : A = condition (0 = fausse). Branche_D : D.
; -------------------------------------------------------------------
Branche_D:
    CMPD    #0
    BEQ     Branche
    LDA     #1
Branche:
    STA     BrCond
    OCTET
    STA     BrOct
    BITA    #$40
    BNE     Br_Court
    ANDA    #$3F
    BITA    #$20
    BEQ     Br_Pos
    ORA     #$C0
Br_Pos:
    STA     BrDep
    OCTET
    STA     BrDep+1
    BRA     Br_Test
Br_Court:
    ANDA    #$3F
    STA     BrDep+1
    CLR     BrDep
Br_Test:
    LDA     BrOct                   ; sur vrai (bit 7) ou sur faux
    ANDA    #$80
    TST     BrCond
    BEQ     Br_Faux
    TSTA
    BNE     Br_Pris
    RTS
Br_Faux:
    TSTA
    BEQ     Br_Pris
    RTS
Br_Pris:
    LDD     BrDep
    CMPD    #1
    BHI     Br_Saut
    JMP     Retour                  ; 0 : rfalse, 1 : rtrue (D)
Br_Saut:
    SUBD    #2
    ; continue dans Saut

; Saut : D = déplacement signé à ajouter au PC
Saut:
    STD     SautDep
    LEAX    D,Y
    TFR     X,D
    SUBD    PCFIN
    ADDD    #256
    TSTA
    BNE     Sa_Lent                 ; hors du créneau courant
    TFR     X,Y
    RTS
Sa_Lent:
    JSR     Lit_PC
    LDD     SautDep
    ADDD    ZPC+1
    STD     ZPC+1
    LDA     SautDep                 ; retenue + extension de signe
    BMI     Sa_Neg
    LDA     ZPC
    ADCA    #0
    BRA     Sa_Fin
Sa_Neg:
    LDA     ZPC
    ADCA    #$FF
Sa_Fin:
    STA     ZPC
    JMP     Va_PC

; ===================================================================
; APPELS ET RETOURS
; ===================================================================
; Appel : Ops = routine (paquée) puis arguments ; NOps ; A = variable de
; résultat, ou B<>0 dans AppDrap (bit 7 : résultat jeté, bit 6 : interne)
Appel_S:                            ; call_*s : l'octet de résultat suit
    JSR     Octet_PC
    STA     AppVar
    CLR     AppDrap
    BRA     Appel
Appel_N:
    CLR     AppVar
    LDA     #$80
    STA     AppDrap
Appel:
    LDD     Ops
    BNE     Ap_Vraie
    LDA     AppDrap                 ; routine 0 : rend 0
    BNE     Ap_Rien
    LDB     AppVar
    LDX     #0
    JMP     Ecrit_Var
Ap_Rien:
    RTS
Ap_Vraie:
    JSR     Lit_PC                  ; le retour
    LEAU    -8,U
    LDX     FP
    STX     ,U
    LDA     ZPC
    STA     2,U
    LDD     ZPC+1
    STD     3,U
    LDA     AppVar
    STA     5,U
    LDB     NOps
    DECB
    STB     7,U
    STU     FP
    LDD     Prof
    ADDD    #1
    STD     Prof
    LDD     Ops                     ; PC = routine * 4 (ou 8)
    JSR     Paquee
    JSR     Va_PC
    JSR     Octet_PC                ; nombre de locales
    ANDA    #$0F
    STA     ApN
    ORA     AppDrap
    LDX     FP
    STA     6,X
    LDX     #Ops+2
    STX     ApArg
    CLR     ApK
Ap_Locale:                          ; locale k : l'argument k (k <= nargs), sinon
    INC     ApK                     ; 0 (v5+) ou la valeur de l'en-tête (v1-4)
    LDA     ApK
    CMPA    ApN
    BHI     Ap_Fin
    CLRA
    CLRB
    TST     Vieux
    BEQ     Ap_Defaut
    OCTET
    TFR     A,B
    OCTET
    EXG     A,B
Ap_Defaut:
    PSHS    D
    LDA     ApK
    LDX     FP
    CMPA    7,X
    BHI     Ap_Zero
    LDX     ApArg
    LDD     ,X++
    STX     ApArg
    LEAS    2,S
    BRA     Ap_Pose
Ap_Zero:
    PULS    D
Ap_Pose:
    STD     ,--U
    BRA     Ap_Locale
Ap_Fin:
    RTS

; Paquee : D = adresse paquée -> ZPC (24 bits) = D * 2 (v3), * 4 (v4,
; v5, v7) ou * 8 (v8)
Paquee:
    CLR     ZPC
    STD     ZPC+1
    LDB     Decal
Pq_Boucle:
    LSL     ZPC+2
    ROL     ZPC+1
    ROL     ZPC
    DECB
    BNE     Pq_Boucle
    RTS

; Retour : D = valeur rendue par la routine courante
Retour:
    STD     RetVal
    LDU     FP
    LDX     ,U
    STX     FP
    LDA     2,U
    STA     ZPC
    LDD     3,U
    STD     ZPC+1
    LDD     5,U                     ; A = variable, B = drapeaux
    STD     RetVarDr
    LEAU    8,U
    LDD     Prof
    SUBD    #1
    STD     Prof
    JSR     Va_PC
    LDB     RetVarDr+1
    BITB    #$40
    BNE     Rt_Interne
    BITB    #$80
    BNE     Rt_Jete
    LDB     RetVarDr
    LDX     RetVal
    JMP     Ecrit_Var
Rt_Interne:
    LDD     RetVal
    STD     ValInterne
Rt_Jete:
    RTS

; Appel_Interne : D = routine (paquée), sans argument -> D = sa valeur.
; L'interpréteur l'exécute jusqu'à son retour (délai de saisie).
Appel_Interne:
    STD     Ops
    LDA     #1
    STA     NOps
    LDD     Prof
    PSHS    D
    CLR     AppVar
    LDA     #$40
    STA     AppDrap
    JSR     Appel
AI_Boucle:
    LDD     Prof
    CMPD    ,S
    BEQ     AI_Fin
    JSR     Pas
    BRA     AI_Boucle
AI_Fin:
    LEAS    2,S
    LDD     ValInterne
    RTS

; ===================================================================
; LES INSTRUCTIONS
; ===================================================================
Op_Illegal:
    LDX     #TxtIllegal
    JMP     Erreur

; --- 2OP -------------------------------------------------------------
Op_Je:
    LDA     NOps
    DECA
    STA     JeN
    LDX     #Ops+2
    LDD     Ops
Je_Boucle:
    TST     JeN
    BEQ     Je_Non
    CMPD    ,X++
    BEQ     Je_Oui
    DEC     JeN
    BRA     Je_Boucle
Je_Non:
    CLRA
    JMP     Branche
Je_Oui:
    LDA     #1
    JMP     Branche

Op_Jl:
    LDD     Ops
    CMPD    Ops+2
    BLT     Vrai
Faux:
    CLRA
    JMP     Branche
Vrai:
    LDA     #1
    JMP     Branche

Op_Jg:
    LDD     Ops
    CMPD    Ops+2
    BGT     Vrai
    BRA     Faux

Op_Dec_Chk:
    LDB     Ops+1
    JSR     Lit_Var_Ind
    SUBD    #1
    PSHS    D
    TFR     D,X
    LDB     Ops+1
    JSR     Ecrit_Var_Ind
    PULS    D
    CMPD    Ops+2
    BLT     Vrai
    BRA     Faux

Op_Inc_Chk:
    LDB     Ops+1
    JSR     Lit_Var_Ind
    ADDD    #1
    PSHS    D
    TFR     D,X
    LDB     Ops+1
    JSR     Ecrit_Var_Ind
    PULS    D
    CMPD    Ops+2
    BGT     Vrai
    BRA     Faux

Op_Jin:
    LDD     Ops
    BEQ     Faux
    JSR     Obj_Adr
    CLRB
    JSR     Lien_Lit
    CMPD    Ops+2
    BEQ     Vrai
    BRA     Faux

Op_Test:
    LDD     Ops
    ANDA    Ops+2
    ANDB    Ops+3
    CMPD    Ops+2
    BEQ     Vrai
    BRA     Faux

Op_Or:
    LDD     Ops
    ORA     Ops+2
    ORB     Ops+3
    JMP     Stocke

Op_And:
    LDD     Ops
    ANDA    Ops+2
    ANDB    Ops+3
    JMP     Stocke

; Attr_Adr : Ops = objet, Ops+2 = attribut -> X = adresse de l'octet,
; B = masque
Attr_Adr:
    LDD     Ops
    JSR     Obj_Adr
    LDD     Ops+2
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LEAX    D,X
    LDB     Ops+3
    ANDB    #7
    LDA     #$80
AA_Masque:
    TSTB
    BEQ     AA_Fin
    LSRA
    DECB
    BRA     AA_Masque
AA_Fin:
    TFR     A,B
    RTS

Op_Test_Attr:
    LDD     Ops
    LBEQ    Faux
    BSR     Attr_Adr
    PSHS    B
    JSR     Lit8
    ANDA    ,S+
    JMP     Branche

Op_Set_Attr:
    LDD     Ops
    BEQ     OSA_Fin
    BSR     Attr_Adr
    PSHS    B,X
    JSR     Lit8
    PULS    B,X
    PSHS    B
    ORA     ,S+
    JMP     Ecrit8
OSA_Fin:
    RTS

Op_Clear_Attr:
    LDD     Ops
    BEQ     OSA_Fin
    BSR     Attr_Adr
    COMB
    PSHS    B,X
    JSR     Lit8
    PULS    B,X
    PSHS    B
    ANDA    ,S+
    JMP     Ecrit8

Op_Store:
    LDB     Ops+1
    LDX     Ops+2
    JMP     Ecrit_Var_Ind

Op_Insert_Obj:
    LDD     Ops
    BEQ     OSA_Fin
    LDD     Ops+2
    BEQ     OSA_Fin
    JMP     Insere

Op_Loadw:
    LDD     Ops+2
    LSLB
    ROLA
    ADDD    Ops
    TFR     D,X
    JSR     Lit16
    JMP     Stocke

Op_Loadb:
    LDD     Ops+2
    ADDD    Ops
    TFR     D,X
    JSR     Lit8
    TFR     A,B
    CLRA
    JMP     Stocke

Op_Get_Prop:
    LDD     Ops
    BEQ     OGP_Defaut
    JSR     Trouve_Prop
    CMPX    #0
    BEQ     OGP_Defaut
    CMPB    #1
    BNE     OGP_Mot
    JSR     Lit8
    TFR     A,B
    CLRA
    JMP     Stocke
OGP_Mot:
    JSR     Lit16
    JMP     Stocke
OGP_Defaut:
    LDD     Ops+2
    SUBD    #1
    LSLB
    ROLA
    ADDD    Objets
    TFR     D,X
    JSR     Lit16
    JMP     Stocke

Op_Get_Prop_Addr:
    LDD     Ops
    BEQ     OGPA_Zero
    JSR     Trouve_Prop
    TFR     X,D
    JMP     Stocke
OGPA_Zero:
    JMP     Stocke

Op_Get_Next_Prop:
    LDD     Ops
    BEQ     OGPA_Zero
    JSR     Props_Debut             ; X = première propriété
    LDD     Ops+2
    BNE     OGNP_Cherche
    JSR     Prop_Lit                ; la première : son numéro (0 : aucune)
    CLRA
    LDB     PropN
    JMP     Stocke
OGNP_Cherche:
    JSR     Prop_Lit
    LDB     PropN
    LBEQ    Op_Illegal              ; propriété absente
    CMPB    Ops+3
    BEQ     OGNP_Suiv
    LDX     PropFin
    BRA     OGNP_Cherche
OGNP_Suiv:
    LDX     PropFin
    JSR     Prop_Lit
    CLRA
    LDB     PropN
    JMP     Stocke

Op_Add:
    LDD     Ops
    ADDD    Ops+2
    JMP     Stocke

Op_Sub:
    LDD     Ops
    SUBD    Ops+2
    JMP     Stocke

Op_Mul:
    LDD     Ops
    MULD    Ops+2                   ; Q = D * m (signé) : le mot bas est W
    TFR     W,D
    JMP     Stocke

Op_Div:
    BSR     Division
    LDD     Quot
    JMP     Stocke

Op_Mod:
    BSR     Division
    LDD     Ops
    PSHS    D
    LDD     Quot                    ; a - q * b
    MULD    Ops+2
    TFR     W,D
    PSHS    D
    LDD     2,S
    SUBD    ,S++
    LEAS    2,S
    JMP     Stocke

; Division : Ops / Ops+2, quotient tronqué vers zéro -> Quot (16 bits)
Division:
    LDD     Ops+2
    BNE     Dv_Ok
    LDX     #TxtDivZero
    JMP     Erreur
Dv_Ok:
    LDD     Ops                     ; |a| et |b| en non signé
    BPL     Dv_APos
    COMA
    COMB
    ADDD    #1
Dv_APos:
    STD     DvA
    LDD     Ops+2
    BPL     Dv_BPos
    COMA
    COMB
    ADDD    #1
Dv_BPos:
    STD     DvB
    ; division non signée 16 bits : DvA / DvB
    CLRA
    CLRB
    LDX     #16
Dv_Boucle:
    LSL     DvA+1
    ROL     DvA
    ROLB
    ROLA
    CMPD    DvB
    BLO     Dv_Pas
    SUBD    DvB
    INC     DvA+1
Dv_Pas:
    LEAX    -1,X
    BNE     Dv_Boucle
    LDD     DvA
    PSHS    D
    LDA     Ops                     ; signe : a XOR b
    EORA    Ops+2
    PULS    D
    BPL     Dv_Fin
    COMA
    COMB
    ADDD    #1
Dv_Fin:
    STD     Quot
    RTS

Op_Call_2S:
    JMP     Appel_S
Op_Call_2N:
    JMP     Appel_N

Op_Set_Colour:
    LDD     Ops
    LDX     Ops+2
    JMP     Couleur

Op_Throw:
Th_Boucle:
    LDD     Prof
    CMPD    Ops+2
    BLS     Th_Fin
    LDX     FP                      ; on jette le cadre du dessus
    LDU     FP
    LDX     ,X
    STX     FP
    LEAU    8,U
    LDD     Prof
    SUBD    #1
    STD     Prof
    BRA     Th_Boucle
Th_Fin:
    LDD     Ops
    JMP     Retour

; --- 1OP -------------------------------------------------------------
Op_Jz:
    LDD     Ops
    LBEQ    Vrai
    JMP     Faux

Op_Get_Sibling:
    LDD     Ops
    BEQ     OGS_Zero
    JSR     Obj_Adr
    LDB     #1
    JSR     Lien_Lit
    JMP     Stocke_Branche
OGS_Zero:
    JMP     Stocke_Branche

Op_Get_Child:
    LDD     Ops
    BEQ     OGS_Zero
    JSR     Obj_Adr
    LDB     #2
    JSR     Lien_Lit
    JMP     Stocke_Branche

Op_Get_Parent:
    LDD     Ops
    BEQ     OGP_Zero
    JSR     Obj_Adr
    CLRB
    JSR     Lien_Lit
OGP_Zero:
    JMP     Stocke

Op_Get_Prop_Len:
    LDX     Ops
    BEQ     OGPL_Zero
    LEAX    -1,X
    JSR     Lit8
    TST     V3
    BEQ     OGPL_V4
    LSRA                            ; v3 : (b >> 5) + 1
    LSRA
    LSRA
    LSRA
    LSRA
    INCA
    BRA     OGPL_Rend
OGPL_V4:
    TSTA
    BPL     OGPL_Court
    ANDA    #$3F
    BNE     OGPL_Rend
    LDA     #64
OGPL_Rend:
    TFR     A,B
    CLRA
    JMP     Stocke
OGPL_Court:
    LDB     #1
    BITA    #$40
    BEQ     OGPL_Un
    LDB     #2
OGPL_Un:
    CLRA
    JMP     Stocke
OGPL_Zero:
    CLRA
    CLRB
    JMP     Stocke

Op_Inc:
    LDB     Ops+1
    JSR     Lit_Var_Ind
    ADDD    #1
    BRA     OI_Ecrit
Op_Dec:
    LDB     Ops+1
    JSR     Lit_Var_Ind
    SUBD    #1
OI_Ecrit:
    TFR     D,X
    LDB     Ops+1
    JMP     Ecrit_Var_Ind

Op_Print_Addr:
    CLR     TxtAdr
    LDD     Ops
    STD     TxtAdr+1
    JMP     Imprime_Adr

Op_Call_1S:
    JMP     Appel_S

Op_Remove_Obj:
    LDD     Ops
    BEQ     ORO_Fin
    JMP     Ote
ORO_Fin:
    RTS

Op_Print_Obj:
    LDD     Ops
    BEQ     ORO_Fin
    JSR     Obj_Adr
    JSR     Table_Prop
    ADDD    #1
    STD     TxtAdr+1
    CLR     TxtAdr
    JMP     Imprime_Adr

Op_Ret:
    LDD     Ops
    JMP     Retour

Op_Jump:
    LDD     Ops
    SUBD    #2
    JMP     Saut

Op_Print_Paddr:
    LDD     Ops
    JSR     Paquee
    LDA     ZPC
    STA     TxtAdr
    LDD     ZPC+1
    STD     TxtAdr+1
    JMP     Imprime_Adr

Op_Load:
    LDB     Ops+1
    JSR     Lit_Var_Ind
    JMP     Stocke

Op_Call_1N:
    TST     Vieux                   ; v1-4 : not
    LBNE    Op_Not
    JMP     Appel_N

; --- 0OP -------------------------------------------------------------
Op_Rtrue:
    LDD     #1
    JMP     Retour
Op_Rfalse:
    CLRA
    CLRB
    JMP     Retour

Op_Print:
    JMP     Imprime_PC

Op_Print_Ret:
    JSR     Imprime_PC
    LDA     #13
    JSR     Sortie
    LDD     #1
    JMP     Retour

Op_Nop:
    RTS

Op_Restart:
    JSR     Redemarre
    LDD     #$FFFF
    JMP     Efface_Fenetre

Op_Ret_Popped:
    LDD     ,U++
    JMP     Retour

Op_Catch:
    TST     Vieux
    BNE     OC_Pop
    LDD     Prof
    JMP     Stocke
OC_Pop:                             ; v1-4 : pop
    LEAU    2,U
    RTS

Op_Save0:                           ; v1-4 : save / restore en 0OP
    TST     Vieux
    LBEQ    Op_Illegal
    JMP     Sauve_Partie
Op_Restore0:
    TST     Vieux
    LBEQ    Op_Illegal
    JMP     Charge_Partie

Op_Show_Status:
    TST     V3
    BEQ     OSS_Fin
    JMP     Etat
OSS_Fin:
    RTS

Op_Quit:
    JMP     Quitte

Op_New_Line:
    LDA     #13
    JMP     Sortie

Op_Verify:
    JSR     Verifie
    JMP     Branche

Op_Piracy:
    LDA     #1
    JMP     Branche

; --- VAR -------------------------------------------------------------
Op_Call_VS:
    JMP     Appel_S

Op_Storew:
    LDD     Ops+2
    LSLB
    ROLA
    ADDD    Ops
    TFR     D,X
    LDD     Ops+4
    JMP     Ecrit16

Op_Storeb:
    LDD     Ops+2
    ADDD    Ops
    TFR     D,X
    LDA     Ops+5
    JMP     Ecrit8

Op_Put_Prop:
    LDD     Ops
    JSR     Trouve_Prop
    CMPX    #0
    LBEQ    Op_Illegal
    CMPB    #1
    BNE     OPP_Mot
    LDA     Ops+5
    JMP     Ecrit8
OPP_Mot:
    LDD     Ops+4
    JMP     Ecrit16

Op_Read:
    JMP     Lit_Ligne

Op_Print_Char:
    LDA     Ops+1
    JMP     Sortie

Op_Print_Num:
    LDD     Ops
    JMP     Imprime_Nombre

Op_Random:
    JSR     Hasard
    JMP     Stocke

Op_Push:
    LDX     Ops
    STX     ,--U
    RTS

Op_Pull:
    LDX     ,U++
    LDB     Ops+1
    JMP     Ecrit_Var_Ind

Op_Split_Window:
    LDD     Ops
    JMP     Coupe

Op_Set_Window:
    LDD     Ops
    JMP     Choisit

Op_Erase_Window:
    LDD     Ops
    JMP     Efface_Fenetre

Op_Erase_Line:
    LDD     Ops
    CMPD    #1
    LBEQ    Efface_Ligne
    RTS

Op_Set_Cursor:
    LDD     Ops
    LDX     Ops+2
    JMP     Curseur

Op_Get_Cursor:
    JSR     Lit_Curseur             ; D = rangée, X = colonne (1..)
    PSHS    X
    LDX     Ops
    JSR     Ecrit16
    PULS    D
    LDX     Ops
    LEAX    2,X
    JMP     Ecrit16

Op_Set_Text_Style:
    JSR     Vide_Mot
    LDA     Ops+1
    BNE     OSTS_Ou
    CLR     Style
    RTS
OSTS_Ou:
    ORA     Style
    STA     Style
    RTS

Op_Buffer_Mode:
    JSR     Vide_Mot
    LDD     Ops
    BEQ     OBM_Non
    LDA     #1
OBM_Non:
    STA     Tampon
    RTS

Op_Output_Stream:
    LDD     Ops
    CMPD    #1
    BEQ     OOS_Un
    CMPD    #$FFFF
    BEQ     OOS_MoinsUn
    CMPD    #3
    BEQ     OOS_Trois
    CMPD    #$FFFD
    BEQ     OOS_MoinsTrois
    RTS
OOS_Un:
    LDA     #1
    STA     Flux1
    RTS
OOS_MoinsUn:
    CLR     Flux1
    RTS
OOS_Trois:
    LDB     Flux3N
    CMPB    #16
    BLO     OOS_Place
    LDX     #TxtFlux3
    JMP     Erreur
OOS_Place:
    LDX     #Flux3T                 ; (table, compte) : 4 octets
    LSLB
    LSLB
    ABX
    LDD     Ops+2
    STD     ,X
    CLR     2,X
    CLR     3,X
    INC     Flux3N
    RTS
OOS_MoinsTrois:
    LDB     Flux3N
    BEQ     OOS_Fin
    DECB
    STB     Flux3N
    LDX     #Flux3T
    LSLB
    LSLB
    ABX
    LDD     2,X
    LDX     ,X
    JMP     Ecrit16
OOS_Fin:
    RTS

Op_Read_Char:
    JMP     Lit_Touche

Op_Scan_Table:
    LDA     #$82                    ; forme par défaut : mots de 2 octets
    LDB     NOps
    CMPB    #4
    BLO     OST_Forme
    LDA     Ops+7
OST_Forme:
    STA     StForme
    ANDA    #$7F
    STA     StPas
    LDD     Ops+2
    STD     StAdr
    LDD     Ops+4
    STD     StN
OST_Boucle:
    LDD     StN
    BEQ     OST_Rate
    LDX     StAdr
    TST     StForme
    BPL     OST_Octet
    JSR     Lit16
    BRA     OST_Cmp
OST_Octet:
    JSR     Lit8
    TFR     A,B
    CLRA
OST_Cmp:
    CMPD    Ops
    BEQ     OST_Trouve
    LDB     StPas
    CLRA
    ADDD    StAdr
    STD     StAdr
    LDD     StN
    SUBD    #1
    STD     StN
    BRA     OST_Boucle
OST_Rate:
    CLRA
    CLRB
    JMP     Stocke_Branche
OST_Trouve:
    LDD     StAdr
    JMP     Stocke_Branche

Op_Not:
    LDD     Ops
    COMA
    COMB
    JMP     Stocke

Op_Call_VN:
    JMP     Appel_N

Op_Tokenise:
    CLRA
    CLRB
    STD     DcDico
    CLR     DcSauf
    LDB     NOps
    CMPB    #3
    BLO     OTk_Go
    LDX     Ops+4
    STX     DcDico
    CMPB    #4
    BLO     OTk_Go
    LDX     Ops+6
    BEQ     OTk_Go
    INC     DcSauf
OTk_Go:
    LDD     Ops
    LDX     Ops+2
    JMP     Decoupe

Op_Encode_Text:
    JMP     Encode_Texte

Op_Copy_Table:
    JMP     Copie_Table

Op_Print_Table:
    JMP     Imprime_Table

Op_Check_Arg_Count:
    LDX     FP
    LDB     7,X
    CLRA
    CMPD    Ops
    LBHS    Vrai
    JMP     Faux

Op_Sound:
Op_Input_Stream:
    RTS

; --- EXT -------------------------------------------------------------
Op_Save:
    LDA     NOps
    BNE     OSv_Table
    JMP     Sauve_Partie
OSv_Table:
    CLRA
    CLRB
    JMP     Stocke

Op_Restore:
    LDA     NOps
    BNE     OSv_Table
    JMP     Charge_Partie

Op_Log_Shift:
    LDD     Ops
    LDX     Ops+2
    BEQ     OLS_Rend
    CMPX    #0
    BLT     OLS_Droite
OLS_Gauche:
    LSLB
    ROLA
    LEAX    -1,X
    BNE     OLS_Gauche
    BRA     OLS_Rend
OLS_Droite:
    LSRA
    RORB
    LEAX    1,X
    BNE     OLS_Droite
OLS_Rend:
    JMP     Stocke

Op_Art_Shift:
    LDD     Ops
    LDX     Ops+2
    BEQ     OLS_Rend
    CMPX    #0
    BGT     OLS_Gauche
OAS_Droite:
    ASRA
    RORB
    LEAX    1,X
    BNE     OAS_Droite
    BRA     OLS_Rend

Op_Set_Font:
    LDD     Ops
    BNE     OSF_Choix
    LDB     Fonte
    JMP     Stocke
OSF_Choix:
    CMPD    #1
    BEQ     OSF_Ok
    CMPD    #4
    BEQ     OSF_Ok
    CLRA
    CLRB
    JMP     Stocke
OSF_Ok:
    LDA     Fonte
    STB     Fonte
    TFR     A,B
    CLRA
    JMP     Stocke

Op_Save_Undo:
    LDD     #$FFFF                  ; pas d'annulation
    JMP     Stocke

Op_Restore_Undo:
    CLRA
    CLRB
    JMP     Stocke

Op_Print_Unicode:
    LDD     Ops
    JMP     Sortie_Unicode

Op_Check_Unicode:
    LDD     Ops
    JSR     Uni_Vers_CP
    BCS     OCU_Non
    LDD     #3
    JMP     Stocke
OCU_Non:
    CLRA
    CLRB
    JMP     Stocke

Op_Set_True_Colour:
    LDD     Ops
    LDX     #9
    JSR     Vraie_Couleur
    PSHS    D
    LDD     Ops+2
    LDX     #2
    JSR     Vraie_Couleur
    TFR     D,X
    PULS    D
    JMP     Couleur

; Vraie_Couleur : D = couleur 15 bits (ou -1 défaut, -2/-3 inchangée),
; X = défaut -> D = couleur Z (0 = inchangée)
Vraie_Couleur:
    CMPD    #$FFFF
    BNE     VC_Pas1
    TFR     X,D
    RTS
VC_Pas1:
    TSTA
    BPL     VC_Bits
    CLRA
    CLRB
    RTS
VC_Bits:                            ; une composante >= 16 allume son bit
    STD     VcC
    CLRB
    LDA     VcC+1
    BITA    #$10                    ; rouge : bits 0-4
    BEQ     VC_V
    ORB     #4
VC_V:
    LDA     VcC
    BITA    #$02                    ; vert : bits 5-9
    BEQ     VC_B
    ORB     #2
VC_B:
    LDA     VcC
    BITA    #$40                    ; bleu : bits 10-14
    BEQ     VC_Z
    ORB     #1
VC_Z:
    LDX     #OsmVersZ
    LDB     B,X
    CLRA
    RTS
OsmVersZ:       FCB 2,6,4,8,3,7,5,9     ; bits OSM39 -> couleur Z

; ===================================================================
; OBJETS (v4+ : 14 octets, 48 attributs, 63 propriétés par défaut)
; ===================================================================
; Obj_Adr : D = objet (<> 0) -> X = adresse de son entrée
Obj_Adr:
    TST     V3
    BEQ     OA_V4
    LDA     #9                      ; v3 : 9 octets (objets 1-255)
    MUL
    ADDD    ObjBase
    TFR     D,X
    RTS
OA_V4:
    PSHS    D
    LDA     #14
    MUL                             ; B (bas de l'objet) * 14
    PSHS    D
    LDA     2,S                     ; haut de l'objet * 14 * 256
    LDB     #14
    MUL
    TFR     B,A
    CLRB
    ADDD    ,S++
    ADDD    ObjBase
    TFR     D,X
    LEAS    2,S
    RTS

; Lien_Lit : X = entrée d'un objet, B = lien (0 parent, 1 frère, 2
; enfant) -> D. Lien_Ecrit : la même chose, valeur dans LkV.
; v3 : un octet en +4+k ; v4+ : un mot en +6+2k.
Lien_Lit:
    TST     V3
    BEQ     LL_V4
    ABX
    LEAX    4,X
    JSR     Lit8
    TFR     A,B
    CLRA
    RTS
LL_V4:
    LSLB
    ABX
    LEAX    6,X
    JMP     Lit16
Lien_Ecrit:
    TST     V3
    BEQ     LE_V4
    ABX
    LEAX    4,X
    LDA     LkV+1
    JMP     Ecrit8
LE_V4:
    LSLB
    ABX
    LEAX    6,X
    LDD     LkV
    JMP     Ecrit16

; Table_Prop : X = entrée d'un objet -> D = sa table de propriétés
Table_Prop:
    TST     V3
    BEQ     TPr_V4
    LEAX    7,X
    JMP     Lit16
TPr_V4:
    LEAX    12,X
    JMP     Lit16

; Ote : Ops = objet (sorti de son père)
Ote:
    LDD     Ops
    JSR     Obj_Adr
    CLRB
    JSR     Lien_Lit
    STD     OtPere
    CMPD    #0
    BEQ     Ot_Fin
    JSR     Obj_Adr                 ; premier enfant du père
    LDB     #2
    JSR     Lien_Lit
    CMPD    Ops
    BNE     Ot_Cherche
    BSR     Frere_O                 ; père.enfant = frère de l'objet
    STD     LkV
    LDD     OtPere
    JSR     Obj_Adr
    LDB     #2
    JSR     Lien_Ecrit
    BRA     Ot_Detache
Ot_Cherche:                         ; D = un enfant ; son frère est-il l'objet ?
    CMPD    #0
    BEQ     Ot_Detache              ; (fin de chaîne : absent)
    STD     OtC
    JSR     Obj_Adr
    LDB     #1
    JSR     Lien_Lit
    CMPD    Ops
    BNE     Ot_Cherche
    BSR     Frere_O                 ; c.frère = frère de l'objet
    STD     LkV
    LDD     OtC
    JSR     Obj_Adr
    LDB     #1
    JSR     Lien_Ecrit
Ot_Detache:
    CLRA
    CLRB
    STD     LkV
    LDD     Ops
    JSR     Obj_Adr
    CLRB
    JSR     Lien_Ecrit
    LDD     Ops
    JSR     Obj_Adr
    LDB     #1
    JMP     Lien_Ecrit
Ot_Fin:
    RTS
Frere_O:
    LDD     Ops
    JSR     Obj_Adr
    LDB     #1
    JMP     Lien_Lit

; Insere : Ops = objet, Ops+2 = destination
Insere:
    JSR     Ote
    LDD     Ops+2                   ; frère(o) = enfant(dest)
    JSR     Obj_Adr
    LDB     #2
    JSR     Lien_Lit
    STD     LkV
    LDD     Ops
    JSR     Obj_Adr
    LDB     #1
    JSR     Lien_Ecrit
    LDD     Ops+2                   ; parent(o) = dest
    STD     LkV
    LDD     Ops
    JSR     Obj_Adr
    CLRB
    JSR     Lien_Ecrit
    LDD     Ops                     ; enfant(dest) = o
    STD     LkV
    LDD     Ops+2
    JSR     Obj_Adr
    LDB     #2
    JMP     Lien_Ecrit

; Props_Debut : D = objet -> X = première propriété (après le nom)
Props_Debut:
    JSR     Obj_Adr
    JSR     Table_Prop
    TFR     D,X
    PSHS    X
    JSR     Lit8                    ; longueur du nom en mots
    PULS    X
    LEAX    1,X
    TFR     A,B
    ABX
    ABX
    RTS

; Prop_Lit : X = une propriété -> PropN (0 = fin), PropDon (données),
; PropLg, PropFin (la suivante)
Prop_Lit:
    STX     PropDon
    JSR     Lit8
    TST     V3
    BEQ     PL_V4
    TFR     A,B                     ; v3 : numéro bits 0-4, longueur - 1 bits 5-7
    ANDB    #$1F
    STB     PropN
    TSTA
    BEQ     PL_Fin
    LSRA
    LSRA
    LSRA
    LSRA
    LSRA
    INCA
    STA     PropLg
    LDX     PropDon
    LEAX    1,X
    BRA     PL_Don
PL_V4:
    TFR     A,B
    ANDB    #$3F
    STB     PropN
    TSTA
    BEQ     PL_Fin
    BPL     PL_Court
    LDX     PropDon
    LEAX    1,X
    JSR     Lit8
    ANDA    #$3F
    BNE     PL_Lg
    LDA     #64
PL_Lg:
    STA     PropLg
    LDX     PropDon
    LEAX    2,X
    BRA     PL_Don
PL_Court:
    LDB     #1
    BITA    #$40
    BEQ     PL_Un
    LDB     #2
PL_Un:
    STB     PropLg
    LDX     PropDon
    LEAX    1,X
PL_Don:
    STX     PropDon
    LDB     PropLg
    ABX
    STX     PropFin
    RTS
PL_Fin:
    CLR     PropN
    RTS

; Trouve_Prop : D = objet, Ops+3 = propriété -> X = adresse des données
; (0 : absente), B = longueur
Trouve_Prop:
    JSR     Props_Debut
TP_Boucle:
    JSR     Prop_Lit
    LDB     PropN
    BEQ     TP_Absente
    CMPB    Ops+3
    BEQ     TP_Trouve
    BLO     TP_Absente              ; décroissantes : passée
    LDX     PropFin
    BRA     TP_Boucle
TP_Trouve:
    LDX     PropDon
    LDB     PropLg
    RTS
TP_Absente:
    LDX     #0
    CLRB
    RTS

; ===================================================================
; HASARD : xorshift 16 bits (7, 9, 8), ou la suite 1..n (graine < 1000)
; ===================================================================
Hasard:
    LDD     Ops
    BMI     Ha_Graine
    BNE     Ha_Tire
    LDD     #1                      ; 0 : retour à l'aléatoire
    STD     Alea
    CLR     AleaSeq
    CLR     AleaSeq+1
    CLRA
    CLRB
    RTS
Ha_Graine:
    COMA
    COMB
    ADDD    #1                      ; -n
    CMPD    #1000
    BHS     Ha_Graine2
    STD     AleaSeq
    CLR     AleaN
    CLR     AleaN+1
    CLRA
    CLRB
    RTS
Ha_Graine2:
    STD     Alea
    CLR     AleaSeq
    CLR     AleaSeq+1
    CLRA
    CLRB
    RTS
Ha_Tire:
    LDD     AleaSeq
    BEQ     Ha_Xor
    LDD     AleaN                   ; n' = n mod seq + 1
    STD     DvA
    LDD     AleaSeq
    STD     DvB
    JSR     Mod_NonSigne
    ADDD    #1
    STD     AleaN
    SUBD    #1                      ; (n' - 1) mod a + 1
    BRA     Ha_Mod
Ha_Xor:
    LDD     Alea
    STD     DvA                     ; x ^= x << 7
    LDB     #7
Ha_G7:
    LSL     DvA+1
    ROL     DvA
    DECB
    BNE     Ha_G7
    LDD     Alea
    EORA    DvA
    EORB    DvA+1
    STD     Alea
    TFR     A,B                     ; x ^= x >> 9
    CLRA
    LSRB
    EORA    Alea
    EORB    Alea+1
    STD     Alea
    EORA    Alea+1                  ; x ^= x << 8 : haut ^= bas
    STA     Alea
    LDD     Alea
Ha_Mod:
    STD     DvA
    LDD     Ops
    STD     DvB
    JSR     Mod_NonSigne
    ADDD    #1
    RTS

; Mod_NonSigne : DvA mod DvB (non signés, DvB <> 0) -> D
Mod_NonSigne:
    CLRA
    CLRB
    LDX     #16
MN_Boucle:
    LSL     DvA+1
    ROL     DvA
    ROLB
    ROLA
    CMPD    DvB
    BLO     MN_Pas
    SUBD    DvB
MN_Pas:
    LEAX    -1,X
    BNE     MN_Boucle
    RTS

; ===================================================================
; Tables de dispatch
; ===================================================================
Tab2OP:
    FDB     Op_Illegal,Op_Je,Op_Jl,Op_Jg,Op_Dec_Chk,Op_Inc_Chk,Op_Jin,Op_Test
    FDB     Op_Or,Op_And,Op_Test_Attr,Op_Set_Attr,Op_Clear_Attr,Op_Store,Op_Insert_Obj,Op_Loadw
    FDB     Op_Loadb,Op_Get_Prop,Op_Get_Prop_Addr,Op_Get_Next_Prop,Op_Add,Op_Sub,Op_Mul,Op_Div
    FDB     Op_Mod,Op_Call_2S,Op_Call_2N,Op_Set_Colour,Op_Throw,Op_Illegal,Op_Illegal,Op_Illegal
Tab1OP:
    FDB     Op_Jz,Op_Get_Sibling,Op_Get_Child,Op_Get_Parent,Op_Get_Prop_Len,Op_Inc,Op_Dec,Op_Print_Addr
    FDB     Op_Call_1S,Op_Remove_Obj,Op_Print_Obj,Op_Ret,Op_Jump,Op_Print_Paddr,Op_Load,Op_Call_1N
Tab0OP:
    FDB     Op_Rtrue,Op_Rfalse,Op_Print,Op_Print_Ret,Op_Nop,Op_Save0,Op_Restore0,Op_Restart
    FDB     Op_Ret_Popped,Op_Catch,Op_Quit,Op_New_Line,Op_Show_Status,Op_Verify,Op_Illegal,Op_Piracy
TabVAR:
    FDB     Op_Call_VS,Op_Storew,Op_Storeb,Op_Put_Prop,Op_Read,Op_Print_Char,Op_Print_Num,Op_Random
    FDB     Op_Push,Op_Pull,Op_Split_Window,Op_Set_Window,Op_Call_VS,Op_Erase_Window,Op_Erase_Line,Op_Set_Cursor
    FDB     Op_Get_Cursor,Op_Set_Text_Style,Op_Buffer_Mode,Op_Output_Stream,Op_Input_Stream,Op_Sound,Op_Read_Char,Op_Scan_Table
    FDB     Op_Not,Op_Call_VN,Op_Call_VN,Op_Tokenise,Op_Encode_Text,Op_Copy_Table,Op_Print_Table,Op_Check_Arg_Count
TabEXT:
    FDB     Op_Save,Op_Restore,Op_Log_Shift,Op_Art_Shift,Op_Set_Font,Op_Illegal,Op_Illegal,Op_Illegal
    FDB     Op_Illegal,Op_Save_Undo,Op_Restore_Undo,Op_Print_Unicode,Op_Check_Unicode,Op_Set_True_Colour

    include "zm_memoire.asm"
    include "zm_ecran.asm"
    include "zm_texte.asm"
    include "zm_fichier.asm"
    include "zmachine_data.inc"

; ===================================================================
; Textes
; ===================================================================
TxtUsage:       FCN "ZMACHINE : donner le jeu (ZMACHINE JEU.Z5)."
TxtCharge:      FCN "Chargement de "
TxtPoints:      FCN "..."
TxtAbsent:      FCN "ZMACHINE : jeu introuvable."
TxtErreur:      FCN "*** Erreur Z-machine : "
TxtIllegal:     FCN "instruction illegale"
TxtDivZero:     FCN "division par zero"
TxtFlux3:       FCN "plus de 16 flux 3"

; ===================================================================
; Variables
; ===================================================================
PileHote:       RMB 2
NomJeu:         RMB 15
InfoJeu:        RMB 14              ; LBA (4), taille (4), page, adresse, attr, parent
Version:        RMB 1
Statique:       RMB 2
Globales:       RMB 2
Objets:         RMB 2
ObjBase:        RMB 2
Abrev:          RMB 2
Dico:           RMB 2
OpCode:         RMB 1
NOps:           RMB 1
Ops:            RMB 16
Types2:         RMB 2
TypesOct:       RMB 1
LtN:            RMB 1
BrCond:         RMB 1
BrOct:          RMB 1
BrDep:          RMB 2
SautDep:        RMB 2
ZPC:            RMB 3               ; une adresse Z sur 24 bits (grand-boutiste)
FP:             RMB 2
Prof:           RMB 2
AppVar:         RMB 1
AppDrap:        RMB 1
ApN:            RMB 1
RetVal:         RMB 2
RetVarDr:       RMB 2
ValInterne:     RMB 2
JeN:            RMB 1
Quot:           RMB 2
DvA:            RMB 2
DvB:            RMB 2
Alea:           RMB 2
AleaSeq:        RMB 2
AleaN:          RMB 2
Fonte:          RMB 1
Flux1:          RMB 1
Flux3N:         RMB 1
StForme:        RMB 1
StPas:          RMB 1
StAdr:          RMB 2
StN:            RMB 2
OtAdr:          RMB 2
OtPere:         RMB 2
OtC:            RMB 2
LkV:            RMB 2
V3:             RMB 1               ; <> 0 : version 3
Vieux:          RMB 1               ; <> 0 : version 3 ou 4 (formats v1-4)
Decal:          RMB 1               ; adresse paquée : décalage (1, 2 ou 3)
PropN:          RMB 1
PropLg:         RMB 1
PropDon:        RMB 2
PropFin:        RMB 2
VcC:            RMB 2
ApArg:          RMB 2
ApK:            RMB 1
Code_Fin:
