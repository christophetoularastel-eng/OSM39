    import  main
    import  __bss_start__
    import __bss_end__
    import  hdlr_SWI3
    import  hdlr_SWI2
    import  hdlr_FIRQ
    import  hdlr_IRQ
    import  hdlr_SWI
    import  hdlr_NMI
    import  CMD17_Packet
    import  handler_NMI,handler_FIRQ,handler_IRQ,handler_SWI,handler_SWI2,handler_SWI3,handler_TRAP
    import scan_keyboard,read_line,PrintChar,PrintString,PrintHexChar,PrintHexWord
    import PrintCRLF,PrintFileName83,FS_Mount,FS_FindFirst,FS_FindNext, FS_DeleteFile
    import FS_GetNextCluster,FS_LoadFile,FS_FindEntry,FS_LoadFile,FS_SaveFile
    import FS_ListRoot,reg_cmd,FS_ClusterToLBA_Offset,Format_Filename_83,strcpy,strlen,Pager,LoadandExec
    import ls_cmd, malloc_sys,video_wait_vsync
    import FS_GetAttributes, FS_SetAttributes,FarRead,FarWrite,FS_RenameFile
    import snd_play,snd_stop
    import Far_Call,Far_CallN,Sys_Absent
    import FS_FileInfo,FS_ReadSector,FS_SetLoad
    import FS_ChDir,FS_MkDir,FS_Dossier,FS_DirInfo
    import kbd_poll,Console_Zone
    export table_function_rom,table_function_rom_end

    export  rvec_SWI3, rvec_SWI2,rvec_FIRQ,rvec_IRQ,rvec_SWI,rvec_NMI
    export  rvec_TRAP
    export  __start, malloc_sys, Redemarrage
    import table_function_ram


HEAP_START  EQU __bss_end__
HEAP_SIZE   EQU $0700
HEAP_END    EQU HEAP_START+HEAP_SIZE

BLK_SIZE    EQU 0
BLK_USED    EQU 2
BLK_DATA    EQU 3
HDR_SIZE    EQU 3

RAM_START   equ     $c000
RAM_TOP     equ     $dFeF

    section .code

__start:

    orcc #%11111111
    lds     #RAM_TOP
    ldmd    #$01            ; mode natif HD6309 (bit 0 du registre MD)

InitBSS:
    ldx     #RAM_START
    ldy     #__bss_end__-__bss_start__
    beq     StartMain
ClearLoop:
    clr     ,x+
    leay    -1,y
    bne     ClearLoop

; Redemarrage - Démarrage à chaud (après un TRAP) : tout comme au reset,
; SAUF l'effacement de la BSS. trap_frame/trap_info (le rapport du TRAP,
; lu par MONITEUR), fs_dossier et boot_chaud survivent. Les tables en RAM
; (vecteurs, services, paquets SD, tas) sont recopiées : le programme qui a
; planté a pu les abîmer.
Redemarrage:
    orcc    #%01010000
    lds     #RAM_TOP
    ldmd    #$01

    ldb     #12
InitIdata:
    ldx     #CMD17_Packet_rom
    ldy     #CMD17_Packet
Idata_loop:
    lda ,x+
    sta ,y+
    decb
    bne Idata_loop

    ldb     #14            ; copie les 7 vecteurs (dont TRAP)
InitITvect:
    ldx     #svec_rom
    ldy     #svec_ram
ITvect_loop:
    lda ,x+
    sta ,y+
    decb
    bne ITvect_loop

;****************************************
;
;gestion de la table des fonctions
;
;   Dans l'ordre :
;   sys_FS_RenameFile
;   scankeyboard
;   read_line
;   PrintChar
;   PrintString
;   PrintHexChar
;   PrintHexWord
;   PrintCRLF
;   PrintFileName83
;   FS_Mount
;   FS_FindFirst
;   FS_FindNext
;   FS_GetNextCluster
;   FS_LoadFile
;   FS_FindEntry
;   FS_LoadFile
;   FS_ListRoot
;   sys_FS_SaveFile
;   reg_cmd
;   FS_ClusterToLBA_Offset
;   Format_Filename_83
;   strcpy
;   strlen
;   Pager
;   sys_memcpy_32_bytes
;   sys_loadandexec
;   sys_ls
;   sys_malloc_sys
;   sys_free
;   sys_FS_DeleteFile
;   sys_FS_GetAttributes
;   sys_FS_SetAttributes
;   sys_FarRead
;   sys_FarWrite
;   sys video_wait_vsync
;   sys_snd_play
;   sys_snd_stop
;*****************************************
    ldb     #table_function_rom_end-table_function_rom
Inittablefunction:
    ldx     #table_function_rom
    ldy     #table_function_ram
tablefunction_loop:
    lda ,x+
    sta ,y+
    decb
    bne tablefunction_loop
    jsr init_heap
StartMain:
    jmp     main

init_heap:
        LDX     #HEAP_START
        LDD     #HEAP_SIZE
        STD     BLK_SIZE,X
        CLR     BLK_USED,X
        RTS

malloc_sys:
        PSHS    D
        ADDD    #HDR_SIZE
        pshs d
        LDX     #HEAP_START
malloc_loop:
        CMPX    #HEAP_END
        BHS     malloc_fail
        LDA     BLK_USED,X
        BNE     malloc_next
        LDD     BLK_SIZE,X
        CMPD    ,S
        BLO     malloc_next
        LDA     #1
        STA     BLK_USED,X
        ldy     BLK_SIZE,x
        puls    d
        CMPD    BLK_SIZE,X
        BEQ     malloc_exact_match
        pshs    y
        STD     BLK_SIZE,X
        pshs    x
        addd    ,s++
        tfr     d,y
        puls    d
        subd    BLK_SIZE,X
        std     BLK_SIZE,y
        clr     BLK_USED,y
malloc_exact_match:
        LEAX    BLK_DATA,X
malloc_exit:
        PULS    D,pc

malloc_next:
        LDD     BLK_SIZE,X
        LEAX    D,X
        BRA     malloc_loop

malloc_fail:
        LDX     #0
        puls d
        bra malloc_exit

free:
        CMPX    #0
        BEQ     free_done
        LEAX    -BLK_DATA,X
        CMPX    #HEAP_START
        BLO     free_done
        CMPX    #HEAP_END
        BHS     free_done
        CLR     BLK_USED,X
free_done:
        RTS

realloc:
        PSHS    X,D
        CMPX    #0
        BEQ     realloc_malloc
        PSHS    X
        BSR     malloc_sys
        CMPX    #0
        BEQ     realloc_fail
        LDX     ,S+
        BSR     free
        PULS    D
        RTS
realloc_malloc:
        PULS    X
        BRA     malloc_sys
realloc_fail:
        PULS    X
        PULS    D
        RTS

hdlr_SWI:
        JMP     [rvec_SWI]

hdlr_SWI2:
        JMP     [rvec_SWI2]

hdlr_SWI3:
        JMP     [rvec_SWI3]

hdlr_IRQ:
        JMP     [rvec_IRQ]

hdlr_FIRQ:
        JMP     [rvec_FIRQ]

hdlr_NMI:
        JMP     [rvec_NMI]

hdlr_TRAP:
        jmp     [rvec_TRAP]

CMD17_Packet_rom:
    FCB     $51,$00,$00,$00,$00,$01

CMD24_Packet_rom:
    FCB     $58,$00,$00,$00,$00,$01

table_function_rom:
    fdb FS_RenameFile
    fdb scan_keyboard
    fdb read_line
    fdb PrintChar
    fdb PrintString
    fdb PrintHexChar
    fdb PrintHexWord
    fdb PrintCRLF
    fdb PrintFileName83
    fdb FS_Mount
    fdb FS_FindFirst
    fdb FS_FindNext
    fdb FS_GetNextCluster
    fdb FS_LoadFile
    fdb FS_FindEntry
    fdb FS_ListRoot
    fdb FS_SaveFile
    fdb reg_cmd
    fdb FS_ClusterToLBA_Offset
    fdb Format_Filename_83
    fdb strcpy
    fdb strlen
    fdb Pager
    fdb LoadandExec
    fdb ls_cmd
    fdb malloc_sys
    fdb free
    fdb FS_DeleteFile
    fdb FS_GetAttributes
    fdb FS_SetAttributes
    fdb FarRead
    fdb FarWrite
    fdb video_wait_vsync
    fdb snd_play
    fdb snd_stop
    fdb Far_Call
    fdb Far_CallN
    fdb FS_FileInfo
    fdb FS_ReadSector
    fdb FS_SetLoad
    fdb FS_ChDir
    fdb FS_MkDir
    fdb FS_Dossier
    fdb FS_DirInfo
    fdb kbd_poll
    fdb Console_Zone
table_function_end:
; Emplacements libres (voir table_reserve dans ram.asm) : C = 1, rien d'autre.
    fdb Sys_Absent
    fdb Sys_Absent
table_function_rom_end:
    fdb 0

    section .code

svec_rom:
    fdb handler_SWI3
    fdb handler_SWI2
    fdb handler_FIRQ
    fdb handler_IRQ
    fdb handler_SWI
    fdb handler_NMI
    fdb handler_TRAP

     section .ram_vectors
svec_ram:
rvec_SWI3 rmb   2
rvec_SWI2 rmb   2
rvec_FIRQ rmb   2
rvec_IRQ rmb    2
rvec_SWI rmb    2
rvec_NMI rmb    2
rvec_TRAP rmb   2

    section .vectors

svec_TRAP FDB     hdlr_TRAP
svec_SWI3 FDB     hdlr_SWI3
svec_SWI2 FDB     hdlr_SWI2
svec_FIRQ FDB     hdlr_FIRQ
svec_IRQ FDB     hdlr_IRQ
svec_SWI FDB     hdlr_SWI
svec_NMI FDB     hdlr_NMI
svec_RST FDB     __start

        end
