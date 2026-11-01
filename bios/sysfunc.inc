; Auto-generated from bios/ram.map by update_includes.py
; Do not edit manually; rebuild the BIOS to refresh these offsets.
;
; Byte offset of each sys_* slot inside table_function_ram. Call as:
;     JSR [table_function_ram+sys_<name>]
;
; Source of truth: the `rmb 2` slots in bios/ram.asm. Count and order are
; checked against table_function_rom (bios/vectors.asm) at build time.
; The right-hand column is the handler that table_function_rom dispatches
; at that offset, kept visible so a misordering shows up in a diff.

sys_FS_RenameFile:              equ     0  ; FS_RenameFile
sys_scan_keyboard:              equ     2  ; scan_keyboard
sys_read_line:                  equ     4  ; read_line
sys_PrintChar:                  equ     6  ; PrintChar
sys_PrintString:                equ     8  ; PrintString
sys_PrintHexChar:               equ    10  ; PrintHexChar
sys_PrintHexWord:               equ    12  ; PrintHexWord
sys_PrintCRLF:                  equ    14  ; PrintCRLF
sys_PrintFileName83:            equ    16  ; PrintFileName83
sys_FS_Mount:                   equ    18  ; FS_Mount
sys_FS_FindFirst:               equ    20  ; FS_FindFirst
sys_FS_FindNext:                equ    22  ; FS_FindNext
sys_FS_GetNextCluster:          equ    24  ; FS_GetNextCluster
sys_FS_LoadFile:                equ    26  ; FS_LoadFile
sys_FS_FindEntry:               equ    28  ; FS_FindEntry
sys_FS_ListRoot:                equ    30  ; FS_ListRoot
sys_FS_SaveFile:                equ    32  ; FS_SaveFile
sys_reg_cmd:                    equ    34  ; reg_cmd
sys_FS_ClusterToLBA_Offset:     equ    36  ; FS_ClusterToLBA_Offset
sys_Format_Filename_83:         equ    38  ; Format_Filename_83
sys_strcpy:                     equ    40  ; strcpy
sys_strlen:                     equ    42  ; strlen
sys_pager:                      equ    44  ; Pager  (nom sys_ diverge, assumé)
sys_loadandexec:                equ    46  ; LoadandExec  (nom sys_ diverge, assumé)
sys_ls:                         equ    48  ; ls_cmd  (nom sys_ diverge, assumé)
sys_malloc_sys:                 equ    50  ; malloc_sys
sys_free:                       equ    52  ; free
sys_FS_DeleteFile:              equ    54  ; FS_DeleteFile
sys_FS_GetAttributes:           equ    56  ; FS_GetAttributes
sys_FS_SetAttributes:           equ    58  ; FS_SetAttributes
sys_FarRead:                    equ    60  ; FarRead
sys_FarWrite:                   equ    62  ; FarWrite
sys_video_wait_vsync:           equ    64  ; video_wait_vsync
sys_snd_play:                   equ    66  ; snd_play
sys_snd_stop:                   equ    68  ; snd_stop
sys_Far_Call:                   equ    70  ; Far_Call
sys_Far_CallN:                  equ    72  ; Far_CallN
sys_FS_FileInfo:                equ    74  ; FS_FileInfo
sys_FS_ReadSector:              equ    76  ; FS_ReadSector
sys_FS_SetLoad:                 equ    78  ; FS_SetLoad
sys_FS_ChDir:                   equ    80  ; FS_ChDir
sys_FS_MkDir:                   equ    82  ; FS_MkDir
sys_FS_Dossier:                 equ    84  ; FS_Dossier
sys_FS_DirInfo:                 equ    86  ; FS_DirInfo
sys_kbd_poll:                   equ    88  ; kbd_poll
sys_Console_Zone:               equ    90  ; Console_Zone

