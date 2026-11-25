; ===================================================================
; EDIT.ASM - Editeur de texte à la WordStar pour OSM-VISION
; ===================================================================
; Application d'OSM-VISION (modèle apps/mire.asm) : liée à $4000,
; contrôle de version, sortie par RTS. Lancée par l'action « Editer »
; d'OSM-VISION avec le nom du fichier en argument (argv[1]) ; sans
; argument, texte vide, le nom est demandé à la sauvegarde.
;
; TEXTE : tampon à trou (gap buffer) de 64 Ko dans les pages de RAM 2 et
; 3, repéré par un décalage 16 bits : physique 0..$7FFF = page 2,
; $8000..$FFFE = page 3. Le texte logique est [0, GapS) suivi de
; [GapE, BUF_END). Insérer ou effacer au curseur ne touche qu'un octet ;
; déplacer le curseur fait glisser le texte d'un côté du trou à l'autre,
; par blocs de CHUNK octets (sys_FarRead / sys_FarWrite).
; Fins de ligne : LF ($0A), comme les fichiers de la machine.
;
; FICHIERS : jusqu'à FILE_MAX octets (64 Ko moins 256 : le trou garde
; de quoi éditer). FS_LoadFile / FS_SaveFile passent d'une page à la
; suivante en $8000 (BIOS du 10 oct. 2026 ou plus récent : un BIOS plus
; ancien ne doit pas lire ni écrire plus de 32 Ko). Le fichier est lu en
; FIN de tampon, physique [$FFFF-taille, $FFFF), le trou devant, curseur
; en haut : il commence en page 2 s'il dépasse 32 Ko. Pour sauver, le trou
; est d'abord poussé en fin de texte : le texte est alors d'un seul
; tenant à partir du début de la page 2. Les attributs sont conservés.
;
; TOUCHES (WordStar) :
;   flèches, ou Ctrl+E haut, Ctrl+X bas, Ctrl+S gauche, Ctrl+D droite
;   Ctrl+R page précédente, Ctrl+C page suivante (la vue défile avec)
;   Ctrl+Q R début du fichier, Ctrl+Q C fin du fichier
;   (BIOS récent) Début / Fin de ligne, Ctrl+Début / Ctrl+Fin du fichier,
;   Page préc. / suiv., Suppr
;   Retour arrière, Ctrl+G efface sous le curseur, Ctrl+Y efface la ligne
;   Ctrl+K S sauver, Ctrl+K X sauver et sortir, Ctrl+K Q sortir sans
;   sauver ; Echap = Ctrl+K Q (confirmation si le texte est modifié)
;   Ctrl+K L ouvrir un autre fichier (son nom est demandé)
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Input
VIS_REQUIS      equ (vis_Input/2)+1

; --- Tampon ---
PAGE_LO         equ 2           ; pages 2 et 3
BUF_END         equ $FFFF       ; fin (exclue) du tampon
CHUNK           equ 256         ; bloc de déplacement du trou
LBUF            equ 255         ; caractères lus pour afficher une ligne
FILE_MAX        equ BUF_END-256 ; taille de fichier lisible / sauvable
LF              equ $0A

; --- Écran : fenêtre pleine largeur, lignes 1 à 23 (ombre en 24) ---
WIN_X           equ 0
WIN_Y           equ 1
WIN_W           equ 79
WIN_H           equ 23
ROW_MSG         equ WIN_Y+1     ; messages, aide de Ctrl+K, saisies
ROW_STATUS      equ WIN_Y+2     ; nom, ligne, colonne
ROW_TEXT        equ WIN_Y+3
TEXT_ROWS       equ WIN_H-4     ; 19 lignes de texte
TEXT_X          equ 1
TEXT_W          equ 77
LINE_W          equ 77
ATTR_HEAD       equ $0B         ; ligne d'état : cyan vif

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
    JSR     Reset_Text
    CLR     HasName
    CLR     FileName
    LDX     #TxtVide
    STX     MsgPtr
    LDA     >argc               ; un nom de fichier en argument ?
    CMPA    #2
    BLO     AS_Draw
    LDX     >argv+2
    LDU     #FileName
    LDB     #15
AS_Copy:
    LDA     ,X+
    BEQ     AS_Copied
    CMPA    #' '
    BEQ     AS_Copied
    STA     ,U+
    DECB
    BNE     AS_Copy
AS_Copied:
    CLR     ,U
    LDA     #1
    STA     HasName
    JSR     Load_File
    BCC     AS_Draw
    LDY     #TxtTitre           ; trop gros ou illisible : on ne l'ouvre
                                ; pas (une sauvegarde l'écraserait)
    JSR     [VIS_TABLE+vis_MsgBox]
    RTS
AS_Draw:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Draw_Text
    JSR     Draw_Status

; -------------------------------------------------------------------
; Boucle principale
; -------------------------------------------------------------------
Main_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     Main_Loop
    PSHS    A
    LDD     CurLine             ; position avant la touche
    STD     OldLine
    LDD     LineStart
    STD     OldLS
    CLR     FullDraw
    LDX     #TxtVide
    STX     MsgPtr
    PULS    A
    JSR     Do_Key
    TST     QuitNow
    BEQ     ML_View
    RTS                         ; OSM-VISION restaure l'écran
ML_View:
    JSR     Fix_View
    TST     FullDraw
    BEQ     ML_Lines
    JSR     Draw_Text
    BRA     ML_Status
ML_Lines:
    LDD     CurLine             ; ligne quittée : sans curseur
    CMPD    OldLine
    BEQ     ML_Cur
    LDD     OldLine
    SUBD    TopLine
    CMPD    #TEXT_ROWS
    BHS     ML_Cur
    STB     DlRow
    LDD     OldLS
    JSR     Draw_Line
ML_Cur:
    JSR     Draw_Cur_Line
ML_Status:
    JSR     Draw_Status
    BRA     Main_Loop

; A = touche.
Do_Key:
    CLR     QuitNow
    CMPA    #$80
    LBEQ    Op_Up
    CMPA    #$05                ; Ctrl+E
    LBEQ    Op_Up
    CMPA    #$81
    LBEQ    Op_Down
    CMPA    #$18                ; Ctrl+X
    LBEQ    Op_Down
    CMPA    #$82
    LBEQ    Op_Left
    CMPA    #$13                ; Ctrl+S
    LBEQ    Op_Left
    CMPA    #$83
    LBEQ    Op_Right
    CMPA    #$04                ; Ctrl+D
    LBEQ    Op_Right
    CMPA    #$12                ; Ctrl+R
    LBEQ    Op_PgUp
    CMPA    #KEY_PGUP
    LBEQ    Op_PgUp
    CMPA    #KEY_PGDN
    LBEQ    Op_PgDn
    CMPA    #KEY_HOME           ; Début / Fin de la ligne
    LBEQ    Op_Home
    CMPA    #KEY_END
    LBEQ    Op_End
    CMPA    #KEY_CHOME          ; Ctrl+Début / Ctrl+Fin : du texte
    LBEQ    OQ_Top
    CMPA    #KEY_CEND
    LBEQ    OQ_End
    CMPA    #KEY_DEL
    LBEQ    Op_Del
    CMPA    #$03                ; Ctrl+C
    LBEQ    Op_PgDn
    CMPA    #$08                ; Retour arrière
    LBEQ    Op_Back
    CMPA    #$07                ; Ctrl+G
    LBEQ    Op_Del
    CMPA    #$19                ; Ctrl+Y
    LBEQ    Op_DelLine
    CMPA    #$0D                ; Entrée
    LBEQ    Op_Enter
    CMPA    #$0B                ; Ctrl+K : commande de bloc / fichier
    LBEQ    Op_CtrlK
    CMPA    #$11                ; Ctrl+Q : début / fin du fichier
    LBEQ    Op_CtrlQ
    CMPA    #$1B                ; Echap = Ctrl+K Q
    LBEQ    Op_Quit
    CMPA    #$09                ; tabulation
    BEQ     DK_Ins
    CMPA    #$20
    BLO     DK_End
    CMPA    #$7F
    BEQ     DK_End
DK_Ins:
    JSR     Insert_Char         ; caractère imprimable
DK_End:
    RTS

; -------------------------------------------------------------------
; Opérations
; -------------------------------------------------------------------
Op_Left:
    LDD     GapS
    BEQ     OL_End
    SUBD    #1
    JSR     Char_At
    PSHS    A
    LDD     #1
    JSR     Move_Left_N
    PULS    A
    CMPA    #LF
    BNE     OL_End
    LDD     CurLine             ; on remonte en fin de ligne précédente
    SUBD    #1
    STD     CurLine
    LDD     GapS
    JSR     Find_Line_Start
    STD     LineStart
OL_End:
    RTS

Op_Right:
    LDD     GapE
    CMPD    #BUF_END
    BEQ     OR_End              ; fin du texte
    LDD     GapS
    JSR     Char_At
    PSHS    A
    LDD     #1
    JSR     Move_Right_N
    PULS    A
    CMPA    #LF
    BNE     OR_End
    LDD     CurLine
    ADDD    #1
    STD     CurLine
    LDD     GapS
    STD     LineStart
OR_End:
    RTS

Op_Up:
    LDD     LineStart
    BEQ     OU_End              ; première ligne
    LDD     GapS                ; colonne
    SUBD    LineStart
    STD     OpCol
    LDD     LineStart           ; fin de la ligne précédente (son LF)
    SUBD    #1
    STD     OpEnd
    JSR     Find_Line_Start
    STD     OpStart
    LDD     OpEnd               ; longueur de la ligne précédente
    SUBD    OpStart
    CMPD    OpCol
    BLS     OU_Len
    LDD     OpCol
OU_Len:
    ADDD    OpStart
    JSR     Move_To
    LDD     OpStart
    STD     LineStart
    LDD     CurLine
    SUBD    #1
    STD     CurLine
OU_End:
    RTS

Op_Down:
    LDD     GapS
    SUBD    LineStart
    STD     OpCol
    LDD     GapS
    JSR     Find_Line_End
    STD     OpEnd
    JSR     Text_Len
    CMPD    OpEnd
    BEQ     OD_End              ; dernière ligne
    LDD     OpEnd
    ADDD    #1
    STD     OpStart
    JSR     Find_Line_End       ; fin de la ligne suivante
    SUBD    OpStart
    CMPD    OpCol
    BLS     OD_Len
    LDD     OpCol
OD_Len:
    ADDD    OpStart
    JSR     Move_To
    LDD     OpStart
    STD     LineStart
    LDD     CurLine
    ADDD    #1
    STD     CurLine
OD_End:
    RTS

; Début / Fin : début / fin de la ligne du curseur.
Op_Home:
    LDD     LineStart
    JSR     Move_To
    RTS
Op_End:
    LDD     GapS
    JSR     Find_Line_End
    JSR     Move_To
    RTS

; Ctrl+R / Ctrl+C : la vue et le curseur défilent ensemble d'une page,
; le curseur garde sa rangée à l'écran (WordStar). En haut du texte, la
; vue s'arrête à la ligne 1.
Op_PgUp:
    JSR     Page_Row            ; rangée du curseur à l'écran
    LDA     #TEXT_ROWS-1
    STA     OpCount
OPU_Loop:
    JSR     Op_Up
    DEC     OpCount
    BNE     OPU_Loop
    BRA     Page_View

Op_PgDn:
    JSR     Page_Row
    LDA     #TEXT_ROWS-1
    STA     OpCount
OPD_Loop:
    JSR     Op_Down
    DEC     OpCount
    BNE     OPD_Loop
Page_View:
    LDD     CurLine             ; nouvelle ligne du haut = CurLine - rangée
    SUBD    PgRow
    BHI     PV_Top              ; >= 1
    LDD     #1
PV_Top:
    JSR     Set_Top
    RTS

Page_Row:
    LDD     CurLine
    SUBD    TopLine
    STD     PgRow
    RTS

; D = nouvelle ligne du haut (<= CurLine, à moins d'une page) : TopLine,
; TopPos recalculé en remontant depuis la ligne du curseur.
Set_Top:
    STD     TopLine
    LDD     CurLine
    SUBD    TopLine
    STB     OpCount             ; lignes à remonter (< TEXT_ROWS)
    LDD     LineStart
    STD     FvPos
ST_Back:
    TST     OpCount
    BEQ     ST_Done
    LDD     FvPos
    SUBD    #1
    JSR     Find_Line_Start
    STD     FvPos
    DEC     OpCount
    BRA     ST_Back
ST_Done:
    LDD     FvPos
    STD     TopPos
    LDA     #1
    STA     FullDraw
    RTS

; Ctrl+Q puis R (début du fichier) ou C (fin du fichier).
Op_CtrlQ:
    LDX     #TxtCtrlQ
    STX     MsgPtr
    JSR     Draw_Status
OQK_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     OQK_Key
    LDX     #TxtVide
    STX     MsgPtr
    CMPA    #$12                ; Ctrl+R accepté aussi
    BEQ     OQ_Top
    CMPA    #$03                ; Ctrl+C
    BEQ     OQ_End
    ANDA    #$DF
    CMPA    #'R'
    BEQ     OQ_Top
    CMPA    #'C'
    BEQ     OQ_End
    RTS
OQ_Top:
    CLRD
    JSR     Move_To
    CLRD
    STD     LineStart
    LDD     #1
    STD     CurLine
    RTS
OQ_End:
    JSR     Text_Len
    JSR     Move_To
    JSR     Count_Lines         ; ligne = 1 + nombre de LF avant le curseur
    STD     CurLine
    LDD     GapS
    JSR     Find_Line_Start
    STD     LineStart
    RTS

; D = 1 + nombre de LF dans [0, GapS) (texte avant le trou : physique =
; logique), lu par blocs de LBUF.
Count_Lines:
    LDD     #1
    STD     ClCount
    CLRD
    STD     ClPos
CL_Block:
    LDD     GapS
    SUBD    ClPos
    BEQ     CL_End
    CMPD    #LBUF
    BLS     CL_N
    LDD     #LBUF
CL_N:
    STB     ClN
    TFR     D,U
    LDD     ClPos
    LDY     #LBuf
    JSR     Get_Phys
    LDX     #LBuf
    LDB     ClN
CL_Scan:
    LDA     ,X+
    CMPA    #LF
    BNE     CL_Next
    PSHS    B
    LDD     ClCount
    ADDD    #1
    STD     ClCount
    PULS    B
CL_Next:
    DECB
    BNE     CL_Scan
    CLRA
    LDB     ClN
    ADDD    ClPos
    STD     ClPos
    BRA     CL_Block
CL_End:
    LDD     ClCount
    RTS

Op_Enter:
    LDA     #LF
    JSR     Insert_Char
    BCS     OE_End
    LDD     CurLine
    ADDD    #1
    STD     CurLine
    LDD     GapS
    STD     LineStart
    LDA     #1
    STA     FullDraw
OE_End:
    RTS

Op_Back:
    LDD     GapS
    BEQ     OB_End
    SUBD    #1
    JSR     Char_At
    PSHS    A
    LDD     GapS                ; le caractère passe dans le trou
    SUBD    #1
    STD     GapS
    LDA     #1
    STA     Modified
    PULS    A
    CMPA    #LF
    BNE     OB_End
    LDD     CurLine             ; deux lignes jointes
    SUBD    #1
    STD     CurLine
    LDD     GapS
    JSR     Find_Line_Start
    STD     LineStart
    LDA     #1
    STA     FullDraw
OB_End:
    RTS

Op_Del:
    LDD     GapE
    CMPD    #BUF_END
    BEQ     ODl_End
    LDD     GapS
    JSR     Char_At
    PSHS    A
    LDD     GapE
    ADDD    #1
    STD     GapE
    LDA     #1
    STA     Modified
    PULS    A
    CMPA    #LF
    BNE     ODl_End
    LDA     #1
    STA     FullDraw
ODl_End:
    RTS

; Ctrl+Y : la ligne entière, LF compris.
Op_DelLine:
    LDD     LineStart
    JSR     Move_To
    LDD     GapS
    JSR     Find_Line_End       ; D = position du LF (ou fin)
    STD     OpEnd
    JSR     Text_Len
    CMPD    OpEnd
    BEQ     ODL_NoLF
    LDD     OpEnd
    ADDD    #1
    STD     OpEnd
ODL_NoLF:
    LDD     OpEnd               ; autant de caractères en moins après le trou
    SUBD    GapS
    ADDD    GapE
    STD     GapE
    LDA     #1
    STA     Modified
    STA     FullDraw
    RTS

; Ctrl+K puis S, X ou Q.
Op_CtrlK:
    LDX     #TxtCtrlK
    STX     MsgPtr
    JSR     Draw_Status
OK_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     OK_Key
    CMPA    #$13                ; Ctrl+S, Ctrl+X, Ctrl+Q acceptés aussi
    BEQ     OK_Save
    CMPA    #$18
    BEQ     OK_Exit
    CMPA    #$11
    BEQ     Op_Quit
    ANDA    #$DF
    CMPA    #'S'
    BEQ     OK_Save
    CMPA    #'X'
    BEQ     OK_Exit
    CMPA    #'Q'
    BEQ     Op_Quit
    CMPA    #'L'
    BEQ     Op_Load
    CMPA    #$0C&$DF            ; Ctrl+L (après le ANDA)
    BEQ     Op_Load
    LDX     #TxtVide
    STX     MsgPtr
    RTS
OK_Save:
    JSR     Save_File
    RTS
OK_Exit:
    JSR     Save_File
    BCS     OKE_End             ; échec : on reste
    LDA     #1
    STA     QuitNow
OKE_End:
    RTS

; Sortie sans sauver : confirmation si le texte est modifié.
Op_Quit:
    TST     Modified
    BEQ     OQ_Yes
    LDX     #TxtPerdre
    STX     MsgPtr
    JSR     Draw_Status
OQ_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     OQ_Key
    ANDA    #$DF
    CMPA    #'O'
    BEQ     OQ_Yes
    LDX     #TxtVide
    STX     MsgPtr
    RTS
OQ_Yes:
    LDA     #1
    STA     QuitNow
    RTS

; Ctrl+K L : ouvrir un autre fichier. Confirmation si le texte est modifié,
; puis le nom (tampon à part : Echap garde le nom en cours). Fichier absent :
; texte vide sous ce nom. Illisible ou trop gros : texte vide SANS nom
; (une sauvegarde ne doit pas écraser ce fichier-là).
Op_Load:
    TST     Modified
    BEQ     OL_Name
    LDX     #TxtPerdre
    STX     MsgPtr
    JSR     Draw_Status
OL_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     OL_Key
    ANDA    #$DF
    CMPA    #'O'
    BEQ     OL_Name
    LDX     #TxtVide
    STX     MsgPtr
    RTS
OL_Name:
    LDX     #TxtVide            ; ligne des messages vide sous la saisie
    STX     MsgPtr
    JSR     Draw_Status
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #TEXT_X
    LDB     #ROW_MSG
    LDX     #TxtOuvrir
    LDE     #ATTR_HEAD
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    CLR     NewName
    LDA     #TEXT_X+10
    LDB     #ROW_MSG
    LDX     #NewName
    LDE     #15
    LDF     #INP_MAJ+INP_SANS_ESPACE+INP_NON_VIDE
    LDY     #0
    JSR     [VIS_TABLE+vis_Input]
    BCS     OL_Cancel
    LDX     #NewName            ; le nom devient celui du texte
    LDU     #FileName
OL_Copy:
    LDA     ,X+
    STA     ,U+
    BNE     OL_Copy
    LDA     #1
    STA     HasName
    JSR     Reset_Text
    JSR     Load_File           ; (le moulinet du BIOS tourne pendant la lecture)
    BCC     OL_Ok
    PSHS    X                   ; le message de Load_File
    CLR     HasName             ; illisible ou trop gros
    CLR     FileName
    JSR     Reset_Text
    PULS    X
    BRA     OL_Msg
OL_Ok:
    LDX     #TxtVide
OL_Msg:
    STX     MsgPtr
OL_Cancel:
    LDA     #1
    STA     FullDraw
    RTS

; Texte vide, curseur et vue en haut, rien de modifié.
Reset_Text:
    CLRD
    STD     GapS
    STD     LineStart
    STD     TopPos
    LDD     #BUF_END
    STD     GapE
    LDD     #1
    STD     CurLine
    STD     TopLine
    CLRD
    STD     LeftCol
    CLR     Modified
    RTS

; A = caractère inséré au curseur. C = 1 si le tampon est plein.
Insert_Char:
    STA     OneByte
    LDD     GapS
    CMPD    GapE
    BHS     IC_Full
    LDU     #1
    LDY     #OneByte
    JSR     Put_Phys
    LDD     GapS
    ADDD    #1
    STD     GapS
    LDA     #1
    STA     Modified
    ANDCC   #%11111110
    RTS
IC_Full:
    LDX     #TxtPlein
    STX     MsgPtr
    ORCC    #%00000001
    RTS

; -------------------------------------------------------------------
; Fichiers
; -------------------------------------------------------------------
; FileName -> FileName15, puis lecture. C = 1 si trop gros ou erreur de
; lecture, X = le message qui le dit.
; Fichier absent : texte vide, C = 0 (nouveau fichier).
Load_File:
    LDX     #FileName
    LDY     #FileName15
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #FileName15
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     LF_New
    LDD     >g_find_fileInfo+20 ; mot de poids fort de la taille
    BNE     LF_Big
    CMPU    #FILE_MAX
    BHI     LF_Big
    STU     FileSize
    LDD     #BUF_END            ; texte en fin de tampon : physique
    SUBD    FileSize            ; [$FFFF-taille, $FFFF)
    PSHS    D
    TFR     D,Y                 ; physique -> page (bit 15) et adresse
    LDA     #PAGE_LO
    CMPY    #$8000
    BLO     LF_Page
    LEAY    -$8000,Y
    INCA
LF_Page:
    LDX     #FileName15
    JSR     [table_function_ram+sys_FS_LoadFile]   ; continue en page 3
    PULS    D                   ; (PULS garde C)
    BCS     LF_Err
    STD     GapE                ; le trou devant : curseur en haut
LF_New:
    ANDCC   #%11111110
    RTS
LF_Big:
    LDX     #TxtTropGros
    BRA     LF_Bad
LF_Err:
    LDX     #TxtErrLect         ; le BIOS a refusé ou la carte n'a pas répondu
LF_Bad:
    ORCC    #%00000001
    RTS

; Sauve le texte. C = 1 si abandon ou échec.
Save_File:
    TST     HasName
    BNE     SF_Named
    LDX     #TxtVide            ; ligne des messages vide sous la saisie
    STX     MsgPtr
    JSR     Draw_Status
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #TEXT_X
    LDB     #ROW_MSG
    LDX     #TxtFichier
    LDE     #ATTR_HEAD
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDA     #TEXT_X+10
    LDB     #ROW_MSG
    LDX     #FileName
    LDE     #15
    LDF     #INP_MAJ+INP_SANS_ESPACE+INP_NON_VIDE
    LDY     #0
    JSR     [VIS_TABLE+vis_Input]
    LBCS    SF_Fail
    LDA     #1
    STA     HasName
SF_Named:
    JSR     Text_Len            ; tient toujours : le tampon fait 64 Ko
    STD     FileSize
    LDX     #FileName
    LDY     #FileName15
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDA     #$06                ; attributs : ceux du fichier s'il existe
    STA     FileAttr
    LDX     #FileName15
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     SF_NoOld
    LDA     >g_find_fileInfo+27
    STA     FileAttr
    LDX     #FileName15
    JSR     [table_function_ram+sys_FS_DeleteFile]
SF_NoOld:
    LDD     GapS                ; trou en fin de texte : texte d'un seul
    STD     SavePos             ; tenant au début de la page 2
    LDD     FileSize
    JSR     Move_To
    LDA     #PAGE_LO            ; A = page SOURCE
    LDX     #FileName15
    LDY     #0
    LDU     FileSize
    JSR     [table_function_ram+sys_FS_SaveFile]
    PSHS    CC
    LDD     SavePos             ; le curseur revient
    JSR     Move_To
    PULS    CC
    BCS     SF_Err
    LDX     #FileName15
    LDA     FileAttr
    JSR     [table_function_ram+sys_FS_SetAttributes]
    CLR     Modified
    LDX     #TxtSauve
    STX     MsgPtr
    ANDCC   #%11111110
    RTS
SF_Err:
    LDX     #TxtErrSauve
SF_Msg:
    STX     MsgPtr
SF_Fail:
    LDA     #1
    STA     FullDraw            ; la ligne d'état a pu être écrasée
    ORCC    #%00000001
    RTS

; -------------------------------------------------------------------
; Tampon à trou
; -------------------------------------------------------------------
; D = longueur du texte.
Text_Len:
    LDD     #BUF_END
    SUBD    GapE
    ADDD    GapS
    RTS

; D = position logique -> D = position physique.
Log_To_Phys:
    CMPD    GapS
    BLO     LP_End
    ADDD    GapE
    SUBD    GapS
LP_End:
    RTS

; D = position logique -> A = caractère.
Char_At:
    JSR     Log_To_Phys
    LDU     #1
    LDY     #OneByte
    JSR     Get_Phys
    LDA     OneByte
    RTS

; D = position physique, U = nombre, Y = destination locale.
; Coupe aux frontières de page ($8000).
Get_Phys:
    STD     FpPhys
    STU     FpCnt
    STY     FpLoc
GP_Loop:
    LDD     FpCnt
    BEQ     GP_End
    JSR     Fp_Chunk            ; FpAddr, FpK, A = page
    LDB     >current_page       ; FarRead : A = page source, B = page dest
    LDX     FpAddr
    LDY     FpLoc
    LDU     FpK
    JSR     [table_function_ram+sys_FarRead]
    JSR     Fp_Advance
    BRA     GP_Loop
GP_End:
    RTS

; D = position physique, U = nombre, Y = source locale.
Put_Phys:
    STD     FpPhys
    STU     FpCnt
    STY     FpLoc
PP_Loop:
    LDD     FpCnt
    BEQ     PP_End
    JSR     Fp_Chunk
    LDB     >current_page       ; FarWrite : A = page dest, B = page source
    LDX     FpLoc               ; X = source locale
    LDY     FpAddr              ; Y = destination
    LDU     FpK
    JSR     [table_function_ram+sys_FarWrite]
    JSR     Fp_Advance
    BRA     PP_Loop
PP_End:
    RTS

; Morceau suivant : FpAddr = adresse dans la page, FpK = taille (jusqu'à
; la fin de la page au plus), A = page.
Fp_Chunk:
    LDD     FpPhys
    ANDA    #$7F
    STD     FpAddr
    LDD     #$8000
    SUBD    FpAddr              ; place jusqu'à la fin de la page
    CMPD    FpCnt
    BLS     FC_K
    LDD     FpCnt
FC_K:
    STD     FpK
    LDA     FpPhys              ; bit 15 : page 3
    ROLA
    LDA     #PAGE_LO
    ADCA    #0
    RTS

Fp_Advance:
    LDD     FpPhys
    ADDD    FpK
    STD     FpPhys
    LDD     FpLoc
    ADDD    FpK
    STD     FpLoc
    LDD     FpCnt
    SUBD    FpK
    STD     FpCnt
    RTS

; D = position logique, U = nombre, Y = destination : texte logique
; (de part et d'autre du trou).
Get_Range:
    STD     GrPos
    STU     GrCnt
    STY     GrDst
    LDD     GrCnt
    BEQ     GR_End
    LDD     GrPos
    CMPD    GapS
    BHS     GR_After
    LDD     GapS                ; partie avant le trou
    SUBD    GrPos
    CMPD    GrCnt
    BLS     GR_K
    LDD     GrCnt
GR_K:
    STD     GrK
    LDD     GrPos
    LDU     GrK
    LDY     GrDst
    JSR     Get_Phys
    LDD     GrPos
    ADDD    GrK
    STD     GrPos
    LDD     GrDst
    ADDD    GrK
    STD     GrDst
    LDD     GrCnt
    SUBD    GrK
    STD     GrCnt
    BEQ     GR_End
GR_After:
    LDD     GrPos               ; partie après le trou
    JSR     Log_To_Phys
    LDU     GrCnt
    LDY     GrDst
    JSR     Get_Phys
GR_End:
    RTS

; D = nombre de caractères : le curseur recule (texte avant le trou ->
; après le trou), par blocs de CHUNK via TmpBuf.
Move_Left_N:
    STD     MvN
ML_Loop:
    LDD     MvN
    BEQ     MLN_End
    CMPD    #CHUNK
    BLS     MLN_K
    LDD     #CHUNK
MLN_K:
    STD     MvK
    LDD     GapS
    SUBD    MvK
    STD     GapS
    LDU     MvK
    LDY     #TmpBuf
    JSR     Get_Phys
    LDD     GapE
    SUBD    MvK
    STD     GapE
    LDU     MvK
    LDY     #TmpBuf
    JSR     Put_Phys
    LDD     MvN
    SUBD    MvK
    STD     MvN
    BRA     ML_Loop
MLN_End:
    RTS

; D = nombre de caractères : le curseur avance.
Move_Right_N:
    STD     MvN
MR_Loop:
    LDD     MvN
    BEQ     MRN_End
    CMPD    #CHUNK
    BLS     MRN_K
    LDD     #CHUNK
MRN_K:
    STD     MvK
    LDD     GapE
    LDU     MvK
    LDY     #TmpBuf
    JSR     Get_Phys
    LDD     GapS
    LDU     MvK
    LDY     #TmpBuf
    JSR     Put_Phys
    LDD     GapS
    ADDD    MvK
    STD     GapS
    LDD     GapE
    ADDD    MvK
    STD     GapE
    LDD     MvN
    SUBD    MvK
    STD     MvN
    BRA     MR_Loop
MRN_End:
    RTS

; D = position logique : le curseur (le trou) y va.
Move_To:
    CMPD    GapS
    BEQ     MT_End
    BHI     MT_Right
    STD     MtT
    LDD     GapS
    SUBD    MtT
    JSR     Move_Left_N
    RTS
MT_Right:
    SUBD    GapS
    JSR     Move_Right_N
MT_End:
    RTS

; D = position : début de sa ligne (après le LF précédent, ou 0).
Find_Line_Start:
    STD     FlQ
FLS_Loop:
    LDD     FlQ
    BEQ     FLS_End
    SUBD    #1
    STD     FlT
    JSR     Char_At
    CMPA    #LF
    BEQ     FLS_End
    LDD     FlT
    STD     FlQ
    BRA     FLS_Loop
FLS_End:
    LDD     FlQ
    RTS

; D = position : position de la fin de sa ligne (son LF, ou la fin).
Find_Line_End:
    STD     FlQ
    JSR     Text_Len
    STD     FlLen
FLE_Loop:
    LDD     FlQ
    CMPD    FlLen
    BHS     FLE_End
    JSR     Char_At
    CMPA    #LF
    BEQ     FLE_End
    LDD     FlQ
    ADDD    #1
    STD     FlQ
    BRA     FLE_Loop
FLE_End:
    LDD     FlQ
    RTS

; -------------------------------------------------------------------
; Affichage
; -------------------------------------------------------------------
; Garde le curseur visible : défilements vertical et horizontal.
Fix_View:
    LDD     CurLine
    CMPD    TopLine
    BHS     FV_Below
    STD     TopLine             ; au-dessus : sa ligne en haut
    LDD     LineStart
    STD     TopPos
    LDA     #1
    STA     FullDraw
    BRA     FV_Horiz
FV_Below:
    SUBD    TopLine
    CMPD    #TEXT_ROWS
    BLO     FV_Horiz
    LDD     CurLine             ; en dessous : sa ligne en bas
    SUBD    #TEXT_ROWS-1
    STD     TopLine
    LDD     LineStart
    STD     FvPos
    LDA     #TEXT_ROWS-1
    STA     OpCount
FV_Back:
    LDD     FvPos
    SUBD    #1
    JSR     Find_Line_Start
    STD     FvPos
    DEC     OpCount
    BNE     FV_Back
    LDD     FvPos
    STD     TopPos
    LDA     #1
    STA     FullDraw
FV_Horiz:
    LDD     GapS                ; colonne du curseur
    SUBD    LineStart
    CMPD    LeftCol
    BHS     FV_Right
    STD     LeftCol
    LDA     #1
    STA     FullDraw
    RTS
FV_Right:
    SUBD    LeftCol
    CMPD    #TEXT_W
    BLO     FV_End
    LDD     GapS
    SUBD    LineStart
    SUBD    #TEXT_W-1
    STD     LeftCol
    LDA     #1
    STA     FullDraw
FV_End:
    RTS

; Toutes les lignes, depuis TopPos.
Draw_Text:
    CLR     DlRow
    LDD     TopPos
    STD     DtPos
DT_Loop:
    LDD     DtPos
    CMPD    #$FFFF
    BNE     DT_Line
    JSR     Draw_Blank          ; après la fin du texte
    BRA     DT_Next
DT_Line:
    JSR     Draw_Line
    STD     DtPos               ; début de la ligne suivante
DT_Next:
    INC     DlRow
    LDA     DlRow
    CMPA    #TEXT_ROWS
    BLO     DT_Loop
    RTS

; Ligne du curseur.
Draw_Cur_Line:
    LDD     CurLine
    SUBD    TopLine
    STB     DlRow
    LDD     LineStart
    JSR     Draw_Line
    RTS

; Ligne vide à l'écran (après la fin du texte), rangée DlRow.
Draw_Blank:
    LDU     #Line
    JSR     Pad_Line
    LBRA    DL_Write

; D = début de ligne, DlRow = rangée : affiche la ligne (avec le curseur
; si c'est la sienne). Sortie : D = début de la ligne suivante, ou $FFFF.
Draw_Line:
    STD     DlPos
    JSR     Text_Len
    SUBD    DlPos
    CMPD    #LBUF
    BLS     DL_N
    LDD     #LBUF
DL_N:
    STB     DlN                 ; <= 255
    LDD     DlPos
    CLRA
    LDB     DlN
    TFR     D,U
    LDD     DlPos
    LDY     #LBuf
    JSR     Get_Range
    CLRB                        ; cherche le LF
DL_Find:
    CMPB    DlN
    BHS     DL_NoLF
    LDX     #LBuf
    ABX
    LDA     ,X
    CMPA    #LF
    BEQ     DL_LF
    INCB
    BRA     DL_Find
DL_LF:
    STB     DlLen
    CLRA
    ADDD    DlPos
    ADDD    #1
    STD     DlNext
    BRA     DL_Build
DL_NoLF:
    STB     DlLen
    LDA     DlN
    CMPA    #LBUF
    BHS     DL_Long
    LDD     #$FFFF              ; fin du texte : plus de ligne
    STD     DlNext
    BRA     DL_Build
DL_Long:
    LDD     DlPos               ; ligne plus longue que LBUF
    ADDD    #LBUF
    JSR     Find_Line_End
    STD     DlNext
    JSR     Text_Len
    CMPD    DlNext
    BNE     DL_LongNext
    LDD     #$FFFF
    STD     DlNext
    BRA     DL_Build
DL_LongNext:
    LDD     DlNext
    ADDD    #1
    STD     DlNext
DL_Build:                       ; Line = colonnes LeftCol.. de la ligne
    LDU     #Line
    LDA     LeftCol
    BNE     DL_Pad              ; colonne > 255 : rien à afficher
    LDB     LeftCol+1
DL_Char:
    CMPB    DlLen
    BHS     DL_Pad
    TFR     U,X
    CMPX    #Line+LINE_W
    BHS     DL_Pad
    LDX     #LBuf
    ABX
    LDA     ,X
    CMPA    #$20                ; tabulation et contrôles : espace
    BHS     DL_Put
    LDA     #' '
DL_Put:
    STA     ,U+
    INCB
    BNE     DL_Char
DL_Pad:
    JSR     Pad_Line
DL_Write:
    JSR     Cursor_Prep         ; caractère sous le curseur (hors synchro)
    CLRA                        ; la ligne, puis le curseur par-dessus, composés
    LDX     #Line               ; hors synchro ; un seul TFM dans la trame
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Prep]
    TST     CurOnRow
    BEQ     DL_NoCur
    LDA     CurX
    SUBA    #TEXT_X
    LDX     #CurStr
    LDE     #COLOR_SEL
    JSR     [VIS_TABLE+vis_Prep]
DL_NoCur:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #TEXT_X
    LDB     DlRow
    ADDB    #ROW_TEXT
    JSR     [VIS_TABLE+vis_Ligne]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDD     DlNext
    RTS

; CurOnRow <> 0 si le curseur est sur la rangée DlRow ; CurX, CurStr.
Cursor_Prep:
    CLR     CurOnRow
    LDD     CurLine
    SUBD    TopLine
    CMPB    DlRow
    BNE     CP_End
    TSTA
    BNE     CP_End
    INC     CurOnRow
    LDD     GapS
    SUBD    LineStart
    SUBD    LeftCol
    ADDB    #TEXT_X
    STB     CurX
    LDA     #' '
    STA     CurStr
    CLR     CurStr+1
    JSR     Text_Len
    CMPD    GapS
    BEQ     CP_End              ; en fin de texte : un blanc
    LDD     GapS
    JSR     Char_At
    CMPA    #$20
    BLO     CP_End
    STA     CurStr
CP_End:
    RTS

; Ligne d'état : nom, ligne, colonne, modifié, message.
Draw_Status:
    LDU     #Line
    LDA     #' '
    STA     ,U+
    TST     HasName
    BEQ     DS_NoName
    LDX     #FileName
    BRA     DS_Name
DS_NoName:
    LDX     #TxtSansNom
DS_Name:
    JSR     Append
    LDX     #TxtLigne
    JSR     Append
    LDD     CurLine
    JSR     Dec16
    LDX     #TxtCol
    JSR     Append
    LDD     GapS
    SUBD    LineStart
    ADDD    #1
    JSR     Dec16
    TST     Modified
    BEQ     DS_Msg
    LDX     #TxtModif
    JSR     Append
DS_Msg:
    JSR     Pad_Line
    CLRA                        ; la ligne composée hors synchro (vis_Prep),
    LDX     #Line               ; copiée par TFM dans la trame (vis_Ligne)
    LDE     #ATTR_HEAD
    JSR     [VIS_TABLE+vis_Prep]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #TEXT_X
    LDB     #ROW_STATUS
    JSR     [VIS_TABLE+vis_Ligne]
    JSR     [VIS_TABLE+vis_Sync_End]
    ; les messages sur leur propre ligne, sous la barre de titre
    LDU     #Line
    LDA     #' '
    STA     ,U+
    LDX     MsgPtr
    JSR     Append
    JSR     Pad_Line
    CLRA                        ; la ligne composée hors synchro (vis_Prep),
    LDX     #Line               ; copiée par TFM dans la trame (vis_Ligne)
    LDE     #ATTR_HEAD
    JSR     [VIS_TABLE+vis_Prep]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #TEXT_X
    LDB     #ROW_MSG
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

; Append / Dec16 : lib/str.asm (U = pointeur d'écriture)
    include "../lib/str.asm"

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
TxtTitre:       FCN " EDIT "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour EDIT."
TxtTropGros:    FCN "Fichier trop grand : 65279 octets au plus."
TxtErrLect:     FCN "Erreur de lecture sur la carte SD."
TxtVide:        FCN ""
TxtSansNom:     FCN "(sans nom)"
TxtLigne:       FCN "   Ligne "
TxtCol:         FCN "  Col "
TxtModif:       FCN "  *modifie*"
TxtCtrlK:       FCN "^K : S sauver  X sauver et sortir  L ouvrir  Q sortir"
TxtCtrlQ:       FCN "^Q : R debut du fichier  C fin du fichier"
TxtPerdre:      FCN "Abandonner les modifications ? (O/N)"
TxtFichier:     FCN "Fichier : "
TxtOuvrir:      FCN "Ouvrir  : "
TxtSauve:       FCN "Fichier sauve."
TxtErrSauve:    FCN "Echec de la sauvegarde."
TxtPlein:       FCN "Texte plein (64 Ko)."

; --- Variables ---
GapS            rmb 2           ; début du trou = curseur
GapE            rmb 2           ; fin du trou
CurLine         rmb 2           ; ligne du curseur (1 = première)
LineStart       rmb 2           ; début de la ligne du curseur
TopLine         rmb 2           ; ligne en haut de l'écran
TopPos          rmb 2           ; son début
LeftCol         rmb 2           ; première colonne affichée
OldLine         rmb 2
OldLS           rmb 2
Modified        rmb 1
HasName         rmb 1
QuitNow         rmb 1
FullDraw        rmb 1
MsgPtr          rmb 2
OpCol           rmb 2
OpEnd           rmb 2
OpStart         rmb 2
OpCount         rmb 1
OneByte         rmb 1
FileSize        rmb 2
FileAttr        rmb 1
SavePos         rmb 2
FpPhys          rmb 2
FpCnt           rmb 2
FpLoc           rmb 2
FpAddr          rmb 2
FpK             rmb 2
GrPos           rmb 2
GrCnt           rmb 2
GrDst           rmb 2
GrK             rmb 2
MvN             rmb 2
MvK             rmb 2
MtT             rmb 2
FlQ             rmb 2
FlT             rmb 2
FlLen           rmb 2
FvPos           rmb 2
DtPos           rmb 2
PgRow           rmb 2
ClCount         rmb 2
ClPos           rmb 2
ClN             rmb 1
DlRow           rmb 1
DlPos           rmb 2
DlN             rmb 1
DlLen           rmb 1
DlNext          rmb 2
CurOnRow        rmb 1
CurX            rmb 1
CurStr          rmb 2
NumStarted      rmb 1           ; lib/str.asm (Dec16)
DigitCnt        rmb 1           ; lib/str.asm (Dec16)
FileName        rmb 16
NewName         rmb 16          ; Ctrl+K L : nom saisi
FileName15      rmb 16
Line            rmb LINE_W+2
LBuf            rmb LBUF+1
TmpBuf          rmb CHUNK

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
