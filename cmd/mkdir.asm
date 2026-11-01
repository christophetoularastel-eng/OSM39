; ===================================================================
; MKDIR.ASM — Crée un dossier
; Usage: MKDIR <nom>    (MKDIR JEUX, MKDIR /APPS/JEUX)
; Charge: page 1, $0000
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    LDA     argc
    CMPA    #2
    BLO     Usage
    LDX     >argv+2
    LDY     #FormattedName
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_MkDir]
    BCS     Echec
    RTS
Usage:
    LDX     #MsgUsage
    JMP     [table_function_ram+sys_PrintString]
Echec:
    LDX     #MsgEchec
    JMP     [table_function_ram+sys_PrintString]

MsgUsage:   FCC "Usage: MKDIR <nom>"
            FCB $0a,$0D,0
MsgEchec:   FCC "Impossible : ce nom existe deja, ou le chemin est introuvable."
            FCB $0a,$0D,0
