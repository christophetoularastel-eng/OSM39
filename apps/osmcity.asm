; ===================================================================
; OSMCITY.ASM - OSM City : la ville d'Annonay vue de dessus
; ===================================================================
; Flèches : rouler dans cette direction (accélérer, freiner si c'est
; l'inverse, tourner dès que la rue le permet) ; Echap : quitter.
; Application d'OSM-VISION (page 1, liée à $0000, App_Start à l'offset 0),
; plein écran 80 x 30. La carte est le fichier OSMCITY.MAP (dossier
; courant, 64 Ko), chargé en pages 2-3.
;
; SOURCE UNIQUE : tools/osmcity/osmcity.py (la carte, tirée
; d'OpenStreetMap, la règle des tuiles et le modèle exact de la conduite
; et de l'écran que test/verifie_osmcity.py compare à ce binaire) et
; tools/osmcity/glyphes.py (les dessins). apps/osmcity_data.inc et
; OSMCITY.MAP sont GÉNÉRÉS. Carte : © contributeurs OpenStreetMap (ODbL).
;
; POLICE. Les tuiles sont dans la page 1 de la banque 1 de la police
; (28C256, $A120 D4-D5 = A13-A14 de la police) : on y passe en entrant,
; on rend la banque 0 en sortant. (Avec l'AT28C64 d'avant, D4 n'est
; relié à rien : l'écran montre les glyphes de la banque 0.)
;
; CARTE. 512 x 256 cases de 4 bits (une sorte), rangée y = 256 octets en
; page 2 + y/128, adresse 256 (y mod 128). Le jeu en garde 32 rangées
; (y - 16 .. y + 15 autour de la voiture) dans un anneau en page 1
; (rangée y en CACHE + 256 (y mod 32)) : un pas vers le nord ou le sud en
; recopie une par FarRead ; un pas de côté, rien.
;
; ÉCRAN. La voiture reste en rangée 15 (colonne 40 ; 39-40 vers l'est ou
; l'ouest) ; la ville défile par l'adresse de départ du 6845 (Debut, en
; cases, modulo 4096). Un pas = une colonne (30 cases) ou une rangée
; (80 cases, un TFM coupé au bout de la VRAM), les cases quittées par la
; voiture, la voiture : préparés pendant la trame, écrits juste après le
; signal de trame (Appliquer). Chaque case : Tuile (sa sorte et celles de
; ses 4 voisines, tables de osmcity_data.inc).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    export App_Start

CENTRE_C        equ 40
CENTRE_R        equ 15
LISTE_MAX       equ 36
RUES_ADR        equ $6000           ; OSMCITY.RUE : la grille des rues (8 Ko)
CACHE           equ $4000           ; 32 rangées de 256 octets ($4000-$5FFF)
CACHE_HI        equ $40
BANQUE_JEU      equ $10             ; $A120 : banque 1 de la police
NFIN            equ NMOB+NPOLICE+2  ; circulation, police, objets : à la suite
NTOUS           equ NGAREES+NFIN    ; garées puis le reste (Garees, Mobiles...)
PATROUILLE      equ 0
CHASSE          equ 1
RECHERCHE       equ 2
RANGEE_T        equ 82              ; Decode : mx - 1 .. mx + 80
COLONNE_T       equ 32              ; Prep_Colonne : my - 16 .. my + 15

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDX     #NomCarte               ; la carte, en pages 2-3
    LDY     #NomFmt
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #NomFmt
    LDA     #2
    LDY     #0
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCC     AS_Carte
    RTS                             ; pas de carte : rien
AS_Carte:
    LDX     #NomRues                ; les rues, en page 1 à RUES_ADR
    LDY     #NomFmt
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #NomFmt
    LDA     #1
    LDY     #RUES_ADR
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCC     AS_Rues
    RTS
AS_Rues:
    LDD     DepartX
    STD     PosX
    LDD     DepartY
    STD     PosY
    CLR     Niv
    CLR     BT
    CLR     BTy
    CLR     BV
    CLR     BP
    CLR     TrameN
    CLR     KeyK
    LDA     #ALEA0
    STA     AleaS
    CLR     TMob
    CLR     OcSauf
    CLR     OcSauf+1
    CLR     Pied
    CLR     KeyEsp
    LDA     #COUL_JOUEUR
    STA     VCoul
    CLR     Dir
    CLR     Vit
    CLR     Ax
    CLR     Ax+1
    CLR     Ay
    CLR     Ay+1
    CLR     Debut
    CLR     Debut+1
    CLR     KeyHaut
    CLR     KeyDroite
    CLR     KeyBas
    CLR     KeyGauche
    CLR     KbE0
    CLR     KbRel
    CLR     QuitReq
    CLR     EscUp
    CLR     SegA
    CLR     SegB
    CLR     SegC
    CLR     LsN
    CLR     CrtcN
    CLR     PlqNum
    CLR     PlqL
    CLR     PlqC0
    LDD     PosY                    ; les 32 rangées autour du départ
    SUBD    #16
    STD     Ligne
    LDA     #32
    STA     Compte
AS_Cache:
    LDD     Ligne
    JSR     Charge_Rangee
    LDD     Ligne
    ADDD    #1
    STD     Ligne
    DEC     Compte
    BNE     AS_Cache
    LDA     >kbd_tete               ; ce qui était tapé avant : oublié
    STA     >kbd_queue
    LDX     #VRAM_BASE+(25*160)     ; rangées 25-29 d'OSM-VISION, une par trame
    LDY     #SaveBas                ; (OSM-VISION ne garde que 0-24)
    LDB     #5
AS_Garde:
    PSHS    B,X,Y
    JSR     Fenetre
    PULS    B,X,Y
    LDW     #160
    TFM     X+,Y+
    DECB
    BNE     AS_Garde
    LDA     #BANQUE_JEU             ; la police d'OSM City
    STA     VRAM_CTRL
    LDA     #$FF                    ; la plaque : à faire
    STA     SigNum
    CLR     PlqNum
    CLR     Signal
    LDA     #COUL_POLICE
    STA     PCoul
    JSR     Nouvelle                ; butin, planque (avant tout dessin)
    CLR     LsN
    JSR     Fait_Proches            ; (le premier dessin en a besoin)
    LDA     #1                      ; départ 0
    STA     CrtcN
    CLR     Rang
AS_Rangee:                          ; l'écran, une rangée par trame
    LDB     Rang
    JSR     Prep_Rangee
    JSR     Fenetre
    JSR     Appliquer
    INC     Rang
    LDA     Rang
    CMPA    #30
    BLO     AS_Rangee
    JSR     Prep_Voiture
    JSR     Fenetre
    JSR     Appliquer
    CLR     Mx                      ; la plaque, dès le départ
    CLR     My
    JSR     Plaque
    JSR     Fenetre
    JSR     Appliquer

; -------------------------------------------------------------------
; Boucle : une trame par tour
; -------------------------------------------------------------------
Boucle:
    JSR     Fenetre
    JSR     Appliquer
    JSR     Lire_Clavier
    TST     QuitReq
    LBNE    Quitter
    JSR     Pas
    JSR     Preparer
    JSR     Population
    JSR     Son
    BRA     Boucle

; Sortie : départ 0 et banque 0 (OSM-VISION rend les rangées 0-24), nos
; rangées 25-29 rendues, le relâchement d'Echap attendu, la file vidée.
Quitter:
    CLR     SegA
    CLR     SegB
    CLR     SegC
    CLR     LsN
    CLR     Debut
    CLR     Debut+1
    LDA     #1
    STA     CrtcN
    JSR     Fenetre
    JSR     Appliquer
    CLR     VRAM_CTRL
    LDX     #SaveBas
    LDY     #VRAM_BASE+(25*160)
    LDB     #5
Q_Rend:
    PSHS    B,X,Y
    JSR     Fenetre
    PULS    B,X,Y
    LDW     #160
    TFM     X+,Y+
    DECB
    BNE     Q_Rend
    LDB     #30
Q_Attente:
    TST     EscUp
    BNE     Q_Fin
    PSHS    B
    JSR     Fenetre
    PULS    B
    DECB
    BNE     Q_Attente
Q_Fin:
    LDD     #$0800                  ; silence, le mixeur du BIOS ($3A)
    JSR     Ay_Ecrit
    LDD     #$0900
    JSR     Ay_Ecrit
    LDD     #$0A00
    JSR     Ay_Ecrit
    LDD     #$073A
    JSR     Ay_Ecrit
    ORCC    #%00010000
    LDA     >kbd_tete
    STA     >kbd_queue
    CLR     >kbd_apres_f0
    CLR     >kbd_echap
    ANDCC   #%11101111
    RTS

; -------------------------------------------------------------------
; Charge_Rangee : D = y (16 bits signés) -> la rangée y de la carte dans
; l'anneau (CACHE + 256 (y mod 32)) ; hors de la carte : du bâti.
; Détruit D, X, Y, U, W.
; -------------------------------------------------------------------
Charge_Rangee:
    STD     CrY
    ANDB    #31                     ; destination
    TFR     B,A
    CLRB
    ADDD    #CACHE
    TFR     D,Y
    LDD     CrY
    CMPD    #CARTE_H                ; (négatif : très grand, non signé)
    BHS     CR_Hors
    TFR     B,A                     ; source : 256 (y mod 128) ...
    ANDA    #127
    CLRB
    TFR     D,X
    LDA     CrY+1                   ; ... en page 2 + y / 128
    LSLA
    LDA     #2
    ADCA    #0
    LDB     #1                      ; vers la page 1 (la nôtre)
    LDU     #256
    JSR     [table_function_ram+sys_FarRead]
    RTS
CR_Hors:
    LDA     #(S_BATI*16)+S_BATI
    STA     ,Y
    LEAX    ,Y
    LEAY    1,Y
    LDW     #255
    TFM     X+,Y+
    RTS

; -------------------------------------------------------------------
; SorteC : X = mx, Y = my (16 bits signés) -> B = la sorte (du bâti hors
; de la carte), lue dans l'anneau. Préserve X, Y, U. Détruit A, W.
; -------------------------------------------------------------------
SorteC:
    CMPX    #CARTE_L
    BHS     SC_Hors
    CMPY    #CARTE_H
    BHS     SC_Hors
    PSHS    U
    TFR     Y,W                     ; F = my (bas)
    TFR     X,D
    LSRA                            ; B = mx / 2, C = mx impair
    RORB
    TFR     F,A                     ; (TFR, AND, OR, LD gardent C)
    ANDA    #31
    ORA     #CACHE_HI
    TFR     D,U
    LDB     ,U
    BCS     SC_Bas
    LSRB
    LSRB
    LSRB
    LSRB
    PULS    U,PC
SC_Bas:
    ANDB    #$0F
    PULS    U,PC
SC_Hors:
    LDB     #S_BATI
    RTS

; -------------------------------------------------------------------
; Tuile : X = mx, Y = my -> A = glyphe, B = attribut (osmcity.py, tuile) :
; la sorte de la case et de ses 4 voisines, puis Calc_Case. Préserve X, Y,
; U. Détruit W.
; -------------------------------------------------------------------
Tuile:
    PSHS    X,Y,U
    JSR     SorteC
    STB     TS
    LEAY    -1,Y
    JSR     SorteC
    STB     VN
    LEAY    2,Y
    JSR     SorteC
    STB     VS
    LEAY    -1,Y
    LEAX    1,X
    JSR     SorteC
    STB     VE
    LEAX    -2,X
    JSR     SorteC
    STB     VO
    LEAX    1,X
    TFR     X,D
    STB     XB
    TFR     Y,D
    STB     YB
    BSR     Calc_Case
    LDX     ,S                      ; (Calc_Case détruit X)
    JSR     Garee_Case              ; une voiture garée ? (X, Y, TS)
    PULS    X,Y,U,PC

; Calc_Case : TS (la sorte), VN VE VS VO (celles des voisines nord, est,
; sud, ouest), XB YB (x, y : l'octet bas) -> A = glyphe, B = attribut. La
; règle de osmcity.py (tuile) : bords (masque TM), coins arrondis, herbe et
; arbres, places de parking, garde-corps. Préserve Y, U. Détruit X.
Calc_Case:
    LDB     TS
    LDX     #Genre
    LDA     B,X
    STA     TG
    CLR     TM
    CMPB    VN                      ; raccourci : les 4 voisines de la même
    BNE     CC_Lent                 ; sorte : ni bord ni coin
    CMPB    VE
    BNE     CC_Lent
    CMPB    VS
    BNE     CC_Lent
    CMPB    VO
    BNE     CC_Lent
    CMPA    #3
    LBEQ    CC_Herbe
    LBRA    CC_Glyphe
CC_Lent:
    LDA     #$FF                    ; la couleur des voisines exposées : aucune
    STA     NC
    LDA     TG
    CMPA    #2
    LBEQ    CC_Pont
    LDX     #Famille
    LDA     B,X                     ; la famille de la case
    LDB     VN
    CMPA    B,X
    BEQ     CC_E
    OIM     #1,TM
    JSR     Note_NC
CC_E:
    LDB     VE
    CMPA    B,X
    BEQ     CC_S
    OIM     #2,TM
    JSR     Note_NC
CC_S:
    LDB     VS
    CMPA    B,X
    BEQ     CC_O
    OIM     #4,TM
    JSR     Note_NC
CC_O:
    LDB     VO
    CMPA    B,X
    BEQ     CC_Coin
    OIM     #8,TM
    JSR     Note_NC
CC_Coin:
    JSR     Coin                    ; une case de coin : arrondie
    BCC     CC_Fin
    LDA     TG
    CMPA    #3
    BEQ     CC_Herbe
CC_Glyphe:
    LDB     TS
    LDX     #Base
    LDA     B,X
    LDB     TG
    CMPB    #1
    BNE     CC_Plus
    TST     TM                      ; place : avec un bord, la route
    BNE     CC_Route
    LDB     YB                      ; y pair : une place
    BITB    #1
    BEQ     CC_Place
    LDB     XB                      ; y impair : l'allée, un P tous les 16
    ANDB    #15
    BNE     CC_Allee
    LDA     #G_P
    BRA     CC_Attr
CC_Allee:
    LDA     #G_ROUTE
    BRA     CC_Attr
CC_Place:
    LDA     #G_PLACE
    BRA     CC_Attr
CC_Route:
    LDA     #G_ROUTE
CC_Plus:
    ADDA    TM
CC_Attr:
    LDB     TS
    LDX     #Attr
    LDB     B,X
CC_Fin:
    RTS
CC_Herbe:                           ; herbe ; dans un parc, un arbre si (x + y) & 3 = 0
    LDA     XB
    LDB     TS
    CMPB    #S_PARC
    BNE     CC_H2
    ADDA    YB
    ANDA    #3
    BNE     CC_H1
    LDA     #G_ARBRE
    BRA     CC_Attr
CC_H1:
    LDA     XB
CC_H2:
    SUBA    YB                      ; HERBE + ((x - y) & 3)
    ANDA    #3
    ADDA    #G_HERBE
    BRA     CC_Attr
CC_Pont:                            ; tablier : garde-corps (table Garde)
    LDX     #Garde
    LDB     VN
    TST     B,X
    BEQ     CC_PE
    OIM     #1,TM
CC_PE:
    LDB     VE
    TST     B,X
    BEQ     CC_PS
    OIM     #2,TM
CC_PS:
    LDB     VS
    TST     B,X
    BEQ     CC_PO
    OIM     #4,TM
CC_PO:
    LDB     VO
    TST     B,X
    LBEQ    CC_Glyphe
    OIM     #8,TM
    LBRA    CC_Glyphe
; Coin : TG, TM (le masque), NC (la couleur des voisines exposées : $FF
; aucune, $FE plusieurs), TS -> C = 0 et D = glyphe:attribut si la case est
; un coin à arrondir (genres 0 et 3, masque N+O, N+E, E+S ou S+O, voisines
; d'une même couleur, autre que la sienne) ; sinon C = 1. Préserve X, Y, U.
Coin:
    LDA     TG
    CMPA    #3
    BEQ     Co_Genre
    TSTA
    BNE     Co_Non
Co_Genre:
    PSHS    X
    LDB     TM
    LDX     #CoinT
    LDA     B,X
    BEQ     Co_NonX
    LDB     NC
    BMI     Co_NonX
    PSHS    A
    LDB     TS
    LDX     #Coul
    LDA     B,X                     ; sa couleur
    CMPA    NC
    BEQ     Co_NonA
    TSTA                            ; noir : premier plan 8 (pas 0)
    BNE     Co_Pp
    LDA     #8
Co_Pp:
    STA     TT2
    LDB     NC                      ; fond : la couleur des voisines
    LSLB
    LSLB
    LSLB
    LSLB
    ORB     TT2
    ORB     #$80
    PULS    A
    ADDA    #G_COIN-1
    PULS    X
    ANDCC   #$FE
    RTS
Co_NonA:
    PULS    A
Co_NonX:
    PULS    X
Co_Non:
    ORCC    #1
    RTS

; Note_NC : B = la sorte d'une voisine exposée -> NC (sa couleur, ou $FE
; si deux voisines exposées n'ont pas la même). Préserve A, X, U.
Note_NC:
    PSHS    A,X
    LDX     #Coul
    LDA     B,X
    LDB     NC
    CMPB    #$FF
    BEQ     NN_Pose
    CMPA    NC
    BEQ     NN_Fin
    LDA     #$FE
NN_Pose:
    STA     NC
NN_Fin:
    PULS    A,X,PC


; -------------------------------------------------------------------
; Segments : un morceau de rangée de l'écran à écrire par TFM (Appliquer).
; Fiche : +0 à écrire, +1 destination, +3 octets jusqu'au bout de la
; VRAM, +5 octets depuis son début, +7 source. SegA : une rangée entière
; (RowBuf) ; SegB : des cases rendues à la carte (RowBuf2) ; SegC : la
; plaque (PlqTxt).
; Prep_Rangee : B = rangée de l'écran -> SegA, ses 80 cases.
; -------------------------------------------------------------------
Prep_Rangee:
    CLRA
    PSHS    A
    LDA     #80
    STA     SgN
    PULS    A
    LDU     #SegA
    LDX     #RowBuf
; Prep_Seg : B = rangée, A = première colonne, SgN = cases, U = fiche,
; X = tampon -> les tuiles de ces cases dans le tampon, la fiche posée.
Prep_Seg:
    STX     7,U
    STU     SgD
    STA     SgC
    STB     SgR
    JSR     Seg_Pose
    LDB     SgR                     ; my = PosY - 15 + rangée
    CLRA
    ADDD    PosY
    SUBD    #CENTRE_R
    STD     RY
    LDB     SgC                     ; mx = PosX - 40 + colonne
    CLRA
    ADDD    PosX
    SUBD    #CENTRE_C
    STD     RX
    LDA     SgN
    ADDA    #2
    STA     DN
    ; les sortes des rangées my - 1, my, my + 1, de mx - 1 à mx + SgN
    LDY     RY
    LEAY    -1,Y
    LDU     #RowN
    JSR     Decode
    LDY     RY
    LDU     #RowC
    JSR     Decode
    LDY     RY
    LEAY    1,Y
    LDU     #RowS
    JSR     Decode
    ; chaque case : la règle de Tuile, les voisines lues dans les tableaux
    LDA     RX+1
    STA     RXb
    LDU     SgD
    LDY     7,U
    LDU     #RowC+1
    LDA     SgN
    STA     Compte
PR_Case:
    LDB     ,U
    STB     TS
    LDB     -RANGEE_T,U
    STB     VN
    LDB     1,U
    STB     VE
    LDB     RANGEE_T,U
    STB     VS
    LDB     -1,U
    STB     VO
    LDA     RXb
    STA     XB
    LDA     RY+1
    STA     YB
    JSR     Calc_Case
    STD     ,Y++
    INC     RXb
    LEAU    1,U
    DEC     Compte
    BNE     PR_Case
    JMP     Garees_Rangee
; Seg_Pose : SgR (rangée), SgC (colonne), SgN (cases), SgD (fiche) -> la
; destination dans la VRAM (coupée au bout), la fiche à écrire.
Seg_Pose:
    LDU     SgD
    LDB     SgR                     ; (Debut + 80 r + c) mod 4096
    LDA     #80
    MUL
    ADDB    SgC
    ADCA    #0
    ADDD    Debut
    ANDA    #$0F
    STD     SgT
    LSLB
    ROLA
    ADDD    #VRAM_BASE
    STD     1,U
    LDD     #4096                   ; cases jusqu'au bout de la VRAM
    SUBD    SgT
    PSHS    D
    LDB     SgN
    CLRA
    CMPD    ,S++
    BLS     SP_Tient
    LDD     #4096
    SUBD    SgT
SP_Tient:
    LSLB                            ; en octets
    ROLA
    STD     3,U
    LDB     SgN
    CLRA
    LSLB
    ROLA
    SUBD    3,U
    STD     5,U
    LDA     #1
    STA     ,U
    RTS

; Decode : Y = my, U -> DN octets : les sortes des cases mx - 1 ..
; mx + DN - 2 (mx = RX) de la rangée my. Hors de la carte : du bâti. Détruit
; D, X, U, W.
Decode:
    LDA     DN
    STA     DCnt
    LDD     RX
    SUBD    #1
    CMPY    #CARTE_H
    BHS     De_Bati
    TSTA                            ; toute la rangée dans la carte ?
    BMI     De_Lent
    PSHS    D
    ADDB    DN
    ADCA    #0
    CMPD    #CARTE_L
    PULS    D                       ; (PULS garde les drapeaux)
    BHI     De_Lent
    TFR     Y,W                     ; rapide : les quartets à la suite
    LSRA
    RORB                            ; B = mx / 2, C = mx impair
    TFR     F,A
    ANDA    #31
    ORA     #CACHE_HI
    TFR     D,X
    BCC     De_Pair
    LDB     ,X+                     ; mx impair : le poids faible d'abord
    ANDB    #$0F
    STB     ,U+
    DEC     DCnt
De_Pair:
    LDB     ,X
    LSRB
    LSRB
    LSRB
    LSRB
    STB     ,U+
    DEC     DCnt
    BEQ     De_Fin
    LDB     ,X+
    ANDB    #$0F
    STB     ,U+
    DEC     DCnt
    BNE     De_Pair
De_Fin:
    RTS
De_Lent:                            ; au bord de la carte : case par case
    TFR     D,X
De_Case:
    JSR     SorteC
    STB     ,U+
    LEAX    1,X
    DEC     DCnt
    BNE     De_Case
    RTS
De_Bati:
    LDB     #S_BATI
De_BCase:
    STB     ,U+
    DEC     DCnt
    BNE     De_BCase
    RTS

; -------------------------------------------------------------------
; Prep_Colonne : B = colonne de l'écran, X = sa colonne de la carte ->
; 30 entrées de Liste (adresse VRAM, glyphe, attribut). Les sortes des
; colonnes mx - 1, mx, mx + 1, rangées my - 16 .. my + 15, d'abord (ColO,
; ColC, ColE : COLONNE_T octets chacune, à la suite), puis Calc_Case.
; -------------------------------------------------------------------
Prep_Colonne:
    STB     Col
    STX     CX
    LDA     LsN                     ; sa première entrée (Garees_Colonne)
    STA     LsCol
    LDD     PosY
    SUBD    #CENTRE_R+1
    STD     CY
    TFR     D,Y
    LDU     #ColO
    LDA     #COLONNE_T
    STA     Compte
    CLR     PcLent                  ; mx - 1 et mx + 1 dans la carte ?
    LDD     CX
    SUBD    #1
    BMI     PC_AuBord
    STB     PcPar                   ; (la parité : le bit 0)
    LSRA
    RORB
    STB     PcB0                    ; l'octet de mx - 1 dans sa rangée
    LDD     CX
    CMPD    #CARTE_L-1
    BLO     PC_Lit
PC_AuBord:
    INC     PcLent
PC_Lit:
    CMPY    #CARTE_H                ; hors de la carte (ou négatif) : du bâti
    BHS     PC_Bati
    TST     PcLent
    BNE     PC_Lent
    TFR     Y,D                     ; rapide : les quartets dans l'anneau
    TFR     B,A
    ANDA    #31
    ORA     #CACHE_HI
    LDB     PcB0
    TFR     D,X
    LDA     PcPar
    BITA    #1
    BNE     PC_Impair
    LDA     ,X                      ; mx - 1 pair : fort, faible, fort suivant
    TFR     A,B
    LSRB
    LSRB
    LSRB
    LSRB
    STB     ,U
    ANDA    #$0F
    STA     COLONNE_T,U
    LDB     1,X
    LSRB
    LSRB
    LSRB
    LSRB
    STB     2*COLONNE_T,U
    BRA     PC_Suite
PC_Impair:
    LDA     ,X                      ; impair : faible, fort suivant, faible suivant
    ANDA    #$0F
    STA     ,U
    LDA     1,X
    TFR     A,B
    LSRB
    LSRB
    LSRB
    LSRB
    STB     COLONNE_T,U
    ANDA    #$0F
    STA     2*COLONNE_T,U
    BRA     PC_Suite
PC_Bati:
    LDB     #S_BATI
    STB     ,U
    STB     COLONNE_T,U
    STB     2*COLONNE_T,U
    BRA     PC_Suite
PC_Lent:                            ; au bord de la carte : case par case
    LDX     CX
    LEAX    -1,X
    JSR     SorteC
    STB     ,U
    LEAX    1,X
    JSR     SorteC
    STB     COLONNE_T,U
    LEAX    1,X
    JSR     SorteC
    STB     2*COLONNE_T,U
PC_Suite:
    LEAU    1,U
    LEAY    1,Y
    DEC     Compte
    LBNE    PC_Lit
    LDA     CX+1
    STA     XB
    LDA     CY+1
    STA     YB
    LDU     #ColC+1
    CLR     Rang
PC_Case:
    INC     YB
    LDB     ,U
    STB     TS
    LDB     -1,U
    STB     VN
    LDB     1,U
    STB     VS
    LDB     -COLONNE_T,U
    STB     VO
    LDB     COLONNE_T,U
    STB     VE
    JSR     Calc_Case
    PSHS    D
    LDB     Rang                    ; adresse : 80 r + c
    LDA     #80
    MUL
    ADDB    Col
    ADCA    #0
    JSR     Cel_Adr
    STX     Tmp
    PULS    D
    JSR     Ajoute
    LEAU    1,U
    INC     Rang
    LDA     Rang
    CMPA    #30
    BLO     PC_Case
    JMP     Garees_Colonne
; Ajoute : D = glyphe:attribut, Tmp = adresse VRAM -> une entrée de Liste.
; Préserve X, Y, U.
Ajoute:
    PSHS    D,X
    LDB     LsN
    LDA     #4
    MUL
    LDX     #Liste
    LEAX    D,X
    LDD     Tmp
    STD     ,X
    PULS    D
    STD     2,X
    INC     LsN
    PULS    X,PC

; Cel_Adr : D = décalage depuis le départ (en cases) -> X = adresse VRAM
Cel_Adr:
    ADDD    Debut
    ANDA    #$0F
    LSLB
    ROLA
    ADDD    #VRAM_BASE
    TFR     D,X
    RTS

; Case_Ecran : B = colonne (39 ou 40) de la rangée 15 -> une entrée : la
; voiture si elle couvre cette case, sinon la tuile.
Case_Ecran:
    STB     Col
    CLRA
    ADDD    #CENTRE_R*80
    JSR     Cel_Adr
    STX     Tmp
    LDB     Col                     ; mx = PosX + colonne - 40
    CLRA
    ADDD    PosX
    SUBD    #CENTRE_C
    TFR     D,X
    LDY     PosY
    JSR     Tuile
    PSHS    D                       ; la tuile
    TST     Niv                     ; au sol, sous un tablier : cachée
    BNE     CE_Voit
    JSR     SorteC
    LDU     #Tablier
    TST     B,U
    BNE     CE_Tuile
CE_Voit:
    TST     Pied
    BEQ     CE_Auto
    LDA     Col                     ; à pied : le piéton en colonne 40
    CMPA    #CENTRE_C
    BNE     CE_Tuile
    LDA     #PIED_COUL
    STA     TT2
    LDA     #G_PIETONNE
    BRA     CE_Pose
CE_Auto:
    LDA     VCoul
    STA     TT2
    LDB     Dir                     ; VoitG : 2 octets par direction
    ASLB
    ADDB    Col
    SUBB    #CENTRE_C-1
    LDX     #VoitG
    LDA     B,X
    BEQ     CE_Tuile
CE_Pose:
    LEAS    2,S                     ; sur le fond de la sorte de la case, sa couleur
    LDB     TS
    LDX     #Attr
    LDB     B,X
    ANDB    #$70
    ORB     #VOIT_ATTR
    ORB     TT2
    JMP     Ajoute
CE_Tuile:
    PULS    D
    JMP     Ajoute

; Prep_Voiture : les deux cases de la voiture (colonnes 39 et 40).
Prep_Voiture:
    LDB     #CENTRE_C-1
    BSR     Case_Ecran
    LDB     #CENTRE_C
    BRA     Case_Ecran

; -------------------------------------------------------------------
; Preparer : après Pas. Un pas fait : la rangée ou la colonne qui entre,
; les deux cases quittées rendues à la carte, la voiture, le départ. Un
; virage sur place : la voiture.
; -------------------------------------------------------------------
Preparer:
    JSR     Fait_Proches            ; (Bascule a pu changer la liste)
    LDA     Mx                      ; un pas : le butin, la planque, la police
    ORA     My
    BEQ     Pp_Bilan
    JSR     Bilan
Pp_Bilan:
    TST     Mx
    BNE     Pp_Pas
    TST     My
    BNE     Pp_Pas
    TST     Tourne
    BEQ     Pp_Fin
    JSR     Prep_Voiture
    BRA     Pp_Fin
Pp_Pas:
    LDA     Mx                      ; un pas en x : la colonne qui entre
    BEQ     Pp_Rang
    BMI     Pp_Ouest
    LDD     PosX                    ; est : colonne 79 = PosX + 39
    ADDD    #79-CENTRE_C
    TFR     D,X
    LDB     #79
    JSR     Prep_Colonne
    BRA     Pp_Rang
Pp_Ouest:
    LDD     PosX                    ; ouest : colonne 0 = PosX - 40
    SUBD    #CENTRE_C
    TFR     D,X
    CLRB
    JSR     Prep_Colonne
Pp_Rang:
    LDA     My                      ; un pas en y : la rangée qui entre
    BEQ     Pp_Quitte
    BMI     Pp_Nord
    LDB     #29
    JSR     Prep_Rangee
    BRA     Pp_Quitte
Pp_Nord:
    CLRB
    JSR     Prep_Rangee
Pp_Quitte:                          ; les cases quittées : (15 - My, 39/40 - Mx)
    LDB     #CENTRE_C-1
    JSR     Quitte
    LDB     #CENTRE_C
    JSR     Quitte
    JSR     Prep_Voiture
    LDA     #1
    STA     CrtcN
Pp_Fin:
    JMP     Plaque

; -------------------------------------------------------------------
; Plaque : le nom de la rue (la grille des rues, en RUES_ADR : un octet
; par bloc de 4 x 4 cases) ; un bloc à 0 garde la plaque. Puis ce que le
; pas a fait de l'ancienne : vers le sud, elle est montée en rangée 28 (ses
; cases rendues à la carte) ; vers le nord, sortie de l'écran ; de côté,
; une case de son bout à rendre (toute l'ancienne si le nom change) ; sans
; pas, rien, ou l'ancienne entière si le nom change. Enfin la plaque à sa
; place (SegC), après un pas ou un changement.
; -------------------------------------------------------------------
Plaque:
    LDA     PlqC0
    STA     AncC0
    LDA     PlqL
    STA     AncL
    CLR     Change
    LDD     PosY                    ; RUES_ADR + 128 (y / 4) + x / 4
    LSRA
    RORB
    LSRA
    RORB
    LDA     #RUES_L
    MUL
    PSHS    D
    LDD     PosX
    LSRA
    RORB
    LSRA
    RORB
    ADDD    ,S++
    ADDD    #RUES_ADR
    TFR     D,X
    LDB     ,X
    BEQ     Pq_Sig
    STB     PlqNum                  ; la rue du bloc
Pq_Sig:
    CLR     PqF                     ; la flèche (en jeu)
    LDA     Etape
    CMPA    #E_ARRETE
    BHS     Pq_Comp
    JSR     Fleche
    STA     PqF
Pq_Comp:
    LDA     PlqNum                  ; la plaque change avec la rue, la
    CMPA    SigNum                  ; flèche ou l'étape
    BNE     Pq_Neuf
    LDA     PqF
    CMPA    SigF
    BNE     Pq_Neuf
    LDA     Etape
    CMPA    SigE
    BEQ     Pq_Suite
Pq_Neuf:
    LDA     PlqNum
    STA     SigNum
    LDA     PqF
    STA     SigF
    LDA     Etape
    STA     SigE
    INC     Change
    JSR     Plq_Texte
Pq_Suite:
    TST     AncL
    LBEQ    Pq_Dessin
    LDA     My
    LBMI    Pq_Dessin               ; vers le nord : l'ancienne est sortie
    BNE     Pq_Sud
    LDA     Mx
    BEQ     Pq_Immobile
    BMI     Pq_Ouest
    LDA     AncC0                   ; est : décalée d'une case à gauche
    DECA
    TST     Change
    BEQ     Pq_Une                  ; la case de son début
    BRA     Pq_Tout29
Pq_Ouest:
    LDA     AncC0                   ; ouest : décalée d'une case à droite
    TST     Change
    BEQ     Pq_UneO
    INCA
    BRA     Pq_Tout29
Pq_UneO:
    ADDA    AncL                    ; la case qui suit son bout
    BRA     Pq_Une
Pq_Immobile:
    TST     Change
    LBEQ    Pq_Fin
    LDA     AncL                    ; la même place : rien à rendre à la carte
    CMPA    PlqL
    BNE     Pq_Immo2
    LDA     AncC0
    CMPA    PlqC0
    LBEQ    Pq_Dessin
Pq_Immo2:
    LDA     AncC0
Pq_Tout29:
    LDB     #PLQ_R
    BRA     Pq_Seg
Pq_Sud:                             ; vers le sud : montée en rangée 28 (et
    LDA     AncC0                   ; décalée de Mx)
    SUBA    Mx
    LDB     #PLQ_R-1
Pq_Seg:
    PSHS    A
    LDA     AncL
    STA     SgN
    PULS    A
    LDU     #SegB
    LDX     #RowBuf2
    JSR     Prep_Seg
    BRA     Pq_Dessin
Pq_Une:                             ; une case de la rangée 29, la tuile
    STA     Col
    LDB     #PLQ_R
    LDA     #80
    MUL
    ADDB    Col
    ADCA    #0
    JSR     Cel_Adr
    STX     Tmp
    LDB     Col
    CLRA
    ADDD    PosX
    SUBD    #CENTRE_C
    TFR     D,X
    LDD     PosY
    ADDD    #PLQ_R-CENTRE_R
    TFR     D,Y
    JSR     Tuile
    JSR     Ajoute
Pq_Dessin:
    LDA     PlqL
    BEQ     Pq_Fin
    TST     Mx
    BNE     Pq_Pose
    TST     My
    BNE     Pq_Pose
    TST     Change
    BEQ     Pq_Fin
Pq_Pose:
    LDA     PlqC0
    STA     SgC
    LDA     #PLQ_R
    STA     SgR
    LDA     PlqL
    STA     SgN
    LDU     #SegC
    STU     SgD
    LDX     #PlqTxt
    STX     7,U
    JMP     Seg_Pose
Pq_Fin:
    RTS

; Plq_Texte : la plaque du nom n° PlqNum -> PlqTxt (glyphe:attribut, une
; espace de chaque côté), PlqL, PlqC0 = 40 - PlqL / 2.
Plq_Texte:
    LDY     #PlqTxt
    LDA     Etape
    CMPA    #E_ARRETE
    BLO     PT_Jeu
    LDX     #MsgArrete              ; la fin : le message
    CMPA    #E_ARRETE
    BEQ     PT_Msg
    LDX     #MsgGagne
PT_Msg:
    LDA     ,X+
    STA     PtAttr
    LDB     ,X+
    TFR     B,E
    ADDB    #2
    STB     PlqL
    LDA     #$20
    LDB     PtAttr
    STD     ,Y++
PT_MC:
    LDA     ,X+
    LDB     PtAttr
    STD     ,Y++
    DECE
    BNE     PT_MC
    BRA     PT_Fin
PT_Jeu:
    LDB     #PLQ_ATTR               ; en jeu : bleue (vol), rouge (fuite)
    CMPA    #E_VOL
    BEQ     PT_Att
    LDB     #PLQ_FUITE
PT_Att:
    STB     PtAttr
    LDA     PqF                     ; la flèche, une espace, le nom, une espace
    ADDA    #G_FLECHE
    ORB     #$80
    STD     ,Y++
    LDA     #$20
    LDB     PtAttr
    STD     ,Y++
    LDA     #3
    STA     PlqL
    LDB     PlqNum
    BEQ     PT_Fin
    DECB
    CLRA
    LSLB
    ROLA
    LDX     #Noms
    LDX     D,X
    LDB     ,X+                     ; la longueur
    TFR     B,E
    ADDB    #3
    STB     PlqL
PT_Car:
    LDA     ,X+
    LDB     PtAttr
    STD     ,Y++
    DECE
    BNE     PT_Car
PT_Fin:
    LDA     #$20
    LDB     PtAttr
    STD     ,Y++
    LDB     PlqL                    ; centrée : 40 - L / 2
    LSRB
    NEGB
    ADDB    #40
    STB     PlqC0
    RTS

; Fleche : A = la direction (0-7) de l'objectif (le butin en vol, la
; planque ensuite) ; osmcity.py, fleche_vers : dy compte 5 / 2.
Fleche:
    LDX     #Objets
    LDA     Etape
    CMPA    #E_VOL
    BEQ     Fl_Obj
    LEAX    8,X
Fl_Obj:
    LDD     ,X
    SUBD    PosX
    STD     FlDx
    LDD     2,X
    SUBD    PosY
    STD     FlDy
    BPL     Fl_Y
    COMA
    COMB
    ADDD    #1
Fl_Y:
    STD     Tmp2                    ; |dyw| = (5 |dy|) / 2
    ASLB
    ROLA
    ASLB
    ROLA
    ADDD    Tmp2
    LSRA
    RORB
    STD     FlAy
    LDD     FlDx
    BPL     Fl_X
    COMA
    COMB
    ADDD    #1
Fl_X:
    STD     FlAx
    LDD     FlAy                    ; |dx| > 2 |dyw| : est ou ouest
    ASLB
    ROLA
    CMPD    FlAx
    BHS     Fl_PasH
    LDA     #2
    TST     FlDx
    BPL     Fl_Fin
    LDA     #6
    RTS
Fl_PasH:
    LDD     FlAx                    ; |dyw| > 2 |dx| : nord ou sud
    ASLB
    ROLA
    CMPD    FlAy
    BHS     Fl_Biais
    LDA     #4
    TST     FlDy
    BPL     Fl_Fin
    CLRA
    RTS
Fl_Biais:
    LDD     FlDx                    ; en biais : dx > 0, dyw > 0 ?
    BLE     Fl_Ouest
    LDD     FlDy
    BLE     Fl_NE
    LDA     #3
    RTS
Fl_NE:
    LDA     #1
    RTS
Fl_Ouest:
    LDD     FlDy
    BLE     Fl_NO
    LDA     #5
    RTS
Fl_NO:
    LDA     #7
Fl_Fin:
    RTS

; Quitte : B = colonne (39, 40) de la voiture d'avant le pas -> la tuile
; de sa case, à sa place dans l'écran d'après le pas : 80 (15 - My) + col
; - Mx ; sur la carte : (PosX + col - 40 - Mx, PosY - My).
Quitte:
    STB     Col
    LDB     Mx
    SEX
    STD     Tmp2
    LDB     My
    SEX
    STD     Tmp3
    LDD     #CENTRE_R*80
    TST     My
    BEQ     Qu_Col
    BMI     Qu_Nord
    SUBD    #80
    BRA     Qu_Col
Qu_Nord:
    ADDD    #80
Qu_Col:
    ADDB    Col
    ADCA    #0
    SUBD    Tmp2
    JSR     Cel_Adr
    STX     Tmp
    LDB     Col
    CLRA
    ADDD    PosX
    SUBD    #CENTRE_C
    SUBD    Tmp2
    TFR     D,X
    LDD     PosY
    SUBD    Tmp3
    TFR     D,Y
    JSR     Tuile
    JMP     Ajoute
; -------------------------------------------------------------------
; Appliquer : juste après le signal de trame, ce que Preparer a laissé.
; -------------------------------------------------------------------
Appliquer:
    LDU     #SegA                   ; la rangée qui entre
    BSR     Ap_Seg
    LDU     #SegB                   ; des cases rendues à la carte
    BSR     Ap_Seg
Ap_Liste:
    LDE     LsN
    BEQ     Ap_Crtc
    CLR     LsN
    LDU     #Liste
Ap_Entree:
    LDX     ,U++
    LDD     ,U++
    STD     ,X
    DECE
    BNE     Ap_Entree
Ap_Crtc:
    LDU     #SegC                   ; la plaque, par-dessus
    BSR     Ap_Seg
    TST     CrtcN
    BEQ     Ap_Fin
    CLR     CrtcN
    LDD     Debut                   ; R12/R13 = départ - 1 (le retard du
    SUBD    #1                      ; sérialiseur, comme le BIOS : $FFFF = 0)
    ANDA    #$3F
    PSHS    CC
    ORCC    #%01010000              ; (l'IRQ choisit aussi un registre)
    PSHS    B
    LDB     #12
    STB     CRTC_RS
    STA     CRTC_DATA
    LDB     #13
    STB     CRTC_RS
    PULS    B
    STB     CRTC_DATA
    PULS    CC
Ap_Fin:
    RTS
Ap_Seg:
    TST     ,U
    BEQ     AS_Rien
    CLR     ,U
    LDX     7,U
    LDY     1,U
    LDW     3,U
    TFM     X+,Y+
    LDW     5,U
    BEQ     AS_Rien
    LDY     #VRAM_BASE
    TFM     X+,Y+
AS_Rien:
    RTS

; Peut : A = direction -> C = 1 si la voiture ne peut pas y tourner : la
; case voisine (en biais : l'une des deux voisines d'axe) ne l'accepte pas
; (osmcity.py, Jeu.peut). Détruit D, X, Y, U, W.
Peut:
    TFR     A,B
    LDX     #DX8
    LDA     B,X
    STA     PdX
    LDX     #DY8
    LDA     B,X
    STA     PdY
    TST     PdX
    BEQ     Pe_Axe
    TST     PdY
    BEQ     Pe_Axe
    LDX     PosX                    ; en biais : la voisine en x...
    LDB     PdX
    SEX
    LEAX    D,X
    LDY     PosY
    JSR     Passe
    BCC     Pe_Oui
    LDX     PosX                    ; ... ou celle en y
    LDY     PosY
    LDB     PdY
    SEX
    LEAY    D,Y
    JMP     Passe
Pe_Axe:
    LDX     PosX
    LDB     PdX
    SEX
    LEAX    D,X
    LDY     PosY
    LDB     PdY
    SEX
    LEAY    D,Y
    JMP     Passe
Pe_Oui:
    RTS
; Passe : X, Y = la case visée (voisine de PosX, PosY), Niv = l'étage ->
; C = 1 si la voiture n'y va pas, sinon NivN = son étage d'arrivée
; (osmcity.py, passe). Sur un tablier : depuis un tablier (étage 1) ou une
; rampe (on monte) ; au sol, seul SOUS_PONT se traverse (dessous) ; du
; tablier on ne descend que sur une rampe. Préserve X, Y. Détruit D, U, W.
Passe:
    CLR     OcSauf
    CLR     OcSauf+1
    JSR     Occupe                  ; une voiture garée : non
    LBCS    Pss_Non
    JSR     SorteC
    LDU     #Bloque
    TST     B,U
    BNE     Pss_Non
    LDU     #Tablier
    TST     B,U
    BEQ     Pss_Sol
    TST     Niv                     ; vers un tablier
    BNE     Pss_Un
    PSHS    B,X,Y
    LDX     PosX
    LDY     PosY
    JSR     SorteC
    CMPB    #S_RAMPE
    PULS    B,X,Y                   ; (PULS garde les drapeaux)
    BEQ     Pss_Un                  ; depuis une rampe : on monte
    CMPB    #S_SOUS_PONT
    BEQ     Pss_Zero                ; dessous
Pss_Non:
    ORCC    #1
    RTS
Pss_Sol:
    TST     Niv
    BEQ     Pss_Zero
    CMPB    #S_RAMPE                ; du tablier : seulement sur une rampe
    BNE     Pss_Non
Pss_Zero:
    CLR     NivN
    ANDCC   #$FE
    RTS
Pss_Un:
    LDA     #1
    STA     NivN
    ANDCC   #$FE
    RTS

; -------------------------------------------------------------------
; Pas : une trame de conduite (osmcity.py, Jeu.conduite). Mx, My = le pas
; fait (-1, 0, +1), Tourne <> 0 : la direction a changé. 8 directions ;
; deux avances, Ax (en x) et Ay (en y, x 107 / 256) ; en biais, chaque axe
; reçoit v x DIAG / 256. En biais, un côté bloqué : la voiture glisse ;
; les deux, ou tout droit contre un mur : arrêt net.
; -------------------------------------------------------------------
Pas:
    JSR     Fait_Proches
    CLR     Mx
    CLR     My
    CLR     Tourne
    CLR     Bloq
    CLR     Fige
    LDA     Etape                   ; la partie finie : Espace en relance une
    CMPA    #E_ARRETE
    BLO     Pa_Jeu
    LDA     #1                      ; (ni circulation ni police cette trame)
    STA     Fige
    TST     KeyEsp
    BEQ     Pa_Finie
    CLR     KeyEsp
    JSR     Nouvelle
Pa_Finie:
    CLR     Vit
    RTS
Pa_Jeu:
    TST     KeyEsp                  ; Espace : sortir, ou entrer
    BEQ     Pa_Pied
    CLR     KeyEsp
    JMP     Bascule
Pa_Pied:
    TST     Pied
    LBNE    Marche
    JSR     Voulu
    STA     Veut
    BPL     Pa_Voulu
    LDA     Vit                     ; aucune flèche : on roule sur l'élan
    BEQ     Pa_Terrain
    DECA
    STA     Vit
    BRA     Pa_Terrain
Pa_Voulu:
    CMPA    Dir
    BNE     Pa_Autre
    LDA     Vit                     ; tout droit : on accélère
    ADDA    #ACCEL
    CMPA    #VMAX
    BLS     Pa_Vmax
    LDA     #VMAX
Pa_Vmax:
    STA     Vit
    BRA     Pa_Terrain
Pa_Autre:
    LDB     Dir
    ADDB    #4
    ANDB    #7
    PSHS    B
    CMPA    ,S+
    BNE     Pa_Cote
    LDA     Vit                     ; l'inverse : on freine, puis demi-tour
    BEQ     Pa_Vire
    SUBA    #FREIN
    BCC     Pa_Frein
    CLRA
Pa_Frein:
    STA     Vit
    BRA     Pa_Terrain
Pa_Cote:
    TST     Vit                     ; de côté : arrêté, ou la rue le permet
    BEQ     Pa_Tourne
    LDA     Veut
    JSR     Peut
    BCS     Pa_Terrain
Pa_Tourne:
    CLR     Ax
    CLR     Ax+1
    CLR     Ay
    CLR     Ay+1
Pa_Vire:
    LDA     Veut
    STA     Dir
    INC     Tourne
Pa_Terrain:
    LDX     PosX                    ; hors de la chaussée : ralenti
    LDY     PosY
    JSR     SorteC
    LDU     #Lente
    TST     B,U
    BEQ     Pa_Avance
    LDA     Vit
    CMPA    #VLENT
    BLS     Pa_Avance
    SUBA    #RALENTI
    CMPA    #VLENT
    BHS     Pa_Lent
    LDA     #VLENT
Pa_Lent:
    STA     Vit
Pa_Avance:                          ; (Marche y vient aussi)
    LDA     Vit
    LBEQ    Pa_Fin
    LDB     Dir
    LDX     #DX8
    LDA     B,X
    STA     DxV
    LDX     #DY8
    LDA     B,X
    STA     DyV
    LDA     Vit                     ; w = v, ou v x DIAG / 256 en biais
    TST     DxV
    BEQ     Pa_W
    TST     DyV
    BEQ     Pa_W
    LDB     #DIAG
    MUL
Pa_W:
    STA     Wv
    TST     DxV                     ; en x
    BEQ     Pa_Y
    LDB     Wv
    CLRA
    ADDD    Ax
    CMPD    #PAS
    BLO     Pa_AxG
    SUBD    #PAS
    STD     Ax
    LDX     PosX
    LDB     DxV
    SEX
    LEAX    D,X
    LDY     PosY
    JSR     Passe
    BCS     Pa_BX
    STX     PosX
    LDA     NivN
    STA     Niv
    LDA     DxV
    STA     Mx
    BRA     Pa_Y
Pa_BX:
    CLR     Ax
    CLR     Ax+1
    INC     Bloq
    BRA     Pa_Y
Pa_AxG:
    STD     Ax
Pa_Y:
    TST     DyV                     ; en y : w x 107 / 256
    BEQ     Pa_Bilan
    LDA     Wv
    LDB     #107
    MUL
    TFR     A,B
    CLRA
    ADDD    Ay
    CMPD    #PAS
    BLO     Pa_AyG
    SUBD    #PAS
    STD     Ay
    LDX     PosX
    LDY     PosY
    LDB     DyV
    SEX
    LEAY    D,Y
    JSR     Passe
    BCS     Pa_BY
    STY     PosY
    LDA     NivN
    STA     Niv
    LDA     DyV
    STA     My
    BRA     Pa_Bilan
Pa_BY:
    CLR     Ay
    CLR     Ay+1
    INC     Bloq
    BRA     Pa_Bilan
Pa_AyG:
    STD     Ay
Pa_Bilan:
    LDA     Bloq                    ; bloqué : glisser (en biais, un côté),
    BEQ     Pa_PasSon               ; sinon arrêt net
    CMPA    #2
    BEQ     Pa_Stop
    TST     DxV
    BEQ     Pa_Stop
    TST     DyV
    BNE     Pa_PasSon
Pa_Stop:
    TST     Pied                    ; en voiture, assez vite : le choc
    BNE     Pa_Arret
    LDA     Vit
    CMPA    #CHOC_V
    BLO     Pa_Arret
    LDA     #EF_CHOC
    JSR     Effet
Pa_Arret:
    CLR     Vit
    CLR     Ax
    CLR     Ax+1
    CLR     Ay
    CLR     Ay+1
Pa_PasSon:
    TST     Pied                    ; à pied, un pas fait : son bruit
    BEQ     Pa_Bouge
    LDA     Mx
    ORA     My
    BEQ     Pa_Bouge
    LDA     #EF_PAS
    JSR     Effet
Pa_Bouge:
    LDB     Mx                      ; le départ : + Mx + 80 My
    SEX
    STD     Tmp2
    LDD     #0
    TST     My
    BEQ     Pa_D
    BMI     Pa_DN
    LDD     #80
    BRA     Pa_D
Pa_DN:
    LDD     #-80
Pa_D:
    ADDD    Tmp2
    ADDD    Debut
    ANDA    #$0F
    STD     Debut
    LDA     My                      ; nord / sud : une rangée de la carte
    BEQ     Pa_Fin                  ; entre dans l'anneau
    BMI     Pa_Nord
    LDD     PosY
    ADDD    #15
    JMP     Charge_Rangee
Pa_Nord:
    LDD     PosY
    SUBD    #16
    JMP     Charge_Rangee
Pa_Fin:
    RTS
; -------------------------------------------------------------------
; Marche : à pied (osmcity.py, Jeu.marche) : la direction de la flèche tout
; de suite, VPIED, sans élan ; puis le pas comme la voiture (Pa_Avance).
; -------------------------------------------------------------------
Marche:
    JSR     Voulu
    BPL     Ma_Fleche
    CLR     Vit                     ; rien : on s'arrête net
    CLR     Ax
    CLR     Ax+1
    CLR     Ay
    CLR     Ay+1
    RTS
Ma_Fleche:
    TST     Vit                     ; au départ, ou une autre direction :
    BEQ     Ma_Neuf                 ; le premier pas tout de suite
    CMPA    Dir
    BEQ     Ma_Va
Ma_Neuf:
    STA     Dir
    LDD     #PAS-1
    STD     Ax
    STD     Ay
Ma_Va:
    LDA     #VPIED
    STA     Vit
    JMP     Pa_Avance

; -------------------------------------------------------------------
; Bascule : Espace (osmcity.py, Jeu.bascule). En voiture (elle s'arrête net), avec
; une place libre dans Garees : le piéton sur la première case libre de
; Sorties (hors de la voiture), la voiture y reste garée. À pied : la
; première voiture garée dont la case (x, y) touche le piéton, au même
; étage : on la conduit. Le pas fait : Mx, My (Pa_Bouge).
; -------------------------------------------------------------------
Bascule:
    TST     Pied
    LBNE    Ba_Entre
    LDU     #Garees                 ; une place libre (en roulant aussi)
    LDB     #NGAREES
Ba_Place:
    TST     7,U
    BNE     Ba_Libre
    LEAU    8,U
    DECB
    BNE     Ba_Place
    RTS
Ba_Libre:
    STU     BaPlace
    LDX     #Sorties
    STX     BaPtr
    LDA     #8
    STA     BaN
Ba_Case:
    LDX     BaPtr
    LDA     ,X
    STA     Mx
    LDA     1,X
    STA     My
    CMPA    #0                      ; (-1, 0) : la voiture elle-même si
    BNE     Ba_Essai                ; elle a deux cases
    LDA     Mx
    CMPA    #-1
    BNE     Ba_Essai
    LDB     Dir
    ASLB
    LDX     #VoitG
    TST     B,X
    BNE     Ba_Suiv
Ba_Essai:
    LDB     Mx
    SEX
    ADDD    PosX
    TFR     D,X
    LDB     My
    SEX
    ADDD    PosY
    TFR     D,Y
    JSR     Passe
    BCC     Ba_Sort
Ba_Suiv:
    LDX     BaPtr
    LEAX    2,X
    STX     BaPtr
    DEC     BaN
    BNE     Ba_Case
    CLR     Mx
    CLR     My
Ba_Rien:
    RTS
Ba_Sort:
    LDU     BaPlace                 ; la voiture garée là
    LDD     PosX
    STD     ,U
    LDD     PosY
    STD     2,U
    LDA     Dir
    STA     4,U
    LDA     VCoul
    STA     5,U
    LDA     Niv
    STA     6,U
    CLR     7,U
    LDA     NivN
    STA     Niv
    LDA     #1
    STA     Pied
    CLR     Vit                     ; la voiture s'arrête net
    BRA     Ba_Pas
Ba_Entre:
    LDU     #Garees
    LDB     #NGAREES
Ba_Cherche:
    TST     7,U
    BNE     Ba_Autre
    LDA     6,U
    CMPA    Niv
    BNE     Ba_Autre
    PSHS    B
    LDD     ,U                      ; |x - PosX| <= 1
    SUBD    PosX
    ADDD    #1
    CMPD    #2
    BHI     Ba_Non
    LDD     2,U                     ; |y - PosY| <= 1
    SUBD    PosY
    ADDD    #1
    CMPD    #2
    BLS     Ba_Prend
Ba_Non:
    PULS    B
Ba_Autre:
    LEAU    8,U
    DECB
    BNE     Ba_Cherche
    RTS
Ba_Prend:
    PULS    B
    LDD     ,U
    SUBD    PosX
    STB     Mx
    LDD     2,U
    SUBD    PosY
    STB     My
    LDA     4,U
    STA     Dir
    LDA     5,U
    STA     VCoul
    LDA     #1
    STA     7,U
    CLR     Pied
    CLR     Vit
Ba_Pas:
    LDA     #EF_PORTE               ; la portière
    JSR     Effet
    CLR     Ax
    CLR     Ax+1
    CLR     Ay
    CLR     Ay+1
    LDB     Mx                      ; on se déplace d'une case
    SEX
    ADDD    PosX
    STD     PosX
    LDB     My
    SEX
    ADDD    PosY
    STD     PosY
    JMP     Pa_Bouge

; -------------------------------------------------------------------
; Les voitures garées (Garees : x 2, y 2, direction, couleur, étage,
; libre). Une voiture couvre (x, y), et (x - 1, y) si VoitG en a deux. Au
; sol sur un tablier : cachée.
; Occupe : X, Y -> C = 1 si une voiture garée couvre la case. Préserve X, Y.
; -------------------------------------------------------------------
Occupe:
    PSHS    D,U
    LDD     #Proches                ; (les entrées proches : Fait_Proches)
    STD     PrP
    LDA     PrN
    STA     GaN
Oc_Voit:
    LDU     [PrP]
    CMPY    2,U                     ; (la rangée d'abord : presque toutes
    BNE     Oc_Suiv                 ; les entrées s'arrêtent là)
    CMPU    OcSauf                  ; (celui qui se déplace)
    BEQ     Oc_Suiv
    TST     7,U
    BNE     Oc_Suiv
    CMPX    ,U
    BEQ     Oc_Oui
    TFR     X,D                     ; (x - 1, y) : si elle a deux cases
    ADDD    #1                      ; (LEAX toucherait Z)
    CMPD    ,U
    BNE     Oc_Suiv
    LDB     4,U
    ASLB
    PSHS    X
    LDX     #VoitG
    TST     B,X
    PULS    X
    BNE     Oc_Oui
Oc_Suiv:
    LDD     PrP
    ADDD    #2
    STD     PrP
    DEC     GaN
    BNE     Oc_Voit
    ANDCC   #$FE
    PULS    D,U,PC
Oc_Oui:
    ORCC    #1
    PULS    D,U,PC

; Fait_Proches : Proches (PrN pointeurs) = les voitures garées près du
; joueur (x à +-66, y à -17 .. +16 : tout ce qu'une trame peut toucher,
; la circulation comprise) puis toute la circulation (elle bouge pendant
; la trame). Occupe et les dessins ne parcourent qu'elles.
Fait_Proches:
    LDX     #Proches
    CLR     PrN
    LDU     #Garees
    LDA     #NGAREES
    STA     GaN
FP_G:
    TST     7,U
    BNE     FP_S
    LDD     ,U
    SUBD    PosX
    ADDD    #66
    CMPD    #132
    BHI     FP_S
    LDD     2,U
    SUBD    PosY
    ADDD    #17
    CMPD    #33
    BHI     FP_S
    STU     ,X++
    INC     PrN
FP_S:
    LEAU    8,U
    DEC     GaN
    BNE     FP_G
    LDU     #Mobiles
    LDA     #NFIN
    STA     GaN
FP_M:
    STU     ,X++
    INC     PrN
    LEAU    8,U
    DEC     GaN
    BNE     FP_M
    RTS

; Garee_Glyphe : U = une voiture, B = 0 (sa case x - 1) ou 1 (sa case x),
; A = l'attribut de la tuile, TS = la sorte de la case -> C = 0 et D =
; glyphe:attribut si elle s'y voit ; C = 1 sinon (pas de glyphe là, ou au
; sol sous un tablier). Préserve X, Y, U.
Garee_Glyphe:
    PSHS    X
    STA     GaA
    LDA     4,U
    ASLA
    PSHS    B
    ADDA    ,S+
    LDX     #VoitG
    LDA     A,X
    BEQ     GG_Non
    STA     GaG
    TST     6,U                     ; au sol, sur un tablier : cachée
    BNE     GG_Oui
    LDB     TS
    LDX     #Tablier
    TST     B,X
    BNE     GG_Non
GG_Oui:
    LDB     TS                      ; le fond : celui de la sorte de la case
    LDX     #Attr
    LDB     B,X
    ANDB    #$70
    ORB     #VOIT_ATTR
    ORB     5,U
    LDA     GaG
    ANDCC   #$FE
    PULS    X,PC
GG_Non:
    ORCC    #1
    PULS    X,PC

; Garee_Case : X, Y, TS, D = la tuile -> D = la voiture garée qui couvre
; la case, si elle s'y voit. Préserve X, Y, U.
Garee_Case:
    PSHS    D,U
    LDB     PrN                     ; (les entrées proches, de la dernière :
    LBEQ    GC_Fin                  ; la dernière dessinée l'emporte)
    STB     GaN
    DECB
    ASLB
    CLRA
    ADDD    #Proches
    STD     PrP
GC_Voit:
    LDU     [PrP]
    CMPY    2,U                     ; (la rangée d'abord)
    BNE     GC_Suiv
    TST     7,U
    BNE     GC_Suiv
    LDB     #1
    CMPX    ,U
    BEQ     GC_Ici
    PSHS    X
    TFR     X,D
    ADDD    #1
    CMPD    ,U
    PULS    X                       ; (PULS garde les drapeaux)
    BNE     GC_Suiv
    CLRB
GC_Ici:
    LDA     1,S                     ; l'attribut de la tuile
    JSR     Garee_Glyphe
    BCS     GC_Suiv
    STD     ,S
    PULS    D,U,PC
GC_Suiv:
    LDD     PrP
    SUBD    #2
    STD     PrP
    DEC     GaN
    BNE     GC_Voit
GC_Fin:
    PULS    D,U,PC

; Garees_Rangee : après la boucle d'une rangée (SgD : la fiche et son
; tampon, RX, RY, SgN, RowC) : les voitures garées de cette rangée.
Garees_Rangee:
    LDD     #Proches                ; (les entrées proches : Fait_Proches)
    STD     PrP
    LDA     PrN
    STA     GaN
GR_Voit:
    LDU     [PrP]
    TST     7,U
    BNE     GR_Suiv
    LDD     2,U
    CMPD    RY
    BNE     GR_Suiv
    CLR     GaK                     ; ses deux cases : x - 1 (k = 0), x (k = 1)
GR_Case:
    LDD     ,U                      ; i = x - 1 + k - RX
    SUBD    #1
    ADDB    GaK
    ADCA    #0
    SUBD    RX
    BMI     GR_K                    ; hors du segment
    TSTA
    BNE     GR_K
    CMPB    SgN
    BHS     GR_K
    STB     GaI
    LDX     #RowC+1                 ; la sorte de la case
    LDA     B,X
    STA     TS
    LDX     SgD                     ; la tuile : tampon + 2 i
    LDX     7,X
    ASLB
    ABX
    STX     GaP
    LDA     1,X
    LDB     GaK
    JSR     Garee_Glyphe
    BCS     GR_K
    LDX     GaP
    STD     ,X
GR_K:
    INC     GaK
    LDA     GaK
    CMPA    #2
    BLO     GR_Case
GR_Suiv:
    LDD     PrP
    ADDD    #2
    STD     PrP
    DEC     GaN
    BNE     GR_Voit
    RTS

; Garees_Colonne : après Prep_Colonne (CX, CY, LsCol, ColC) : les voitures
; garées de cette colonne (ses entrées dans Liste, rangée r = y - CY - 1).
Garees_Colonne:
    LDD     #Proches                ; (les entrées proches : Fait_Proches)
    STD     PrP
    LDA     PrN
    STA     GaN
GK_Voit:
    LDU     [PrP]
    TST     7,U
    BNE     GK_Suiv
    LDB     #1                      ; sa case x...
    LDX     ,U
    CMPX    CX
    BEQ     GK_Ici
    CLRB                            ; ... ou x - 1
    LEAX    -1,X
    CMPX    CX
    BNE     GK_Suiv
GK_Ici:
    STB     GaK
    LDD     2,U                     ; r = y - CY - 1, 0..29
    SUBD    CY
    SUBD    #1
    TSTA
    BNE     GK_Suiv
    CMPB    #30
    BHS     GK_Suiv
    STB     GaI
    LDX     #ColC+1
    LDA     B,X
    STA     TS
    LDA     LsCol                   ; l'entrée : Liste + 4 (LsCol + r) + 2
    ADDA    GaI
    LDB     #4
    MUL
    ADDD    #Liste+2
    TFR     D,X
    STX     GaP
    LDA     1,X
    LDB     GaK
    JSR     Garee_Glyphe
    BCS     GK_Suiv
    LDX     GaP
    STD     ,X
GK_Suiv:
    LDD     PrP
    ADDD    #2
    STD     PrP
    DEC     GaN
    BNE     GK_Voit
    RTS

; -------------------------------------------------------------------
; La circulation (osmcity.py, Jeu.population) : NMOB_V voitures puis des
; passants dans Mobiles (même format que Garees, juste après ; direction
; 8 = un passant). Une trame : la voiture TMob & 7, et (TMob impair) le
; passant NMOB_V + (TMob / 2) & 7 ; aucune quand l'écran défile (Mx, My :
; la trame est déjà chargée).
; -------------------------------------------------------------------
Population:
    TST     Fige                    ; la partie finie (ou relancée) : rien
    BNE     Po_Fin
    TST     Mx
    BNE     Po_Fin
    TST     My
    BNE     Po_Fin
    LDA     TMob
    ANDA    #7
    JSR     Tick
    LDA     TMob
    BITA    #1
    BEQ     Po_Police
    LSRA
    ANDA    #7
    ADDA    #NMOB_V
    JSR     Tick
Po_Police:
    LDA     TMob                    ; la police TMob & 3 (si < NPOLICE)
    ANDA    #3
    CMPA    #NPOLICE
    BHS     Po_Inc
    ADDA    #NMOB
    JSR     Tick
    LDA     Etape
    PSHS    A
    JSR     Bilan
    PULS    A
    CMPA    Etape                   ; l'étape a changé : la plaque tout de suite
    BEQ     Po_Inc
    JSR     Plaque
Po_Inc:
    INC     TMob
Po_Fin:
    RTS

; Alea : A = le hasard suivant (LFSR 8 bits, $B8). Préserve B, X, Y, U.
Alea:
    LDA     AleaS
    LSRA
    BCC     Al_Pose
    EORA    #$B8
Al_Pose:
    STA     AleaS
    RTS

; Tick : A = n° (0 .. NMOB - 1) -> elle réapparaît (absente ou trop loin),
; roule (une voiture) ou flâne (un passant).
Tick:
    STA     MobI
    LDB     #8
    MUL
    ADDD    #Mobiles
    TFR     D,U
    STU     MobU
    LDA     MobI
    CMPA    #NMOB
    LBHS    Police_Tk
    TST     7,U
    LBNE    Apparait
    LDD     ,U                      ; trop loin ?
    SUBD    PosX
    BPL     Tk_X
    COMA
    COMB
    ADDD    #1
Tk_X:
    CMPD    #MOB_LOIN_X
    LBGT    Apparait
    LDD     2,U                     ; hors des rangées de l'anneau ?
    SUBD    PosY
    CMPD    #MOB_HAUT
    LBLT    Apparait
    CMPD    #MOB_BAS
    LBGT    Apparait
    LDA     MobI
    CMPA    #NMOB
    LBHS    Police_Tick
    CMPA    #NMOB_V
    LBHS    Flane
Roule:
    LDX     #Phase                  ; une voiture : en vertical, une fois sur deux
    LDB     MobI
    LDA     B,X
    EORA    #1
    STA     B,X
    LDB     4,U
    BITB    #2
    BNE     Ro_Ordre
    TSTA
    LBNE    Tk_Fin
Ro_Ordre:
    JSR     Alea                    ; (osmcity.py, roule)
    STA     RoR
    LDA     4,U
    STA     RoD
    ADDA    #2
    ANDA    #7
    STA     RoDr
    ADDA    #4
    ANDA    #7
    STA     RoGa
    LDA     RoR                     ; un carrefour : tourner (au hasard)
    CMPA    #VIRAGE
    BHS     Ro_Serre
    LDB     RoDr
    BITA    #1
    BNE     Ro_V1
    LDB     RoGa
Ro_V1:
    STB     RoS
    JSR     Ouverture
    BCC     Ro_Serre
    LDA     RoS
    STA     EsD
    STA     EsG
    JSR     Essaie
    LBCC    Tk_Fin
Ro_Serre:
    LDB     RoDr                    ; serrer à droite : changer de voie en
    LDA     #1                      ; biais, dans une rue étroite (à droite :
    JSR     Ouverture_N             ; 1 à LARGE_V rangées, 1 à LARGE_H
    BCC     Ro_Droit                ; colonnes de chaussée)
    LDB     RoDr
    LDA     #LARGE_H+1
    BITB    #2
    BNE     Ro_L
    LDA     #LARGE_V+1
Ro_L:
    JSR     Ouverture_N
    BCS     Ro_Droit
    LDA     RoD
    STA     EsG
    INCA
    ANDA    #7
    STA     EsD
    JSR     Essaie
    LBCC    Garer
Ro_Droit:
    LDA     RoD                     ; tout droit
    STA     EsD
    STA     EsG
    JSR     Essaie
    LBCC    Garer
    CLR     MlK                     ; devant, de la chaussée : attendre
Ro_Dv:
    LDB     NewD
    ASLB
    ADDB    MlK
    LDX     #VoitG
    TST     B,X
    BEQ     Ro_DvS
    LDD     NewX
    SUBD    #1
    ADDB    MlK
    ADCA    #0
    TFR     D,X
    LDY     NewY
    JSR     Route_Connue
    BCC     Ro_Fin
Ro_DvS:
    INC     MlK
    LDA     MlK
    CMPA    #2
    BLO     Ro_Dv
    LBSR    Att_Plus                ; quelqu'un devant : attendre,
    CMPA    #ATT_DOUBLE             ; puis doubler en biais (gauche, droite),
    LBLS    Ro_Rts
    LDA     RoD
    STA     EsG
    ADDA    #7
    ANDA    #7
    STA     EsD
    JSR     Essaie
    LBCC    Ro_Rts
    LDA     RoD
    STA     EsG
    INCA
    ANDA    #7
    STA     EsD
    JSR     Essaie
    LBCC    Ro_Rts
    LDX     #Att                    ; puis faire demi-tour
    LDB     MobI
    LDA     B,X
    CMPA    #ATT_DEMI
    BLS     Ro_Coince
    LDA     RoD
    ADDA    #4
    ANDA    #7
    STA     EsD
    STA     EsG
    JSR     Essaie
    LBCC    Ro_Rts
    BRA     Ro_Coince
Ro_Fin:
    LDA     RoD                     ; la rue finie : un côté, l'autre, demi-tour
    ADDA    #4
    ANDA    #7
    STA     OrdT+2
    LDA     RoR                     ; (r & 2 : la droite d'abord)
    BITA    #2
    BNE     Ro_F2
    LDA     RoGa
    LDB     RoDr
    BRA     Ro_FC
Ro_F2:
    LDA     RoDr
    LDB     RoGa
Ro_FC:
    STD     OrdT
    CLR     OrdK
Ro_Essai:
    LDB     OrdK
    LDX     #OrdT
    LDA     B,X
    STA     EsD
    STA     EsG
    JSR     Essaie
    BCC     Ro_Rts
    INC     OrdK
    LDA     OrdK
    CMPA    #3
    BLO     Ro_Essai
    BSR     Att_Plus
Ro_Coince:
    LDX     #Att                    ; coincée (ATT_FIN) : se garer sur une
    LDB     MobI                    ; place, sinon disparaître hors de l'écran
    LDA     B,X
    CMPA    #ATT_FIN
    BLS     Ro_Rts
    CMPB    #NMOB_V
    BHS     Ro_Rts
    LDU     MobU
    LDX     ,U
    LDY     2,U
    JSR     SorteC
    CMPB    #S_PLACE
    BNE     Ro_Loin
    LDA     #$FF
    STA     RoR
    JMP     Garer
Ro_Loin:
    LDU     MobU
    LDD     ,U
    SUBD    PosX
    JSR     Abs_D
    CMPD    #41
    BGT     Ro_Part
    LDD     2,U
    SUBD    PosY
    JSR     Abs_D
    CMPD    #15
    BLE     Ro_Rts
Ro_Part:
    LDA     #1
    STA     7,U
    JMP     Fait_Proches
Ro_Rts:
    RTS

; Att_Plus : Att[MobI] + 1 (bloqué à 255) -> A.
Att_Plus:
    LDX     #Att
    LDB     MobI
    LDA     B,X
    INCA
    BEQ     AP_S
    STA     B,X
AP_S:
    LDA     B,X
    RTS
Tk_Fin:
    RTS
Flane:
    LDX     #PDir
    LDB     MobI
    LDA     B,X
    LDB     #$40
    JSR     Ordre
    CLR     OrdK
Fl_Essai:
    LDB     OrdK
    LDX     #OrdT
    LDA     B,X
    STA     EsD
    LDA     #8
    STA     EsG
    JSR     Essaie
    BCS     Fl_Suiv
    LDX     #PDir
    LDB     MobI
    LDA     EsD
    STA     B,X
    RTS
Fl_Suiv:
    INC     OrdK
    LDA     OrdK
    CMPA    #4
    BLO     Fl_Essai
    RTS

; Route_Connue : X, Y -> C = 1 sur la chaussée (MobRoute) dans les rangées
; de l'anneau. Préserve X, Y, U.
Route_Connue:
    TFR     Y,D
    SUBD    PosY
    CMPD    #MOB_HAUT
    BLT     RC_Non
    CMPD    #MOB_BAS
    BGT     RC_Non
    JSR     SorteC
    PSHS    U
    LDU     #MobRoute
    TST     B,U
    PULS    U
    BEQ     RC_Non
    ORCC    #1
    RTS
RC_Non:
    ANDCC   #$FE
    RTS

; Ouverture : B = un côté, MobU -> C = 1 si une rue en part (OUV_V
; rangées, OUV_H colonnes de chaussée).
; Ouverture_N : la même sur A cases ; Ouverture_XY : depuis X, Y.
Ouverture:
    LDA     #OUV_H
    BITB    #2
    BNE     Ouverture_N
    LDA     #OUV_V
Ouverture_N:
    LDU     MobU
    LDX     ,U
    LDY     2,U
    BRA     Ou_XYN
Ouverture_XY:
    LDA     #OUV_H
    BITB    #2
    BNE     Ou_XYN
    LDA     #OUV_V
Ou_XYN:
    STB     OuS
    STA     OuN
Ou_K:
    LDB     OuS
    PSHS    X
    LDX     #DX8
    LDB     B,X
    SEX
    ADDD    ,S++
    TFR     D,X
    LDB     OuS
    PSHS    X
    LDX     #DY8
    LDB     B,X
    PULS    X
    SEX
    PSHS    Y
    ADDD    ,S++
    TFR     D,Y
    BSR     Route_Connue
    BCC     Ou_Non
    DEC     OuN
    BNE     Ou_K
    ORCC    #1
Ou_Non:
    RTS

; Garer : après un pas (RoR) : une voiture de la circulation sur une
; place, un tirage >= GARER : elle prend la fiche d'une voiture garée
; hors de l'écran (|dx| > 41 ou |dy| > 16) ; sa place se libère.
Garer:
    LDA     MobI
    CMPA    #NMOB_V
    BHS     Ga_Fin
    LDA     RoR
    CMPA    #GARER
    BLO     Ga_Fin
    LDU     MobU
    LDX     ,U
    LDY     2,U
    JSR     SorteC
    CMPB    #S_PLACE
    BNE     Ga_Fin
    LDU     #Garees
    LDA     #NGAREES
    STA     GaN
Ga_G:
    TST     7,U
    BNE     Ga_S
    LDD     ,U
    SUBD    PosX
    JSR     Abs_D
    CMPD    #41
    BGT     Ga_Ici
    LDD     2,U
    SUBD    PosY
    JSR     Abs_D
    CMPD    #16
    BGT     Ga_Ici
Ga_S:
    LEAU    8,U
    DEC     GaN
    BNE     Ga_G
Ga_Fin:
    RTS
Ga_Ici:
    LDX     MobU
    LDW     #8
    TFM     X+,U+
    LDU     MobU
    LDA     #1
    STA     7,U
    JMP     Fait_Proches

; Ordre : A = la direction, B = le seuil -> OrdT : tout droit, un côté,
; l'autre, le demi-tour ; un tirage sous le seuil : les côtés d'abord.
Ordre:
    STA     OrdD
    STB     OrdS
    JSR     Alea
    STA     OrdR
    LDA     OrdD
    ADDA    #6
    ANDA    #7
    STA     OrdG
    LDA     OrdD
    ADDA    #2
    ANDA    #7
    STA     OrdDr
    LDA     OrdD
    ADDA    #4
    ANDA    #7
    STA     OrdB
    LDA     OrdR                    ; r & $80 : gauche d'abord
    BMI     Or_G
    LDA     OrdDr
    LDB     OrdG
    BRA     Or_C
Or_G:
    LDA     OrdG
    LDB     OrdDr
Or_C:
    STD     OrdC
    LDA     OrdR
    CMPA    OrdS
    BHS     Or_Droit
    LDD     OrdC                    ; tourner d'abord
    STD     OrdT
    LDA     OrdD
    LDB     OrdB
    STD     OrdT+2
    RTS
Or_Droit:
    LDA     OrdD
    LDB     OrdC
    STD     OrdT
    LDA     OrdC+1
    LDB     OrdB
    STD     OrdT+2
    RTS

; Essaie : EsD (la direction du pas), EsG (celle des cases et du glyphe),
; MobU -> C = 0 : avancé (et dessiné) ; C = 1 : pas permis.
Essaie:
    LDU     MobU
    LDB     EsD
    LDX     #DX8
    LDB     B,X
    SEX
    ADDD    ,U
    STD     NewX
    LDB     EsD
    LDX     #DY8
    LDB     B,X
    SEX
    ADDD    2,U
    STD     NewY
    LDA     EsG
    STA     NewD
    JSR     MobLibre
    BCS     Es_Non
    LDU     MobU
    LDD     ,U
    STD     OldX
    LDD     2,U
    STD     OldY
    LDA     4,U
    STA     OldD
    LDD     NewX
    STD     ,U
    LDD     NewY
    STD     2,U
    LDA     NewD
    STA     4,U
    LDX     #Att
    LDB     MobI
    CLR     B,X
    LDA     MobI                    ; la police : le gyrophare, en avançant
    CMPA    #NMOB
    BLO     Es_Des
    LDA     PCoul
    STA     5,U
Es_Des:
    JSR     Mob_Dessin
    ANDCC   #$FE
    RTS
Es_Non:
    ORCC    #1
    RTS

; MobLibre : NewX, NewY, NewD, MobI, MobU -> C = 1 si une de ses cases
; n'est pas permise (voiture : MobRoute ; passant : PIETON), est au joueur
; ou occupée par une autre entrée.
MobLibre:
    LDD     NewY                    ; dans les rangées de l'anneau seulement
    SUBD    PosY
    CMPD    #MOB_HAUT
    LBLT    Ml_Non
    CMPD    #MOB_BAS
    LBGT    Ml_Non
    CLR     MlK
Ml_K:
    LDB     NewD
    ASLB
    ADDB    MlK
    LDX     #VoitG
    TST     B,X
    BEQ     Ml_Suiv
    LDD     NewX
    SUBD    #1
    ADDB    MlK
    ADCA    #0
    TFR     D,X
    LDY     NewY
    JSR     SorteC
    LDA     MobI
    CMPA    #NMOB_V
    BLO     Ml_R
    CMPA    #NMOB
    BLO     Ml_P
Ml_R:
    LDU     #MobRoute
    TST     B,U
    BEQ     Ml_Non
    BRA     Ml_J
Ml_P:
    CMPB    #S_PIETON
    BNE     Ml_Non
Ml_J:
    JSR     Joueur_Ici
    BCS     Ml_Non
    LDD     MobU
    STD     OcSauf
    JSR     Occupe
    BCS     Ml_Non
Ml_Suiv:
    INC     MlK
    LDA     MlK
    CMPA    #2
    BLO     Ml_K
    CLR     OcSauf
    CLR     OcSauf+1
    ANDCC   #$FE
    RTS
Ml_Non:
    CLR     OcSauf
    CLR     OcSauf+1
    ORCC    #1
    RTS

; Joueur_Ici : X, Y -> C = 1 si c'est une case du joueur (le piéton, ou
; la voiture : (PosX, PosY), et (PosX - 1, PosY) si elle en a deux).
; Préserve X, Y.
Joueur_Ici:
    CMPY    PosY
    BNE     Ji_Non
    CMPX    PosX
    BEQ     Ji_Oui
    TST     Pied
    BNE     Ji_Non
    LDB     Dir
    ASLB
    PSHS    X
    LDX     #VoitG
    TST     B,X
    PULS    X                       ; (PULS garde les drapeaux)
    BEQ     Ji_Non
    TFR     X,D
    ADDD    #1
    CMPD    PosX
    BEQ     Ji_Oui
Ji_Non:
    ANDCC   #$FE
    RTS
Ji_Oui:
    ORCC    #1
    RTS

; Mob_Dessin : OldX/Y/D -> NewX/Y/D : les cases quittées (hors des
; nouvelles) rendues à la carte (Tuile), les nouvelles : le glyphe, le fond
; de la sorte, sa couleur (sous un tablier : la tuile). À l'écran seulement.
Mob_Dessin:
    CLR     MlK
Md_Vieux:
    LDB     OldD
    ASLB
    ADDB    MlK
    LDX     #VoitG
    TST     B,X
    BEQ     Md_VS
    LDD     OldX
    SUBD    #1
    ADDB    MlK
    ADCA    #0
    STD     CelX
    LDD     OldY
    STD     CelY
    JSR     Dans_Neuves
    BCS     Md_VS
    JSR     Cel_Ecran
    BCS     Md_VS
    STX     Tmp
    LDX     CelX
    LDY     CelY
    JSR     Tuile
    JSR     Ajoute
Md_VS:
    INC     MlK
    LDA     MlK
    CMPA    #2
    BLO     Md_Vieux
    CLR     MlK
Md_Neuf:
    LDB     NewD
    ASLB
    ADDB    MlK
    LDX     #VoitG
    LDA     B,X
    BEQ     Md_NS
    STA     MdG
    LDD     NewX
    SUBD    #1
    ADDB    MlK
    ADCA    #0
    STD     CelX
    LDD     NewY
    STD     CelY
    JSR     Cel_Ecran
    BCS     Md_NS
    STX     Tmp
    LDX     CelX
    LDY     CelY
    JSR     SorteC
    STB     TS
    LDU     #Tablier
    TST     B,U
    BEQ     Md_Pose
    JSR     Tuile                   ; sous un tablier : caché
    JSR     Ajoute
    BRA     Md_NS
Md_Pose:
    LDU     #Attr
    LDB     B,U
    ANDB    #$70
    ORB     #VOIT_ATTR
    LDU     MobU
    ORB     5,U
    LDA     MdG
    JSR     Ajoute
Md_NS:
    INC     MlK
    LDA     MlK
    CMPA    #2
    BLO     Md_Neuf
    RTS

; Dans_Neuves : CelX, CelY -> C = 1 si c'est une des nouvelles cases.
Dans_Neuves:
    LDD     CelY
    CMPD    NewY
    BNE     Dn_Non
    LDD     CelX
    CMPD    NewX
    BEQ     Dn_Oui
    ADDD    #1
    CMPD    NewX
    BNE     Dn_Non
    LDB     NewD
    ASLB
    LDX     #VoitG
    TST     B,X
    BEQ     Dn_Non
Dn_Oui:
    ORCC    #1
    RTS
Dn_Non:
    ANDCC   #$FE
    RTS

; Cel_Ecran : CelX, CelY -> X = son adresse VRAM ; C = 1 hors de l'écran
; (ou sous la plaque, qui reste par-dessus ; ou une case du joueur, alors
; redessinée par Case_Ecran : le joueur par-dessus, sinon la tuile).
Cel_Ecran:
    LDD     CelX
    SUBD    PosX
    ADDD    #CENTRE_C
    CMPD    #80
    BHS     Ce_Hors
    STB     CeC
    LDD     CelY
    SUBD    PosY
    ADDD    #CENTRE_R
    CMPD    #30
    BHS     Ce_Hors
    CMPB    #PLQ_R                  ; sous la plaque : elle reste par-dessus
    BNE     Ce_Ok
    LDA     CeC
    SUBA    PlqC0
    CMPA    PlqL
    BLO     Ce_Hors
    LDB     #PLQ_R
Ce_Ok:
    CMPB    #CENTRE_R               ; les cases du joueur : lui par-dessus
    BNE     Ce_Ok2                  ; (Case_Ecran), pas l'autre
    LDA     CeC
    SUBA    #CENTRE_C-1
    CMPA    #2
    BHS     Ce_Ok2
    LDB     CeC
    JSR     Case_Ecran
    BRA     Ce_Hors
Ce_Ok2:
    LDA     #80
    MUL
    ADDB    CeC
    ADCA    #0
    JSR     Cel_Adr
    ANDCC   #$FE
    RTS
Ce_Hors:
    ORCC    #1
    RTS

; Apparait : (4 tirages, toujours) juste hors de l'écran : à gauche, à
; droite, en haut ou en bas ; sur une case permise et libre, sinon rien
; (l'entrée reste libre). Rien à dessiner : hors de l'écran.
Apparait:
    JSR     Alea
    STA     ApA
    JSR     Alea
    STA     ApB
    JSR     Alea
    STA     ApC
    JSR     Alea
    STA     ApE
    LDU     MobU
    LDA     #1
    STA     7,U
    LDA     ApA
    ANDA    #3
    CMPA    #2
    BHS     Ap_HB
    LDB     ApB                     ; à gauche ou à droite
    ANDB    #7
    CLRA
    STD     Tmp2
    LDA     ApA
    ANDA    #3
    BNE     Ap_Dr
    LDD     PosX
    SUBD    #44
    SUBD    Tmp2
    BRA     Ap_Xok
Ap_Dr:
    LDD     PosX
    ADDD    #43
    ADDD    Tmp2
Ap_Xok:
    STD     NewX
    LDB     ApB
    LSRB
    LSRB
    LSRB
    ANDB    #31
    CLRA
    ADDD    PosY
    SUBD    #16
    STD     NewY
    BRA     Ap_D
Ap_HB:
    LDA     ApA                     ; en haut ou en bas : la rangée au bord
    ANDA    #3                      ; de l'anneau
    CMPA    #2
    BNE     Ap_Bas
    LDD     PosY
    ADDD    #MOB_HAUT
    BRA     Ap_Yok
Ap_Bas:
    LDD     PosY
    ADDD    #MOB_BAS
Ap_Yok:
    STD     NewY
    LDB     ApB
    LSRB
    CLRA
    ADDD    PosX
    SUBD    #64
    STD     NewX
Ap_D:
    LDA     MobI
    CMPA    #NMOB_V
    BLO     Ap_V
    CMPA    #NMOB
    BLO     Ap_P
Ap_V:
    LDA     ApC                     ; une voiture : dans le sens de la rue
    ANDA    #3                      ; (elle continue devant)
    ASLA
    STA     NewD
    LDA     #4
    STA     ApK
Ap_Sens:
    LDX     NewX
    LDY     NewY
    LDB     NewD
    JSR     Ouverture_XY
    BCS     Ap_Libre
    LDA     NewD
    ADDA    #2
    ANDA    #7
    STA     NewD
    DEC     ApK
    BNE     Ap_Sens
    RTS
Ap_P:
    LDA     #8
Ap_Dd:
    STA     NewD
Ap_Libre:
    JSR     MobLibre
    BCS     Ap_Rien
    LDU     MobU
    LDD     NewX
    STD     ,U
    LDD     NewY
    STD     2,U
    LDA     NewD
    STA     4,U
    LDA     ApE
    ANDA    #7
    LDX     #CoulMobV
    LDB     MobI
    CMPB    #NMOB_V
    BLO     Ap_C
    LDX     #CoulMobP
    CMPB    #NMOB
    BLO     Ap_C
    LDA     #COUL_POLICE
    BRA     Ap_C2
Ap_C:
    LDA     A,X
Ap_C2:
    STA     5,U
    CLR     6,U
    CLR     7,U
    LDX     #Phase
    LDB     MobI
    CLR     B,X
    LDA     ApC
    ANDA    #3
    ASLA
    LDX     #PDir
    STA     B,X
Ap_Rien:
    RTS

; -------------------------------------------------------------------
; Le son (osmcity.py, Jeu.son) : A le moteur (en voiture : période 1000 -
; 5 v, volume 8 + v / 32), B le klaxon (K tenue) ou le bruitage en cours
; (du bruit, volume - 2 par trame), C coupé. Tous les registres utiles
; écrits à chaque trame ; son coupé (son_coupe = $4D) : volumes à 0.
; -------------------------------------------------------------------
Son:
    TST     Pied
    BNE     So_Pied
    LDA     Vit
    LDB     #5
    MUL
    STD     Tmp2
    LDD     #1000
    SUBD    Tmp2
    STD     SnPa
    LDA     Vit
    LSRA
    LSRA
    LSRA
    LSRA
    LSRA
    ADDA    #8
    STA     SnVa
    BRA     So_B
So_Pied:
    LDD     #1000
    STD     SnPa
    CLR     SnVa
So_B:
    CLR     SnPb
    CLR     SnPb+1
    LDA     Etape                   ; (la partie finie : pas de klaxon)
    CMPA    #E_ARRETE
    BHS     So_Eff
    TST     KeyK
    BEQ     So_Eff
    LDA     TrameN                  ; le klaxon : deux tons
    BITA    #8
    BNE     So_K2
    LDD     #KLAX_A
    BRA     So_K3
So_K2:
    LDD     #KLAX_B
So_K3:
    STD     SnPb
    LDA     #R7_KLAX
    STA     SnR7
    LDA     #12
    STA     SnVb
    BRA     So_Muet
So_Eff:
    TST     BT
    BEQ     So_Rien
    LDA     #R7_BRUIT
    STA     SnR7
    LDA     BV
    STA     SnVb
    BRA     So_Muet
So_Rien:
    LDA     #R7_RIEN
    STA     SnR7
    CLR     SnVb
So_Muet:
    CLR     SnPc                    ; la sirène (canal C) : en fuite, une
    CLR     SnPc+1                  ; voiture de police en chasse
    CLR     SnVc
    LDA     Etape
    CMPA    #E_FUITE
    BNE     So_Coupe
    LDA     PMode
    ORA     PMode+1
    BEQ     So_Coupe
    LDA     TrameN
    BITA    #16
    BNE     So_S2
    LDD     #SIRENE_A
    BRA     So_S3
So_S2:
    LDD     #SIRENE_B
So_S3:
    STD     SnPc
    LDA     #10
    STA     SnVc
    LDA     SnR7
    ANDA    #$FB
    STA     SnR7
So_Coupe:
    LDA     >son_coupe
    CMPA    #$4D
    BNE     So_Ecrit
    CLR     SnVa
    CLR     SnVb
    CLR     SnVc
So_Ecrit:
    LDA     #0
    LDB     SnPa+1
    BSR     Ay_Ecrit
    LDA     #1
    LDB     SnPa
    BSR     Ay_Ecrit
    LDA     #2
    LDB     SnPb+1
    BSR     Ay_Ecrit
    LDA     #3
    LDB     SnPb
    BSR     Ay_Ecrit
    LDA     #4
    LDB     SnPc+1
    BSR     Ay_Ecrit
    LDA     #5
    LDB     SnPc
    BSR     Ay_Ecrit
    LDA     #6
    LDB     BP
    BSR     Ay_Ecrit
    LDA     #7
    LDB     SnR7
    BSR     Ay_Ecrit
    LDA     #8
    LDB     SnVa
    BSR     Ay_Ecrit
    LDA     #9
    LDB     SnVb
    BSR     Ay_Ecrit
    LDA     #10
    LDB     SnVc
    BSR     Ay_Ecrit
    TST     BT                      ; le bruitage s'éteint
    BEQ     So_Trame
    DEC     BT
    LDA     BV
    SUBA    #2
    BCC     So_V
    CLRA
So_V:
    STA     BV
So_Trame:
    INC     TrameN
    RTS

; Ay_Ecrit : A = registre, B = valeur.
Ay_Ecrit:
    STA     AY_ADR
    STB     AY_DATA
    RTS

; Effet : A = type (EF_PAS, EF_PORTE, EF_CHOC) -> le bruitage, si l'autre
; est fini ou pas plus fort. Préserve X, Y, U.
Effet:
    TST     BT
    BEQ     Ef_Pose
    CMPA    BTy
    BLO     Ef_Fin
Ef_Pose:
    STA     BTy
    PSHS    X
    LDX     #EffT-3
    LDB     #3
    MUL
    ABX
    LDA     ,X
    STA     BT
    LDA     1,X
    STA     BP
    LDA     2,X
    STA     BV
    PULS    X
Ef_Fin:
    RTS

; -------------------------------------------------------------------
; Le cache-cache (osmcity.py : nouvelle_partie, bilan, police_tick).
; -------------------------------------------------------------------
; Apparence : A = celle du joueur (8 à pied, sinon la couleur de sa voiture).
Apparence:
    LDA     #8
    TST     Pied
    BNE     Ap_Fin8
    LDA     VCoul
Ap_Fin8:
    RTS

; Abs_D : D = |D|.
Abs_D:
    TSTA
    BPL     AD_Fin
    COMA
    COMB
    ADDD    #1
AD_Fin:
    RTS

; Touche_Case : X, Y -> C = 1 si la case touche le joueur (8 voisines
; d'une de ses cases). Préserve X, Y.
Touche_Case:
    TFR     Y,D
    SUBD    PosY
    BSR     Abs_D
    CMPD    #1
    BHI     TC_Non
    TFR     X,D                     ; x - PosX dans -1 .. 1, ou -2 si la
    SUBD    PosX                    ; voiture a deux cases
    ADDD    #2
    CMPD    #3
    BHI     TC_Non
    CMPD    #0
    BNE     TC_Oui
    TST     Pied
    BNE     TC_Non
    LDB     Dir
    ASLB
    PSHS    X
    LDX     #VoitG
    TST     B,X
    PULS    X
    BEQ     TC_Non
TC_Oui:
    ORCC    #1
    RTS
TC_Non:
    ANDCC   #$FE
    RTS

; Touche_Entree : U = une entrée active -> C = 1 si une de ses cases
; touche le joueur.
Touche_Entree:
    CLR     TeK
TE_K:
    LDB     4,U
    ASLB
    ADDB    TeK
    LDX     #VoitG
    TST     B,X
    BEQ     TE_Suiv
    LDD     ,U
    SUBD    #1
    ADDB    TeK
    ADCA    #0
    TFR     D,X
    LDY     2,U
    BSR     Touche_Case
    BCS     TE_Oui
TE_Suiv:
    INC     TeK
    LDA     TeK
    CMPA    #2
    BLO     TE_K
    ANDCC   #$FE
    RTS
TE_Oui:
    RTS

; Redessine : U = une entrée -> ses cases (d'après x, y, direction)
; redessinées si elles sont à l'écran (Tuile : ce qu'il y a maintenant).
Redessine:
    CLR     TeK
RD_K:
    LDB     4,U
    ASLB
    ADDB    TeK
    LDX     #VoitG
    TST     B,X
    BEQ     RD_Suiv
    LDD     ,U
    SUBD    #1
    ADDB    TeK
    ADCA    #0
    STD     CelX
    LDD     2,U
    STD     CelY
    JSR     Cel_Ecran
    BCS     RD_Suiv
    STX     Tmp
    LDX     CelX
    LDY     CelY
    JSR     Tuile
    JSR     Ajoute
RD_Suiv:
    INC     TeK
    LDA     TeK
    CMPA    #2
    BLO     RD_K
    RTS

; Bilan : après un mouvement (osmcity.py, bilan) : le butin pris (la
; fuite, la police en chasse), la planque atteinte (gagné), une voiture
; de police au contact (arrêté).
Bilan:
    LDA     Etape
    CMPA    #E_VOL
    BNE     Bi_Fuite
    LDU     #Objets
    JSR     Touche_Entree
    BCC     Bi_Police
    LDA     #E_FUITE                ; le butin pris : l'alerte
    STA     Etape
    LDU     #Objets
    LDA     #1
    STA     7,U
    JSR     Redessine
    JSR     Apparence
    STA     Signal
    LDA     #CHASSE
    STA     PMode
    STA     PMode+1
    LDD     PosX
    STD     PCX
    STD     PCX+2
    LDD     PosY
    STD     PCY
    STD     PCY+2
    CLR     PPerdu
    CLR     PPerdu+1
    BRA     Bi_Police
Bi_Fuite:
    CMPA    #E_FUITE
    BNE     Bi_Fin
    LDU     #Objets+8
    JSR     Touche_Entree
    BCC     Bi_Police
    LDA     #E_GAGNE                ; la planque : gagné
    STA     Etape
    RTS
Bi_Police:
    LDA     Etape
    CMPA    #E_FUITE
    BNE     Bi_Fin
    LDU     #Mobiles+8*NMOB         ; une voiture de police au contact
    LDA     #NPOLICE
    STA     BiN
Bi_P:
    TST     7,U
    BNE     Bi_PS
    PSHS    U
    JSR     Touche_Entree
    PULS    U
    BCC     Bi_PS
    LDA     #E_ARRETE
    STA     Etape
    RTS
Bi_PS:
    LEAU    8,U
    DEC     BiN
    BNE     Bi_P
Bi_Fin:
    RTS

; Nouvelle : une partie : butin et planque tirés au sort (Cands ; la
; planque à DIST_PLANQUE au moins, 8 essais), la police en patrouille
; (absente : elle réapparaîtra), les cases changées redessinées.
Nouvelle:
    LDU     #Mobiles+8*NMOB         ; les anciennes cases : police, objets
    LDX     #NvVieux
    LDB     #NPOLICE+2
Nv_Garde:
    LDA     ,U
    STA     ,X+
    LDA     1,U
    STA     ,X+
    LDA     2,U
    STA     ,X+
    LDA     3,U
    STA     ,X+
    LDA     4,U
    STA     ,X+
    LEAU    8,U
    DECB
    BNE     Nv_Garde
    JSR     Alea                    ; le butin
    ANDA    #NCANDS-1
    LDB     #4
    MUL
    ADDD    #Cands
    TFR     D,X
    LDD     ,X
    STD     NvBx
    LDD     2,X
    STD     NvBy
    LDA     #8
    STA     NvN
Nv_Essai:
    JSR     Alea                    ; la planque
    ANDA    #NCANDS-1
    LDB     #4
    MUL
    ADDD    #Cands
    TFR     D,X
    LDD     ,X
    STD     NvPx
    LDD     2,X
    STD     NvPy
    LDD     NvPx
    SUBD    NvBx
    JSR     Abs_D
    STD     Tmp2
    LDD     NvPy
    SUBD    NvBy
    JSR     Abs_D
    ASLB
    ROLA
    ADDD    Tmp2
    CMPD    #DIST_PLANQUE
    BHS     Nv_Ok
    DEC     NvN
    BNE     Nv_Essai
Nv_Ok:
    LDU     #Objets
    LDD     NvBx
    STD     ,U
    LDD     NvBy
    STD     2,U
    LDD     #$0906                  ; direction 9, jaune
    STD     4,U
    CLR     6,U
    CLR     7,U
    LDD     NvPx
    STD     8,U
    LDD     NvPy
    STD     10,U
    LDD     #$0A02                  ; direction 10, vert
    STD     12,U
    CLR     14,U
    CLR     15,U
    LDA     #E_VOL
    STA     Etape
    LDX     #Poste                  ; la police au poste (devant la mairie)
    LDU     #Mobiles+8*NMOB
    LDW     #8*NPOLICE
    TFM     X+,U+
    CLR     PMode
    CLR     PMode+1
    LDX     #NvVieux                ; redessiner : les anciennes cases...
    LDA     #NPOLICE+2
    STA     NvN
Nv_Re:
    PSHS    X
    LDU     #NvTmp
    LDD     ,X
    STD     ,U
    LDD     2,X
    STD     2,U
    LDA     4,X
    STA     4,U
    JSR     Redessine
    PULS    X
    LEAX    5,X
    DEC     NvN
    BNE     Nv_Re
    LDU     #Mobiles+8*NMOB         ; ... la police, les nouveaux objets
    LDA     #NPOLICE+2
    STA     NvN
Nv_Neuf:
    PSHS    U
    JSR     Redessine
    PULS    U
    LEAU    8,U
    DEC     NvN
    BNE     Nv_Neuf
    RTS

; Police_Tk : garée tant qu'il n'y a pas de vol ; hors de la zone connue
; (ou hors des rues) : Aveugle ; sinon Police_Tick.
Police_Tk:
    LDA     Etape
    CMPA    #E_FUITE
    LBNE    Tk_Fin
    LDA     MobI
    SUBA    #NMOB
    STA     PoK
    LDX     ,U
    LDY     2,U
    JSR     Dans_Zone
    LDA     #1
    STA     AvDeh
    BCS     Aveugle
    CLR     AvDeh
    CLR     MlK                     ; ses cases : des rues ?
PK_K:
    LDU     MobU
    LDB     4,U
    ASLB
    ADDB    MlK
    LDX     #VoitG
    TST     B,X
    BEQ     PK_S
    LDD     ,U
    SUBD    #1
    ADDB    MlK
    ADCA    #0
    TFR     D,X
    LDY     2,U
    JSR     SorteC
    LDU     #MobRoute
    TST     B,U
    BEQ     Aveugle
PK_S:
    INC     MlK
    LDA     MlK
    CMPA    #2
    BLO     PK_K
    JMP     Police_Tick

; Dans_Zone : X, Y -> C = 1 hors de la zone connue (|x - PosX| > MOB_LOIN_X,
; ou hors des rangées de l'anneau). Préserve X, Y.
Dans_Zone:
    TFR     X,D
    SUBD    PosX
    JSR     Abs_D
    CMPD    #MOB_LOIN_X
    BGT     DZ_Non
    TFR     Y,D
    SUBD    PosY
    CMPD    #MOB_HAUT
    BLT     DZ_Non
    CMPD    #MOB_BAS
    BGT     DZ_Non
    ANDCC   #$FE
    RTS
DZ_Non:
    ORCC    #1
    RTS

; Aveugle (osmcity.py, aveugle) : un pas vers la cible sans carte (en
; vertical une fois sur deux) ; dans la zone seulement sur des cases
; libres (MobLibre), sinon de côté, sinon rien. AvDeh : partie de dehors.
Aveugle:
    LDX     #PMode
    LDB     PoK
    LDA     B,X
    CMPA    #CHASSE
    BNE     Av_1
    LDA     #RECHERCHE
    STA     B,X
    LDX     #PPerdu
    CLR     B,X
Av_1:
    LDX     #PCX
    LDB     PoK
    ASLB
    ABX
    LDD     ,X
    STD     PoTx
    LDX     #PCY
    LDB     PoK
    ASLB
    ABX
    LDD     ,X
    STD     PoTy
    LDX     #PMode
    LDB     PoK
    LDA     B,X
    CMPA    #RECHERCHE              ; arrivée à la cible : patrouille
    BNE     Av_2
    LDU     MobU
    LDD     PoTx
    SUBD    ,U
    JSR     Abs_D
    STD     Tmp2
    LDD     PoTy
    SUBD    2,U
    JSR     Abs_D
    ADDD    Tmp2
    CMPD    #1
    BGT     Av_2
    LDX     #PMode
    LDB     PoK
    CLR     B,X
Av_2:
    LDA     #COUL_POLICE            ; le gyrophare
    STA     PCoul
    LDX     #PMode
    LDB     PoK
    LDA     B,X
    BNE     Av_Gyro
    LDD     PosX                    ; patrouille : vers le joueur
    STD     PoTx
    LDD     PosY
    STD     PoTy
    BRA     Av_3
Av_Gyro:
    LDA     TrameN
    BITA    #8
    BEQ     Av_3
    LDA     #COUL_GYRO
    STA     PCoul
Av_3:
    LDX     #Phase
    LDB     MobI
    LDA     B,X
    EORA    #1
    STA     B,X
    STA     PoPh
    LDU     MobU
    LDA     #$FF                    ; dv : 4 (sud), 0 (nord), $FF
    LDX     PoTy
    CMPX    2,U
    BEQ     Av_V
    BLT     Av_N
    LDA     #4
    BRA     Av_V
Av_N:
    CLRA
Av_V:
    STA     AvDv
    LDA     #$FF                    ; dh : 2 (est), 6 (ouest), $FF
    LDX     PoTx
    CMPX    ,U
    BEQ     Av_H
    BLT     Av_O
    LDA     #2
    BRA     Av_H
Av_O:
    LDA     #6
Av_H:
    STA     AvDh
    LDA     AvDv
    BMI     Av_Hz
    TST     PoPh
    BNE     Av_D
    LDB     AvDh
    BMI     Av_D
Av_Hz:
    LDA     AvDh
    LBMI    Tk_Fin
Av_D:
    STA     NewD
    BSR     Av_Bloque
    BCC     Av_Va
    LDA     NewD                    ; de côté
    BITA    #2
    BNE     Av_CV
    LDA     AvDh                    ; (il allait en vertical)
    BPL     Av_C2
    JSR     Alea
    ANDA    #$80                    ; bit 7 : est, sinon ouest
    BEQ     Av_C6
    LDA     #2
    BRA     Av_C2
Av_C6:
    LDA     #6
    BRA     Av_C2
Av_CV:
    LDA     AvDv
    BPL     Av_C2
    JSR     Alea
    ANDA    #$80                    ; bit 7 : sud, sinon nord
    BEQ     Av_C2
    LDA     #4
Av_C2:
    STA     NewD
    BSR     Av_Bloque
    LBCS    Tk_Fin
Av_Va:
    LDU     MobU
    LDD     ,U
    STD     OldX
    LDD     2,U
    STD     OldY
    LDA     4,U
    STA     OldD
    LDD     NewX
    STD     ,U
    LDD     NewY
    STD     2,U
    LDA     NewD
    STA     4,U
    LDA     PCoul
    STA     5,U
    JMP     Mob_Dessin

; Av_Bloque : NewD -> NewX, NewY ; C = 1 si, venue de dehors, la case est
; dans la zone et pas libre.
Av_Bloque:
    LDU     MobU
    LDB     NewD
    LDX     #DX8
    LDB     B,X
    SEX
    ADDD    ,U
    STD     NewX
    LDB     NewD
    LDX     #DY8
    LDB     B,X
    SEX
    ADDD    2,U
    STD     NewY
    TST     AvDeh
    BEQ     AB_Non
    LDX     NewX
    LDY     NewY
    JSR     Dans_Zone
    BCS     AB_Non
    JMP     MobLibre
AB_Non:
    ANDCC   #$FE
    RTS

; Police_Tick : MobI (NMOB + k), MobU. Voir (en fuite), puis rouler :
; patrouille (Roule), sinon vers la cible (de N, E, S, O : la case permise
; la plus proche, |dx| + 2 |dy| ; en vertical une fois sur deux).
Police_Tick:
    LDA     MobI
    SUBA    #NMOB
    STA     PoK
    LDA     Etape
    CMPA    #E_FUITE
    LBNE    Pt_Mode
    LDU     MobU
    LDD     PosX
    SUBD    ,U
    JSR     Abs_D
    CMPD    #VUE_X
    BGT     Pt_PasVu
    STD     PoAx
    LDD     PosY
    SUBD    2,U
    JSR     Abs_D
    CMPD    #VUE_Y
    BGT     Pt_PasVu
    STD     PoAy
    TST     Niv                     ; caché sous un pont ?
    BNE     Pt_Visible
    LDX     PosX
    LDY     PosY
    JSR     SorteC
    CMPB    #S_SOUS_PONT
    BEQ     Pt_PasVu
Pt_Visible:
    JSR     Apparence               ; reconnu : le signalement, ou tout près
    CMPA    Signal
    BEQ     Pt_Vu
    LDD     PoAx
    CMPD    #PRES_X
    BGT     Pt_PasVu
    LDD     PoAy
    CMPD    #PRES_Y
    BGT     Pt_PasVu
Pt_Vu:
    LDX     #PMode
    LDB     PoK
    LDA     #CHASSE
    STA     B,X
    LDX     #PCX
    ASLB
    ABX
    LDD     PosX
    STD     ,X
    LDX     #PCY
    LDB     PoK
    ASLB
    ABX
    LDD     PosY
    STD     ,X
    LDX     #PPerdu
    LDB     PoK
    CLR     B,X
    JSR     Apparence
    STA     Signal
    BRA     Pt_Mode
Pt_PasVu:
    LDX     #PMode
    LDB     PoK
    LDA     B,X
    CMPA    #CHASSE
    BNE     Pt_Mode
    LDA     #RECHERCHE
    STA     B,X
    LDX     #PPerdu
    CLR     B,X
Pt_Mode:
    LDU     MobU                    ; (Roule attend l'entrée en U)
    LDA     #COUL_POLICE            ; le gyrophare (pris en avançant)
    STA     PCoul
    LDX     #PMode
    LDB     PoK
    LDA     B,X
    LBEQ    Roule                   ; patrouille : comme la circulation
    LDA     TrameN
    BITA    #8
    BEQ     Pt_Chasse
    LDA     #COUL_GYRO
    STA     PCoul
Pt_Chasse:
    LDX     #Phase
    LDB     MobI
    LDA     B,X
    EORA    #1
    STA     B,X
    STA     PoPh
    LDX     #PCX
    LDB     PoK
    ASLB
    ABX
    LDD     ,X
    STD     PoTx
    LDX     #PCY
    LDB     PoK
    ASLB
    ABX
    LDD     ,X
    STD     PoTy
    LDU     MobU                    ; le coût d'ici
    LDD     PoTx
    SUBD    ,U
    JSR     Abs_D
    STD     Tmp2
    LDD     PoTy
    SUBD    2,U
    JSR     Abs_D
    ASLB
    ROLA
    ADDD    Tmp2
    STD     PoCur
    CLR     PoN                     ; les directions permises (PoL)
    CLR     PoNd
Pt_Dir:
    LDA     PoNd
    BITA    #2
    BNE     Pt_Essai
    TST     PoPh                    ; en vertical : une fois sur deux
    BNE     Pt_Suiv
Pt_Essai:
    LDU     MobU
    LDB     PoNd
    LDX     #DX8
    LDB     B,X
    SEX
    ADDD    ,U
    STD     NewX
    LDB     PoNd
    LDX     #DY8
    LDB     B,X
    SEX
    ADDD    2,U
    STD     NewY
    LDA     PoNd
    STA     NewD
    JSR     MobLibre
    BCS     Pt_Suiv
    LDX     #PoL
    LDB     PoN
    LDA     PoNd
    STA     B,X
    INC     PoN
Pt_Suiv:
    LDA     PoNd
    ADDA    #2
    STA     PoNd
    CMPA    #8
    BLO     Pt_Dir
    LDU     MobU                    ; sans le demi-tour (sauf s'il est seul)
    LDA     4,U
    ADDA    #4
    ANDA    #7
    STA     PoRev
    CLR     PoM
    CLR     PoI
Pt_Av:
    LDA     PoI
    CMPA    PoN
    BHS     Pt_AvF
    LDX     #PoL
    LDB     PoI
    LDA     B,X
    CMPA    PoRev
    BEQ     Pt_AvS
    LDX     #PoA
    LDB     PoM
    STA     B,X
    INC     PoM
Pt_AvS:
    INC     PoI
    BRA     Pt_Av
Pt_AvF:
    TST     PoM
    BNE     Pt_Best
    LDA     PoN                     ; que le demi-tour : lui
    STA     PoM
    LDD     PoL
    STD     PoA
    LDD     PoL+2
    STD     PoA+2
Pt_Best:
    TST     PoM
    LBEQ    Pt_Rech
    LDD     #$7FFF                  ; la plus proche (la première)
    STD     PoCout
    CLR     PoI
Pt_BC:
    LDX     #PoA
    LDB     PoI
    LDB     B,X
    STB     PoNd
    LDX     #DX8
    LDB     B,X
    SEX
    LDU     MobU
    ADDD    ,U
    STD     Tmp3
    LDD     PoTx
    SUBD    Tmp3
    JSR     Abs_D
    STD     Tmp2
    LDB     PoNd
    LDX     #DY8
    LDB     B,X
    SEX
    ADDD    2,U
    STD     Tmp3
    LDD     PoTy
    SUBD    Tmp3
    JSR     Abs_D
    ASLB
    ROLA
    ADDD    Tmp2
    CMPD    PoCout
    BHS     Pt_BS
    STD     PoCout
    LDA     PoI
    STA     PoBest
Pt_BS:
    INC     PoI
    LDA     PoI
    CMPA    PoM
    BLO     Pt_BC
    LDD     PoCout                  ; elle ne rapproche pas : au hasard
    CMPD    PoCur
    BLO     Pt_Va
    JSR     Alea
Pt_Mod:
    CMPA    PoM
    BLO     Pt_ModF
    SUBA    PoM
    BRA     Pt_Mod
Pt_ModF:
    STA     PoBest
Pt_Va:
    LDX     #PoA
    LDB     PoBest
    LDA     B,X
    STA     EsD
    STA     EsG
    JSR     Essaie
Pt_Rech:
    LDX     #PMode
    LDB     PoK
    LDA     B,X
    CMPA    #RECHERCHE
    BNE     Pt_Fin
    LDX     #PPerdu
    INC     B,X
    LDA     B,X
    STA     PoP
    LDU     MobU
    LDD     PoTx
    SUBD    ,U
    JSR     Abs_D
    STD     Tmp2
    LDD     PoTy
    SUBD    2,U
    JSR     Abs_D
    ADDD    Tmp2
    CMPD    #1
    BLS     Pt_Patr
    LDA     PoP
    CMPA    #PERDU_MAX
    BLS     Pt_Fin
Pt_Patr:
    LDX     #PMode
    LDB     PoK
    CLR     B,X
Pt_Fin:
    RTS

; Voulu : A = la direction voulue (0-7, osmcity.py voulu_de), ou -1 :
; VouluT[8 haut + 4 droite + 2 bas + gauche].
Voulu:
    CLRB
    TST     KeyHaut
    BEQ     Vo_D
    ORB     #8
Vo_D:
    TST     KeyDroite
    BEQ     Vo_B
    ORB     #4
Vo_B:
    TST     KeyBas
    BEQ     Vo_G
    ORB     #2
Vo_G:
    TST     KeyGauche
    BEQ     Vo_T
    ORB     #1
Vo_T:
    LDX     #VouluT
    LDA     B,X
    RTS
; -------------------------------------------------------------------
; Clavier : octets PS/2 de la file de la NMI (comme DONJON39)
; -------------------------------------------------------------------
Lire_Clavier:
    LDB     >kbd_queue
    CMPB    >kbd_tete
    LBEQ    LC_Fin
    LDX     #kbd_buf
    LDA     B,X
    INCB
    ANDB    #15
    STB     >kbd_queue
    CMPA    #$E0
    BNE     LC_PasE0
    STA     KbE0
    BRA     Lire_Clavier
LC_PasE0:
    CMPA    #$F0
    BNE     LC_Code
    STA     KbRel
    BRA     Lire_Clavier
LC_Code:
    LDB     KbRel                   ; B <> 0 : relâchement
    LDX     #0
    TST     KbE0
    BEQ     LC_Normal
    CMPA    #$75                    ; E0 75 : haut
    BNE     LC_E1
    LDX     #KeyHaut
LC_E1:
    CMPA    #$72                    ; E0 72 : bas
    BNE     LC_E2
    LDX     #KeyBas
LC_E2:
    CMPA    #$6B                    ; E0 6B : gauche
    BNE     LC_E3
    LDX     #KeyGauche
LC_E3:
    CMPA    #$74                    ; E0 74 : droite
    BNE     LC_Tenue
    LDX     #KeyDroite
LC_Tenue:
    CMPX    #0
    BEQ     LC_Suite
    TSTB
    BEQ     LC_Appui
    CLR     ,X
    BRA     LC_Suite
LC_Appui:
    LDA     #1
    STA     ,X
    BRA     LC_Suite
LC_Normal:
    CMPA    #$42                    ; K : le klaxon, tenu
    BNE     LC_Esp
    TSTB
    BEQ     LC_KAppui
    CLR     KeyK
    BRA     LC_Suite
LC_KAppui:
    LDA     #1
    STA     KeyK
    BRA     LC_Suite
LC_Esp:
    CMPA    #$29                    ; Espace (à l'appui) : sortir / entrer
    BNE     LC_Echap
    TSTB
    BNE     LC_Suite
    LDA     #1
    STA     KeyEsp
    BRA     LC_Suite
LC_Echap:
    CMPA    #$76                    ; Echap
    BNE     LC_Suite
    TSTB
    BEQ     LC_EchapAppui
    LDA     #1
    STA     EscUp
    BRA     LC_Suite
LC_EchapAppui:
    LDA     #1
    STA     QuitReq
LC_Suite:
    CLR     KbE0
    CLR     KbRel
    LBRA    Lire_Clavier
LC_Fin:
    RTS

; Fenetre : attend le signal de trame (en lisant le clavier) ; au retour,
; il reste ~1700 cycles où la VRAM peut être touchée sans parasites.
Fenetre:
    LDD     >vsync_tick
    STD     TickVu
Fe_Boucle:
    JSR     Lire_Clavier
    LDD     >vsync_tick
    CMPD    TickVu
    BEQ     Fe_Boucle
    RTS

; -------------------------------------------------------------------
; Tables
; -------------------------------------------------------------------
DX8:        fcb 0,1,1,1,0,-1,-1,-1  ; dx, dy par direction (0 nord ... 7 nord-ouest)
DY8:        fcb -1,-1,0,1,1,1,0,-1
NomCarte:   fcn "OSMCITY.MAP"
NomRues:    fcn "OSMCITY.RUE"
DepartX:    fdb DEPART_X            ; (le vérificateur peut les changer)
DepartY:    fdb DEPART_Y

    include "osmcity_data.inc"

; -------------------------------------------------------------------
; Variables
; -------------------------------------------------------------------
PosX        rmb 2
OcSauf      rmb 2                   ; Occupe : l'entrée à ignorer (0 : aucune)
AleaS       rmb 1
TMob        rmb 1
MobI        rmb 1
MobU        rmb 2
OldX        rmb 2
OldY        rmb 2
OldD        rmb 1
NewX        rmb 2
NewY        rmb 2
NewD        rmb 1
EsD         rmb 1
EsG         rmb 1
MlK         rmb 1
MdG         rmb 1
CelX        rmb 2
CelY        rmb 2
CeC         rmb 1
ApA         rmb 1
ApB         rmb 1
ApC         rmb 1
ApE         rmb 1
OrdD        rmb 1
OrdS        rmb 1
OrdR        rmb 1
OrdG        rmb 1
OrdDr       rmb 1
OrdB        rmb 1
OrdC        rmb 2
OrdT        rmb 4
OrdK        rmb 1
Phase       rmb NMOB+NPOLICE
PDir        rmb NMOB+NPOLICE
Att         rmb NMOB+NPOLICE        ; voitures : les pas attendus (bloquées)
ApK         rmb 1
Proches     rmb 2*NTOUS
PrN         rmb 1
PrP         rmb 2
BT          rmb 1                   ; le bruitage : trames restantes, type,
BTy         rmb 1                   ; volume, période du bruit
BV          rmb 1
BP          rmb 1
TrameN      rmb 1
KeyK        rmb 1
SnPa        rmb 2
SnPb        rmb 2
SnR7        rmb 1
SnVa        rmb 1
SnVb        rmb 1
Etape       rmb 1                   ; E_VOL, E_FUITE, E_ARRETE, E_GAGNE
Signal      rmb 1
PCoul       rmb 1
PMode       rmb NPOLICE             ; PATROUILLE 0, CHASSE 1, RECHERCHE 2
PCX         rmb 2*NPOLICE
PCY         rmb 2*NPOLICE
PPerdu      rmb NPOLICE
PoK         rmb 1
PoAx        rmb 2
PoAy        rmb 2
PoPh        rmb 1
PoTx        rmb 2
PoTy        rmb 2
PoBest      rmb 1
PoCur       rmb 2
PoN         rmb 1
PoM         rmb 1
PoI         rmb 1
PoRev       rmb 1
PoL         rmb 4
PoA         rmb 4
Fige        rmb 1
RoR         rmb 1
RoD         rmb 1
RoDr        rmb 1
RoGa        rmb 1
RoS         rmb 1
OuS         rmb 1
OuN         rmb 1
AvDeh       rmb 1
AvDv        rmb 1
AvDh        rmb 1
PoCout      rmb 2
PoNd        rmb 1
PoP         rmb 1
TeK         rmb 1
BiN         rmb 1
NvVieux     rmb 5*(NPOLICE+2)
NvTmp       rmb 8
NvBx        rmb 2
NvBy        rmb 2
NvPx        rmb 2
NvPy        rmb 2
NvN         rmb 1
SigNum      rmb 1
SigF        rmb 1
SigE        rmb 1
PqF         rmb 1
PtAttr      rmb 1
FlDx        rmb 2
FlDy        rmb 2
FlAx        rmb 2
FlAy        rmb 2
SnPc        rmb 2
SnVc        rmb 1
Pied        rmb 1                   ; 1 : à pied
VCoul       rmb 1                   ; la couleur de la voiture conduite
KeyEsp      rmb 1
BaPlace     rmb 2
BaPtr       rmb 2
BaN         rmb 1
GaN         rmb 1
GaK         rmb 1
GaI         rmb 1
GaA         rmb 1
GaG         rmb 1
GaP         rmb 2
LsCol       rmb 1
Niv         rmb 1                   ; l'étage : 0 sol, 1 sur un pont
NivN        rmb 1
PosY        rmb 2
Dir         rmb 1
Vit         rmb 1
Ax          rmb 2
Ay          rmb 2
Wv          rmb 1
DxV         rmb 1
DyV         rmb 1
Mx          rmb 1
My          rmb 1
Bloq        rmb 1
PdX         rmb 1
PdY         rmb 1
Tmp2        rmb 2
Tmp3        rmb 2
VN          rmb 1
VE          rmb 1
VS          rmb 1
VO          rmb 1
XB          rmb 1
YB          rmb 1
CX          rmb 2
PcLent      rmb 1
PcPar       rmb 1
PcB0        rmb 1
CY          rmb 2
Debut       rmb 2
Veut        rmb 1
Bouge       rmb 1
Tourne      rmb 1
KeyHaut     rmb 1
KeyDroite   rmb 1
KeyBas      rmb 1
KeyGauche   rmb 1
KbE0        rmb 1
KbRel       rmb 1
QuitReq     rmb 1
EscUp       rmb 1
TickVu      rmb 2
Rang        rmb 1
Col         rmb 1
Compte      rmb 1
Ligne       rmb 2
CrY         rmb 2
Tmp         rmb 2
TS          rmb 1
TG          rmb 1
TT          rmb 1
TM          rmb 1
TBit        rmb 1
TV          rmb 1
TT2         rmb 1
NC          rmb 1
SegA        rmb 9
SegB        rmb 9
SegC        rmb 9
SgD         rmb 2
SgR         rmb 1
SgC         rmb 1
SgN         rmb 1
SgT         rmb 2
DN          rmb 1
PlqNum      rmb 1
PlqL        rmb 1
PlqC0       rmb 1
AncL        rmb 1
AncC0       rmb 1
Change      rmb 1
CrtcN       rmb 1
LsN         rmb 1
NomFmt      rmb 16
RX          rmb 2
RY          rmb 2
RXb         rmb 1
DCnt        rmb 1
RowN        rmb RANGEE_T
RowC        rmb RANGEE_T
RowS        rmb RANGEE_T
ColO        rmb COLONNE_T
ColC        rmb COLONNE_T
ColE        rmb COLONNE_T
Liste       rmb LISTE_MAX*4
RowBuf      rmb 160
RowBuf2     rmb 160
PlqTxt      rmb 80
SaveBas     rmb 800
FinCode
