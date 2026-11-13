; ===================================================================
; VRAM.ASM - Calc_Addr : adresse VRAM d'une cellule (colonne, ligne)
; ===================================================================
; Source unique du calcul d'adresse VRAM general, partagee par
; OSM-VISION et les futures applications. Code : a inclure DANS le
; .code, APRES le point d'entree (regle offset 0, cf. lib/snd.asm) :
;       include "../lib/vram.asm"
;
; Entree : A = colonne (0..79), B = ligne
; Sortie : Y = adresse du caractere de la cellule (v4 : VRAM_BASE + B*80
; + A ; mono : VRAM_BASE + B*160 + A*2)
; Detruit : D. La couleur de la meme cellule est en VRAM_COL_OFS,Y
; (v4 : 4 Ko plus haut ; mono : l'octet suivant).
;
; Variante geometrie fixe : pour un bloc de lignes toujours aux memes
; coordonnees (plaque de jeu, panneau), une table d'adresses de ligne
; evite le MUL a chaque cellule -- voir lib/rowaddr.inc, dont les FDB
; dependent de BOARD_X/BOARD_Y definis par l'application.
; BRIQUES a une cousine Fr_Row qui rend en U a partir de variables
; d'application (FrRow0/FrCol) : games/briques.asm.
; ===================================================================

; A = colonne, B = ligne  ->  Y = VRAM_BASE + B*80 + A   (détruit D)
; Carte mono (VRAM entrelacée) : Y = VRAM_BASE + B*160 + A*2.
Calc_Addr:
    PSHS    A
    LDA     #VRAM_LIGNE
    MUL
    IFNE    CARTE_MONO
    ADDB    ,S                          ; mono : la colonne compte double
    ADCA    #0
    ENDC
    ADDB    ,S+
    ADCA    #0
    ADDD    #VRAM_BASE
    TFR     D,Y
    RTS
