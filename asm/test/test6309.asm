; test6309.asm - ASM contre lwasm en mode objet (test/verifie_asm.py) :
; instructions HD6309, règles de taille, syntaxe lwasm.
;   lwasm --format=obj --6309 test6309.asm + lwlink --format=raw
K5      equ     5
KZ      equ     0
KB      equ     $40
K300    equ     300
Un_nom_de_symbole_long_de_31_c  equ  K5*3+(K300/10)-2
* commentaire en colonne 1
        section .code
debut:
        lde     #$12
        ldf     #-1
        lde     K5,x
        ldf     ,y+
        ste     $1234
        stf     [KB,u]
        adde    #1
        addf    debut,pcr
        sube    <KB
        subf    $C000
        cmpe    #'A'
        cmpf    #' '            un commentaire sans point-virgule
        ldw     #(K5*256)+KZ
        ldw     debut
        stw     ,--s
        addw    #K300
        subw    K300,y
        cmpw    #$FFFF
        sbcd    #1
        sbca    #0                      ; SBCA/SBCB manquaient (DONJON39)
        sbcb    #$12
        sbca    <$40
        sbcb    $1234
        sbca    ,x
        sbcb    5,y
        andd    #$0FF0
        bitd    ,x
        eord    #KB
        adcd    2,x
        ord     $4000
        ldq     ,x
        stq     $2000
        divd    #7
        divq    #K300
        muld    #3
        ldmd    #1
        bitmd   #$80
        negd
        comd
        lsrd
        rord
        asrd
        asld
        lsld
        rold
        decd
        incd
        tstd
        clrd
        comw
        lsrw
        rorw
        rolw
        decw
        incw
        tstw
        clrw
        come
        dece
        ince
        tste
        clre
        comf
        decf
        incf
        tstf
        clrf
        pshsw
        pulsw
        pshuw
        puluw
        sexw
        addr    a,b
        adcr    d,x
        subr    w,y
        sbcr    e,f
        andr    a,cc
        orr     b,dp
        eorr    x,u
        cmpr    w,d
        tfr     w,x
        tfr     e,a
        exg     f,b
        tfm     x+,y+
        tfm     u-,s-
        tfm     d+,x
        tfm     y,u+
; --- tailles (règles de lwasm en mode objet) ---
        lda     0,x
        lda     KZ,x
        lda     $0,x
        lda     1-1,x
        lda     K5,x
        lda     -16,y
        lda     -17,y
        lda     127,u
        lda     128,u
        lda     [0,x]
        lda     [KZ,x]
        lda     [K5,x]
        lda     debut,x
        lda     plus_loin,x
        lda     KF,x
        lda     fin-debut,x
        lda     $40
        lda     KB
        lda     <KB
        lda     >KB
        leax    debut,pcr
        leax    plus_loin,pcr
        ldy     debut,pcr
        ldy     plus_loin,pcr
        lda     a,x
        ldb     [d,y]
        ldx     [$C000]
        jsr     [Un_nom_de_symbole_long_de_31_c,x]
        ldd     #Un_nom_de_symbole_long_de_31_c
        ldx     #fin-debut
        ldx     #*
        lbra    plus_loin
        bra     debut2
Sans_deux_points nop
debut2  rts
fin:
        fcb     1,-1,'a,KB+1
        fdb     debut,plus_loin-fin,$1234
        fcc     "chaine ; avec point-virgule et blancs"
        fcn     /deli,miteur/
        rmb     3
        fcb     $AA
plus_loin:
        rts
; --- assemblage conditionnel ---
        IFNE    K5-5
        fcb     $EE             ; sauté
        ELSE
        fcb     $11
        ENDC
        IFGT    K5
        fcb     $22
        IFEQ    KZ
        fcb     $33
        ELSE
        fcb     $EE
        ENDC
        ELSE
        fcb     $EE
        IFNE    1
        fcb     $EE             ; IF imbriqué dans un bloc sauté
        ENDC
        ENDC
        IFDEF   KB
        fcb     $44
        ENDC
        IFNDEF  KF
        fcb     $55             ; KF est défini plus loin : pas encore
        ENDC
        IFLT    -1
        fcb     $66
        ENDC
        IFLE    K5
        error   "jamais"
        ENDC
Tard    equ     Encore_plus_loin+1      ; EQU d'un symbole défini plus loin
        fcb     Tard
Chaine1 equ     Chaine2*2               ; provisoire qui dépend d'un provisoire
Chaine2 equ     Encore_plus_loin+Chaine3
        fdb     Chaine1,Chaine2
Encore_plus_loin equ 7
Chaine3 equ     $100
KF      equ     7
