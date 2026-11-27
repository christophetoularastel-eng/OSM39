; ===================================================================
; DONJON39.ASM - Labyrinthe en 3D (lancer de rayons) pour OSM-VISION
; ===================================================================
; Flèches haut/bas : avancer/reculer ; gauche/droite : tourner ; Espace :
; ouvrir la porte devant soi (elle se referme seule) ; Tab : mini-carte ;
; Echap : quitter. La carte est lue dans DONJON39.TXT (dossier courant),
; sinon la carte intégrée. Application d'OSM-VISION (page 1,
; liée à $0000, App_Start à l'offset 0), sur le modèle de ENVAHIS.
;
; SOURCE UNIQUE : tools/donjon39/donjon39.py (tables, carte, et le modèle
; exact du rendu que test/verifie_donjon39.py compare à ce binaire).
; apps/donjon_data.inc est GÉNÉRÉ : ne pas l'éditer.
;
; RENDU. Un rayon par colonne de la vue (64), DDA case par case ; la
; hauteur d'un mur en tiers de rangée (mosaïques 2 x 3 de la page 1,
; celles du MINITEL). Faces est/ouest pleines, faces nord/sud en damier
; (plus sombres) ; sol pointillé ; couleurs atténuées (D3 = 1) comme le
; reste du système. Sans division : tables (voir donjon39.py).
;
; ÉCRAN. Deux tampons d'image en RAM : Want (l'image qu'on calcule) et
; Pret (celle qu'on affiche). Quand Pret est toute à l'écran, Want lui est
; comparée rangée par rangée (Sale), puis les deux s'échangent. La recopie
; se fait DANS l'IRQ du VSYNC (Irq_Donjon, posée dans rvec_IRQ, avant celle
; du BIOS) : RANGEES_TRAME rangées par TFM au tout début du retour de
; trame (un accès du CPU à la VRAM pendant l'affichage fait scintiller),
; pendant que la boucle calcule l'image suivante.
;
; CLAVIER. Les octets PS/2 bruts sont lus dans la file de la NMI
; (kbd_buf, 16 octets) : touches tenues (appui / F0 relâchement), rien de
; perdu pendant le calcul d'une image. En sortant, la file est vidée et
; on attend le relâchement d'Echap (sinon OSM-VISION le recevrait).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"
    include "../lib/snd.inc"

    export App_Start

VIS_REQUIS      equ (vis_Window/2)+1

; --- Fenêtre : intérieur 64 x 20 (vue 64 x 18 + 2 rangées d'état) ---
WIN_X           equ 7
WIN_Y           equ 1
WIN_W           equ 66
WIN_H           equ 23
F_X             equ WIN_X+1
F_Y             equ WIN_Y+2
F_H             equ 20
ETAT_Y          equ 18              ; rangées d'état (dans l'intérieur)

; --- Tampons (page 1, après le code : voir le garde-fou du Makefile) ---
; Un tampon : glyphes (F_TAILLE) puis attributs (F_TAILLE).
TAMPONS         equ $5000
F_TAILLE        equ 64*F_H          ; 1280 octets par plan
BufA            equ TAMPONS
BufB            equ TAMPONS+2*F_TAILLE
TEXTE           equ TAMPONS+4*F_TAILLE  ; DONJON39.TXT, 2 Ko au plus
TEXTE_MAX       equ 2048
PORTES_N        equ 8               ; portes ouvertes en même temps
PORTE_DUREE     equ 300             ; trames (5 s) avant de se refermer
DEVANT          equ 192             ; la porte à 3/4 de case devant soi
; v4 : un tampon = le plan des glyphes puis celui des attributs. mono :
; entrelacé comme la VRAM (glyphe, attribut), une rangée = un seul TFM.
    IFNE    CARTE_MONO
ATTR_OFS        equ 1               ; l'attribut suit le glyphe
CEL             equ 2               ; octets par cellule dans un tampon
RANG_O          equ 128             ; octets par rangée dans un tampon
    ELSE
ATTR_OFS        equ F_TAILLE        ; attributs = glyphes + ATTR_OFS
CEL             equ 1
RANG_O          equ VUE_L           ; (VUE_L = 64, défini plus bas : forme longue, comme avant)
    ENDC

RANGEES_TRAME   equ 4               ; rangées recopiées par VSYNC au plus
VITESSE         equ 16              ; 1/16 de case par trame
ROTATION        equ 6               ; 6/1024 de tour par trame
MARGE           equ 64              ; on reste à 1/4 de case des murs
TRAMES_MAX      equ 8               ; une image lente ne fait pas sauter
ETAT_ATTR       equ $0F             ; texte blanc (page 0, atténué), fond noir
ASCII_0         equ $30

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDA     >VIS_COUNT_ADR
    CMPA    #VIS_REQUIS
    BHS     AS_VisOk
    RTS
AS_VisOk:
    LDD     #DEPART_X
    STD     PosX
    LDD     #DEPART_Y
    STD     PosY
    LDD     #DEPART_A
    STD     Ang
    CLR     KeyHaut
    CLR     KeyBas
    CLR     KeyGauche
    CLR     KeyDroite
    CLR     KbE0
    CLR     KbRel
    CLR     QuitReq
    CLR     EscUp
    CLR     UsageReq
    CLR     MiniOn
    CLR     TabBas
    CLR     JoyAvant
    JSR     Joy_Init                ; le joystick (/BIN/JOYSTICK.CFG)
    LDX     #Portes                 ; aucune porte ouverte
    LDB     #PORTES_N*4
AS_Portes:
    CLR     ,X+
    DECB
    BNE     AS_Portes
    JSR     Charger_Carte
    LDA     >kbd_tete           ; ce qui était tapé avant : oublié
    STA     >kbd_queue
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Init_Ecran
    ORCC    #%00010000              ; la recopie se branche sur l'IRQ VSYNC
    LDX     >rvec_IRQ
    STX     AncienIRQ
    LDX     #Irq_Donjon
    STX     >rvec_IRQ
    ANDCC   #%11101111
    LDD     >vsync_tick
    STD     TickImage
    LDA     #1
    STA     Trames

; -------------------------------------------------------------------
; Boucle : une image par tour
; -------------------------------------------------------------------
Boucle:
    JSR     Lire_Clavier
    TST     QuitReq
    LBNE    Quitter
    JSR     Bouger
    JSR     Portes_Gerer
    JSR     Rendre                  ; dans Want, pendant que l'IRQ recopie Pret
    TST     MiniOn
    BEQ     Bo_SansMini
    JSR     Dessiner_Mini
Bo_SansMini:
    JSR     Ecrire_Etat
Bo_Attente:                         ; Pret toute à l'écran ?
    JSR     Lire_Clavier
    TST     Reste
    BNE     Bo_Attente
    JSR     Marquer                 ; rangées de Want qui diffèrent de Pret
    ORCC    #%00010000              ; échange, et la recopie démarre
    LDD     PtrWant
    LDX     PtrPret
    STD     PtrPret
    STX     PtrWant
    LDA     NSale
    STA     Reste
    ANDCC   #%11101111
    LDD     >vsync_tick             ; trames entre deux images
    SUBD    TickImage
    BNE     Bo_PasZero
    LDB     #1
Bo_PasZero:
    CMPD    #TRAMES_MAX
    BLS     Bo_Trames
    LDB     #TRAMES_MAX
Bo_Trames:
    STB     Trames
    LDD     >vsync_tick
    STD     TickImage
    BRA     Boucle

; Sortie : on attend le relâchement d'Echap (une demi-seconde au plus),
; puis la file du clavier est vidée pour OSM-VISION.
Quitter:
    LDB     #30
Q_Attente:
    TST     EscUp
    BNE     Q_Fin
    PSHS    B
    JSR     Attendre_Trame
    PULS    B
    DECB
    BNE     Q_Attente
Q_Fin:
    ORCC    #%00010000
    LDX     AncienIRQ               ; l'IRQ du BIOS seule, comme avant
    STX     >rvec_IRQ
    LDA     >kbd_tete
    STA     >kbd_queue
    CLR     >kbd_apres_f0
    CLR     >kbd_echap
    ANDCC   #%11101111
    RTS                             ; OSM-VISION restaure l'écran

; -------------------------------------------------------------------
; Clavier : octets PS/2 de la file de la NMI
; -------------------------------------------------------------------
Lire_Clavier:
    LDB     >kbd_queue
    CMPB    >kbd_tete
    LBEQ     LC_Fin
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
    CMPA    #$29                    ; Espace : ouvrir (à l'appui)
    BNE     LC_Tab
    TSTB
    BNE     LC_Suite
    LDA     #1
    STA     UsageReq
    BRA     LC_Suite
LC_Tab:
    CMPA    #$0D                    ; Tab : mini-carte (une fois par appui :
    BNE     LC_Echap                ;  la répétition du clavier ne compte pas)
    TSTB
    BEQ     LC_TabAppui
    CLR     TabBas
    BRA     LC_Suite
LC_TabAppui:
    TST     TabBas
    BNE     LC_Suite
    INC     TabBas
    LDA     MiniOn
    EORA    #1
    STA     MiniOn
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
    LBRA     Lire_Clavier
LC_Fin:
    RTS

; Joy_Fleches : FHaut... = la flèche tenue OU le joystick (lib/joy.asm) ;
; le bouton, à l'appui, ouvre comme Espace (UsageReq).
Joy_Fleches:
    JSR     Joy_Lit
    TFR     A,B
    LDA     KeyHaut
    BITB    #JOY_HAUT
    BEQ     JF_1
    LDA     #1
JF_1:
    STA     FHaut
    LDA     KeyBas
    BITB    #JOY_BAS
    BEQ     JF_2
    LDA     #1
JF_2:
    STA     FBas
    LDA     KeyGauche
    BITB    #JOY_GAUCHE
    BEQ     JF_3
    LDA     #1
JF_3:
    STA     FGauche
    LDA     KeyDroite
    BITB    #JOY_DROITE
    BEQ     JF_4
    LDA     #1
JF_4:
    STA     FDroite
    TFR     B,A                     ; le bouton : son front
    ANDA    #JOY_BOUTON
    LDB     JoyAvant
    STA     JoyAvant
    COMB
    PSHS    B
    ANDA    ,S+
    BEQ     JF_Fin
    STA     UsageReq
JF_Fin:
    RTS

; Attend le prochain VSYNC en lisant le clavier.
Attendre_Trame:
    LDD     >vsync_tick
    STD     TickVu
AT_Boucle:
    JSR     Lire_Clavier
    LDD     >vsync_tick
    CMPD    TickVu
    BEQ     AT_Boucle
    RTS

; -------------------------------------------------------------------
; Déplacement : Trames trames depuis la dernière image
; -------------------------------------------------------------------
Bouger:
    JSR     Joy_Fleches             ; le joystick, en plus des flèches
    LDB     Trames                  ; tourner : ROTATION x trames
    LDA     #ROTATION
    MUL
    STD     Pas
    TST     FGauche
    BEQ     Bg_PasG
    LDD     Ang
    SUBD    Pas
    ANDA    #3
    STD     Ang
Bg_PasG:
    TST     FDroite
    BEQ     Bg_PasD
    LDD     Ang
    ADDD    Pas
    ANDA    #3
    STD     Ang
Bg_PasD:
    LDB     Trames                  ; avancer : VITESSE x trames (8.8)
    LDA     #VITESSE
    MUL
    STD     Pas
    TST     FHaut
    BNE     Bg_Avance
    TST     FBas
    LBEQ     Bg_Fin
    LDD     #0                      ; reculer : pas négatif
    SUBD    Pas
    STD     Pas
Bg_Avance:
    LDD     Ang                     ; dx = cos x pas, dy = sin x pas
    ADDD    #256
    ANDA    #3
    BSR     Sin_D
    MULD    Pas
    STQ     Tmp4
    LDD     Tmp4+1
    STD     DepX
    LDD     Ang
    BSR     Sin_D
    MULD    Pas
    STQ     Tmp4
    LDD     Tmp4+1
    STD     DepY
    LDD     PosX                    ; x d'abord : la case de x + dx +/- marge
    ADDD    DepX
    STD     NouvX
    LDX     #MARGE
    TST     DepX
    BPL     Bg_XMarge
    LDX     #-MARGE
Bg_XMarge:
    PSHS    X
    ADDD    ,S++
    TFR     A,B                     ; colonne de carte
    LDA     PosY                    ; rangée de carte
    BSR     Case_Libre
    BNE     Bg_Y
    LDD     NouvX
    STD     PosX
Bg_Y:
    LDD     PosY
    ADDD    DepY
    STD     NouvY
    LDX     #MARGE
    TST     DepY
    BPL     Bg_YMarge
    LDX     #-MARGE
Bg_YMarge:
    PSHS    X
    ADDD    ,S++
    LDB     PosX                    ; colonne
    BSR     Case_Libre              ; A = rangée
    BNE     Bg_Fin
    LDD     NouvY
    STD     PosY
Bg_Fin:
    RTS

; Sin_D : D = angle (0-1023) -> D = sin x 256
Sin_D:
    LSLB
    ROLA
    LDX     #Sin
    LDD     D,X
    RTS

; Case_Libre : A = rangée, B = colonne de carte -> Z = 1 si la case est vide
Case_Libre:
    ANDA    #15
    ANDB    #15
    PSHS    B
    LDB     #CARTE_L
    MUL
    ADDB    ,S+
    LDX     #Carte
    ABX                             ; (B,X serait signé : 256 cases)
    TST     ,X
    RTS

; -------------------------------------------------------------------
; Rendu : un rayon par colonne, la colonne composée dans Want
; -------------------------------------------------------------------
Rendre:
    CLR     Col
Re_Colonne:
    JSR     Rayon
    JSR     Composer
    INC     Col
    LDA     Col
    CMPA    #VUE_L
    BLO     Re_Colonne
    RTS

; Rayon : colonne Col -> HMur (hauteur en sous-rangées), Mur (1-7), Cote
Rayon:
    LDB     Col                     ; r = (Ang + ColOff[Col]) & 1023
    LSLB
    LDX     #ColOff
    ABX
    LDD     ,X
    ADDD    Ang
    ANDA    #3
    STD     RayA
    LSLB                            ; dX = Delta[r]
    ROLA
    LDX     #Delta
    LDD     D,X
    STD     DltX
    LDD     RayA                       ; dY = Delta[(r - 256) & 1023]
    SUBD    #256
    ANDA    #3
    LSLB
    ROLA
    LDX     #Delta
    LDD     D,X
    STD     DltY
    LDA     PosY                    ; U = la case de départ dans la carte
    LDB     #CARTE_L                ; (fermée par des murs : un rayon n'en sort
    MUL                             ;  pas, le pointeur non plus)
    ADDB    PosX
    ADCA    #0
    ADDD    #Carte
    TFR     D,U
    LDD     RayA                       ; sens en x : +1 si r <= 256 ou r >= 768
    CMPD    #256
    BLS     Ra_XPlus
    CMPD    #768
    BHS     Ra_XPlus
    LDD     #-1
    STD     PasX
    CLRA
    LDB     PosX+1                  ; fx
    BRA     Ra_XSide
Ra_XPlus:
    LDD     #1
    STD     PasX
    LDD     #256
    SUBB    PosX+1                  ; 256 - fx
    SBCA    #0
Ra_XSide:
    MULD    DltX
    STQ     Tmp4
    LDD     Tmp4+1
    STD     SideX
    LDD     RayA                       ; sens en y : +1 si r <= 512
    CMPD    #512
    BLS     Ra_YPlus
    LDD     #-CARTE_L
    STD     PasY
    CLRA
    LDB     PosY+1
    BRA     Ra_YSide
Ra_YPlus:
    LDD     #CARTE_L
    STD     PasY
    LDD     #256
    SUBB    PosY+1
    SBCA    #0
Ra_YSide:
    MULD    DltY
    STQ     Tmp4
    LDD     Tmp4+1
    STD     SideY
    LDA     #PAS_MAX
    STA     Compte
Ra_Pas:
    LDD     SideX
    CMPD    SideY
    BHS     Ra_PasY
    ADDD    DltX                    ; vers la case suivante en x
    BCC     Ra_XOk
    LDD     #$FFFF
Ra_XOk:
    STD     SideX
    LDD     PasX                    ; +1 ou -1
    LEAU    D,U
    CLR     Cote
    LDA     ,U
    BNE     Ra_Touche
    DEC     Compte
    BNE     Ra_Pas
    BRA     Ra_Touche
Ra_PasY:
    LDD     SideY
    ADDD    DltY
    BCC     Ra_YOk
    LDD     #$FFFF
Ra_YOk:
    STD     SideY
    LDD     PasY                    ; +16 ou -16
    LEAU    D,U
    LDA     #1
    STA     Cote
    LDA     ,U
    BNE     Ra_Touche
    DEC     Compte
    BNE     Ra_Pas
Ra_Touche:
    STA     Mur                     ; (0 si PAS_MAX cases sans mur)
    TST     Cote                    ; distance le long du rayon
    BNE     Ra_DistY
    LDD     SideX
    SUBD    DltX
    BRA     Ra_Perp
Ra_DistY:
    LDD     SideY
    SUBD    DltY
Ra_Perp:
    PSHS    D                       ; perpendiculaire : x ColCos[Col] / 256
    LDB     Col
    LSLB
    LDX     #ColCos
    ABX
    PULS    D
    MULD    ,X
    STQ     Tmp4
    LDD     Tmp4+1
    LSRA                            ; indice = perp / 8 (pas de 1/32 de case)
    RORB
    LSRA
    RORB
    LSRA
    RORB
    CMPD    #1023
    BLS     Ra_IdxMax
    LDD     #1023
Ra_IdxMax:
    CMPD    #0
    BNE     Ra_IdxMin
    LDD     #1
Ra_IdxMin:
    LDX     #HTab
    LDA     D,X
    STA     HMur
    RTS

; Composer : la colonne Col de Want, de haut en bas, d'après HMur, Mur, Cote
Composer:
    LDA     HMur                       ; haut = (SOUS - HMur) / 2, bas = haut + HMur
    CMPA    #SOUS
    BLO     Co_Court
    CLR     Haut
    LDA     #SOUS
    STA     Bas
    BRA     Co_Prep
Co_Court:
    NEGA
    ADDA    #SOUS
    LSRA
    STA     Haut
    ADDA    HMur
    STA     Bas
Co_Prep:
    LDX     #MurFg                  ; attribut du mur
    LDB     Mur
    LDA     B,X
    ORA     #$80
    STA     AttrMur
    LDB     Cote                    ; masques : face E/O, face N/S, porte
    LDX     #MasquePlein
    TSTB
    BEQ     Co_Masques
    LDX     #MasqueOmbre
Co_Masques:
    LDA     Mur
    CMPA    #PORTE
    BNE     Co_PasPorte
    LDX     #MasquePorte
    LDB     #2
Co_PasPorte:
    STX     PtrMasques
    LDX     #MurVal                 ; glyphe d'une cellule toute de mur
    LDB     B,X
    LDX     #TabMos
    LDA     B,X
    STA     GlyMur
    LDX     PtrWant                 ; X = cellule (rangée 0, colonne Col)
    LDB     Col
    ABX
    IFNE    CARTE_MONO
    ABX
    ENDC
    LDY     #Div3                   ; rangées et restes de Haut et Bas
    LDB     Haut
    LDA     B,Y
    STA     HautR
    LDB     Bas
    LDA     B,Y
    STA     BasR
    LDY     #Mod3
    LDB     Haut
    LDA     B,Y
    STA     HautM
    LDB     Bas
    LDA     B,Y
    STA     BasM
; 1) plafond : rangées 0 .. Haut/3 - 1
    CLR     Rang
    LDA     HautR
    BEQ     Co_HautPart
    STA     Compte
    ADDA    Rang
    STA     Rang
    LDA     TabMos
    LDB     #VIDE_ATTR
Co_Plafond:
    STA     ,X
    STB     ATTR_OFS,X
    LEAX    RANG_O,X
    DEC     Compte
    BNE     Co_Plafond
; 2) la rangée où le mur commence, s'il commence en cours de rangée
Co_HautPart:
    TST     HautM
    BEQ     Co_Mur
    BSR     Co_Ligne
; 3) mur plein : jusqu'à la rangée Bas/3 (exclue)
Co_Mur:
    LDA     BasR
    SUBA    Rang
    BLS     Co_BasPart              ; (rien, ou la rangée est déjà faite)
    STA     Compte
    ADDA    Rang
    STA     Rang
    LDA     GlyMur
    LDB     AttrMur
Co_MurPlein:
    STA     ,X
    STB     ATTR_OFS,X
    LEAX    RANG_O,X
    DEC     Compte
    BNE     Co_MurPlein
; 4) la rangée où le mur finit, s'il finit en cours de rangée (et
;    qu'elle n'est pas celle du haut, déjà faite)
Co_BasPart:
    TST     BasM
    BEQ     Co_Sol
    LDA     BasR
    CMPA    Rang
    BLO     Co_Sol
    BSR     Co_Ligne
; 5) sol : jusqu'en bas, une cellule par rangée (table)
Co_Sol:
    LDA     Rang
    CMPA    #VUE_H
    BHS     Co_Fin
    LDB     Rang
    LSLB
    LDY     #SolCel
    LDD     B,Y
    STA     ,X
    STB     ATTR_OFS,X
    LEAX    RANG_O,X
    INC     Rang
    BRA     Co_Sol
Co_Fin:
    RTS

; Co_Ligne : la rangée Rang (cellule X), sous-rangée par sous-rangée ;
; X et Rang avancent d'une rangée
Co_Ligne:
    LDA     Rang
    LDB     #3
    MUL
    STB     J0
    CLR     ValMur
    CLR     ValSol
    CLR     SousK
Co_Sous:
    LDA     J0
    ADDA    SousK                   ; j
    CMPA    Haut
    BLO     Co_SousSuiv             ; plafond : rien
    CMPA    Bas
    BHS     Co_SousSol
    LDY     PtrMasques              ; mur : masque de la sous-rangée
    LDB     SousK
    LDA     B,Y
    ORA     ValMur
    STA     ValMur
    BRA     Co_SousSuiv
Co_SousSol:
    LDY     #SolMasque              ; sol : SolMasque[j] << 2k
    LDB     A,Y
    LDA     SousK
    BEQ     Co_SolPose
Co_SolDecale:
    LSLB
    LSLB
    DECA
    BNE     Co_SolDecale
Co_SolPose:
    ORB     ValSol
    STB     ValSol
Co_SousSuiv:
    INC     SousK
    LDA     SousK
    CMPA    #3
    BLO     Co_Sous
    LDY     #TabMos
    LDB     ValMur
    BEQ     Co_LigSol
    LDA     B,Y
    LDB     AttrMur
    BRA     Co_LigEcrit
Co_LigSol:
    LDB     ValSol
    BEQ     Co_LigVide
    LDA     B,Y
    LDB     #$80+SOL_FG
    BRA     Co_LigEcrit
Co_LigVide:
    LDA     ,Y
    LDB     #VIDE_ATTR
Co_LigEcrit:
    STA     ,X
    STB     ATTR_OFS,X
    LEAX    RANG_O,X
    INC     Rang
    RTS

; -------------------------------------------------------------------
; Rangées d'état (texte, page 0) dans Want : l'aide (18), puis position,
; angle et trames par image (19). Écrites à chaque image : les deux
; tampons s'échangent.
; -------------------------------------------------------------------
Ecrire_Etat:
    IFNE    CARTE_MONO
    LDX     #TxtAide64              ; mono : rangée 18, l'aide, case par case
    LDY     PtrWant
    LEAY    ETAT_Y*RANG_O,Y
    LDB     #64
EE_Aide:
    LDA     ,X+
    STA     ,Y+
    LDA     #ETAT_ATTR
    STA     ,Y+
    DECB
    BNE     EE_Aide
    LDA     #' '                    ; rangée 19 : espaces dans EtatTxt,
    LDX     #EtatTxt                ; les mesures par-dessus, puis entrelacée
    LDB     #64
EE_Esp:
    STA     ,X+
    DECB
    BNE     EE_Esp
    LDU     #EtatTxt
    BSR     EE_Mesures
    LDX     #EtatTxt
    LDY     PtrWant
    LEAY    ETAT_Y*RANG_O+RANG_O,Y
    LDB     #64
EE_R19:
    LDA     ,X+
    STA     ,Y+
    LDA     #ETAT_ATTR
    STA     ,Y+
    DECB
    BNE     EE_R19
    RTS
EE_Mesures:
    ELSE
    LDX     #TxtAide64              ; rangée 18 : l'aide (64 caractères)
    LDY     PtrWant
    LEAY    ETAT_Y*64,Y
    LDW     #64
    TFM     X+,Y+
    LDA     #ETAT_ATTR              ; attributs des rangées 18 et 19
    STA     Tmp4
    LDX     #Tmp4
    LDY     PtrWant
    LEAY    ATTR_OFS+ETAT_Y*64,Y
    LDW     #128
    TFM     X,Y+
    LDA     #' '                    ; rangée 19 : espaces, puis les mesures
    STA     Tmp4
    LDX     #Tmp4
    LDY     PtrWant
    LEAY    ETAT_Y*64+64,Y
    LDW     #64
    TFM     X,Y+
    LDU     PtrWant
    LEAU    ETAT_Y*64+64,U
    ENDC
    LDX     #TxtPos
    JSR     Append
    LDB     PosX
    CLRA
    JSR     Dec16
    LDA     #','
    STA     ,U+
    LDB     PosY
    CLRA
    JSR     Dec16
    LDX     #TxtAng
    JSR     Append
    LDD     Ang
    JSR     Dec16
    LDX     #TxtTrames
    JSR     Append
    LDB     Trames
    CLRA
    JMP     Dec16

; Init_Ecran : Want = A, Pret = B rempli de $FF (rien de tel à l'écran :
; la première image est recopiée en entier)
Init_Ecran:
    LDD     #BufA
    STD     PtrWant
    LDD     #BufB
    STD     PtrPret
    CLR     Reste
    LDA     #$FF
    STA     Tmp4
    LDX     #Tmp4
    LDY     #BufB
    LDW     #2*F_TAILLE
    TFM     X,Y+
    RTS

; -------------------------------------------------------------------
; Écran : rangées de Want qui diffèrent de Pret (Sale, NSale). Appelé
; quand la recopie est finie (Reste = 0) : l'IRQ ne touche à rien.
; -------------------------------------------------------------------
Marquer:
    CLR     NSale
    CLRB
Ma_Rangee:
    PSHS    B
    LDA     #RANG_O
    MUL                             ; D = décalage de la rangée
    LDX     PtrWant
    LEAX    D,X
    LDY     PtrPret
    LEAY    D,Y
    LDA     #64
    STA     Compte
Ma_Comp:
    LDB     ,X
    CMPB    ,Y
    BNE     Ma_Change
    LDB     ATTR_OFS,X
    CMPB    ATTR_OFS,Y
    BNE     Ma_Change
    LEAX    CEL,X
    LEAY    CEL,Y
    DEC     Compte
    BNE     Ma_Comp
    PULS    B
    LDX     #Sale
    CLR     B,X
    BRA     Ma_Suiv
Ma_Change:
    PULS    B
    LDX     #Sale
    LDA     #1
    STA     B,X
    INC     NSale
Ma_Suiv:
    INCB
    CMPB    #F_H
    BLO     Ma_Rangee
    RTS

; -------------------------------------------------------------------
; Irq_Donjon : posée dans rvec_IRQ. Au tout début du retour de trame, au
; plus RANGEES_TRAME rangées sales de Pret vers la VRAM (TFM), puis l'IRQ
; du BIOS (acquittement, vsync_tick, son...). Tous les registres (W
; compris, mode natif) sont dans la trame d'interruption.
; -------------------------------------------------------------------
Irq_Donjon:
    TST     Reste
    BEQ     Iq_Bios
    LDA     #RANGEES_TRAME
    STA     Lot
    CLRB
Iq_Rangee:
    LDX     #Sale
    TST     B,X
    BEQ     Iq_Suiv
    CLR     B,X
    PSHS    B
    LDA     #RANG_O
    MUL
    STD     Decal
    LDB     ,S                      ; Y = adresse VRAM de la rangée
    LSLB
    LDU     #RangVram
    LDY     B,U
    LDX     PtrPret
    LDD     Decal
    LEAX    D,X
    IFNE    CARTE_MONO
    LDW     #RANG_O                 ; mono : la rangée entrelacée, d'un coup
    TFM     X+,Y+
    ELSE
    LDW     #64
    TFM     X+,Y+                   ; les glyphes...
    LDB     ,S
    LSLB
    LDY     B,U
    LEAY    VRAM_COL_OFS,Y
    LDX     PtrPret
    LDD     Decal
    LEAX    D,X
    LEAX    ATTR_OFS,X
    LDW     #64
    TFM     X+,Y+                   ; ... et les attributs
    ENDC
    PULS    B
    DEC     Reste
    BEQ     Iq_Bios
    DEC     Lot
    BEQ     Iq_Bios
Iq_Suiv:
    INCB
    CMPB    #F_H
    BLO     Iq_Rangee
Iq_Bios:
    JMP     [AncienIRQ]

; -------------------------------------------------------------------
; Carte : DONJON39.TXT (dossier courant), lu au lancement. Mêmes règles que
; texte_carte() de tools/donjon39/donjon39.py : une ligne entre CR/LF, vides
; et « ; » sautées, 16 rangées de 16 caractères ('1'-'7' mur, 'P' porte,
; 'J' départ, le reste vide), tour de la carte en mur '1' s'il est vide.
; Absent, vide ou de plus de TEXTE_MAX octets : la carte intégrée.
; -------------------------------------------------------------------
Charger_Carte:
    LDX     #NomCarte
    LDY     #Nom15
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #Nom15
    LDY     #Info14
    JSR     [table_function_ram+sys_FS_FileInfo]
    LBCS    CC_Fin
    LDD     Info14+4                ; taille : 4 octets, grand-boutiste
    LBNE    CC_Fin
    LDD     Info14+6
    LBEQ    CC_Fin
    CMPD    #TEXTE_MAX
    LBHI    CC_Fin
    ADDD    #TEXTE
    STD     FinTexte
    LDA     >current_page
    LDX     #Nom15
    LDY     #TEXTE
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    CC_Fin
    LDX     #Carte                  ; la carte repart de zéro
    CLRB
CC_Vide:
    CLR     ,X+
    DECB
    BNE     CC_Vide
    LDX     #TEXTE
    CLR     Rang
CC_Ligne:
    LDA     Rang
    CMPA    #CARTE_L
    LBHS    CC_Bords
    CMPX    FinTexte
    LBHS    CC_Bords
    LDA     ,X
    CMPA    #$0D
    BEQ     CC_Saut
    CMPA    #$0A
    BEQ     CC_Saut
    CMPA    #';'
    BEQ     CC_Comment
    CLR     MiniC                   ; une rangée : colonne 0...
CC_Car:
    CMPX    FinTexte
    BHS     CC_RangFin
    LDA     ,X
    CMPA    #$0D
    BEQ     CC_RangFin
    CMPA    #$0A
    BEQ     CC_RangFin
    LDB     MiniC
    CMPB    #CARTE_L
    BHS     CC_CarSuiv              ; au-delà de 16 : ignoré
    CMPA    #'a'
    BLO     CC_Maj
    SUBA    #$20
CC_Maj:
    CMPA    #'1'
    BLO     CC_Lettre
    CMPA    #'7'
    BHI     CC_Lettre
    SUBA    #'0'
    BRA     CC_Pose
CC_Lettre:
    CMPA    #'P'
    BNE     CC_Depart
    LDA     #PORTE
    BRA     CC_Pose
CC_Depart:
    CMPA    #'J'
    BNE     CC_CarSuiv
    LDA     MiniC                   ; départ : au milieu de la case, angle 0
    LDB     #$80
    STD     PosX
    LDA     Rang
    STD     PosY
    LDD     #0
    STD     Ang
    BRA     CC_CarSuiv
CC_Pose:
    PSHS    A,X
    LDA     Rang
    LDB     MiniC
    JSR     Ptr_Case
    PULS    A
    STA     ,X
    PULS    X
CC_CarSuiv:
    LEAX    1,X
    INC     MiniC
    BRA     CC_Car
CC_RangFin:
    INC     Rang
    LBRA     CC_Ligne
CC_Saut:
    LEAX    1,X
    LBRA     CC_Ligne
CC_Comment:                         ; jusqu'à la fin de la ligne
    CMPX    FinTexte
    LBHS    CC_Ligne
    LDA     ,X
    CMPA    #$0D
    LBEQ    CC_Ligne
    CMPA    #$0A
    LBEQ    CC_Ligne
    LEAX    1,X
    BRA     CC_Comment
CC_Bords:                           ; le tour : mur s'il est vide
    CLRB
CC_Bord:
    PSHS    B
    LDX     #Carte
    ABX
    TST     ,X                      ; rangée du haut
    BNE     CC_B1
    INC     ,X
CC_B1:
    LEAX    240,X                   ; rangée du bas
    TST     ,X
    BNE     CC_B2
    INC     ,X
CC_B2:
    LDB     ,S
    LDA     #CARTE_L
    MUL
    LDX     #Carte
    LEAX    D,X
    TST     ,X                      ; colonne de gauche
    BNE     CC_B3
    INC     ,X
CC_B3:
    LEAX    15,X                    ; colonne de droite
    TST     ,X
    BNE     CC_B4
    INC     ,X
CC_B4:
    PULS    B
    INCB
    CMPB    #CARTE_L
    BLO     CC_Bord
CC_Fin:
    RTS

; Ptr_Case : A = rangée, B = colonne -> X = la case dans Carte
Ptr_Case:
    ANDA    #15
    ANDB    #15
    PSHS    B
    LDB     #CARTE_L
    MUL
    ADDB    ,S+
    LDX     #Carte
    ABX
    RTS

; -------------------------------------------------------------------
; Portes : Espace ouvre celle qui est à 3/4 de case devant soi ; une porte
; ouverte (case 0) se referme après PORTE_DUREE trames, quand le joueur
; n'y est plus (ses quatre coins, à MARGE).
; -------------------------------------------------------------------
Portes_Gerer:
    TST     UsageReq
    BEQ     PG_Minuter
    CLR     UsageReq
    LDD     Ang                     ; la case devant : pos + (cos, sin) x DEVANT
    ADDD    #256
    ANDA    #3
    JSR     Sin_D
    MULD    #DEVANT
    STQ     Tmp4
    LDD     Tmp4+1
    ADDD    PosX
    STA     JX
    LDD     Ang
    JSR     Sin_D
    MULD    #DEVANT
    STQ     Tmp4
    LDD     Tmp4+1
    ADDD    PosY                    ; A = rangée
    LDB     JX
    JSR     Ptr_Case
    LDA     ,X
    CMPA    #PORTE
    BNE     PG_Minuter
    LDU     #Portes                 ; une place libre dans la table ?
    LDA     #PORTES_N
    STA     MiniR
PG_Cherche:
    LDD     ,U
    BEQ     PG_Libre
    LEAU    4,U
    DEC     MiniR
    BNE     PG_Cherche
    BRA     PG_Minuter              ; table pleine : la porte reste fermée
PG_Libre:
    CLR     ,X                      ; ouverte
    STX     ,U
    LDD     #PORTE_DUREE
    STD     2,U
PG_Minuter:
    LDU     #Portes
    LDA     #PORTES_N
    STA     MiniR
PG_Boucle:
    LDX     ,U
    BEQ     PG_Suiv
    LDD     2,U
    SUBB    Trames
    SBCA    #0
    STD     2,U
    BGT     PG_Suiv
    BSR     Joueur_Dans
    BEQ     PG_Attendre
    LDA     #PORTE                  ; refermée
    STA     ,X
    CLR     ,U
    CLR     1,U
    BRA     PG_Suiv
PG_Attendre:
    LDD     #30                     ; le joueur est dedans : on réessaie
    STD     2,U
PG_Suiv:
    LEAU    4,U
    DEC     MiniR
    BNE     PG_Boucle
    RTS

; Joueur_Dans : X = une case -> Z = 1 si un des coins du joueur y est
Joueur_Dans:
    PSHS    X
    LDD     PosY
    SUBD    #MARGE
    STA     JR1
    LDD     PosY
    ADDD    #MARGE
    STA     JR2
    LDD     PosX
    SUBD    #MARGE
    STA     JC1
    LDD     PosX
    ADDD    #MARGE
    STA     JC2
    LDA     JR1
    LDB     JC1
    LBSR     Ptr_Case
    CMPX    ,S
    BEQ     JD_Fin
    LDA     JR1
    LDB     JC2
    LBSR     Ptr_Case
    CMPX    ,S
    BEQ     JD_Fin
    LDA     JR2
    LDB     JC1
    LBSR     Ptr_Case
    CMPX    ,S
    BEQ     JD_Fin
    LDA     JR2
    LDB     JC2
    LBSR     Ptr_Case
    CMPX    ,S
JD_Fin:
    PULS    X,PC

; -------------------------------------------------------------------
; Mini-carte (Tab) : par-dessus la vue, en haut à droite (MINI_COL,
; MINI_H rangées de 8 cellules ; une cellule = 2 x 3 cases de la carte).
; Un point par case non vide ; la case du joueur aussi, et sa cellule en
; rouge (MINI_JOUEUR).
; -------------------------------------------------------------------
Dessiner_Mini:
    LDA     PosX
    STA     JX
    LDA     PosY
    STA     JY
    LDX     PtrWant
    LEAX    MINI_COL*CEL,X
    CLR     MiniR
DM_Rangee:
    CLR     MiniC
DM_Cel:
    CLR     MiniV
    LDA     #MINI_ATTR
    STA     MiniA
    LDA     MiniR                   ; première case : (2 x colonne, 3 x rangée)
    LDB     #3
    MUL
    STB     DmY0
    LDA     MiniC
    ASLA
    STA     DmX0
    CLR     SousK
DM_K:
    LDA     DmY0
    ADDA    SousK
    CMPA    #CARTE_L
    BHS     DM_KSuiv                ; sous la carte
    LDB     DmX0
    BSR     DM_Point
    LDA     DmY0
    ADDA    SousK
    LDB     DmX0
    INCB
    BSR     DM_Point
DM_KSuiv:
    INC     SousK
    LDA     SousK
    CMPA    #3
    BLO     DM_K
    LDB     MiniV
    LDY     #TabMos
    LDA     B,Y
    STA     ,X
    LDA     MiniA
    STA     ATTR_OFS,X
    LEAX    CEL,X
    INC     MiniC
    LDA     MiniC
    CMPA    #8
    BLO     DM_Cel
    LEAX    RANG_O-8*CEL,X
    INC     MiniR
    LDA     MiniR
    CMPA    #MINI_H
    BLO     DM_Rangee
    RTS

; DM_Point : A = rangée, B = colonne de carte ; le point 2 x SousK +
; (colonne & 1) de MiniV s'allume si la case n'est pas vide (ou si c'est
; celle du joueur : MiniA rouge)
DM_Point:
    PSHS    X
    STB     DmX
    CMPA    JY
    BNE     DMP_Mur
    CMPB    JX
    BNE     DMP_Mur
    LDA     #MINI_JOUEUR
    STA     MiniA
    BRA     DMP_Pose
DMP_Mur:
    JSR     Ptr_Case
    TST     ,X
    BEQ     DMP_Fin
DMP_Pose:
    LDA     SousK                   ; bit = 2 x SousK + (colonne & 1)
    ASLA
    LDB     DmX
    ANDB    #1
    PSHS    B
    ADDA    ,S+
    LDB     #1
DMP_Decale:
    TSTA
    BEQ     DMP_Or
    LSLB
    DECA
    BRA     DMP_Decale
DMP_Or:
    ORB     MiniV
    STB     MiniV
DMP_Fin:
    PULS    X,PC

; Append / Dec16 : lib/str.asm (U = pointeur d'écriture)
    include "../lib/str.asm"
; Services de dessin d'OSM-VISION (VIS_TABLE...)
    include "../lib/vision.asm"
    include "../lib/joy.asm"
; Tables et carte : générées par tools/donjon39/donjon39.py --inc
    include "donjon_data.inc"

; Adresse VRAM du début de chaque rangée de l'intérieur
RangVram:
    FDB     VRAM_BASE+(F_Y+0)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+1)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+2)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+3)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+4)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+5)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+6)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+7)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+8)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+9)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+10)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+11)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+12)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+13)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+14)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+15)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+16)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+17)*VRAM_LIGNE+F_X*VRAM_PAS
    FDB     VRAM_BASE+(F_Y+18)*VRAM_LIGNE+F_X*VRAM_PAS,VRAM_BASE+(F_Y+19)*VRAM_LIGNE+F_X*VRAM_PAS

TxtTitre:   FCN " DONJON39 "
TxtAide64:  FCC " Fleches : bouger   Espace : porte   Tab : carte   Echap : fin  "
NomCarte:   FCN "DONJON39.TXT"
TxtPos:     FCN " Case "
TxtAng:     FCN "   angle "
TxtTrames:  FCN "   trames/image "

; -------------------------------------------------------------------
; Variables
; -------------------------------------------------------------------
PosX:       RMB 2                   ; position 8.8 (cases)
PosY:       RMB 2
Ang:        RMB 2                   ; 0-1023
Trames:     RMB 1                   ; trames prises par l'image précédente
TickImage:  RMB 2
TickVu:     RMB 2
Pas:        RMB 2
DepX:         RMB 2
DepY:         RMB 2
NouvX:      RMB 2
NouvY:      RMB 2
KeyHaut:    RMB 1
KeyBas:     RMB 1
KeyGauche:  RMB 1
KeyDroite:  RMB 1
FHaut:      RMB 1                   ; les flèches tenues OU le joystick
FBas:       RMB 1
FGauche:    RMB 1
FDroite:    RMB 1
JoyAvant:   RMB 1                   ; le bouton à l'image d'avant
KbE0:       RMB 1
KbRel:      RMB 1
QuitReq:    RMB 1
EscUp:      RMB 1
Col:        RMB 1
RayA:          RMB 2
DltX:       RMB 2
DltY:       RMB 2
SideX:      RMB 2
SideY:      RMB 2
PasX:       RMB 2                   ; pas dans la carte : +-1
PasY:       RMB 2                   ; +-CARTE_L
Compte:     RMB 1
Cote:       RMB 1
Mur:        RMB 1
HMur:          RMB 1
Haut:       RMB 1
Bas:        RMB 1
AttrMur:    RMB 1
GlyMur:     RMB 1
PtrMasques: RMB 2
Rang:       RMB 1
HautR:      RMB 1                   ; Haut / 3, Haut mod 3, Bas / 3, Bas mod 3
HautM:      RMB 1
BasR:       RMB 1
BasM:       RMB 1
J0:         RMB 1
SousK:          RMB 1
ValMur:         RMB 1
ValSol:         RMB 1
Tmp4:       RMB 4
    IFNE    CARTE_MONO
EtatTxt:    RMB 64                  ; mono : la rangée 19 en texte, avant entrelacement
    ENDC
Reste:      RMB 1                   ; rangées encore à recopier (l'IRQ décompte)
NSale:      RMB 1
PtrWant:    RMB 2                   ; tampon qu'on calcule
PtrPret:    RMB 2                   ; tampon qu'on affiche
AncienIRQ:  RMB 2                   ; l'IRQ du BIOS (rvec_IRQ d'avant)
Lot:        RMB 1
Decal:      RMB 2
AdrV:       RMB 2
Sale:       RMB F_H
UsageReq:   RMB 1                   ; Espace appuyée
MiniOn:     RMB 1                   ; mini-carte affichée
TabBas:     RMB 1                   ; Tab enfoncée
Portes:     RMB PORTES_N*4          ; portes ouvertes : adresse, trames restantes
Nom15:      RMB 16                  ; nom OSMFS
Info14:     RMB 14                  ; FS_FileInfo
FinTexte:   RMB 2
JX:         RMB 1                   ; case du joueur (mini-carte, porte)
JY:         RMB 1
JR1:        RMB 1                   ; Joueur_Dans : rangées et colonnes des coins
JR2:        RMB 1
JC1:        RMB 1
JC2:        RMB 1
MiniV:      RMB 1
MiniA:      RMB 1
MiniR:      RMB 1
MiniC:      RMB 1
DmY0:       RMB 1
DmX0:       RMB 1
DmX:        RMB 1
NumStarted: RMB 1                   ; lib/str.asm
DigitCnt:   RMB 1
Fin_Code:
