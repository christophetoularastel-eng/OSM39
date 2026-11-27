; ===================================================================
; BRIQUES.ASM - Jeu Briques pour OSM39 V2 / OSM-VISION
; ===================================================================
; SOUS-APPLICATION OSMVISION. A distinguer d'un executable console :
;
;   * lié à $4000, PAS à $0000 (voir games/Makefile). OSMVISION occupe
;     $0000..$3xxx (voir OSMVISION.map : la longueur de .code doit rester
;     < $4000) ; chargé à $0000, ce jeu l'écraserait, point d'entrée
;     compris, et il n'y aurait plus de quoi revenir à l'interface.
;
;   * lancé par OSMVISION via FS_LoadFile, pas par sys_loadandexec. Marqué
;     par le bit 4 de l'attribut OSMFS : CHMOD BRIQUES +x+a
;
;   * à l'entrée, argv/argc/input_buffer (RAM système $C000+) sont
;     renseignés par OSMVISION ; BRIQUES n'en tient pas compte pour l'instant.
;     Les IRQ sont ACTIFS et le curseur est garé : sys_video_wait_vsync
;     en a besoin, et c'est la machine hôte qui le gare.
;
;   * à la sortie : RTS, et surtout PAS d'effacement d'écran. OSMVISION a
;     sauvegardé les deux plans avant l'appel et les restaure après ; un
;     effacement ici laisserait un écran noir au retour.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    export Briques_Start

; --- UI & Constantes Graphiques ---
WIN_X           equ 24          ; Colonne de la fenêtre
WIN_Y           equ 1           ; Ligne de la fenêtre (la ligne 0 reste noire sur la carte)
WIN_W           equ 32          ; Largeur totale
WIN_H           equ 23          ; Hauteur totale : ombre en ligne 24, la dernière sauvegardée par OSM-VISION

BOARD_X         equ WIN_X+2     ; Début de la grille (20 caractères de large = 10 blocs)
BOARD_Y         equ WIN_Y+2     ; Début de la grille (20 lignes de haut), sous le filet du titre
BOARD_W         equ 10
PANEL_X         equ WIN_X+24    ; panneau de score, à droite de la paroi (WIN_X+22)
; Services d'OSM-VISION utilises : jusqu'a vis_Rect_Restore (lib/vis.inc)
VIS_REQUIS      equ (vis_Rect_Restore/2)+1
; Fenetre de pause, par-dessus le puits (ombre : +1 colonne, +1 ligne)
PAUSE_X         equ BOARD_X+4
PAUSE_Y         equ BOARD_Y+8
PAUSE_W         equ 12
PAUSE_H         equ 3
BOARD_H         equ 20

; Cases vides du puits : fond noir, PREMIER PLAN $8 (noir vif) et non 0.
; Le caractère est vide, donc l'écran est le même noir. Mais sur la carte,
; des cases au premier plan 0 montrent de fins pointillés roses verticaux
; dès qu'il y a du contenu à côté sur la même ligne (bureau, fenêtre de
; fichiers) : MIRE, touche P, essai 3 ($20/$08) propre, essai 1 ($20/$00)
; non (9 oct. 2026). Défaut matériel du chemin couleur, contourné ici.
COLOR_BOARD     equ $08
CHAR_BLOCK      equ $DB         ; Code d'un bloc plein (Ajuste selon ton générateur vidéo)
CHAR_EMPTY      equ $20         ; Espace (dessine le fond noir du puits)
CHAR_BRICK_L    equ $FD         ; Remplace par l'index réel de ton caractère gauche
CHAR_BRICK_R    equ $FE         ; Remplace par l'index réel de ton caractère droit
; Couleurs des pièces (Atributs VRAM P0_COL)
COL_I           equ $3F         ; Cyan
COL_J           equ $1F         ; Bleu
COL_L           equ $2F         ; Vert  (fond 2)
COL_O           equ $6F         ; Jaune
COL_S           equ $4F         ; Rouge (fond 4)
COL_T           equ $5F         ; Violet
COL_Z           equ $70         ; Blanc (fond 7, avant-plan noir : $7F serait blanc sur blanc = bloc plein)
; --- Rendu différentiel ---
MAXW            equ 24          ; cases écrites par trame (objectif)
WR_CAP          equ 40          ; capacité de la liste d'écritures
SCAN_BUDGET     equ 64          ; cases évaluées par trame lors d'un rafraîchissement complet
DIRTY_CAP       equ 32          ; cases "à réévaluer" mémorisées entre deux trames

; Glyphes semi-graphiques et couleurs : source unique dans lib/ui.inc
; (le look vient de la, plus d'une recopie locale du tableau).
    include "../lib/ui.inc"
; Fenetres, texte et son : services d'OSM-VISION, resident en $0000-$3FFF
; pendant qu'on tourne (table de sauts, contrat dans lib/vis.inc).
    include "../lib/vis.inc"
; Notes, SND_PTR/SND_TIMER et format de partition : source unique dans
; lib/snd.inc (partagee avec OSM-VISION ; hardware.inc est inclus plus haut).
    include "../lib/snd.inc"
; --- Effets sonores BRIQUES : alias vers la table de lib/snd.inc quand la
; valeur est EXACTEMENT la meme, constante locale sinon ---
SFX_SILENCE equ SN_SIL       ; Silence
SFX_END     equ SN_END       ; Marqueur de fin
SFX_LINE2   equ SN_E5        ; Mi5
SFX_LINE3   equ SN_G5        ; Sol5
SFX_BEEP    equ $0800        ; Bruit de rotation (pas dans la table)
SFX_DROP    equ $0C00        ; Bruit de chute lourde (pas dans la table)
SFX_LINE1   equ $06E0        ; Do5 voisin de SN_C5 ($06E1) mais different : reste local


    section .code

Briques_Start:
    ANDCC   #%11101111
    ; 0. L'OSM-VISION charge connait-il tous les services qu'on appelle ?
    ;    Sinon le JSR [VIS_TABLE+...] partirait n'importe ou.
    LDA     >VIS_COUNT_ADR
    CMPA    #VIS_REQUIS
    BHS     TS_VisOk
    CMPA    #(vis_MsgBox/2)+1
    BLO     TS_Abandon      ; pas meme la boite de message : on rend la main
    LDX     #TxtVisVieux
    LDY     #TitleBriques
    JSR     [VIS_TABLE+vis_MsgBox]
TS_Abandon:
    RTS
TS_VisOk:
    JSR     Joy_Init                ; le joystick (/BIN/JOYSTICK.CFG)
    ; 1. Initialisation du jeu
    JSR     Reset_Score
    JSR     Clear_Board
    JSR     Spawn_Piece

    ; 2. Dessiner l'interface graphique façon OSM-VISION
    JSR     Draw_Briques_Window
    JSR     Init_Disp               ; rien n'est encore affiché dans le puits
    JSR     Mark_All                ; le rendu différentiel le dessinera par morceaux

; -------------------------------------------------------------------
; BOUCLE PRINCIPALE (Game Loop)
; Cadencée par le VSYNC du 6845
; -------------------------------------------------------------------
Main_Loop:
    JSR     Prepare_Writes  ; (RAM seulement) calcule ce qui a changé depuis la dernière trame
    LDE     #1              ; un VSYNC : 60 Hz
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Apply_Writes    ; écrit en VRAM tout de suite après le VSYNC, IRQ masquées, très court
    TST     LastWr
    BNE     ML_NoScore      ; trame déjà occupée par le puits : le score attend
    JSR     Score_Step
ML_NoScore:

    ; Compteur de gravité pour la chute de la pièce
    INC     DropTimer
    LDA     DropTimer
    CMPA    #30             ; Vitesse de chute (30 trames = 0,5 s)
    BLO     Check_Keys
    CLR     DropTimer
    JSR     Move_Down

Check_Keys:
    JSR     Joy_Touche      ; le joystick d'abord : A = la touche qu'il fait
    BNE     CK_Action
    TST     NEW_CODE        ; Y a-t-il une nouvelle touche pressée ? (Ton astuce !)
    LBEQ    Main_Loop        ; Si 0, aucune touche -> on saute le scan bloquant
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    LBEQ    Main_Loop
CK_Action:

    CMPA    #$1B            ; Echap -> Quitter
    BEQ     Quit_Game
    CMPA    #$80            ; Flèche HAUT -> Rotation
    BEQ     Do_Rotate
    CMPA    #$81            ; Flèche BAS -> Chute accélérée
    BEQ     Do_Down
    CMPA    #$82            ; Flèche GAUCHE -> Gauche
    BEQ     Do_Left
    CMPA    #$83            ; Flèche DROITE -> Droite
    BEQ     Do_Right
    CMPA    #$20            ; Espace -> Drop instantané
    BEQ     Do_Drop
    CMPA    #'P'            ; P -> Pause
    LBEQ    Do_Pause
    CMPA    #'p'
    LBEQ    Do_Pause

    LBRA    Main_Loop

Do_Left:
    JSR     Move_Left
    LBRA    Main_Loop

Do_Right:
    JSR     Move_Right
    LBRA    Main_Loop

Do_Down:
    JSR     Move_Down
    LBRA    Main_Loop

Do_Rotate:
    JSR     Rotate_Piece
    LBRA    Main_Loop

Do_Drop:
Drop_Loop:
    JSR     Move_Down
    LDA     PieceLanded
    BEQ     Drop_Loop
    LBRA    Main_Loop

Quit_Game:
    JSR     [VIS_TABLE+vis_Sound_Stop] ; coupe le séquenceur : sinon il lirait une partition
                            ; située dans notre zone, que la prochaine application écrasera
    ; RIEN à nettoyer ici. OSMVISION a sauvegardé les deux plans avant de
    ; nous appeler et les restaure après le RTS : effacer l'écran laisserait
    ; un rectangle noir au retour, et le repaint complet est exactement ce
    ; que le tampon de sauvegarde nous evite.
    RTS

; Pause : sauve le dessous (vis_Rect_Save, tampon a nous), petite fenetre,
; une touche, puis remet le dessous tel quel (vis_Rect_Restore). Le
; rendu differentiel n'en sait rien : la VRAM redevient ce qu'il croit.
Do_Pause:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #PAUSE_X
    LDB     #PAUSE_Y
    LDW     #((PAUSE_W+1)*256)+PAUSE_H+1
    LDX     #PauseBuf
    JSR     [VIS_TABLE+vis_Rect_Save]
    LDW     #(PAUSE_W*256)+PAUSE_H ; A, B preserves ; W detruit
    LDY     #0              ; cadre simple, sans titre
    JSR     [VIS_TABLE+vis_Window]
    LDA     #PAUSE_X+4
    LDB     #PAUSE_Y+1
    LDE     #COLOR_TEXT
    LDX     #TxtPause
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
DP_Wait:
    JSR     Attend_Touche   ; une touche, ou le bouton du joystick
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #PAUSE_X
    LDB     #PAUSE_Y
    LDW     #((PAUSE_W+1)*256)+PAUSE_H+1
    LDX     #PauseBuf
    JSR     [VIS_TABLE+vis_Rect_Restore]
    JSR     [VIS_TABLE+vis_Sync_End]
    LBRA    Main_Loop

; -------------------------------------------------------------------
; JOYSTICK (lib/joy.asm, Joy_Evts : un pas à l'appui, puis toutes les 3
; trames après 12) : Joy_Touche -> A = la touche qu'il fait (Z = 1 :
; aucune) : bouton = Espace (chute), haut = rotation, gauche, droite, bas.
; -------------------------------------------------------------------
Joy_Touche:
    JSR     Joy_Evts
    BEQ     JT_Fin
    LDB     #$20
    BITA    #JOY_BOUTON
    BNE     JT_B
    LDB     #$80
    BITA    #JOY_HAUT
    BNE     JT_B
    LDB     #$82
    BITA    #JOY_GAUCHE
    BNE     JT_B
    LDB     #$83
    BITA    #JOY_DROITE
    BNE     JT_B
    LDB     #$81
JT_B:
    TFR     B,A
JT_Fin:
    RTS

; Attend_Touche : une touche (sys_kbd_poll), ou le bouton du joystick
; (A = $20, Espace), une trame à la fois -> A
Attend_Touche:
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    BNE     AT_Fin
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Joy_Evts
    BITA    #JOY_BOUTON
    BEQ     Attend_Touche
    LDA     #$20
AT_Fin:
    RTS

; -------------------------------------------------------------------
; LOGIQUE DU JEU (Grille,Collisions & Pièces)
; -------------------------------------------------------------------

Clear_Board:
    LDX     #BoardGrid
    LDW     #BOARD_W*BOARD_H
    CLRA
CB_Loop:
    STA     ,X+
    DECW
    ;LEAW    -1,W
    CMPW    #0
    BNE     CB_Loop
    RTS

Spawn_Piece:
    CLR     PieceLanded
    LDA     #3              ; Position X de départ (centré)
    STA     PieceX
    CLR     PieceY          ; Ligne 0

    ; Générateur de pièce simple (0 à 6)
    LDA     RandomSeed
    INCA
    STA     RandomSeed
    LSRA
    ANDA    #$07
    CMPA    #7
    BLO     SP_Ok
    SUBA    #7
SP_Ok:
    STA     PieceType
    CLR     PieceRot

    ; Tester la collision immédiate (Game Over)
    JSR     Check_Collision
    ;BCC     SP_End
    ; Si collision au spawn = Fin de partie !
    ;JSR     Clear_Board
SP_End:
    RTS

Move_Left:
    DEC     PieceX
    JSR     Check_Collision
    BCC     ML_Ok
    INC     PieceX          ; Obstacle : on annule, rien à redessiner
    RTS
ML_Ok:
    INC     PieceX          ; ancienne position
    JSR     Mark_Piece
    DEC     PieceX          ; nouvelle position
    JSR     Mark_Piece
    RTS

Move_Right:
    INC     PieceX
    JSR     Check_Collision
    BCC     MR_Ok
    DEC     PieceX          ; Obstacle : on annule
    RTS
MR_Ok:
    DEC     PieceX
    JSR     Mark_Piece
    INC     PieceX
    JSR     Mark_Piece
    RTS

Move_Down:
    INC     PieceY
    JSR     Check_Collision
    BCC     MD_Ok
    LDX     #Sfx_Lock
    JSR     [VIS_TABLE+vis_Sound]      ; Déclenche le son de chute
    ; Touche le fond ou une brique : Verrouillage
    DEC     PieceY
    JSR     Lock_Piece
    JSR     Check_Lines
    JSR     Spawn_Piece
    BCS     Trigger_GameOver    ; Si Carry=1 au spawn, la partie est perdue !
    LDA     #1
    STA     PieceLanded
    JSR     Mark_All        ; la grille a changé : réévaluation complète, par morceaux
    RTS
MD_Ok:
    DEC     PieceY
    JSR     Mark_Piece
    INC     PieceY
    JSR     Mark_Piece
    RTS
Trigger_GameOver:
    JSR     Mark_All        ; montre la grille finale (le bloc qui bloque)

Game_Over:
    LDX     #Sfx_GameOver
    JSR     [VIS_TABLE+vis_Sound]
    JSR     Flush_Render    ; termine l'affichage du puits (quelques trames)

    ; Affiche "GAME OVER" par-dessus les briques, dans la fenêtre d'accès VRAM
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDE     #COLOR_TEXT
    LDA     #WIN_X+10
    LDB     #BOARD_Y+7
    LDX     #TxtGameOver1
    JSR     [VIS_TABLE+vis_Text]
    LDE     #COLOR_TEXT     ; vis_Text detruit W
    LDA     #WIN_X+10
    LDB     #BOARD_Y+9
    LDX     #TxtGameOver2
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]

GO_Wait:
    JSR     Attend_Touche   ; une touche, ou le bouton du joystick (Espace)

    CMPA    #$1B            ; Echap -> Quitter vers OSM-VISION
    lBEQ     Quit_Game
    CMPA    #$20            ; Espace -> Rejouer
    BNE     GO_Wait

    ; --- Relancer une partie ---
    JSR     Reset_Score
    JSR     Clear_Board
    JSR     Spawn_Piece
    JSR     Init_Disp       ; l'écran contient GAME OVER : tout le puits est "inconnu"
    JSR     Mark_All
    LDA     #1
    STA     ScoreStep       ; le score remis à zéro doit être réécrit
    CLR     DropTimer
    JMP     Main_Loop       ; Repart pour un tour !

Rotate_Piece:
    LDA     PieceRot
    INCA
    ANDA    #$03
    STA     PieceRot
    JSR     Check_Collision
    BCC     RO_Ok

    ; Obstacle : on annule la rotation
    LDA     PieceRot
    DECA
    ANDA    #$03
    STA     PieceRot
    RTS
RO_Ok:
    LDA     PieceRot        ; ancienne rotation
    DECA
    ANDA    #$03
    STA     PieceRot
    JSR     Mark_Piece
    LDX     #Sfx_Rotate
    JSR     [VIS_TABLE+vis_Sound]      ; Déclenche le "Bip" de rotation
    LDA     PieceRot        ; nouvelle rotation
    INCA
    ANDA    #$03
    STA     PieceRot
    JSR     Mark_Piece
    RTS
; -------------------------------------------------------------------
; VERIFICATION DES COLLISIONS
; Sortie: Carry=1 si collision,Carry=0 si déplacement valide
; -------------------------------------------------------------------
Check_Collision:
    LDX     #PiecesData
    LDA     PieceType
    LDB     #16
    MUL
    LEAX    D,X
    LDA     PieceRot
    LDB     #8
    MUL
    LEAX    D,X

    LDB     #4
CC_Loop:
    LDA     ,X+             ; Offset dX
    ADDA    PieceX
    BMI     CC_Hit
    CMPA    #BOARD_W
    BHS     CC_Hit
    STA     TmpX            ; Sauvegarde du X calculé

    LDA     ,X+             ; Offset dY
    ADDA    PieceY
    BMI     CC_Hit
    CMPA    #BOARD_H
    BHS     CC_Hit

    PSHS    B,X
    LDB     #BOARD_W
    MUL                     ; D = Y * 10
    ADDD    #BoardGrid
    TFR     D,Y             ; Y pointe sur le début de la ligne
    LDB     TmpX
    LDA     B,Y             ; Safe : B est entre 0 et 9
    PULS    B,X
    BNE     CC_Hit

    DECB
    BNE     CC_Loop
    ANDCC   #$FE            ; Carry = 0 (Pas de collision)
    RTS

CC_Hit:
    ORCC    #$01            ; Carry = 1 (Collision)
    RTS

; Verrouille la pièce active dans la grille
Lock_Piece:
    LDX     #PiecesData
    LDA     PieceType
    LDB     #16
    MUL
    LEAX    D,X
    LDA     PieceRot
    LDB     #8
    MUL
    LEAX    D,X

    LDB     #4
LP_Loop:
    LDA     1,X             ; dY
    ADDA    PieceY
    PSHS    B
    LDB     #BOARD_W
    MUL                     ; D = Y * 10
    ADDD    #BoardGrid
    TFR     D,Y             ; Y pointe sur le début de la ligne

    LDB     ,X              ; dX
    ADDB    PieceX          ; B = dX + PieceX

    LDA     PieceType
    INCA
    STA     B,Y             ; Safe : B max = 9 (évite l'overflow signé)

    PULS    B
    LEAX    2,X
    DECB
    BNE     LP_Loop
    RTS
; Nettoyage des lignes complètes
Check_Lines:
    LDB     #BOARD_H-1
CL_RowLoop:
    PSHS    B
    ; Vérifier si la ligne B est pleine
    LDX     #BoardGrid
    LDA     #BOARD_W
    MUL                     ; Ici c'est sûr, B a été sauvegardé au-dessus
    ADDD    #BoardGrid
    TFR     D,X
    LDB     #BOARD_W
CL_CellLoop:
    LDA     ,X+
    BEQ     CL_NextRow
    DECB
    BNE     CL_CellLoop

    ; --- Ligne pleine ! Décaler tout le plateau ---
    INC     Lines
    JSR     Add_Line_Score
    LDX     #Sfx_Clear
    JSR     [VIS_TABLE+vis_Sound]      ; Déclenche la petite musique de victoire !
    PULS    B               ; On récupère B (la ligne pleine)
    PSHS    B               ; On le remet sur la pile pour CL_NextRow
CL_ShiftRow:
    CMPB    #0
    BEQ     CL_ClearTop
    DECB                    ; B = ligne destination - 1 (source)

    ; --- LA CORRECTION EST ICI ---
    PSHS    B               ; SAUVEGARDER LE COMPTEUR B !
    LDA     #BOARD_W
    MUL                     ; ATTENTION: MUL écrase B (D = A * B) !
    ADDD    #BoardGrid
    TFR     D,X             ; X = Ligne Source
    LEAY    BOARD_W,X       ; Y = Ligne Destination (Source + 10)
    LDW     #BOARD_W
    TFM     X+,Y+           ; Copie la ligne complète
    PULS    B               ; RESTAURER LE COMPTEUR B !
    ; -----------------------------

    BRA     CL_ShiftRow

CL_ClearTop:
    LDX     #BoardGrid
    LDB     #BOARD_W
    CLRA
CL_CTLoop:
    STA     ,X+
    DECB
    BNE     CL_CTLoop

    ; On a descendu les lignes, il faut revérifier la ligne actuelle
    PULS    B               ; On récupère B (la ligne qui était pleine)
    INCB                    ; +1 pour compenser le DECB de CL_NextRow
    PSHS    B               ; On remet sur la pile

CL_NextRow:
    PULS    B
    DECB
    BPL     CL_RowLoop
    RTS

; -------------------------------------------------------------------
; RENDU GRAPHIQUE DANS LA VRAM DU 6845
; -------------------------------------------------------------------
; Cadre, fond, ombre et titre : vis_Window, le meme dessin que les
; fenetres d'OSM-VISION. Le puits (lignes BOARD_Y..BOARD_Y+19) est peint
; ensuite par le rendu differentiel, par-dessus l'interieur.
Draw_Briques_Window:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TitleBriques
    JSR     [VIS_TABLE+vis_Window]
    JSR     Draw_Well

    ; Panneau de score
    LDE     #COLOR_TEXT
    LDA     #PANEL_X
    LDB     #WIN_Y+4
    LDX     #TxtScore
    JSR     [VIS_TABLE+vis_Text]
    LDE     #COLOR_TEXT
    LDA     #PANEL_X
    LDB     #WIN_Y+8
    LDX     #TxtLines
    JSR     [VIS_TABLE+vis_Text]
    JSR     Update_Score_Display
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; ===================================================================
; RENDU DIFFÉRENTIEL DU PUITS
;
; Le jeu ne dessine plus rien directement. Les actions MARQUENT les cases
; touchées (Mark_Piece / Mark_All). A chaque trame :
;   Prepare_Writes (RAM seulement, n'importe quand) compare ce qu'on veut
;       afficher à ce qui l'est déjà (Disp) et ne retient que les cases qui
;       diffèrent : liste WrAddr / WrVal.
;   Apply_Writes (juste après le VSYNC, IRQ masquées) écrit cette liste :
;       chaque case, caractères puis couleurs 4 Ko plus haut (V4 : $9000).
;       Un déplacement = quelques octets, donc
;       quelques centaines de cycles passés hors affichage -> plus de
;       clignotement. Une case effacée puis redessinée à l'identique (le
;       recouvrement ancienne/nouvelle pièce) n'est même pas écrite.
; Valeur d'une case : 0 = vide, 1..7 = type de pièce + 1 (= ColorTable).
; ===================================================================
Init_Disp:
    LDX     #Disp
    LDB     #BOARD_W*BOARD_H
    LDA     #$FF            ; $FF = "inconnu" : sera toujours différent
ID_Loop:
    STA     ,X+
    DECB
    BNE     ID_Loop
    CLR     DirtyCnt
    CLR     WrCnt
    CLR     LastWr
    CLR     ScoreStep
    CLR     FullDirty
    RTS

; Termine l'affichage en attente (balayage complet compris), trame par trame
Flush_Render:
    JSR     Prepare_Writes
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Apply_Writes
    TST     FullDirty
    BNE     Flush_Render
    TST     DirtyCnt
    BNE     Flush_Render
    TST     WrCnt
    BNE     Flush_Render
    RTS

; Tout réévaluer, progressivement (une partie du puits à chaque trame)
Mark_All:
    LDA     #1
    STA     FullDirty
    CLR     ScanX
    CLR     ScanY
    CLR     DirtyCnt
    RTS

; Ajoute les 4 cases de la pièce COURANTE (position et rotation actuelles)
; à la liste des cases à réévaluer.
Mark_Piece:
    LDA     DirtyCnt
    CMPA    #DIRTY_CAP-4
    BHI     Mark_All        ; liste pleine : on repasse en réévaluation complète
    LDX     #PiecesData
    LDA     PieceType
    LDB     #16
    MUL
    LEAX    D,X
    LDA     PieceRot
    LDB     #8
    MUL
    LEAX    D,X
    LDA     #4
    STA     CpCnt
MP_Loop:
    LDA     ,X              ; dX
    ADDA    PieceX
    BMI     MP_Skip
    CMPA    #BOARD_W
    BHS     MP_Skip
    STA     TmpX
    LDA     1,X             ; dY
    ADDA    PieceY
    BMI     MP_Skip
    CMPA    #BOARD_H
    BHS     MP_Skip
    STA     TmpY
    PSHS    X
    LDB     DirtyCnt
    ASLB                    ; 2 octets par entrée (x, y)
    LDX     #DirtyList
    ABX
    LDA     TmpX
    STA     ,X
    LDA     TmpY
    STA     1,X
    INC     DirtyCnt
    PULS    X
MP_Skip:
    LEAX    2,X
    DEC     CpCnt
    BNE     MP_Loop
    RTS

; PCell[0..3] = indices (0..199) des cases de la pièce courante, $FF si hors puits
Calc_PCells:
    LDX     #PiecesData
    LDA     PieceType
    LDB     #16
    MUL
    LEAX    D,X
    LDA     PieceRot
    LDB     #8
    MUL
    LEAX    D,X
    LDY     #PCell
    LDA     #4
    STA     CpCnt
CP_Loop:
    LDA     ,X
    ADDA    PieceX
    BMI     CP_Out
    CMPA    #BOARD_W
    BHS     CP_Out
    STA     TmpX
    LDA     1,X
    ADDA    PieceY
    BMI     CP_Out
    CMPA    #BOARD_H
    BHS     CP_Out
    LDB     #BOARD_W
    MUL                     ; D = y * 10
    ADDB    TmpX
    BRA     CP_Store
CP_Out:
    LDB     #$FF
CP_Store:
    STB     ,Y+
    LEAX    2,X
    DEC     CpCnt
    BNE     CP_Loop
    RTS

; Construit la liste d'écritures de la trame suivante (aucun accès VRAM)
Prepare_Writes:
    CLR     WrCnt
    JSR     Calc_PCells
    LDA     DirtyCnt
    BEQ     PW_Scan
    CLR     PWi
PW_D:
    LDA     PWi
    ASLA
    LDX     #DirtyList
    LEAX    A,X
    LDA     ,X
    STA     EvX
    LDA     1,X
    STA     EvY
    JSR     Eval_Cell
    INC     PWi
    LDA     PWi
    CMPA    DirtyCnt
    BLO     PW_D
    CLR     DirtyCnt
PW_Scan:
    TST     FullDirty
    BEQ     PW_End
    LDA     #SCAN_BUDGET
    STA     PWBudget
PW_S:
    LDA     WrCnt
    CMPA    #MAXW
    BHS     PW_End
    LDA     ScanX
    STA     EvX
    LDA     ScanY
    STA     EvY
    JSR     Eval_Cell
    INC     ScanX
    LDA     ScanX
    CMPA    #BOARD_W
    BLO     PW_Next
    CLR     ScanX
    INC     ScanY
    LDA     ScanY
    CMPA    #BOARD_H
    BLO     PW_Next
    CLR     ScanY           ; tout le puits a été passé en revue
    CLR     FullDirty
    BRA     PW_End
PW_Next:
    DEC     PWBudget
    BNE     PW_S
PW_End:
    RTS

; Évalue la case (EvX, EvY) : valeur voulue = pièce courante ou grille.
; Si elle diffère de Disp, met à jour Disp et ajoute une écriture.
Eval_Cell:
    LDA     EvY
    LDB     #BOARD_W
    MUL                     ; D = EvY * 10
    ADDB    EvX             ; B = indice 0..199
    STB     EvIdx
    LDX     #PCell
    LDA     #4
EC_P:
    CMPB    ,X+
    BEQ     EC_Piece
    DECA
    BNE     EC_P
    LDX     #BoardGrid
    ABX
    LDA     ,X              ; valeur de la grille
    BRA     EC_Have
EC_Piece:
    LDA     PieceType
    INCA
EC_Have:                    ; A = valeur voulue
    LDX     #Disp
    LDB     EvIdx
    ABX
    CMPA    ,X
    BEQ     EC_End          ; déjà affiché tel quel
    LDB     WrCnt
    CMPB    #WR_CAP
    BHS     EC_Full
    STA     ,X              ; Disp[indice] = valeur
    LDX     #WrVal
    ABX                     ; X = WrVal + WrCnt
    STA     ,X
    LDA     EvY             ; adresse VRAM = RowAddr[y] + 2*x
    ASLA
    LDX     #RowAddr
    LDX     A,X
    LDA     EvX
    ASLA
    IFNE    CARTE_MONO      ; mono : 2 octets par cellule
    ASLA
    ENDC
    TFR     A,B
    ABX
    LDB     WrCnt
    ASLB
    LDY     #WrAddr
    LEAY    B,Y
    STX     ,Y
    INC     WrCnt
EC_End:
    RTS
EC_Full:                    ; liste pleine : on laissera le balayage complet s'en charger
    LDA     #1
    STA     FullDirty
    CLR     ScanX
    CLR     ScanY
    RTS

; Écrit la liste en VRAM : à appeler JUSTE APRÈS le VSYNC
Apply_Writes:
    LDA     WrCnt
    STA     LastWr
    BEQ     AW_End
    ORCC    #%00010000      ; IRQ masquées : pas d'IRQ au milieu des écritures
    LDU     #WrAddr         ; V4 : caractères en ,Y, couleurs en VRAM_COL_OFS,Y
    LDX     #WrVal
    LDB     WrCnt
AW_Cell:
    LDY     ,U++            ; adresse VRAM (16 bits : l'autoincrément de 2 est voulu ici)
    LDA     ,X+             ; valeur 0..7 (0 = case vide)
    PSHS    A
    BNE     AW_Brick
    LDA     #CHAR_EMPTY
    STA     ,Y
    STA     VRAM_PAS,Y
    BRA     AW_Col
AW_Brick:
    LDA     #CHAR_BRICK_L
    STA     ,Y
    LDA     #CHAR_BRICK_R
    STA     VRAM_PAS,Y
AW_Col:
    PULS    A
    PSHS    X
    LDX     #ColorTable
    LDA     A,X
    PULS    X
    STA     VRAM_COL_OFS,Y
    STA     VRAM_COL_OFS+VRAM_PAS,Y
    DECB
    BNE     AW_Cell
    ANDCC   #%11101111
    CLR     WrCnt
AW_End:
    RTS

; Score : une ligne de texte par trame (le texte coûte cher), seulement quand
; le puits n'a rien eu à écrire.
Score_Step:
    LDA     ScoreStep
    BEQ     SS_End
    ORCC    #%00010000
    LDE     #COLOR_TEXT
    LDA     ScoreStep
    CMPA    #1
    BNE     SS_Lines
    LDA     #PANEL_X
    LDB     #WIN_Y+5
    LDX     #ValScore
    JSR     [VIS_TABLE+vis_Text]
    LDA     #2
    STA     ScoreStep
    BRA     SS_Done
SS_Lines:
    LDA     #PANEL_X
    LDB     #WIN_Y+9
    LDX     #ValLines
    JSR     [VIS_TABLE+vis_Text]
    CLR     ScoreStep
SS_Done:
    ANDCC   #%11101111
SS_End:
    RTS

; Table des adresses VRAM du debut de chaque ligne du puits :
; source unique dans lib/rowaddr.inc (BOARD_X/BOARD_Y ci-dessus).
    include "../lib/rowaddr.inc"

Reset_Score:
    LDX     #ValLines
    LDD     #$3030              ; "00"
    STD     ,X
    LDA     #$30                ; "0"
    STA     2,X
    LDX     #ValScore
    LDD     #$3030
    STD     ,X
    STD     2,X
    STD     4,X
    RTS

Add_Line_Score:
    LDA     #1
    STA     ScoreStep       ; Score_Step réécrira les deux lignes de texte
    ; +1 Ligne (incrémente les unités des lignes)
    LDX     #ValLines+2
    JSR     Inc_Ascii
    ; +10 au Score (incrémente les dizaines du score)
    LDX     #ValScore+4
    JSR     Inc_Ascii
    RTS

; Incrementation d'entier ASCII avec retenue (score) : source
; unique dans lib/ascii.asm (X = chiffre des unites).
    include "../lib/ascii.asm"

; Parois et fond du puits, par-dessus la fenetre de vis_Window, avec
; vis_PutCell et vis_Fill (attribut COLOR_WIN, celui de la fenetre).
;   ligne BOARD_Y-1 (filet)      UI_TOP_R ............ UI_TOP_L
;   lignes du puits              UI_VERT_R [ puits ]   UI_VERT_L
;   ligne BOARD_Y+BOARD_H (bord) UI_WELL_BL UI_WELL_BOT.. UI_WELL_BR
; Le fond est la ligne du bord bas de la fenetre : WIN_Y+WIN_H-1.
; Appele entre vis_Sync_Begin et vis_Sync_End. Detruit A, B, Y, W.
    IFNE    BOARD_Y+BOARD_H-(WIN_Y+WIN_H-1)
    error   "le fond du puits doit etre sur le bord bas de la fenetre"
    ENDC
Draw_Well:
    ; departs des parois, sur le filet du titre
    LDA     #BOARD_X-1
    LDB     #BOARD_Y-1
    LDW     #(UI_TOP_R*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    LDA     #BOARD_X+BOARD_W*2
    LDW     #(UI_TOP_L*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    ; parois : une colonne de BOARD_H cases de chaque cote
    LDA     #BOARD_X-1
    LDB     #BOARD_Y
    LDW     #(1*256)+BOARD_H
    LDY     #(UI_VERT_R*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #BOARD_X+BOARD_W*2
    LDW     #(1*256)+BOARD_H    ; vis_Fill detruit W
    LDY     #(UI_VERT_L*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    ; fond, sur la ligne du bord bas
    LDA     #BOARD_X
    LDB     #BOARD_Y+BOARD_H
    LDW     #(BOARD_W*2*256)+1
    LDY     #(UI_WELL_BOT*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #BOARD_X-1
    LDW     #(UI_WELL_BL*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    LDA     #BOARD_X+BOARD_W*2
    LDW     #(UI_WELL_BR*256)+COLOR_WIN
    JSR     [VIS_TABLE+vis_PutCell]
    RTS

; Appele par Draw_Briques_Window, entre vis_Sync_Begin et vis_Sync_End
Update_Score_Display:
    LDE     #COLOR_TEXT
    LDA     #PANEL_X
    LDB     #WIN_Y+5
    LDX     #ValScore
    JSR     [VIS_TABLE+vis_Text]
    LDE     #COLOR_TEXT
    LDA     #PANEL_X
    LDB     #WIN_Y+9
    LDX     #ValLines
    JSR     [VIS_TABLE+vis_Text]
    RTS
; -------------------------------------------------------------------
; DONNÉES ET DONNÉES DU TETROMINO (4 rotations par pièce)
; -------------------------------------------------------------------
ColorTable:     FCB COLOR_BOARD,COL_I,COL_J,COL_L,COL_O,COL_S,COL_T,COL_Z
TitleBriques:    FCN " BRIQUES 6809 "
TxtScore:       FCN "SCORE"
TxtLines:       FCN "LIGNES"
ValScore:       FCN "000000"
ValLines:       FCN "000"
TxtGameOver1:   FCN "GAME"
TxtGameOver2:   FCN "OVER"
TxtVisVieux:    FCN "OSM-VISION trop ancien pour BRIQUES."
TxtPause:       FCN "PAUSE"

; Format : [dx1,dy1,dx2,dy2,dx3,dy3,dx4,dy4] x 4 rotations
PiecesData:
    ; --- Pièce I (Cyan) ---
    FCB 0,1,1,1,2,1,3,1   ; Rot 0
    FCB 2,0,2,1,2,2,2,3   ; Rot 1
    FCB 0,2,1,2,2,2,3,2   ; Rot 2
    FCB 1,0,1,1,1,2,1,3   ; Rot 3
    ; --- Pièce J (Bleu) ---
    FCB 0,0,0,1,1,1,2,1
    FCB 1,0,2,0,1,1,1,2
    FCB 0,1,1,1,2,1,2,2
    FCB 1,0,1,1,0,2,1,2
    ; --- Pièce L (Orange) ---
    FCB 2,0,0,1,1,1,2,1
    FCB 1,0,1,1,1,2,2,2
    FCB 0,1,1,1,2,1,0,2
    FCB 0,0,1,0,1,1,1,2
    ; --- Pièce O (Jaune) ---
    FCB 1,0,2,0,1,1,2,1
    FCB 1,0,2,0,1,1,2,1
    FCB 1,0,2,0,1,1,2,1
    FCB 1,0,2,0,1,1,2,1
    ; --- Pièce S (Vert) ---
    FCB 1,0,2,0,0,1,1,1
    FCB 1,0,1,1,2,1,2,2
    FCB 1,1,2,1,0,2,1,2
    FCB 0,0,0,1,1,1,2,2
    ; --- Pièce T (Violet) ---
    FCB 1,0,0,1,1,1,2,1
    FCB 1,0,1,1,2,1,1,2
    FCB 0,1,1,1,2,1,1,2
    FCB 1,0,0,1,1,1,1,2
    ; --- Pièce Z (Rouge) ---
    FCB 0,0,1,0,1,1,2,1
    FCB 2,0,1,1,2,1,1,2
    FCB 0,1,1,1,1,2,2,2
    FCB 1,0,0,1,1,1,0,2

;effets sonores (joues par vis_Sound : format lib/snd.inc)
; --- Effet : Rotation d'une pièce ---
Sfx_Rotate:
    FDB SFX_BEEP,SFX_SILENCE
    FCB 2                   ; Dure 2 frames (très court)
    FDB SFX_SILENCE,SFX_SILENCE
    FCB 1
    FDB SFX_END

; --- Effet : Pièce qui touche le fond (Lock) ---
Sfx_Lock:
    FDB SFX_DROP,SFX_SILENCE
    FCB 3
    FDB SFX_SILENCE,SFX_SILENCE
    FCB 1
    FDB SFX_END

; --- Effet : Ligne complétée (Petit arpège rapide) ---
Sfx_Clear:
    FDB SFX_LINE1,SFX_SILENCE
    FCB 3
    FDB SFX_LINE2,SFX_SILENCE
    FCB 3
    FDB SFX_LINE3,SFX_SILENCE
    FCB 6
    FDB SFX_SILENCE,SFX_SILENCE
    FCB 1
    FDB SFX_END

; --- Effet sonore dramatique ---
Sfx_GameOver:
    FDB $0A00,SFX_SILENCE  ; Note très grave
    FCB 20
    FDB $1000,SFX_SILENCE  ; Encore plus grave
    FCB 40
    FDB SFX_SILENCE,SFX_SILENCE
    FCB 1
    FDB SFX_END

; --- Variables de Jeu ---
PieceX          rmb 1
PieceY          rmb 1
PieceType       rmb 1
PieceRot        rmb 1
PieceLanded     rmb 1
DropTimer       rmb 1
RandomSeed      rmb 1
Score           rmb 2
Lines           rmb 1
DrawX           rmb 1
DrawY           rmb 1
TmpX            rmb 1
PauseBuf        rmb (PAUSE_W+1)*(PAUSE_H+1)*2 ; dessous de la fenetre de pause

; --- Rendu différentiel ---
PCell           rmb 4           ; indices des 4 cases de la pièce courante
DirtyList       rmb DIRTY_CAP*2 ; cases (x, y) à réévaluer
DirtyCnt        rmb 1
FullDirty       rmb 1           ; <>0 : balayage complet en cours
ScanX           rmb 1
ScanY           rmb 1
EvX             rmb 1
EvY             rmb 1
EvIdx           rmb 1
CpCnt           rmb 1
TmpY            rmb 1
PWi             rmb 1
PWBudget        rmb 1
WrCnt           rmb 1           ; écritures préparées pour la prochaine trame
LastWr          rmb 1           ; écritures faites à la dernière trame
ScoreStep       rmb 1           ; 0 = rien, 1 = ligne du score, 2 = ligne des lignes
WrVal           rmb WR_CAP
WrAddr          rmb WR_CAP*2
Disp            rmb BOARD_W*BOARD_H ; ce qui est actuellement affiché, case par case

BoardGrid       rmb BOARD_W*BOARD_H ; 10x20 octets

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
    include "../lib/joy.asm"
