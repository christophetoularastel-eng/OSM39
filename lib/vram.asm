; ===================================================================
; VRAM.ASM - Calc_Addr : adresse VRAM d'une cellule (colonne, ligne)
; ===================================================================
; Source unique du calcul d'adresse VRAM general, partagee par
; OSM-VISION et les futures applications. Code : a inclure DANS le
; .code, APRES le point d'entree (regle offset 0, cf. lib/snd.asm) :
;       include "../lib/vram.asm"
;
; Entree : A = colonne (0..79), B = ligne
; Sortie : Y = VRAM_BASE + B*80 + A (plan caracteres)
; Detruit : D. V4 : la couleur de la meme cellule est en
; VRAM_COL_OFS,Y ($9000-$9FFF).
;
; Variante geometrie fixe : pour un bloc de lignes toujours aux memes
; coordonnees (plaque de jeu, panneau), une table d'adresses de ligne
; evite le MUL a chaque cellule -- voir lib/rowaddr.inc, dont les FDB
; dependent de BOARD_X/BOARD_Y definis par l'application.
; BRIQUES a une cousine Fr_Row qui rend en U a partir de variables
; d'application (FrRow0/FrCol) : games/briques.asm.
; ===================================================================

; A = colonne, B = ligne  ->  Y = VRAM_BASE + B*80 + A   (détruit D)
Calc_Addr:
    PSHS    A
    LDA     #80
    MUL
    ADDB    ,S+
    ADCA    #0
    ADDD    #VRAM_BASE
    TFR     D,Y
    RTS
