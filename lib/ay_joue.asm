; ===================================================================
; lib/ay_joue.asm — Lecteur de morceaux pour l'AY-3-8910 (SD-KBD-SON)
; ===================================================================
; À inclure APRÈS le point d'entrée (il émet du code), avec
; bios/hardware.inc. Le format des morceaux, le modèle exact de ce
; lecteur et la compilation des partitions sont dans tools/ay/ay.py
; (source unique) ; verifie_ayjoue.py compare ce code à ce modèle.
;
;   LDX #Morceau / JSR AyJ_Demarre    C = 1 : pas un morceau (rien ne joue)
;   TST AyJ_Actif                     0 : toutes les voix sont finies
;   JSR AyJ_Arrete                    AVANT de rendre la main : rend
;                                     rvec_IRQ au BIOS, silence
;
; Le lecteur s'accroche à l'IRQ du VSYNC (rvec_IRQ, comme DONJON39) et joue
; une trame à chaque VSYNC, puis passe la main au BIOS. Le morceau et ce
; code restent dans la page du programme : pas de FAR_CALL vers une autre
; page pendant qu'il joue (l'IRQ y trouverait autre chose). Les services
; du BIOS qui changent de page le font IRQ masquées : ils sont sans
; danger. Ne pas mêler avec snd_play (qui écrit aussi l'AY).
; son_coupe = $4D (touche M d'OSM-VISION) : volumes à 0.
; ===================================================================

; --- état d'une voix (AyJ_Voix : 3 fois AYJ_TAILLE octets) ---
AYJ_PTR         equ 0           ; flot de la voix (0 : finie)
AYJ_BOUCLE      equ 2           ; repère de boucle
AYJ_RESTE       equ 4           ; trames avant de relire le flot
AYJ_DUREE       equ 5           ; durée courante (trames)
AYJ_INSTR       equ 6           ; instrument courant (adresse)
AYJ_VOL         equ 8           ; volume courant dans l'instrument (0 : silence)
AYJ_TP          equ 10          ; période du ton
AYJ_DECL        equ 12          ; <> 0 : relancer l'enveloppe à cette trame
AYJ_TAILLE      equ 13

; -------------------------------------------------------------------
; AyJ_Demarre : X = morceau. C = 0 : il joue ; C = 1 : pas un morceau.
; Préserve tous les registres (sauf CC).
; -------------------------------------------------------------------
AyJ_Demarre:
        pshs    d,x,y,u
        ldd     ,x
        cmpd    #$4159                  ; "AY"
        bne     ayd_non
        lda     2,x
        cmpa    #1                      ; version 1
        bne     ayd_non
        jsr     AyJ_Arrete              ; déjà accroché : décroché d'abord
        stx     AyJ_Base
        ldd     11,x                    ; table des instruments
        addd    AyJ_Base
        std     AyJ_Table
        leau    5,x                     ; FDB voix A, B, C
        ldy     #AyJ_Voix
ayd_voix:
        ldd     ,u++
        beq     ayd_absente
        addd    AyJ_Base
ayd_absente:
        std     AYJ_PTR,y
        std     AYJ_BOUCLE,y
        lda     #1
        sta     AYJ_RESTE,y             ; lue dès la première trame
        sta     AYJ_DUREE,y
        clr     AYJ_DECL,y
        clra
        clrb
        std     AYJ_INSTR,y
        std     AYJ_VOL,y
        std     AYJ_TP,y
        leay    AYJ_TAILLE,y
        cmpy    #AyJ_Voix+39
        bne     ayd_voix
        lda     #1
        sta     AyJ_Actif
        pshs    cc
        orcc    #%00010000              ; IRQ masquée le temps de poser le vecteur
        ldd     >rvec_IRQ
        std     AyJ_AncienIRQ
        ldd     #AyJ_Irq
        std     >rvec_IRQ
        puls    cc
        andcc   #%11111110
        puls    d,x,y,u,pc
ayd_non:
        orcc    #%00000001
        puls    d,x,y,u,pc

; -------------------------------------------------------------------
; AyJ_Arrete : rvec_IRQ rendu au BIOS (si le lecteur y était), silence
; (volumes à 0, R7 = $3F : ni ton ni bruit, ports en entrée).
; Préserve tous les registres. Sans effet si rien ne joue.
; -------------------------------------------------------------------
AyJ_Arrete:
        pshs    cc,d
        orcc    #%00010000
        ldd     >rvec_IRQ               ; accroché ? (vrai même au chargement,
        cmpd    #AyJ_Irq                ; où les variables valent n'importe quoi)
        bne     aya_silence
        ldd     AyJ_AncienIRQ
        std     >rvec_IRQ
aya_silence:
        clr     AyJ_Actif
        ldd     #$073F
        sta     AY_ADR
        stb     AY_DATA
        ldd     #$0800
        sta     AY_ADR
        stb     AY_DATA
        inca
        sta     AY_ADR
        stb     AY_DATA
        inca
        sta     AY_ADR
        stb     AY_DATA
        puls    cc,d,pc

; L'IRQ : une trame, puis le BIOS (acquittement du VSYNC, console...).
AyJ_Irq:
        jsr     AyJ_Trame
        jmp     [AyJ_AncienIRQ]

; -------------------------------------------------------------------
; AyJ_Trame : une trame du lecteur (le modèle : Lecteur.trame de ay.py).
; Détruit D, X, Y, U.
; -------------------------------------------------------------------
AyJ_Trame:
        tst     AyJ_Actif
        bne     ayt_go
        rts
ayt_go:
        lda     #$3F
        sta     AyJ_Mix
        lda     #$FF                    ; aucune voix ne joue de bruit
        sta     AyJ_Bruit
        lda     #1
        sta     AyJ_Masque
        clr     AyJ_K
        clr     AyJ_Vivantes
        ldy     #AyJ_Voix
ayt_voix:
        clr     AyJ_Volume
        ldx     AYJ_PTR,y
        lbeq    ayt_ecrit               ; voix finie (ou absente)
        dec     AYJ_RESTE,y
        lbne    ayt_son
ayt_lit:
        lda     ,x+
        beq     ayt_silence             ; $00
        cmpa    #$60
        blo     ayt_note                ; $01-$5F
        beq     ayt_tenue               ; $60
        cmpa    #$80
        blo     ayt_lit                 ; $61-$7F : réservés, ignorés
        cmpa    #$C0
        blo     ayt_duree               ; $80-$BF
        cmpa    #$E0
        blo     ayt_instr               ; $C0-$DF
        beq     ayt_repere              ; $E0
        cmpa    #$E1
        beq     ayt_retour              ; $E1
        ldx     #0                      ; $E2-$FF : fin de la voix
        stx     AYJ_PTR,y
        lbra    ayt_ecrit
ayt_duree:
        suba    #$7F
        sta     AYJ_DUREE,y
        bra     ayt_lit
ayt_instr:
        suba    #$C0
        lsla
        ldu     AyJ_Table
        ldd     a,u
        addd    AyJ_Base
        std     AYJ_INSTR,y
        bra     ayt_lit
ayt_repere:
        stx     AYJ_BOUCLE,y
        bra     ayt_lit
ayt_retour:
        ldx     AYJ_BOUCLE,y
        bra     ayt_lit
ayt_silence:
        clrb                            ; A = 0
        std     AYJ_VOL,y
        bra     ayt_tenue
ayt_note:
        deca                            ; n - 1 = 12 x octave + demi-ton
        clrb
ayt_octave:
        cmpa    #12
        blo     ayt_demiton
        suba    #12
        incb
        bra     ayt_octave
ayt_demiton:
        pshs    b                       ; octave
        lsla
        ldu     #AyJ_Periodes
        ldd     a,u
ayt_decale:
        tst     ,s
        beq     ayt_periode
        lsra
        rorb
        dec     ,s
        bra     ayt_decale
ayt_periode:
        leas    1,s
        std     AYJ_TP,y
        ldu     AYJ_INSTR,y
        lda     ,u
        anda    #4                      ; instrument à enveloppe : la relancer
        sta     AYJ_DECL,y
        leau    5,u                     ; premier volume
        stu     AYJ_VOL,y
ayt_tenue:
        lda     AYJ_DUREE,y
        sta     AYJ_RESTE,y
        stx     AYJ_PTR,y
ayt_son:
        ldu     AYJ_VOL,y
        beq     ayt_ecrit               ; silence
        ldx     AYJ_INSTR,y
        lda     ,u                      ; volume de cette trame
        ldb     1,u
        cmpb    #$FF
        beq     ayt_garde               ; dernier volume : tenu
        leau    1,u
        stu     AYJ_VOL,y
ayt_garde:
        ldb     ,x                      ; drapeaux de l'instrument
        bitb    #4
        beq     ayt_vol
        lda     #$10                    ; volume par l'enveloppe
ayt_vol:
        sta     AyJ_Volume
        bitb    #1
        beq     ayt_pas_ton
        lda     AyJ_Masque
        coma
        anda    AyJ_Mix
        sta     AyJ_Mix
ayt_pas_ton:
        bitb    #2
        beq     ayt_ecrit
        lda     AyJ_Masque
        lsla
        lsla
        lsla
        coma
        anda    AyJ_Mix
        sta     AyJ_Mix
        lda     1,x
        sta     AyJ_Bruit
ayt_ecrit:
        lda     AyJ_K                   ; période : R(2k), R(2k+1)
        lsla
        sta     AY_ADR
        ldb     AYJ_TP+1,y
        stb     AY_DATA
        inca
        sta     AY_ADR
        ldb     AYJ_TP,y
        stb     AY_DATA
        lda     AyJ_K                   ; volume : R(8+k)
        adda    #8
        sta     AY_ADR
        ldb     AyJ_Volume
        lda     son_coupe
        cmpa    #$4D
        bne     ayt_volume
        clrb
ayt_volume:
        stb     AY_DATA
        tst     AYJ_DECL,y
        beq     ayt_suivante
        clr     AYJ_DECL,y
        ldx     AYJ_INSTR,y
        lda     #11                     ; période de l'enveloppe, puis la forme
        sta     AY_ADR
        ldb     3,x
        stb     AY_DATA
        inca
        sta     AY_ADR
        ldb     4,x
        stb     AY_DATA
        inca
        sta     AY_ADR
        ldb     2,x
        stb     AY_DATA
ayt_suivante:
        ldx     AYJ_PTR,y
        beq     ayt_morte
        inc     AyJ_Vivantes
ayt_morte:
        leay    AYJ_TAILLE,y
        lsl     AyJ_Masque
        inc     AyJ_K
        lda     AyJ_K
        cmpa    #3
        lbne    ayt_voix
        ldb     AyJ_Bruit
        cmpb    #$FF
        beq     ayt_mixeur
        lda     #6
        sta     AY_ADR
        stb     AY_DATA
ayt_mixeur:
        lda     #7
        sta     AY_ADR
        ldb     AyJ_Mix
        stb     AY_DATA
        tst     AyJ_Vivantes
        bne     ayt_fin
        clr     AyJ_Actif               ; toutes les voix sont finies
ayt_fin:
        rts

; Périodes de l'octave 1 (Do 1 à Si 1), E / (16 f) : ay.py, TP_DO1
AyJ_Periodes:
        fdb     3523,3325,3138,2962,2796,2639,2491,2351,2219,2095,1977,1866

AyJ_Actif       rmb 1           ; <> 0 : au moins une voix joue
AyJ_AncienIRQ   rmb 2
AyJ_Base        rmb 2
AyJ_Table       rmb 2
AyJ_Mix         rmb 1
AyJ_Bruit       rmb 1
AyJ_Masque      rmb 1
AyJ_K           rmb 1
AyJ_Vivantes    rmb 1
AyJ_Volume      rmb 1
AyJ_Voix        rmb 39
