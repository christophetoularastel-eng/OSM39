; ===================================================================
; bioslib.asm - Librairie d'accès aux services BIOS pour programmes
;               externes OSM09 (page 1, $0000)
;
; PRINCIPE (thunks) : chaque service BIOS est un stub de 3 octets
;     bsc_X:  jmp [table_function_ram+sys_X]
; Le JMP indirect ne pousse rien ; le RTS final du BIOS retourne donc
; directement chez l'appelant du thunk. Un programme fait simplement
;     jsr  bsc_PrintString      (X = chaîne)
; au lieu de  jsr [table_function_ram+sys_PrintString].
;
; Utilisation :
;     include "bioslib.asm"
; Assemblage hôte (lwasm) :  -I../bios -I../lib
; ===================================================================

    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

   section .code
 
; ===================================================================
; Codes clavier (retournés par bsc_scan_keyboard / bsc_inkey)
; ===================================================================
KB_ESC      equ $1B
KB_CR       equ $0D
KB_LF       equ $0A
KB_BS       equ $08
KB_TAB      equ $09
KB_UP       equ $80
KB_DOWN     equ $81
KB_LEFT     equ $82
KB_RIGHT    equ $83

; ===================================================================
; Attributs de fichiers (bits : 2=r 1=w 0=x 3=hidden)
; ===================================================================
ATTR_READ       equ $04
ATTR_WRITE      equ $02
ATTR_EXEC       equ $01
ATTR_HIDDEN     equ $08

; ===================================================================
; Thunks des 31 services BIOS (offset pair -> 2 octets chacun)
; ===================================================================
bsc_FS_RenameFil:           jmp [table_function_ram+sys_FS_RenameFile]
bsc_scan_keyboard:          jmp [table_function_ram+sys_scan_keyboard]
bsc_read_line:              jmp [table_function_ram+sys_read_line]
bsc_PrintChar:              jmp [table_function_ram+sys_PrintChar]
bsc_PrintString:            jmp [table_function_ram+sys_PrintString]
bsc_PrintHexChar:           jmp [table_function_ram+sys_PrintHexChar]
bsc_PrintHexWord:           jmp [table_function_ram+sys_PrintHexWord]
bsc_PrintCRLF:              jmp [table_function_ram+sys_PrintCRLF]
bsc_PrintFileName83:        jmp [table_function_ram+sys_PrintFileName83]
bsc_FS_Mount:               jmp [table_function_ram+sys_FS_Mount]
bsc_FS_FindFirst:           jmp [table_function_ram+sys_FS_FindFirst]
bsc_FS_FindNext:            jmp [table_function_ram+sys_FS_FindNext]
bsc_FS_GetNextCluster:      jmp [table_function_ram+sys_FS_GetNextCluster]
bsc_FS_LoadFile:            jmp [table_function_ram+sys_FS_LoadFile]
bsc_FS_FindEntry:           jmp [table_function_ram+sys_FS_FindEntry]
bsc_FS_ListRoot:            jmp [table_function_ram+sys_FS_ListRoot]
bsc_FS_SaveFile:            jmp [table_function_ram+sys_FS_SaveFile]
bsc_reg_cmd:                jmp [table_function_ram+sys_reg_cmd]
bsc_FS_ClusterToLBA_Offset: jmp [table_function_ram+sys_FS_ClusterToLBA_Offset]
bsc_Format_Filename_83:     jmp [table_function_ram+sys_Format_Filename_83]
bsc_strcpy:                 jmp [table_function_ram+sys_strcpy]
bsc_strlen:                 jmp [table_function_ram+sys_strlen]
bsc_pager:                  jmp [table_function_ram+sys_pager]
bsc_loadandexec:            jmp [table_function_ram+sys_loadandexec]
bsc_ls:                     jmp [table_function_ram+sys_ls]
bsc_malloc_sys:             jmp [table_function_ram+sys_malloc_sys]
bsc_free:                   jmp [table_function_ram+sys_free]
bsc_FS_DeleteFile:          jmp [table_function_ram+sys_FS_DeleteFile]
bsc_FS_GetAttributes:       jmp [table_function_ram+sys_FS_GetAttributes]
bsc_FS_SetAttributes:       jmp [table_function_ram+sys_FS_SetAttributes]
bsc_FarRead:                jmp [table_function_ram+sys_FarRead]
bsc_FarWrite:               jmp [table_function_ram+sys_FarWrite]
bsc_FS_FileInfo:            jmp [table_function_ram+sys_FS_FileInfo]
bsc_FS_ReadSector:          jmp [table_function_ram+sys_FS_ReadSector]
bsc_FS_SetLoad:             jmp [table_function_ram+sys_FS_SetLoad]
bsc_FS_ChDir:               jmp [table_function_ram+sys_FS_ChDir]
bsc_FS_MkDir:               jmp [table_function_ram+sys_FS_MkDir]
bsc_FS_Dossier:             jmp [table_function_ram+sys_FS_Dossier]
bsc_FS_DirInfo:             jmp [table_function_ram+sys_FS_DirInfo]
