; ===================================================================
; GLOUTON.ASM - GLOUTON pour OSM-VISION
; ===================================================================
; Application d'OSM-VISION, partie du modèle apps/mire.asm : liée à
; $4000, contrôle de version, sortie par RTS sans effacer l'écran.
;
; Labyrinthe et glyphes : video/glyphes_glouton.py, source UNIQUE. Il
; écrit la page 1 de video/font_osm39.bin ($88-$FF, réservés dans
; lib/ui.inc) et génère apps/glout_data.inc (ne pas l'éditer).
; La borne (28 x 31) y est ramenée à 27 x 21 cases ; une case = 2
; cellules côte à côte = 16 x 16 pixels.
;
; Commandes : flèches (ou pavé numérique), P pause, Espace pour
; rejouer, Echap pour quitter.
;
; DÉPLACEMENTS. Tout se fait case par case. Chaque acteur a un
; accumulateur de vitesse : à chaque trame on y ajoute sa vitesse, et
; une retenue fait un pas (vitesse 32 = un pas toutes les 8 trames,
; 7,5 cases par seconde). GLOUTON tourne dès que la direction demandée
; est libre ; les fantômes choisissent à chaque case, sans demi-tour,
; la direction qui rapproche le plus de leur cible (règle de la borne,
; égalités dans l'ordre haut, gauche, bas, droite). Cibles en poursuite :
; Rouge vise GLOUTON, Rose 4 cases devant lui, Cyan le symétrique de
; Rouge par rapport au point 2 cases devant, Orange GLOUTON s'il est à
; plus de 8 cases, sinon son coin. Effrayés, ils tournent au hasard.
;
; RENDU. Pas de double tampon d'écran : une case touchée (acteur qui
; part ou arrive, pastille qui clignote, point mangé) est mise dans
; une liste ; Compose recalcule son contenu (points gagnés > GLOUTON >
; fantômes > fruit > fond) et met ses deux cellules dans une file
; d'écriture, vidée juste après le VSYNC, APPLY_MAX cellules au plus
; par trame, IRQ masquées (comme ENVAHIS). Le labyrinthe entier se
; redessine une rangée par trame.
;
; CLAVIER : octets PS/2 bruts (SCAN_CODE), comme ENVAHIS : une flèche
; enfoncée oriente GLOUTON tout de suite, sans attendre le relâchement.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"
    include "../lib/snd.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Sound_Stop
VIS_REQUIS      equ (vis_Sound_Stop/2)+1

; --- Fenêtre, labyrinthe, panneau ---
WIN_X           equ 2
WIN_Y           equ 1           ; (la ligne 0 était hors écran avant le BIOS 80 x 30)
WIN_W           equ 76
WIN_H           equ 23
MZ_X            equ WIN_X+2     ; colonne écran de la case (0,0)
MZ_Y            equ WIN_Y+1     ; juste sous la barre de titre
PN_X            equ 60          ; panneau de droite
PN_Y            equ MZ_Y+1

; --- Cases particulières (vérifiées par le générateur) ---
PAC_X0          equ 13
PAC_Y0          equ 15
MAISON_X        equ 13          ; colonne de la porte
SORTIE_Y        equ 7           ; case au-dessus de la porte
MAISON_Y        equ 9           ; intérieur de la maison
FRUIT_X         equ 13
FRUIT_Y         equ 11
MSG_Y           equ 11          ; rangée des messages (READY!, GAME OVER)

; --- Directions (ordre des glyphes et des égalités de la borne) ---
D_HAUT          equ 0
D_GAUCHE        equ 1
D_BAS           equ 2
D_DROITE        equ 3           ; demi-tour = direction EOR 2

; --- Etats d'un fantôme ---
G_MAISON        equ 0           ; attend dans la maison
G_SORT          equ 1           ; sort par la porte
G_ACTIF         equ 2           ; dans le labyrinthe
G_YEUX          equ 3           ; mangé : les yeux rentrent
G_RENTRE        equ 4           ; les yeux passent la porte

; --- Etats du jeu ---
ST_READY        equ 0
ST_JEU          equ 1
ST_MANGE        equ 2           ; fantôme mangé : arrêt sur image, points
ST_MORT         equ 3
ST_FINI         equ 4           ; niveau terminé : le labyrinthe clignote
ST_OVER         equ 5

; --- Attributs (bit 7 = page 1 ; premier plan jamais nul, voir AGENTS.md) ---
ATTR_VIDE       equ COLOR_WIN   ; blanc sur noir : cases vides, points
ATTR_MUR        equ $89         ; bleu vif
ATTR_FLASH      equ $8F         ; blanc : fin de niveau, fin de peur
ATTR_PORTE      equ $8D
ATTR_PAC        equ $8E         ; jaune vif
ATTR_PEUR       equ $89
ATTR_YEUX       equ $8F
ATTR_PTS        equ $8B         ; cyan vif
ATTR_READY      equ $0E         ; texte (page 0) jaune
ATTR_OVER       equ $0C         ; rouge
ATTR_PAUSE      equ $0F
ATTR_LABEL      equ $0E
ATTR_VALEUR     equ $0F
ATTR_AIDE       equ $07

; --- Rendu ---
QCAP            equ 240         ; file d'écriture (index sur un octet)
APPLY_MAX       equ 40          ; cellules écrites par trame au plus
TCAP            equ 48          ; cases touchées par trame au plus

; --- Panneau : morceaux à réécrire ---
P_SCORE         equ $01
P_RECORD        equ $02
P_NIVEAU        equ $04
P_VIES          equ $08
VIES_MAX        equ 5           ; icônes affichées au plus

ASCII_0         equ $30         ; lib/str.asm (Dec16)
SN_B2           equ $1D28       ; 123,5 Hz (absente de lib/snd.inc)

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDA     >VIS_COUNT_ADR      ; '>' : adressage étendu, pas direct
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
    LDA     >vsync_tick+1       ; graine du hasard
    ORA     #1
    STA     Seed
    CLR     KbRel
    CLR     StartReq
    CLR     JoyAvant
    JSR     Joy_Init            ; le joystick (/BIN/JOYSTICK.CFG)
    CLR     PauseReq
    CLR     QuitReq
    CLR     EscUp
    CLR     TCount
    CLR     QHead
    CLR     QCount
    CLR     SndBusy
    CLR     RedrawOn
    CLR     MsgPending
    CLR     IntroPending
    CLR     PacVis
    CLR     GhostVis
    CLR     State               ; rien ne bouge avant New_Game
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Draw_Panel
    JSR     Load_HiScore
    JSR     New_Game

; -------------------------------------------------------------------
; Boucle principale : une trame par tour
; -------------------------------------------------------------------
Main_Loop:
    JSR     Wait_Frame          ; lit le clavier en attendant le VSYNC
    JSR     Apply_Queue         ; tout de suite après le VSYNC
    TST     QuitReq
    BNE     Quit
    LDA     QHead               ; file pas encore vidée : on attend
    CMPA    QCount
    BNE     Main_Loop
    JSR     Update
    JSR     Compose
    BRA     Main_Loop

; Sortie : silence, puis on attend le relâchement d'Echap (sinon
; OSM-VISION recevrait un F0 76 orphelin et le prendrait pour une touche).
Quit:
    JSR     [VIS_TABLE+vis_Sound_Stop]
    LDB     #30                 ; une demi-seconde au plus
Q_Wait:
    TST     EscUp
    BNE     Q_End
    PSHS    B
    JSR     Wait_Frame
    PULS    B
    DECB
    BNE     Q_Wait
Q_End:
    RTS                         ; OSM-VISION restaure l'écran

; -------------------------------------------------------------------
; Clavier
; -------------------------------------------------------------------
; Attend le prochain VSYNC (vsync_tick change) en lisant le clavier.
Wait_Frame:
    LDD     >vsync_tick
    STD     LastTick
WF_Loop:
    JSR     Poll_Keys
    LDD     >vsync_tick
    CMPD    LastTick
    BEQ     WF_Loop
    RTS

; Vide les octets PS/2 reçus. Le préfixe E0 est ignoré : les flèches
; et le pavé numérique (sans Verr. Num.) envoient les mêmes codes.
; Seuls les appuis comptent, sauf pour Echap (EscUp au relâchement).
Poll_Keys:
    TST     >NEW_CODE
    BEQ     PK_End
    CLR     >NEW_CODE
    LDA     >SCAN_CODE
    CMPA    #$E0
    BEQ     Poll_Keys
    CMPA    #$F0
    BNE     PK_Code
    STA     KbRel
    BRA     Poll_Keys
PK_Code:
    TST     KbRel
    BEQ     PK_Down
    CLR     KbRel
    CMPA    #$76                ; Echap relâché
    BNE     Poll_Keys
    LDA     #1
    STA     EscUp
    BRA     Poll_Keys
PK_Down:
    LDX     #KeyTbl
PK_Find:
    LDB     ,X
    BEQ     Poll_Keys           ; touche sans effet
    CMPA    ,X++
    BNE     PK_Find
    LDB     -1,X                ; action
    CMPB    #4
    BHS     PK_Act
    STB     WantDir             ; 0..3 : direction voulue
    BRA     Poll_Keys
PK_Act:
    LDA     #1
    CMPB    #4
    BNE     PK_P
    STA     StartReq
    BRA     Poll_Keys
PK_P:
    CMPB    #5
    BNE     PK_Q
    STA     PauseReq
    BRA     Poll_Keys
PK_Q:
    STA     QuitReq
    BRA     Poll_Keys
PK_End:
    ; (continue dans Joy_Touches)

; Joy_Touches : le joystick (lib/joy.asm) : une direction nouvellement
; poussée devient la direction voulue (en diagonale : la dernière
; poussée) ; le bouton, à l'appui, fait Espace (StartReq).
Joy_Touches:
    JSR     Joy_Lit
    LDB     JoyAvant
    STA     JoyAvant
    COMB
    PSHS    B
    ANDA    ,S+                 ; A = les appuis nouveaux
    BEQ     JT_Fin
    BITA    #JOY_BOUTON
    BEQ     JT_Dir
    LDB     #1
    STB     StartReq
JT_Dir:
    LDX     #JoyDirs            ; haut, droite, bas, gauche
JT_Bit:
    LSRA
    BCC     JT_Suiv
    LDB     ,X
    STB     WantDir
JT_Suiv:
    LEAX    1,X
    CMPX    #JoyDirs+4
    BLO     JT_Bit
JT_Fin:
    RTS
JoyDirs:
    FCB     D_HAUT,D_DROITE,D_BAS,D_GAUCHE

; Code PS/2 (jeu 2), action : 0-3 direction, 4 Espace, 5 pause, 6 Echap
KeyTbl:
    FCB     $75,D_HAUT
    FCB     $6B,D_GAUCHE
    FCB     $72,D_BAS
    FCB     $74,D_DROITE
    FCB     $29,4
    FCB     $4D,5
    FCB     $76,6
    FCB     0

; -------------------------------------------------------------------
; Parties, niveaux, vies
; -------------------------------------------------------------------
New_Game:
    CLR     Score
    CLR     Score+1
    LDA     #2                  ; vies en réserve (3 en tout)
    STA     Lives
    LDA     #1
    STA     Level
    CLR     BonusDone
    CLR     NewRecord
    LDA     #P_SCORE+P_RECORD+P_NIVEAU+P_VIES
    STA     PanelDirty
    JSR     New_Level
    JSR     Reset_Actors
    LDA     #248                ; durée de la musique d'ouverture
    JSR     Set_Ready
    LDA     #1                  ; elle part quand le labyrinthe est dessiné
    STA     IntroPending
    RTS

; Labyrinthe neuf (points, pastilles), vitesses et fruit du niveau.
New_Level:
    LDX     #LabInit
    LDY     #Lab
    LDW     #PM_W*PM_H
    TFM     X+,Y+
    LDA     #NB_POINTS_LAB
    STA     DotsLeft
    CLR     DotsEaten
    CLR     FruitOn
    CLR     FruitPtsT
    LDA     #$FF
    STA     PelOn
    LDA     #10
    STA     PelTimer
    LDA     #ATTR_MUR
    STA     WallAttr
    CLR     WallsOnly
    JSR     Start_Redraw
    LDA     PanelDirty
    ORA     #P_NIVEAU
    STA     PanelDirty
    ; niveau 1, 2-4, 5 et plus : vitesses, seuils de sortie
    LDB     Level
    LDX     #Spd1
    LDY     #RelSeuil1
    CMPB    #1
    BEQ     NL_Spd
    LDX     #Spd2
    LDY     #RelSeuil2
    CMPB    #5
    BLO     NL_Spd
    LDX     #Spd5
NL_Spd:
    LDA     ,X+
    STA     PacSpd
    LDA     ,X+
    STA     PacFrSpd
    LDA     ,X+
    STA     GhSpd
    LDA     ,X+
    STA     GhFrSpd
    LDA     ,X
    STA     GhTunSpd
    STY     RelPtr
    ; fruit : cerise, fraise, orange (3-4), pomme (5-6), melon
    LDB     Level
    CMPB    #8
    BLO     NL_Fr
    LDB     #8
NL_Fr:
    LDX     #FruitParNiv-1
    LDB     B,X
    STB     FruitIdx
    LDX     #FruitAttrTbl
    LDA     B,X
    STA     FruitAttr
    ASLB
    ADDB    #CHR_FRUIT
    STB     FruitChr
    RTS

; Tous les acteurs à leur place de départ.
Reset_Actors:
    CLRB                        ; efface les anciennes positions
RA_Old:
    JSR     Touch_Actor
    INCB
    CMPB    #5
    BLO     RA_Old
    LDY     #AX
    LDX     #StartX
    LDW     #5*4                ; AX, AY, ADir, GState : 4 tableaux de 5
    TFM     X+,Y+
    LDX     #AAcc
    LDB     #5*3                ; AAcc, GRev, GFright : 3 tableaux de 5
RA_Clr:
    CLR     ,X+
    DECB
    BNE     RA_Clr
    CLR     FrightT
    CLR     FrightT+1
    CLR     ModeIdx
    LDD     ModeTbl
    STD     ModeT
    CLR     RelTimer
    CLR     RelTimer+1
    LDA     #D_GAUCHE
    STA     WantDir
    CLR     PacStep
    CLR     PacDying
    CLR     GAnim
    LDA     #1
    STA     PacVis
    STA     GhostVis
    CLRB
RA_New:
    JSR     Touch_Actor
    INCB
    CMPB    #5
    BLO     RA_New
    RTS

; A = trames d'attente : READY! sous la maison, puis le jeu.
Set_Ready:
    STA     StTimer
    LDA     #ST_READY
    STA     State
    CLR     Paused
    LDX     #TxtReady
    LDA     #24                 ; 6 lettres centrées : cellules 24-29
    LDB     #ATTR_READY
    JMP     Show_Msg

; X = texte, A = première cellule (depuis la gauche du labyrinthe),
; B = attribut : affiché sur la rangée MSG_Y dès que le labyrinthe est
; dessiné.
Show_Msg:
    STX     MsgPtr
    STA     MsgCol
    STB     MsgAttr
    LDA     #1
    STA     MsgPending
    RTS

; Efface le message : les cases qu'il couvre sont redessinées.
Msg_Clear:
    CLR     MsgPending
    LDA     #11
MC_Loop:
    LDB     #MSG_Y
    JSR     Touch_Tile
    INCA
    CMPA    #16
    BLO     MC_Loop
    RTS

Game_Over:
    LDA     #ST_OVER
    STA     State
    LDX     #TxtOver
    LDA     #22                 ; 10 lettres centrées : cellules 22-31
    LDB     #ATTR_OVER
    JSR     Show_Msg
    TST     NewRecord
    BEQ     GO_End
    JSR     Save_HiScore
GO_End:
    RTS

; -------------------------------------------------------------------
; Meilleur score : fichier GLOUTON.HI de 2 octets sur la carte
; (même mécanique qu'ENVAHIS.HI)
; -------------------------------------------------------------------
; Lu seulement s'il fait exactement 2 octets : un fichier étranger ne
; peut pas écraser la mémoire du jeu. Absent ou illisible : record 0.
Load_HiScore:
    CLR     HiScore
    CLR     HiScore+1
    LDX     #HiName
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     LH_End              ; pas encore de record
    LDD     >g_find_fileInfo+20 ; taille, mot de poids fort
    BNE     LH_End
    CMPU    #2
    BNE     LH_End
    LDA     >current_page       ; FS_LoadFile : page de destination dans A
    LDX     #HiName
    LDY     #HiScore
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCC     LH_End
    CLR     HiScore             ; lecture ratée : record 0
    CLR     HiScore+1
LH_End:
    RTS

; Efface l'ancien fichier (FS_SaveFile crée toujours une nouvelle entrée),
; sauve les 2 octets, puis rw : ce n'est pas un programme.
Save_HiScore:
    LDX     #HiName
    JSR     [table_function_ram+sys_FS_DeleteFile]   ; absent : sans importance
    LDA     >current_page       ; FS_SaveFile : page SOURCE dans A
    LDX     #HiName
    LDY     #HiScore
    LDU     #2
    JSR     [table_function_ram+sys_FS_SaveFile]
    BCS     SH_Fin
    LDX     #HiName
    LDA     #$06                ; rw-
    JSR     [table_function_ram+sys_FS_SetAttributes]
SH_Fin:
    RTS

; -------------------------------------------------------------------
; Logique, une trame
; -------------------------------------------------------------------
Update:
    INC     Frame
    TST     SndBusy
    BEQ     U_Snd
    DEC     SndBusy
U_Snd:
    LDA     State
    CMPA    #ST_JEU
    LBEQ    Upd_Jeu
    CMPA    #ST_READY
    LBEQ    Upd_Ready
    CMPA    #ST_MANGE
    LBEQ    Upd_Mange
    CMPA    #ST_MORT
    LBEQ    Upd_Mort
    CMPA    #ST_FINI
    LBEQ    Upd_Fini
    ; ST_OVER : Espace pour rejouer
    JSR     Blink_Pellets
    TST     StartReq
    BEQ     UO_End
    CLR     StartReq
    JSR     New_Game
UO_End:
    RTS

Upd_Ready:
    CLR     StartReq
    CLR     PauseReq
    TST     RedrawOn            ; labyrinthe pas encore dessiné : on attend
    BNE     UR_End
    TST     IntroPending
    BEQ     UR_Tick
    CLR     IntroPending
    LDX     #Sd_Intro
    LDA     #250
    JSR     Snd_Fx
UR_Tick:
    DEC     StTimer
    BNE     UR_End
    JSR     Msg_Clear
    LDA     #ST_JEU
    STA     State
UR_End:
    RTS

Upd_Jeu:
    CLR     StartReq
    TST     PauseReq
    BEQ     UJ_NoP
    CLR     PauseReq
    COM     Paused
    BEQ     UJ_Reprise
    LDX     #TxtPause
    LDA     #24
    LDB     #ATTR_PAUSE
    JSR     Show_Msg
    JMP     [VIS_TABLE+vis_Sound_Stop]
UJ_Reprise:
    JSR     Msg_Clear
UJ_NoP:
    TST     Paused
    LBNE    UJ_End
    JSR     Blink_Pellets
    JSR     Anim_Ghosts
    JSR     Upd_Modes
    JSR     Upd_Fright
    JSR     Release_Ghosts
    JSR     Upd_Fruit
    ; GLOUTON
    LDA     PacSpd
    LDB     FrightT
    ORB     FrightT+1
    BEQ     UJ_PSpd
    LDA     PacFrSpd
UJ_PSpd:
    ADDA    AAcc
    STA     AAcc
    BCC     UJ_Ghosts
    JSR     Pac_Step
    LDA     State
    CMPA    #ST_JEU
    BNE     UJ_End
UJ_Ghosts:
    LDB     #1
UJ_GLoop:
    STB     CurG
    JSR     Ghost_Speed         ; A = vitesse du fantôme B
    LDB     CurG
    LDX     #AAcc
    ADDA    B,X
    STA     B,X                 ; STA laisse C intact
    BCC     UJ_GNext
    JSR     Ghost_Step
    LDA     State
    CMPA    #ST_JEU
    BNE     UJ_End
UJ_GNext:
    LDB     CurG
    INCB
    CMPB    #5
    BLO     UJ_GLoop
UJ_End:
    RTS

; Fantôme mangé : arrêt sur image une seconde, les points à sa place.
Upd_Mange:
    DEC     StTimer
    BNE     UM_End
    LDA     #ST_JEU
    STA     State
    LDA     PtsX
    LDB     PtsY
    JSR     Touch_Tile
UM_End:
    RTS

; GLOUTON touché : 1 s figé, les fantômes disparaissent, il se
; dégonfle (6 images), une pause, puis vie suivante ou fin de partie.
Upd_Mort:
    DEC     StTimer
    BNE     UD_End
    LDA     Phase
    BEQ     UD_P0
    CMPA    #1
    BEQ     UD_P1
    TST     Lives
    LBEQ    Game_Over
    DEC     Lives
    LDA     PanelDirty
    ORA     #P_VIES
    STA     PanelDirty
    JSR     Reset_Actors
    LDA     #120
    JMP     Set_Ready
UD_P0:
    CLR     GhostVis
    JSR     Touch_Ghosts
    JSR     Fruit_Off
    INC     Phase
    CLR     DeathFr
    LDA     #1
    STA     PacDying
    LDA     #8
    STA     StTimer
    CLRB
    JSR     Touch_Actor
    LDX     #Sd_Mort
    LDA     #90
    JMP     Snd_Fx
UD_P1:
    INC     DeathFr
    LDA     DeathFr
    CMPA    #6
    BLO     UD_Img
    CLR     PacVis
    INC     Phase
    LDA     #45
    BRA     UD_T
UD_Img:
    LDA     #8
UD_T:
    STA     StTimer
    CLRB
    JSR     Touch_Actor
UD_End:
    RTS

; Plus de points : 1 s figé, les fantômes disparaissent, le labyrinthe
; clignote 4 fois (blanc / bleu), puis niveau suivant.
Upd_Fini:
    TST     RedrawOn            ; un clignotement se dessine encore
    BNE     UF_End
    DEC     StTimer
    BNE     UF_End
    TST     Phase
    BNE     UF_Flash
    CLR     GhostVis
    JSR     Touch_Ghosts
    JSR     Fruit_Off
    LDA     #6                  ; blanc, bleu, 3 fois
    STA     FlashN
    INC     Phase
    LDA     #1
    STA     StTimer
    RTS
UF_Flash:
    LDA     FlashN
    BEQ     UF_Next
    DEC     FlashN
    LDA     #ATTR_FLASH
    LDB     WallAttr
    CMPB    #ATTR_MUR
    BEQ     UF_Set
    LDA     #ATTR_MUR
UF_Set:
    STA     WallAttr
    LDA     #1
    STA     WallsOnly
    JSR     Start_Redraw
    LDA     #6
    STA     StTimer
    RTS
UF_Next:
    INC     Level
    JSR     New_Level
    JSR     Reset_Actors
    LDA     #120
    JMP     Set_Ready
UF_End:
    RTS

Level_Clear:
    LDA     #ST_FINI
    STA     State
    CLR     Phase
    LDA     #60
    STA     StTimer
    JMP     [VIS_TABLE+vis_Sound_Stop]

; --- Pastilles : clignotent toutes les 10 trames ---
Blink_Pellets:
    DEC     PelTimer
    BNE     BP_End
    LDA     #10
    STA     PelTimer
    COM     PelOn
    LDX     #PelTbl
BP_Loop:
    LDA     ,X
    BMI     BP_End
    STA     NX
    LDB     1,X
    STB     NY
    PSHS    X
    JSR     Type_N
    CMPA    #T_PASTILLE         ; déjà mangée : rien à redessiner
    BNE     BP_Next
    LDA     NX
    LDB     NY
    JSR     Touch_Tile
BP_Next:
    PULS    X
    LEAX    2,X
    BRA     BP_Loop
BP_End:
    RTS

; --- Les jupes des fantômes ondulent toutes les 8 trames ---
Anim_Ghosts:
    LDA     Frame
    ANDA    #7
    BNE     AG_End
    LDA     GAnim
    EORA    #1
    STA     GAnim
    JMP     Touch_Ghosts
AG_End:
    RTS

; --- Dispersion / poursuite : la minuterie s'arrête pendant la peur ---
Upd_Modes:
    LDD     FrightT
    BNE     UMo_End
    LDD     ModeT
    BEQ     UMo_End             ; 0 : poursuite sans fin
    SUBD    #1
    STD     ModeT
    BNE     UMo_End
    INC     ModeIdx
    LDB     ModeIdx
    ASLB
    LDX     #ModeTbl
    ABX
    LDD     ,X
    STD     ModeT
    JMP     Reverse_All         ; changement de mode : demi-tour
UMo_End:
    RTS

; Demi-tour au prochain pas pour tous les fantômes du labyrinthe.
Reverse_All:
    LDB     #1
RVA_Loop:
    LDX     #GState
    LDA     B,X
    CMPA    #G_ACTIF
    BNE     RVA_Next
    LDX     #GRev
    LDA     #1
    STA     B,X
RVA_Next:
    INCB
    CMPB    #5
    BLO     RVA_Loop
    RTS

Upd_Fright:
    LDD     FrightT
    BEQ     UFr_End
    SUBD    #1
    STD     FrightT
    BNE     UFr_End
    LDX     #GFright            ; fin de la peur
    CLR     1,X
    CLR     2,X
    CLR     3,X
    CLR     4,X
    JMP     Touch_Ghosts
UFr_End:
    RTS

; Pastille mangée : peur (durée selon le niveau) et demi-tour.
Start_Fright:
    CLR     GhostEat
    LDB     Level
    CMPB    #19
    BLO     SF_Niv
    LDB     #19
SF_Niv:
    DECB
    ASLB
    LDX     #FrightTbl
    ABX
    LDD     ,X
    STD     FrightT
    JSR     Reverse_All
    LDD     FrightT
    BEQ     SF_Fin              ; niveaux hauts : demi-tour seulement
    LDB     #1
SF_Loop:
    LDX     #GState
    LDA     B,X
    CMPA    #G_YEUX             ; les yeux ne s'effraient pas
    BHS     SF_Next
    LDX     #GFright
    LDA     #1
    STA     B,X
SF_Next:
    INCB
    CMPB    #5
    BLO     SF_Loop
SF_Fin:
    JSR     Touch_Ghosts
    LDX     #Sd_Pastille
    LDA     #6
    JMP     Snd_Fx

; Un fantôme quitte la maison quand son seuil de temps OU de points
; est atteint ; un seul à la fois dans la porte.
Release_Ghosts:
    LDD     RelTimer
    ADDD    #1
    STD     RelTimer
    LDB     #1
RG_Busy:
    LDX     #GState
    LDA     B,X
    CMPA    #G_SORT
    BEQ     RG_End
    INCB
    CMPB    #5
    BLO     RG_Busy
    LDB     #2
RG_Loop:
    LDX     #GState
    LDA     B,X
    CMPA    #G_MAISON
    BNE     RG_Next
    STB     TmpG
    LDX     RelPtr              ; FCB seuil de points, FDB seuil de trames
    SUBB    #2
    LDA     #3
    MUL
    ABX
    LDA     ,X
    CMPA    DotsEaten
    BLS     RG_Go
    LDD     1,X
    CMPD    RelTimer
    BLS     RG_Go
    LDB     TmpG
RG_Next:
    INCB
    CMPB    #5
    BLO     RG_Loop
RG_End:
    RTS
RG_Go:
    LDB     TmpG
    LDX     #GState
    LDA     #G_SORT
    STA     B,X
    RTS

; --- Fruit : sort à 70 et 170 points mangés, 9,5 s ---
Fruit_Show:
    LDA     #1
    STA     FruitOn
    LDD     #570
    STD     FruitT
    BRA     Fruit_Touch

Fruit_Off:
    CLR     FruitOn
    CLR     FruitPtsT
Fruit_Touch:
    LDA     #FRUIT_X
    LDB     #FRUIT_Y
    JMP     Touch_Tile

Upd_Fruit:
    TST     FruitOn
    BEQ     UFt_Pts
    LDD     FruitT
    SUBD    #1
    STD     FruitT
    BNE     UFt_Pts
    CLR     FruitOn
    BSR     Fruit_Touch
UFt_Pts:
    TST     FruitPtsT
    BEQ     UFt_End
    DEC     FruitPtsT
    BNE     UFt_End
    BSR     Fruit_Touch
UFt_End:
    RTS

; -------------------------------------------------------------------
; GLOUTON
; -------------------------------------------------------------------
Pac_Step:
    CLR     CurA
    LDA     WantDir             ; tourne dès que c'est libre
    JSR     Can_Go
    BCS     PS_Keep
    STA     ADir
PS_Keep:
    LDA     ADir
    JSR     Can_Go
    BCS     PS_End              ; contre un mur : il s'arrête
    JSR     Actor_Move
    INC     PacStep
    JSR     Pac_Eat
    LDA     State
    CMPA    #ST_JEU
    BNE     PS_End
    JMP     Check_Collide
PS_End:
    RTS

; Ce qu'il y a sur la case de GLOUTON.
Pac_Eat:
    LDA     AX
    STA     NX
    LDA     AY
    STA     NY
    JSR     Type_N              ; X = la case dans Lab
    CMPA    #T_POINT
    BEQ     PE_Dot
    CMPA    #T_PASTILLE
    BNE     PE_Fruit
    CLR     ,X                  ; T_VIDE
    LDD     #5                  ; 50 points (le score compte par 10)
    JSR     Add_Score
    JSR     Start_Fright
    BRA     PE_Count
PE_Dot:
    CLR     ,X
    LDD     #1
    JSR     Add_Score
    JSR     Snd_Waka
PE_Count:
    INC     DotsEaten
    LDA     DotsEaten
    CMPA    #70
    BEQ     PE_FruitOn
    CMPA    #170
    BNE     PE_Left
PE_FruitOn:
    JSR     Fruit_Show
PE_Left:
    DEC     DotsLeft
    BNE     PE_Fruit
    JMP     Level_Clear
PE_Fruit:
    TST     FruitOn
    BEQ     PE_End
    LDA     AX
    CMPA    #FRUIT_X
    BNE     PE_End
    LDA     AY
    CMPA    #FRUIT_Y
    BNE     PE_End
    CLR     FruitOn
    LDB     FruitIdx
    ASLB
    LDX     #FruitValTbl
    ABX
    LDD     ,X
    JSR     Add_Score
    LDA     FruitIdx
    ADDA    #4                  ; PtsGly : 100, 300, 500, 700, 1000
    STA     FruitPtsIdx
    LDA     #120
    STA     FruitPtsT
    LDX     #Sd_Fruit
    LDA     #12
    JMP     Snd_Fx
PE_End:
    RTS

; D = points / 10. Vie en plus à 10 000 points, record en direct.
Add_Score:
    ADDD    Score
    STD     Score
    TST     BonusDone
    BNE     ASc_Hi
    CMPD    #1000
    BLO     ASc_Hi
    INC     BonusDone
    INC     Lives
    LDA     PanelDirty
    ORA     #P_VIES
    STA     PanelDirty
    LDX     #Sd_Vie
    LDA     #20
    JSR     Snd_Fx
ASc_Hi:
    LDD     Score
    CMPD    HiScore
    BLS     ASc_End
    STD     HiScore
    LDA     #1
    STA     NewRecord
    LDA     PanelDirty
    ORA     #P_RECORD
    STA     PanelDirty
ASc_End:
    LDA     PanelDirty
    ORA     #P_SCORE
    STA     PanelDirty
    RTS

; Collision avec un fantôme sur la même case : mangé s'il a peur,
; sinon GLOUTON meurt. Les yeux passent au travers.
Check_Collide:
    LDB     #1
CC_Loop:
    LDX     #GState
    LDA     B,X
    CMPA    #G_ACTIF
    BEQ     CC_Pos
    CMPA    #G_SORT
    BNE     CC_Next
CC_Pos:
    LDX     #AX
    LDA     B,X
    CMPA    AX
    BNE     CC_Next
    LDX     #AY
    LDA     B,X
    CMPA    AY
    BNE     CC_Next
    LDX     #GFright
    TST     B,X
    BNE     Eat_Ghost
    JMP     Pac_Die
CC_Next:
    INCB
    CMPB    #5
    BLO     CC_Loop
    RTS

; B = fantôme mangé : 200, 400, 800, 1600 pour une même pastille.
Eat_Ghost:
    LDX     #GFright
    CLR     B,X
    LDX     #GState
    LDA     #G_YEUX
    STA     B,X
    LDA     AX
    STA     PtsX
    LDA     AY
    STA     PtsY
    LDB     GhostEat
    STB     PtsIdx
    CMPB    #3
    BHS     EG_Max
    INC     GhostEat
EG_Max:
    ASLB
    LDX     #GhostPts
    ABX
    LDD     ,X
    JSR     Add_Score
    LDA     #ST_MANGE
    STA     State
    LDA     #60
    STA     StTimer
    LDA     PtsX
    LDB     PtsY
    JSR     Touch_Tile
    LDX     #Sd_Fantome
    LDA     #15
    JMP     Snd_Fx

Pac_Die:
    LDA     #ST_MORT
    STA     State
    CLR     Phase
    LDA     #60
    STA     StTimer
    JMP     [VIS_TABLE+vis_Sound_Stop]

; -------------------------------------------------------------------
; Fantômes
; -------------------------------------------------------------------
; B = fantôme -> A = vitesse. Détruit X.
Ghost_Speed:
    LDX     #GState
    LDA     B,X
    CMPA    #G_YEUX
    BHS     GSp_Yeux
    CMPA    #G_ACTIF
    BNE     GSp_Maison
    LDX     #GFright
    TST     B,X
    BNE     GSp_Peur
    LDX     #AY                 ; tunnel : ralenti
    LDA     B,X
    CMPA    #PM_TUNNEL
    BNE     GSp_Norm
    LDX     #AX
    LDA     B,X
    CMPA    #5
    BLS     GSp_Tun
    CMPA    #21
    BHS     GSp_Tun
GSp_Norm:
    LDA     GhSpd
    CMPB    #1                  ; Rouge accélère à 20 points de la fin
    BNE     GSp_Ret
    LDB     DotsLeft
    CMPB    #20
    BHI     GSp_Ret
    ADDA    #4
GSp_Ret:
    RTS
GSp_Tun:
    LDA     GhTunSpd
    RTS
GSp_Peur:
    LDA     GhFrSpd
    RTS
GSp_Maison:
    LDA     #24
    RTS
GSp_Yeux:
    LDA     #96
    RTS

; Un pas du fantôme CurG.
Ghost_Step:
    LDB     CurG
    STB     CurA
    LDX     #GState
    LDA     B,X
    CMPA    #G_ACTIF
    LBEQ    GSt_Actif
    CMPA    #G_YEUX
    BEQ     GSt_Yeux
    CMPA    #G_SORT
    BEQ     GSt_Sort
    CMPA    #G_RENTRE
    BEQ     GSt_Rentre
    LDX     #ADir               ; G_MAISON : regarde en haut, en bas
    LDA     B,X
    EORA    #2
    STA     B,X
    JMP     Touch_Actor

GSt_Sort:
    LDX     #AX                 ; vers la colonne de la porte, puis en haut
    LDA     B,X
    CMPA    #MAISON_X
    BEQ     GSo_Haut
    LDA     #D_DROITE           ; LDA garde C : BLO teste encore le CMPA
    BLO     GSo_Move
    LDA     #D_GAUCHE
    BRA     GSo_Move
GSo_Haut:
    LDA     #D_HAUT
GSo_Move:
    LDX     #ADir
    STA     B,X
    JSR     Actor_Move
    LDB     CurA
    LDX     #AY
    LDA     B,X
    CMPA    #SORTIE_Y
    BNE     GSo_End
    LDX     #GState             ; dehors : il part à gauche
    LDA     #G_ACTIF
    STA     B,X
    LDX     #ADir
    LDA     #D_GAUCHE
    STA     B,X
    JMP     Check_Collide
GSo_End:
    RTS

GSt_Rentre:
    LDA     #D_BAS
    LDX     #ADir
    STA     B,X
    JSR     Actor_Move
    LDB     CurA
    LDX     #AY
    LDA     B,X
    CMPA    #MAISON_Y
    BNE     GR_End
    LDX     #GState             ; revenu au centre : il ressort, guéri
    LDA     #G_SORT
    STA     B,X
    LDX     #GFright
    CLR     B,X
GR_End:
    RTS

GSt_Yeux:
    LDX     #AX                 ; au-dessus de la porte : on rentre
    LDA     B,X
    CMPA    #MAISON_X
    BNE     GY_Go
    LDX     #AY
    LDA     B,X
    CMPA    #SORTIE_Y
    BNE     GY_Go
    LDX     #GState
    LDA     #G_RENTRE
    STA     B,X
    BRA     GSt_Rentre
GY_Go:
    LDA     #MAISON_X
    STA     TgtX
    LDA     #SORTIE_Y
    STA     TgtY
    BRA     GA_Choose

GSt_Actif:
    LDX     #GFright
    TST     B,X
    BNE     GA_Peur
    JSR     Get_Target
GA_Choose:
    JSR     Choose_Dir
    BRA     GA_Move
GA_Peur:
    JSR     Random_Dir
GA_Move:
    LDB     CurA
    LDX     #ADir
    STA     B,X
    JSR     Actor_Move
    JMP     Check_Collide

; Cible du fantôme CurA (dispersion : son coin ; poursuite : sa règle).
Get_Target:
    LDA     ModeIdx
    BITA    #1
    BNE     GT_Chase
GT_Coin:
    LDB     CurA
    LDX     #ScatX
    LDA     B,X
    STA     TgtX
    LDX     #ScatY
    LDA     B,X
    STA     TgtY
    RTS
GT_Chase:
    LDB     CurA
    CMPB    #2
    BEQ     GT_Rose
    CMPB    #3
    BEQ     GT_Cyan
    LDA     AX                  ; Rouge, et Orange quand il est loin
    STA     TgtX
    LDA     AY
    STA     TgtY
    CMPB    #4
    BNE     GT_End
    LDA     AX+4                ; Orange : à 8 cases ou moins, son coin
    STA     NX
    LDA     AY+4
    STA     NY
    JSR     Dist2
    CMPD    #64
    BLS     GT_Coin
GT_End:
    RTS
GT_Rose:
    LDX     #RoseDX            ; 4 cases devant (vers le haut : aussi
    LDY     #RoseDY            ; 4 à gauche, comme sur la borne)
    BRA     GT_Ahead
GT_Cyan:
    LDX     #CyanDX
    LDY     #CyanDY
    BSR     GT_Ahead
    LDA     TgtX                ; 2 x (point devant) - Rouge
    ASLA
    SUBA    AX+1
    STA     TgtX
    LDA     TgtY
    ASLA
    SUBA    AY+1
    STA     TgtY
    RTS
GT_Ahead:
    LDB     ADir
    LDA     AX
    ADDA    B,X
    STA     TgtX
    LDA     AY
    ADDA    B,Y
    STA     TgtY
    RTS

; Direction du fantôme CurA vers TgtX/TgtY -> A.
Choose_Dir:
    LDB     CurA
    LDX     #GRev
    TST     B,X
    BEQ     CD_Normal
    CLR     B,X                 ; demi-tour demandé
    LDX     #ADir
    LDA     B,X
    EORA    #2
    JSR     Can_Go
    BCC     CD_Ret
CD_Normal:
    LDD     #$FFFF
    STD     BestDist
    LDA     #$FF
    STA     BestDir
    LDB     CurA
    LDX     #ADir
    LDA     B,X
    EORA    #2
    STA     RevDir
    CLRA
CD_Loop:
    STA     CandDir
    CMPA    RevDir              ; jamais de demi-tour de lui-même
    BEQ     CD_Next
    JSR     Can_Go              ; NX, NY = case voisine
    BCS     CD_Next
    JSR     Dist2
    CMPD    BestDist
    BHS     CD_Next             ; égalité : la première direction gagne
    STD     BestDist
    LDA     CandDir
    STA     BestDir
CD_Next:
    LDA     CandDir
    INCA
    CMPA    #4
    BLO     CD_Loop
    LDA     BestDir
    BPL     CD_Ret
    LDA     RevDir              ; cul-de-sac (n'existe pas ici)
CD_Ret:
    RTS

; Fantôme effrayé : direction au hasard, sans demi-tour -> A.
Random_Dir:
    JSR     Rand
    ANDA    #3
    STA     CandDir
    LDB     CurA
    LDX     #ADir
    LDA     B,X
    EORA    #2
    STA     RevDir
    LDA     #4
    STA     TmpN
RD_Loop:
    LDA     CandDir
    CMPA    RevDir
    BEQ     RD_Next
    JSR     Can_Go
    BCC     RD_Ret
RD_Next:
    LDA     CandDir
    INCA
    ANDA    #3
    STA     CandDir
    DEC     TmpN
    BNE     RD_Loop
    LDA     RevDir
RD_Ret:
    RTS

; D = distance² entre (NX,NY) et la cible (TgtX,TgtY), valeurs signées.
Dist2:
    LDA     NX
    SUBA    TgtX
    BPL     D2_X
    NEGA
D2_X:
    TFR     A,B
    MUL
    STD     TmpD
    LDA     NY
    SUBA    TgtY
    BPL     D2_Y
    NEGA
D2_Y:
    TFR     A,B
    MUL
    ADDD    TmpD
    RTS

; -------------------------------------------------------------------
; Cases
; -------------------------------------------------------------------
; A = direction, acteur CurA -> NX, NY : case voisine (le tunnel se
; replie d'un bord à l'autre). Préserve A.
Next_Tile:
    PSHS    A
    LDB     CurA
    LDX     #AX
    LDA     B,X
    LDB     ,S
    LDX     #DXTbl
    ADDA    B,X
    BPL     NT_Pos
    ADDA    #PM_W
NT_Pos:
    CMPA    #PM_W
    BLO     NT_In
    SUBA    #PM_W
NT_In:
    STA     NX
    LDB     CurA
    LDX     #AY
    LDA     B,X
    LDB     ,S
    LDX     #DYTbl
    ADDA    B,X
    STA     NY
    PULS    A,PC

; -> A = type de la case (NX,NY), X = son adresse dans Lab.
Type_N:
    LDA     #PM_W
    LDB     NY
    MUL
    ADDB    NX
    ADCA    #0
    ADDD    #Lab
    TFR     D,X
    LDA     ,X
    RTS

; A = direction : C = 0 si l'acteur CurA peut y aller (couloir, point,
; pastille ; ni mur ni porte), C = 1 sinon. NX, NY = la case. Préserve A.
Can_Go:
    BSR     Next_Tile
    PSHS    A
    BSR     Type_N
    CMPA    #T_MUR
    PULS    A                   ; PULS ne touche pas aux drapeaux
    BLO     CG_Ok
    ORCC    #1
    RTS
CG_Ok:
    ANDCC   #$FE
    RTS

; A = direction : l'acteur CurA avance d'une case (sans contrôle) ;
; l'ancienne et la nouvelle case sont à redessiner.
Actor_Move:
    LDB     CurA
    BSR     Touch_Actor
    BSR     Next_Tile
    LDB     CurA
    LDX     #AX
    LDA     NX
    STA     B,X
    LDX     #AY
    LDA     NY
    STA     B,X
    BRA     Touch_Actor

Touch_Ghosts:
    LDB     #1
TG_Loop:
    BSR     Touch_Actor
    INCB
    CMPB    #5
    BLO     TG_Loop
    RTS

; B = acteur : sa case est à redessiner. Préserve A, B.
Touch_Actor:
    PSHS    D
    LDX     #AX
    LDA     B,X
    LDX     #AY
    LDB     B,X
    BSR     Touch_Tile
    PULS    D,PC

; A = colonne, B = rangée : case à redessiner. Préserve A, B, X.
Touch_Tile:
    PSHS    X
    STB     TtY
    LDB     TCount
    CMPB    #TCAP
    BHS     TT_End
    LDX     #TouchX
    STA     B,X
    PSHS    A
    LDA     TtY
    LDX     #TouchY
    STA     B,X
    PULS    A
    INC     TCount
TT_End:
    LDB     TtY
    PULS    X,PC

Start_Redraw:
    CLR     RedrawY
    LDA     #1
    STA     RedrawOn
    RTS

; --- Hasard : générateur linéaire 8 bits mélangé au compteur de trames ---
Rand:
    LDA     #13
    LDB     Seed
    MUL
    ADDB    #7
    EORB    >vsync_tick+1
    STB     Seed
    TFR     B,A
    RTS

; --- Sons (vis_Sound : respecte la touche M d'OSM-VISION) ---
; X = partition, A = trames pendant lesquelles le « wa-ka » se tait.
Snd_Fx:
    STA     SndBusy
    JMP     [VIS_TABLE+vis_Sound]

Snd_Waka:
    TST     SndBusy
    BNE     SW_End
    LDX     #Sd_Waka1
    COM     WakaIdx
    BEQ     SW_Go
    LDX     #Sd_Waka2
SW_Go:
    JMP     [VIS_TABLE+vis_Sound]
SW_End:
    RTS

; -------------------------------------------------------------------
; Rendu
; -------------------------------------------------------------------
; Appelé quand la file est vide : cases touchées, une rangée du
; labyrinthe à redessiner, message, panneau.
Compose:
    CLR     QHead
    CLR     QCount
    CLR     TIdx
CP_Touch:
    LDB     TIdx
    CMPB    TCount
    BHS     CP_TDone
    LDX     #TouchX
    LDA     B,X
    STA     TX
    LDX     #TouchY
    LDA     B,X
    STA     TY
    JSR     Tile_Render
    INC     TIdx
    BRA     CP_Touch
CP_TDone:
    CLR     TCount
CP_Redraw:
    TST     RedrawOn
    BEQ     CP_Msg
    LDA     QCount              ; place pour une rangée entière ?
    CMPA    #QCAP-(PM_W*2)
    BHI     CP_Panel
    LDA     RedrawY
    STA     TY
    CLR     TX
CP_Row:
    TST     WallsOnly           ; clignotement : les murs seulement
    BEQ     CP_RAll
    LDA     TX
    STA     NX
    LDA     TY
    STA     NY
    JSR     Type_N
    CMPA    #T_MUR
    BNE     CP_RNext
CP_RAll:
    JSR     Tile_Render
CP_RNext:
    INC     TX
    LDA     TX
    CMPA    #PM_W
    BLO     CP_Row
    INC     RedrawY
    LDA     RedrawY
    CMPA    #PM_H
    BLO     CP_Redraw
    CLR     RedrawOn            ; le message attend la trame suivante
    BRA     CP_Panel
CP_Msg:
    TST     MsgPending
    BEQ     CP_Panel
    CLR     MsgPending
    LDA     MsgAttr
    STA     CurAttr
    LDX     MsgPtr
    LDA     MsgCol
    ADDA    #MZ_X
    LDB     #MZ_Y+MSG_Y
    JSR     Q_Text
CP_Panel:
    JMP     Q_Panel

; Case (TX,TY) : ses deux cellules en file.
Tile_Render:
    LDA     #VRAM_LIGNE
    LDB     TY
    ADDB    #MZ_Y
    MUL
    ADDD    #VRAM_BASE+MZ_X*VRAM_PAS
    ADDB    TX
    ADCA    #0
    ADDB    TX
    ADCA    #0
    IFNE    CARTE_MONO          ; mono : 2 octets par cellule
    ADDB    TX
    ADCA    #0
    ADDB    TX
    ADCA    #0
    ENDC
    STD     CellAddr
    JSR     Tile_Content
    LDX     CellAddr
    LDA     C1
    LDB     CA
    JSR     Q_Put
    LEAX    VRAM_PAS,X
    LDA     C2
    LDB     CA
    JMP     Q_Put

; Contenu de la case (TX,TY) -> C1, C2 (glyphes gauche, droite), CA.
; Priorité : points gagnés, GLOUTON, fantômes, fruit, fond.
Tile_Content:
    LDA     State
    CMPA    #ST_MANGE
    BNE     TC_Pac
    LDA     TX
    CMPA    PtsX
    BNE     TC_Pac
    LDA     TY
    CMPA    PtsY
    BNE     TC_Pac
    LDB     PtsIdx
    LBRA    TC_Pts
TC_Pac:
    TST     PacVis
    BEQ     TC_Ghosts
    LDA     TX
    CMPA    AX
    BNE     TC_Ghosts
    LDA     TY
    CMPA    AY
    BNE     TC_Ghosts
    LDA     #ATTR_PAC
    STA     CA
    TST     PacDying
    BEQ     TC_PacVit
    LDA     DeathFr
    ASLA
    ADDA    #CHR_MORT
    BRA     TC_Pair
TC_PacVit:
    LDA     PacStep             ; bouche : 1, 2, 1, 0 (fermée)
    ANDA    #3
    LDX     #MouthTbl
    LDA     A,X
    BEQ     TC_Ferme
    DECA
    ASLA
    STA     TmpC
    LDA     ADir                ; CHR_PAC + dir*4 + (ouverture-1)*2
    ASLA
    ASLA
    ADDA    TmpC
    ADDA    #CHR_PAC
    BRA     TC_Pair
TC_Ferme:
    LDA     #CHR_PAC_FERME
    BRA     TC_Pair
TC_Ghosts:
    TST     GhostVis
    BEQ     TC_Fruit
    LDB     #1                  ; Rouge d'abord : il passe devant
TC_GLoop:
    LDX     #AX
    LDA     B,X
    CMPA    TX
    BNE     TC_GNext
    LDX     #AY
    LDA     B,X
    CMPA    TY
    LBEQ    Ghost_Glyph
TC_GNext:
    INCB
    CMPB    #5
    BLO     TC_GLoop
TC_Fruit:
    LDA     TX
    CMPA    #FRUIT_X
    BNE     TC_Fond
    LDA     TY
    CMPA    #FRUIT_Y
    BNE     TC_Fond
    TST     FruitOn
    BEQ     TC_FPts
    LDA     FruitAttr
    STA     CA
    LDA     FruitChr
    BRA     TC_Pair
TC_FPts:
    TST     FruitPtsT
    BEQ     TC_Fond
    LDB     FruitPtsIdx
TC_Pts:
    LDA     #ATTR_PTS
    STA     CA
    ASLB
    LDX     #PtsGly
    ABX
    LDA     ,X
    STA     C1
    LDA     1,X
    STA     C2
    RTS
TC_Pair:
    STA     C1
    INCA
    STA     C2
    RTS
TC_Fond:
    LDA     TX
    STA     NX
    LDA     TY
    STA     NY
    JSR     Type_N
    CMPA    #T_MUR
    BEQ     TC_Mur
    CMPA    #T_POINT
    BEQ     TC_Point
    CMPA    #T_PASTILLE
    BEQ     TC_Past
    CMPA    #T_PORTE
    BEQ     TC_Porte
TC_Blanc:
    CLR     C1
    CLR     C2
    LDA     #ATTR_VIDE
    STA     CA
    RTS
TC_Point:
    LDA     #ATTR_VIDE
    STA     CA
    LDA     #CHR_POINT
    BRA     TC_Pair
TC_Past:
    TST     PelOn
    BEQ     TC_Blanc
    LDA     #ATTR_VIDE
    STA     CA
    LDA     #CHR_PASTILLE
    BRA     TC_Pair
TC_Porte:
    LDA     #ATTR_PORTE
    STA     CA
    LDA     #CHR_PORTE
    STA     C1
    STA     C2
    RTS
TC_Mur:
    TFR     X,D                 ; LabMurs + 2 x (case - Lab)
    SUBD    #Lab
    LSLD
    ADDD    #LabMurs
    TFR     D,X
    LDA     ,X
    STA     C1
    LDA     1,X
    STA     C2
    LDA     WallAttr
    STA     CA
    RTS

; B = fantôme sur la case (suite de Tile_Content).
Ghost_Glyph:
    STB     TmpG
    LDX     #GState
    LDA     B,X
    CMPA    #G_YEUX
    BLO     GG_Corps
    LDA     #ATTR_YEUX          ; les yeux seuls
    STA     CA
    LDX     #ADir
    LDA     B,X
    ASLA
    ADDA    #CHR_YEUX
    LBRA    TC_Pair
GG_Corps:
    LDX     #GFright
    TST     B,X
    BEQ     GG_Normal
    LDA     #ATTR_PEUR
    LDX     FrightT             ; les 2 dernières secondes : clignote
    CMPX    #120
    BHS     GG_Peur
    LDB     FrightT+1
    BITB    #16
    BEQ     GG_Peur
    LDA     #ATTR_FLASH
GG_Peur:
    STA     CA
    LDA     GAnim
    ASLA
    ADDA    #CHR_PEUR
    LBRA    TC_Pair
GG_Normal:
    LDX     #GAttr
    LDA     B,X
    STA     CA
    LDX     #ADir               ; CHR_FANT + dir*4 + jupe*2
    LDA     B,X
    ASLA
    ASLA
    STA     TmpC
    LDA     GAnim
    ASLA
    ADDA    TmpC
    ADDA    #CHR_FANT
    LBRA    TC_Pair

; X = adresse VRAM, A = caractère, B = attribut : une cellule en file.
; Préserve X ; détruit A, B.
Q_Put:
    STA     QpC
    STB     QpA
    STX     QpX
    LDB     QCount
    CMPB    #QCAP
    BHS     QP_End
    LDX     #QChr
    ABX
    LDA     QpC
    STA     ,X
    LDX     #QAttr
    ABX
    LDA     QpA
    STA     ,X
    LDX     #QAddr
    ABX
    ABX
    LDD     QpX
    STD     ,X
    INC     QCount
QP_End:
    LDX     QpX
    RTS

; X = texte (0 final), A = colonne, B = ligne d'écran, attribut CurAttr.
Q_Text:
    STA     TmpC
    LDA     #VRAM_LIGNE
    MUL
    ADDD    #VRAM_BASE
    ADDB    TmpC
    ADCA    #0
    IFNE    CARTE_MONO          ; mono : 2 octets par cellule
    ADDB    TmpC
    ADCA    #0
    ENDC
    STD     QtAddr
QT_Loop:
    LDA     ,X+
    BEQ     QT_End
    PSHS    X
    LDX     QtAddr
    LDB     CurAttr
    BSR     Q_Put
    LEAX    VRAM_PAS,X
    STX     QtAddr
    PULS    X
    BRA     QT_Loop
QT_End:
    RTS

; Panneau : les morceaux marqués dans PanelDirty.
Q_Panel:
    LDA     QCount
    CMPA    #QCAP-40
    LBHI    QPn_End             ; pas la place : à la trame suivante
    LDA     #ATTR_VALEUR
    STA     CurAttr
    LDA     PanelDirty
    BITA    #P_SCORE
    BEQ     QPn_Rec
    LDA     #PN_Y+1
    STA     PnRow
    LDD     Score
    BSR     QPn_Score
QPn_Rec:
    LDA     PanelDirty
    BITA    #P_RECORD
    BEQ     QPn_Niv
    LDA     #PN_Y+4
    STA     PnRow
    LDD     HiScore
    BSR     QPn_Score
QPn_Niv:
    LDA     PanelDirty
    BITA    #P_NIVEAU
    BEQ     QPn_Vies
    LDA     #PN_Y+7
    STA     PnRow
    LDU     #Line
    CLRA
    LDB     Level
    JSR     Dec16
    BSR     QPn_Line
QPn_Vies:
    LDA     PanelDirty
    BITA    #P_VIES
    BEQ     QPn_Fin
    LDA     #VRAM_LIGNE         ; adresse de la première icône
    LDB     #PN_Y+10
    MUL
    ADDD    #VRAM_BASE+PN_X*VRAM_PAS
    TFR     D,X
    CLR     TmpN
QPn_VLoop:
    LDA     TmpN
    CMPA    Lives
    BHS     QPn_VVide
    LDA     #CHR_PAC+(D_GAUCHE*4)+2   ; GLOUTON tourné à gauche, grand ouvert
    LDB     #ATTR_PAC
    BRA     QPn_VPut
QPn_VVide:
    CLRA
    LDB     #ATTR_VIDE
QPn_VPut:
    PSHS    D
    JSR     Q_Put
    LEAX    VRAM_PAS,X
    LDD     ,S
    TSTA
    BEQ     QPn_V2
    INCA
QPn_V2:
    JSR     Q_Put
    LEAX    2*VRAM_PAS,X        ; une cellule d'écart
    PULS    D
    INC     TmpN
    LDA     TmpN
    CMPA    #VIES_MAX
    BLO     QPn_VLoop
QPn_Fin:
    CLR     PanelDirty
QPn_End:
    RTS
; Valeur du score (D) suivie d'un 0 (le score compte par 10).
QPn_Score:
    LDU     #Line
    JSR     Dec16
    LDA     #ASCII_0
    STA     ,U+
; Line (U = fin) complétée d'espaces sur 8 caractères, ligne PnRow.
QPn_Line:
    LDA     #$20
QPL_Pad:
    CMPU    #Line+8
    BHS     QPL_Put
    STA     ,U+
    BRA     QPL_Pad
QPL_Put:
    CLR     ,U
    LDX     #Line
    LDA     #PN_X
    LDB     PnRow
    JMP     Q_Text

; Ecrit au plus APPLY_MAX cellules de la file, juste après le VSYNC,
; IRQ masquées : chaque caractère et sa couleur (V4 : $9000 = $8000 + 4 Ko).
Apply_Queue:
    LDB     QCount
    SUBB    QHead
    BEQ     AQ_End
    CMPB    #APPLY_MAX
    BLS     AQ_N
    LDB     #APPLY_MAX
AQ_N:
    STB     ApN
    ORCC    #%00010000
    BSR     AQ_Ptr              ; U = QAddr + 2 x QHead, B = QHead
    LDX     #QChr
    ABX                         ; X = QChr[QHead] ; QAttr suit QChr (QCAP,X)
    LDB     ApN
AQ_Cell:
    LDY     ,U++                ; adresse (16 bits : +2 voulu)
    LDA     ,X                  ; caractère...
    STA     ,Y
    LDA     QCAP,X              ; ... et sa couleur, 4 Ko plus haut (V4)
    STA     VRAM_COL_OFS,Y
    LEAX    1,X
    DECB
    BNE     AQ_Cell
    ANDCC   #%11101111
    LDA     QHead
    ADDA    ApN
    STA     QHead
AQ_End:
    RTS
; U = QAddr + QHead*2, B = QHead
AQ_Ptr:
    LDB     QHead
    CLRA
    LSLD
    ADDD    #QAddr
    TFR     D,U
    LDB     QHead
    RTS

; Textes fixes du panneau, une ligne par VSYNC (vis_Text ne se
; synchronise pas).
Draw_Panel:
    LDX     #PanelTxt
DP_Loop:
    LDB     ,X+                 ; ligne, $FF = fin
    CMPB    #$FF
    BEQ     DP_End
    LDE     ,X+                 ; attribut
    PSHS    X
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     ,S
    LDA     #PN_X
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    PULS    X
DP_Skip:
    LDA     ,X+                 ; texte suivant
    BNE     DP_Skip
    BRA     DP_Loop
DP_End:
    RTS

; Append / Dec16 : source unique lib/str.asm (U = pointeur d'écriture)
    include "../lib/str.asm"

; Labyrinthe, codes des glyphes, points : générés (video/glyphes_glouton.py)
    include "glout_data.inc"

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
TxtTitre:       FCN " GLOUTON "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour GLOUTON."
TxtReady:       FCN "READY!"
TxtOver:        FCN "GAME  OVER"
TxtPause:       FCN "PAUSE "
HiName:         FCC "GLOUTON.HI      "   ; 15 caractères, complété par des espaces

PanelTxt:
    FCB     PN_Y,ATTR_LABEL
    FCN     "SCORE"
    FCB     PN_Y+3,ATTR_LABEL
    FCN     "RECORD"
    FCB     PN_Y+6,ATTR_LABEL
    FCN     "NIVEAU"
    FCB     PN_Y+9,ATTR_LABEL
    FCN     "VIES"
    FCB     PN_Y+13,ATTR_AIDE
    FCN     "Fleches : diriger"
    FCB     PN_Y+14,ATTR_AIDE
    FCN     "P : pause"
    FCB     PN_Y+15,ATTR_AIDE
    FCN     "Espace : rejouer"
    FCB     PN_Y+16,ATTR_AIDE
    FCN     "Echap : quitter"
    FCB     $FF

DXTbl:          FCB 0,-1,0,1            ; haut, gauche, bas, droite
DYTbl:          FCB -1,0,1,0
RoseDX:        FCB -4,-4,0,4
RoseDY:        FCB -4,0,4,0
CyanDX:         FCB -2,-2,0,2
CyanDY:         FCB -2,0,2,0
ScatX:          FCB 0,24,2,26,0         ; coins (indice 0 : GLOUTON)
ScatY:          FCB 0,-3,-3,23,23
GAttr:          FCB 0,$8C,$8D,$8B,$86   ; Rouge, Rose, Cyan, Orange
MouthTbl:       FCB 1,2,1,0
PelTbl:         FCB 1,2,25,2,1,15,25,15,$FF

; Départ : AX, AY, ADir, GState (GLOUTON, Rouge, Rose, Cyan, Orange)
StartX:         FCB PAC_X0,13,13,11,15
StartY:         FCB PAC_Y0,SORTIE_Y,MAISON_Y,MAISON_Y,MAISON_Y
StartDir:       FCB D_GAUCHE,D_GAUCHE,D_BAS,D_HAUT,D_HAUT
StartState:     FCB 0,G_ACTIF,G_MAISON,G_MAISON,G_MAISON

; Vitesses : GLOUTON, GLOUTON (peur), fantôme, fantôme effrayé, tunnel
Spd1:           FCB 32,36,30,20,16
Spd2:           FCB 36,38,34,22,18
Spd5:           FCB 40,40,38,24,20
; Sortie de la maison (Rose, Cyan, Orange) : FCB points, FDB trames
RelSeuil1:
    FCB     0
    FDB     0
    FCB     30
    FDB     300
    FCB     60
    FDB     540
RelSeuil2:
    FCB     0
    FDB     0
    FCB     10
    FDB     150
    FCB     40
    FDB     300
; Dispersion / poursuite (trames) ; 0 = poursuite sans fin
ModeTbl:        FDB 420,1200,420,1200,300,1200,300,0
; Durée de la peur par niveau (trames), niveaux 1 à 19 et plus
FrightTbl:      FDB 360,300,240,180,120,300,120,120,60,300
                FDB 120,60,60,180,60,60,0,60,0
GhostPts:       FDB 20,40,80,160        ; par 10
FruitParNiv:    FCB 0,1,2,2,3,3,4,4     ; niveaux 1 à 8 et plus
FruitAttrTbl:   FCB $8C,$8D,$86,$8C,$8A
FruitValTbl:    FDB 10,30,50,70,100     ; par 10

; Partitions : FDB voix1,voix2 / FCB durée ; fin FDB SN_END (lib/snd.inc)
Sd_Waka1:
    FDB     SN_E5,SN_SIL
    FCB     0
    FDB     SN_C5,SN_SIL
    FCB     0
    FDB     SN_A4,SN_SIL
    FCB     0
    FDB     SN_END
Sd_Waka2:
    FDB     SN_A4,SN_SIL
    FCB     0
    FDB     SN_C5,SN_SIL
    FCB     0
    FDB     SN_E5,SN_SIL
    FCB     0
    FDB     SN_END
Sd_Pastille:
    FDB     SN_G5,SN_SIL
    FCB     0
    FDB     SN_B5,SN_SIL
    FCB     0
    FDB     SN_D6,SN_SIL
    FCB     0
    FDB     SN_G6,SN_SIL
    FCB     1
    FDB     SN_END
Sd_Fantome:
    FDB     SN_C5,SN_SIL
    FCB     1
    FDB     SN_E5,SN_SIL
    FCB     1
    FDB     SN_G5,SN_SIL
    FCB     1
    FDB     SN_C6,SN_SIL
    FCB     1
    FDB     SN_E6,SN_SIL
    FCB     1
    FDB     SN_G6,SN_SIL
    FCB     3
    FDB     SN_END
Sd_Fruit:
    FDB     SN_C6,SN_SIL
    FCB     1
    FDB     SN_G5,SN_SIL
    FCB     1
    FDB     SN_C6,SN_SIL
    FCB     1
    FDB     SN_E6,SN_SIL
    FCB     3
    FDB     SN_END
Sd_Vie:
    FDB     SN_E6,SN_SIL
    FCB     3
    FDB     SN_SIL,SN_SIL
    FCB     1
    FDB     SN_E6,SN_SIL
    FCB     3
    FDB     SN_SIL,SN_SIL
    FCB     1
    FDB     SN_E6,SN_SIL
    FCB     3
    FDB     SN_END
; Ouverture de la borne (deux voix, 248 trames), générée par un script
; jetable : mélodie en doubles croches, basse en croches, notes piquées.
Sd_Intro:
    FDB     SN_B4,SN_B2
    FCB     6
    FDB     SN_SIL,SN_B2
    FCB     0
    FDB     SN_B5,SN_B2
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_Gb5,SN_B3
    FCB     6
    FDB     SN_SIL,SN_B3
    FCB     0
    FDB     SN_Eb5,SN_B3
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_B5,SN_B2
    FCB     2
    FDB     SN_SIL,SN_B2
    FCB     0
    FDB     SN_Gb5,SN_B2
    FCB     10
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_Eb5,SN_B3
    FCB     14
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_C5,SN_C3
    FCB     6
    FDB     SN_SIL,SN_C3
    FCB     0
    FDB     SN_C6,SN_C3
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_G6,SN_C4
    FCB     6
    FDB     SN_SIL,SN_C4
    FCB     0
    FDB     SN_E6,SN_C4
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_C6,SN_C3
    FCB     2
    FDB     SN_SIL,SN_C3
    FCB     0
    FDB     SN_G6,SN_C3
    FCB     10
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_E6,SN_C4
    FCB     14
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_B4,SN_B2
    FCB     6
    FDB     SN_SIL,SN_B2
    FCB     0
    FDB     SN_B5,SN_B2
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_Gb5,SN_B3
    FCB     6
    FDB     SN_SIL,SN_B3
    FCB     0
    FDB     SN_Eb5,SN_B3
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_B5,SN_B2
    FCB     2
    FDB     SN_SIL,SN_B2
    FCB     0
    FDB     SN_Gb5,SN_B2
    FCB     10
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_Eb5,SN_B3
    FCB     14
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_Eb5,SN_Gb3
    FCB     2
    FDB     SN_SIL,SN_Gb3
    FCB     0
    FDB     SN_E5,SN_Gb3
    FCB     2
    FDB     SN_SIL,SN_Gb3
    FCB     0
    FDB     SN_F5,SN_Gb3
    FCB     2
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_F5,SN_Ab3
    FCB     2
    FDB     SN_SIL,SN_Ab3
    FCB     0
    FDB     SN_Gb5,SN_Ab3
    FCB     2
    FDB     SN_SIL,SN_Ab3
    FCB     0
    FDB     SN_G5,SN_Ab3
    FCB     2
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_G5,SN_Bb3
    FCB     2
    FDB     SN_SIL,SN_Bb3
    FCB     0
    FDB     SN_Ab5,SN_Bb3
    FCB     2
    FDB     SN_SIL,SN_Bb3
    FCB     0
    FDB     SN_A5,SN_Bb3
    FCB     6
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_B5,SN_B3
    FCB     14
    FDB     SN_SIL,SN_SIL
    FCB     0
    FDB     SN_END
; Mort : descente en vibrato puis deux « bloups » (80 trames)
Sd_Mort:
    FDB     $0417,SN_SIL
    FCB     1
    FDB     $03A7,SN_SIL
    FCB     1
    FDB     $0484,SN_SIL
    FCB     1
    FDB     $0408,SN_SIL
    FCB     1
    FDB     $04FD,SN_SIL
    FCB     1
    FDB     $0474,SN_SIL
    FCB     1
    FDB     $0582,SN_SIL
    FCB     1
    FDB     $04EB,SN_SIL
    FCB     1
    FDB     $0614,SN_SIL
    FCB     1
    FDB     $056E,SN_SIL
    FCB     1
    FDB     $06B6,SN_SIL
    FCB     1
    FDB     $05FE,SN_SIL
    FCB     1
    FDB     $0769,SN_SIL
    FCB     1
    FDB     $069E,SN_SIL
    FCB     1
    FDB     $082F,SN_SIL
    FCB     1
    FDB     $074E,SN_SIL
    FCB     1
    FDB     $0909,SN_SIL
    FCB     1
    FDB     $0811,SN_SIL
    FCB     1
    FDB     $09F9,SN_SIL
    FCB     1
    FDB     $08E8,SN_SIL
    FCB     1
    FDB     $0B03,SN_SIL
    FCB     1
    FDB     $09D5,SN_SIL
    FCB     1
    FDB     $0C28,SN_SIL
    FCB     1
    FDB     $0ADB,SN_SIL
    FCB     1
    FDB     $0D6C,SN_SIL
    FCB     1
    FDB     $0BFC,SN_SIL
    FCB     1
    FDB     $0ED2,SN_SIL
    FCB     1
    FDB     $0D3C,SN_SIL
    FCB     1
    FDB     $0000,SN_SIL
    FCB     7
    FDB     $1200,SN_SIL
    FCB     0
    FDB     $0C00,SN_SIL
    FCB     0
    FDB     $0900,SN_SIL
    FCB     0
    FDB     $0733,SN_SIL
    FCB     0
    FDB     $0000,SN_SIL
    FCB     3
    FDB     $1200,SN_SIL
    FCB     0
    FDB     $0C00,SN_SIL
    FCB     0
    FDB     $0900,SN_SIL
    FCB     0
    FDB     $0733,SN_SIL
    FCB     0
    FDB     $0000,SN_SIL
    FCB     3
    FDB     SN_END

; --- Variables ---
Seed            rmb 1
LastTick        rmb 2
KbRel           rmb 1           ; préfixe F0 reçu
WantDir         rmb 1           ; direction demandée au clavier
JoyAvant        rmb 1           ; le joystick à la trame d'avant
StartReq        rmb 1
PauseReq        rmb 1
QuitReq         rmb 1
EscUp           rmb 1
State           rmb 1
Phase           rmb 1           ; étape dans ST_MORT / ST_FINI
StTimer         rmb 1
Paused          rmb 1           ; $FF : en pause
Frame           rmb 1
SndBusy         rmb 1           ; trames pendant lesquelles le wa-ka se tait
WakaIdx         rmb 1
IntroPending    rmb 1
Score           rmb 2           ; par 10
HiScore         rmb 2           ; par 10 (GLOUTON.HI)
NewRecord       rmb 1
BonusDone       rmb 1           ; vie en plus déjà donnée
Lives           rmb 1           ; vies en réserve
Level           rmb 1           ; 1, 2...
DotsLeft        rmb 1
DotsEaten       rmb 1
PelOn           rmb 1           ; $FF : pastilles visibles
PelTimer        rmb 1
WallAttr        rmb 1
WallsOnly       rmb 1
FlashN          rmb 1
PacSpd          rmb 1           ; vitesses du niveau (Spd1/2/5)
PacFrSpd        rmb 1
GhSpd           rmb 1
GhFrSpd         rmb 1
GhTunSpd        rmb 1
RelPtr          rmb 2           ; RelSeuil1 / RelSeuil2
RelTimer        rmb 2           ; trames depuis le début de la vie
ModeIdx         rmb 1           ; pair : dispersion, impair : poursuite
ModeT           rmb 2
FrightT         rmb 2           ; trames de peur restantes
GhostEat        rmb 1           ; fantômes mangés sur cette pastille
FruitOn         rmb 1
FruitT          rmb 2
FruitIdx        rmb 1
FruitChr        rmb 1
FruitAttr       rmb 1
FruitPtsT       rmb 1
FruitPtsIdx     rmb 1
PtsX            rmb 1           ; points d'un fantôme mangé
PtsY            rmb 1
PtsIdx          rmb 1
PacVis          rmb 1
GhostVis        rmb 1
PacDying        rmb 1
DeathFr         rmb 1
PacStep         rmb 1           ; pas faits (bouche)
GAnim           rmb 1           ; jupe 0/1
; Acteurs : 0 = GLOUTON, 1 Rouge, 2 Rose, 3 Cyan, 4 Orange.
; AX..GState dans cet ordre (copiés d'un bloc depuis StartX..StartState),
; AAcc..GFright dans cet ordre (effacés d'un bloc) : Reset_Actors.
AX              rmb 5
AY              rmb 5
ADir            rmb 5
GState          rmb 5
AAcc            rmb 5           ; accumulateurs de vitesse
GRev            rmb 5           ; demi-tour au prochain pas
GFright         rmb 5           ; effrayé
CurA            rmb 1           ; acteur traité
CurG            rmb 1
NX              rmb 1           ; case voisine / case examinée
NY              rmb 1
TgtX            rmb 1           ; cible (signée)
TgtY            rmb 1
BestDist        rmb 2
BestDir         rmb 1
CandDir         rmb 1
RevDir          rmb 1
TmpD            rmb 2
TmpG            rmb 1
TmpC            rmb 1
TmpN            rmb 1
TtY             rmb 1
NumStarted      rmb 1           ; lib/str.asm (Dec16)
DigitCnt        rmb 1           ; lib/str.asm (Dec16)
Line            rmb 12
PnRow           rmb 1
PanelDirty      rmb 1
MsgPending      rmb 1
MsgPtr          rmb 2
MsgCol          rmb 1
MsgAttr         rmb 1
CurAttr         rmb 1
RedrawOn        rmb 1
RedrawY         rmb 1
TX              rmb 1           ; case en cours de rendu
TY              rmb 1
C1              rmb 1
C2              rmb 1
CA              rmb 1
CellAddr        rmb 2
QtAddr          rmb 2
QpC             rmb 1
QpA             rmb 1
QpX             rmb 2
TCount          rmb 1
TIdx            rmb 1
TouchX          rmb TCAP
TouchY          rmb TCAP
QHead           rmb 1
QCount          rmb 1
ApN             rmb 1
QAddr           rmb QCAP*2
QChr            rmb QCAP
QAttr           rmb QCAP
Lab             rmb PM_W*PM_H   ; le labyrinthe en cours (points mangés)

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
    include "../lib/joy.asm"
