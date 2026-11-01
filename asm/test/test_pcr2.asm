        ORG     $2000
p1:     ldx     back,pcr
        nop
back:   rts
        ldx     $2010,pcr
        ldx     $3000,pcr
        end
