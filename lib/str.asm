; ===================================================================
; STR.ASM - Outils de construction de chaines (Append/Hex8/Dec16)
; ===================================================================
; Source unique des outils texte des applications a fenetres
; (OSM-VISION, futures apps). Code : a inclure DANS le .code, APRES
; le point d'entree (regle offset 0, cf. lib/snd.asm) :
;       include "../lib/str.asm"
;
; Contrat commun : U = pointeur d'ecriture (avance), sortie NUL-free
; (l'appelant range le 0 s'il en a besoin).
;   Append : copie la chaine pointee par X (terminee par 0) a ,U+
;   Hex8   : A -> 2 chiffres hexa majuscules a ,U+
;   Dec16  : D (0..65535) -> decimal a ,U+, sans zeros de tete
;
; Cotes exigees de l'application, AVANT l'include :
;   ASCII_0    equ $30                    (bloc equ de l'appli)
;   NumStarted  rmb 1                     (RAM : zero de tete)
;   DigitCnt    rmb 1                     (RAM : compteur Dec16)
; Voir le bloc equ/rmb de osmvision.asm pour la reference.
;
; Le Makefile de l'application doit lister ce fichier en dependance
; de l'objet, sinon une modification ne declenche pas le
; reassemblage.
; ===================================================================

; ===================================================================
; Outils de construction de chaînes (U = pointeur d'écriture, avance)
; ===================================================================
Append:                         ; copie la chaîne X (sans le 0) à ,U+
    LDA     ,X+
    BEQ     Append_End
    STA     ,U+
    BRA     Append
Append_End:
    RTS

Hex8:                           ; A -> 2 chiffres hexa à ,U+
    PSHS    A
    LSRA
    LSRA
    LSRA
    LSRA
    BSR     Hex_Nibble
    PULS    A
    ANDA    #$0F
Hex_Nibble:
    ADDA    #ASCII_0
    CMPA    #$3A
    BLO     Hex_Put
    ADDA    #7
Hex_Put:
    STA     ,U+
    RTS

Dec16:                          ; D (0..65535) -> décimal à ,U+, sans zéros de tête
    PSHS    X
    LDX     #Pow10Tbl
    CLR     NumStarted
D16_Pow:
    CLR     DigitCnt
D16_Sub:
    SUBD    ,X
    BCS     D16_Under
    INC     DigitCnt
    BRA     D16_Sub
D16_Under:
    ADDD    ,X++
    PSHS    D
    LDA     DigitCnt
    BNE     D16_Emit
    TST     NumStarted
    BEQ     D16_Skip
D16_Emit:
    ADDA    #ASCII_0
    STA     ,U+
    INC     NumStarted
D16_Skip:
    PULS    D
    CMPX    #Pow10End
    BNE     D16_Pow
    TFR     B,A                 ; reste = unités (0..9)
    ADDA    #ASCII_0
    STA     ,U+
    PULS    X
    RTS

Pow10Tbl:       FDB 10000,1000,100,10
Pow10End:
