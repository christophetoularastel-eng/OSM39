; test1.asm - Exercice complet du jeu d'instructions 6809
; Assemble avec lwasm de reference : lwasm --6809 --format=raw test1.asm
        ORG     $0100
start:
        nop
        orcc    #$50
        andcc   #$EF
        pshs    a,b,x,y
        puls    a,b,x,y
        pshu    cc,dp,s
        pulu    pc
        tfr     x,y
        exg     d,x
        lda     #$42
        ldb     #42
        ldd     #$1234
        ldx     #$5678
        ldy     #$9ABC
        ldu     #$1234
        lds     #$5678
        lda     <$7F
        lda     >$C000
        lda     $C000
        sta     $C000
        ldd     $C000
        std     $C000
        ldx     $1234
        ldy     $1234
        ldu     $1234
        lds     $1234
        cmpa    #$10
        cmpb    #$20
        cmpd    #$1234
        cmpx    #$1234
        cmpy    #$1234
        cmpu    #$1234
        cmps    #$1234
        addd    #$0001
        subd    #$0001
        lda     ,x
        lda     0,x
        lda     1,y
        lda     -1,u
        lda     15,s
        lda     -16,x
        lda     ,x+
        lda     ,x++
        lda     ,-x
        lda     ,--x
        lda     a,x
        lda     b,y
        lda     d,u
        lda     5,x
        lda     -100,x
        lda     $1234,x
        lda     [,x]
        lda     [,x++]
        lda     [,--x]
        lda     [a,x]
        lda     [b,x]
        lda     [d,x]
        lda     [5,x]
        lda     [$1234,x]
        leax    10,x
        leay    ,y
        leau    -8,s
        leas    ,s
        jmp     $C000
        jmp     ,x
        jmp     [$F000]
        jsr     $C000
        jsr     ,y
        jsr     [$1234]
loop1:
        bra     loop1
        brn     loop1
        bne     loop1
        beq     loop1
        bcc     loop1
        bcs     loop1
        bhi     loop1
        bls     loop1
        bge     loop1
        blt     loop1
        bgt     loop1
        ble     loop1
        lbcs    loop1
        lbeq    loop1
        lbne    loop1
        lbra    loop1
        lbsr    sub1
        lbra    far
        lbeq    far
        clr     $C000
        clra
        clrb
        inc     $C000
        dec     $C000
        neg     $C000
        com     $C000
        asl     $C000
        asr     $C000
        lsr     $C000
        rol     $C000
        ror     $C000
        tst     $C000
        asla
        aslb
        lsla
        lslb
        lsra
        lsrb
        rola
        rolb
        rora
        rorb
        nega
        negb
        coma
        comb
        tsta
        tstb
        inca
        incb
        deca
        decb
        daa
        sex
        mul
        abx
        swi
        swi2
        swi3
        sync
        rti
        rts
sub1:
        rts
far:
        end
