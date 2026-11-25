; ===================================================================
; essai_neige_gr.asm - La neige en mode graphique : écrire la VRAM
; pendant l'affichage (carte OSM39_mono, par TELE)
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = mode, B = secondes
; (0 : 10). IRQ masquées ; la page vidéo 0 est sauvée en RAM page 2 et
; rendue à la fin (les pages 1-7, qui ne servent qu'au mode graphique,
; gardent l'image d'essai).
;
; Image fixe : moitié haute noire (pixels $00), moitié basse blanche ($FF),
; blanc sur noir ($07) sur les rangées 0-24, $08 au-delà. Puis, pendant
; B secondes en mode graphique :
;   A = 0 : rien (la référence : l'image doit être nette)
;   A = 1 : chaque page vidéo recopiée SUR ELLE-MÊME par TFM, sans arrêt,
;           pendant tout l'affichage. Les octets ne changent pas : tout ce
;           qui bouge à l'écran est de la neige (les accès du processeur)
;   A = 2 : des barres verticales qui défilent, écrites sans arrêt dans
;           les lignes paires (première moitié de chaque page) : le cas
;           d'un jeu
;   A = 3 : lectures seules, sans arrêt (TFM de la VRAM vers la RAM)
;   A = 4 : les mêmes barres, mais 480 octets par trame, juste après le
;           signal de trame (la fenêtre permise) : pour comparer avec 2
; Sortie : X = trames comptées (doit valoir B x 60).
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

GRAPH           equ $08             ; $A120 D3
TAMPON          equ $2000           ; page 1 : barres (4096 + 32 octets)
FENETRE         equ 480             ; octets par trame en mode 4

    org     $1000

Debut:
    STA     Mode
    TSTB
    BNE     De_Duree
    LDB     #10
De_Duree:
    LDA     #60
    MUL
    STD     Trames
    CLRA
    CLRB
    STD     Compte
    ORCC    #%01010000
    CLR     VRAM_CTRL
    LDA     #2                      ; la page vidéo 0 (8 Ko) -> RAM page 2
    LDB     #1
    LDX     #$8000
    LDY     #$0000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarWrite]

; --- l'image fixe, dans les 8 pages ---
    CLR     Page
Im_Page:
    LDA     Page
    STA     VRAM_CTRL
    LDX     #$8000                  ; X : la case c (0-4095 : 2 moitiés)
    CLRA
    CLRB
    STD     Cel
Im_Case:
    LDD     Cel
    ANDA    #$07                    ; c mod 2048
    CMPD    #1000                   ; y < 200 : noir
    BLO     Im_Noir
    LDA     #$FF
    BRA     Im_Pix
Im_Noir:
    CLRA
Im_Pix:
    STA     ,X+
    LDD     Cel                     ; couleur : rangées 0-24 = cases 0-1999
    CMPD    #2000
    BLO     Im_Blanc
    LDA     #$08
    BRA     Im_Coul
Im_Blanc:
    LDA     #$07
Im_Coul:
    STA     ,X+
    LDD     Cel
    ADDD    #1
    STD     Cel
    CMPD    #4096
    BLO     Im_Case
    INC     Page
    LDA     Page
    CMPA    #8
    BLO     Im_Page

; --- le tampon des barres : 16 cases blanches, 16 noires, couleur $07 ---
    LDX     #TAMPON
    CLRA
    CLRB
    STD     Cel
Ta_Case:
    LDA     Cel+1
    BITA    #16
    BEQ     Ta_Noir
    LDA     #$FF
    BRA     Ta_Pix
Ta_Noir:
    CLRA
Ta_Pix:
    LDB     #$07
    STD     ,X++
    LDD     Cel
    ADDD    #1
    STD     Cel
    CMPD    #2048+16
    BLO     Ta_Case

; --- l'essai ---
    CLR     Page
    CLR     Decal
    LDA     #GRAPH
    STA     VRAM_CTRL
    LDA     STATUS                  ; drapeau de trame effacé
    LDX     TIMER1
Es_Boucle:
    LDA     Mode
    CMPA    #1
    BEQ     Es_Copie
    CMPA    #2
    BEQ     Es_Barres
    CMPA    #3
    BEQ     Es_Lit
    CMPA    #4
    BEQ     Es_Fenetre
    LBSR    Trame                   ; 0 : on attend
    BRA     Es_Fin

Es_Copie:                           ; 1 : une page sur elle-même
    LBSR    Choisit
    LDX     #$8000
    LDY     #$8000
    LDW     #$2000
    TFM     X+,Y+
    LBSR    Suivante
    BRA     Es_Fin

Es_Barres:                          ; 2 : les barres, sans attendre
    LBSR    Choisit
    LBSR    Barres
    LBSR    Suivante
    BRA     Es_Fin

Es_Lit:                             ; 3 : lectures seules
    LBSR    Choisit
    LDX     #$8000
    LDY     #TAMPON+$1100
    LDW     #$1000
    TFM     X+,Y+
    LBSR    Suivante
    BRA     Es_Fin

Es_Fenetre:                         ; 4 : dans la fenêtre seulement
Ef_Attend:
    LDA     STATUS
    BITA    #1
    BEQ     Ef_Attend
    LDX     TIMER1
    LDD     Compte
    ADDD    #1
    STD     Compte
    LBSR    Choisit
    LDB     Decal                   ; source : tampon + 2 x décalage
    CLRA
    LSLB
    LDX     #TAMPON
    ABX
    LDY     #$8000
    LDW     #FENETRE
    TFM     X+,Y+
    LDA     Page
    INCA
    ANDA    #7
    STA     Page
    BNE     Es_Fin
    LDA     Decal
    INCA
    ANDA    #15
    STA     Decal
Es_Fin:
    LDD     Compte
    CMPD    Trames
    LBLO    Es_Boucle

; --- retour en texte, la page 0 rendue ---
    CLR     VRAM_CTRL
    LDA     #2
    LDB     #1
    LDX     #$0000
    LDY     #$8000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarRead]
    LDA     STATUS
    LDX     TIMER1
    LDX     Compte
    ANDCC   #%10101111
    ANDCC   #%11111110
    RTS

; Trame : compte un signal de trame s'il est là (C = 1 si oui)
Trame:
    LDA     STATUS
    BITA    #1
    BEQ     Tr_Non
    LDX     TIMER1
    LDD     Compte
    ADDD    #1
    STD     Compte
    ORCC    #1
    RTS
Tr_Non:
    ANDCC   #%11111110
    RTS

; Choisit : la page vidéo Page, en mode graphique
Choisit:
    LDA     Page
    ORA     #GRAPH
    STA     VRAM_CTRL
    RTS

; Suivante : compte la trame, page suivante ; après la page 7 les barres
; avancent d'une case
Suivante:
    LBSR    Trame
    LDA     Page
    INCA
    ANDA    #7
    STA     Page
    BNE     Su_Fin
    LDA     Decal
    INCA
    ANDA    #15
    STA     Decal
Su_Fin:
    RTS

; Barres : la première moitié de la page (lignes paires) <- le tampon
Barres:
    LDB     Decal
    CLRA
    LSLB
    LDX     #TAMPON
    ABX
    LDY     #$8000
    LDW     #$1000
    TFM     X+,Y+
    RTS

Mode:       RMB     1
Page:       RMB     1
Decal:      RMB     1
Cel:        RMB     2
Trames:     RMB     2
Compte:     RMB     2
Fin:
