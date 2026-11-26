; ===================================================================
; graphe.asm - Le mode graphique de la carte OSM39_mono (BIOS2)
; ===================================================================
; 640 x 400 points, 1 bit par point (bit 7 à gauche). Une couleur par
; case de 8 x 16 pour le service, écrite dans ses 16 lignes : la RAM des
; couleurs (U512) est adressée comme celle des points (RA11-RA14, depuis le
; 26 nov. 2026), une couleur par ligne de 8 points. Le modèle exact (ce que chaque fonction allume) et la
; liste des fonctions : tools/graphe/graphe.py. Service sys_Graphe :
; B = fonction, X = bloc de paramètres (mots signés), A = mode/couleur ;
; tout est préservé, sauf A pour GR_LIT ; C = 1 : refusé.
;
; L'image est DESSINÉE dans la RAM page 3 (ligne y à y x 80, 32 000
; octets ; la police 8 x 8 de /BIN/POLICE8 en $7D00) : le service passe
; en page 3 (current_page suit, comme Far_Call) sur sa propre pile
; (gr_pile, RAM système : la pile de l'appelant peut être dans sa page).
; Chaque ligne modifiée est marquée dans gr_sale APRÈS l'écriture.
;
; L'IRQ du VSYNC (X_Gr_IRQ, appelée au début de handler_IRQ tant que
; gr_actif <> 0 ; la console et le moulinet se taisent) :
;   1. dans la fenêtre du retour de trame : recopie la ligne préparée à
;      la trame d'avant (un octet sur deux : les octets impairs sont ses
;      couleurs) ; ou, s'il n'y en a pas, un pas de l'effacement (gr_ef :
;      EF_N octets de paires (0, couleur) par TFM) ou de la tâche de
;      couleur (GC_N cases, chacune dans ses 16 lignes) ;
;   2. après : prépare la ligne marquée suivante dans gfx_tampon (page 3
;      lue sur la pile gr_pirq), sauf si une couleur ou un effacement
;      attend.
; Ligne y -> rangée R = y / 16, r = y mod 16 ; page vidéo r / 2 ; adresse
; $8000 + (r mod 2) x $1000 + 160 R + 2 x octet ; sa couleur à l'octet
; suivant. Le 6845 n'affiche que 25 rangées en mode graphique (R6 = 25) :
; les rangées 26-29 répéteraient le haut, couleurs comprises.
; Banc sur la carte : tools/tele/essai_graphe.asm.
; ===================================================================
    include "hardware.inc"

    import  gr_actif, gr_sale, gr_np, gr_r0, gr_n2, gr_m, gr_yc, gr_src
    import  gr_cc, gr_cx, gr_cw, gr_cn, gr_ca
    import  gr_s, gr_pg, gr_sirq, gr_fn, gr_cc0, gr_mode, gr_par, gr_res
    import  gr_x, gr_y, gr_x1, gr_y1, gr_dx, gr_dy, gr_sx, gr_sy, gr_err, gr_e2
    import  gr_hx0, gr_hx1, gr_hn, gr_plein, gr_s2
    import  gr_pile_h, gr_pirq_h
    import  cz_actif, char_attribut, ecran_abime, sys_ClearScreen, Zone_Cls, Format_Filename_83, FS_LoadFile
    import  SCREEN_START_OFFSET, CUR_PAGE
    export  X_Graphe, X_Gr_IRQ

GRAPH           equ $08             ; $A120 D3
LARG            equ 640
HAUT            equ 400
GR_STG          equ gfx_tampon      ; 3 lignes x 160 octets
GR_TAB          equ gfx_tampon+480  ; 3 x (page vidéo, adresse)
POLICE          equ 32000           ; $7D00 en page 3
GR_N            equ 12
EF_N            equ 420             ; effacement : octets par trame (TFM)
GC_N            equ 7               ; tâche de couleur : cases par trame
gr_ef           equ gr_r0           ; effacement : page + 1 (0 : aucun)
gr_eo           equ gr_src+2        ;   l'adresse suivante dans la page

    section .ext

; ===================================================================
; Le service
; ===================================================================
X_Graphe:
    pshs    cc,d,x,y,u
    pshsw
    cmpb    #GR_N
    lbhs    Gx_Refus
    tstb
    beq     Gx_Ok
    tst     gr_actif
    lbeq    Gx_Refus
Gx_Ok:
    sta     gr_mode
    stb     gr_fn
    lda     2,s                     ; CC de l'appelant (bit I : les attentes)
    sta     gr_cc0
    ldd     ,x                      ; le bloc, lu dans la page de l'appelant
    std     gr_par
    ldd     2,x
    std     gr_par+2
    ldd     4,x
    std     gr_par+4
    ldd     6,x
    std     gr_par+6
    sts     gr_s
    lds     #gr_pile_h
    lda     current_page
    sta     gr_pg
    lda     #3                      ; current_page d'abord : l'IRQ y revient
    sta     current_page
    sta     pager_reg
    ldb     gr_fn
    lslb
    ldx     #Gr_Table
    jsr     [b,x]
    lda     gr_pg
    sta     current_page
    sta     pager_reg
    lds     gr_s
    lda     gr_fn
    cmpa    #7                      ; GR_LIT : A = le point
    bne     Gx_Fin
    lda     gr_res
    sta     3,s
Gx_Fin:
    pulsw
    puls    cc,d,x,y,u
    andcc   #$FE
    rts
Gx_Refus:
    pulsw
    puls    cc,d,x,y,u
    orcc    #1
    rts

Gr_Table:
    fdb     Gr_Debut,Gr_Fin,Gr_Point,Gr_Ligne,Gr_Rect,Gr_Cercle,Gr_Disque
    fdb     Gr_Lit,Gr_Efface,Gr_Car,Gr_Couleur,Gr_Attend

Masques:    fcb     $80,$40,$20,$10,$08,$04,$02,$01
Gauche:     fcb     $FF,$7F,$3F,$1F,$0F,$07,$03,$01
Droite:     fcb     $80,$C0,$E0,$F0,$F8,$FC,$FE,$FF
NomPolice:  fcn     "POLICE8"

; ===================================================================
; Ouvrir et fermer le mode graphique (IRQ masquées pendant le travail)
; ===================================================================
Gr_Debut:
    pshs    cc
    orcc    #%01010000
    clr     gr_actif
    clr     gr_np
    clr     gr_cn
    clr     gr_ef
    ldx     #gr_sale
    ldb     #50
Gd_Sale:
    clr     ,x+
    decb
    bne     Gd_Sale
    ldd     #$0A2D                  ; R10 : curseur caché
    lbsr     Crtc
    ldd     #$0CFF                  ; R12/R13 = $FFFF (comme le texte)
    lbsr     Crtc
    ldd     #$0DFF
    lbsr     Crtc
    ldd     #$0619                  ; R6 : 25 rangées affichées
    lbsr     Crtc
    ldd     #-1
    std     SCREEN_START_OFFSET
    lda     gr_mode                 ; les 8 pages : (0, attribut)
    lbsr    Remplit
    clr     0                       ; l'image (page 3) à 0
    ldu     #0
    ldx     #1
    ldw     #POLICE-1
    tfm     u+,x+
    ldx     #POLICE                 ; police absente : vide
    clr     ,x
    ldu     #POLICE
    leax    1,x
    ldw     #768-1
    tfm     u+,x+
    sts     gr_s2                   ; le chargement sur une pile plus grande :
    lds     #gfx_tampon+512         ; gfx_tampon (l'IRQ ne s'en sert pas encore)
    ldx     #NomPolice
    ldy     #gfx_tampon             ; le nom formaté
    jsr     Format_Filename_83
    lda     #3
    ldx     #gfx_tampon
    ldy     #POLICE
    jsr     FS_LoadFile
    lds     gr_s2
    lda     #GRAPH
    sta     VRAM_CTRL
    clr     CUR_PAGE
    inc     gr_actif
    puls    cc,pc

; Crtc : A = registre du 68B45, B = valeur
Crtc:
    sta     CRTC_RS
    stb     CRTC_DATA
    rts

Gr_Fin:
    pshs    cc
    orcc    #%01010000
    clr     gr_actif
    clr     gr_np
    clr     gr_cn
    clr     gr_ef
    clr     VRAM_CTRL
    clr     CUR_PAGE
    ldd     #$061E                  ; R6 : 30 rangées (le texte)
    bsr     Crtc
    tst     cz_actif                ; console plein écran : tout effacé
    bne     Gf_Zone
    jsr     sys_ClearScreen
    bra     Gf_Curseur
Gf_Zone:                                ; Terminal : l'écran en noir ($08),
    lda     char_attribut           ; la zone à sa couleur ; ecran_abime :
    ldb     cz_actif                ; le SHELL fait redessiner le bureau
    pshs    d
    lda     #$08
    sta     char_attribut
    clr     cz_actif
    jsr     sys_ClearScreen
    puls    d
    sta     char_attribut
    stb     cz_actif
    jsr     Zone_Cls
    lda     #1                      ; le SHELL fera redessiner OSM-VISION
    sta     ecran_abime
Gf_Curseur:
    ldd     #$0A6D                  ; curseur visible (CURSEUR_VISIBLE)
    bsr     Crtc
    puls    cc,pc

; ===================================================================
; Les points
; ===================================================================
; Pt : le point (gr_x, gr_y) selon gr_mode. Détruit D, X, U.
Pt:
    ldd     gr_y
    cmpd    #HAUT
    bhs     Pt_Fin
    ldd     gr_x
    cmpd    #LARG
    bhs     Pt_Fin
    bsr     Adr
    ldb     gr_x+1
    andb    #7
    ldu     #Masques
    lda     b,u
    bsr     Applique
    ldd     gr_y
    bra     Sale
Pt_Fin:
    rts

; Applique : A = masque, à l'octet ,X selon gr_mode. Détruit A, B.
Applique:
    ldb     gr_mode
    beq     Ap_Ou
    decb
    beq     Ap_Et
    eora    ,x
    sta     ,x
    rts
Ap_Ou:
    ora     ,x
    sta     ,x
    rts
Ap_Et:
    coma
    anda    ,x
    sta     ,x
    rts

; Adr : X = gr_y x 80 + gr_x / 8. Détruit D.
Adr:
    ldd     gr_y
    bsr     Fois80
    pshs    d
    ldd     gr_x
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    addd    ,s++
    tfr     d,x
    rts

; Fois80 : D = D x 80 (D < 820)
Fois80:
    lslb
    rola
    lslb
    rola
    lslb
    rola
    lslb
    rola
    pshs    d                       ; x 16
    lslb
    rola
    lslb
    rola                            ; x 64
    addd    ,s++
    rts

; Sale : la ligne D (0-399) est à recopier. Détruit D, X, U.
Sale:
    pshs    b
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    ldx     #gr_sale
    abx
    puls    a
    anda    #7
    ldu     #Masques
    lda     a,u
    ora     ,x
    sta     ,x
    rts

Gr_Point:
    ldd     gr_par
    std     gr_x
    ldd     gr_par+2
    std     gr_y
    lbra     Pt

Gr_Lit:
    clr     gr_res
    ldd     gr_par
    std     gr_x
    cmpd    #LARG
    bhs     Gl_Fin
    ldd     gr_par+2
    std     gr_y
    cmpd    #HAUT
    bhs     Gl_Fin
    bsr     Adr
    ldb     gr_x+1
    andb    #7
    ldu     #Masques
    lda     b,u
    anda    ,x
    beq     Gl_Fin
    inc     gr_res
Gl_Fin:
    rts

; ===================================================================
; Ligne (Bresenham, chaque point une fois)
; ===================================================================
Gr_Ligne:
    ldd     gr_par
    std     gr_x
    ldd     gr_par+2
    std     gr_y
    ldd     gr_par+4
    std     gr_x1
    ldd     gr_par+6
    std     gr_y1
    ldx     #1
    ldd     gr_x1
    subd    gr_x
    bge     Gli_Dx
    ldx     #-1
    bsr     Neg
Gli_Dx:
    std     gr_dx
    stx     gr_sx
    ldx     #1
    ldd     gr_y1
    subd    gr_y
    bge     Gli_Dy
    ldx     #-1
    bsr     Neg
Gli_Dy:
    stx     gr_sy
    bsr     Neg                     ; dy = -|y1 - y0|
    std     gr_dy
    addd    gr_dx
    std     gr_err
Gli_Point:
    lbsr    Pt
    ldd     gr_x
    cmpd    gr_x1
    bne     Gli_Pas
    ldd     gr_y
    cmpd    gr_y1
    beq     Gli_Fin
Gli_Pas:
    ldd     gr_err
    addd    gr_err
    std     gr_e2
    cmpd    gr_dy
    blt     Gli_Y
    ldd     gr_err
    addd    gr_dy
    std     gr_err
    ldd     gr_x
    addd    gr_sx
    std     gr_x
Gli_Y:
    ldd     gr_e2
    cmpd    gr_dx
    bgt     Gli_Point
    ldd     gr_err
    addd    gr_dx
    std     gr_err
    ldd     gr_y
    addd    gr_sy
    std     gr_y
    bra     Gli_Point
Gli_Fin:
    rts

; Neg : D = -D (sans NEGD)
Neg:
    coma
    comb
    addd    #1
    rts

; ===================================================================
; Travées et rectangles
; ===================================================================
; Hl : les points gr_hx0..gr_hx1 (gr_hx0 <= gr_hx1) de la ligne gr_y,
; coupés à l'écran. Détruit tout sauf Y.
Hl:
    ldd     gr_y
    cmpd    #HAUT
    lbhs     Hl_Fin
    ldd     gr_hx1
    lbmi     Hl_Fin
    ldd     gr_hx0
    cmpd    #LARG
    bge     Hl_Fin
    tsta
    bpl     Hl_G
    ldd     #0
    std     gr_hx0
Hl_G:
    ldd     gr_hx1
    cmpd    #LARG-1
    ble     Hl_D
    ldd     #LARG-1
    std     gr_hx1
Hl_D:
    ldd     gr_hx0
    std     gr_x
    lbsr    Adr                     ; X = premier octet
    ldd     gr_hx1                  ; E = octets après le premier
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    stb     gr_hn
    ldd     gr_hx0
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    negb
    addb    gr_hn
    tfr     b,e
    ldb     gr_hx0+1
    andb    #7
    ldu     #Gauche
    lda     b,u
    tste
    bne     Hl_Plus
    ldb     gr_hx1+1                ; un seul octet : gauche ET droite
    andb    #7
    ldu     #Droite
    anda    b,u
    lbsr    Applique
    bra     Hl_Sale
Hl_Plus:
    lbsr    Applique
    leax    1,x
Hl_Milieu:
    dece
    beq     Hl_Dernier
    lda     #$FF
    lbsr    Applique
    leax    1,x
    bra     Hl_Milieu
Hl_Dernier:
    ldb     gr_hx1+1
    andb    #7
    ldu     #Droite
    lda     b,u
    lbsr    Applique
Hl_Sale:
    ldd     gr_y
    lbra    Sale
Hl_Fin:
    rts

; Ordonne : gr_par..+7 = x0, y0, x1, y1 -> x0 <= x1, y0 <= y1
Ordonne:
    ldd     gr_par+4
    cmpd    gr_par
    bge     Or_Y
    ldx     gr_par
    std     gr_par
    stx     gr_par+4
Or_Y:
    ldd     gr_par+6
    cmpd    gr_par+2
    bge     Or_Fin
    ldx     gr_par+2
    std     gr_par+2
    stx     gr_par+6
Or_Fin:
    rts

Gr_Rect:
    bsr     Ordonne
    ldd     gr_par+2                ; y de max(y0, 0) à min(y1, 399)
    bpl     Gre_Y0
    ldd     #0
Gre_Y0:
    std     gr_y
Gre_Ligne:
    ldd     gr_y
    cmpd    gr_par+6
    bgt     Gre_Fin
    cmpd    #HAUT
    bhs     Gre_Fin
    ldd     gr_par
    std     gr_hx0
    ldd     gr_par+4
    std     gr_hx1
    lbsr    Hl
    ldd     gr_y
    addd    #1
    std     gr_y
    bra     Gre_Ligne
Gre_Fin:
    rts

; ===================================================================
; Cercle et disque (point milieu ; xc, yc, r dans gr_par)
; gr_x1 = x, gr_y1 = y, gr_err = d
; ===================================================================
Gr_Cercle:
    clr     gr_plein
    bra     Gc_Debut
Gr_Disque:
    lda     #1
    sta     gr_plein
Gc_Debut:
    ldd     gr_par+4
    lbmi     Gc_Fin
    std     gr_y1
    ldd     #0
    std     gr_x1
    ldd     #1
    subd    gr_par+4
    std     gr_err
Gc_Boucle:
    ldd     gr_x1
    cmpd    gr_y1
    bgt     Gc_Fin
    tst     gr_plein
    bne     Gc_Plein
    lbsr    Huit
    bra     Gc_Suite
Gc_Plein:
    ldd     gr_x1                   ; travée de la ligne x, demi-largeur y
    cmpd    gr_y1                   ; (sauf x = y : c'est celle de y)
    beq     Gc_LigneY
    ldx     gr_y1
    lbsr    Travees
Gc_LigneY:
    ldd     gr_err                  ; la ligne y, si c'est son dernier point
    bge     Gc_DerY
    ldd     gr_x1
    addd    #1
    cmpd    gr_y1
    ble     Gc_Suite
Gc_DerY:
    ldd     gr_y1
    ldx     gr_x1
    lbsr    Travees
Gc_Suite:
    ldd     gr_err
    bge     Gc_DPos
    ldd     gr_x1                   ; d += 2x + 3
    addd    gr_x1
    addd    #3
    addd    gr_err
    std     gr_err
    bra     Gc_X
Gc_DPos:
    ldd     gr_x1                   ; d += 2(x - y) + 5 ; y -= 1
    subd    gr_y1
    std     gr_e2
    addd    gr_e2
    addd    #5
    addd    gr_err
    std     gr_err
    ldd     gr_y1
    subd    #1
    std     gr_y1
Gc_X:
    ldd     gr_x1
    addd    #1
    std     gr_x1
    bra     Gc_Boucle
Gc_Fin:
    rts

; Travees : D = dy, X = demi-largeur a : les lignes yc + dy et yc - dy
; (une fois si dy = 0), de xc - a à xc + a.
Travees:
    std     gr_e2
    stx     gr_dx
    addd    gr_par+2
    bsr     Tr_Une
    ldd     gr_e2
    beq     Tr_Fin
    ldd     gr_par+2
    subd    gr_e2
Tr_Une:
    std     gr_y
    ldd     gr_par
    subd    gr_dx
    std     gr_hx0
    ldd     gr_par
    addd    gr_dx
    std     gr_hx1
    lbra    Hl
Tr_Fin:
    rts

; Huit : les points symétriques de (x, y) = (gr_x1, gr_y1), sans doublon
Huit:
    ldd     gr_x1
    bne     Hu_Pas0
    ldd     gr_y1
    bne     Hu_Axes
    ldd     #0                      ; r = 0 : le centre
    tfr     d,x
    bra     Pp
Hu_Axes:                            ; x = 0 : (0, ±y), (±y, 0)
    ldx     gr_y1
    ldd     #0
    bsr     Pp
    ldx     gr_y1
    ldd     #0
    bsr     PpMy
    ldd     gr_y1
    ldx     #0
    bsr     Pp
    ldd     gr_y1
    bsr     NegD
    ldx     #0
    bra     Pp
Hu_Pas0:
    cmpd    gr_y1
    beq     Hu_Diag
    ldd     gr_y1                   ; (±y, ±x)
    ldx     gr_x1
    bsr     Quatre
Hu_Diag:                            ; (±x, ±y)
    ldd     gr_x1
    ldx     gr_y1
; Quatre : (±D, ±X)
Quatre:
    pshs    d,x
    bsr     Pp
    ldd     ,s
    bsr     NegD
    ldx     2,s
    bsr     Pp
    ldd     ,s
    ldx     2,s
    bsr     PpMy
    ldd     ,s
    bsr     NegD
    ldx     2,s
    bsr     PpMy
    puls    d,x,pc
; PpMy : le point (xc + D, yc - X)
PpMy:
    pshs    d
    tfr     x,d
    bsr     NegD
    tfr     d,x
    puls    d
; Pp : le point (xc + D, yc + X)
Pp:
    addd    gr_par
    std     gr_x
    tfr     x,d
    addd    gr_par+2
    std     gr_y
    lbra    Pt
NegD:
    coma
    comb
    addd    #1
    rts

; ===================================================================
; Effacer, caractères, couleurs, attente
; ===================================================================
Gr_Efface:
    clr     0                       ; page 3 : l'image à 0
    ldu     #0
    ldx     #1
    ldw     #POLICE-1
    tfm     u+,x+
    clr     gr_sale                 ; plus rien à recopier
    ldu     #gr_sale
    ldx     #gr_sale+1
    ldw     #49
    tfm     u+,x+
    clr     gr_cn
    clr     gr_np
    lda     gr_mode
    sta     gr_ca
    ldb     gr_cc0                  ; IRQ masquées : tout de suite
    bitb    #$10
    bne     Remplit
    ldx     #$8002                  ; sinon une tâche de l'IRQ
    stx     gr_eo
    inc     gr_ef                   ; en dernier : l'IRQ la voit complète
    rts

; Remplit : les 8 pages vidéo = paires (0, A). Détruit A, B, X, U, W.
Remplit:
    ldb     #GRAPH
Rp_Page:
    stb     VRAM_CTRL
    clr     $8000
    sta     $8001
    ldu     #$8000
    ldx     #$8002
    ldw     #$2000-2
    tfm     u+,x+
    incb
    cmpb    #GRAPH+8
    blo     Rp_Page
    lda     #GRAPH
    sta     VRAM_CTRL
    rts

; Ef_Pas : EF_N octets au plus de l'effacement (paires (0, gr_ca) par TFM
; qui se recouvre) ; page suivante, ou fin. Détruit D, X, U, W.
Ef_Pas:
    lda     gr_ef
    adda    #GRAPH-1
    sta     VRAM_CTRL
    ldx     gr_eo
    cmpx    #$8002
    bne     Ep_Suite
    clr     $8000                   ; la première paire de la page
    lda     gr_ca
    sta     $8001
Ep_Suite:
    ldd     #$A000
    subd    gr_eo
    cmpd    #EF_N
    bls     Ep_N
    ldd     #EF_N
Ep_N:
    tfr     d,w
    leau    -2,x
    tfm     u+,x+
    stx     gr_eo
    cmpx    #$A000
    blo     Ep_Fin
    ldx     #$8002                  ; page suivante
    stx     gr_eo
    inc     gr_ef
    lda     gr_ef
    cmpa    #9
    blo     Ep_Fin
    clr     gr_ef
Ep_Fin:
    lda     #GRAPH
    sta     VRAM_CTRL
    rts

Gr_Car:
    ldd     gr_par                  ; colonne < 80, rangée < 25
    cmpd    #80
    bhs     Gca_Fin
    ldd     gr_par+2
    cmpd    #25
    bhs     Gca_Fin
    ldb     gr_par+5                ; caractère $20-$7F, sinon '?'
    cmpb    #$20
    blo     Gca_Q
    tstb
    bpl     Gca_Ok
Gca_Q:
    ldb     #'?'
Gca_Ok:
    subb    #$20
    lda     #8
    mul
    addd    #POLICE
    tfr     d,u                     ; U = le dessin 8 x 8
    ldd     gr_par+2                ; rangée x 16 (< 400)
    lslb
    rola
    lslb
    rola
    lslb
    rola
    lslb
    rola
    lbsr    Fois80
    addd    gr_par
    tfr     d,x                     ; X = première ligne de la case
    ldf     #8
Gca_Ligne:
    lda     ,u+
    ldb     gr_mode
    cmpb    #2
    bne     Gca_Pose
    coma
Gca_Pose:
    sta     ,x
    sta     80,x
    leax    160,x
    decf
    bne     Gca_Ligne
    ldx     #gr_sale                ; ses 16 lignes : 2 octets de gr_sale
    ldb     gr_par+3
    lslb
    abx
    ldd     #$FFFF
    std     ,x
Gca_Fin:
    rts

; Gr_Couleur : cases (c0, r0)-(c1, r1), attribut gr_mode. Une tâche de
; l'IRQ ; celle d'avant d'abord (attendue, ou finie ici si IRQ masquées).
Gr_Couleur:
    lda     gr_cn                   ; une couleur ou un effacement en cours ?
    ora     gr_ef
    beq     Gco_Libre
    lda     gr_cc0
    bita    #$10
    bne     Gco_Direct
Gco_Att:
    lda     gr_cn
    ora     gr_ef
    bne     Gco_Att
    bra     Gco_Libre
Gco_Direct:
    ldf     #255
    lbsr    Gc_Pas
    tst     gr_cn
    bne     Gco_Direct
Gco_Libre:
    lbsr    Ordonne
    ldd     gr_par                  ; c0 = max(c0, 0)
    bpl     Gco_C0
    ldd     #0
Gco_C0:
    std     gr_par
    ldd     gr_par+2
    bpl     Gco_R0
    ldd     #0
Gco_R0:
    std     gr_par+2
    ldd     gr_par+4                ; c1 = min(c1, 79)
    cmpd    #79
    ble     Gco_C1
    ldd     #79
Gco_C1:
    std     gr_par+4
    ldd     gr_par+6
    cmpd    #24
    ble     Gco_R1
    ldd     #24
Gco_R1:
    std     gr_par+6
    ldd     gr_par+4                ; vide ?
    cmpd    gr_par
    blt     Gco_Fin
    ldd     gr_par+6
    cmpd    gr_par+2
    blt     Gco_Fin
    ldb     gr_par+5
    subb    gr_par+1
    incb
    stb     gr_cw
    stb     gr_cx
    lda     gr_mode
    sta     gr_ca
    ldb     gr_par+3                ; première case = r0 x 80 + c0
    lda     #80
    mul
    addb    gr_par+1
    adca    #0
    std     gr_cc
    ldb     gr_par+7
    subb    gr_par+3
    incb
    stb     gr_cn                   ; en dernier : l'IRQ la voit complète
Gco_Fin:
    rts

; Gc_Pas : F cases au plus de la tâche de couleur (IRQ, ou direct).
; Détruit D, X, F.
Gc_Pas:
    lda     #GRAPH
    sta     VRAM_CTRL
Gp_Rang:
    ldd     gr_cc
    lslb
    rola
    addd    #$8001
    tfr     d,x
    lda     gr_ca
    ldb     gr_cx
Gp_Case:
    pshs    b                       ; la case dans ses 16 lignes : les 8
    ldb     #GRAPH                  ; pages, les deux moitiés
Gp_Pg:
    stb     VRAM_CTRL
    sta     ,x
    sta     $1000,x
    incb
    cmpb    #GRAPH+8
    blo     Gp_Pg
    puls    b
    leax    2,x
    decb
    beq     Gp_FinR
    decf
    bne     Gp_Case
    stb     gr_cx                   ; budget épuisé
    tfr     x,d
    subd    #$8001
    lsra
    rorb
    std     gr_cc
    rts
Gp_FinR:
    tfr     x,d                     ; rangée suivante : + 80 - largeur
    subd    #$8001
    lsra
    rorb
    addd    #80
    subb    gr_cw
    sbca    #0
    std     gr_cc
    lda     gr_cw
    sta     gr_cx
    dec     gr_cn
    beq     Gp_Fin
    decf
    bne     Gp_Rang
Gp_Fin:
    rts

; Gr_Attend : jusqu'à ce que l'écran ait rattrapé l'image (rien si l'appelant
; a masqué les IRQ : rien ne bougerait).
Gr_Attend:
    lda     gr_cc0
    bita    #$10
    bne     Ga_Fin
Ga_Encore:
    lda     gr_np
    ora     gr_cn
    ora     gr_ef
    bne     Ga_Encore
    ldx     #gr_sale
Ga_Oct:
    tst     ,x+
    bne     Ga_Encore
    cmpx    #gr_sale+50
    blo     Ga_Oct
    tst     gr_np                   ; (une préparation a pu finir entre-temps)
    bne     Ga_Encore
Ga_Fin:
    rts

; ===================================================================
; L'IRQ du VSYNC (IRQ masquées ; la page de l'appelant est current_page)
; ===================================================================
X_Gr_IRQ:
    tst     gr_np
    beq     GI_Coul
    ldy     #GR_TAB                 ; la ligne : un octet sur deux
    ldu     #GR_STG
    lda     ,y+
    sta     VRAM_CTRL
    ldx     ,y
    lde     #40
GI_Oct:
    ldd     ,u++
    sta     ,x
    stb     2,x
    leax    4,x
    dece
    bne     GI_Oct
    clr     gr_np
    lda     #GRAPH
    sta     VRAM_CTRL
    bra     GI_Prep
GI_Coul:
    tst     gr_ef                   ; l'effacement d'abord
    lbne    Ef_Pas
    tst     gr_cn
    beq     GI_Prep
    ldf     #GC_N
    lbsr    Gc_Pas
    lda     #GRAPH
    sta     VRAM_CTRL
    rts

; --- après la fenêtre : la ligne marquée suivante
GI_Prep:
    lda     gr_cn                   ; une couleur ou un effacement attend :
    ora     gr_ef                   ; eux d'abord
    lbne    GI_Fin
    ldx     #gr_sale
    ldd     #0
    std     gr_yc
GP_Oct:
    tst     ,x
    bne     GP_Bits
    ldd     gr_yc
    addd    #8
    std     gr_yc
    leax    1,x
    cmpx    #gr_sale+50
    blo     GP_Oct
    rts
GP_Bits:
    lda     #$80
    sta     gr_m
GP_Bit:
    lda     ,x
    anda    gr_m
    bne     GP_Prend
    ldd     gr_yc
    addd    #1
    std     gr_yc
    lsr     gr_m
    bra     GP_Bit
GP_Prend:
    lda     gr_m                    ; la marque retirée AVANT la copie
    coma
    anda    ,x
    sta     ,x
    ldx     #GR_TAB                 ; page vidéo, adresse
    ldb     gr_yc+1
    andb    #15
    lsrb
    orb     #GRAPH
    stb     ,x+
    lda     #$80
    ldb     gr_yc+1
    bitb    #1
    beq     GP_Pair
    lda     #$90
GP_Pair:
    pshs    a
    ldd     gr_yc
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    lsra
    rorb
    lda     #160
    mul
    adda    ,s+
    std     ,x
    sts     gr_sirq                 ; page 3 : sur la pile gr_pirq
    lds     #gr_pirq_h
    lda     #3
    sta     pager_reg
    ldd     gr_yc                   ; la ligne : y x 80
    lbsr    Fois80
    tfr     d,x
    ldu     #GR_STG
    ldw     #80
    tfm     x+,u+
    lda     current_page
    sta     pager_reg
    lds     gr_sirq
    lda     #1
    sta     gr_np                   ; prête pour la trame suivante
GI_Fin:
    rts
