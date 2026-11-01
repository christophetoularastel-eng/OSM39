; ===================================================================
; SND.ASM - Declencheur commun du sequenceur 2 voix (Snd_Start)
; ===================================================================
; Source unique du declencheur son, partagee par OSM-VISION, BRIQUES et
; les futures applications. A inclure dans le .code, APRES le point
; d'entree de l'application (sinon le point d'entree n'est plus a
; l'offset 0, cf. la regle de games/Makefile et osmvision/Makefile) :
;
;       include "../lib/snd.inc"      ; notes + SND_PTR/SND_TIMER (apres hardware.inc)
;       ...
;       section .code
;   Mon_App:
;       ...
;       include "../lib/snd.asm"      ; ici : Snd_Start
;
; Appel : X = adresse de la partition (format dans snd.inc).
; Redemarre le sequenceur tout de suite, sans attendre la fin de la
; note en cours (SND_TIMER remis a 0). L'ecriture pointeur + minuteur
; est faite IRQ masquees pour etre atomique vis-a-vis du handler IRQ
; (le sequenceur lit la partition a chaque VSYNC) ; on restitue le CC
; du appelant, donc ni les IRQ ni le reste de l'etat ne changent.
; Ne modifie que la pile (le RTS) et SND_PTR/SND_TIMER.
; ===================================================================

Snd_Start:
    PSHS    CC
    ORCC    #%00010000        ; IRQ masquees : bascule pointeur+minuteur atomique
    CLR     SND_TIMER         ; demarre a la trame suivante
    STX     SND_PTR           ; X = partition
    PULS    CC
    RTS
