; ===================================================================
; TYPE.ASM — Affiche le contenu d'un fichier texte
; Usage: TYPE <filename>
; Charge: page 1, $0000
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

MAX_FILE_SIZE:  EQU 16384

    section .code

Start:
    ; --- Vérifier argc >= 2 ---
    LDA     argc
    CMPA    #2
    LBLO    PrintUsage

    ; --- Formater le nom du fichier (argv[1]) ---
    LDX     >argv+2             ; X = pointeur vers argv[1]
    LDY     #FormattedName
    JSR     [table_function_ram+sys_Format_Filename_83]

    ; --- Chercher l'entrée pour obtenir la taille ---
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_FindEntry]
    LBCS    FileNotFound

    ; U = taille du fichier
    CMPU    #MAX_FILE_SIZE
    LBHS    FileTooLarge

    ldx #FileBuffer
    ; --- Charger le fichier ---
    PSHS    X               ; sauver pointeur buffer
    lda     current_page
    LDX     #FormattedName
    LDY     ,S              ; Y = buffer
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    LoadError

    ; --- Fin du texte : un 0 après le dernier octet (U = taille) ---
    LDX     ,S
    TFR     U,D
    CLR     D,X

    ; --- Lignes par page : la zone du Terminal, sinon l'écran ---
    LDD     #(80*256)+25
    TST     cz_actif
    BEQ     TailleOk
    LDA     cz_l
    LDB     cz_h
TailleOk:
    STA     Largeur
    DECB                        ; la dernière ligne : « -- suite -- »
    STB     Hauteur
    CLR     Colonne
    CLR     Lignes

    ; --- Afficher, une page à la fois ---
    LDX     ,S              ; X = buffer
PrintLoop:
    LDA     ,X+
    BEQ     PrintDone       ; NUL = fin
    CMPA    #$0D
    BEQ     FinLigne
    CMPA    #$0A
    BEQ     FinLigneLf
    JSR     [table_function_ram+sys_PrintChar]
    INC     Colonne
    LDA     Colonne
    CMPA    Largeur
    BLO     PrintLoop
    BSR     LigneComptee    ; la console passe à la ligne toute seule
    BCC     PrintLoop
    BRA     PrintFin
FinLigne:
    LDA     ,X              ; CR LF : un seul saut
    CMPA    #$0A
    BNE     FinLigneLf
    LEAX    1,X
FinLigneLf:
    JSR     [table_function_ram+sys_PrintCRLF]
    BSR     LigneComptee
    BCC     PrintLoop
    BRA     PrintFin
PrintDone:
    JSR     [table_function_ram+sys_PrintCRLF]
PrintFin:
    ; --- Libérer le buffer ---
    LDX     ,S++
    RTS

; LigneComptee : une ligne de plus ; page pleine : on attend une touche.
; C = 1 si Échap (fin de l'affichage).
LigneComptee:
    PSHS    X
    CLR     Colonne
    INC     Lignes
    LDA     Lignes
    CMPA    Hauteur
    BLO     LcFin
    CLR     Lignes
    LDX     #MsgSuite
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_scan_keyboard]
    PSHS    A
    LDX     #MsgEfface
    JSR     [table_function_ram+sys_PrintString]
    PULS    A
    CMPA    #$1B
    BEQ     LcEchap
LcFin:
    ANDCC   #$FE
    PULS    X,PC
LcEchap:
    ORCC    #1
    PULS    X,PC

LoadError:
    LDX     ,S++
    LDX     #MsgLoadError
    JMP     PrintAndReturn

FileNotFound:
    LDX     #MsgNotFound
    JMP     PrintAndReturn

FileTooLarge:
    LDX     #MsgTooLarge
    JMP     PrintAndReturn

MemError:
    LDX     #MsgMemError
    JMP     PrintAndReturn

PrintUsage:
    LDX     #MsgUsage
PrintAndReturn:
    JSR     [table_function_ram+sys_PrintString]
    RTS

; --- Données ---
MsgUsage:       FCN "Usage: TYPE <filename>"
                FCB $0a,$0D,0
MsgNotFound:    FCN "Fichier non trouve."
                FCB $0a,$0D,0
MsgTooLarge:    FCN "Fichier trop grand (max 16 Ko)."
                FCB $0a,$0D,0
MsgMemError:    FCN "Erreur memoire."
                FCB $0a,$0D,0
MsgLoadError:   FCN "Erreur lecture fichier."
                FCB $0a,$0D,0
MsgSuite:       FCN "-- suite : une touche, Echap pour finir --"
MsgEfface:      FCB $0D
                FCC "                                          "
                FCB $0D,0

Largeur:    RMB 1
Hauteur:    RMB 1
Colonne:    RMB 1
Lignes:     RMB 1


FileBuffer: RMB 1
