; ===================================================================
; test/stage7_bureau.asm - ETAPE 7 : les traits du puits viennent-ils
; de ce qu'il y a AUTOUR ?
; -------------------------------------------------------------------
; Etape 6 (8 oct. 2026) : ecran entierement $20/$00 PROPRE, et ecran
; propre apres effacement des bandes : les ecritures sont saines. Les
; seuls parasites sont aux TRANSITIONS entre cellules differentes.
; Or dans BRIQUES les traits sont la DES LE DEBUT, au milieu d'un puits
; vide ($20/$00 partout, sans transition), a des colonnes fixes. Seul
; change le reste de la ligne : le bureau en DAMIER ($03, attribut $97)
; qui bascule a chaque pixel, l'ombre (damier $02), les bordures.
; Soupcon : bruit de commutation (alimentation, masse, diaphonie).
;
; Chaque ligne de l'ecran reprend une ligne de BRIQUES (WIN_X=24,
; WIN_W=32) : bord en 24, paroi en 25, puits vide en 26..45, paroi en
; 46, bord en 55, ombre en 56. Les bandes sont verticales : les traits
; ne dependent que de la colonne, inutile de dessiner les bords haut
; et bas.
;
; DEROULEMENT (chaque phase ~8 s ; photographier chacune) :
;   phase 1  motif_briques : la ligne de BRIQUES telle quelle. Les traits
;            DOIVENT revenir dans le puits, sinon le banc ne reproduit
;            pas le defaut et les phases suivantes ne prouvent rien.
;   phase 2  motif_uni : la meme, bureau ET ombre en bleu uni
;            ($20, attribut $10). Traits disparus -> c'est le damier.
;   phase 3  motif_damier : bureau en damier et puits noir, SANS fenetre
;            (ni bordures ni interieur $8F). Puis on reste la (RESET).
;            Traits presents -> le damier suffit a lui seul.
;
; `start` doit rester la premiere chose de .code : voir stage3.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     bureau_briques   ; phase 1
        bsr     longue_attente
        jsr     bureau_uni      ; phase 2
        bsr     longue_attente
        jsr     bureau_damier   ; phase 3
        jmp     fini

longue_attente:                 ; ~8 s
        jsr     attente
        jsr     attente
        jsr     attente
        jsr     attente
        rts

        include "common.inc"

; ===================================================================
; Une entree par phase : U = motif (80 caracteres puis 80 attributs).
; Detruit : U
; ===================================================================
bureau_briques:
        ldu     #motif_briques
        bra     remplit_motif
bureau_uni:
        ldu     #motif_uni
        bra     remplit_motif
bureau_damier:
        ldu     #motif_damier
        bra     remplit_motif

; ===================================================================
; remplit_motif - toute la fenetre (4096 octets par plan) : la ligne
; de 80 colonnes pointee par U, repetee. Le debut de la table du plan
; en cours est garde sur la pile (puls/pshs u) ; B compte les colonnes.
; Les deux boucles se ferment sur X (cmpx #VRAM_END pour les
; caracteres, cmpx #VRAM_COL_END pour les couleurs, carte V4).
; Entree : U = motif. Detruit : U
; ===================================================================
remplit_motif:
        pshs    d,x,cc
        orcc    #%01010000
        lda     #$00                ; page 0 (V4 : D0-D2 seuls comptent)
        sta     VRAM_CTRL
        ldx     #VRAM_BASE
        pshs    u                   ; debut des caracteres du motif
rm_c0:
        puls    u
        pshs    u
        ldb     #80
rm_c:
        lda     ,u+
        sta     ,x+
        cmpx    #VRAM_END
        beq     rm_c_fin
        decb
        bne     rm_c
        bra     rm_c0
rm_c_fin:
        puls    u
        leau    80,u                ; debut des attributs du motif
        pshs    u

        ldx     #VRAM_COL           ; V4 : RAM couleurs, $9000-$9FFF
rm_a0:
        puls    u
        pshs    u
        ldb     #80
rm_a:
        lda     ,u+
        sta     ,x+
        cmpx    #VRAM_COL_END
        beq     rm_a_fin
        decb
        bne     rm_a
        bra     rm_a0
rm_a_fin:
        puls    u
        ; V4 : plus de `lda #$10` (mode affichage) : la VRAM revient
        ; au 68B45 des que le CPU cesse d'y ecrire.
        puls    d,x,cc
        rts

; Motifs (generes ; une ligne de BRIQUES, 80 colonnes) :
motif_briques:
        ; caracteres
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$22,$23,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$22,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$23,$02,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        ; attributs
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$8F,$8F,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$8F,$8F,$8F,$8F
        fcb     $8F,$8F,$8F,$8F,$8F,$8F,$90,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
motif_uni:
        ; caracteres
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$22,$23,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$22,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$23,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        ; attributs
        fcb     $10,$10,$10,$10,$10,$10,$10,$10,$10,$10
        fcb     $10,$10,$10,$10,$10,$10,$10,$10,$10,$10
        fcb     $10,$10,$10,$10,$8F,$8F,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$8F,$8F,$8F,$8F
        fcb     $8F,$8F,$8F,$8F,$8F,$8F,$10,$10,$10,$10
        fcb     $10,$10,$10,$10,$10,$10,$10,$10,$10,$10
        fcb     $10,$10,$10,$10,$10,$10,$10,$10,$10,$10
motif_damier:
        ; caracteres
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        fcb     $03,$03,$03,$03,$03,$03,$03,$03,$03,$03
        ; attributs
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97
        fcb     $97,$97,$97,$97,$97,$97,$97,$97,$97,$97

        end
