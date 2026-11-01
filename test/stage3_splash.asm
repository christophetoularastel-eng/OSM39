; ===================================================================
; test/stage3_splash.asm - ETAPE 3 : LE SPLASH COMPLET
; -------------------------------------------------------------------
; C'est l'etape qui compte. Elle rend le vrai contenu du splash de
; demarrage, via le meme algorithme que bios/splash.asm, et laisse
; l'image a l'ecran.
;
; L'IMAGE DOIT RESTER. C'est tout le but de l'etape.
;
; Comparee a l'etape 2, la seule difference est la table : si 2
; marche et 3 non, le rendu est bon et c'est le contenu qu'il faut
; revoir. Comparee a bios/splash.asm, la seule difference est
; l'absence d'appel a video_wait_vsync et l'absence du
; `lda #$0C / jsr PUTCHARV` de la fin - deux choses impossibles a
; faire ici sans dependre du plan memoire de l'EPROM installee
; (voir common.inc). L'etape 4 traite l'effacement.
;
; -------------------------------------------------------------------
; ATTENTION A L'ORDRE DES INCLUDE
;
; `start` DOIT etre la premiere chose de la section .code, parce que
; le moniteur fait `JSR $0000` (run_cmd fait JSR ,X avec X=0). Les
; includes viennent APRES : si common.inc precede start, c'est
; splash_clear qui se retrouve a $0000, le banc demarre au milieu d'une
; routine, et `RUN 0000` n'execute pas le test. C'est exactement le
; symptome "rien ne se passe" du premier essai, reproduit par une
; faute de placement. Le Makefile verifie que start est bien a 0000.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     splash_clear
        ldx     #splash_data
        jsr     splash_draw
        jmp     fini               ; jmp 16 bits : avec la table, l'ecart
                                    ; a `fini` depasse les 127 d'un bra

        include "common.inc"
        include "splash.asm"
        include "splash_ecran.inc"

        end
