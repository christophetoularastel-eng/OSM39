; ===================================================================
; MV.ASM — Déplace/renomme un fichier
; Usage: MV <source> <dest>
; Charge: page 1, $0000
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    ; --- Vérifier argc >= 3 ---
    LDA     argc
    CMPA    #2
    BLO     PrintUsage


    ; === 1. Supprimer la source ===
    LDX     >argv+2
    LDY     #FormattedName
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_DeleteFile]
    BCS     SrcNotFound

    LDX     #MsgSuccess
    JSR     [table_function_ram+sys_PrintString]
    RTS

; --- Gestion des erreurs ---
PrintUsage:
    LDX     #MsgUsage
    JSR     [table_function_ram+sys_PrintString]
    RTS

SrcNotFound:
    LDX     #MsgNotFound
    JSR     [table_function_ram+sys_PrintString]
    RTS


; --- Données ---
MsgUsage:       FCN "Usage: RM <source>"
                FCB $0a,$0D,0
MsgNotFound:    FCN "Introuvable (ou dossier non vide)."
                FCB $0a,$0D,0
MsgSuccess:     FCN "Fichier efface."
                FCB $0a,$0D,0
FileSize:       RMB 2
SourceBuffer:   RMB 2

FileBuffer:     RMB 1
