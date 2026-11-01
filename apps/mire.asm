; ===================================================================
; MIRE.ASM - Application modèle d'OSM-VISION, et outil de diagnostic
; ===================================================================
; MODÈLE : partir de ce fichier pour écrire une application. Tout ce
; qu'une application doit faire y est, dans l'ordre :
;   1. point d'entrée à l'offset 0 (lié à $4000, apps/Makefile le vérifie) ;
;   2. vérifier que l'OSM-VISION chargé offre les services utilisés ;
;   3. dessiner par les services vis_* (lib/vis.inc), jamais en direct ;
;   4. rendre la main par RTS, SANS effacer l'écran : OSM-VISION a
;      sauvegardé les deux plans avant l'appel et les restaure après.
; Sur la carte : attributs rwxa ($17), page 0, adresse $4000
; (deploy_sd.sh et tools/egofs/egofs_deploy.py s'en chargent).
;
; DIAGNOSTIC : la fenêtre affiche le code de chaque touche reçue et
; l'historique des 8 dernières (Ctrl+F doit donner $06).
;   N      écran noir, IRQ actives   (comme l'écran GAME OVER de BRIQUES)
;   M      écran noir, IRQ masquées  (comme le banc test/)
;   S      essai de saisie (vis_Input avec INP_CTRL : une touche de
;          contrôle rend la main, son code s'affiche)
;   T      l'écran de BRIQUES SANS briques, sur l'écran d'OSM-VISION tel
;          que BRIQUES le trouve ; chaque touche retire un élément
;          (1 complet, 2 sans textes, 3 sans parois, 4 sans case page 0)
;   C      test des instructions MULD, DIVD et DIVQ du 6309 (certains
;          lots seraient défectueux) : 48 cas chacune, résultats attendus
;          calculés par Python ; bilan et premier échec en détail
;   P      cinq essais indépendants sur le puits de la réplique :
;          1 référence $20/$00 (page 0), 2 puits $00/$80 (page 1 noir),
;          3 puits $20/$08 (page 0, premier plan gris), 4 sans titre,
;          5 sur écran noir (sans OSM-VISION derrière)
;   Echap  retour à OSM-VISION
; Les deux écrans noirs servent à l'enquête sur les traits du puits de
; BRIQUES : traits avec N et pas avec M = activité de l'IRQ.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Input
VIS_REQUIS      equ (vis_Input/2)+1

WIN_X           equ 14          ; fenêtre 52 x 18 (ombre : 53 x 19)
WIN_Y           equ 3
WIN_W           equ 52
WIN_H           equ 21
LBL_X           equ WIN_X+2     ; colonne des libellés
VAL_X           equ WIN_X+20    ; colonne des valeurs (une espace après le « : »)
ROW_KEY         equ WIN_Y+3
ROW_HIST        equ WIN_Y+4
ROW_INPUT       equ WIN_Y+13
ROW_OUT         equ WIN_Y+15
ROW_CALC        equ WIN_Y+17        ; touche C : bilan
ROW_CALC2       equ WIN_Y+18        ; touche C : premier échec
CALC_N          equ 48              ; cas par instruction (tables générées)
CALC_W          equ 47              ; largeur des lignes de la touche C
INPUT_X         equ WIN_X+11
INPUT_MAX       equ 24
HIST_N          equ 8           ; touches gardées dans l'historique
LINE_W          equ 30          ; largeur des valeurs (efface l'ancienne)
ASCII_0         equ $30         ; lib/str.asm (Hex8)
; --- Réplique de l'écran de BRIQUES (mêmes valeurs que games/briques.asm) ---
T_WIN_X         equ 24
T_WIN_Y         equ 1
T_WIN_W         equ 32
T_WIN_H         equ 23
T_BOARD_X       equ T_WIN_X+2       ; puits : 20 colonnes x 20 lignes
T_BOARD_Y       equ T_WIN_Y+2
T_BOARD_W       equ 20
T_BOARD_H       equ 20
T_PANEL_X       equ T_WIN_X+24
T_ETAPE_X       equ 68              ; « ETAPE n/4 », sur le bureau
T_ETAPE_Y       equ 24

    section .code

; -------------------------------------------------------------------
; 1. POINT D'ENTRÉE (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    ; 2. L'OSM-VISION chargé connaît-il tous les services appelés ?
    LDA     >VIS_COUNT_ADR      ; '>' : adressage étendu, pas direct
    CMPA    #VIS_REQUIS
    BHS     AS_VisOk
    CMPA    #(vis_MsgBox/2)+1
    BLO     AS_Abandon          ; pas même la boîte de message : retour sec
    LDX     #TxtVisVieux
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_MsgBox]
AS_Abandon:
    RTS
AS_VisOk:
    LDX     #History            ; historique vide
    LDB     #HIST_N
AS_Clr:
    CLR     ,X+
    DECB
    BNE     AS_Clr
    CLR     LastKey
    ; L'écran d'OSM-VISION tel qu'une application le trouve : gardé pour
    ; la réplique de BRIQUES (touche T).
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    CLRB
    LDW     #(80*256)+25
    LDX     #OrigBuf
    JSR     [VIS_TABLE+vis_Rect_Save]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Draw_Main

; -------------------------------------------------------------------
; Boucle principale : une touche, son code, l'action éventuelle
; -------------------------------------------------------------------
Main_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     Main_Loop
    CMPA    #$1B                ; Echap : retour à OSM-VISION
    BEQ     Quit
    JSR     Record_Key          ; préserve A
    ANDA    #$DF                ; minuscule -> majuscule (lettres seules)
    CMPA    #'N'
    LBEQ    Do_Noir
    CMPA    #'M'
    LBEQ    Do_Noir_Masque
    CMPA    #'S'
    LBEQ    Do_Saisie
    CMPA    #'T'
    LBEQ    Do_Briques
    CMPA    #'P'
    LBEQ    Do_Puits
    CMPA    #'C'
    LBEQ    Do_Calcul
    CMPA    #'V'
    LBEQ    Do_Crtc
Main_Refresh:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    JSR     Show_Keys
    JSR     [VIS_TABLE+vis_Sync_End]
    BRA     Main_Loop

; 4. Sortie : RTS, rien à effacer (OSM-VISION restaure l'écran).
Quit:
    RTS

; -------------------------------------------------------------------
; Écrans noirs : tout l'écran sauvegardé (vis_Rect_Save, 4000 octets
; dans ScreenBuf), peint en $20/$00, une touche, puis restauré.
; -------------------------------------------------------------------
Do_Noir:
    JSR     Ecran_Noir
DN_Wait:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     DN_Wait
    JSR     Ecran_Rendu
    BRA     Main_Refresh

Do_Noir_Masque:
    JSR     Ecran_Noir
    ORCC    #%00010000          ; IRQ masquées : plus d'IRQ VSYNC du BIOS
DM_Wait:                        ; le clavier arrive par NMI : il marche encore
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     DM_Wait
    ANDCC   #%11101111          ; Ecran_Rendu a besoin du VSYNC
    JSR     Ecran_Rendu
    BRA     Main_Refresh

Ecran_Noir:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    CLRB
    LDW     #(80*256)+25
    LDX     #ScreenBuf
    JSR     [VIS_TABLE+vis_Rect_Save]
    LDW     #(80*256)+25        ; vis_Rect_Save détruit W
    LDY     #$2000              ; caractère $20, attribut $00 : noir sur noir
    JSR     [VIS_TABLE+vis_Fill]
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

Ecran_Rendu:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    CLRB
    LDW     #(80*256)+25
    LDX     #ScreenBuf
    JSR     [VIS_TABLE+vis_Rect_Restore]
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; -------------------------------------------------------------------
; Saisie : vis_Input avec INP_CTRL. Affiche la touche de sortie et la
; longueur ; Echap s'affiche en clair.
; -------------------------------------------------------------------
Do_Saisie:
    CLR     InBuf
    LDA     #INPUT_X
    LDB     #ROW_INPUT
    LDX     #InBuf
    LDE     #INPUT_MAX
    LDF     #INP_CTRL
    LDY     #0
    JSR     [VIS_TABLE+vis_Input]
    STB     InLen
    LDU     #Line
    BCS     DS_Esc
    STA     OutKey
    LDX     #TxtSortie
    JSR     Append
    LDA     OutKey
    JSR     Hex8
    LDX     #TxtLong
    JSR     Append
    LDA     InLen
    JSR     Hex8
    BRA     DS_Show
DS_Esc:
    LDX     #TxtEchap
    JSR     Append
DS_Show:
    JSR     Pad_Line
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #VAL_X
    LDB     #ROW_OUT
    LDX     #Line
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    LBRA    Main_Loop

; -------------------------------------------------------------------
; C : MULD, DIVD et DIVQ du 6309 contre des résultats calculés par Python
; (tables TabMuld / TabDivd / TabDivq en fin de fichier). Bilan sur
; ROW_CALC, premier échec en détail sur ROW_CALC2.
; -------------------------------------------------------------------
Do_Calcul:
    CLR     FailType
    ; MULD : Q = D * mot
    CLR     OkMuld
    LDX     #TabMuld
    LDB     #CALC_N
DC_Mul:
    PSHS    B
    LDD     ,X
    MULD    2,X
    STQ     CalcRes
    LDD     CalcRes
    CMPD    4,X
    BNE     DC_MulBad
    LDD     CalcRes+2
    CMPD    6,X
    BNE     DC_MulBad
    INC     OkMuld
    BRA     DC_MulNext
DC_MulBad:
    LDA     #'M'
    JSR     Calc_Fail
DC_MulNext:
    LEAX    8,X
    PULS    B
    DECB
    BNE     DC_Mul
    ; DIVD : D / octet -> B quotient, A reste
    CLR     OkDivd
    LDX     #TabDivd
    LDB     #CALC_N
DC_Divd:
    PSHS    B
    LDD     ,X
    DIVD    2,X
    STD     CalcRes             ; A = reste, B = quotient
    LDA     CalcRes+1
    CMPA    3,X
    BNE     DC_DivdBad
    LDA     CalcRes
    CMPA    4,X
    BNE     DC_DivdBad
    INC     OkDivd
    BRA     DC_DivdNext
DC_DivdBad:
    LDA     #'D'
    JSR     Calc_Fail
DC_DivdNext:
    LEAX    5,X
    PULS    B
    DECB
    BNE     DC_Divd
    ; DIVQ : Q / mot -> W quotient, D reste
    CLR     OkDivq
    LDX     #TabDivq
    LDB     #CALC_N
DC_Divq:
    PSHS    B
    LDQ     ,X
    DIVQ    4,X
    STW     CalcRes             ; quotient
    STD     CalcRes+2           ; reste
    LDD     CalcRes
    CMPD    6,X
    BNE     DC_DivqBad
    LDD     CalcRes+2
    CMPD    8,X
    BNE     DC_DivqBad
    INC     OkDivq
    BRA     DC_DivqNext
DC_DivqBad:
    LDA     #'Q'
    JSR     Calc_Fail
DC_DivqNext:
    LEAX    10,X
    PULS    B
    DECB
    BNE     DC_Divq
    JSR     Calc_Show
    LBRA    Main_Refresh

; A = 'M', 'D' ou 'Q' : garde le premier échec (type, cas, résultat
; obtenu dans CalcRes). Préserve X.
Calc_Fail:
    TST     FailType
    BNE     CF_End
    STA     FailType
    STX     FailPtr
    LDD     CalcRes
    STD     FailRes
    LDD     CalcRes+2
    STD     FailRes+2
CF_End:
    RTS

; Bilan « MULD n/48  DIVD n/48  DIVQ n/48 » et détail du premier échec.
Calc_Show:
    LDU     #Line2
    LDX     #TxtMuld
    JSR     Append
    CLRA
    LDB     OkMuld
    JSR     Dec16
    LDX     #TxtSur48
    JSR     Append
    LDX     #TxtDivd
    JSR     Append
    CLRA
    LDB     OkDivd
    JSR     Dec16
    LDX     #TxtSur48
    JSR     Append
    LDX     #TxtDivq
    JSR     Append
    CLRA
    LDB     OkDivq
    JSR     Dec16
    LDX     #TxtSur48
    JSR     Append
    JSR     Pad_Line2
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #LBL_X
    LDB     #ROW_CALC
    LDX     #Line2
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    ; détail du premier échec
    LDU     #Line2
    LDA     FailType
    BNE     CS_Fail
    LDX     #TxtTousOk
    JSR     Append
    LBRA    CS_Out
CS_Fail:
    LDX     FailPtr
    CMPA    #'M'
    BNE     CS_NotM
    PSHS    X                   ; MULD aaaa*bbbb -> pppppppp att pppppppp
    LDX     #TxtMuld
    JSR     Append
    LDX     ,S
    LDA     ,X
    JSR     Hex8
    LDA     1,X
    JSR     Hex8
    LDA     #'*'
    STA     ,U+
    LDA     2,X
    JSR     Hex8
    LDA     3,X
    JSR     Hex8
    LDX     #TxtFleche
    JSR     Append
    LDX     #FailRes
    LDB     #4
    JSR     Hex_N
    LDX     #TxtAtt
    JSR     Append
    PULS    X
    LEAX    4,X
    LDB     #4
    JSR     Hex_N
    LBRA    CS_Out
CS_NotM:
    CMPA    #'D'
    BNE     CS_Q
    PSHS    X                   ; DIVD aaaa/bb -> qq,rr att qq,rr
    LDX     #TxtDivd+2
    JSR     Append
    LDX     ,S
    LDB     #2
    JSR     Hex_N
    LDA     #'/'
    STA     ,U+
    LDX     ,S
    LDA     2,X
    JSR     Hex8
    LDX     #TxtFleche
    JSR     Append
    LDA     FailRes+1           ; quotient (B)
    JSR     Hex8
    LDA     #','
    STA     ,U+
    LDA     FailRes             ; reste (A)
    JSR     Hex8
    LDX     #TxtAtt
    JSR     Append
    PULS    X
    LDA     3,X
    JSR     Hex8
    LDA     #','
    STA     ,U+
    LDA     4,X
    JSR     Hex8
    LBRA    CS_Out
CS_Q:
    PSHS    X                   ; DIVQ aaaaaaaa/bbbb -> qqqq,rrrr att qqqq,rrrr
    LDX     #TxtDivq+2
    JSR     Append
    LDX     ,S
    LDB     #4
    JSR     Hex_N
    LDA     #'/'
    STA     ,U+
    LDX     ,S
    LEAX    4,X
    LDB     #2
    JSR     Hex_N
    LDX     #TxtFleche
    JSR     Append
    LDX     #FailRes
    LDB     #2
    JSR     Hex_N
    LDA     #','
    STA     ,U+
    LDX     #FailRes+2
    LDB     #2
    JSR     Hex_N
    LDX     #TxtAtt
    JSR     Append
    PULS    X
    LEAX    6,X
    LDB     #2
    JSR     Hex_N
    LDA     #','
    STA     ,U+
    LDB     #2
    JSR     Hex_N               ; X a avancé de 2 : le reste attendu
CS_Out:
    JSR     Pad_Line2
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #LBL_X
    LDB     #ROW_CALC2
    LDX     #Line2
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; X = octets, B = nombre : en hexadécimal à ,U+ ; X avance.
Hex_N:
    LDA     ,X+
    JSR     Hex8                ; préserve B et X
    DECB
    BNE     Hex_N
    RTS

; Comme Pad_Line, sur Line2 et CALC_W colonnes.
Pad_Line2:
    TFR     U,D
    SUBD    #Line2
    CMPB    #CALC_W
    BHS     PL2_End
    LDA     #$20
    STA     ,U+
    BRA     Pad_Line2
PL2_End:
    CLR     ,U
    RTS

; -------------------------------------------------------------------
; T : l'écran de BRIQUES sans briques, puis un élément de moins par touche.
; Echap revient à MIRE à tout moment.
; -------------------------------------------------------------------
Do_Briques:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA                        ; l'écran que BRIQUES trouve en démarrant
    CLRB
    LDW     #(80*256)+25
    LDX     #OrigBuf
    JSR     [VIS_TABLE+vis_Rect_Restore]
    LDA     #T_WIN_X            ; fenêtre (Draw_Briques_Window)
    LDB     #T_WIN_Y
    LDW     #(T_WIN_W*256)+T_WIN_H
    LDY     #TxtBriques
    JSR     [VIS_TABLE+vis_Window]
    JSR     T_Parois            ; parois et fond (Draw_Well)
    LDA     #T_BOARD_X          ; puits vide : $20 / $00, comme le rendu
    LDB     #T_BOARD_Y
    LDW     #(T_BOARD_W*256)+T_BOARD_H
    LDY     #$2000
    JSR     [VIS_TABLE+vis_Fill]
    LDU     #BriquesTexts        ; panneau SCORE / LIGNES et valeurs
DT_Txt:
    LDA     ,U+
    BEQ     DT_TxtEnd
    LDB     ,U+
    LDX     ,U++
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    BRA     DT_Txt
DT_TxtEnd:
    LDA     #'1'
    JSR     T_Etape
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     T_Touche
    BEQ     DT_Fin
    ; 2. sans les textes du panneau
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #T_PANEL_X
    LDB     #T_WIN_Y+4
    LDW     #(6*256)+6
    LDY     #(UI_SPACE*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #'2'
    JSR     T_Etape
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     T_Touche
    BEQ     DT_Fin
    ; 3. sans les parois (le fond et ses coins restent)
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #T_BOARD_X-1
    LDB     #T_BOARD_Y
    LDW     #(1*256)+T_BOARD_H
    LDY     #(UI_SPACE*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #T_BOARD_X+T_BOARD_W
    LDW     #(1*256)+T_BOARD_H
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #'3'
    JSR     T_Etape
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     T_Touche
    BEQ     DT_Fin
    ; 4. le puits devient de l'intérieur de fenêtre : plus de case page 0
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #T_BOARD_X
    LDB     #T_BOARD_Y
    LDW     #(T_BOARD_W*256)+T_BOARD_H
    LDY     #(UI_SPACE*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #'4'
    JSR     T_Etape
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     T_Touche
DT_Fin:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    CLRB
    LDW     #(80*256)+25
    LDX     #OrigBuf
    JSR     [VIS_TABLE+vis_Rect_Restore]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Draw_Main
    LBRA    Main_Loop

; -------------------------------------------------------------------
; P : cinq essais indépendants. Chaque essai redessine tout l'écran
; (Draw_Replica) et ne change qu'un facteur : arrière-plan, titre, ou
; contenu du puits. Table PuitsTable : fond (0 = écran d'OSM-VISION,
; 1 = noir), titre (0 = cadre simple), puits (caractère*256+attribut).
; -------------------------------------------------------------------
Do_Puits:
    LDX     #PuitsTable
    LDA     #'1'
    STA     EssaiNum
DP_Next:
    LDA     ,X+
    CMPA    #$FF                ; fin de table
    BEQ     DP_Fin
    STA     R_Fond
    LDD     ,X++
    STD     R_Titre
    LDD     ,X++
    STD     R_Puits
    STX     R_Ptr
    JSR     Draw_Replica
    JSR     T_Touche
    BEQ     DP_Fin
    INC     EssaiNum
    LDX     R_Ptr
    BRA     DP_Next
DP_Fin:
    LBRA    DT_Fin              ; même sortie que T : écran restauré, MIRE

; La réplique, paramétrée par R_Fond / R_Titre / R_Puits.
Draw_Replica:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    CLRB
    LDW     #(80*256)+25
    TST     R_Fond
    BNE     DR_Noir
    LDX     #OrigBuf            ; l'écran d'OSM-VISION derrière
    JSR     [VIS_TABLE+vis_Rect_Restore]
    BRA     DR_Win
DR_Noir:
    LDY     #$2000              ; écran entier noir
    JSR     [VIS_TABLE+vis_Fill]
DR_Win:
    LDA     #T_WIN_X
    LDB     #T_WIN_Y
    LDW     #(T_WIN_W*256)+T_WIN_H
    LDY     R_Titre             ; 0 : cadre simple, sans titre ni filet
    JSR     [VIS_TABLE+vis_Window]
    JSR     T_Parois
    LDA     #T_BOARD_X
    LDB     #T_BOARD_Y
    LDW     #(T_BOARD_W*256)+T_BOARD_H
    LDY     R_Puits
    JSR     [VIS_TABLE+vis_Fill]
    LDU     #BriquesTexts
DR_Txt:
    LDA     ,U+
    BEQ     DR_TxtEnd
    LDB     ,U+
    LDX     ,U++
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    BRA     DR_Txt
DR_TxtEnd:
    LDA     EssaiNum
    LDX     #TxtEssai
    LDY     #TxtSur5
    JSR     T_Label
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; Parois et fond du puits, comme Draw_Well de BRIQUES. Entre Sync_Begin
; et Sync_End.
T_Parois:
    LDA     #T_BOARD_X-1
    LDB     #T_BOARD_Y-1
    LDW     #(UI_TOP_R*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    LDA     #T_BOARD_X+T_BOARD_W
    LDW     #(UI_TOP_L*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    LDA     #T_BOARD_X-1
    LDB     #T_BOARD_Y
    LDW     #(1*256)+T_BOARD_H
    LDY     #(UI_VERT_R*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #T_BOARD_X+T_BOARD_W
    LDW     #(1*256)+T_BOARD_H
    LDY     #(UI_VERT_L*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #T_BOARD_X
    LDB     #T_BOARD_Y+T_BOARD_H
    LDW     #(T_BOARD_W*256)+1
    LDY     #(UI_WELL_BOT*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #T_BOARD_X-1
    LDW     #(UI_WELL_BL*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    LDA     #T_BOARD_X+T_BOARD_W
    LDW     #(UI_WELL_BR*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    RTS

; A = chiffre de l'étape : « ETAPE n/4 » sur le bureau, en bas à droite.
T_Etape:
    LDX     #TxtEtape
    LDY     #TxtSur4
; A = chiffre, X = préfixe, Y = suffixe : « <préfixe><chiffre><suffixe> ».
T_Label:
    LDU     #Line
    PSHS    A,Y
    JSR     Append
    PULS    A,Y
    STA     ,U+
    TFR     Y,X
    JSR     Append
    CLR     ,U
    LDA     #T_ETAPE_X
    LDB     #T_ETAPE_Y
    LDX     #Line
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    RTS

; Attend une touche. Z = 1 si Echap.
T_Touche:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     T_Touche
    CMPA    #$1B
    RTS

; -------------------------------------------------------------------
; Dessin
; -------------------------------------------------------------------
; La fenêtre et ses textes fixes (table TextTable : colonne, ligne,
; texte ; colonne 0 = fin), puis les valeurs.
Draw_Main:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    LDU     #TextTable
DM_Loop:
    LDA     ,U+
    BEQ     DM_End
    LDB     ,U+
    LDX     ,U++
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]  ; préserve U
    BRA     DM_Loop
DM_End:
    JSR     Show_Keys
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; -------------------------------------------------------------------
; V : registres verticaux et adresse de départ du 68B45, en direct
; (enquête sur la rangée 0 qui reste noire). Haut/bas : R7, position de
; la synchro verticale ; gauche/droite : R5, lignes d'ajustement ;
; Pg.préc/Pg.suiv : départ -/+ 80 (une rangée) ; Inser/Suppr : départ
; -/+ 1 ; + / - : R6, rangées affichées ; Début : valeurs de
; bios/video.asm. Entrée ou Echap : retour,
; valeurs d'origine remises.
;   Si la bande noire SUIT le contenu quand le départ bouge d'une rangée,
;   c'est la VRAM ; si elle reste la première rangée affichée, c'est le
;   balayage (ou l'écran).
; Le 68B45 a un registre d'index : l'IRQ VSYNC du BIOS y choisit R14/R15
; (curseur) à chaque trame. On écrit donc IRQ masquées.
; -------------------------------------------------------------------
CRTC_R5         equ $0D         ; bios/video.asm, crtc_table
CRTC_R6         equ $1E
CRTC_R7         equ $1E
CRTC_DEPART     equ $FFFF

Do_Crtc:
    LBSR    Crtc_Defaut
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #LBL_X
    LDB     #ROW_CALC2
    LDX     #TxtCrtcAide
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
DV_Loop:
    LBSR    Crtc_Ecrit
    JSR     Crtc_Show
DV_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     DV_Key
    LDB     VR7
    CMPA    #KEY_UP
    BNE     DV_Dn
    INCB
    BRA     DV_R7
DV_Dn:
    CMPA    #KEY_DOWN
    BNE     DV_R5
    DECB
DV_R7:
    ANDB    #$7F                ; R7 : 7 bits
    STB     VR7
    BRA     DV_Loop
DV_R5:
    LDB     VR5
    CMPA    #KEY_RIGHT
    BNE     DV_Lt
    INCB
    BRA     DV_R5S
DV_Lt:
    CMPA    #KEY_LEFT
    BNE     DV_Dep
    DECB
DV_R5S:
    ANDB    #$1F                ; R5 : 5 bits
    STB     VR5
    BRA     DV_Loop
DV_Dep:
    LDX     #-80
    CMPA    #KEY_PGUP
    BEQ     DV_DAdd
    LDX     #80
    CMPA    #KEY_PGDN
    BEQ     DV_DAdd
    LDX     #-1
    CMPA    #KEY_INS
    BEQ     DV_DAdd
    LDX     #1
    CMPA    #KEY_DEL
    BEQ     DV_DAdd
    CMPA    #KEY_HOME
    BNE     DV_R6
    BSR     Crtc_Defaut
    LBRA    DV_Loop
DV_R6:
    LDB     VR6
    CMPA    #'+'
    BNE     DV_Moins
    INCB
    BRA     DV_R6S
DV_Moins:
    CMPA    #'-'
    BNE     DV_Fin
    DECB
DV_R6S:
    ANDB    #$7F                ; R6 : 7 bits
    STB     VR6
    LBRA    DV_Loop
DV_DAdd:
    TFR     X,D
    ADDD    VStart
    STD     VStart
    BRA     DV_Loop
DV_Fin:
    CMPA    #$1B
    BEQ     DV_Sortie
    CMPA    #$0D
    LBNE    DV_Key
DV_Sortie:
    BSR     Crtc_Defaut
    BSR     Crtc_Ecrit
    LBRA    Main_Refresh

Crtc_Defaut:
    LDA     #CRTC_R5
    STA     VR5
    LDA     #CRTC_R6
    STA     VR6
    LDA     #CRTC_R7
    STA     VR7
    LDD     #CRTC_DEPART
    STD     VStart
    RTS

; R5, R7, R12, R13 <- VR5, VR7, VStart.
Crtc_Ecrit:
    PSHS    CC
    ORCC    #%00010000
    LDA     #5
    STA     CRTC_RS
    LDA     VR5
    STA     CRTC_DATA
    LDA     #6
    STA     CRTC_RS
    LDA     VR6
    STA     CRTC_DATA
    LDA     #7
    STA     CRTC_RS
    LDA     VR7
    STA     CRTC_DATA
    LDA     #12
    STA     CRTC_RS
    LDA     VStart
    STA     CRTC_DATA
    LDA     #13
    STA     CRTC_RS
    LDA     VStart+1
    STA     CRTC_DATA
    PULS    CC,PC

; « R5 $0D  R7 $1D  depart $FFFF » sur ROW_CALC.
Crtc_Show:
    LDU     #Line2
    LDX     #TxtCrtcR5
    JSR     Append
    LDA     VR5
    JSR     Hex8
    LDX     #TxtCrtcR6
    JSR     Append
    LDA     VR6
    JSR     Hex8
    LDX     #TxtCrtcR7
    JSR     Append
    LDA     VR7
    JSR     Hex8
    LDX     #TxtCrtcDep
    JSR     Append
    LDA     VStart
    JSR     Hex8
    LDA     VStart+1
    JSR     Hex8
    JSR     Pad_Line2
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #LBL_X
    LDB     #ROW_CALC
    LDX     #Line2
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JMP     [VIS_TABLE+vis_Sync_End]

; Dernière touche ($XX et son caractère) et historique. Entre
; vis_Sync_Begin et vis_Sync_End.
Show_Keys:
    LDU     #Line
    LDA     #'$'
    STA     ,U+
    LDA     LastKey
    JSR     Hex8
    LDA     #$20
    STA     ,U+
    LDA     LastKey
    CMPA    #$20                ; imprimable ? sinon un point
    BLO     SK_Dot
    CMPA    #$7E
    BLS     SK_Chr
SK_Dot:
    LDA     #'.'
SK_Chr:
    STA     ,U+
    JSR     Pad_Line
    LDA     #VAL_X
    LDB     #ROW_KEY
    LDX     #Line
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]

    LDU     #Line
    LDX     #History
    LDB     #HIST_N
SK_Hist:
    LDA     ,X+
    JSR     Hex8                ; préserve B et X
    LDA     #$20
    STA     ,U+
    DECB
    BNE     SK_Hist
    JSR     Pad_Line
    LDA     #VAL_X
    LDB     #ROW_HIST
    LDX     #Line
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    RTS

; A = touche : LastKey, et entrée la plus récente de l'historique (en fin).
; Préserve A.
Record_Key:
    PSHS    A
    STA     LastKey
    LDX     #History
    LDB     #HIST_N-1
RK_Shift:
    LDA     1,X
    STA     ,X+
    DECB
    BNE     RK_Shift
    LDA     ,S
    STA     ,X
    PULS    A,PC

; Complète Line par des espaces jusqu'à LINE_W colonnes (efface la
; valeur précédente), puis pose le 0. U = pointeur d'écriture dans Line.
Pad_Line:
    TFR     U,D
    SUBD    #Line
    CMPB    #LINE_W
    BHS     PL_End
    LDA     #$20
    STA     ,U+
    BRA     Pad_Line
PL_End:
    CLR     ,U
    RTS

; Append / Hex8 : source unique lib/str.asm (U = pointeur d'écriture)
    include "../lib/str.asm"

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
TextTable:
    FCB     LBL_X,ROW_KEY
    FDB     TxtDerniere
    FCB     LBL_X,ROW_HIST
    FDB     TxtHist
    FCB     LBL_X,WIN_Y+6
    FDB     TxtAideN
    FCB     LBL_X,WIN_Y+7
    FDB     TxtAideM
    FCB     LBL_X,WIN_Y+8
    FDB     TxtAideS
    FCB     LBL_X,WIN_Y+9
    FDB     TxtAideT
    FCB     LBL_X,WIN_Y+10
    FDB     TxtAideP
    FCB     LBL_X,WIN_Y+11
    FDB     TxtAideC
    FCB     LBL_X,WIN_Y+12
    FDB     TxtAideQ
    FCB     LBL_X,ROW_INPUT
    FDB     TxtSaisie
    FCB     LBL_X,ROW_OUT
    FDB     TxtResultat
    FCB     0

TxtTitre:       FCN " MIRE "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour MIRE."
TxtDerniere:    FCN "Derniere touche :"
TxtHist:        FCN "Historique      :"
TxtAideN:       FCN "N      ecran noir, IRQ actives"
TxtAideM:       FCN "M      ecran noir, IRQ masquees"
TxtAideS:       FCN "S      essai de saisie (vis_Input)"
TxtAideT:       FCN "T      ecran BRIQUES sans briques"
TxtAideP:       FCN "P      puits : 5 essais"
TxtAideC:       FCN "C      test MULD / DIVD / DIVQ du 6309"
TxtAideQ:       FCN "V      CRTC en direct     Echap  retour"
TxtCrtcAide:    FCN "R7 haut/bas  R5 g/d  R6 +/-  depart PgP/PgS"
TxtCrtcR5:      FCN "R5 $"
TxtCrtcR6:      FCN "  R6 $"
TxtCrtcR7:      FCN "  R7 $"
TxtCrtcDep:     FCN "  depart $"
TxtMuld:        FCN "MULD "
TxtDivd:        FCN "  DIVD "
TxtDivq:        FCN "  DIVQ "
TxtSur48:       FCN "/48"
TxtTousOk:      FCN "aucun echec"
TxtFleche:      FCN " -> "
TxtAtt:         FCN " att "
TxtEssai:       FCN "ESSAI "
TxtSur5:        FCN "/5"
; Essais de P : fond (0 OSM-VISION, 1 noir), titre, puits (car*256+attr)
PuitsTable:
    FCB     0
    FDB     TxtBriques,$2000     ; 1 référence : page 0, noir sur noir
    FCB     0
    FDB     TxtBriques,$0080     ; 2 page 1, noir sur noir ($00 y est blanc)
    FCB     0
    FDB     TxtBriques,$2008     ; 3 page 0, premier plan gris
    FCB     0
    FDB     0,$2000             ; 4 cadre simple : ni titre ni filet
    FCB     1
    FDB     TxtBriques,$2000     ; 5 sans OSM-VISION derrière (écran noir)
    FCB     $FF
TxtBriques:      FCN " BRIQUES 6809 "
TxtEtape:       FCN "ETAPE "
TxtSur4:        FCN "/4"
TxtScore:       FCN "SCORE"
TxtLignes:      FCN "LIGNES"
TxtZero6:       FCN "000000"
TxtZero3:       FCN "000"
; Panneau de BRIQUES : colonne, ligne, texte (colonne 0 = fin)
BriquesTexts:
    FCB     T_PANEL_X,T_WIN_Y+4
    FDB     TxtScore
    FCB     T_PANEL_X,T_WIN_Y+5
    FDB     TxtZero6
    FCB     T_PANEL_X,T_WIN_Y+8
    FDB     TxtLignes
    FCB     T_PANEL_X,T_WIN_Y+9
    FDB     TxtZero3
    FCB     0
TxtSaisie:      FCN "Saisie :"
TxtResultat:    FCN "Sortie          :"
TxtSortie:      FCN "touche $"
TxtLong:        FCN ", longueur $"
TxtEchap:       FCN "Echap"

; --- Cas générés par Python (graine 6309) : opérandes puis attendu ---
; MULD : D(2) multiplicateur(2) produit Q(4)
TabMuld:
    FDB     $0000,$0000,$0000,$0000
    FDB     $0001,$0001,$0000,$0001
    FDB     $FFFF,$0001,$FFFF,$FFFF
    FDB     $FFFF,$FFFF,$0000,$0001
    FDB     $7FFF,$7FFF,$3FFF,$0001
    FDB     $8000,$8000,$4000,$0000
    FDB     $8000,$7FFF,$C000,$8000
    FDB     $8000,$0001,$FFFF,$8000
    FDB     $7FFF,$FFFF,$FFFF,$8001
    FDB     $04D2,$E9D2,$FF95,$1644
    FDB     $FED4,$012C,$FFFE,$A070
    FDB     $00FF,$0100,$0000,$FF00
    FDB     $0100,$0100,$0001,$0000
    FDB     $FFFF,$7FFF,$FFFF,$8001
    FDB     $0D8D,$61F6,$052F,$727E
    FDB     $16E5,$B987,$F9B2,$8FC3
    FDB     $D690,$903F,$1216,$CD70
    FDB     $E32B,$8E0F,$0CD5,$2985
    FDB     $F684,$7238,$FBC4,$B4E0
    FDB     $BAA0,$A504,$18A8,$0A80
    FDB     $FAD6,$738F,$FDAB,$3F8A
    FDB     $8D2F,$F400,$0561,$CC00
    FDB     $3F53,$AD3E,$EB87,$6D1A
    FDB     $1006,$FE9A,$FFE9,$979C
    FDB     $5F3A,$CE6A,$ED8E,$1A04
    FDB     $3B57,$ADF2,$ECFA,$E33E
    FDB     $950A,$0116,$FF8B,$D8DC
    FDB     $169B,$813A,$F4CE,$3A1E
    FDB     $0C1C,$7B85,$05D7,$BE8C
    FDB     $86AE,$2AF4,$EBA4,$E9D8
    FDB     $1796,$9869,$F674,$BC86
    FDB     $A432,$FAD5,$01DA,$719A
    FDB     $A214,$AA59,$1F6C,$A0F4
    FDB     $A316,$16C0,$F7BE,$3480
    FDB     $74DE,$2A9E,$1374,$8D04
    FDB     $5350,$A5F0,$E2B0,$AB00
    FDB     $F860,$D540,$0145,$F800
    FDB     $3B1C,$1926,$05CE,$8228
    FDB     $0005,$5406,$0001,$A41E
    FDB     $4499,$29B2,$0B2C,$3362
    FDB     $A5E6,$809E,$2CD5,$63F4
    FDB     $1823,$D80B,$FC3B,$9181
    FDB     $AEA4,$278B,$F36E,$CF0C
    FDB     $8C69,$76B9,$CA64,$DDE1
    FDB     $2645,$A8A4,$F2F0,$CC34
    FDB     $29EE,$4E74,$0CD9,$83D8
    FDB     $FDC2,$A0C6,$00D5,$840C
    FDB     $30D8,$E3D5,$FAA0,$2BB8
; DIVD : D(2) diviseur(1) quotient B(1) reste A(1)
TabDivd:
    FDB     $0000
    FCB     $01,$00,$00
    FDB     $0001
    FCB     $01,$01,$00
    FDB     $FFFF
    FCB     $01,$FF,$00
    FDB     $007F
    FCB     $01,$7F,$00
    FDB     $FF80
    FCB     $01,$80,$00
    FDB     $007F
    FCB     $FF,$81,$00
    FDB     $FF81
    FCB     $FF,$7F,$00
    FDB     $0064
    FCB     $07,$0E,$02
    FDB     $FF9C
    FCB     $07,$F2,$FE
    FDB     $0064
    FCB     $F9,$F2,$02
    FDB     $FF9C
    FCB     $F9,$0E,$FE
    FDB     $C080
    FCB     $7F,$80,$00
    FDB     $03E8
    FCB     $F8,$83,$00
    FDB     $FC18
    FCB     $08,$83,$00
    FDB     $00FF
    FCB     $02,$7F,$01
    FDB     $FF01
    FCB     $02,$81,$FF
    FDB     $0006
    FCB     $03,$02,$00
    FDB     $FFFA
    FCB     $03,$FE,$00
    FDB     $0B5E
    FCB     $82,$E9,$0C
    FDB     $FDA0
    FCB     $DB,$10,$F0
    FDB     $08FD
    FCB     $E9,$9C,$01
    FDB     $0016
    FCB     $D7,$00,$16
    FDB     $F17B
    FCB     $B4,$30,$BB
    FDB     $E20B
    FCB     $5F,$B0,$BB
    FDB     $05F4
    FCB     $60,$0F,$54
    FDB     $00A9
    FCB     $FE,$AC,$01
    FDB     $0F6B
    FCB     $C9,$B9,$2A
    FDB     $FD88
    FCB     $5F,$FA,$C2
    FDB     $2312
    FCB     $7C,$48,$32
    FDB     $E671
    FCB     $41,$9C,$D5
    FDB     $040D
    FCB     $DE,$E2,$11
    FDB     $007E
    FCB     $01,$7E,$00
    FDB     $05F8
    FCB     $23,$2B,$17
    FDB     $E3F3
    FCB     $6C,$BE,$CB
    FDB     $FDC7
    FCB     $05,$8F,$FC
    FDB     $FDE8
    FCB     $13,$E4,$FC
    FDB     $F7EA
    FCB     $62,$EB,$F4
    FDB     $1475
    FCB     $6B,$30,$65
    FDB     $01D7
    FCB     $07,$43,$02
    FDB     $EC2E
    FCB     $86,$29,$B8
    FDB     $FCC3
    FCB     $E5,$1E,$ED
    FDB     $042A
    FCB     $0B,$60,$0A
    FDB     $039E
    FCB     $29,$16,$18
    FDB     $FC5B
    FCB     $4E,$F5,$B5
    FDB     $F50E
    FCB     $DA,$49,$E4
    FDB     $FEAF
    FCB     $DD,$09,$EA
    FDB     $FDCF
    FCB     $37,$F6,$F5
    FDB     $DBF0
    FCB     $98,$58,$B0
; DIVQ : Q(4) diviseur(2) quotient W(2) reste D(2)
TabDivq:
    FDB     $0000,$0000,$0001,$0000,$0000
    FDB     $0000,$0001,$0001,$0001,$0000
    FDB     $FFFF,$FFFF,$0001,$FFFF,$0000
    FDB     $0000,$7FFF,$0001,$7FFF,$0000
    FDB     $FFFF,$8000,$0001,$8000,$0000
    FDB     $0000,$7FFF,$FFFF,$8001,$0000
    FDB     $0001,$86A0,$0007,$37CD,$0005
    FDB     $FFFE,$7960,$0007,$C833,$FFFB
    FDB     $0001,$86A0,$FFF9,$C833,$0005
    FDB     $FFFE,$7960,$FFF9,$37CD,$FFFB
    FDB     $C000,$8000,$7FFF,$8000,$0000
    FDB     $000F,$4240,$FC18,$FC18,$0000
    FDB     $FFF0,$BDC0,$03E8,$FC18,$0000
    FDB     $0000,$0006,$0003,$0002,$0000
    FDB     $FFFF,$FFFA,$0003,$FFFE,$0000
    FDB     $0004,$3387,$FFF2,$B32E,$000B
    FDB     $CDE6,$B3C4,$6C34,$8979,$BB30
    FDB     $F7FB,$593B,$2613,$CA17,$EF86
    FDB     $E42E,$B448,$A4DB,$4E21,$BA0D
    FDB     $1238,$FE36,$B2E5,$C380,$1CB6
    FDB     $FFFB,$A7F3,$0085,$F7A4,$FFBF
    FDB     $0044,$DE3C,$1FC4,$022B,$0050
    FDB     $08A1,$548F,$78F3,$1244,$1E03
    FDB     $FEC5,$3B40,$0819,$D921,$FF07
    FDB     $0000,$670A,$FF8E,$FF19,$002C
    FDB     $0032,$60C8,$00DF,$39D5,$003D
    FDB     $CDC6,$39FB,$7625,$932C,$AC9F
    FDB     $0031,$A2C6,$006F,$7279,$004F
    FDB     $FFE7,$7F13,$FFBE,$5F0B,$FFE9
    FDB     $FFEA,$3006,$FEFC,$157A,$FFEE
    FDB     $3A0F,$50EA,$7F40,$74CD,$6AAA
    FDB     $0E24,$F4F3,$7BCE,$1D3F,$2741
    FDB     $000F,$C395,$FFD1,$AA23,$0002
    FDB     $0073,$96F6,$0111,$6C64,$0052
    FDB     $FF07,$BE68,$6D85,$FDBC,$DFBC
    FDB     $0006,$D314,$0010,$6D31,$0004
    FDB     $FF6C,$BBD0,$0735,$EB91,$FFCB
    FDB     $00B3,$A63E,$FE95,$814F,$0143
    FDB     $004F,$D4B1,$FF32,$9CCB,$000B
    FDB     $0036,$42E8,$FF74,$9CC8,$0048
    FDB     $FD6B,$D71F,$0563,$8573,$FCA6
    FDB     $02CE,$CBEB,$6490,$0725,$531B
    FDB     $0A45,$4B97,$31AD,$34ED,$2A6E
    FDB     $23CD,$2D83,$5640,$6A43,$1AC3
    FDB     $FFB3,$6260,$FF05,$4E24,$FFAC
    FDB     $0032,$AB44,$00F9,$3417,$00E5
    FDB     $0000,$C346,$FFCA,$FC63,$0028
    FDB     $3706,$D5EB,$73E8,$7989,$26C3
; --- Variables ---
LastKey         rmb 1
OutKey          rmb 1
InLen           rmb 1
NumStarted      rmb 1           ; lib/str.asm (Dec16)
DigitCnt        rmb 1           ; lib/str.asm (Dec16)
History         rmb HIST_N
InBuf           rmb INPUT_MAX+1
Line            rmb LINE_W+1
Line2           rmb CALC_W+1    ; touches C et V
VR5             rmb 1           ; touche V : valeurs en essai
VR6             rmb 1
VR7             rmb 1
VStart          rmb 2
CalcRes         rmb 4           ; résultat obtenu (Q, ou quotient/reste)
OkMuld          rmb 1           ; cas réussis
OkDivd          rmb 1
OkDivq          rmb 1
FailType        rmb 1           ; premier échec : 'M', 'D', 'Q' ou 0
FailPtr         rmb 2           ; son cas dans la table
FailRes         rmb 4           ; ce qu'a donné le processeur
ScreenBuf       rmb 80*25*2     ; écran entier, deux plans (vis_Rect_Save)
OrigBuf         rmb 80*25*2     ; l'écran d'OSM-VISION au lancement (touche T)
EssaiNum        rmb 1           ; touche P : chiffre de l'essai en cours
R_Fond          rmb 1           ; Draw_Replica : 0 OSM-VISION, 1 noir
R_Titre         rmb 2           ; Draw_Replica : titre, ou 0
R_Puits         rmb 2           ; Draw_Replica : caractère*256+attribut
R_Ptr           rmb 2           ; Do_Puits : position dans PuitsTable

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
