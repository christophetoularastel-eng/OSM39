; ===================================================================
; test/stage2_rendu.asm - ETAPE 2 : le rendu, isole
; -------------------------------------------------------------------
; splash_clear puis splash_draw sur une table de DEUX LIGNES.
;
; Ce que cela prouve : le calcul d'adresse de splash_draw
; (ligne x 80 + colonne, offset $8000) est correct, et le type de
; caractere est bien ecrit.
;
; L'etape 3 fait la meme chose avec la vraie table de 26 segments.
; Si l'etape 2 marche et pas la 3, le probleme est dans le contenu de
; la table, pas dans le rendu.
;
; La table porte le nom `table_rendu`, et non `splash_data` : splash.asm
; declare deja le splash de reference sous ce nom, et l'etape 2 a la
; sienne. Le nom de la table a rendre est un ARGUMENT de
; verifie_rendu.py (que le Makefile passe), pas une convention ecrite
; en dur dans le verificateur -- donc cette etape est verifiee au meme
; titre que les etapes 3 et 4, automatiquement, avant tout envoi sur la
; ligne serie. Le format (mots de 16 bits) et sa raison sont documentes
; dans splash.asm.
;
; `start` doit rester la premiere chose de .code : voir stage3.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     splash_clear
        ldx     #table_rendu
        jsr     splash_draw
        jmp     fini

        include "common.inc"
        include "splash.asm"

table_rendu:
        fdb  0,0
        fcb  SPL_TITLE
        fcn  "RENDU OK"
        fdb  1,0
        fcb  SPL_SUB
        fcn  "ligne 1"
        fdb  $00FF,$0000
        fcb  $00

        end
