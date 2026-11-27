; ===================================================================
; essai_mire.asm - Mire de télévision en mode graphique (carte mono), par
; TELE : pour régler la netteté d'un moniteur ou d'une caméra
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = secondes (0 : 10).
; L'image vient de tools/tele/mire_tv.py (mire_tv_data.inc, généré) :
; PixRLE = les octets de points en plages (n, octet) dans l'ordre ligne r
; (0-15), rangée (0-24), colonne (0-79) ; CoulRLE = la couleur des 2000
; cases en plages, décompressée dans CoulBuf puis mise sur les 16 lignes
; de chaque case. IRQ masquées ; la page vidéo 0 sauvée en RAM page 2 et
; rendue à la fin ; R6 = 25 pendant la mire, 30 après.
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

; --- les couleurs des cases -> CoulBuf ---
    LDY     #CoulRLE
    LDX     #CoulBuf
Co_Plage:
    LDD     ,Y++
    TSTA
    BEQ     Co_Fin
Co_Oct:
    STB     ,X+
    DECA
    BNE     Co_Oct
    BRA     Co_Plage
Co_Fin:

; --- les points : 16 lignes x 25 rangées x 80 cases ---
    LDY     #PixRLE
    CLR     Cnt
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
    LDU     #CoulBuf
    CLR     Rangee
Li_Rangee:
    LDE     #80
Li_Case:
    TST     Cnt                     ; l'octet suivant de PixRLE
    BNE     Li_Oct
    LDD     ,Y++
    STA     Cnt
    STB     Val
Li_Oct:
    DEC     Cnt
    LDA     Val
    LDB     ,U+                     ; la couleur de la case
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

Secondes:   RMB     1
Ligne:      RMB     1
Rangee:     RMB     1
Cnt:        RMB     1
Val:        RMB     1
CoulBuf:    RMB     2000
    include "mire_tv_data.inc"
Fin:
