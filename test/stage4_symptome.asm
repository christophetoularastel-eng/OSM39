; ===================================================================
; test/stage4_symptome.asm - ETAPE 4 : LE SYMPTOME D'ORIGINE
; -------------------------------------------------------------------
; Etape 3, puis attente, puis ecran_noir.
;
; C'est la reproduction du symptome du premier essai : "rien ne
; s'affiche, ecran noir + curseur". Un splash correct (sans le
; `lda #$0C` final) ne fait PAS ca.
;
; Si CETTE etape laisse un ecran noir, alors le symptome vient bien
; d'un effacement posterieur au dessin, et le correctif a porter dans
; bios/splash.asm est bien de retirer cet effacement de la fin de la
; routine (l'appelant, main.asm, decidera). Diagnostic confirme.
;
; Si cette etape LAISSE le splash a l'ecran, mon diagnostic est faux :
; l'effacement n'est pas la cause et il faut chercher ailleurs.
;
; L'attente est un compte de cycles (ATT_TOURS dans common.inc), pas
; une vraie temporisation : sa duree reelle depend de la frequence E,
; inconnue dans ce depot. Reglez-la a l'oeil, ~2 secondes suffit.
;
; `start` doit rester la premiere chose de .code : voir stage3.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     splash_clear
        ldx     #splash_data
        jsr     splash_draw
        jsr     attente
        jsr     ecran_noir
        jmp     fini               ; jmp 16 bits : avec la table, l'ecart
                                    ; a `fini` depasse les 127 d'un bra

        include "common.inc"
        include "splash.asm"
        include "splash_ecran.inc"

        end
