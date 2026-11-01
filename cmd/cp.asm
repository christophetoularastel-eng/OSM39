; ===================================================================
; CP.ASM — Copie un fichier
; Usage: CP <source> <dest>
; Charge: page 1, $0000
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    ; --- Vérifier argc >= 3 ---
    LDA     argc
    CMPA    #3
    BLO     PrintUsage

    ; === 1. Formater le nom source (argv[1]) ===
    ; Pour obtenir argv[1] (La source)
    LDX     >argv+2     ; Charge le pointeur du 2ème argument
    LDY     #FormattedName
    JSR     [table_function_ram+sys_Format_Filename_83]

    ; === 2. Obtenir la taille du fichier source ===
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     SrcNotFound

    ; U = taille
    STU     FileSize

    ldx #FileBuffer
    STX     SourceBuffer

    ; === 4. Charger le fichier source ===
    lda     current_page
    LDX     #FormattedName
    LDY     SourceBuffer
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCS     LoadError

    ; === 5. Formater le nom destination (argv[2]) ===

    ; Pour obtenir argv[2] (La destination)
    LDX     >argv+4     ; Charge le pointeur du 3ème argument
    LDY     #FormattedName
    JSR     [table_function_ram+sys_Format_Filename_83]

    ; === 6. Supprimer la destination si elle existe ===
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_DeleteFile]

    ; === 7. Sauvegarder ===
    lda     current_page
    LDX     #FormattedName
    LDY     SourceBuffer
    LDD     FileSize
    JSR     [table_function_ram+sys_FS_SaveFile]
    BCS     SaveError

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

MemError:
    LDX     #MsgMemError
    JSR     [table_function_ram+sys_PrintString]
    RTS

LoadError:
    LDX     #MsgLoadError
    JSR     [table_function_ram+sys_PrintString]
    RTS

SaveError:
    LDX     #MsgSaveError
    JSR     [table_function_ram+sys_PrintString]
    RTS

; --- Données ---
MsgUsage:       FCN "Usage: CP <source> <dest>"
                FCB $0a,$0D,0
MsgNotFound:    FCN "Fichier source non trouve."
                FCB $0a,$0D,0
MsgMemError:    FCN "Erreur memoire."
                FCB $0a,$0D,0
MsgLoadError:   FCN "Erreur lecture fichier."
                FCB $0a,$0D,0
MsgSaveError:   FCN "Erreur ecriture fichier."
                FCB $0a,$0D,0
MsgSuccess:     FCN "Fichier copie."
                FCB $0a,$0D,0
FileSize:       RMB 2
SourceBuffer:   RMB 2
FileBuffer:
end
