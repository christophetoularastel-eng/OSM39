; ===================================================================
; ZM_ECRAN.ASM - L'écran (la Grille du modèle) et le clavier
; ===================================================================
; Copie d'écran ECRAN (30 rangées de 160 octets, format de la carte),
; recopiée en VRAM par Irq_Z (RANG_TRAME rangées sales par trame).
; Fenêtre 1 (en haut, Haut rangées) : pas de retour à la ligne, coupée à
; droite. Fenêtre 0 : coupure aux mots quand Tampon <> 0, défilement de
; la seule fenêtre 0, « [Suite] » après une page sans saisie.
; Ecran_Car : A = caractère CP437 (10 = nouvelle ligne), vers la fenêtre
; courante, avec l'attribut du style courant.
; ===================================================================

; -------------------------------------------------------------------
; Ecran_Init : sauve les rangées 25-29 d'OSM-VISION (IRQ), écran noir,
; curseur caché
; -------------------------------------------------------------------
Ecran_Init:
    LDD     >VRAM_PTR
    STD     VramPtrAvant
    JSR     Curseur_Cache
    CLR     IrqEtat                 ; 0 : sauver les rangées 25-29
    LDA     #25
    STA     IrqRang
    ORCC    #%00010000
    LDX     >rvec_IRQ
    STX     AncienIRQ
    LDX     #Irq_Z
    STX     >rvec_IRQ
    ANDCC   #%11101111
EI_Attente:
    LDA     IrqEtat
    BEQ     EI_Attente
    LDA     #9                      ; blanc sur noir
    STA     Encre
    LDA     #2
    STA     Fond
    ; continue dans Ecran_RAZ

; Ecran_RAZ : la Grille du début (tout effacé, fenêtre 0 en haut)
Ecran_RAZ:
    CLR     Style
    LDA     Base                    ; v3 : la rangée 0 est la ligne d'état
    STA     Haut
    STA     PosY
    CLR     Fen
    CLR     PosX
    CLR     UX
    CLR     UX+1
    CLR     UY
    CLR     UY+1
    LDA     #1
    STA     Tampon
    CLR     MotN
    CLR     Lignes
    CLRA
    LDB     #HAUTEUR
    JMP     Efface_Rangs

; Ecran_Fin : rend les rangées 25-29, décroche l'IRQ, curseur caché
Ecran_Fin:
    LDA     #25
    STA     IrqRang
    LDA     #2
    STA     IrqEtat
EF_Attente:
    LDA     IrqEtat
    CMPA    #3
    BNE     EF_Attente
    ORCC    #%00010000
    LDX     AncienIRQ
    STX     >rvec_IRQ
    LDD     VramPtrAvant
    STD     >VRAM_PTR
    LDA     >kbd_tete               ; ce qui reste tapé : oublié
    STA     >kbd_queue
    ANDCC   #%11101111
    JMP     Curseur_Cache

; -------------------------------------------------------------------
; Irq_Z : posée dans rvec_IRQ, avant celle du BIOS. Tous les registres
; sont dans la trame d'interruption (mode natif).
; -------------------------------------------------------------------
Irq_Z:
    LDA     >IrqEtat
    BEQ     IZ_Sauve
    CMPA    #1
    BEQ     IZ_Normal
    CMPA    #2
    BEQ     IZ_Rend
    JMP     [AncienIRQ]
IZ_Normal:
    TST     >SalePresente           ; rien à recopier : rien à parcourir
    BEQ     IZ_Bios
    CLR     >SalePresente
    LDA     #RANG_TRAME
    STA     >IzLot
    CLRB
IZ_Boucle:
    LDX     #SALE
    TST     B,X
    BEQ     IZ_Suiv
    CLR     B,X
    PSHS    B
    LSLB
    LDX     #RangEcran
    LDX     B,X
    LDY     #RangVram
    LDY     B,Y
    BSR     IZ_Copie
    PULS    B
    DEC     >IzLot
    BNE     IZ_Suiv
    LDA     #1                      ; le lot est fait : il en reste peut-être
    STA     >SalePresente
    BRA     IZ_Bios
IZ_Suiv:
    INCB
    CMPB    #HAUTEUR
    BLO     IZ_Boucle
IZ_Bios:
    JMP     [AncienIRQ]

; IZ_Copie : X = rangée de la copie, Y = rangée de la VRAM
IZ_Copie:
    IFNE    CARTE_MONO
    LDW     #RANG_OCT
    TFM     X+,Y+
    ELSE
    LDW     #LARGEUR
    TFM     X+,Y+
    LEAY    VRAM_COL_OFS-LARGEUR,Y
    LDW     #LARGEUR
    TFM     X+,Y+
    ENDC
    RTS

; IZ_Sauve / IZ_Rend : rangées 25-29 entre la VRAM et SAUVE, 2 par trame
IZ_Sauve:
    BSR     IZ_Rang25               ; X = SAUVE, Y = VRAM
    IFNE    CARTE_MONO
    LDW     #RANG_OCT
    TFM     Y+,X+
    ELSE
    LDW     #LARGEUR
    TFM     Y+,X+
    LEAY    VRAM_COL_OFS-LARGEUR,Y
    LDW     #LARGEUR
    TFM     Y+,X+
    ENDC
    BSR     IZ_Rang25Suiv
    BLO     IZ_Sauve
    BRA     IZ_Bios
IZ_Rend:
    BSR     IZ_Rang25
    BSR     IZ_Copie
    BSR     IZ_Rang25Suiv
    BLO     IZ_Rend
    BRA     IZ_Bios

IZ_Rang25:
    LDB     >IrqRang
    SUBB    #25
    LDA     #RANG_OCT
    MUL
    ADDD    #SAUVE
    TFR     D,X
    LDB     >IrqRang
    LSLB
    LDY     #RangVram
    LDY     B,Y
    RTS

; IZ_Rang25Suiv : rangée suivante ; C = 1 (BLO) s'il en reste une à
; faire dans cette trame. Après la 29 : état suivant (1 ou 3).
IZ_Rang25Suiv:
    INC     >IrqRang
    LDA     >IrqRang
    CMPA    #HAUTEUR
    BLO     IZ_Reste
    INC     >IrqEtat
    ANDCC   #$FE
    RTS
IZ_Reste:
    BITA    #1                      ; deux rangées par trame : 25-26, 27-28, 29
    BNE     IZ_Encore
    ANDCC   #$FE
    RTS
IZ_Encore:
    ORCC    #1
    RTS

; -------------------------------------------------------------------
; Curseur matériel
; -------------------------------------------------------------------
Curseur_Cache:
    LDA     #CURSEUR_CACHE
    BRA     Curseur_R10
Curseur_Montre:
    ; VRAM_PTR = la case (PosX, PosY) ; l'IRQ du BIOS y met R14/R15
    LDA     #LARGEUR
    LDB     PosY
    MUL
    ADDB    PosX
    ADCA    #0
    IFNE    CARTE_MONO
    LSLB
    ROLA
    ENDC
    ADDD    #VRAM_BASE
    STD     >VRAM_PTR
    LDA     #CURSEUR_VISIBLE
Curseur_R10:
    PSHS    CC
    ORCC    #%01010000
    LDB     #10
    STB     CRTC_RS
    STA     CRTC_DATA
    PULS    CC,PC

; -------------------------------------------------------------------
; Cases et rangées
; -------------------------------------------------------------------
; Case : A = colonne, B = rangée -> X = la case (attribut en ATTR_OFS,X)
Case:
    PSHS    A
    LSLB
    LDX     #RangEcran
    LDX     B,X
    PULS    B
    ABX
    IFNE    CARTE_MONO
    ABX
    ENDC
    RTS

; Sale_B : la rangée B sera recopiée
Sale_B:
    PSHS    X
    LDX     #SALE
    LDA     #1
    STA     B,X
    STA     SalePresente
    PULS    X,PC

; Attr_De : B = style -> A = attribut (fond D4-D6, encre D0-D2, D3 atténué)
Attr_De:
    PSHS    B
    LDX     #ZCoul
    LDA     Encre
    LDA     A,X
    STA     AtE
    LDA     Fond
    LDA     A,X
    STA     AtF
    LDB     ,S+
    BITB    #1
    BEQ     AD_PasInv
    LDA     AtE
    PSHS    A
    LDA     AtF
    STA     AtE
    PULS    A
    STA     AtF
AD_PasInv:
    BITB    #6
    BNE     AD_Plein
    LDA     AtE
    ORA     #8
    STA     AtE
AD_Plein:
    LDA     AtE
    BITA    #7
    BNE     AD_Encre
    LDA     #8                      ; encre noire : $8 (défaut de l'encre 0)
AD_Encre:
    STA     AtE
    LDA     AtF
    LSLA
    LSLA
    LSLA
    LSLA
    ORA     AtE
    RTS

; Efface_Rangs : rangées A..B-1 en espaces, attribut du style 0
Efface_Rangs:
    STA     ErDe
    STB     ErA
    CLRB
    JSR     Attr_De
    STA     ErAttr
ER_Boucle:
    LDB     ErDe
    CMPB    ErA
    BHS     ER_Fin
    JSR     Rang_Vide
    INC     ErDe
    BRA     ER_Boucle
ER_Fin:
    RTS

; Rang_Vide : la rangée B en espaces d'attribut ErAttr (marquée sale)
Rang_Vide:
    PSHS    B,Y
    LSLB
    LDX     #RangEcran
    LDY     B,X
    IFNE    CARTE_MONO
    LDA     #' '
    LDB     ErAttr
    LDX     #LARGEUR
RV_Boucle:
    STD     ,Y++
    LEAX    -1,X
    BNE     RV_Boucle
    ELSE
    LDX     #Espace
    LDW     #LARGEUR
    TFM     X,Y+
    LDX     #ErAttr
    LDW     #LARGEUR
    TFM     X,Y+
    ENDC
    PULS    B,Y
    JMP     Sale_B                  ; marquée APRÈS (l'IRQ peut recopier entre deux)

; -------------------------------------------------------------------
; Ecran_Car : A = CP437 (10 = nouvelle ligne)
; -------------------------------------------------------------------
Ecran_Car:
    STA     EcC
    LDB     Style
    JSR     Attr_De
    STA     EcA
    TST     Fen
    BNE     EC_Haut
    TST     Tampon
    BEQ     EC_Direct
    LDA     EcC
    CMPA    #10
    BEQ     EC_NL
    CMPA    #' '
    BEQ     EC_Espace
    LDB     MotN                    ; le mot s'allonge
    CMPB    #MOT_MAX
    BLO     EC_Ajoute
    JSR     Vide_Mot
    LDB     MotN
EC_Ajoute:
    LDX     #MOT
    ABX
    LDA     EcC
    STA     ,X
    LDA     EcA
    STA     MOT_ATTR-MOT,X
    INC     MotN
    RTS
EC_NL:
    JSR     Vide_Mot
    JMP     Nouvelle_Ligne
EC_Espace:
    JSR     Vide_Mot
    LDA     PosX
    CMPA    #LARGEUR
    LBHS    Nouvelle_Ligne
    LDA     #' '
    LDB     EcA
    JMP     Pose
EC_Direct:
    LDA     EcC
    CMPA    #10
    LBEQ    Nouvelle_Ligne
    LDB     EcA
    JMP     Pose
EC_Haut:                            ; fenêtre 1 : coupée à droite
    LDA     EcC
    CMPA    #10
    BNE     EC_HCar
    LDD     UY
    ADDD    #1
    STD     UY
    CLR     UX
    CLR     UX+1
    RTS
EC_HCar:
    LDD     UY                      ; (pas coupée à Haut : comme frotz)
    CMPD    #HAUTEUR
    BHS     EC_HSuiv
    LDD     UX
    CMPD    #LARGEUR
    BHS     EC_HSuiv
    LDA     UX+1
    LDB     UY+1
    JSR     Case
    LDA     EcC
    STA     ,X
    LDA     EcA
    STA     ATTR_OFS,X
    LDB     UY+1
    JSR     Sale_B
EC_HSuiv:
    LDD     UX
    ADDD    #1
    STD     UX
    RTS

; Pose : A = caractère, B = attribut, à (PosX, PosY) de la fenêtre 0
Pose:
    PSHS    D
    LDA     PosX
    CMPA    #LARGEUR
    BLO     Po_Place
    JSR     Nouvelle_Ligne
Po_Place:
    LDA     PosX
    LDB     PosY
    JSR     Case
    PULS    D
    STA     ,X
    STB     ATTR_OFS,X
    LDB     PosY
    JSR     Sale_B
    INC     PosX
    RTS

; Vide_Mot : le mot en attente va à l'écran (à la ligne s'il dépasse)
Vide_Mot:
    LDB     MotN
    BEQ     VM_Fin
    STB     VmN
    CLR     MotN
    LDA     PosX
    BEQ     VM_Pose
    ADDA    VmN
    BCS     VM_NL
    CMPA    #LARGEUR
    BLS     VM_Pose
VM_NL:
    JSR     Nouvelle_Ligne
VM_Pose:
    CLR     VmI
VM_Boucle:
    LDB     VmI
    CMPB    VmN
    BHS     VM_Fin
    LDX     #MOT
    ABX
    LDA     ,X
    LDB     MOT_ATTR-MOT,X
    JSR     Pose
    INC     VmI
    BRA     VM_Boucle
VM_Fin:
    RTS

; Nouvelle_Ligne : fenêtre 0
Nouvelle_Ligne:
    CLR     PosX
    LDA     PosY
    CMPA    #HAUTEUR-1
    BHS     NL_Defile
    INC     PosY
    BRA     NL_Compte
NL_Defile:
    JSR     Defile
NL_Compte:
    INC     Lignes
    LDB     #HAUTEUR-1              ; Lignes >= H - Haut - 1 : [Suite]
    SUBB    Haut
    CMPB    Lignes
    BGT     NL_Fin
    JMP     Suite
NL_Fin:
    RTS

; Defile : la fenêtre 0 monte d'une rangée, une rangée vide en bas
Defile:
    LDB     Haut
    CMPB    #HAUTEUR-1
    BHS     Df_Fin
    PSHS    Y
    LDA     #HAUTEUR-1
    SUBA    Haut
    LDB     #RANG_OCT
    MUL
    TFR     D,W
    LDB     Haut
    LSLB
    LDX     #RangEcran
    LDY     B,X                     ; destination : la rangée Haut
    LEAX    RANG_OCT,Y
    TFM     X+,Y+
    PULS    Y
    LDB     Haut
Df_Sale:
    JSR     Sale_B
    INCB
    CMPB    #HAUTEUR
    BLO     Df_Sale
    CLRB
    JSR     Attr_De
    STA     ErAttr
    LDB     #HAUTEUR-1
    JMP     Rang_Vide
Df_Fin:
    RTS

; Suite : « [Suite] » en inverse au début de la rangée, une touche, et la
; rangée revient
Suite:
    CLR     Lignes
    LDA     #0
    LDB     PosY
    JSR     Case
    PSHS    Y
    LDY     #SUITE_SAUVE
    LDW     #RANG_OCT
    TFM     X+,Y+
    PULS    Y
    LDB     #1
    JSR     Attr_De
    STA     SuA
    CLR     SuI
Su_Boucle:
    LDB     SuI
    CMPB    #7
    BHS     Su_Attente
    LDX     #TxtSuite
    LDA     B,X
    PSHS    A
    TFR     B,A
    LDB     PosY
    JSR     Case
    PULS    A
    STA     ,X
    LDA     SuA
    STA     ATTR_OFS,X
    INC     SuI
    BRA     Su_Boucle
Su_Attente:
    LDB     PosY
    JSR     Sale_B
    LDA     #1
    STA     EnSuite
    JSR     Attend_Touche
    CLR     EnSuite
    LDA     #0
    LDB     PosY
    JSR     Case
    PSHS    Y
    TFR     X,Y
    LDX     #SUITE_SAUVE
    LDW     #RANG_OCT
    TFM     X+,Y+
    PULS    Y
    LDB     PosY
    JMP     Sale_B

; -------------------------------------------------------------------
; Fenêtres (les instructions de l'écran)
; -------------------------------------------------------------------
; Efface_Fenetre : D = n (signé)
Efface_Fenetre:
    PSHS    D
    JSR     Vide_Mot
    PULS    D
    CMPD    #$FFFF
    BEQ     EF_M1
    CMPD    #$FFFE
    BEQ     EF_M2
    CMPD    #0
    BEQ     EF_0
    CMPD    #1
    BEQ     EF_1
    RTS
EF_M1:
    LDA     Base
    STA     Haut
    CLR     Fen
EF_M2:
    LDA     Base
    LDB     #HAUTEUR
    JSR     Efface_Rangs
    JSR     UX_Base
EF_Bas:
    CLR     PosX
    LDA     Haut
    STA     PosY
    CLR     Lignes
    RTS
EF_0:
    LDA     Haut
    LDB     #HAUTEUR
    JSR     Efface_Rangs
    BRA     EF_Bas
EF_1:
    LDA     Base
    LDB     Haut
    JSR     Efface_Rangs
    ; continue dans UX_Base

; UX_Base : le curseur de la fenêtre 1 en haut à gauche (rangée Base)
UX_Base:
    CLR     UX
    CLR     UX+1
    CLR     UY
    LDA     Base
    STA     UY+1
    RTS

; Coupe : D = hauteur de la fenêtre 1
Coupe:
    PSHS    D
    JSR     Vide_Mot
    PULS    D
    ADDB    Base                    ; (v3 : sous la ligne d'état)
    ADCA    #0
    BCS     Cp_Max
    CMPD    #HAUTEUR
    BLS     Cp_Ok
Cp_Max:
    LDD     #HAUTEUR
Cp_Ok:
    STB     Haut
    LDD     UY                      ; UY >= Haut : le curseur du haut revient
    TSTA
    BNE     Cp_Raz
    CMPB    Haut
    BLO     Cp_Y
Cp_Raz:
    JSR     UX_Base
Cp_Y:
    LDA     PosY
    CMPA    Haut
    BHS     Cp_Fin
    CLR     PosX
    LDA     Haut
    STA     PosY
Cp_Fin:
    RTS

; Choisit : D = fenêtre
Choisit:
    PSHS    D
    JSR     Vide_Mot
    PULS    D
    CLR     Fen
    CMPD    #1
    BNE     Ch_Fin
    INC     Fen
    JSR     UX_Base
Ch_Fin:
    RTS

; Curseur : D = rangée, X = colonne (1..) ; fenêtre 1 seulement
Curseur:
    TST     Fen
    BEQ     Cu_Fin
    PSHS    D,X
    JSR     Vide_Mot
    PULS    D,X
    SUBD    #1
    BCC     Cu_Y
    CLRA
    CLRB
Cu_Y:
    ADDB    Base
    ADCA    #0
    STD     UY
    TFR     X,D
    SUBD    #1
    BCC     Cu_X
    CLRA
    CLRB
Cu_X:
    STD     UX
Cu_Fin:
    RTS

; Lit_Curseur -> D = rangée, X = colonne (1..)
Lit_Curseur:
    TST     Fen
    BEQ     LC_Bas
    LDD     UX
    ADDD    #1
    TFR     D,X
    LDD     UY
    ADDD    #1
    SUBB    Base
    SBCA    #0
    RTS
LC_Bas:
    LDB     PosX
    CLRA
    ADDD    #1
    TFR     D,X
    LDB     PosY
    CLRA
    ADDD    #1
    RTS

; Efface_Ligne : de la colonne courante à la fin de la rangée
Efface_Ligne:
    TST     Fen
    BNE     EL_Haut
    JSR     Vide_Mot
    LDA     PosX
    LDB     PosY
    BRA     EL_Go
EL_Haut:
    LDD     UY
    CMPD    #HAUTEUR
    BHS     EL_Fin
    LDD     UX
    CMPD    #LARGEUR
    BHS     EL_Fin
    LDA     UX+1
    LDB     UY+1
EL_Go:
    STA     ElX
    STB     ElY
    CLRB
    JSR     Attr_De
    STA     ElA
EL_Boucle:
    LDA     ElX
    CMPA    #LARGEUR
    BHS     EL_Sale
    LDB     ElY
    JSR     Case
    LDA     #' '
    STA     ,X
    LDA     ElA
    STA     ATTR_OFS,X
    INC     ElX
    BRA     EL_Boucle
EL_Sale:
    LDB     ElY
    JMP     Sale_B
EL_Fin:
    RTS

; Couleur : D = encre Z, X = fond Z (1 = défaut, 2-9, autre : inchangée)
Couleur:
    CMPD    #1
    BNE     Co_E
    LDB     #9
Co_E:
    CMPD    #2
    BLO     Co_F
    CMPD    #9
    BHI     Co_F
    STB     Encre
Co_F:
    TFR     X,D
    CMPD    #1
    BNE     Co_F2
    LDB     #2
Co_F2:
    CMPD    #2
    BLO     Co_Fin
    CMPD    #9
    BHI     Co_Fin
    STB     Fond
Co_Fin:
    RTS

; -------------------------------------------------------------------
; Saisie
; -------------------------------------------------------------------
Saisie_Debut:
    JSR     Vide_Mot
    CLR     Lignes
    RTS

; Echo_NL : la fin d'une saisie
Echo_NL:
    JSR     Nouvelle_Ligne
    CLR     Lignes
    RTS

; Recul : la case avant le curseur s'efface
Recul:
    LDA     PosX
    BEQ     Re_Fin
    DEC     PosX
    LDB     Style
    JSR     Attr_De
    PSHS    A
    LDA     PosX
    LDB     PosY
    JSR     Case
    LDA     #' '
    STA     ,X
    PULS    A
    STA     ATTR_OFS,X
    LDB     PosY
    JSR     Sale_B
Re_Fin:
    RTS

; Attend_Touche : une touche (n'importe laquelle) -> A
Attend_Touche:
    CLR     Delai
    CLR     Delai+1
    JSR     Touche
    TSTA
    BEQ     Attend_Touche
    RTS

; Touche : la touche suivante -> A ; 0 si Delai (1/10 s, 0 = sans fin)
; s'est écoulé. Codes : ceux de sys_kbd_poll (Latin-1, $80-$8B).
Touche:
    LDD     Delai                   ; échéance en trames
    BEQ     To_Sans
    LDA     #TRAMES_DIXIEME
    LDB     Delai+1
    MUL
    PSHS    D
    LDA     #TRAMES_DIXIEME
    LDB     Delai
    MUL
    TFR     B,A
    CLRB
    ADDD    ,S++
    ADDD    >vsync_tick
    STD     Echeance
    LDA     #1
    STA     AvecDelai
    BRA     To_Boucle
To_Sans:
    CLR     AvecDelai
To_Boucle:
    PSHS    Y,U
    JSR     [table_function_ram+sys_kbd_poll]
    PULS    Y,U
    CMPA    #$11                    ; Ctrl+Q : on quitte, tout de suite
    LBEQ    Quitte
    TSTA
    BNE     To_Fin
    TST     AvecDelai
    BEQ     To_Boucle
    LDD     >vsync_tick
    SUBD    Echeance
    BMI     To_Boucle
    CLRA
To_Fin:
    RTS

; Lit_Saisie : une ligne au clavier dans LIGNE (LgN caractères, LgMax au
; plus), écho à l'écran. Retour : A = 13 (Entrée) ou 0 (délai écoulé et
; la routine LgRoutine a dit d'arrêter).
Lit_Saisie:
    CLR     LgN
LS_Touche:
    JSR     Curseur_Montre
    LDD     LgDelai
    STD     Delai
    JSR     Touche
    PSHS    A
    JSR     Curseur_Cache
    PULS    A
    TSTA
    BNE     LS_Code
    LDD     LgRoutine               ; délai écoulé : la routine
    JSR     Appel_Interne
    CMPD    #0
    BEQ     LS_Touche
    CLRA
    RTS
LS_Code:
    CMPA    #13
    BEQ     LS_Fin
    CMPA    #8
    BEQ     LS_Recul
    CMPA    #' '
    BLO     LS_Touche
    CMPA    #126
    BLS     LS_Prend
    CMPA    #$A0
    BLO     LS_Touche
LS_Prend:
    LDB     LgN
    CMPB    LgMax
    BHS     LS_Touche
    LDX     #LIGNE
    ABX
    STA     ,X
    INC     LgN
    JSR     Lat_Vers_CP
    PSHS    A
    LDB     Style
    JSR     Attr_De
    TFR     A,B
    PULS    A
    JSR     Pose
    BRA     LS_Touche
LS_Recul:
    LDA     LgN
    BEQ     LS_Touche
    DEC     LgN
    JSR     Recul
    BRA     LS_Touche
LS_Fin:
    JSR     Echo_NL
    LDA     #13
    RTS

; Lit_Ligne : @read (aread) texte, analyse, délai, routine
Lit_Ligne:
    TST     Vieux                   ; v1-4 : pas de résultat
    BNE     LL_Ops
    JSR     Octet_PC                ; la variable de résultat (lue d'abord)
    STA     LlVar
LL_Ops:
    LDD     Ops
    STD     LlTexte
    LDD     Ops+2
    STD     LlAnalyse
    CLRA
    CLRB
    STD     LgDelai
    STD     LgRoutine
    LDB     NOps
    CMPB    #4
    BLO     LL_Pas
    LDD     Ops+6
    STD     LgRoutine
    BEQ     LL_Pas
    LDD     Ops+4
    STD     LgDelai
LL_Pas:
    TST     V3                      ; v3 : la ligne d'état d'abord
    BEQ     LL_Debut
    JSR     Etat
LL_Debut:
    JSR     Saisie_Debut
    LDX     LlTexte
    JSR     Lit8
    STA     LlMax
    CLR     LlDeja
    TST     Vieux                   ; v1-4 : octet 0 = la place + 1
    BEQ     LL_V5
    LDA     LlMax
    BEQ     LL_Calc
    DEC     LlMax
    BRA     LL_Calc
LL_V5:
    LDX     LlTexte
    LEAX    1,X
    JSR     Lit8
    STA     LlDeja
LL_Calc:
    LDA     LlMax
    SUBA    LlDeja
    BCC     LL_Max
    CLRA
LL_Max:
    STA     LgMax
    JSR     Lit_Saisie
    TSTA
    BNE     LL_Range
    LDX     LlTexte                 ; arrêtée par la routine
    LEAX    1,X
    CLRA
    JSR     Ecrit8
    CLRA
    CLRB
    BRA     LL_Rend
LL_Range:
    CLR     LlI
LL_Car:
    LDB     LlI
    CMPB    LgN
    BHS     LL_Compte
    LDX     #LIGNE
    LDA     B,X
    JSR     Lat_Minuscule
    JSR     Lat_Vers_Z
    PSHS    A
    LDB     LlDeja
    ADDB    LlI
    CLRA
    ADDB    DcOfs
    ADCA    #0
    ADDD    LlTexte
    TFR     D,X
    PULS    A
    JSR     Ecrit8
    INC     LlI
    BRA     LL_Car
LL_Compte:
    TST     Vieux
    BEQ     LL_Long
    LDB     LgN                     ; v1-4 : un 0 à la fin
    CLRA
    ADDD    LlTexte
    ADDD    #1
    TFR     D,X
    CLRA
    JSR     Ecrit8
    BRA     LL_Analyse
LL_Long:
    LDA     LlDeja
    ADDA    LgN
    LDX     LlTexte
    LEAX    1,X
    JSR     Ecrit8
LL_Analyse:
    LDD     LlAnalyse
    BEQ     LL_Treize
    CLR     DcDico
    CLR     DcDico+1
    CLR     DcSauf
    LDD     LlTexte
    LDX     LlAnalyse
    JSR     Decoupe
LL_Treize:
    LDD     #13
LL_Rend:
    TST     Vieux
    BNE     LL_Fin
    TFR     D,X
    LDB     LlVar
    JMP     Ecrit_Var
LL_Fin:
    RTS

; Lit_Touche : @read_char 1, délai, routine
Lit_Touche:
    CLRA
    CLRB
    STD     Delai
    STD     LgRoutine
    LDB     NOps
    CMPB    #3
    BLO     LT_Pas
    LDD     Ops+4
    STD     LgRoutine
    BEQ     LT_Pas
    LDD     Ops+2
    STD     LgDelai
LT_Pas:
    JSR     Saisie_Debut
LT_Attente:
    JSR     Curseur_Montre
    LDD     LgRoutine
    BEQ     LT_SansDelai
    LDD     LgDelai
LT_SansDelai:
    STD     Delai
    JSR     Touche
    PSHS    A
    JSR     Curseur_Cache
    PULS    A
    TSTA
    BNE     LT_Code
    LDD     LgRoutine
    JSR     Appel_Interne
    CMPD    #0
    BEQ     LT_Attente
    CLRA
    CLRB
    JMP     Stocke
LT_Code:
    CMPA    #KEY_UP                 ; flèches : ZSCII 129-132
    BLO     LT_Normal
    CMPA    #KEY_RIGHT
    BHI     LT_Autre
    SUBA    #KEY_UP-129
    TFR     A,B
    CLRA
    JMP     Stocke
LT_Autre:
    CMPA    #$A0
    BLO     LT_Attente              ; autres touches spéciales : ignorées
LT_Normal:
    CMPA    #$7F
    BNE     LT_Z
    LDA     #8
LT_Z:
    CMPA    #8
    BEQ     LT_Rend
    CMPA    #13
    BEQ     LT_Rend
    CMPA    #27
    BEQ     LT_Rend
    JSR     Lat_Vers_Z              ; (autre contrôle : « ? »)
LT_Rend:
    TFR     A,B
    CLRA
    JMP     Stocke

; -------------------------------------------------------------------
; Tables et variables de l'écran
; -------------------------------------------------------------------
ZCoul:          FCB 0,0,0,4,2,6,1,5,3,7     ; couleur Z -> bits OSM39
TxtSuite:       FCC "[Suite]"
Espace:         FCB ' '
SUITE_SAUVE     equ $5540           ; une rangée (160)

RangEcran:
    FDB     ECRAN+0,ECRAN+160,ECRAN+320,ECRAN+480,ECRAN+640,ECRAN+800,ECRAN+960,ECRAN+1120,ECRAN+1280,ECRAN+1440,ECRAN+1600,ECRAN+1760,ECRAN+1920,ECRAN+2080,ECRAN+2240
    FDB     ECRAN+2400,ECRAN+2560,ECRAN+2720,ECRAN+2880,ECRAN+3040,ECRAN+3200,ECRAN+3360,ECRAN+3520,ECRAN+3680,ECRAN+3840,ECRAN+4000,ECRAN+4160,ECRAN+4320,ECRAN+4480,ECRAN+4640
RangVram:
    FDB     VRAM_BASE+0*VRAM_LIGNE,VRAM_BASE+1*VRAM_LIGNE,VRAM_BASE+2*VRAM_LIGNE,VRAM_BASE+3*VRAM_LIGNE,VRAM_BASE+4*VRAM_LIGNE,VRAM_BASE+5*VRAM_LIGNE,VRAM_BASE+6*VRAM_LIGNE,VRAM_BASE+7*VRAM_LIGNE,VRAM_BASE+8*VRAM_LIGNE,VRAM_BASE+9*VRAM_LIGNE,VRAM_BASE+10*VRAM_LIGNE,VRAM_BASE+11*VRAM_LIGNE,VRAM_BASE+12*VRAM_LIGNE,VRAM_BASE+13*VRAM_LIGNE,VRAM_BASE+14*VRAM_LIGNE
    FDB     VRAM_BASE+15*VRAM_LIGNE,VRAM_BASE+16*VRAM_LIGNE,VRAM_BASE+17*VRAM_LIGNE,VRAM_BASE+18*VRAM_LIGNE,VRAM_BASE+19*VRAM_LIGNE,VRAM_BASE+20*VRAM_LIGNE,VRAM_BASE+21*VRAM_LIGNE,VRAM_BASE+22*VRAM_LIGNE,VRAM_BASE+23*VRAM_LIGNE,VRAM_BASE+24*VRAM_LIGNE,VRAM_BASE+25*VRAM_LIGNE,VRAM_BASE+26*VRAM_LIGNE,VRAM_BASE+27*VRAM_LIGNE,VRAM_BASE+28*VRAM_LIGNE,VRAM_BASE+29*VRAM_LIGNE

AncienIRQ:      RMB 2
IrqEtat:        RMB 1               ; 0 sauve 25-29, 1 normal, 2 rend, 3 fini
IrqRang:        RMB 1
SalePresente:   RMB 1
IzLot:          RMB 1
VramPtrAvant:   RMB 2
Encre:          RMB 1
Fond:           RMB 1
Style:          RMB 1
Haut:           RMB 1
Base:           RMB 1               ; 1 en v3 : la rangée 0 est la ligne d'état
Fen:            RMB 1
PosX:           RMB 1
PosY:           RMB 1
UX:             RMB 2
UY:             RMB 2
Tampon:         RMB 1
MotN:           RMB 1
Lignes:         RMB 1
EcC:            RMB 1
EcA:            RMB 1
AtE:            RMB 1
AtF:            RMB 1
ErDe:           RMB 1
ErA:            RMB 1
ErAttr:         RMB 1
VmN:            RMB 1
VmI:            RMB 1
SuA:            RMB 1
SuI:            RMB 1
EnSuite:        RMB 1
ElX:            RMB 1
ElY:            RMB 1
ElA:            RMB 1
Delai:          RMB 2
Echeance:       RMB 2
AvecDelai:      RMB 1
LgN:            RMB 1
LgMax:          RMB 1
LgDelai:        RMB 2
LgRoutine:      RMB 2
LlVar:          RMB 1
LlTexte:        RMB 2
LlAnalyse:      RMB 2
LlMax:          RMB 1
LlDeja:         RMB 1
LlI:            RMB 1
