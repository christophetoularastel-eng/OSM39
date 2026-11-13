; ===================================================================
; ZM_MEMOIRE.ASM - La mémoire de la Z-machine : cache de blocs en page 1
; ===================================================================
; Bloc b (256 octets) : en pages 2-3 à la position (b+1)*256 si b <
; BLOCS_RAM, sinon sur la carte (secteur LBA + b/2, moitié b&1). Au-delà
; de la fin du fichier : des zéros (comme le modèle).
;
; Lit8 / Lit16 : X = adresse (16 bits) -> A / D.
; Ecrit8 / Ecrit16 : X = adresse, A / D = valeur. Le créneau devient sale.
; Lit8_Txt : TxtAdr (24 bits) -> A.
; Toutes détruisent D, X, W (sauf le résultat) et préservent Y, U.
; ===================================================================

; -------------------------------------------------------------------
; Octet_PC : l'octet suivant du code -> A (préserve B, X, W)
; -------------------------------------------------------------------
Octet_PC:
    OCTET
    RTS

; PC_Suivant : Y est au bout du créneau : le bloc suivant (préserve B, X, W)
PC_Suivant:
    PSHS    B,X
    PSHSW
    LDD     PCBLOC
    ADDD    #1
    JSR     Pc_Bloc
    PULSW
    PULS    B,X,PC

; Pc_Bloc : D = bloc -> le code continue au début de son créneau
Pc_Bloc:
    STD     PCBLOC
    JSR     Bloc_Page
    CLRB
    TFR     D,Y
    INCA
    STD     PCFIN
    RTS

; Va_PC : PC = ZPC (24 bits)
Va_PC:
    LDD     ZPC
    BSR     Pc_Bloc
    TFR     Y,D
    LDB     ZPC+2
    TFR     D,Y
    RTS

; Lit_PC : ZPC = le PC (24 bits)
Lit_PC:
    TFR     Y,D
    SUBD    PCFIN
    ADDD    #256                    ; 0..256 (256 : début du bloc suivant)
    STB     ZPC+2
    TFR     A,B
    CLRA
    ADDD    PCBLOC
    STD     ZPC
    RTS

; -------------------------------------------------------------------
; Bloc_Page : D = bloc -> A = page de son créneau (chargé au besoin)
; -------------------------------------------------------------------
Bloc_Page:
    CMPD    #BLOCS_MAX
    BHS     BP_Hors
    STD     BpBloc
    EORB    #$80
    LDX     #CARTE
    LDA     D,X
    BNE     BP_Ok
    LDD     BpBloc
    JMP     Charge_Bloc
BP_Ok:
    RTS
BP_Hors:
    LDX     #TxtHors
    JMP     Erreur

Lit8:
    TFR     X,W
    TFR     X,D
    LDX     #CARTEC
    LDA     A,X
    BEQ     L8_Rate
    TFR     D,X
    LDA     ,X
    RTS
L8_Rate:
    TFR     E,B
    CLRA
    PSHSW
    JSR     Charge_Bloc
    PULSW
    TFR     W,X
    BRA     Lit8

Lit16:
    TFR     X,D
    CMPB    #$FF
    BEQ     L16_Deux
    TFR     X,W
    LDX     #CARTEC
    LDA     A,X
    BEQ     L16_Rate
    TFR     D,X
    LDD     ,X
    RTS
L16_Rate:
    TFR     E,B
    CLRA
    PSHSW
    JSR     Charge_Bloc
    PULSW
    TFR     W,X
    BRA     Lit16
L16_Deux:                           ; à cheval sur deux blocs
    PSHS    X
    BSR     Lit8
    PULS    X
    PSHS    A
    LEAX    1,X
    BSR     Lit8
    TFR     A,B
    PULS    A
    RTS

Ecrit8:
    PSHS    A
E8_Re:
    TFR     X,W
    TFR     X,D
    LDX     #CARTEC
    LDA     A,X
    BEQ     E8_Rate
    PSHS    D
    LDX     #CrenSale-CREN_HI
    STA     A,X                     ; créneau sale
    PULS    X
    PULS    A
    STA     ,X
    RTS
E8_Rate:
    TFR     E,B
    CLRA
    PSHSW
    JSR     Charge_Bloc
    PULSW
    TFR     W,X
    BRA     E8_Re

Ecrit16:
    PSHS    D
    TFR     X,D
    CMPB    #$FF
    BEQ     E16_Deux
E16_Re:
    TFR     X,W
    TFR     X,D
    LDX     #CARTEC
    LDA     A,X
    BEQ     E16_Rate
    PSHS    D
    LDX     #CrenSale-CREN_HI
    STA     A,X
    PULS    X
    PULS    D
    STD     ,X
    RTS
E16_Rate:
    TFR     E,B
    CLRA
    PSHSW
    JSR     Charge_Bloc
    PULSW
    TFR     W,X
    BRA     E16_Re
E16_Deux:
    PSHS    X
    LDA     2,S
    BSR     Ecrit8
    PULS    X
    LEAX    1,X
    PULS    D
    TFR     B,A
    BRA     Ecrit8

; Lit8_Txt : l'octet en TxtAdr (24 bits) -> A
Lit8_Txt:
    LDD     TxtAdr
    JSR     Bloc_Page
    LDB     TxtAdr+2
    TFR     D,X
    LDA     ,X
    RTS

; Inc_Txt : TxtAdr += 1 (préserve tout)
Inc_Txt:
    INC     TxtAdr+2
    BNE     IT_Fin
    INC     TxtAdr+1
    BNE     IT_Fin
    INC     TxtAdr
IT_Fin:
    RTS

; -------------------------------------------------------------------
; Charge_Bloc : D = bloc -> A = page du créneau qui le reçoit
; -------------------------------------------------------------------
Charge_Bloc:
    STD     CbBloc
    JSR     Victime
    STA     CbPage
    LDD     CbBloc                  ; la carte des blocs
    EORB    #$80
    LDX     #CARTE
    LEAX    D,X
    LDA     CbPage
    STA     ,X
    LDB     CbPage                  ; le créneau -> le bloc
    SUBB    #CREN_HI
    LSLB
    LDX     #CrenBloc
    ABX
    LDD     CbBloc
    STD     ,X
    CMPD    NBlocsRam
    BHS     CB_Carte
    JSR     Phys                    ; pages 2-3 : A = page, X = adresse
    PSHS    Y,U
    PSHS    A
    LDA     CbPage
    CLRB
    TFR     D,Y                     ; Y = le créneau
    PULS    A
    LDB     >current_page
    LDU     #256
    JSR     [table_function_ram+sys_FarRead]
    PULS    Y,U
    LDA     CbPage
    RTS
CB_Carte:
    CMPD    NBlocs
    BHS     CB_Zero
    JSR     Lit_Secteur_Bloc        ; SECTEUR = le secteur du bloc
    LDX     #SECTEUR
    LDA     CbBloc+1
    LSRA
    BCC     CB_Moitie
    LEAX    256,X
CB_Moitie:
    PSHS    Y
    LDA     CbPage
    CLRB
    TFR     D,Y
    LDW     #256
    TFM     X+,Y+
    PULS    Y
    JSR     Queue_Zero
    LDA     CbPage
    RTS
CB_Zero:
    PSHS    Y
    LDX     #ZeroOct
    LDA     CbPage
    CLRB
    TFR     D,Y
    LDW     #256
    TFM     X,Y+
    PULS    Y
    LDA     CbPage
    RTS

; Queue_Zero : le bloc CbBloc (dans le créneau CbPage) est-il le dernier,
; coupé par la fin du fichier ? Le reste : des zéros.
Queue_Zero:
    LDD     CbBloc
    ADDD    #1
    CMPD    NBlocs
    BNE     QZ_Fin
    LDB     InfoJeu+7               ; taille mod 256
    BEQ     QZ_Fin
    PSHS    Y
    LDA     CbPage
    TFR     D,Y
    NEGB                            ; 256 - reste
    CLRA
    TFR     D,W
    LDX     #ZeroOct
    TFM     X,Y+
    PULS    Y
QZ_Fin:
    RTS

; Lit_Secteur_Bloc : SECTEUR = le secteur du fichier qui contient CbBloc
Lit_Secteur_Bloc:
    LDD     CbBloc
    LSRA
    RORB
Lit_Secteur_N:                      ; D = numéro de secteur dans le fichier
    ADDD    InfoJeu+2
    STD     SecLBA+2
    LDD     InfoJeu
    ADCB    #0
    ADCA    #0
    STD     SecLBA
    PSHS    Y,U
    LDX     #SecLBA
    LDY     #SECTEUR
    JSR     [table_function_ram+sys_FS_ReadSector]
    PULS    Y,U
    BCS     LSB_Err
    RTS
LSB_Err:
    LDX     #TxtLecture
    JMP     Erreur

; Phys : D = bloc (< BLOCS_RAM) -> A = page (2 ou 3), X = adresse
Phys:
    INCB
    PSHS    B
    ANDB    #$7F
    TFR     B,A
    CLRB
    TFR     D,X
    LDA     #2
    TST     ,S+
    BPL     Ph_Fin
    INCA
Ph_Fin:
    RTS

; -------------------------------------------------------------------
; Victime : un créneau libre -> A = sa page. Tourniquet ; le créneau du
; code (PCFIN-256) est sauté ; un créneau sale est d'abord renvoyé.
; -------------------------------------------------------------------
Victime:
    LDB     VicIdx
Vi_Essai:
    TFR     B,A
    ADDA    #CREN_HI
    INCA
    CMPA    PCFIN
    BNE     Vi_Prend
    BSR     Vi_Suivant
    BRA     Vi_Essai
Vi_Prend:
    STB     ViIdx
    BSR     Vi_Suivant
    STB     VicIdx
    LDB     ViIdx
    LSLB
    LDX     #CrenBloc
    ABX
    LDD     ,X
    CMPD    #$FFFF
    BEQ     Vi_Libre
    STD     ViBloc
    LDD     #$FFFF
    STD     ,X
    LDD     ViBloc
    EORB    #$80
    LDX     #CARTE
    LEAX    D,X
    CLR     ,X
    LDX     #CrenSale
    LDB     ViIdx
    ABX
    TST     ,X
    BEQ     Vi_Libre
    CLR     ,X
    LDD     ViBloc
    CMPD    #BLOCS_RAM
    BHS     Vi_Libre
    LDA     ViIdx
    ADDA    #CREN_HI
    JSR     Renvoie
Vi_Libre:
    LDA     ViIdx
    ADDA    #CREN_HI
    RTS

; Vi_Suivant : B = le créneau suivant du tourniquet (les 0-2 sont épinglés)
Vi_Suivant:
    INCB
    CMPB    #NB_CRENEAUX
    BLO     VS_Fin
    LDB     #CREN_EPINGLES
VS_Fin:
    RTS

; Renvoie : A = page d'un créneau, D' = ViBloc : 256 octets vers les pages
Renvoie:
    PSHS    A
    LDD     ViBloc
    JSR     Phys                    ; A = page, X = adresse
    PSHS    Y,U
    TFR     X,Y                     ; destination
    LDB     4,S                     ; la page du créneau
    PSHS    A
    TFR     B,A
    CLRB
    TFR     D,X                     ; source
    PULS    A
    LDB     >current_page
    LDU     #256
    JSR     [table_function_ram+sys_FarWrite]
    PULS    Y,U
    PULS    A,PC

; -------------------------------------------------------------------
; Cache_Init : tout oublier (rien n'est renvoyé). Le PC doit être refait.
; Cache_Vide : renvoyer les créneaux sales (ils restent valides).
; -------------------------------------------------------------------
Cache_Init:
    PSHS    Y
    LDY     #CARTE
    LDX     #ZeroOct
    LDW     #BLOCS_MAX
    TFM     X,Y+
    PULS    Y
    LDX     #CrenBloc
    LDB     #NB_CRENEAUX*2
CI_Bloc:
    LDA     #$FF
    STA     ,X+
    DECB
    BNE     CI_Bloc
    LDX     #CrenSale
    LDB     #NB_CRENEAUX
CI_Sale:
    CLR     ,X+
    DECB
    BNE     CI_Sale
    LDA     #CREN_EPINGLES
    STA     VicIdx
    LDD     #0
    STD     PCFIN
    RTS

; Epingle : les blocs des globales dans les créneaux 0-2 (jamais choisis
; comme victimes), consécutifs : GlobHote = l'adresse de la globale 16.
; Un bloc déjà en cache ailleurs y est d'abord renvoyé (s'il est sale).
Epingle:
    CLR     EpK
Ep_Boucle:
    LDB     Globales
    ADDB    EpK
    CLRA
    CMPD    NBlocsRam
    LBHS    Ep_Suiv
    STD     EpBloc
    EORB    #$80                    ; déjà dans un créneau ?
    LDX     #CARTE
    LEAX    D,X
    LDA     ,X
    BEQ     Ep_Charge
    CLR     ,X
    SUBA    #CREN_HI
    STA     ViIdx
    LDB     ViIdx
    LSLB
    LDX     #CrenBloc
    ABX
    LDD     #$FFFF
    STD     ,X
    LDX     #CrenSale
    LDB     ViIdx
    ABX
    TST     ,X
    BEQ     Ep_Charge
    CLR     ,X
    LDD     EpBloc
    STD     ViBloc
    LDA     ViIdx
    ADDA    #CREN_HI
    JSR     Renvoie
Ep_Charge:
    LDB     EpK                     ; le créneau k reçoit le bloc
    LSLB
    LDX     #CrenBloc
    ABX
    LDD     EpBloc
    STD     ,X
    LDX     #CrenSale
    LDB     EpK
    CLR     B,X
    LDD     EpBloc
    EORB    #$80
    LDX     #CARTE
    LEAX    D,X
    LDA     EpK
    ADDA    #CREN_HI
    STA     ,X
    LDD     EpBloc
    JSR     Phys
    PSHS    Y,U
    PSHS    A
    LDA     EpK
    ADDA    #CREN_HI
    CLRB
    TFR     D,Y
    PULS    A
    LDB     >current_page
    LDU     #256
    JSR     [table_function_ram+sys_FarRead]
    PULS    Y,U
Ep_Suiv:
    INC     EpK
    LDA     EpK
    CMPA    #CREN_EPINGLES
    LBLO    Ep_Boucle
    LDA     #CREN_HI
    LDB     Globales+1
    STD     GlobHote
    RTS

Cache_Vide:
    CLR     ViIdx
CV_Boucle:
    LDX     #CrenSale
    LDB     ViIdx
    ABX
    TST     ,X
    BEQ     CV_Suiv
    CLR     ,X
    LDB     ViIdx
    LSLB
    LDX     #CrenBloc
    ABX
    LDD     ,X
    CMPD    #BLOCS_RAM
    BHS     CV_Suiv
    STD     ViBloc
    LDA     ViIdx
    ADDA    #CREN_HI
    JSR     Renvoie
CV_Suiv:
    INC     ViIdx
    LDA     ViIdx
    CMPA    #NB_CRENEAUX
    BLO     CV_Boucle
    RTS

; -------------------------------------------------------------------
; Charge_Jeu : en-tête vérifié, blocs 0..NBlocsRam-1 copiés en pages 2-3.
; C = 1 et X = message si le jeu ne convient pas.
; -------------------------------------------------------------------
Charge_Jeu:
    LDD     InfoJeu+4               ; taille : au plus 256 Ko
    CMPD    #4
    BHS     CJ_Gros
    LDD     InfoJeu+5               ; blocs = ceil(taille / 256)
    TST     InfoJeu+7
    BEQ     CJ_Exact
    ADDD    #1
CJ_Exact:
    STD     NBlocs
    CMPD    #BLOCS_RAM
    BLS     CJ_Ram
    LDD     #BLOCS_RAM
CJ_Ram:
    STD     NBlocsRam
    LDD     #0                      ; secteur 0 : l'en-tête
    JSR     Lit_Secteur_N
    LDA     SECTEUR
    STA     Version
    CMPA    #3
    BEQ     CJ_VOk
    CMPA    #4
    BEQ     CJ_VOk
    CMPA    #5
    BEQ     CJ_VOk
    CMPA    #7
    BEQ     CJ_VOk
    CMPA    #8
    BEQ     CJ_VOk
    LDX     #TxtVersion
    ORCC    #1
    RTS
CJ_Gros:
    LDX     #TxtGros
    ORCC    #1
    RTS
CJ_VOk:                             ; V3, Vieux (v1-4), Decal (paquées)
    CLR     V3
    CLR     Vieux
    LDB     #2
    CMPA    #4
    BHI     CJ_Decal
    INC     Vieux
    CMPA    #3
    BNE     CJ_Decal
    INC     V3
    DECB
CJ_Decal:
    CMPA    #8
    BNE     CJ_DecalOk
    INCB
CJ_DecalOk:
    STB     Decal
    LDD     #$0906                  ; clés du dictionnaire
    TST     V3
    BEQ     CJ_Cle
    LDD     #$0604
CJ_Cle:
    STD     CleZ                    ; (CleZ puis CleOct)
    LDA     #2
    SUBA    Vieux
    STA     DcOfs
    LDA     V3                      ; v3 : la rangée 0 est la ligne d'état
    STA     Base
    LDD     #0
    STD     CjBloc
CJ_Boucle:
    LDD     CjBloc
    CMPD    NBlocsRam
    BHS     CJ_Fin
    STD     CbBloc
    JSR     Lit_Secteur_Bloc
    LDD     CjBloc
    JSR     Ecrit_Bloc_Pages
    LDD     CjBloc                  ; la moitié haute du secteur
    ADDD    #1
    STD     CjBloc
    CMPD    NBlocsRam
    BHS     CJ_Fin
    JSR     Ecrit_Bloc_Pages
    LDD     CjBloc
    ADDD    #1
    STD     CjBloc
    BRA     CJ_Boucle
CJ_Fin:
    ANDCC   #$FE
    RTS

; Ecrit_Bloc_Pages : D = bloc ; la moitié de SECTEUR qui lui correspond
; va en pages 2-3 (la fin du fichier : des zéros)
Ecrit_Bloc_Pages:
    STD     CbBloc
    LDX     #SECTEUR
    BITB    #1
    BEQ     EBP_Moitie
    LEAX    256,X
EBP_Moitie:
    PSHS    X
    LDD     CbBloc                  ; dernier bloc coupé : zéros dans le secteur
    ADDD    #1
    CMPD    NBlocs
    BNE     EBP_Copie
    LDB     InfoJeu+7
    BEQ     EBP_Copie
    LDX     ,S
    ABX
    NEGB
    CLRA
    TFR     D,W
    TFR     X,D
    PSHS    Y
    TFR     D,Y
    LDX     #ZeroOct
    TFM     X,Y+
    PULS    Y
EBP_Copie:
    LDD     CbBloc
    JSR     Phys                    ; A = page, X = destination
    PSHS    Y,U
    TFR     X,Y
    LDX     4,S                     ; la source
    LDB     >current_page
    LDU     #256
    JSR     [table_function_ram+sys_FarWrite]
    PULS    Y,U
    LEAS    2,S
    RTS

TxtHors:        FCN "adresse hors du jeu"
TxtLecture:     FCN "lecture de la carte"
TxtVersion:     FCN "version non prise en charge (3, 4, 5, 7, 8)"
TxtGros:        FCN "jeu de plus de 256 Ko"
ZeroOct:        FCB 0

PCBLOC:         RMB 2
PCFIN:          RMB 2
BpBloc:         RMB 2
CbBloc:         RMB 2
CbPage:         RMB 1
CjBloc:         RMB 2
VicIdx:         RMB 1
ViIdx:          RMB 1
ViBloc:         RMB 2
NBlocs:         RMB 2
NBlocsRam:      RMB 2
SecLBA:         RMB 4
TxtAdr:         RMB 3
GlobHote:       RMB 2
EpK:            RMB 1
EpBloc:         RMB 2
CrenBloc:       RMB NB_CRENEAUX*2
CrenSale:       RMB NB_CRENEAUX
