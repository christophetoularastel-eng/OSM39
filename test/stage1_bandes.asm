; ===================================================================
; test/stage1_bandes.asm - ETAPE 1 : le test de reference
; -------------------------------------------------------------------
; Toute la fenetre video est remplie : 'W' partout, attribut qui
; progresse de 1 tous les 16 caracteres (bandes verticales).
;
; Ce que cela prouve, d'un coup :
;   - l'ecriture directe dans $8000-$8FFF (caracteres) et
;     $9000-$9FFF (couleurs) fonctionne : contention de bus avec le
;     68B45, ou decodage d'adresse a12 (U126, carte V4) faux, et cela
;     se voit ;
;   - l'image revient seule au 68B45 apres les ecritures : depuis la
;     V4 il n'y a plus de mode affichage ($10) a ecrire dans $A120 ;
;   - les attributs couleur sont ecrits au bon offset (+ $1000).
;
; Si l'ecran est couvert de 'W' colores, tout le mecanisme video
; fonctionne et le probleme ne peut plus etre la : il reste a tester
; que le rendu (etapes 2 et 3).
;
; CE QU'IL FAUT VOIR SUR LA CARTE, et rien d'autre :
;   - la fenetre entierement couverte de 'W'. Pas UN SEUL glyphe
;     autre. Le 30 septembre 2026 elle affichait « W@W@W@W repete en
;     8 couleurs » : le second glyphe est le caractere $00, leake
;     parce que `std` ecrit A puis B et qu'un `ldb #'W'` seul laissait
;     A a $00. Corrige depuis (voir common.inc et l'invariant 3 bis
;     de verifie_remplissage.py, qui controle les VALEURS ecrites et
;     pas seulement quels offsets le sont). Si un glyphe revient
;     Melange, c'est que cette correction a ete reprise par derriere.
;   - huit teintes differentes, et RIEN qui clignote, et aucune bande
;     qui s'inverse d'une trame a l'autre. C'est la premiere preuve
;     positive de la carte du 29 septembre : D0-D2 = premier plan,
;     D4-D6 = fond, donc `anda #$0F` doit laisser le fond a 0 et ne
;     faire tourner que la couleur du caractere. Un clignotement
;     prouverait un cablage resté ancien (D4 = blink, D5 = inversion).
;
; `start` doit rester la premiere chose de .code : voir stage3.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     splash_bandes
        jmp     fini

        include "common.inc"

        end
