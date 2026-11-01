; ===================================================================
; PWD.ASM — Affiche le dossier courant (/APPS/JEUX)
; Usage: PWD
; Charge: page 1, $0000
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

PROF_MAX    EQU 16              ; niveaux affichés au plus

    section .code

Start:
    ; --- remonter jusqu'à la racine en notant les n° ---
    LDD     #$FFFF
    JSR     [table_function_ram+sys_FS_Dossier]
    LDY     #Chaine
    CLR     Niveaux
Monte:
    CMPD    #0
    BEQ     Affiche
    PSHS    D
    LDB     Niveaux
    CMPB    #PROF_MAX
    PULS    D                   ; (PULS ne touche pas les drapeaux)
    BHS     Affiche
    STD     ,Y++
    INC     Niveaux
    PSHS    Y
    LDY     #0
    JSR     [table_function_ram+sys_FS_DirInfo]   ; D = parent
    PULS    Y
    BCC     Monte
Affiche:
    ; --- les noms, de la racine vers le dossier courant ---
    TST     Niveaux
    BNE     Nom
    LDA     #'/'
    JSR     [table_function_ram+sys_PrintChar]
    BRA     Fin
Nom:
    LDA     #'/'
    JSR     [table_function_ram+sys_PrintChar]
    LDD     ,--Y
    PSHS    Y
    LDY     #NomBuf
    JSR     [table_function_ram+sys_FS_DirInfo]
    LDX     #NomBuf
    LDB     #15
Car:
    LDA     ,X+
    CMPA    #' '
    BEQ     Suite
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     Car
Suite:
    PULS    Y
    DEC     Niveaux
    BNE     Nom
Fin:
    JMP     [table_function_ram+sys_PrintCRLF]

Niveaux:    RMB 1
NomBuf:     RMB 16
Chaine:     RMB 2*PROF_MAX
