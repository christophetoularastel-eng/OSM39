; ======================================================
; SHELL.ASM - Interpréteur de commandes pour MON_OS
; ======================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

        export Shell_Start


    section .code

MAX_INPUT_LEN  EQU 128
MAX_ARGS       EQU 10
CMD_NAME_LEN   EQU 12

Shell_Start:
                LDX     #ShellMsg
                JSR     [table_function_ram+sys_PrintString]

MainLoop:
                LDX     #PromptMsg
                JSR     [table_function_ram+sys_PrintString]                     ; Affiche "A> "
                JSR     [table_function_ram+sys_read_line]          ; Lit une ligne dans input_buffer

                LDX     #input_buffer
                LDA     ,x
                BEQ MainLoop
                JSR     ParseCommand      ; Analyse la commande Retour: U=pointeur fonction, B=argc, Y=pointeur arg1
 
                cmpu    #0
                BEQ     TryExternalCmd

                ; --- OUI ! On exécute la fonction trouvée ---
                JSR     ,u                ; MAGIE ! Saut indirect à l'adresse dans U
                BRA     MainLoop


  ; Si U n'est pas 0, on a trouvé une commande interne !

; --- Pas une commande interne. Essayons de trouver un .EXE sur le disque ---
; --- Pas une commande interne. Essayons de trouver un .EXE sur le disque ---
; --- Pas une commande interne. Essayons de trouver un .EXE sur le disque ---
TryExternalCmd:
    ; --- Recherche d'un fichier exécutable sur la carte SD ---
                ldd     #16
                JSR     [table_function_ram+sys_malloc_sys]
                CMPX    #0
                BEQ     Malloc_Fail

                PSHS    x
                TFR     x,y
                LDX     #argv
                LDX     0,x                             ; on veut la commande
                JSR     Build_Filename
                PULS    x                               ; X pointe sur le nom formaté

                ; ==========================================================
                ; NOUVEAU : Lecture dynamique des attributs
                ; ==========================================================
                JSR     [table_function_ram+sys_FS_FindEntry]
                BCS     Free_And_Fail                   ; Carry=1 : Fichier introuvable

                ; L'entrée OSMFS fait 32 octets.
                ; Offset  1 = Nom sur 15 octets
                ; Offset 24 = Page de boot (1 octet)
                ; Offset 25 = Adresse de boot (2 octets Big-Endian)
                ; IMPORTANT : LoadandExec lit ses 3 arguments dans SA propre
                ; sauvegarde PSHS y,x,d -> 0,s = page, 2,s = X, 4,s = Y.
                ; Sans ce LDX, X conservait g_find_fileInfo (pointeur sur la
                ; DESC structure) au lieu du nom, et LoadandExec relisait
                ; l'entrée comme si c'était un tampon de nom.
                LDX     #g_find_fileInfo+1             ; X = nom du fichier (15 octets)
                LDA     g_find_fileInfo+24              ; A = Page cible dynamique
                LDY     g_find_fileInfo+25              ; Y = Adresse d'exécution dynamique

                ; On appelle le bios pour exécuter le fichier
                JSR     [table_function_ram+sys_loadandexec]

Free_And_Fail:
                PSHS    cc                              ; Sauvegarde le résultat de LoadandExec (ou FindEntry)
                JSR     [table_function_ram+sys_free]   ; On libère la ram system allouée par malloc
                PULS    cc
                BCS     Unknown_Command                 ; Si Carry=1 (Fichier non trouvé ou erreur de charge), on va à l'erreur

                BRA     MainLoop


Malloc_Fail:
Unknown_Command:

                LDX     #UnknownCmdMsg
                JSR     [table_function_ram+sys_PrintString]
                BRA     MainLoop


; ===================================================================
; ParseCommand
; Description : Analyse input_buffer, trouve la fonction correspondante
;               et prépare les arguments.
; Entrée      : X -> Pointeur vers input_buffer
; Sortie      : U -> Pointeur vers la fonction à exécuter (0 si non trouvée)
;               B = Nombre d'arguments (argc), incluant la commande.
;               Y -> Pointeur vers le début du premier argument (argv[1]).
; ===================================================================
ParseCommand:
    PSHS    a,x

    ; --- 1. Isoler le premier mot (la commande) ---
    TFR     x,y
FindEndOfCmd:

    LDA     ,y+
    CMPA    #' '
    BEQ     FoundSpace
    CMPA    #0
    BEQ     FoundSpace
    BRA     FindEndOfCmd
FoundSpace:
    PSHS    y           ; Sauvegarde le pointeur de la fin du mot
    LDB     -1,y        ; B = le caractère à la fin (espace ou 0)
    PSHS    b           ; Sauvegarde ce caractère
    LDB     #0
    STB     -1,y        ; Remplace temporairement l'espace par un NUL



    ; --- 2. Chercher la commande dans la table ---
    ldu     #CommandTable
SearchCmdLoop:
    ldd     ,u          ; D = pointeur vers la chaîne de la table

    CMPD    #0
    BEQ     CmdNotFound ; Fin de la table, commande non trouvée

    ; On compare la commande du buffer (en X) avec celle de la table (en D)
    PSHS    u,d         ; Sauvegarde U et D
    TFR     d,y         ; Y = pointeur de la chaîne de la table
    JSR     strcmp      ; Compare X et Y
    PULS    u,d         ; Restaure U et D
    BEQ     CmdFound    ; Si égales, on a trouvé !

    LEAU    4,u         ; Passe à l'entrée suivante de la table (+4 octets)
    BRA     SearchCmdLoop

CmdNotFound:
    ldu     #0          ; U = 0, signal d'échec
    BRA     RestoreAndCountArgs ; On va quand même restaurer le buffer

CmdFound:
    ; On a trouvé ! U pointe sur l'entrée de la table.
    ldu     2,u         ; On charge le 2ème pointeur de l'entrée : l'adresse de la fonction !
    ; U contient maintenant l'adresse de Do_Ver_Cmd, etc.

RestoreAndCountArgs:
    ; --- 3. Restaurer le buffer et compter les arguments ---
    PULS    b,y         ; Récupère le caractère original et le pointeur de fin
    STB     -1,y        ; Restaure l'espace ou le NUL


; ===============================================================
; --- 1. Tokenization de CommandBuffer ---
; Cette partie va découper la chaîne et remplir argc (en B) et argv (pointé par Y)
; ===============================================================
    ; ===============================================================
    ; !!! ATTENTION : `U` EST UNE VALEUR DE RETOUR DE ParseCommand !!!
    ; Le contrat (cf. l'en-tête de la routine) est :
    ;     U = pointeur vers la fonction à exécuter (0 si non trouvée)
    ; et MainLoop fait ensuite `JSR ,u`. Or CMPX n'a pas de mode
    ; "immédiat 16 bits" : le seul moyen de borner X sans toucher Y
    ; est de charger la borne dans un registre 16 bits.(on ne peut pas
    ; utiliser E/F : 8 bits seulement, et D est déjà le compteur de
    ; caractères de certaines routines). On utilise donc U.
    ; CONSÉQUENCE : il faut SAUVEGARDER U autour du tokenizer, sinon
    ; le `JSR ,u` de MainLoop saute dans une variable BSS et plante.
    ; C'est exactement ce qui se passait : le CPU partait sur
    ; read_line_ptr ($C1E9) et finissait son errance dans SD_BUFFER.
    ; ===============================================================
    LDX     #input_buffer  ; X pointe sur le début du buffer à analyser
    LDY     #argv           ; Y pointe sur notre table de pointeurs argv
    PSHS    u               ; <— sauvegarde le pointeur de fonction
    ldu     #input_buffer+MAX_INPUT_LEN  ; U = borne haute du buffer
    CLRB                    ; B = argc (compteur d'arguments), initialisé à 0

TokenizeLoop:
    ; --- On saute les espaces au début ou entre les mots ---
SkipSpaces_Tok:
    cmpx    0,U                   ; FIN DE BUFFER : on arrête de découper
    BHS     Tokenize_Done
    LDA     ,x
    CMPA    #' '
    BNE     StartOfToken
    LEAX    1,x
    BRA     SkipSpaces_Tok

StartOfToken:
    ; --- On regarde sur quoi on est tombé ---
    cmpx    0,U                   ; FIN DE BUFFER
    BHS     Tokenize_Done
    LDA     ,x
    BEQ     Tokenize_Done   ; Si c'est NUL, fin de la chaîne, on a fini de découper.

    ; --- On a trouvé le début d'un mot ! ---
    ; NE PAS dépasser argv : la table fait MAX_ARGS mots de 2 octets et
    ; argv est immédiatement suivi de argc, puis current_page, vsync_tick,
    ; BUF_HEAD et BUF_TAIL. Un débordement écrasait le tampon d'affichage
    ; vidéo et le compteur de synchro.
    CMPB    #(MAX_ARGS-1)
    BHS     Tokenize_Done   ; argv plein : on s'arrête là
    STX     ,y++            ; 1. On sauvegarde son pointeur dans argv
    INCB                    ; 2. On incrémente argc

    ; --- On cherche la fin de ce mot (le prochain espace ou NUL) ---
SkipChars_Tok:
    cmpx    0,U
    BHS     Tokenize_Done
    LEAX    1,x
    cmpx    0,U
    BHS     Tokenize_Done
    LDA     ,x
    BEQ     Tokenize_Done   ; Si fin de chaîne, on a fini.
    CMPA    #' '
    BNE     SkipChars_Tok   ; Tant que ce n'est pas un espace, on continue d'avancer.

    ; --- On a trouvé un espace, on le remplace par un NUL pour terminer le mot ---
              ; On utilise B temporairement
    CLR     ,x+            ; Remplace l'espace par NUL et je vais au caractère suivant

    BRA     TokenizeLoop    ; On repart chercher le mot suivant.


Tokenize_Done:
    ; À la sortie de cette boucle :
    ; - B contient le bon nombre d'arguments (argc).
    ; - La table `argv` contient les pointeurs vers chaque argument.
    ; - U doit contenir le pointeur de fonction rendu par ParseCommand.
    ;   C'est le SEUL point de sortie du tokenizer, donc le PULS u
    ;   équilibre le PSHS u posé juste avant le chargement de la borne.
    ;   Ne JAMAIS sortir du tokenizer par un autre chemin.
    STB         argc
    ; --- CORRECTIF RAHAN : Terminer la liste par un NULL ---
    CLR     ,y          ; Met 00 dans l'octet pointé par Y (fin de argv)
    CLR     1,y         ; Met 00 dans l'octet suivant (pour faire un mot de 16 bits propre)

    PULS    u              ; restitution du pointeur de fonction
    PULS    a,x,pc        ; Retour
; ===================================================================
; COMMANDES DU MONITEUR (SYSTÈME)
; ===================================================================

Do_Ver_Cmd:     PSHS x
                LDX #VersionMsg
                JSR     [table_function_ram+sys_PrintString]
                PULS x
                RTS


Do_Help_Cmd:
                PSHS x
                LDX #HelpMsg
                JSR     [table_function_ram+sys_PrintString]
                PULS x
                RTS


Do_Cls_Cmd:     PSHS a
                lda     #$0c
                JSR     [table_function_ram+sys_PrintChar]
                PULS    a
                RTS

; ===================================================================
; Do_MemDump_Cmd
; Gère la commande 'dump'.
; Entrée via parser : B = argc, X -> argv
; ===================================================================
Do_MemDump_Cmd:
        PSHS    u,y,x,d
        CMPB    #2              ; On a besoin d'au moins 2 args ("dump" et "adresse")
        LBLO     MemDump_SyntaxError
        LDX #argv
        LEAX    [2,x]           ; on recupère l'adresse dans table argv

        JSR     [table_function_ram+sys_PrintCRLF]
        JSR     StringToNumber            ;D=adresse
        TFR d,x
MemDump_Loop:
        LDY     #LineBuffer
        TFR     X,D
        JSR     [table_function_ram+sys_PrintHexChar]
        TFR     B,A
        JSR     [table_function_ram+sys_PrintHexChar]
MemDump_Byte:
        LDA     #' '
        JSR     [table_function_ram+sys_PrintChar]
        LDA     ,X+
        PSHS     A
        CMPA    #$1F
        BLS     MemDump_NonPrint
        CMPA    #$7F
        BLS     MemDump_PrintOk
MemDump_NonPrint:
        LDA     #'.'
MemDump_PrintOk:
        STA     ,Y+
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDA     #$08
        JSR     [table_function_ram+sys_PrintChar]
        JSR     [table_function_ram+sys_PrintChar]
        JSR     [table_function_ram+sys_scan_keyboard]
        CMPA    #' '
        BEQ     MemDump_NextAddr
        CMPA    #$0D
        BEQ     MemDump_Done
        TFR     A,B
        JSR     [table_function_ram+sys_PrintChar]
        JSR     [table_function_ram+sys_scan_keyboard]
        CMPA    #' '
        BEQ     MemDump_Backspace
        CMPA    #$0D
        BEQ     MemDump_Done
        JSR     [table_function_ram+sys_PrintChar]
        EXG     A,B
        JSR     asc2hex8
        STA     -$01,X
        CMPA    #$1F
        BLS     MemDump_ReplaceLow
        CMPA    #$7F
        BLS     MemDump_ReplaceOk
MemDump_ReplaceLow:
        LDA     #'.'
        BRA     MemDump_ReplaceStore
MemDump_ReplaceOk:
MemDump_ReplaceStore:
        STA     ,Y+
        CLR     ,Y
MemDump_CheckLine:
        CMPY    #LineBuffer+16
        BNE     MemDump_Byte
        LDA     #' '
        JSR     [table_function_ram+sys_PrintChar]
        CLRA
        STA     ,Y+
        EXG     X,Y
        LDX     #LineBuffer
        JSR     [table_function_ram+sys_PrintString]
        EXG     X,Y
        LDA     #$0A
        JSR     [table_function_ram+sys_PrintChar]
        LDA     #$0D
        JSR     [table_function_ram+sys_PrintChar]
        LBRA    MemDump_Loop
MemDump_Backspace:
        LDA     #$08
        JSR     [table_function_ram+sys_PrintChar]
MemDump_NextAddr:
        LDA     -$01,X
        JSR     [table_function_ram+sys_PrintHexChar]
        BRA     MemDump_CheckLine
MemDump_Done:
        PULS    u,y,x,d,pc

MemDump_SyntaxError:
                JSR     [table_function_ram+sys_PrintCRLF]
                LDX     #SyntaxErrorMsg
                JSR     [table_function_ram+sys_PrintString]
                PULS    u,y,x,d,pc

Do_Reg_Cmd:
        PSHS    PC,U,Y,X,DP,D,CC
        LDX     #control_register
        JSR     [table_function_ram+sys_PrintString]
        LDX     #status_flag
        PULS     B
Reg_FlagLoop:   LDA     ,X+
        ASLB
        BCS     Reg_FlagPrint
        LDA     #'.'
Reg_FlagPrint:   JSR     [table_function_ram+sys_PrintChar]
        CMPX    #reg_end
        BLS     Reg_FlagLoop
        LDX     #A_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #B_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #DP_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #X_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #Y_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #U_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #pc_reg
        JSR     [table_function_ram+sys_PrintString]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        PULS     A
        JSR     [table_function_ram+sys_PrintHexChar]
        LDX     #S_reg
        JSR     [table_function_ram+sys_PrintString]
        TFR     S,D
        JSR     [table_function_ram+sys_PrintHexChar]
        TFR     B,A
        JSR     [table_function_ram+sys_PrintHexChar]
        RTS


 ; ===================================================================
; Do_LS_Cmd
; Gère la commande 'ls' ou 'dir'.
; ===================================================================
Do_Ls_Cmd:

        JMP     [table_function_ram+sys_ls]

Do_Del_Cmd:
        LDA argc
        CMPA #2
        BNE No_Arg_Provided

        LDX #argv
        LDX 2,x

        LDY     #FormattedName          ; Destination: notre buffer de 15 octets

        JSR     [table_function_ram+sys_Format_Filename_83]     ; Appelle la conversion

        LDX     #FormattedName          ; <-- 2. X pointe maintenant vers le nom formaté

        JSR     [table_function_ram+sys_FS_DeleteFile]
        BCC     Del_Success
        BRA     No_Arg_Provided
Del_Success:
        LDX     #DelSuccessMsg
        JSR     [table_function_ram+sys_PrintString]
        RTS

No_Arg_Provided:
        LDX     #No_filename
        JSR     [table_function_ram+sys_PrintString]
        RTS

; ===================================================================
; Do_Chmod_Cmd - Change file attributes (rwx)
; Usage : CHMOD <file> <mode>
;         mode octal : 0-7 (ou 644/755 : seul le 1er chiffre compte)
;         mode symbolique : [u|g|o|a][+|-|=][rwx]  (ex: +x, -w, =r)
; ===================================================================
Do_Chmod_Cmd:
        LDA     argc
        CMPA    #3
        BNE     Chmod_Usage

        LDX     #argv
        LDX     2,x             ; argv[1] = nom de fichier

        LDY     #FormattedName          ; Destination: notre buffer de 15 octets
        JSR     [table_function_ram+sys_Format_Filename_83]

        LDX     #argv
        LDX     4,x             ; argv[2] = mode
        LDY     #FormattedName
        JSR     Parse_Mode
        BCS     Chmod_Usage
        PSHS    a               ; nouveau mode

        LDX     #FormattedName
        JSR     [table_function_ram+sys_FS_SetAttributes]
        PULS    a
        BCC     Chmod_Success
        BRA     Chmod_NotFound

Chmod_Success:
        LDX     #ChmodMsg
        JSR     [table_function_ram+sys_PrintString]
        JSR     Print_Attrs
        JSR     [table_function_ram+sys_PrintCRLF]
        RTS

Chmod_NotFound:
        LDX     #ChmodNotFoundMsg
        JSR     [table_function_ram+sys_PrintString]
        RTS

Chmod_Usage:
        LDX     #ChmodUsageMsg
        JSR     [table_function_ram+sys_PrintString]
        RTS

; ===================================================================
; Parse_Mode - Parse l'argument mode de CHMOD
; Entrée : X -> chaîne mode, Y -> nom formaté
; Sortie : carry=0, A = nouveaux attributs (bit2=r bit1=w bit0=x)
;          carry=1 mode invalide
; ===================================================================
Parse_Mode:
        PSHS    y,x
        LDA     ,x
        CMPA    #'+'
        BEQ     Mode_Symbolic
        CMPA    #'-'
        BEQ     Mode_Symbolic
        CMPA    #'='
        BEQ     Mode_Symbolic
        CMPA    #'0'            ; chiffre octal ? sinon mode symbolique
        BLO     Mode_Symbolic   ; (u/g/o/a, r/w/x, ... tout non-chiffre)
        CMPA    #'7'
        BHI     Mode_Symbolic

        ; --- mode octal : premier chiffre 0-7 ---
        LDA     ,x
        JSR     CharToVal
        CMPA    #$FF
        BEQ     Mode_Error
        CMPA    #$07
        BHI     Mode_Error
        ANDCC   #%11111110      ; carry=0 (effacer le borrow de CMPA #$07)
        PULS    x,y,pc          ; A = mode

Mode_Error:
        ORCC    #%00000001
        PULS    x,y,pc

Mode_Symbolic:
        TFR     y,x             ; X = nom
        JSR     [table_function_ram+sys_FS_GetAttributes]
        BCS     Mode_Error
        STA     chmod_cur
        LDX     0,s             ; X = chaîne mode (0,s = X sauvegardé)

Mode_Sym_Who:                   ; saute le préfixe u/g/o/a éventuel
        LDA     ,x
        BEQ     Mode_Error
        CMPA    #'A'            ; majuscule -> minuscule (l'entrée est en majuscules)
        BLO     Mode_Sym_Who_Cmp
        CMPA    #'Z'
        BHI     Mode_Sym_Who_Cmp
        ADDA    #$20
Mode_Sym_Who_Cmp:
        CMPA    #'u'
        BEQ     Mode_Sym_WhoSkip
        CMPA    #'g'
        BEQ     Mode_Sym_WhoSkip
        CMPA    #'o'
        BEQ     Mode_Sym_WhoSkip
        CMPA    #'a'
        BEQ     Mode_Sym_WhoSkip
        BRA     Mode_Sym_Op
Mode_Sym_WhoSkip:
        LEAX    1,x
        BRA     Mode_Sym_Who

Mode_Sym_Op:
        LDA     ,x+
        STA     chmod_op
        CMPA    #'+'
        BEQ     Mode_Sym_Bits
        CMPA    #'-'
        BEQ     Mode_Sym_Bits
        CMPA    #'='
        BNE     Mode_Error
        ; op '+' ou '-' : il faut le masque ; op '=' : masque seul
Mode_Sym_Bits:
        CLRA                    ; A = masque des bits r/w/x
Mode_Sym_Bits_Loop:
        PSHS    a
        LDA     ,x+
        BEQ     Mode_Sym_Apply
        CMPA    #' '
        BEQ     Mode_Sym_Apply
        CMPA    #'A'            ; majuscule -> minuscule (l'entrée est en majuscules)
        BLO     Mode_Sym_Bits_Cmp
        CMPA    #'Z'
        BHI     Mode_Sym_Bits_Cmp
        ADDA    #$20
Mode_Sym_Bits_Cmp:
        CMPA    #'r'
        BEQ     Mode_Sym_R
        CMPA    #'w'
        BEQ     Mode_Sym_W
        CMPA    #'x'
        BEQ     Mode_Sym_X
        PULS    a
        BRA     Mode_Error
Mode_Sym_R:
        PULS    a
        ORA     #$04            ; bit read
        BRA     Mode_Sym_Bits_Loop
Mode_Sym_W:
        PULS    a
        ORA     #$02            ; bit write
        BRA     Mode_Sym_Bits_Loop
Mode_Sym_X:
        PULS    a
        ORA     #$01            ; bit exec
        BRA     Mode_Sym_Bits_Loop

Mode_Sym_Apply:
        PULS    a               ; A = masque
        LDB     chmod_op
        CMPB    #'='
        BEQ     Mode_Sym_Set
        CMPB    #'+'
        BEQ     Mode_Sym_Add
        ; '-' : A = attrs actuels ET PAS masque
        COMA
        ANDA    chmod_cur
        ANDCC   #%11111110
        PULS    x,y,pc
Mode_Sym_Add:
        ORA     chmod_cur
        PULS    x,y,pc
Mode_Sym_Set:
        ANDA    #$07
        PULS    x,y,pc

; ===================================================================
; Print_Attrs - Affiche les attributs rwx (ex: "rwx" ou "-w-")
; Entrée : A = attributs
; ===================================================================
Print_Attrs:
        PSHS    a,x
        LDA     0,s
        BITA    #$04
        BEQ     PA_NoR
        LDA     #'r'
        BRA     PA_PutR
PA_NoR:
        LDA     #'-'
PA_PutR:
        JSR     [table_function_ram+sys_PrintChar]
        LDA     0,s
        BITA    #$02
        BEQ     PA_NoW
        LDA     #'w'
        BRA     PA_PutW
PA_NoW:
        LDA     #'-'
PA_PutW:
        JSR     [table_function_ram+sys_PrintChar]
        LDA     0,s
        BITA    #$01
        BEQ     PA_NoX
        LDA     #'x'
        BRA     PA_PutX
PA_NoX:
        LDA     #'-'
PA_PutX:
        JSR     [table_function_ram+sys_PrintChar]
        PULS    a,x,pc
;*****************************************
; --- Routine de comparaison de chaînes
;*****************************************

strcmp:
                PSHS    a,x,y
                ;PSHS x,y
                ;JSR Debug_String
                ;TFR y,x
                ;JSR Debug_String
                ;PULS x,y

strcmp_loop:

                LDA     ,x+
                CMPA    ,y+
                BNE     strcmp_notequal
                TSTA
                BNE     strcmp_loop
    ; Si on arrive ici, les chaînes sont égales et on a atteint le NUL
strcmp_equal:
strcmp_notequal:

                PULS    a,x,y,pc


; ===================================================================
; StringToNumber
; Entrée : X -> Pointeur vers la chaîne (ex: "123")
; Sortie : D = Valeur binaire finale
; ===================================================================
StringToNumber:
    PSHS    y,x
    LDY     #0          ; Y = Accumulateur (Résultat = 0)
       ; JSR Debug_String
STN_Loop:
       ;JSR Debug_X
    LDA     ,x+         ; Charge le caractère
        ;JSR Debug_a
        ;TSTA
    BEQ     STN_Done    ; Fin si NUL
    CMPA    #' '
    BEQ     STN_Done    ; Fin si Espace
        ;JSR Debug_a
    ; --- Conversion ASCII vers Valeur 0-15 ---
    JSR     CharToVal   ; Doit retourner la valeur dans A, ou $FF
         ;JSR Debug_a
    CMPA    #$FF
    BEQ     STN_Error    ; Si invalide, on arrête

    PSHS    a           ; Sauvegarde la valeur du chiffre (0-15)
    TFR     y,d         ; On transfère l'accumulateur dans D pour le calcul


STN_Mul16:              ; Logique Base 16 (D * 16) — native 6309 ASLD
    asld
    asld
    asld
    asld

STN_AddDigit:
    TFR     d,y         ; Remet le résultat multiplié dans Y
    PULS    a           ; Récupère la valeur du chiffre (poussée avant le calcul)
    CLRB                ; D reste A:B en mode natif 6309 (E:F = W, D:W = Q) :
    EXG     a,b         ; D = 00:Valeur. NE PAS utiliser TFR a,e ici.
    LEAY    d,y         ; Y = Y + Valeur (Accumulation finale)
       ; PSHS x
        ;TFR d,x
        ;JSR Debug_X
        ;PULS x
    ; (Ici il faudrait idéalement suivre l'avancement de X,
    ; mais pour un test simple, on reboucle)
    ; Note : Pour que X avance, il faut le mettre à jour régulièrement
    BRA     STN_Loop

STN_Done:
    TFR     y,d         ; Résultat final dans D
    ANDCC       #%11111110
    PULS    x,y,pc
STN_Error:
    ORCC        #%00000001
    PULS    x,y,pc

CharToVal:
        CMPA    #$46        ;minuscule ?
        BLS     Majuscule
        CMPA    #$60
        BLS     NotNumber
        SUBA    #$20
Majuscule:
        CMPA    #$2F
        BLS     NotNumber
        CMPA    #$46
        BHI     NotNumber
        SUBA    #$30
        CMPA    #$09         ;chiffre 0-9?
        BLS     End_CharToVal
        SUBA    #$07         ;A-F
End_CharToVal:
        RTS
NotNumber:
        LDA #$ff
        RTS

asc2hex8:
        CMPA    #$60        ;minuscule ?
        BLS     majuscule
        SUBA    #$20
majuscule:
        SUBA    #$30
        CMPA    #$09         ;chiffre 0-9?
        BLS     chiffre
        SUBA    #$07         ;A-F
chiffre:
        ASLA
        ASLA
        ASLA
        ASLA
        CMPB    #$60
        BLS     Asc2Hex_Maj2
        SUBB    #$20
Asc2Hex_Maj2   SUBB    #$30
        CMPB    #$09
        BLS     AscHex_Merge
        SUBB    #$07
AscHex_Merge   PSHS     B
        ORA     ,S+
        RTS

; ===================================================================
; Build_Filename
; Description : Construit le nom de fichier exécutable au format OSMFS
;               (15 caractères, pad espaces). Plus d'extension : le nom
;               saisi est utilisé tel quel (converti en majuscules).
; Entrée      : X -> Pointeur vers le nom de la commande source
;               Y -> Pointeur vers le buffer destination (16 octets)
; Sortie      : Le buffer en Y contient 15 caractères pad espaces.
; ===================================================================
Build_Filename:
    PSHS    a,b,x,y
    LDB     #15            ; compteur max
CopyBaseNameLoop:
    LDA     ,x+            ; lit un caractère source
    CMPA    #' '
    BEQ     PadSpaces
    CMPA    #0
    BEQ     PadSpaces
    CMPA    #'a'
    BLO     NoUpper
    CMPA    #'z'
    BHI     NoUpper
    SUBA    #$20
NoUpper:
    STA     ,y+            ; copie dans la destination
    DECB
    BNE     CopyBaseNameLoop
PadSpaces:
    TSTB
    BEQ     BuildDone
PadSpacesLoop:
    LDA     #' '
    STA     ,y+
    DECB
    BNE     PadSpacesLoop
BuildDone:
    PULS    a,b,x,y,pc


; ======================================================
; shell.asm - Section de données
; ======================================================


; --- Chaînes de caractères pour les commandes ---
CmdStr_Ver:     FCN "VER"
CmdStr_Cls:     FCN "CLS"
CmdStr_Dump:    FCN "DUMP"
CmdStr_Reg:     FCN "REG"
CmdStr_Ls:      FCN "LS"
CmdStr_Del:     FCN "DEL"
CmdStr_Chmod:   FCN "CHMOD"
CmdStr_Help:    FCN "HELP"

; --- Table de commandes principale ---
; Format : [Pointeur vers la chaîne], [Pointeur vers la fonction]
CommandTable:
                FDB CmdStr_Ver,Do_Ver_Cmd
                FDB CmdStr_Cls,Do_Cls_Cmd
                FDB CmdStr_Dump,Do_MemDump_Cmd
                FDB CmdStr_Reg,Do_Reg_Cmd
                FDB CmdStr_Ls,Do_Ls_Cmd
                FDB CmdStr_Del,Do_Del_Cmd
                FDB CmdStr_Chmod,Do_Chmod_Cmd
                FDB CmdStr_Help,Do_Help_Cmd
                FDB 0,0                  ; Marqueur de fin de table, TRÈS IMPORTANT !




UnknownCmdMsg:  FCC "Commande inconnue."
 MsgCR:         FCB $0a,$0d
                FCB 0
VersionMsg:
ShellMsg:       FCC "Shell Version 1.0"
                FCB $0a,$0d
                FCB 0

No_filename:   FCC "Usage: DEL <filename>"
                FCB $0a,$0d
                FCB 0

DelSuccessMsg: FCC "Fichier supprime."
                FCB $0a,$0d
                FCB 0

ChmodUsageMsg:  FCN "Usage: CHMOD <file> <mode>"
ChmodNotFoundMsg: FCC "Fichier introuvable."
                FCB $0a,$0d
                FCB 0
ChmodMsg:       FCC "Attributs: "
                FCB 0

HelpMsg:       FCN "Commandes: VER CLS DUMP REG LS DEL CHMOD HELP TYPE CP "

; --- Données ---
PromptMsg:
                FCB $0a,$0d
                FCC "# "
                FCB 0
; --- Données ---
SyntaxErrorMsg: FCN "Usage: DUMP <address>"

A_reg:
        FCB     09
        FCN     "A:"
B_reg:
        FCB     09
        FCN     "B:"
X_reg:
        FCB     $0A,$0D,09
        FCN     "X:"
Y_reg:
        FCB     09
        FCN     "Y:"
U_reg:
        FCB     09
        FCN     "U:"
S_reg:
        FCB     09
        FCN     "S:"
DP_reg:
        FCB     09
        FCN     "DP:"
pc_reg:
        FCB     09
        FCN     "PC:"
control_register:
        FCB     $0A,$0D
        FCN     "CCR:"
status_flag:
        FCN     "EFHINZVC"
reg_end:FCB     0

MsgDir: FCC "<DIR>"
        FCB 0

LineBuffer:     RMB 18
FileInfoBuffer: RMB 40
chmod_op:       RMB 1   ; Opérateur symbolique (+ - =) pour CHMOD
chmod_cur:      RMB 1   ; Attributs courants pour CHMOD

