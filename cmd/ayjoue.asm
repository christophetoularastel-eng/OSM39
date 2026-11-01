; ===================================================================
; AYJOUE.ASM — Joue un morceau sur l'AY-3-8910 (carte SD-KBD-SON)
; Usage: AYJOUE <morceau>        (Entrée sur un .MUS dans OSM-VISION)
; Charge: page 1, $0000
;
; Le morceau (format de tools/ay/ay.py, qui compile les partitions
; texte) est chargé derrière le programme, dans la même page, et joué
; par lib/ay_joue.asm, accroché à l'IRQ du VSYNC. Fin du morceau ou
; Echap : silence, et l'IRQ est rendue au BIOS. Un morceau qui boucle
; joue jusqu'à Echap.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    LDA     argc
    CMPA    #2
    LBLO    Usage
    LDX     >argv+2
    LDY     #Nom
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #Nom
    JSR     [table_function_ram+sys_FS_FindEntry]
    LBCS    Introuvable
    PSHS    U                   ; U = taille ; place : de Tampon à $7FFF
    LDD     #$8000
    SUBD    #Tampon
    CMPD    ,S++
    LBLO    TropGros
    LDA     current_page
    LDX     #Nom
    LDY     #Tampon
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    Illisible
    LDX     #Tampon
    JSR     AyJ_Demarre
    LBCS    PasUnMorceau
    LDX     #MsgJoue            ; « Joue : » puis le titre
    JSR     [table_function_ram+sys_PrintString]
    LDD     Tampon+3
    LDX     #Tampon
    LEAX    D,X
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_PrintCRLF]
    LDX     #MsgEchap
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_PrintCRLF]
Boucle:
    TST     AyJ_Actif
    BEQ     Fin                 ; toutes les voix sont finies
    JSR     [table_function_ram+sys_kbd_poll]
    CMPA    #$1B
    BEQ     Fin
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    BRA     Boucle
Fin:
    JSR     AyJ_Arrete
    RTS

Usage:
    LDX     #MsgUsage
    BRA     Erreur
Introuvable:
    LDX     #MsgIntrouvable
    BRA     Erreur
TropGros:
    LDX     #MsgTropGros
    BRA     Erreur
Illisible:
    LDX     #MsgIllisible
    BRA     Erreur
PasUnMorceau:
    LDX     #MsgPasUnMorceau
Erreur:
    JSR     [table_function_ram+sys_PrintString]
    JMP     [table_function_ram+sys_PrintCRLF]

    include "../lib/ay_joue.asm"

MsgUsage:        FCN "Usage : AYJOUE <morceau>"
MsgIntrouvable:  FCN "Morceau introuvable"
MsgTropGros:     FCN "Morceau trop gros"
MsgIllisible:    FCN "Lecture impossible"
MsgPasUnMorceau: FCN "Pas un morceau AY (tools/ay/ay.py)"
MsgJoue:         FCN "Joue : "
MsgEchap:        FCN "Echap : arret"
Nom              rmb 15
Tampon:
