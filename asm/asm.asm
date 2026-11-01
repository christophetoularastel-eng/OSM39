; ===================================================================
; ASM.ASM — Assembleur 6809/HD6309 auto-hébergé pour OSM39 (2 ou 3 passes)
; Usage  : ASM <source> <sortie> [origine]
;          origine en hexadécimal ($ facultatif), $0000 par défaut ; un
;          ORG placé avant le premier octet émis la remplace.
; Charge : page 1, $0000. Le binaire se construit en page 2 (32 Ko max).
;
; BUT : assembler sur la machine les sources écrites pour lwasm (avec
;       EDIT ou Vi), octet pour octet comme `lwasm --format=obj` suivi de
;       `lwlink --format=raw` : test/verifie_asm.py le prouve sur GLOUTON.
;
; FONCTIONNALITÉS :
;   - Sources de toute taille : les fichiers sont lus secteur par secteur
;     (FS_FileInfo / FS_ReadSector), ils ne sont jamais chargés en entier.
;   - INCLUDE "chemin/NOM.EXT" (4 niveaux) : le chemin part du dossier du
;     fichier qui inclut, comme lwasm (sur la carte, APPS/LIB/BIOS reprennent
;     le dépôt) ; à défaut, NOM.EXT seul, dans ce dossier puis à la racine.
;   - <source> et <sortie> peuvent être des chemins ("/GLOUTON").
;   - Étiquette en colonne 1, avec ou sans ':' ; '*' ou ';' en colonne 1 =
;     commentaire ; l'opérande s'arrête au premier blanc hors chaîne : la
;     suite de la ligne est un commentaire (comme lwasm).
;   - Table des symboles : hachage sur 256 seaux, noms de 31 caractères,
;     casse respectée (LBuf et LBUF diffèrent, comme dans lwasm) ; autant
;     de symboles que la page en contient (~1000). Mnémoniques et
;     registres : casse ignorée.
;   - Un EQU peut référencer un symbole défini plus loin : il est
;     provisoire en passe 1, recalculé par une passe 3 (sans émission)
;     avant la passe 2.
;   - Évaluateur : $hex, %bin, décimal, 'c, *, symbole, + - * / ( ) et
;     - unaire (16 bits, diviseur <= 255).
;   - Directives : ORG EQU FCB FDB FCC FCN RMB END INCLUDE ; SECTION et
;     EXPORT sont acceptées et ignorées (un seul bloc de code).
;   - Assemblage conditionnel : IF/IFNE IFEQ IFGT IFGE IFLT IFLE (expression
;     comparée à 0), IFDEF/IFNDEF, ELSE, ENDC/ENDIF, et ERROR.
;   - Jeu 6809 complet et l'essentiel du HD6309 (opcodes.inc) : W, E, F,
;     Q, inhérents D/W/E/F, PSHSW..., registre à registre, TFM.
;   - Le binaire est enregistré avec sa page et son adresse de chargement
;     (FS_SetLoad) : celles de l'ancien fichier s'il existait, sinon page 1,
;     plus l'attribut « app » si le source inclut VISION.ASM (application
;     d'OSM-VISION, qui tourne dans sa page).
;
; TAILLE DES OPÉRANDES (règles de lwasm en mode objet, mesurées) :
;   - mémoire : toujours étendu, sauf '<' explicite ;
;   - une étiquette (adresse) ou une référence avant force la forme
;     longue : étendu, décalage indexé 16 bits, PCR 16 bits ;
;   - une constante connue prend la forme la plus courte ; un décalage
;     indexé nul donne ,R — sauf le texte exact « 0 » (0,X = 5 bits) ;
;   - RMB émet des zéros.
;
; LIMITATIONS :
;   - Pas de macro, d'IMPORT, de section séparée.
;   - Pas de référence avant dans ORG/RMB (erreur explicite).
;   - Branches : pas de conversion automatique Bxx -> LBxx.
;   - Pas d'[n,pcr], pas de E,R / F,R / W,R, pas de LDQ immédiat, pas des
;     instructions sur bits (BAND..., AIM...).
; ===================================================================
    ; NOTE : bioslib.asm (thunks bsc_*) est inclus EN FIN DE FICHIER,
    ; pour que le point d'entrée Start soit à l'adresse $0000 (le shell
    ; lance les programmes externes par un JSR 0).


; ===================================================================
; Constantes
; ===================================================================
MAX_NIV     EQU 4               ; fichiers ouverts à la fois (INCLUDE)
SYM_MAXLEN  EQU 31              ; caractères d'un nom de symbole
LIGNE_MAX   EQU 511             ; caractères gardés d'une ligne
HAS_LABEL   EQU $01
HAS_MNEM    EQU $02
HAS_OPER    EQU $04

; --- drapeaux d'adressage dans la table des instructions ---
MI_INH      EQU $01             ; inhérent (ou liste registres)
MI_IMM8     EQU $02             ; immédiat 8 bits
MI_IMM16    EQU $04             ; immédiat 16 bits
MI_DIR      EQU $08             ; direct (page zéro)
MI_EXT      EQU $10             ; étendu
MI_IDX      EQU $20             ; indexé
MI_REL8     EQU $40             ; relatif 8 bits
MI_REL16    EQU $80             ; relatif 16 bits

; --- décalages dans une entrée de table (19 octets) ---
INST_FLAGS  EQU 6               ; drapeaux (1 octet, après le nom)
INST_IMM    EQU 7
INST_DIR    EQU 9
INST_EXT    EQU 11
INST_IDX    EQU 13
INST_INH    EQU 15
INST_REL16  EQU 17
INST_LEN    EQU 19

; --- modes résolus ---
IM_INH      EQU 0
IM_IMM      EQU 1
IM_DIR      EQU 2
IM_EXT      EQU 3
IM_IDX      EQU 4
IM_REL      EQU 5

; --- sous-modes indexés ---
IDX_NONE    EQU 0               ; ,R ou [,R]
IDX_PLUS    EQU 1               ; ,R+
IDX_PLUS2   EQU 2               ; ,R++
IDX_ACC     EQU 3               ; A/R, B/R, D/R
IDX_MINUS   EQU 4               ; ,-R
IDX_MINUS2  EQU 5               ; ,--R
IDX_EXPR    EQU 6               ; décalage numérique
IDX_ABS     EQU 7               ; [adresse] indirect absolu

; --- drapeaux d'expression (expr_flag) ---
EXPR_SYM    EQU $01             ; l'expression référence un symbole
EXPR_UNDEF  EQU $02             ; symbole encore inconnu (passe 1)
EXPR_FWD    EQU $04             ; référence avant : forme longue
EXPR_PROV   EQU $08             ; symbole provisoire (EQU à recalculer)

; --- contexte d'un fichier source ouvert (FC_TAILLE octets) ---
FC_LBA      EQU 0               ; prochain secteur à lire (4, BE)
FC_RESTE    EQU 4               ; octets du fichier pas encore lus (2)
FC_POS      EQU 6               ; prochain caractère dans FC_BUF (2)
FC_FIN      EQU 8               ; fin des données valides de FC_BUF (2)
FC_LIGNE    EQU 10              ; numéro de la ligne courante (2)
FC_CR       EQU 12              ; 1 : la ligne précédente finissait par CR
FC_NOM      EQU 13              ; nom formaté : 15 octets + NUL
FC_DOS      EQU 29              ; son dossier (2) : base de ses INCLUDE
FC_BUF      EQU 31              ; un secteur (512)
FC_TAILLE   EQU 543

; --- symbole : SY_NOM+longueur octets, à la suite dans sym_pool ---
SY_SUIV     EQU 0               ; suivant du même seau (2), 0 = fin
SY_VAL      EQU 2               ; valeur (2)
SY_FL       EQU 4               ; drapeaux (1)
SY_LEN      EQU 5               ; longueur du nom (1)
SY_NOM      EQU 6               ; nom en majuscules (sans NUL)
SF_VU       EQU $01             ; défini plus haut dans la passe en cours
SF_REL      EQU $02             ; adresse (étiquette) : forme longue
SF_PROV     EQU $04             ; EQU provisoire (référence avant) : passe 3

ATTR_RWX    EQU $07
ATTR_APP    EQU $10

; --- zones de travail, au-delà de la fin du programme (pas dans le
;     fichier binaire) ---
ctx_zone    EQU fin_prog                        ; MAX_NIV contextes
line_buf    EQU ctx_zone+MAX_NIV*FC_TAILLE      ; LIGNE_MAX+1
sym_heads   EQU line_buf+LIGNE_MAX+1            ; 256 seaux de 2 octets
mn_index    EQU sym_heads+512                   ; 27 pointeurs (A..Z, fin)
mn_list     EQU mn_index+54                     ; 1 pointeur par instruction
sym_pool    EQU mn_list+2*NB_INSTR              ; les symboles
SYM_POOL_FIN EQU $7F00

    section .code

; ===================================================================
; Start - Point d'entrée
; ===================================================================
Start:
    ; --- argc >= 3 ? ---
    lda     argc
    cmpa    #3
    lblo    Usage

    ; --- origine (argument 3, facultatif) ---
    ldd     #0
    std     Origine0
    lda     argc
    cmpa    #4
    blo     st_noms
    ldx     >argv+6
    jsr     LitHexa
    lbcs    Usage
    std     Origine0

st_noms:
    ; --- noms formatés (15 octets + NUL) ---
    ldx     >argv+2
    ldy     #NomSource
    jsr     bsc_Format_Filename_83
    clr     NomSource+15
    ldx     >argv+4
    ldy     #NomSortie
    jsr     bsc_Format_Filename_83
    clr     NomSortie+15

    ; --- le source existe ? ---
    ldx     #NomSource
    ldy     #fi_buf
    jsr     bsc_FS_FileInfo
    lbcs    ErrNotFound

    jsr     InitMnem

    ; --- Passe 1 ---
    ldx     #MsgPasse1
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
    lda     #1
    sta     pass_no
    jsr     InitPasse
    jsr     PassLoop
    lbcs    AsmFail
    ldx     #MsgEspDollar
    jsr     bsc_PrintString
    ldd     HautEau
    std     Pass1Size
    jsr     bsc_PrintHexWord
    ldx     #MsgOctets
    jsr     bsc_PrintString
    ldd     sym_nb
    jsr     PrintDec
    ldx     #MsgSymboles
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF

    ; --- Rien à émettre ? ---
    ldd     HautEau
    lbeq    Nothing

    ; --- Passe 3 (EQU provisoires), tant que leurs valeurs bougent ---
    ldd     nb_prov
    beq     st_p2
    lda     #8
    sta     p3_tours
    ldx     #MsgPasse3
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
st_p3:
    lda     #3
    sta     pass_no
    jsr     InitPasse
    clr     prov_change
    clr     prov_chaine
    jsr     PassLoop
    lbcs    AsmFail
    ; un autre tour seulement si un provisoire dépend d'un autre et a bougé
    tst     prov_change
    beq     st_p2
    tst     prov_chaine
    beq     st_p2
    dec     p3_tours
    bne     st_p3
st_p2:

    ; --- Passe 2 ---
    ldx     #MsgPasse2
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
    lda     #2
    sta     pass_no
    jsr     InitPasse
    jsr     PassLoop
    lbcs    AsmFail
    jsr     FlushOutBuf

    ; --- Cohérence passes 1/2 ---
    ldd     HautEau
    cmpd    Pass1Size
    lbne    AsmInternal

    jsr     Sauver
    rts

; ===================================================================
; Sorties d'erreur
; ===================================================================
ErrNotFound:
    ldx     #MsgNotFound
    lbra    DoExit
ErrSave:
    ldx     #MsgSave
    lbra    DoExit
AsmFail:
    ldx     #MsgFail
    lbra    DoExit
AsmInternal:
    ldx     #MsgInternal
    lbra    DoExit
Nothing:
    ldx     #MsgNothing
    lbra    DoExit
Usage:
    ldx     #MsgUsage
DoExit:
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
    rts

; ===================================================================
; Sauver - Enregistre le binaire (page 2, HautEau octets) dans NomSortie,
; puis sa page, son adresse (Origine) et ses attributs.
; ===================================================================
Sauver:
    ; --- un ancien fichier ? on garde sa page et ses attributs ---
    ldx     #NomSortie
    ldy     #fi_buf
    jsr     bsc_FS_FileInfo
    bcs     sv_neuf
    lda     fi_buf+8
    sta     sv_page
    lda     fi_buf+11
    sta     sv_attr
    ldx     #NomSortie
    jsr     bsc_FS_DeleteFile
    lbcs    ErrSave
    bra     sv_ecrit
sv_neuf:
    ; page 1 ; un source qui inclut VISION.ASM est une application
    ; d'OSM-VISION : attribut « app » en plus
    lda     #1
    sta     sv_page
    lda     #ATTR_RWX
    tst     est_app
    beq     sv_attr_ok
    ora     #ATTR_APP
sv_attr_ok:
    sta     sv_attr
sv_ecrit:
    ldx     #NomSortie
    ldy     #0              ; le binaire commence en $0000 de la page 2
    ldu     HautEau
    lda     #2
    jsr     bsc_FS_SaveFile
    lbcs    ErrSave
    ldx     #NomSortie
    lda     sv_page
    ldy     Origine
    jsr     bsc_FS_SetLoad
    lbcs    ErrSave
    ldx     #NomSortie
    lda     sv_attr
    jsr     bsc_FS_SetAttributes
    lbcs    ErrSave

    ; --- « ASM OK : $xxxx octets, page p, $adresse » ---
    ldx     #MsgDone
    jsr     bsc_PrintString
    ldd     HautEau
    jsr     bsc_PrintHexWord
    ldx     #MsgOctetsPage
    jsr     bsc_PrintString
    lda     sv_page
    adda    #'0'
    jsr     bsc_PrintChar
    ldx     #MsgVirgDollar
    jsr     bsc_PrintString
    ldd     Origine
    jsr     bsc_PrintHexWord
    jsr     bsc_PrintCRLF
    rts

; ===================================================================
; LitHexa - X = chaîne hexadécimale ('$' facultatif, NUL final) -> D.
; C=1 si vide ou caractère invalide.
; ===================================================================
LitHexa:
    lda     ,x
    cmpa    #'$'
    bne     lh_debut
    leax    1,x
lh_debut:
    tst     ,x
    beq     lh_err
    ldd     #0
    std     lh_val
lh_lp:
    lda     ,x+
    beq     lh_fin
    jsr     HexVal
    bcs     lh_err
    ; lh_val = lh_val*16 + A
    ldb     #4
lh_dec:
    lsl     lh_val+1
    rol     lh_val
    decb
    bne     lh_dec
    ora     lh_val+1
    sta     lh_val+1
    bra     lh_lp
lh_fin:
    ldd     lh_val
    andcc   #$FE
    rts
lh_err:
    orcc    #1
    rts

; ===================================================================
; InitMnem - Index des instructions par première lettre : mn_index[i]
; pointe dans mn_list sur la première entrée de la lettre 'A'+i,
; mn_index[i+1] sur la fin. Évite de parcourir toute la table.
; ===================================================================
InitMnem:
    ldu     #mn_list
    ldy     #mn_index
    lda     #'A'
im_lettre:
    stu     ,y++
    ldx     #instr_table
im_lp:
    cmpa    ,x
    bne     im_suiv
    stx     ,u++
im_suiv:
    leax    INST_LEN,x
    cmpx    #instr_end
    blo     im_lp
    inca
    cmpa    #'Z'+1
    bne     im_lettre
    stu     ,y
    rts

; ===================================================================
; InitPasse - Début d'une passe : compteurs, sortie, table des symboles
; (vidée en passe 1 ; en passe 2, chaque symbole redevient « pas encore
; vu », pour que les références avant soient reconnues comme en passe 1).
; ===================================================================
InitPasse:
    ldd     Origine0
    std     Origine
    std     LC
    ldd     #0
    std     HautEau
    std     OutPtr
    std     OutLocalIdx
    clr     end_flag
    clr     saut
    clr     trop_gros
    clr     err_lecture
    clr     niv
    lda     #1
    sta     org_libre
    lda     pass_no
    cmpa    #1
    bne     ip_p2
    ; passe 1 : table vide
    ldx     #sym_heads
    ldd     #0
ip_clr:
    std     ,x++
    cmpx    #sym_heads+512
    blo     ip_clr
    std     sym_nb
    std     nb_prov
    ldx     #sym_pool
    stx     sym_libre
    rts
ip_p2:
    ldx     #sym_pool
ip_vu:
    cmpx    sym_libre
    bhs     ip_fin
    lda     SY_FL,x
    anda    #$FF-SF_VU
    sta     SY_FL,x
    ldb     SY_LEN,x
    abx
    leax    SY_NOM,x
    bra     ip_vu
ip_fin:
    rts

; ===================================================================
; PassLoop - Une passe : lit et traite chaque ligne du source et de ses
; INCLUDE. Sortie : C=1 en cas d'erreur (message déjà affiché).
; ===================================================================
PassLoop:
    ldx     #NomSource
    jsr     OuvreFichier
    lbcs    pl_err
pl_loop:
    jsr     LitLigne
    bcs     pl_eof
    ldx     #line_buf
    jsr     ScanLine
    jsr     ProcessLine
    lbcs    pl_err
    lda     trop_gros
    lbne    pl_gros
    lda     end_flag
    lbne    pl_fin
    bra     pl_loop
pl_eof:
    lda     err_lecture
    lbne    pl_lect
    dec     niv
    beq     pl_fin
    jsr     CtxCourant
    bra     pl_loop
pl_fin:
    andcc   #$FE
    rts
pl_lect:
    ldx     #EMsgLecture
    jsr     ErrShow
    rts
pl_gros:
    ldx     #EMsgTropGros
    jsr     ErrShow
    rts
pl_err:
    orcc    #1
    rts

; ===================================================================
; OuvreFichier - X = nom formaté (15 octets + NUL) : ouvre un niveau de
; plus. C=1 si trop de niveaux, absent ou > 64 Ko (message affiché).
; ===================================================================
OuvreFichier:
    lda     niv
    cmpa    #MAX_NIV
    lbhs    of_trop
    pshs    x
    ldy     #fi_buf
    jsr     bsc_FS_FileInfo
    puls    x
    lbcs    of_absent
    ldd     fi_buf+4            ; poids fort de la taille
    lbne    of_gros
    inc     niv
    jsr     CtxCourant          ; Y = contexte
    pshs    y
    leay    FC_NOM,y
    ldb     #16
of_nom:
    lda     ,x+
    sta     ,y+
    decb
    bne     of_nom
    puls    y
    ldd     fi_buf
    std     FC_LBA,y
    ldd     fi_buf+2
    std     FC_LBA+2,y
    ldd     fi_buf+6
    std     FC_RESTE,y
    ldd     fi_buf+12
    std     FC_DOS,y
    leax    FC_BUF,y
    stx     FC_POS,y
    stx     FC_FIN,y
    ldd     #0
    std     FC_LIGNE,y
    clr     FC_CR,y
    andcc   #$FE
    rts
of_trop:
    ldx     #EMsgNiveaux
    jmp     ErrShow
of_absent:
    ; le source principal : pas encore de contexte pour situer l'erreur
    lda     niv
    lbeq    of_abs0
    ldx     #EMsgInclude
    jmp     ErrShow
of_abs0:
    ldx     #MsgNotFound
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
    orcc    #1
    rts
of_gros:
    ldx     #EMsgFich64
    jmp     ErrShow

; CtxCourant - Y = ctx = contexte du niveau niv (1..MAX_NIV).
CtxCourant:
    pshs    d,x
    ldb     niv
    decb
    lslb
    ldx     #ctx_adr
    abx
    ldy     ,x
    sty     ctx
    puls    d,x,pc

ctx_adr:
    fdb     ctx_zone,ctx_zone+FC_TAILLE,ctx_zone+2*FC_TAILLE,ctx_zone+3*FC_TAILLE

; ===================================================================
; LitLigne - Ligne suivante du fichier courant dans line_buf, sans CR/LF,
; NUL final (tronquée à LIGNE_MAX). Fins de ligne CR, LF ou CR LF.
; Un ';' hors chaîne "..." et hors 'c commence un commentaire : la suite
; n'est pas copiée (c'est l'essentiel du temps de lecture).
; Sortie : C=0 ligne lue (FC_LIGNE avancé) ; C=1 fin du fichier.
; ===================================================================
LitLigne:
    ldu     ctx
    ldy     #line_buf
    clr     ll_mode             ; 0 code, 1 chaîne, 2 commentaire, 3 après '
    ldx     FC_POS,u
    tst     FC_CR,u
    beq     ll_lp
    clr     FC_CR,u
    ; la ligne précédente finissait par CR : un LF qui suit est le sien
ll_cr_peek:
    cmpx    FC_FIN,u
    bhs     ll_cr_rempl
    lda     ,x
    cmpa    #$0A
    bne     ll_lp
    leax    1,x
    bra     ll_lp
ll_cr_rempl:
    jsr     Remplir
    lbcs    ll_eof
    bra     ll_cr_peek
ll_rempl:
    jsr     Remplir
    lbcs    ll_eof
ll_lp:
    cmpx    FC_FIN,u
    bhs     ll_rempl
    lda     ,x+
    cmpa    #'"'
    bls     ll_bas              ; contrôle, blanc, '!' ou '"'
    ldb     ll_mode
    bne     ll_mode123
    cmpa    #';'
    beq     ll_pv
    cmpa    #39
    beq     ll_apos
ll_garde:
    cmpy    #line_buf+LIGNE_MAX
    bhs     ll_lp               ; ligne trop longue : la fin est ignorée
    sta     ,y+
    bra     ll_lp
ll_mode123:
    cmpb    #1
    beq     ll_garde            ; dans une chaîne : tout est gardé
    cmpb    #3
    bne     ll_lp               ; commentaire : rien
ll_brut:
    clr     ll_mode             ; le caractère d'un 'c
    bra     ll_garde
ll_pv:
    lda     #2
    sta     ll_mode
    bra     ll_lp
ll_apos:
    ldb     #3
    stb     ll_mode
    bra     ll_garde
ll_bas:
    cmpa    #' '
    beq     ll_blanc
    bhi     ll_bas2
    cmpa    #9
    beq     ll_blanc
    cmpa    #$0A
    beq     ll_fin
    cmpa    #$0D
    beq     ll_cr
    tsta
    beq     ll_stop             ; NUL ou ^Z : fin du texte
    cmpa    #$1A
    beq     ll_stop
ll_blanc:
    ; blanc : hors chaîne, une suite de blancs devient un seul espace
    ; (sauf en colonne 1, qui distingue étiquette et mnémonique)
    ldb     ll_mode
    beq     ll_bl0
    cmpb    #2
    lbeq    ll_lp
    cmpb    #3
    beq     ll_brut
    lbra    ll_garde
ll_bl0:
    cmpy    #line_buf
    lbeq    ll_garde
    lda     -1,y
    cmpa    #' '
    lbeq    ll_lp
    lda     #' '
    lbra    ll_garde
ll_bas2:
    ldb     ll_mode             ; '!' ou '"'
    cmpb    #2
    lbeq    ll_lp
    cmpb    #3
    beq     ll_brut
    cmpa    #'"'
    bne     ll_garde
    eorb    #1                  ; '"' : entrée ou sortie de chaîne
    stb     ll_mode
    bra     ll_garde
ll_cr:
    lda     #1
    sta     FC_CR,u
ll_fin:
    stx     FC_POS,u
ll_fin2:
    clr     ,y
    ldd     FC_LIGNE,u
    addd    #1
    std     FC_LIGNE,u
    andcc   #$FE
    rts
ll_stop:
    ldd     FC_FIN,u
    std     FC_POS,u
    ldd     #0
    std     FC_RESTE,u
ll_eof:
    cmpy    #line_buf
    bne     ll_fin2             ; dernière ligne, sans fin de ligne
    orcc    #1
    rts

; Remplir - U = contexte : lit le secteur suivant du fichier dans FC_BUF.
; Sortie : C=0, X = FC_POS = début des données ; C=1 fin du fichier (ou
; erreur de lecture : err_lecture = 1). Préserve Y et U.
Remplir:
    ldd     FC_RESTE,u
    beq     rp_fin
    pshs    y
    leax    FC_LBA,u
    leay    FC_BUF,u
    jsr     bsc_FS_ReadSector
    puls    y
    bcs     rp_err
    ldd     FC_RESTE,u          ; n = min(512, reste)
    cmpd    #512
    bls     rp_n
    ldd     #512
rp_n:
    std     lc_tmp
    ldd     FC_RESTE,u
    subd    lc_tmp
    std     FC_RESTE,u
    leax    FC_BUF,u
    stx     FC_POS,u
    tfr     x,d
    addd    lc_tmp
    std     FC_FIN,u
    inc     FC_LBA+3,u          ; secteur suivant (fichier contigu)
    bne     rp_ok
    inc     FC_LBA+2,u
    bne     rp_ok
    inc     FC_LBA+1,u
    bne     rp_ok
    inc     FC_LBA,u
rp_ok:
    andcc   #$FE
    rts
rp_err:
    lda     #1
    sta     err_lecture
rp_fin:
    orcc    #1
    rts

; ===================================================================
; ScanLine - Analyse une ligne (X = line_buf, NUL final).
; Colonne 1 : '*' ou ';' = commentaire ; sinon une étiquette (':' final
; facultatif). Plus loin, un mot suivi de ':' est aussi une étiquette.
; L'opérande s'arrête au premier blanc hors chaîne "..." ou caractère 'c :
; un NUL y est écrit, la suite est un commentaire.
; Sortie : descripteur ld_* rempli.
; ===================================================================
ScanLine:
    clr     ld_type
    ldd     #0
    std     ld_label
    std     ld_mnem
    std     ld_oper
    sta     ld_labelLen
    sta     ld_mnemLen
    lda     ,x
    lbeq    sl_done
    cmpa    #'*'
    lbeq    sl_done
    cmpa    #';'
    lbeq    sl_done
    cmpa    #' '
    lbeq    sl_skip1
    cmpa    #9
    lbeq    sl_skip1
    ; --- colonne 1 : étiquette ---
    stx     ld_label
sl_col1:
    lda     ,x
    lbeq    sl_lab_eol
    cmpa    #':'
    lbeq    sl_col1_dp
    cmpa    #' '
    lbeq    sl_lab_fin
    cmpa    #9
    lbeq    sl_lab_fin
    leax    1,x
    inc     ld_labelLen
    lbra    sl_col1
sl_col1_dp:
    leax    1,x
sl_lab_fin:
    lda     ld_type
    ora     #HAS_LABEL
    sta     ld_type
    lbra    sl_skip1
sl_lab_eol:
    lda     ld_type
    ora     #HAS_LABEL
    sta     ld_type
    lbra    sl_done
    ; --- sauter les blancs ---
sl_skip1:
    lda     ,x
    cmpa    #' '
    lbeq    sl_skip1x
    cmpa    #9
    lbne    sl_got
sl_skip1x:
    leax    1,x
    lbra    sl_skip1
sl_got:
    lda     ,x
    lbeq    sl_done
    cmpa    #';'
    lbeq    sl_done
    ; --- un mot : mnémonique, ou étiquette s'il finit par ':' ---
    stx     ld_mnem
sl_scanm:
    lda     ,x
    lbeq    sl_mnem_fin
    cmpa    #' '
    lbeq    sl_mnem_fin
    cmpa    #9
    lbeq    sl_mnem_fin
    cmpa    #';'
    lbeq    sl_mnem_fin
    cmpa    #':'
    lbeq    sl_mot_dp
    leax    1,x
    inc     ld_mnemLen
    lbra    sl_scanm
sl_mot_dp:
    ; « mot: » : c'est une étiquette (s'il n'y en a pas déjà une)
    lda     ld_type
    bita    #HAS_LABEL
    lbne    sl_mnem_fin
    ora     #HAS_LABEL
    sta     ld_type
    ldd     ld_mnem
    std     ld_label
    lda     ld_mnemLen
    sta     ld_labelLen
    clr     ld_mnemLen
    ldd     #0
    std     ld_mnem
    leax    1,x
    lbra    sl_skip1
sl_mnem_fin:
    lda     ld_mnemLen
    lbeq    sl_done
    lda     ld_type
    ora     #HAS_MNEM
    sta     ld_type
    ; --- blancs avant l'opérande ---
sl_skip2:
    lda     ,x
    cmpa    #' '
    lbeq    sl_skip2x
    cmpa    #9
    lbne    sl_oper
sl_skip2x:
    leax    1,x
    lbra    sl_skip2
sl_oper:
    lda     ,x
    lbeq    sl_done
    cmpa    #';'
    lbeq    sl_done
    stx     ld_oper
    lda     ld_type
    ora     #HAS_OPER
    sta     ld_type
sl_scanop:
    lda     ,x
    lbeq    sl_opfin
    cmpa    #' '
    lbeq    sl_opfin
    cmpa    #9
    lbeq    sl_opfin
    cmpa    #';'
    lbeq    sl_opfin
    cmpa    #'"'
    lbeq    sl_chaine
    cmpa    #39
    lbeq    sl_apos
    leax    1,x
    lbra    sl_scanop
sl_apos:
    ; 'c : le caractère suivant fait partie de l'opérande, même un blanc
    leax    1,x
    tst     ,x
    lbeq    sl_opfin
    leax    1,x
    lbra    sl_scanop
sl_chaine:
    leax    1,x
sl_ch_lp:
    lda     ,x
    lbeq    sl_opfin
    leax    1,x
    cmpa    #'"'
    lbne    sl_ch_lp
    lbra    sl_scanop
sl_opfin:
    clr     ,x                  ; l'opérande est une chaîne NUL
sl_done:
    rts

; ===================================================================
; ProcessLine - Traite la ligne courante selon pass_no.
; Sortie : C=1 erreur d'assemblage (message affiché).
; ===================================================================
ProcessLine:
    ; tolérance des symboles non définis : passe 1 oui, ensuite non
    clr     no_undef
    lda     pass_no
    cmpa    #1
    beq     pl_tol
    inc     no_undef
pl_tol:
    tst     saut
    lbne    PL_Saut
    lda     ld_type
    bita    #HAS_MNEM
    lbeq    PL_LabOnly
    jsr     UpperMnem
    lbcs    PL_Err
    ; EQU : l'étiquette prend la valeur de l'opérande
    ldx     #str_equ
    jsr     CmpMnem
    lbcc    PL_DoEQU
    ; sinon l'étiquette éventuelle = LC
    lda     ld_type
    bita    #HAS_LABEL
    lbeq    PL_NoLab
    jsr     DefLabel
    lbcs    PL_Err
PL_NoLab:
    clr     asm_err
    jsr     DoDirective
    lbcs    PL_Inst
    lbra    PL_Done
PL_Inst:
    lda     asm_err
    lbne    PL_Err
    jsr     EmitInst
    lbcs    PL_Err
    lbra    PL_Done
PL_DoEQU:
    jsr     DirEQU
    lbcs    PL_Err
    lbra    PL_Done
PL_LabOnly:
    lda     ld_type
    bita    #HAS_LABEL
    lbeq    PL_Done
    jsr     DefLabel
    lbcs    PL_Err
PL_Done:
    andcc   #$FE
    rts
PL_Err:
    orcc    #1
    rts

; --- dans un bloc IF faux : seuls IF.../ELSE/ENDC comptent ---
PL_Saut:
    lda     ld_type
    bita    #HAS_MNEM
    lbeq    PL_Done
    ldb     ld_mnemLen
    cmpb    #7
    lbhi    PL_Done
    jsr     UpperMnem
    lda     mnem_buf
    cmpa    #'I'
    bne     ps_autre
    lda     mnem_buf+1
    cmpa    #'F'
    bne     ps_autre
    inc     saut                ; IF imbriqué : son ENDC aussi
    lbra    PL_Done
ps_autre:
    ldx     #str_endc
    jsr     CmpMnem
    bcc     ps_fin
    ldx     #str_endif
    jsr     CmpMnem
    bcc     ps_fin
    ldx     #str_else
    jsr     CmpMnem
    lbcs    PL_Done
    lda     saut
    cmpa    #1
    lbne    PL_Done
    clr     saut                ; ELSE du IF faux : on assemble
    lbra    PL_Done
ps_fin:
    dec     saut
    lbra    PL_Done

; ===================================================================
; DefLabel - L'étiquette de la ligne vaut LC.
; Passe 1 : nouveau symbole (adresse). Passe 2 : il doit avoir la même
; valeur qu'en passe 1 (sinon les tailles ont changé : erreur de phase),
; et devient « vu ».
; ===================================================================
DefLabel:
    ldx     ld_label
    lda     ld_labelLen
    jsr     ToNameBuf
    lbcs    ErrNomLong
    lda     pass_no
    cmpa    #1
    bne     dl_p2
    ldd     LC
    std     sym_val_tmp
    lda     #SF_VU|SF_REL
    jmp     SymAdd
dl_p2:
    jsr     SymFind
    lbcs    ErrPhase
    ldd     SY_VAL,x
    cmpd    LC
    lbne    ErrPhase
    lda     SY_FL,x
    ora     #SF_VU
    sta     SY_FL,x
    andcc   #$FE
    rts

; ===================================================================
; UpperMnem - Copie le mnémonique (majuscules, NUL) dans mnem_buf.
; C=1 (message affiché) s'il dépasse 7 caractères.
; ===================================================================
UpperMnem:
    ldx     ld_mnem
    ldb     ld_mnemLen
    cmpb    #7
    bhi     um_long
    ldy     #mnem_buf
um_loop:
    lda     ,x+
    jsr     UpA
    sta     ,y+
    decb
    bne     um_loop
    clr     ,y
    andcc   #$FE
    rts
um_long:
    ldx     #EMsgMnem
    jmp     ErrShow

; ===================================================================
; CmpMnem - Compare mnem_buf avec une chaîne NUL-terminée.
; Entrée : X = pointeur chaîne. Sortie : C=0 égales, C=1 différentes.
; ===================================================================
CmpMnem:
    pshs    y
    ldy     #mnem_buf
cm_loop:
    lda     ,x+
    cmpa    ,y+
    bne     cm_diff
    tsta
    bne     cm_loop
    andcc   #$FE
    puls    y,pc
cm_diff:
    orcc    #1
    puls    y,pc

; ===================================================================
; DoDirective - Dispatch directives/instructions.
; Sortie : C=0 directive gérée ; C=1 = instruction, ou erreur (asm_err).
; ===================================================================
DoDirective:
    lda     mnem_buf
    cmpa    #'I'
    beq     dd_cond
    cmpa    #'E'
    bne     dd_suite
dd_cond:
    jsr     DirCond             ; IF..., ELSE, ENDC, ENDIF, ERROR ?
    bcc     dd_ret
    tst     asm_err
    bne     dd_ret              ; (erreur : C=1, asm_err = 1)
dd_suite:
    ldx     #str_fcb
    jsr     CmpMnem
    lbcc    DirFCB
    ldx     #str_fdb
    jsr     CmpMnem
    lbcc    DirFDB
    ldx     #str_fcn
    jsr     CmpMnem
    lbcc    DirFCN
    ldx     #str_fcc
    jsr     CmpMnem
    lbcc    DirFCC
    ldx     #str_rmb
    jsr     CmpMnem
    lbcc    DirRMB
    ldx     #str_org
    jsr     CmpMnem
    lbcc    DirORG
    ldx     #str_include
    jsr     CmpMnem
    lbcc    DirINCLUDE
    ldx     #str_section
    jsr     CmpMnem
    lbcc    DirRien
    ldx     #str_export
    jsr     CmpMnem
    lbcc    DirRien
    ldx     #str_end
    jsr     CmpMnem
    lbcc    DirEND
    ; pas une directive → instruction
    orcc    #1
dd_ret:
    rts

; ===================================================================
; DirCond - Assemblage conditionnel. C=0 : directive traitée ; C=1 :
; autre chose (ou erreur si asm_err). Un IF faux met saut à 1 :
; ProcessLine saute alors jusqu'au ELSE ou ENDC correspondant.
; ===================================================================
DirCond:
    ldx     #str_endc
    jsr     CmpMnem
    lbcc    dc_ok
    ldx     #str_endif
    jsr     CmpMnem
    lbcc    dc_ok
    ldx     #str_else
    jsr     CmpMnem
    lbcc    dc_faux             ; ELSE d'un IF vrai : sauter la suite
    ldx     #str_error
    jsr     CmpMnem
    lbcc    dc_error
    ldx     #str_ifdef
    jsr     CmpMnem
    lbcc    dc_ifdef
    ldx     #str_ifndef
    jsr     CmpMnem
    lbcc    dc_ifndef
    ; IF, IFNE, IFEQ, IFGT, IFGE, IFLT, IFLE : comparaison à 0 (signée)
    ldy     #dc_table
dc_lp:
    ldx     ,y
    lbeq    dc_non
    jsr     CmpMnem
    bcc     dc_if
    leay    4,y
    bra     dc_lp
dc_if:
    pshs    y                   ; (l'évaluateur se sert de Y)
    jsr     EvalDef
    puls    y
    lbcs    dir_err
    cmpd    #0
    jmp     [2,y]               ; branche selon la comparaison
dc_ne:
    bne     dc_ok
    bra     dc_faux
dc_eq:
    beq     dc_ok
    bra     dc_faux
dc_gt:
    bgt     dc_ok
    bra     dc_faux
dc_ge:
    bge     dc_ok
    bra     dc_faux
dc_lt:
    blt     dc_ok
    bra     dc_faux
dc_le:
    ble     dc_ok
dc_faux:
    lda     #1
    sta     saut
dc_ok:
    andcc   #$FE
    rts
dc_non:
    orcc    #1
    rts
dc_error:
    ldx     #EMsgError
    jmp     ErrShow
; IFDEF / IFNDEF : symbole déjà défini plus haut dans la passe
dc_ifdef:
    jsr     DcDefini
    bcs     dc_ret
    tsta
    bne     dc_ok
    bra     dc_faux
dc_ifndef:
    jsr     DcDefini
    bcs     dc_ret
    tsta
    beq     dc_ok
    bra     dc_faux
dc_ret:
    rts

; DcDefini - A = 1 si le symbole de l'opérande est défini plus haut.
DcDefini:
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    ldx     ld_oper
    clrb
dd_len:
    lda     b,x
    jsr     EstCarSym
    bcs     dd_lfin
    incb
    bne     dd_len
dd_lfin:
    tfr     b,a
    jsr     ToNameBuf
    lbcs    ErrNomLong
    clra
    jsr     SymFind_X
    bcs     dd_rep
    ldb     SY_FL,y
    bitb    #SF_VU
    beq     dd_rep
    inca
dd_rep:
    andcc   #$FE
    rts

dc_table:
    fdb     str_if,dc_ne,str_ifne,dc_ne,str_ifeq,dc_eq,str_ifgt,dc_gt
    fdb     str_ifge,dc_ge,str_iflt,dc_lt,str_ifle,dc_le,0

; Directive : C=0 si tout va bien. Une erreur passe par ErrShow (C=1 et
; asm_err = 1 : ProcessLine ne la prend pas pour une instruction).

DirRien:
    andcc   #$FE
    rts

; EvalDef - Évalue l'opérande, qui ne doit référencer que des symboles
; déjà définis (EQU, ORG, RMB). Sortie : D, C=1 erreur affichée.
EvalDef:
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    clr     expr_flag
    ldx     ld_oper
    jsr     EvalExpr
    lbcs    dir_err
    pshs    a
    lda     expr_flag
    bita    #EXPR_UNDEF|EXPR_PROV
    puls    a
    lbne    ErrAvant
    andcc   #$FE
    rts

DirORG:
    jsr     EvalDef
    bcs     dorg_ret
    ; avant le premier octet : nouvelle origine
    tst     org_libre
    beq     dorg_trou
    std     Origine
    std     LC
    andcc   #$FE
dorg_ret:
    rts
dorg_trou:
    ; plus loin : des zéros jusqu'à la nouvelle adresse
    std     pi_tmp
    subd    LC
    lblo    ErrOrgArr
    tfr     d,y
    lbra    zeros

DirRMB:
    jsr     EvalDef
    bcs     drmb_ret
    tfr     d,y
zeros:
    cmpy    #0
    beq     drmb_ok
    clra
    jsr     EmitByte
    leay    -1,y
    bra     zeros
drmb_ok:
    andcc   #$FE
drmb_ret:
    rts

; EQU. Passe 1 : une expression qui référence un symbole défini plus
; loin (ou provisoire) donne un symbole PROVISOIRE (SF_PROV), toujours
; traité comme une référence avant (forme longue) ; la passe 3 le recalcule
; avant la passe 2 (comme lwasm, qui accepte ces EQU).
DirEQU:
    lda     ld_type
    bita    #HAS_LABEL
    lbeq    ErrNoLabel
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    lda     pass_no
    cmpa    #1
    bne     dequ_p23
    clr     expr_flag
    ldx     ld_oper
    jsr     EvalExpr
    lbcs    dir_err
    std     sym_val_tmp
    lda     expr_flag
    bita    #EXPR_UNDEF|EXPR_PROV
    beq     dequ_def
    ldd     nb_prov
    addd    #1
    std     nb_prov
    lda     #SF_PROV
    bra     dequ_add
dequ_def:
    lda     #SF_VU
    ldb     ev_rel
    beq     dequ_add
    ora     #SF_REL             ; EQU d'une adresse : reste une adresse
dequ_add:
    pshs    a
    ldx     ld_label
    lda     ld_labelLen
    jsr     ToNameBuf
    puls    a
    lbcs    ErrNomLong
    jmp     SymAdd
dequ_p23:
    ldx     ld_label
    lda     ld_labelLen
    jsr     ToNameBuf
    lbcs    ErrNomLong
    jsr     SymFind
    lbcs    ErrPhase
    lda     SY_FL,x
    ora     #SF_VU
    sta     SY_FL,x
    bita    #SF_PROV
    beq     dequ_ok
    ; provisoire : recalculé avec les valeurs connues
    pshs    x
    clr     expr_flag
    ldx     ld_oper
    jsr     EvalExpr
    puls    x
    lbcs    dir_err
    pshs    a                   ; dépend d'un autre provisoire ?
    lda     expr_flag
    anda    #EXPR_PROV
    ora     prov_chaine
    sta     prov_chaine
    puls    a
    cmpd    SY_VAL,x
    beq     dequ_ok
    std     SY_VAL,x
    inc     prov_change
dequ_ok:
    andcc   #$FE
    rts

dir_err:
    orcc    #1
    rts

DirFCB:
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    ldx     ld_oper
dfcb_loop:
    jsr     EvalExpr
    lbcs    dir_err
    tfr     b,a
    jsr     EmitByte
    lda     ,x
    cmpa    #','
    lbne    dfcb_done
    leax    1,x
    lbra    dfcb_loop
dfcb_done:
    andcc   #$FE
    rts

DirFDB:
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    ldx     ld_oper
dfdb_loop:
    jsr     EvalExpr
    lbcs    dir_err
    pshs    b
    jsr     EmitByte        ; octet haut
    puls    a
    jsr     EmitByte        ; octet bas
    lda     ,x
    cmpa    #','
    lbne    dfdb_done
    leax    1,x
    lbra    dfdb_loop
dfdb_done:
    andcc   #$FE
    rts

; FCC / FCN : le premier caractère de l'opérande est le délimiteur.
DirFCN:
    lda     #1
    bra     dfc_go
DirFCC:
    clra
dfc_go:
    sta     fc_nul
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    ldx     ld_oper
    ldb     ,x+                 ; B = délimiteur
dfc_loop:
    lda     ,x
    lbeq    ErrString
    pshs    b
    cmpa    ,s+
    beq     dfc_close
    jsr     EmitByte
    leax    1,x
    bra     dfc_loop
dfc_close:
    tst     fc_nul
    beq     dfc_ok
    clra
    jsr     EmitByte
dfc_ok:
    andcc   #$FE
    rts

; INCLUDE "chemin/NOM.EXT" : comme lwasm, le chemin part du dossier du
; fichier qui inclut ("../lib/ui.inc" depuis APPS = /LIB/UI.INC). Introuvable
; ainsi (carte sans dossiers) : NOM.EXT seul, dans ce dossier, puis à la
; racine. Guillemets facultatifs.
DirINCLUDE:
    lda     ld_type
    bita    #HAS_OPER
    lbeq    ErrOper
    ldx     ld_oper
    lda     ,x
    cmpa    #'"'
    bne     dinc_deb
    leax    1,x
dinc_deb:
    stx     pi_tmp              ; le chemin
    stx     inc_nom
dinc_scan:
    lda     ,x
    beq     dinc_fin
    cmpa    #'"'
    beq     dinc_fin
    leax    1,x
    cmpa    #'/'
    bne     dinc_scan
    stx     inc_nom
    bra     dinc_scan
dinc_fin:
    clr     ,x                  ; fin du chemin (le guillemet fermant)
    ldx     inc_nom
    tst     ,x
    lbeq    ErrOper             ; pas de nom
    ; le dossier du fichier qui inclut devient le dossier courant
    ldd     #$FFFF
    jsr     bsc_FS_Dossier
    std     inc_sauve
    ldu     ctx
    ldd     FC_DOS,u
    jsr     bsc_FS_Dossier
    ; 1. le chemin tel quel
    ldx     pi_tmp
    jsr     dinc_essai
    bcc     dinc_ouvre
    ; 2. le nom seul, dans ce dossier
    ldx     inc_nom
    jsr     dinc_essai
    bcc     dinc_ouvre
    ; 3. le nom seul, à la racine
    ldd     #0
    jsr     bsc_FS_Dossier
    ldx     inc_nom
    jsr     dinc_essai
dinc_ouvre:
    ; VISION.ASM (lib/vision.asm) : ce source est une application
    ldx     #NomInclude
    ldy     #str_vision
    ldb     #15
dinc_vis:
    lda     ,x+
    cmpa    ,y+
    bne     dinc_pas_app
    decb
    bne     dinc_vis
    lda     #1
    sta     est_app
dinc_pas_app:
    ldx     #NomInclude
    jsr     OuvreFichier        ; (message s'il est introuvable)
    pshs    cc
    ldd     inc_sauve           ; le dossier courant d'avant
    jsr     bsc_FS_Dossier
    puls    cc
    rts

; dinc_essai - X = nom ou chemin -> NomInclude ; C=0 s'il existe.
dinc_essai:
    ldy     #NomInclude
    jsr     bsc_Format_Filename_83
    clr     NomInclude+15
    ldx     #NomInclude
    ldy     #fi_buf
    jmp     bsc_FS_FileInfo

DirEND:
    lda     #1
    sta     end_flag
    andcc   #$FE
    rts

; ===================================================================
; ParseInst - Analyse l'instruction courante (mnem_buf + ld_oper).
; Remplit inst_mode, inst_pfx, inst_op, inst_extra, inst_xlen, inst_size.
; Sortie : C=1 erreur (message déjà affiché).
; ===================================================================
ParseInst:
    clr     expr_flag
    ; --- chercher le mnémonique (index par première lettre) ---
    jsr     ChercheMnem
    lbcc    pi_found
    ldx     #EMsgMnem
    jsr     ErrShow
    rts
pi_found:
    stx     inst_ptr
    ldb     INST_FLAGS,x
    stb     inst_flags
    ; --- pas d'opérande ? ---
    lda     ld_type
    bita    #HAS_OPER
    lbeq    pi_nooper
    ; --- opérande présent : inhérent avec opérande (PSHS/TFR) ? ---
    lda     inst_flags
    bita    #MI_INH
    lbne    pi_inh_oper
    ldx     ld_oper
    lda     ,x
    cmpa    #'#'
    lbeq    pi_imm
    cmpa    #'<'
    lbeq    pi_fdir
    cmpa    #'>'
    lbeq    pi_fext
    cmpa    #'['
    lbeq    pi_indexed
    jsr     HasComma
    lbcc    pi_indexed
    lda     inst_flags
    bita    #MI_REL8
    lbne    pi_rel8
    bita    #MI_REL16
    lbne    pi_rel16
    bita    #MI_DIR
    lbne    pi_mem
    lbra    pi_badop

; --- sans opérande ---
pi_nooper:
    lda     inst_flags
    bita    #MI_INH
    lbeq    pi_nomissing
    ; les instructions à opérande obligatoire refusent ici
    jsr     GenreInh
    tsta
    lbne    pi_nomissing
pi_nop_ok:
    ldx     inst_ptr
    ldd     INST_INH,x
    sta     inst_pfx
    stb     inst_op
    clra
    sta     inst_xlen
    lda     #1
    ldb     inst_pfx
    lbeq    pi_nop1
    inca
pi_nop1:
    sta     inst_size
    lda     #IM_INH
    sta     inst_mode
    andcc   #$FE
    rts
pi_nomissing:
    ldx     #EMsgOper
    jsr     ErrShow
    rts

; --- inhérent avec opérande : TFR/EXG/ADDR..., PSHS..., TFM ; pour un
;     inhérent simple, le mot qui suit est un commentaire (comme lwasm) ---
pi_inh_oper:
    jsr     GenreInh
    cmpa    #1
    lbeq    pi_tfr
    cmpa    #2
    lbeq    pi_pushpull
    cmpa    #3
    lbeq    pi_tfm
    lbra    pi_nop_ok

; GenreInh - Genre de l'inhérent courant (inst_ptr) : A = 0 simple,
; 1 paire de registres (TFR, EXG, ADDR...), 2 liste (PSHS...), 3 TFM.
GenreInh:
    ldx     inst_ptr
    ldd     INST_INH,x
    tsta
    bne     gi_pfx
    cmpb    #$1E
    beq     gi_paire
    cmpb    #$1F
    beq     gi_paire
    cmpb    #$34
    blo     gi_simple
    cmpb    #$37
    bls     gi_liste
    bra     gi_simple
gi_pfx:
    cmpa    #$10
    bne     gi_11
    cmpb    #$30
    blo     gi_simple
    cmpb    #$37
    bls     gi_paire
    bra     gi_simple
gi_11:
    cmpb    #$38
    beq     gi_tfm
gi_simple:
    clra
    rts
gi_paire:
    lda     #1
    rts
gi_liste:
    lda     #2
    rts
gi_tfm:
    lda     #3
    rts

; --- immédiat ---
pi_imm:
    lda     inst_flags
    bita    #MI_IMM8
    lbne    pi_imm8
    bita    #MI_IMM16
    lbne    pi_imm16
    lbra    pi_badop
pi_imm8:
    ldx     ld_oper
    leax    1,x
    jsr     EvalExpr
    lbcs    pi_errret
    ; plage octet : 0..255 ou -128..-1 (comme lwasm)
    tsta
    lbeq    pi_i8ok
    cmpa    #$FF
    lbne    pi_rngerr
    cmpb    #$80
    lblo    pi_rngerr
pi_i8ok:
    stb     inst_extra
    ldx     inst_ptr
    ldd     INST_IMM,x
    sta     inst_pfx
    stb     inst_op
    lda     #1
    sta     inst_xlen
    lda     #1
    ldb     inst_pfx
    lbeq    pi_i8s
    inca
pi_i8s:
    inca
    sta     inst_size
    lda     #IM_IMM
    sta     inst_mode
    andcc   #$FE
    rts
pi_imm16:
    ldx     ld_oper
    leax    1,x
    jsr     EvalExpr
    lbcs    pi_errret
    std     inst_extra
    ldx     inst_ptr
    ldd     INST_IMM,x
    sta     inst_pfx
    stb     inst_op
    lda     #2
    sta     inst_xlen
    lda     #2
    ldb     inst_pfx
    lbeq    pi_i16s
    inca
pi_i16s:
    inca
    sta     inst_size
    lda     #IM_IMM
    sta     inst_mode
    andcc   #$FE
    rts

; --- direct forcé (<) ---
pi_fdir:
    lda     inst_flags
    bita    #MI_DIR
    lbeq    pi_badop
    ldx     ld_oper
    leax    1,x
    jsr     EvalExpr
    lbcs    pi_errret
    stb     inst_extra
    ldx     inst_ptr
    ldd     INST_DIR,x
    sta     inst_pfx
    stb     inst_op
    lda     #1
    sta     inst_xlen
    lda     #1
    ldb     inst_pfx
    lbeq    pi_fd1
    inca
pi_fd1:
    inca
    sta     inst_size
    lda     #IM_DIR
    sta     inst_mode
    andcc   #$FE
    rts

; --- étendu forcé (>) ---
pi_fext:
    lda     inst_flags
    bita    #MI_EXT
    lbeq    pi_badop
    ldx     ld_oper
    leax    1,x
    jsr     EvalExpr
    lbcs    pi_errret
    std     inst_extra
    ldx     inst_ptr
    ldd     INST_EXT,x
    sta     inst_pfx
    stb     inst_op
    lda     #2
    sta     inst_xlen
    lda     #2
    ldb     inst_pfx
    lbeq    pi_fe1
    inca
pi_fe1:
    inca
    sta     inst_size
    lda     #IM_EXT
    sta     inst_mode
    andcc   #$FE
    rts

; --- mémoire : toujours étendu (lwasm en mode objet ne choisit jamais le
;     direct tout seul ; '<' le force) ---
pi_mem:
    ldx     ld_oper
    jsr     EvalExpr
    lbcs    pi_errret
    std     pi_tmp
pi_memext:
    ; étendu
    ldd     pi_tmp
    std     inst_extra
    ldx     inst_ptr
    ldd     INST_EXT,x
    sta     inst_pfx
    stb     inst_op
    lda     #2
    sta     inst_xlen
    lda     #2
    ldb     inst_pfx
    lbeq    pi_mem2
    inca
pi_mem2:
    inca
    sta     inst_size
    lda     #IM_EXT
    sta     inst_mode
    andcc   #$FE
    rts

; --- branche relative 8 bits ---
pi_rel8:
    ldx     ld_oper
    jsr     EvalExpr
    lbcs    pi_errret
    std     pi_tmp
    ldd     LC
    addd    #2
    std     pi_tmp2
    ; contrôle de portée en passe 2 uniquement
    ldb     pass_no
    cmpb    #2
    pshs    cc
    ldd     pi_tmp
    subd    pi_tmp2
    puls    cc
    lbne    pi_r8ok
    tsta
    lbne    pi_r8neg
    cmpb    #$80
    lblo    pi_r8ok
    lbra    pi_rngerr
pi_r8neg:
    cmpa    #$FF
    lbne    pi_rngerr
    cmpb    #$80
    lblo    pi_rngerr
pi_r8ok:
    stb     inst_extra
    ldx     inst_ptr
    ldd     INST_INH,x
    sta     inst_pfx
    stb     inst_op
    lda     #1
    sta     inst_xlen
    lda     #2
    sta     inst_size
    lda     #IM_REL
    sta     inst_mode
    andcc   #$FE
    rts

; --- branche relative 16 bits ---
pi_rel16:
    ldx     ld_oper
    jsr     EvalExpr
    lbcs    pi_errret
    std     pi_tmp
    ldx     inst_ptr
    ldd     INST_REL16,x
    sta     inst_pfx
    stb     inst_op
    cmpa    #$10
    lbeq    pi_r16_pfx
    cmpa    #$11
    lbeq    pi_r16_pfx
    lda     #3
    lbra    pi_r16_sz
pi_r16_pfx:
    lda     #4
pi_r16_sz:
    sta     inst_size
    ldd     LC
    addd    #3
    std     pi_tmp2
    lda     inst_size
    cmpa    #3
    lbeq    pi_r16_base
    ldd     pi_tmp2
    addd    #1
    std     pi_tmp2
pi_r16_base:
    ldd     pi_tmp
    subd    pi_tmp2
    std     inst_extra
    lda     #2
    sta     inst_xlen
    lda     #IM_REL
    sta     inst_mode
    andcc   #$FE
    rts

; --- indexé ---
pi_indexed:
    lda     inst_flags
    bita    #MI_IDX
    lbeq    pi_badop
    ldx     ld_oper
    clr     idx_ind
    clr     idx_mode
    clr     idx_sym
    clr     idx_acc
    clr     idx_lit0
    lda     ,x
    cmpa    #'['
    lbne    pi_ix_off
    lda     #1
    sta     idx_ind
    leax    1,x
pi_ix_off:
    jsr     SkipSpaces
    lda     ,x
    cmpa    #','
    lbeq    pi_ix_reg
    cmpa    #']'
    lbeq    pi_ix_bad
    ; token d'offset : accumulateur A/B/D isolé ?
    jsr     IsAccumTok
    lbcc    pi_ix_accset
    ; le texte exact « 0 » : lwasm garde un décalage 5 (ou 8) bits nul,
    ; toute autre expression nulle donne ,R
    lda     ,x
    cmpa    #'0'
    bne     pi_ix_eval
    lda     1,x
    cmpa    #','
    bne     pi_ix_eval
    inc     idx_lit0
pi_ix_eval:
    ; expression numérique / symbole
    jsr     EvalExpr
    lbcs    pi_errret
    std     pi_tmp
    ; forme longue forcée : référence avant, ou adresse (étiquette)
    lda     expr_flag
    anda    #EXPR_FWD
    ora     ev_rel
    sta     idx_sym
    lda     #IDX_EXPR
    sta     idx_mode
    jsr     SkipSpaces
    lda     ,x
    cmpa    #','
    lbeq    pi_ix_reg
    cmpa    #']'
    lbne    pi_ix_bad
    ; [expression] indirect absolu
    lda     idx_ind
    lbeq    pi_ix_bad
    lda     #IDX_ABS
    sta     idx_mode
    lbra    pi_ix_close
pi_ix_accset:
    lda     #IDX_ACC
    sta     idx_mode
    lbra    pi_ix_reg
pi_ix_reg:
    jsr     SkipSpaces
    lda     ,x
    cmpa    #','
    lbne    pi_ix_bad
    leax    1,x
    jsr     SkipSpaces
    ; pré-décrément : ,-R ou ,--R
    lda     ,x
    cmpa    #'-'
    lbeq    pi_ix_pred
    jsr     ReadReg
    lbcs    pi_ix_bad
    stb     idx_reg
    ; inc/déc seulement si pas d'offset
    lda     idx_mode
    bne     pi_ix_close
    jsr     SkipSpaces
    lda     ,x
    cmpa    #'+'
    lbeq    pi_ix_inc
    cmpa    #'-'
    lbeq    pi_ix_dec
    lbra    pi_ix_close
pi_ix_pred:
    ldb     1,x
    cmpb    #'-'
    lbeq    pi_ix_pred2
    lda     #IDX_MINUS
    sta     idx_mode
    leax    1,x
    jsr     ReadReg
    lbcs    pi_ix_bad
    stb     idx_reg
    lbra    pi_ix_close
pi_ix_pred2:
    lda     #IDX_MINUS2
    sta     idx_mode
    leax    2,x
    jsr     ReadReg
    lbcs    pi_ix_bad
    stb     idx_reg
    lbra    pi_ix_close
pi_ix_inc:
    ldb     1,x
    cmpb    #'+'
    lbeq    pi_ix_inc2
    lda     #IDX_PLUS
    sta     idx_mode
    leax    1,x
    lbra    pi_ix_close
pi_ix_inc2:
    lda     #IDX_PLUS2
    sta     idx_mode
    leax    2,x
    lbra    pi_ix_close
pi_ix_dec:
    ldb     1,x
    cmpb    #'-'
    lbeq    pi_ix_dec2
    lda     #IDX_MINUS
    sta     idx_mode
    leax    1,x
    lbra    pi_ix_close
pi_ix_dec2:
    lda     #IDX_MINUS2
    sta     idx_mode
    leax    2,x
    lbra    pi_ix_close
pi_ix_close:
    ; indirect : attendre ']'
    lda     idx_ind
    lbeq    pi_ix_build
    jsr     SkipSpaces
    lda     ,x
    cmpa    #']'
    lbne    pi_ix_bad
    leax    1,x
pi_ix_build:
    ldx     inst_ptr
    ldd     INST_IDX,x
    sta     inst_pfx
    stb     inst_op
    lda     idx_mode
    cmpa    #IDX_ABS
    lbeq    pi_ix_absb
    cmpa    #IDX_ACC
    lbeq    pi_ix_accb
    cmpa    #IDX_EXPR
    lbeq    pi_ix_expb
    ; modes sans offset : ,R / ,R+ / ,R++ / ,-R / ,--R
    ldb     idx_reg
    cmpb    #4
    lbeq    pi_ix_bad        ; PCR sans décalage non supporté
    lda     idx_ind
    lbne    pi_ix_i
    ldb     idx_mode
    cmpb    #IDX_PLUS
    lbeq    pi_ix_p_plus
    cmpb    #IDX_PLUS2
    lbeq    pi_ix_p_pp
    cmpb    #IDX_MINUS
    lbeq    pi_ix_p_minus
    cmpb    #IDX_MINUS2
    lbeq    pi_ix_p_mm
    lda     #$84
    lbra    pi_ix_pb
pi_ix_p_plus:
    lda     #$80
    lbra    pi_ix_pb
pi_ix_p_pp:
    lda     #$81
    lbra    pi_ix_pb
pi_ix_p_minus:
    lda     #$82
    lbra    pi_ix_pb
pi_ix_p_mm:
    lda     #$83
    lbra    pi_ix_pb
pi_ix_i:
    ldb     idx_mode
    cmpb    #IDX_PLUS
    lbeq    pi_ix_bad        ; [,R+] invalide
    cmpb    #IDX_MINUS
    lbeq    pi_ix_bad        ; [,-R] invalide
    cmpb    #IDX_PLUS2
    lbeq    pi_ix_i_pp
    cmpb    #IDX_MINUS2
    lbeq    pi_ix_i_mm
    lda     #$94             ; [,R]
    lbra    pi_ix_pb
pi_ix_i_pp:
    lda     #$91             ; [,R++]
    lbra    pi_ix_pb
pi_ix_i_mm:
    lda     #$93             ; [,--R]
    lbra    pi_ix_pb
pi_ix_pb:
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    lda     #1
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_accb:
    ldb     idx_reg
    cmpb    #4
    lbeq    pi_ix_bad
    lda     idx_acc
    lbeq    pi_ix_a
    cmpa    #1
    lbeq    pi_ix_b
    lda     #$8B             ; D,R
    lbra    pi_ix_accbase
pi_ix_a:
    lda     #$86             ; A,R
    lbra    pi_ix_accbase
pi_ix_b:
    lda     #$85             ; B,R
pi_ix_accbase:
    ldb     idx_ind
    lbeq    pi_ix_accbp
    adda    #$10             ; [A/R], [B/R], [D/R]
pi_ix_accbp:
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    lda     #1
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_expb:
    ldb     idx_reg
    cmpb    #4
    lbeq    pi_ix_pcr
    lda     idx_ind
    lbeq    pi_ix_expdir
    ; indirect [n,R] : [,R] si nul, puis 8 bits ou 16 bits
    lda     idx_sym
    lbne    pi_ix_e16
    ldd     pi_tmp
    lbne    pi_ix_i8
    tst     idx_lit0
    lbne    pi_ix_i8
    lda     #$94                ; [,R]
    lbra    pi_ix_pb
pi_ix_i8:
    ldd     pi_tmp
    tsta
    lbne    pi_ix_e16n
    cmpb    #$80
    lblo    pi_ix_e8i
    lbra    pi_ix_e16
pi_ix_e16n:
    cmpa    #$FF
    lbne    pi_ix_e16
    cmpb    #$80
    lblo    pi_ix_e16
pi_ix_e8i:
    lda     #$98
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    ldb     pi_tmp+1
    stb     inst_extra+1
    lda     #2
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_e16:
    lda     #$99
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    ldd     pi_tmp
    std     inst_extra+1
    lda     #3
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_expdir:
    lda     idx_sym
    lbne    pi_ix_e16d
    ldd     pi_tmp
    lbne    pi_ix_e5t
    tst     idx_lit0
    lbne    pi_ix_e5t
    lda     #$84                ; ,R
    lbra    pi_ix_pb
pi_ix_e5t:
    ldd     pi_tmp
    tsta
    lbeq    pi_ix_e5c
    cmpa    #$FF
    lbne    pi_ix_e8d
    cmpb    #$F0
    lblo    pi_ix_e8d
    lbra    pi_ix_e5
pi_ix_e5c:
    cmpb    #15
    lbhi    pi_ix_e8d
pi_ix_e5:
    ldb     pi_tmp+1
    andb    #$1F
    tfr     b,a
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    lda     #1
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_e8d:
    ldd     pi_tmp
    tsta
    lbne    pi_ix_e8dn
    cmpb    #$80
    lblo    pi_ix_e8d2        ; 0..127 → 8 bits
    lbra    pi_ix_e16d        ; 128..255 → 16 bits
pi_ix_e8dn:
    cmpa    #$FF
    lbne    pi_ix_e16d
    cmpb    #$80
    lblo    pi_ix_e16d
pi_ix_e8d2:
    lda     #$88
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    ldb     pi_tmp+1
    stb     inst_extra+1
    lda     #2
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_e16d:
    lda     #$89
    ldb     idx_reg
    jsr     BuildPB
    sta     inst_extra
    ldd     pi_tmp
    std     inst_extra+1
    lda     #3
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_pcr:
    lda     idx_ind
    lbne    pi_ix_bad        ; [n,pcr] non supporté
    ; base = adresse de l'instruction suivante (préfixe éventuel compris)
    ldd     LC
    tst     inst_pfx
    beq     pi_ix_pcrb
    addd    #1
pi_ix_pcrb:
    std     pcr_base
    ; 16 bits : référence avant, ou cible absolue (constante : lwasm la
    ; reloge, il ne peut pas connaître la distance)
    lda     expr_flag
    bita    #EXPR_FWD
    lbne    pi_ix_pcr16
    tst     ev_rel
    lbeq    pi_ix_pcr16
    ldd     pcr_base
    addd    #3
    std     pi_tmp2
    ldd     pi_tmp
    subd    pi_tmp2
    tsta
    lbne    pi_ix_pcrneg
    cmpb    #$80
    lblo    pi_ix_pcr8
    lbra    pi_ix_pcr16
pi_ix_pcrneg:
    cmpa    #$FF
    lbne    pi_ix_pcr16
    cmpb    #$80
    lblo    pi_ix_pcr16
pi_ix_pcr8:
    lda     #$8C
    sta     inst_extra
    stb     inst_extra+1
    lda     #2
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_pcr16:
    ldd     pcr_base
    addd    #4
    std     pi_tmp2
    ldd     pi_tmp
    subd    pi_tmp2
    std     inst_extra+1
    lda     #$8D
    sta     inst_extra
    lda     #3
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_absb:
    lda     #$9F
    sta     inst_extra
    ldd     pi_tmp
    std     inst_extra+1
    lda     #3
    sta     inst_xlen
    lbra    pi_ix_done
pi_ix_done:
    ; inst_size = octets d'opcode + inst_xlen
    ldb     inst_xlen
    lda     inst_pfx
    lbeq    pi_ix_s
    incb
pi_ix_s:
    stb     inst_size
    lda     #IM_IDX
    sta     inst_mode
    andcc   #$FE
    rts

; --- TFR / EXG : paires de registres ---
pi_tfr:
    ldx     ld_oper
    jsr     ParseReg
    lbcs    pi_ix_bad
    tfr     a,b
    lslb
    lslb
    lslb
    lslb
    stb     pi_tmp
    lda     ,x
    cmpa    #','
    lbne    pi_ix_bad
    leax    1,x
    jsr     SkipSpaces
    jsr     ParseReg
    lbcs    pi_ix_bad
    tfr     a,b
    stb     pi_tmp2
    lda     pi_tmp
    ora     pi_tmp2
    sta     inst_extra
    ldx     inst_ptr
    ldd     INST_INH,x
    sta     inst_pfx
    stb     inst_op
pi_paire_fin:
    lda     #1
    sta     inst_xlen
    lda     #2
    tst     inst_pfx
    beq     pi_tfr_s
    inca                        ; ADDR... : préfixe $10
pi_tfr_s:
    sta     inst_size
    lda     #IM_INH
    sta     inst_mode
    andcc   #$FE
    rts

; --- TFM r0+,r1+ / r0-,r1- / r0+,r1 / r0,r1+ (r = D X Y U S) ---
pi_tfm:
    ldx     ld_oper
    jsr     TfmReg
    lbcs    pi_ix_bad
    stb     pi_tmp              ; registre source << 4
    sta     pi_tmp+1            ; son signe : 0, '+' ou '-'
    lda     ,x+
    cmpa    #','
    lbne    pi_ix_bad
    jsr     TfmReg
    lbcs    pi_ix_bad
    lsrb                        ; destination : code non décalé
    lsrb
    lsrb
    lsrb
    orb     pi_tmp
    stb     inst_extra
    ldb     pi_tmp+1
    ; A = signe destination, B = signe source
    cmpb    #'+'
    bne     pi_tfm_s2
    cmpa    #'+'
    beq     pi_tfm_pp
    tsta
    beq     pi_tfm_p0
    lbra    pi_ix_bad
pi_tfm_s2:
    cmpb    #'-'
    bne     pi_tfm_s0
    cmpa    #'-'
    lbne    pi_ix_bad
    ldb     #$39                ; r0-,r1-
    bra     pi_tfm_op
pi_tfm_s0:
    cmpa    #'+'
    lbne    pi_ix_bad
    ldb     #$3B                ; r0,r1+
    bra     pi_tfm_op
pi_tfm_pp:
    ldb     #$38                ; r0+,r1+
    bra     pi_tfm_op
pi_tfm_p0:
    ldb     #$3A                ; r0+,r1
pi_tfm_op:
    stb     inst_op
    lda     #$11
    sta     inst_pfx
    lbra    pi_paire_fin

; TfmReg - X = registre de TFM (D X Y U S) suivi d'un signe facultatif.
; Sortie : B = code << 4, A = signe (0, '+' ou '-'), X après ; C=1 sinon.
TfmReg:
    jsr     ParseReg
    bcs     tr_non
    cmpa    #4
    bhi     tr_non
    ldb     #16
    mul                         ; D = 16 × code : B = code << 4
    lda     ,x
    cmpa    #'+'
    beq     tr_signe
    cmpa    #'-'
    beq     tr_signe
    clra
    andcc   #$FE
    rts
tr_signe:
    leax    1,x
    andcc   #$FE
    rts
tr_non:
    orcc    #1
    rts

; --- PSHS / PULS / PSHU / PULU : liste de registres ---
pi_pushpull:
    ldx     inst_ptr
    ldd     INST_INH,x
    stb     inst_op
    clra
    sta     inst_pfx
    ; opcode : 34=PSHS 35=PULS 36=PSHU 37=PULU
    ldx     ld_oper
    clr     pp_mask
pp_loop:
    jsr     SkipSpaces
    jsr     ParseRegName
    lbcs    pi_ix_bad
    stb     pp_idx
    ; A = bit du registre via pp_bits[B]
    pshs    x
    ldx     #pp_bits
    abx
    lda     ,x
    puls    x
    ; validation selon opcode
    ldb     inst_op
    cmpb    #$36
    lblo    pp_sside
    ; PSHU/PULU : U (index 6) interdit
    ldb     pp_idx
    cmpb    #6
    lbeq    pi_ix_bad
    lbra    pp_ok
pp_sside:
    ; PSHS/PULS : S (index 7) interdit
    ldb     pp_idx
    cmpb    #7
    lbeq    pi_ix_bad
pp_ok:
    ora     pp_mask
    sta     pp_mask
    jsr     SkipSpaces
    lda     ,x
    cmpa    #','
    lbne    pp_done
    leax    1,x
    lbra    pp_loop
pp_done:
    lda     pp_mask
    sta     inst_extra
    lda     #1
    sta     inst_xlen
    lda     #2
    sta     inst_size
    lda     #IM_INH
    sta     inst_mode
    andcc   #$FE
    rts

pp_bits:
    fcb     $01,$02,$04,$08,$10,$20,$40,$40,$80,$06   ; CC A B DP X Y U S PC D

; --- erreurs ---
pi_badop:
    ldx     #EMsgOperand
    jsr     ErrShow
    orcc    #1
    rts
pi_ix_bad:
    ldx     #EMsgOperand
    jsr     ErrShow
    orcc    #1
    rts
pi_rngerr:
    ldx     #EMsgRange
    jsr     ErrShow
    orcc    #1
    rts
pi_errret:
    rts

; ===================================================================
; CmpEntryName - Compare mnem_buf avec le nom de l'entrée table en X.
; Sortie : C=0 égaux, C=1 différents. X inchangé (début d'entrée).
; ===================================================================
CmpEntryName:
    pshs    x,y
    ldy     #mnem_buf
cen_lp:
    lda     ,x+
    cmpa    ,y+
    lbne    cen_diff
    tsta
    lbeq    cen_same
    lbra    cen_lp
cen_same:
    puls    x,y
    andcc   #$FE
    rts
cen_diff:
    puls    x,y
    orcc    #1
    rts

; ===================================================================
; HasComma - C=0 si l'opérande (ld_oper) contient une virgule.
; ===================================================================
HasComma:
    ldx     ld_oper
hc_lp:
    lda     ,x
    lbeq    hc_no
    cmpa    #','
    lbeq    hc_yes
    cmpa    #$0D
    lbeq    hc_no
    cmpa    #$0A
    lbeq    hc_no
    leax    1,x
    lbra    hc_lp
hc_yes:
    andcc   #$FE
    rts
hc_no:
    orcc    #1
    rts

; ===================================================================
; SkipSpaces - Avance X sur les espaces.
; ===================================================================
SkipSpaces:
ss_lp:
    lda     ,x
    cmpa    #' '
    lbne    ss_done
    leax    1,x
    lbra    ss_lp
ss_done:
    rts

; ===================================================================
; BuildPB - A = postbyte de base, B = code registre (0-3).
; Sortie : A |= (B<<5).
; ===================================================================
BuildPB:
    pshs    b
    lslb
    lslb
    lslb
    lslb
    lslb
    stb     pb_tmp
    puls    b
    ora     pb_tmp
    rts

; ===================================================================
; IsAccumTok - Token en X = accumulateur A/B/D isolé ?
; Sortie : C=0 oui (A = code 0/1/2, X après le token, idx_acc défini),
;          C=1 non (X inchangé).
; ===================================================================
IsAccumTok:
    pshs    x
    lda     ,x
    jsr     UpA
    cmpa    #'A'
    lbeq    iat_a
    cmpa    #'B'
    lbeq    iat_b
    cmpa    #'D'
    lbeq    iat_d
    lbra    iat_no
iat_a:
    ldb     #0
    lbra    iat_chk
iat_b:
    ldb     #1
    lbra    iat_chk
iat_d:
    ldb     #2
iat_chk:
    leax    1,x
    jsr     SkipSpaces
    lda     ,x
    cmpa    #','
    lbeq    iat_yes
    cmpa    #']'
    lbeq    iat_yes
    lbra    iat_no
iat_yes:
    stb     idx_acc
    stx     0,s
    andcc   #$FE
    puls    x,pc
iat_no:
    orcc    #1
    puls    x,pc

; ===================================================================
; ReadRegName - Lit un nom de registre (1-3 lettres) dans regbuf.
; Entrée : X = premier caractère. Sortie : X après le nom, regbuf =
;          nom en majuscules (NUL terminal) ; C=1 si pas de lettre.
; ===================================================================
ReadRegName:
    pshs    y
    ldy     #regbuf
    clrb
rrn_lp:
    lda     ,x
    cmpa    #'A'
    lblo    rrn_end
    cmpa    #'Z'
    lbls    rrn_chk
    cmpa    #'a'
    lblo    rrn_end
    cmpa    #'z'
    lbhi    rrn_end
rrn_chk:
    cmpb    #3
    lbhs    rrn_end
    jsr     UpA
    sta     ,y+
    incb
    leax    1,x
    lbra    rrn_lp
rrn_end:
    tstb
    lbeq    rrn_no
    clr     ,y
    andcc   #$FE
    puls    y,pc
rrn_no:
    orcc    #1
    puls    y,pc

; ===================================================================
; ReadReg - Registre indexé en X.
; Sortie : B = 0=X 1=Y 2=U 3=S 4=PCR, X après le nom ; C=1 si inconnu.
; ===================================================================
ReadReg:
    pshs    x
    jsr     ReadRegName
    lbcs    rr_no
    lda     regbuf
    cmpa    #'X'
    lbne    rr_y
    ldb     #0
    lbra    rr_yes
rr_y:
    cmpa    #'Y'
    lbne    rr_u
    ldb     #1
    lbra    rr_yes
rr_u:
    cmpa    #'U'
    lbne    rr_s
    ldb     #2
    lbra    rr_yes
rr_s:
    cmpa    #'S'
    lbne    rr_pc
    ldb     #3
    lbra    rr_yes
rr_pc:
    cmpa    #'P'
    lbne    rr_no
    lda     regbuf+1
    cmpa    #'C'
    lbeq    rr_pc_ok
    cmpa    #'R'
    lbne    rr_no
rr_pc_ok:
    ldb     #4
rr_yes:
    stx     0,s
    andcc   #$FE
    puls    x,pc
rr_no:
    orcc    #1
    puls    x,pc

; ===================================================================
; ParseReg - Registre de TFR/EXG en X.
; Sortie : A = code (D=0 X=1 Y=2 U=3 S=4 PC=5 A=8 B=9 CC=$A DP=$B),
;          X après le nom ; C=1 si inconnu.
; ===================================================================
ParseReg:
    pshs    x
    clr     regbuf+1            ; comparaison sur 3 octets complétés de NUL
    clr     regbuf+2
    jsr     ReadRegName
    bcs     pr_no
    stx     pr_fin
    ; regbuf : nom en majuscules, NUL final ; table pr_noms (nom, code)
    ldx     #pr_noms
pr_lp:
    lda     ,x
    beq     pr_no
    cmpa    regbuf
    bne     pr_suiv
    lda     1,x
    cmpa    regbuf+1
    bne     pr_suiv
    lda     2,x
    cmpa    regbuf+2
    bne     pr_suiv
    lda     3,x                 ; code
    andcc   #$FE
    leas    2,s                 ; X d'entrée oublié (LEAS ne touche pas CC)
    ldx     pr_fin              ; (LDX non plus touche C : seuls N, Z, V)
    rts
pr_suiv:
    leax    4,x
    bra     pr_lp
pr_no:
    orcc    #1
    puls    x,pc

; nom sur 3 octets (NUL complétés), code TFR/EXG du 6309
pr_noms:
    fcb     'D,0,0,$00,'X,0,0,$01,'Y,0,0,$02,'U,0,0,$03
    fcb     'S,0,0,$04,'P,'C,0,$05,'P,'C,'R,$05,'W,0,0,$06
    fcb     'V,0,0,$07,'A,0,0,$08,'B,0,0,$09,'C,'C,0,$0A
    fcb     'D,'P,0,$0B,'E,0,0,$0E,'F,0,0,$0F,0

; ===================================================================
; ParseRegName - Nom de registre de PSHS/PULS en X.
; Sortie : B = index (0=CC 1=A 2=B 3=DP 4=X 5=Y 6=U 7=S 8=PC),
;          X après le nom ; C=1 si inconnu.
; ===================================================================
ParseRegName:
    pshs    x
    jsr     ReadRegName
    lbcs    prn_no
    lda     regbuf
    cmpa    #'C'
    lbne    prn_a
    lda     regbuf+1
    cmpa    #'C'
    lbne    prn_no
    ldb     #0
    lbra    prn_ok
prn_a:
    cmpa    #'A'
    lbne    prn_b
    ldb     #1
    lbra    prn_ok
prn_b:
    cmpa    #'B'
    lbne    prn_dp
    ldb     #2
    lbra    prn_ok
prn_dp:
    cmpa    #'D'
    lbne    prn_x
    ldb     #9                  ; D = A,B
    lda     regbuf+1
    lbeq    prn_ok
    cmpa    #'P'
    lbne    prn_no
    ldb     #3
    lbra    prn_ok
prn_x:
    cmpa    #'X'
    lbne    prn_y
    ldb     #4
    lbra    prn_ok
prn_y:
    cmpa    #'Y'
    lbne    prn_u
    ldb     #5
    lbra    prn_ok
prn_u:
    cmpa    #'U'
    lbne    prn_s
    ldb     #6
    lbra    prn_ok
prn_s:
    cmpa    #'S'
    lbne    prn_pc
    ldb     #7
    lbra    prn_ok
prn_pc:
    cmpa    #'P'
    lbne    prn_no
    lda     regbuf+1
    cmpa    #'C'
    lbeq    prn_pc_ok
    cmpa    #'R'
    lbne    prn_no
prn_pc_ok:
    ldb     #8
prn_ok:
    stx     0,s
    puls    x,pc
prn_no:
    orcc    #1
    puls    x,pc

; ===================================================================
; Cmp2 - Compare 2 caractères NUL-terminés (X vs Y). C=0 égaux.
; ===================================================================
Cmp2:
    lda     ,x+
    cmpa    ,y+
    lbne    c2_diff
    tsta
    lbeq    c2_same
    lbra    Cmp2
c2_same:
    andcc   #$FE
    rts
c2_diff:
    orcc    #1
    rts

; ===================================================================
; EmitInst - Émet l'instruction courante via ParseInst.
; ===================================================================
EmitInst:
    jsr     ParseInst
    lbcs    ei_ret
    lda     inst_pfx
    lbeq    ei_op
    jsr     EmitByte
ei_op:
    lda     inst_op
    jsr     EmitByte
    ldb     inst_xlen
    ldx     #inst_extra
    tstb
    lbeq    ei_fin           ; inst_xlen=0 : rien à émettre
ei_xl:
    lda     ,x+
    jsr     EmitByte
    decb
    lbne    ei_xl
ei_fin:
    andcc   #$FE
ei_ret:
    rts

; ===================================================================
; ChercheMnem - mnem_buf dans la table, par l'index de InitMnem.
; Sortie : C=0, X = entrée ; C=1 inconnu.
; ===================================================================
ChercheMnem:
    lda     mnem_buf
    suba    #'A'
    cmpa    #25
    bhi     chm_non
    lsla
    ldx     #mn_index
    leax    a,x
    ldy     ,x                  ; première entrée de la lettre
    ldd     2,x                 ; fin
    std     chm_fin
chm_lp:
    cmpy    chm_fin
    bhs     chm_non
    ldx     ,y++
    jsr     CmpEntryName
    bcs     chm_lp
    rts
chm_non:
    orcc    #1
    rts

; ===================================================================
; EmitByte - Émet un octet (A) à LC, qui avance.
; Passe 1 : compte seulement. Passe 2 : l'octet va dans OutLocalBuf, vidé
; par blocs de 256 en page 2. HautEau = taille du binaire (LC - Origine).
; Au-delà de 32 Ko : trop_gros (PassLoop arrête la passe).
; Préserve tous les registres.
; ===================================================================
EmitByte:
    pshs    d,x
    clr     org_libre
    ldx     LC
    leax    1,x
    stx     LC
    tfr     x,d
    subd    Origine
    cmpd    #$8000
    bls     eb_taille
    lda     #1
    sta     trop_gros
    puls    d,x,pc
eb_taille:
    cmpd    HautEau
    bls     eb_hb
    std     HautEau
eb_hb:
    lda     pass_no
    cmpa    #2
    bne     eb_ret
    lda     ,s                  ; l'octet
    ldx     OutLocalIdx
    sta     OutLocalBuf,x
    leax    1,x
    stx     OutLocalIdx
    cmpx    #256
    bne     eb_ret
    jsr     FlushOutBuf
eb_ret:
    puls    d,x,pc

; ===================================================================
; FlushOutBuf - Expédie le buffer local vers la page 2 (FarWrite)
; ===================================================================
FlushOutBuf:
    pshs    d,x,y,u
    ldu     OutLocalIdx
    beq     fob_end         ; Si le buffer est vide, on ne fait rien
    ; sys_FarWrite(A=PageDest, B=PageSource, X=PtrSource, Y=PtrDest, U=Taille)
    lda     #2
    ldb     current_page    ; la page de l'assembleur
    ldx     #OutLocalBuf
    ldy     OutPtr
    jsr     bsc_FarWrite
    ldd     OutPtr
    addd    OutLocalIdx
    std     OutPtr
    ldd     #0
    std     OutLocalIdx
fob_end:
    puls    d,x,y,u,pc

; ===================================================================
; Évaluateur d'expressions (16 bits non signés)
; EvalExpr : X = début -> X = après, D = valeur, C=1 erreur.
; expr_flag reçoit EXPR_SYM / EXPR_UNDEF / EXPR_FWD (cumulés : l'appelant
; le remet à zéro) ; ev_rel = nombre d'adresses (étiquettes) dans le
; résultat, comme lwasm : fin-debut vaut 0 (une constante), debut+2 vaut 1
; (une adresse). Les termes de * et / sont de simples nombres.
; ===================================================================
EvalExpr:
EvalAddSub:
    jsr     EvalMulDiv
    lbcs    EvErr
ev_as_lp:
    std     as_tmp
    lda     ,x
    cmpa    #'+'
    lbeq    ev_as_plus
    cmpa    #'-'
    lbeq    ev_as_minus
    ldd     as_tmp
    andcc   #$FE
    rts
ev_as_plus:
    leax    1,x
    ldd     as_tmp
    pshs    d
    lda     ev_rel
    pshs    a
    jsr     EvalMulDiv
    lbcs    EvErrPop3
    std     as_tmp              ; terme de droite
    puls    a
    adda    ev_rel
    sta     ev_rel
    puls    d                   ; terme de gauche
    addd    as_tmp
    lbra    ev_as_lp
ev_as_minus:
    leax    1,x
    ldd     as_tmp
    pshs    d
    lda     ev_rel
    pshs    a
    jsr     EvalMulDiv
    lbcs    EvErrPop3
    std     as_tmp              ; terme de droite
    puls    a
    suba    ev_rel
    sta     ev_rel              ; gauche - droite
    puls    d                   ; terme de gauche
    subd    as_tmp
    lbra    ev_as_lp

EvalMulDiv:
    jsr     EvalPrimary
    lbcs    EvErr
ev_md_lp:
    std     md_tmp
    lda     ,x
    cmpa    #'*'
    lbeq    ev_mul
    cmpa    #'/'
    lbeq    ev_div
    ldd     md_tmp
    andcc   #$FE
    rts
ev_mul:
    leax    1,x
    ldd     md_tmp
    pshs    d                   ; terme de gauche
    lda     ev_rel
    pshs    a
    jsr     EvalPrimary
    lbcs    EvErrPop3
    std     mu_b                ; terme de droite
    puls    a
    jsr     ev_rel_ou
    puls    d
    jsr     Mul16
    lbra    ev_md_lp
ev_div:
    leax    1,x
    ldd     md_tmp
    pshs    d                   ; dividende
    lda     ev_rel
    pshs    a
    jsr     EvalPrimary
    lbcs    EvErrPop3
    std     dv_d                ; diviseur
    puls    a
    jsr     ev_rel_ou
    ldd     dv_d
    lbeq    EvErrDiv0
    puls    d
    jsr     Div16
    lbra    ev_md_lp

; ev_rel_ou - ev_rel = (A ou ev_rel) ? 1 : 0. Préserve B.
ev_rel_ou:
    ora     ev_rel
    beq     ev_ro0
    lda     #1
ev_ro0:
    sta     ev_rel
    rts

EvErrPop3:
    leas    3,s
EvErr:
    orcc    #1
    rts
EvErrDiv0:
    leas    2,s
    ldx     #EMsgDiv0
    jmp     ErrShow

; EvalPrimary - un terme : (expr), 'c, $hex, %bin, décimal, *, -terme,
; +terme, symbole. ev_rel = 1 pour une adresse (étiquette, *), 0 sinon.
EvalPrimary:
evp_sp:
    lda     ,x
    cmpa    #' '
    lbne    evp_got
    leax    1,x
    lbra    evp_sp
evp_got:
    clr     ev_rel
    cmpa    #'('
    lbne    evp_par2
    leax    1,x
    jsr     EvalExpr
    lbcs    evp_ret
    pshs    a
    lda     ,x
    cmpa    #')'
    puls    a
    lbne    evp_err
    leax    1,x
    andcc   #$FE
    rts
evp_par2:
    cmpa    #39
    lbne    evp_lc
    ; 'c : littéral caractère (un ' fermant est toléré)
    leax    1,x
    clra
    ldb     ,x
    lbeq    evp_err
    leax    1,x
    pshs    a
    lda     ,x
    cmpa    #39
    bne     evp_c1
    leax    1,x
evp_c1:
    puls    a
    andcc   #$FE
    rts
evp_lc:
    cmpa    #'*'
    lbne    evp_char2
    ; * : l'adresse de la ligne
    leax    1,x
    lda     #1
    sta     ev_rel
    ldd     LC
    andcc   #$FE
    rts
evp_char2:
    cmpa    #'$'
    lbeq    evp_hex
    cmpa    #'%'
    lbeq    evp_bin
    cmpa    #'0'
    lblo    evp_sym
    cmpa    #'9'
    lbhi    evp_sym
    ; nombre décimal
    ldb     #10
    lbra    evp_nbase
evp_hex:
    leax    1,x
    ldb     #16
    lbra    evp_nbase
evp_bin:
    leax    1,x
    ldb     #2
evp_nbase:
    stb     madd_base
    lda     ,x                  ; au moins un chiffre
    jsr     DigitVal
    lbcs    evp_err
    ldd     #0
evp_nloop:
    pshs    d          ; sauve la valeur accumulée (Dhi,Dlo)
    lda     ,x
    jsr     DigitVal
    lbcs    evp_nend_pop
    leax    1,x
    sta     madd_digit
    puls    d          ; restaure la valeur accumulée
    jsr     MultAdd16
    lbcs    evp_ovf
    lbra    evp_nloop
evp_nend_pop:
    puls    d          ; D = valeur accumulée
    andcc   #$FE
    rts
evp_ovf:
    ldx     #EMsgOvf
    jmp     ErrShow
evp_sym:
    cmpa    #'-'
    lbne    evp_sym2
    leax    1,x
    jsr     EvalPrimary
    lbcs    evp_ret
    nega
    negb
    sbca    #0
    pshs    a
    lda     ev_rel
    nega
    sta     ev_rel
    puls    a
    andcc   #$FE
    rts
evp_sym2:
    cmpa    #'+'
    lbne    evp_sym3
    leax    1,x
    jmp     EvalPrimary
evp_sym3:
    jmp     EvalSymbol
evp_err:
    ldx     #EMsgExpr
    jmp     ErrShow
evp_ret:
    rts

; ===================================================================
; EvalSymbol - Référence de symbole. Entrée : X = début du nom.
; Sortie : X = après, D = valeur, expr_flag et ev_rel mis à jour.
; Un symbole pas encore vu dans la passe est une référence avant
; (EXPR_FWD) ; inconnu en passe 1 : valeur 0 (EXPR_UNDEF), en passe 2 :
; erreur.
; ===================================================================
EvalSymbol:
    pshs    x
    clrb
es_len:
    lda     ,x
    jsr     EstCarSym
    bcs     es_end
    leax    1,x
    incb
    bne     es_len
es_end:
    tfr     b,a
    puls    x
    tsta
    lbeq    evp_err
    pshs    a
    jsr     ToNameBuf
    puls    a
    lbcs    ErrNomLong
    leax    a,x                 ; X après le nom (A <= 31 : décalage signé ok)
    jsr     SymFind_X           ; préserve X
    bcc     es_found
    lda     no_undef
    lbne    es_err
    lda     expr_flag
    ora     #EXPR_SYM|EXPR_UNDEF|EXPR_FWD
    sta     expr_flag
    ldd     #0
    andcc   #$FE
    rts
es_err:
    ldx     #EMsgSym
    jmp     ErrShow
es_found:
    ; Y = symbole
    lda     expr_flag
    ora     #EXPR_SYM
    ldb     SY_FL,y
    bitb    #SF_PROV
    beq     es_def
    ora     #EXPR_FWD|EXPR_PROV
es_def:
    bitb    #SF_VU
    bne     es_vu
    ora     #EXPR_FWD
es_vu:
    sta     expr_flag
    clra
    bitb    #SF_REL
    beq     es_abs
    inca
es_abs:
    sta     ev_rel
    ldd     SY_VAL,y
    andcc   #$FE
    rts

; EstCarSym - A fait partie d'un nom ? (lettre, chiffre, _ . $ @ ?)
; C=0 oui, C=1 non. Préserve A et B.
EstCarSym:
    cmpa    #'0'
    blo     ecs_autre
    cmpa    #'9'
    bls     ecs_oui
    cmpa    #'A'
    blo     ecs_autre
    cmpa    #'Z'
    bls     ecs_oui
    cmpa    #'a'
    blo     ecs_autre
    cmpa    #'z'
    bls     ecs_oui
ecs_autre:
    cmpa    #'_'
    beq     ecs_oui
    cmpa    #'.'
    beq     ecs_oui
    cmpa    #'$'
    beq     ecs_oui
    cmpa    #'@'
    beq     ecs_oui
    cmpa    #'?'
    beq     ecs_oui
    orcc    #1
    rts
ecs_oui:
    andcc   #$FE
    rts
; ===================================================================
; DigitVal - Valeur du chiffre selon madd_base (2, 10 ou 16).
; Entrée : A = char. Sortie : A = valeur, C=1 si non chiffre.
; ===================================================================
DigitVal:
    ldb     madd_base
    cmpb    #16
    lbeq    dv_hex
    cmpb    #2
    lbeq    dv_bin
    ; décimal
    cmpa    #'0'
    lblo    dv_no
    cmpa    #'9'
    lbhi    dv_no
    suba    #'0'
    andcc   #$FE
    rts
dv_hex:
    jsr     HexVal
    rts
dv_bin:
    cmpa    #'0'
    lbeq    dv_b0
    cmpa    #'1'
    lbeq    dv_b1
    lbra    dv_no
dv_b0:
    lda     #0
    andcc   #$FE
    rts
dv_b1:
    lda     #1
    andcc   #$FE
    rts
dv_no:
    orcc    #1
    rts

; ===================================================================
; HexVal - A → 0-15 si hexadécimal ; C=1 sinon.
; ===================================================================
HexVal:
    cmpa    #'0'
    lblo    hv_no
    cmpa    #'9'
    lbls    hv_09
    cmpa    #'A'
    lblo    hv_no
    cmpa    #'F'
    lbls    hv_AF
    cmpa    #'a'
    lblo    hv_no
    cmpa    #'f'
    lbls    hv_af
    lbra    hv_no
hv_09:
    suba    #'0'
    andcc   #$FE
    rts
hv_AF:
    suba    #'A'-10
    andcc   #$FE
    rts
hv_af:
    suba    #'a'-10
    andcc   #$FE
    rts
hv_no:
    orcc    #1
    rts

; ===================================================================
; UpA - A en majuscule si minuscule.
; ===================================================================
UpA:
    cmpa    #'a'
    lblo    UpA_done
    cmpa    #'z'
    lbhi    UpA_done
    suba    #32
UpA_done:
    rts

; ===================================================================
; MultAdd16 - D = D×base + digit (16 bits, base ≤ 255).
; Entrée : D = valeur, madd_digit = chiffre, madd_base = base.
; Sortie : D = résultat, C=1 débordement.
; ===================================================================
MultAdd16:
    pshs    d          ; [s]=Dhi, [s+1]=Dlo
    ldd     #0
    std     mul_tmp
    sta     mul_tmp+2
    ; Dlo×base
    ldd     ,s
    lda     madd_base
    ldb     1,s         ; Dlo (0,s = Dhi)
    mul                 ; A:B = Dlo×base
    stb     mul_tmp
    pshs    a          ; [s]=loHi, [s+1]=Dhi, [s+2]=Dlo
    ; Dhi×base
    lda     madd_base
    ldb     1,s         ; Dhi (1,s = Dhi après pshs a)
    mul                 ; A:B = Dhi×base
    addb    ,s+         ; B += loHi
    stb     mul_tmp+1
    lbcc    madd_a
    inca                ; report dans A
madd_a:
    sta     mul_tmp+2
    ; + digit
    lda     madd_digit
    adda    mul_tmp
    sta     mul_tmp
    lbcc    madd_ok
    inc     mul_tmp+1
    lbne    madd_ok
    inc     mul_tmp+2
madd_ok:
    lda     mul_tmp+2
    lbne    madd_ovf
    lda     mul_tmp+1
    ldb     mul_tmp
    leas    2,s
    andcc   #$FE        ; (la retenue de l'ADDA ci-dessus n'est pas une erreur)
    rts
madd_ovf:
    leas    2,s
    orcc    #1
    rts

; ===================================================================
; Mul16 - D = D × mu_b (les 16 bits bas du produit).
; ===================================================================
Mul16:
    std     mu_a
    lda     mu_a+1
    ldb     mu_b+1
    mul
    std     mu_r
    lda     mu_a
    ldb     mu_b+1
    mul
    addb    mu_r
    stb     mu_r
    lda     mu_a+1
    ldb     mu_b
    mul
    addb    mu_r
    stb     mu_r
    ldd     mu_r
    rts

; ===================================================================
; Div16 - D = D ÷ dv_d (non signés, dv_d non nul).
; ===================================================================
Div16:
    std     dv_q
    ldd     #0
    std     dv_r
    lda     #16
    sta     dv_n
dv_lp:
    lsl     dv_q+1              ; quotient <<= 1, le bit sortant entre
    rol     dv_q                ; dans le reste
    rol     dv_r+1
    rol     dv_r
    ldd     dv_r
    subd    dv_d
    blo     dv_suiv
    std     dv_r
    inc     dv_q+1
dv_suiv:
    dec     dv_n
    bne     dv_lp
    ldd     dv_q
    rts


; ===================================================================
; Table des symboles : 256 seaux (sym_heads), chaque symbole à la suite
; du précédent dans sym_pool (SY_SUIV, SY_VAL, SY_FL, SY_LEN, SY_NOM).
; ===================================================================

; ToNameBuf - X = nom, A = longueur -> name_buf (casse gardée, NUL),
; nm_len, nm_hash. C=1 si vide ou plus de SYM_MAXLEN caractères.
; Préserve X, Y et D.
ToNameBuf:
    pshs    d,x,y
    tsta
    beq     tnb_long
    cmpa    #SYM_MAXLEN
    bhi     tnb_long
    sta     nm_len
    tfr     a,b
    ldy     #name_buf
    clr     nm_hash
tnb_lp:
    lda     ,x+
    sta     ,y+
    pshs    a
    lda     nm_hash             ; hash = 2*hash + retenue + caractère
    lsla
    adca    ,s+
    sta     nm_hash
    decb
    bne     tnb_lp
    clr     ,y
    andcc   #$FE
    puls    d,x,y,pc
tnb_long:
    orcc    #1
    puls    d,x,y,pc

; SymFind_X - Cherche name_buf. C=0 : Y = le symbole ; C=1 absent.
; sf_seau = adresse de son seau (pour SymAdd). Préserve X et D.
SymFind_X:
    pshs    d,x
    ldb     nm_hash
    clra
    aslb
    rola
    addd    #sym_heads
    std     sf_seau
    tfr     d,y
    ldy     ,y
sfx_lp:
    beq     sfx_non
    lda     SY_LEN,y
    cmpa    nm_len
    bne     sfx_suiv
    leax    SY_NOM,y
    pshs    y
    ldy     #name_buf
    ldb     nm_len
sfx_cmp:
    lda     ,x+
    cmpa    ,y+
    bne     sfx_diff
    decb
    bne     sfx_cmp
    puls    y
    andcc   #$FE
    puls    d,x,pc
sfx_diff:
    puls    y
sfx_suiv:
    ldy     SY_SUIV,y
    bra     sfx_lp
sfx_non:
    orcc    #1
    puls    d,x,pc

; SymFind - Comme SymFind_X, le symbole en X.
SymFind:
    jsr     SymFind_X
    tfr     y,x
    rts

; SymAdd - Ajoute name_buf, valeur sym_val_tmp, drapeaux A.
; Sortie : C=1 doublon ou table pleine (message affiché).
SymAdd:
    pshs    a
    jsr     SymFind_X
    bcc     sa_dup
    ldx     sym_libre
    ldb     nm_len
    abx
    leax    SY_NOM,x
    cmpx    #SYM_POOL_FIN
    bhi     sa_plein
    ldx     sym_libre
    ldy     sf_seau             ; en tête de son seau
    ldd     ,y
    std     SY_SUIV,x
    stx     ,y
    ldd     sym_val_tmp
    std     SY_VAL,x
    puls    a
    sta     SY_FL,x
    ldb     nm_len
    stb     SY_LEN,x
    leax    SY_NOM,x
    ldy     #name_buf
sa_cp:
    lda     ,y+
    sta     ,x+
    decb
    bne     sa_cp
    stx     sym_libre
    ldd     sym_nb
    addd    #1
    std     sym_nb
    andcc   #$FE
    rts
sa_dup:
    leas    1,s
    ldx     #EMsgSymDup
    jmp     ErrShow
sa_plein:
    leas    1,s
    ldx     #EMsgSymFull
    jmp     ErrShow

; ===================================================================
; Erreurs
; ===================================================================
ErrOper:
    ldx     #EMsgOper
    bra     ErrShow
ErrExpr:
    ldx     #EMsgExpr
    bra     ErrShow
ErrNoLabel:
    ldx     #EMsgNoLabel
    bra     ErrShow
ErrString:
    ldx     #EMsgStr
    bra     ErrShow
ErrNomLong:
    ldx     #EMsgNomLong
    bra     ErrShow
ErrPhase:
    ldx     #EMsgPhase
    bra     ErrShow
ErrAvant:
    ldx     #EMsgAvant
    bra     ErrShow
ErrOrgArr:
    ldx     #EMsgOrgArr

; ErrShow - « ASM: NOM ligne n : message », puis la ligne. C=1.
; Entrée : X = message.
ErrShow:
    stx     ErrMsgPtr
    lda     #1
    sta     asm_err
    ldx     #EMsgAsm
    jsr     bsc_PrintString
    ldu     ctx
    leax    FC_NOM,u
    jsr     PrintNom
    ldx     #EMsgLine
    jsr     bsc_PrintString
    ldd     FC_LIGNE,u
    jsr     PrintDec
    ldx     ErrMsgPtr
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
    ldx     #line_buf
    jsr     bsc_PrintString
    jsr     bsc_PrintCRLF
    orcc    #1
    rts

; PrintNom - X = nom formaté : ses caractères jusqu'au premier blanc.
PrintNom:
    ldb     #15
pn_lp:
    lda     ,x+
    cmpa    #' '
    bls     pn_fin
    jsr     bsc_PrintChar
    decb
    bne     pn_lp
pn_fin:
    rts

; PrintDec - D en décimal, sans zéros de tête.
PrintDec:
    pshs    d,x
    ldx     #dec_tab
    clr     dec_nz
pd_lp:
    clr     dec_ch
pd_sub:
    cmpd    ,x
    blo     pd_dig
    subd    ,x
    inc     dec_ch
    bra     pd_sub
pd_dig:
    pshs    d
    lda     dec_ch
    bne     pd_out
    tst     dec_nz
    bne     pd_out
    cmpx    #dec_tab+8          ; le chiffre des unités, toujours
    bne     pd_skip
pd_out:
    sta     dec_nz
    inc     dec_nz
    adda    #'0'
    jsr     bsc_PrintChar
pd_skip:
    puls    d
    leax    2,x
    cmpx    #dec_tab+10
    bne     pd_lp
    puls    d,x,pc
dec_tab:
    fdb     10000,1000,100,10,1

; ===================================================================
; Messages
; ===================================================================
MsgUsage:       fcn "Usage: ASM <source> <sortie> [origine hexa]"
MsgNotFound:    fcn "Fichier source introuvable."
MsgSave:        fcn "Erreur ecriture fichier sortie."
MsgFail:        fcn "Assemblage echoue."
MsgInternal:    fcn "Erreur interne (tailles passe 1/2 differentes)."
MsgNothing:     fcn "Aucune donnee a produire."
MsgPasse1:      fcn "Passe 1..."
MsgEspDollar:   fcn "  $"
MsgPasse3:      fcn "Passe 3 (EQU en avant)..."
MsgOctets:      fcn " octets, "
MsgSymboles:    fcn " symboles"
MsgPasse2:      fcn "Passe 2..."
MsgDone:        fcn "ASM OK : $"
MsgOctetsPage:  fcn " octets, page "
MsgVirgDollar:  fcn ", $"

EMsgAsm:        fcn "ASM: "
EMsgLine:       fcn " ligne "
EMsgOper:       fcn " : operande manquant."
EMsgExpr:       fcn " : expression invalide."
EMsgNoLabel:    fcn " : etiquette manquante (EQU)."
EMsgSym:        fcn " : symbole non defini."
EMsgSymDup:     fcn " : symbole duplique."
EMsgSymFull:    fcn " : table des symboles pleine."
EMsgStr:        fcn " : chaine non terminee."
EMsgDiv0:       fcn " : division par zero."
EMsgOvf:        fcn " : valeur trop grande."
EMsgMnem:       fcn " : mnemonique inconnu."
EMsgOperand:    fcn " : operande invalide."
EMsgRange:      fcn " : valeur hors limites."
EMsgNomLong:    fcn " : nom de plus de 31 caracteres."
EMsgPhase:      fcn " : erreur de phase (passe 2 /= passe 1)."
EMsgAvant:      fcn " : symbole defini plus loin (interdit ici)."
EMsgOrgArr:     fcn " : ORG en arriere."
EMsgNiveaux:    fcn " : plus de 4 INCLUDE imbriques."
EMsgInclude:    fcn " : fichier INCLUDE introuvable."
EMsgFich64:     fcn " : fichier de plus de 64 Ko."
EMsgLecture:    fcn " : erreur de lecture SD."
EMsgTropGros:   fcn " : binaire de plus de 32 Ko."
EMsgError:      fcn " : directive ERROR."

str_equ:        fcn "EQU"
str_org:        fcn "ORG"
str_rmb:        fcn "RMB"
str_fcb:        fcn "FCB"
str_fdb:        fcn "FDB"
str_fcc:        fcn "FCC"
str_fcn:        fcn "FCN"
str_end:        fcn "END"
str_include:    fcn "INCLUDE"
str_vision:     fcc "VISION.ASM     "
str_section:    fcn "SECTION"
str_export:     fcn "EXPORT"
str_endc:       fcn "ENDC"
str_endif:      fcn "ENDIF"
str_else:       fcn "ELSE"
str_error:      fcn "ERROR"
str_ifdef:      fcn "IFDEF"
str_ifndef:     fcn "IFNDEF"
str_if:         fcn "IF"
str_ifne:       fcn "IFNE"
str_ifeq:       fcn "IFEQ"
str_ifgt:       fcn "IFGT"
str_ifge:       fcn "IFGE"
str_iflt:       fcn "IFLT"
str_ifle:       fcn "IFLE"


; ===================================================================
; Table des opcodes 6809 / 6309 (données)
; ===================================================================
    include "opcodes.inc"
NB_INSTR    EQU (instr_end-instr_table)/INST_LEN

; ===================================================================
; Thunks BIOS (bsc_*) - placés EN FIN pour que Start reste à $0000.
; ===================================================================
    include "bioslib.asm"

; ===================================================================
; Variables (dans le binaire : petites) ; les grandes zones sont après
; fin_prog (voir ctx_zone).
; ===================================================================
Origine0    RMB 2       ; origine donnée en argument
Origine     RMB 2       ; adresse du premier octet du binaire
LC          RMB 2
HautEau     RMB 2       ; taille du binaire
Pass1Size   RMB 2
OutPtr      RMB 2       ; prochain octet du binaire, en page 2
OutLocalIdx RMB 2       ; remplissage de OutLocalBuf
OutLocalBuf RMB 256
pass_no     RMB 1
end_flag    RMB 1
asm_err     RMB 1
ErrMsgPtr   RMB 2
trop_gros   RMB 1
err_lecture RMB 1
org_libre   RMB 1       ; 1 tant qu'aucun octet n'est émis (ORG = origine)
saut        RMB 1       ; > 0 : dans un bloc IF faux (profondeur)
niv         RMB 1       ; fichiers ouverts
ctx         RMB 2       ; contexte du fichier courant
ll_mode     RMB 1
lc_tmp      RMB 2
lh_val      RMB 2
sv_page     RMB 1
est_app     RMB 1       ; 1 : le source inclut VISION.ASM (application)
sv_attr     RMB 1
fc_nul      RMB 1
fi_buf      RMB 14      ; FS_FileInfo
inc_sauve   RMB 2       ; dossier courant pendant un INCLUDE
inc_nom     RMB 2       ; le nom seul, après le dernier '/'
NomSource   RMB 16
NomSortie   RMB 16
NomInclude  RMB 16

; --- Descripteur de ligne ---
ld_type     RMB 1
ld_label    RMB 2
ld_labelLen RMB 1
ld_mnem     RMB 2
ld_mnemLen  RMB 1
ld_oper     RMB 2

mnem_buf    RMB 8
name_buf    RMB 32
nm_len      RMB 1
nm_hash     RMB 1

; --- Évaluateur ---
madd_base   RMB 1
madd_digit  RMB 1
mul_tmp     RMB 3
sym_val_tmp RMB 2
md_tmp      RMB 2
as_tmp      RMB 2
ev_rel      RMB 1
mu_a        RMB 2
mu_b        RMB 2
mu_r        RMB 2
dv_q        RMB 2
dv_r        RMB 2
dv_d        RMB 2
dv_n        RMB 1
dec_ch      RMB 1
dec_nz      RMB 1

; --- Parseur d'instructions ---
pi_tmp      RMB 2
pi_tmp2     RMB 2
pcr_base    RMB 2
idx_ind     RMB 1
idx_mode    RMB 1
idx_acc     RMB 1
idx_reg     RMB 1
idx_sym     RMB 1
idx_lit0    RMB 1
pp_mask     RMB 1
pp_idx      RMB 1
pb_tmp      RMB 1
regbuf      RMB 4
pr_fin      RMB 2
chm_fin     RMB 2
inst_ptr    RMB 2
inst_flags  RMB 1
inst_mode   RMB 1
inst_pfx    RMB 1
inst_op     RMB 1
inst_extra  RMB 3
inst_xlen   RMB 1
inst_size   RMB 1
expr_flag   RMB 1
no_undef    RMB 1

; --- Table des symboles ---
sym_libre   RMB 2
sym_nb      RMB 2
sf_seau     RMB 2
nb_prov     RMB 2       ; EQU provisoires (passe 1)
prov_change RMB 1       ; une valeur provisoire a changé (passe 3)
prov_chaine RMB 1       ; un provisoire dépend d'un autre provisoire
p3_tours    RMB 1

fin_prog:

    end
