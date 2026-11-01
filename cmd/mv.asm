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
    CMPA    #3
    BLO     PrintUsage

    ; === 1. Formater le nom source (argv[1]) dans OldName ===
    LDX     >argv+2
    LDY     #OldName
    JSR     [table_function_ram+sys_Format_Filename_83]

    ; === 2. Formater le nom destination (argv[2]) dans NewName ===
    LDX     >argv+4
    LDY     #NewName
    JSR     [table_function_ram+sys_Format_Filename_83]

    ; === 3. Renommer le fichier via le système ===
    LDX     #OldName
    LDY     #NewName
    JSR     [table_function_ram+sys_FS_RenameFile]  ; <-- Le NOUVEL APPEL
    BCS     RenameError

    ; --- Succès ---
    LDX     #MsgSuccess
    JSR     [table_function_ram+sys_PrintString]
    RTS

; --- Gestion des erreurs ---
PrintUsage:
    LDX     #MsgUsage
    JSR     [table_function_ram+sys_PrintString]
    RTS

RenameError:
    LDX     #MsgError
    JSR     [table_function_ram+sys_PrintString]
    RTS

; --- Données ---
MsgUsage:       FCN "Usage: MV <source> <dest>"
                FCB $0a,$0D,0
MsgError:       FCN "Erreur: Fichier introuvable ou erreur SD."
                FCB $0a,$0D,0
MsgSuccess:     FCN "Fichier renomme."
                FCB $0a,$0D,0

OldName:        RMB 15
NewName:        RMB 15
end
