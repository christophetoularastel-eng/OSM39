; ===================================================================
; ASCII.ASM - Inc_Ascii : incrémenter un entier ASCII avec retenue
; ===================================================================
; Source unique de l'incrementation d'entier ecrit en ASCII en
; memoire (score, lignes, compteurs de panneau). Code : a
; inclure DANS le .code, APRES le point d'entree (regle offset 0,
; cf. lib/snd.asm) :
;       include "../lib/ascii.asm"
;
; Entree : X = adresse du CHIFFRE DE DROITE (unites) d'une chaine
;          ASCII du type "000000"
; Sortie : la chaine est passee de +1 (ou +10... selon le chiffre ou
;          on pointe), retenue propagate vers la gauche jusqu'a un
;          chiffre qui n'est pas '9'. X avance vers la gauche en meme
;          temps que la retenue (donc n'est PAS preserve).
; Detruit : A.
;
; Exemple (briques, +10 au score : on pointe les dizaines) :
;       LDX  #ValScore+4
;       JSR  Inc_Ascii
;
; Le Makefile de l'application doit lister ce fichier en dependance
; de l'objet, sinon une modification ne declenche pas le
; reassemblage.
; ===================================================================

Inc_Ascii:
    LDA     ,X
    INCA
    CMPA    #$3A                ; A-t-on dépassé '9' ?
    BNE     IA_End
    LDA     #$30                ; Retombe à '0'
    STA     ,X
    LEAX    -1,X                ; Applique la retenue sur le chiffre de gauche
    BRA     Inc_Ascii
IA_End:
    STA     ,X
    RTS
