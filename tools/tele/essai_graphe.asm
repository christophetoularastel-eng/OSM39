; ===================================================================
; essai_graphe.asm - Recopier une image de la RAM page 3 vers l'écran
;                    graphique, au retour de trame (par TELE)
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = lignes de 640
; points (80 octets) recopiées par trame, B = secondes d'affichage à la fin.
; A + $80 : variante TFM. Hors de la fenêtre, chaque ligne est lue dans la
; page 3 (FarRead) et rangée en paires (point, $08) dans STG ; dans la
; fenêtre, un TFM de 160 octets par ligne. Les lignes r = 0 sont en page
; vidéo 0, dont les octets impairs SONT les couleurs des cases : elles
; gardent la boucle un octet sur deux, seules dans leur trame. Les
; « couleurs » écrites dans les pages 1-7 ne sont pas affichées (vu le
; 21 nov. 2026) ; en page 0 ($9000-$9FFF, lignes r = 1) elles sont celles
; des rangées 26-29 : on y met $08.
; Carte mono seulement.
;
; L'architecture prévue pour lib/graphe : l'image entière (640 x 400,
; 32 000 octets, ligne y à y x 80) est dessinée dans la RAM page 3 ; une
; routine posée dans gfx_tampon (RAM commune : visible quelle que soit la
; page) bascule en page 3, recopie des lignes vers la VRAM (un octet sur
; deux : les octets impairs sont la couleur), revient à la page de
; l'appelant. Elle change de pile (la pile de l'appelant peut être dans sa
; page : une NMI écrirait dans l'image).
; Ligne y -> rangée R = y / 16, ligne r = y mod 16 ; page vidéo r / 2 ;
; adresse $8000 + (r mod 2) x $1000 + 160 R (+ 2 par octet).
;
; Déroulement, IRQ masquées : page vidéo 0 sauvée en RAM page 2 ; image
; de test dans la page 3 (cadre, grille, diagonales) ; les 8 pages vidéo
; mises à 0, couleurs par bandes ; mesure (comme essai_cycles) du coût de
; A lignes ; puis GRAPH, et l'image arrive A lignes par trame juste après
; le signal de trame ; B secondes ; retour au texte.
; Sortie : D = trames pour toute l'image, X = tours de boucle par trame,
; Y = tours restants sans rien, U = tours restants après A lignes.
; Cycles(A lignes) = (Y - U) x 30 751 / X.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

GRAPH           equ $08             ; $A120 D3
HAUT            equ 400
LIGNE           equ $3000           ; une ligne de 80 octets, page 1
TMP             equ $3100           ; une ligne lue dans la page 3
STG             equ $3200           ; lignes en paires (point, 0) : 8 x 160
TAB             equ $3700           ; par ligne : page vidéo, adresse VRAM
NMAX            equ 8
; variables et pile de la routine, dans gfx_tampon (après son code)
G_Y             equ gfx_tampon+$1E0 ; prochaine ligne à recopier
G_SRC           equ gfx_tampon+$1E2 ; son adresse dans la page 3
G_S             equ gfx_tampon+$1E4 ; pile de l'appelant
G_N             equ gfx_tampon+$1E6 ; lignes restant pour cet appel
G_M             equ gfx_tampon+$1E7 ; GRAPH ou 0
G_H             equ gfx_tampon+$1E8
G_PILE          equ gfx_tampon+$1E0 ; pile (descend vers le code)

    org     $1000

Entree:
    PSHS    CC
    ORCC    #%01010000
    STA     Mode
    ANDA    #$7F
    STA     Nlig
    STB     Secondes
    CLR     VRAM_CTRL
    LDA     #2                      ; la page vidéo 0 (8 Ko) -> RAM page 2
    LDB     #1
    LDX     #$8000
    LDY     #$0000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarWrite]

; --- la routine dans gfx_tampon ---
    LDX     #Copie
    LDY     #gfx_tampon
    LDW     #Copie_Fin-Copie
    TFM     X+,Y+

; --- l'image de test dans la page 3 ---
    LDD     #0
    STD     Ycour
    STD     Yoff
Im_Ligne:
    LDD     Ycour                   ; octet de base : cadre et grille (50)
    BEQ     Im_Plein
    CMPD    #HAUT-1
    BEQ     Im_Plein
Im_Mod:
    SUBD    #50
    BHI     Im_Mod
    BEQ     Im_Plein
    CLRA
    BRA     Im_Base
Im_Plein:
    LDA     #$FF
Im_Base:
    LDX     #LIGNE
    CLRB
Im_Oct:
    PSHS    A
    BITB    #7
    BNE     Im_P8
    ORA     #$80
Im_P8:
    CMPB    #79
    BNE     Im_Pose
    ORA     #$01
Im_Pose:
    STA     ,X+
    PULS    A
    INCB
    CMPB    #80
    BLO     Im_Oct
    LDD     Ycour                   ; diagonales : x = y + y/2 + y/8
    LSRA
    RORB
    STD     Px
    LSRA
    RORB
    LSRA
    RORB
    ADDD    Px
    ADDD    Ycour
    CMPD    #639
    BLS     Im_DOk
    LDD     #639
Im_DOk:
    STD     Px
    BSR     Allume
    LDD     #639
    SUBD    Px
    STD     Px
    BSR     Allume
    LDA     #3                      ; la ligne -> page 3, y x 80
    LDB     #1
    LDX     #LIGNE
    LDY     Yoff
    LDU     #80
    JSR     [table_function_ram+sys_FarWrite]
    LDD     Yoff
    ADDD    #80
    STD     Yoff
    LDD     Ycour
    ADDD    #1
    STD     Ycour
    CMPD    #HAUT
    LBLO    Im_Ligne
    BRA     Vide

; Allume : le point Px dans LIGNE
Allume:
    LDD     Px
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LDX     #LIGNE
    ABX
    LDA     Px+1
    ANDA    #7
    LDB     #$80
Al_Masque:
    TSTA
    BEQ     Al_Ou
    LSRB
    DECA
    BRA     Al_Masque
Al_Ou:
    ORB     ,X
    STB     ,X
    RTS

; --- les 8 pages vidéo à 0 (TFM qui se recouvre), couleurs en page 0 ---
Vide:
    CLRA
Vi_Page:
    STA     VRAM_CTRL
    CLR     $8000
    LDU     #$8000
    LDX     #$8001
    LDW     #$1FFF
    TFM     U+,X+
    INCA
    CMPA    #8
    BLO     Vi_Page
    CLR     VRAM_CTRL
    LDX     #$8001
    CLR     Rangee
Co_Rangee:
    CLR     Col
Co_Case:
    LDA     Rangee
    CMPA    #25
    BLO     Co_Visible
    LDA     #$08                    ; rangées 25-29 : premier plan noir
    BRA     Co_Ecrit
Co_Visible:
    LDB     Col                     ; (col / 8) mod 7 + 1
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

; --- mesure : tours d'une trame, reste sans rien, reste après N lignes ---
    CLR     G_M
    LBSR    Mesure
    LBSR    Signal
    LBSR    Compte
    STX     Reste0
    TST     Mode
    BMI     Me_Tfm
    LDD     #0
    STD     G_Y
    STD     G_SRC
    LBSR    Signal
    LDA     Nlig
    JSR     gfx_tampon
    LBSR    Compte
    STX     Reste
    BRA     Me_Fin
Me_Tfm:                             ; N lignes TFM à partir de y = 1
    LBSR    Signal                  ; le drapeau resté levé par Compte
    LDD     #1
    STD     Ty
    LBSR    Prepare
    LBSR    Signal
    LBSR    Fenetre
    LBSR    Compte
    STX     Reste
Me_Fin:

; --- l'image, N lignes par trame, en mode graphique ---
    LDD     #0
    STD     G_Y
    STD     G_SRC
    STD     Trames
    LDA     #GRAPH
    STA     G_M
    STA     VRAM_CTRL
    TST     Mode
    BPL     Gr_Trame
    LDD     #0
    STD     Ty
Gt_Trame:
    LBSR    Prepare
    LBSR    Signal
    LBSR    Fenetre
    LDD     Trames
    ADDD    #1
    STD     Trames
    LDD     Ty
    CMPD    #HAUT
    BLO     Gt_Trame
    BRA     Gr_Fin
Gr_Trame:
    LBSR    Signal
    LDA     Nlig
    JSR     gfx_tampon
    LDD     Trames
    ADDD    #1
    STD     Trames
    LDD     G_Y
    CMPD    #HAUT
    BLO     Gr_Trame
Gr_Fin:
    LDA     Secondes
    BEQ     Retour
Gr_Seconde:
    LDB     #60
Gr_Att:
    PSHS    B
    LBSR    Signal
    PULS    B
    DECB
    BNE     Gr_Att
    DEC     Secondes
    BNE     Gr_Seconde

; --- retour en texte, la page 0 rendue ---
Retour:
    CLR     VRAM_CTRL
    LDA     #2
    LDB     #1
    LDX     #$0000
    LDY     #$8000
    LDU     #$2000
    JSR     [table_function_ram+sys_FarRead]
    LDA     STATUS
    LDX     TIMER1
    LDD     Trames
    LDX     Tours
    LDY     Reste0
    LDU     Reste
    PULS    CC,PC

; Prepare : à partir de la ligne Ty, jusqu'à Nlig lignes dans STG (ou
; une seule ligne r = 0, à part). Tn = lignes prêtes, Tdeb = la première,
; T0 <> 0 : c'est une ligne r = 0 (dans TMP, non entrelacée).
Prepare:
    CLR     Tn
    CLR     T0
    LDD     Ty
    STD     Tdeb
    LDX     #TAB
    STX     Ttab
    LDY     #STG
Pr_Ligne:
    LDD     Ty
    CMPD    #HAUT
    BHS     Pr_Fin
    LDA     Tn
    CMPA    Nlig
    BHS     Pr_Fin
    ANDB    #15
    BNE     Pr_Lit
    TST     Tn                      ; r = 0 : seule dans sa trame
    BNE     Pr_Fin
    INC     T0
Pr_Lit:
    PSHS    Y
    LDD     Ty                      ; page et adresse VRAM, hors fenêtre
    BSR     VAdr
    LDY     Ttab
    STA     ,Y+
    STX     ,Y++
    STY     Ttab
    LDD     Ty                      ; FarRead page 3, y x 80 -> TMP
    LDA     #80
    MUL                             ; (y mod 256) x 80 : faux au-delà
    PSHS    D
    LDA     Ty                      ; + (y / 256) x 256 x 80
    LDB     #80
    MUL
    TFR     B,A
    CLRB
    ADDD    ,S++
    TFR     D,X
    LDA     #3
    LDB     #1
    LDY     #TMP
    LDU     #80
    JSR     [table_function_ram+sys_FarRead]
    PULS    Y
    INC     Tn
    LDD     Ty
    ADDD    #1
    STD     Ty
    TST     T0
    BNE     Pr_Fin
    LDX     #TMP                    ; entrelacement : (point, $08). Les
    LDF     #80                     ; lignes r = 1 tombent en page vidéo 0,
    LDB     #$08                    ; $9000-$9FFF : leurs octets impairs sont
Pr_Oct:                             ; les couleurs des rangées 26-29 (qui
    LDA     ,X+                     ; répètent le haut) : $08 les cache
    STD     ,Y++
    DECF
    BNE     Pr_Oct
    BRA     Pr_Ligne
Pr_Fin:
    RTS

; VAdr : D = y -> X = adresse VRAM, A = page vidéo | GRAPH (G_M).
VAdr:
    PSHS    D
    ANDB    #15
    TFR     B,A
    LSRA
    ORA     G_M
    STA     Vpage
    LDA     #$80
    BITB    #1
    BEQ     Va_Pair
    LDA     #$90
Va_Pair:
    STA     G_H
    PULS    D
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LDA     #160
    MUL
    ADDA    G_H
    TFR     D,X
    LDA     Vpage
    RTS

; Fenetre : juste après le signal, recopie ce que Prepare a rangé.
Fenetre:
    LDY     #TAB
    TST     T0
    BEQ     Fe_Tfm
    LDA     ,Y+                     ; ligne r = 0 : un octet sur deux
    STA     VRAM_CTRL
    LDX     ,Y
    LDU     #TMP
    LDE     #40
Fe_Oct:
    LDD     ,U++
    STA     ,X
    STB     2,X
    LEAX    4,X
    DECE
    BNE     Fe_Oct
    BRA     Fe_Fin
Fe_Tfm:
    LDU     #STG
    LDB     Tn
    BEQ     Fe_Fin
Fe_Ligne:
    LDA     ,Y+
    STA     VRAM_CTRL
    LDX     ,Y++
    LDW     #160
    TFM     U+,X+
    DECB
    BNE     Fe_Ligne
Fe_Fin:
    LDA     G_M
    STA     VRAM_CTRL
    RTS

; Signal : attend le drapeau du timer 1 et l'efface. Détruit A, X.
Signal:
    LDA     STATUS
    BITA    #1
    BEQ     Signal
    LDX     TIMER1
    RTS

; Compte : X = tours de boucle jusqu'au prochain signal (sans l'effacer).
Compte:
    LDX     #0
Cp_Tour:
    LEAX    1,X
    LDA     STATUS
    BITA    #1
    BEQ     Cp_Tour
    RTS

; Mesure : Tours = tours de boucle pendant une trame (la dernière de 4).
Mesure:
    LDB     #4
Me_Trame:
    PSHS    B
    BSR     Signal
    BSR     Compte
    STX     Tours
    PULS    B
    DECB
    BNE     Me_Trame
    RTS

; ===================================================================
; Copie : recopiée dans gfx_tampon (code sans adresse propre : branches
; relatives, variables à des adresses fixes de gfx_tampon). A = lignes ;
; IRQ masquées. Détruit tout sauf S, rend la page de l'appelant.
; ===================================================================
Copie:
    STS     G_S
    LDS     #G_PILE
    STA     G_N
    LDA     #3
    STA     pager_reg
Co_Ligne:
    TST     G_N
    BEQ     Co_Fin
    LDD     G_Y
    CMPD    #HAUT
    BHS     Co_Fin
    ANDB    #15                     ; r
    TFR     B,A
    LSRA
    ORA     G_M
    STA     VRAM_CTRL               ; page vidéo r / 2
    LDA     #$80
    BITB    #1
    BEQ     Co_Pair
    LDA     #$90
Co_Pair:
    STA     G_H
    LDD     G_Y
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB                            ; B = R
    LDA     #160
    MUL
    ADDA    G_H
    TFR     D,Y
    LDX     G_SRC
    LDE     #40
Co_Oct:
    LDD     ,X++
    STA     ,Y
    STB     2,Y
    LEAY    4,Y
    DECE
    BNE     Co_Oct
    STX     G_SRC
    LDD     G_Y
    ADDD    #1
    STD     G_Y
    DEC     G_N
    BRA     Co_Ligne
Co_Fin:
    LDA     G_M
    STA     VRAM_CTRL
    LDA     current_page
    STA     pager_reg
    LDS     G_S
    RTS
Copie_Fin:

Nlig:       RMB     1
Mode:       RMB     1
Ty:         RMB     2
Tdeb:       RMB     2
Tcur:       RMB     2
Tn:         RMB     1
Tk:         RMB     1
T0:         RMB     1
Vpage:      RMB     1
Ttab:       RMB     2
Secondes:   RMB     1
Rangee:     RMB     1
Col:        RMB     1
Ycour:      RMB     2
Yoff:       RMB     2
Px:         RMB     2
Trames:     RMB     2
Tours:      RMB     2
Reste0:     RMB     2
Reste:      RMB     2
