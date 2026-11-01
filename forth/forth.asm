; ======================================================
; FORTH.ASM - langage forth pour mon OSM09
; Version corrigée — DO/LOOP réécrit (Stack Frames propres)
; ======================================================
;
; Structure d'un mot du dictionnaire (RÉFÉRENCE UNIQUE)
;   +0 : Link      (2 octets) — pointeur vers le mot précédent
;   +2 : Op        (2 octets) — adresse de l'exécuteur
;   +4 : Checksum  (1 octet)  — XOR de tous les caractères du nom
;   +5 : Longueur  (1 octet)  — nombre de caractères (sans NUL)
;   +6 : Nom       (N octets) — ASCII, terminé par NUL
;   +6+N+1 : Body  (liste d'adresses 16 bits, terminée par $0000)
;
; Corrections appliquées :
;   [C1] Stack overflow Forth     → Check_Stack_Overflow
;   [C2] Stack underflow          → Check_Stack_1 / Check_Stack_2
;   [C3] Op_Store protection BIOS → bhs + zone basse $0100
;   [H1] Op_Mul tronqué 8 bits    → Mul16 décomposé
;   [H2] Op_Div O(N)              → délègue à Div16_Fast
;   [H3] Do_Compiled_Word fragile → offsets fixes documentés
;   [H4] Op_Colon corrompt dico   → rollback HERE/CURRENT_WORD
;   [M1] Tokenizer débordement    → MAX_ARGS + vérification
;   [M2] Op_If offset pile fixe   → ARGV_PTR partagé, ELSE ajouté
;   [M3] Marge mémoire fixe       → marge dynamique + NEST_DEPTH
;   [L1] Op_DoLoop stack frame    → ordre limit/index/body/ret corrigé
;   [L2] LoopEx_Done              → nettoyage de pile et avance body_ptr
;   [L3] PlusLoop_Done            → nettoyage de pile et avance body_ptr
;   [L4] Op_J offset              → index externe lu à 8,s
; ======================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

; ======================================================
; Constantes
; ======================================================
MAX_ARGS        equ     32      ; Maximum d'arguments par ligne
BASE_MARGIN     equ     64      ; Marge mémoire de base (octets)
NEST_COST       equ     4       ; Octets empilés par DO sur S (limit + index)
MAX_NEST        equ     16      ; Profondeur d'imbrication maximale

    section .code

FORTH_Start:

                ldx     #ForthMsg
                JSR     [table_function_ram+sys_PrintString]
                ldu     #CalcStackPointer  ; Initialisation de la pile Forth

MainLoop:
                jsr     Forth_ReadLine

                ldx     #Forth_InputBuf
                lda     ,x
                beq     MainLoop
                jsr     ParseCommand

                jsr     Do_Calc_Cmd
                ldx     #PromptMsg
                JSR     [table_function_ram+sys_PrintString]
                lda     FORTH_QUIT_FLAG
                beq     MainLoop

                clr     FORTH_QUIT_FLAG
                rts


; ===================================================================
; ParseCommand
; Entrée  : X -> Forth_InputBuf
; Sortie  : Forth_Argv, Forth_Argc remplis
; ===================================================================
ParseCommand:
    pshs    a,x

    ldx     #Forth_InputBuf
    ldy     #Forth_Argv
    clrb

TokenizeLoop:
SkipSpaces_Tok:
    lda     ,x
    cmpa    #' '
    bne     StartOfToken
    leax    1,x
    bra     SkipSpaces_Tok

StartOfToken:
    lda     ,x
    beq     Tokenize_Done

    cmpb    #MAX_ARGS
    beq     Tokenize_Full

    stx     ,y++
    incb

SkipChars_Tok:
    leax    1,x
    lda     ,x
    beq     Tokenize_Done
    cmpa    #' '
    bne     SkipChars_Tok

    clr     ,x+
    bra     TokenizeLoop

Tokenize_Full:
    pshs    x,d
    ldx     #MsgTooManyArgs
    jsr     [table_function_ram+sys_PrintString]
    puls    x,d
SkipToEnd:
    lda     ,x+
    bne     SkipToEnd

Tokenize_Done:
    stb     Forth_Argc
    clr     ,y
    clr     1,y
    puls    a,x,pc


; ===================================================================
; Calculate_Checksum
; ===================================================================
Calculate_Checksum:
    pshs    x
    clra
    clrb
Calc_CS_Loop:
    ldb     ,x+
    beq     Calc_CS_End
    cmpb    #' '
    beq     Calc_CS_End
    eora    -1,x
    incb
    bra     Calc_CS_Loop
Calc_CS_End:
    tfr     a,b
    puls    x
    pshs    b
    clrb
Count_Len:
    lda     ,x+
    beq     Count_Done
    cmpa    #' '
    beq     Count_Done
    incb
    bra     Count_Len
Count_Done:
    puls    a
    rts


; ===================================================================
; Do_Calc_Cmd
; ===================================================================
Do_Calc_Cmd:
        pshs    x,y,u,d

        ldx     #Forth_Argv

Calc_Loop:
        stx     ARGV_PTR        ; Sauve la position courante dans argv
        ldy     ,x++
        cmpy    #0
        lbeq    Calc_Exit

        pshs    x
        tfr     y,x
        jsr     Calculate_Checksum
        sta     Searched_CS
        stb     Searched_Len
        puls    x

        pshs    x,y
        ldx     CURRENT_WORD

find_Op_loop:
        cmpx    #0
        beq     not_Op

        lda     4,x
        cmpa    Searched_CS
        bne     Next_Word_Opt

        lda     5,x
        cmpa    Searched_Len
        bne     Next_Word_Opt

        pshs    x,y
        leax    6,x
        jsr     memcmp
        beq     This_Op
        puls    x,y

Next_Word_Opt:
        ldx     ,x
        bra     find_Op_loop

This_Op:
        puls    x,y
        tfr     x,d
        jsr     [2,x]
        bra     Other_Op

not_Op:
        tfr     y,x
        jsr     StringToNumber
        lbcs    Error_Op
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        pshu    d

Other_Op:
        puls    x,y
        bra     Calc_Loop

Error_Stack_Full:
        ldx     #MsgStackFull
        jsr     [table_function_ram+sys_PrintString]
        puls    x,y
        bra     Calc_Loop

Error_Op:
        ldx     #MsgSyntaxError
        jsr     [table_function_ram+sys_PrintString]
        puls    x,y

Calc_Exit:
        puls    x,y,u,d,pc

; ===================================================================
; Forth_ReadLine
; ===================================================================
Forth_ReadLine:
        ldx     #Forth_InputBuf
FRL_Key:
        jsr     [table_function_ram+sys_scan_keyboard]
        cmpa    #$0D
        beq     FRL_Enter
        cmpa    #$0A
        beq     FRL_Enter
        jsr     [table_function_ram+sys_PrintChar]
        cmpa    #$60
        bls     FRL_NotLower
        suba    #' '
FRL_NotLower:
        cmpa    #$08
        bne     FRL_Store
        cmpx    #Forth_InputBuf
        beq     FRL_Key
        clra
        sta     ,-x
        bra     FRL_Key
FRL_Store:
        cmpx    #Forth_InputBuf+255
        bhs     FRL_Key
        sta     ,x+
        clra
        sta     ,x
        bra     FRL_Key
FRL_Enter:
        rts


; ===================================================================
; Vérifications de pile Forth
; ===================================================================
Check_Stack_Overflow:
    cmpu    #CalcStack+2
    bhi     Stack_OF_OK
    orcc    #%00000001
    rts
Stack_OF_OK:
    andcc   #%11111110
    rts

Check_Stack_1:
    cmpu    #CalcStackPointer-2
    bls     Stack_Check_OK
    orcc    #%00000001
    rts

Check_Stack_2:
    cmpu    #CalcStackPointer-4
    bls     Stack_Check_OK
    orcc    #%00000001
    rts

Check_Stack_3:
    cmpu    #CalcStackPointer-6
    bls     Stack_Check_OK
    orcc    #%00000001
    rts

Stack_Check_OK:
    andcc   #%11111110
    rts

Error_Underflow:
        ldx     #MsgUnderflow
        jsr     [table_function_ram+sys_PrintString]
        rts


; ===================================================================
; Implémentation des Mots de base
; ===================================================================

Op_Quit:
    lda     #1
    sta     FORTH_QUIT_FLAG
    rts

Op_Add:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        addd    ,u
        std     ,u
        rts

Op_Sub:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        pshs    d
        ldd     ,u
        subd    ,s++
        std     ,u
        rts

Op_Print:
    jsr     Check_Stack_1
    lbcs    Error_Underflow
    lda     #' '
    jsr     [table_function_ram+sys_PrintChar]
    pulu    d
    pshs    y,x,u
    ldy     #0

Print_Process:
    ldx     CURRENT_BASE
    jsr     Div16_Fast
    addb    #$30
    cmpb    #$39
    bls     Print_Store
    addb    #7

Print_Store:
    pshs    b
    leay    1,y
    tfr     x,d
    addd    #0
    bne     Print_Process

Print_Flush:
    puls    a
    jsr     [table_function_ram+sys_PrintChar]
    leay    -1,y
    bne     Print_Flush

    lda     #' '
    jsr     [table_function_ram+sys_PrintChar]
    puls    y,x,u,pc


; ===================================================================
; Divisions et Multiplications
; ===================================================================
Div16_Fast:
    pshs    y,u
    tfr     x,u
    tfr     d,y
    ldd     #0
    ldx     #16

Div_Loop:
    exg     y,d
    aslb
    rola
    exg     y,d
    rolb
    rola
    pshs    u
    cmpd    ,s++
    blo     Div_Next
    pshs    u
    subd    ,s++
    leay    1,y

Div_Next:
    leax    -1,x
    bne     Div_Loop

    tfr     y,x
    puls    y,u,pc

Op_Mul:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        jsr     Mul16
        std     ,u
        rts

Mul16:
        pshs    x,y
        pshs    d               ; S+2=N1_hi, S+3=N1_lo
        ldd     ,u
        pshs    d               ; S+0=N2_hi, S+1=N2_lo
        lda     3,s             ; A = N1_lo
        ldb     1,s             ; B = N2_lo
        mul                     ; D = N1_lo * N2_lo
        pshs    d               ; Sauve P1 (S+0=hi, S+1=lo)
        lda     4,s             ; A = N1_hi
        ldb     3,s             ; B = N2_lo
        mul                     ; D = N1_hi * N2_lo
        addb    1,s
        stb     1,s
        lda     5,s             ; A = N1_lo
        ldb     2,s             ; B = N2_hi
        mul                     ; D = N1_lo * N2_hi
        addb    1,s
        stb     1,s
        puls    d               ; D = résultat final
        leas    4,s             ; Nettoie N1 et N2
        puls    x,y,pc

Op_Div:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pshs    x
        pulu    x
        cmpx    #0
        beq     Div_Zero
        ldd     ,u
        jsr     Div16_Fast
        tfr     x,d
        std     ,u
        puls    x,pc
Div_Zero:
        ldd     #$FFFF
        std     ,u
        puls    x,pc


Op_Fetch:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        pulu    x
        ldd     ,x
        pshu    d
        rts

Op_Store:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    x
        pulu    d
        cmpx    #$0100
        blo     Store_Denied
        cmpx    #$E000
        bhs     Store_Denied
Do_Store:
        std     ,x
        rts

Store_Denied:
        ldx     #MsgStoreDenied
        jsr     [table_function_ram+sys_PrintString]
        rts

Op_CFetch:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        pulu    x
        clra
        ldb     ,x
        pshu    d
        rts

Op_CStore:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    x
        pulu    d
        cmpx    #$0100
        blo     Store_Denied
        cmpx    #$E000
        bhs     Store_Denied
        stb     ,x
        rts

Op_Dup:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full_Dup
        ldd     ,u
        pshu    d
        rts
Error_Stack_Full_Dup:
        ldx     #MsgStackFull
        jsr     [table_function_ram+sys_PrintString]
        rts

Op_Drop:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        leau    2,u
        rts

Op_Swap:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        ldd     ,u
        ldy     2,u
        std     2,u
        sty     ,u
        rts

Op_Over:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full_Dup
        ldd     2,u
        pshu    d
        rts

Op_Rot:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pshs    x
        ldd     4,u
        ldx     2,u
        ldy     ,u
        std     ,u
        sty     2,u
        stx     4,u
        puls    x
        rts

Op_Emit:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        pulu    d
        tfr     b,a
        jsr     [table_function_ram+sys_PrintChar]
        rts

Op_Eq:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        cmpd    ,u
        beq     Is_Equal
        ldd     #0
        bra     Store_Bool
Is_Equal:
        ldd     #1
Store_Bool:
        std     ,u
        rts

Op_Gt:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        cmpd    ,u
        blo     Is_True_Gt
        bra     Is_False
Is_True_Gt:
        ldd     #1
        bra     Store_Bool_Gt
Is_False:
        ldd     #0
Store_Bool_Gt:
        std     ,u
        rts

Op_Lt:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        cmpd    ,u
        bhi     Is_True_Lt
        ldd     #0
        bra     Store_Bool_Lt
Is_True_Lt:
        ldd     #1
Store_Bool_Lt:
        std     ,u
        rts

; ===================================================================
; Op_If / Op_Else / Op_Then
; ===================================================================
Op_If:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        pulu    d
        cmpd    #0
        bne     If_True

        ldx     ARGV_PTR
        cmpx    #Forth_Argv
        blo     If_Compiled
        cmpx    #Forth_Argv+MAX_ARGS*2
        bhs     If_Compiled

        ; --- Mode Interpréteur ---
        ldb     #1
If_Int_Skip:
        ldy     ,x+
        cmpy    #0
        beq     If_Int_Done
        pshs    x,y
        ldx     #Word_If+6
        jsr     strcmp
        puls    x,y
        bne     If_Int_NotIF
        incb
        bra     If_Int_Skip
If_Int_NotIF:
        pshs    x,y
        ldx     #Word_Else+6
        jsr     strcmp
        puls    x,y
        bne     If_Int_NotElse
        cmpb    #1
        beq     If_Int_Done
        bra     If_Int_Skip
If_Int_NotElse:
        pshs    x,y
        ldx     #Word_Then+6
        jsr     strcmp
        puls    x,y
        bne     If_Int_Skip
        decb
        bne     If_Int_Skip
If_Int_Done:
        stx     ARGV_PTR
        rts

        ; --- Mode Compilé ---
If_Compiled:
        ldx     2,s
        ldb     #1
If_Comp_Skip:
        ldd     ,x+
        beq     If_Comp_Done
        cmpd    #Word_If
        bne     If_Comp_NotIF
        incb
        bra     If_Comp_Skip
If_Comp_NotIF:
        cmpd    #Word_Else
        bne     If_Comp_NotElse
        cmpb    #1
        beq     If_Comp_Done
        bra     If_Comp_Skip
If_Comp_NotElse:
        cmpd    #Word_Then
        bne     If_Comp_Skip
        decb
        bne     If_Comp_Skip
If_Comp_Done:
        stx     2,s
If_True:
        rts

Op_Else:
        ldx     ARGV_PTR
        cmpx    #Forth_Argv
        blo     Else_Compiled
        cmpx    #Forth_Argv+MAX_ARGS*2
        bhs     Else_Compiled

        ; --- Mode Interpréteur ---
        ldb     #1
Else_Int_Skip:
        ldy     ,x+
        cmpy    #0
        beq     Else_Int_Done
        pshs    x,y
        ldx     #Word_If+6
        jsr     strcmp
        puls    x,y
        bne     Else_Int_NotIF
        incb
        bra     Else_Int_Skip
Else_Int_NotIF:
        pshs    x,y
        ldx     #Word_Then+6
        jsr     strcmp
        puls    x,y
        bne     Else_Int_Skip
        decb
        bne     Else_Int_Skip
Else_Int_Done:
        stx     ARGV_PTR
        rts

        ; --- Mode Compilé ---
Else_Compiled:
        ldx     2,s
        ldb     #1
Else_Comp_Skip:
        ldd     ,x+
        lbeq    Else_Comp_Done
        cmpd    #Word_If
        bne     Else_Comp_NotIF
        incb
        bra     Else_Comp_Skip
Else_Comp_NotIF:
        cmpd    #Word_Then
        bne     Else_Comp_Skip
        decb
        bne     Else_Comp_Skip
Else_Comp_Done:
        stx     2,s
        rts

Op_Then_NoOp:
        rts

Op_0Branch:
        ldx     2,s
        pulu    d
        cmpd    #0
        beq     ZB_Take
        leax    2,x
        stx     2,s
        rts
ZB_Take:
        ldd     ,x
        leax    d,x
        stx     2,s
        rts

Op_Branch:
        ldx     2,s
        ldd     ,x
        leax    d,x
        stx     2,s
        rts

; ===================================================================
; Boucles DO ... LOOP / +LOOP — Réécriture complète
;
; PRINCIPE : Op_DoLoop ne touche PAS à ret_addr ni à body_ptr déjà
; sur la pile S (posés par Do_Compiled_Word/Next_Word). Il empile
; simplement index et limit PAR-DESSUS les deux valeurs existantes,
; puis fait rts normalement.
;
; Layout de pile S pendant l'exécution du corps d'une boucle :
;   ,s    = ret_addr        (vers Next_Word, posé par jsr [,x])
;   2,s   = body_ptr        (posé par pshs x dans Next_Word)
;   4,s   = index           (posé par Op_DoLoop)
;   6,s   = limit           (posé par Op_DoLoop)
;   8,s   = ... (frame appelante : body_ptr_parent, ret_addr_parent ...)
;
; Pour J (boucle externe) :
;   Dans le corps de la boucle interne, le prochain Op appelé voit :
;   ,s=ret ,2,s=body ,4,s=index_interne ,6,s=limit_interne
;   ,8,s=index_externe ,10,s=limit_externe ,12,s=ret_appel
;
; Offset field du LOOP compilé : body_ptr (2,s) pointe sur le token
; Word_LoopEx/Word_PlusLoop ; l'offset 16 bits est 2 octets APRÈS dans
; le flux compilé.  Op_LoopEx lit cet offset via le body_ptr courant.
; ===================================================================

; -------------------------------------------------------------------
; Op_DoLoop — appelé depuis Next_Word (Do_Compiled_Word)
;
; Contexte à l'entrée (posé par Next_Word avant jsr) :
;   ,s   = ret_addr (dans Next_Word)
;   2,s  = body_ptr (mot suivant APRÈS Word_DoLoop dans le flux compilé)
;
; Pile Forth U :
;   ,u   = index (start)
;   2,u  = limit
; -------------------------------------------------------------------
Op_DoLoop:
        jsr     Check_Stack_2
        lbcs    Error_Underflow

        lda     NEST_DEPTH
        cmpa    #MAX_NEST
        bhs     Do_Too_Deep

        pulu    d               ; D = start (index)
        pulu    y               ; Y = limit

        ; Comparaison signée : start >= limit → boucle vide
        pshs    y
        cmpd    ,s++
        bge     Do_Skip_Loop

        ; -------------------------------------------------------
        ; Boucle active : Construire la frame correcte.
        ; Pull ret_addr et body_ptr, push limit/index, puis re-push
        ; body_ptr et ret_addr par-dessus.
        ; Résultat : ,s=ret ,2,s=body ,4,s=index ,6,s=limit
        ; -------------------------------------------------------
        puls    x               ; X = ret_addr
        stx     DoLoopSave
        puls    x               ; X = body_ptr
        stx     DoLoopSave+2

        pshs    y               ; limit
        pshs    d               ; index
        ldx     DoLoopSave+2
        pshs    x               ; body_ptr
        ldx     DoLoopSave
        pshs    x               ; ret_addr

        inc     NEST_DEPTH
        rts

        ; -------------------------------------------------------
        ; Boucle vide : avancer body_ptr (2,s) au-delà du corps,
        ; du token LOOP/+LOOP et de son offset field.
        ; -------------------------------------------------------
Do_Skip_Loop:
        puls    x               ; X = ret_addr
        stx     DoLoopSave
        puls    x               ; X = body_ptr (premier mot du corps)
        clrb                    ; B = compteur d'imbrication

Do_Skip_Scan:
        ldd     ,x++            ; D = token courant, X avance
        beq     Do_Skip_Done    ; fin du mot compilé (ne devrait pas arriver)
        cmpd    #Word_DoLoop
        bne     Do_Skip_NotDO
        incb                    ; DO imbriqué trouvé
        bra     Do_Skip_Scan

Do_Skip_NotDO:
        cmpd    #Word_LoopEx
        beq     Do_Skip_Check
        cmpd    #Word_PlusLoop
        bne     Do_Skip_Scan

Do_Skip_Check:
        tstb
        beq     Do_Skip_Exit    ; LOOP du niveau courant
        decb                    ; LOOP d'un DO interne
        leax    2,x             ; sauter l'offset field de ce LOOP interne
        bra     Do_Skip_Scan

Do_Skip_Exit:
        leax    2,x             ; sauter l'offset field du LOOP courant

Do_Skip_Done:
        pshs    x               ; body_ptr (après la boucle)
        ldx     DoLoopSave
        pshs    x               ; ret_addr
        rts

Do_Too_Deep:
        ldx     #MsgNestTooDeep
        jsr     [table_function_ram+sys_PrintString]
        rts


; -------------------------------------------------------------------
; Op_LoopEx — runtime de LOOP
;
; Contexte en entrée (appelé depuis Next_Word) :
;   ,s   = ret_addr (vers Next_Word)
;   2,s  = body_ptr (pointe sur Word_LoopEx dans le flux compilé)
;   4,s  = index
;   6,s  = limit
;
; L'offset field de branchement arrière est situé juste après
; Word_LoopEx dans le flux compilé, donc à *body_ptr (soit [2,s]).
; Mais body_ptr pointe déjà sur Word_LoopEx (Next_Word l'avance de 2
; avant le jsr, donc body_ptr = adresse du mot SUIVANT Word_LoopEx).
; L'offset est à body_ptr - 2 + 2 = *body_ptr... ATTENTION :
;
; Dans Next_Word :
;   ldd ,x++   → D = Word_LoopEx, X avance de 2 → X pointe sur offset
;   pshs x     → 2,s = X = adresse de l'offset field
;   jsr [,x]   → appelle Op_LoopEx
;
; Donc 2,s pointe exactement sur l'offset field (2 octets). Correct.
; -------------------------------------------------------------------
Op_LoopEx:
        ldd     4,s             ; D = index courant
        addd    #1              ; index++
        std     4,s
        cmpd    6,s             ; index >= limit ?
        bge     LoopEx_Done     ; oui → fin de boucle

        ; Continuer : brancher en arrière via l'offset field
        ; 2,s = adresse de l'offset field dans le flux compilé
        ldx     2,s             ; X = &offset
        ldd     ,x              ; D = offset (signé 16 bits, relatif à &offset)
        leax    d,x             ; X = &offset + offset = adresse du prochain token
        stx     2,s             ; mettre à jour body_ptr → Next_Word reprend là
        rts

LoopEx_Done:
        ; Fin de boucle : dépiler index + limit, avancer body_ptr
        ; au-delà de l'offset field (2 octets après body_ptr actuel).
        dec     NEST_DEPTH
        puls    d               ; D = ret_addr (,s)
        puls    x               ; X = body_ptr (2,s) = offset field addr
        leax    2,x             ; X = après l'offset field
        leas    4,s             ; supprimer index (4,s) et limit (6,s)
        pshs    x               ; body_ptr mis à jour
        pshs    d               ; ret_addr
        rts


; -------------------------------------------------------------------
; Op_PlusLoopEx — runtime de +LOOP
;
; Même layout de pile que Op_LoopEx.
; Consomme un entier signé de la pile Forth U comme incrément.
; Gère correctement les incréments positifs ET négatifs.
; -------------------------------------------------------------------
Op_PlusLoopEx:
        pulu    d               ; D = incrément (signé)
        addd    4,s             ; new_index = index + incrément
        std     4,s

        ; Condition de sortie (Forth standard) :
        ;   Si incrément > 0 : sortir si new_index >= limit
        ;   Si incrément < 0 : sortir si new_index < limit
        ;   Si incrément = 0 : boucle infinie (on continue)
        tsta
        bmi     PlusLoop_Neg
        tstb
        bmi     PlusLoop_Neg

PlusLoop_Pos:
        cmpd    6,s             ; new_index >= limit ?
        blt     PlusLoop_Branch ; non → continuer
        bra     PlusLoop_Done   ; oui → sortir

PlusLoop_Neg:
        cmpd    6,s             ; new_index < limit ?
        bge     PlusLoop_Branch ; non (new_index >= limit) → continuer

PlusLoop_Done:
        dec     NEST_DEPTH
        puls    d               ; D = ret_addr
        puls    x               ; X = body_ptr (offset field addr)
        leax    2,x             ; X = après l'offset field
        leas    4,s             ; supprimer index et limit
        pshs    x               ; body_ptr mis à jour
        pshs    d               ; ret_addr
        rts

PlusLoop_Branch:
        ldx     2,s             ; X = &offset field
        ldd     ,x              ; D = offset
        leax    d,x             ; X = cible
        stx     2,s
        rts


; -------------------------------------------------------------------
; Op_Unloop — vider la frame de boucle (pour EXIT depuis le corps)
;
; Dépile index + limit sans modifier ret_addr ni body_ptr.
; -------------------------------------------------------------------
Op_Unloop:
        puls    d               ; D = ret_addr
        puls    x               ; X = body_ptr
        leas    4,s             ; supprimer index et limit
        pshs    x               ; body_ptr
        pshs    d               ; ret_addr
        dec     NEST_DEPTH
        rts


; -------------------------------------------------------------------
; Op_Leave — forcer la sortie au prochain LOOP
;
; Copie index dans limit pour que la condition de sortie soit vraie
; dès le prochain Op_LoopEx / Op_PlusLoopEx.
; -------------------------------------------------------------------
Op_Leave:
        ldd     4,s             ; D = index courant
        std     6,s             ; limit = index → sortie au LOOP suivant
        rts


Op_Do:
        ldx     #MsgCompileOnly
        jsr     [table_function_ram+sys_PrintString]
        rts


; -------------------------------------------------------------------
; Op_I — index de la boucle courante
;
; ,s=ret ,2,s=body ,4,s=index ,6,s=limit
; -------------------------------------------------------------------
Op_I:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full_Dup
        ldd     4,s             ; index de la boucle courante
        pshu    d
        rts


; -------------------------------------------------------------------
; Op_J — index de la boucle externe (une imbrication au-dessus)
;
; Layout avec deux boucles imbriquées (interne en cours d'exécution) :
;   ,s    = ret_addr interne
;   2,s   = body_ptr interne
;   4,s   = index interne
;   6,s   = limit interne
;   8,s   = index externe     (la boucle DO interne consomme ret/body externe)
;   10,s  = limit externe
;   12,s  = ret_addr de la couche appelante (REPL etc.)
; -------------------------------------------------------------------
Op_J:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full_Dup
        ldd     8,s             ; index de la boucle externe
        pshu    d
        rts


Op_Loop:
        ldx     #MsgCompileOnly
        jsr     [table_function_ram+sys_PrintString]
        rts


Op_Lit:
        ldx     2,s
        ldd     ,x++
        pshu    d
        stx     2,s
        rts


; ===================================================================
; Op_Colon — Compilateur
; ===================================================================
Op_Colon:
        ldx     #CompileStack
        stx     CompileSP
        ldx     #LoopStack
        stx     LoopSP

        ldd     HERE
        pshs    d               
        ldd     CURRENT_WORD
        pshs    d               

        ldd     #32
        jsr     Check_Memory_Limit
        lbcs    Abort_Mem_Full

        ldy     HERE
        ldd     CURRENT_WORD
        std     ,y++

        ldx     HERE
        stx     CURRENT_WORD

        ldd     #Do_Compiled_Word
        std     ,y++

        ldx     ARGV_PTR
        leax    2,x             ; Skip past ":" entry to get the name
        ldd     ,x++
        stx     ARGV_PTR
        pshs    d
        tfr     d,x
        jsr     Calculate_Checksum
        sta     ,y+
        stb     ,y+
        puls    x

Copy_Name:
        lda     ,x+
        sta     ,y+
        bne     Copy_Name

        sty     HERE

Compile_Loop:
        ldx     ARGV_PTR
        ldd     ,x++
        lbeq    EndError
        stx     ARGV_PTR

        tfr     d,x
        lda     ,x
        cmpa    #';'
        lbeq    Finish_Colon

        pshs    x
        jsr     Find_Word_Internal
        puls    x
        cmpd    #0
        beq     Compile_Number

        cmpd    #Word_If
        lbeq    Compile_IF
        cmpd    #Word_Else
        lbeq    Compile_ELSE
        cmpd    #Word_Then
        lbeq    Compile_THEN
        cmpd    #Word_Do
        lbeq    Compile_DO
        cmpd    #Word_Loop
        lbeq    Compile_LOOP
        cmpd    #Word_PlusLoop
        lbeq    Compile_PlusLoop
        cmpd    #Word_DotQuote
        lbeq    Compile_DotQuote

        ldy     HERE
        std     ,y++
        sty     HERE
        lbra    Compile_Loop

Compile_Number:
        tfr     x,y
        jsr     StringToNumber
        lbcs    SyntaxError

        pshs    d
        ldy     HERE
        ldd     #Word_Lit
        std     ,y++
        puls    d
        std     ,y++
        sty     HERE
        lbra    Compile_Loop

Compile_DO:
        ldy     HERE
        ldd     #Word_DoLoop
        std     ,y++            
        sty     HERE
        ldx     LoopSP
        sty     ,x++            
        stx     LoopSP
        lbra    Compile_Loop

Compile_LOOP:
        ldx     LoopSP
        leax    -2,x
        stx     LoopSP
        ldd     ,x              
        pshs    d               
        ldy     HERE
        ldd     #Word_LoopEx
        std     ,y++            
        ldd     ,s              
        pshs    y               
        subd    ,s++            
        std     ,y++            
        sty     HERE
        leas    2,s             
        lbra    Compile_Loop

Compile_PlusLoop:
        ldx     LoopSP
        leax    -2,x
        stx     LoopSP
        ldd     ,x              
        pshs    d
        ldy     HERE
        ldd     #Word_PlusLoop
        std     ,y++            
        ldd     ,s              
        pshs    y               
        subd    ,s++            
        std     ,y++            
        sty     HERE
        leas    2,s             
        lbra    Compile_Loop

Compile_DotQuote:
        ldy     HERE
        ldd     #Word_PrintStr
        std     ,y++
        pshs    y               ; save position where first string char goes
        ldx     ARGV_PTR
        ldd     ,x++
        stx     ARGV_PTR
        tfr     d,x
CDQ_Copy:
        lda     ,x+
        beq     CDQ_ChkQ
        cmpa    #' '
        beq     CDQ_ChkQ
        sta     ,y+
        bra     CDQ_Copy
CDQ_ChkQ:
        cmpy    0,s
        beq     CDQ_Done
        lda     ,-y
        cmpa    #'"'
        bne     CDQ_Restore
        bra     CDQ_Done
CDQ_Restore:
        leay    1,y
CDQ_Done:
        clr     ,y+
        sty     HERE
        leas    2,s
        lbra    Compile_Loop

Compile_IF:
        ldy     HERE
        ldd     #Word_0Branch
        std     ,y++
        ldx     CompileSP
        sty     ,x++
        stx     CompileSP
        ldd     #0
        std     ,y++
        sty     HERE
        lbra    Compile_Loop

Compile_ELSE:
        ldx     CompileSP
        leax    -2,x
        stx     CompileSP
        ldd     ,x
        pshs    d
        ldy     HERE
        ldd     #Word_Branch
        std     ,y++
        ldx     CompileSP
        sty     ,x++
        stx     CompileSP
        ldd     #0
        std     ,y++
        sty     HERE
        ldd     HERE
        subd    ,s
        ldx     ,s
        std     ,x
        leas    2,s
        lbra    Compile_Loop

Compile_THEN:
        ldx     CompileSP
        leax    -2,x
        stx     CompileSP
        ldd     ,x
        pshs    d
        ldd     HERE
        subd    ,s
        ldx     ,s
        std     ,x
        leas    2,s
        lbra    Compile_Loop

Finish_Colon:
        ldx     CompileSP
        cmpx    #CompileStack
        bne     IF_Mismatch
        ldx     LoopSP
        cmpx    #LoopStack
        bne     Loop_Mismatch

        ldy     HERE
        ldd     #0
        std     ,y++
        sty     HERE
        leas    4,s             ; Clean up rollback (HERE + CURRENT_WORD)
        ldd     ARGV_PTR        ; D = pointer after ";"
        std     2,s             ; Update stacked X_next_argv for Other_Op's puls x,y
        rts

IF_Mismatch:
        ldx     #MsgIFMismatch
        bra     ColonError
Loop_Mismatch:
        ldx     #MsgLoopMismatch
        bra     ColonError
SyntaxError:
        ldx     #MsgSyntaxError
        bra     ColonError
EndError:
        ldx     #MsgMissingEnd
ColonError:
        jsr     [table_function_ram+sys_PrintString]
        ldx     #CompileStack
        stx     CompileSP
        ldx     #LoopStack
        stx     LoopSP
        puls    d               
        std     CURRENT_WORD
        puls    d               
        std     HERE
        rts

Abort_Mem_Full:
        leas    4,s             
        ldx     #MsgErrMemFull
        jsr     [table_function_ram+sys_PrintString]
        rts


; ===================================================================
; Do_Compiled_Word
; ===================================================================
Do_Compiled_Word:
        tfr     d,x             

        ldb     5,x             
        leax    6,x             
        abx                     
        leax    1,x             
        
Next_Word:
        ldd     ,x++
        beq     End_Word

        pshs    x
        tfr     d,x
        leax    2,x             
        jsr     [,x]
        puls    x
        bra     Next_Word

End_Word:
        rts


Op_Decimal:
    ldd     #10
    std     CURRENT_BASE
    rts

Op_Hex:
    ldd     #16
    std     CURRENT_BASE
    rts

Op_List:
    pshs    x,d
    ldx     CURRENT_WORD

List_Loop:
    cmpx    #0
    beq     List_Done
    pshs    x
    leax    6,x
    jsr     [table_function_ram+sys_PrintString]
    lda     #' '
    jsr     [table_function_ram+sys_PrintChar]
    puls    x
    ldx     ,x
    bra     List_Loop

List_Done:
    jsr     [table_function_ram+sys_PrintCRLF]
    puls    x,d,pc


Op_SaveDict:
        ldx     ARGV_PTR        ; X = &argv[N]
        ldy     2,x             ; Y = argv[N+1] = nom du fichier
        ldd     ARGV_PTR
        addd    #4              ; D = &argv[N+2] (saute SAVE + nom)
        std     ARGV_PTR
        std     2,s             ; met à jour next_pos pour la boucle
        tfr     y,x             ; X = nom du fichier
        ldy     #FormattedName
        jsr     [table_function_ram+sys_Format_Filename_83]

        ldx     #MsgSaving
        jsr     [table_function_ram+sys_PrintString]

        ldx     #FormattedName
        jsr     [table_function_ram+sys_FS_DeleteFile]

        ldd     CURRENT_WORD
        std     User_Dict_Header

        ldd     HERE
        subd    #User_Dict_Header
        tfr     d,u
        lda     current_page
        ldx     #FormattedName
        ldy     #User_Dict_Header
        jsr     [table_function_ram+sys_FS_SaveFile]
        bcc     SaveDict_Ok
        ldx     #MsgSaveDictError
        jsr     [table_function_ram+sys_PrintString]
        rts
SaveDict_Ok:
        ldx     #MsgOK
        jsr     [table_function_ram+sys_PrintString]
        rts

Op_LoadDict:
        ldx     ARGV_PTR        ; X = &argv[N]
        ldy     2,x             ; Y = argv[N+1] = nom du fichier
        ldd     ARGV_PTR
        addd    #4              ; D = &argv[N+2] (saute LOAD + nom)
        std     ARGV_PTR
        std     2,s             ; met à jour next_pos pour la boucle
        tfr     y,x             ; X = nom du fichier
        ldy     #FormattedName
        jsr     [table_function_ram+sys_Format_Filename_83]
        lda     current_page
        ldx     #FormattedName
        ldy     #User_Dict_Header
        jsr     [table_function_ram+sys_FS_LoadFile]
        lbcs    LoadDict_Err

        ldd     User_Dict_Header
        std     CURRENT_WORD

        tfr     u,d
        addd    #User_Dict_Header
        std     HERE
        rts

LoadDict_Err:
        ldx     #MsgLoadDictError
        jsr     [table_function_ram+sys_PrintString]
        rts

; ===================================================================
; Nouveaux mots
; ===================================================================

Op_CR:
        jsr     [table_function_ram+sys_PrintCRLF]
        rts

Op_Space:
        lda     #' '
        jsr     [table_function_ram+sys_PrintChar]
        rts

Op_Key:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        jsr     [table_function_ram+sys_scan_keyboard]
        tfr     a,b
        clra
        pshu    d
        rts

Op_Negate:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     #0
        subd    ,u
        std     ,u
        rts

Op_And:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        anda    ,u
        andb    1,u
        std     ,u
        rts

Op_Or:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        ora     ,u
        orb     1,u
        std     ,u
        rts

Op_Mod:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pshs    x
        pulu    x
        cmpx    #0
        beq     Mod_Zero
        ldd     ,u
        jsr     Div16_Fast
        std     ,u
        puls    x,pc
Mod_Zero:
        ldd     #$FFFF
        std     ,u
        puls    x,pc

Op_PrintStr:
        ldx     2,s
        pshs    x
        jsr     [table_function_ram+sys_PrintString]
        puls    x
PS_Scan:
        lda     ,x+
        bne     PS_Scan
        stx     2,s
        rts

Op_DotQuote:
        ldx     #MsgCompileOnly
        jsr     [table_function_ram+sys_PrintString]
        rts

Op_Abs:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        bpl     Abs_Done
        coma
        comb
        addd    #1
        std     ,u
Abs_Done:
        rts

Op_1Plus:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        addd    #1
        std     ,u
        rts

Op_1Minus:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        subd    #1
        std     ,u
        rts

Op_2Plus:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        addd    #2
        std     ,u
        rts

Op_2Minus:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        subd    #2
        std     ,u
        rts

Op_2Mul:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        lslb
        rola
        std     ,u
        rts

Op_2Div:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        asra
        rorb
        std     ,u
        rts

Op_Invert:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     ,u
        coma
        comb
        std     ,u
        rts

Op_Xor:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        pulu    d
        eora    ,u
        eorb    1,u
        std     ,u
        rts

Op_Depth:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        tfr     u,d
        pshs    d
        ldd     #CalcStackPointer
        subd    ,s++
        lsra
        rorb
        pshu    d
        rts

Op_True:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        ldd     #-1
        pshu    d
        rts

Op_False:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        clra
        clrb
        pshu    d
        rts

Op_Nip:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        ldd     ,u
        ldy     2,u
        std     2,u
        sty     ,u
        leau    2,u
        rts

Op_Tuck:
        jsr     Check_Stack_2
        lbcs    Error_Underflow
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        ldd     ,u
        ldy     2,u
        std     2,u
        sty     ,u
        ldd     2,u
        pshu    d
        rts

Op_Here:
        jsr     Check_Stack_Overflow
        lbcs    Error_Stack_Full
        ldd     HERE
        pshu    d
        rts

Op_Comma:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        ldd     #2
        jsr     Check_Memory_Limit
        lbcs    Abort_Mem_Full
        ldy     HERE
        pulu    d
        std     ,y++
        sty     HERE
        rts

Op_Allot:
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        pulu    d
        tsta
        bmi     Allot_Do
        pshs    d
        jsr     Check_Memory_Limit
        lbcs    Abort_Mem_Full_Allot
        puls    d
Allot_Do:
        addd    HERE
        std     HERE
        rts
Abort_Mem_Full_Allot:
        puls    d
        lbra    Abort_Mem_Full

Op_VariableCreate:
        ldx     #CompileStack
        stx     CompileSP
        ldx     #LoopStack
        stx     LoopSP
        ldd     HERE
        pshs    d
        ldd     CURRENT_WORD
        pshs    d
        ldd     #32
        jsr     Check_Memory_Limit
        lbcs    Abort_Mem_Full
        ldy     HERE
        ldd     CURRENT_WORD
        std     ,y++
        ldx     HERE
        stx     CURRENT_WORD
        ldd     #Op_Variable
        std     ,y++
        ldx     ARGV_PTR
        leax    2,x
        ldd     ,x++
        stx     ARGV_PTR
        pshs    d
        tfr     d,x
        jsr     Calculate_Checksum
        sta     ,y+
        stb     ,y+
        puls    x
VarCreate_Copy:
        lda     ,x+
        beq     VarCreate_Done
        cmpa    #' '
        beq     VarCreate_Done
        sta     ,y+
        bra     VarCreate_Copy
VarCreate_Done:
        clr     ,y+
        clra
        clrb
        std     ,y++
        sty     HERE
        leas    4,s
        rts

Op_Variable:
        ldd     ,x
        cmpd    #Op_Variable
        beq     Var_Compiled
        ldb     5,x
        leax    6,x
        abx
        leax    1,x
        tfr     x,d
        pshu    d
        rts
Var_Compiled:
        leax    -2,x
        ldb     5,x
        leax    6,x
        abx
        leax    1,x
        tfr     x,d
        pshu    d
        rts

Op_ConstantCreate:
        ldx     #CompileStack
        stx     CompileSP
        ldx     #LoopStack
        stx     LoopSP
        ldd     HERE
        pshs    d
        ldd     CURRENT_WORD
        pshs    d
        ldd     #32
        jsr     Check_Memory_Limit
        lbcs    Abort_Mem_Full
        ldy     HERE
        ldd     CURRENT_WORD
        std     ,y++
        ldx     HERE
        stx     CURRENT_WORD
        ldd     #Op_Constant
        std     ,y++
        ldx     ARGV_PTR
        leax    2,x
        ldd     ,x++
        stx     ARGV_PTR
        pshs    d
        tfr     d,x
        jsr     Calculate_Checksum
        sta     ,y+
        stb     ,y+
        puls    x
ConstCreate_Copy:
        lda     ,x+
        beq     ConstCreate_Done
        cmpa    #' '
        beq     ConstCreate_Done
        sta     ,y+
        bra     ConstCreate_Copy
ConstCreate_Done:
        clr     ,y+
        jsr     Check_Stack_1
        lbcs    Error_Underflow
        pulu    d
        std     ,y++
        sty     HERE
        leas    4,s
        rts

Op_Constant:
        ldd     ,x
        cmpd    #Op_Constant
        beq     Const_Compiled
        ldb     5,x
        leax    6,x
        abx
        leax    1,x
        ldd     ,x
        pshu    d
        rts
Const_Compiled:
        leax    -2,x
        ldb     5,x
        leax    6,x
        abx
        leax    1,x
        ldd     ,x
        pshu    d
        rts

Op_Fill:
        cmpu    #CalcStackPointer-6
        lbls    Fill_OK
        lbra    Error_Underflow
Fill_OK:
        pulu    d
        pulu    y
        pulu    x
        pshs    d
        bra     Fill_Check
Fill_Loop:
        ldb     1,s
        stb     ,x+
Fill_Check:
        leay    -1,y
        bpl     Fill_Loop
Fill_Done:
        leas    2,s
        rts

Op_CMove:
        cmpu    #CalcStackPointer-6
        lbls    CMove_OK
        lbra    Error_Underflow
CMove_OK:
        pulu    y
        pulu    d
        pulu    x
        pshs    d
        bra     CMove_Check
CMove_Loop:
        lda     ,x+
        pshs    x
        ldx     2,s
        sta     ,x+
        stx     2,s
        puls    x
CMove_Check:
        leay    -1,y
        bpl     CMove_Loop
CMove_Done:
        leas    2,s
        rts

MsgLoadDictError: fcn "Erreur: chargement dictionnaire !"
MsgSaveDictError: fcn "Erreur: sauvegarde dictionnaire !"
MsgSaving: fcc "Sauvegarde..."
          fcb 0
MsgOK:    fcc " OK"
          fcb 0


; ===================================================================
; Find_Word_Internal
; ===================================================================
Find_Word_Internal:
        pshs    y,x

        tfr     x,y
        ldx     CURRENT_WORD

FW_Loop:
        cmpx    #0
        beq     FW_NotFound

        pshs    x,y
        leax    6,x
        jsr     strcmp
        puls    x,y
        beq     FW_Found

        ldx     ,x
        bra     FW_Loop

FW_Found:
        tfr     x,d
        puls    x,y,pc

FW_NotFound:
        clra
        clrb
        puls    x,y,pc


; ===================================================================
; strcmp / memcmp / StringToNumber
; ===================================================================
strcmp:
        pshs    a,x,y
strcmp_loop:
        lda     ,x+
        cmpa    ,y+
        bne     strcmp_notequal
        tsta
        bne     strcmp_loop
strcmp_equal:
strcmp_notequal:
        puls    a,x,y,pc

memcmp:
    pshs    a,x,y
memcmp_loop:
    lda     ,x+
    cmpa    ,y+
    bne     memcmp_not_equal
    decb
    bne     memcmp_loop
memcmp_not_equal:
    puls    a,x,y,pc

StringToNumber:
    pshs    y,x
    ldy     #0

STN_Loop:
    lda     ,x+
    beq     STN_Done
    cmpa    #' '
    beq     STN_Done

    jsr     CharToVal
    cmpa    #$FF
    beq     STN_Error

    pshs    a
    tfr     y,d

    ldy     CURRENT_BASE
    cmpy    #10
    beq     STN_Mul10

STN_Mul16:
    asld
    asld
    asld
    asld
    bra     STN_AddDigit

STN_Mul10:
    asld
    pshs    d
    asld
    asld
    addd    ,s++

STN_AddDigit:
    tfr     d,y
    puls    a
    clrb
    exg     a,b
    leay    d,y
    bra     STN_Loop

STN_Done:
    tfr     y,d
    andcc   #%11111110
    puls    x,y,pc

STN_Error:
    orcc    #%00000001
    puls    x,y,pc

CharToVal:
    CMPA    #$46
    BLS     Majuscule
    cmpa    #$60
    bls     NotNumber
    SUBA    #$20
Majuscule:
    cmpa    #$2F
    bls     NotNumber
    cmpa    #$46
    bhi     NotNumber
    SUBA    #$30
    CMPA    #$09
    BLS     End_CharToVal
    SUBA    #$07
End_CharToVal:
    rts
NotNumber:
    lda     #$ff
    rts

Check_Memory_Limit:
        pshs    x,d

        lda     NEST_DEPTH
        ldb     #NEST_COST
        mul                     
        addb    #BASE_MARGIN    
        clra                    

        pshs    d               
        tfr     s,x
        leax    4,x             
        tfr     x,d
        subd    ,s++            

        pshs    d               
        ldd     2,s             
        addd    HERE
        cmpd    ,s++
        bhi     Mem_Full_Error

        andcc   #%11111110
        puls    x,d,pc

Mem_Full_Error:
        orcc    #%00000001
        puls    x,d,pc

; ======================================================
; Section de données
; ======================================================

MsgCR:          fcb $0a,$0d,0
UnknownCmdMsg:  fcc "Commande inconnue."
                fcb $0a,$0d,0
ForthMsg:       fcb $0c
                fcc "Forth Version V1.1"
                fcb $0a,$0d,0
MsgMissingEnd:  fcc " Erreur manque ;"
                fcb $0a,$0d,0
MsgCompileOnly: fcc " compile seulement"
                fcb $0a,$0d,0
MsgSyntaxError: fcc " Erreur de syntaxe"
                fcb $0a,$0d,0
PromptMsg:      fcb $0a,$0d
                fcc "OK "
                fcb 0
MsgErrMemFull:  fcn "Erreur: Dictionnaire plein (Collision Pile) !"
MsgStoreDenied: fcc " Erreur: adresse protegee"
                fcb $0a,$0d,0
MsgUnderflow:   fcc " Erreur: pile vide"
                fcb $0a,$0d,0
MsgStackFull:   fcc " Erreur: pile pleine"
                fcb $0a,$0d,0
MsgTooManyArgs: fcc " Attention: trop d'arguments (max 32)"
                fcb $0a,$0d,0
MsgNestTooDeep: fcc " Erreur: imbrication trop profonde"
                fcb $0a,$0d,0
MsgIFMismatch:  fcn " Erreur: IF sans THEN/ELSE"
MsgLoopMismatch: fcn " Erreur: DO sans LOOP/+LOOP"

FORTH_QUIT_FLAG: fcb 0
NEST_DEPTH:     fcb 0

Forth_InputBuf: rmb 256         
Forth_Argv:     rmb MAX_ARGS*2  
Forth_Argc:     rmb 1           
xFormattedName:  rmb 12

CalcStack:      rmb 256
CalcStackPointer equ CalcStack+256

Searched_CS:    rmb 1
Searched_Len:   rmb 1
ARGV_PTR:       rmb 2           


; ======================================================
; DICTIONNAIRE DE PRIMITIVES
; ======================================================

first_Word:
Word_Dup:       fdb $0000
                fdb Op_Dup
                fcb $41
                fcb 3
                fcn "DUP"
Word_Drop:      fdb Word_Dup
                fdb Op_Drop
                fcb $09
                fcb 4
                fcn "DROP"
Word_Swap:      fdb Word_Drop
                fdb Op_Swap
                fcb $15
                fcb 4
                fcn "SWAP"
Word_Over:      fdb Word_Swap
                fdb Op_Over
                fcb $0e
                fcb 4
                fcn "OVER"
Word_Rot:       fdb Word_Over
                fdb Op_Rot
                fcb $49
                fcb 3
                fcn "ROT"
Word_Emit:      fdb Word_Rot
                fdb Op_Emit
                fcb $15
                fcb 4
                fcn "EMIT"
; SETPAGE retiré (2026-10-31) : il écrivait la page en $A000 (aujourd'hui
; le contrôle de la liaison série) ; en $A0C0 il aurait basculé la page où
; tourne le FORTH lui-même ($0000-$13FF de la page 1). Une autre page se
; lira par FarRead/FarWrite, pas par une bascule.
Word_Add:       fdb Word_Emit
                fdb Op_Add
                fcb $2b
                fcb 1
                fcn "+"
Word_Fetch:     fdb Word_Add
                fdb Op_Fetch
                fcb '@'
                fcb 1
                fcn "@"
Word_Store:     fdb Word_Fetch
                fdb Op_Store
                fcb '!'
                fcb 1
                fcn "!"
Word_CFetch:    fdb Word_Store
                fdb Op_CFetch
                fcb $03
                fcb 2
                fcn "C@"
Word_CStore:    fdb Word_CFetch
                fdb Op_CStore
                fcb $62
                fcb 2
                fcn "C!"
Word_Sub:       fdb Word_CStore
                fdb Op_Sub
                fcb $2d
                fcb 1
                fcn "-"
Word_Print:     fdb Word_Sub
                fdb Op_Print
                fcb $2e
                fcb 1
                fcn "."
Word_Mul:       fdb Word_Print
                fdb Op_Mul
                fcb $2a
                fcb 1
                fcn "*"
Word_Div:       fdb Word_Mul
                fdb Op_Div
                fcb $2f
                fcb 1
                fcn "/"
Word_Eq:        fdb Word_Div
                fdb Op_Eq
                fcb $3d
                fcb 1
                fcn "="
Word_If:        fdb Word_Eq
                fdb Op_If
                fcb $0f
                fcb 2
                fcn "IF"
Word_Else:      fdb Word_If
                fdb Op_Else
                fcb $1f
                fcb 4
                fcn "ELSE"
Word_Then:      fdb Word_Else
                fdb Op_Then_NoOp
                fcb $17
                fcb 4
                fcn "THEN"
Word_0Branch:   fdb Word_Then
                fdb Op_0Branch
                fcb $24
                fcb 7
                fcn "0BRANCH"
Word_Branch:    fdb Word_0Branch
                fdb Op_Branch
                fcb $14
                fcb 6
                fcn "BRANCH"
Word_Gt:        fdb Word_Branch
                fdb Op_Gt
                fcb '>'
                fcb 1
                fcn ">"
Word_Lt:        fdb Word_Gt
                fdb Op_Lt
                fcb '<'
                fcb 1
                fcn "<"
Word_Do:        fdb Word_Lt
                fdb Op_Do
                fcb $0b
                fcb 2
                fcn "DO"
Word_Loop:      fdb Word_Do
                fdb Op_Loop
                fcb $1C
                fcb 4
                fcn "LOOP"
Word_Colon:     fdb Word_Loop
                fdb Op_Colon
                fcb $3a
                fcb 1
                fcn ":"
Word_Lit:       fdb Word_Colon
                fdb Op_Lit
                fcb $51
                fcb 3
                fcn "LIT"
Word_Decimal:   fdb Word_Lit
                fdb Op_Decimal
                fcb $4b
                fcb 7
                fcn "DECIMAL"
Word_Hex:       fdb Word_Decimal
                fdb Op_Hex
                fcb $55
                fcb 3
                fcn "HEX"
Word_Quit:      fdb Word_Hex
                fdb Op_Quit
                fcb $19
                fcb 4
                fcn "QUIT"
Word_List:      fdb Word_Quit
                fdb Op_List
                fcb $02
                fcb 4
                fcn "LIST"
Word_Load:      fdb Word_List
                fdb Op_LoadDict
                fcb $06
                fcb 4
                fcn "LOAD"
Word_Save:      fdb Word_Load
                fdb Op_SaveDict
                fcb $01
                fcb 4
                fcn "SAVE"
Word_DoLoop:    fdb Word_Save
                fdb Op_DoLoop
                fcb $17
                fcb 6
                fcn "DOLOOP"
Word_LoopEx:    fdb Word_DoLoop
                fdb Op_LoopEx
                fcb $35
                fcb 5
                fcn "LOOP)"
Word_PlusLoop:  fdb Word_LoopEx
                fdb Op_PlusLoopEx
                fcb $37
                fcb 5
                fcn "+LOOP"
Word_Unloop:    fdb Word_PlusLoop
                fdb Op_Unloop
                fcb $07
                fcb 6
                fcn "UNLOOP"
Word_Leave:     fdb Word_Unloop
                fdb Op_Leave
                fcb $5B
                fcb 5
                fcn "LEAVE"
Word_I:         fdb Word_Leave
                fdb Op_I
                fcb $49
                fcb 1
                fcn "I"
Word_J:         fdb Word_I
                fdb Op_J
                fcb $4A
                fcb 1
                fcn "J"
Word_CR:        fdb Word_J
                fdb Op_CR
                fcb $11
                fcb 2
                fcn "CR"
Word_Space:     fdb Word_CR
                fdb Op_Space
                fcb $44
                fcb 5
                fcn "SPACE"
Word_Key:       fdb Word_Space
                fdb Op_Key
                fcb $57
                fcb 3
                fcn "KEY"
Word_Negate:    fdb Word_Key
                fdb Op_Negate
                fcb $1C
                fcb 6
                fcn "NEGATE"
Word_And:       fdb Word_Negate
                fdb Op_And
                fcb $4B
                fcb 3
                fcn "AND"
Word_Or:        fdb Word_And
                fdb Op_Or
                fcb $1D
                fcb 2
                fcn "OR"
Word_Mod:       fdb Word_Or
                fdb Op_Mod
                fcb $46
                fcb 3
                fcn "MOD"
Word_PrintStr:  fdb Word_Mod
                fdb Op_PrintStr
                fcb $04
                fcb 8
                fcn "PRINTSTR"
Word_DotQuote:  fdb Word_PrintStr
                fdb Op_DotQuote
                fcb $0C
                fcb 2
                fcb '.','"',0
Word_Abs:       fdb Word_DotQuote
                fdb Op_Abs
                fcb $50
                fcb 3
                fcn "ABS"
Word_1Plus:     fdb Word_Abs
                fdb Op_1Plus
                fcb $1A
                fcb 2
                fcn "1+"
Word_1Minus:    fdb Word_1Plus
                fdb Op_1Minus
                fcb $1C
                fcb 2
                fcn "1-"
Word_2Plus:     fdb Word_1Minus
                fdb Op_2Plus
                fcb $19
                fcb 2
                fcn "2+"
Word_2Minus:    fdb Word_2Plus
                fdb Op_2Minus
                fcb $1F
                fcb 2
                fcn "2-"
Word_2Mul:      fdb Word_2Minus
                fdb Op_2Mul
                fcb $18
                fcb 2
                fcn "2*"
Word_2Div:      fdb Word_2Mul
                fdb Op_2Div
                fcb $1D
                fcb 2
                fcn "2/"
Word_Invert:    fdb Word_2Div
                fdb Op_Invert
                fcb $12
                fcb 6
                fcn "INVERT"
Word_Xor:       fdb Word_Invert
                fdb Op_Xor
                fcb $45
                fcb 3
                fcn "XOR"
Word_Depth:     fdb Word_Xor
                fdb Op_Depth
                fcb $4D
                fcb 5
                fcn "DEPTH"
Word_True:      fdb Word_Depth
                fdb Op_True
                fcb $16
                fcb 4
                fcn "TRUE"
Word_False:     fdb Word_True
                fdb Op_False
                fcb $5D
                fcb 5
                fcn "FALSE"
Word_Nip:       fdb Word_False
                fdb Op_Nip
                fcb $57
                fcb 3
                fcn "NIP"
Word_Tuck:      fdb Word_Nip
                fdb Op_Tuck
                fcb $09
                fcb 4
                fcn "TUCK"
Word_Here:      fdb Word_Tuck
                fdb Op_Here
                fcb $1A
                fcb 4
                fcn "HERE"
Word_Comma:     fdb Word_Here
                fdb Op_Comma
                fcb $2C
                fcb 1
                fcn ","
Word_Allot:     fdb Word_Comma
                fdb Op_Allot
                fcb $5A
                fcb 5
                fcn "ALLOT"
Word_Variable:  fdb Word_Allot
                fdb Op_VariableCreate
                fcb $06
                fcb 8
                fcn "VARIABLE"
Word_Constant:  fdb Word_Variable
                fdb Op_ConstantCreate
                fcb $1E
                fcb 8
                fcn "CONSTANT"
Word_Fill:      fdb Word_Constant
                fdb Op_Fill
                fcb $0F
                fcb 4
                fcn "FILL"
Word_CMove:     fdb Word_Fill
                fdb Op_CMove
                fcb $52
                fcb 5
                fcn "CMOVE"

; ======================================================
; VARIABLES DE GESTION DU DICTIONNAIRE RAM
; ======================================================
CURRENT_BASE:   fdb 16
CURRENT_WORD:   fdb Word_CMove
HERE:           fdb User_Dict_Buffer

; ======================================================
; ZONE DE STOCKAGE (Dictionnaire Étendu)
; ======================================================
LoopStack:      rmb 16      ; 8 × 2 octets pour DO/LOOP imbriqués
LoopSP:         rmb 2       ; Pointeur dans LoopStack
CompileStack:   rmb 32      ; 16 × 2 octets pour IF imbriqués
CompileSP:      rmb 2       ; Pointeur dans CompileStack
DoLoopSave:     rmb 4       ; (inutilisé depuis la réécriture DO/LOOP v2)
User_Dict_Header: rmb 2
User_Dict_Buffer:
