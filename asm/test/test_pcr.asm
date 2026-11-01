        ORG     $1000
p1:     lda     3,pcr
        lda     $100,pcr
        ldx     msg,pcr
        rts
msg:    fcc     "HELLO"
        end
