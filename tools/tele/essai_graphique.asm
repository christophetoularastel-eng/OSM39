; ===================================================================
; essai_graphique.asm - Le mode graphique de la carte OSM39_mono, par TELE
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = secondes d'affichage.
; Carte mono seulement (VRAM entrelacée écrite ici en dur, comme stage9).
;
; Le mode graphique (schéma OSM39_mono) : $A120 D3 = GRAPH.
;  - U507/U509 (74HC157) donnent au 166 l'octet de la RAM des caractères
;    au lieu du dessin de la police : 8 pixels, bit 7 à gauche ;
;  - U514 met RA0-3 (la ligne dans la rangée, 6845) sur A11-A14 de cette
;    RAM : l'octet de la case c, ligne r (0-15) est à r x 2048 + (c mod 2048).
;    2048 cases = 25,6 rangées : image utile 640 x 400 ; les rangées 26-29
;    répètent le haut (on les met en noir par leur couleur) ;
;  - la couleur reste par case (RAM des couleurs, comme en texte).
; Le processeur atteint l'adresse A de la RAM des caractères avec la page
; vidéo ($A120 D0-D2) = A / 4096 et l'adresse $8000 + 2 x (A mod 4096).
;
; Déroulement, IRQ masquées : la page vidéo 0 sauvée en RAM page 2
; (FarWrite) ; cadre, grille, deux diagonales, un cercle ; couleurs par
; bandes de 8 colonnes, fond bleu sur les rangées 22-24 ; GRAPH pendant A
; secondes (drapeau de trame du 68B40) ; retour en texte, page 0 rendue.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

GRAPH           equ $08             ; $A120 D3
HAUT            equ 400             ; lignes utiles (25 rangées x 16)

    org     $1000

Debut:
    TSTA
    BNE     De_Duree
    LDA     #10                     ; 0 : 10 secondes
De_Duree:
    STA     Secondes
    ORCC    #%01010000
    CLR     VRAM_CTRL
    LDA     #2                      ; la page vidéo 0 (8 Ko) -> RAM page 2, $0000
    LDB     #1
    LDX     #$8000
    LDY     #$0000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarWrite]

; --- les pixels : 16 lignes r, chacune dans sa tranche de 2 Ko ---
    CLR     LigneR
Px_Ligne:
    LDA     LigneR
    LSRA                            ; page vidéo = r / 2
    STA     VRAM_CTRL
    LDX     #$8000                  ; r impair : la seconde moitié de la page
    LDA     LigneR
    BITA    #1
    BEQ     Px_Base
    LDX     #$9000
Px_Base:
    CLR     Rangee
Px_Rangee:
    LDA     Rangee                  ; y = rangée x 16 + r
    LDB     #16
    MUL
    ADDB    LigneR
    ADCA    #0
    STD     Ycour
    CLRB                            ; l'octet de base de la ligne
    LDD     Ycour
    BEQ     Px_Plein                ; y = 0 : bord du haut
    CMPD    #HAUT-1
    BEQ     Px_Plein                ; bord du bas
Px_Mod:
    SUBD    #50                     ; une ligne de grille toutes les 50
    BHI     Px_Mod
    BEQ     Px_Plein
    CLRA
    BRA     Px_Pose
Px_Plein:
    LDA     #$FF
Px_Pose:
    STA     Octet
    CLR     Col
Px_Case:
    LDA     Octet
    LDB     Col
    BITB    #7                      ; une colonne de grille toutes les 64 pixels
    BNE     Px_Pas8
    ORA     #$80
Px_Pas8:
    CMPB    #79                     ; bord droit
    BNE     Px_Ecrit
    ORA     #$01
Px_Ecrit:
    STA     ,X++
    INC     Col
    LDB     Col
    CMPB    #80
    BLO     Px_Case
    INC     Rangee
    LDA     Rangee
    CMPA    #25
    BLO     Px_Rangee
    INC     LigneR
    LDA     LigneR
    CMPA    #16
    LBLO    Px_Ligne

; --- les couleurs (page 0) : bandes de 8 colonnes, fond bleu en 22-24,
;     rangées 25-29 éteintes ($08 : premier plan noir atténué) ---
    CLR     VRAM_CTRL
    LDX     #$8001
    CLR     Rangee
Co_Rangee:
    CLR     Col
Co_Case:
    LDA     Rangee
    CMPA    #25
    BLO     Co_Visible
    LDA     #$08
    BRA     Co_Ecrit
Co_Visible:
    LDB     Col                     ; couleur = (col / 8) mod 7 + 1
    LSRB
    LSRB
    LSRB
Co_Mod7:
    CMPB    #7
    BLO     Co_Fg
    SUBB    #7
    BRA     Co_Mod7
Co_Fg:
    INCB
    TFR     B,A
    LDB     Rangee
    CMPB    #22
    BLO     Co_Ecrit
    ORA     #$10                    ; fond bleu
Co_Ecrit:
    STA     ,X++
    INC     Col
    LDA     Col
    CMPA    #80
    BLO     Co_Case
    INC     Rangee
    LDA     Rangee
    CMPA    #30
    BLO     Co_Rangee

; --- deux diagonales : x = y + y/2 + y/8 (~ 1,6 y), et son miroir ---
    LDD     #0
    STD     Ycour
Di_Ligne:
    LDD     Ycour
    STD     Py
    LSRA
    RORB
    STD     Px                      ; y/2
    LSRA
    RORB
    LSRA
    RORB                            ; y/8
    ADDD    Px
    ADDD    Ycour
    CMPD    #639
    BLS     Di_Ok
    LDD     #639
Di_Ok:
    STD     Px
    JSR     Point
    LDD     #639
    SUBD    Px
    STD     Px
    JSR     Point
    LDD     Ycour
    ADDD    #1
    STD     Ycour
    CMPD    #HAUT
    BLO     Di_Ligne

; --- un cercle, centre (320, 200), rayon 180 (point milieu) ---
    LDD     #0
    STD     Cx
    LDD     #180
    STD     Cy
    LDD     #1-180
    STD     Cd
Ce_Boucle:
    JSR     Huit
    LDD     Cd
    BPL     Ce_Dpos
    LDD     Cx                      ; d += 2x + 3
    ADDD    Cx
    ADDD    #3
    ADDD    Cd
    STD     Cd
    BRA     Ce_Suite
Ce_Dpos:
    LDD     Cx                      ; d += 2(x - y) + 5 ; y -= 1
    SUBD    Cy
    STD     Tmp
    ADDD    Tmp
    ADDD    #5
    ADDD    Cd
    STD     Cd
    LDD     Cy
    SUBD    #1
    STD     Cy
Ce_Suite:
    LDD     Cx
    ADDD    #1
    STD     Cx
    CMPD    Cy
    BLE     Ce_Boucle

; --- le mode graphique, A secondes ---
    LDA     #GRAPH                  ; page 0, GRAPH
    STA     VRAM_CTRL
    LDA     Secondes
Gr_Seconde:
    PSHS    A
    LDB     #60
Gr_Trame:
    LDA     STATUS
    BITA    #1
    BEQ     Gr_Trame
    LDX     TIMER1                  ; drapeau effacé
    DECB
    BNE     Gr_Trame
    PULS    A
    DECA
    BNE     Gr_Seconde

; --- retour en texte, la page 0 rendue ---
    CLR     VRAM_CTRL
    LDA     #2                      ; RAM page 2 -> $8000
    LDB     #1
    LDX     #$0000
    LDY     #$8000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarRead]
    LDA     STATUS
    LDX     TIMER1
    ANDCC   #%10101111
    ANDCC   #%11111110
    RTS

; Huit : les 8 points symétriques (Cx, Cy) autour de (320, 200)
Huit:
    LDX     #Paires
Hu_Point:
    LDD     [,X]                    ; dx (Cx ou Cy)
    TST     2,X
    BEQ     Hu_Plus1
    PSHS    D                       ; signe moins
    CLRA
    CLRB
    SUBD    ,S++
Hu_Plus1:
    ADDD    #320
    STD     Px
    LDD     [3,X]                   ; dy
    TST     5,X
    BEQ     Hu_Plus2
    PSHS    D
    CLRA
    CLRB
    SUBD    ,S++
Hu_Plus2:
    ADDD    #200
    STD     Py
    PSHS    X
    BSR     Point
    PULS    X
    LEAX    6,X
    CMPX    #Paires_Fin
    BLO     Hu_Point
    RTS
; (adresse de dx, signe, adresse de dy, signe) x 8
Paires:
    FDB     Cx
    FCB     0
    FDB     Cy
    FCB     0
    FDB     Cx
    FCB     1
    FDB     Cy
    FCB     0
    FDB     Cx
    FCB     0
    FDB     Cy
    FCB     1
    FDB     Cx
    FCB     1
    FDB     Cy
    FCB     1
    FDB     Cy
    FCB     0
    FDB     Cx
    FCB     0
    FDB     Cy
    FCB     1
    FDB     Cx
    FCB     0
    FDB     Cy
    FCB     0
    FDB     Cx
    FCB     1
    FDB     Cy
    FCB     1
    FDB     Cx
    FCB     1
Paires_Fin:

; Point : allume le pixel (Px, Py), 0 <= Px < 640, 0 <= Py < 400
Point:
    LDD     Py
    ANDB    #15
    STB     LigneR                  ; r
    LDD     Py
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB                            ; B = rangée (< 25)
    LDA     #80
    MUL                             ; D = rangée x 80
    STD     Tmp
    LDD     Px
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB                            ; D = colonne
    ADDD    Tmp                     ; c
    STD     Tmp
    LDX     #$8000
    LDA     LigneR                  ; r impair : seconde moitié de la page
    BITA    #1
    BEQ     Po_Base
    LDX     #$9000
Po_Base:
    LDD     Tmp
    LEAX    D,X
    LEAX    D,X                     ; X = base + 2c
    LDA     LigneR
    LSRA
    STA     VRAM_CTRL               ; page = r / 2
    LDA     Px+1
    ANDA    #7
    LDB     #$80
Po_Masque:
    TSTA
    BEQ     Po_Ou
    LSRB
    DECA
    BRA     Po_Masque
Po_Ou:
    ORB     ,X
    STB     ,X
    RTS

Secondes:   RMB     1
LigneR:     RMB     1
Rangee:     RMB     1
Col:        RMB     1
Octet:      RMB     1
Ycour:      RMB     2
Px:         RMB     2
Py:         RMB     2
Cx:         RMB     2
Cy:         RMB     2
Cd:         RMB     2
Tmp:        RMB     2
Fin:
