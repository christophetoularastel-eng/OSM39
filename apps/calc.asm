; ===================================================================
; CALC.ASM - Tableur à la VisiCalc pour OSM-VISION
; ===================================================================
; Application d'OSM-VISION (modèle apps/mire.asm) : liée à $4000,
; contrôle de version, sortie par RTS.
;
; FEUILLE : 26 colonnes (A-Z) x 50 lignes, 8 colonnes et 17 lignes
; visibles, défilement dans les deux sens. Une cellule contient ce qu'on
; a tapé (15 caractères au plus) :
;   - un LIBELLÉ s'il commence par une lettre (ou ", ôté à l'affichage) ;
;   - une VALEUR sinon : nombre ou formule, à la VisiCalc :
;       12,50   -3   +A1*2   (B2+B3)/2   @SUM(A1...A9)   @AVG(B1:B5)
;     opérateurs + - * /, parenthèses, références A1..Z50,
;     fonctions @SUM @MIN @MAX @AVG sur une plage (... ou :).
; Les valeurs sont des entiers 32 bits en CENTIÈMES (2 décimales fixes) :
; 12,50 est stocké 1250. La saisie accepte , ou . comme séparateur.
; Multiplication et division passent par un produit 64 bits (logiciel),
; puis une division : pas de dépassement intermédiaire.
;
; MÉMOIRE : 1300 cellules. Les TEXTES (16 octets chacun, 20,8 Ko) sont
; dans la page de RAM TEXT_PAGE, lus et écrits par sys_FarRead /
; sys_FarWrite ; le type (bit 7 = erreur) et la valeur (4 octets) restent
; ici. Le fichier sauvé est l'image de ces 20,8 Ko de textes. Il faut le
; BIOS dont FS_SaveFile rétablit la page de l'appelant (9 oct. 2026).
;
; RECALCUL : passes successives sur toutes les valeurs, dans l'ordre
; des lignes, jusqu'à ce que plus rien ne change (10 passes au plus,
; sinon « référence circulaire ? »). Une erreur (division par zéro,
; dépassement, syntaxe, référence à une cellule en erreur) affiche ERREUR.
;
; COMMANDES : flèches pour se déplacer ; une touche tapée commence la
; saisie de la cellule ; Entrée modifie la cellule (texte actuel repris) ;
; / ouvre les commandes : S sauver, L lire (fichier sur la carte),
; B vider la cellule, E effacer la feuille ; Echap quitte (O/N si la
; feuille n'est pas sauvée).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Input
VIS_REQUIS      equ (vis_Input/2)+1

; --- Feuille ---
NCOLS           equ 26
NROWS           equ 50
VIS_COLS        equ 8           ; colonnes visibles
NCELLS          equ NCOLS*NROWS
TXT_LEN         equ 16          ; texte d'une cellule : 15 caractères + 0
TEXT_SIZE       equ NCELLS*TXT_LEN
CT_EMPTY        equ 0
CT_LABEL        equ 1
CT_VALUE        equ 2
CT_ERR          equ $80         ; bit 7 du type : valeur en erreur
CT_MASK         equ $7F
TEXT_PAGE       equ 3           ; page des textes (libre : OSM-VISION ne
                                ; s'en sert que dans son visualiseur)
MAX_PASS        equ 10

; --- Écran : fenêtre pleine largeur, lignes 1 à 23 (ombre en 24) ---
WIN_X           equ 0
WIN_Y           equ 1
WIN_W           equ 79
WIN_H           equ 23
ROW_STATUS      equ WIN_Y+2     ; cellule courante et son contenu
ROW_EDIT        equ WIN_Y+3     ; saisie, ou aide / messages
ROW_HEAD        equ WIN_Y+4     ; lettres des colonnes
ROW_GRID        equ WIN_Y+5     ; première ligne de la grille
VIS_ROWS        equ WIN_H-6     ; lignes de feuille visibles (17)
COL_X           equ 1           ; numéros de ligne
CELL_X          equ 5           ; première colonne de cellules
CELL_W          equ 9           ; 8 caractères + 1 espace
FIELD_W         equ 8
LINE_W          equ 76          ; largeur des lignes écrites
EDIT_X          equ 3           ; champ de saisie
ATTR_HEAD       equ $0B         ; en-têtes : cyan vif

ASCII_0         equ $30         ; lib/str.asm

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0)
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDA     >VIS_COUNT_ADR
    CMPA    #VIS_REQUIS
    BHS     AS_VisOk
    CMPA    #(vis_MsgBox/2)+1
    BLO     AS_Abandon
    LDX     #TxtVisVieux
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_MsgBox]
AS_Abandon:
    RTS
AS_VisOk:
    JSR     Clear_Sheet
    CLR     CurCol
    CLR     CurRow
    CLR     Top
    CLR     LeftCol
    LDX     #TxtDefName         ; nom de fichier proposé
    LDA     >argc               ; ou celui reçu en argument (OSM-VISION :
    CMPA    #2                  ; Entrée sur une .CAL)
    BLO     AS_Nom
    LDX     >argv+2
AS_Nom:
    LDU     #FileName
    LDB     #15
AS_Copie:
    LDA     ,X+
    BEQ     AS_Copie_Fin
    CMPA    #' '
    BEQ     AS_Copie_Fin
    STA     ,U+
    DECB
    BNE     AS_Copie
AS_Copie_Fin:
    CLR     ,U
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Draw_Grid
    JSR     Draw_Status
    LDX     #TxtAide
    LDA     >argc               ; une feuille en argument : on la lit
    CMPA    #2
    BLO     AS_Msg
    LDX     #FileName
    LDY     #FileName15
    JSR     [table_function_ram+sys_Format_Filename_83]
    JSR     Load_Sheet
AS_Msg:
    JSR     Show_Msg

; -------------------------------------------------------------------
; Boucle principale : une touche à la fois
; -------------------------------------------------------------------
Main_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     Main_Loop
    CMPA    #$1B                ; Echap : on quitte
    LBEQ    Quitter

    CMPA    #$80
    LBEQ    Go_Up
    CMPA    #$81
    LBEQ    Go_Down
    CMPA    #$82
    LBEQ    Go_Left
    CMPA    #$83
    LBEQ    Go_Right
    CMPA    #KEY_PGUP           ; touches du BIOS récent
    LBEQ    Go_PgUp
    CMPA    #KEY_PGDN
    LBEQ    Go_PgDn
    CMPA    #KEY_HOME
    LBEQ    Go_Home
    CMPA    #KEY_END
    LBEQ    Go_End
    CMPA    #KEY_CHOME
    LBEQ    Go_CHome
    CMPA    #KEY_CEND
    LBEQ    Go_CEnd
    CMPA    #KEY_DEL            ; Suppr : vide la cellule
    LBEQ    Cmd_Blank
    CMPA    #$0D                ; Entrée : modifier la cellule
    BNE     ML_2
    JSR     Cur_Index
    JSR     Get_Text            ; X = texte actuel, repris
    LDU     #InBuf
    JSR     Append
    CLR     ,U
    LBRA    Edit_Cell
ML_2:
    CMPA    #'/'
    LBEQ    Command
    CMPA    #$20                ; caractère imprimable : nouvelle saisie
    BLO     Main_Loop
    CMPA    #$7E
    BHI     Main_Loop
    STA     InBuf
    CLR     InBuf+1
    LBRA    Edit_Cell

; --- Déplacements ---
Go_Up:
    LDA     CurRow
    LBEQ    Main_Loop
    DECA
    BRA     Go_Row
Go_Down:
    LDA     CurRow
    CMPA    #NROWS-1
    LBHS    Main_Loop
    INCA
Go_Row:
    LDB     CurRow              ; ancienne ligne
    STB     OldRow
    STA     CurRow
    JSR     Scroll_To
    BCS     GR_Full             ; la fenêtre a défilé
    LDA     OldRow
    JSR     Draw_Row_Of
    LDA     CurRow
    JSR     Draw_Row_Of
    BRA     GR_Status
GR_Full:
    JSR     Draw_Grid
GR_Status:
    JSR     Draw_Status
    LBRA    Main_Loop
Go_Left:
    LDA     CurCol
    LBEQ    Main_Loop
    DECA
    BRA     Go_Col
Go_Right:
    LDA     CurCol
    CMPA    #NCOLS-1
    LBHS    Main_Loop
    INCA
Go_Col:
    STA     CurCol
    JSR     HScroll_To
    BCS     GC_Full             ; défilement horizontal : tout redessiner
    LDA     CurRow
    JSR     Draw_Row_Of
    JSR     Draw_Status
    LBRA    Main_Loop
GC_Full:
    JSR     Draw_Grid
    JSR     Draw_Status
    LBRA    Main_Loop

; Ajuste LeftCol pour que CurCol soit visible. C = 1 si LeftCol a changé.
HScroll_To:
    LDA     CurCol
    CMPA    LeftCol
    BHS     HS_Right
    STA     LeftCol
    ORCC    #%00000001
    RTS
HS_Right:
    LDB     LeftCol
    ADDB    #VIS_COLS-1
    PSHS    B
    CMPA    ,S+
    BLS     HS_Same
    SUBA    #VIS_COLS-1
    STA     LeftCol
    ORCC    #%00000001
    RTS
HS_Same:
    ANDCC   #%11111110
    RTS

; Page préc. / suiv. : VIS_ROWS lignes.
Go_PgUp:
    LDA     CurRow
    SUBA    #VIS_ROWS
    BHS     GP_Set
    CLRA
    BRA     GP_Set
Go_PgDn:
    LDA     CurRow
    ADDA    #VIS_ROWS
    CMPA    #NROWS-1
    BLS     GP_Set
    LDA     #NROWS-1
GP_Set:
    STA     CurRow
    LBRA    Go_Jump

; Début : colonne A ; Fin : dernière cellule remplie de la ligne.
Go_Home:
    CLR     CurCol
    BRA     Go_Jump
Go_End:
    CLR     JmpCol
    CLR     IterCol
GE_Loop:
    LDA     CurRow
    LDB     #NCOLS
    MUL
    ADDB    IterCol
    ADCA    #0
    JSR     Type_Of
    LDA     ,X
    ANDA    #CT_MASK
    BEQ     GE_Next
    LDA     IterCol
    STA     JmpCol
GE_Next:
    INC     IterCol
    LDA     IterCol
    CMPA    #NCOLS
    BLO     GE_Loop
    LDA     JmpCol
    STA     CurCol
    BRA     Go_Jump

; Ctrl+Début : A1 ; Ctrl+Fin : dernière ligne et dernière colonne utilisées.
Go_CHome:
    CLR     CurCol
    CLR     CurRow
    BRA     Go_Jump
Go_CEnd:
    CLR     JmpRow
    CLR     JmpCol
    CLRD
GCE_Loop:
    STD     JmpIdx
    JSR     Type_Of
    LDA     ,X
    ANDA    #CT_MASK
    BEQ     GCE_Next
    LDD     JmpIdx
    JSR     Ref_RowCol          ; A = ligne, B = colonne
    CMPA    JmpRow
    BLS     GCE_Col
    STA     JmpRow
GCE_Col:
    CMPB    JmpCol
    BLS     GCE_Next
    STB     JmpCol
GCE_Next:
    LDD     JmpIdx
    ADDD    #1
    CMPD    #NCELLS
    BLO     GCE_Loop
    LDA     JmpRow
    STA     CurRow
    LDA     JmpCol
    STA     CurCol
; Après un saut : défilements et redessin complet.
Go_Jump:
    JSR     Scroll_To
    JSR     HScroll_To
    JSR     Draw_Grid
    JSR     Draw_Status
    LBRA    Main_Loop

; Ajuste Top pour que CurRow soit visible. C = 1 si Top a changé.
Scroll_To:
    LDA     CurRow
    CMPA    Top
    BHS     ST_Below
    STA     Top                 ; au-dessus : CurRow en haut
    ORCC    #%00000001
    RTS
ST_Below:
    LDB     Top
    ADDB    #VIS_ROWS-1
    PSHS    B
    CMPA    ,S+
    BLS     ST_Same
    SUBA    #VIS_ROWS-1         ; en dessous : CurRow en bas
    STA     Top
    ORCC    #%00000001
    RTS
ST_Same:
    ANDCC   #%11111110
    RTS

; -------------------------------------------------------------------
; Saisie d'une cellule. InBuf contient le texte de départ.
; -------------------------------------------------------------------
Edit_Cell:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #COL_X
    LDB     #ROW_EDIT
    LDX     #TxtPrompt
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDA     #EDIT_X
    LDB     #ROW_EDIT
    LDX     #InBuf
    LDE     #TXT_LEN-1
    LDF     #0
    LDY     #0
    JSR     [VIS_TABLE+vis_Input]
    BCS     EC_Cancel
    JSR     Store_Cell
    JSR     Recalc
    LDA     CurRow              ; la ligne suivante, comme un tableur
    CMPA    #NROWS-1
    BHS     EC_Draw
    INCA
    STA     CurRow
    JSR     Scroll_To
EC_Draw:
    JSR     Draw_Grid
    JSR     Draw_Status
    LDX     MsgPtr              ; message du recalcul, ou l'aide
    JSR     Show_Msg
    LBRA    Main_Loop
EC_Cancel:
    LDX     #TxtAide
    JSR     Show_Msg
    LBRA    Main_Loop

; -------------------------------------------------------------------
; Commandes : / puis une lettre
; -------------------------------------------------------------------
Command:
    LDX     #TxtCmd
    JSR     Show_Msg
CM_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     CM_Key
    ANDA    #$DF                ; majuscule
    CMPA    #'S'
    LBEQ    Cmd_Save
    CMPA    #'L'
    LBEQ    Cmd_Load
    CMPA    #'B'
    LBEQ    Cmd_Blank
    CMPA    #'E'
    LBEQ    Cmd_Erase
    LDX     #TxtAide            ; autre touche : abandon
    JSR     Show_Msg
    LBRA    Main_Loop

; Echap : sortie, après confirmation si la feuille n'est pas sauvée.
Quitter:
    TST     Modified
    BEQ     QT_Fin
    LDX     #TxtPerdre
    JSR     Show_Msg
QT_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     QT_Key
    ANDA    #$DF
    CMPA    #'O'
    BEQ     QT_Fin
    LDX     #TxtAide
    JSR     Show_Msg
    LBRA    Main_Loop
QT_Fin:
    RTS                         ; OSM-VISION restaure l'écran

Cmd_Blank:
    CLR     InBuf
    JSR     Store_Cell
    JSR     Recalc
    JSR     Draw_Grid
    JSR     Draw_Status
    LDX     MsgPtr
    JSR     Show_Msg
    LBRA    Main_Loop

Cmd_Erase:
    LDX     #TxtSur
    JSR     Show_Msg
CE_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     CE_Key
    ANDA    #$DF
    CMPA    #'O'
    BNE     CE_No
    JSR     Clear_Sheet
    CLR     Modified            ; feuille vide : rien à perdre
    CLR     CurCol
    CLR     CurRow
    CLR     Top
    CLR     LeftCol
    JSR     Draw_Grid
    JSR     Draw_Status
CE_No:
    LDX     #TxtAide
    JSR     Show_Msg
    LBRA    Main_Loop

; Demande le nom du fichier (FileName, repris) puis le met au format
; OSMFS dans FileName15. C = 1 si Echap.
Ask_Name:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #COL_X
    LDB     #ROW_EDIT
    LDX     #TxtFichier
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDA     #COL_X+10
    LDB     #ROW_EDIT
    LDX     #FileName
    LDE     #15
    LDF     #INP_MAJ+INP_SANS_ESPACE+INP_NON_VIDE
    LDY     #0
    JSR     [VIS_TABLE+vis_Input]
    BCS     AN_End
    LDX     #FileName
    LDY     #FileName15
    JSR     [table_function_ram+sys_Format_Filename_83]
    ANDCC   #%11111110
AN_End:
    RTS

; Sauve tout le texte des cellules (TEXT_SIZE octets). FS_SaveFile crée
; toujours une nouvelle entrée : l'ancien fichier est d'abord effacé.
; A = page SOURCE (sinon le BIOS bascule la RAM ailleurs).
Cmd_Save:
    JSR     Ask_Name
    BCS     CS_Abort
    LDX     #FileName15
    JSR     [table_function_ram+sys_FS_DeleteFile]
    LDA     #TEXT_PAGE          ; page SOURCE : les textes (le BIOS
    LDX     #FileName15         ; rétablit ensuite notre page)
    LDY     #0
    LDU     #TEXT_SIZE
    JSR     [table_function_ram+sys_FS_SaveFile]
    BCS     CS_Err
    LDX     #FileName15
    LDA     #$06                ; rw : ce n'est pas un programme
    JSR     [table_function_ram+sys_FS_SetAttributes]
    CLR     Modified
    LDX     #TxtSauve
    BRA     CS_Msg
CS_Err:
    LDX     #TxtErrSauve
    BRA     CS_Msg
CS_Abort:
    LDX     #TxtAide
CS_Msg:
    JSR     Show_Msg
    LBRA    Main_Loop

; Charge une feuille : seulement un fichier de TEXT_SIZE octets exactement.
Cmd_Load:
    JSR     Ask_Name
    BCS     CS_Abort
    JSR     Load_Sheet
    BRA     CS_Msg

; Load_Sheet - Lit la feuille FileName15 (TEXT_SIZE octets exactement) et
; redessine. Sortie : X = message à afficher.
Load_Sheet:
    LDX     #FileName15
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     CL_NotFound
    LDD     >g_find_fileInfo+20
    BNE     CL_Bad
    CMPU    #TEXT_SIZE
    BNE     CL_Bad
    LDA     #TEXT_PAGE          ; A = page de destination
    LDX     #FileName15
    LDY     #0
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCS     CL_Bad
    JSR     Classify_All
    JSR     Recalc
    CLR     Modified
    CLR     CurCol
    CLR     CurRow
    CLR     Top
    CLR     LeftCol
    JSR     Draw_Grid
    JSR     Draw_Status
    LDX     #TxtLu
    RTS
CL_NotFound:
    LDX     #TxtIntrouvable
    RTS
CL_Bad:
    LDX     #TxtPasFeuille
    RTS

; -------------------------------------------------------------------
; Feuille : stockage. Textes en page TEXT_PAGE (adresse = indice * 16),
; type et valeur ici.
; -------------------------------------------------------------------
; Tout à zéro. CellVal (5200 octets, effacé d'abord) sert de source de
; zéros pour les 20 800 octets de textes : 4 copies.
Clear_Sheet:
    LDX     #CellVal
    LDY     #Zero
    LDW     #NCELLS*4
    TFM     Y,X+
    LDX     #CellType
    LDY     #Zero
    LDW     #NCELLS
    TFM     Y,X+
    LDY     #0                  ; destination dans TEXT_PAGE
    LDA     #4
    STA     LoopN
CS_Text:
    PSHS    Y
    LDA     #TEXT_PAGE          ; FarWrite : A = page dest, B = page source
    LDB     >current_page
    LDX     #CellVal
    LDU     #NCELLS*4
    JSR     [table_function_ram+sys_FarWrite]
    PULS    Y
    LEAY    NCELLS*4,Y
    DEC     LoopN
    BNE     CS_Text
    LDX     #TxtAide
    STX     MsgPtr
    RTS

; D = indice de la cellule courante (ligne * 26 + colonne).
Cur_Index:
    LDA     CurRow
    LDB     #NCOLS
    MUL
    ADDB    CurCol
    ADCA    #0
    RTS

; D = indice -> X = TxtTmp, copie du texte de la cellule (16 octets).
; Préserve D.
Get_Text:
    PSHS    D,Y,U
    LSLD                        ; adresse en page TEXT_PAGE : indice * 16
    LSLD
    LSLD
    LSLD
    TFR     D,X
    LDY     #TxtTmp
    LDA     #TEXT_PAGE          ; FarRead : A = page source, B = page dest
    LDB     >current_page
    LDU     #TXT_LEN
    JSR     [table_function_ram+sys_FarRead]
    LDX     #TxtTmp
    PULS    D,Y,U,PC

; D = indice -> X = adresse de son octet de type. Préserve D.
Type_Of:
    PSHS    D
    ADDD    #CellType
    TFR     D,X
    PULS    D,PC

; InBuf -> cellule courante : texte complété par des 0 (page TEXT_PAGE),
; type.
Store_Cell:
    LDX     #InBuf              ; zéros après le texte, jusqu'à 16 octets
    LDB     #TXT_LEN
SC_Find:
    TST     ,X+
    BEQ     SC_Zero
    DECB
    BNE     SC_Find
    BRA     SC_Write
SC_Zero:
    DECB
    BEQ     SC_Write
    CLR     ,X+
    BRA     SC_Zero
SC_Write:
    LDA     #1
    STA     Modified
    CLR     InBuf+TXT_LEN-1     ; 16e octet : toujours 0
    JSR     Cur_Index
    LSLD
    LSLD
    LSLD
    LSLD
    TFR     D,Y                 ; destination en page TEXT_PAGE
    LDA     #TEXT_PAGE
    LDB     >current_page
    LDX     #InBuf
    LDU     #TXT_LEN
    JSR     [table_function_ram+sys_FarWrite]
    LDX     #InBuf
    JSR     Classify
    PSHS    A
    JSR     Cur_Index
    JSR     Type_Of
    PULS    A
    STA     ,X
    RTS

; X = texte : A = CT_EMPTY, CT_LABEL ou CT_VALUE.
Classify:
    LDA     ,X
    BEQ     CF_Empty
    CMPA    #'"'
    BEQ     CF_Label
    ANDA    #$DF                ; lettre ?
    CMPA    #'A'
    BLO     CF_Value
    CMPA    #'Z'
    BHI     CF_Value
CF_Label:
    LDA     #CT_LABEL
    RTS
CF_Value:
    LDA     #CT_VALUE
    RTS
CF_Empty:
    CLRA
    RTS

; Après un chargement : le type de chaque cellule d'après son texte.
Classify_All:
    CLRD
CA_Loop:
    JSR     Get_Text            ; préserve D
    PSHS    D
    JSR     Classify
    PSHS    A
    LDD     1,S
    JSR     Type_Of
    PULS    A
    STA     ,X
    PULS    D
    ADDD    #1
    CMPD    #NCELLS
    BLO     CA_Loop
    RTS

; -------------------------------------------------------------------
; Recalcul : passes jusqu'à stabilité
; -------------------------------------------------------------------
Recalc:
    LDX     #TxtAide
    STX     MsgPtr
    LDA     #MAX_PASS
    STA     PassLeft
RC_Pass:
    CLR     Changed
    CLRD
RC_Cell:
    STD     RcIdx
    JSR     Type_Of
    LDA     ,X
    ANDA    #CT_MASK
    CMPA    #CT_VALUE
    BNE     RC_Next
    LDD     RcIdx
    JSR     Get_Text
    JSR     Eval_Text           ; Q = valeur, EvalErr
    STQ     NewVal
    LDD     RcIdx               ; erreur : drapeau changé ?
    JSR     Type_Of
    LDA     #CT_VALUE
    TST     EvalErr
    BEQ     RC_Err
    ORA     #CT_ERR
RC_Err:
    CMPA    ,X
    BEQ     RC_SameErr
    STA     ,X
    INC     Changed
RC_SameErr:
    LDD     RcIdx               ; valeur changée ?
    LSLD
    LSLD
    ADDD    #CellVal
    TFR     D,X
    LDQ     NewVal
    CMPD    ,X
    BNE     RC_Store
    CMPW    2,X
    BEQ     RC_Next
RC_Store:
    STQ     ,X
    INC     Changed
RC_Next:
    LDD     RcIdx
    ADDD    #1
    CMPD    #NCELLS
    BLO     RC_Cell
    TST     Changed
    BEQ     RC_End
    DEC     PassLeft
    BNE     RC_Pass
    LDX     #TxtCirc            ; toujours instable
    STX     MsgPtr
RC_End:
    RTS

; -------------------------------------------------------------------
; Évaluation d'une formule. X = texte. Sortie : Q = valeur (centièmes),
; EvalErr <> 0 si erreur.
; -------------------------------------------------------------------
Eval_Text:
    STX     PPtr
    CLR     EvalErr
    JSR     Parse_Expr
    JSR     Skip_Sp
    LDX     PPtr
    TST     ,X                  ; tout doit avoir été lu
    BEQ     ET_End
    JSR     Set_Err
ET_End:
    RTS

Set_Err:
    LDA     #1
    STA     EvalErr
    RTS

; Caractère courant (après les espaces) dans A ; Z = 1 si fin.
Skip_Sp:
    LDX     PPtr
SS_Loop:
    LDA     ,X
    CMPA    #' '
    BNE     SS_End
    LEAX    1,X
    BRA     SS_Loop
SS_End:
    STX     PPtr
    TSTA
    RTS

Next_Ch:
    LDX     PPtr
    LEAX    1,X
    STX     PPtr
    RTS

; expr := term (('+'|'-') term)*
Parse_Expr:
    JSR     Parse_Term
PE_Loop:
    PSHSW                       ; résultat partiel sur la pile
    PSHS    D
    JSR     Skip_Sp
    CMPA    #'+'
    BEQ     PE_Add
    CMPA    #'-'
    BEQ     PE_Sub
    PULS    D
    PULSW
    RTS
PE_Add:
    JSR     Next_Ch
    JSR     Parse_Term
    STQ     Op2
    PULS    D
    PULSW
    STQ     Op1
    JSR     Add32
    BRA     PE_Loop
PE_Sub:
    JSR     Next_Ch
    JSR     Parse_Term
    STQ     Op2
    PULS    D
    PULSW
    STQ     Op1
    JSR     Sub32
    BRA     PE_Loop

; term := factor (('*'|'/') factor)*
Parse_Term:
    JSR     Parse_Factor
PT_Loop:
    PSHSW
    PSHS    D
    JSR     Skip_Sp
    CMPA    #'*'
    BEQ     PT_Mul
    CMPA    #'/'
    BEQ     PT_Div
    PULS    D
    PULSW
    RTS
PT_Mul:
    JSR     Next_Ch
    JSR     Parse_Factor
    STQ     Op2
    PULS    D
    PULSW
    STQ     Op1
    JSR     Mul_Scaled
    BRA     PT_Loop
PT_Div:
    JSR     Next_Ch
    JSR     Parse_Factor
    STQ     Op2
    PULS    D
    PULSW
    STQ     Op1
    JSR     Div_Scaled
    BRA     PT_Loop

; factor := + factor | - factor | ( expr ) | @fonction | nombre | référence
Parse_Factor:
    JSR     Skip_Sp
    CMPA    #'+'
    BNE     PF_1
    JSR     Next_Ch
    BRA     Parse_Factor
PF_1:
    CMPA    #'-'
    BNE     PF_2
    JSR     Next_Ch
    JSR     Parse_Factor
    STQ     Op1
    JSR     Neg_Op1
    LDQ     Op1
    RTS
PF_2:
    CMPA    #'('
    BNE     PF_3
    JSR     Next_Ch
    JSR     Parse_Expr
    PSHSW
    PSHS    D
    JSR     Skip_Sp
    CMPA    #')'
    BEQ     PF_Close
    JSR     Set_Err
    BRA     PF_Ret
PF_Close:
    JSR     Next_Ch
PF_Ret:
    PULS    D
    PULSW
    RTS
PF_3:
    CMPA    #'@'
    BNE     PF_4
    JSR     Next_Ch
    LBRA    Parse_Func
PF_4:
    CMPA    #'0'
    BLO     PF_5
    CMPA    #'9'
    LBLS    Parse_Number
PF_5:
    CMPA    #'.'
    LBEQ    Parse_Number
    CMPA    #','
    LBEQ    Parse_Number
    JSR     Parse_Ref           ; lettre ?
    BCS     PF_Bad
    JSR     Ref_Value
    RTS
PF_Bad:
    JSR     Set_Err
    CLRD
    CLRW
    RTS

; Nombre : chiffres, puis , ou . et deux décimales au plus -> Q (centièmes).
Parse_Number:
    CLRD
    CLRW
    STQ     Acc
    CLR     Decs
PN_Int:
    LDX     PPtr
    LDA     ,X
    CMPA    #'0'
    BLO     PN_Sep
    CMPA    #'9'
    BHI     PN_Sep
    SUBA    #'0'
    JSR     Acc_Mul10_Add
    JSR     Next_Ch
    BRA     PN_Int
PN_Sep:
    CMPA    #','
    BEQ     PN_Dot
    CMPA    #'.'
    BNE     PN_Scale
PN_Dot:
    JSR     Next_Ch
PN_Dec:
    LDX     PPtr
    LDA     ,X
    CMPA    #'0'
    BLO     PN_Scale
    CMPA    #'9'
    BHI     PN_Scale
    LDB     Decs
    CMPB    #2
    BHS     PN_Skip             ; au-delà de 2 décimales : ignorées
    SUBA    #'0'
    JSR     Acc_Mul10_Add
    INC     Decs
PN_Skip:
    JSR     Next_Ch
    BRA     PN_Dec
PN_Scale:
    LDA     Decs                ; complète à 2 décimales
    CMPA    #2
    BHS     PN_Done
    CLRA
    JSR     Acc_Mul10_Add
    INC     Decs
    BRA     PN_Scale
PN_Done:
    LDQ     Acc
    RTS

; Acc = Acc * 10 + A (0..9) ; dépassement -> erreur (Acc reste >= 0).
Acc_Mul10_Add:
    STA     DigitW+1
    CLR     DigitW
    LDQ     Acc
    STQ     T1                  ; v
    ADDW    T1+2
    ADCD    T1
    BVS     AM_Err              ; 2v
    STQ     T2
    ADDW    T2+2
    ADCD    T2
    BVS     AM_Err              ; 4v
    ADDW    T1+2
    ADCD    T1
    BVS     AM_Err              ; 5v
    STQ     T2
    ADDW    T2+2
    ADCD    T2
    BVS     AM_Err              ; 10v
    ADDW    DigitW              ; + chiffre
    ADCD    #0
    BVS     AM_Err
    STQ     Acc
    RTS
AM_Err:
    JSR     Set_Err
    RTS

; Référence A1..Z50 à PPtr. Sortie : C = 0 et D = indice, ou C = 1.
Parse_Ref:
    LDX     PPtr
    LDA     ,X
    ANDA    #$DF
    SUBA    #'A'
    BCS     PR_Bad
    CMPA    #NCOLS
    BHS     PR_Bad
    STA     RefCol
    LEAX    1,X
    CLR     RefRow
    CLR     RefDigits
PR_Dig:
    LDA     ,X
    CMPA    #'0'
    BLO     PR_End
    CMPA    #'9'
    BHI     PR_End
    SUBA    #'0'
    PSHS    A
    LDA     RefRow
    LDB     #10
    MUL
    ADDB    ,S+
    STB     RefRow
    LEAX    1,X
    INC     RefDigits
    LDA     RefDigits
    CMPA    #2
    BHI     PR_Bad              ; 3 chiffres : hors feuille
    BRA     PR_Dig
PR_End:
    TST     RefDigits
    BEQ     PR_Bad              ; pas de chiffre
    LDA     RefRow
    BEQ     PR_Bad              ; ligne 0
    CMPA    #NROWS
    BHI     PR_Bad
    STX     PPtr
    DECA                        ; ligne 1 -> 0
    LDB     #NCOLS
    MUL
    ADDB    RefCol
    ADCA    #0
    ANDCC   #%11111110
    RTS
PR_Bad:
    ORCC    #%00000001
    RTS

; D = indice : Q = valeur de la cellule (0 si vide ou libellé ; erreur
; si elle est elle-même en erreur).
Ref_Value:
    PSHS    D
    JSR     Type_Of
    LDA     ,X
    BITA    #CT_ERR
    BEQ     RV_NoErr
    PSHS    A
    JSR     Set_Err             ; référence à une cellule en erreur
    PULS    A                   ; (Set_Err écrase A)
RV_NoErr:
    ANDA    #CT_MASK
    CMPA    #CT_VALUE
    BEQ     RV_Ok
    PULS    D
    CLRD
    CLRW
    RTS
RV_Ok:
    PULS    D
    LSLD
    LSLD
    ADDD    #CellVal
    TFR     D,X
    LDQ     ,X
    RTS

; @SUM @MIN @MAX @AVG ( réf sep réf ). Sortie Q.
Parse_Func:
    LDX     PPtr
    LDD     ,X                  ; deux premières lettres suffisent
    ANDA    #$DF
    ANDB    #$DF
    CLR     FuncId
    CMPD    #$5355              ; SU
    BEQ     PFn_Name
    INC     FuncId
    CMPD    #$4D49              ; MI
    BEQ     PFn_Name
    INC     FuncId
    CMPD    #$4D41              ; MA
    BEQ     PFn_Name
    INC     FuncId
    CMPD    #$4156              ; AV
    BEQ     PFn_Name
    LBRA    PF_Bad
PFn_Name:
    LDX     PPtr                ; saute le nom (lettres)
PFn_Skip:
    LDA     ,X
    ANDA    #$DF
    CMPA    #'A'
    BLO     PFn_Open
    CMPA    #'Z'
    BHI     PFn_Open
    LEAX    1,X
    BRA     PFn_Skip
PFn_Open:
    STX     PPtr
    JSR     Skip_Sp
    CMPA    #'('
    LBNE    PF_Bad
    JSR     Next_Ch
    JSR     Skip_Sp
    JSR     Parse_Ref
    LBCS    PF_Bad
    JSR     Ref_RowCol
    STA     R1Row
    STB     R1Col
    LDX     PPtr                ; séparateur : des points ou :
    LDB     #0
PFn_Sep:
    LDA     ,X
    CMPA    #'.'
    BEQ     PFn_SepOk
    CMPA    #':'
    BNE     PFn_SepEnd
PFn_SepOk:
    LEAX    1,X
    INCB
    BRA     PFn_Sep
PFn_SepEnd:
    TSTB
    LBEQ    PF_Bad
    STX     PPtr
    JSR     Parse_Ref
    LBCS    PF_Bad
    JSR     Ref_RowCol
    STA     R2Row
    STB     R2Col
    JSR     Skip_Sp
    CMPA    #')'
    LBNE    PF_Bad
    JSR     Next_Ch
    ; bornes dans l'ordre
    LDA     R1Row
    CMPA    R2Row
    BLS     PFn_R
    LDB     R2Row
    STA     R2Row
    STB     R1Row
PFn_R:
    LDA     R1Col
    CMPA    R2Col
    BLS     PFn_C
    LDB     R2Col
    STA     R2Col
    STB     R1Col
PFn_C:
    ; parcours de la plage
    CLRD
    CLRW
    STQ     Acc                 ; somme
    CLR     Count
    CLR     Count+1
    CLR     FirstVal
    LDA     R1Row
    STA     IterRow
PFn_Row:
    LDA     R1Col
    STA     IterCol
PFn_Col:
    LDA     IterRow
    LDB     #NCOLS
    MUL
    ADDB    IterCol
    ADCA    #0
    PSHS    D                   ; LDA ,X écrase A, moitié haute de l'indice
    JSR     Type_Of
    LDA     ,X
    ANDA    #CT_MASK
    CMPA    #CT_VALUE
    PULS    D                   ; PULS ne touche pas aux drapeaux
    BNE     PFn_NextCell        ; vide ou libellé : ignoré
    JSR     Ref_Value           ; Q = valeur (erreur propagée)
    STQ     Op2
    LDD     Count
    ADDD    #1
    STD     Count
    LDA     FuncId
    BEQ     PFn_Sum
    CMPA    #3
    BEQ     PFn_Sum             ; AVG : somme d'abord
    TST     FirstVal
    BNE     PFn_Cmp
    INC     FirstVal
    LDQ     Op2
    STQ     Acc
    BRA     PFn_NextCell
PFn_Cmp:
    LDQ     Op2                 ; Op2 < Acc ? (signé, 32 bits)
    CMPD    Acc
    BLT     PFn_Less
    BGT     PFn_More
    CMPW    Acc+2
    BLO     PFn_Less
    BHI     PFn_More
    BRA     PFn_NextCell        ; égal
PFn_Less:
    LDA     FuncId
    CMPA    #1                  ; MIN
    BNE     PFn_NextCell
    LDQ     Op2
    STQ     Acc
    BRA     PFn_NextCell
PFn_More:
    LDA     FuncId
    CMPA    #2                  ; MAX
    BNE     PFn_NextCell
    LDQ     Op2
    STQ     Acc
    BRA     PFn_NextCell
PFn_Sum:
    LDQ     Acc
    STQ     Op1
    JSR     Add32
    STQ     Acc
PFn_NextCell:
    INC     IterCol
    LDA     IterCol
    CMPA    R2Col
    LBLS    PFn_Col
    INC     IterRow
    LDA     IterRow
    CMPA    R2Row
    LBLS    PFn_Row
    LDA     FuncId
    CMPA    #3
    BNE     PFn_Res
    LDD     Count               ; AVG = somme / nombre
    BEQ     PFn_Zero
    LDQ     Acc
    STQ     Op1
    JSR     Div_Count
    RTS
PFn_Zero:
    CLRD
    CLRW
    RTS
PFn_Res:
    LDQ     Acc
    RTS

; D = indice -> A = ligne, B = colonne.
Ref_RowCol:
    PSHS    D
    CLR     RcRow
RRC_Loop:
    LDD     ,S
    CMPD    #NCOLS
    BLO     RRC_End
    SUBD    #NCOLS
    STD     ,S
    INC     RcRow
    BRA     RRC_Loop
RRC_End:
    PULS    D
    LDA     RcRow
    RTS

; -------------------------------------------------------------------
; Arithmétique 32 bits signée (centièmes). Op1, Op2 -> Q.
; -------------------------------------------------------------------
Add32:
    LDQ     Op1
    ADDW    Op2+2
    ADCD    Op2
    BVC     A32_End
    JSR     Set_Err
A32_End:
    RTS

Sub32:
    LDQ     Op1
    SUBW    Op2+2
    SBCD    Op2
    BVC     S32_End
    JSR     Set_Err
S32_End:
    RTS

; Op1 = -Op1
Neg_Op1:
    LDQ     Op1
    COMD
    COMW
    ADDW    #1
    ADCD    #0
    STQ     Op1
    RTS
Neg_Op2:
    LDQ     Op2
    COMD
    COMW
    ADDW    #1
    ADCD    #0
    STQ     Op2
    RTS

; Op1, Op2 -> valeurs absolues, Sign = signe du produit / quotient.
Abs_Both:
    CLR     Sign
    TST     Op1
    BPL     AB_2
    COM     Sign
    JSR     Neg_Op1
AB_2:
    TST     Op2
    BPL     AB_End
    COM     Sign
    JSR     Neg_Op2
AB_End:
    RTS

; Résultat P (64 bits, quotient) -> Q signé ; dépassement -> erreur.
Signed_Result:
    LDQ     P                   ; poids fort doit être nul
    BNE     SR_Err
    TSTW
    BNE     SR_Err
    LDQ     P+4
    BMI     SR_Err              ; > $7FFFFFFF
    TST     Sign
    BEQ     SR_End
    STQ     Op1
    JSR     Neg_Op1
    LDQ     Op1
SR_End:
    RTS
SR_Err:
    JSR     Set_Err
    CLRD
    CLRW
    RTS

; Q = Op1 * Op2 / 100
Mul_Scaled:
    JSR     Abs_Both
    LDQ     Op1
    STQ     M1
    LDQ     Op2
    STQ     M2
    JSR     UMul32              ; P = |a| * |b|
    CLRD
    CLRW
    LDW     #100
    STQ     Dv
    JSR     UDiv64              ; P = P / 100
    LBRA    Signed_Result

; Q = Op1 * 100 / Op2
Div_Scaled:
    LDQ     Op2
    BNE     DS_Ok
    TSTW
    BNE     DS_Ok
    JSR     Set_Err             ; division par zéro
    CLRD
    CLRW
    RTS
DS_Ok:
    JSR     Abs_Both
    LDQ     Op1
    STQ     M1
    CLRD
    CLRW
    LDW     #100
    STQ     M2
    JSR     UMul32              ; P = |a| * 100
    LDQ     Op2
    STQ     Dv
    JSR     UDiv64              ; P = P / |b|
    LBRA    Signed_Result

; Q = Op1 / Count (moyenne)
Div_Count:
    CLR     Sign
    TST     Op1
    BPL     DC_Pos
    COM     Sign
    JSR     Neg_Op1
DC_Pos:
    CLRD                        ; P = |somme| sur 64 bits
    CLRW
    STQ     P
    LDQ     Op1
    STQ     P+4
    CLRD
    LDW     Count
    STQ     Dv
    JSR     UDiv64
    LBRA    Signed_Result

; P (64) = M1 * M2 (32 x 32, non signés). M2 est détruit.
UMul32:
    CLRD
    CLRW
    STQ     P
    STQ     P+4
    LDA     #32
    STA     LoopN
UM_Loop:
    LSR     M2                  ; bit de poids faible de M2 -> C
    ROR     M2+1
    ROR     M2+2
    ROR     M2+3
    BCC     UM_NoAdd
    LDQ     P                   ; P haut += M1, retenue -> C
    ADDW    M1+2
    ADCD    M1
    STQ     P
    BRA     UM_Shift
UM_NoAdd:
    ANDCC   #%11111110
UM_Shift:
    LDX     #P                  ; P >>= 1, la retenue entre en haut
    LDB     #8
UM_Ror:
    ROR     ,X+
    DECB
    BNE     UM_Ror
    DEC     LoopN
    BNE     UM_Loop
    RTS

; P (64) / Dv (32, non signés) -> quotient dans P, reste dans R.
; Division restaurante : à chaque pas, P glisse d'un bit dans R ; si
; R >= Dv (ou si R a débordé sur 33 bits), R -= Dv et le bit de quotient
; entre en bas de P.
UDiv64:
    CLRD
    CLRW
    STQ     R
    LDA     #64
    STA     LoopN
UD_Loop:
    LDX     #P+8                ; P <<= 1, le bit sorti -> C
    LDB     #8
    ANDCC   #%11111110
UD_Shl:
    ROL     ,-X
    DECB
    BNE     UD_Shl
    LDX     #R+4                ; R = R*2 + ce bit ; le bit sorti -> C
    LDB     #4
UD_Rol:
    ROL     ,-X
    DECB
    BNE     UD_Rol
    BCS     UD_Take             ; R a débordé : forcément >= Dv
    LDQ     R
    SUBW    Dv+2
    SBCD    Dv
    BCS     UD_Next             ; R < Dv : bit de quotient 0
    BRA     UD_Store
UD_Take:
    LDQ     R
    SUBW    Dv+2
    SBCD    Dv
UD_Store:
    STQ     R
    INC     P+7                 ; bit de quotient 1
UD_Next:
    DEC     LoopN
    BNE     UD_Loop
    RTS

; -------------------------------------------------------------------
; Affichage
; -------------------------------------------------------------------
; X = texte : ligne de message (ROW_EDIT), effacée au-delà. MsgPtr = X.
Show_Msg:
    STX     MsgPtr
    LDU     #Line
    JSR     Append
    JSR     Pad_Line
    CLRA                        ; la ligne composée hors synchro (vis_Prep),
    LDX     #Line               ; copiée par TFM dans la trame (vis_Ligne)
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Prep]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #COL_X
    LDB     #ROW_EDIT
    JSR     [VIS_TABLE+vis_Ligne]
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; Complète Line par des espaces jusqu'à LINE_W, puis 0. U = écriture.
Pad_Line:
    TFR     U,D
    SUBD    #Line
    CMPB    #LINE_W
    BHS     PL_End
    LDA     #' '
    STA     ,U+
    BRA     Pad_Line
PL_End:
    CLR     ,U
    RTS

; Ligne d'état : « A1 : <contenu brut> ».
Draw_Status:
    LDU     #Line
    LDA     CurCol
    ADDA    #'A'
    STA     ,U+
    CLRA
    LDB     CurRow
    INCB
    JSR     Dec16
    LDX     #TxtDeux
    JSR     Append
    JSR     Cur_Index
    JSR     Get_Text
    JSR     Append
    JSR     Pad_Line
    CLRA                        ; la ligne composée hors synchro (vis_Prep),
    LDX     #Line               ; copiée par TFM dans la trame (vis_Ligne)
    LDE     #ATTR_HEAD
    JSR     [VIS_TABLE+vis_Prep]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #COL_X
    LDB     #ROW_STATUS
    JSR     [VIS_TABLE+vis_Ligne]
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; En-têtes de colonnes : composés par vis_Prep (Draw_Grid les copie).
Draw_Head:
    LDU     #Line
    LDB     #CELL_X-COL_X
DH_Sp:
    LDA     #' '
    STA     ,U+
    DECB
    BNE     DH_Sp
    LDA     LeftCol
    ADDA    #'A'
    ADDA    #VIS_COLS
    STA     HeadEnd             ; lettre de fin (exclue)
    SUBA    #VIS_COLS
DH_Col:
    LDB     #4                  ; lettre centrée sur 9
DH_L:
    PSHS    A
    LDA     #' '
    STA     ,U+
    PULS    A
    DECB
    BNE     DH_L
    STA     ,U+
    LDB     #4
DH_R:
    PSHS    A
    LDA     #' '
    STA     ,U+
    PULS    A
    DECB
    BNE     DH_R
    INCA
    CMPA    HeadEnd
    BLO     DH_Col
    JSR     Pad_Line
    CLRA                        ; composée ici, hors synchro (vis_Prep)
    LDX     #Line
    LDE     #ATTR_HEAD
    JSR     [VIS_TABLE+vis_Prep]
    RTS

; Toutes les lignes visibles, une par synchronisation.
Draw_Grid:
    JSR     Draw_Head
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #COL_X
    LDB     #ROW_HEAD
    JSR     [VIS_TABLE+vis_Ligne]
    JSR     [VIS_TABLE+vis_Sync_End]
    CLR     GridI
DG_Loop:
    LDA     Top
    ADDA    GridI
    JSR     Draw_Row_Of
    INC     GridI
    LDA     GridI
    CMPA    #VIS_ROWS
    BLO     DG_Loop
    RTS

; A = ligne de feuille : la redessine si elle est visible.
Draw_Row_Of:
    CMPA    Top
    BLO     DR_End
    STA     DrRow
    SUBA    Top
    CMPA    #VIS_ROWS
    BHS     DR_End
    ADDA    #ROW_GRID
    STA     DrY
    JSR     Build_Row
    CLRA                        ; la ligne, puis la cellule courante par-dessus,
    LDX     #Line               ; composées hors synchro ; un TFM dans la trame
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Prep]
    LDA     DrRow
    CMPA    CurRow
    BNE     DR_NoSel
    LDA     CurCol              ; cellule courante en surbrillance
    SUBA    LeftCol
    LDB     #CELL_W
    MUL
    ADDB    #CELL_X-COL_X       ; colonne dans la ligne composée
    PSHS    B
    LDA     DrRow
    LDB     CurCol
    JSR     Format_Cell         ; FmtBuf
    PULS    A
    LDX     #FmtBuf
    LDE     #COLOR_SEL
    JSR     [VIS_TABLE+vis_Prep]
DR_NoSel:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #COL_X
    LDB     DrY
    JSR     [VIS_TABLE+vis_Ligne]
    JSR     [VIS_TABLE+vis_Sync_End]
DR_End:
    RTS

; Line = numéro de ligne (DrRow+1, sur 3) + espace + 8 cellules.
Build_Row:
    LDU     #Line
    LDA     DrRow
    INCA
    CMPA    #10
    BHS     BR_2
    LDB     #' '
    STB     ,U+
BR_2:
    LDB     #' '
    STB     ,U+
    TFR     A,B
    CLRA
    JSR     Dec16
    LDA     #' '
    STA     ,U+
    LDA     LeftCol
    STA     BrCol
    ADDA    #VIS_COLS
    STA     BrEnd
BR_Col:
    PSHS    U
    LDA     DrRow
    LDB     BrCol
    JSR     Format_Cell
    PULS    U
    LDX     #FmtBuf
    JSR     Append
    LDA     #' '
    STA     ,U+
    INC     BrCol
    LDA     BrCol
    CMPA    BrEnd
    BLO     BR_Col
    JSR     Pad_Line
    RTS

; A = ligne, B = colonne : FmtBuf = contenu affiché sur 8 caractères.
Format_Cell:
    PSHS    B
    LDB     #NCOLS
    MUL
    ADDB    ,S+
    ADCA    #0
    STD     FcIdx
    JSR     Type_Of
    LDA     ,X
    STA     FcType
    ANDA    #CT_MASK
    CMPA    #CT_LABEL
    BEQ     FC_Label
    CMPA    #CT_VALUE
    BEQ     FC_Value
    LDX     #TxtVide            ; vide
    BRA     FC_Copy
FC_Label:
    LDD     FcIdx
    JSR     Get_Text
    LDA     ,X
    CMPA    #'"'
    BNE     FC_Copy
    LEAX    1,X
FC_Copy:                        ; X = texte, à gauche, tronqué à 8
    LDU     #FmtBuf
    LDB     #FIELD_W
FC_CL:
    LDA     ,X+
    BEQ     FC_Pad
    STA     ,U+
    DECB
    BNE     FC_CL
    BRA     FC_End
FC_Pad:
    LDA     #' '
FC_PL:
    STA     ,U+
    DECB
    BNE     FC_PL
FC_End:
    CLR     ,U
    RTS
FC_Value:
    LDA     FcType
    BITA    #CT_ERR
    BEQ     FC_Num
    LDX     #TxtErreur
    BRA     FC_Copy
FC_Num:
    LDD     FcIdx
    LSLD
    LSLD
    ADDD    #CellVal
    TFR     D,X
    LDQ     ,X
    JSR     Format_Num          ; NumBuf, longueur dans B
    CMPB    #FIELD_W
    BLS     FC_Right
    LDX     #TxtTrop            ; trop large
    BRA     FC_Copy
FC_Right:                       ; à droite
    LDU     #FmtBuf
    PSHS    B
    LDA     #FIELD_W
    SUBA    ,S+
    BEQ     FC_Digits
    TFR     A,B
    LDA     #' '
FC_RS:
    STA     ,U+
    DECB
    BNE     FC_RS
FC_Digits:
    LDX     #NumBuf
    JSR     Append
    CLR     ,U
    RTS

; Q = valeur (centièmes) -> NumBuf « -123,45 », B = longueur.
; Au-delà de 99999,99 en valeur absolue : longueur 9 (trop large).
Format_Num:
    STQ     Op1
    LDU     #NumBuf
    TST     Op1
    BPL     FN_Pos
    LDA     #'-'
    STA     ,U+
    JSR     Neg_Op1
FN_Pos:
    LDQ     Op1                 ; |v| <= 9 999 999 ?
    CMPD    #$0098
    BHI     FN_Big
    BLO     FN_Ok
    CMPW    #$967F
    BHI     FN_Big
FN_Ok:
    DIVQ    #1000               ; W = |v| / 1000, D = reste (< 1000)
    STD     FnRest
    TSTW
    BEQ     FN_Small
    TFR     W,D                 ; milliers de centièmes : |v|/1000
    JSR     Dec16
    LDD     FnRest
    DIVD    #100                ; B = chiffre (dizaines d'unités), A = reste
    STA     FnCent
    TFR     B,A
    ADDA    #'0'
    STA     ,U+
    BRA     FN_Frac
FN_Small:
    LDD     FnRest
    DIVD    #100                ; B = partie entière (0..9), A = centimes
    STA     FnCent
    TFR     B,A
    ADDA    #'0'
    STA     ,U+
FN_Frac:
    LDA     #','
    STA     ,U+
    LDA     FnCent              ; deux chiffres
    LDB     #'0'-1
FN_Tens:
    INCB
    SUBA    #10
    BCC     FN_Tens
    ADDA    #10+'0'
    STB     ,U+
    STA     ,U+
    CLR     ,U
    TFR     U,D
    SUBD    #NumBuf
    RTS
FN_Big:
    LDB     #FIELD_W+1
    RTS

; Append / Dec16 : lib/str.asm (U = pointeur d'écriture)
    include "../lib/str.asm"

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
TxtTitre:       FCN " VISICALC "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour CALC."
TxtAide:        FCN "Fleches: deplacer  Entree: modifier  /: commandes  Echap: quitter"
TxtCmd:         FCN "/ S:sauver  L:lire  B:vider la cellule  E:effacer tout"
TxtSur:         FCN "Effacer toute la feuille ? (O/N)"
TxtPerdre:      FCN "Feuille non sauvee : quitter quand meme ? (O/N)"
TxtPrompt:      FCN "> "
TxtFichier:     FCN "Fichier : "
TxtDefName:     FCN "FEUILLE.CAL"
TxtSauve:       FCN "Feuille sauvee."
TxtErrSauve:    FCN "Echec de la sauvegarde."
TxtLu:          FCN "Feuille lue."
TxtIntrouvable: FCN "Fichier introuvable."
TxtPasFeuille:  FCN "Ce fichier n'est pas une feuille."
TxtCirc:        FCN "Calcul instable : reference circulaire ?"
TxtDeux:        FCN " : "
TxtVide:        FCN ""
TxtErreur:      FCN "ERREUR"
TxtTrop:        FCN ">>>>>>>>"
Zero:           FCB 0

; --- Variables ---
CurCol          rmb 1
CurRow          rmb 1
LeftCol         rmb 1           ; première colonne visible
HeadEnd         rmb 1
BrEnd           rmb 1
FcType          rmb 1
JmpRow          rmb 1           ; Fin / Ctrl+Fin
JmpCol          rmb 1
JmpIdx          rmb 2
RefDigits       rmb 1
OldRow          rmb 1
Top             rmb 1
GridI           rmb 1
DrRow           rmb 1
DrY             rmb 1
BrCol           rmb 1
FcIdx           rmb 2
MsgPtr          rmb 2
Modified        rmb 1           ; feuille changée depuis la lecture ou la sauvegarde
PPtr            rmb 2           ; analyse : caractère courant
EvalErr         rmb 1
Changed         rmb 1
PassLeft        rmb 1
RcIdx           rmb 2
NewVal          rmb 4
Acc             rmb 4
T1              rmb 4
T2              rmb 4
DigitW          rmb 2           ; chiffre sur 16 bits
Decs            rmb 1
RefCol          rmb 1
RefRow          rmb 1
RcRow           rmb 1
FuncId          rmb 1           ; 0 SUM, 1 MIN, 2 MAX, 3 AVG
R1Row           rmb 1
R1Col           rmb 1
R2Row           rmb 1
R2Col           rmb 1
IterRow         rmb 1
IterCol         rmb 1
Count           rmb 2
FirstVal        rmb 1
Op1             rmb 4
Op2             rmb 4
Sign            rmb 1
M1              rmb 4
M2              rmb 4
P               rmb 8
Dv              rmb 4
R               rmb 4
LoopN           rmb 1
FnRest          rmb 2
FnCent          rmb 1
NumStarted      rmb 1           ; lib/str.asm (Dec16)
DigitCnt        rmb 1           ; lib/str.asm (Dec16)
InBuf           rmb TXT_LEN
TxtTmp          rmb TXT_LEN     ; copie d'un texte lu en page TEXT_PAGE
FileName        rmb 16
FileName15      rmb 16
NumBuf          rmb 16
FmtBuf          rmb FIELD_W+1
Line            rmb LINE_W+2
CellType        rmb NCELLS      ; CT_* (bit 7 : erreur)
CellVal         rmb NCELLS*4    ; valeurs en centièmes

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
