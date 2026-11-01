; ===================================================================
; SIZE.ASM — Affiche la taille d'un fichier
; Usage: SIZE <filename>
; Charge: page 1, $0000
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    ; --- Vérifier argc >= 2 ---
    LDA     argc
    CMPA    #2
    BLO     PrintUsage

    ; --- Formater le nom du fichier (argv[1]) ---
    LDX     >argv+2
    LDY     #FormattedName
    JSR     [table_function_ram+sys_Format_Filename_83]

    ; --- Chercher l'entrée ---
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     FileNotFound

    ; U = taille du fichier
    TFR     U,D
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     [table_function_ram+sys_PrintCRLF]
    RTS

FileNotFound:
    LDX     #MsgNotFound
    JSR     [table_function_ram+sys_PrintString]
    RTS

PrintUsage:
    LDX     #MsgUsage
    JSR     [table_function_ram+sys_PrintString]
    RTS

; --- Données ---
MsgUsage:       FCN "Usage: SIZE <filename>"
                FCB $0a,$0D,0
MsgNotFound:    FCN "Fichier non trouve."
                FCB $0a,$0D,0
