; ===================================================================
; test/stage9_mono.asm - ETAPE 9 : premier ecran de la carte OSM39_mono
; -------------------------------------------------------------------
; La carte mono a sa VRAM ENTRELACEE : la case c a son caractere en
; $8000+2c et sa couleur en $8001+2c (A0 du CPU choisit la RAM). Cette
; etape dessine une mire fixe ainsi rangee, sans aucun appel au BIOS
; (n'importe quelle EPROM fait l'affaire : SECOURS, LOAD, RUN 0000).
; Elle s'assemble pareil quel que soit le fichier CARTE : l'entrelacement
; est ecrit ici en dur (pas de 2), c'est ce qu'on veut essayer.
;
; A L'ECRAN (80 x 30) :
;   rangee 0   le titre, blanc sur noir ;
;   rangee 3   X O X O ... : chaque X ROUGE, chaque O VERT. Des X verts
;              et des O rouges = couleur decalee d'une case ;
;   rangees 5-12  les 8 fonds (une rangee par fond) x les 8 couleurs de
;              texte (un bloc de 10 cases par couleur, « f/b OSM ») ;
;   rangee 15  les codes $00-$4F de la PAGE 1 du generateur (bit 7 de
;              l'attribut) : semigraphiques, icones ;
;   rangees 17-20  les 256 caracteres de la page 0 ;
;   rangee 22  une regle 0123456789... (alignement des colonnes) ;
;   rangee 29  la derniere rangee visible.
; Le reste : espace, attribut $08 (contournement des traits roses, cf.
; AGENTS.md). Curseur cache, adresse de depart $FFFF (comme le BIOS),
; page video 0 et GRAPH = 0. IRQ et FIRQ masquees : le BIOS ne repeint
; plus rien ; on reste la (RESET pour sortir).
; Verifie hors carte par test/verifie_banc_mono.py (make STAGE=stage9_mono).
; ===================================================================
        include "../bios/hardware.inc"

M_CASE  equ     2               ; mono : 2 octets par case
M_LIGNE equ     160             ; 80 cases par rangee

        section .code

start:
        orcc    #%01010000      ; IRQ + FIRQ masquees pour de bon
        lda     #$00            ; page video 0, GRAPH (D3) = 0
        sta     VRAM_CTRL
        ; --- fond : espace / $08 dans les 4096 cases ---
        ldx     #VRAM_BASE
        ldd     #$2008
s9_fond:
        std     ,x++
        cmpx    #VRAM_BASE+4096*M_CASE
        bne     s9_fond
        ; --- les textes de la table ---
        ldu     #s9_textes
s9_texte:
        lda     ,u+             ; rangee ($FF : fin)
        cmpa    #$FF
        beq     s9_xo
        ldb     ,u+             ; colonne
        lbsr    s9_adresse      ; X = la case
        ldb     ,u+             ; attribut
s9_car:
        lda     ,u+
        beq     s9_texte
        std     ,x++
        bra     s9_car
        ; --- rangee 3 : X rouge, O vert ---
s9_xo:
        ldx     #VRAM_BASE+3*M_LIGNE
        ldf     #40
s9_xo1:
        ldd     #$5804          ; 'X', rouge sur noir
        std     ,x++
        ldd     #$4F02          ; 'O', vert sur noir
        std     ,x++
        decf
        bne     s9_xo1
        ; --- rangees 5-12 : fond (rangee) x texte (bloc de 10 cases) ---
        clre                    ; E = fond 0..7
s9_fonds:
        tfr     e,a
        adda    #5
        clrb
        lbsr    s9_adresse
        clrf                    ; F = couleur du texte 0..7
s9_blocs:
        tfr     e,a             ; attribut = fond * 16 + texte
        lsla
        lsla
        lsla
        lsla
        stf     s9_tmp
        ora     s9_tmp
        tfr     a,b
        ldy     #s9_bloc
s9_bloc1:
        lda     ,y+
        beq     s9_bloc2
        cmpa    #'f'
        bne     s9_bloc3
        tfr     f,a
        adda    #'0'
s9_bloc3:
        cmpa    #'b'
        bne     s9_bloc4
        tfr     e,a
        adda    #'0'
s9_bloc4:
        std     ,x++
        bra     s9_bloc1
s9_bloc2:
        incf
        cmpf    #8
        bne     s9_blocs
        ince
        cmpe    #8
        bne     s9_fonds
        ; --- rangee 15 : page 1 du generateur, codes $00-$4F ---
        ldx     #VRAM_BASE+15*M_LIGNE
        clra
        ldb     #$87            ; page 1, blanc sur noir
s9_p1:
        std     ,x++
        inca
        cmpa    #80
        bne     s9_p1
        ; --- rangees 17-20 : les 256 caracteres de la page 0 ---
        ldx     #VRAM_BASE+17*M_LIGNE
        clra
        ldb     #$07
s9_p0:
        std     ,x++
        inca
        bne     s9_p0
        ; --- rangee 22 : regle ---
        ldx     #VRAM_BASE+22*M_LIGNE
        ldb     #$06            ; jaune sur noir
        lde     #8
s9_regle:
        lda     #'0'
s9_regle1:
        std     ,x++
        inca
        cmpa    #'9'+1
        bne     s9_regle1
        dece
        bne     s9_regle
        ; --- 68B45 : depart $FFFF (comme le BIOS), curseur cache ---
        lda     #12
        sta     CRTC_RS
        lda     #$FF
        sta     CRTC_DATA
        lda     #13
        sta     CRTC_RS
        lda     #$FF
        sta     CRTC_DATA
        lda     #10
        sta     CRTC_RS
        lda     #$20            ; bits 6-5 = 01 : curseur non affiche
        sta     CRTC_DATA
s9_fin:
        bra     s9_fin

; A = rangee, B = colonne -> X = VRAM_BASE + A*160 + B*2. Detruit D.
s9_adresse:
        pshs    b
        ldb     #M_LIGNE
        mul
        addb    ,s
        adca    #0
        addb    ,s+
        adca    #0
        addd    #VRAM_BASE
        tfr     d,x
        rts

s9_bloc:
        fcn     " f/b OSM  "
s9_textes:
        fcb     0,0,$07
        fcc     "OSM39_mono - ETAPE 9 : VRAM ENTRELACEE (caractere pair, couleur impaire)"
        fcb     0
        fcb     2,0,$07
        fcc     "Rangee 3 : X rouge et O vert. X vert / O rouge = couleur decalee d'une case."
        fcb     0
        fcb     14,0,$07
        fcc     "Page 1 du generateur (attribut bit 7), codes $00-$4F :"
        fcb     0
        fcb     16,0,$07
        fcc     "Page 0, les 256 caracteres :"
        fcb     0
        fcb     24,0,$07
        fcc     "Rangees 5-12 : fond 0-7 (une rangee chacun) x texte 0-7 (blocs f/b)."
        fcb     0
        fcb     29,0,$07
        fcc     "Rangee 29 : la derniere rangee visible (80 x 30)."
        fcb     0
        fcb     $FF
s9_tmp  rmb     1
