; ===================================================================
; banc_bios_sd.asm - Banc d'essai du VRAI pilote bios/SD.asm en RAM
; ===================================================================
; tools/tele/essai_bios_sd.py relie ce banc, bios/SD.o et les adresses
; de la RAM du BIOS (variables du pilote), à $1000 en page 1, et le
; pilote par TELE avant de flasher l'EPROM.
;   Banc_Lectures : D (= A x 256 + B) lectures du secteur BlockAddr ; chacune
;                   est comparée à Reference (512 octets). Rend D =
;                   erreurs (code <> 0 ou contenu différent), Trames =
;                   trames écoulées, Dernier = dernier code d'erreur.
; ===================================================================
    include "../../bios/hardware.inc"

    import  SD_ReadBlock, SD_BUFFER

    export  Banc_Lectures, Reference, Trames, Dernier

    section .code

Banc_Lectures:
    STD     Reste
    LDD     #0
    STD     Erreurs
    STA     Dernier
    LDD     vsync_tick
    STD     Trames
BL_Tour:
    LDD     Reste
    BEQ     BL_Fin
    SUBD    #1
    STD     Reste
    JSR     SD_ReadBlock
    TSTA
    BNE     BL_Err
    LDX     #SD_BUFFER
    LDY     #Reference
    LDW     #512
BL_Cmp:
    LDA     ,X+
    CMPA    ,Y+
    BNE     BL_Diff
    DECW
    BNE     BL_Cmp
    BRA     BL_Tour
BL_Diff:
    LDA     #$DD
BL_Err:
    STA     Dernier
    LDD     Erreurs
    ADDD    #1
    STD     Erreurs
    BRA     BL_Tour
BL_Fin:
    LDD     vsync_tick
    SUBD    Trames
    STD     Trames
    LDD     Erreurs
    RTS

Reste           rmb 2
Erreurs         rmb 2
Trames          rmb 2
Dernier         rmb 1
Reference       rmb 512
