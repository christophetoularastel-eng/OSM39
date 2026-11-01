; ===================================================================
; VISION.ASM - Les services d'affichage d'OSM-VISION, en source unique
; ===================================================================
; Fenêtres, texte, cellules, remplissages, rectangles sauvés/restaurés,
; ligne de saisie, boîte de message, sons d'erreur : ce que décrit
; lib/vis.inc. Inclus par osmvision/osmvision.asm ET par chaque
; application fenêtrée : une application tourne dans sa propre page
; (page 1, $0000), elle ne voit pas OSM-VISION (page 0) et emporte donc
; sa copie. Elle appelle toujours JSR [VIS_TABLE+vis_xxx] : VIS_TABLE est
; la table ci-dessous (lib/vis.inc).
;
; A inclure APRÈS le point d'entrée ; lib/ui.inc doit être inclus (en
; tête, définitions). Ce fichier inclut lui-même lib/vram.asm (Calc_Addr),
; lib/snd.asm (Snd_Start) et, si l'appelant ne l'a pas fait, lib/snd.inc.
; Le son coupé (touche M d'OSM-VISION) est son_coupe, en RAM système :
; toutes les copies le lisent.
; ===================================================================

SAVE_BUF_SIZE   equ 1400        ; tampon de sauvegarde de l'écran sous les boîtes
YIELD_RECT      equ 1           ; 1 = Rect_Save/Restore par petits lots synchronisés sur le VSYNC
YIELD_WINDOW    equ 1           ; 1 = Draw_Window par petits lots (boîtes de dialogue seulement)
; Budget VRAM par trame, compté dans WinAcc (16 bits : plus de plafond à 176).
; Copies TFM : 3 cycles/octet, plus un surcoût fixe par ligne (Calc_Addr,
; piles, compteurs) d'environ 100 cycles, compté comme COUT_LIGNE octets.
; Estimation (E = 1,8432 MHz) : fenêtre après l'IRQ ~2600 cycles avec
; R7=$1e (BIOS depuis le 10 oct. 2026, 80 x 30 ; ~3500 avec l'ancien $1d).
; A CALIBRER SUR LA CARTE : monter par paliers jusqu'aux parasites en haut
; de l'écran, puis redescendre d'un palier.
YIELD_CELLS     equ 480         ; octets-équivalents TFM par trame
COUT_LIGNE      equ 32          ; surcoût d'une ligne, en octets-équivalents TFM
SND_MUTED       equ $4D                 ; son_coupe = $4D : son coupé ; toute autre valeur : son actif
; V4 : caractères en $8000-$8FFF, couleurs en $9000-$9FFF. Un « plan »
; est le poids fort de son décalage : on l'ajoute au poids fort d'une
; adresse calculée depuis VRAM_BASE (Calc_Addr). $A120 ne porte plus que
; la page (0), posée par Sync_Begin.
VRAM_P0_CHR     equ $00
VRAM_P0_COL     equ VRAM_COL_OFS/256


    IFNDEF  SND_PTR
    include "../lib/snd.inc"
    ENDC

; --- la table des services (lib/vis.inc) : n'ajouter qu'en fin ---
VIS_COUNT_ADR:  FCB (Vis_Table_End-VIS_TABLE)/2   ; (lib/vis.inc)
VIS_TABLE:                                      ; la table : JSR [VIS_TABLE+vis_xxx]
VT_Sync_Begin   FDB Sync_Begin
VT_Sync_End     FDB Sync_End
VT_Window       FDB Draw_Window
VT_Text         FDB Vis_Text
VT_MsgBox       FDB Msg_Box
VT_Sound        FDB Vis_Sound
VT_Sound_Stop   FDB Snd_Stop
VT_Fill         FDB Vis_Fill
VT_PutCell      FDB Vis_PutCell
VT_Rect_Save    FDB Vis_Rect_Save
VT_Rect_Restore FDB Vis_Rect_Restore
VT_Input        FDB Vis_Input
Vis_Table_End:
; Chaque entree doit etre a l'offset que lib/vis.inc annonce.
    IFNE    VT_Sync_Begin-VIS_TABLE-vis_Sync_Begin
    error   "vis.inc : vis_Sync_Begin n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Sync_End-VIS_TABLE-vis_Sync_End
    error   "vis.inc : vis_Sync_End n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Window-VIS_TABLE-vis_Window
    error   "vis.inc : vis_Window n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Text-VIS_TABLE-vis_Text
    error   "vis.inc : vis_Text n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_MsgBox-VIS_TABLE-vis_MsgBox
    error   "vis.inc : vis_MsgBox n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Sound-VIS_TABLE-vis_Sound
    error   "vis.inc : vis_Sound n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Sound_Stop-VIS_TABLE-vis_Sound_Stop
    error   "vis.inc : vis_Sound_Stop n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Fill-VIS_TABLE-vis_Fill
    error   "vis.inc : vis_Fill n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_PutCell-VIS_TABLE-vis_PutCell
    error   "vis.inc : vis_PutCell n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Rect_Save-VIS_TABLE-vis_Rect_Save
    error   "vis.inc : vis_Rect_Save n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Rect_Restore-VIS_TABLE-vis_Rect_Restore
    error   "vis.inc : vis_Rect_Restore n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    VT_Input-VIS_TABLE-vis_Input
    error   "vis.inc : vis_Input n'est pas a sa place dans Vis_Table"
    ENDC
    IFNE    (Vis_Table_End-VIS_TABLE)/2-VIS_COUNT
    error   "vis.inc : VIS_COUNT ne correspond pas a la taille de Vis_Table"
    ENDC


; ===================================================================
; SYNCHRONISATION VRAM
; Sync_Begin : attend le VSYNC (IRQ actives), masque les IRQ, page 0.
; Sync_End   : réactive les IRQ (V4 : plus de « mode affichage » $10).
; Tout accès CPU à la VRAM se fait entre les deux, par petits lots.
; ===================================================================
Sync_Begin:
    PSHSW
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    PULSW
    ORCC    #%00010000
    PSHS    A
    CLRA                        ; page vidéo 0 (V4 : $A120 = la page seule)
    STA     VRAM_CTRL
    PULS    A,PC

Sync_End:                       ; V4 : la VRAM revient seule au 68B45
    ANDCC   #%11101111
    RTS

; Fin de lot : laisse passer l'image, attend le VSYNC suivant, reprend l'accès
; CPU. A appeler ENTRE Sync_Begin et Sync_End de l'appelant.
; Préserve D, X, Y, U. Ne fait rien si NoYield <> 0.
Sync_Yield:
    TST     NoYield
    BNE     SY_End
    PSHS    D,X,Y,U
    JSR     Sync_End
    JSR     Sync_Begin
    PULS    D,X,Y,U
SY_End:
    RTS

; A = colonne, B = ligne -> Y = VRAM_BASE + B*80 + A : source
; unique dans lib/vram.asm (apres le point d'entree).
    include "../lib/vram.asm"

; ===================================================================
; SAUVEGARDE / RESTAURATION D'UN RECTANGLE D'ÉCRAN (2 plans)
; Entrée : RectX, RectY, RectW, RectH (ombre comprise)
; Rect_Save / Rect_Restore : tampon SaveBuf (OSM-VISION et vis_MsgBox).
; Rect_Save_U / Rect_Restore_U : tampon en U (vis_Rect_Save/Restore,
; tampon de l'application). Plan caractères puis plan couleur.
; ===================================================================
Rect_Save:
    PSHS    U
    LDU     #SaveBuf
    BSR     Rect_Save_U
    PULS    U,PC

Rect_Save_U:                    ; U = tampon (avance)
    LDA     #VRAM_P0_CHR
    BSR     Rect_Pass_Save
    IFNE    YIELD_RECT
    JSR     Sync_Yield                  ; un plan par trame au minimum
    ENDC
    LDA     #VRAM_P0_COL
    BSR     Rect_Pass_Save
    RTS

; Remplit de couleur $00 (noir sur noir) le rectangle RectX/RectY/RectW/RectH
Rect_Blank:
    CLR     WinAcc
    CLR     WinAcc+1
    CLR     WinZero
    LDA     RectH
    STA     RectCnt
    LDB     RectY
RB_Row:
    PSHS    B
    LDA     RectX
    JSR     Calc_Addr
    LEAX    VRAM_COL_OFS,Y              ; plan couleurs
    LDB     RectW
    CLRA
    TFR     D,W
    LDY     #WinZero
    TFM     Y,X+
    PULS    B
    INCB
    CLRE
    LDF     RectW
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     RB_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
RB_NoYield:
    DEC     RectCnt
    BNE     RB_Row
    RTS

Rect_Pass_Save:                 ; A = plan (VRAM_P0_xxx), U = tampon (avance)
    STA     WinPlane
    CLR     WinAcc
    CLR     WinAcc+1
    LDA     RectH
    STA     RectCnt
    LDB     RectY
RPS_Row:
    PSHS    B
    LDA     RectX
    JSR     Calc_Addr
    TFR     Y,D                         ; + plan (poids fort)
    ADDA    WinPlane
    TFR     D,Y
    LDB     RectW
    CLRA
    TFR     D,W
    TFM     Y+,U+
    PULS    B
    INCB
    IFNE    YIELD_RECT
    CLRE
    LDF     RectW
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     RPS_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
RPS_NoYield:
    ENDC
    DEC     RectCnt
    BNE     RPS_Row
    RTS

Rect_Restore:
    PSHS    U
    LDU     #SaveBuf
    BSR     Rect_Restore_U
    PULS    U,PC

Rect_Restore_U:                 ; U = tampon (avance)
    IFNE    YIELD_RECT
    JSR     Rect_Blank                  ; noir sur noir : la restauration ne se voit pas, puis les couleurs révèlent
    JSR     Sync_Yield
    ENDC
    LDA     #VRAM_P0_CHR
    BSR     Rect_Pass_Rest
    IFNE    YIELD_RECT
    JSR     Sync_Yield
    ENDC
    LDA     #VRAM_P0_COL
    BSR     Rect_Pass_Rest
    RTS

; vis_Rect_Save / vis_Rect_Restore (lib/vis.inc) : A = colonne, B = ligne,
; W = largeur*256+hauteur, X = tampon de l'application. Préservent
; A, B, X, Y, U. Rectangle vide : rien (RectCnt partirait de 0 et
; ferait 256 lignes).
Vis_Rect_Save:
    PSHS    D,X,Y,U
    BSR     Vis_Rect_Args
    BEQ     VRS_End
    JSR     Rect_Save_U
VRS_End:
    PULS    D,X,Y,U,PC

Vis_Rect_Restore:
    PSHS    D,X,Y,U
    BSR     Vis_Rect_Args
    BEQ     VRR_End
    JSR     Rect_Restore_U
VRR_End:
    PULS    D,X,Y,U,PC

; Range A, B, W dans RectX..RectH, U = X. Z = 1 si largeur ou hauteur nulle.
Vis_Rect_Args:
    STA     RectX
    STB     RectY
    TFR     W,D
    STA     RectW
    STB     RectH
    TFR     X,U
    TSTA
    BEQ     VRA_End
    TSTB
VRA_End:
    RTS

Rect_Pass_Rest:                 ; A = plan (VRAM_P0_xxx), U = tampon (avance)
    STA     WinPlane
    CLR     WinAcc
    CLR     WinAcc+1
    LDA     RectH
    STA     RectCnt
    LDB     RectY
RPR_Row:
    PSHS    B
    LDA     RectX
    JSR     Calc_Addr
    TFR     Y,D                         ; + plan (poids fort)
    ADDA    WinPlane
    TFR     D,Y
    LDB     RectW
    CLRA
    TFR     D,W
    TFM     U+,Y+
    PULS    B
    INCB
    IFNE    YIELD_RECT
    CLRE
    LDF     RectW
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     RPR_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
RPR_NoYield:
    ENDC
    DEC     RectCnt
    BNE     RPR_Row
    RTS

; ===================================================================
; Put_Text : A = colonne, B = ligne, X = chaîne (0 final), TextAttr = attribut
; Texte ASCII (page 0 du générateur : l'attribut doit avoir le bit 7 à 0).
; ===================================================================
Put_Text:
    PSHS    U
    JSR     Calc_Addr
    LEAU    VRAM_COL_OFS,Y              ; U : les couleurs, 4 Ko plus haut
    CLRB
VPT_Chr:
    LDA     ,X+
    BEQ     VPT_ChrDone
    STA     ,Y+
    INCB
    BRA     VPT_Chr
VPT_ChrDone:
    TSTB
    BEQ     VPT_End
    CLRE                                ; W = B (non nul : teste plus haut)
    TFR     B,F
    LDD     #TextAttr                   ; TextAttr sert directement de source
    TFM     D,U+
    LDA     TextAttr                    ; sortie identique a l'ancienne boucle : A = octet, B = 0
    CLRB
VPT_End:
    PULS    U
    RTS

; vis_Text (lib/vis.inc) : comme Put_Text, mais l'attribut arrive en E,
; pour que l'application n'ait pas a connaitre l'adresse de TextAttr.
Vis_Text:
    STE     TextAttr
    BRA     Put_Text

; vis_PutCell (lib/vis.inc) : A = colonne, B = ligne, E = caractère,
; F = attribut. Préserve tous les registres.
Vis_PutCell:
    PSHS    D,Y
    JSR     Calc_Addr                   ; Y = adresse (détruit D)
    STE     ,Y
    STF     VRAM_COL_OFS,Y
    PULS    D,Y,PC

; vis_Fill (lib/vis.inc) : A = colonne, B = ligne, W = largeur*256+hauteur,
; Y = caractère*256+attribut. Un plan après l'autre, une ligne par TFM,
; par lots de YIELD_CELLS comme Rect_Blank. Préserve A, B, X, Y, U.
Vis_Fill:
    PSHS    D,X,Y,U
    STA     FillX
    STB     FillY
    TFR     W,D
    STA     FillW
    STB     FillH
    TFR     Y,D
    STA     FillChr
    STB     FillAttr
    TST     FillW                       ; rectangle vide : rien
    BEQ     VF_End
    TST     FillH
    BEQ     VF_End
    LDA     FillChr
    LDB     #VRAM_P0_CHR
    BSR     Fill_Pass
    LDA     FillAttr
    LDB     #VRAM_P0_COL
    BSR     Fill_Pass
VF_End:
    PULS    D,X,Y,U,PC

; A = octet à écrire, B = plan (VRAM_P0_xxx). Détruit D, X, Y, W.
Fill_Pass:
    STA     FillByte
    STB     WinPlane
    CLR     WinAcc
    CLR     WinAcc+1
    LDA     FillH
    STA     FillCnt
    LDB     FillY
FP_Row:
    PSHS    B
    LDA     FillX
    JSR     Calc_Addr
    TFR     Y,D                         ; + plan (poids fort)
    ADDA    WinPlane
    TFR     D,X
    CLRE
    LDF     FillW                       ; W = largeur (non nulle)
    LDY     #FillByte
    TFM     Y,X+
    PULS    B
    INCB
    CLRE
    LDF     FillW
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     FP_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
FP_NoYield:
    DEC     FillCnt
    BNE     FP_Row
    RTS

; ===================================================================
; vis_Input (lib/vis.inc) : ligne de saisie modale, partagée par
; Renommer, Exécuter et les applications. A = colonne, B = ligne,
; X = tampon, E = longueur max, F = options INP_*, Y = crochet ou 0.
; Sortie : C = 1 Echap ; sinon A = touche de sortie. B = longueur.
; Préserve X, Y, U.
; ===================================================================
Vis_Input:
    PSHS    X,Y,U
    STA     InpX
    STB     InpY
    STX     InpBuf
    STE     InpMax
    STF     InpFlags
    STY     InpHook
    CLRB                                ; longueur du texte prérempli,
VI_Len:                                 ; coupé à InpMax
    CMPB    InpMax
    BHS     VI_Cut
    LDA     B,X
    BEQ     VI_LenOk
    INCB
    BRA     VI_Len
VI_Cut:
    CLR     B,X
VI_LenOk:
    STB     InpLen
    JSR     Sync_Begin
    JSR     Inp_Draw
    JSR     Sync_End
VI_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     VI_Loop
    CMPA    #$1B
    BEQ     VI_Esc
    CMPA    #$0D
    BEQ     VI_Enter
    CMPA    #$08
    BEQ     VI_Back
    CMPA    #$20
    BLO     VI_Ctrl
    CMPA    #$7E
    BHI     VI_Loop
    LDB     InpFlags
    CMPA    #$20
    BNE     VI_NotSp
    BITB    #INP_SANS_ESPACE
    BNE     VI_Loop
VI_NotSp:
    BITB    #INP_MAJ
    BEQ     VI_Add
    CMPA    #$61                        ; minuscules -> majuscules
    BLO     VI_Add
    CMPA    #$7A
    BHI     VI_Add
    SUBA    #$20
VI_Add:
    LDB     InpLen
    CMPB    InpMax
    BHS     VI_Loop                     ; plein
    LDX     InpBuf
    ABX
    STA     ,X+
    CLR     ,X
    INC     InpLen
    BRA     VI_Refresh
VI_Back:
    LDB     InpLen
    BEQ     VI_Loop
    DECB
    STB     InpLen
    LDX     InpBuf
    CLR     B,X
VI_Refresh:
    JSR     Sync_Begin
    LDY     InpHook
    BEQ     VI_NoHook
    JSR     ,Y
VI_NoHook:
    JSR     Inp_Draw
    JSR     Sync_End
    BRA     VI_Loop
VI_Ctrl:
    LDB     InpFlags
    BITB    #INP_CTRL
    BEQ     VI_Loop
    BRA     VI_Out                      ; A = la touche de contrôle
VI_Enter:
    LDB     InpFlags
    BITB    #INP_NON_VIDE
    BEQ     VI_Out
    TST     InpLen
    BEQ     VI_Loop
VI_Out:
    LDB     InpLen
    ANDCC   #%11111110                  ; C = 0 : validé (ou touche INP_CTRL)
    PULS    X,Y,U,PC
VI_Esc:
    LDB     InpLen
    ORCC    #%00000001                  ; C = 1 : abandon
    PULS    X,Y,U,PC

; Le champ : texte, curseur '_', blancs jusqu'à InpMax+1 colonnes, fond
; COLOR_SEL. Entre Sync_Begin et Sync_End.
Inp_Draw:
    LDA     #COLOR_SEL
    STA     TextAttr
    LDU     #TmpStr
    LDX     InpBuf
    JSR     Vis_Append
    LDA     #$5F                        ; curseur
    STA     ,U+
ID_Pad:
    TFR     U,D
    SUBD    #TmpStr
    CMPB    InpMax
    BHI     ID_Done                     ; InpMax+1 colonnes écrites
    LDA     #$20
    STA     ,U+
    BRA     ID_Pad
ID_Done:
    CLR     ,U
    LDA     InpX
    LDB     InpY
    LDX     #TmpStr
    JMP     Put_Text

; ===================================================================
; BOÎTE DE MESSAGE : X = texte, Y = titre ; Entrée/Echap/Espace pour fermer
; ===================================================================
Msg_Box:
    STX     MsgText
    STY     MsgTitle
    JSR     Snd_Err
    LDA     #20
    STA     RectX
    LDA     #11
    STA     RectY
    LDA     #41
    STA     RectW
    LDA     #7
    STA     RectH
    JSR     Sync_Begin
    JSR     Rect_Save
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #20
    LDB     #11
    LDW     #(40*256)+6
    LDY     MsgTitle
    JSR     Draw_Window
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #22
    LDB     #13
    LDX     MsgText
    JSR     Put_Text
    LDA     #22
    LDB     #15
    LDX     #Txt_MsgHint
    JSR     Put_Text
    JSR     Sync_End
MB_Wait:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     MB_Wait
    CMPA    #$0D
    BEQ     MB_Close
    CMPA    #$1B
    BEQ     MB_Close
    CMPA    #$20
    BNE     MB_Wait
MB_Close:
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    RTS

Txt_MsgHint:    FCN "Entree : continuer"

; ===================================================================
; SONS : Snd_Err (vis_MsgBox), vis_Sound, vis_Sound_Stop
; ===================================================================
    include "../lib/snd.asm"
Snd_Err:    PSHS    A,X
            LDX     #Sd_Err
            BRA     Snd_Go
Vis_Sound:  PSHS    A,X                 ; vis_Sound : X = partition de l'application
            BRA     Snd_Go
Snd_Stop:   PSHS    A,X                 ; silence immédiat, même si le son est coupé
            LDX     #Sd_Off
            BRA     Snd_Force
Snd_Go:
    LDA     son_coupe
    CMPA    #SND_MUTED
    BEQ     SG_Out
Snd_Force:
    JSR     Snd_Start               ; declencheur commun (lib/snd.asm), puis
SG_Out:                              ; tombe sur la restauration du cadre Snd_Go
    PULS    A,X,PC

Sd_Err:                                 ; erreur / protégé : bourdonnement dissonant (do + do#)
    FDB     SN_C3,SN_Db3
    FCB     7
    FDB     SN_SIL,SN_SIL
    FCB     1
    FDB     SN_C3,SN_Db3
    FCB     7
    FDB     SN_END
Sd_Off:                                 ; silence
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_END

; ===================================================================
; Primitive Graphique
; ===================================================================
Draw_Window:
    PSHS    D
    TFR     W,D
    PSHS    D
    PSHS    Y
    PSHS    X,U

    LDB     9,S
    LDA     #80
    MUL
    ADDB    8,S
    ADCA    #0
    ADDD    #VRAM_BASE
    TFR     D,U

    IFNE    YIELD_WINDOW
    TST     NoYield
    BNE     WB_Done
    CLR     WinAcc                      ; 1. zone en noir sur noir : rien ne se voit pendant le dessin
    CLR     WinAcc+1
    CLR     WinZero
    LEAX    VRAM_COL_OFS,U              ; (plan couleurs)
    STX     WBPtr
    LDB     7,S                         ; hauteur + ligne d'ombre
    INCB
    PSHS    B                           ; compteur (les arguments se décalent d'un octet)
WB_Row:
    LDB     7,S                         ; largeur + colonne d'ombre
    INCB
    CLRA
    TFR     D,W
    LDX     WBPtr
    LDY     #WinZero
    TFM     Y,X+
    LDX     WBPtr
    LEAX    80,X
    STX     WBPtr
    CLRE
    LDF     7,S
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     WB_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
WB_NoYield:
    DEC     0,S
    BNE     WB_Row
    LEAS    1,S
    JSR     Sync_Yield                  ; les caractères partent dans une trame à part
WB_Done:
    ENDC

    CLR     WinAcc                      ; plan caractères
    CLR     WinAcc+1

    ; Y = titre. Y = 0 : fenêtre simple (menus, sans barre de titre)
    LDY     4,S
    BEQ     Plain_Top

    ; --- Barre de titre : rayures sur toute la largeur ---
    TFR     U,X
    LDB     6,S
    LDA     #UI_TITLE_BAR
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    LDA     #UI_CLOSE_BOX       ; case de fermeture, 2e colonne
    STA     1,U
    LDB     6,S                 ; case de zoom, avant-dernière colonne
    SUBB    #2
    LDA     #UI_ZOOM_BOX
    STA     B,U
    BRA     Top_Done

Plain_Top:
    TFR     U,X
    LDA     #UI_TOP_L
    STA     ,X+
    LDB     6,S
    SUBB    #2
    LDA     #UI_HORIZ_TOP
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    LDA     #UI_TOP_R
    STA     ,X+
Top_Done:

    LDB     7,S
    SUBB    #2
    PSHS    B
Mid_Rows:
    LEAU    80,U
    TFR     U,X
    LDA     #UI_VERT_L
    STA     ,X+
    LDB     7,S
    SUBB    #2
    LDA     #UI_SPACE
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    LDA     #UI_VERT_R
    STA     ,X+
    LDA     #UI_SHADOW
    STA     ,X+
    IFNE    YIELD_WINDOW
    CLRE                                ; lot de ~YIELD_CELLS octets, puis VSYNC suivant
    LDF     7,S                         ; (7,S : le compteur de lignes est empilé)
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     Mid_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
Mid_NoYield:
    ENDC
    DEC     0,S
    BNE     Mid_Rows
    LEAS    1,S

    LEAU    80,U
    TFR     U,X
    LDA     #UI_BOT_L
    STA     ,X+
    LDB     6,S
    SUBB    #2
    LDA     #UI_HORIZ_BOT
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    LDA     #UI_BOT_R
    STA     ,X+
    LDA     #UI_SHADOW
    STA     ,X+

    LEAU    80,U
    TFR     U,X
    LEAX    1,X
    LDB     6,S
    LDA     #UI_SHADOW
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+

    ; --- Filet sous la barre de titre (ligne y+1, entre les montants) ---
    LDY     4,S
    BEQ     Sep_Skip
    LDB     9,S
    INCB
    LDA     #80
    MUL
    ADDB    8,S
    ADCA    #0
    ADDD    #VRAM_BASE+1
    TFR     D,X
    LDB     6,S
    SUBB    #2
    LDA     #UI_HORIZ_TOP
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
Sep_Skip:

    CLR     WinAcc                      ; plan couleurs
    CLR     WinAcc+1

    LDB     9,S
    LDA     #80
    MUL
    ADDB    8,S
    ADCA    #0
    ADDD    #VRAM_COL
    TFR     D,U

    LDB     7,S
    PSHS    B
Col_Rows:
    TFR     U,X
    LDB     7,S
    LDA     #COLOR_WIN
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    LDA     #COLOR_SHADOW
    STA     ,X+
    LEAU    80,U
    IFNE    YIELD_WINDOW
    CLRE
    LDF     7,S
    ADDW    #COUT_LIGNE
    ADDW    WinAcc
    STW     WinAcc
    CMPW    #YIELD_CELLS
    BLO     Col_NoYield
    CLR     WinAcc
    CLR     WinAcc+1
    JSR     Sync_Yield
Col_NoYield:
    ENDC
    DEC     0,S
    BNE     Col_Rows
    LEAS    1,S

    TFR     U,X
    LEAX    1,X
    LDB     6,S
    LDA     #COLOR_SHADOW
    CLRE                                ; W = B (B = 0 : rien ; l'ancienne boucle en ecrivait 256)
    TFR     B,F
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+

    LDB     9,S                         ; plan caractères : le titre
    LDA     #80
    MUL
    ADDB    8,S
    ADCA    #0
    ADDD    #VRAM_BASE
    TFR     D,U

    LDY     4,S                 ; longueur du titre -> B
    LBEQ    Done_Draw           ; pas de titre : fenêtre simple
    CLRB
Title_Len:
    LDA     ,Y+
    BEQ     Title_Len_Done
    INCB
    BRA     Title_Len
Title_Len_Done:
    NEGB
    ADDB    6,S                 ; B = (largeur - longueur) / 2
    LSRB
    LEAU    B,U                 ; U = début du titre, centré

    TFR     U,X
    LDY     4,S
Title_Char:
    LDA     ,Y+
    BEQ     Title_Col
    STA     ,X+
    BRA     Title_Char

Title_Col:
    LEAX    VRAM_COL_OFS,U              ; plan couleurs
    LDY     4,S
    LDA     #COLOR_TITLE
Title_Col_Loop:
    LDB     ,Y+
    BEQ     Done_Draw
    STA     ,X+
    BRA     Title_Col_Loop

Done_Draw:
    PULS    X,U
    PULS    Y
    PULS    D
    PULS    D
    RTS


; Vis_Append - copie la chaîne X (sans le 0) à ,U+ (comme Append de
; lib/str.asm, qu'une application n'inclut pas forcément).
Vis_Append:
    LDA     ,X+
    BEQ     VAp_Fin
    STA     ,U+
    BRA     Vis_Append
VAp_Fin:
    RTS

; --- Variables ---
WinPlane        rmb 1           ; plan d'une passe Rect_Pass_* / Fill_Pass (poids fort à ajouter)
WinAcc          rmb 2           ; octets écrits depuis le dernier VSYNC (16 bits)
WinZero         rmb 1           ; octet à 0 : source du remplissage "noir" (TFM)
FillByte        rmb 1           ; source des remplissages TFM (TFM D,R+ : D pointe ici)
WBPtr           rmb 2
NoYield         rmb 1           ; <>0 : Sync_Yield ne fait rien (Draw_Base_UI)
RectX           rmb 1           ; rectangle sauvegardé / restauré
RectY           rmb 1
RectW           rmb 1
RectH           rmb 1
RectCnt         rmb 1
TextAttr        rmb 1           ; attribut utilisé par Put_Text
FillX           rmb 1           ; vis_Fill : rectangle, caractère, attribut
FillY           rmb 1
FillW           rmb 1
FillH           rmb 1
FillChr         rmb 1
FillAttr        rmb 1
FillCnt         rmb 1           ; lignes restantes
InpX            rmb 1           ; vis_Input : position du champ
InpY            rmb 1
InpBuf          rmb 2           ; tampon de l'appelant
InpMax          rmb 1           ; longueur max (<= 78 : TmpStr fait 80)
InpFlags        rmb 1           ; options INP_*
InpHook         rmb 2           ; crochet apres chaque modification, ou 0
InpLen          rmb 1           ; longueur courante
TmpStr          rmb 80
MsgText         rmb 2
MsgTitle        rmb 2
SaveBuf         rmb SAVE_BUF_SIZE
