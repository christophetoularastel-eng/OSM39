; ===================================================================
; test/stage8_adresse.asm - ETAPE 8 : un alea d'ADRESSE dans le chemin
; video ?
; -------------------------------------------------------------------
; Les traits du puits de BRIQUES sont FIXES et gardent la meme couleur
; aux memes colonnes d'une partie a l'autre (8 oct. 2026) : c'est le
; contenu de la VRAM, pas l'activite de la machine. Mais l'etape 7 a
; montre le meme puits PROPRE sur un ecran en bandes verticales.
;
; Hypothese : quand l'adresse du 68B45 passe a la cellule suivante en
; faisant basculer plusieurs bits (retenue), la RAM presente un court
; instant l'octet d'une AUTRE adresse, que le verrou capte sur un
; pixel. Une ligne fait 80 = 5 x 16 cellules : les retenues des 4 bits
; faibles tombent aux memes colonnes a chaque ligne (trait vertical),
; celles des bits au-dessus alternent d'une ligne a l'autre
; (pointilles). En bandes verticales (etapes 6 et 7), l'octet lu par
; erreur avait souvent le meme contenu : rien de visible.
;
; Ici l'ecran est NOIR sauf des lignes colorees : un trait dans le noir
; ne peut venir que d'une lecture a une autre adresse. Chaque colonne
; de la ligne coloree a son propre fond, (colonne mod 7)+1 : bleu,
; vert, cyan, rouge, magenta, jaune, blanc, bleu... La COULEUR d'un
; trait dit donc de quelle colonne (a 7 pres) vient l'octet lu.
;
; DEROULEMENT (chaque phase ~8 s ; photographier chacune) :
;   phase 1  noir + UNE ligne coloree en ligne 1 (la 0 reste noire sur
;            la carte, defaut connu).
;   phase 2  noir + la meme ligne en ligne 12. Si les traits bougent ou
;            changent avec la ligne, la distance entre lignes compte.
;   phase 3  une ligne sur deux coloree, sur tout l'ecran. Puis on reste
;            la (RESET). Un trait dans une ligne NOIRE = lecture dans la
;            ligne voisine.
;
; `start` doit rester la premiere chose de .code : voir stage3.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     ecran_noir      ; phase 1
        jsr     ligne_haut
        bsr     longue_attente
        jsr     ecran_noir      ; phase 2
        jsr     ligne_milieu
        bsr     longue_attente
        jsr     bandes_horiz    ; phase 3
        jmp     fini

longue_attente:                 ; ~8 s
        jsr     attente
        jsr     attente
        jsr     attente
        jsr     attente
        rts

        include "common.inc"

; ===================================================================
; Une ligne coloree (ligne_car / ligne_att) a la ligne 1 ou 12.
; Detruit : X
; ===================================================================
ligne_haut:
        ldx     #VRAM_BASE+80
        bra     ecrit_ligne
ligne_milieu:
        ldx     #VRAM_BASE+960
        bra     ecrit_ligne

; ===================================================================
; ecrit_ligne - 80 caracteres a partir de X, puis 80 attributs a
; partir de X + $1000 (RAM couleurs, carte V4).
; ligne_att suit ligne_car : U enchaine les deux tables sans recharge.
; Entree : X = debut de la ligne. Detruit : X
; ===================================================================
ecrit_ligne:
        pshs    d,u,cc
        orcc    #%01010000
        lda     #$00                ; page 0 (V4 : D0-D2 seuls comptent)
        sta     VRAM_CTRL
        ldu     #ligne_car
        ldb     #80
el_c:
        lda     ,u+
        sta     ,x+
        decb
        bne     el_c
        ; V4 : retour au debut de la ligne ET passage a la RAM
        ; couleurs, meme cellule + $1000 ($9000-$9FFF). Plus de $08
        ; dans VRAM_CTRL. Sans espace dans l'expression (piege lwasm).
        leax    VRAM_COL_OFS-80,x
        ldb     #80                 ; U pointe deja ligne_att
el_a:
        lda     ,u+
        sta     ,x+
        decb
        bne     el_a
        ; V4 : plus de `lda #$10` (mode affichage) : la VRAM revient
        ; au 68B45 des que le CPU cesse d'y ecrire.
        puls    d,u,cc
        rts

; ===================================================================
; bandes_horiz - toute la fenetre (4096 octets par plan) : motif_2l,
; deux lignes de 80 (couleur puis noir), repete. Meme structure que
; remplit_motif de l'etape 7, sur 160 colonnes.
; Detruit : U
; ===================================================================
bandes_horiz:
        ldu     #motif_2l
        pshs    d,x,cc
        orcc    #%01010000
        lda     #$00                ; page 0 (V4 : D0-D2 seuls comptent)
        sta     VRAM_CTRL
        ldx     #VRAM_BASE
        pshs    u                   ; debut des caracteres du motif
bh_c0:
        puls    u
        pshs    u
        ldb     #160
bh_c:
        lda     ,u+
        sta     ,x+
        cmpx    #VRAM_END
        beq     bh_c_fin
        decb
        bne     bh_c
        bra     bh_c0
bh_c_fin:
        puls    u
        leau    160,u               ; debut des attributs du motif
        pshs    u

        ldx     #VRAM_COL           ; V4 : RAM couleurs, $9000-$9FFF
bh_a0:
        puls    u
        pshs    u
        ldb     #160
bh_a:
        lda     ,u+
        sta     ,x+
        cmpx    #VRAM_COL_END
        beq     bh_a_fin
        decb
        bne     bh_a
        bra     bh_a0
bh_a_fin:
        puls    u
        ; V4 : plus de `lda #$10` (mode affichage) : la VRAM revient
        ; au 68B45 des que le CPU cesse d'y ecrire.
        puls    d,x,cc
        rts

; Tables (generees) :
ligne_car:
        ; caracteres : $20 partout (le fond seul est colore)
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
ligne_att:
        ; attributs : fond (colonne mod 7)+1, sans premier plan
        fcb     $10,$20,$30,$40,$50,$60,$70,$10,$20,$30
        fcb     $40,$50,$60,$70,$10,$20,$30,$40,$50,$60
        fcb     $70,$10,$20,$30,$40,$50,$60,$70,$10,$20
        fcb     $30,$40,$50,$60,$70,$10,$20,$30,$40,$50
        fcb     $60,$70,$10,$20,$30,$40,$50,$60,$70,$10
        fcb     $20,$30,$40,$50,$60,$70,$10,$20,$30,$40
        fcb     $50,$60,$70,$10,$20,$30,$40,$50,$60,$70
        fcb     $10,$20,$30,$40,$50,$60,$70,$10,$20,$30
motif_2l:
        ; caracteres des deux lignes
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        ; attributs : ligne paire = palette, ligne impaire = noir
        fcb     $10,$20,$30,$40,$50,$60,$70,$10,$20,$30
        fcb     $40,$50,$60,$70,$10,$20,$30,$40,$50,$60
        fcb     $70,$10,$20,$30,$40,$50,$60,$70,$10,$20
        fcb     $30,$40,$50,$60,$70,$10,$20,$30,$40,$50
        fcb     $60,$70,$10,$20,$30,$40,$50,$60,$70,$10
        fcb     $20,$30,$40,$50,$60,$70,$10,$20,$30,$40
        fcb     $50,$60,$70,$10,$20,$30,$40,$50,$60,$70
        fcb     $10,$20,$30,$40,$50,$60,$70,$10,$20,$30
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        fcb     $00,$00,$00,$00,$00,$00,$00,$00,$00,$00

        end
