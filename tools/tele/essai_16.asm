; ===================================================================
; essai_16.asm - Mire graphique : 16 couleurs, une par case et par ligne
; (carte OSM39_mono, couleur 8 x 1), par TELE
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = secondes (0 : 10),
; B = épaisseur des lignes en points : 1, 2 ou 4 (0 : 1).
; IRQ masquées ; la page vidéo 0 sauvée en RAM page 2 et rendue à la fin.
; Tous les points allumés ($FF) : seul le premier plan se voit. Ligne y de
; l'écran (0-399) : la couleur (y / épaisseur) mod 16 sur toute la largeur,
; soit les 8 couleurs vives (0-7) puis atténuées (8-15, D3 = 1), fond 0,
; répétées sur tout l'écran. Épaisseur 1 : la couleur change à chaque
; ligne (8 x 1) ; 2 ou 4 : pour voir si le moniteur mélange les lignes
; voisines. R6 = 25 pendant l'essai, 30 après.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

GRAPH           equ $08             ; $A120 D3

    org     $1000

Debut:
    CLR     Decal                   ; B = épaisseur 1, 2, 4 -> 0, 1, 2 décalages
    CMPB    #2
    BLO     De_Ep
    INC     Decal
    CMPB    #4
    BLO     De_Ep
    INC     Decal
De_Ep:
    TSTA
    BNE     De_Duree
    LDA     #10
De_Duree:
    STA     Secondes
    ORCC    #%01010000
    CLR     VRAM_CTRL
    LDA     #2                      ; la page vidéo 0 (8 Ko) -> RAM page 2
    LDB     #1
    LDX     #$8000
    LDY     #$0000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarWrite]
    LDD     #$0619                  ; R6 : 25 rangées
    STA     CRTC_RS
    STB     CRTC_DATA

; --- les 16 lignes : 25 rangées de 80 cases, paires ($FF, (y / épaisseur) mod 16) ---
    CLR     Ligne
Li_Ligne:
    LDA     Ligne
    LSRA                            ; page vidéo = r / 2
    STA     VRAM_CTRL
    LDX     #$8000                  ; r impair : la seconde moitié
    LDA     Ligne
    BITA    #1
    BEQ     Li_Base
    LDX     #$9000
Li_Base:
    CLR     Rangee
Li_Rangee:
    LDB     Rangee                  ; y = 16 R + r
    LDA     #16
    MUL
    ADDB    Ligne
    ADCA    #0
    TST     Decal                   ; / épaisseur
    BEQ     Li_K
    LSRA
    RORB
    LDA     Decal
    CMPA    #2
    BLO     Li_K
    LSRB
Li_K:
    ANDB    #15
    LDA     #$FF
    LDE     #80
Li_L:
    STD     ,X++
    DECE
    BNE     Li_L
Li_Suite:
    INC     Rangee
    LDA     Rangee
    CMPA    #25
    BLO     Li_Rangee
    INC     Ligne
    LDA     Ligne
    CMPA    #16
    BLO     Li_Ligne

; --- le mode graphique, A secondes ---
    LDA     #GRAPH
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
    LDD     #$061E                  ; R6 : 30 rangées
    STA     CRTC_RS
    STB     CRTC_DATA
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

Secondes:   RMB     1
Decal:      RMB     1
Ligne:      RMB     1
Rangee:     RMB     1
Fin:
