; ===================================================================
; essai_bits.asm - Mire graphique : une ligne d'adresse de la RAM des couleurs
; (carte OSM39_mono, couleur 8 x 1), par TELE
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = secondes (0 : 10),
; B = le bit du numéro de ligne essayé (0-3), X = les deux couleurs (haut :
; bit à 0, bas : bit à 1 ; 0 : bleu $01 et jaune $06).
; IRQ masquées ; la page vidéo 0 sauvée en RAM page 2 et rendue à la fin.
; Tous les points allumés ($FF). La ligne r (0-15) de chaque case : la
; couleur basse de X si le bit B de r vaut 1, sinon la haute, sur tout
; l'écran. Deux couleurs qui ne diffèrent que d'un bit essaient ce bit de
; données d'une ligne à l'autre.
; Chaque ligne d'adresse de la RAM des couleurs (U512 A11-A14 = RA11-RA14 =
; bits 0-3 de r) a sa mire : une alternance de 1, 2, 4 ou 8 lignes si elle
; marche. R6 = 25 pendant l'essai, 30 après.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

GRAPH           equ $08             ; $A120 D3

    org     $1000

Debut:
    ANDB    #3
    STB     Decal                   ; le bit essayé
    CMPX    #0
    BNE     De_X
    LDX     #$0106                  ; bleu, jaune
De_X:
    STX     Cl0                     ; Cl0 : bit à 0, Cl1 : bit à 1
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

; --- les 16 lignes : 25 rangées de 80 cases, paires ($FF, Cl0 ou Cl1) ---
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
    LDA     Ligne                   ; le bit Decal de r -> jaune ou bleu
    LDB     Decal
Li_Dec:
    BEQ     Li_Bit
    LSRA
    DECB
    BRA     Li_Dec
Li_Bit:
    LDB     Cl0
    BITA    #1
    BEQ     Li_K
    LDB     Cl1
Li_K:
    LDA     #$FF
    LDE     #80
Li_L:
    STD     ,X++
    DECE
    BNE     Li_L
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
Cl0:        RMB     1
Cl1:        RMB     1
Ligne:      RMB     1
Rangee:     RMB     1
Fin:
