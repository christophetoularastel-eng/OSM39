; minitel_data.inc - GÉNÉRÉ par tools/minitel/videotex.py --inc : NE PAS ÉDITER
MOS_CONT        equ $4F         ; glyphe contigu n (1..7) = MOS_CONT+n (page 1)
MOS_DISJ        equ $56         ; glyphe disjoint n (1..7) = MOS_DISJ+n
; couleur Minitel (0..7) -> couleur OSM39
Tab_Coul        fcb $00,$04,$02,$06,$01,$05,$03,$07
; SS2 + diacritique + lettre : diacritique, lettre, code CP437 ; 0 final
Tab_Combi
        fcb $41,$61,$85
        fcb $41,$65,$8A
        fcb $41,$69,$8D
        fcb $41,$6F,$95
        fcb $41,$75,$97
        fcb $42,$45,$90
        fcb $42,$61,$A0
        fcb $42,$65,$82
        fcb $42,$69,$A1
        fcb $42,$6F,$A2
        fcb $42,$75,$A3
        fcb $43,$61,$83
        fcb $43,$65,$88
        fcb $43,$69,$8C
        fcb $43,$6F,$93
        fcb $43,$75,$96
        fcb $48,$41,$8E
        fcb $48,$4F,$99
        fcb $48,$55,$9A
        fcb $48,$61,$84
        fcb $48,$65,$89
        fcb $48,$69,$8B
        fcb $48,$6F,$94
        fcb $48,$75,$81
        fcb $4B,$43,$80
        fcb $4B,$63,$87
        fcb 0
; SS2 + symbole : code G2, code CP437 ; 0 final
Tab_Speciaux
        fcb $23,$9C
        fcb $24,$24
        fcb $26,$23
        fcb $27,$15
        fcb $2C,$1B
        fcb $2D,$18
        fcb $2E,$1A
        fcb $2F,$19
        fcb $30,$F8
        fcb $31,$F1
        fcb $38,$F6
        fcb $3C,$AC
        fcb $3D,$AB
        fcb $3E,$AC
        fcb $6A,$4F
        fcb $7A,$6F
        fcb $7B,$E1
        fcb 0
; mosaïque (valeur 0-63) -> glyphe de la page 1, fenêtre 40 colonnes
Tab_Mos40
        fcb $00,$5E,$5F,$50,$60,$61,$62,$63
        fcb $64,$65,$66,$67,$51,$68,$69,$52
        fcb $6A,$6B,$6C,$6D,$6E,$6F,$70,$71
        fcb $72,$73,$74,$75,$76,$77,$78,$79
        fcb $7A,$7B,$7C,$7D,$7E,$7F,$4F,$07
        fcb $08,$09,$0A,$0B,$0C,$0D,$0E,$0F
        fcb $53,$10,$11,$54,$12,$13,$14,$15
        fcb $16,$17,$18,$19,$55,$1A,$1B,$56
; G0 : caractères remplacés (code, CP437) ; 0 final
Tab_G0
        fcb $60,$C4
        fcb $7E,$C4
        fcb 0
