        ORG     $1000
        lda     [$1234]
        lda     [,x++]
        lda     [,--x]
        lda     ,x+
        lda     0,x
        lda     -16,x
        lda     -17,x
        lda     16,x
        lda     127,x
        lda     128,x
        lda     -128,x
        lda     -129,x
        ldb     ,s
        ldd     ,y
        end
