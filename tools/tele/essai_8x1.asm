; ===================================================================
; essai_8x1.asm - Une couleur par ligne de 8 points en mode graphique
; (carte OSM39_mono avec U512 A11-A14 sur RA11-RA14), par TELE
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = secondes (0 : 10).
; IRQ masquées ; la page vidéo 0 sauvée en RAM page 2 et rendue à la fin.
;
; Chaque octet de points vaut $FF : seul le premier plan se voit.
;   - rangées 0-11 : la couleur de la ligne r (0-15) de chaque case vient
;     de CoulL[r] : premier plan (r mod 7) + 1. Avec le câblage 8 x 1 :
;     16 lignes horizontales d'un point, de couleurs différentes, par
;     rangée de texte ;
;     sans lui : toute la case prend la couleur de sa ligne 0 ;
;   - rangées 12-24 : une couleur par case (CoulR[rangée]) sur ses 16
;     lignes, comme le BIOS : des blocs unis, pour comparer.
; R6 = 25 pendant l'essai (les rangées 26-29 répéteraient le haut), 30
; après. Ligne r de la case c : page vidéo r / 2, adresse $8000 + (r mod 2)
; x $1000 + 2c (points), la couleur à l'octet suivant.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

GRAPH           equ $08             ; $A120 D3

    org     $1000

Debut:
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

; --- les 16 lignes : 25 rangées de 80 cases, paires ($FF, couleur) ---
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
    LDU     #CoulL                  ; rangées 0-11 : la couleur de la ligne
    LDB     Ligne
    LDA     Rangee
    CMPA    #12
    BLO     Li_Coul
    LDU     #CoulR                  ; rangées 12-24 : celle de la rangée
    LDB     Rangee
Li_Coul:
    LDB     B,U
    LDA     #$FF
    LDE     #80
Li_Case:
    STD     ,X++
    DECE
    BNE     Li_Case
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

; premier plan (k mod 7) + 1, fond 7 - premier plan
CoulL:  FCB     $61,$52,$43,$34,$25,$16,$07,$61,$52,$43,$34,$25,$16,$07,$61,$52
CoulR:  FCB     $61,$52,$43,$34,$25,$16,$07,$61,$52,$43,$34,$25,$16,$07,$61,$52
        FCB     $43,$34,$25,$16,$07,$61,$52,$43,$34

Secondes:   RMB     1
Ligne:      RMB     1
Rangee:     RMB     1
Fin:
