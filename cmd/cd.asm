; ===================================================================
; CD.ASM — Change de dossier courant
; Usage: CD <dossier>   (CD APPS, CD .., CD /, CD /APPS/JEUX)
; Charge: page 1, $0000. Le dossier courant est celui du BIOS
; (fs_dossier) : le shell, OSM-VISION et tous les programmes le partagent.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    LDA     argc
    CMPA    #2
    BLO     Usage
    LDX     >argv+2
    JSR     [table_function_ram+sys_FS_ChDir]
    BCS     Absent
    RTS
Usage:
    LDX     #MsgUsage
    JMP     [table_function_ram+sys_PrintString]
Absent:
    LDX     #MsgAbsent
    JMP     [table_function_ram+sys_PrintString]

MsgUsage:   FCC "Usage: CD <dossier>  (CD .. : parent, CD / : racine)"
            FCB $0a,$0D,0
MsgAbsent:  FCC "Dossier introuvable."
            FCB $0a,$0D,0
