; ===================================================================
; ROWADDR.INC - Table des adresses VRAM du debut de chaque ligne
; ===================================================================
; Table FDB : une entree par ligne, adresse VRAM du DEBUT de la ligne
; (colonne BOARD_X). Lecture typique :
;       LDA  ligne / ASLA / LDX #RowAddr / LDX A,X   (2 octets par entree)
; Le calcul par table evite un MUL par cellule quand la zone est fixe
; (plaque de jeu, panneau).
;
; Cotes exigees de l'application, AVANT l'include :
;   BOARD_X    equ <colonne de depart>
;   BOARD_Y    equ <ligne de depart>
;   VRAM_BASE  (bios/hardware.inc, inclus avant)
; La table contient 20 lignes (0..19) ; au-dela, l'application
; complete elle-meme ou utilise Calc_Addr (lib/vram.asm).
;
; Donnees : a inclure DANS le .code, APRES le point d'entree (regle
; offset 0, cf. lib/snd.asm) :
;       include "../lib/rowaddr.inc"
;
; Le Makefile de l'application doit lister ce fichier en dependance
; de l'objet, sinon une modification ne declenche pas le
; reassemblage.
; ===================================================================

; Adresse VRAM du début (colonne BOARD_X) de chaque ligne du puits
RowAddr:
    FDB     VRAM_BASE+(BOARD_Y+0)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+1)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+2)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+3)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+4)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+5)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+6)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+7)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+8)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+9)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+10)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+11)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+12)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+13)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+14)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+15)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+16)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+17)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+18)*VRAM_LIGNE+BOARD_X*VRAM_PAS
    FDB     VRAM_BASE+(BOARD_Y+19)*VRAM_LIGNE+BOARD_X*VRAM_PAS
