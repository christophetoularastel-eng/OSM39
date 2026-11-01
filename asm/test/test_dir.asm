        ORG     $2000
val:    fdb     $1234
        lda     $7F
        lda     $80
        lda     $FF
        lda     $100
        lda     val
        lda     <val
        lda     >val
        lda     #-1
        ldb     #-128
        sta     val
        ldd     val
        end
