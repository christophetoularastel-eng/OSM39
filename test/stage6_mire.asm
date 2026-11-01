; ===================================================================
; test/stage6_mire.asm - ETAPE 6 : les traits verticaux de BRIQUES
; -------------------------------------------------------------------
; Symptome (8 oct. 2026, deux ecrans differents, donc pas l'ecran) :
; dans le puits de BRIQUES, de fins traits verticaux en pointilles, une
; couleur par colonne, et un trait bleu fonce au bord gauche de
; certaines briques. Les cases vides du puits sont $20 (page 0, glyphe
; ENTIEREMENT vide) sur l'attribut $00 : elles ne devraient allumer
; aucun pixel. L'interieur noir des fenetres ($00 page 1, attribut $8F)
; n'a, lui, aucun trait.
;
; Deux hypotheses materielles, qui ne se corrigent pas au meme endroit :
;   P  pipeline : l'attribut est applique un pixel trop tot ou trop tard
;      par rapport au caractere (cf. SCREEN_START_OFFSET = -1) ;
;   E  ecritures : une ecriture CPU en VRAM est abimee, la case ne
;      contient pas ce que le logiciel croit y avoir mis.
;
; DEROULEMENT (chaque phase ~8 s, soit 4 x attente ; photographier
; chacune) :
;   phase 1  ecran_noir : tout l'ecran en $20 / $00, comme une case vide
;            du puits. Tout pixel allume = bruit materiel PUR, sans aucun
;            contenu autour.
;   phase 2  mire_bandes : sur chaque ligne, de gauche a droite
;            A  7 bandes de briques BRIQUES ($FD $FE, attributs des
;               pieces $3F $1F $2F $6F $4F $5F $70), 2 colonnes noires
;               entre deux ;
;            B  les memes couleurs en FOND seul ($20, attribut $x0) ;
;            C  10 colonnes d'un caractere PLEIN ($DB) en PREMIER PLAN
;               seul ($01..$07, $0F, $0A, $0C), une colonne noire entre.
;            Regarder les colonnes noires : un trait collé a GAUCHE ou a
;            DROITE d'une bande, et dans quel groupe (fond / premier plan),
;            situe le decalage -> P.
;   phase 3  ecran_noir a nouveau, puis on reste la (RESET pour sortir).
;            Un reste de la phase 2 la ou il y avait de la couleur, alors
;            que la phase 1 etait propre -> E.
;
; `start` doit rester la premiere chose de .code : voir stage3.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     ecran_noir      ; phase 1
        bsr     longue_attente
        jsr     mire_bandes     ; phase 2
        bsr     longue_attente
        jsr     ecran_noir      ; phase 3
        jmp     fini

longue_attente:                 ; ~8 s
        jsr     attente
        jsr     attente
        jsr     attente
        jsr     attente
        rts

        include "common.inc"

; ===================================================================
; mire_bandes - toute la fenetre (4096 octets par plan : caracteres
; $8000-$8FFF puis couleurs $9000-$9FFF, carte V4) : le motif de
; 80 colonnes mire_car / mire_att, repete ligne apres ligne.
; U parcourt la table et repart au debut tous les 80 octets ; X
; parcourt la fenetre. Les deux boucles se ferment sur X (cmpx).
; U et non Y : verifie_remplissage.py ne simule pas LDY/CMPY.
; Detruit : rien (D, X, U et CC sont restaures)
; ===================================================================
mire_bandes:
        pshs    d,x,u,cc
        orcc    #%01010000
        lda     #$00                ; page 0 (V4 : D0-D2 seuls comptent)
        sta     VRAM_CTRL
        ldu     #mire_car
        ldx     #VRAM_BASE
mb_c:
        lda     ,u+
        sta     ,x+
        cmpu    #mire_car+80
        bne     mb_c1
        ldu     #mire_car
mb_c1:
        cmpx    #VRAM_END
        bne     mb_c

        ldu     #mire_att
        ldx     #VRAM_COL           ; V4 : RAM couleurs, $9000-$9FFF
mb_a:
        lda     ,u+
        sta     ,x+
        cmpu    #mire_att+80
        bne     mb_a1
        ldu     #mire_att
mb_a1:
        cmpx    #VRAM_COL_END
        bne     mb_a

        ; V4 : plus de `lda #$10` (mode affichage) : la VRAM revient
        ; au 68B45 des que le CPU cesse d'y ecrire.
        puls    d,x,u,cc
        rts

; Motif d'une ligne (genere, 80 colonnes) :
;   ..AA..AA..AA..AA..AA..AA..AA....BB..BB..BB..BB..BB..BB..BB..C.C.C.C.C.C.C.C.C.C.
mire_car:
        fcb     $20,$20,$FD,$FE,$20,$20,$FD,$FE,$20,$20
        fcb     $FD,$FE,$20,$20,$FD,$FE,$20,$20,$FD,$FE
        fcb     $20,$20,$FD,$FE,$20,$20,$FD,$FE,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $20,$20,$20,$20,$20,$20,$20,$20,$20,$20
        fcb     $DB,$20,$DB,$20,$DB,$20,$DB,$20,$DB,$20
        fcb     $DB,$20,$DB,$20,$DB,$20,$DB,$20,$DB,$20
mire_att:
        fcb     $00,$00,$3F,$3F,$00,$00,$1F,$1F,$00,$00
        fcb     $2F,$2F,$00,$00,$6F,$6F,$00,$00,$4F,$4F
        fcb     $00,$00,$5F,$5F,$00,$00,$70,$70,$00,$00
        fcb     $00,$00,$30,$30,$00,$00,$10,$10,$00,$00
        fcb     $20,$20,$00,$00,$60,$60,$00,$00,$40,$40
        fcb     $00,$00,$50,$50,$00,$00,$70,$70,$00,$00
        fcb     $01,$00,$02,$00,$03,$00,$04,$00,$05,$00
        fcb     $06,$00,$07,$00,$0F,$00,$0A,$00,$0C,$00

        end
