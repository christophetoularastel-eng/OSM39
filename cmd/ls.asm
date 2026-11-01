; ===================================================================
; LS.ASM — Liste le dossier courant (ou celui donné)
; Usage: LS [dossier]     (LS, LS .., LS /APPS)
; Charge: page 1, $0000. Autrefois dans l'EPROM (ls_cmd) : sorti avec le
; moniteur pour faire de la place.
; Affiche : nom ('/' après un dossier), taille, attributs rwx (+a).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

DE_OFF_NAME     EQU 1
DE_OFF_SIZE     EQU 20
DE_OFF_ATTR     EQU 27

    section .code

Start:
    ; --- un dossier en argument : on y va le temps de la liste ---
    LDD     #$FFFF
    JSR     [table_function_ram+sys_FS_Dossier]
    STD     Avant
    LDA     argc
    CMPA    #2
    BLO     Liste
    LDX     >argv+2
    JSR     [table_function_ram+sys_FS_ChDir]
    BCC     Liste
    LDX     #MsgAbsent
    JMP     [table_function_ram+sys_PrintString]
Liste:
    JSR     [table_function_ram+sys_PrintCRLF]
    JSR     [table_function_ram+sys_FS_FindFirst]
    BCS     Fin
Boucle:
    LDX     #g_find_fileInfo
    JSR     PrintEntree
    JSR     [table_function_ram+sys_FS_FindNext]
    BCC     Boucle
Fin:
    LDD     Avant               ; le dossier d'avant
    JSR     [table_function_ram+sys_FS_Dossier]
    RTS

; PrintEntree - X = entrée de 32 octets : nom, taille, attributs.
PrintEntree:
    PSHS    a,b,y
    LEAY    DE_OFF_NAME,x
    LDB     #15
PE_Nom:
    LDA     ,y+
    CMPA    #' '
    BEQ     PE_FinNom
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     PE_Nom
PE_FinNom:
    LDA     DE_OFF_ATTR,x       ; un dossier : son nom suivi de '/'
    BITA    #$20
    BEQ     PE_Taille
    LDA     #'/'
    JSR     [table_function_ram+sys_PrintChar]
PE_Taille:
    LDA     #9
    JSR     [table_function_ram+sys_PrintChar]
    LDD     DE_OFF_SIZE+2,x
    JSR     PrintDec16
    LDA     #9
    JSR     [table_function_ram+sys_PrintChar]
    LDA     DE_OFF_ATTR,x
    JSR     PrintAttrs
    JSR     [table_function_ram+sys_PrintCRLF]
    PULS    a,b,y,pc

; PrintDec16 - D en décimal (0-65535), sans zéros de tête.
DecPowers:
    FDB     10000,1000,100,10,1,0
PrintDec16:
    PSHS    a,b,x,y,u
    TFR     d,u
    LDB     #0                  ; B = au moins un chiffre affiché
    LDX     #DecPowers
PD_Boucle:
    LDY     ,x
    BEQ     PD_Fin
    CLRA
PD_Div:
    PSHS    a,b
    TFR     u,d
    SUBD    ,x
    BCS     PD_Suiv
    TFR     d,u
    PULS    a,b
    INCA
    BRA     PD_Div
PD_Suiv:
    PULS    a,b
    TSTB
    BNE     PD_Chiffre
    TSTA
    BNE     PD_Chiffre
    CMPY    #1
    BEQ     PD_Chiffre
PD_Puiss:
    LEAX    2,x
    BRA     PD_Boucle
PD_Chiffre:
    INCB
    ADDA    #'0'
    JSR     [table_function_ram+sys_PrintChar]
    BRA     PD_Puiss
PD_Fin:
    PULS    a,b,x,y,u,pc

; PrintAttrs - A = attributs : r w x, puis a (application OSM-VISION).
PrintAttrs:
    PSHS    a,x
    LDX     #Lettres
PA_Bit:
    LDA     ,x+                 ; masque
    BEQ     PA_Fin
    BITA    0,s
    BEQ     PA_Non
    LDA     ,x
    BRA     PA_Ecrit
PA_Non:
    LDA     #'-'
    CMPX    #Lettres+7          ; 'a' absent : rien
    BEQ     PA_Saut
PA_Ecrit:
    JSR     [table_function_ram+sys_PrintChar]
PA_Saut:
    LEAX    1,x
    BRA     PA_Bit
PA_Fin:
    PULS    a,x,pc
Lettres:
    FCB     $04,'r,$02,'w,$01,'x,$10,'a,0

MsgAbsent:  FCC "Dossier introuvable."
            FCB $0a,$0D,0
Avant:      RMB 2
