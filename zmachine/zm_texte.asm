; ===================================================================
; ZM_TEXTE.ASM - Texte Z : décodage, sortie, dictionnaire
; ===================================================================
; Les caractères circulent en ZSCII. Sortie : A = ZSCII ; normalisé comme
; zscii() puis vers_zscii() du modèle (0 : rien ; 13, 32-126, 155-
; 155+n-1 : tels quels ; le reste : « ? »), vers le flux 3 s'il est
; ouvert, sinon vers l'écran (flux 1) en CP437.
; ===================================================================

Imprime_PC:
    CLR     TxtMode
    BRA     Decode
Imprime_Adr:
    LDA     #1
    STA     TxtMode
Decode:
    CLR     DtAlpha
    CLR     DtEtat
Dc_Mot:
    JSR     Mot_Txt
    STD     DtMot
    LDA     DtMot                   ; z1 : bits 14-10
    LSRA
    LSRA
    ANDA    #$1F
    JSR     Z_Car
    LDD     DtMot                   ; z2 : bits 9-5
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    TFR     B,A
    ANDA    #$1F
    JSR     Z_Car
    LDA     DtMot+1                 ; z3 : bits 4-0
    ANDA    #$1F
    JSR     Z_Car
    TST     DtMot
    BPL     Dc_Mot
    RTS

; Mot_Txt : le mot suivant de la chaîne (au PC, ou en TxtAdr) -> D
Mot_Txt:
    TST     TxtMode
    BNE     MT_Mem
    JSR     Octet_PC
    TFR     A,B
    JSR     Octet_PC
    EXG     A,B
    RTS
MT_Mem:
    JSR     Lit8_Txt
    JSR     Inc_Txt
    PSHS    A
    JSR     Lit8_Txt
    JSR     Inc_Txt
    TFR     A,B
    PULS    A
    RTS

; Z_Car : A = un caractère Z (0-31)
Z_Car:
    LDB     DtEtat
    BNE     ZC_Etat
    TSTA
    BNE     ZC_1
    CLR     DtAlpha
    LDA     #' '
    JMP     Sortie
ZC_1:
    CMPA    #3
    BHI     ZC_4
    STA     DtAbZ
    LDA     #1
    STA     DtEtat
    RTS
ZC_4:
    CMPA    #4
    BNE     ZC_5
    LDA     #1
    STA     DtAlpha
    RTS
ZC_5:
    CMPA    #5
    BNE     ZC_Car
    LDA     #2
    STA     DtAlpha
    RTS
ZC_Car:
    LDB     DtAlpha
    CMPB    #2
    BNE     ZC_Table
    CMPA    #6
    BNE     ZC_7
    LDA     #2                      ; échappement : 10 bits suivent
    STA     DtEtat
    RTS
ZC_7:
    CMPA    #7
    BNE     ZC_Table
    CLR     DtAlpha
    LDA     #13
    JMP     Sortie
ZC_Table:
    SUBA    #6
    PSHS    A
    LDA     #26
    MUL                             ; B = alphabet * 26
    ADDB    ,S+
    LDX     #AlphaT
    LDA     B,X
    CLR     DtAlpha
    JMP     Sortie
ZC_Etat:
    CMPB    #1
    BEQ     ZC_Abrev
    CMPB    #2
    BNE     ZC_Bas
    STA     DtEsc                   ; les 5 bits hauts
    LDA     #3
    STA     DtEtat
    RTS
ZC_Bas:
    PSHS    A
    LDA     #32
    LDB     DtEsc
    MUL
    ORB     ,S+
    CLR     DtEtat
    CLR     DtAlpha
    TSTA
    BEQ     ZC_Code
    LDB     #'?'
ZC_Code:
    TFR     B,A
    JMP     Sortie
ZC_Abrev:                           ; n = 32 * (DtAbZ - 1) + z
    PSHS    A
    LDB     DtAbZ
    DECB
    LDA     #32
    MUL
    ADDB    ,S+
    ADCA    #0
    TST     DtNiv
    BEQ     ZA_Ok
    LDX     #TxtAbrev
    JMP     Erreur
ZA_Ok:
    LSLB                            ; mot en Abrev + 2n
    ROLA
    ADDD    Abrev
    TFR     D,X
    JSR     Lit16
    PSHS    D
    LDD     DtMot                   ; l'état de la chaîne en cours
    PSHS    D
    LDA     DtAlpha
    LDB     TxtMode
    PSHS    D
    LDD     TxtAdr
    PSHS    D
    LDA     TxtAdr+2
    PSHS    A
    LDD     5+2,S                   ; adresse de mot * 2
    CLR     TxtAdr
    LSLB
    ROLA
    ROL     TxtAdr
    STD     TxtAdr+1
    LDA     #1
    STA     TxtMode
    STA     DtNiv
    JSR     Decode
    CLR     DtNiv
    PULS    A
    STA     TxtAdr+2
    PULS    D
    STD     TxtAdr
    PULS    D
    STA     DtAlpha
    STB     TxtMode
    PULS    D
    STD     DtMot
    LEAS    2,S
    CLR     DtEtat
    CLR     DtAlpha
    RTS

; -------------------------------------------------------------------
; Sorties
; -------------------------------------------------------------------
; Norm_Z : A = ZSCII -> A normalisé ; C = 1 : rien (0)
Norm_Z:
    TSTA
    BEQ     NZ_Rien
    CMPA    #13
    BEQ     NZ_Ok
    CMPA    #32
    BLO     NZ_Q
    CMPA    #126
    BLS     NZ_Ok
    CMPA    #155
    BLO     NZ_Q
    PSHS    A
    SUBA    #155
    CMPA    ZsN
    PULS    A
    BLO     NZ_Ok
NZ_Q:
    LDA     #'?'
NZ_Ok:
    ANDCC   #$FE
    RTS
NZ_Rien:
    ORCC    #1
    RTS

Sortie:
    BSR     Norm_Z
    BCS     So_Fin
    TST     VersEtat                ; v3 : la ligne d'état se compose
    BNE     So_Etat
    TST     Flux3N
    LBNE    Flux3_Octet
    TST     Flux1
    BEQ     So_Fin
    CMPA    #13
    BNE     So_Cp
    LDA     #10
    JMP     Ecran_Car
So_Cp:
    CMPA    #155
    BLO     So_Ecran
    SUBA    #155
    LDX     #ZsCp
    LDA     A,X
So_Ecran:
    JMP     Ecran_Car
So_Fin:
    RTS
So_Etat:                            ; CP437 dans le tampon (13 : « ? »)
    CMPA    #13
    BNE     SE_Cp
    LDA     #'?'
SE_Cp:
    CMPA    #155
    BLO     SE_Pose
    SUBA    #155
    LDX     #ZsCp
    LDA     A,X
SE_Pose:
    LDX     EtatP
    CMPX    EtatLim
    BHS     So_Fin
    STA     ,X+
    STX     EtatP
    RTS

; -------------------------------------------------------------------
; Etat : v3, la ligne d'état (rangée 0, en inverse) : le lieu (nom de
; l'objet de la globale 0) à gauche, « Score: s  Moves: t » (ou « Time:
; h:mm am ») à droite ; le lieu coupé à LARGEUR - (droite) - 4.
; Les textes passent par Sortie (VersEtat) vers LIGNE et LIGNE+128.
; -------------------------------------------------------------------
Etat:
    LDA     #1
    STA     VersEtat
    LDX     #LIGNE+128
    STX     EtatP
    LDX     #LIGNE+128+LARGEUR
    STX     EtatLim
    LDB     #17
    JSR     Lit_Var
    STD     EtA
    LDB     #18
    JSR     Lit_Var
    STD     EtB
    LDX     #1
    JSR     Lit8
    BITA    #2
    BNE     Et_Heure
    LDX     #TxtScore
    JSR     Et_Texte
    LDD     EtA
    JSR     Imprime_Nombre
    LDX     #TxtMoves
    JSR     Et_Texte
    LDD     EtB
    JSR     Imprime_Nombre
    BRA     Et_Gauche
Et_Heure:
    LDX     #TxtTime
    JSR     Et_Texte
    LDD     EtA                     ; heure sur 12 (0 -> 12)
Et_Mod:
    CMPD    #12
    BLT     Et_H
    SUBD    #12
    BRA     Et_Mod
Et_H:
    CMPD    #0
    BNE     Et_H12
    LDD     #12
Et_H12:
    JSR     Imprime_Nombre
    LDA     #':'
    JSR     Sortie
    LDD     EtB
    CMPD    #10
    BHS     Et_Min
    LDA     #'0'
    JSR     Sortie
    LDD     EtB
Et_Min:
    JSR     Imprime_Nombre
    LDX     #TxtAm
    LDD     EtA
    CMPD    #12
    BLT     Et_Am
    LDX     #TxtPm
Et_Am:
    JSR     Et_Texte
Et_Gauche:
    LDD     EtatP                   ; longueur de droite
    SUBD    #LIGNE+128
    STB     EtDl
    LDX     #LIGNE
    STX     EtatP
    LDB     #LARGEUR-4              ; place du lieu
    SUBB    EtDl
    BPL     Et_Lim
    CLRB
Et_Lim:
    ABX
    STX     EtatLim
    LDB     #16
    JSR     Lit_Var
    CMPD    #0
    BEQ     Et_Dessin
    JSR     Obj_Adr
    JSR     Table_Prop
    ADDD    #1
    STD     TxtAdr+1
    CLR     TxtAdr
    JSR     Imprime_Adr
Et_Dessin:
    CLR     VersEtat
    LDB     #1                      ; la rangée 0 en inverse
    JSR     Attr_De
    STA     ErAttr
    CLRB
    JSR     Rang_Vide
    LDX     #LIGNE                  ; le lieu en colonne 1
    LDA     #1
    BSR     Et_Pose
    LDA     #LARGEUR-1              ; la droite finit colonne 78
    SUBA    EtDl
    LDX     #LIGNE+128
    LDB     EtDl
    ABX
    STX     EtatP
    LDX     #LIGNE+128
    BSR     Et_Pose
    CLRB                            ; la rangée 0, une fois écrite
    JMP     Sale_B

; Et_Pose : de X à EtatP, en rangée 0 à partir de la colonne A
Et_Pose:
    STA     EtCol
EtP_Car:
    CMPX    EtatP
    BHS     EtP_Fin
    LDA     ,X+
    PSHS    X
    PSHS    A
    LDA     EtCol
    CLRB
    JSR     Case
    PULS    A
    STA     ,X
    LDA     ErAttr
    STA     ATTR_OFS,X
    INC     EtCol
    PULS    X
    BRA     EtP_Car
EtP_Fin:
    RTS

Et_Texte:                           ; X = texte ASCII (0 final) -> Sortie
    LDA     ,X+
    BEQ     ET_Ret
    PSHS    X
    JSR     Sortie
    PULS    X
    BRA     Et_Texte
ET_Ret:
    RTS

TxtScore:       FCN "Score: "
TxtMoves:       FCN "  Moves: "
TxtTime:        FCN "Time: "
TxtAm:          FCN " am"
TxtPm:          FCN " pm"

; Flux3_Octet : A = ZSCII vers la table du flux 3 ouvert en dernier
Flux3_Octet:
    PSHS    A
    LDB     Flux3N
    DECB
    LSLB
    LSLB
    LDX     #Flux3T
    ABX
    LDD     2,X                     ; compte
    PSHS    D,X
    ADDD    #2
    ADDD    ,X                      ; table + 2 + compte
    TFR     D,X
    LDA     4,S
    JSR     Ecrit8
    PULS    D,X
    ADDD    #1
    STD     2,X
    PULS    A,PC

; Sortie_Unicode : D = point de code (@print_unicode)
Sortie_Unicode:
    STD     SuU
    CMPD    #10
    BNE     SU_13
    LDA     #13
    STA     SuZ
    LDA     #10
    BRA     SU_Route
SU_13:
    CMPD    #13
    BNE     SU_Ascii
    LDA     #13
    STA     SuZ
    LDA     #'?'
    BRA     SU_Route
SU_Ascii:
    CMPD    #32
    BLO     SU_Autre
    CMPD    #126
    BHI     SU_Autre
    STB     SuZ
    TFR     B,A
    BRA     SU_Route
SU_Autre:
    JSR     Uni_Vers_Z
    STA     SuZ
    LDD     SuU
    JSR     Uni_Vers_CP
    BCC     SU_Route
    LDA     #'?'
SU_Route:
    TST     Flux3N
    BEQ     SU_Ecran
    LDA     SuZ
    JMP     Flux3_Octet
SU_Ecran:
    TST     Flux1
    BEQ     SU_Fin
    JMP     Ecran_Car
SU_Fin:
    RTS

; Imprime_Nombre : D = nombre signé
Imprime_Nombre:
    STD     NbV
    BPL     IN_Pos
    LDA     #'-'
    JSR     Sortie
    LDD     NbV
    COMA
    COMB
    ADDD    #1
    STD     NbV
IN_Pos:
    CLR     NbZero
    LDX     #Puiss10
IN_Chiffre:
    LDA     #'0'
    STA     NbC
    LDD     NbV
IN_Sous:
    CMPD    ,X
    BLO     IN_Rend
    SUBD    ,X
    INC     NbC
    BRA     IN_Sous
IN_Rend:
    STD     NbV
    LDA     NbC
    CMPX    #Puiss10+8              ; le dernier chiffre : toujours
    BEQ     IN_Ecrit
    CMPA    #'0'
    BNE     IN_Ecrit
    TST     NbZero
    BEQ     IN_Suiv
IN_Ecrit:
    INC     NbZero
    PSHS    X
    JSR     Sortie
    PULS    X
IN_Suiv:
    LEAX    2,X
    CMPX    #Puiss10+10
    BLO     IN_Chiffre
    RTS
Puiss10:        FDB 10000,1000,100,10,1

; Imprime_Table : @print_table texte, largeur, hauteur, saut
Imprime_Table:
    LDD     Ops
    STD     PtAdr
    LDD     #1
    STD     PtH
    CLRA
    CLRB
    STD     PtSaut
    LDB     NOps
    CMPB    #3
    BLO     PT_Go
    LDD     Ops+4
    STD     PtH
    LDB     NOps
    CMPB    #4
    BLO     PT_Go
    LDD     Ops+6
    STD     PtSaut
PT_Go:
    JSR     Lit_Curseur
    STD     PtLigne
    STX     PtCol
    LDD     #0
    STD     PtR
PT_Rang:
    LDD     PtR
    CMPD    PtH
    BHS     PT_Fin
    LDD     PtR
    BEQ     PT_Car                  ; (rangée 0 : pas de saut)
    TST     Fen
    BEQ     PT_Bas
    LDD     PtLigne
    ADDD    PtR
    LDX     PtCol
    JSR     Curseur
    BRA     PT_Car
PT_Bas:
    LDA     #13
    JSR     Sortie
    LDD     PtCol
    SUBD    #1
    STD     PtI
PT_Esp:
    LDD     PtI
    BEQ     PT_Car
    SUBD    #1
    STD     PtI
    LDA     #' '
    JSR     Sortie
    BRA     PT_Esp
PT_Car:
    LDD     #0
    STD     PtI
PT_Boucle:
    LDD     PtI
    CMPD    Ops+2
    BHS     PT_Suiv
    ADDD    PtAdr
    TFR     D,X
    JSR     Lit8
    JSR     Sortie
    LDD     PtI
    ADDD    #1
    STD     PtI
    BRA     PT_Boucle
PT_Suiv:
    LDD     PtAdr
    ADDD    Ops+2
    ADDD    PtSaut
    STD     PtAdr
    LDD     PtR
    ADDD    #1
    STD     PtR
    BRA     PT_Rang
PT_Fin:
    RTS

; Copie_Table : @copy_table premier, second, taille
Copie_Table:
    LDD     Ops+4
    BPL     CT_Pos
    COMA
    COMB
    ADDD    #1
CT_Pos:
    STD     CtN                     ; |taille|
    LDD     #0
    STD     CtI
    LDD     Ops+2
    BEQ     CT_Zero
    TST     Ops+4
    BMI     CT_Avant
    CMPD    Ops
    BLO     CT_Avant
    ; vers l'arrière : i = taille-1 .. 0
CT_Arriere:
    LDD     CtN
    BEQ     CT_Fin
    SUBD    #1
    STD     CtN
    ADDD    Ops
    TFR     D,X
    JSR     Lit8
    PSHS    A
    LDD     CtN
    ADDD    Ops+2
    TFR     D,X
    PULS    A
    JSR     Ecrit8
    BRA     CT_Arriere
CT_Avant:
    LDD     CtI
    CMPD    CtN
    BHS     CT_Fin
    ADDD    Ops
    TFR     D,X
    JSR     Lit8
    PSHS    A
    LDD     CtI
    ADDD    Ops+2
    TFR     D,X
    PULS    A
    JSR     Ecrit8
    LDD     CtI
    ADDD    #1
    STD     CtI
    BRA     CT_Avant
CT_Zero:
    LDD     CtI
    CMPD    CtN
    BHS     CT_Fin
    ADDD    Ops
    TFR     D,X
    CLRA
    JSR     Ecrit8
    LDD     CtI
    ADDD    #1
    STD     CtI
    BRA     CT_Zero
CT_Fin:
    RTS

; -------------------------------------------------------------------
; Tables de caractères
; -------------------------------------------------------------------
; Alphabets : AlphaT (78 ZSCII) = les trois alphabets (celui de l'en-tête
; $34 s'il y en a un) ; A2 : positions 6 et 7 = échappement, nouvelle ligne
Alphabets:
    LDX     #$34
    JSR     Lit16
    STD     AlAdr
    BEQ     Al_Defaut
    CLR     AlI
Al_Boucle:
    LDB     AlI
    CMPB    #78
    BHS     Al_Fin
    CLRA
    ADDD    AlAdr
    TFR     D,X
    JSR     Lit8
    LDB     AlI
    LDX     #AlphaT
    STA     B,X
    INC     AlI
    BRA     Al_Boucle
Al_Defaut:
    PSHS    Y                       ; (Y est le PC)
    LDX     #AlphaDef
    LDY     #AlphaT
    LDW     #78
    TFM     X+,Y+
    PULS    Y
Al_Fin:
    LDX     #AlphaT
    LDA     #' '
    STA     52,X
    LDA     #13
    STA     53,X
    RTS
AlphaDef:
    FCC     "abcdefghijklmnopqrstuvwxyz"
    FCC     "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    FCB     32,13
    FCC     "0123456789.,!?_#"
    FCB     39,34
    FCC     "/"
    FCB     92                      ; « \ » (FCC ne connaît pas l'échappement)
    FCC     "-:()"

; Unicode_Init : la table Unicode du jeu (en-tête étendu, mot 3) ou celle
; par défaut -> UniT, ZsN ; puis ZsCp (ZSCII 155+ -> CP437), LatZs et
; LatCp (Latin-1 $A0-$FF -> ZSCII, -> CP437)
Unicode_Init:
    LDX     #$36
    JSR     Lit16
    STD     UiExt
    BEQ     UI_Defaut
    TFR     D,X
    JSR     Lit16                   ; nombre de mots de l'en-tête étendu
    CMPD    #3
    BLO     UI_Defaut
    LDD     UiExt
    ADDD    #6
    TFR     D,X
    JSR     Lit16
    STD     UiT
    BEQ     UI_Defaut
    TFR     D,X
    JSR     Lit8
    CMPA    #97
    BLS     UI_N
    LDA     #97
UI_N:
    STA     ZsN
    CLR     UiI
UI_Copie:
    LDB     UiI
    CMPB    ZsN
    BHS     UI_Tables
    CLRA
    LSLB
    ROLA
    ADDD    UiT
    ADDD    #1
    TFR     D,X
    JSR     Lit16
    PSHS    D
    LDB     UiI
    LSLB
    LDX     #UniT
    ABX
    PULS    D
    STD     ,X
    INC     UiI
    BRA     UI_Copie
UI_Defaut:
    LDA     #UNI_DEFAUT_N
    STA     ZsN
    PSHS    Y
    LDX     #Uni_Defaut
    LDY     #UniT
    LDW     #UNI_DEFAUT_N*2
    TFM     X+,Y+
    PULS    Y
UI_Tables:
    CLR     UiI                     ; ZsCp
UI_Zs:
    LDB     UiI
    CMPB    ZsN
    BHS     UI_Lat
    LSLB
    LDX     #UniT
    ABX
    LDD     ,X
    JSR     Uni_Vers_CP
    BCC     UI_ZsOk
    LDA     #'?'
UI_ZsOk:
    LDB     UiI
    LDX     #ZsCp
    STA     B,X
    INC     UiI
    BRA     UI_Zs
UI_Lat:
    CLR     UiI                     ; LatZs, LatCp : $A0 + i
UI_LatB:
    LDB     UiI
    CMPB    #96
    BHS     UI_Fin
    ADDB    #$A0
    CLRA
    PSHS    D
    JSR     Uni_Vers_Z
    LDB     UiI
    LDX     #LatZs
    STA     B,X
    PULS    D
    JSR     Uni_Vers_CP
    BCC     UI_LatOk
    LDA     #'?'
UI_LatOk:
    LDB     UiI
    LDX     #LatCp
    STA     B,X
    INC     UiI
    BRA     UI_LatB
UI_Fin:
    RTS

; Uni_Vers_CP : D = point de code -> A = CP437 ; C = 1 : absent
Uni_Vers_CP:
    CMPD    #32
    BLO     UC_Cherche
    CMPD    #126
    BHI     UC_Cherche
    TFR     B,A
    ANDCC   #$FE
    RTS
UC_Cherche:
    LDX     #Uni_Cp437
    PSHS    D
    LDB     #128
UC_Boucle:
    LDA     ,S
    CMPA    ,X
    BNE     UC_Suiv
    LDA     1,S
    CMPA    1,X
    BEQ     UC_Trouve
UC_Suiv:
    LEAX    2,X
    INCB
    BNE     UC_Boucle
    LEAS    2,S
    ORCC    #1
    RTS
UC_Trouve:
    LEAS    2,S
    TFR     B,A                     ; 128 + rang
    ANDCC   #$FE
    RTS

; Uni_Vers_Z : D = point de code -> A = ZSCII (vers_zscii : la table
; Unicode, sinon « ? » ; ASCII et 13 tels quels)
Uni_Vers_Z:
    CMPD    #32
    BLO     UZ_Cherche
    CMPD    #126
    BHI     UZ_Cherche
    TFR     B,A
    RTS
UZ_Cherche:
    PSHS    D
    LDX     #UniT
    CLRB
UZ_Boucle:
    CMPB    ZsN
    BHS     UZ_Absent
    LDA     ,S
    CMPA    ,X
    BNE     UZ_Suiv
    LDA     1,S
    CMPA    1,X
    BEQ     UZ_Trouve
UZ_Suiv:
    LEAX    2,X
    INCB
    BRA     UZ_Boucle
UZ_Trouve:
    LEAS    2,S
    TFR     B,A
    ADDA    #155
    RTS
UZ_Absent:
    LEAS    2,S
    LDA     #'?'
    RTS

; Lat_Vers_CP / Lat_Vers_Z : A = Latin-1 (32-126, $A0-$FF) -> A
Lat_Vers_CP:
    CMPA    #$A0
    BLO     LV_Ascii
    SUBA    #$A0
    LDX     #LatCp
    LDA     A,X
    RTS
Lat_Vers_Z:
    CMPA    #$A0
    BLO     LV_Ascii
    SUBA    #$A0
    LDX     #LatZs
    LDA     A,X
    RTS
LV_Ascii:
    CMPA    #32
    BLO     LV_Q
    CMPA    #126
    BLS     LV_Fin
LV_Q:
    LDA     #'?'
LV_Fin:
    RTS

; Lat_Minuscule : A-Z et À-Þ (sauf ×) en minuscules
Lat_Minuscule:
    CMPA    #'A'
    BLO     LM_Fin
    CMPA    #'Z'
    BLS     LM_Bas
    CMPA    #$C0
    BLO     LM_Fin
    CMPA    #$DE
    BHI     LM_Fin
    CMPA    #$D7
    BEQ     LM_Fin
LM_Bas:
    ADDA    #32
LM_Fin:
    RTS

; -------------------------------------------------------------------
; Dictionnaire
; -------------------------------------------------------------------
; Encode_Mot : X = adresse Z, B = longueur -> EncCle (6 octets)
Encode_Mot:
    STX     EnAdr
    STB     EnLg
    CLR     EnN
EN_Car:
    LDA     EnN
    CMPA    CleZ
    LBHS    EN_Pack
    LDA     EnLg
    LBEQ    EN_Pack
    DEC     EnLg
    LDX     EnAdr
    LEAX    1,X
    STX     EnAdr
    LEAX    -1,X
    JSR     Lit8
    JSR     Norm_Z
    BCS     EN_Car                  ; 0 : rien
    STA     EnC
    LDX     #AlphaT                 ; A0 ?
    CLRB
EN_A0:
    CMPA    B,X
    BEQ     EN_Z0
    INCB
    CMPB    #26
    BLO     EN_A0
EN_A1:
    CMPA    B,X
    BEQ     EN_Z1
    INCB
    CMPB    #52
    BLO     EN_A1
    LDB     #54
EN_A2:
    CMPA    B,X
    BEQ     EN_Z2
    INCB
    CMPB    #78
    BLO     EN_A2
    LDA     #5                      ; 5, 6, haut, bas
    JSR     EN_Pose
    LDA     #6
    JSR     EN_Pose
    LDA     EnC
    LSRA
    LSRA
    LSRA
    LSRA
    LSRA
    JSR     EN_Pose
    LDA     EnC
    ANDA    #$1F
    JSR     EN_Pose
    BRA     EN_Car
EN_Z0:
    TFR     B,A
    ADDA    #6
    JSR     EN_Pose
    BRA     EN_Car
EN_Z1:
    PSHS    B
    LDA     #4
    JSR     EN_Pose
    PULS    A
    SUBA    #26-6
    JSR     EN_Pose
    LBRA    EN_Car
EN_Z2:
    PSHS    B
    LDA     #5
    JSR     EN_Pose
    PULS    A
    SUBA    #52-6
    JSR     EN_Pose
    JMP     EN_Car
EN_Pack:
    LDA     EnN                     ; complété par des 5
    CMPA    CleZ
    BHS     EN_Mots
    LDA     #5
    BSR     EN_Pose
    BRA     EN_Pack
EN_Mots:
    PSHS    Y                       ; (Y est le PC)
    LDX     #EnZ
    LDY     #EncCle
    LDB     CleZ                    ; 3 caractères Z par mot
    LDA     #3
    CMPB    #9
    BEQ     EN_NMots
    DECA
EN_NMots:
    TFR     A,B
EN_Mot:
    PSHS    B
    LDA     ,X                      ; z1 << 10 | z2 << 5 | z3
    LSLA
    LSLA
    STA     EnW
    LDA     1,X
    LSRA
    LSRA
    LSRA
    ORA     EnW
    STA     ,Y
    LDA     1,X
    LSLA
    LSLA
    LSLA
    LSLA
    LSLA
    ORA     2,X
    STA     1,Y
    LEAX    3,X
    LEAY    2,Y
    PULS    B
    DECB
    BNE     EN_Mot
    PULS    Y
    LDX     #EncCle-2               ; le dernier mot : bit 15
    LDB     CleOct
    ABX
    LDA     ,X
    ORA     #$80
    STA     ,X
    RTS
EN_Pose:                            ; un caractère Z de plus (au plus 12)
    LDB     EnN
    CMPB    #12
    BHS     EP_Fin
    LDX     #EnZ
    STA     B,X
    INC     EnN
EP_Fin:
    RTS

; Encode_Texte : @encode_text texte, longueur, début, résultat
Encode_Texte:
    LDD     Ops
    ADDD    Ops+4
    TFR     D,X
    LDB     Ops+3
    JSR     Encode_Mot
    CLR     EtI
ET_Boucle:
    LDB     EtI
    CMPB    CleOct
    BHS     ET_Fin
    LDX     #EncCle
    LDA     B,X
    PSHS    A
    CLRA
    ADDD    Ops+6
    TFR     D,X
    PULS    A
    JSR     Ecrit8
    INC     EtI
    BRA     ET_Boucle
ET_Fin:
    RTS

; Decoupe : D = texte, X = analyse ; DcDico (0 : celui du jeu), DcSauf
Decoupe:
    STD     DcTexte
    STX     DcAnalyse
    LDD     DcDico
    BNE     Dc_D
    LDD     Dico
Dc_D:
    STD     DcD
    TFR     D,X
    JSR     Lit8
    STA     DcNSep
    CLR     DcI                     ; les séparateurs
Dc_Sep:
    LDB     DcI
    CMPB    DcNSep
    BHS     Dc_Ent
    CMPB    #32
    BHS     Dc_Ent
    CLRA
    ADDD    DcD
    ADDD    #1
    TFR     D,X
    JSR     Lit8
    LDB     DcI
    LDX     #DcSeps
    STA     B,X
    INC     DcI
    BRA     Dc_Sep
Dc_Ent:
    LDB     DcNSep
    CLRA
    ADDD    DcD
    ADDD    #1
    TFR     D,X
    JSR     Lit8
    STA     DcLgE
    LDB     DcNSep
    CLRA
    ADDD    DcD
    ADDD    #2
    TFR     D,X
    JSR     Lit16
    STD     DcNb
    LDB     DcNSep
    CLRA
    ADDD    DcD
    ADDD    #4
    STD     DcEntrees
    TST     Vieux                   ; le texte : dans LIGNE
    BNE     Dc_V4                   ; (v1-4 : en +1, fini par 0)
    LDX     DcTexte
    LEAX    1,X
    JSR     Lit8
    STA     DcLg
Dc_V4:
    CLR     DcI
Dc_Copie:
    LDB     DcI
    TST     Vieux
    BNE     Dc_CopieV4
    CMPB    DcLg
    BHS     Dc_Max
Dc_CopieV4:
    CLRA
    ADDD    DcTexte
    ADDB    DcOfs
    ADCA    #0
    TFR     D,X
    JSR     Lit8
    TST     Vieux
    BEQ     Dc_Range
    TSTA
    BNE     Dc_Range
    LDB     DcI                     ; v1-4 : le 0 final donne la longueur
    STB     DcLg
    BRA     Dc_Max
Dc_Range:
    LDB     DcI
    LDX     #LIGNE
    ABX
    STA     ,X
    INC     DcI
    LBNE    Dc_Copie
    DEC     DcI                     ; (255 au plus)
    LDB     DcI
    STB     DcLg
Dc_Max:
    LDX     DcAnalyse
    JSR     Lit8
    STA     DcMaxi
    CLR     DcK
    CLR     DcI
Dc_Scan:
    LDB     DcI
    CMPB    DcLg
    LBHS    Dc_Fin
    LDA     DcK
    CMPA    DcMaxi
    LBHS    Dc_Fin
    LDX     #LIGNE
    LDA     B,X
    CMPA    #' '
    BNE     Dc_PasEsp
    INC     DcI
    BRA     Dc_Scan
Dc_PasEsp:
    JSR     Est_Sep
    BCC     Dc_MotLong
    LDA     DcI                     ; un séparateur : un mot à lui seul
    STA     DcDeb
    LDA     #1
    STA     DcN
    INC     DcI
    BRA     Dc_Traite
Dc_MotLong:
    LDA     DcI
    STA     DcDeb
Dc_MotC:
    INC     DcI
    LDB     DcI
    CMPB    DcLg
    BHS     Dc_MotFin
    LDX     #LIGNE
    LDA     B,X
    CMPA    #' '
    BEQ     Dc_MotFin
    JSR     Est_Sep
    BCC     Dc_MotC
Dc_MotFin:
    LDA     DcI
    SUBA    DcDeb
    STA     DcN
Dc_Traite:
    LDB     DcDeb                   ; la clé
    CLRA
    ADDD    DcTexte
    ADDB    DcOfs
    ADCA    #0
    TFR     D,X
    LDB     DcN
    JSR     Encode_Mot
    JSR     Cherche_Mot             ; D = entrée ou 0
    STD     DcTrouve
    BNE     Dc_Ecrit
    TST     DcSauf
    BNE     Dc_Suiv
Dc_Ecrit:
    LDB     DcK                     ; analyse + 2 + 4k
    CLRA
    LSLB
    ROLA
    LSLB
    ROLA
    ADDD    DcAnalyse
    ADDD    #2
    STD     DcB
    TFR     D,X
    LDD     DcTrouve
    JSR     Ecrit16
    LDX     DcB
    LEAX    2,X
    LDA     DcN
    JSR     Ecrit8
    LDX     DcB
    LEAX    3,X
    LDA     DcDeb
    ADDA    DcOfs
    JSR     Ecrit8
Dc_Suiv:
    INC     DcK
    JMP     Dc_Scan
Dc_Fin:
    LDX     DcAnalyse
    LEAX    1,X
    LDA     DcK
    JMP     Ecrit8

; Est_Sep : A = caractère ; C = 1 s'il est un séparateur
Est_Sep:
    LDX     #DcSeps
    CLRB
ES_Boucle:
    CMPB    DcNSep
    BHS     ES_Non
    CMPB    #32
    BHS     ES_Non
    CMPA    B,X
    BEQ     ES_Oui
    INCB
    BRA     ES_Boucle
ES_Non:
    ANDCC   #$FE
    RTS
ES_Oui:
    ORCC    #1
    RTS

; Cherche_Mot : EncCle dans le dictionnaire -> D = adresse de l'entrée, 0
Cherche_Mot:
    LDD     DcNb
    BMI     CM_Lineaire
    BEQ     CM_Rien
    LDD     #0
    STD     CmBas
    LDD     DcNb
    SUBD    #1
    STD     CmHaut
CM_Boucle:
    LDD     CmBas
    CMPD    CmHaut
    BGT     CM_Rien
    ADDD    CmHaut                  ; mil = (bas + haut) / 2
    LSRA
    RORB
    STD     CmMil
    JSR     CM_Adr                  ; X = entrée mil
    STX     CmE
    JSR     Compare_Cle             ; A : 0 égal, 1 e < clé, 2 e > clé
    TSTA
    BEQ     CM_Trouve
    CMPA    #1
    BNE     CM_Haut
    LDD     CmMil
    ADDD    #1
    STD     CmBas
    BRA     CM_Boucle
CM_Haut:
    LDD     CmMil
    SUBD    #1
    STD     CmHaut
    BRA     CM_Boucle
CM_Trouve:
    LDD     CmE
    RTS
CM_Rien:
    CLRA
    CLRB
    RTS
CM_Lineaire:
    COMA
    COMB
    ADDD    #1
    STD     CmHaut                  ; -nb entrées
    LDD     #0
    STD     CmMil
CM_LBoucle:
    LDD     CmMil
    CMPD    CmHaut
    BHS     CM_Rien
    JSR     CM_Adr
    STX     CmE
    JSR     Compare_Cle
    TSTA
    BEQ     CM_Trouve
    LDD     CmMil
    ADDD    #1
    STD     CmMil
    BRA     CM_LBoucle

; CM_Adr : X = DcEntrees + CmMil * DcLgE
CM_Adr:
    LDA     DcLgE
    LDB     CmMil+1
    MUL
    PSHS    D
    LDA     DcLgE
    LDB     CmMil
    MUL
    TFR     B,A
    CLRB
    ADDD    ,S++
    ADDD    DcEntrees
    TFR     D,X
    RTS

; Compare_Cle : les 6 octets en CmE contre EncCle -> A (0, 1 <, 2 >)
Compare_Cle:
    CLR     CcI
CC_Boucle:
    LDB     CcI
    CMPB    CleOct
    BHS     CC_Egal
    CLRA
    ADDD    CmE
    TFR     D,X
    JSR     Lit8
    LDB     CcI
    LDX     #EncCle
    CMPA    B,X
    BLO     CC_Moins
    BHI     CC_Plus
    INC     CcI
    BRA     CC_Boucle
CC_Egal:
    CLRA
    RTS
CC_Moins:
    LDA     #1
    RTS
CC_Plus:
    LDA     #2
    RTS

TxtAbrev:       FCN "abreviation dans une abreviation"

TxtMode:        RMB 1               ; 0 : au PC ; 1 : en TxtAdr
DtMot:          RMB 2
DtAlpha:        RMB 1
DtEtat:         RMB 1               ; 0, 1 abréviation, 2-3 échappement
DtAbZ:          RMB 1
DtEsc:          RMB 1
DtNiv:          RMB 1
AlAdr:          RMB 2
AlI:            RMB 1
ZsN:            RMB 1
UiExt:          RMB 2
UiT:            RMB 2
UiI:            RMB 1
SuU:            RMB 2
SuZ:            RMB 1
NbV:            RMB 2
NbC:            RMB 1
NbZero:         RMB 1
PtAdr:          RMB 2
PtH:            RMB 2
PtSaut:         RMB 2
PtLigne:        RMB 2
PtCol:          RMB 2
PtR:            RMB 2
PtI:            RMB 2
CtN:            RMB 2
CtI:            RMB 2
EnAdr:          RMB 2
EnLg:           RMB 1
EnN:            RMB 1
EnC:            RMB 1
EnW:            RMB 1
EnZ:            RMB 12
EncCle:         RMB 6
VersEtat:       RMB 1
EtatP:          RMB 2
EtatLim:        RMB 2
EtA:            RMB 2
EtB:            RMB 2
EtDl:           RMB 1
EtCol:          RMB 1
CleZ:           RMB 1               ; caractères Z d'une clé : 9 (6 en v1-3)
CleOct:         RMB 1               ; octets d'une clé : 6 (4 en v1-3)
DcOfs:          RMB 1               ; le texte saisi en +2 (+1 en v1-4)
EtI:            RMB 1
DcTexte:        RMB 2
DcAnalyse:      RMB 2
DcDico:         RMB 2
DcSauf:         RMB 1
DcD:            RMB 2
DcNSep:         RMB 1
DcLgE:          RMB 1
DcNb:           RMB 2
DcEntrees:      RMB 2
DcLg:           RMB 1
DcI:            RMB 1
DcK:            RMB 1
DcMaxi:         RMB 1
DcDeb:          RMB 1
DcN:            RMB 1
DcTrouve:       RMB 2
DcB:            RMB 2
CmBas:          RMB 2
CmHaut:         RMB 2
CmMil:          RMB 2
CmE:            RMB 2
CcI:            RMB 1
